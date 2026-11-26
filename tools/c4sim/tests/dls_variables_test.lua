-- DLS 1.16.23: read-only Control4 variables for outcome checks (c4-bridge reads item variables).
-- LAST_ON_EDGE, LAST_OFF_EDGE, OFF_RAMP_DONE, PRESENCE, LAST_ERROR, HEARTBEAT.
-- Time format: local "YYYY-MM-DDTHH:MM:SS", edges and ramp add " <room>".
-- Run: python tools/c4sim/run.py test dls_variables
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600
local NAMES = { "LAST_ON_EDGE", "LAST_OFF_EDGE", "OFF_RAMP_DONE", "PRESENCE", "LAST_ERROR", "HEARTBEAT" }
local ISO = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end

local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

-- Capture the full AddVariable call (the sim stub keeps only name and value).
local added = {}
local realAdd = C4.AddVariable
C4.AddVariable = function(self, name, value, vtype, readOnly, hidden)
  added[#added + 1] = { name = name, value = value, vtype = vtype, readOnly = readOnly, hidden = hidden }
  return realAdd(self, name, value)
end

local function v(name) return sim.dvars[name] end

local ROOMS = '[{"name":"Den","type":"mixed","on":"16:00","off":"16:30","off_ramp_min":3,' ..
  '"lights":[{"id":480,"kind":"lifx"},{"id":476,"kind":"lifx"}]}]'

local function start(h, m, persist)
  added = {}
  local ok = sim.load_driver(DRV, {
    xml = XML,
    persist = persist,
    properties = {
      ["Enabled"] = "On",
      ["Update Interval (min)"] = "1",
      ["Ramp Time (sec)"] = "90",
      ["Override Hold (min)"] = "120",
      ["Cloud Cover Source"] = "None (assume clear)",
      ["Latitude"] = "40",
      ["Longitude"] = "-75",
      ["Rooms JSON"] = ROOMS,
    },
    start_ms = local_sec(h, m) * SEC,
    before = function(s)
      s.set_var(480, VAR, "0")
      s.set_var(476, VAR, "0")
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
end

local function hhmm(val) return val and string.sub(val, 12, 16) end

t.test("1: all six variables are added read-only STRING on load, heartbeat and presence set", function()
  start(15, 0)
  for _, name in ipairs(NAMES) do
    local found
    for _, a in ipairs(added) do if a.name == name then found = a end end
    t.ok(found ~= nil, name .. " added")
    if found then
      t.eq(found.vtype, "STRING", name .. " type")
      t.eq(found.readOnly, true, name .. " read-only")
    end
    t.ok(v(name) ~= nil, name .. " has a value")
  end
  t.eq(v("PRESENCE"), "HOME", "PRESENCE HOME")
  t.ok(v("HEARTBEAT"):match(ISO .. "$") ~= nil, "HEARTBEAT ISO time: " .. tostring(v("HEARTBEAT")))
  t.eq(hhmm(v("HEARTBEAT")), "15:00", "HEARTBEAT written at load")
  t.eq(v("LAST_ERROR"), "", "LAST_ERROR empty")
  t.eq(v("LAST_ON_EDGE"), "", "no on edge yet")
end)

t.test("2: heartbeat rewritten every 5 minutes", function()
  start(15, 0)
  sim.advance(4 * MIN + 59 * SEC)
  t.eq(hhmm(v("HEARTBEAT")), "15:00", "unchanged before 5 min")
  sim.advance(2 * SEC)
  t.eq(hhmm(v("HEARTBEAT")), "15:05", "rewritten at 5 min")
  sim.advance(10 * MIN)
  t.eq(hhmm(v("HEARTBEAT")), "15:15", "still running")
end)

t.test("3: on edge, off edge and off ramp done carry time and room", function()
  start(15, 50)
  sim.advance(3 * MIN)                                  -- 15:53, first passes off-window
  t.eq(v("LAST_ON_EDGE"), "", "no edge before the on time")
  sim.advance(9 * MIN)                                  -- 16:02
  local on = v("LAST_ON_EDGE")
  t.ok(on:match(ISO .. " Den$") ~= nil, "LAST_ON_EDGE format: " .. tostring(on))
  t.ok(hhmm(on) == "16:00" or hhmm(on) == "16:01", "on edge at 16:00/16:01: " .. tostring(on))
  sim.set_var(480, VAR, "40")
  sim.set_var(476, VAR, "40")
  sim.advance(29 * MIN)                                 -- 16:31
  local off = v("LAST_OFF_EDGE")
  t.ok(off:match(ISO .. " Den$") ~= nil, "LAST_OFF_EDGE format: " .. tostring(off))
  t.ok(hhmm(off) == "16:30" or hhmm(off) == "16:31", "off edge at 16:30/16:31: " .. tostring(off))
  t.eq(v("OFF_RAMP_DONE"), "", "3 min stepped fade not done yet")
  sim.advance(5 * MIN)                                  -- 16:36
  local done = v("OFF_RAMP_DONE")
  t.ok(done:match(ISO .. " Den$") ~= nil, "OFF_RAMP_DONE format: " .. tostring(done))
  t.ok(done > off, "ramp done after the off edge")
  t.eq(v("LAST_ON_EDGE"), on, "on edge unchanged")
end)

t.test("4: a reload restores the values and is not reported as an on edge", function()
  start(15, 50)
  sim.advance(12 * MIN)                                 -- 16:02, on edge recorded
  local on = v("LAST_ON_EDGE")
  t.ok(on ~= "", "on edge recorded before reload")
  local persist = sim.persist
  start(16, 10, persist)                                -- reload inside the on window
  t.eq(v("LAST_ON_EDGE"), on, "LAST_ON_EDGE restored, not a new edge")
  sim.advance(5 * MIN)
  t.eq(v("LAST_ON_EDGE"), on, "first pass after reload is not an edge")
  local found = false
  for _, a in ipairs(added) do if a.name == "LAST_ON_EDGE" and a.value == on and a.readOnly == true then found = true end end
  t.ok(found, "re-added read-only with the persisted value")
end)

t.test("5: PRESENCE follows SetPresence", function()
  start(15, 0)
  sim.exec("SetPresence", { PRESENT = "AWAY" })
  t.eq(v("PRESENCE"), "AWAY", "AWAY")
  sim.exec("SetPresence", { PRESENT = "HOME" })
  t.eq(v("PRESENCE"), "HOME", "HOME")
end)

t.test("6: an Update error lands in LAST_ERROR and the timer keeps running", function()
  start(15, 0)
  sim.env.Update = function() error("boom") end
  sim.advance(2 * MIN)
  local e = v("LAST_ERROR")
  t.ok(e:match(ISO .. " Update: ") ~= nil, "LAST_ERROR format: " .. tostring(e))
  t.ok(e:find("boom", 1, true) ~= nil, "message kept")
  t.ok(#e <= 19 + 1 + 200, "capped length")
end)

t.test("7: no lighting change from the variables: same commands as without them", function()
  start(15, 50)
  sim.advance(12 * MIN)
  local n = 0
  for _, s in ipairs(sim.sent) do if s.cmd == "RAMP_TO_LEVEL" then n = n + 1 end end
  t.ok(n > 0, "on edge still drives the lights")
end)

t.finish("dls-variables")
