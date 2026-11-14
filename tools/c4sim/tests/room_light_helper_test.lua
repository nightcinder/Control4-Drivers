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
-- ramps: turn-on ramps (level above 0). offs: plain OFF or a Fade Out ramp to 0.
local function count_sent_where(pred)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if pred(s) then n = n + 1 end
  end
  return n
end
local function ramps()
  return count_sent_where(function(s) return s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL > 0 end)
end
local function offs()
  return count_sent_where(function(s)
    return s.cmd == "OFF" or (s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == 0)
  end)
end
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
  t.eq(r.params.TIME, 5000, "fade in default 5 s")
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

-- Reload: a new driver instance on the same persisted data. extra_ms moves the clock forward first
-- (the driver was down for that long). Light stays on at level 60, as it would after a reload.
local function reload(extra_ms)
  local saved, now = sim.persist, sim.now_ms + (extra_ms or 0)
  local ok = sim.load_driver(LUA, {
    xml = XML,
    properties = { ["Room Light ID"] = tostring(LIGHT) },
    persist = saved,
    start_ms = now,
    before = function(s) s.set_var(LIGHT, LEVEL_VAR, "60") end,
  })
  t.ok(ok, "reload: " .. tostring(sim.errors[1]))
end

t.test("repeated Request On from the same Source keeps the first start time (120 min timeout)", function()
  start({ ["Source Timeout (min)"] = "120" })
  on("Alpha")
  sim.advance(100 * MIN)
  on("Alpha")                    -- repeat must not restart the timeout clock
  t.eq(Properties.Status, "Active: 1 source(s)", "still one source")
  sim.advance(19 * MIN)          -- 119 min after the first request
  t.eq(Properties["Active Sources"], "Alpha", "not yet timed out at 119 min")
  sim.advance(2 * MIN)           -- 121 min after the first request
  t.eq(Properties["Active Sources"], "None", "timed out 120 min after the first request")
  t.eq(Properties.Status, "Off pending", "off pending after timeout")
  sim.advance(180 * SEC)
  t.eq(offs(), 1, "off after Off Delay")
end)

t.test("reload keeps active sources and their start time", function()
  start()
  on("Alpha")
  sim.advance(10 * MIN)
  reload()
  t.eq(Properties["Active Sources"], "Alpha", "source restored")
  t.eq(Properties.Status, "Active: 1 source(s)", "status restored")
  t.eq(ramps(), 0, "no re-ramp on restore")
  sim.advance(109 * MIN)         -- 119 min after the original request
  t.eq(Properties["Active Sources"], "Alpha", "still active at 119 min")
  sim.advance(2 * MIN)           -- 121 min: timeout counted from the original request
  t.eq(Properties["Active Sources"], "None", "timed out from the original request")
  sim.advance(180 * SEC)
  t.eq(offs(), 1, "off after Off Delay following timeout")
end)

t.test("reload during a pending off re-arms the remaining delay", function()
  start()
  on("Alpha")
  off("Alpha")                   -- off due in 180 s
  sim.advance(60 * SEC)
  reload()
  t.eq(Properties.Status, "Off pending", "pending off restored")
  sim.advance(119 * SEC)
  t.eq(offs(), 0, "no off before the remaining 120 s")
  sim.advance(2 * SEC)
  t.eq(offs(), 1, "off at the original 180 s mark")
end)

t.test("reload after a source has expired while down drops it and turns off after Off Delay", function()
  start({ ["Source Timeout (min)"] = "120" })
  on("Alpha")
  reload(121 * MIN)
  t.eq(Properties["Active Sources"], "None", "expired source dropped")
  t.eq(Properties.Status, "Off pending", "off pending with Off Delay")
  sim.advance(179 * SEC)
  t.eq(offs(), 0, "no off at 179 s")
  sim.advance(2 * SEC)
  t.eq(offs(), 1, "off at 180 s")
end)

t.test("reload with nothing saved starts idle and sends nothing", function()
  start()
  reload()
  t.eq(Properties.Status, "Idle", "idle")
  t.eq(Properties["Active Sources"], "None", "no sources")
  sim.advance(300 * SEC)
  t.eq(offs(), 0, "no off")
  t.eq(ramps(), 0, "no ramp")
end)

t.test("Fade In (sec) sets the turn-on ramp time", function()
  start({ ["Fade In (sec)"] = "12" })
  on("Alpha")
  t.eq(sim.last_sent("RAMP_TO_LEVEL").params.TIME, 12000, "ramp time from property")
end)

t.test("last release fades out: RAMP_TO_LEVEL 0 over Fade Out (sec), no plain OFF", function()
  start()
  on("Alpha")
  off("Alpha")
  sim.advance(179 * SEC)
  t.eq(offs(), 0, "no fade at 179 s")
  sim.advance(2 * SEC)
  local r = sim.last_sent("RAMP_TO_LEVEL")
  t.eq(r.id, LIGHT, "to bound light")
  t.eq(r.params.LEVEL, 0, "fade to 0")
  t.eq(r.params.TIME, 30000, "default Fade Out 30 s")
  t.eq(offs(), 1, "one fade")
  t.eq(sim.count_sent("OFF"), 0, "no plain OFF")
  t.eq(event_count(2), 1, "off event")
end)

t.test("Fade Out (sec) changes the fade time", function()
  start({ ["Fade Out (sec)"] = "45" })
  on("Alpha")
  off("Alpha")
  sim.advance(180 * SEC)
  t.eq(sim.last_sent("RAMP_TO_LEVEL").params.TIME, 45000, "45 s fade")
end)

t.test("Fade Out 0 sends plain OFF after Off Delay", function()
  start({ ["Fade Out (sec)"] = "0" })
  on("Alpha")
  off("Alpha")
  sim.advance(181 * SEC)
  t.eq(sim.count_sent("OFF"), 1, "plain OFF")
  t.eq(count_sent_where(function(s) return s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == 0 end), 0, "no fade")
end)

t.test("Request On during a fade-out reclaims the light with a normal ramp", function()
  start()
  on("Alpha")
  off("Alpha")
  sim.advance(181 * SEC)           -- fade-out started
  sim.fire_var(LIGHT, LEVEL_VAR, "40")  -- light still above 0 mid-fade
  on("Beta")
  local r = sim.last_sent("RAMP_TO_LEVEL")
  t.eq(r.params.LEVEL, 60, "normal ramp to target")
  t.eq(r.params.TIME, 5000, "fade in time")
  t.eq(ramps(), 2, "turn-on ramp sent again")
  t.eq(event_count(1), 2, "on event fired again")
  t.eq(Properties["Light State"], "On by helper", "helper owns the light again")
  sim.advance(600 * SEC)
  t.eq(offs(), 1, "no new fade while Beta is active")
  off("Beta")
  sim.advance(181 * SEC)
  t.eq(offs(), 2, "new fade after Beta releases")
end)

t.test("light turned on externally after our fade ended is left alone", function()
  start()
  on("Alpha")
  off("Alpha")
  sim.advance(181 * SEC)
  sim.fire_var(LIGHT, LEVEL_VAR, "0")   -- fade finished
  sim.fire_var(LIGHT, LEVEL_VAR, "80")  -- someone else turns it on
  on("Beta")
  t.eq(ramps(), 1, "no new ramp")
  t.eq(Properties["Light State"], "On externally", "state")
  off("Beta")
  sim.advance(600 * SEC)
  t.eq(offs(), 1, "helper never fades out an external light")
end)

t.finish("room-light-helper")
