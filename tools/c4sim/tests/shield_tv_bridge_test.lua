-- Shield TV Bridge tests: app launch from the bound mini app. Run from the repo root.
local sim = require("c4sim")
local t = require("t")

local LUA = "drivers/shield-tv-bridge/driver.lua"
local XML = "drivers/shield-tv-bridge/driver.xml"
local MINI = 300   -- mini app device id bound to MiniApp 1 (input 3051)

-- Fresh driver per test. `extra` runs after reset, before OnDriverInit (bind, set_device_vars).
local function start(extra, extraProps)
  local props = { ["Bridge URL"] = "http://bridge.test:8080", ["Shield Name"] = "Downstairs" }
  for k, v in pairs(extraProps or {}) do props[k] = v end
  local ok = sim.load_driver(LUA, {
    xml = XML,
    properties = props,
    before = function(s)
      if extra then extra(s) end
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
end

local function send_input(input)
  sim.call("ReceivedFromProxy", 5002, "SET_INPUT", { INPUT = tostring(input), OUTPUT = "4000" })
end

-- package= value from the last /v1/launch request, or nil.
local function launched()
  local pkg
  for _, r in ipairs(sim.http) do
    if string.find(r.url, "/v1/launch", 1, true) then
      pkg = string.match(r.url, "[?&]package=([^&]*)")
    end
  end
  return pkg
end

local function any_url_has(s)
  for _, r in ipairs(sim.http) do
    if string.find(r.url, s, 1, true) then return true end
  end
  return false
end

-- Named shape: { [varId] = { name = ..., value = ... } }
local function named(list)
  local out = {}
  for i, pair in ipairs(list) do
    out[1000 + i] = { name = pair[1], value = pair[2] }
  end
  return out
end

t.test("bound mini app UM_NV_SHIELD wins over App 1 Package", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, MINI)
    s.set_device_vars(MINI, named({ { "UM_NV_SHIELD", "com.netflix.ninja" } }))
  end)
  send_input("3051")
  t.eq(launched(), "com.netflix.ninja", "mini app package launched")
end)

t.test("UM_SUNBRITE_TV is used before UM_AMAZON", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, MINI)
    s.set_device_vars(MINI, named({ { "UM_AMAZON", "a.amz" }, { "UM_SUNBRITE_TV", "a.sun" } }))
  end)
  send_input("3051")
  t.eq(launched(), "a.sun", "sunbrite before amazon")
end)

t.test("empty UM_NV_SHIELD falls through to UM_AMAZON", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, MINI)
    s.set_device_vars(MINI, named({ { "UM_NV_SHIELD", "" }, { "UM_AMAZON", "a.amz" } }))
  end)
  send_input("3051")
  t.eq(launched(), "a.amz", "empty value skipped")
end)

t.test("plain name map shape works", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, MINI)
    s.set_device_vars(MINI, { UM_NV_SHIELD = "a.map" })
  end)
  send_input("3051")
  t.eq(launched(), "a.map", "plain map value launched")
end)

t.test("no bound device uses the property", function()
  start()
  send_input("3051")
  t.eq(launched(), "com.plexapp.android", "App 1 Package default used")
end)

t.test("GetDeviceVariables error uses the property, no driver error", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, MINI)
    s.set_device_vars(MINI, "error")
  end)
  send_input("3051")
  t.eq(launched(), "com.plexapp.android", "property used after error")
  t.eq(#sim.errors, 0, "no driver error logged")
end)

t.test("unsafe mini app value is never sent", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, MINI)
    s.set_device_vars(MINI, named({ { "UM_NV_SHIELD", "com.x;rm" } }))
  end)
  send_input("3051")
  t.eq(launched(), "com.plexapp.android", "property used instead")
  t.ok(not any_url_has("com.x"), "unsafe value not in any url")
end)

t.test("no mini app and empty property launches nothing", function()
  start(nil, { ["App 3 Package"] = "" })
  send_input("3053")
  t.eq(launched(), nil, "nothing launched with default App 3 Package")
end)

t.test("PASSTHROUGH UP on binding 5002 sends DPAD_UP", function()
  start(nil)
  sim.call("ReceivedFromProxy", 5002, "PASSTHROUGH", { PASSTHROUGH_COMMAND = "UP" })
  t.ok(any_url_has("/v1/key") and any_url_has("name=DPAD_UP"), "DPAD_UP key posted")
end)

t.test("PASSTHROUGH PLAY on binding 3051 sends MEDIA_PLAY", function()
  start(nil)
  sim.call("ReceivedFromProxy", 3051, "PASSTHROUGH", { PASSTHROUGH_COMMAND = "PLAY" })
  t.ok(any_url_has("/v1/key") and any_url_has("name=MEDIA_PLAY"), "MEDIA_PLAY key posted")
end)

t.test("PASSTHROUGH without a command does nothing", function()
  start(nil)
  local before = #sim.http
  sim.call("ReceivedFromProxy", 5002, "PASSTHROUGH", {})
  t.eq(#sim.http, before, "no http request")
  t.eq(#sim.errors, 0, "no driver error logged")
end)

t.finish("shield-tv-bridge")
