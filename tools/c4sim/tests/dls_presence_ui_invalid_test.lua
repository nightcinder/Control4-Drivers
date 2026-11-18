-- DLS 1.16.6: an invalid Rooms JSON empties the presence picker instead of leaving stale, silently no-op values,
-- and remembered light confirmations are pruned for ids that no longer exist.
-- Run: python tools/c4sim/run.py test dls_presence_ui_invalid
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local SEC = 1000

local ROOMS = '[{"name":"Kitchen","key":"Kitchen","min_level":60,"max_level":60,' ..
  '"presence":{"follow":true,"offDelaySec":180,"sources":["esp"]},"lights":[{"id":101,"kind":"lutron"}]}]'

C4.ServerSend = function() end
C4.ServerCloseClient = function() end

local function start()
  local props = { ["Presence Lighting"] = "On", ["Rooms JSON"] = ROOMS, ["Presence"] = "Home",
    ["Latitude"] = "51.5", ["Longitude"] = "-0.1" }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = 12 * 3600 * SEC,
    persist = { lightSeen = { ["101"] = true, ["999"] = true } },
    before = function(s) s.set_var(101, 1001, "0") end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  return ok
end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

t.test("remembered confirmations are pruned for lights that no longer exist", function()
  start()
  local seen = sim.persist and sim.persist.lightSeen or {}
  t.eq(seen["101"], true, "the live light keeps its confirmation")
  t.eq(seen["999"], nil, "the removed id is forgotten")
end)

t.test("an invalid Rooms JSON empties the picker and says why", function()
  start()
  setprop("Rooms JSON", "{not json")
  t.eq(sim._store["Presence Room State"], "Rooms JSON invalid", "the state names the problem")
  t.eq(sim._store["Presence Room"], "", "the picker no longer points at a room that is not loaded")
end)

t.finish("dls-presence-ui-invalid")
