-- DLS Presence Lighting Off (1.16.0): release presence-driven rooms back to the schedule, keep manual holds.
-- See docs/presence-lighting-off.md.
-- Run: python tools/c4sim/run.py test dls_presence_off
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
  '"presence":{"warnLevelPct":0,"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},' ..
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
  local props = { ["Presence Port"] = PORT, ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
    ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1",
    ["Presence Lighting"] = "On" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(K, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", "0", "clear", TOK))
  sim.events = {}
  return ok
end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

local function occupied()
  sim.advance(185 * SEC)            -- the post-load gate must expire before presence drives
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  sim.set_var(K, VAR, "60")
  sim.advance(4 * SEC)
end

t.test("switching presence off releases the room and fires Room Vacant", function()
  start()
  occupied()
  sim.events = {}
  setprop("Presence Lighting", "Off")
  t.ok(fired("Room Vacant"), "Room Vacant fired for the released room")
  local st = sim.persist and sim.persist.presence and sim.persist.presence["Kitchen"]
  t.ok(not st or st.state == nil or st.state == "VACANT", "room is back to VACANT")
end)

t.test("a manual off-hold survives the release", function()
  start()
  occupied()
  sim.fire_var(K, VAR, "60")        -- the light confirms the on level first
  sim.advance(3 * SEC)
  sim.fire_var(K, VAR, "0")         -- hand off in an occupied room: HOLD
  sim.advance(2 * SEC)
  local before = sim.persist and sim.persist.presence and sim.persist.presence["Kitchen"]
  t.eq(before and before.state, "HOLD", "manual off produced HOLD")
  sim.events = {}
  setprop("Presence Lighting", "Off")
  local st = sim.persist and sim.persist.presence and sim.persist.presence["Kitchen"]
  t.ok(st and st.state == "HOLD", "HOLD kept, not released")
end)

t.test("presence back on re-occupies the room after the gate", function()
  start()
  occupied()
  setprop("Presence Lighting", "Off")
  setprop("Presence Lighting", "On")
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  sim.advance(3 * SEC)
  local st = sim.persist and sim.persist.presence and sim.persist.presence["Kitchen"]
  t.ok(st and st.state == "OCCUPIED", "room is driven again after the switch returns to On")
end)

t.finish("dls-presence-off")
