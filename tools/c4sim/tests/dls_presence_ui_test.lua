-- DLS presence UI (1.13.0): the Composer properties that expose one presence room at a time.
-- Run: python tools/c4sim/run.py test dls_presence_ui
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
  '"lights":[{"id":101,"kind":"lutron"}]},' ..
  '{"name":"Hall","key":"Hall","min_level":60,"max_level":60,' ..
  '"presence":{"follow":false,"offDelaySec":60,"sources":["esp"]},"lights":[{"id":102,"kind":"lutron"}]}]'

C4.ServerSend = function(_, handle, data) end
C4.ServerCloseClient = function(_, handle) end

local function start(persist)
  local props = { ["Presence Lighting"] = "On", ["Presence Port"] = PORT, ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
    ["Presence"] = "Home", ["Latitude"] = "51.5", ["Longitude"] = "-0.1" }
  local ok = sim.load_driver(DRV, {
    xml = XML, properties = props, persist = persist, start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(K, VAR, "0"); s.set_var(102, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  return ok
end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

t.test("the room picker is a text field that starts on the first room", function()
  start()
  -- 1.16.9: this firmware ignores dynamic LIST items in both call forms, so the picker is a STRING.
  t.eq(sim._store["Presence Room"], "Kitchen", "defaults to the first room in the Rooms JSON")
  setprop("Presence Room", "Hall")
  t.eq(sim._store["Presence Room State"] ~= nil, true, "state refreshes for a typed room name")
  setprop("Presence Room", "NoSuchRoom")
  t.ok(tostring(sim._store["Presence Room State"]):find("Vacant") == nil, "an unknown room does not pretend to be another")
end)

t.test("selecting a room shows its follow mode, off delay and state", function()
  start()
  setprop("Presence Room", "Hall")
  t.eq(sim._store["Presence Follow"], "Off", "Hall has follow off")
  t.eq(sim._store["Presence Off Delay (sec)"], 60, "Hall's own off delay")
  t.eq(type(sim._store["Presence Off Delay (sec)"]), "number", "written as a number: DriverWorks rejects a string for RANGED_INTEGER")
  t.ok(tostring(sim._store["Presence Room State"]):find("Vacant") ~= nil, "state reads Vacant")
end)

t.test("changing follow persists and overrides the JSON default on reload", function()
  start()
  setprop("Presence Room", "Hall")
  setprop("Presence Follow", "Follow")
  t.eq(sim._store["Presence Follow"], "Follow", "property reflects the change")
  local saved = sim.persist and sim.persist.presenceUI and sim.persist.presenceUI["Hall"]
  t.ok(type(saved) == "table" and saved.follow == true, "override written to PersistData")

  start(sim.persist)                      -- reload with the same PersistData
  setprop("Presence Room", "Hall")
  t.eq(sim._store["Presence Follow"], "Follow", "override survives the reload")
end)

t.test("off delay is clamped to the documented range", function()
  start()
  setprop("Presence Room", "Kitchen")
  setprop("Presence Off Delay (sec)", "5")
  t.eq(sim._store["Presence Off Delay (sec)"], 10, "clamped up to 10 s")
  setprop("Presence Off Delay (sec)", "99999")
  t.eq(sim._store["Presence Off Delay (sec)"], 3600, "clamped down to 3600 s")
end)

t.finish("dls-presence-ui")
