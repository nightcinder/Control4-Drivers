-- 1.17.5: dark overcast afternoons. The room lux sensor can fire the daylight trigger (two samples in a row), an
-- afternoon Off scene holds only until that trigger, the lux loop starts from the model level, and a dusk turn-on
-- of an already occupied room ramps over Ramp Time (sec) instead of the 2 s walk-in fade.
-- Run: uv run python tools/c4sim/run.py test dls_dusk_lux
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
local LAT, LON = 40.8, -81.5

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
local function mirror()
  local r = ramps(331)
  if #r > 0 then sim.set_var(331, VAR, tostring(r[#r].level)) end
end

-- the driver's daylight model, for the expected open-loop level (base 100 in the afternoon, one window, gain 0.4)
local function rad(d) return d * math.pi / 180 end
local function deg(r) return r * 180 / math.pi end
local function sunEl(utc)
  local jd = utc / 86400 + 2440587.5
  local n = jd - 2451545.0
  local L = (280.460 + 0.9856474 * n) % 360
  local g = rad((357.528 + 0.9856003 * n) % 360)
  local lam = rad(L + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g))
  local eps = rad(23.439 - 0.0000004 * n)
  local dec = math.asin(math.sin(eps) * math.sin(lam))
  local ra = math.atan(math.cos(eps) * math.sin(lam), math.cos(lam))
  local gmst = (18.697374558 + 24.06570982441908 * n) % 24
  local H = rad(((gmst * 15 + LON) - deg(ra)) % 360)
  local la = rad(LAT)
  local s = math.sin(la) * math.sin(dec) + math.cos(la) * math.cos(dec) * math.cos(H)
  return deg(math.asin(math.max(-1, math.min(1, s))))
end
local function modelLevel(utc)
  local el = sunEl(utc)
  local D
  if el <= -6 then D = 0 elseif el < 0 then D = 0.1 * (el + 6) / 6
  else D = math.min(1, 0.1 + 0.95 * math.sqrt(math.sin(rad(el)))) end
  return 100 * (1 - 0.4 * D), D
end

local ROOMS = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on_daylight":0.3,"off":"23:30",' ..
  '"off_ramp_min":30,"window_gain":0.4,"scenes":{"Off":{"off":true}},' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":1200,"fadeInSec":2,"fadeOutSec":30,"nightLevel":5,' ..
  '"nightAfterDark":true,"sources":["esp"]},' ..
  '"lux":{"dev":603,"var":1048,"target":5,"targets":[{"at":"12:00","target":5},{"at":"21:00","target":3}]},' ..
  '"morning":{"target":3},' ..
  '"lights":[{"id":331,"kind":"lutron"}]}]'

local function start(at, lux, persist)
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "5", ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "120", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = tostring(LAT), ["Longitude"] = tostring(LON), ["Presence"] = "Home",
    ["Presence Lighting"] = "On", ["Debug"] = "On",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
  }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, persist = persist, before = function(s)
    s.set_var(331, VAR, "0")
    s.set_var(LUXDEV, LUXVAR, tostring(lux))
  end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "LivingRoom", "0", "clear", TOK))
  sim.advance(5 * SEC)
  sim.sent = {}
  return ok
end
local function occupy() send(ln("OCC", "LivingRoom", "1", "esp", TOK)) sim.advance(5 * SEC) end
local function keepOccupied(minutes)        -- the bridge keeps reporting occupied
  for _ = 1, minutes do send(ln("OCC", "LivingRoom", "1", "esp", TOK)); sim.advance(MIN); mirror() end
end

-- 1.17.10: the lux path only counts while the model D is under 0.6, so these start at 15:30 (D about 0.56).
t.test("A1+C+D: dark room lux fires before the model; no history seeds 25 (not model, not floor+2), 90 s ramp", function()
  start(local_sec(15, 30), 0.3)
  occupy()
  t.eq(firstOn(331), nil, "15:30 walk-in in daylight stays dark (nightAfterDark)")
  keepOccupied(12)
  local on = firstOn(331)
  t.ok(on ~= nil, "lux trigger turned the room on by 15:42")
  local model, D = modelLevel(EPOCH + local_sec(15, 40))
  t.ok(D > 0.3, string.format("the model alone would not fire yet (D=%.2f)", D))
  t.ok(model > 25, string.format("model level %.1f is above the default seed", model))
  if on then
    print(string.format("  A1 seed level %.1f (model %.1f)", on.level, model))
    t.ok(on.level <= 25, "first level <= 25 with no history, got " .. tostring(on.level))
    t.ok(on.level > 10, "not the floor, got " .. tostring(on.level))
    t.eq(on.ms, 90000, "dusk turn-on of an occupied room ramps over Ramp Time (sec)")
  end
end)

t.test("C1: the loop saves its converged level once lux is near target", function()
  start(local_sec(15, 30), 0.3)
  occupy()
  keepOccupied(12)
  t.ok(firstOn(331) ~= nil, "on")
  sim.set_var(LUXDEV, LUXVAR, "4.5")         -- lights on: room near the 5 lux target
  keepOccupied(6)
  local c = sim.persist.luxConverged and sim.persist.luxConverged["Living Room"]
  print("  C1 converged saved " .. tostring(c))
  -- 25 seed, +2 on the next dark pass, +1 at 4.5 lux (err 10%) = 28
  t.ok(c ~= nil and c <= 30 and c >= 20, "converged level saved, got " .. tostring(c))
end)

t.test("C2: a stored converged level of 18 caps the seed, and survives a reload", function()
  start(local_sec(15, 30), 0.3, { luxConverged = { ["Living Room"] = 18 } })
  occupy()
  keepOccupied(12)
  local on = firstOn(331)
  print("  C2 seed level " .. tostring(on and on.level))
  t.ok(on ~= nil and math.abs(on.level - 18) < 0.5, "dusk seed is 18, got " .. tostring(on and on.level))
  local saved = sim.persist
  t.eq(saved.luxConverged and saved.luxConverged["Living Room"], 18, "18 still stored")
  start(local_sec(16, 30), 0.3, saved)        -- driver reload; lights off, trigger already fired today
  occupy()
  local on2 = firstOn(331)
  print("  C2 after reload seed level " .. tostring(on2 and on2.level))
  t.ok(on2 ~= nil and math.abs(on2.level - 18) < 0.5, "after reload the seed is still 18, got " .. tostring(on2 and on2.level))
end)

t.test("A2: a single dark sample (passing cloud) does not fire the trigger", function()
  start(local_sec(14, 0), 0.3)
  occupy()
  sim.advance(30 * SEC)
  sim.set_var(LUXDEV, LUXVAR, "50")          -- bright again before the next Update
  keepOccupied(30)
  t.eq(firstOn(331), nil, "no turn-on from one dark sample")
end)

t.test("B1: an Off pressed after noon before the trigger is released when the trigger fires", function()
  start(local_sec(15, 30), 50)
  occupy()
  sim.exec("ApplyScene", { ROOM = "Living Room", SCENE = "Off" })
  t.eq(sim.persist.roomHoldKinds and sim.persist.roomHoldKinds["Living Room"], "off", "hold kind off (1.17.10)")
  local hu = sim.persist.roomHolds and sim.persist.roomHolds["Living Room"]
  t.ok(hu ~= nil and hu - (EPOCH + local_sec(15, 30)) <= 36 * 3600 + 60, "no next-noon hold: only the 36 h cap")
  keepOccupied(10)
  t.eq(firstOn(331), nil, "still bright: held and dark")
  sim.set_var(LUXDEV, LUXVAR, "0.3")         -- the afternoon goes dark
  keepOccupied(12)
  local on = firstOn(331)
  t.ok(on ~= nil, "the trigger released the Off hold and the room came on")
  t.eq(sim.persist.roomHolds and sim.persist.roomHolds["Living Room"], nil, "room hold cleared")
  if on then t.eq(on.ms, 90000, "gentle ramp") end
end)

t.test("B2: an Off pressed after the trigger fired keeps the room off for the evening", function()
  start(local_sec(16, 0), 50)
  occupy()
  keepOccupied(90)                           -- model trigger near sunset
  t.ok(firstOn(331) ~= nil, "the model trigger lit the room by 17:30")
  sim.exec("ApplyScene", { ROOM = "Living Room", SCENE = "Off" })
  t.eq(sim.persist.roomHoldKinds and sim.persist.roomHoldKinds["Living Room"], "off", "hold kind off")
  sim.set_var(331, VAR, "0")
  sim.set_var(LUXDEV, LUXVAR, "0.3")
  sim.sent = {}
  keepOccupied(60)
  t.eq(firstOn(331), nil, "Off after the trigger holds (no re-trigger, no presence on)")
  sim.exec("ApplyScene", { ROOM = "Living Room", SCENE = "Off" })   -- a second Off the same evening
  t.eq(sim.persist.roomHoldKinds and sim.persist.roomHoldKinds["Living Room"], "off", "second Off still kind off")
  keepOccupied(15)
  t.eq(firstOn(331), nil, "still off after a second Off")
end)

t.test("B3+D: a walk-in ends an Off-scene hold and uses the fast walk-in fade", function()
  start(local_sec(19, 0), 0.3)
  sim.advance(6 * MIN)                       -- trigger fires (dark), room vacant
  sim.exec("ApplyScene", { ROOM = "Living Room", SCENE = "Off" })
  sim.sent = {}
  occupy()
  local on = firstOn(331)
  t.ok(on ~= nil, "walk-in turned the room on despite the Off hold")
  if on then t.eq(on.ms, 2000, "walk-in uses fadeInSec") end
  t.eq(sim.persist.roomHolds and sim.persist.roomHolds["Living Room"], nil, "Off hold released")
end)

t.finish("dls-dusk-lux")
