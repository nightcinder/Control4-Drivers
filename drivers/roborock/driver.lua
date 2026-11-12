--[[
  Roborock Vacuum via LAN HTTP bridge (Control4 DriverWorks, OS 3.4.x)
  Version: 0.1.0  (UNTESTED on real Composer/Director; see docs/roborock.md)

  Bridge endpoints (plain HTTP on the LAN):
    GET  /state    -> {"state":"charging","battery":100,"error":"none","rooms":[],"last_error":null,...}
    POST /command  -> {"action":"start|stop|pause|dock|clean_rooms","rooms":[ids]}
  Polls /state every Poll Interval seconds (minimum 30).
  The state fields are read with simple key patterns (the bridge sends flat scalar fields).
]]

local DRIVER_VERSION = "0.1.0"
local DEFAULT_HOST = "172.21.1.157"
local DEFAULT_PORT = "8788"
local DEFAULT_POLL = 60
local MIN_POLL = 30
local RETRY_SECONDS = 30
local COMMAND_RECHECK_SECONDS = 3
local HTTP_TIMEOUT_SECONDS = 15

local EVENT_CLEANING_STARTED = 1
local EVENT_CLEANING_FINISHED = 2
local EVENT_ERROR_RAISED = 3
local EVENT_BATTERY_LOW = 4
local EVENT_BRIDGE_UNREACHABLE = 5

local VAR_STATE = "VACUUM_STATE"
local VAR_BATTERY = "VACUUM_BATTERY"
local VAR_ERROR = "VACUUM_ERROR"

local state = {
  pollTimer = nil,
  busy = false,         -- an HTTP request is in flight
  lastState = "",       -- last bridge state seen
  lastError = "none",   -- last error code seen (edge detection for Error Raised)
  lowFired = false,     -- Battery Low already fired; re-arms when battery rises above threshold
  unreachable = false,  -- Bridge Unreachable already fired for this outage
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

local function fire(id)
  pcall(function() C4:FireEvent(id) end)
end

local function logmsg(msg)
  local mode = prop("Log Mode")
  local line = "[Roborock] " .. tostring(msg)
  if mode == "Print" or mode == "Print and Log" then
    pcall(function() print(line) end)
  end
  if mode == "Log" or mode == "Print and Log" then
    pcall(function() C4:ErrorLog(line) end)
  end
end

local function bridgeBase()
  local host = prop("Bridge Host")
  if host == "" then host = DEFAULT_HOST end
  local port = prop("Bridge Port")
  if port == "" then port = DEFAULT_PORT end
  return "http://" .. host .. ":" .. port
end

local function pollSeconds()
  local n = tonumber(prop("Poll Interval")) or DEFAULT_POLL
  if n < MIN_POLL then n = MIN_POLL end
  return n
end

local function lowThreshold()
  return tonumber(prop("Low Battery Threshold")) or 20
end

local function jsonEscape(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- Field readers for the flat bridge JSON. "error" is matched with its quotes so it
-- does not match "last_error".
local function strField(body, key)
  return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function numField(body, key)
  return tonumber(body:match('"' .. key .. '"%s*:%s*(%-?[%d%.]+)'))
end

local function isCleaning(s)
  return s == "cleaning" or s == "zoned_cleaning" or s == "segment_cleaning" or s == "spot_cleaning"
end

local function isDocked(s)
  return s == "docked" or s == "charging"
end

-- ============================================================================
-- HTTP
-- ============================================================================
-- cb(ok, body, httpCode, errText)
local function httpRequest(method, path, body, cb)
  local url = bridgeBase() .. path
  local headers = { ["Accept"] = "application/json" }

  local function onReply(_, data, code, _, err)
    code = tonumber(code) or 0
    local ok = (code >= 200 and code < 300)
    cb(ok, data, code, err)
  end

  pcall(function() C4:urlSetTimeout(HTTP_TIMEOUT_SECONDS) end)

  local ok, perr = pcall(function()
    if method == "POST" then
      headers["Content-Type"] = "application/json"
      C4:urlPost(url, body or "", headers, false, onReply)
    else
      C4:urlGet(url, headers, false, onReply)
    end
  end)
  if not ok then
    cb(false, nil, 0, tostring(perr))
  end
end

-- ============================================================================
-- Status and events
-- ============================================================================
local function setUnreachable(reason)
  setProp("Status", "Bridge unreachable")
  setProp("Last Error", reason or "unreachable")
  if not state.unreachable then
    state.unreachable = true
    fire(EVENT_BRIDGE_UNREACHABLE)
  end
end

local function applyState(body)
  local st = strField(body, "state") or ""
  local battery = numField(body, "battery")
  local err = strField(body, "error") or "none"
  local lastErr = strField(body, "last_error")

  setProp("State", st)
  setVar(VAR_STATE, st)

  if battery then
    setProp("Battery", tostring(battery) .. "%")
    setVar(VAR_BATTERY, battery)
  end

  setVar(VAR_ERROR, err)
  setProp("Last Error", lastErr or err)

  -- Cleaning Started / Finished on state transitions
  if isCleaning(st) and not isCleaning(state.lastState) then
    fire(EVENT_CLEANING_STARTED)
    logmsg("cleaning started")
  end
  if isCleaning(state.lastState) and isDocked(st) then
    fire(EVENT_CLEANING_FINISHED)
    logmsg("cleaning finished")
  end
  state.lastState = st

  -- Error Raised on a new error code
  local hasErr = (err ~= "" and err ~= "none")
  if hasErr and err ~= state.lastError then
    fire(EVENT_ERROR_RAISED)
    logmsg("error raised: " .. err)
  end
  state.lastError = hasErr and err or "none"

  -- Battery Low, once until battery recovers above threshold
  if battery then
    local th = lowThreshold()
    if battery <= th then
      if not state.lowFired then
        state.lowFired = true
        fire(EVENT_BATTERY_LOW)
        logmsg("battery low: " .. tostring(battery))
      end
    else
      state.lowFired = false
    end
  end
end

-- ============================================================================
-- Polling
-- ============================================================================
local poll

local function schedule(seconds)
  if state.pollTimer then
    pcall(function() state.pollTimer:Cancel() end)
    state.pollTimer = nil
  end
  state.pollTimer = C4:SetTimer(math.floor(seconds * 1000), function()
    state.pollTimer = nil
    poll()
  end)
end

function poll()
  if state.busy then
    schedule(COMMAND_RECHECK_SECONDS)
    return
  end
  state.busy = true
  httpRequest("GET", "/state", nil, function(ok, data, code, err)
    state.busy = false
    if ok and data and data ~= "" then
      state.unreachable = false
      applyState(data)
      setProp("Status", "Connected")
      schedule(pollSeconds())
    else
      local reason = err
      if reason == nil or reason == "" then reason = "HTTP " .. tostring(code) end
      logmsg("poll failed: " .. tostring(reason))
      setUnreachable(reason)
      schedule(RETRY_SECONDS)
    end
  end)
end

-- ============================================================================
-- Commands
-- ============================================================================
local function parseRooms(s)
  local out = {}
  for tok in string.gmatch(s or "", "[^,%s]+") do
    if tonumber(tok) then
      out[#out + 1] = tok
    else
      out[#out + 1] = '"' .. jsonEscape(tok) .. '"'
    end
  end
  return out
end

local function sendCommand(action, rooms)
  local body = '{"action":"' .. action .. '"'
  if rooms and #rooms > 0 then
    body = body .. ',"rooms":[' .. table.concat(rooms, ",") .. "]"
  end
  body = body .. "}"

  state.busy = true
  httpRequest("POST", "/command", body, function(ok, data, code, err)
    state.busy = false
    if ok then
      state.unreachable = false
      logmsg("command " .. action .. " accepted")
      setProp("Status", "Command sent: " .. action)
    else
      local reason = err
      if reason == nil or reason == "" then reason = "HTTP " .. tostring(code) end
      logmsg("command " .. action .. " failed: " .. tostring(reason))
      setUnreachable(reason)
    end
    -- Re-read state shortly after a command
    schedule(COMMAND_RECHECK_SECONDS)
  end)
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "START" then
    sendCommand("start")
  elseif strCommand == "STOP" then
    sendCommand("stop")
  elseif strCommand == "PAUSE" then
    sendCommand("pause")
  elseif strCommand == "DOCK" then
    sendCommand("dock")
  elseif strCommand == "CLEAN_ROOMS" then
    local rooms = parseRooms(tParams["Rooms"] or "")
    if #rooms == 0 then
      logmsg("Clean Rooms called with no room ids")
      return
    end
    sendCommand("clean_rooms", rooms)
  elseif strCommand == "REFRESH" then
    schedule(1)
  end
end

-- ============================================================================
-- Driver lifecycle
-- ============================================================================
local function ensureVariables()
  local defs = {
    { VAR_STATE, "STRING" },
    { VAR_BATTERY, "NUMBER" },
    { VAR_ERROR, "STRING" },
  }
  for _, d in ipairs(defs) do
    pcall(function() C4:AddVariable(d[1], "", d[2], true, false) end)
  end
end

function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  ensureVariables()
  setProp("Status", "Starting")
end

function OnDriverLateInit()
  schedule(1)
end

function OnDriverDestroyed()
  if state.pollTimer then
    pcall(function() state.pollTimer:Cancel() end)
    state.pollTimer = nil
  end
end

function OnPropertyChanged(name)
  if name == "Bridge Host" or name == "Bridge Port" or name == "Poll Interval" then
    state.unreachable = false
    schedule(1)
  elseif name == "Low Battery Threshold" then
    state.lowFired = false
    schedule(1)
  end
end
