-- DLS offline alert (1.16.3): a light that confirmed before a reload can still be flagged afterwards, and a
-- hand on the dimmer is not an outage.
-- Run: python tools/c4sim/run.py test dls_offline_reload
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local TOK = "tok"
local PORT = "8730"
local K = 101
local VAR = 1001
local SEC = 1000
local EPOCH = 1767225600

local function local_sec(h, m)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local ROOMS = '[{"name":"Kitchen","key":"Kitchen","min_level":60,"max_level":60,' ..
  '"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'

C4.ServerSend = function() end
C4.ServerCloseClient = function() end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data) sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000) end
local function fired(name)
  for _, e in ipairs(sim.events or {}) do if e.id == name then return true end end
  return false
end

local function start(persist, keep_var)
  local props = { ["Presence Lighting"] = "On", ["Presence Token"] = TOK, ["Presence Port"] = PORT,
    ["Rooms JSON"] = ROOMS, ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1",
    ["Light Timeout (sec)"] = "12" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, persist = persist, start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(K, VAR, keep_var and "60" or "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(185 * SEC)
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", "0", "clear", TOK))
  sim.events = {}
  return ok
end

local function confirm_on()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  sim.set_var(K, VAR, "60")
  sim.advance(4 * SEC)
end

local function go_silent()
  send(ln("OCC", "Kitchen", "0", "clear", TOK))     -- off delay 10 s, then a fade the light never performs
  sim.advance(40 * SEC)
end

t.test("a confirmed light is still flagged after a reload", function()
  start()
  confirm_on()
  local persist = sim.persist
  start(persist, true)                              -- reload with the light still at 60: fbSeen comes from PersistData
  go_silent()
  t.ok(fired("Light Not Responding"), "flagged after the reload")
  t.eq(sim._store["Offline Lights"], "101", "listed in Offline Lights")
  t.ok(tostring(sim._store["Status"]):find("not responding", 1, true) ~= nil, "Status carries the note")
end)

t.test("a hand on the dimmer is not an outage", function()
  start()
  confirm_on()
  sim.events = {}
  sim.set_var(K, VAR, "35")                         -- user dims while a fade is outstanding
  sim.call("OnWatchedVariableChanged", K, VAR, "35")
  sim.advance(40 * SEC)
  t.ok(not fired("Light Not Responding"), "no false alert for a manual change")
end)

t.finish("dls-offline-reload")
