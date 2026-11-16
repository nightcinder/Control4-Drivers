-- Shield TV Bridge tests: Navigator tabs/screens, keys, mini app launch, PASSTHROUGH, Bound Apps.
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
  t.ok(string.find(reply.params.DATA, "<ScreenId>RemoteScreen</ScreenId>", 1, true) == nil, "Remote tab removed (1.5.0)")
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
  t.ok(string.find(reply.params.DATA, "<default_action>RemotePress</default_action>", 1, true) ~= nil, "default_action set")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("GetAppsScreen lists configured App N Package entries", function()
  start()
  sim.call("ReceivedFromProxy", 5001, "GetAppsScreen", { NAVID = "nav-1", SEQ = 44 })
  local reply = sent_proxy("DATA_RECEIVED")
  t.ok(reply ~= nil, "DATA_RECEIVED sent")
  t.ok(string.find(reply.params.DATA, "<id>com.plexapp.android</id>", 1, true) ~= nil, "Plex listed")
  t.ok(string.find(reply.params.DATA, "<title>Plex</title>", 1, true) ~= nil, "Plex label")
  t.ok(string.find(reply.params.DATA, "<default_action>AppLaunchUI</default_action>", 1, true) ~= nil, "AppLaunchUI set")
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

t.test("SELECT_SOURCE and END_* commands are handled cleanly", function()
  start()
  local before_http = #sim.http
  sim.call("ReceivedFromProxy", 5001, "SELECT_SOURCE", {})
  sim.call("ReceivedFromProxy", 5001, "RESELECT_SOURCE", {})
  sim.call("ReceivedFromProxy", 5001, "END_DOWN", {})
  sim.call("ReceivedFromProxy", 5001, "END_ENTER", {})
  t.eq(#sim.http, before_http, "SELECT_SOURCE/END_* do not send HTTP requests")
  t.ok(not has_unknown_log("SELECT_SOURCE"), "no Unknown command SELECT_SOURCE")
  t.ok(not has_unknown_log("RESELECT_SOURCE"), "no Unknown command RESELECT_SOURCE")
  t.ok(not has_unknown_log("END_DOWN"), "no Unknown command END_DOWN")
  t.ok(not has_unknown_log("END_ENTER"), "no Unknown command END_ENTER")
  t.eq(#sim.errors, 0, "no driver error")
end)

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

t.test("Bound Apps lists bound mini apps at late init", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, 300)
    s.set_device_vars(300, named({ { "UM_NV_SHIELD", "com.netflix.ninja" } }))
    s.bind(C4:GetDeviceID(), 3053, 301)
    s.set_device_vars(301, named({ { "UM_NV_SHIELD", "a.b" } }))
  end)
  t.eq(sim._store["Bound Apps"], "MiniApp 1=com.netflix.ninja; MiniApp 3=a.b", "bound apps at late init")
end)

t.test("Bound Apps updates on OnBindingChanged and shows none when empty", function()
  start(nil)
  t.eq(sim._store["Bound Apps"], "none", "none when nothing is bound")
  sim.bind(C4:GetDeviceID(), 3052, 302)
  sim.set_device_vars(302, named({ { "UM_NV_SHIELD", "c.d" } }))
  sim.call("OnBindingChanged", 3052, "RF_MINI_APP", true)
  t.eq(sim._store["Bound Apps"], "MiniApp 2=c.d", "updated on binding change")
end)

t.test("binding change outside 3051-3075 is ignored", function()
  start(nil)
  sim.bind(C4:GetDeviceID(), 3052, 302)
  sim.set_device_vars(302, named({ { "UM_NV_SHIELD", "c.d" } }))
  sim.call("OnBindingChanged", 2000, "HDMI", true)
  t.eq(sim._store["Bound Apps"], "none", "value unchanged")
  t.eq(#sim.errors, 0, "no driver error logged")
end)

-- ---- 1.5.0: UTF-8, Apps tab, Shield Remote companion hook

local STATUS_EPISODE = '{"awake":true,"app":"com.plexapp.android","art":"/art/abc",'
  .. '"now_playing":{"state":"playing","title":"Supernatural","artist":"S12E14 \\u2013 The Raid","album":"Season 12",'
  .. '"app":"com.plexapp.android"}}'

-- The driver calls C4:urlGet(url, headers, false, cb) with a DriverWorks-shape callback
-- (ticket, data, code, headers, err); the shared sim stub uses another argument order, so
-- answer /v1/status directly here.
local function feed_status(body)
  C4.urlGet = function(_, url, headers, async, cb)
    if string.find(url, "/v1/status", 1, true) and type(cb) == "function" then cb(1, body, 200, {}, nil) end
  end
  sim.call("OnDriverLateInit")
end

t.test("\\u2013 in bridge JSON becomes a real en dash, not ?", function()
  start(nil)
  feed_status(STATUS_EPISODE)
  local np = sim._store["Now Playing"] or ""
  t.ok(string.find(np, "S12E14 \226\128\147 The Raid", 1, true) ~= nil, "en dash decoded: " .. np)
  t.ok(string.find(np, "?", 1, true) == nil, "no ? in Now Playing")
end)

t.test("Apps tab lists a bound mini app by package and has a Now Playing entry", function()
  start(function(s)
    s.bind(C4:GetDeviceID(), 3051, MINI)
    s.set_device_vars(MINI, named({ { "UM_NV_SHIELD", "com.netflix.ninja" } }))
  end)
  sim.call("ReceivedFromProxy", 5001, "GetAppsScreen", { NAVID = "nav-1", SEQ = 50 })
  local reply = sent_proxy("DATA_RECEIVED")
  t.ok(string.find(reply.params.DATA, "<id>com.netflix.ninja</id>", 1, true) ~= nil, "mini app listed")
  t.ok(string.find(reply.params.DATA, "<id>__nowplaying__</id>", 1, true) ~= nil, "Now Playing entry")
end)

-- Shield Remote page on uibutton proxy 5003. Room 77; the Shield's media_service proxy is 900.
local REMOTE = 5003
local function remote_room(onShield)
  C4.RoomGetId = function() return 77 end
  C4.GetBoundConsumerDevices = function() return { [900] = "SHIELD TV" } end
  sim.set_var(77, 1000, onShield and "900" or "0")
end

t.test("UI_STATE snapshot carries now playing JSON for the page", function()
  start(nil)
  feed_status(STATUS_EPISODE)
  local v = sim.dvars["UI_STATE"] or ""
  t.ok(string.find(v, '"t":"shieldremote"', 1, true) ~= nil, "tag present: " .. v)
  t.ok(string.find(v, '"title":"Supernatural"', 1, true) ~= nil, "title in np")
  t.ok(string.find(v, '"state":"playing"', 1, true) ~= nil, "state in np")
  t.ok(string.find(v, '"art":"http://bridge.test:8080/art/abc"', 1, true) ~= nil, "plain art url")
  t.ok(string.find(v, '"awake":true', 1, true) ~= nil, "awake true")
end)

t.test("UI_KEY_* on 5003 posts the key when the room is on the Shield", function()
  start(nil)
  remote_room(true)
  sim.call("ReceivedFromProxy", REMOTE, "UI_KEY_DPAD_LEFT", {})
  sim.exec("UI_KEY_HOME", {})
  t.ok(any_url_has("name=DPAD_LEFT"), "DPAD_LEFT posted via proxy")
  sim.advance(500)
  t.ok(any_url_has("name=HOME"), "HOME posted via ExecuteCommand")
  t.ok(sim.last_sent("SELECT_VIDEO_DEVICE") == nil, "no source change")
end)

t.test("UI_KEY_* with the room elsewhere selects the Shield and drops the key", function()
  start(nil)
  remote_room(false)
  sim.exec("UI_KEY_DPAD_LEFT", {})
  local sel = sim.last_sent("SELECT_VIDEO_DEVICE")
  t.ok(sel ~= nil and sel.id == 77 and sel.params.deviceid == 900, "SELECT_VIDEO_DEVICE to room 77")
  t.ok(not any_url_has("name=DPAD_LEFT"), "key dropped on the selecting press")
end)

t.test("UI_KEY_* refuses keys outside the allow list", function()
  start(nil)
  remote_room(true)
  sim.exec("UI_KEY_POWER", {})
  sim.exec("UI_KEY_DPAD_UP&x=1", {})
  t.ok(not any_url_has("name=POWER"), "POWER not sent")
  t.ok(not any_url_has("x=1"), "injection not sent")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("opening the tile (SELECT on 5003) sends no key and no source change", function()
  start(nil)
  remote_room(false)
  local before = #sim.http
  sim.call("ReceivedFromProxy", REMOTE, "SELECT", {})
  t.eq(#sim.http, before, "no http request")
  t.ok(sim.last_sent("SELECT_VIDEO_DEVICE") == nil, "no source change")
  t.ok(not has_unknown_log("SELECT"), "not treated as a key")
end)

t.test("UI_VOL_UP / UI_MUTE go to the room", function()
  start(nil)
  remote_room(true)
  sim.exec("UI_VOL_UP", {})
  local v = sim.last_sent("PULSE_VOL_UP")
  t.ok(v ~= nil and v.id == 77, "PULSE_VOL_UP to room 77")
  sim.exec("UI_MUTE", {})
  t.ok(sim.last_sent("MUTE_TOGGLE") ~= nil, "MUTE_TOGGLE sent")
end)

t.test("UI_HELLO sets Web Page Status (OK and stale)", function()
  start(nil)
  sim.exec("UI_HELLO_3", {})
  t.eq(sim._store["Web Page Status"], "Page build 3 OK", "build 3 ok")
  sim.exec("UI_HELLO_1", {})
  t.ok(string.find(sim._store["Web Page Status"] or "", "PAGE IS STALE", 1, true) ~= nil, "stale flagged")
end)

t.test("inline art: ?w=320 thumbnail goes to the UI_ART variable as a data URI, not into UI_STATE", function()
  local sentUi
  C4.SendDataToUI = function(_, s) sentUi = s end
  local artUrls = {}
  C4.urlGet = function(_, url, headers, async, cb)
    if type(cb) ~= "function" then return end
    if string.find(url, "/v1/status", 1, true) then cb(1, STATUS_EPISODE, 200, {}, nil)
    elseif string.find(url, "/art/abc", 1, true) then
      artUrls[#artUrls + 1] = url
      cb(2, "JPEGBYTES", 200, { ["Content-Type"] = "image/jpeg" }, nil)
    end
  end
  start(nil)
  C4.SendDataToUI = function(_, s) sentUi = s end
  sim.call("OnDriverLateInit")
  t.ok(artUrls[1] and string.find(artUrls[1], "/art/abc?w=320", 1, true) ~= nil, "thumbnail requested: " .. tostring(artUrls[1]))
  local art = sim.dvars["UI_ART"] or ""
  t.ok(string.find(art, '"t":"shieldart"', 1, true) ~= nil, "UI_ART tagged")
  t.ok(string.find(art, '"key":"/art/abc"', 1, true) ~= nil, "UI_ART key")
  t.ok(string.find(art, '"data":"data:image/jpeg;base64,', 1, true) ~= nil, "UI_ART carries data URI")
  t.ok(sentUi and string.find(sentUi, '"artKey":"/art/abc"', 1, true) ~= nil, "artKey set")
  t.ok(string.find(sim.dvars["UI_STATE"] or "", "data:", 1, true) == nil, "UI_STATE has no art data")
end)

t.test("inline art too big (old bridge ignores ?w) is skipped, no error", function()
  C4.urlGet = function(_, url, headers, async, cb)
    if type(cb) ~= "function" then return end
    if string.find(url, "/v1/status", 1, true) then cb(1, STATUS_EPISODE, 200, {}, nil)
    elseif string.find(url, "/art/", 1, true) then cb(2, string.rep("x", 70000), 200, {}, nil) end
  end
  local sentUi
  start(nil)
  C4.SendDataToUI = function(_, s) sentUi = s end
  sim.exec("UI_REFRESH", {})
  t.ok(string.find(sim.dvars["UI_ART"] or "", '"data":""', 1, true) ~= nil, "UI_ART data empty")
  t.ok(sentUi and string.find(sentUi, '"artKey":"/art/abc"', 1, true) ~= nil, "art handled (key set, not retried)")
  t.eq(#sim.errors, 0, "no driver error")
end)

t.test("page art reports set Web Page Status", function()
  start(nil)
  sim.exec("UI_ART_OK", {})
  t.ok(string.find(sim._store["Web Page Status"] or "", "art shown", 1, true) ~= nil, "art shown")
  sim.exec("UI_ART_NONE", {})
  t.ok(string.find(sim._store["Web Page Status"] or "", "no art received", 1, true) ~= nil, "no art")
end)

t.test("room mute variable is watched and reaches UI_STATE", function()
  start(nil)
  remote_room(true)
  sim.set_device_vars(77, { [1012] = { name = "IS_MUTED", value = "0" }, [1011] = { name = "CURRENT_VOLUME", value = "35" } })
  sim.call("OnDriverLateInit")
  sim.call("OnWatchedVariableChanged", 77, 1012, "1")
  local v = sim.dvars["UI_STATE"] or ""
  t.ok(string.find(v, '"muted":true', 1, true) ~= nil, "muted true: " .. v)
  t.ok(string.find(v, '"vol":35', 1, true) ~= nil, "volume 35")
end)

t.test("Driver Version is 1.5.1", function()
  start(nil)
  t.eq(sim._store["Driver Version"], "1.5.1", "driver version property")
end)

t.finish("shield-tv-bridge")
