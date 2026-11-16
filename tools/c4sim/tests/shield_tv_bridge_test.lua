-- Shield TV Bridge tests: Navigator TabsCommand, Remote/Apps screens, DESTROY_NAV, and keys.
local sim = require("c4sim")
local t = require("t")

local LUA = "drivers/shield-tv-bridge/driver.lua"
local XML = "drivers/shield-tv-bridge/driver.xml"

local function start(extraProps)
  local props = {
    ["Bridge URL"] = "http://bridge.test:8080",
    ["Shield Name"] = "Downstairs",
    ["Log Level"] = "5 - Debug",
    ["Log Mode"] = "Print",
  }
  for k, v in pairs(extraProps or {}) do props[k] = v end
  local ok = sim.load_driver(LUA, { xml = XML, properties = props })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
end

local function has_unknown_log(cmd)
  for _, line in ipairs(sim.prints) do
    if string.find(line, "Unknown command " .. cmd, 1, true) then return true end
  end
  return false
end

local function sent_proxy(cmd)
  for i = #sim.sent, 1, -1 do
    local s = sim.sent[i]
    if s.kind == "proxy" and s.cmd == cmd then return s end
  end
  return nil
end

local function any_url_has(s)
  for _, r in ipairs(sim.http) do
    if string.find(r.url, s, 1, true) then return true end
  end
  return false
end

t.test("TabsCommand returns Remote and Apps tabs via DATA_RECEIVED", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "TabsCommand", { NAVID = "nav-1", SEQ = 42, ROOMID = 7 })
  local reply = sent_proxy("DATA_RECEIVED")
  t.ok(reply ~= nil, "DATA_RECEIVED sent")
  t.eq(reply.id, 5001, "binding 5001")
  t.eq(reply.params.NAVID, "nav-1", "NAVID preserved")
  t.eq(reply.params.SEQ, 42, "SEQ preserved")
  t.ok(string.find(reply.params.DATA, "<ScreenId>RemoteScreen</ScreenId>", 1, true) ~= nil, "Remote tab present")
  t.ok(string.find(reply.params.DATA, "<ScreenId>AppsScreen</ScreenId>", 1, true) ~= nil, "Apps tab present")
  t.ok(not has_unknown_log("TabsCommand"), "no Unknown command log")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("GetRemoteScreen returns D-pad, Home, Back, and Now Playing items", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "GetRemoteScreen", { NAVID = "nav-1", SEQ = 43 })
  local reply = sent_proxy("DATA_RECEIVED")
  t.ok(reply ~= nil, "DATA_RECEIVED sent")
  t.ok(string.find(reply.params.DATA, "<id>DPAD_UP</id>", 1, true) ~= nil, "DPAD_UP item")
  t.ok(string.find(reply.params.DATA, "<id>DPAD_CENTER</id>", 1, true) ~= nil, "DPAD_CENTER item")
  t.ok(string.find(reply.params.DATA, "<id>HOME</id>", 1, true) ~= nil, "HOME item")
  t.ok(string.find(reply.params.DATA, "<id>BACK</id>", 1, true) ~= nil, "BACK item")
  t.ok(string.find(reply.params.DATA, "<id>__nowplaying__</id>", 1, true) ~= nil, "Now Playing item")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("GetAppsScreen lists configured App N Package entries", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "GetAppsScreen", { NAVID = "nav-1", SEQ = 44 })
  local reply = sent_proxy("DATA_RECEIVED")
  t.ok(reply ~= nil, "DATA_RECEIVED sent")
  t.ok(string.find(reply.params.DATA, "<id>com.plexapp.android</id>", 1, true) ~= nil, "Plex listed")
  t.ok(string.find(reply.params.DATA, "<title>Plex</title>", 1, true) ~= nil, "Plex label")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("RemotePress posts key and replies empty DATA_RECEIVED; __nowplaying__ opens #nowplaying", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "RemotePress", {
    NAVID = "nav-1", SEQ = 45, ARGS = '<args><arg name="id">DPAD_DOWN</arg></args>',
  })
  t.ok(any_url_has("name=DPAD_DOWN"), "DPAD_DOWN posted")
  local r1 = sent_proxy("DATA_RECEIVED")
  t.eq(r1.params.SEQ, 45, "SEQ 45 replied")
  t.eq(r1.params.DATA, "", "stays on remote screen")

  sim.call("ReceivedFromProxy", 5001, "RemotePress", {
    NAVID = "nav-1", SEQ = 46, ROOMID = 7, ARGS = '<args><arg name="id">__nowplaying__</arg></args>',
  })
  local r2 = sent_proxy("DATA_RECEIVED")
  t.eq(r2.params.SEQ, 46, "SEQ 46 replied")
  t.eq(r2.params.DATA, "<NextScreen>#nowplaying</NextScreen>", "navigates to #nowplaying")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("AppLaunchUI launches package and navigates to #nowplaying", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "AppLaunchUI", {
    NAVID = "nav-1", SEQ = 47, ROOMID = 7, ARGS = '<args><arg name="id">com.netflix.ninja</arg></args>',
  })
  t.ok(any_url_has("/v1/launch?package=com.netflix.ninja"), "launch url posted")
  local reply = sent_proxy("DATA_RECEIVED")
  t.eq(reply.params.DATA, "<NextScreen>#nowplaying</NextScreen>", "navigates to #nowplaying")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("DESTROY_NAV and DESTROY_NAVIGATOR are handled quietly", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "DESTROY_NAV", { NAVID = "nav-1" })
  sim.call("ReceivedFromProxy", 5001, "DESTROY_NAVIGATOR", { NAVID = "nav-2" })
  t.ok(not has_unknown_log("DESTROY_NAV"), "DESTROY_NAV handled")
  t.ok(not has_unknown_log("DESTROY_NAVIGATOR"), "DESTROY_NAVIGATOR handled")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("D-pad, Home, and Back keys post to /v1/key", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "UP", {})
  sim.advance(200)
  sim.call("ReceivedFromProxy", 5001, "ENTER", {})
  sim.advance(200)
  sim.call("ReceivedFromProxy", 5001, "HOME", {})
  sim.advance(200)
  sim.call("ReceivedFromProxy", 5001, "RECALL", {})
  t.ok(any_url_has("name=DPAD_UP"), "UP -> DPAD_UP")
  t.ok(any_url_has("name=DPAD_CENTER"), "ENTER -> DPAD_CENTER")
  t.ok(any_url_has("name=HOME"), "HOME -> HOME")
  t.ok(any_url_has("name=BACK"), "RECALL -> BACK")
end)

t.test("Driver Version is 1.3.4", function()
  start()
  t.eq(sim._store["Driver Version"], "1.3.4", "driver version property")
end)

t.finish("shield-tv-bridge")
