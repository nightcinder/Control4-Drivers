-- Open question C probe (documentation only; asserts TODAY's driver behaviour without changing it).
-- Non-follow presence room that is PR_VACANT with lights ON:
--   1) turned on by hand while vacant
--   2) on when Presence Lighting is switched Off -> On
--   3) on at driver reload
-- Run: uv run python tools/c4sim/run.py test dls_vacant_lights_on_probe
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

local function state_of(room)
  local p = sim.persist and sim.persist.presence
  return p and p[room] and p[room].state
end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

local function start(at, extra, before, persist)
  local rooms = '[{"name":"Kitchen","key":"Kitchen","on":"18:00","off":"22:00","min_level":60,"max_level":60,' ..
    '"presence":{"follow":false,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5},' ..
    '"lights":[{"id":101,"kind":"lutron"}]}]'
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "5", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "51.5", ["Longitude"] = "-0.1", ["Presence"] = "Home",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = rooms,
  }
  for k, v in pairs(extra or {}) do props[k] = v end
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, persist = persist, start_ms = at * SEC, before = before,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  return ok
end

t.test("C1: manual-on light while PR_VACANT is turned off at scheduled off", function()
  start(local_sec(21, 50), { ["Presence Lighting"] = "On" }, function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("0", "clear"))
  sim.advance(20 * SEC)
  t.eq(state_of("Kitchen"), "VACANT", "room starts PR_VACANT")

  sim.fire_var(101, VAR, "60")
  sim.sent = {}
  sim.advance(40 * 60 * SEC)                              -- to 22:30, past 5-min hold and 22:00 off
  t.ok(offs(101) >= 1, "manual-on light while PR_VACANT is turned off at the scheduled off (1.16.15)")
  t.eq(state_of("Kitchen"), "VACANT", "room remains PR_VACANT")
end)

t.test("C2: light on when Presence Lighting switches Off -> On is turned off at scheduled off", function()
  start(local_sec(21, 50), { ["Presence Lighting"] = "Off" }, function(s) s.set_var(101, VAR, "60") end)
  send(snapshot("0", "clear"))
  sim.advance(20 * SEC)

  setprop("Presence Lighting", "On")
  t.eq(state_of("Kitchen"), "VACANT", "room is PR_VACANT after switching Presence Lighting On")
  sim.sent = {}
  sim.advance(40 * 60 * SEC)                              -- to 22:30, past 22:00 off
  t.ok(offs(101) >= 1, "light on after Off -> On toggle is turned off at the scheduled off (1.16.15)")
  t.eq(state_of("Kitchen"), "VACANT", "room remains PR_VACANT")
end)

t.test("C3: light on at driver reload while PR_VACANT is turned off at scheduled off", function()
  start(local_sec(21, 48), { ["Presence Lighting"] = "On" }, function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("0", "clear"))
  local persist = sim.persist

  start(local_sec(21, 50), { ["Presence Lighting"] = "On" }, function(s) s.set_var(101, VAR, "60") end, persist)
  send(snapshot("0", "clear"))
  sim.advance(20 * SEC)
  t.eq(offs(101), 0, "no off sent on reconcile for PR_VACANT room")

  sim.sent = {}
  sim.advance(40 * 60 * SEC)                              -- to 22:30, past 22:00 off
  t.ok(offs(101) >= 1, "light on at reload while PR_VACANT is turned off at the scheduled off (1.16.15)")
  t.eq(state_of("Kitchen"), "VACANT", "room remains PR_VACANT")
end)

t.finish("dls-vacant-lights-on-probe")
