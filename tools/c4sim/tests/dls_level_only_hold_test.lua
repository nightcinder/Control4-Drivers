-- 1.16.19: presence.manualHold "level" on a follow room. A hand on the dimmer holds brightness only;
-- presence owns on/off (hand-on in a vacant room fades after the off delay, hand-off in an occupied room is re-driven).
-- Run: uv run python tools/c4sim/run.py test dls_level_only_hold
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC = 1000
local EPOCH = 1767225600
local TOK = "tok"

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
local function snapshot(state, src)
  return ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", state, src, TOK)
end
local function offs(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == 0 then n = n + 1 end
  end
  return n
end
local function ons(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and (tonumber(s.params.LEVEL) or 0) > 0 then n = n + 1 end
  end
  return n
end
local function state_of(room)
  local p = sim.persist and sim.persist.presence
  return p and p[room] and p[room].state
end

local function start(at, hold, before)
  local rooms = '[{"name":"Kitchen","key":"Kitchen","on":"18:00","off":"23:00","min_level":60,"max_level":60,' ..
    '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5' ..
    (hold and (',"manualHold":"' .. hold .. '"') or '') .. '},' ..
    '"lights":[{"id":101,"kind":"lutron"}]}]'
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "5", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "51.5", ["Longitude"] = "-0.1", ["Presence"] = "Home", ["Presence Lighting"] = "On",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = rooms,
  }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, before = before })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  return ok
end

t.test("L1: hand-on in a vacant level-only room fades after the off delay", function()
  start(local_sec(20, 0), "level", function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("0", "clear"))
  sim.advance(20 * SEC)
  sim.fire_var(101, VAR, "60")
  sim.sent = {}
  sim.advance(60 * SEC)
  t.ok(offs(101) >= 1, "light switched on by hand while vacant is faded off")
end)

t.test("L1b: same room without manualHold keeps the hand-on (old behaviour)", function()
  start(local_sec(20, 0), nil, function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("0", "clear"))
  sim.advance(20 * SEC)
  sim.fire_var(101, VAR, "60")
  sim.sent = {}
  sim.advance(60 * SEC)
  t.eq(offs(101), 0, "default room holds the hand-on for the 5 min hold")
end)

t.test("L2: hand-off in an occupied level-only room is re-driven, no HOLD", function()
  start(local_sec(20, 0), "level", function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("1", "esp"))
  sim.advance(20 * SEC)
  t.ok(state_of("Kitchen") == "OCCUPIED", "occupied")
  sim.sent = {}
  sim.fire_var(101, VAR, "0")
  t.ok(state_of("Kitchen") ~= "HOLD", "no HOLD state")
  t.ok(ons(101) >= 1, "presence turns the light back on")
end)

t.test("L3: hand dim in an occupied level-only room holds brightness, vacancy still fades", function()
  start(local_sec(20, 0), "level", function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("1", "esp"))
  sim.advance(20 * SEC)
  sim.fire_var(101, VAR, "25")
  sim.sent = {}
  sim.advance(30 * SEC)
  t.eq(ons(101), 0, "brightness hold: no re-drive over the hand level")
  send(snapshot("0", "clear"))
  sim.advance(60 * SEC)
  t.ok(offs(101) >= 1, "vacancy fades the room despite the brightness hold")
end)

t.test("L4: light already on at load in a vacant level-only room fades despite a restored hold", function()
  start(local_sec(20, 0), "level", function(s) s.set_var(101, VAR, "16") end)
  send(snapshot("0", "clear"))
  sim.advance(120 * SEC)
  t.ok(offs(101) >= 1, "stuck light in a vacant level-only room is faded off")
end)

t.test("L9: hand-off while the sensor is already clear (off delay running) is honoured", function()
  start(local_sec(20, 0), "level", function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("1", "esp"))
  sim.advance(20 * SEC)
  t.ok(ons(101) >= 1, "occupied room is lit")
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  sim.advance(2 * SEC)
  sim.sent = {}
  sim.fire_var(101, VAR, "0")
  sim.advance(60 * SEC)
  t.eq(ons(101), 0, "no re-drive after a hand-off with the sensor clear")
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  sim.advance(20 * SEC)
  t.ok(ons(101) >= 1, "next occupancy turns it on again")
end)
t.finish("dls-level-only-hold")
