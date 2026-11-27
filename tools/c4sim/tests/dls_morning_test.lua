-- 1.17.0: morning window (lux-gated on window before noon) and lux.targets by time of day.
-- Run: uv run python tools/c4sim/run.py test dls_morning
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local SEC = 1000
local EPOCH = 1767225600
local TOK = "tok"
local LUXDEV, LUXVAR = 603, 1048

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

local function ons(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and (tonumber(s.params.LEVEL) or 0) > 0 then n = n + 1 end
  end
  return n
end
local function offs(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and tonumber(s.params.LEVEL) == 0 then n = n + 1 end
  end
  return n
end

-- Massillon, 1 Jan: sunrise about 07:52 local (the sim runs in the host time zone, Eastern on ixhel).
local function start(at, lux, morning, presenceLighting)
  local rooms = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30",' ..
    '"off_ramp_min":2,"min_level":0,' ..
    '"presence":{"warnLevelPct":0,"graceSec":0,"arrival":false,"follow":false,"offDelaySec":60,"fadeOutSec":5,"sources":["esp"]},' ..
    '"lux":{"dev":603,"var":1048,"target":5},' ..
    '"morning":' .. (morning or '{"target":3}') .. ',' ..
    '"lights":[{"id":101,"kind":"lutron"}]},' ..
    '{"name":"Downstairs","type":"lifx_only","on_daylight":0.3,"off":"23:30","off_ramp_min":2,"min_level":0,' ..
    '"morning":{"target":3,"presence_room":"LivingRoom","dev":603,"var":1048},' ..
    '"lights":[{"id":201,"kind":"lifx"}]}]'
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "30",
    ["Override Hold (min)"] = "5", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "40.8", ["Longitude"] = "-81.5", ["Presence"] = "Home",
    ["Presence Lighting"] = presenceLighting or "Off",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = rooms,
  }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, before = function(s)
    s.set_var(101, 1001, "0"); s.set_var(201, 1001, "0"); s.set_var(LUXDEV, LUXVAR, tostring(lux))
  end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  return ok
end

t.test("M1: dark morning turns the lights on", function()
  start(local_sec(8, 0), 1)
  sim.advance(3 * 60 * SEC)
  t.ok(ons(101) >= 1, "Living Room light on in a dark morning")
  t.ok(ons(201) >= 1, "Downstairs light on (no presence gate with Presence Lighting off)")
end)

t.test("M2: bright morning leaves the lights off", function()
  start(local_sec(8, 0), 10)
  sim.advance(3 * 60 * SEC)
  t.eq(ons(101), 0, "no on when lux is above the morning target")
end)

t.test("M3: outside the window nothing happens", function()
  start(local_sec(6, 0), 1)
  sim.advance(3 * 60 * SEC)
  t.eq(ons(101), 0, "no on before sunrise-30")
end)

t.test("M4: daylight takes over and the room fades off, no re-latch", function()
  start(local_sec(8, 0), 1)
  sim.advance(3 * 60 * SEC)
  t.ok(ons(101) >= 1, "on first")
  sim.set_var(LUXDEV, LUXVAR, "50")
  sim.advance(80 * 60 * SEC)
  t.ok(offs(101) >= 1, "faded off once lux is high and the loop is at min_level")
  sim.set_var(LUXDEV, LUXVAR, "1")
  sim.sent = {}
  sim.advance(10 * 60 * SEC)
  t.eq(ons(101), 0, "no second morning latch the same day")
end)

t.test("M5: presence gate - vacant LivingRoom keeps both rooms dark", function()
  start(local_sec(8, 0), 1, nil, "On")
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "LivingRoom", "0", "esp", TOK))
  sim.advance(3 * 60 * SEC)
  t.eq(ons(101), 0, "vacant Living Room stays dark")
  t.eq(ons(201), 0, "Downstairs gated by the vacant LivingRoom")
end)

t.test("M6: lux.targets picks the latest entry at or before now", function()
  local lx = { target = 5, targets = { { at = "06:00", target = 3 }, { at = "12:00", target = 5 }, { at = "21:00", target = 2 } } }
  t.eq(sim.env.luxTargetFor(lx, 0, 7 * 60, 51.5, -0.1), 3, "morning")
  t.eq(sim.env.luxTargetFor(lx, 0, 14 * 60, 51.5, -0.1), 5, "afternoon")
  t.eq(sim.env.luxTargetFor(lx, 0, 22 * 60, 51.5, -0.1), 2, "late evening")
  t.eq(sim.env.luxTargetFor(lx, 0, 2 * 60, 51.5, -0.1), 2, "after midnight carries the evening entry")
  t.eq(sim.env.luxTargetFor({ target = 5 }, 0, 600, 51.5, -0.1), 5, "no list uses lux.target")
end)

t.finish("dls-morning")
