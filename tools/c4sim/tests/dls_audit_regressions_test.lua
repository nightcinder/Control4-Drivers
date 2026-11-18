-- DLS 1.11.7 audit regressions: Release Room Override, a scene hold surviving a reload, no re-ramp on a
-- plain property change, and the on_daylight window between noon and midnight.
-- Run: python tools/c4sim/run.py test dls_audit_regressions
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local U = 337
local SEC = 1000
local EPOCH = 1767225600

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local ROOMS = '[{"name":"Upstairs","on":"18:00","off":"22:30","scenes":{"Off":{"off":true}},"lights":[{"id":337,"kind":"lutron"}]}]'

local function zeros(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == 0 then n = n + 1 end
  end
  return n
end

local function levels(id, min)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and (min == nil or s.params.LEVEL >= min) then n = n + 1 end
  end
  return n
end

local function load(h, m, day, persist)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Override Hold (min)"] = "120", ["Rooms JSON"] = ROOMS, ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" },
    persist = persist,
    start_ms = (local_sec(h, m) + (day or 0) * 86400) * SEC,
    before = function(s) s.set_var(U, VAR, "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

t.test("1: Release Room Override clears the per-light hold and the schedule resumes", function()
  sim.reset(1)
  load(19, 0)
  sim.advance(70 * SEC)
  sim.advance(7 * 60 * SEC)                    -- let the ignore window pass and the target settle
  sim.fire_var(U, VAR, "55")                   -- hand on the dimmer
  sim.advance(60 * SEC)
  t.ok(type(sim.persist.holds) == "table" and sim.persist.holds.Upstairs ~= nil, "hold set before release")
  sim.sent = {}
  sim.exec("Release Room Override", { ROOM = "Upstairs" })
  t.ok(levels(U, 1) >= 1, "the schedule drives the light again after release")
  local h = type(sim.persist.holds) == "table" and sim.persist.holds.Upstairs
  t.ok(h == nil or next(h) == nil, "the persisted hold was cleared")
end)

t.test("2: an Off scene hold survives a driver reload", function()
  sim.reset(1)
  load(19, 0)
  sim.advance(70 * SEC)
  sim.exec("ApplyScene", { ROOM = "Upstairs", SCENE = "Off" })
  sim.advance(60 * SEC)
  local persist = sim.persist
  t.ok(type(persist.roomHolds) == "table" and persist.roomHolds.Upstairs ~= nil, "room hold persisted")
  load(19, 5, 0, persist)
  sim.advance(10 * 60 * SEC)                   -- in the on window, but the Off hold must still be live
  t.eq(levels(U, 1), 0, "no automatic level while the restored scene hold is live")
end)

t.test("3: a plain property change does not re-ramp the lights", function()
  sim.reset(1)
  load(19, 0)
  sim.advance(70 * SEC)
  sim.advance(7 * 60 * SEC)                    -- target settled, nothing pending
  sim.sent = {}
  sim.call("OnPropertyChanged", "Debug")
  sim.advance(5 * SEC)                         -- the 2 s Update kick
  t.eq(levels(U, 0), 0, "no level re-sent just because a property changed")
end)

-- Presence harness for case 4.
local TOK = "tok"
local K = 101
C4.ServerSend = function(_, handle, data) end
C4.ServerCloseClient = function(_, handle) end
local presenceRooms = '[{"name":"Kitchen","key":"Kitchen","on_daylight":2,"off":"00:30","presence":{"follow":true,"nightLevel":1},"lights":[{"id":101,"kind":"lutron"}]}]'

t.test("4: occupied on_daylight presence room at 21:00 uses the daylight target, not nightLevel", function()
  sim.reset(1)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Override Hold (min)"] = "120", ["Rooms JSON"] = presenceRooms, ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1", ["Presence Token"] = TOK, ["Presence Port"] = "0", ["Night Level (%)"] = "50" },
    start_ms = local_sec(21, 0) * SEC,
    before = function(s) s.set_var(K, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.call("OnServerDataIn", 1, "PRESENCE HOME " .. TOK .. "\r\nHELLO 1 1 " .. TOK .. "\r\nOCC Kitchen 1 esp " .. TOK .. "\r\n", "192.0.2.5", 50000)
  sim.sent = {}
  sim.advance(2 * 60 * SEC)
  t.ok(levels(K, 10) >= 1, "target level sent, not the presence nightLevel of 1")
end)

t.test("5: off enforcement retries a plain room while Presence Lighting is On", function()
  sim.reset(1)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Override Hold (min)"] = "120", ["Rooms JSON"] = ROOMS, ["Presence"] = "Home", ["Presence Lighting"] = "On", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" },
    start_ms = local_sec(22, 28) * SEC,
    before = function(s) s.set_var(U, VAR, "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(2 * 60 * SEC + 10 * SEC)         -- 22:30:10, scheduled off sent
  t.ok(levels(U, 0) >= 1, "scheduled off sent")
  sim.sent = {}
  sim.advance(3 * 60 * SEC)                    -- past offFadeUntil; a dropped off is re-sent once
  t.ok(levels(U, 0) >= 1, "enforcement retried the off")
end)

t.test("6: the lux closed loop reaches per-light targets", function()
  sim.reset(1)
  local rooms = '[{"name":"Office","on":"18:00","off":"22:30","lux":{"dev":900,"var":1000,"target":200},"lights":[{"id":337,"kind":"lutron","max_level":80}]}]'
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = "51.5", ["Longitude"] = "-0.1" },
    start_ms = local_sec(19, 0) * SEC,
    before = function(s) s.set_var(U, VAR, "0") s.set_var(900, 1000, "2000") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(4 * 60 * SEC)
  local last
  for _, e in ipairs(sim.sent) do
    if e.id == U and e.cmd == "RAMP_TO_LEVEL" then last = e.params.LEVEL end
  end
  t.ok(last ~= nil and last <= 10, "lux correction applied to the per-light target (last " .. tostring(last) .. ")")
end)

t.test("7: a manual change above an upward ramp is detected", function()
  sim.reset(1)
  local rooms = '[{"name":"Upstairs","on":"18:00","off":"22:30","max_level":40,"lights":[{"id":337,"kind":"lutron"}]}]'
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = "51.5", ["Longitude"] = "-0.1" },
    start_ms = local_sec(19, 0) * SEC,
    before = function(s) s.set_var(U, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(20 * SEC)                        -- 19:00:15 first tick sends 0 -> 40
  sim.fire_var(U, VAR, "90")                   -- hand far above the ramp target, inside the window
  t.ok(type(sim.persist.holds) == "table" and sim.persist.holds.Upstairs ~= nil, "manual change held")
end)

t.test("8: min_level 0 lets strong daylight turn the light fully off, once", function()
  sim.reset(1)
  local rooms = '[{"name":"Office","on":"06:00","off":"22:30","min_level":0,"max_level":100,"daylight_off":0.5,"lights":[{"id":337,"kind":"lutron"}]}]'
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = "0", ["Longitude"] = "0", ["Cloud Cover Source"] = "None (assume clear)" },
    start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(U, VAR, "50") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(20 * SEC)                        -- first tick at noon: target 0
  t.ok(zeros(U) >= 1, "a 0 target was sent")
  sim.set_var(U, VAR, "0")                     -- the light reports off
  sim.sent = {}
  sim.advance(5 * 60 * SEC)
  t.eq(zeros(U), 0, "0 is not re-sent every tick once the light is off")
end)

t.test("9: curtains still run while Away", function()
  sim.reset(1)
  local rooms = '[{"name":"Den","on":"18:00","off":"23:00","curtains":[{"id":493,"name":"Den West","facing_deg":180,"open_at":"08:00","close_at":"20:00"}],"lights":[{"id":337,"kind":"lutron"}]}]'
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = "51.5", ["Longitude"] = "-0.1", ["Curtain Automation"] = "On" },
    start_ms = local_sec(21, 0) * SEC,
    before = function(s) s.set_var(U, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  sim.exec("SetPresence", { PRESENT = "AWAY" })
  local closed = false
  for _, e in ipairs(sim.sent) do
    if e.id == 493 and (e.cmd == "CLOSE" or e.cmd == "SET_POSITION") then closed = true end
  end
  t.ok(closed, "curtain closed after sunset while Away")
end)

t.finish("dls-audit-regressions")
