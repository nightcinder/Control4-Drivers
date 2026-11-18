-- DLS Presence Lighting Off (1.16.1): the room is genuinely handed back to the schedule — no presence fade
-- while the switch is Off, and the scheduled off still happens.
-- Run: python tools/c4sim/run.py test dls_presence_off_release
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

local ROOMS = '[{"name":"Kitchen","key":"Kitchen","on":"12:00","off":"13:00","min_level":60,"max_level":60,' ..
  '"presence":{"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'

local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "10.0.0.5", 50000)
  return table.concat(replies)
end

local function ramp_to(level)
  for _, s in ipairs(sim.sent or {}) do
    if s.id == K and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == level then return true end
  end
  return false
end

local function start()
  local props = { ["Presence Port"] = PORT, ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
    ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1",
    ["Presence Lighting"] = "On" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, start_ms = local_sec(12, 30) * SEC,
    before = function(s) s.set_var(K, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.advance(185 * SEC)                    -- let the post-load gate expire
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", "1", "esp", TOK))
  sim.set_var(K, VAR, "60")
  sim.advance(4 * SEC)
  return ok
end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

t.test("with the switch Off presence no longer fades the room", function()
  start()
  setprop("Presence Lighting", "Off")
  sim.sent = {}
  sim.advance(20 * 60 * SEC)                -- 12:3x -> 12:5x, still inside the on window
  t.ok(not ramp_to(0), "no presence fade to 0 while the switch is Off")
end)

t.test("the schedule still turns the room off at its own off time", function()
  start()
  setprop("Presence Lighting", "Off")
  sim.sent = {}
  sim.advance(31 * 60 * SEC)                -- past 13:00
  t.ok(ramp_to(0), "scheduled off happened")
end)

t.finish("dls-presence-off-release")
