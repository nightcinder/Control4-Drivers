-- 1.17.3: an occupied follow room glides down to nightLevel at its off edge (stepped, off_ramp_min) instead of a
-- 2 s drop, and "nightAfterDark" keeps the off-window walk-in dark while the sun is up.
-- Run: uv run python tools/c4sim/run.py test dls_presence_glide
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
local function times(id)
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then out[#out + 1] = tonumber(s.params.TIME) end
  end
  return out
end

local function start(at)
  local rooms = '[{"name":"Living Room","key":"LivingRoom","type":"lutron","on":"18:00","off":"23:30",' ..
    '"off_ramp_min":10,"min_level":20,' ..
    '"presence":{"follow":true,"offDelaySec":1200,"fadeInSec":2,"fadeOutSec":30,"nightLevel":5,' ..
    '"nightAfterDark":true,"sources":["esp"]},' ..
    '"lights":[{"id":101,"kind":"lutron"}]}]'
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "30",
    ["Override Hold (min)"] = "5", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "40.8", ["Longitude"] = "-81.5", ["Presence"] = "Home", ["Presence Lighting"] = "On",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = rooms,
  }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, before = function(s)
    s.set_var(101, VAR, "0")
  end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "LivingRoom", "0", "clear", TOK))
  sim.advance(5 * SEC)
  sim.sent = {}
  return ok
end

local function enter()
  send(ln("OCC", "LivingRoom", "1", "esp", TOK))
  sim.advance(10 * SEC)
end

-- feedback follows commands so curLevel() sees the light as on
local function mirror()
  local lv = levels(101)
  if #lv > 0 then sim.set_var(101, VAR, tostring(lv[#lv])) end
end

t.test("G1: occupied at the off edge glides down in steps and stops at nightLevel", function()
  start(local_sec(23, 20))
  enter()
  local first = levels(101)[1]
  t.ok(first and first > 5, "in-window level above night level, got " .. tostring(first))
  mirror()
  sim.sent = {}
  for _ = 1, 25 do   -- the bridge keeps reporting occupied (feed silence would start the vacancy delay)
    send(ln("OCC", "LivingRoom", "1", "esp", TOK)); sim.advance(60 * SEC); mirror()
  end
  local lv = levels(101)
  t.ok(#lv >= 3, "several glide steps, got " .. tostring(#lv))
  for _, v in ipairs(lv) do t.ok(v >= 5, "never under night level, got " .. tostring(v)) end
  t.eq(lv[#lv], 5, "ends at night level")
  for _, ms in ipairs(times(101)) do t.ok(ms >= 60000, "each step glides 60 s, got " .. tostring(ms)) end
end)

t.test("G2: a walk-in after midnight goes straight to nightLevel with the fast fade", function()
  start(local_sec(1, 0))
  enter()
  t.eq(levels(101)[1], 5, "01:00 walk-in is 5")
  t.eq(times(101)[1], 2000, "2 s walk-in fade")
end)

t.test("G3: nightAfterDark keeps a sunny off-window walk-in dark", function()
  start(local_sec(14, 0))
  enter()
  for _, v in ipairs(levels(101)) do t.eq(v, 0, "no light at 14:00") end
end)

t.test("G4: vacancy during the glide ends at 0", function()
  start(local_sec(23, 20))
  enter()
  mirror()
  for _ = 1, 12 do sim.advance(60 * SEC); mirror() end
  sim.sent = {}
  send(ln("OCC", "LivingRoom", "0", "clear", TOK))
  for _ = 1, 22 do sim.advance(60 * SEC); mirror() end
  local lv = levels(101)
  t.eq(lv[#lv], 0, "faded to 0 after the 20 min vacancy delay")
end)

t.finish("dls-presence-glide")
