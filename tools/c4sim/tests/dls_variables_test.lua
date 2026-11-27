-- DLS 1.16.23/1.16.24: read-only Control4 variables for outcome checks (c4-bridge reads item variables).
-- LAST_ON_EDGE, LAST_OFF_EDGE, OFF_RAMP_DONE, PRESENCE, LAST_ERROR, HEARTBEAT.
-- Time format: local "YYYY-MM-DDTHH:MM:SS", edges and ramp add " <room>" (ramp may add " skipped:<reason>").
-- Run: python tools/c4sim/run.py test dls_variables
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = os.getenv("DLS_DRV") or "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600
local NAMES = { "LAST_ON_EDGE", "LAST_OFF_EDGE", "OFF_RAMP_DONE", "PRESENCE", "LAST_ERROR", "HEARTBEAT" }
local ISO = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"
local TOK, PORT = "tok", "8731"

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end

local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

-- Capture the full AddVariable call (the sim stub keeps only name and value).
local added = {}
local realAdd = C4.AddVariable
C4.AddVariable = function(self, name, value, vtype, readOnly, hidden)
  added[#added + 1] = { name = name, value = value, vtype = vtype, readOnly = readOnly, hidden = hidden }
  return realAdd(self, name, value)
end

C4.ServerSend = function() end
C4.ServerCloseClient = function() end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data) sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000) end

local function v(name) return sim.dvars[name] end

local function den(ramp)
  return '[{"name":"Den","type":"mixed","on":"16:00","off":"16:30"' ..
    (ramp and (',"off_ramp_min":' .. ramp) or '') .. ',' ..
    '"lights":[{"id":480,"kind":"lifx"},{"id":476,"kind":"lifx"}]}]'
end
local ROOMS = den(3)

local function start(h, m, persist, rooms, extra)
  added = {}
  local props = {
    ["Enabled"] = "On",
    ["Update Interval (min)"] = "1",
    ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "120",
    ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "40",
    ["Longitude"] = "-75",
    ["Rooms JSON"] = rooms or ROOMS,
  }
  for k, val in pairs(extra or {}) do props[k] = val end
  local ok = sim.load_driver(DRV, {
    xml = XML,
    persist = persist,
    properties = props,
    start_ms = local_sec(h, m) * SEC,
    before = function(s)
      s.set_var(480, VAR, "0")
      s.set_var(476, VAR, "0")
      s.set_var(101, VAR, "0")
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
end

local function hhmm(val) return val and string.sub(val, 12, 16) end
local function lit(level)
  sim.set_var(480, VAR, tostring(level))
  sim.set_var(476, VAR, tostring(level))
end

-- Exact command list for a full on/off day (16:00 on, 16:30 off, 3 min stepped fade), captured by running this
-- scenario against 1.16.22 (141ace4, no variables). The variables must not add, drop or change any command.
local EXPECTED = {
    "75600 device 480 RAMP_TO_LEVEL LEVEL=75,TIME=90000",
    "75600 device 480 SET_COLOR_TARGET LIGHT_COLOR_TARGET_MODE=1,LIGHT_COLOR_TARGET_RATE=90000,LIGHT_COLOR_TARGET_X=0.45931395234466,LIGHT_COLOR_TARGET_Y=0.41066024937842",
    "75600 device 476 RAMP_TO_LEVEL LEVEL=75,TIME=90000",
    "75600 device 476 SET_COLOR_TARGET LIGHT_COLOR_TARGET_MODE=1,LIGHT_COLOR_TARGET_RATE=90000,LIGHT_COLOR_TARGET_X=0.45931395234466,LIGHT_COLOR_TARGET_Y=0.41066024937842",
    "75660 device 480 RAMP_TO_LEVEL LEVEL=75,TIME=90000",
    "75660 device 476 RAMP_TO_LEVEL LEVEL=75,TIME=90000",
    "75720 device 480 RAMP_TO_LEVEL LEVEL=75,TIME=90000",
    "75720 device 476 RAMP_TO_LEVEL LEVEL=75,TIME=90000",
    "75780 device 480 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "75780 device 476 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "75840 device 480 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "75840 device 476 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "75900 device 480 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "75900 device 476 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "75960 device 480 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "75960 device 476 RAMP_TO_LEVEL LEVEL=76,TIME=90000",
    "76020 device 480 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76020 device 476 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76080 device 480 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76080 device 476 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76140 device 480 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76140 device 476 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76200 device 480 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76200 device 476 RAMP_TO_LEVEL LEVEL=77,TIME=90000",
    "76260 device 480 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76260 device 476 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76320 device 480 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76320 device 476 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76380 device 480 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76380 device 476 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76440 device 480 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76440 device 476 RAMP_TO_LEVEL LEVEL=78,TIME=90000",
    "76500 device 480 RAMP_TO_LEVEL LEVEL=79,TIME=90000",
    "76500 device 476 RAMP_TO_LEVEL LEVEL=79,TIME=90000",
    "76560 device 480 RAMP_TO_LEVEL LEVEL=79,TIME=90000",
    "76560 device 476 RAMP_TO_LEVEL LEVEL=79,TIME=90000",
    "76620 device 480 RAMP_TO_LEVEL LEVEL=79,TIME=90000",
    "76620 device 476 RAMP_TO_LEVEL LEVEL=79,TIME=90000",
    "76680 device 480 RAMP_TO_LEVEL LEVEL=80,TIME=90000",
    "76680 device 476 RAMP_TO_LEVEL LEVEL=80,TIME=90000",
    "76740 device 480 RAMP_TO_LEVEL LEVEL=80,TIME=90000",
    "76740 device 476 RAMP_TO_LEVEL LEVEL=80,TIME=90000",
    "76800 device 480 RAMP_TO_LEVEL LEVEL=80,TIME=90000",
    "76800 device 476 RAMP_TO_LEVEL LEVEL=80,TIME=90000",
    "76860 device 480 RAMP_TO_LEVEL LEVEL=81,TIME=90000",
    "76860 device 476 RAMP_TO_LEVEL LEVEL=81,TIME=90000",
    "76920 device 480 RAMP_TO_LEVEL LEVEL=81,TIME=90000",
    "76920 device 476 RAMP_TO_LEVEL LEVEL=81,TIME=90000",
    "76980 device 480 RAMP_TO_LEVEL LEVEL=81,TIME=90000",
    "76980 device 476 RAMP_TO_LEVEL LEVEL=81,TIME=90000",
    "77040 device 480 RAMP_TO_LEVEL LEVEL=82,TIME=90000",
    "77040 device 476 RAMP_TO_LEVEL LEVEL=82,TIME=90000",
    "77100 device 480 RAMP_TO_LEVEL LEVEL=82,TIME=90000",
    "77100 device 476 RAMP_TO_LEVEL LEVEL=82,TIME=90000",
    "77160 device 480 RAMP_TO_LEVEL LEVEL=82,TIME=90000",
    "77160 device 476 RAMP_TO_LEVEL LEVEL=82,TIME=90000",
    "77220 device 480 RAMP_TO_LEVEL LEVEL=83,TIME=90000",
    "77220 device 476 RAMP_TO_LEVEL LEVEL=83,TIME=90000",
    "77280 device 480 RAMP_TO_LEVEL LEVEL=83,TIME=90000",
    "77280 device 476 RAMP_TO_LEVEL LEVEL=83,TIME=90000",
    "77340 device 480 RAMP_TO_LEVEL LEVEL=84,TIME=90000",
    "77340 device 476 RAMP_TO_LEVEL LEVEL=84,TIME=90000",
    "77400 device 480 RAMP_TO_LEVEL LEVEL=56,TIME=60000",
    "77400 device 476 RAMP_TO_LEVEL LEVEL=56,TIME=60000",
    "77460 device 480 RAMP_TO_LEVEL LEVEL=28,TIME=60000",
    "77460 device 476 RAMP_TO_LEVEL LEVEL=28,TIME=60000",
    "77520 device 480 RAMP_TO_LEVEL LEVEL=0,TIME=60000",
    "77520 device 476 RAMP_TO_LEVEL LEVEL=0,TIME=60000",
    "77640 device 480 RAMP_TO_LEVEL LEVEL=0,TIME=90000",
    "77640 device 476 RAMP_TO_LEVEL LEVEL=0,TIME=90000",
    "77940 device 480 RAMP_TO_LEVEL LEVEL=0,TIME=90000",
    "77940 device 476 RAMP_TO_LEVEL LEVEL=0,TIME=90000",
}

local function sentList()
  local got = {}
  for _, s in ipairs(sim.sent) do
    local p = s.params or {}
    local keys = {}
    for k in pairs(p) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(p[k]) end
    got[#got + 1] = string.format("%d %s %s %s %s", math.floor((s.t or 0) / 1000), tostring(s.kind),
      tostring(s.id), tostring(s.cmd), table.concat(parts, ","))
  end
  return got
end

local function day()
  start(15, 50)
  sim.advance(39 * MIN)                                 -- 16:29, on edge and daylight steps sent
  lit(84)                                               -- lights report the last level DLS sent
  sim.advance(11 * MIN)                                 -- 16:30 off edge, 3 min stepped fade, to 16:40
  return sentList()
end

if os.getenv("DLS_DUMP") then
  print("DRV " .. DRV)
  for _, g in ipairs(day()) do print(string.format("    %q,", g)) end
  return
end

t.test("1: all six variables are added read-only STRING once per load, heartbeat and presence set", function()
  start(15, 0)
  for _, name in ipairs(NAMES) do
    local count, found = 0, nil
    for _, a in ipairs(added) do if a.name == name then found = a; count = count + 1 end end
    t.eq(count, 1, name .. " added exactly once (Init only, LateInit skips AddVariable)")
    if found then
      t.eq(found.vtype, "STRING", name .. " type")
      t.eq(found.readOnly, true, name .. " read-only")
    end
    t.ok(v(name) ~= nil, name .. " has a value")
  end
  t.eq(v("PRESENCE"), "HOME", "PRESENCE HOME")
  t.ok(v("HEARTBEAT"):match(ISO .. "$") ~= nil, "HEARTBEAT ISO time: " .. tostring(v("HEARTBEAT")))
  t.eq(hhmm(v("HEARTBEAT")), "15:00", "HEARTBEAT written at load")
  t.eq(v("LAST_ERROR"), "", "LAST_ERROR empty")
  t.eq(v("LAST_ON_EDGE"), "", "no on edge yet")
end)

t.test("2: heartbeat rewritten every 5 minutes", function()
  start(15, 0)
  sim.advance(4 * MIN + 59 * SEC)
  t.eq(hhmm(v("HEARTBEAT")), "15:00", "unchanged before 5 min")
  sim.advance(2 * SEC)
  t.eq(hhmm(v("HEARTBEAT")), "15:05", "rewritten at 5 min")
  sim.advance(10 * MIN)
  t.eq(hhmm(v("HEARTBEAT")), "15:15", "still running")
end)

t.test("3: on edge, off edge and stepped off ramp done carry time and room", function()
  start(15, 50)
  sim.advance(3 * MIN)                                  -- 15:53, first passes off-window
  t.eq(v("LAST_ON_EDGE"), "", "no edge before the on time")
  sim.advance(9 * MIN)                                  -- 16:02
  local on = v("LAST_ON_EDGE")
  t.ok(on:match(ISO .. " Den$") ~= nil, "LAST_ON_EDGE format: " .. tostring(on))
  t.ok(hhmm(on) == "16:00" or hhmm(on) == "16:01", "on edge at 16:00/16:01: " .. tostring(on))
  lit(40)
  sim.advance(29 * MIN)                                 -- 16:31
  local off = v("LAST_OFF_EDGE")
  t.ok(off:match(ISO .. " Den$") ~= nil, "LAST_OFF_EDGE format: " .. tostring(off))
  t.ok(hhmm(off) == "16:30" or hhmm(off) == "16:31", "off edge at 16:30/16:31: " .. tostring(off))
  t.eq(v("OFF_RAMP_DONE"), "", "3 min stepped fade not done yet")
  sim.advance(5 * MIN)                                  -- 16:36
  local done = v("OFF_RAMP_DONE")
  t.ok(done:match(ISO .. " Den$") ~= nil, "OFF_RAMP_DONE format: " .. tostring(done))
  t.ok(done > off, "ramp done after the off edge")
  t.eq(v("LAST_ON_EDGE"), on, "on edge unchanged")
end)

t.test("4: a reload in the on window restores values and is not an on edge; heartbeat not restored", function()
  start(15, 50)
  sim.advance(12 * MIN)                                 -- 16:02, on edge recorded
  local on = v("LAST_ON_EDGE")
  t.ok(on ~= "", "on edge recorded before reload")
  start(16, 10, sim.persist)                            -- reload inside the on window
  t.eq(v("LAST_ON_EDGE"), on, "LAST_ON_EDGE restored, not a new edge")
  sim.advance(5 * MIN)
  t.eq(v("LAST_ON_EDGE"), on, "first pass after reload is not an edge")
  local onAdd, hbAdd
  for _, a in ipairs(added) do
    if a.name == "LAST_ON_EDGE" then onAdd = a end
    if a.name == "HEARTBEAT" then hbAdd = a end
  end
  t.ok(onAdd and onAdd.value == on and onAdd.readOnly == true, "re-added read-only with the persisted value")
  t.ok(hbAdd and hbAdd.value == "", "HEARTBEAT added as empty, not restored")
  t.eq(hhmm(v("HEARTBEAT")), "16:15", "heartbeat from this load only")
end)

t.test("5: a reload in the off window is not an off edge and writes no ramp", function()
  start(15, 50)
  sim.advance(12 * MIN)
  lit(40)
  sim.advance(34 * MIN)                                 -- 16:36, off edge and ramp done
  local off, done = v("LAST_OFF_EDGE"), v("OFF_RAMP_DONE")
  t.ok(off ~= "" and done ~= "", "edge and ramp recorded before reload")
  local persist = sim.persist
  start(17, 0, persist)
  sim.advance(10 * MIN)
  t.eq(v("LAST_OFF_EDGE"), off, "LAST_OFF_EDGE unchanged after an off-window reload")
  t.eq(v("OFF_RAMP_DONE"), done, "OFF_RAMP_DONE unchanged after an off-window reload")
end)

t.test("6: PRESENCE follows SetPresence", function()
  start(15, 0)
  sim.exec("SetPresence", { PRESENT = "AWAY" })
  t.eq(v("PRESENCE"), "AWAY", "AWAY")
  sim.exec("SetPresence", { PRESENT = "HOME" })
  t.eq(v("PRESENCE"), "HOME", "HOME")
end)

t.test("7: Update error in LAST_ERROR, 500 chars capped to 220, same message not rewritten within 60 s", function()
  start(15, 0)
  sim.env.Update = function() error(string.rep("x", 500), 0) end
  sim.advance(20 * SEC)                                 -- 15:00:02 (load property pass) fails, 15:00:15 again
  local e1 = v("LAST_ERROR")
  t.ok(e1:match(ISO .. " Update: x") ~= nil, "LAST_ERROR format: " .. string.sub(tostring(e1), 1, 40))
  t.eq(#e1, 220, "19 time + 1 space + 200 message")
  t.eq(string.sub(e1, 12, 19), "15:00:02", "first error time; the 15:00:15 pass, same message, is not rewritten")
  sim.call("OnPropertyChanged", "Debug")                -- another Update 2 s later (15:00:22), same error
  sim.advance(5 * SEC)
  t.eq(v("LAST_ERROR"), e1, "same message within 60 s not rewritten")
  sim.advance(40 * SEC)                                 -- 15:01:00 main timer, 58 s after the first
  t.eq(v("LAST_ERROR"), e1, "still within 60 s")
  sim.advance(60 * SEC)                                 -- 15:02:00, 118 s after the first
  t.eq(string.sub(v("LAST_ERROR"), 12, 19), "15:02:00", "rewritten after 60 s")
  sim.env.Update = function() error("other", 0) end
  sim.advance(60 * SEC)
  t.ok(v("LAST_ERROR"):match(ISO .. " Update: other$") ~= nil, "a new message is written at once")
end)

t.test("8: daylight room loaded after noon-60 still reports its on edge", function()
  start(13, 0, nil, '[{"name":"Dusk","type":"mixed","on_daylight":0.3,"off":"23:30",' ..
    '"lights":[{"id":480,"kind":"lifx"},{"id":476,"kind":"lifx"}]}]')
  sim.advance(2 * MIN)
  t.eq(v("LAST_ON_EDGE"), "", "no edge in daylight")
  sim.advance(6 * 60 * MIN)                             -- 19:02, past dusk
  local on = v("LAST_ON_EDGE")
  t.ok(on:match(ISO .. " Dusk$") ~= nil, "daylight on edge recorded: " .. tostring(on))
  t.ok(hhmm(on) > "15:00" and hhmm(on) < "18:00", "edge time near dusk: " .. tostring(on))
end)

t.test("9: short ramp (<= 2 min) marks OFF_RAMP_DONE at the edge", function()
  start(15, 50, nil, den(nil))
  sim.advance(12 * MIN)
  lit(40)
  sim.advance(30 * MIN)                                 -- 16:32
  local off = v("LAST_OFF_EDGE")
  t.ok(off ~= "", "off edge recorded")
  t.eq(v("OFF_RAMP_DONE"), off, "ramp done at the edge, same time and room")
end)

t.test("10: an off edge with nothing lit marks OFF_RAMP_DONE at the edge", function()
  start(15, 50)
  sim.advance(12 * MIN)
  lit(0)
  sim.advance(30 * MIN)                                 -- 16:32
  local off = v("LAST_OFF_EDGE")
  t.ok(off ~= "", "off edge recorded")
  t.eq(v("OFF_RAMP_DONE"), off, "nothing to fade: done at the edge")
end)

t.test("11: a stepped fade finished by presence away writes OFF_RAMP_DONE", function()
  start(15, 50, nil, den(10))
  sim.advance(12 * MIN)
  lit(40)
  sim.advance(30 * MIN + 30 * SEC)                      -- 16:32:30, fade running
  t.ok(v("LAST_OFF_EDGE") ~= "", "off edge recorded")
  t.eq(v("OFF_RAMP_DONE"), "", "10 min fade still running")
  sim.exec("SetPresence", { PRESENT = "AWAY" })
  sim.advance(2 * MIN)
  local done = v("OFF_RAMP_DONE")
  t.ok(done:match(ISO .. " Den$") ~= nil, "ramp done by the away finish: " .. tostring(done))
  t.ok(hhmm(done) < "16:40", "before the full 10 min: " .. tostring(done))
end)

t.test("12: presence-owned room: off edge writes OFF_RAMP_DONE skipped:presence", function()
  start(15, 50, nil, '[{"name":"Kitchen","key":"Kitchen","on":"16:00","off":"16:30",' ..
    '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
    '"lights":[{"id":101,"kind":"lutron"}]}]',
    { ["Presence Port"] = PORT, ["Presence Token"] = TOK, ["Presence"] = "Home", ["Presence Lighting"] = "On" })
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", "0", "clear", TOK))
  sim.advance(12 * MIN)
  t.ok(v("LAST_ON_EDGE"):match(" Kitchen$") ~= nil, "presence-owned room still reports the on edge")
  sim.advance(30 * MIN)                                 -- 16:32
  local off = v("LAST_OFF_EDGE")
  t.ok(off:match(" Kitchen$") ~= nil, "off edge recorded: " .. tostring(off))
  t.eq(v("OFF_RAMP_DONE"), off .. " skipped:presence", "skipped ramp is told apart from a missed one")
end)

t.test("13: the variables change no light command (exact sent list vs 1.16.22)", function()
  local got = day()
  t.ok(#EXPECTED > 0, "expected list present")
  t.eq(#got, #EXPECTED, "same number of commands")
  for i = 1, math.max(#got, #EXPECTED) do
    t.eq(got[i], EXPECTED[i], "command " .. i)
  end
end)

t.finish("dls-variables")
