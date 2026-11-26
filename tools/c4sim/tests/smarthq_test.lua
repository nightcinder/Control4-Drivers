local sim = require("c4sim")
local t   = require("t")

local BRIDGE_LUA = "drivers/smarthq-bridge/driver.lua"
local BRIDGE_XML = "drivers/smarthq-bridge/driver.xml"
local APP_LUA    = "drivers/smarthq-appliance/driver.lua"
local APP_XML    = "drivers/smarthq-appliance/driver.xml"
local HOOD_LUA   = "drivers/smarthq-hood-light/driver.lua"
local HOOD_XML   = "drivers/smarthq-hood-light/driver.xml"

local SAMPLE_INVENTORY = '[' ..
  '{"id":"app-oven","type":"oven","nickname":"Wall Oven","online":true,"erds":{' ..
    '"UPPER_OVEN_CURRENT_STATE":"Preheat",' ..
    '"UPPER_OVEN_DISPLAY_TEMPERATURE":"350",' ..
    '"UPPER_OVEN_COOK_TIME_REMAINING":600,' ..
    '"UPPER_OVEN_COOK_MODE":"Bake"' ..
  '}},' ..
  '{"id":"app-hood","type":"hood","nickname":"Range Hood","online":true,"erds":{' ..
    '"HOOD_LIGHT_LEVEL":"DIM",' ..
    '"HOOD_FAN_SPEED":"LOW"' ..
  '}}' ..
']'

t.test("smarthq bridge: poll inventory, register children, hood cmd, unreachable event", function()
  local ok = sim.load_driver(BRIDGE_LUA, {
    xml = BRIDGE_XML,
    deviceId = 100,
    properties = {
      Host = "192.0.2.20",
      Port = "8789",
      ["Poll Interval"] = "60",
      ["Auto Create Children"] = "Off",
    },
  })
  t.ok(ok, "bridge loaded: " .. tostring(sim.errors[1]))
  t.eq(sim._store["Driver Version"], "0.3.8", "bridge version 0.3.8")

  -- Register one appliance child and one hood light child.
  sim.exec("SH_REGISTER", { CHILD_ID = "201", APPLIANCE_ID = "app-oven", KIND = "oven" })
  sim.exec("SH_REGISTER", { CHILD_ID = "202", APPLIANCE_ID = "app-hood", KIND = "hood" })

  sim.queue_http("/inventory", SAMPLE_INVENTORY, 200)
  sim.sent = {}
  sim.exec("LUA_ACTION", { ACTION = "REFRESH_NOW" })
  sim.advance(0)
  t.ok(string.find(sim._store["Status"] or "", "Connected, polled", 1, true) ~= nil, "bridge status Connected")

  -- Check SH_STATUS pushed to oven and hood children.
  local sawOven, sawHood = false, false
  for _, s in ipairs(sim.sent) do
    if s.cmd == "SH_STATUS" and s.id == 201 and s.params.STATE == "Preheat" then sawOven = true end
    if s.cmd == "SH_STATUS" and s.id == 202 and s.params.STATE == "DIM" then sawHood = true end
  end
  t.ok(sawOven, "SH_STATUS pushed to oven child")
  t.ok(sawHood, "SH_STATUS pushed to hood child")

  -- List Appliances action populates property.
  sim.queue_http("/inventory", SAMPLE_INVENTORY, 200)
  sim.exec("LUA_ACTION", { ACTION = "LIST_APPLIANCES" })
  sim.advance(0)
  t.ok(string.find(sim._store["Appliance List"] or "", "app-oven | oven | Wall Oven", 1, true) ~= nil,
       "Appliance List contains oven")

  -- Hood command forwards POST /appliances/app-hood/command and pushes updated state.
  sim.queue_http("/command", '{"online":true,"light_level":"HIGH","fan_speed":"MED"}', 200)
  sim.sent = {}
  sim.exec("SH_HOOD_CMD", { CHILD_ID = "202", APPLIANCE_ID = "app-hood", LEVEL = "on" })
  sim.advance(0)
  local post = sim.http[#sim.http]
  t.eq(post.method, "POST", "hood command sent POST")
  t.ok(string.find(post.body or "", '"level":"on"', 1, true) ~= nil, "POST body sets level on")
  local hoodUp = sim.last_sent("SH_STATUS")
  t.ok(hoodUp ~= nil and hoodUp.id == 202 and hoodUp.params.STATE == "HIGH", "updated hood status pushed")

  -- Bridge unreachable (HTTP 503) fires event 1 via FireEventByID and pushes REACHABLE=false.
  sim.events = {}
  sim.sent = {}
  sim.queue_http("/inventory", '{"last_error":"session expired"}', 503)
  sim.exec("REFRESH_NOW", {})
  sim.advance(0)
  t.eq(#sim.events, 1, "Bridge Unreachable event fired")
  t.eq(sim.events[1].id, 1, "Bridge Unreachable uses numeric event ID 1")
  local reach = sim.last_sent("SH_PARENT")
  t.ok(reach ~= nil and reach.params.REACHABLE == "false", "children notified bridge unreachable")
end)

t.test("smarthq appliance: oven events, door-left-open, and dryer cycle done", function()
  local ok = sim.load_driver(APP_LUA, {
    xml = APP_XML,
    deviceId = 201,
    properties = {
      ["Appliance Type"] = "Oven",
      ["Appliance ID"] = "app-oven",
      ["Door Open Alert Minutes"] = "2",
    },
    before = function(s) s.bind(201, 1, 100) end,
  })
  t.ok(ok, "appliance loaded: " .. tostring(sim.errors[1]))
  t.eq(sim._store["Driver Version"], "0.3.4", "appliance version 0.3.4")

  sim.exec("SH_HELLO", {})
  local reg = sim.last_sent("SH_REGISTER")
  t.ok(reg ~= nil and reg.id == 100 and reg.params.APPLIANCE_ID == "app-oven", "child registers on SH_HELLO")

  -- First update records baseline without firing events.
  sim.exec("SH_STATUS", {
    ONLINE = "true", ACTIVE = "true", STATE = "Preheating", DOOR = "Open",
    TEMP = "325", TIME = "180", CYCLE = "Bake",
  })
  t.eq(#sim.events, 0, "baseline SH_STATUS fires no events")
  t.eq(sim._store["Temperature"], "325 F", "Temperature formatted with F")

  -- Advance 130s (> 2 min), transition out of Preheat with TIME=0 and door still open.
  sim.advance(130000)
  sim.exec("SH_STATUS", {
    ONLINE = "true", ACTIVE = "true", STATE = "Baking", DOOR = "Open",
    TEMP = "350", TIME = "0", CYCLE = "Bake",
  })
  local evts = {}
  for _, e in ipairs(sim.events) do
    evts[e.id] = true
  end
  t.ok(evts[1], "Oven Preheated event (1) fired")
  t.ok(evts[2], "Oven Timer Done event (2) fired")
  t.ok(evts[6], "Door Left Open event (6) fired")

  -- Verify SH_CONFIGURE on a dryer also works and fires Dryer Done (5).
  sim.events = {}
  ok = sim.load_driver(APP_LUA, {
    xml = APP_XML,
    deviceId = 203,
    before = function(s) s.bind(203, 1, 100) end,
  })
  t.ok(ok, "dryer loaded")
  sim.exec("SH_CONFIGURE", { APPLIANCE_ID = "app-dryer", APPLIANCE_TYPE = "Dryer" })
  t.eq(sim._store["Appliance Type"], "Dryer", "SH_CONFIGURE updated Appliance Type")
  sim.exec("SH_STATUS", { ONLINE = "true", ACTIVE = "true", STATE = "Running", TIME = "120" })
  sim.exec("SH_STATUS", { ONLINE = "true", ACTIVE = "false", STATE = "Idle", TIME = "0" })
  t.eq(#sim.events, 1, "Dryer Done fired")
  t.eq(sim.events[1].id, 5, "Dryer Done event ID is 5")
end)

t.test("smarthq hood light: proxy level mapping and status sync", function()
  local ok = sim.load_driver(HOOD_LUA, {
    xml = HOOD_XML,
    deviceId = 202,
    properties = { ["Appliance ID"] = "app-hood" },
    before = function(s) s.bind(202, 1, 100) end,
  })
  t.ok(ok, "hood light loaded: " .. tostring(sim.errors[1]))

  sim.sent = {}
  sim.exec("SH_STATUS", { STATE = "DIM", FAN = "LOW" })
  t.eq(sim._store["Status"], "Hood light dim, fan LOW", "Status reflects dim")
  local bc = sim.last_sent("LIGHT_BRIGHTNESS_CHANGED")
  t.ok(bc ~= nil and tonumber(bc.params.LIGHT_BRIGHTNESS_CURRENT) == 33, "DIM notifies LIGHT_BRIGHTNESS_CHANGED 33")
  t.ok(sim.last_sent("LIGHT_LEVEL") ~= nil, "DIM notifies LIGHT_LEVEL")
  t.ok(sim.last_sent("LIGHT_CHANGED") == nil, "no legacy LIGHT_CHANGED")

  sim.sent = {}
  sim.exec("SH_STATUS", { STATE = "HIGH", FAN = "OFF", ONLINE = "true" })
  t.eq(tonumber(sim.last_sent("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT), 100, "HIGH notifies 100")
  t.eq(sim.last_sent("ONLINE_CHANGED").params.STATE, "true", "ONLINE true notifies ONLINE_CHANGED")

  sim.sent = {}
  sim.exec("SH_STATUS", { STATE = "HIGH", FAN = "OFF" })
  t.ok(sim.last_sent("LIGHT_BRIGHTNESS_CHANGED") == nil, "same level is not re-notified")

  sim.sent = {}
  sim.exec("SH_STATUS", { STATE = "OFF", FAN = "OFF" })
  t.eq(tonumber(sim.last_sent("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT), 0, "OFF notifies 0")

  sim.sent = {}
  sim.call("ReceivedFromProxy", 5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20" })
  t.eq(sim.last_sent("SH_HOOD_CMD").params.LEVEL, "dim", "slider 20 sends dim")
  sim.call("ReceivedFromProxy", 5001, "TOGGLE", {})
  t.eq(sim.last_sent("SH_HOOD_CMD").params.LEVEL, "on", "TOGGLE while off sends on")

  sim.sent = {}
  sim.call("ReceivedFromProxy", 5001, "SET_LEVEL", { LEVEL = "50" })
  t.eq(sim.last_sent("SH_HOOD_CMD").params.LEVEL, "dim", "level 50 sends dim")
  sim.call("ReceivedFromProxy", 5001, "SET_LEVEL", { LEVEL = "90" })
  t.eq(sim.last_sent("SH_HOOD_CMD").params.LEVEL, "on", "level 90 sends on")
  sim.call("ReceivedFromProxy", 5001, "OFF", {})
  t.eq(sim.last_sent("SH_HOOD_CMD").params.LEVEL, "off", "OFF sends off")
end)

t.finish("smarthq")
