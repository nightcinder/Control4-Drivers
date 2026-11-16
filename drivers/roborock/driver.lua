--[[
  Roborock Vacuum via LAN HTTP bridge (Control4 DriverWorks, OS 3.4.x)
  Version: 0.7.0  (logic tested in c4sim; the 0.7.0 features are UNTESTED on the vacuum; see docs/roborock.md)
  v0.7.0 per-run cleaning mode (Vacuum Only / Vacuum and Mop / Mop Only; needs bridge 0.2.3), Run Progress
  (the vacuum's own percent, or an estimate from cleaned area against the last same job), state names from
  python-roborock handled (returning_home, charging_complete, mopping states, dock service states), events
  10 Docked and 11 Error Cleared, commands Start Full Clean and Set Cleaning Mode, a Mode parameter and
  room names on Clean Rooms, error text and code variables. Cleaning Finished now fires when the robot is
  back on the dock after a job (it used to need a poll that went straight from cleaning to charging).
  Events are fired by NAME (C4:FireEvent takes the event name, not the id). VACUUM_ACTIVITY / Activity give
  one of cleaning, paused, returning, docked, idle, error, offline, other for Composer conditionals. Dock is
  skipped (no request, no error) when the robot is already on the dock. A recharge in the middle of a job
  (charging with in_cleaning above 0 and battery below 100) does not end the job.
  v0.6.3 accepts Composer command display names and LUA_ACTION in ExecuteCommand; ReceivedFromProxy added.
  v0.6.2 fires Laundry Room Clean Started as soon as the bridge accepts a clean_rooms command that includes
  the Laundry Room ID (no state edge needed, so a job sent while the robot is already cleaning fires). The
  poll-based start is a backup only. Adaptive polling: 5 s while cleaning or returning, otherwise the
  Poll Interval property (default 15, minimum 5).
  v0.5.1 moves events to devicedata level so Composer lists them (driver.xml only; no Lua logic change).
  v0.5.0 adds Active Room / Room Progress properties (ACTIVE_ROOM, ROOM_PROGRESS variables). Laundry
  Room Entered / Left use the bridge's current_room while it is known; v0.4.0 run-target rule is the fallback.
  v0.4.0 adds Laundry Room Entered / Laundry Room Left events (driver-side fallback, see below).
  v0.2.0 adds a uibutton proxy (binding 5001) and the Navigator web view www/vacuum2.html (renamed in v0.5.0).
  v0.3.0 exposes the map's rooms in the UI_STATE snapshot and adds UI_CLEAN_ROOMS_<ids>.
  The page reads the UI_STATE snapshot and sends UI_* commands through ExecuteCommand.

  Bridge endpoints (plain HTTP on the LAN):
    GET  /state    -> {"state":"charging","battery":100,"error":"none","rooms":[{"id":16,"name":"Study"}],"last_error":null,...}
    POST /command  -> {"action":"start|stop|pause|dock|clean_rooms|set_mode","rooms":[ids],"mode":"vacuum|vac_and_mop|mop"}
  Polls /state every Poll Interval seconds (minimum 5); every 5 s while cleaning or returning (v0.6.2).
  The state fields are read with simple key patterns (the bridge sends flat scalar fields).
]]

local DRIVER_VERSION = "0.7.0"
local PROXY_BINDING = 5001          -- uibutton proxy (tile, icon and web view)
local UI_BUILD = "4"                -- must match PAGE_BUILD in www/vacuum2.html
local DEFAULT_HOST = "172.21.1.157"
local DEFAULT_PORT = "8788"
local DEFAULT_POLL = 15
local MIN_POLL = 5
local FAST_POLL = 5             -- v0.6.2: while cleaning or returning
local RETRY_SECONDS = 30
local COMMAND_RECHECK_SECONDS = 3
local HTTP_TIMEOUT_SECONDS = 15
local PENDING_JOB_SECONDS = 180 -- v0.7.0: a command's job must be seen running within this time
local MIN_REFERENCE_AREA = 1    -- v0.7.0: m2; smaller jobs are not kept as a progress reference

local EVENT_CLEANING_STARTED = 1
local EVENT_CLEANING_FINISHED = 2
local EVENT_ERROR_RAISED = 3
local EVENT_BATTERY_LOW = 4
local EVENT_BRIDGE_UNREACHABLE = 5
local EVENT_LAUNDRY_ENTERED = 6
local EVENT_LAUNDRY_LEFT = 7
local EVENT_LAUNDRY_CLEAN_STARTED = 8   -- v0.6.0: a clean job that includes the Laundry Room ID starts
local EVENT_LAUNDRY_CLEAN_FINISHED = 9  -- v0.6.0: that clean job ends (docked or charging or idle)
local EVENT_DOCKED = 10                 -- v0.7.0: the robot arrives on the dock
local EVENT_ERROR_CLEARED = 11          -- v0.7.0: the vacuum error goes back to none

-- C4:FireEvent takes the event NAME from driver.xml. These must match the <event><name> entries exactly.
local EVENT_NAMES = {
  [EVENT_CLEANING_STARTED] = "Cleaning Started",
  [EVENT_CLEANING_FINISHED] = "Cleaning Finished",
  [EVENT_ERROR_RAISED] = "Error Raised",
  [EVENT_BATTERY_LOW] = "Battery Low",
  [EVENT_BRIDGE_UNREACHABLE] = "Bridge Unreachable",
  [EVENT_LAUNDRY_ENTERED] = "Laundry Room Entered",
  [EVENT_LAUNDRY_LEFT] = "Laundry Room Left",
  [EVENT_LAUNDRY_CLEAN_STARTED] = "Laundry Room Clean Started",
  [EVENT_LAUNDRY_CLEAN_FINISHED] = "Laundry Room Clean Finished",
  [EVENT_DOCKED] = "Docked",
  [EVENT_ERROR_CLEARED] = "Error Cleared",
}

local VAR_STATE = "VACUUM_STATE"
local VAR_BATTERY = "VACUUM_BATTERY"
local VAR_ERROR = "VACUUM_ERROR"
local VAR_UI = "UI_STATE"           -- JSON snapshot read by the web view page
local VAR_ROOM = "ACTIVE_ROOM"      -- v0.5.0: name of the room under the robot (string)
local VAR_ROOM_PROGRESS = "ROOM_PROGRESS" -- v0.5.0: 0-100 (0 when the bridge reports null)
local VAR_RUN_PROGRESS = "RUN_PROGRESS"   -- v0.7.0: 0-100 for the whole job (0 when unknown or no job)
local VAR_MODE = "CLEANING_MODE"          -- v0.7.0: vacuum, vac_and_mop, mop, custom, smart_mode or ""
local VAR_ERROR_TEXT = "VACUUM_ERROR_TEXT" -- v0.7.0: readable error, "None" when there is none
local VAR_ERROR_CODE = "VACUUM_ERROR_CODE" -- v0.7.0: Roborock error number, 0 when there is none
local VAR_IS_CLEANING = "IS_CLEANING"     -- v0.7.0: 1 while the state is a cleaning state
local VAR_IS_DOCKED = "IS_DOCKED"         -- v0.7.0: 1 while the robot is on the dock
local VAR_JOB_ACTIVE = "JOB_ACTIVE"       -- v0.7.0: 1 from cleaning start until docked or stopped (pause included)
local VAR_ACTIVITY = "VACUUM_ACTIVITY"    -- v0.7.0: cleaning, paused, returning, docked, idle, error, offline, other

-- State names are python-roborock's RoborockStateCode names in lower case. Spaces and hyphens are
-- turned into underscores before these tables are used.
local RETURNING_STATES = { returning = true, returning_home = true, docking = true,
  going_to_wash_the_mop = true, back_to_dock_washing_duster = true }
local DOCKED_STATES = { docked = true, charging = true, charging_complete = true, charging_problem = true,
  fully_charged = true, air_drying_stopping = true }
-- On the dock but busy. A job is not treated as finished in these states (the robot may go out again).
local DOCK_SERVICE_STATES = { emptying_the_bin = true, washing_the_mop = true, washing_the_mop_2 = true,
  attaching_the_mop = true, detaching_the_mop = true }

local MODE_LABELS = { vacuum = "Vacuum Only", vac_and_mop = "Vacuum and Mop", mop = "Mop Only",
  custom = "Custom (per room)", smart_mode = "Smart" }
local UI_MODES = { VACUUM = "vacuum", VACMOP = "vac_and_mop", MOP = "mop" }

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
  laundryJobAt = 0,      -- v0.7.0: os.time() when laundryJob was set by a command
  -- v0.7.0 job tracking
  runActive = false,    -- a job is in progress (cleaning seen, not yet docked or stopped)
  runAborted = false,   -- Stop or Dock was sent during the job (not used as a progress reference)
  runKey = nil,         -- "full", or sorted room ids such as "16,17"; nil when the job kind is unknown
  runMaxArea = 0,       -- largest clean_area_m2 seen in the job
  pendingKey = nil,     -- job kind of the last accepted start or clean_rooms command
  pendingKeyAt = 0,
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
  -- v0.7.0 fields from bridge 0.2.3 (nil or "" with an older bridge)
  devicePct = nil,      -- run_progress_pct: the vacuum's own clean percent
  area = nil,           -- clean_area_m2
  cleanTime = nil,      -- clean_time_s
  mode = "",            -- cleaning_mode
  waterMode = "",
  fanSpeed = "",
  bridgeVersion = "",
  restorePending = false,
  runPct = nil,         -- shown job percent
  runPctSource = "",    -- "device" or "estimate"
}

local propCache = {}
local varCache = {}

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

-- Composer only shows values written with C4:UpdateProperty. Unchanged values are not sent again.
local function setProp(name, value)
  local text = tostring(value or "")
  if propCache[name] == text then return end
  propCache[name] = text
  pcall(function() C4:UpdateProperty(name, text) end)
end

-- v0.7.0: what happened to the last command (sent, skipped, rejected), with the controller's clock time.
-- Status goes back to Connected on the next poll; this one stays.
local function setLastCommand(text)
  setProp("Last Command", os.date("%H:%M", os.time()) .. " " .. tostring(text))
end

local function setVar(name, value)
  local text = tostring(value or "")
  if varCache[name] == text then return end
  varCache[name] = text
  pcall(function() C4:SetVariable(name, text) end)
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

-- Events are fired by name: C4:FireEvent(name). A numeric id does not fire the event in Composer.
local function fire(id)
  local name = EVENT_NAMES[id] or tostring(id)
  local ok, err = pcall(function() C4:FireEvent(name) end)
  if not ok then
    logmsg("FireEvent(" .. name .. ") failed: " .. tostring(err))
  end
end

local function bridgeBase()
  local host = prop("Bridge Host")
  if host == "" then host = DEFAULT_HOST end
  local port = prop("Bridge Port")
  if port == "" then port = DEFAULT_PORT end
  return "http://" .. host .. ":" .. port
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

-- v0.7.0: lower case, spaces and hyphens to underscores ("Segment Cleaning" -> "segment_cleaning").
local function normState(s)
  return (trim(s):lower():gsub("[%s%-]+", "_"))
end

-- Any state with "clean" or "mopping" in its name: cleaning, segment_cleaning, zoned_cleaning,
-- spot_cleaning, segment_mopping, zoned_mopping, clean_mop_cleaning and the like.
local function isCleaning(s)
  s = normState(s)
  return s:find("clean", 1, true) ~= nil or s:find("mopping", 1, true) ~= nil
end

local function isReturning(s)
  return RETURNING_STATES[normState(s)] == true
end

-- Resting on the dock: docked, charging, charging_complete, charging_problem.
local function isDocked(s)
  return DOCKED_STATES[normState(s)] == true
end

-- On the dock, resting or busy (emptying the bin, washing the mop).
local function isAtDock(s)
  s = normState(s)
  return DOCKED_STATES[s] == true or DOCK_SERVICE_STATES[s] == true
end

-- v0.7.0: one word for Composer conditionals (VACUUM_ACTIVITY). Every python-roborock state name
-- lands in one of: error, cleaning, paused, returning, docked, idle, offline, other.
--   error     state "error", or any state while the vacuum reports an error code
--   cleaning  cleaning, spot/zoned/segment cleaning, every mopping and clean_mop state
--   paused    paused
--   returning returning_home, docking, going_to_wash_the_mop, back_to_dock_washing_duster
--   docked    charging, charging_complete, charging_problem, air_drying_stopping, emptying_the_bin,
--             washing_the_mop, attaching_the_mop, detaching_the_mop
--   idle      idle, charger_disconnected (standing on the floor, no job)
--   offline   device_offline
--   other     starting, going_to_target, mapping, manual_mode, remote_control_active, updating,
--             shutting_down, in_call, egg_attack, patrol, locked, unknown and anything new
local function activityFor(s, hasErr)
  s = normState(s)
  if s == "error" or hasErr then return "error" end
  if isCleaning(s) then return "cleaning" end
  if s == "paused" then return "paused" end
  if RETURNING_STATES[s] then return "returning" end
  if isAtDock(s) then return "docked" end
  if s == "idle" or s == "charger_disconnected" then return "idle" end
  if s == "device_offline" then return "offline" end
  return "other"
end

-- v0.6.2: adaptive poll. Fast while the robot is cleaning, returning or busy at the dock.
local function pollSeconds()
  local s = state.st or ""
  if isCleaning(s) or isReturning(s) or DOCK_SERVICE_STATES[s] then return FAST_POLL end
  local n = tonumber(prop("Poll Interval")) or DEFAULT_POLL
  if n < MIN_POLL then n = MIN_POLL end
  return n
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

-- v0.7.0: room id (string) for a room name from the bridge's room list, nil if there is none.
local function roomIdForName(name)
  local want = trim(name):lower()
  for id, rname in state.roomsJson:gmatch('"id"%s*:%s*(%d+)%s*,%s*"name"%s*:%s*"([^"]*)"') do
    if rname:lower() == want then return id end
  end
  return nil
end

-- v0.6.0: text for the Room field. Docked wins while on the dock. While a room job runs,
-- the target shows, because the bridge's current room is often unknown during the trip.
local function displayRoom(st)
  if isAtDock(st) then return "Docked" end
  local running = isCleaning(st) or st == "paused" or isReturning(st)
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

-- v0.7.0: "main_brush_jammed" -> "Main brush jammed"; "None" when there is no error.
local function errorText(err)
  if err == nil or err == "" or err == "none" then return "None" end
  local t = tostring(err):gsub("_", " ")
  return t:sub(1, 1):upper() .. t:sub(2)
end

-- v0.7.0: cleaning mode from a command parameter. nil = use the vacuum's own setting, false = not a mode.
local function modeFromParam(v)
  local s = normState(v)
  if s == "" or s == "device_setting" or s == "default" then return nil end
  if s == "vacuum_only" or s == "vacuum" then return "vacuum" end
  if s == "vacuum_and_mop" or s == "vac_and_mop" then return "vac_and_mop" end
  if s == "mop_only" or s == "mop" then return "mop" end
  return false
end

local function modeText()
  if state.mode == "" then return "Unknown" end
  local text = MODE_LABELS[state.mode] or state.mode
  local parts = {}
  if state.fanSpeed ~= "" then parts[#parts + 1] = "suction " .. state.fanSpeed:gsub("_", " ") end
  if state.waterMode ~= "" then parts[#parts + 1] = "water " .. state.waterMode:gsub("_", " ") end
  if #parts > 0 then text = text .. " (" .. table.concat(parts, ", ") .. ")" end
  if state.restorePending then text = text .. " - for this job only" end
  return text
end

-- ============================================================================
-- Saved data (v0.7.0): last full clean time and the cleaned area of earlier jobs
-- ============================================================================
local function saved()
  local t = nil
  pcall(function()
    if type(PersistData) ~= "table" then PersistData = {} end
    if type(PersistData.roborock) ~= "table" then PersistData.roborock = {} end
    t = PersistData.roborock
  end)
  if type(t) ~= "table" then t = {} end
  if type(t.areas) ~= "table" then t.areas = {} end
  return t
end

-- Job kind for a room list: the ids sorted and joined, e.g. "16,17".
local function roomsKey(rooms)
  local ids = {}
  for _, r in ipairs(rooms or {}) do
    local n = tonumber(r)
    if n then ids[#ids + 1] = n end
  end
  if #ids == 0 then return nil end
  table.sort(ids)
  for i, n in ipairs(ids) do ids[i] = string.format("%d", n) end
  return table.concat(ids, ",")
end

local function hoursSinceFullClean()
  local t = tonumber(saved().lastFull)
  if not t then return nil end
  return (os.time() - t) / 3600
end

local function showLastFullClean()
  local t = tonumber(saved().lastFull)
  if t then
    setProp("Last Full Clean", os.date("%Y-%m-%d %H:%M", t))
  else
    setProp("Last Full Clean", "Not seen yet")
  end
end

-- Job percent. The vacuum's own number is used when the bridge has one. Otherwise the cleaned area
-- is compared with the area of the last finished job of the same kind; that is an estimate and is
-- capped at 99. Returns nil when there is no job or nothing to compare with.
local function computeRunProgress()
  if not state.runActive then return nil, "" end
  if state.devicePct then
    local p = math.floor(state.devicePct + 0.5)
    if p < 0 then p = 0 elseif p > 100 then p = 100 end
    return p, "device"
  end
  local ref = state.runKey and tonumber(saved().areas[state.runKey]) or nil
  if ref and ref > 0 and state.area then
    local p = math.floor(state.area / ref * 100 + 0.5)
    if p < 0 then p = 0 elseif p > 99 then p = 99 end
    return p, "estimate"
  end
  return nil, ""
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
  local runProgress = "null"
  if state.runPct then runProgress = string.format("%.0f", state.runPct) end
  local json = string.format(
    '{"t":"rbrock","seq":%d,"build":"%s","version":"%s","online":%s,"state":"%s","battery":%s,"error":"%s","lastError":"%s","activeRoom":"%s","roomProgress":%s,"runProgress":%s,"progressSource":"%s","mode":"%s","modeLabel":"%s","modeOk":%s,"rooms":%s}',
    state.uiSeq, UI_BUILD, DRIVER_VERSION, state.online and "true" or "false",
    jsonEscape(state.st or ""), batt, jsonEscape(state.err or "none"), jsonEscape(state.lastErr or ""),
    jsonEscape(displayRoom(state.st or "")), progress, runProgress, state.runPctSource or "",
    jsonEscape(state.mode or ""), jsonEscape(MODE_LABELS[state.mode] or state.mode or ""),
    state.bridgeVersion ~= "" and "true" or "false", state.roomsJson)
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
  elseif isAtDock(state.st) then
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
  local rawState = strField(body, "state") or ""
  local st = normState(rawState)
  local battery = numField(body, "battery")
  local err = strField(body, "error") or "none"
  local errCode = numField(body, "error_code")
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

  -- v0.7.0: fields from bridge 0.2.3. An older bridge does not send them, so they stay nil or "".
  state.devicePct = numField(body, "run_progress_pct")
  state.area = numField(body, "clean_area_m2")
  state.cleanTime = numField(body, "clean_time_s")
  state.mode = strField(body, "cleaning_mode") or ""
  state.waterMode = strField(body, "water_mode") or ""
  state.fanSpeed = strField(body, "fan_speed") or ""
  state.bridgeVersion = strField(body, "bridge_version") or ""
  state.restorePending = body:find('"mode_restore_pending"%s*:%s*true') ~= nil

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

  local cleaningNow = isCleaning(st)
  local dockedNow = isDocked(st)
  local atDockNow = isAtDock(st)
  local hasErr = (err ~= "" and err ~= "none")

  -- v0.7.0 job tracking. A job starts when a cleaning state is first seen and lasts through pause,
  -- returning and dock service until the robot rests on the dock or is stopped (idle).
  local started = false
  if cleaningNow and not state.runActive then
    started = true
    state.runActive = true
    state.runAborted = false
    state.runMaxArea = 0
    if state.pendingKey and (os.time() - state.pendingKeyAt) <= PENDING_JOB_SECONDS then
      state.runKey = state.pendingKey
    elseif st == "cleaning" then
      state.runKey = "full"            -- a whole-home job started from the Roborock app or a schedule
    else
      state.runKey = nil
    end
    state.pendingKey = nil
  end
  if state.runActive and state.area then
    -- The area only grows inside one job; a clear drop means the first value was left from the job before.
    if state.area > state.runMaxArea or state.area < state.runMaxArea - 1 then
      state.runMaxArea = state.area
    end
  end
  -- A recharge in the middle of a job: on the dock, charging, the vacuum still says it is in a job
  -- (in_cleaning above 0, bridge 0.2.3) and the battery is not full. The job is not over then.
  local inCleaning = numField(body, "in_cleaning")
  local midJobCharge = (st == "charging") and inCleaning ~= nil and inCleaning > 0
    and battery ~= nil and battery < 100
  local ended = state.runActive and ((dockedNow and not midJobCharge) or st == "idle")
  state.runPct, state.runPctSource = computeRunProgress()

  -- Properties and variables are written before any event fires, so a program that runs on the
  -- event reads the new values.
  setProp("State", rawState)
  setVar(VAR_STATE, rawState)
  local activity = activityFor(st, hasErr)
  setProp("Activity", activity)
  setVar(VAR_ACTIVITY, activity)

  if battery then
    setProp("Battery", tostring(battery) .. "%")
    setVar(VAR_BATTERY, battery)
  end

  setVar(VAR_ERROR, err)
  setVar(VAR_ERROR_TEXT, errorText(err))
  setVar(VAR_ERROR_CODE, hasErr and (errCode or 0) or 0)
  setProp("Last Error", lastErr or err)
  if hasErr and errCode then
    setProp("Vacuum Error", errorText(err) .. " (code " .. string.format("%d", errCode) .. ")")
  else
    setProp("Vacuum Error", errorText(err))
  end

  -- v0.5.0 room properties and variables
  setProp("Active Room", displayRoom(st))
  setVar(VAR_ROOM, state.activeRoom)
  if state.roomProgress then
    setProp("Room Progress", string.format("%.0f%%", state.roomProgress))
  else
    setProp("Room Progress", "n/a")
  end
  setVar(VAR_ROOM_PROGRESS, state.roomProgress or 0)

  -- v0.7.0 job progress, cleaning mode and job numbers
  if state.runPct then
    setProp("Run Progress", string.format("%d%% (%s)", state.runPct, state.runPctSource))
  else
    setProp("Run Progress", "n/a")
  end
  setVar(VAR_RUN_PROGRESS, state.runPct or 0)
  setProp("Cleaning Mode", modeText())
  setVar(VAR_MODE, state.mode)
  setProp("Cleaned Area", state.area and string.format("%.1f m2", state.area) or "n/a")
  setProp("Clean Time", state.cleanTime and string.format("%d min", math.floor(state.cleanTime / 60 + 0.5)) or "n/a")
  setProp("Bridge Version", state.bridgeVersion ~= "" and state.bridgeVersion or "older than 0.2.3")
  setVar(VAR_IS_CLEANING, cleaningNow and "1" or "0")
  setVar(VAR_IS_DOCKED, atDockNow and "1" or "0")
  setVar(VAR_JOB_ACTIVE, (state.runActive and not ended) and "1" or "0")

  -- Cleaning Started: once per job (not again after a pause or a mop wash)
  if started then
    fire(EVENT_CLEANING_STARTED)
    logmsg("cleaning started (" .. tostring(state.runKey or "job kind unknown") .. ")")
  end

  -- v0.7.0 Docked: the robot arrives on the dock from somewhere else. Not fired for the first state
  -- after a driver start.
  if atDockNow and state.lastState ~= "" and not isAtDock(state.lastState) then
    fire(EVENT_DOCKED)
    logmsg("docked")
  end

  -- v0.5.0 laundry events. While cleaning, the bridge's current_room decides: Entered when it
  -- is the Laundry Room ID, Left when it changes to another room. When current_room is null,
  -- the v0.4.0 run-target rule applies (Entered on cleaning start for a laundry-only run).
  local laundryId = tonumber(prop("Laundry Room ID"))
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
  elseif cleaningNow and not state.laundryActive then
    if isLaundryOnlyRun(state.runRooms) then
      state.laundryActive = true
      fire(EVENT_LAUNDRY_ENTERED)
      logmsg("laundry room entered (run target)")
    end
  end
  -- v0.6.0 laundry clean job events. These do not depend on the bridge's current room, so they
  -- fire while the robot is still travelling to the Laundry Room ID.
  -- Poll backup: fires only if sendCommand did not already fire it for this run (laundryJob).
  if cleaningNow and not state.laundryJob and targetsLaundry(state.runRooms) then
    state.laundryJob = true
    state.laundryJobAt = os.time()
    fire(EVENT_LAUNDRY_CLEAN_STARTED)
    logmsg("laundry clean job started (poll)")
  end
  -- v0.7.0: a laundry job that was accepted but never seen running is dropped, so its Finished
  -- event does not fire at the end of a later, unrelated job.
  if state.laundryJob and not state.runActive and (os.time() - state.laundryJobAt) > PENDING_JOB_SECONDS then
    state.laundryJob = false
    state.runRooms = nil
    logmsg("laundry clean job never started; dropped")
  end

  -- Job ended: resting on the dock, or stopped (idle). Not on pause, returning or dock service.
  if ended then
    if dockedNow then
      fire(EVENT_CLEANING_FINISHED)
      logmsg("cleaning finished")
      if not state.runAborted then
        local data = saved()
        if state.runKey == "full" then
          data.lastFull = os.time()
          showLastFullClean()
        end
        if state.runKey and state.runMaxArea >= MIN_REFERENCE_AREA then
          data.areas[state.runKey] = state.runMaxArea
          logmsg(string.format("progress reference for %s: %.1f m2", state.runKey, state.runMaxArea))
        end
      end
    else
      logmsg("cleaning stopped")
    end
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
    state.runActive = false
    state.runAborted = false
    state.runKey = nil
    state.runPct, state.runPctSource = nil, ""
    setProp("Run Progress", "n/a")
    setVar(VAR_RUN_PROGRESS, 0)
    setProp("Active Room", displayRoom(st))
  end
  state.lastState = st

  -- Error Raised on a new error code; v0.7.0 Error Cleared when it goes back to none
  if hasErr and err ~= state.lastError then
    fire(EVENT_ERROR_RAISED)
    logmsg("error raised: " .. err)
  elseif not hasErr and state.lastError ~= "none" then
    fire(EVENT_ERROR_CLEARED)
    logmsg("error cleared: " .. state.lastError)
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
-- Room list from a command parameter: ids ("16,17" or "16 17") or room names from the vacuum's map
-- ("Kitchen, Living room"), separated by commas. Returns the id list and the first unknown name.
local function parseRooms(s)
  local out, unknown = {}, nil
  for piece in string.gmatch(tostring(s or ""), "[^,;]+") do
    local p = trim(piece)
    if p ~= "" then
      if p:match("^[%d%s]+$") then
        for id in p:gmatch("%d+") do out[#out + 1] = id end
      else
        local id = roomIdForName(p)
        if id then
          out[#out + 1] = id
        elseif not unknown then
          unknown = p
        end
      end
    end
  end
  return out, unknown
end

-- True when a clean_rooms run targets only the Laundry Room ID (v0.4.0 fallback).
function isLaundryOnlyRun(rooms)
  local laundry = tonumber(prop("Laundry Room ID"))
  if not laundry or laundry <= 0 or not rooms or #rooms ~= 1 then
    return false
  end
  return tonumber(rooms[1]) == laundry
end

-- mode (v0.7.0): nil, or "vacuum" / "vac_and_mop" / "mop". With start and clean_rooms the bridge sets
-- the mode for that job only and puts the old setting back afterwards; with set_mode it is lasting.
local function sendCommand(action, rooms, mode)
  if mode and state.bridgeVersion == "" then
    -- An older bridge would ignore the mode and clean with the vacuum's own setting (it could mop
    -- when Vacuum Only was asked for), so nothing is sent.
    logmsg("command " .. action .. " not sent: a cleaning mode needs bridge 0.2.3 or later")
    setLastCommand("not sent: " .. action .. " with a mode needs bridge 0.2.3 or later")
    publishUi()
    return false
  end
  local body = '{"action":"' .. action .. '"'
  if rooms and #rooms > 0 then
    body = body .. ',"rooms":[' .. table.concat(rooms, ",") .. "]"
  end
  if mode then
    body = body .. ',"mode":"' .. mode .. '"'
  end
  body = body .. "}"
  local label = action
  if mode then label = action .. " (" .. (MODE_LABELS[mode] or mode) .. ")" end

  state.busy = true
  httpRequest("POST", "/command", body, function(ok, data, code, err)
    state.busy = false
    if ok then
      state.unreachable = false
      if action == "clean_rooms" then
        state.runRooms = rooms
        if state.runActive then
          state.runKey = nil           -- a new room list in the middle of a job: job kind unknown
        else
          state.pendingKey, state.pendingKeyAt = roomsKey(rooms), os.time()
        end
      elseif action == "start" then
        if not state.runActive then    -- while a job is active, start only resumes it
          state.runRooms = nil
          state.pendingKey, state.pendingKeyAt = "full", os.time()
        end
      elseif (action == "stop" or action == "dock") and state.runActive then
        state.runAborted = true
      end
      logmsg("command " .. label .. " accepted")
      setProp("Status", "Command sent: " .. label)
      setLastCommand("sent: " .. label)
      -- v0.6.2: fire the laundry clean start now, not on the next poll
      if action == "clean_rooms" and targetsLaundry(rooms) then
        state.laundryJob = true
        state.laundryJobAt = os.time()
        fire(EVENT_LAUNDRY_CLEAN_STARTED)
        logmsg("laundry clean job started (command accepted)")
      end
      publishUi()
    elseif code >= 400 and code < 500 then
      -- v0.7.0: the bridge answered and refused the command. It is reachable, so no Bridge Unreachable.
      local why = "HTTP " .. tostring(code)
      if code == 422 then
        why = "this vacuum does not have that mode"
      elseif code == 409 then
        why = "vacuum not ready"
      end
      logmsg("command " .. label .. " rejected: " .. why)
      setProp("Status", "Command rejected: " .. label)
      setLastCommand("rejected: " .. label .. " (" .. why .. ")")
      publishUi()
    else
      local reason = err
      if reason == nil or reason == "" then reason = "HTTP " .. tostring(code) end
      logmsg("command " .. label .. " failed: " .. tostring(reason))
      setLastCommand("failed: " .. label .. " (" .. tostring(reason) .. ")")
      setUnreachable(reason)
    end
    -- Re-read state shortly after a command
    schedule(COMMAND_RECHECK_SECONDS)
  end)
  return true
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
  elseif cmd:sub(1, 7) == "UI_RUN_" then
    -- v0.7.0: a job with a mode, UI_RUN_<VACUUM|VACMOP|MOP>_START or ..._ROOMS_16_17
    local token, rest = cmd:match("^UI_RUN_([A-Z]+)_(.+)$")
    local mode = token and UI_MODES[token] or nil
    if not mode then
      logmsg("web view: unknown mode in " .. cmd)
      return
    end
    if rest == "START" then
      logmsg("web view: start (" .. mode .. ")")
      sendCommand("start", nil, mode)
    elseif rest:sub(1, 6) == "ROOMS_" then
      local rooms = {}
      for id in rest:sub(7):gmatch("%d+") do
        rooms[#rooms + 1] = id
      end
      if #rooms == 0 then
        logmsg("web view: clean rooms with no room ids")
        return
      end
      logmsg("web view: clean rooms " .. table.concat(rooms, ",") .. " (" .. mode .. ")")
      sendCommand("clean_rooms", rooms, mode)
    end
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
  if strCommand == "LUA_ACTION" and tParams.ACTION then
    strCommand = tParams.ACTION
  end
  if tostring(strCommand):sub(1, 3) == "UI_" then
    handleUi(tostring(strCommand))
    return
  end
  if strCommand == "START" or strCommand == "Start" then
    sendCommand("start")
  elseif strCommand == "START_FULL_CLEAN" or strCommand == "Start Full Clean" then
    -- v0.7.0: whole-home job with an optional mode and an optional "cleaned recently" guard
    local mode = modeFromParam(tParams["Mode"])
    if mode == false then
      logmsg("Start Full Clean: unknown Mode '" .. tostring(tParams["Mode"]) .. "'")
      setLastCommand("Start Full Clean not sent: unknown Mode")
      return
    end
    local skipHours = tonumber(tParams["Skip If Cleaned Within Hours"]) or 0
    if skipHours > 0 then
      if state.runActive then
        logmsg("Start Full Clean skipped: a job is already running")
        setLastCommand("Start Full Clean skipped: a job is already running")
        return
      end
      local h = hoursSinceFullClean()
      if h and h < skipHours then
        local text = string.format("Start Full Clean skipped: a full clean finished %.1f h ago", h)
        logmsg(text)
        setLastCommand(text)
        return
      end
    end
    sendCommand("start", nil, mode or nil)
  elseif strCommand == "STOP" or strCommand == "Stop" then
    sendCommand("stop")
  elseif strCommand == "PAUSE" or strCommand == "Pause" then
    sendCommand("pause")
  elseif strCommand == "DOCK" or strCommand == "RETURN_TO_DOCK" or strCommand == "Dock" then
    -- v0.7.0: safe to call at any time (for example on arrival). On the dock with no job and no start
    -- just sent, nothing is sent and nothing fails. The web view Dock button always sends.
    local startJustSent = state.pendingKey ~= nil and (os.time() - state.pendingKeyAt) <= PENDING_JOB_SECONDS
    if state.online and isAtDock(state.st) and not state.runActive and not startJustSent then
      logmsg("Dock skipped: already on the dock")
      setLastCommand("Dock skipped: already on the dock")
      return
    end
    sendCommand("dock")
  elseif strCommand == "CLEAN_ROOMS" or strCommand == "Clean Rooms" then
    local rooms, unknown = parseRooms(tParams["Rooms"] or "")
    if unknown then
      logmsg("Clean Rooms: no room named '" .. unknown .. "' on the vacuum's map")
      setLastCommand("Clean Rooms not sent: unknown room '" .. unknown .. "'")
      return
    end
    if #rooms == 0 then
      logmsg("Clean Rooms called with no room ids")
      return
    end
    local mode = modeFromParam(tParams["Mode"])
    if mode == false then
      logmsg("Clean Rooms: unknown Mode '" .. tostring(tParams["Mode"]) .. "'")
      setLastCommand("Clean Rooms not sent: unknown Mode")
      return
    end
    sendCommand("clean_rooms", rooms, mode or nil)
  elseif strCommand == "SET_CLEANING_MODE" or strCommand == "Set Cleaning Mode" then
    -- v0.7.0: lasting change of the vacuum's own setting (not for one job)
    local mode = modeFromParam(tParams["Mode"])
    if not mode then
      logmsg("Set Cleaning Mode: unknown Mode '" .. tostring(tParams["Mode"]) .. "'")
      setLastCommand("Set Cleaning Mode not sent: unknown Mode")
      return
    end
    sendCommand("set_mode", nil, mode)
  elseif strCommand == "REFRESH" or strCommand == "Refresh Now" then
    schedule(1)
  else
    logmsg("unhandled command: " .. tostring(strCommand))
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if strCommand == "GET_CONNECTED_STATE" or strCommand == "SELECT" then
    return
  end
  ExecuteCommand(strCommand, tParams)
end

-- ============================================================================
-- Driver lifecycle
-- ============================================================================
local function ensureVariables()
  local defs = {
    { VAR_STATE, "", "STRING" },
    { VAR_BATTERY, "", "NUMBER" },
    { VAR_ERROR, "", "STRING" },
    { VAR_UI, "", "STRING" },
    { VAR_ROOM, "", "STRING" },
    { VAR_ROOM_PROGRESS, "", "NUMBER" },
    { VAR_RUN_PROGRESS, "0", "NUMBER" },
    { VAR_MODE, "", "STRING" },
    { VAR_ERROR_TEXT, "None", "STRING" },
    { VAR_ERROR_CODE, "0", "NUMBER" },
    { VAR_IS_CLEANING, "0", "BOOL" },
    { VAR_IS_DOCKED, "0", "BOOL" },
    { VAR_JOB_ACTIVE, "0", "BOOL" },
    { VAR_ACTIVITY, "", "STRING" },
  }
  for _, d in ipairs(defs) do
    pcall(function() C4:AddVariable(d[1], d[2], d[3], true, false) end)
  end
end

function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  ensureVariables()
  setProp("Status", "Starting")
  showLastFullClean()
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
