-- DLS offline-light alert (1.14.0): a light that never confirms a level command is flagged once,
-- appears in "Offline Lights", and is cleared when it obeys again.
-- Run: python tools/c4sim/run.py test dls_offline
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
  '"presence":{"follow":true,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'

local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000)
  return table.concat(replies)
end

local function fired(name)
  for _, e in ipairs(sim.events or {}) do if e.id == name then return true end end
  return false
end

local function start()
  local props = { ["Presence Lighting"] = "On", ["Presence Port"] = PORT, ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
    ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1",
    ["Light Timeout (sec)"] = "12" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(K, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", "0", "clear", TOK))
  sim.events = {}
  return ok
end

t.test("a light that never confirms is reported once and listed", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))       -- commands the light to the room target
  sim.set_var(K, VAR, "60")                          -- first command confirmed: the light works
  sim.advance(3 * SEC)
  send(ln("OCC", "Kitchen", "0", "clear", TOK))      -- fade to 0; the light now goes silent
  sim.advance(45 * SEC)                              -- off delay + fade + 12 s timeout
  t.ok(fired("Light Not Responding"), "Light Not Responding fired")
  t.eq(sim._store["Offline Lights"], "101", "Offline Lights names the light")
end)

t.test("recovery clears the alert and fires once", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  sim.set_var(K, VAR, "60")
  sim.advance(3 * SEC)
  send(ln("OCC", "Kitchen", "0", "clear", TOK))
  sim.advance(45 * SEC)
  t.ok(fired("Light Not Responding"), "still flagged while silent")
  sim.set_var(K, VAR, "0")                           -- the light obeys the fade
  sim.advance(2 * SEC)
  t.ok(fired("Light Responding Again"), "Light Responding Again fired")
  t.eq(sim._store["Offline Lights"], "", "Offline Lights cleared")
end)

t.finish("dls-offline")
