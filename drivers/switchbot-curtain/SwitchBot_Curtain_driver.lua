--[[
  SwitchBot Curtain (child) driver for Control4 (OS 3.4.x)
  Version: 2.0.0
  One instance = one window: a SwitchBot Curtain/Blind (Device ID), optionally a second unpaired motor
  (Second Device ID). It has no Token or Secret: bind its SwitchBot connection to a "SwitchBot Cloud"
  (parent) driver, which talks to the SwitchBot cloud API and polls status for every child.

  Messages (C4:SendToDevice, arrive in ExecuteCommand):
    to parent:   SB_REGISTER {CHILD_ID, IDS}, SB_COMMAND {IDS, COMMAND, PARAMETER}, SB_POLL {IDS}
    from parent: SB_STATUS {DEVICE_ID, POSITION, MOVING, BATTERY}, SB_PARENT_STATUS {TEXT}, SB_HELLO
]]

local DRIVER_VERSION = "2.0.0"
local PROXY_BINDING = 5001
local CLOUD_BINDING = 1
local COMMAND_DEBOUNCE_MS = 800   -- rapid button presses collapse into the last one
local FOLLOWUP_FIRST_MS = 6000    -- first status check after a command
local FOLLOWUP_MS = 4000          -- later checks while the curtain is moving
local HOLD_SECONDS = 30           -- cloud status is stale this long after a command
local MAX_FOLLOWUPS = 30          -- stop chasing after about two minutes
local LEVEL_TOLERANCE = 5         -- close enough to the target level

local state = {
  lastLevel = nil,
  cmdTimer = nil,      -- debounce timer for the pending command
  pending = nil,       -- {command, parameter} waiting to be sent
  followTimer = nil,   -- single follow-up status poll
  followCount = 0,
  targetLevel = nil,   -- level the last command is heading to
  proxySetup = false,  -- SET_CAN_STOP / SET_HAS_LEVEL sent to the proxy
  holdUntil = 0,       -- os.time() until which a non-matching idle status is treated as stale
  dev = {},            -- latest status per device ID
}

local function prop(name)
  local ok, v = pcall(function() return Properties[name] end)
  if ok then return v end
  return nil
end

local function setProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value)) end)
end

local function setStatus(text)
  setProp("Status", text)
  pcall(function() print("[SwitchBot Curtain] " .. text) end)
end

local function stamp()
  local ok, v = pcall(os.date, "%H:%M:%S")
  return ok and v or "--:--:--"
end

local function paramsText(t)
  if type(t) ~= "table" then return tostring(t) end
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function clamp(n, lo, hi)
  if n < lo then return lo elseif n > hi then return hi end
  return n
end

-- Invert Level depends on how each motor was calibrated in the SwitchBot app. With False the level is the
-- SwitchBot slidePosition (100 = open on Den West); with True it is 100 - position (the Lounge pair).
local function invertLevel()
  return (prop("Invert Level") or "False") == "True"
end

local function levelToPosition(level)
  if invertLevel() then return 100 - level end
  return level
end

local function positionToLevel(pos)
  if invertLevel() then return 100 - pos end
  return pos
end

-- ============================================================================
-- Link to the parent
-- ============================================================================
local function deviceIds()
  local ids = {}
  for _, name in ipairs({ "Device ID", "Second Device ID" }) do
    local v = (prop(name) or ""):gsub("%s+", "")
    if v ~= "" and v ~= ids[1] then ids[#ids + 1] = v end
  end
  return ids
end

local function parentId()
  local ok, id = pcall(function() return C4:GetBoundProviderDevice(C4:GetDeviceID(), CLOUD_BINDING) end)
  id = ok and tonumber(id) or nil
  if id and id > 0 then return id end
  return nil
end

local function sendToParent(cmd, params)
  local pid = parentId()
  if not pid then
    setStatus("Not connected: bind SwitchBot Cloud in Connections")
    return false
  end
  pcall(function() C4:SendToDevice(pid, cmd, params or {}) end)
  return true
end

local function register()
  local ids = deviceIds()
  if #ids == 0 then
    setStatus("Set Device ID (run Discover Devices on the SwitchBot Cloud driver)")
    return
  end
  local cid = 0
  pcall(function() cid = C4:GetDeviceID() end)
  if sendToParent("SB_REGISTER", { CHILD_ID = tostring(cid), IDS = table.concat(ids, ",") }) then
    setStatus("Waiting for SwitchBot Cloud")
  end
end

local function requestPoll()
  local ids = deviceIds()
  if #ids > 0 then sendToParent("SB_POLL", { IDS = table.concat(ids, ",") }) end
end

-- ============================================================================
-- Blind proxy notifications
-- ============================================================================
-- Names and argument shapes (SET_CAN_STOP, SET_HAS_LEVEL, STOPPED with LEVEL, sent with "NOTIFY", true) come
-- from the open-source Control4-HA-Blinds driver, which works with this proxy.
local function sendNotify(name, params)
  print("SwitchBot " .. stamp() .. ": SendToProxy " .. name .. " " .. paramsText(params))
  pcall(function() C4:SendToProxy(PROXY_BINDING, name, params, "NOTIFY", true) end)
end

local function sendProxySetup()
  sendNotify("SET_CAN_STOP", { CAN_STOP = true })
  sendNotify("SET_HAS_LEVEL", {
    HAS_LEVEL = true,
    LEVEL_OPEN = 100,
    LEVEL_CLOSED = 0,
    LEVEL_SECONDARY_CLOSED = "",
    LEVEL_UNKNOWN = -1,
    LEVEL_DISCRETE_CONTROL = true,
    HAS_LEVEL_SECONDARY_CLOSED = false,
  })
end

local function sendLevelToProxy(level)
  if not state.proxySetup then
    state.proxySetup = true
    sendProxySetup()
  end
  sendNotify("STOPPED", { LEVEL = level })
end

local function scheduleFollowUp(ms)
  if state.followTimer then pcall(function() state.followTimer:Cancel() end) end
  local ok, timer = pcall(function()
    return C4:SetTimer(ms, function()
      state.followTimer = nil
      requestPoll()
    end)
  end)
  if ok then state.followTimer = timer end
end

-- ============================================================================
-- Status from the parent
-- ============================================================================
local function handleStatus(body)
  if type(body.slidePosition) == "number" then
    local level = clamp(positionToLevel(body.slidePosition), 0, 100)
    local moving = body.moving == true
    local target = state.targetLevel
    local holding = target ~= nil and os.time() < state.holdUntil
    local waiting = moving or (holding and math.abs(level - target) > LEVEL_TOLERANCE)
    if waiting and state.followCount < MAX_FOLLOWUPS then
      -- Mid-move or stale cloud status: do not overwrite the expected level; check again soon.
      state.followCount = state.followCount + 1
      print("SwitchBot " .. stamp() .. ": status level=" .. tostring(level) .. " moving="
        .. tostring(moving) .. " target=" .. tostring(target) .. ", checking again")
      scheduleFollowUp(FOLLOWUP_MS)
    else
      state.targetLevel = nil
      state.followCount = 0
      state.lastLevel = level
      sendLevelToProxy(level)
    end
  end
  if type(body.battery) == "number" then
    setProp("Battery", body.battery)
    local threshold = tonumber(prop("Low Battery Threshold")) or 20
    if body.battery < threshold then
      pcall(function() C4:FireEventByID(1) end)
    end
  end
end

-- Combine the status of one or two motors into one window: moving if either moves,
-- position is the average, battery is the lowest.
local function combineStatus(list)
  local out, posSum, posN = {}, 0, 0
  for _, b in ipairs(list) do
    if type(b.slidePosition) == "number" then posSum = posSum + b.slidePosition; posN = posN + 1 end
    if b.moving == true then out.moving = true end
    if type(b.battery) == "number" and (out.battery == nil or b.battery < out.battery) then
      out.battery = b.battery
    end
  end
  if posN > 0 then out.slidePosition = posSum / posN end
  return out
end


local function onStatus(p)
  if (prop("Status") or ""):sub(1, 7) == "Waiting" then setStatus("Online") end
  local id = tostring(p.DEVICE_ID or "")
  state.dev[id] = {
    slidePosition = tonumber(p.POSITION),
    moving = p.MOVING == "true",
    battery = tonumber(p.BATTERY),
  }
  local list = {}
  for _, did in ipairs(deviceIds()) do
    if state.dev[did] then list[#list + 1] = state.dev[did] end
  end
  if #list == 0 then return end
  handleStatus(#list == 1 and list[1] or combineStatus(list))
end

local function sendCommand(command, parameter)
  local ids = deviceIds()
  if #ids == 0 then
    setStatus("Set Device ID")
    return
  end
  if sendToParent("SB_COMMAND", { IDS = table.concat(ids, ","), COMMAND = command, PARAMETER = parameter or "default" }) then
    scheduleFollowUp(FOLLOWUP_FIRST_MS)
  end
end

local function modeParam()
  local m = prop("Mode") or "ff"
  if m ~= "ff" and m ~= "0" and m ~= "1" then m = "ff" end
  return m
end

-- Debounced command: shows the expected level at once, then sends only the latest press.
local function queueCommand(command, parameter, targetLevel)
  if state.cmdTimer then pcall(function() state.cmdTimer:Cancel() end) end
  state.pending = { command = command, parameter = parameter }
  state.followCount = 0
  if targetLevel ~= nil then
    state.targetLevel = targetLevel
    state.holdUntil = os.time() + HOLD_SECONDS
    state.lastLevel = targetLevel
    -- Shows the expected level in Navigator at once (stand-in until the moving notifications are known).
    sendLevelToProxy(targetLevel)
  else
    state.targetLevel = nil
  end
  local ok, timer = pcall(function()
    return C4:SetTimer(COMMAND_DEBOUNCE_MS, function()
      state.cmdTimer = nil
      local p = state.pending
      state.pending = nil
      if p then sendCommand(p.command, p.parameter) end
    end)
  end)
  if ok then
    state.cmdTimer = timer
  else
    local p = state.pending
    state.pending = nil
    sendCommand(p.command, p.parameter)
  end
end

local function setLevel(level)
  level = clamp(math.floor(tonumber(level) or 0), 0, 100)
  local pos = levelToPosition(level)
  queueCommand("setPosition", "0," .. modeParam() .. "," .. tostring(pos), level)
end


-- ============================================================================
-- Control4 entry points
-- ============================================================================
function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  setStatus("Starting")
end

function OnDriverLateInit()
  state.proxySetup = false
  sendProxySetup()
  pcall(function() C4:SetTimer(5000, function() sendProxySetup() end) end)
  -- Give the parent a moment to start, then tell it which devices to poll.
  pcall(function() C4:SetTimer(3000, function() register() end) end)
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  if idBinding == CLOUD_BINDING and bIsBound then register() end
end

function OnPropertyChanged(strProperty)
  if strProperty == "Device ID" or strProperty == "Second Device ID" then
    state.dev = {}
    register()
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  -- Composer dispatches <actions> as ExecuteCommand("LUA_ACTION", {ACTION = <command>}).
  if strCommand == "LUA_ACTION" then
    strCommand = tParams.ACTION
    if strCommand == nil then
      print("SwitchBot: LUA_ACTION with no ACTION parameter, ignoring")
      return
    end
  end
  if strCommand == "SB_STATUS" then
    onStatus(tParams)
    return
  elseif strCommand == "SB_PARENT_STATUS" then
    setStatus(tostring(tParams.TEXT or ""))
    return
  elseif strCommand == "SB_HELLO" then
    register()
    return
  end
  print("SwitchBot " .. stamp() .. ": ExecuteCommand " .. tostring(strCommand))
  if strCommand == "ACTION_OPEN" then strCommand = "Open"
  elseif strCommand == "ACTION_CLOSE" then strCommand = "Close"
  elseif strCommand == "ACTION_REFRESH" then
    requestPoll()
    return
  end
  if strCommand == "Open" or strCommand == "OPEN" then
    queueCommand("turnOn", "default", 100)
  elseif strCommand == "Close" or strCommand == "CLOSE" then
    queueCommand("turnOff", "default", 0)
  elseif strCommand == "Stop" or strCommand == "STOP" then
    queueCommand("pause", "default", nil)
  elseif strCommand == "Set Position" or strCommand == "SET_POSITION" then
    setLevel(tParams.LEVEL or tParams.Level or tParams.level)
  end
end

-- Proxy (shade) commands from Composer, UI and programming.
function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  print("SwitchBot " .. stamp() .. ": ReceivedFromProxy binding=" .. tostring(idBinding)
    .. " command=" .. tostring(strCommand) .. " params=" .. paramsText(tParams))
  -- Confirmed from a live log (2026-11-04): the Navigator open/close buttons send UP and DOWN.
  -- UP = open and DOWN = close is the assumed mapping (confirm by watching the curtain).
  if strCommand == "OPEN" or strCommand == "UP" then
    queueCommand("turnOn", "default", 100)
  elseif strCommand == "CLOSE" or strCommand == "DOWN" then
    queueCommand("turnOff", "default", 0)
  elseif strCommand == "STOP" then
    queueCommand("pause", "default", nil)
  elseif strCommand == "SET_LEVEL_TARGET" then
    -- Blind proxy: LEVEL_TARGET carries 0-100, or an open/closed marker (unverified names).
    local t = tParams.LEVEL_TARGET
    if t == "LEVEL_TARGET_OPEN" then
      queueCommand("turnOn", "default", 100)
    elseif t == "LEVEL_TARGET_CLOSED" then
      queueCommand("turnOff", "default", 0)
    else
      setLevel(t)
    end
  elseif strCommand == "TOGGLE" then
    if (state.lastLevel or 0) > 0 then
      queueCommand("turnOff", "default", 0)
    else
      queueCommand("turnOn", "default", 100)
    end
  elseif strCommand == "SET_LEVEL" then
    setLevel(tParams.LEVEL)
  end
end
