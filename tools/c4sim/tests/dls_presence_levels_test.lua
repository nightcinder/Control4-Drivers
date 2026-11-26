-- 1.17.2: presence "levels" = fixed walk-in levels by time of day for a follow room, no lux loop.
-- Run: uv run python tools/c4sim/run.py test dls_presence_levels
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
local function levels(id)
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then out[#out + 1] = tonumber(s.params.LEVEL) end
  end
  return out
end

local function start(at, lux)
  local rooms = '[{"name":"Laundry","key":"Laundry","on":"06:30","off":"23:00",' ..
    '"presence":{"follow":true,"manualHold":"level","offDelaySec":60,"fadeOutSec":5,"nightLevel":10,' ..
    '"levels":[{"at":"06:30","level":80},{"at":"21:00","level":20}],"sources":["esp"]},' ..
    (lux and '"lux":{"dev":602,"var":1015,"target":4},' or '') ..
    '"lights":[{"id":101,"kind":"lutron"}]}]'
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "30",
    ["Override Hold (min)"] = "5", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "40.8", ["Longitude"] = "-81.5", ["Presence"] = "Home", ["Presence Lighting"] = "On",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = rooms,
  }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, before = function(s)
    s.set_var(101, VAR, "0"); s.set_var(602, 1015, "40")
  end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Laundry", "0", "clear", TOK))
  sim.advance(5 * SEC)
  sim.sent = {}
  return ok
end

local function enter()
  send(ln("OCC", "Laundry", "1", "esp", TOK))
  sim.advance(10 * SEC)
end

t.test("P1: daytime walk-in goes straight to 80", function()
  start(local_sec(10, 0), true)
  enter()
  local lv = levels(101)
  t.eq(lv[1], 80, "first command is 80")
end)

t.test("P2: evening walk-in goes straight to 20", function()
  start(local_sec(21, 30), true)
  enter()
  t.eq(levels(101)[1], 20, "first command is 20")
end)

t.test("P3: level holds for the visit, the lux sensor does not move it", function()
  start(local_sec(10, 0), true)
  enter()
  sim.set_var(602, 1015, "200")
  sim.sent = {}
  sim.advance(10 * 60 * SEC)
  for _, v in ipairs(levels(101)) do t.ok(v == 80 or v == 0, "no loop step, got " .. tostring(v)) end
end)

t.test("P4: after midnight the evening level carries over", function()
  start(local_sec(1, 0), false)
  enter()
  t.eq(levels(101)[1], 20, "01:00 uses the 21:00 entry")
end)

t.finish("dls-presence-levels")
