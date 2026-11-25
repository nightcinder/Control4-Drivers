-- DLS 1.16.22 regression: the scheduled off edge beats every hold set before it.
-- Live failure 2026-11-24: Den Lamp (476) got a 120 min per-light hold at about 22:03, the 23:30 off fade
-- skipped it, and it stayed on at 100% until off enforcement turned it off at 00:06.
-- Also covers the per-light "ignore_room_off" flag (room Off scene skips that light, the scheduled off does not).
-- Run: python tools/c4sim/run.py test dls_off_edge_hold
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end

local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local function ramps(id)
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then out[#out + 1] = s.params.LEVEL end
  end
  return out
end
local function has_level(id, level)
  for _, lv in ipairs(ramps(id)) do if lv == level then return true end end
  return false
end
local function has_lt(id, ceiling)
  for _, lv in ipairs(ramps(id)) do if lv < ceiling then return true end end
  return false
end

-- Same shape as the live Downstairs room (2026-11-24): dusk trigger, off 23:30, 30 min stepped fade.
local function rooms(ignore478)
  return '[{"name":"Downstairs","type":"mixed","follow":true,"on_daylight":0.3,"off":"23:30","off_ramp_min":30,' ..
    '"scenes":{"Max":{"levels":{"480":100,"478":100,"476":100}},"Off":{"off":true}},' ..
    '"lights":[{"id":480,"kind":"lifx"},{"id":478,"kind":"lifx"' .. (ignore478 and ',"ignore_room_off":true' or '') ..
    '},{"id":476,"kind":"lifx"}]}]'
end

local function start(ignore478)
  sim.reset(1)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = {
      ["Enabled"] = "On",
      ["Update Interval (min)"] = "1",
      ["Ramp Time (sec)"] = "90",
      ["Override Hold (min)"] = "120",
      ["Scene Hold (min)"] = "240",
      ["Cloud Cover Source"] = "None (assume clear)",
      ["Latitude"] = "40",
      ["Longitude"] = "-75",
      ["Rooms JSON"] = rooms(ignore478),
    },
    start_ms = local_sec(21, 50) * SEC,
    before = function(s)
      s.set_var(480, VAR, "40")
      s.set_var(478, VAR, "40")
      s.set_var(476, VAR, "40")
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(2 * MIN)                                 -- 21:52: first updates ran, room is in its on window
end

t.test("1: a per-light hold set at 22:03 does not stop the 23:30 off fade (2026-11-24 Den Lamp)", function()
  start(false)
  sim.advance(11 * MIN)                                -- 22:03
  sim.set_var(476, VAR, "100")                         -- something outside DLS puts the lamp at 100%
  sim.fire_var(476, VAR, "100")
  local h = sim.persist.holds and sim.persist.holds.Downstairs and sim.persist.holds.Downstairs["476"]
  t.ok(h ~= nil, "the change is taken as manual and held")
  sim.sent = {}
  sim.advance(86 * MIN)                                -- 23:29, still in the on window
  t.eq(#ramps(476), 0, "476 untouched while held inside the on window")
  sim.advance(3 * MIN)                                 -- 23:32
  t.ok(has_lt(476, 100), "476 is in the off fade right after 23:30")
  sim.advance(30 * MIN)                                -- 00:02, before the old hold (00:03) would expire
  t.ok(has_level(476, 0), "476 reached 0 by the fade, not by enforcement at hold expiry")
  t.ok(has_level(480, 0), "480 reached 0")
  local h2 = sim.persist.holds and sim.persist.holds.Downstairs and sim.persist.holds.Downstairs["476"]
  t.ok(h2 == nil, "the pre-edge hold is gone from PersistData")
end)

t.test("2: a hand-on after the off edge still holds (1.11.2/1.11.6 behaviour)", function()
  start(false)
  sim.advance(102 * MIN)                               -- 23:34, fade running
  sim.advance(30 * MIN)                                -- 00:04, fade done
  t.ok(has_level(476, 0), "476 faded to 0")
  sim.set_var(476, VAR, "0")
  sim.fire_var(476, VAR, "0")
  sim.advance(6 * MIN)                                 -- 00:10
  sim.set_var(476, VAR, "30")                          -- hand on after the edge
  sim.fire_var(476, VAR, "30")
  sim.sent = {}
  sim.advance(12 * MIN)
  t.eq(#ramps(476), 0, "no off re-sent while the after-edge manual hold is active")
end)

t.test("3: room Off scene skips an ignore_room_off light; the 23:30 off still takes it", function()
  start(true)
  sim.advance(18 * MIN)                                -- 22:10
  sim.sent = {}
  sim.exec("ApplyScene", { ROOM = "Downstairs", SCENE = "Off" })
  t.ok(has_level(480, 0), "480 off by the Off scene")
  t.ok(has_level(476, 0), "476 off by the Off scene")
  t.eq(#ramps(478), 0, "478 (ignore_room_off) not sent anything by the Off scene")
  sim.set_var(480, VAR, "0")
  sim.set_var(476, VAR, "0")
  sim.sent = {}
  sim.advance(79 * MIN)                                -- 23:29
  t.eq(#ramps(478), 0, "478 left alone until the off edge")
  t.eq(#ramps(476), 0, "476 stays off (Off scene hold)")
  sim.advance(34 * MIN)                                -- 00:03
  t.ok(has_lt(478, 40), "478 faded after 23:30")
  t.ok(has_level(478, 0), "478 reached 0 at the scheduled off")
  t.ok(not has_lt(476, 0) and not has_lt(480, 0), "no bad levels")
end)

t.test("4: without the flag the Off scene turns every light off", function()
  start(false)
  sim.advance(18 * MIN)
  sim.sent = {}
  sim.exec("ApplyScene", { ROOM = "Downstairs", SCENE = "Off" })
  t.ok(has_level(478, 0), "478 off by the Off scene")
end)

t.test("5: a scene (Max) applied before the edge does not stop the 23:30 off fade", function()
  start(false)
  sim.advance(68 * MIN)                                -- 23:00
  sim.exec("ApplyScene", { ROOM = "Downstairs", SCENE = "Max" })
  sim.set_var(476, VAR, "100")
  sim.sent = {}
  sim.advance(29 * MIN)                                -- 23:29
  t.eq(#ramps(476), 0, "scene holds inside the on window")
  sim.advance(33 * MIN)                                -- 00:02
  t.ok(has_level(476, 0), "476 faded to 0 although the 240 min scene hold had not expired")
end)

t.finish("dls-off-edge-hold")
