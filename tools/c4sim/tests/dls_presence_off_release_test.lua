-- DLS Presence Lighting Off (1.16.4): the room is genuinely handed back to the schedule — no presence fade
-- while the switch is Off, and the scheduled off still happens.
-- Written first, against the known defect: it fails on 1.16.3.
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

local function any_command()
  for _, s in ipairs(sim.sent or {}) do if s.id == K then return true end end
  return false
end

local function start()
  local props = { ["Presence Lighting"] = "On", ["Presence Port"] = PORT, ["Presence Token"] = TOK,
    ["Rooms JSON"] = ROOMS, ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" }
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

local function fired_vacant()
  for _, e in ipairs(sim.events or {}) do if e.id == "Room Vacant" then return true end end
  return false
end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

t.test("with the switch Off presence commands nothing", function()
  start()
  setprop("Presence Lighting", "Off")
  sim.sent = {}
  sim.advance(20 * 60 * SEC)                -- 12:35 -> 12:55, still inside the on window
  t.ok(not ramp_to(0), "no presence fade to 0 while the switch is Off")
end)

t.test("the schedule still turns the room off at its own off time", function()
  start()
  setprop("Presence Lighting", "Off")
  sim.sent = {}
  sim.advance(24 * 60 * SEC)                -- to 12:59
  t.ok(not ramp_to(0), "no fade to 0 before the scheduled off")
  sim.sent = {}
  sim.advance(5 * 60 * SEC)                 -- past 13:00
  t.ok(ramp_to(0), "scheduled off happened")
end)

t.test("a per-light hand hold does not block the room release", function()
  start()
  sim.fire_var(K, VAR, "35")       -- one light dimmed by hand: per-light hold
  sim.advance(3 * SEC)
  sim.events = {}
  setprop("Presence Lighting", "Off")
  t.ok(fired_vacant(), "the room is still released")
end)

t.finish("dls-presence-off-release")

