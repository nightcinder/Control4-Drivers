-- DLS regression: a long scheduled off (off_ramp_min) is stepped by the driver, 60 s at a time.
-- On 2026-11-18 the Den's 30-minute off reached the Chair Lamp as one RAMP_TO_LEVEL 0 TIME=1800000 and
-- the bulb went out instantly (trace: on 20% at 23:47:15, off 20% at 23:47:30). DLS now sends one step
-- per minute with a matching ramp time, so no light is asked to glide for more than 60 s.
-- Run: python tools/c4sim/run.py test dls_off_fade
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

-- Load at 23:44:00, let the first settling update drive the room, put the light at 20% and start the
-- clock just before the 23:45 off edge with nothing recorded yet.
local function load(rooms)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Presence Lighting"] = "Off", ["Update Interval (min)"] = "1",
                   ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = "40", ["Longitude"] = "-75" },
    start_ms = local_sec(23, 44) * SEC,
    before = function(s) s.set_var(U, VAR, "20") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(20 * SEC)                                  -- the 15 s settling update has run
  sim.set_var(U, VAR, "20")
  sim.fire_var(U, VAR, "20")
  sim.sent = {}
end

local function levels()
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == U and s.cmd == "RAMP_TO_LEVEL" then out[#out + 1] = s.params.LEVEL end
  end
  return out
end

local function max_time()
  local m = 0
  for _, s in ipairs(sim.sent) do
    if s.id == U and s.cmd == "RAMP_TO_LEVEL" then m = math.max(m, tonumber(s.params.TIME) or 0) end
  end
  return m
end

t.test("a 30-minute off is stepped: one level per minute, never a 30-minute TIME", function()
  sim.reset(1)
  load('[{"name":"Den","on":"18:00","off":"23:45","off_ramp_min":30,"lights":[{"id":337,"kind":"lutron"}]}]')
  sim.advance(60 * SEC)                                  -- past the 23:45 edge
  t.ok(#levels() >= 1, "first fade step sent")
  t.eq(levels()[1], 19, "first step is one step below the starting level")
  t.ok(max_time() <= 60000, "no command asks for more than 60 s")
  sim.sent = {}
  sim.advance(5 * 60 * SEC)                              -- five more steps
  local ls = levels()
  t.ok(#ls >= 3, "the fade keeps stepping")
  local prev = 20
  for _, lvl in ipairs(ls) do
    t.ok(lvl > 0, "still above 0 six minutes in")
    t.ok(lvl < prev, "each step is lower than the one before")
    prev = lvl
  end
  sim.sent = {}
  sim.advance(24 * 60 * SEC)                             -- 00:15:00, past the last step at 00:14:00
  local last = levels()
  t.ok(#last >= 1, "final step sent")
  t.eq(last[#last], 0, "the fade ends at 0")
  t.ok(max_time() <= 60000, "every step is a 60 s ramp")
  sim.set_var(U, VAR, "0")                               -- the light has obeyed; no feedback event needed
  sim.sent = {}
  sim.advance(10 * 60 * SEC)
  t.eq(#levels(), 0, "no more steps after the fade finished")
end)

t.test("a hand on the dimmer takes that light out of the fade", function()
  sim.reset(1)
  load('[{"name":"Den","on":"18:00","off":"23:45","off_ramp_min":30,"lights":[{"id":337,"kind":"lutron"}]}]')
  sim.advance(5 * 60 * SEC)                              -- fade running
  sim.set_var(U, VAR, "80")                              -- someone raises it by hand
  sim.fire_var(U, VAR, "80")
  sim.sent = {}
  sim.advance(30 * 60 * SEC)
  for _, s in ipairs(sim.sent) do
    t.ok(not (s.id == U and s.cmd == "RAMP_TO_LEVEL"), "the held light is not stepped or re-sent to 0")
  end
end)

t.test("a short off_ramp_min stays a single command", function()
  sim.reset(1)
  load('[{"name":"Den","on":"18:00","off":"23:45","off_ramp_min":1,"lights":[{"id":337,"kind":"lutron"}]}]')
  sim.advance(60 * SEC)
  local ls = levels()
  t.eq(#ls, 1, "one command, no stepping")
  t.eq(ls[1], 0, "straight to 0")
  t.eq(max_time(), 60000, "over the configured minute")
end)

t.test("a light that is already off is not faded up at the off edge", function()
  sim.reset(1)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Presence Lighting"] = "Off", ["Update Interval (min)"] = "1",
                   ["Ramp Time (sec)"] = "90", ["Override Hold (min)"] = "1", ["Rooms JSON"] =
                   '[{"name":"Den","on":"18:00","off":"19:00","off_ramp_min":30,"lights":[{"id":337,"kind":"lutron"}]}]',
                   ["Latitude"] = "40", ["Longitude"] = "-75" },
    start_ms = local_sec(18, 0, 30) * SEC,
    before = function(s) s.set_var(U, VAR, "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(30 * SEC)                                  -- settling update drove it, lastLevel is now set
  sim.sent = {}
  sim.set_var(U, VAR, "0")                               -- hand off: lastLevel stays, the bulb is dark
  sim.fire_var(U, VAR, "0")
  sim.advance(90 * SEC)                                  -- override hold (1 min) expires
  sim.advance(56 * 60 * SEC)                             -- past the 19:00 off edge
  t.eq(#levels(), 0, "no nonzero step re-lights a light that is off")
  sim.set_var(U, VAR, "30")                              -- a light found on with no fade running
  sim.sent = {}
  sim.advance(6 * 60 * SEC)
  t.ok(#levels() >= 1 and levels()[#levels()] == 0, "off enforcement is not suppressed when no fade started")
end)

t.test("OnDriverDestroyed cancels a running fade", function()
  sim.reset(1)
  load('[{"name":"Den","on":"18:00","off":"23:45","off_ramp_min":30,"lights":[{"id":337,"kind":"lutron"}]}]')
  sim.advance(3 * 60 * SEC)                              -- fade running
  sim.call("OnDriverDestroyed")
  sim.sent = {}
  sim.advance(20 * 60 * SEC)
  t.eq(#levels(), 0, "no step timer outlives the driver")
end)

t.test("presence away during a stepped fade finishes at 0, not at the floor", function()
  sim.reset(1)
  load('[{"name":"Den","on":"18:00","off":"23:45","off_ramp_min":30,"lights":[{"id":337,"kind":"lutron"}]}]')
  sim.advance(5 * 60 * SEC)                              -- fade running, still above 0
  sim.sent = {}
  sim.exec("SetPresence", { PRESENT = "Away" })          -- 1.16.17: the stall case, cancelled mid-fade
  sim.advance(2 * 60 * SEC)
  local ls = levels()
  t.ok(#ls >= 1, "a command goes out after presence away")
  t.eq(ls[#ls], 0, "the fade ends at 0, not stranded above 0")
  sim.sent = {}
  sim.advance(10 * 60 * SEC)
  t.eq(#levels(), 0, "no steps after the final 0")
end)

t.finish("dls-off-fade")
