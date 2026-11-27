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

local ROOMS = '[{"name":"Kitchen","key":"Kitchen","min_level":60,"max_level":60,"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"robotOffDelaySec":90,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp","robot"]},"lights":[{"id":101,"kind":"lutron"}]},{"name":"MasterBed","key":"MasterBed","presence":{"graceSec":0,"arrival":false,"follow":false},"lights":[{"id":201,"kind":"lutron"}]}]'

-- Server hooks: the driver answers each line with C4:ServerSend and then C4:ServerCloseClient.
local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end

local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end

-- Feed raw TCP data to OnServerDataIn; return the reply text for this call only.
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000)
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
  local props = { ["Presence Lighting"] = "On", ["Presence Port"] = PORT, ["Presence Token"] = o.token or TOK,
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


local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

t.test("xA M2: HOLD restored, vacant snapshot, next entry must light", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(15)
  feed(K, 0)
  t.eq(state_of("Kitchen"), "HOLD", "HOLD")
  reload({ nosnap = true })
  t.eq(state_of("Kitchen"), "HOLD", "HOLD restored (persist)")
  send(snapshot("0", "clear"))
  print("   state right after vacant snapshot: " .. tostring(state_of("Kitchen")))
  adv(181)
  t.eq(state_of("Kitchen"), "VACANT", "VACANT after confirmed clear + delay")
  clear()
  t.eq(send(ln("OCC", "Kitchen", "1", "esp", TOK)), "OK\r\n", "reply")
  t.ok(ramp(K, 60, 2000), "entry after reload ramps on")
end)

t.test("xB H3 on reload: restored HOLD survives no feed and unknown", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(15)
  feed(K, 0)
  reload({ nosnap = true })
  adv(400)
  t.eq(state_of("Kitchen"), "HOLD", "HOLD kept with no feed after reload")
  clear()
  send(snapshot("1", "esp"))
  t.ok(not any_ramp(K), "no ramp when feed returns")
  t.eq(state_of("Kitchen"), "HOLD", "still HOLD")
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(15)
  feed(K, 0)
  reload({ nosnap = true })
  send(snapshot("0", "unknown"))
  adv(400)
  send(snapshot("0", "unknown"))
  t.eq(state_of("Kitchen"), "HOLD", "HOLD kept on 0 unknown snapshot after reload")
  clear()
  send(snapshot("1", "esp"))
  t.ok(not any_ramp(K), "no ramp")
end)

t.test("xC M4: Vacancy Delay change must not fade an occupied room", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(2)
  feed(K, 60)
  clear()
  setprop("Vacancy Delay (min)", "11")
  adv(40)
  t.ok(not ramp(K, 0, 30000), "no fade before the next heartbeat")
  send(snapshot("1", "esp"))
  adv(5)
  t.ok(not ramp(K, 0, 30000), "no fade after heartbeat")
  t.eq(state_of("Kitchen"), "OCCUPIED", "OCCUPIED")
  clear()
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(181)
  t.ok(ramp(K, 0, 30000), "vacancy still fades")
end)

t.test("xD Enabled=Off: no vacant-sweep fade", function()
  start()
  sim.Properties["Enabled"] = "Off"
  sim.set_var(K, VAR, "50")
  adv(10)
  t.ok(not any_ramp(K), "no ramp while disabled")
end)

t.test("xE H1: manual off 5 s after auto-on, and mid-ramp", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(5)
  feed(K, 0)
  t.eq(state_of("Kitchen"), "HOLD", "HOLD at +5 s")
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  sim.advance(500)
  feed(K, 30)
  sim.advance(500)
  feed(K, 0)
  t.eq(state_of("Kitchen"), "HOLD", "HOLD mid-ramp")
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(1)
  feed(K, 0)
  print("   off at +1 s with no earlier feedback: " .. tostring(state_of("Kitchen")))
end)

t.test("xG H2: light on again after fade with missed feedback is adopted, later faded", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(2)
  feed(K, 60)
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(186)
  t.eq(state_of("Kitchen"), "FADING", "FADING")
  clear()
  sim.set_var(K, VAR, "50")
  adv(60)
  t.eq(state_of("Kitchen"), "VACANT", "VACANT")
  t.ok(not any_ramp(K), "not faded again at once")
  adv(125 * 60)
  t.ok(ramp(K, 0, 30000), "faded after the hold expires (no latch)")
end)

t.test("xH target-first feedback order (device reports target, then real levels)", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  feed(K, 60)
  sim.advance(500)
  feed(K, 20)
  sim.advance(500)
  feed(K, 40)
  sim.advance(1000)
  feed(K, 60)
  clear()
  sim.call("Update")
  print("   state " .. tostring(state_of("Kitchen")) .. ", ramps after Update: " .. tostring(sent_count(K)))
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(181)
  feed(K, 0)
  sim.advance(1000)
  feed(K, 50)
  sim.advance(1000)
  feed(K, 30)
  adv(29)
  feed(K, 0)
  print("   after fade with target-first feedback: " .. tostring(state_of("Kitchen")))
  adv(400)
  print("   400 s later: " .. tostring(state_of("Kitchen")))
end)

t.finish("dls-extra")
