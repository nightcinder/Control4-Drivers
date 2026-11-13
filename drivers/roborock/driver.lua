--[[
  Roborock Vacuum via LAN HTTP bridge (Control4 DriverWorks, OS 3.4.x)
  Version: 0.6.1  (UNTESTED on real Composer/Director; see docs/roborock.md)
  v0.5.1 moves events to devicedata level so Composer lists them (driver.xml only; no Lua logic change).
  v0.5.0 adds Active Room / Room Progress properties (ACTIVE_ROOM, ROOM_PROGRESS variables). Laundry
  Room Entered / Left use the bridge's current_room while it is known; v0.4.0 run-target rule is the fallback.
  v0.4.0 adds Laundry Room Entered / Laundry Room Left events (driver-side fallback, see below).
  v0.2.0 adds a uibutton proxy (binding 5001) and the Navigator web view www/vacuum2.html (renamed in v0.5.0).
  v0.3.0 exposes the map's rooms in the UI_STATE snapshot and adds UI_CLEAN_ROOMS_<ids>.
  The page reads the UI_STATE snapshot and sends UI_* commands through ExecuteCommand.

  Bridge endpoints (plain HTTP on the LAN):
    GET  /state    -> {"state":"charging","battery":100,"error":"none","rooms":[{"id":16,"name":"Study"}],"last_error":null,...}
    POST /command  -> {"action":"start|stop|pause|dock|clean_rooms","rooms":[ids]}
  Polls /state every Poll Interval seconds (minimum 30).
  The state fields are read with simple key patterns (the bridge sends flat scalar fields).
]]

local DRIVER_VERSION = "0.6.1"
local PROXY_BINDING = 5001          -- uibutton proxy (tile, icon and web view)
local UI_BUILD = "3"                -- must match PAGE_BUILD in www/vacuum2.html
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
local EVENT_LAUNDRY_ENTERED = 6
local EVENT_LAUNDRY_LEFT = 7
local EVENT_LAUNDRY_CLEAN_STARTED = 8   -- v0.6.0: a clean job that includes the Laundry Room ID starts
local EVENT_LAUNDRY_CLEAN_FINISHED = 9  -- v0.6.0: that clean job ends (docked or charging or idle)

local VAR_STATE = "VACUUM_STATE"
local VAR_BATTERY = "VACUUM_BATTERY"
local VAR_ERROR = "VACUUM_ERROR"
local VAR_UI = "UI_STATE"           -- JSON snapshot read by the web view page
local VAR_ROOM = "ACTIVE_ROOM"      -- v0.5.0: name of the room under the robot (string)
local VAR_ROOM_PROGRESS = "ROOM_PROGRESS" -- v0.5.0: 0-100 (0 when the bridge reports null)

local state = {
  pollTimer = nil,
  busy = false,         -- an HTTP request is in flight
  lastState = "",       -- last bridge state seen
  lastError = "none",   -- last error code seen (edge detection for Error Raised)
  lowFired = false,     -- Battery Low already fired; re-arms when battery rises above threshold
  unreachable = false,  -- Bridge Unreachable already fired for this outage
  runRooms = nil,      -- room ids of the last clean_rooms command (list of strings), nil otherwise
  laundryActive = false, -- Laundry Room Entered fired for the current run, Left not yet fired
  laundryJob = false,    -- v0.6.0: Laundry Room Clean Started fired for the current run, Finished not yet
  -- web view and tile icon snapshot (v0.2.0)
  uiSeq = 0,
  online = false,
  st = "",
  battery = nil,
  err = "none",
  lastErr = "",
  icon = nil,
  roomsJson = "[]",     -- v0.3.0: [{"id":16,"name":"Study"}, ...] as JSON text
  curRoomId = nil,      -- v0.5.0: current_room.id from the bridge, nil when null
  activeRoom = "",      -- v0.5.0: current_room name ("" when unknown)
  roomProgress = nil,   -- v0.5.0: room_progress_pct from the bridge, nil when null
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

-- v0.6.0: true when a clean_rooms run list contains the Laundry Room ID.
local function targetsLaundry(rooms)
  local laundry = tonumber(prop("Laundry Room ID"))
  if not laundry or laundry <= 0 or not rooms then return false end
  for _, r in ipairs(rooms) do
    if tonumber(r) == laundry then return true end
  end
  return false
end

-- v0.6.0: room name for a numeric id from the last UI room list ("Room <id>" if unknown).
local function roomNameFor(id)
  local n = tonumber(id)
  if not n then return tostring(id) end
  local name = state.roomsJson:match('"id"%s*:%s*' .. n .. '%s*,%s*"name"%s*:%s*"([^"]*)"')
  return name or ("Room " .. n)
end

-- v0.6.0: text for the Room field. Docked wins for docked or charging. While a room job runs,
-- the target shows, because the bridge's current room is often unknown during the trip.
local function displayRoom(st)
  if isDocked(st) then return "Docked" end
  local running = isCleaning(st) or st == "paused" or st == "returning"
  if running and state.runRooms and #state.runRooms > 0 then
    local names = {}
    for _, id in ipairs(state.runRooms) do names[#names + 1] = roomNameFor(id) end
    local target = table.concat(names, ", ")
    if state.activeRoom ~= "" and state.activeRoom ~= target then
      return state.activeRoom .. " (to " .. target .. ")"
    end
    if state.activeRoom == "" then return target .. " (target)" end
    return target
  end
  return state.activeRoom ~= "" and state.activeRoom or "Unknown"
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
-- Web view (v0.2.0): UI_STATE snapshot and tile icon
local UI_COMMAND_ACTIONS = { UI_START = "start", UI_STOP = "stop", UI_PAUSE = "pause", UI_DOCK = "dock" }

local function publishUi()
  state.uiSeq = state.uiSeq + 1
  local batt = "null"
  if state.battery then batt = tostring(state.battery) end
  local progress = "null"
  if state.roomProgress then progress = string.format("%.0f", state.roomProgress) end
  local json = string.format(
    '{"t":"rbrock","seq":%d,"build":"%s","version":"%s","online":%s,"state":"%s","battery":%s,"error":"%s","lastError":"%s","activeRoom":"%s","roomProgress":%s,"rooms":%s}',
    state.uiSeq, UI_BUILD, DRIVER_VERSION, state.online and "true" or "false",
    jsonEscape(state.st or ""), batt, jsonEscape(state.err or "none"), jsonEscape(state.lastErr or ""),
    jsonEscape(displayRoom(state.st or "")), progress, state.roomsJson)
  setVar(VAR_UI, json)
  pcall(C4.SendDataToUI, C4, json)
end

-- Icon ids must match the <state id="..."> entries in driver.xml.
local function updateIcon()
  local id = "Default"
  if state.online and state.err ~= "" and state.err ~= "none" then
    id = "Error"
  elseif isCleaning(state.st) then
    id = "Cleaning"
  elseif isDocked(state.st) then
    id = "Docked"
  end
  if id ~= state.icon then
    state.icon = id
    pcall(function()
      C4:SendToProxy(PROXY_BINDING, "ICON_CHANGED", { icon = id, icon_description = id }, "NOTIFY")
    end)
  end
end

local function setUnreachable(reason)
  state.online = false
  publishUi()
  updateIcon()
  setProp("Status", "Bridge unreachable")
  setProp("Last Error", reason or "unreachable")
  if not state.unreachable then
    state.unreachable = true
    fire(EVENT_BRIDGE_UNREACHABLE)
  end
end

local isLaundryOnlyRun -- defined below; forward-declared so applyState can call it

local function applyState(body)
  local st = strField(body, "state") or ""
  local battery = numField(body, "battery")
  local err = strField(body, "error") or "none"
  local lastErr = strField(body, "last_error")

  -- v0.5.0: current_room is {"id":N,"name":"..."} or null (from the bridge's parsed map).
  -- The block is matched on its own so the room name is not confused with a room list name.
  local crBlock = body:match('"current_room"%s*:%s*(%b{})')
  local curId = crBlock and tonumber(crBlock:match('"id"%s*:%s*(%d+)')) or nil
  local curName = ""
  if curId then curName = strField(crBlock, "name") or ("Room " .. tostring(curId)) end
  state.curRoomId = curId
  state.activeRoom = curName
  state.roomProgress = numField(body, "room_progress_pct")

  -- v0.3.0: rooms arrive as an array of {"id":N,"name":"..."} objects. The names are
  -- already JSON-escaped by the bridge, so they are copied through as they are.
  local parts = {}
  local roomsBlock = body:match('"rooms"%s*:%s*(%b[])')
  if roomsBlock then
    for id, name in roomsBlock:gmatch('"id"%s*:%s*(%d+)%s*,%s*"name"%s*:%s*"([^"]*)"') do
      parts[#parts + 1] = '{"id":' .. id .. ',"name":"' .. name .. '"}'
    end
  end
  state.roomsJson = "[" .. table.concat(parts, ",") .. "]"

  setProp("State", st)
  setVar(VAR_STATE, st)

  if battery then
    setProp("Battery", tostring(battery) .. "%")
    setVar(VAR_BATTERY, battery)
  end

  setVar(VAR_ERROR, err)
  setProp("Last Error", lastErr or err)

  -- v0.5.0 room properties and variables
  setProp("Active Room", displayRoom(st))
  setVar(VAR_ROOM, state.activeRoom)
  if state.roomProgress then
    setProp("Room Progress", string.format("%.0f%%", state.roomProgress))
  else
    setProp("Room Progress", "n/a")
  end
  setVar(VAR_ROOM_PROGRESS, state.roomProgress or 0)

  -- Cleaning Started / Finished on state transitions
  if isCleaning(st) and not isCleaning(state.lastState) then
    fire(EVENT_CLEANING_STARTED)
    logmsg("cleaning started")
  end
  if isCleaning(state.lastState) and isDocked(st) then
    fire(EVENT_CLEANING_FINISHED)
    logmsg("cleaning finished")
  end

  -- v0.5.0 laundry events. While cleaning, the bridge's current_room decides: Entered when it
  -- is the Laundry Room ID, Left when it changes to another room. When current_room is null,
  -- the v0.4.0 run-target rule applies (Entered on cleaning start for a laundry-only run).
  local laundryId = tonumber(prop("Laundry Room ID"))
  local cleaningNow = isCleaning(st)
  if cleaningNow and state.curRoomId and laundryId and laundryId > 0 then
    local inLaundry = (state.curRoomId == laundryId)
    if inLaundry and not state.laundryActive then
      state.laundryActive = true
      fire(EVENT_LAUNDRY_ENTERED)
      logmsg("laundry room entered (current room)")
    elseif not inLaundry and state.laundryActive then
      state.laundryActive = false
      fire(EVENT_LAUNDRY_LEFT)
      logmsg("laundry room left (current room)")
    end
  elseif cleaningNow and not isCleaning(state.lastState) then
    if isLaundryOnlyRun(state.runRooms) then
      state.laundryActive = true
      fire(EVENT_LAUNDRY_ENTERED)
      logmsg("laundry room entered (run target)")
    end
  end
  -- v0.6.0 laundry clean job events. These do not depend on the bridge's current room, so they
  -- fire while the robot is still travelling to the Laundry Room ID.
  if cleaningNow and not isCleaning(state.lastState) and targetsLaundry(state.runRooms) then
    state.laundryJob = true
    fire(EVENT_LAUNDRY_CLEAN_STARTED)
    logmsg("laundry clean job started")
  end
  -- Run ended (docked, charging or idle), not on pause or returning
  if isCleaning(state.lastState) and not cleaningNow
      and st ~= "paused" and st ~= "returning" then
    if state.laundryJob then
      state.laundryJob = false
      fire(EVENT_LAUNDRY_CLEAN_FINISHED)
      logmsg("laundry clean job finished")
    end
    state.runRooms = nil
    if state.laundryActive then
      state.laundryActive = false
      fire(EVENT_LAUNDRY_LEFT)
      logmsg("laundry room left")
    end
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

  -- v0.2.0: web view snapshot and tile icon
  state.st, state.err, state.lastErr = st, err, (lastErr or "")
  if battery then state.battery = battery end
  state.online = true
  publishUi()
  updateIcon()
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

-- True when a clean_rooms run targets only the Laundry Room ID (v0.4.0 fallback).
function isLaundryOnlyRun(rooms)
  local laundry = tonumber(prop("Laundry Room ID"))
  if not laundry or laundry <= 0 or not rooms or #rooms ~= 1 then
    return false
  end
  return tonumber(rooms[1]) == laundry
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
      state.runRooms = (action == "clean_rooms") and rooms or nil
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

local function handleUi(cmd)
  local action = UI_COMMAND_ACTIONS[cmd]
  if action then
    logmsg("web view: " .. action)
    sendCommand(action)
  elseif cmd:sub(1, 15) == "UI_CLEAN_ROOMS_" then
    -- Room ids are encoded as underscore-separated integers, e.g. UI_CLEAN_ROOMS_16_17
    local rooms = {}
    for id in cmd:sub(16):gmatch("%d+") do
      rooms[#rooms + 1] = id
    end
    if #rooms == 0 then
      logmsg("web view: clean rooms with no room ids")
      return
    end
    logmsg("web view: clean rooms " .. table.concat(rooms, ","))
    sendCommand("clean_rooms", rooms)
  elseif cmd == "UI_REFRESH" then
    publishUi()
    schedule(1)
  elseif cmd:sub(1, 9) == "UI_HELLO_" then
    local b = cmd:sub(10)
    if b == UI_BUILD then
      setProp("Web Page Status", "Page build " .. b .. " OK")
    else
      setProp("Web Page Status", "PAGE IS STALE: page " .. b .. ", driver expects " .. UI_BUILD)
    end
    publishUi()
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if tostring(strCommand):sub(1, 3) == "UI_" then
    handleUi(tostring(strCommand))
    return
  end
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
    { VAR_UI, "STRING" },
    { VAR_ROOM, "STRING" },
    { VAR_ROOM_PROGRESS, "NUMBER" },
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
