-- DLS 1.11.2 regression: a manual change made during a scheduled-off ramp (non-presence room) must set a hold,
-- not be swallowed as DLS's own feedback and then undone by off enforcement.
-- Run: python tools/c4sim/run.py test dls_manual_override
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

local ROOMS = '[{"name":"Upstairs","on":"18:00","off":"22:30","lights":[{"id":337,"kind":"lutron"}]}]'

local function ramps_to(level)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == U and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == level then n = n + 1 end
  end
  return n
end

local function start()
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Override Hold (min)"] = "120", ["Rooms JSON"] = ROOMS, ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" },
    start_ms = local_sec(22, 28) * SEC,
    before = function(s) s.set_var(U, VAR, "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

t.test("manual 0 -> 30 during the 22:30 off ramp holds; no re-send of 0 later", function()
  sim.reset(1)
  start()
  sim.advance(2 * 60 * SEC + 5 * SEC)               -- 22:30:05, off ramp to 0 has been sent
  t.ok(ramps_to(0) >= 1, "scheduled off ramp sent")
  sim.fire_var(U, VAR, "30")                          -- hand on the dimmer during the ramp
  sim.sent = {}
  sim.advance(10 * 60 * SEC)                          -- past ramp end, offFadeUntil and the 5 min enforce interval
  t.eq(ramps_to(0), 0, "no off re-sent while the manual hold is active")
end)

t.finish("dls-manual-override")
