-- Shield Remote tests: keys, room volume, REMOTE_STATE listener, UI_STATE snapshot, page build check.
local sim = require("c4sim")
local t = require("t")

local LUA = "drivers/shield-remote/driver.lua"
local XML = "drivers/shield-remote/driver.xml"
local SHIELD = 500   -- Shield TV device id chosen in the "Shield TV" property
local ROOM = 77      -- room id returned by C4:RoomGetId
local VAR = 1000     -- REMOTE_STATE variable id on the Shield TV device

local NP = '{"title":"Song","artist":"Artist","album":"Album","state":"playing","art":"","app":"Netflix","awake":true}'

-- Fresh driver per test. `extra` runs after reset, before OnDriverInit (set_device_vars, etc.).
local function start(extra, extraProps)
  local props = {}
  for k, v in pairs(extraProps or {}) do props[k] = v end
  local ok = sim.load_driver(LUA, {
    xml = XML,
    properties = props,
    before = function(s)
      C4.RoomGetId = function() return ROOM end
      if extra then extra(s) end
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
end

-- Shield TV device with REMOTE_STATE set to `value` (defaults to NP).
local function with_remote_state(value)
  return function()
    sim.set_device_vars(SHIELD, { [VAR] = { name = "REMOTE_STATE", value = value or NP } })
  end
end

local function last_key()
  return sim.last_sent("SHIELD_REMOTE_KEY")
end

t.test("UI_KEY_DPAD_UP sends SHIELD_REMOTE_KEY to the Shield TV with KEY and room", function()
  start(nil, { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  sim.exec("UI_KEY_DPAD_UP", {})
  local s = last_key()
  t.ok(s ~= nil, "SHIELD_REMOTE_KEY sent")
  if s then
    t.eq(s.id, SHIELD, "sent to Shield TV id")
    t.eq(s.params.KEY, "DPAD_UP", "KEY param")
    t.eq(s.params.ROOMID, "77", "ROOMID param")
  end
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("unknown command UI_KEY_POWER sends nothing", function()
  start(nil, { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  sim.exec("UI_KEY_POWER", {})
  t.eq(sim.count_sent("SHIELD_REMOTE_KEY"), 0, "no key sent")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("UI_VOL_UP sends PULSE_VOL_UP to the room", function()
  start(nil, { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  sim.exec("UI_VOL_UP", {})
  local s = sim.last_sent("PULSE_VOL_UP")
  t.ok(s ~= nil, "PULSE_VOL_UP sent")
  if s then t.eq(s.id, ROOM, "sent to room 77") end
end)

t.test("REMOTE_STATE found at late init is embedded raw in UI_STATE np and linked is true", function()
  start(with_remote_state(), { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  local ui = sim.dvars["UI_STATE"] or ""
  t.ok(string.find(ui, '"t":"shieldremote"', 1, true) ~= nil, "snapshot tag")
  t.ok(string.find(ui, '"linked":true', 1, true) ~= nil, "linked true")
  t.ok(string.find(ui, '"build":1', 1, true) ~= nil, "build 1")
  t.ok(string.find(ui, '"np":' .. NP, 1, true) ~= nil, "np embedded raw")
end)

t.test("OnWatchedVariableChanged updates UI_STATE", function()
  start(with_remote_state(), { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  sim.fire_var(SHIELD, VAR, '{"title":"Next Track","state":"paused","awake":true}')
  local ui = sim.dvars["UI_STATE"] or ""
  t.ok(string.find(ui, '"title":"Next Track"', 1, true) ~= nil, "new title in UI_STATE")
  t.ok(string.find(ui, '"state":"paused"', 1, true) ~= nil, "new state in UI_STATE")
end)

t.test("ReceivedFromProxy 5001 SELECT sends no SHIELD_REMOTE_KEY", function()
  start(with_remote_state(), { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  sim.call("ReceivedFromProxy", 5001, "SELECT", {})
  t.eq(sim.count_sent("SHIELD_REMOTE_KEY"), 0, "no key on page open")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("UI_HELLO_1 sets Page build 1 OK and UI_HELLO_0 sets PAGE IS STALE", function()
  start(nil, { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  sim.exec("UI_HELLO_1", {})
  t.eq(sim._store["Web Page Status"], "Page build 1 OK", "page build 1 accepted")
  sim.exec("UI_HELLO_0", {})
  t.ok(string.find(sim._store["Web Page Status"] or "", "PAGE IS STALE", 1, true) ~= nil, "stale page flagged")
end)

t.test("no Shield TV chosen: UI_KEY_HOME sends nothing and no driver error", function()
  start(nil, {})
  sim.exec("UI_KEY_HOME", {})
  t.eq(sim.count_sent("SHIELD_REMOTE_KEY"), 0, "no key sent")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("Shield TV list is filled from Shield TV Bridge devices with (id N)", function()
  local listed
  start(function()
    C4.GetDevicesByC4iName = function(_, name)
      if name == "shield-tv-bridge.c4z" then return { [512] = "x", [500] = "y" } end
      return {}
    end
    C4.GetDeviceDisplayName = function(_, id) return id == 500 and "Downstairs, Shield" or "Bedroom Shield" end
    C4.UpdatePropertyList = function(_, name, value) if name == "Shield TV" then listed = value end end
  end, {})
  t.eq(listed, "Downstairs  Shield (id 500),Bedroom Shield (id 512)", "list built, comma stripped, sorted by id")
end)

t.test("Shield TV Device ID overrides the list choice", function()
  start(nil, { ["Shield TV"] = "Shield TV (id 500)", ["Shield TV Device ID"] = "612" })
  sim.exec("UI_KEY_BACK", {})
  local s = last_key()
  t.ok(s ~= nil and s.id == 612, "sent to override id 612")
end)

t.test("Driver Version is 0.1.0", function()
  start(nil, { ["Shield TV"] = "Shield TV (id " .. SHIELD .. ")" })
  t.eq(sim._store["Driver Version"], "0.1.0", "driver version property")
end)

t.finish("shield-remote")
