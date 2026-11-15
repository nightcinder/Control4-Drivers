-- DLS 1.11.3 regression tests: edge cases from the read-only review (manual off holds, load during the off window,
-- on_daylight rooms whose off time is after midnight).
-- Run: python tools/c4sim/run.py test dls_edge_cases
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

local function ramps(pred)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == U and s.cmd == "RAMP_TO_LEVEL" and pred(s.params.LEVEL) then n = n + 1 end
  end
  return n
end
local function ramps_on() return ramps(function(l) return l > 0 end) end
local function ramps_off() return ramps(function(l) return l == 0 end) end

local function start(h, m, rooms)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Override Hold (min)"] = "120", ["Rooms JSON"] = rooms, ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" },
    start_ms = local_sec(h, m) * SEC,
    before = function(s) s.set_var(U, VAR, "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

local ROOM_EVE = '[{"name":"Upstairs","on":"18:00","off":"22:30","lights":[{"id":337,"kind":"lutron"}]}]'
local ROOM_EVE_LOW = '[{"name":"Upstairs","on":"18:00","off":"22:30","lights":[{"id":337,"kind":"lutron","scale":0.06}]}]'
local ROOM_DAYLIGHT_WRAP = '[{"name":"Porch","on_daylight":2,"off":"00:30","lights":[{"id":337,"kind":"lutron"}]}]'

t.test("1: manual off inside the on-window stays off after the 120 min hold expires", function()
  sim.reset(1)
  start(19, 0, ROOM_EVE)
  sim.advance(70 * SEC)                       -- first in-window tick sends the target
  t.ok(ramps_on() >= 1, "in-window target sent before the manual off")
  sim.advance(5 * 60 * SEC)                   -- let the ramp's ignore window pass; the manual off must not be read as ours
  sim.sent = {}
  sim.fire_var(U, VAR, "0")                   -- manual off at about 19:06
  sim.advance(140 * 60 * SEC)                 -- about 21:26: the 120 min hold has expired
  t.eq(ramps_on(), 0, "no level re-sent after the hold expired")
  sim.sent = {}
  sim.advance((local_sec(18, 30) + 86400 - local_sec(21, 26)) * SEC)   -- next evening, 18:30
  t.ok(ramps_on() >= 1, "next on edge brings the room back")
end)

t.test("2: manual off at 8% or less inside the on-window sets a hold", function()
  sim.reset(1)
  start(19, 0, ROOM_EVE_LOW)                  -- scale 0.06: DLS target is about 6%
  sim.advance(70 * SEC)
  t.ok(ramps_on() >= 1, "low in-window target sent before the manual off")
  sim.advance(5 * 60 * SEC)                   -- let the ramp's ignore window pass; the manual off must not be read as ours
  sim.sent = {}
  sim.fire_var(U, VAR, "0")
  sim.advance(2 * 60 * SEC)
  t.eq(ramps_on(), 0, "no level re-sent after a manual off at 8% or less")
end)

t.test("3: restart inside the off window sends the pending off edge", function()
  sim.reset(1)
  start(23, 0, ROOM_EVE)                      -- loaded at 23:00, after the 22:30 off time
  sim.advance(2 * 60 * SEC)
  t.ok(ramps_off() >= 1, "off sent on the first tick after load in the off window")
  t.eq(ramps_on(), 0, "nothing turned on")
end)

t.test("5: on_daylight room with a 00:30 off time lights after the trigger and goes off at 00:30", function()
  sim.reset(1)
  start(15, 0, ROOM_DAYLIGHT_WRAP)
  sim.advance(2 * 60 * SEC)
  t.ok(ramps_on() >= 1, "lights on after the afternoon daylight trigger")
  sim.sent = {}
  sim.advance((local_sec(0, 10) + 86400 - local_sec(15, 2)) * SEC)   -- 00:10 next day
  t.eq(ramps_off(), 0, "not off before 00:30")
  sim.sent = {}
  sim.advance(30 * 60 * SEC)                  -- about 00:40
  t.ok(ramps_off() >= 1, "off after 00:30")
end)

t.finish("dls-edge-cases")
