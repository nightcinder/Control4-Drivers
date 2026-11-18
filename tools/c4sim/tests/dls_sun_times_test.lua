-- Sun-time accuracy: sunrise/sunset must be the real crossing, not the next 5-minute sample.
-- Regression for 2026-11-18: sunrise 07:16 was recorded as 07:20, so the curtains opened at 07:35
-- instead of 07:31. Run: python tools/c4sim/run.py test dls_sun_times
local sim = require("c4sim")
local t = require("t")
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local BLIND = 493
local SEC = 1000
local MIN = 60 * SEC
local EPOCH = 1767225600

local function start_ms(y, mo, d, h, mi)
  return (os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 }) - EPOCH) * SEC
end

-- House coordinates and the first curtain opening after them.
local LAT = "40.88904293582148"
local LON = "-81.51524774333599"

local ROOMS = '[{"name":"Downstairs","facing_deg":0,"curtains":[{"id":493,"name":"Den West",'
  .. '"facing_deg":90,"open_at":"sunrise+15","close_at":"sunset+30"}]}]'

local START_MIN

local function load_at(h, m)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = {
      ["Enabled"] = "On",
      ["Curtain Automation"] = "On",
      ["Update Interval (min)"] = "1",
      ["Ramp Time (sec)"] = "90",
      ["Rooms JSON"] = ROOMS,
      ["Latitude"] = LAT,
      ["Longitude"] = LON,
    },
    start_ms = start_ms(2026, 11, 18, h, m),
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  START_MIN = start_ms(2026, 11, 18, h, m) / 60000
end

t.test("curtains open at the real sunrise+15, not at the next 5-minute sample", function()
  sim.reset(1)
  load_at(7, 0)
  sim.advance(40 * MIN)                       -- 07:00 -> 07:40; sunrise is 07:16, open_at 07:31
  local first = nil
  for _, s in ipairs(sim.sent) do
    if s.id == BLIND and s.cmd == "OPEN" then first = s; break end
  end
  t.ok(first ~= nil, "curtain was commanded open")
  if first then
    local at = first.t / MIN - START_MIN
    t.ok(at >= 30, "not before sunrise+15 (opened at minute " .. at .. ")")
    t.ok(at <= 33, "no 5-minute rounding drift (opened at minute " .. at .. ")")
  end
end)

t.test("open_at sunrise uses the real sunrise, not the next 5-minute sample", function()
  sim.reset(1)
  ROOMS = '[{"name":"Downstairs","facing_deg":0,"curtains":[{"id":493,"name":"Den West",'
    .. '"facing_deg":90,"open_at":"sunrise+10","close_at":"sunset+30"}]}]'
  load_at(7, 0)
  sim.advance(30 * MIN)                       -- 07:00 -> 07:30; sunrise 07:16, so open_at 07:26
  local first = nil
  for _, s in ipairs(sim.sent) do
    if s.id == BLIND and s.cmd == "OPEN" then first = s; break end
  end
  t.ok(first ~= nil, "curtain was commanded open")
  if first then
    local at = first.t / MIN - START_MIN
    t.ok(at >= 25, "not before sunrise+10 (opened at minute " .. at .. ")")
    t.ok(at <= 28, "no 5-minute rounding drift (opened at minute " .. at .. ")")
  end
end)

t.finish("dls-sun-times")
