-- DLS 1.17.10 regressions: one test (or more) per fix. Times are host-local (Eastern on ixhel), like the other
-- DLS tests that use Massillon (40.8, -81.5) or (40, -75) on 1 Jan 2026.
-- Run: python tools/c4sim/run.py test dls_1_17_10
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
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
local function adv(sec) sim.advance(sec * SEC) end
local function levels(id)
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then out[#out + 1] = { level = tonumber(s.params.LEVEL), ms = tonumber(s.params.TIME) } end
  end
  return out
end
local function has(id, level, ms)
  for _, r in ipairs(levels(id)) do if r.level == level and (ms == nil or r.ms == ms) then return true end end
  return false
end
local function count_on(id)
  local n = 0
  for _, r in ipairs(levels(id)) do if r.level > 0 then n = n + 1 end end
  return n
end
local function max_level(id)
  local m = -1
  for _, r in ipairs(levels(id)) do if r.level > m then m = r.level end end
  return m
end
local function mirror(id)
  local r = levels(id)
  if #r > 0 then sim.set_var(id, VAR, tostring(r[#r].level)) end
end
local function printed(s)
  for _, p in ipairs(sim.prints or {}) do if tostring(p):find(s, 1, true) then return true end end
  return false
end
local function hand(id, v) sim.set_var(id, VAR, tostring(v)) sim.fire_var(id, VAR, tostring(v)) end
local function state_of(key)
  local p = sim.persist and sim.persist.presence
  return p and p[key] and p[key].state
end

local function start(o)
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "120", ["Scene Hold (min)"] = "240", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = o.lat or "40.8", ["Longitude"] = o.lon or "-81.5", ["Presence"] = "Home",
    ["Presence Lighting"] = o.presence or "Off", ["Debug"] = "On",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = o.rooms,
  }
  for k, v in pairs(o.props or {}) do props[k] = v end
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = o.at * SEC, persist = o.persist,
    before = function(s)
      for id, v in pairs(o.vars or {}) do s.set_var(id, VAR, tostring(v)) end
      s.set_var(LUXDEV, LUXVAR, tostring(o.lux or 0))
    end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  if o.hello then
    send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", o.hello, "0", "clear", TOK))
  end
  return ok
end

-- -------------------------------------------------------------------------------------------------------------
-- fix 1: the daylight trigger is reset in the morning even while Away
local DAYROOM = '[{"name":"Den","type":"lutron","on_daylight":0.3,"off":"23:00","lights":[{"id":301,"kind":"lutron"}]}]'
t.test("f1 a trigger from last evening does not light the room at noon after a night Away", function()
  start({ at = local_sec(18, 0), lat = "40", lon = "-75", rooms = DAYROOM, vars = { [301] = 0 }, props = { ["Update Interval (min)"] = "5" } })
  adv(60)
  t.ok(count_on(301) >= 1, "evening trigger lit the room")
  sim.exec("SetPresence", { PRESENT = "Away" })
  sim.set_var(301, VAR, "0")
  sim.advance((18 * 60 + 30) * MIN)                    -- next day 12:31, Away all night
  sim.sent = {}
  sim.exec("SetPresence", { PRESENT = "Home" })
  adv(120)
  t.eq(count_on(301), 0, "no turn-on at 12:30 the next day (trigger was reset while Away)")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 2: lux path uses lux.on_below (default 2) and only while model D < 0.6
local LUXROOM = '[{"name":"Living Room","type":"lutron","on_daylight":0.3,"off":"23:30","window_gain":0.4,' ..
  '"lux":{"dev":603,"var":1048,"target":5},"lights":[{"id":331,"kind":"lutron"}]}]'
t.test("f2a 4 lux at solar noon (under the loop target 5) does not fire the trigger", function()
  start({ at = local_sec(12, 30), rooms = LUXROOM, lux = 4, vars = { [331] = 0 } })
  adv(10 * 60)
  t.eq(count_on(331), 0, "no trigger at 4 lux")
end)
t.test("f2b 1 lux at solar noon (D > 0.6) does not fire the trigger either", function()
  start({ at = local_sec(12, 30), rooms = LUXROOM, lux = 1, vars = { [331] = 0 } })
  adv(10 * 60)
  t.eq(count_on(331), 0, "no trigger while D >= 0.6")
end)
t.test("f2c 1 lux at 16:00 (D under 0.6, over 0.3) fires the trigger; lux.on_below can be raised", function()
  start({ at = local_sec(16, 0), rooms = LUXROOM, lux = 1, vars = { [331] = 0 } })
  adv(5 * 60)
  t.ok(count_on(331) >= 1, "lux trigger at 1 lux")
  start({ at = local_sec(16, 0), rooms = LUXROOM:gsub('"target":5', '"target":5,"on_below":4.5'), lux = 4, vars = { [331] = 0 } })
  adv(5 * 60)
  t.ok(count_on(331) >= 1, "on_below 4.5 fires at 4 lux")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 3 + B: arrival level seeds the lux loop; no minimum Away time
local ARRROOM = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30",' ..
  '"presence":{"graceSec":0,"follow":true,"offDelaySec":600,"fadeInSec":2,"fadeOutSec":30,"nightLevel":5,"sources":["esp"]},' ..
  '"lux":{"dev":603,"var":1048,"target":5},"lights":[{"id":331,"kind":"lutron"}]}]'
t.test("f3+B dark arrival after a 1 s Away lights at the seed 25, not ~100", function()
  start({ at = local_sec(18, 0), rooms = ARRROOM, presence = "On", lux = 0, vars = { [331] = 0 }, hello = "LivingRoom" })
  adv(30)
  sim.sent = {}
  send(ln("PRESENCE", "AWAY", TOK))
  adv(1)
  send(ln("PRESENCE", "HOME", TOK))
  local on
  for _, r in ipairs(levels(331)) do if r.level > 0 then on = r break end end
  t.ok(on ~= nil, "arrival lit the room after a 1 s Away")
  if on then t.eq(on.level, 25, "seeded level 25 (min(model 100, default 25)), not ~100") end
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 5: follow mode does not fight off enforcement
local FOLLOWROOM = '[{"name":"Hall","type":"lutron","follow":true,"on":"18:00","off":"22:00","min_level":40,' ..
  '"lights":[{"id":401,"kind":"lutron"}]}]'
t.test("f5 after the scheduled off, a dropped light gets 0 from enforcement, never a level from follow", function()
  start({ at = local_sec(21, 50), lat = "40", lon = "-75", rooms = FOLLOWROOM, vars = { [401] = 40 } })
  adv(15 * 60)                                         -- 22:05: off edge sent 0; the light ignored it (stuck at its level)
  t.ok(has(401, 0), "scheduled off sent")
  sim.sent = {}
  adv(15 * 60)
  t.ok(has(401, 0), "enforcement re-sends 0")
  t.eq(count_on(401), 0, "follow mode sends no level to the light")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 6 (owner decision): a lamp turned on by hand after the off stays on, also past its 120 min hold and a reload
local DOWN = '[{"name":"Downstairs","type":"mixed","follow":true,"on_daylight":0.3,"off":"23:30","off_ramp_min":30,' ..
  '"scenes":{"Off":{"off":true}},"lights":[{"id":480,"kind":"lifx"},{"id":476,"kind":"lifx"}]}]'
t.test("f6 hand-on after the scheduled off is never sent 0 by enforcement (hold expiry, reload)", function()
  start({ at = local_sec(21, 50), lat = "40", lon = "-75", rooms = DOWN, vars = { [480] = 40, [476] = 40 } })
  adv(105 * 60)                                        -- 23:35: fade running
  adv(30 * 60)                                         -- 00:05: fade done
  sim.set_var(480, VAR, "0") sim.set_var(476, VAR, "0")
  adv(60)
  hand(476, 30)                                        -- hand-on at 00:06
  sim.sent = {}
  adv(130 * 60)                                        -- past the 120 min hold
  t.eq(#levels(476), 0, "no 0 (and nothing else) after the hold ran out")
  local saved = sim.persist
  start({ at = local_sec(2, 20) + 86400, lat = "40", lon = "-75", rooms = DOWN, vars = { [480] = 0, [476] = 30 }, persist = saved })
  sim.sent = {}
  adv(20 * 60)
  t.eq(#levels(476), 0, "still left on after a reload")
  hand(476, 0)                                         -- manual off ends it
  hand(476, 25)
  t.ok(true, "manual off/on accepted")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 7: a reload during the off fade resumes it instead of follow driving the lamps back up
t.test("f7 reload at 23:40 during the 23:30 off fade: fade resumes to 0, nothing goes back up", function()
  start({ at = local_sec(21, 50), lat = "40", lon = "-75", rooms = DOWN, vars = { [480] = 40, [476] = 40 } })
  adv(110 * 60)                                        -- 23:40, about a third into the fade
  mirror(480) mirror(476)
  local r480 = levels(480)
  local at480 = r480[#r480].level
  t.ok(at480 < 40 and at480 > 0, "fade in progress at 23:40 (" .. tostring(at480) .. ")")
  t.ok(sim.persist.offFades and sim.persist.offFades.Downstairs ~= nil, "fade persisted")
  local saved = sim.persist
  start({ at = local_sec(23, 40), lat = "40", lon = "-75", rooms = DOWN, vars = { [480] = at480, [476] = at480 }, persist = saved })
  sim.sent = {}
  for _ = 1, 25 do adv(60) mirror(480) mirror(476) end
  t.ok(has(480, 0) and has(476, 0), "fade finished at 0 after the reload")
  t.ok(max_level(480) <= at480, "no level above the reload level (follow did not drive it up)")
  sim.sent = {}
  adv(20 * 60)
  t.eq(count_on(480), 0, "off enforcement still owns the room after the fade")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 14: a walk-in just after midnight is not the evening window
local SUN_HOST_LON = tostring(((os.time(realdate("*t", EPOCH)) - os.time(realdate("!*t", EPOCH))) / 3600) * 15)
local KROOM = '[{"name":"Kitchen","key":"Kitchen","on_daylight":0.3,"off":"23:00","min_level":60,"max_level":60,' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'
t.test("f14 walk-in at 00:00:10, before the first Update after midnight, gets nightLevel", function()
  start({ at = local_sec(23, 50, 30), lat = "0", lon = SUN_HOST_LON, rooms = KROOM, presence = "On", vars = { [101] = 0 },
    hello = "Kitchen", props = { ["Update Interval (min)"] = "5" } })
  adv(580)                                             -- 00:00:10 (Updates at :30 and :45)
  sim.sent = {}
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(has(101, 20, 2000), "night level 20")
  t.ok(not has(101, 60), "not the evening level 60")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 15: a HOLD (or FADING) presence room keeps the morning window of the room it gates open
local MROOMS = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30","min_level":0,' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":false,"offDelaySec":600,"fadeOutSec":5,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]},' ..
  '{"name":"Downstairs","type":"lifx_only","on_daylight":0.3,"off":"23:30","min_level":0,' ..
  '"morning":{"target":3,"presence_room":"LivingRoom","dev":603,"var":1048},"lights":[{"id":201,"kind":"lifx"}]}]'
t.test("f15 Living Room in HOLD still opens the Downstairs morning window", function()
  start({ at = local_sec(7, 0), rooms = MROOMS, presence = "On", lux = 1, vars = { [101] = 0, [201] = 0 }, hello = "LivingRoom" })
  send(ln("OCC", "LivingRoom", "1", "esp", TOK))
  adv(5)
  hand(101, 50)
  adv(5)
  hand(101, 0)
  t.eq(state_of("LivingRoom"), "HOLD", "Living Room HOLD after hand on/off")
  sim.sent = {}
  adv(40 * 60)                                         -- past sunrise-30
  t.ok(count_on(201) >= 1, "Downstairs morning on while the gate room is in HOLD")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 16a/16b: curtains
local CROOM = '[{"name":"Den","type":"lutron","lights":[{"id":301,"kind":"lutron"}],' ..
  '"curtains":[{"id":901,"name":"Den Curtain","open_at":"sunrise+15","close_at":"17:30"}]}]'
local function curtain_cmds()
  local n = {}
  for _, s in ipairs(sim.sent) do
    if s.id == 901 and (s.cmd == "OPEN" or s.cmd == "CLOSE" or s.cmd == "SET_POSITION") then n[#n + 1] = s.cmd end
  end
  return n
end
t.test("f16a a reload does not re-command the curtain", function()
  start({ at = local_sec(12, 0), rooms = CROOM, vars = { [301] = 0 }, props = { ["Curtain Automation"] = "On" } })
  adv(60)
  t.ok(#curtain_cmds() >= 1, "curtain commanded once")
  local saved = sim.persist
  start({ at = local_sec(12, 2), rooms = CROOM, vars = { [301] = 0 }, persist = saved, props = { ["Curtain Automation"] = "On" } })
  sim.sent = {}
  adv(60)
  t.eq(#curtain_cmds(), 0, "no curtain command after the reload")
end)
t.test("f16b close_at 17:30 is honoured after sunset (no el <= 0 close at ~17:05)", function()
  start({ at = local_sec(16, 55), rooms = CROOM, vars = { [301] = 0 }, props = { ["Curtain Automation"] = "On" } })
  adv(60)
  sim.sent = {}
  adv(25 * 60)                                         -- 17:21, sun below the horizon
  for _, c in ipairs(curtain_cmds()) do t.ok(c ~= "CLOSE", "no close before close_at") end
  adv(11 * 60)                                         -- 17:32
  local closed = false
  for _, c in ipairs(curtain_cmds()) do if c == "CLOSE" then closed = true end end
  t.ok(closed, "closed at close_at")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 17a/17b: remote log
t.test("f17 a failed remote-log POST is requeued; LIGHTS_ON goes out on the all-off -> on edge", function()
  start({ at = local_sec(12, 0), rooms = CROOM, vars = { [301] = 0 }, props = { ["Remote Log URL"] = "http://loki.test/push" } })
  sim.queue_http("loki", "", 500)
  adv(16)                                              -- first flush fails
  local n1 = #sim.http
  t.ok(n1 >= 1, "first post sent")
  local first = sim.http[n1].body or ""
  hand(301, 50)                                        -- room all-off -> on
  sim.queue_http("loki", "", 204)
  adv(16)
  local body = sim.http[#sim.http].body or ""
  t.ok(#sim.http > n1, "second post sent")
  t.ok(body:find("dls loaded version", 1, true) ~= nil and first:find("dls loaded version", 1, true) ~= nil,
    "the failed batch's lines are in the next post")
  t.ok(body:find("dls var LIGHTS_ON ", 1, true) ~= nil and body:find("Den", 1, true) ~= nil, "LIGHTS_ON line")
end)

-- -------------------------------------------------------------------------------------------------------------
-- fix 19: grace restore across a window boundary; arrival errors and gate-closed skips are logged
local GROOM = '[{"name":"Kitchen","key":"Kitchen","on":"06:00","off":"23:00","min_level":60,"max_level":60,' ..
  '"presence":{"arrival":false,"follow":true,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'
t.test("f19a grace walk-in after the 23:00 window end gets the night level, not the pre-fade 60", function()
  start({ at = local_sec(22, 58), lat = "40", lon = "-75", rooms = GROOM, presence = "On", vars = { [101] = 0 }, hello = "Kitchen" })
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(2) mirror(101)
  t.ok(has(101, 60), "lit at 60 in the window")
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(11) mirror(101)                                  -- 22:58:13: the off fade (5 s) was sent at +10 s
  adv(19)                                              -- 22:58:32: fade done, grace runs
  t.eq(state_of("Kitchen"), "VACANT", "VACANT, in the grace")
  adv(75)                                              -- 22:59:47 -> past 23:00 inside the 120 s grace
  adv(15)
  sim.sent = {}
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(not has(101, 60, 500), "no pre-fade restore across the window end")
  t.ok(has(101, 20), "current target: night level 20")
end)
t.test("f19b arrival lighting while the gate is closed logs a skip; an error inside it is logged", function()
  start({ at = local_sec(18, 0), rooms = ARRROOM, presence = "On", lux = 0, vars = { [331] = 0 } })
  sim.prints = {}
  sim.exec("SetPresence", { PRESENT = "Away" })
  sim.exec("SetPresence", { PRESENT = "Home" })
  t.ok(printed("arrival lighting skipped, presence gate closed"), "gate-closed skip logged")
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "LivingRoom", "0", "clear", TOK))
  adv(5)
  start({ at = local_sec(12, 30), rooms = ARRROOM, presence = "On", lux = 50, vars = { [331] = 0 }, hello = "LivingRoom" })
  sim.env.LuxDark = function() error("boom") end
  sim.prints = {}
  send(ln("PRESENCE", "AWAY", TOK))
  send(ln("PRESENCE", "HOME", TOK))
  t.ok(printed("arrival lighting error"), "arrival error logged")
end)

-- -------------------------------------------------------------------------------------------------------------
-- A: Away loop leaves a hand / keypad change alone
local AWROOM = '[{"name":"Kitchen","key":"Kitchen","on":"06:00","off":"23:00",' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'
t.test("A a hand change in a vacant presence room while Away is not undone every pass", function()
  start({ at = local_sec(20, 0), lat = "40", lon = "-75", rooms = AWROOM, presence = "On", vars = { [101] = 0 }, hello = "Kitchen" })
  adv(30)
  send(ln("PRESENCE", "AWAY", TOK))
  adv(120)
  hand(101, 50)
  sim.sent = {}
  adv(10 * 60)
  t.ok(not has(101, 0), "no 0 sent to the hand-set light while Away")
end)
-- -------------------------------------------------------------------------------------------------------------
-- C + D: Living Room hand-off HOLD ends at dusk; manual level holds until vacant and joins the off-edge glide
local LR = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30","off_ramp_min":30,' ..
  '"window_gain":0.4,"scenes":{"Off":{"off":true}},' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":1200,"fadeInSec":2,"fadeOutSec":30,"nightLevel":5,"sources":["esp"]},' ..
  '"lux":{"dev":603,"var":1048,"target":5},"morning":{"target":3},' ..
  '"lights":[{"id":331,"kind":"lutron"},{"id":332,"kind":"lutron"}]}]'
local function keep(minutes, ids)
  for _ = 1, minutes do
    send(ln("OCC", "LivingRoom", "1", "esp", TOK))
    adv(60)
    for _, id in ipairs(ids or { 331, 332 }) do mirror(id) end
  end
end
t.test("C a hand-off HOLD ends at the dusk on edge and the occupied room lights", function()
  start({ at = local_sec(16, 0), rooms = LR, presence = "On", lux = 50, vars = { [331] = 0, [332] = 0 }, hello = "LivingRoom" })
  send(ln("OCC", "LivingRoom", "1", "esp", TOK))
  adv(5) mirror(331) mirror(332)
  t.ok(count_on(331) >= 1, "walk-in at night level before the trigger")
  adv(20)                                              -- past the walk-in ignore window
  hand(331, 0) hand(332, 0)
  adv(2)
  t.eq(state_of("LivingRoom"), "HOLD", "hand-off HOLD")
  sim.sent = {}
  keep(60, {})                                         -- past the ~16:50 model trigger
  t.ok(count_on(331) >= 1 and count_on(332) >= 1, "dusk on edge ended the HOLD and lit the room")
  t.eq(state_of("LivingRoom"), "OCCUPIED", "OCCUPIED")
end)
t.test("D a manual level in the occupied Living Room holds past 120 min and joins the 23:30 glide", function()
  start({ at = local_sec(21, 0), rooms = LR, presence = "On", lux = 0, vars = { [331] = 0, [332] = 0 }, hello = "LivingRoom" })
  keep(3)
  t.ok(count_on(331) >= 1, "lit at dusk level")
  hand(331, 70)                                        -- Lutron scene / hand: 70
  sim.sent = {}
  keep(140, { 332 })                                   -- 23:23
  t.eq(#levels(331), 0, "331 untouched for 140 min (held until vacant)")
  keep(20, { 331, 332 })                               -- 23:43
  local dropped = false
  for _, r in ipairs(levels(331)) do if r.level < 70 and r.level >= 5 then dropped = true end end
  t.ok(dropped, "held 331 joined the glide down toward the night level")
end)

-- -------------------------------------------------------------------------------------------------------------
-- E: Off scene holds until the next window start, not until 12:00
t.test("E1 an Off pressed at 06:35 in the Living Room ends when the morning window opens", function()
  start({ at = local_sec(6, 30), rooms = LR, presence = "On", lux = 0.5, vars = { [331] = 0, [332] = 0 }, hello = "LivingRoom" })
  keep(3)
  sim.exec("ApplyScene", { ROOM = "Living Room", SCENE = "Off" })
  sim.set_var(331, VAR, "0") sim.set_var(332, VAR, "0")
  sim.sent = {}
  keep(70, {})                                         -- to 07:45, past sunrise-30 (~07:22)
  t.ok(count_on(331) >= 1, "morning window lit the room (Off hold ended)")
  t.eq(sim.persist.roomHolds and sim.persist.roomHolds["Living Room"], nil, "Off hold cleared")
end)
t.test("E2 an Off in the Living Room ends when the room goes vacant", function()
  start({ at = local_sec(20, 0), rooms = LR, presence = "On", lux = 0, vars = { [331] = 0, [332] = 0 }, hello = "LivingRoom" })
  keep(3)
  sim.exec("ApplyScene", { ROOM = "Living Room", SCENE = "Off" })
  sim.set_var(331, VAR, "0") sim.set_var(332, VAR, "0")
  send(ln("OCC", "LivingRoom", "0", "clear", TOK))
  adv(1205)
  t.eq(sim.persist.roomHolds and sim.persist.roomHolds["Living Room"], nil, "Off hold cleared by the vacancy")
end)
t.test("E3 an Off in Downstairs (no presence) at 15:00 ends at the dusk trigger", function()
  start({ at = local_sec(15, 0), lat = "40", lon = "-75", rooms = DOWN, vars = { [480] = 0, [476] = 0 } })
  adv(60)
  sim.exec("ApplyScene", { ROOM = "Downstairs", SCENE = "Off" })
  sim.sent = {}
  sim.advance(150 * MIN)                               -- 17:31
  t.ok(count_on(480) >= 1, "dusk trigger lit Downstairs")
  t.eq(sim.persist.roomHolds and sim.persist.roomHolds.Downstairs, nil, "Off hold cleared")
end)

t.finish("dls-1-17-10")
