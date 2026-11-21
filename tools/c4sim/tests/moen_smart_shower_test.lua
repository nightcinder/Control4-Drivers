local sim = require("c4sim")
local t   = require("t")

local MOEN_LUA = "drivers/moen-smart-shower/Moen_Smart_Shower_Standalone_driver.lua"
local MOEN_XML = "drivers/moen-smart-shower/Moen_Smart_Shower_Standalone_driver.xml"

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
    function ws:new(url)
      local inst = setmetatable({ url = url, sent = {}, started = false, deleted = false }, ws)
      s._last_ws = inst
      return inst
    end
    function ws:SetEstablishedFunction(fn) self.on_est = fn; return self end
    function ws:SetProcessMessageFunction(fn) self.on_msg = fn; return self end
    function ws:SetOfflineFunction(fn) self.on_off = fn; return self end
    function ws:SetClosedByRemoteFunction(fn) self.on_closed = fn; return self end
    function ws:Start() self.started = true; return self end
    function ws:Send(data) self.sent[#self.sent + 1] = data; return self end
    function ws:delete() self.deleted = true end
    return ws
  end
end

local BRIDGE_STATE_OFF = '{"event":"state","shower_connected":true,"on":false,"current_f":72,"target_f":102,"active_preset":1,"min_f":60,"max_f":115,"outlets":[false,false],"presets":[{"n":1,"title":"Morning","temp_f":104,"outlets":[1]}]}\n'

t.test("moen-smart-shower: Local Bridge TCPClient state sync, extras XML, setpoint safety, commands", function()
  local ok = sim.load_driver(MOEN_LUA, {
    xml = MOEN_XML,
    deviceId = 100,
    properties = {
      Transport = "Local Bridge",
      ["Bridge Host"] = "192.0.2.70",
      ["Bridge Port"] = "8765",
    },
    before = install_common_shims,
  })
  t.ok(ok, "moen-smart-shower loaded: " .. tostring(sim.errors[1]))
  t.eq(#sim.errors, 0, "no load errors")
  t.ok(#sim.tcp_clients >= 1, "TCPClient created for Local Bridge")

  local client = sim.tcp_clients[#sim.tcp_clients]
  client:sim_connect()
  t.eq(#client.writes, 1, "OnConnect sends get_state")
  t.ok(string.find(client.writes[1].data, '"get_state"', 1, true) ~= nil, "get_state JSON line")

  -- Deliver bridge state in two TCP chunks.
  sim.sent = {}
  client:sim_read(BRIDGE_STATE_OFF:sub(1, 40))
  client:sim_read(BRIDGE_STATE_OFF:sub(41))

  t.eq(sim._store["Bridge Status"], "Connected", "Bridge Status Connected")
  local setup = sim.last_sent("EXTRAS_SETUP_CHANGED")
  t.ok(setup ~= nil and string.find(setup.params.XML or "", "Morning", 1, true) ~= nil,
       "EXTRAS_SETUP_CHANGED contains Morning preset")
  local mode = sim.last_sent("HVAC_MODE_CHANGED")
  t.ok(mode ~= nil and mode.params.MODE == "Off", "HVAC_MODE_CHANGED Off")

  -- In Local Bridge mode, SET_SETPOINT_HEAT while shower is off must NOT start water.
  local beforeWrites = #client.writes
  sim.call("ReceivedFromProxy", 5001, "SET_SETPOINT_HEAT", { SETPOINT = 105 })
  t.eq(#client.writes, beforeWrites, "setpoint ignored while shower is off in Local Bridge mode")

  -- Turn shower on via thermostat proxy SET_MODE_HVAC Heat, then adjust setpoint.
  sim.call("ReceivedFromProxy", 5001, "SET_MODE_HVAC", { MODE = "Heat" })
  t.ok(string.find(client.writes[#client.writes].data, '"on"', 1, true) ~= nil, "SET_MODE_HVAC Heat sends cmd=on")

  sim.call("ReceivedFromProxy", 5001, "SET_SETPOINT_HEAT", { SETPOINT = 106 })
  t.ok(string.find(client.writes[#client.writes].data, '"set_temp"', 1, true) ~= nil, "SET_SETPOINT_HEAT while running sends set_temp")

  -- Activate preset 1 via ExtrasPreset_1 and turn off via LUA_ACTION.
  sim.call("ReceivedFromProxy", 5001, "ExtrasPreset_1", {})
  t.ok(string.find(client.writes[#client.writes].data, '"preset"', 1, true) ~= nil, "ExtrasPreset_1 sends cmd=preset")

  sim.exec("LUA_ACTION", { ACTION = "ACTION_SHOWER_OFF" })
  t.ok(string.find(client.writes[#client.writes].data, '"off"', 1, true) ~= nil, "ACTION_SHOWER_OFF sends cmd=off")
end)

t.finish("moen-smart-shower")
