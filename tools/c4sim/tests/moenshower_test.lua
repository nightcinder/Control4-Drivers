local sim = require("c4sim")
local t   = require("t")

local MS_LUA = "drivers/moenshower/Moen_Smart_Shower_Standalone_driver.lua"
local MS_XML = "drivers/moenshower/driver.xml"

local function install_common_shims(s)
  local mods = {
    "drivers-common-public.global.handlers",
    "drivers-common-public.global.timer",
    "drivers-common-public.global.url",
    "drivers-common-public.module.websocket",
  }
  for _, m in ipairs(mods) do package.loaded[m] = nil end

  package.preload["drivers-common-public.global.handlers"] = function()
    local env = s.env
    env.EC  = env.EC or {}
    env.OPC = env.OPC or {}
    env.RFP = env.RFP or {}
    env.OBC = env.OBC or {}
    env.OCS = env.OCS or {}
    env.RFN = env.RFN or {}
    env.ExecuteCommand = function(cmd, params)
      params = params or {}
      if cmd == "LUA_ACTION" and params.ACTION then cmd = params.ACTION end
      local fn = env.EC[cmd] or env.EC[tostring(cmd):gsub(" ", "_")]
      if fn then return fn(params) end
    end
    env.OnPropertyChanged = function(prop)
      local fn = env.OPC[prop] or env.OPC[tostring(prop):gsub(" ", "_")]
      if fn then return fn(env.Properties[prop]) end
    end
    env.ReceivedFromProxy = function(idBinding, cmd, params, args)
      local fn = env.RFP[idBinding] or env.RFP[cmd]
      if fn then return fn(idBinding, cmd, params, args) end
    end
    env.OnBindingChanged = function(idBinding, class, bound)
      local fn = env.OBC[idBinding]
      if fn then return fn(idBinding, class, bound) end
    end
    return true
  end

  package.preload["drivers-common-public.global.timer"] = function()
    local env = s.env
    env.ONE_SECOND = 1000
    env.ONE_MINUTE = 60000
    env.Timer = env.Timer or {}
    env.CancelTimer = function(id)
      if id and env.Timer[id] then
        local h = env.Timer[id]
        env.Timer[id] = nil
        pcall(function() h:Cancel() end)
      end
    end
    env.SetTimer = function(id, ms, fn, repeating)
      env.CancelTimer(id)
      if ms and ms > 0 and type(fn) == "function" then
        env.Timer[id] = env.C4:SetTimer(ms, function()
          if not repeating then env.Timer[id] = nil end
          fn(id)
        end, repeating == true)
      end
      return env.Timer[id]
    end
    return true
  end

  package.preload["drivers-common-public.global.url"] = function()
    local env = s.env
    env.JSON = {
      encode = function(_, v) return env.C4:JsonEncode(v) end,
      decode = function(_, str)
        local ok, r = pcall(function() return env.C4:JsonDecode(str) end)
        return ok and r or nil
      end,
    }
    env.URLEncode = function(str)
      return tostring(str or ""):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
      end)
    end
    local function wrap_cb(cb, context, url)
      return function(_, body, code, hdrs, err)
        local data = body
        if type(body) == "string" and body ~= "" then
          local ok, j = pcall(function() return env.C4:JsonDecode(body) end)
          if ok and type(j) == "table" then data = j end
        end
        if cb then cb(err, tonumber(code) or 0, hdrs or {}, data, context, url) end
      end
    end
    env.urlGet = function(url, headers, cb, context)
      return env.C4:urlGet(url, headers or {}, false, wrap_cb(cb, context, url))
    end
    env.urlPost = function(url, data, headers, cb, context)
      return env.C4:urlPost(url, data or "", headers or {}, false, wrap_cb(cb, context, url))
    end
    return true
  end

  package.preload["drivers-common-public.module.websocket"] = function()
    local ws = {}
    ws.__index = ws
    function ws:new(url) return setmetatable({ url = url, sent = {} }, ws) end
    function ws:SetEstablishedFunction(fn) self.on_est = fn; return self end
    function ws:SetProcessMessageFunction(fn) self.on_msg = fn; return self end
    function ws:SetOfflineFunction(fn) self.on_off = fn; return self end
    function ws:SetClosedByRemoteFunction(fn) self.on_closed = fn; return self end
    function ws:Start() return self end
    function ws:Send(data) self.sent[#self.sent + 1] = data; return self end
    function ws:delete() end
    return ws
  end
end

local STATE_OFF = '{"event":"state","shower_connected":true,"on":false,"current_f":70,"target_f":100,"active_preset":1,"min_f":60,"max_f":115,"outlets":[false,false],"presets":[{"n":1,"title":"His","temp_f":104,"outlets":[1]},{"n":2,"title":"Hers","temp_f":106,"outlets":[1,2]}]}\n'
local STATE_RUNNING_P1 = '{"event":"state","shower_connected":true,"on":true,"current_f":98,"target_f":104,"active_preset":1,"min_f":60,"max_f":115,"outlets":[true,false],"presets":[{"n":1,"title":"His","temp_f":104,"outlets":[1]},{"n":2,"title":"Hers","temp_f":106,"outlets":[1,2]}]}\n'

t.test("moenshower: web view gating, UI commands, keypad tap/hold/ignore-other-preset, LEDs", function()
  local ok = sim.load_driver(MS_LUA, {
    xml = MS_XML,
    deviceId = 100,
    properties = {
      Transport = "Local Bridge",
      ["Bridge Host"] = "192.0.2.71",
      ["Bridge Port"] = "8765",
      ["Key Hold Time (ms)"] = "1000",
      ["If Another Preset Is Running"] = "Ignore the key",
    },
    before = install_common_shims,
  })
  t.ok(ok, "moenshower loaded: " .. tostring(sim.errors[1]))
  t.eq(#sim.errors, 0, "no load errors")

  local client = sim.tcp_clients[#sim.tcp_clients]
  -- Before bridge connects, UI_SHOWER_ON must be refused by the v304 bridge gate.
  sim.exec("UI_SHOWER_ON", {})
  t.eq(#client.writes, 0, "UI_SHOWER_ON refused before bridge is connected")

  -- Connect bridge and deliver initial state.
  client:sim_connect()
  client:sim_read(STATE_OFF)
  t.eq(sim._store["Bridge Status"], "Connected", "Bridge Status Connected")

  -- Web view hello checks (PAGE_BUILD = "2").
  sim.exec("UI_HELLO_2", {})
  t.eq(sim._store["Web Page Status"], "Page build 2 OK", "UI_HELLO_2 OK")
  sim.exec("UI_HELLO_1", {})
  t.ok(string.find(sim._store["Web Page Status"] or "", "PAGE IS STALE", 1, true) ~= nil, "stale build flagged")

  -- Keypad Preset Key 1 (binding 901): tap (DO_PUSH + DO_CLICK) starts preset 1.
  sim.call("ReceivedFromProxy", 901, "DO_PUSH", {})
  sim.call("ReceivedFromProxy", 901, "DO_CLICK", {})
  -- A trailing DO_RELEASE from the same physical tap is ignored.
  local afterTapWrites = #client.writes
  sim.call("ReceivedFromProxy", 901, "DO_RELEASE", {})
  t.eq(#client.writes, afterTapWrites, "duplicate DO_RELEASE after DO_CLICK ignored")
  t.ok(string.find(client.writes[#client.writes].data, '"preset"', 1, true) ~= nil, "key 901 tap starts preset 1")

  -- Advance 400ms to flush paced keypad LED queue (BUTTON_COLORS + MATCH_LED_STATE).
  sim.advance(400)
  t.ok(sim.last_sent("BUTTON_COLORS") ~= nil, "BUTTON_COLORS sent to keypad")
  t.ok(sim.last_sent("MATCH_LED_STATE") ~= nil, "MATCH_LED_STATE sent to keypad")

  -- Deliver running state for preset 1; tapping Preset Key 2 (902) is ignored when "Ignore the key" is set.
  client:sim_read(STATE_RUNNING_P1)
  local beforeKey2 = #client.writes
  sim.call("ReceivedFromProxy", 902, "DO_PUSH", {})
  sim.call("ReceivedFromProxy", 902, "DO_CLICK", {})
  t.eq(#client.writes, beforeKey2, "Preset Key 2 ignored while Preset 1 is running")

  -- Holding Preset Key 2 for 1000ms stops the shower.
  sim.call("ReceivedFromProxy", 902, "DO_PUSH", {})
  sim.advance(1000)
  sim.call("ReceivedFromProxy", 902, "DO_RELEASE", {})
  t.ok(string.find(client.writes[#client.writes].data, '"off"', 1, true) ~= nil, "key hold stops shower")
end)

t.finish("moenshower")
