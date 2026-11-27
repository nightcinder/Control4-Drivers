-- DLS 1.17.9: dim-to-warn before the vacancy off fade, grace restore after it, and arrival lighting.
-- Run: python tools/c4sim/run.py test dls_warn_arrival
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local TOK = "tok"
local PORT = "8730"
local K = 101
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

-- Defaults on purpose: warnLevelPct 50, warnSec 60, graceSec 120, arrival on (follow room without levels).
local ROOMS = '[{"name":"Kitchen","key":"Kitchen","min_level":60,"max_level":60,' ..
  '"presence":{"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'

local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000)
  return table.concat(replies)
end
local function clear() sim.sent = {} end
local function ramp(id, level, ms)
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == level and (ms == nil or s.params.TIME == ms) then
      return true
    end
  end
  return false
end
local function any_ramp(id)
  for _, s in ipairs(sim.sent) do if s.id == id and s.cmd == "RAMP_TO_LEVEL" then return true end end
  return false
end
local function state_of(room)
  local p = sim.persist and sim.persist.presence
  return p and p[room] and p[room].state
end
local function adv(sec) sim.advance(sec * SEC) end
local function feed(level) sim.fire_var(K, VAR, level) end

-- Sun position follows the host time zone (sim local time). Equator at the host's own meridian: local noon is
-- solar noon (sun high), local 23:45 is night, whatever the host's zone.
local HOST_OFF_H = (os.time(realdate("*t", EPOCH)) - os.time(realdate("!*t", EPOCH))) / 3600
local SUN_LON = tostring(HOST_OFF_H * 15)

local function start(at, rooms, lat, lon)
  local props = { ["Presence Lighting"] = "On", ["Presence Port"] = PORT, ["Presence Token"] = TOK,
    ["Rooms JSON"] = rooms or ROOMS, ["Presence"] = "Home", ["Latitude"] = lat or "51.5", ["Longitude"] = lon or "-0.1",
    ["Debug"] = "On" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, start_ms = (at or local_sec(12, 0)) * SEC,
    before = function(s) s.set_var(K, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", "0", "clear", TOK))
  clear()
  return ok
end

local function occupy_then_leave()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(2)
  feed(60)
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  clear()
  adv(181)
end

t.test("w1 vacancy delay ends with a dim to 50% for 60 s, then the off fade", function()
  start()
  occupy_then_leave()
  t.ok(ramp(K, 30, 1000), "dim to 30 (50% of 60) over 1 s")
  t.ok(not ramp(K, 0), "no off yet")
  t.eq(state_of("Kitchen"), "FADING", "FADING during the warn")
  feed(30)
  clear()
  adv(58)
  t.ok(not any_ramp(K), "nothing during the warn")
  adv(3)
  t.ok(ramp(K, 0, 30000), "off fade over 30 s after the warn")
  adv(33)
  t.eq(state_of("Kitchen"), "VACANT", "VACANT after the fade")
end)

t.test("w2 occupancy during the warn restores the previous level at once", function()
  start()
  occupy_then_leave()
  feed(30)
  clear()
  adv(20)
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(ramp(K, 60, 500), "back to 60 over 0.5 s")
  t.eq(state_of("Kitchen"), "OCCUPIED", "OCCUPIED again")
  clear()
  adv(120)
  t.ok(not ramp(K, 0), "no off fade after the restore")
end)

t.test("w3 occupancy within the 120 s grace restores the previous level", function()
  start()
  occupy_then_leave()
  feed(30)
  adv(61)
  adv(33)
  feed(0)
  t.eq(state_of("Kitchen"), "VACANT", "VACANT")
  clear()
  adv(60)
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(ramp(K, 60, 500), "grace: previous level 60 at once")
  t.eq(state_of("Kitchen"), "OCCUPIED", "OCCUPIED")
end)

t.test("w4 after the grace a walk-in is a normal walk-in ramp", function()
  start()
  occupy_then_leave()
  feed(30)
  adv(61)
  adv(33)
  feed(0)
  adv(125)
  clear()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(ramp(K, 60, 2000), "walk-in ramp over fadeInSec 2 s")
  t.ok(not ramp(K, 60, 500), "not the grace restore")
end)

t.test("w5 warnLevelPct 0 turns the warn off", function()
  start(nil, ROOMS:gsub('"follow":true', '"follow":true,"warnLevelPct":0'))
  occupy_then_leave()
  t.ok(ramp(K, 0, 30000), "straight to the off fade")
end)

-- Arrival: Kitchen with an on window 06:00-23:00, so 23:45 is outside it (late level, held for the off delay).
local ROOMS_WIN = ROOMS:gsub('"key":"Kitchen","min_level"', '"key":"Kitchen","on":"06:00","off":"23:00","min_level"')

local function arrive()
  send(ln("PRESENCE", "AWAY", TOK))
  adv(5)
  clear()
  sim.prints = {}
  send(ln("PRESENCE", "HOME", TOK))
end
local function printed(s)
  for _, p in ipairs(sim.prints or {}) do if tostring(p):find(s, 1, true) then return true end end
  return false
end

t.test("a1 dark late arrival lights the room at nightLevel, holds it, then warns after the off delay", function()
  start(local_sec(23, 45), ROOMS_WIN, "0", SUN_LON)
  arrive()
  t.ok(ramp(K, 20, 2000), "arrival: night level 20 after the 23:00 off time")
  t.eq(state_of("Kitchen"), "OCCUPIED", "handed to presence as OCCUPIED")
  t.ok(printed("arrival lighting room Kitchen level 20"), "log line 'arrival lighting room Kitchen level 20'")
  feed(20)
  clear()
  adv(170)
  t.ok(not ramp(K, 60), "the arrival level is held, not replaced by the schedule")
  adv(11)
  t.ok(ramp(K, 10, 1000), "nobody seen: dim-to-warn (50% of 20) after the off delay")
end)

t.test("a2 arrival with the sun up does nothing", function()
  start(local_sec(12, 0), ROOMS_WIN, "0", SUN_LON)
  arrive()
  t.ok(not any_ramp(K), "no arrival lighting at solar noon")
  t.eq(state_of("Kitchen"), "VACANT", "stays VACANT")
end)

t.test("a3 arrival false in the room config turns it off", function()
  start(local_sec(23, 45), ROOMS_WIN:gsub('"follow":true', '"follow":true,"arrival":false'), "0", SUN_LON)
  arrive()
  t.ok(not any_ramp(K), "no arrival lighting")
  t.eq(state_of("Kitchen"), "VACANT", "stays VACANT")
end)

t.test("a4 arrival lateLevel and lateAfter from the room config", function()
  start(local_sec(22, 30), ROOMS_WIN:gsub('"follow":true',
    '"follow":true,"arrival":{"lateLevel":7,"lateAfter":"22:00","level":45}'), "0", SUN_LON)
  arrive()
  t.ok(ramp(K, 7, 2000), "late level 7 after lateAfter 22:00")
end)

t.test("a5 occupied arrival room is lit by presence, not twice by arrival", function()
  start(local_sec(23, 45), ROOMS_WIN, "0", SUN_LON)
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(2)
  arrive()
  t.ok(not printed("arrival lighting room"), "no arrival line when the room was already lit")
end)

t.finish("dls-warn-arrival")
