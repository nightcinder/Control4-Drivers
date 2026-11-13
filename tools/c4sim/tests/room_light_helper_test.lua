-- Room Light Helper 1.1.1 tests. Run from the repo root (run.py sets cwd).
local sim = require("c4sim")
local t = require("t")

local LUA = "drivers/room-light-helper/Room_Light_Helper_driver.lua"
local XML = "drivers/room-light-helper/Room_Light_Helper_driver.xml"
local LIGHT = 200          -- bound light device id
local LEVEL_VAR = 1001     -- LIGHT_LEVEL variable on the light
local MIN = 60000
local SEC = 1000

-- Fresh driver per test: select the light in the Room Light ID property and set its level before OnDriverInit runs.
local function start(props, extra)
  props = props or {}
  props["Room Light ID"] = tostring(LIGHT)
  local ok = sim.load_driver(LUA, {
    xml = XML,
    properties = props,
    before = function(s)
      s.set_var(LIGHT, LEVEL_VAR, "0")
      if extra then extra(s) end
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
end

local function cmd(name, params) sim.exec(name, params or {}) end
local function on(src) cmd("REQUEST_ON", { Source = src }) end
local function off(src) cmd("RELEASE", { Source = src }) end
local function ramps() return sim.count_sent("RAMP_TO_LEVEL") end
local function offs() return sim.count_sent("OFF") end
local function event_count(id)
  local n = 0
  for _, e in ipairs(sim.events) do
    if e.id == id then n = n + 1 end
  end
  return n
end
local function last_level()
  local r = sim.last_sent("RAMP_TO_LEVEL")
  return r and r.params.LEVEL
end

t.test("first Request ramps the light on with fallback level", function()
  start()
  on("Laundry Motion")
  local r = sim.last_sent("RAMP_TO_LEVEL")
  t.ok(r ~= nil, "ramp sent")
  t.eq(r.id, LIGHT, "to bound light")
  t.eq(r.params.LEVEL, 60, "fallback level without lux")
  t.eq(r.params.TIME, 1500, "ramp time")
  t.eq(event_count(1), 1, "on event")
  t.eq(Properties["Active Sources"], "Laundry Motion", "active sources")
  t.eq(Properties.Status, "Active: 1 source(s)", "status")
end)

t.test("second source adds a reference without re-sending", function()
  start()
  on("Alpha")
  on("Beta")
  t.eq(ramps(), 1, "one ramp only")
  t.eq(Properties["Active Sources"], "Alpha, Beta", "both listed")
  t.eq(Properties.Status, "Active: 2 source(s)", "status")
end)

t.test("releasing one of two sources does nothing", function()
  start()
  on("Alpha")
  on("Beta")
  off("Alpha")
  sim.advance(600 * SEC)
  t.eq(offs(), 0, "no off")
  t.eq(Properties.Status, "Active: 1 source(s)", "status")
end)

t.test("last release turns off after 180 s, not before", function()
  start()
  on("Alpha")
  on("Beta")
  off("Alpha")
  off("Beta")
  sim.advance(179 * SEC)
  t.eq(offs(), 0, "no off at 179 s")
  sim.advance(2 * SEC)
  t.eq(offs(), 1, "off at 181 s")
  t.eq(event_count(2), 1, "off event")
end)

t.test("Quick-Release source Roborock uses 90 s; list match is case-insensitive", function()
  start({ ["Quick-Release Sources"] = " ROBOROCK , Other" })
  on("Roborock")
  off("Roborock")
  sim.advance(89 * SEC)
  t.eq(offs(), 0, "no off at 89 s")
  sim.advance(1 * SEC)
  t.eq(offs(), 1, "off at 90 s")
end)

t.test("a new Request during the off delay cancels the pending off", function()
  start()
  on("Alpha")
  off("Alpha")
  sim.advance(100 * SEC)
  on("Beta")
  sim.advance(300 * SEC)
  t.eq(offs(), 0, "no off")
  t.eq(ramps(), 1, "no re-ramp at same level")
  t.eq(Properties.Status, "Active: 1 source(s)", "status")
end)

t.test("light already on: helper never turns it off", function()
  start(nil, function(s) s.set_var(LIGHT, LEVEL_VAR, "80") end)
  on("Alpha")
  t.eq(ramps(), 0, "no ramp")
  t.eq(Properties["Light State"], "On externally", "state")
  off("Alpha")
  sim.advance(600 * SEC)
  t.eq(offs(), 0, "no off")
end)

-- Lux mapping: Lux Low 20 -> Max 100, Lux High 300 -> Min 20, linear between.
local lux_cases = {
  { lux = 0, want = 100 },
  { lux = 20, want = 100 },
  { lux = 100, want = 77 },
  { lux = 160, want = 60 },
  { lux = 300, want = 20 },
  { lux = 5000, want = 20 },
}
for _, c in ipairs(lux_cases) do
  t.test("lux " .. c.lux .. " maps to level " .. c.want, function()
    start()
    cmd("SET_LUX", { Lux = c.lux })
    on("Alpha")
    t.eq(last_level(), c.want, "level")
  end)
end

t.test("no lux reading uses Fallback Level", function()
  start({ ["Fallback Level"] = "40" })
  on("Alpha")
  t.eq(last_level(), 40, "fallback")
end)

t.test("lux exactly Lux Max Age old still counts", function()
  start()
  cmd("SET_LUX", { Lux = 20 })
  sim.advance(30 * 60 * SEC)
  on("Alpha")
  t.eq(last_level(), 100, "lux used")
end)

t.test("stale lux (older than Lux Max Age) gives Fallback Level", function()
  start()
  cmd("SET_LUX", { Lux = 20 })
  sim.advance(30 * 60 * SEC + SEC)
  on("Alpha")
  t.eq(last_level(), 60, "fallback")
end)

t.test("safety timeout auto-releases after 120 min, then off uses Off Delay", function()
  start()
  on("Alpha")
  sim.advance(7199 * SEC)
  t.eq(Properties.Status, "Active: 1 source(s)", "still active at 119:59")
  t.eq(event_count(3), 0, "no timeout yet")
  sim.advance(1 * SEC)
  t.eq(event_count(3), 1, "timeout event at 120 min")
  t.ok(sim.logs[#sim.logs] ~= nil, "log written")
  local logged = false
  for _, l in ipairs(sim.logs) do
    if l:find("Source timeout", 1, true) then logged = true end
  end
  t.ok(logged, "timeout logged")
  t.eq(Properties.Status, "Off pending", "off pending")
  sim.advance(179 * SEC)
  t.eq(offs(), 0, "no off at 179 s after timeout")
  sim.advance(1 * SEC)
  t.eq(offs(), 1, "off at 180 s after timeout")
end)

t.test("Release All uses Off Delay (180 s) even for Roborock", function()
  start()
  on("Alpha")
  on("Roborock")
  cmd("RELEASE_ALL")
  t.eq(Properties["Active Sources"], "None", "sources cleared")
  t.eq(Properties.Status, "Off pending", "status")
  sim.advance(100 * SEC)
  t.eq(offs(), 0, "no off at 100 s")
  sim.advance(80 * SEC)
  t.eq(offs(), 1, "off at 180 s")
end)

t.test("lux change of 10+ target points re-ramps while active; smaller change does not", function()
  start()
  cmd("SET_LUX", { Lux = 300 })
  on("Alpha")
  t.eq(last_level(), 20, "first ramp at min")
  cmd("SET_LUX", { Lux = 20 })
  t.eq(ramps(), 2, "re-ramp to 100 (80 points)")
  t.eq(last_level(), 100, "new level")
  cmd("SET_LUX", { Lux = 25 })
  t.eq(ramps(), 2, "no re-ramp for 1 point")
end)

t.finish("room-light-helper")
