-- DLS regression: a light turned on by hand AFTER the scheduled off (off ramp already finished,
-- outside every ignore window) must hold; off enforcement must not send it back to 0.
-- Run: python tools/c4sim/run.py test dls_manual_on_after_off
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

-- Same shape as live Upstairs: dusk trigger, off at 22:30, no presence object.
local ROOMS = '[{"name":"Upstairs","on_daylight":0.3,"off":"22:30","lights":[{"id":337,"kind":"lutron"}]}]'

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

t.test("manual on 50 min after the scheduled off holds; enforcement does not re-send 0", function()
  sim.reset(1)
  start()
  sim.advance(2 * 60 * SEC + 10 * SEC)               -- 22:30:10, off ramp to 0 sent, light dark
  t.ok(ramps_to(0) >= 1, "scheduled off ramp sent")
  sim.advance(48 * 60 * SEC)                         -- 23:18, well past ramp end + ignore window
  sim.set_var(U, VAR, "30")                          -- hand on the dimmer: 0 -> 30
  sim.fire_var(U, VAR, "30")
  sim.sent = {}
  sim.advance(12 * 60 * SEC)                         -- past next two 5 min enforce intervals
  t.eq(ramps_to(0), 0, "no off re-sent while the manual hold is active")
end)

t.test("manual on a few seconds after the off ramp ends (inside ignoreUntil) holds", function()
  sim.reset(1)
  start()
  sim.advance(2 * 60 * SEC + 10 * SEC)               -- 22:30:10: off ramp to 0 sent, ends ~22:31:40
  -- run the tick past ramp end + settle with the light at 0
  sim.set_var(U, VAR, "0")
  sim.fire_var(U, VAR, "0")
  sim.advance(95 * SEC)                              -- ~22:31:45, settle check has run, ignoreUntil still live
  sim.set_var(U, VAR, "30")                          -- hand on the dimmer just after it went dark
  sim.fire_var(U, VAR, "30")
  sim.sent = {}
  sim.advance(10 * 60 * SEC)
  t.eq(ramps_to(0), 0, "no off re-sent while the manual hold is active")
end)

t.finish("dls-manual-on-after-off")
