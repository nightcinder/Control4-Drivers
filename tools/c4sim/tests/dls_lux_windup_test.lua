-- 1.17.7: lux loop windup. Living Room (follow presence room, lux target 5) jumped 30 -> 100 in 2 s at 19:15 when
-- per-light holds expired: the loop integrated while every light was held, the level was lost on reload, the
-- EPP could not reach the target, and schedule passes with lights on used the 2 s walk-in fade.
-- Run: uv run python tools/c4sim/run.py test dls_lux_windup
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local LUXDEV, LUXVAR = 603, 1048
local SEC = 1000
local MIN = 60 * SEC
local EPOCH = 1767225600
local TOK = "tok"
local RAMP_MS = 90000

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000)
  return table.concat(replies)
end
local function ramps(id)
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then
      out[#out + 1] = { level = tonumber(s.params.LEVEL), ms = tonumber(s.params.TIME) }
    end
  end
  return out
end
local function firstOn(id)
  for _, r in ipairs(ramps(id)) do if r.level > 0 then return r end end
  return nil
end
local function maxLevel(id)
  local m = nil
  for _, r in ipairs(ramps(id)) do if not m or r.level > m then m = r.level end end
  return m
end
local function mirror()
  for _, id in ipairs({ 331, 332 }) do
    local r = ramps(id)
    if #r > 0 then sim.set_var(id, VAR, tostring(r[#r].level)) end
  end
end

local ROOMS = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30",' ..
  '"off_ramp_min":30,"window_gain":0.4,"scenes":{"Off":{"off":true}},' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":1200,"fadeInSec":2,"fadeOutSec":30,"nightLevel":5,' ..
  '"nightAfterDark":true,"sources":["esp"]},' ..
  '"lux":{"dev":603,"var":1048,"target":5},' ..
  '"lights":[{"id":331,"kind":"lutron"},{"id":332,"kind":"lutron"}]}]'

local function start(at, lux, lit, persist)
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "5", ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "120", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "40.8", ["Longitude"] = "-81.5", ["Presence"] = "Home",
    ["Presence Lighting"] = "On", ["Debug"] = "On",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
  }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, persist = persist, before = function(s)
    s.set_var(331, VAR, tostring(lit or 0))
    s.set_var(332, VAR, tostring(lit or 0))
    s.set_var(LUXDEV, LUXVAR, tostring(lux))
  end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "LivingRoom", "1", "esp", TOK))
  sim.advance(5 * SEC)
  mirror()
  return ok
end
local function keepOccupied(minutes)
  for _ = 1, minutes do send(ln("OCC", "LivingRoom", "1", "esp", TOK)); sim.advance(MIN); mirror() end
end
local function holds(ids, untilSec)
  local h = {}
  for _, id in ipairs(ids) do h[tostring(id)] = { u = EPOCH + untilSec, o = false } end
  return { holds = { ["Living Room"] = h } }
end
local function saw(pat)
  for _, p in ipairs(sim.prints) do if p:find(pat, 1, true) then return true end end
  return false
end

t.test("a: all lights held 2 h with lux below target: expiry is bumpless and ramps over Ramp Time", function()
  start(local_sec(17, 15), 1, 30, holds({ 331, 332 }, local_sec(19, 15)))
  sim.sent = {}
  keepOccupied(119)
  t.eq(firstOn(331), nil, "no command while held")
  keepOccupied(10)
  local on = firstOn(331)
  print("  a expiry send " .. tostring(on and on.level) .. " ms " .. tostring(on and on.ms))
  t.ok(on ~= nil and math.abs(on.level - 30) <= 2, "expiry send within 2 of the held 30, got " .. tostring(on and on.level))
  if on then t.eq(on.ms, RAMP_MS, "expiry ramps over Ramp Time") end
  t.ok((maxLevel(331) or 0) <= 32, "never above 32, got " .. tostring(maxLevel(331)))
end)

t.test("b: reload with lights at 30 and no hold: first send <= 32", function()
  start(local_sec(20, 0), 3.2, 30, { daylightFired = { ["Living Room"] = "20260101" } })
  keepOccupied(10)
  local on = firstOn(331)
  print("  b first send " .. tostring(on and on.level))
  t.ok(on == nil or on.level <= 32, "first send <= 32, got " .. tostring(on and on.level))
  t.ok((maxLevel(331) or 0) <= 40, "no jump, max " .. tostring(maxLevel(331)))
end)

t.test("c: lux fixed at 3.5 at night: loop latches, never 100", function()
  start(local_sec(19, 0), 3.5, 0)
  keepOccupied(180)
  local m = maxLevel(331)
  print("  c max level " .. tostring(m))
  t.ok(m ~= nil and m < 50, "loop stops well below 100, max " .. tostring(m))
  t.ok(saw("lux loop saturated"), "saturation logged")
end)

t.test("d: lux sensor nil: level unchanged (no revert to the model)", function()
  start(local_sec(19, 0), "unavailable", 30)
  keepOccupied(30)
  local m = maxLevel(331)
  print("  d max level " .. tostring(m))
  t.ok(m == nil or math.abs(m - 30) <= 2, "level stays near 30, max " .. tostring(m))
end)

t.test("e: Away -> Home with lights on: Ramp Time, no jump", function()
  start(local_sec(20, 0), 3.2, 30, { daylightFired = { ["Living Room"] = "20260101" } })
  keepOccupied(5)
  send(ln("PRESENCE", "AWAY", TOK))
  sim.advance(5 * SEC); mirror()
  sim.set_var(331, VAR, "30"); sim.set_var(332, VAR, "30")   -- lights still on at 30 when he comes home
  sim.sent = {}
  send(ln("PRESENCE", "HOME", TOK))
  sim.advance(5 * SEC); mirror()
  keepOccupied(5)
  local r = ramps(331)
  print("  e ramps after home " .. #r .. " max " .. tostring(maxLevel(331)))
  for _, x in ipairs(r) do
    print("    e ramp " .. tostring(x.level) .. " " .. tostring(x.ms))
    t.ok(x.level <= 34, "no jump after Home, got " .. tostring(x.level))
    if x.level > 0 then t.eq(x.ms, RAMP_MS, "Home pass ramps over Ramp Time") end
  end
end)

t.test("f: partial hold: no windup, the held light rejoins at the loop level", function()
  start(local_sec(17, 15), 1, 30, holds({ 331 }, local_sec(19, 15)))
  sim.sent = {}
  keepOccupied(119)
  t.eq(firstOn(331), nil, "held light untouched")
  local m332 = maxLevel(332)
  print("  f free light max " .. tostring(m332))
  t.ok(m332 == nil or m332 < 45, "free light does not wind up, max " .. tostring(m332))
  sim.sent = {}
  keepOccupied(10)
  local on = firstOn(331)
  local cur = tonumber(C4:GetDeviceVariable(332, VAR)) or 30
  print("  f expiry send " .. tostring(on and on.level) .. " free light at " .. tostring(cur))
  t.ok(on == nil or math.abs(on.level - cur) <= 3, "held light rejoins near the free light, got " .. tostring(on and on.level))
  if on then t.eq(on.ms, RAMP_MS, "expiry ramps over Ramp Time") end
end)

t.finish("dls-lux-windup")
