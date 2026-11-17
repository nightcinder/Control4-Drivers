-- DLS send queue: without the DLS_TEST_SYNC hook the driver sends one device command per 250 ms.
-- No test in the rest of the suite exercises the real queue.
-- Run: python tools/c4sim/run.py test dls_queue
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
-- deliberately NOT setting _G.DLS_TEST_SYNC

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC = 1000
local EPOCH = 1767225600

local function local_sec(h, m)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

t.test("two lights are sent one per 250 ms tick, in room order", function()
  sim.reset(1)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = '[{"name":"Den","on":"18:00","off":"23:00","lights":[{"id":337,"kind":"lutron"},{"id":338,"kind":"lutron"}]}]', ["Latitude"] = "40", ["Longitude"] = "-75" },
    start_ms = local_sec(19, 0) * SEC,
    before = function(s) s.set_var(337, VAR, "40") s.set_var(338, VAR, "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  sim.advance(2010)                           -- the 2 s property-change Updates enqueue both
  t.eq(#sim.sent, 0, "nothing on the wire before the first queue tick")
  sim.advance(300)                             -- 15.31 s: first queue tick
  t.eq(#sim.sent, 1, "one command after 250 ms")
  sim.advance(300)                             -- second tick
  t.eq(#sim.sent, 2, "second command on the next tick")
  t.eq(sim.sent[1].id, 337, "first light first")
  t.eq(sim.sent[2].id, 338, "second light second")
end)

t.finish("dls-queue")
