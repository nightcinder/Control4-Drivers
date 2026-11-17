-- DLS 1.11.6 regression tests: a manual hold survives a driver reload, and off enforcement never sends 0
-- over a light the user turned on when the manual event was missed.
-- Run: python tools/c4sim/run.py test dls_hold_persist
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

local function ramps_off()
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == U and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == 0 then n = n + 1 end
  end
  return n
end

local function load(h, m, day, persist, level)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Override Hold (min)"] = "120", ["Rooms JSON"] = ROOMS, ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" },
    persist = persist,
    start_ms = (local_sec(h, m) + (day or 0) * 86400) * SEC,
    before = function(s) s.set_var(U, VAR, level or "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

t.test("1: a manual hold survives a reload inside the off window; no off is sent over it", function()
  sim.reset(1)
  load(21, 0)
  sim.advance(70 * SEC)                       -- first in-window target
  sim.advance(5 * 60 * SEC)                   -- let the ramp ignore window pass
  sim.sent = {}
  sim.advance(2 * 60 * SEC)                   -- stable target: no DLS command, ignore window clear
  sim.fire_var(U, VAR, "55")                  -- hand on the dimmer: hold set
  sim.advance(60 * SEC)
  local persist = sim.persist
  t.ok(type(persist.holds) == "table" and persist.holds.Upstairs ~= nil, "hold was persisted")
  load(23, 0, 0, persist, "55")               -- Composer import / project refresh, light still on
  sim.advance(3 * 60 * SEC)
  t.eq(ramps_off(), 0, "no off after the reload while the hold is live")
  sim.advance(10 * 60 * SEC)
  t.eq(ramps_off(), 0, "still no off inside the 120 min hold")
end)

t.test("2: off enforcement holds a light left on without a manual event (missed feedback)", function()
  sim.reset(1)
  load(22, 28)
  sim.advance(2 * 60 * SEC + 10 * SEC)        -- 22:30:10, scheduled off ramp sent
  t.ok(ramps_off() >= 1, "scheduled off ramp sent")
  sim.sent = {}
  -- no feedback ever arrives: the Control4 variable still reads 40 although DLS sent 0
  sim.advance(10 * 60 * SEC)
  t.eq(ramps_off(), 0, "enforcement held the light instead of re-sending 0")
  t.ok(type(sim.persist.holds) == "table" and sim.persist.holds.Upstairs ~= nil, "the hold was persisted")
end)

t.finish("dls-hold-persist")
