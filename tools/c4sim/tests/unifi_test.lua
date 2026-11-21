local sim = require("c4sim")
local t   = require("t")

local CTRL_LUA   = "drivers/unifi-controller/UniFi_Controller_driver.lua"
local CTRL_XML   = "drivers/unifi-controller/UniFi_Controller_driver.xml"
local OUTLET_LUA = "drivers/unifi-outlet/UniFi_Outlet_driver.lua"
local OUTLET_XML = "drivers/unifi-outlet/UniFi_Outlet_driver.xml"

local DEVICES_JSON = '{"meta":{"rc":"ok"},"data":[{' ..
  '"_id":"dev1","model":"USPPDUP","name":"Rack PDU","outlet_ac_power_consumption":42.5,' ..
  '"outlet_table":[' ..
    '{"index":1,"name":"aa:bb:cc:dd:ee:01","relay_state":false,"outlet_power":0},' ..
    '{"index":2,"name":"Modem","relay_state":true,"outlet_power":18.2}' ..
  '],' ..
  '"outlet_overrides":[' ..
    '{"index":1,"name":"aa:bb:cc:dd:ee:01","relay_state":false},' ..
    '{"index":2,"name":"Modem","relay_state":true}' ..
  ']' ..
'}]}'

local USERS_JSON = '{"meta":{"rc":"ok"},"data":[{"mac":"aa:bb:cc:dd:ee:01","name":"NAS"}]}'

t.test("unifi controller: login, discovery, client names, child sync, full-array PUT", function()
  local ok = sim.load_driver(CTRL_LUA, {
    xml = CTRL_XML,
    deviceId = 100,
    properties = {
      Host = "198.51.100.10",
      Port = "443",
      ["Controller Type"] = "Auto",
      Username = "admin",
      Password = "secret",
      Site = "default",
      ["Poll Interval Seconds"] = "30",
    },
  })
  t.ok(ok, "controller loaded: " .. tostring(sim.errors[1]))

  -- Register child outlet before initial 5s poll finishes.
  sim.exec("UO_REGISTER", { CHILD_ID = "501", KEY = "dev1:1" })

  sim.queue_http("/api/auth/login", '{"unique_id":"u1"}', 200, {
    ["Set-Cookie"] = "TOKEN=tok123; Path=/",
    ["X-CSRF-Token"] = "csrf99",
  })
  sim.queue_http("/stat/device", DEVICES_JSON, 200)
  sim.queue_http("/rest/user", USERS_JSON, 200)

  sim.sent = {}
  sim.advance(5000)

  t.eq(sim._store["Connection Status"], "Connected: 2 outlet(s)", "discovered 2 outlets")
  t.ok(string.find(sim._store["Discovered Outlets"] or "", "dev1:1  Rack PDU / NAS (OFF)", 1, true) ~= nil,
       "MAC-named outlet resolved via /rest/user client list")
  local st = sim.last_sent("UO_STATUS")
  t.ok(st ~= nil and st.id == 501 and st.params.STATE == "OFF", "child 501 notified OFF")
  local uiJson = sim.ui[#sim.ui] and sim.ui[#sim.ui][1]
  t.ok(uiJson ~= nil and string.find(uiJson, '"NAS"', 1, true) ~= nil,
       "UI_STATE contains resolved outlet name")

  -- Web view hello checks.
  sim.exec("UI_HELLO_4", {})
  t.eq(sim._store["Web Page Status"], "Page build 4 OK", "hello build 4 OK")
  sim.exec("UI_HELLO_2", {})
  t.ok(string.find(sim._store["Web Page Status"] or "", "PAGE IS STALE", 1, true) ~= nil, "stale build detected")

  -- Toggle dev1:1 via child command -> re-reads device then PUTs FULL outlet_overrides array.
  sim.queue_http("/stat/device", DEVICES_JSON, 200)
  sim.queue_http("/rest/device/dev1", '{"meta":{"rc":"ok"}}', 200)
  sim.exec("UO_COMMAND", { KEY = "dev1:1", ACTION = "TOGGLE" })
  sim.advance(0)

  local put = sim.http[#sim.http]
  t.eq(put.method, "PUT", "outlet write uses C4:urlPut")
  t.ok(string.find(put.url, "/proxy/network/api/s/default/rest/device/dev1", 1, true) ~= nil,
       "PUT uses UniFi OS prefix and device id")
  t.ok(string.find(put.body or "", "Modem", 1, true) ~= nil, "PUT preserves outlet 2 in outlet_overrides")
  t.ok(string.find(put.body or "", '"relay_state":true', 1, true) ~= nil, "PUT flips target outlet on")
end)

t.test("unifi outlet child: status, proxy commands, and LUA_ACTION UO_REFRESH", function()
  local ok = sim.load_driver(OUTLET_LUA, {
    xml = OUTLET_XML,
    deviceId = 501,
    properties = {
      ["Device ID"] = "dev1",
      ["Outlet Index"] = "1",
    },
    before = function(s) s.bind(501, 1, 100) end,
  })
  t.ok(ok, "outlet loaded: " .. tostring(sim.errors[1]))
  t.eq(sim._store["Driver Version"], "1.0.4", "outlet version 1.0.4")

  sim.advance(3000)
  local reg = sim.last_sent("UO_REGISTER")
  t.ok(reg ~= nil and reg.id == 100 and reg.params.KEY == "dev1:1", "registers on startup")

  -- Mismatched key is ignored.
  sim.sent = {}
  sim.exec("UO_STATUS", { KEY = "dev1:2", STATE = "ON" })
  t.eq(#sim.sent, 0, "mismatched key ignored")
  t.eq(sim._store["Outlet State"], "Unknown", "state unchanged")

  sim.exec("UO_STATUS", { KEY = "dev1:1", STATE = "ON" })
  t.eq(sim._store["Outlet State"], "On", "Outlet State On")
  t.ok(sim.last_sent("CLOSED") ~= nil, "proxy notified CLOSED")

  sim.exec("UO_STATUS", { KEY = "dev1:1", STATE = "OFF" })
  t.eq(sim._store["Outlet State"], "Off", "Outlet State Off")
  t.ok(sim.last_sent("OPENED") ~= nil, "proxy notified OPENED")

  sim.sent = {}
  sim.call("ReceivedFromProxy", 5001, "CLOSE", {})
  t.eq(sim.last_sent("UO_COMMAND").params.ACTION, "ON", "CLOSE sends ON")
  sim.call("ReceivedFromProxy", 5001, "TOGGLE", {})
  t.eq(sim.last_sent("UO_COMMAND").params.ACTION, "TOGGLE", "TOGGLE sends TOGGLE")

  -- Regression check for LUA_ACTION unwrapping in UniFi_Outlet_driver.lua.
  sim.sent = {}
  sim.exec("LUA_ACTION", { ACTION = "UO_REFRESH" })
  t.ok(sim.last_sent("UO_REGISTER") ~= nil, "LUA_ACTION UO_REFRESH triggers UO_REGISTER")
end)

t.finish("unifi")
