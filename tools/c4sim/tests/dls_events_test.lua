-- DLS programming events: Room Occupied / Room Vacant / Presence Home / Presence Away / Lighting Held.
-- DriverWorks events carry no parameters, so the room name rides on the "Last Event" property.
-- Run: python tools/c4sim/run.py test dls_events
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

local function fired(name)
  for _, e in ipairs(sim.events or {}) do
    if e.id == name then return true end
  end
  return false
end

local function count_fired(name)
  local n = 0
  for _, e in ipairs(sim.events or {}) do
    if e.id == name then n = n + 1 end
  end
  return n
end

local function last_event_prop()
  return sim._store and sim._store["Last Event"]
end

local function start()
  local props = { ["Presence Port"] = PORT, ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
    ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(K, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", "0", "clear", TOK))
  sim.events = {}
  return ok
end

t.test("presence away fires Presence Away and records it in Last Event", function()
  start()
  send(ln("PRESENCE", "AWAY", TOK))
  t.ok(fired("Presence Away"), "Presence Away fired")
  t.eq(last_event_prop(), "Away", "Last Event carries the new presence")
end)

t.test("presence home fires Presence Home", function()
  start()
  send(ln("PRESENCE", "AWAY", TOK))
  sim.events = {}
  send(ln("PRESENCE", "HOME", TOK))
  t.ok(fired("Presence Home"), "Presence Home fired")
  t.eq(last_event_prop(), "Home", "Last Event carries Home")
end)

t.test("room occupancy change fires Room Occupied with the room name", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.ok(fired("Room Occupied"), "Room Occupied fired")
  t.eq(last_event_prop(), "Kitchen", "Last Event names the room")
end)

t.test("occupancy events do not repeat while the room stays occupied", function()
  start()
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.eq(count_fired("Room Occupied"), 1, "one Room Occupied per transition")
end)

t.finish("dls-events")
