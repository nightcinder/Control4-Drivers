-- Roborock 0.7.0: state names, job events, cleaning mode, progress, guard and web view commands.
-- Run: python tools/c4sim/run.py test roborock
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

-- The driver uses the DriverWorks form with a flag before the callback:
--   C4:urlGet(url, headers, false, callback) and C4:urlPost(url, body, headers, false, callback).
-- The simulator's stubs take the callback right after the headers, so these wrappers move it.
C4.urlGet = function(_, url, headers, a, b)
  return urlGet(url, headers, type(a) == "function" and a or b, 0)
end
C4.urlPost = function(_, url, body, headers, a, b)
  return urlPost(url, body, headers, type(a) == "function" and a or b, 0)
end

local DRV = "drivers/roborock/driver.lua"
local XML = "drivers/roborock/driver.xml"
local ROOMS = '[{"id": 16, "name": "Study"}, {"id": 17, "name": "Living room"}, {"id": 18, "name": "Kitchen"}, '
  .. '{"id": 19, "name": "Hall"}, {"id": 20, "name": "Lounge"}, {"id": 21, "name": "Laundry"}]'

-- The driver fires events by NAME (C4:FireEvent(name)); a numeric id does not fire in Composer.
local EV = { STARTED = "Cleaning Started", FINISHED = "Cleaning Finished", ERROR = "Error Raised",
  BATTERY_LOW = "Battery Low", UNREACHABLE = "Bridge Unreachable", L_ENTERED = "Laundry Room Entered",
  L_LEFT = "Laundry Room Left", L_CLEAN_STARTED = "Laundry Room Clean Started",
  L_CLEAN_FINISHED = "Laundry Room Clean Finished", DOCKED = "Docked", ERROR_CLEARED = "Error Cleared" }

-- Event id -> name as declared in driver.xml.
local function xml_events()
  local f = assert(io.open(XML, "rb"))
  local xml = f:read("*a")
  f:close()
  local out = {}
  local block = xml:match("<events>(.-)</events>") or ""
  for id, name in block:gmatch("<event>%s*<id>(%d+)</id>%s*<name>(.-)</name>") do
    out[tonumber(id)] = name
  end
  return out
end

-- /state body the way the bridge sends it (Python json.dumps spacing). o.old = bridge 0.2.2 fields only.
local function body(o)
  o = o or {}
  local function s(v) return v and ('"' .. v .. '"') or "null" end
  local function n(v) return v and tostring(v) or "null" end
  local p = {
    '"state": ' .. s(o.state or "charging"),
    '"battery": ' .. n(o.battery or 100),
    '"error": ' .. s(o.error or "none"),
    '"rooms": ' .. ROOMS,
    '"last_error": null',
  }
  if not o.old then
    p[#p + 1] = '"error_code": ' .. n(o.error_code or 0)
    p[#p + 1] = '"in_cleaning": ' .. n(o.in_cleaning or 0)
    p[#p + 1] = '"clean_time_s": ' .. n(o.time)
    p[#p + 1] = '"clean_area_m2": ' .. n(o.area)
    p[#p + 1] = '"clean_percent": ' .. n(o.pct)
    p[#p + 1] = '"cleaning_mode": ' .. s(o.mode or "vac_and_mop")
    p[#p + 1] = '"water_mode": "medium"'
    p[#p + 1] = '"fan_speed": "balanced"'
    p[#p + 1] = '"mop_route": "standard"'
    p[#p + 1] = '"cleaning_modes": ["vacuum", "vac_and_mop", "mop"]'
  end
  p[#p + 1] = '"last_success_age_s": 1.2'
  p[#p + 1] = '"current_room": ' .. (o.room and ('{"id": ' .. o.room .. ', "name": "' .. (o.room_name or "X") .. '"}') or "null")
  p[#p + 1] = '"room_progress_pct": null'
  p[#p + 1] = '"run_progress_pct": ' .. n(o.pct)
  if not o.old then
    p[#p + 1] = '"run_progress_source": ' .. s(o.pct and "device" or nil)
    p[#p + 1] = '"mode_restore_pending": ' .. (o.pending and "true" or "false")
    p[#p + 1] = '"bridge_version": "0.2.3"'
  end
  return "{" .. table.concat(p, ", ") .. "}"
end

local function start(opts)
  opts = opts or {}
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Poll Interval"] = "5", ["Laundry Room ID"] = opts.laundry or "21", ["Log Mode"] = "Print" },
    persist = opts.persist,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
end

-- Answer the next /state poll with this state and run time forward until that poll has happened.
local function step(o)
  sim.queue_http("/state$", body(o), 200)
  local n = #sim.http
  for _ = 1, 120 do
    sim.advance(1000)
    if #sim.http > n then break end
  end
  t.ok(#sim.http > n, "a poll happened")
  t.eq(#sim.errors, 0, "no Lua errors: " .. tostring(sim.errors[1]))
end

-- Run a programming or web view command; the bridge answers with this HTTP code (202 = accepted).
local function cmd(name, params, code)
  local n = #sim.http
  sim.queue_http("/command$", '{"ok": true}', code or 202)
  sim.exec(name, params or {})
  sim.advance(0)
  t.eq(#sim.errors, 0, "no Lua errors: " .. tostring(sim.errors[1]))
  local req = sim.http[#sim.http]
  if #sim.http > n and req.method == "POST" then return req.body end
  table.remove(sim._http_queue)  -- nothing was sent, so drop the unused answer
  return nil
end

local function fired(id)
  local n = 0
  for _, e in ipairs(sim.events) do
    if e.id == id then n = n + 1 end
  end
  return n
end

local function P(name) return sim._store[name] end
local function V(name) return sim.dvars[name] end

local function last_icon()
  local s = sim.last_sent("ICON_CHANGED")
  return s and s.params.icon or nil
end

t.test("loads; version label and every updated property exist in driver.xml", function()
  start()
  step({ state = "charging" })
  t.eq(P("Driver Version"), "0.7.0", "Driver Version")
  t.eq(P("Status"), "Connected", "Status")
  local declared = {}
  for _, n in ipairs(sim.xml_names) do declared[n] = true end
  for _, p in ipairs(sim.props) do
    t.ok(declared[p.name], "UpdateProperty on a property that driver.xml does not declare: " .. tostring(p.name))
  end
  for _, n in ipairs({ "Cleaning Mode", "Run Progress", "Vacuum Error", "Last Full Clean", "Bridge Version" }) do
    t.ok(sim.props_api[n], n .. " is written with C4:UpdateProperty")
  end
  t.eq(P("Bridge Version"), "0.2.3", "Bridge Version")
  t.eq(P("Cleaning Mode"), "Vacuum and Mop (suction balanced, water medium)", "Cleaning Mode")
  t.eq(V("CLEANING_MODE"), "vac_and_mop", "CLEANING_MODE")
  t.eq(P("Active Room"), "Docked", "Room shows Docked while charging")
  t.eq(P("Run Progress"), "n/a", "no job, no progress")
  t.eq(fired(EV.DOCKED), 0, "Docked does not fire for the first state after a start")
end)

t.test("job events with python-roborock names: segment_cleaning, returning_home, charging", function()
  start()
  step({ state = "charging" })
  step({ state = "segment_cleaning" })
  t.eq(fired(EV.STARTED), 1, "Cleaning Started")
  t.eq(last_icon(), "Cleaning", "icon")
  t.eq(V("IS_CLEANING"), "1", "IS_CLEANING")
  t.eq(V("JOB_ACTIVE"), "1", "JOB_ACTIVE")
  step({ state = "returning_home" })
  t.eq(fired(EV.FINISHED), 0, "not finished while returning home")
  t.eq(V("JOB_ACTIVE"), "1", "job still active while returning")
  t.eq(V("IS_CLEANING"), "0", "not cleaning while returning")
  step({ state = "charging" })
  t.eq(fired(EV.FINISHED), 1, "Cleaning Finished on the dock")
  t.eq(fired(EV.DOCKED), 1, "Docked")
  t.eq(fired(EV.STARTED), 1, "Started once")
  t.eq(V("JOB_ACTIVE"), "0", "job over")
  t.eq(V("IS_DOCKED"), "1", "IS_DOCKED")
  t.eq(last_icon(), "Docked", "icon")
  step({ state = "charging_complete" })
  t.eq(fired(EV.FINISHED), 1, "no second Finished")
  t.eq(fired(EV.DOCKED), 1, "no second Docked")
  t.eq(P("Active Room"), "Docked", "charging_complete shows Docked")
  t.eq(last_icon(), "Docked", "icon stays Docked for charging_complete")
end)

t.test("case and space variants are treated like the underscore names", function()
  start()
  step({ state = "Charging" })
  step({ state = "Segment Cleaning" })
  t.eq(fired(EV.STARTED), 1, "Started")
  t.eq(P("State"), "Segment Cleaning", "State property keeps the bridge's text")
  step({ state = "Returning Home" })
  step({ state = "Charging Complete" })
  t.eq(fired(EV.FINISHED), 1, "Finished")
  t.eq(fired(EV.DOCKED), 1, "Docked")
end)

t.test("mopping states count as cleaning", function()
  start()
  step({ state = "charging" })
  step({ state = "segment_mopping" })
  t.eq(fired(EV.STARTED), 1, "Started")
  t.eq(last_icon(), "Cleaning", "icon")
end)

t.test("pause and resume is one job; idle ends it without Cleaning Finished", function()
  start()
  step({ state = "charging" })
  step({ state = "cleaning" })
  step({ state = "paused" })
  t.eq(V("JOB_ACTIVE"), "1", "paused job is still active")
  step({ state = "cleaning" })
  t.eq(fired(EV.STARTED), 1, "no second Started after a pause")
  step({ state = "idle" })
  t.eq(fired(EV.FINISHED), 0, "stopped on the floor is not Finished")
  t.eq(V("JOB_ACTIVE"), "0", "job over")
  step({ state = "returning_home" })
  step({ state = "charging" })
  t.eq(fired(EV.DOCKED), 1, "Docked when it gets home later")
  t.eq(fired(EV.FINISHED), 0, "still no Finished")
end)

t.test("emptying the bin: Docked on arrival, Finished when it rests", function()
  start()
  step({ state = "charging" })
  step({ state = "cleaning" })
  step({ state = "returning_home" })
  step({ state = "emptying_the_bin" })
  t.eq(fired(EV.DOCKED), 1, "Docked on arrival")
  t.eq(fired(EV.FINISHED), 0, "not finished while the dock is busy")
  step({ state = "charging" })
  t.eq(fired(EV.FINISHED), 1, "Finished")
  t.eq(fired(EV.DOCKED), 1, "one Docked")
end)

t.test("error raised and cleared, with text and code variables set before the event", function()
  start()
  step({ state = "charging" })
  step({ state = "error", error = "main_brush_jammed", error_code = 5 })
  t.eq(fired(EV.ERROR), 1, "Error Raised")
  t.eq(V("VACUUM_ERROR"), "main_brush_jammed", "VACUUM_ERROR")
  t.eq(V("VACUUM_ERROR_TEXT"), "Main brush jammed", "VACUUM_ERROR_TEXT")
  t.eq(V("VACUUM_ERROR_CODE"), "5", "VACUUM_ERROR_CODE")
  t.eq(P("Vacuum Error"), "Main brush jammed (code 5)", "Vacuum Error")
  t.eq(last_icon(), "Error", "icon")
  step({ state = "error", error = "main_brush_jammed", error_code = 5 })
  t.eq(fired(EV.ERROR), 1, "same error does not fire again")
  step({ state = "charging" })
  t.eq(fired(EV.ERROR_CLEARED), 1, "Error Cleared")
  t.eq(V("VACUUM_ERROR_TEXT"), "None", "text back to None")
  t.eq(V("VACUUM_ERROR_CODE"), "0", "code back to 0")
end)

t.test("Clean Rooms with a mode and room names", function()
  start()
  step({ state = "charging" })
  local b = cmd("CLEAN_ROOMS", { Rooms = "Kitchen, living room", Mode = "Vacuum Only" })
  t.eq(b, '{"action":"clean_rooms","rooms":[18,17],"mode":"vacuum"}', "body")
  t.ok(P("Last Command"):find("sent: clean_rooms (Vacuum Only)", 1, true) ~= nil, "Last Command: " .. tostring(P("Last Command")))
  b = cmd("CLEAN_ROOMS", { Rooms = "16,17" })
  t.eq(b, '{"action":"clean_rooms","rooms":[16,17]}', "ids with no mode: body as before 0.7.0")
  b = cmd("CLEAN_ROOMS", { Rooms = "16 17", Mode = "Device Setting" })
  t.eq(b, '{"action":"clean_rooms","rooms":[16,17]}', "Device Setting sends no mode")
  b = cmd("CLEAN_ROOMS", { Rooms = "Kitchen, Garage" })
  t.eq(b, nil, "an unknown room name sends nothing")
  t.ok(P("Last Command"):find("unknown room 'Garage'", 1, true) ~= nil, "Last Command names the room")
  b = cmd("CLEAN_ROOMS", { Rooms = "18", Mode = "Steam" })
  t.eq(b, nil, "an unknown mode sends nothing")
end)

t.test("Start Full Clean, Set Cleaning Mode, Dock and the older commands", function()
  start()
  step({ state = "charging" })
  t.eq(cmd("START_FULL_CLEAN", { Mode = "Vacuum and Mop" }), '{"action":"start","mode":"vac_and_mop"}', "start with mode")
  t.eq(cmd("START_FULL_CLEAN", {}), '{"action":"start"}', "start without params")
  t.eq(cmd("SET_CLEANING_MODE", { Mode = "Mop Only" }), '{"action":"set_mode","mode":"mop"}', "set_mode")
  t.eq(cmd("SET_CLEANING_MODE", { Mode = "Device Setting" }), nil, "set_mode needs a real mode")
  t.eq(cmd("START"), '{"action":"start"}', "Start")
  t.eq(cmd("DOCK"), '{"action":"dock"}', "Dock")
  t.eq(cmd("RETURN_TO_DOCK"), '{"action":"dock"}', "Return to Dock alias")
  t.eq(cmd("PAUSE"), '{"action":"pause"}', "Pause")
  t.eq(cmd("STOP"), '{"action":"stop"}', "Stop")
end)

t.test("a mode is refused when the bridge is older than 0.2.3", function()
  start()
  step({ state = "charging", old = true })
  t.eq(P("Bridge Version"), "older than 0.2.3", "Bridge Version")
  t.eq(P("Cleaning Mode"), "Unknown", "Cleaning Mode")
  t.eq(cmd("START_FULL_CLEAN", { Mode = "Vacuum Only" }), nil, "nothing sent")
  t.ok(P("Last Command"):find("needs bridge 0.2.3", 1, true) ~= nil, "Last Command explains")
  t.eq(cmd("START_FULL_CLEAN", { Mode = "Device Setting" }), '{"action":"start"}', "no mode still works")
  step({ state = "cleaning", old = true })
  t.eq(P("Run Progress"), "n/a", "no progress from an old bridge")
  t.eq(V("RUN_PROGRESS"), "0", "RUN_PROGRESS 0")
end)

t.test("a rejected command (HTTP 422) is not Bridge Unreachable", function()
  start()
  step({ state = "charging" })
  cmd("START_FULL_CLEAN", { Mode = "Mop Only" }, 422)
  t.eq(fired(EV.UNREACHABLE), 0, "no Bridge Unreachable")
  t.ok(P("Last Command"):find("rejected", 1, true) ~= nil, "Last Command: " .. tostring(P("Last Command")))
  cmd("START", {}, 502)
  t.eq(fired(EV.UNREACHABLE), 1, "HTTP 502 is Bridge Unreachable, as before")
  step({ state = "charging" })
  t.eq(P("Status"), "Connected", "recovers on the next poll")
end)

t.test("Start Full Clean guard: skipped when a full clean finished recently", function()
  start()
  step({ state = "charging" })
  t.eq(P("Last Full Clean"), "Not seen yet", "nothing seen yet")
  t.ok(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "20" }) ~= nil, "sent when no full clean is known")
  step({ state = "cleaning", area = 5 })
  t.eq(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "20" }), nil, "skipped while a job runs")
  t.ok(P("Last Command"):find("already running", 1, true) ~= nil, "Last Command says why")
  step({ state = "returning_home", area = 42 })
  step({ state = "charging", area = 42 })
  t.ok(P("Last Full Clean") ~= "Not seen yet", "Last Full Clean is set: " .. tostring(P("Last Full Clean")))
  t.eq(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "20" }), nil, "skipped: cleaned minutes ago")
  t.ok(P("Last Command"):find("skipped: a full clean finished", 1, true) ~= nil, "Last Command: " .. tostring(P("Last Command")))
  t.ok(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "0" }) ~= nil, "0 hours means no guard")
  t.ok(cmd("START_FULL_CLEAN", {}) ~= nil, "no guard without the parameter")
  sim.persist.roborock.lastFull = sim.persist.roborock.lastFull - 21 * 3600
  t.ok(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "20" }) ~= nil, "sent again after 21 hours")
end)

t.test("a room job or a stopped job does not count as a full clean", function()
  start()
  step({ state = "charging" })
  cmd("CLEAN_ROOMS", { Rooms = "18" })
  step({ state = "segment_cleaning", area = 3 })
  step({ state = "charging", area = 8 })
  t.eq(P("Last Full Clean"), "Not seen yet", "room job")
  cmd("START")
  step({ state = "cleaning", area = 2 })
  cmd("DOCK")
  step({ state = "returning_home", area = 6 })
  step({ state = "charging", area = 6 })
  t.eq(fired(EV.FINISHED), 2, "Finished fires for both jobs")
  t.eq(P("Last Full Clean"), "Not seen yet", "a job sent home early is not a full clean")
  t.eq(sim.persist.roborock.areas["full"], nil, "and is not a progress reference")
end)

t.test("progress: the vacuum's own percent wins", function()
  start()
  step({ state = "charging", pct = 100 })
  t.eq(P("Run Progress"), "n/a", "not shown without a job")
  step({ state = "cleaning", pct = 41, area = 12.5, time = 754 })
  t.eq(P("Run Progress"), "41% (device)", "Run Progress")
  t.eq(V("RUN_PROGRESS"), "41", "RUN_PROGRESS")
  t.eq(P("Cleaned Area"), "12.5 m2", "Cleaned Area")
  t.eq(P("Clean Time"), "13 min", "Clean Time")
  t.eq(P("Room Progress"), "n/a", "Room Progress stays n/a")
  t.ok(V("UI_STATE"):find('"runProgress":41,"progressSource":"device"', 1, true) ~= nil, "UI snapshot: " .. V("UI_STATE"))
  step({ state = "charging", pct = 100, area = 30 })
  t.eq(P("Run Progress"), "n/a", "cleared when the job is over")
  t.eq(V("RUN_PROGRESS"), "0", "RUN_PROGRESS 0")
end)

t.test("progress: estimate from cleaned area against the last same job", function()
  start()
  step({ state = "charging" })
  cmd("START")
  step({ state = "cleaning", area = 10 })
  t.eq(P("Run Progress"), "n/a", "first job: nothing to compare with")
  step({ state = "cleaning", area = 40 })
  step({ state = "returning_home", area = 40 })
  step({ state = "charging", area = 40 })
  t.eq(sim.persist.roborock.areas["full"], 40, "reference saved")
  cmd("START")
  step({ state = "cleaning", area = 10 })
  t.eq(P("Run Progress"), "25% (estimate)", "Run Progress is marked as an estimate")
  t.eq(V("RUN_PROGRESS"), "25", "RUN_PROGRESS")
  t.ok(V("UI_STATE"):find('"runProgress":25,"progressSource":"estimate"', 1, true) ~= nil, "UI snapshot")
  step({ state = "cleaning", area = 44 })
  t.eq(P("Run Progress"), "99% (estimate)", "an estimate never reaches 100")
  step({ state = "charging", area = 44 })
  t.eq(sim.persist.roborock.areas["full"], 44, "reference follows the newest finished job")
  -- a room job has its own reference
  cmd("CLEAN_ROOMS", { Rooms = "17,16" })
  step({ state = "segment_cleaning", area = 4 })
  t.eq(P("Run Progress"), "n/a", "no reference for this room list yet")
  step({ state = "charging", area = 12 })
  t.eq(sim.persist.roborock.areas["16,17"], 12, "room list reference, ids sorted")
  cmd("CLEAN_ROOMS", { Rooms = "16,17" })
  step({ state = "segment_cleaning", area = 6 })
  t.eq(P("Run Progress"), "50% (estimate)", "room job estimate")
  -- a job started from the Roborock app: plain "cleaning" is a full job
  step({ state = "charging", area = 12 })
  step({ state = "cleaning", area = 11 })
  t.eq(P("Run Progress"), "25% (estimate)", "app-started full job uses the full reference")
end)

t.test("the saved reference and last full clean survive a driver reload", function()
  start()
  step({ state = "charging" })
  cmd("START")
  step({ state = "cleaning", area = 20 })
  step({ state = "charging", area = 20 })
  local keep = sim.persist
  local shown = P("Last Full Clean")
  start({ persist = keep })
  t.eq(P("Last Full Clean"), shown, "Last Full Clean shown again at start")
  step({ state = "cleaning", area = 5 })
  t.eq(P("Run Progress"), "25% (estimate)", "reference kept")
  t.eq(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "20" }), nil, "guard still knows the last full clean")
end)

t.test("laundry events: clean job start at accept, finish on the dock", function()
  start()
  step({ state = "charging" })
  cmd("CLEAN_ROOMS", { Rooms = "21", Mode = "Vacuum and Mop" })
  t.eq(fired(EV.L_CLEAN_STARTED), 1, "Laundry Room Clean Started when the bridge accepts")
  step({ state = "charging" })
  t.eq(fired(EV.L_CLEAN_FINISHED), 0, "not finished before the robot has left the dock")
  step({ state = "segment_cleaning" })
  t.eq(fired(EV.L_ENTERED), 1, "Entered (run target rule, current room unknown)")
  t.eq(P("Active Room"), "Laundry (target)", "Room shows the target")
  step({ state = "segment_cleaning", room = 21, room_name = "Laundry" })
  t.eq(fired(EV.L_ENTERED), 1, "no second Entered")
  step({ state = "returning_home" })
  t.eq(fired(EV.L_CLEAN_FINISHED), 0, "not finished while returning home")
  step({ state = "charging" })
  t.eq(fired(EV.L_CLEAN_FINISHED), 1, "Laundry Room Clean Finished on the dock")
  t.eq(fired(EV.L_LEFT), 1, "Laundry Room Left")
  t.eq(fired(EV.L_CLEAN_STARTED), 1, "one start")
end)

t.test("laundry entered and left follow the bridge's current room", function()
  start()
  step({ state = "charging" })
  step({ state = "cleaning", room = 18, room_name = "Kitchen" })
  t.eq(fired(EV.L_ENTERED), 0, "kitchen")
  t.eq(P("Active Room"), "Kitchen", "Active Room")
  step({ state = "cleaning", room = 21, room_name = "Laundry" })
  t.eq(fired(EV.L_ENTERED), 1, "entered")
  step({ state = "cleaning", room = 19, room_name = "Hall" })
  t.eq(fired(EV.L_LEFT), 1, "left")
end)

t.test("web view commands", function()
  start()
  step({ state = "charging" })
  cmd("UI_HELLO_4")
  t.eq(P("Web Page Status"), "Page build 4 OK", "page build")
  t.eq(cmd("UI_START"), '{"action":"start"}', "UI_START")
  t.eq(cmd("UI_CLEAN_ROOMS_16_17"), '{"action":"clean_rooms","rooms":[16,17]}', "UI_CLEAN_ROOMS")
  t.eq(cmd("UI_RUN_VACUUM_START"), '{"action":"start","mode":"vacuum"}', "UI_RUN start")
  t.eq(cmd("UI_RUN_VACMOP_ROOMS_16_17"), '{"action":"clean_rooms","rooms":[16,17],"mode":"vac_and_mop"}', "UI_RUN rooms")
  t.eq(cmd("UI_RUN_MOP_ROOMS_21"), '{"action":"clean_rooms","rooms":[21],"mode":"mop"}', "UI_RUN mop")
  t.eq(cmd("UI_RUN_STEAM_START"), nil, "unknown mode token sends nothing")
  t.eq(cmd("UI_DOCK"), '{"action":"dock"}', "UI_DOCK")
  local ui = V("UI_STATE")
  t.ok(ui:find('"modeOk":true', 1, true) ~= nil, "modeOk in the snapshot")
  t.ok(ui:find('"modeLabel":"Vacuum and Mop"', 1, true) ~= nil, "modeLabel in the snapshot")
  t.ok(ui:find('"build":"4"', 1, true) ~= nil, "build 4")
  t.ok(pcall(JsonDecode, ui), "snapshot is valid JSON")
end)

t.test("a per-run mode that is waiting to be restored is shown", function()
  start()
  step({ state = "segment_cleaning", mode = "vacuum", pending = true })
  t.eq(P("Cleaning Mode"), "Vacuum Only (suction balanced, water medium) - for this job only", "Cleaning Mode")
end)

t.test("bridge unreachable and back", function()
  start()
  step({ state = "charging" })
  sim.queue_http("/state$", "", 500)
  sim.advance(6000)
  t.eq(fired(EV.UNREACHABLE), 1, "Bridge Unreachable")
  t.eq(P("Status"), "Bridge unreachable", "Status")
  step({ state = "charging" })
  t.eq(P("Status"), "Connected", "Connected again")
  t.eq(fired(EV.DOCKED), 0, "no Docked from an outage")
end)

-- ---------------------------------------------------------------------------
-- 0.6.3 behaviour kept in 0.7.0
-- ---------------------------------------------------------------------------
local function printed(text)
  for _, line in ipairs(sim.prints) do
    if line:find(text, 1, true) then return true end
  end
  return false
end

-- Like cmd(), but the command arrives through ReceivedFromProxy on the uibutton binding.
local function proxy(name, params)
  local n = #sim.http
  sim.queue_http("/command$", '{"ok": true}', 202)
  sim.call("ReceivedFromProxy", 5001, name, params or {})
  sim.advance(0)
  t.eq(#sim.errors, 0, "no Lua errors: " .. tostring(sim.errors[1]))
  local req = sim.http[#sim.http]
  if #sim.http > n and req.method == "POST" then return req.body end
  table.remove(sim._http_queue)
  return nil
end

t.test("0.6.3: Composer display names work like the command codes", function()
  start()
  step({ state = "cleaning" })
  t.eq(cmd("Start"), '{"action":"start"}', "Start")
  t.eq(cmd("Stop"), '{"action":"stop"}', "Stop")
  t.eq(cmd("Pause"), '{"action":"pause"}', "Pause")
  t.eq(cmd("Dock"), '{"action":"dock"}', "Dock")
  t.eq(cmd("Clean Rooms", { Rooms = "16,17" }), '{"action":"clean_rooms","rooms":[16,17]}', "Clean Rooms")
  t.eq(cmd("Clean Rooms", { Rooms = "Kitchen", Mode = "Mop Only" }),
    '{"action":"clean_rooms","rooms":[18],"mode":"mop"}', "Clean Rooms with a mode")
  t.eq(cmd("Start Full Clean", { Mode = "Vacuum Only" }), '{"action":"start","mode":"vacuum"}', "Start Full Clean")
  t.eq(cmd("Set Cleaning Mode", { Mode = "Vacuum and Mop" }), '{"action":"set_mode","mode":"vac_and_mop"}', "Set Cleaning Mode")
  local n = #sim.http
  sim.exec("Refresh Now", {})
  sim.advance(1500)
  t.ok(#sim.http > n and sim.http[#sim.http].method ~= "POST", "Refresh Now polls /state")
end)

t.test("0.6.3: LUA_ACTION is mapped to its ACTION", function()
  start()
  step({ state = "cleaning" })
  t.eq(cmd("LUA_ACTION", { ACTION = "DOCK" }), '{"action":"dock"}', "LUA_ACTION DOCK")
  t.eq(cmd("LUA_ACTION", { ACTION = "START_FULL_CLEAN", Mode = "Mop Only" }), '{"action":"start","mode":"mop"}', "LUA_ACTION with params")
  local n = #sim.http
  sim.exec("LUA_ACTION", { ACTION = "REFRESH" })
  sim.advance(1500)
  t.ok(#sim.http > n and sim.http[#sim.http].method ~= "POST", "the Refresh Now action polls /state")
  t.eq(cmd("LUA_ACTION", {}), nil, "LUA_ACTION without ACTION sends nothing")
  t.ok(printed("unhandled command: LUA_ACTION"), "and is logged as unhandled")
end)

t.test("0.6.3: an unknown command is logged and sends nothing", function()
  start()
  step({ state = "charging" })
  t.eq(cmd("FLY_AWAY"), nil, "nothing sent")
  t.ok(printed("unhandled command: FLY_AWAY"), "logged")
end)

t.test("0.6.3: ReceivedFromProxy routes to ExecuteCommand, except GET_CONNECTED_STATE and SELECT", function()
  start()
  step({ state = "cleaning" })
  t.eq(type(sim.env.ReceivedFromProxy), "function", "ReceivedFromProxy is a global function")
  t.eq(proxy("GET_CONNECTED_STATE"), nil, "GET_CONNECTED_STATE sends nothing")
  t.eq(proxy("SELECT"), nil, "SELECT (tile tap) sends nothing")
  t.ok(not printed("unhandled command"), "and neither is logged as unhandled")
  t.eq(proxy("DOCK"), '{"action":"dock"}', "DOCK through the proxy")
  t.eq(proxy("Start Full Clean", { Mode = "Vacuum Only" }), '{"action":"start","mode":"vacuum"}', "display name through the proxy")
  t.eq(proxy("UI_PAUSE"), '{"action":"pause"}', "UI_ commands still reach the web view handler")
  t.eq(proxy("UI_RUN_MOP_ROOMS_21"), '{"action":"clean_rooms","rooms":[21],"mode":"mop"}', "UI_RUN through the proxy")
  t.eq(proxy("SOMETHING_ELSE"), nil, "an unknown proxy command sends nothing")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

-- ---------------------------------------------------------------------------
-- Events are fired by name
-- ---------------------------------------------------------------------------
t.test("every fired event is a name from driver.xml; ids 1-11 keep their names", function()
  local names = xml_events()
  local want = { "Cleaning Started", "Cleaning Finished", "Error Raised", "Battery Low", "Bridge Unreachable",
    "Laundry Room Entered", "Laundry Room Left", "Laundry Room Clean Started", "Laundry Room Clean Finished",
    "Docked", "Error Cleared" }
  for id, name in ipairs(want) do
    t.eq(names[id], name, "event id " .. id)
  end
  local declared = {}
  for _, name in pairs(names) do declared[name] = true end
  start()
  step({ state = "charging" })
  cmd("CLEAN_ROOMS", { Rooms = "21" })
  step({ state = "segment_cleaning", room = 21, room_name = "Laundry", battery = 15 })
  step({ state = "error", error = "bumper_stuck", error_code = 2, battery = 15 })
  step({ state = "returning_home", battery = 15 })
  step({ state = "charging", battery = 15 })
  sim.queue_http("/state$", "", 500)
  sim.advance(20000)
  local seen = {}
  for _, e in ipairs(sim.events) do
    t.eq(type(e.id), "string", "C4:FireEvent gets a name, not an id")
    t.ok(declared[e.id], "fired event is not in driver.xml: " .. tostring(e.id))
    seen[e.id] = true
  end
  for _, name in ipairs(want) do
    t.ok(seen[name], "this run fires " .. name)
  end
end)

t.test("Battery Low fires once until the battery recovers", function()
  start()
  step({ state = "cleaning", battery = 25 })
  t.eq(fired(EV.BATTERY_LOW), 0, "above the threshold")
  step({ state = "cleaning", battery = 20 })
  step({ state = "cleaning", battery = 18 })
  t.eq(fired(EV.BATTERY_LOW), 1, "once")
  step({ state = "charging", battery = 40 })
  step({ state = "cleaning", battery = 19 })
  t.eq(fired(EV.BATTERY_LOW), 2, "again after it recovered")
end)

-- ---------------------------------------------------------------------------
-- State names: every python-roborock RoborockStateCode name (7.22.0)
-- ---------------------------------------------------------------------------
local STATE_ACTIVITY = {
  cleaning = "cleaning", spot_cleaning = "cleaning", zoned_cleaning = "cleaning", segment_cleaning = "cleaning",
  robot_status_mopping = "cleaning", clean_mop_cleaning = "cleaning", clean_mop_mopping = "cleaning",
  segment_mopping = "cleaning", segment_clean_mop_cleaning = "cleaning", segment_clean_mop_mopping = "cleaning",
  zoned_mopping = "cleaning", zoned_clean_mop_cleaning = "cleaning", zoned_clean_mop_mopping = "cleaning",
  paused = "paused",
  returning_home = "returning", docking = "returning", going_to_wash_the_mop = "returning",
  back_to_dock_washing_duster = "returning",
  charging = "docked", charging_complete = "docked", charging_problem = "docked", air_drying_stopping = "docked",
  emptying_the_bin = "docked", washing_the_mop = "docked", washing_the_mop_2 = "docked",
  attaching_the_mop = "docked", detaching_the_mop = "docked",
  idle = "idle", charger_disconnected = "idle",
  error = "error",
  device_offline = "offline",
  unknown = "other", starting = "other", remote_control_active = "other", manual_mode = "other",
  shutting_down = "other", updating = "other", going_to_target = "other", in_call = "other",
  mapping = "other", egg_attack = "other", patrol = "other", locked = "other",
}

t.test("every python-roborock state name maps to one activity", function()
  local count = 0
  for name, activity in pairs(STATE_ACTIVITY) do
    count = count + 1
    start()
    step({ state = name })
    t.eq(V("VACUUM_ACTIVITY"), activity, "VACUUM_ACTIVITY for " .. name)
    t.eq(P("Activity"), activity, "Activity for " .. name)
    t.eq(P("State"), name, "State keeps the bridge's name for " .. name)
    t.eq(V("IS_CLEANING"), activity == "cleaning" and "1" or "0", "IS_CLEANING for " .. name)
    t.eq(V("IS_DOCKED"), activity == "docked" and "1" or "0", "IS_DOCKED for " .. name)
    t.eq(fired(EV.STARTED), activity == "cleaning" and 1 or 0, "Cleaning Started for " .. name)
    local icon = (activity == "cleaning" and "Cleaning") or (activity == "docked" and "Docked") or "Default"
    t.eq(last_icon(), icon, "icon for " .. name)
  end
  t.eq(count, 43, "all 43 state names of python-roborock 7.22.0 are covered")
  t.ok(sim.props_api["Activity"], "Activity is written with C4:UpdateProperty")
end)

t.test("an error code wins over the state for the activity", function()
  start()
  step({ state = "charging", error = "dustbin_full", error_code = 23 })
  t.eq(V("VACUUM_ACTIVITY"), "error", "error while charging")
  t.eq(V("IS_DOCKED"), "1", "still on the dock")
  step({ state = "charging" })
  t.eq(V("VACUUM_ACTIVITY"), "docked", "docked when the error is gone")
end)

t.test("air drying on the dock is not a departure", function()
  start()
  step({ state = "charging" })
  step({ state = "air_drying_stopping" })
  step({ state = "charging" })
  t.eq(fired(EV.DOCKED), 0, "no Docked: it never left the dock")
end)

t.test("mop wash in the middle of a job: one job, one Started, one Finished", function()
  start()
  step({ state = "charging" })
  step({ state = "segment_clean_mop_mopping" })
  step({ state = "going_to_wash_the_mop" })
  t.eq(V("JOB_ACTIVE"), "1", "job active on the way to the wash")
  step({ state = "washing_the_mop" })
  t.eq(fired(EV.DOCKED), 1, "Docked for the wash")
  t.eq(fired(EV.FINISHED), 0, "not finished during the wash")
  step({ state = "segment_clean_mop_mopping" })
  t.eq(fired(EV.STARTED), 1, "no second Started after the wash")
  step({ state = "back_to_dock_washing_duster" })
  step({ state = "washing_the_mop_2" })
  step({ state = "charging" })
  t.eq(fired(EV.FINISHED), 1, "Finished once")
  t.eq(fired(EV.DOCKED), 2, "Docked for each arrival")
end)

t.test("a recharge in the middle of a job does not end it", function()
  start()
  step({ state = "charging" })
  cmd("START")
  step({ state = "cleaning", area = 30, battery = 25 })
  step({ state = "returning_home", area = 30, battery = 19 })
  step({ state = "charging", area = 30, battery = 20, in_cleaning = 1 })
  t.eq(fired(EV.DOCKED), 1, "Docked fires for the recharge")
  t.eq(fired(EV.FINISHED), 0, "not finished: the vacuum is still in a job")
  t.eq(V("JOB_ACTIVE"), "1", "JOB_ACTIVE")
  t.eq(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "20" }), nil, "the guard sees the job")
  step({ state = "cleaning", area = 31, battery = 80, in_cleaning = 1 })
  t.eq(fired(EV.STARTED), 1, "no second Started")
  step({ state = "charging", area = 60, battery = 60, in_cleaning = 0 })
  t.eq(fired(EV.FINISHED), 1, "Finished at the real end")
  t.eq(sim.persist.roborock.areas["full"], 60, "the whole job is the progress reference")
  -- in_cleaning left above 0 does not hold a job open for ever
  step({ state = "cleaning", area = 5, battery = 90 })
  step({ state = "charging", area = 40, battery = 100, in_cleaning = 1 })
  t.eq(fired(EV.FINISHED), 2, "a full battery ends the job")
  step({ state = "cleaning", area = 5, battery = 90 })
  step({ state = "charging_complete", area = 40, battery = 99, in_cleaning = 1 })
  t.eq(fired(EV.FINISHED), 3, "charging_complete ends the job")
end)

-- ---------------------------------------------------------------------------
-- Dock on arrival: safe when already docked
-- ---------------------------------------------------------------------------
t.test("Dock is skipped without an error when the robot is already on the dock", function()
  start()
  for _, s in ipairs({ "charging", "charging_complete", "emptying_the_bin" }) do
    step({ state = s })
    t.eq(cmd("DOCK"), nil, "DOCK sends nothing in " .. s)
    t.eq(cmd("Dock"), nil, "Dock (display name) sends nothing in " .. s)
    t.eq(cmd("RETURN_TO_DOCK"), nil, "RETURN_TO_DOCK sends nothing in " .. s)
  end
  t.ok(P("Last Command"):find("Dock skipped: already on the dock", 1, true) ~= nil, "Last Command: " .. tostring(P("Last Command")))
  t.eq(P("Status"), "Connected", "Status is untouched")
  t.eq(fired(EV.UNREACHABLE), 0, "no Bridge Unreachable")
  t.eq(fired(EV.ERROR), 0, "no Error Raised")
  t.eq(fired(EV.DOCKED), 0, "no Docked")
  t.eq(#sim.errors, 0, "no Lua errors")
  for _, s in ipairs({ "cleaning", "paused", "returning_home", "idle", "error" }) do
    step({ state = s })
    t.eq(cmd("DOCK"), '{"action":"dock"}', "DOCK is sent in " .. s)
  end
end)

t.test("Dock is sent right after a start, before the robot has left the dock", function()
  start()
  step({ state = "charging" })
  cmd("START_FULL_CLEAN", {})
  t.eq(cmd("DOCK"), '{"action":"dock"}', "the state is not trusted just after a start")
end)

t.test("Dock is sent when the bridge is unreachable (state unknown)", function()
  start()
  step({ state = "charging" })
  sim.queue_http("/state$", "", 500)
  sim.advance(6000)
  t.eq(P("Status"), "Bridge unreachable", "offline")
  t.eq(cmd("DOCK"), '{"action":"dock"}', "sent, the last state may be old")
end)

-- ---------------------------------------------------------------------------
-- Review fixes (0.7.0)
-- ---------------------------------------------------------------------------
t.test("Dock sent while the robot is already returning home does not discard the full clean", function()
  start()
  step({ state = "charging" })
  cmd("START_FULL_CLEAN", {})
  step({ state = "cleaning", area = 20 })
  step({ state = "returning_home", area = 42 })
  t.eq(cmd("DOCK"), '{"action":"dock"}', "Dock is still sent")
  step({ state = "charging", area = 42 })
  t.eq(fired(EV.FINISHED), 1, "Finished")
  t.ok(P("Last Full Clean") ~= "Not seen yet", "the job counts as a full clean")
  t.eq(sim.persist.roborock.areas["full"], 42, "and as the progress reference")
  t.eq(cmd("START_FULL_CLEAN", { ["Skip If Cleaned Within Hours"] = "20" }), nil, "so the guard skips the next one")
end)

t.test("Dock sent by the driver ends the job on the dock even when in_cleaning stays above 0", function()
  start()
  step({ state = "charging" })
  cmd("START")
  step({ state = "cleaning", area = 10, battery = 70, in_cleaning = 1 })
  cmd("DOCK")
  step({ state = "returning_home", area = 10, battery = 69, in_cleaning = 1 })
  step({ state = "charging", area = 10, battery = 69, in_cleaning = 1 })
  t.eq(fired(EV.FINISHED), 1, "Finished is not held back as a recharge")
  t.eq(V("JOB_ACTIVE"), "0", "job over")
  t.eq(P("Last Full Clean"), "Not seen yet", "a job sent home early is not a full clean")
  -- Pause, then Dock: the same
  cmd("START")
  step({ state = "cleaning", area = 3, battery = 68, in_cleaning = 1 })
  cmd("PAUSE")
  step({ state = "paused", area = 3, battery = 68, in_cleaning = 1 })
  cmd("DOCK")
  step({ state = "charging", area = 3, battery = 68, in_cleaning = 1 })
  t.eq(fired(EV.FINISHED), 2, "Finished after pause and Dock")
end)

t.test("Clean Rooms with no rooms says so in Last Command", function()
  start()
  step({ state = "charging" })
  t.eq(cmd("CLEAN_ROOMS", { Rooms = " , " }), nil, "nothing sent")
  t.ok(P("Last Command"):find("no rooms given", 1, true) ~= nil, "Last Command: " .. tostring(P("Last Command")))
end)

t.test("the bridge's first answer (all null) and a non-JSON body do not break the driver", function()
  start()
  sim.queue_http("/state$", '{"state": null, "battery": null, "error": null, "rooms": [], "last_error": null, '
    .. '"last_success_age_s": null, "current_room": null, "room_progress_pct": null, "run_progress_pct": null, '
    .. '"run_progress_source": null, "mode_restore_pending": false, "bridge_version": "0.2.3"}', 200)
  sim.advance(2000)
  t.eq(#sim.errors, 0, "no Lua errors: " .. tostring(sim.errors[1]))
  t.eq(P("Status"), "Connected", "Status")
  t.eq(V("VACUUM_ACTIVITY"), "other", "no state yet")
  t.eq(V("VACUUM_ERROR_TEXT"), "None", "no error")
  t.eq(#sim.events, 0, "no events")
  sim.queue_http("/state$", "<html>oops</html>", 200)
  sim.advance(6000)
  t.eq(#sim.errors, 0, "no Lua errors: " .. tostring(sim.errors[1]))
  t.eq(#sim.events, 0, "still no events")
end)

t.test("Run Progress is n/a in every state without a job", function()
  for _, s in ipairs({ "charging", "charging_complete", "idle", "returning_home", "paused", "error", "emptying_the_bin" }) do
    start()
    step({ state = s, pct = 77, area = 12 })
    t.eq(P("Run Progress"), "n/a", "Run Progress in " .. s)
    t.eq(V("RUN_PROGRESS"), "0", "RUN_PROGRESS in " .. s)
    t.ok(V("UI_STATE"):find('"runProgress":null', 1, true) ~= nil, "web view snapshot in " .. s)
  end
end)

t.test("variables are created with C4:AddVariable and properties are never written directly", function()
  local added = {}
  local real = C4.AddVariable
  C4.AddVariable = function(self, name, ...)
    added[name] = true
    return real(self, name, ...)
  end
  start()
  C4.AddVariable = real
  step({ state = "charging" })
  for _, name in ipairs({ "VACUUM_STATE", "VACUUM_BATTERY", "VACUUM_ERROR", "UI_STATE", "ACTIVE_ROOM", "ROOM_PROGRESS",
    "RUN_PROGRESS", "CLEANING_MODE", "VACUUM_ERROR_TEXT", "VACUUM_ERROR_CODE", "IS_CLEANING", "IS_DOCKED",
    "JOB_ACTIVE", "VACUUM_ACTIVITY" }) do
    t.ok(added[name], name .. " is added with C4:AddVariable")
    t.ok(sim.dvars[name] ~= nil, name .. " has a value")
  end
  t.eq(next(sim.props_direct), nil, "no Properties[x] = v writes")
end)

t.finish("roborock")
