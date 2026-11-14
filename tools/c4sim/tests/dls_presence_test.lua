-- DLS follow-me presence tests (package C). Written from docs/room-presence-dls-interface.md,
-- TEST CASES 1-24 (DLS part only; poller cases 25-35 are package A's Python tests).
-- Run from anywhere: python tools/c4sim/run.py test dls_presence
-- Assumptions, to check against the driver when it lands (each is one helper, marked ASSUMED):
--   * server hooks (C4:ServerSend, C4:ServerCloseClient, OnServerDataIn injection) are defined here;
--   * per-room state is read from PersistData key "presence" as {state=...} (state_of);
--   * light level bounds for the target fixture are per-light min_level / max_level (cases 22);
--   * the time-of-day fixture puts Kitchen's off window around 23:30 (case 21).
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
-- Driver test hook: send device commands at once instead of one per 250 ms queue tick.
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local TOK = "tok"
local PORT = "8730"
local K, M = 101, 201        -- Kitchen light, MasterBed light
local VAR = 1001             -- LIGHT_LEVEL
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600     -- sim.epoch (2026-01-01 UTC)

-- Local clock: sim time 0 = EPOCH. os.date() with no time argument follows the sim clock.
local function local_sec(h, m)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local ROOMS = '[{"name":"Kitchen","key":"Kitchen","min_level":60,"max_level":60,"presence":{"follow":true,"offDelaySec":180,"robotOffDelaySec":90,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp","robot"]},"lights":[{"id":101,"kind":"lutron"}]},{"name":"MasterBed","key":"MasterBed","presence":{"follow":false},"lights":[{"id":201,"kind":"lutron"}]}]'

-- Server hooks: the driver answers each line with C4:ServerSend and then C4:ServerCloseClient.
local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end

local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end

-- Feed raw TCP data to OnServerDataIn; return the reply text for this call only.
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "10.0.0.5", 50000)
  return table.concat(replies)
end

local function snapshot(kstate, ksrc)
  return ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "2", TOK)
    .. ln("OCC", "Kitchen", kstate, ksrc, TOK) .. ln("OCC", "MasterBed", "0", "clear", TOK)
end

local function clear() sim.sent = {} end

local function ramp(id, level, ms)
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == level and s.params.TIME == ms then
      return true
    end
  end
  return false
end

local function any_ramp(id)
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then return true end
  end
  return false
end

local function sent_count(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id then n = n + 1 end
  end
  return n
end

-- ASSUMED: per-room state lives in PersistData under "presence".
local function state_of(room)
  local p = sim.persist and sim.persist.presence
  return p and p[room] and p[room].state
end

local function adv(sec) sim.advance(sec * SEC) end
local function feed(light, level) sim.fire_var(light, VAR, level) end

local function start(o)
  o = o or {}
  local props = { ["Presence Port"] = PORT, ["Presence Token"] = o.token or TOK,
    ["Rooms JSON"] = o.rooms or ROOMS, ["Presence"] = "Home",
    ["Latitude"] = "51.5", ["Longitude"] = "-0.1" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, persist = o.persist,
    start_ms = (o.at or local_sec(12, 0)) * SEC,
    before = function(s) s.set_var(K, VAR, "0"); s.set_var(M, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  if not o.nosnap then send(snapshot("0", "clear")) end
  clear()
  return ok
end

-- Reload keeps PersistData and the simulated clock (T14 path).
local function reload(o)
  o = o or {}
  o.persist = sim.persist
  o.at = o.at or math.floor(sim.now_ms / SEC)
  return start(o)
end

local ROOMS_N0 = ROOMS:gsub('"nightLevel":20', '"nightLevel":0')
local ROOMS_T0 = ROOMS:gsub('"id":101,"kind":"lutron"', '"id":101,"kind":"lutron","min_level":0,"max_level":0')
local ROOMS_T30 = ROOMS:gsub('"id":101,"kind":"lutron"', '"id":101,"kind":"lutron","min_level":30,"max_level":30')
-- Kitchen has an off window that starts at 23:00, so 23:30 is inside it (nightLevel applies).
local ROOMS_NIGHT = ROOMS:gsub('"key":"Kitchen","min_level"', '"key":"Kitchen","on":"06:00","off":"23:00","min_level"')

t.test("c1 OCC 1 ramps to target; 0 clear fades after 180 s", function()
  start()
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", TOK)), "OK\r\n", "reply")
  t.ok(ramp(K, 60, 2000), "ramp to 60 over 2 s")
  t.eq(state_of("Kitchen"), "OCCUPIED", "state OCCUPIED")
  clear()
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(179)
  t.ok(not any_ramp(K), "no fade at 179 s")
  adv(2)
  t.ok(ramp(K, 0, 30000), "fade to 0 over 30 s at 181 s")
  t.eq(state_of("Kitchen"), "FADING", "state FADING")
  adv(32)
  t.eq(state_of("Kitchen"), "VACANT", "state VACANT")
end)

t.test("c3 vacancy then re-entry inside the off delay cancels the fade", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(100)
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(300)
  t.ok(not ramp(K, 0, 30000), "no ramp to 0")
  t.eq(state_of("Kitchen"), "OCCUPIED", "still OCCUPIED")
end)

t.test("c4 re-entry during FADING ramps back up", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(185)
  t.eq(state_of("Kitchen"), "FADING", "FADING at +185 s")
  clear()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(ramp(K, 60, 2000), "ramp back to 60")
  t.eq(state_of("Kitchen"), "OCCUPIED", "OCCUPIED")
end)

t.test("c5 robot-only occupancy uses robotOffDelaySec (90 s)", function()
  start()
  send(ln("OCC", "Kitchen", "1", "robot", TOK))
  clear()
  send(ln("OCC", "Kitchen", "0", "dock", TOK))
  adv(89)
  t.ok(not ramp(K, 0, 30000), "no fade at 89 s")
  adv(2)
  t.ok(ramp(K, 0, 30000), "fade at 91 s")
end)

t.test("c6 follow=false room never turns on from OCC but still fades off", function()
  start()
  t.eq(send(ln("OCC", "MasterBed", "1", "esp", TOK)), "OK\r\n", "reply")
  t.ok(not any_ramp(M), "no ramp on")
  t.eq(state_of("MasterBed"), "OCCUPIED", "OCCUPIED")
  feed(M, 50)
  clear()
  send(ln("OCC", "MasterBed", "0", "clear", TOK))
  adv(181)
  t.ok(ramp(M, 0, 30000), "MasterBed fades off")
end)

t.test("c7 wrong or empty token gives ERR AUTH and no ramp", function()
  start()
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", "bad")), "ERR AUTH\r\n", "wrong token")
  t.ok(not any_ramp(K), "no ramp on bad token")
  start({ token = "", nosnap = true })
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", "x")), "ERR AUTH\r\n", "empty property rejects all")
  t.ok(not any_ramp(K), "no ramp with empty token")
end)

t.test("c8 unknown room and bad syntax are rejected", function()
  start()
  t.eq(send(ln("OCC", "Garage", "1", "esp", TOK)), "ERR ROOM\r\n", "unknown room")
  t.eq(send(ln("OCC", "Kitchen", "2", "esp", TOK)), "ERR SYNTAX\r\n", "state 2")
  t.eq(send(ln("OCC", "Kitchen", "1", TOK)), "ERR SYNTAX\r\n", "missing src")
end)

t.test("c9 PRESENCE AWAY still works (v1.10.1 regression)", function()
  start()
  t.eq(send(ln("PRESENCE", "AWAY", TOK)), "OK\r\n", "reply")
  t.eq(sim.Properties["Presence"], "Away", "Presence = Away")
end)

t.test("c10 batch: PRESENCE, HELLO and two OCC lines in one write", function()
  start({ nosnap = true })
  local r = send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "100", "2", TOK)
    .. ln("OCC", "Kitchen", "1", "esp", TOK) .. ln("OCC", "MasterBed", "0", "clear", TOK))
  t.eq(r, "OK\r\nOK\r\nOK\r\nOK\r\n", "four OK in order")
  t.ok(ramp(K, 60, 2000), "ramp to 60")
end)

t.test("c11 first OCC after a fresh load gets OK RESYNC, then OK after a snapshot", function()
  start({ nosnap = true })
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", TOK)), "OK RESYNC\r\n", "resync")
  send(snapshot("1", "esp"))
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", TOK)), "OK\r\n", "plain OK")
end)

t.test("c12 feed lost after 180 s of silence; heartbeats prevent the fade", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  clear()
  adv(181)
  t.ok(string.find(tostring(sim.Properties["Status"]), "Presence feed lost", 1, true) ~= nil, "status shows feed lost")
  adv(180)
  t.ok(ramp(K, 0, 30000), "fade at 361 s")

  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  clear()
  for _ = 1, 10 do
    adv(60)
    send(snapshot("1", "esp"))
  end
  t.ok(not ramp(K, 0, 30000), "no fade while heartbeats arrive")
end)

t.test("c13 manual off enters HOLD; vacancy ends it; re-entry ramps again", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(15)
  clear()
  feed(K, 0)
  t.eq(state_of("Kitchen"), "HOLD", "HOLD after manual off")
  t.ok(not any_ramp(K), "no ramp in HOLD")
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(3 * 3600)
  t.ok(not any_ramp(K), "no ramp while occupied for 3 h")
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(181)
  t.eq(state_of("Kitchen"), "VACANT", "VACANT after vacancy")
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(ramp(K, 60, 2000), "ramp on at re-entry")
end)

t.test("c14 manual level change in HOLD brings the room back to OCCUPIED", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(15)
  feed(K, 0)
  clear()
  feed(K, 40)
  t.eq(state_of("Kitchen"), "OCCUPIED", "OCCUPIED")
  t.ok(not any_ramp(K), "no ramp")
end)

t.test("c15 per-light hold does not block vacancy", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(15)
  clear()
  feed(K, 90)
  t.ok(not any_ramp(K), "manual change gives a hold, no ramp")
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(181)
  t.ok(ramp(K, 0, 30000), "vacancy fades despite the hold")
end)

t.test("c16 ramp-tracking levels inside the ignore window are not a hold", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(2)
  clear()
  feed(K, 20)
  sim.advance(500)
  feed(K, 40)
  sim.advance(500)
  feed(K, 60)
  t.eq(state_of("Kitchen"), "OCCUPIED", "still OCCUPIED")
  t.ok(not any_ramp(K), "no DLS ramp caused by own feedback")
end)

t.test("c17 manual change during FADING holds the light and goes OCCUPIED", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(190)
  t.eq(state_of("Kitchen"), "FADING", "FADING at +10 s into fade")
  clear()
  feed(K, 100)
  t.eq(state_of("Kitchen"), "OCCUPIED", "OCCUPIED")
  adv(60)
  t.ok(not any_ramp(K), "no further ramp for light 101")
end)

t.test("c18 AWAY filter: esp ignored, robot counts; HOME rule via src", function()
  start()
  t.eq(send(ln("PRESENCE", "AWAY", TOK)), "OK\r\n", "AWAY")
  clear()
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", TOK)), "OK\r\n", "reply")
  t.ok(not any_ramp(K), "no ramp for esp while AWAY")
  t.eq(state_of("Kitchen"), "VACANT", "VACANT")
  t.eq(send(ln("OCC", "Kitchen", "1", "esp,robot", TOK)), "OK\r\n", "reply robot")
  t.ok(ramp(K, 60, 2000), "robot ramps on")
  clear()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(91)
  t.ok(ramp(K, 0, 30000), "fade at 91 s (robot delay)")
end)

t.test("c19 PRESENCE AWAY ends occupancy at once when no robot is present", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  clear()
  send(ln("PRESENCE", "AWAY", TOK))
  t.ok(ramp(K, 0, 30000), "fade starts with no 180 s wait")
end)

t.test("c20 PRESENCE HOME re-evaluates the last src without a new OCC line", function()
  start()
  send(ln("PRESENCE", "AWAY", TOK))
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  clear()
  send(ln("PRESENCE", "HOME", TOK))
  t.ok(ramp(K, 60, 2000), "ramp on at HOME")
end)

t.test("c21 occupied inside the off window uses nightLevel; 0 keeps it dark", function()
  start({ at = local_sec(23, 30), rooms = ROOMS_NIGHT })
  clear()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(ramp(K, 20, 2000), "night level 20")

  start({ at = local_sec(23, 30), rooms = ROOMS_NIGHT:gsub('"nightLevel":20', '"nightLevel":0') })
  clear()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(5 * 60)
  t.ok(not any_ramp(K), "nightLevel 0: no ramp and no enforcement sends")
end)

t.test("c22 daytime target 0 keeps lights off; raising the target ramps on", function()
  start({ rooms = ROOMS_T0, nosnap = true })
  send(snapshot("1", "esp"))
  clear()
  t.eq(state_of("Kitchen"), "OCCUPIED", "OCCUPIED at target 0")
  t.ok(not any_ramp(K), "no ramp at target 0")
  reload({ rooms = ROOMS_T30, nosnap = true })
  send(snapshot("1", "esp"))
  t.ok(ramp(K, 30, 2000), "ramp to 30 after target raised")
end)

t.test("c23 bad values fall back to defaults; duplicate key disables the later room", function()
  local rooms23 = '[{"name":"Kitchen","key":"kitchen","min_level":60,"max_level":60,"presence":{"offDelaySec":"x","fadeOutSec":999,"follow":true},"lights":[{"id":101,"kind":"lutron"}]},{"name":"Kitchen2","key":"Kitchen","presence":{"follow":true},"lights":[{"id":201,"kind":"lutron"}]}]'
  start({ rooms = rooms23, nosnap = true })
  send(ln("HELLO", "1", "0", TOK))
  clear()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(ramp(K, 60, 2000), "room 1 ramps on")
  t.ok(not any_ramp(M), "duplicate-key room gets nothing")
  clear()
  send(ln("OCC", "kitchen", "0", "clear", TOK))
  adv(179)
  t.ok(not any_ramp(K), "default 180 s off delay")
  adv(2)
  t.ok(ramp(K, 0, 30000), "default 30 s fade")
  t.ok(string.find(tostring(sim.Properties["Status"]), "Rooms JSON warning", 1, true) ~= nil, "warning in Status")
end)

t.test("c24 legacy top-level follow with no presence object gives ERR ROOM", function()
  local rooms24 = '[{"name":"Kitchen","key":"Kitchen","follow":true,"lights":[{"id":101,"kind":"lutron"}]}]'
  start({ rooms = rooms24, nosnap = true })
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", TOK)), "ERR ROOM\r\n", "ERR ROOM")
  t.ok(not any_ramp(K), "schedule-follow path unchanged, no OCC effect")
end)

t.finish("dls-presence")
