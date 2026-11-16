--[[
  Shield Remote (Control4 DriverWorks, OS 3.4.x)
  Version: 0.1.0
  Navigator web view (www/remote1.html) for the Shield TV bridge driver (shield-tv-bridge).
  Keys go to the Shield TV driver with SHIELD_REMOTE_KEY. Volume and mute go to the room
  with PULSE_VOL_UP / PULSE_VOL_DOWN / MUTE_TOGGLE. Now Playing comes from the REMOTE_STATE
  variable on the Shield TV driver.

  The page reads the UI_STATE snapshot and sends UI_* commands through ExecuteCommand.
  Opening the page never sends a key.
]]

local DRIVER_VERSION = "0.1.0"
local PAGE_FILE = "remote1.html"   -- web_view_url in driver.xml; renamed every page release
local PAGE_BUILD = 1               -- must match PAGE_BUILD in www/remote1.html
local PROXY = 5001                 -- uibutton proxy (tile and web view)
local REMOTE_VAR = "REMOTE_STATE"  -- visible variable on the Shield TV driver (JSON)
local RETRY_SECONDS = 30

local ALLOWED_KEYS = {
  DPAD_UP = true, DPAD_DOWN = true, DPAD_LEFT = true, DPAD_RIGHT = true, DPAD_CENTER = true,
  BACK = true, HOME = true, MENU = true,
  MEDIA_PLAY_PAUSE = true, MEDIA_NEXT = true, MEDIA_PREVIOUS = true,
  MEDIA_REWIND = true, MEDIA_FAST_FORWARD = true,
}

local ROOM_COMMANDS = {
  UI_VOL_UP = "PULSE_VOL_UP",
  UI_VOL_DOWN = "PULSE_VOL_DOWN",
  UI_MUTE = "MUTE_TOGGLE",
}

local state = {
  uiSeq = 0,
  varId = nil,         -- id of REMOTE_STATE on the Shield TV driver, nil when not listening
  listenDevice = nil,  -- device id the listener is registered on
  np = "",             -- last REMOTE_STATE JSON text
  retryTimer = nil,
}

-- ============================================================================
-- Small helpers
-- ============================================================================
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function prop(name)
  local v = nil
  pcall(function() v = Properties[name] end)
  return trim(v)
end

local function setProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value or "")) end)
end

local function setVar(name, value)
  pcall(function() C4:SetVariable(name, tostring(value or "")) end)
end

local function logmsg(msg)
  if prop("Log Mode") == "Print" then
    pcall(function() print("[ShieldRemote] " .. tostring(msg)) end)
  end
end

-- The Shield TV list is filled from the Shield TV Bridge devices in the project
-- (GetDevicesByC4iName). Each entry ends in "(id N)". "Shield TV Device ID" overrides it.
local NONE_FOUND = "(no Shield TV Bridge found)"

local function findShieldDevices()
  local ids, seen = {}, {}
  for _, name in ipairs({ "shield-tv-bridge.c4z", "shield-tv-bridge.c4i" }) do
    local ok, devs = pcall(function() return C4:GetDevicesByC4iName(name) end)
    if ok and type(devs) == "table" then
      for k, v in pairs(devs) do
        local id = tonumber(k) or tonumber(v)
        if id and not seen[id] then
          seen[id] = true
          ids[#ids + 1] = id
        end
      end
    end
  end
  table.sort(ids)
  return ids
end

local function refreshShieldList()
  local labels = {}
  for _, id in ipairs(findShieldDevices()) do
    local name = "Shield TV"
    pcall(function()
      local n = C4:GetDeviceDisplayName(id)
      if type(n) == "string" and trim(n) ~= "" then name = trim(n) end
    end)
    labels[#labels + 1] = (name:gsub(",", " ")) .. " (id " .. id .. ")"
  end
  if #labels == 0 then labels[1] = NONE_FOUND end
  pcall(function() C4:UpdatePropertyList("Shield TV", table.concat(labels, ",")) end)
  logmsg("Shield TV list: " .. table.concat(labels, "; "))
end

local function shieldId()
  local override = tonumber(prop("Shield TV Device ID"))
  if override and override > 0 then return override end
  local id = tostring(prop("Shield TV")):match("%(id (%d+)%)%s*$")
  return tonumber(id)
end

local function roomId()
  local ok, r = pcall(function() return C4:RoomGetId() end)
  if ok then return tonumber(r) end
  return nil
end

-- ============================================================================
-- REMOTE_STATE listener
-- ============================================================================
local function cancelRetry()
  if state.retryTimer then
    pcall(function() state.retryTimer:Cancel() end)
    state.retryTimer = nil
  end
end

local function unlisten()
  if state.varId and state.listenDevice then
    pcall(function() C4:UnregisterVariableListener(state.listenDevice, state.varId) end)
  end
  state.varId = nil
  state.listenDevice = nil
  state.np = ""
end

-- Looks up REMOTE_STATE on the chosen Shield TV and listens to it. Returns true when found.
local function findRemoteState()
  unlisten()
  local sid = shieldId()
  if not sid then return false end
  local ok, vars = pcall(function() return C4:GetDeviceVariables(sid) end)
  if not ok or type(vars) ~= "table" then return false end
  for id, v in pairs(vars) do
    if type(v) == "table" and v.name == REMOTE_VAR then
      state.varId = id
      state.listenDevice = sid
      state.np = tostring(v.value or "")
      pcall(function() C4:RegisterVariableListener(sid, id) end)
      logmsg("listening to " .. REMOTE_VAR .. " on device " .. sid)
      return true
    end
  end
  logmsg(REMOTE_VAR .. " not found on device " .. sid .. " (Shield TV driver not updated?)")
  return false
end

-- ============================================================================
-- UI_STATE snapshot
-- ============================================================================
local function publish()
  state.uiSeq = state.uiSeq + 1
  local linked = (shieldId() ~= nil) and (state.varId ~= nil)
  local np = state.np or ""
  if not np:match("^%s*{") then np = "{}" end
  local json = string.format(
    '{"t":"shieldremote","seq":%d,"build":%d,"linked":%s,"np":%s}',
    state.uiSeq, PAGE_BUILD, linked and "true" or "false", np)
  pcall(function() C4:SetVariable("UI_STATE", json) end)
  pcall(function() C4:SendDataToUI(json) end)
end

-- Starts a repeating retry every RETRY_SECONDS until REMOTE_STATE is found.
local function startRetry()
  if state.retryTimer or not shieldId() then return end
  local ok, timer = pcall(function()
    return C4:SetTimer(RETRY_SECONDS * 1000, function()
      local ok2, found = pcall(findRemoteState)
      if ok2 and found then
        cancelRetry()
        publish()
      end
    end, true)
  end)
  if ok then state.retryTimer = timer end
end

-- Full lookup: used at late init and when the Shield TV property changes.
local function refreshLookup()
  cancelRetry()
  local found = findRemoteState()
  if not found then startRetry() end
  publish()
end

-- ============================================================================
-- Commands
-- ============================================================================
local function sendKey(key)
  local sid = shieldId()
  if not sid then
    logmsg("no Shield TV chosen; key " .. key .. " ignored")
    publish()
    return
  end
  local rid = roomId()
  pcall(function()
    C4:SendToDevice(sid, "SHIELD_REMOTE_KEY", { KEY = key, ROOMID = tostring(rid or "") })
  end)
end

local function sendRoomCommand(cmd)
  local rid = roomId()
  if not rid then
    logmsg("no room id for " .. cmd)
    return
  end
  pcall(function() C4:SendToDevice(rid, cmd, {}) end)
end

local function handleUi(cmd)
  if cmd:sub(1, 7) == "UI_KEY_" then
    local key = cmd:sub(8)
    if ALLOWED_KEYS[key] then
      sendKey(key)
    else
      logmsg("key not allowed: " .. key)
    end
  elseif ROOM_COMMANDS[cmd] then
    sendRoomCommand(ROOM_COMMANDS[cmd])
  elseif cmd == "UI_REFRESH" then
    local sid = shieldId()
    if sid then
      pcall(function() C4:SendToDevice(sid, "SHIELD_REMOTE_REFRESH", {}) end)
    end
    publish()
  elseif cmd:sub(1, 9) == "UI_HELLO_" then
    local b = cmd:sub(10)
    if tonumber(b) == PAGE_BUILD then
      setProp("Web Page Status", "Page build " .. b .. " OK")
    else
      setProp("Web Page Status", "PAGE IS STALE: page " .. b .. ", driver expects " .. PAGE_BUILD)
    end
    publish()
  else
    logmsg("unhandled UI command: " .. cmd)
  end
end

function ExecuteCommand(strCommand, tParams)
  pcall(function()
    tParams = tParams or {}
    local cmd = tostring(strCommand or "")
    if cmd == "LUA_ACTION" and tParams.ACTION then
      cmd = tostring(tParams.ACTION)
    end
    if cmd:sub(1, 3) == "UI_" then
      handleUi(cmd)
    else
      logmsg("unhandled command: " .. cmd)
    end
  end)
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  pcall(function()
    local cmd = tostring(strCommand or "")
    -- Only web view UI_* commands act. Anything else (SELECT, GET_CONNECTED_STATE) just republishes.
    if cmd:sub(1, 3) == "UI_" then
      ExecuteCommand(cmd, tParams)
    else
      publish()
    end
  end)
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  pcall(function()
    if tonumber(idVariable) == tonumber(state.varId) and tonumber(idDevice) == tonumber(state.listenDevice) then
      state.np = tostring(strValue or "")
      publish()
    end
  end)
end

-- ============================================================================
-- Driver lifecycle
-- ============================================================================
function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  pcall(function() C4:AddVariable("UI_STATE", "", "STRING", true, false) end)
end

function OnDriverLateInit()
  pcall(refreshShieldList)
  pcall(refreshLookup)
end

function OnDriverDestroyed()
  cancelRetry()
  unlisten()
end

function OnPropertyChanged(name)
  pcall(function()
    if name == "Shield TV" or name == "Shield TV Device ID" then
      refreshLookup()
    end
  end)
end
