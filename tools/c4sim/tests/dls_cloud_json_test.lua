-- DLS cloud feed robustness: bad, truncated and empty Open-Meteo replies must not raise, must leave the
-- driver running, must keep the last good cloud cover, and must still produce a sane Status line.
-- Sun times are computed locally (no API), so only the cloud feed can be malformed.
-- Run: python tools/c4sim/run.py test dls_cloud_json
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600

local function local_sec(h, m)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local ROOMS = '[{"name":"Office","on":"06:00","off":"22:30","lights":[{"id":337,"kind":"lutron"}]}]'

local function status() return tostring(sim._store["Status"]) end

-- Load and answer the four startup polls (LateInit plus the Latitude, Longitude and Cloud Cover Source
-- property changes) with a good reading of 100%.
local function start()
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = ROOMS, ["Latitude"] = "40", ["Longitude"] = "-75", ["Cloud Cover Source"] = "Open-Meteo (internet)" },
    start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(337, VAR, "40") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  for _ = 1, 4 do sim.queue_http("open%-meteo", '{"current":{"cloud_cover":100}}', 200) end
  sim.advance(3 * SEC)
  t.ok(status():find("cloud: 100%%") ~= nil, "the good reading is shown (" .. status() .. ")")
end

-- Ask again, answer with body/code, and let the callback and the suspended Update run.
local function poll(body, code)
  sim.queue_http("open%-meteo", body, code or 200)
  sim.Properties["Cloud Cover Source"] = "Open-Meteo (internet)"
  sim.call("OnPropertyChanged", "Cloud Cover Source")
  sim.advance(3 * SEC)
end

local function keptGood(what)
  t.eq(#sim.errors, 0, what .. ": no Lua error")
  t.ok(status():find("cloud: 100%%") ~= nil, what .. ": the last good value is kept (" .. status() .. ")")
  t.ok(status():find("OK ", 1, true) == 1, what .. ": Status still looks sane")
end

t.test("1: a truncated JSON reply is ignored and the last good value is kept", function()
  sim.reset(1)
  start()
  poll('{"current":{"cloud_cov')
  keptGood("truncated JSON")
end)

t.test("2: a non-JSON body is ignored and the last good value is kept", function()
  sim.reset(1)
  start()
  poll("not json at all")
  keptGood("garbage body")
end)

t.test("3: JSON in the wrong shape is ignored", function()
  sim.reset(1)
  start()
  poll('{"current":{}}')
  keptGood("no cloud_cover field")
  poll("null")
  keptGood("null body")
  poll("")
  keptGood("empty body")
end)

t.test("4: an HTTP error keeps the last good value even with a valid body", function()
  sim.reset(1)
  start()
  poll('{"current":{"cloud_cover":55}}', 500)
  keptGood("HTTP 500")
end)

t.test("5: the driver keeps running after a run of bad replies", function()
  sim.reset(1)
  start()
  poll('{"current":{"cloud_cov')
  poll("not json at all")
  poll('{"current":{}}')
  poll("", 500)
  sim.advance(2 * MIN)
  t.eq(#sim.errors, 0, "no Lua errors")
  t.ok(status():find("OK ", 1, true) == 1, "the schedule keeps writing Status (" .. status() .. ")")
  t.ok(status():find("cloud: 100%%") ~= nil, "the last good cloud cover survived the run")
  t.ok(status():find("12:0") ~= nil, "the Status clock kept advancing")
end)

-- KNOWN BUG (DLS 1.16.11, left unfixed on purpose): ReceivedAsync does cloudPct = tonumber(...) without
-- checking the result, so a well-formed reply whose cloud_cover is not a number ("abc", an object, true)
-- replaces the last good reading with nil and Status falls to "cloud: n/a".
t.test("6: a non-numeric cloud_cover must not drop the last good value", function()
  sim.reset(1)
  start()
  poll('{"current":{"cloud_cover":"abc"}}')
  keptGood("non-numeric cloud_cover")
end)

t.finish("dls-cloud-json")
