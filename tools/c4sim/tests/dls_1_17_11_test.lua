-- DLS 1.17.11 audit fixes: one test per fix, named by the audit number (B1..B10, D11..D19, N1..N8).
-- Times are host-local (Eastern on ixhel), Massillon (40.8, -81.5) on 1 Jan 2026 unless a test says otherwise:
-- sunrise ~07:50, solar noon ~12:29, sunset ~17:09; el 9.7 at 16:00, 2.3 at 16:50, -2.6 at 17:20.
-- Run: python tools/c4sim/run.py test dls_1_17_11
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
local function min_on(id)
  local m = nil
  for _, r in ipairs(levels(id)) do if r.level > 0 and (m == nil or r.level < m) then m = r.level end end
  return m
end
local function mirror(id)
  local r = levels(id)
  if #r > 0 then sim.set_var(id, VAR, tostring(r[#r].level)) end
end
local function nprinted(s)
  local n = 0
  for _, p in ipairs(sim.prints or {}) do if tostring(p):find(s, 1, true) then n = n + 1 end end
  return n
end
local function printed(s) return nprinted(s) > 0 end
local function hand(id, v) sim.set_var(id, VAR, tostring(v)) sim.fire_var(id, VAR, tostring(v)) end
local function state_of(key)
  local p = sim.persist and sim.persist.presence
  return p and p[key] and p[key].state
end
local function status() return tostring(sim._store["Status"]) end
local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end
local function events(name)
  local n = 0
  for _, e in ipairs(sim.events or {}) do if e.id == name then n = n + 1 end end
  return n
end
-- a live lux sensor: the value moves a little every minute (a bit-identical value for 30 min is stale)
local function wiggle(minutes, base, each)
  for i = 1, minutes do
    sim.set_var(LUXDEV, LUXVAR, tostring(base + ((i % 2 == 0) and 0 or 0.01)))
    if each then each() end
    adv(60)
  end
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
      if o.before then o.before(s) end
    end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  if o.hello then
    send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", o.hello, "0", "clear", TOK))
  end
  return ok
end

local HALL = '[{"name":"Hall","type":"lutron","on":"18:00","off":"22:00","min_level":40,"max_level":40,' ..
  '"scenes":{"Off":{"off":true}},"lights":[{"id":401,"kind":"lutron"}]}]'
local KITCHEN = '[{"name":"Kitchen","key":"Kitchen","on":"06:00","off":"23:00","min_level":60,"max_level":60,' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'
local LR = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30","off_ramp_min":30,' ..
  '"window_gain":0.4,"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":1200,"fadeInSec":2,' ..
  '"fadeOutSec":30,"nightLevel":5,"sources":["esp"]},"lux":{"dev":603,"var":1048,"target":5},' ..
  '"lights":[{"id":331,"kind":"lutron"}]}]'
local function keepLR(minutes, base)
  wiggle(minutes, base or 0, function() send(ln("OCC", "LivingRoom", "1", "esp", TOK)) mirror(331) end)
end

t.test("version 1.17.11", function()
  start({ at = local_sec(12, 0), rooms = HALL })
  t.eq(sim.env.DRIVER_VERSION, "1.17.11", "DRIVER_VERSION")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("B1 a reload across the off time still sees the off edge; a reload deep in the off window sends none", function()
  start({ at = local_sec(21, 50), rooms = HALL, vars = { [401] = 40 } })
  adv(5 * 60)
  t.ok(type(sim.persist.wasInWindow) == "table" and sim.persist.wasInWindow.Hall ~= nil, "wasInWindow persisted")
  local saved = sim.persist
  start({ at = local_sec(22, 3), rooms = HALL, vars = { [401] = 40 }, persist = saved })
  sim.sent = {}
  adv(60)
  t.ok(has(401, 0), "the first pass after the reload sends the scheduled off")
  -- deep in the off window: the last pass before the reload was already off-window
  start({ at = local_sec(21, 55), rooms = HALL, vars = { [401] = 40 } })
  adv(15 * 60)
  saved = sim.persist
  t.eq(saved.wasInWindow and saved.wasInWindow.Hall, nil, "off-window persisted as no entry")
  start({ at = local_sec(22, 12), rooms = HALL, vars = { [401] = 0 }, persist = saved })
  adv(60)
  t.ok(not printed("scheduled off Hall"), "no off edge after a reload deep in the off window")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("B2 Away with people in the Living Room: the off-edge glide runs and the dusk trigger fires", function()
  start({ at = local_sec(23, 0), rooms = LR, presence = "On", lux = 0, vars = { [331] = 0 }, hello = "LivingRoom" })
  keepLR(5)
  local lit = max_level(331)
  t.ok(lit > 10, "lit before the off edge (" .. lit .. ")")
  send(ln("PRESENCE", "AWAY", TOK))
  sim.sent = {}
  keepLR(45)                                           -- 23:50, glide 23:30 -> 00:00
  local mid = false
  for _, r in ipairs(levels(331)) do if r.level > 5 and r.level < lit then mid = true end end
  t.ok(mid, "a glide step between the night level and " .. lit .. " while Away")
  t.ok(not has(331, 0), "the occupied room is not turned off by the Away")
  -- the dusk trigger during an Away with people home
  start({ at = local_sec(15, 0), rooms = LR, presence = "On", lux = 50, vars = { [331] = 0 }, hello = "LivingRoom" })
  keepLR(5, 50)
  send(ln("PRESENCE", "AWAY", TOK))
  keepLR(60, 1)                                        -- 16:05: lux 1, D under 0.6
  t.ok(sim.persist.daylightFired and sim.persist.daylightFired["Living Room"] ~= nil, "daylight trigger fired while Away")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("B3 the HOME edge keeps a manual hold in a room other people are using", function()
  start({ at = local_sec(20, 0), lat = "40", lon = "-75", rooms = KITCHEN, presence = "On", vars = { [101] = 0 }, hello = "Kitchen" })
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(20) mirror(101)
  hand(101, 30)
  t.ok(sim.persist.holds and sim.persist.holds.Kitchen ~= nil, "hand level held")
  send(ln("PRESENCE", "AWAY", TOK))
  adv(5)
  send(ln("PRESENCE", "HOME", TOK))
  sim.sent = {}
  adv(120)
  t.ok(sim.persist.holds and sim.persist.holds.Kitchen and sim.persist.holds.Kitchen["101"] ~= nil, "hold kept on HOME")
  t.eq(#levels(101), 0, "the held light is not re-driven")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("B4 reload in a vacant follow room with a restored until-vacant hold: the lights go off", function()
  local persist = { holds = { Kitchen = { ["101"] = { u = EPOCH + local_sec(20, 0) + 7 * 86400, o = false } } } }
  start({ at = local_sec(20, 0), lat = "40", lon = "-75", rooms = KITCHEN, presence = "On", vars = { [101] = 60 },
    hello = "Kitchen", persist = persist })
  sim.sent = {}
  adv(6 * 60)
  t.ok(has(101, 0), "vacancy fade after the off delay")
end)

-- -------------------------------------------------------------------------------------------------------------
local DOWN = '[{"name":"Downstairs","type":"mixed","follow":true,"on_daylight":0.3,"off":"23:30","off_ramp_min":30,' ..
  '"scenes":{"Off":{"off":true}},"lights":[{"id":480,"kind":"lifx"},{"id":478,"kind":"lifx","ignore_room_off":true}]}]'
t.test("B5 keypad Off during the off fade turns off ignore_room_off lights too; before the edge it skips them", function()
  start({ at = local_sec(21, 50), lat = "40", lon = "-75", rooms = DOWN, vars = { [480] = 40, [478] = 40 } })
  adv(10 * 60)
  sim.sent = {}
  sim.exec("ApplyScene", { ROOM = "Downstairs", SCENE = "Off" })
  t.ok(has(480, 0, 2000) and not has(478, 0), "22:00: Off skips the ignore_room_off light")
  start({ at = local_sec(21, 50), lat = "40", lon = "-75", rooms = DOWN, vars = { [480] = 40, [478] = 40 } })
  adv(105 * 60)                                        -- 23:35, fade running
  sim.sent = {}
  sim.exec("ApplyScene", { ROOM = "Downstairs", SCENE = "Off" })
  t.ok(has(478, 0, 2000), "23:35: Off also turns off the ignore_room_off light")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("B6 plain room: hold expiry returns a hand-dimmed lamp to the schedule; a hand-off after a hand-on is seen", function()
  start({ at = local_sec(19, 30), rooms = HALL, vars = { [401] = 0 } })
  adv(120) mirror(401)
  t.ok(has(401, 40), "on at 40")
  hand(401, 70)
  sim.sent = {}
  adv(125 * 60)
  t.ok(has(401, 40), "back to the schedule level 40 after the 120 min hold")
  start({ at = local_sec(21, 50), rooms = HALL, vars = { [401] = 40 } })
  adv(12 * 60)
  sim.set_var(401, VAR, "0")
  adv(8 * 60)                                          -- 22:10
  hand(401, 30)
  t.eq(sim.persist.holds.Hall["401"].m, true, "hand-on after the off: manualOn")
  hand(401, 0)
  t.eq(sim.persist.holds.Hall["401"].m, nil, "the hand-off is seen (manualOn cleared)")
end)

-- -------------------------------------------------------------------------------------------------------------
local DEN = '[{"name":"Den","type":"lifx_only","follow":true,"on_daylight":0.3,"off":"22:00","off_ramp_min":30,' ..
  '"lights":[{"id":476,"kind":"lifx"}]}]'
t.test("B7 a hand-on at 5% after a stepped off is manual, not feedback; enforcement leaves it on", function()
  start({ at = local_sec(21, 50), lat = "40", lon = "-75", rooms = DEN, vars = { [476] = 40 } })
  for _ = 1, 45 do adv(60) mirror(476) end            -- 22:35, the stepped fade ended at 0
  t.ok(has(476, 0), "faded to 0")
  adv(5 * 60)
  hand(476, 5)
  sim.sent = {}
  adv(15 * 60)
  t.ok(not has(476, 0), "no 0 sent over the 5% hand-on")
  t.eq(sim.persist.holds.Den["476"].m, true, "held as a hand-on after the off")
end)

-- -------------------------------------------------------------------------------------------------------------
local LAUNDRY = '[{"name":"Laundry","key":"Laundry","on":"06:30","off":"23:00","lights":[{"id":568,"kind":"lutron"}],' ..
  '"presence":{"graceSec":0,"follow":true,"manualHold":"level","offDelaySec":600,"fadeInSec":1,"fadeOutSec":30,"nightLevel":20,' ..
  '"sources":["robot","esp"],"levels":[{"at":"06:30","level":80},{"at":"21:00","level":LATE}]}}]'
t.test("B8 a fixed-level room keeps its walk-in level across a level boundary while occupied", function()
  start({ at = local_sec(20, 55), lat = "40", lon = "-75", rooms = LAUNDRY:gsub("LATE", "20"), presence = "On",
    vars = { [568] = 0 }, hello = "Laundry" })
  send(ln("OCC", "Laundry", "1", "esp", TOK))
  adv(2) mirror(568)
  t.ok(has(568, 80), "walk-in at 80")
  for _ = 1, 12 do send(ln("OCC", "Laundry", "1", "esp", TOK)) adv(60) mirror(568) end   -- 21:07
  t.ok(not has(568, 20), "no re-level to 20 at 21:00 while occupied")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("B10 one bad room does not stop the others; string ids load; a raising Rooms JSON keeps the old rooms", function()
  local TWO = '[{"name":"Bad","type":"lutron","on":"18:00","off":"22:00","lights":[{"id":402,"kind":"lutron"}]},' ..
    '{"name":"Good","type":"lutron","on":"18:00","off":"22:00","min_level":40,"max_level":40,"lights":[{"id":403,"kind":"lutron"}]}]'
  start({ at = local_sec(20, 0), rooms = TWO, vars = { [402] = 0, [403] = 0 } })
  local real = sim.env.ComputeRoomTarget
  sim.env.ComputeRoomTarget = function(room, ...)
    if room.name == "Bad" then error("boom") end
    return real(room, ...)
  end
  sim.prints = {}
  sim.sent = {}
  adv(5 * 60)
  t.ok(has(403, 40), "the room after the failing one is still driven")
  t.eq(nprinted("Update room Bad failed"), 1, "the error is logged once, not every pass")
  sim.env.ComputeRoomTarget = real
  setprop("Rooms JSON", '[{"name":"Den","type":"lutron","on":"18:00","off":"22:00","lux":{"dev":"603","var":"1048","target":5},' ..
    '"occ":{"dev":"0"},"lights":[{"id":404,"kind":"lutron"}]}]')
  t.ok(status():find("Rooms JSON error", 1, true) == nil, "string device ids load (" .. status() .. ")")
  setprop("Rooms JSON", '[{"name":"X","lights":5}]')
  t.ok(status():find("Rooms JSON error", 1, true) ~= nil, "Status names the failed load")
  hand(404, 70)
  t.ok(sim.persist.holds and sim.persist.holds.Den ~= nil, "the previous rooms (Den) still run")
end)

-- -------------------------------------------------------------------------------------------------------------
local DENNL = '[{"name":"Den","type":"lutron","on_daylight":0.3,"off":"23:00","lights":[{"id":301,"kind":"lutron"}]}]'
local LUXR = '{"name":"Living Room","type":"lutron","on_daylight":0.3,"off":"23:30","lux":{"dev":603,"var":1048,"target":5},' ..
  '"lights":[{"id":331,"kind":"lutron"}]}'
t.test("D11 the trigger follows lux: no overcast-noon model fire, lux rooms wait for lux, no-lux rooms follow", function()
  -- (a) no lux room at all, fully overcast at 12:40 (D ~0.18 < 0.3): the model needs el < 10
  start({ at = local_sec(12, 35), rooms = DENNL, vars = { [301] = 0 }, props = { ["Cloud Cover Source"] = "Open-Meteo (internet)" },
    before = function(s) for _ = 1, 6 do s.queue_http("open%-meteo", '{"current":{"cloud_cover":100}}', 200) end end })
  adv(50 * 60)
  t.eq(count_on(301), 0, "no trigger at an overcast solar noon")
  sim.queue_http("open%-meteo", '{"current":{"cloud_cover":100}}', 200)
  setprop("Cloud Cover Source", "Open-Meteo (internet)")
  sim.advance((16 * 60 + 5 - (13 * 60 + 25)) * MIN)   -- 16:05, el 9 overcast: the elevation-gated fallback fires
  t.ok(count_on(301) >= 1, "model fallback below 10 degrees")
  -- (b) a lux room with a fresh sensor above on_below does not fire on the model at dusk
  start({ at = local_sec(16, 30), rooms = '[' .. LUXR .. ']', lux = 5, vars = { [331] = 0 } })
  wiggle(35, 5)                                        -- 17:05: model D 0.2 < 0.3, el < 10
  t.eq(count_on(331), 0, "no model trigger while the lux sensor is fresh and bright")
  wiggle(3, 1)
  t.ok(count_on(331) >= 1, "lux under on_below triggers")
  -- (c) a room with no lux sensor follows the lux room
  start({ at = local_sec(16, 0), rooms = '[' .. DENNL:sub(2, -2) .. ',' .. LUXR .. ']', lux = 1, vars = { [301] = 0, [331] = 0 } })
  wiggle(6, 1)
  t.ok(count_on(331) >= 1, "the lux room fired at 1 lux")
  t.ok(count_on(301) >= 1, "the no-lux room followed it (model alone would wait to ~16:50)")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("D12 the morning window end keeps a scene hold", function()
  local R = '[{"name":"Living Room","type":"lutron","on_daylight":0.3,"off":"23:30","off_ramp_min":2,"min_level":0,' ..
    '"lux":{"dev":603,"var":1048,"target":5},"morning":{"target":3},"scenes":{"Evening":{"levels":{"101":50}}},' ..
    '"lights":[{"id":101,"kind":"lutron"}]}]'
  start({ at = local_sec(8, 0), rooms = R, lux = 1, vars = { [101] = 0 } })
  adv(5 * 60)
  t.ok(count_on(101) >= 1, "morning window on")
  sim.exec("ApplyScene", { ROOM = "Living Room", SCENE = "Evening" })
  sim.sent = {}
  sim.advance(155 * MIN)                               -- 10:40, past the morning stop (sunrise+150)
  t.ok(sim.persist.roomHolds and sim.persist.roomHolds["Living Room"] ~= nil, "scene hold kept past the morning end")
  t.ok(not has(101, 0), "the held light is not turned off")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("D14 a Composer edit stores only that room and key; a Rooms JSON change drops the override", function()
  local function rooms(kd)
    return '[{"name":"Kitchen","key":"Kitchen","presence":{"follow":true,"offDelaySec":' .. kd .. ',"sources":["esp"]},' ..
      '"lights":[{"id":101,"kind":"lutron"}]},{"name":"Hall","key":"Hall","presence":{"follow":true,"offDelaySec":240,' ..
      '"sources":["esp"]},"lights":[{"id":102,"kind":"lutron"}]}]'
  end
  start({ at = local_sec(12, 0), rooms = rooms(180), presence = "On" })
  setprop("Presence Room", "Kitchen")
  setprop("Presence Off Delay (sec)", 600)
  local ui = sim.persist.presenceUI or {}
  t.eq(ui.Kitchen and ui.Kitchen.offDelaySec, 600, "Kitchen override stored")
  t.eq(ui.Hall, nil, "Hall not stored")
  setprop("Rooms JSON", rooms(180))
  t.eq(tonumber(sim._store["Presence Off Delay (sec)"]), 600, "unchanged JSON keeps the override")
  setprop("Rooms JSON", rooms(300))
  t.eq(tonumber(sim._store["Presence Off Delay (sec)"]), 300, "a Rooms JSON edit wins over the old override")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("D15 re-entry during the fade-out restores the pre-fade level at once", function()
  local K = KITCHEN:gsub('"offDelaySec":180', '"offDelaySec":10')
  start({ at = local_sec(20, 0), lat = "40", lon = "-75", rooms = K, presence = "On", vars = { [101] = 0 }, hello = "Kitchen" })
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  adv(2) mirror(101)
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  adv(12)
  t.eq(state_of("Kitchen"), "FADING", "fading")
  sim.sent = {}
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(has(101, 60, 500), "pre-fade 60 restored in 500 ms")
end)

-- -------------------------------------------------------------------------------------------------------------
local function curtainRooms(th)
  return '[{"name":"Den","type":"lutron","lights":[{"id":301,"kind":"lutron"}],' ..
    '"curtains":[{"id":901,"name":"Den Curtain","facing_deg":135,"open_at":"sunrise+15","close_at":"sunset",' ..
    '"glare_threshold":' .. th .. ',"glare_position":25}]}]'
end
local function curtain_cmds()
  local n = {}
  for _, s in ipairs(sim.sent) do
    if s.id == 901 then n[#n + 1] = s.cmd .. (s.params and s.params.POSITION and (" " .. s.params.POSITION) or "") end
  end
  return n
end
t.test("D16 curtains: vertical-window glare, hysteresis, held logged once", function()
  -- (a) 09:30 el 13.8 az 138, facing 135: old sin(el) 0.24 (open), new cos(el) 0.97 (glare)
  start({ at = local_sec(9, 30), rooms = curtainRooms(0.35), props = { ["Curtain Automation"] = "On" } })
  adv(60)
  t.eq(table.concat(curtain_cmds(), ","), "SET_POSITION 25", "low sun in front of the window is glare")
  -- (b) hysteresis: trip at 0.9 in clear sky, cloud 60% (glare ~0.84) stays tripped (release under 0.72)
  start({ at = local_sec(9, 30), rooms = curtainRooms(0.9), props = { ["Curtain Automation"] = "On", ["Cloud Cover Source"] = "Open-Meteo (internet)" },
    before = function(s) for _ = 1, 6 do s.queue_http("open%-meteo", '{"current":{"cloud_cover":0}}', 200) end end })
  adv(60)
  t.eq(table.concat(curtain_cmds(), ","), "SET_POSITION 25", "tripped in clear sky")
  sim.prints = {}
  sim.queue_http("open%-meteo", '{"current":{"cloud_cover":60}}', 200)
  setprop("Cloud Cover Source", "Open-Meteo (internet)")
  adv(10 * 60)
  t.ok(not printed("curtain target Den Curtain 100"), "a cloud change inside the band does not flip the target")
  -- (d) target changes inside the 15 min cooldown: "curtain held" logged once, not every pass
  start({ at = local_sec(8, 0), rooms = curtainRooms(0.35), props = { ["Curtain Automation"] = "On" } })
  adv(14 * 60)
  t.eq(nprinted("curtain held"), 1, "held logged once")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("D17 a walk-in outside the window evaluates the dusk trigger at once", function()
  local K = '[{"name":"Kitchen","key":"Kitchen","on_daylight":0.3,"off":"23:00","min_level":60,"max_level":60,' ..
    '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":600,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
    '"lights":[{"id":101,"kind":"lutron"}]}]'
  start({ at = local_sec(16, 30), rooms = K, presence = "On", vars = { [101] = 0 }, hello = "Kitchen",
    props = { ["Update Interval (min)"] = "30" } })
  adv(25 * 60)                                         -- 16:55: D 0.25 < 0.3, next Update only at 17:00
  sim.sent = {}
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(has(101, 60), "walk-in gets the evening level 60")
  t.ok(not has(101, 20), "not the night level 20")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("D18 stale lux freezes the loop in both directions", function()
  local R = '[{"name":"Den","type":"lutron","on_daylight":0.3,"off":"23:30","min_level":5,' ..
    '"lux":{"dev":603,"var":1048,"target":5,"step":0.2},"lights":[{"id":301,"kind":"lutron"}]}]'
  start({ at = local_sec(20, 0), rooms = R, lux = 50, vars = { [301] = 0 } })
  for _ = 1, 35 do adv(60) mirror(301) end            -- 20:35: the bright value has not changed for 30 min
  t.ok(count_on(301) >= 1, "lit")
  sim.sent = {}
  for _ = 1, 55 do adv(60) mirror(301) end            -- 21:30: the old code kept dimming to the floor
  t.eq(#levels(301), 0, "the loop is frozen: no dimming on a stale bright reading")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("D19 morning.presence_room naming no room: warned at load, the gate reads vacant", function()
  local R = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30",' ..
    '"presence":{"graceSec":0,"arrival":false,"follow":false,"sources":["esp"]},"lights":[{"id":101,"kind":"lutron"}]},' ..
    '{"name":"Downstairs","type":"lifx_only","on_daylight":0.3,"off":"23:30","min_level":0,' ..
    '"morning":{"target":3,"presence_room":"Nowhere","dev":603,"var":1048},"lights":[{"id":201,"kind":"lifx"}]}]'
  start({ at = local_sec(8, 0), rooms = R, presence = "On", lux = 1, vars = { [101] = 0, [201] = 0 }, hello = "LivingRoom" })
  adv(5 * 60)
  t.eq(count_on(201), 0, "no morning latch through an unknown gate room")
  t.ok(status():find("presence_room (unknown room 'Nowhere'", 1, true) ~= nil, "warned in Status")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N1 a persisted off fade that ended more than 1 h before the load is ignored", function()
  start({ at = local_sec(23, 30), rooms = HALL, vars = { [401] = 40 },
    persist = { offFades = { Hall = { endAt = EPOCH + local_sec(22, 0) } } } })
  adv(30)
  t.ok(not has(401, 0), "no off sent for a fade that ended 90 min ago")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N2 the wake ramp honours a light's max_level", function()
  local R = '[{"name":"Upstairs","type":"lutron","on_daylight":0.3,"off":"22:30","lights":[{"id":337,"kind":"lutron","max_level":30}],' ..
    '"wake":{"enabled":true,"at":"06:15","stop":"07:15","ramp_min":30,"level":35}}]'
  start({ at = local_sec(6, 10), rooms = R, vars = { [337] = 0 } })
  adv(50 * 60)
  t.ok(max_level(337) <= 30 and max_level(337) >= 25, "wake capped at 30 (max " .. max_level(337) .. ")")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N3 a presence levels entry of 0 means off", function()
  start({ at = local_sec(21, 30), lat = "40", lon = "-75", rooms = LAUNDRY:gsub("LATE", "0"), presence = "On",
    vars = { [568] = 0 }, hello = "Laundry" })
  sim.sent = {}
  send(ln("OCC", "Laundry", "1", "esp", TOK))
  adv(5)
  t.eq(count_on(568), 0, "no walk-in light (not the night level 20)")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N4 Release Room Override after the off edge hands a lit lamp back to enforcement", function()
  start({ at = local_sec(21, 50), rooms = HALL, vars = { [401] = 40 } })
  adv(12 * 60)
  sim.set_var(401, VAR, "0")
  adv(8 * 60)                                          -- 22:10
  hand(401, 30)
  adv(10 * 60)
  sim.sent = {}
  sim.exec("Release Room Override", { ROOM = "Hall" })
  adv(5)
  t.ok(has(401, 0), "enforcement turns the released lamp off")
  t.ok(sim.persist.holds.Hall == nil or sim.persist.holds.Hall["401"] == nil, "no hold or manualOn left")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N5 time specs: HHMM and any case / spaces resolve; a bad spec is warned", function()
  local R = '[{"name":"Hall","type":"lutron","on":"1800","off":"2200","min_level":40,"max_level":40,"lights":[{"id":401,"kind":"lutron"}]},' ..
    '{"name":"Den","type":"lutron","on":"Sunset - 15","off":"teatime","lights":[{"id":301,"kind":"lutron"}]}]'
  start({ at = local_sec(21, 55), rooms = R, vars = { [401] = 40, [301] = 0 } })
  adv(12 * 60)
  t.ok(has(401, 0), "off \"2200\" is 22:00")
  t.ok(status():find("Den.off (bad time 'teatime')", 1, true) ~= nil, "bad spec warned")
  t.ok(status():find("Den.on", 1, true) == nil, "\"Sunset - 15\" is accepted")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N6 PRESENCE with a blank Presence Token is rejected and logged", function()
  start({ at = local_sec(12, 0), rooms = HALL, props = { ["Presence Token"] = "" } })
  sim.prints = {}
  local r = send(ln("PRESENCE", "AWAY"))
  t.ok(r:find("ERR AUTH", 1, true) ~= nil, "ERR AUTH (" .. r .. ")")
  t.eq(sim._store["Presence"], "Home", "still Home")
  t.ok(printed("presence line rejected"), "rejection logged")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N7 remote log: a 4xx batch is dropped; a batch whose callback never returns is requeued", function()
  start({ at = local_sec(12, 0), rooms = HALL, props = { ["Remote Log URL"] = "http://loki.test/push" } })
  sim.queue_http("loki", "", 400)
  adv(16)
  local n1 = #sim.http
  hand(401, 70)                                        -- new lines for the next post
  sim.queue_http("loki", "", 204)
  adv(15)
  t.ok(#sim.http > n1, "a second post went out")
  local body = sim.http[#sim.http].body or ""
  t.ok(body:find("dls loaded version", 1, true) == nil, "the rejected batch is not posted again")
  t.ok(body:find("manual change", 1, true) ~= nil, "the new lines are posted")
  start({ at = local_sec(12, 0), rooms = HALL, props = { ["Remote Log URL"] = "http://loki.test/push" } })
  sim.queue_http("loki", "", 0, nil, "__HANG__")
  adv(16)
  sim.queue_http("loki", "", 204)
  adv(65)
  body = sim.http[#sim.http].body or ""
  t.ok(body:find("dls loaded version", 1, true) ~= nil, "the lost batch is posted again after the busy timeout")
end)

-- -------------------------------------------------------------------------------------------------------------
t.test("N8 Room Occupied fires on a hand-on in a vacant level-only room", function()
  start({ at = local_sec(20, 0), lat = "40", lon = "-75", rooms = LAUNDRY:gsub("LATE", "20"), presence = "On",
    vars = { [568] = 0 }, hello = "Laundry" })
  sim.events = {}
  hand(568, 50)
  t.eq(events("Room Occupied"), 1, "Room Occupied fired")
end)

t.finish("dls-1-17-11")
