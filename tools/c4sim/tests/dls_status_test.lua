-- DLS Status strings: the main states an installer reads in Composer (loaded OK, Load error, presence
-- Home/Away, offline lights, held rooms and held lights).
-- Run: python tools/c4sim/run.py test dls_status
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600

local function local_sec(h, m)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local SCENES = '"scenes":{"Low":{"levels":{"337":3}},"High":{"levels":{"337":97}}},'
local ROOMS = '[{"name":"Upstairs","on":"18:00","off":"22:30",' .. SCENES .. '"lights":[{"id":337,"kind":"lutron"}]}]'

local function status() return tostring(sim._store["Status"]) end

local function load(extra, lit)
  local properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = ROOMS, ["Latitude"] = "40", ["Longitude"] = "-75" }
  for k, v in pairs(extra or {}) do properties[k] = v end
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = properties,
    start_ms = local_sec(19, 0) * SEC,
    before = function(s) s.set_var(337, VAR, lit or "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

t.test("1: a good load shows the running OK line", function()
  sim.reset(1)
  load()
  sim.advance(20 * SEC)                        -- the first pass after the loads settle
  t.ok(status():find("^OK %d%d:%d%d | lights driven: %d+ | rooms held: 0 | lights held: 0 | cloud: ") ~= nil,
    "Status is the running line (" .. status() .. ")")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.test("2: a failing load reports Load error and still starts the timers", function()
  sim.reset(1)
  local real = C4.RegisterVariableListener
  local boom = true
  C4.RegisterVariableListener = function(...)  -- fail once, during OnDriverLateInit only
    if boom then boom = false error("simulated load failure") end
    return real(...)
  end
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Rooms JSON"] = ROOMS, ["Latitude"] = "40", ["Longitude"] = "-75" },
    start_ms = local_sec(19, 0) * SEC,
    before = function(s) s.set_var(337, VAR, "40") end,
  })
  C4.RegisterVariableListener = real
  t.ok(ok, "load reported no uncaught error")
  t.ok(status():find("Load error:", 1, true) == 1, "Status is the load error (" .. status() .. ")")
  sim.advance(20 * SEC)
  t.ok(status():find("OK ", 1, true) == 1, "the schedule still runs after a load error (" .. status() .. ")")
end)

t.test("3: presence Away and Home are named in Status", function()
  sim.reset(1)
  load()
  sim.advance(20 * SEC)
  sim.exec("SetPresence", { PRESENT = "AWAY" })
  t.ok(status():find("Away | someone's-home lamps: 0 | ", 1, true) == 1, "Away line (" .. status() .. ")")
  sim.exec("SetPresence", { PRESENT = "HOME" })
  t.ok(status():find("OK ", 1, true) == 1, "back to the running line (" .. status() .. ")")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.test("4: an offline light is counted in Status and the note survives the next update", function()
  sim.reset(1)
  load({ ["Light Timeout (sec)"] = "10" }, "100")   -- already at the 19:00 target, so it confirms at once
  sim.advance(5 * SEC)                             -- first command, then the confirming feedback
  sim.sent = {}
  sim.exec("ApplyScene", { ROOM = "Upstairs", SCENE = "Low" })   -- level 3, never confirmed
  sim.advance(15 * SEC)
  t.eq(sim._store["Offline Lights"], "337", "Offline Lights names the light")
  t.ok(status():find("1 light(s) not responding", 1, true) ~= nil, "Status counts it (" .. status() .. ")")
  sim.advance(1 * MIN)
  t.ok(status():find("not responding", 1, true) ~= nil, "the note is still there after an update (" .. status() .. ")")
  sim.set_var(337, VAR, "3")                       -- it obeys
  sim.advance(2 * SEC)
  t.eq(sim._store["Offline Lights"], "", "Offline Lights cleared")
  sim.advance(1 * MIN)
  t.ok(status():find("not responding", 1, true) == nil, "Status dropped the note (" .. status() .. ")")
end)

t.test("5: held lights and held rooms are counted in Status", function()
  sim.reset(1)
  load()
  sim.advance(20 * SEC)
  sim.advance(7 * MIN)                         -- past the ramp's ignore window
  sim.fire_var(337, VAR, "55")                 -- a hand on the dimmer
  sim.advance(1 * MIN)
  t.ok(status():find("lights held: 1", 1, true) ~= nil, "a held light is counted (" .. status() .. ")")
  t.ok(status():find("rooms held: 0", 1, true) ~= nil, "the room itself is not held")
  sim.exec("ApplyScene", { ROOM = "Upstairs", SCENE = "Low" })
  sim.advance(1 * MIN)
  t.ok(status():find("rooms held: 1", 1, true) ~= nil, "a held room is counted (" .. status() .. ")")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.finish("dls-status")
