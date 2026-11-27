-- DLS vacation pattern (1.15.0): deterministic per-day off-time jitter, off by default, never crosses noon.
-- Run: python tools/c4sim/run.py test dls_vacation
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local SEC = 1000
local EPOCH = 1767225600

local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local ROOMS = '[{"name":"Kitchen","key":"Kitchen","min_level":60,"max_level":60,' ..
  '"presence":{"warnLevelPct":0,"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"sources":["esp"]},"lights":[{"id":101,"kind":"lutron"}]}]'

C4.ServerSend = function() end
C4.ServerCloseClient = function() end

local function start()
  local props = { ["Rooms JSON"] = ROOMS, ["Presence"] = "Home",
    ["Latitude"] = "51.5", ["Longitude"] = "-0.1" }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = 12 * 3600 * SEC,
    before = function(s) s.set_var(101, 1001, "0") end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  local hook = sim.env.DLS_vacation or _G.DLS_vacation
  t.ok(type(hook) == "table", "test hook exported")
  return hook
end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

t.test("vacation off leaves the off time exactly as scheduled", function()
  local v = start()
  local now = EPOCH + 12 * 3600
  t.eq(v.shift(1380, now), 1380, "23:00 stays 23:00")
end)

t.test("vacation on shifts the off time, stable within the day and inside the jitter", function()
  local v = start()
  setprop("Vacation Pattern", "On")
  setprop("Vacation Jitter (min)", "15")
  local now = EPOCH + 12 * 3600
  local a = v.shift(1380, now)
  local b = v.shift(1380, now)
  t.ok(a >= 1380 and a <= 1395, "within 0..15 minutes: got " .. tostring(a))
  t.eq(b, a, "same day, same shift")
end)

t.test("the shift changes from day to day", function()
  local v = start()
  setprop("Vacation Pattern", "On")
  setprop("Vacation Jitter (min)", "15")
  local seen, distinct = {}, 0
  for d = 0, 9 do
    local now = EPOCH + (12 * 3600) + d * 86400
    local o = v.offset(now)
    t.ok(o >= 0 and o <= 15, "offset in range on day " .. d)
    if not seen[o] then seen[o] = true; distinct = distinct + 1 end
  end
  t.ok(distinct > 1, "jitter varies across 10 days")
end)

t.test("the shift never crosses noon", function()
  local v = start()
  setprop("Vacation Pattern", "On")
  setprop("Vacation Jitter (min)", "60")
  local now = EPOCH + 12 * 3600
  t.ok(v.shift(700, now) < 720, "morning off stays before noon")
  t.ok(v.shift(1400, now) < 1440, "evening off stays inside the day")
end)

t.finish("dls-vacation")
