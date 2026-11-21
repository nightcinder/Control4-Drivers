local sim = require("c4sim")
local t   = require("t")

local FAN_LUA  = "drivers/haiku-senseme-fan/Haiku_SenseME_Fan_driver.lua"
local FAN_XML  = "drivers/haiku-senseme-fan/Haiku_SenseME_Fan_driver.xml"
local LGT_LUA  = "drivers/haiku-senseme-light/Haiku_SenseME_Light_driver.lua"
local LGT_XML  = "drivers/haiku-senseme-light/Haiku_SenseME_Light_driver.xml"

local function load_fan(props)
  local p = {
    ["Fan IP Address"] = "192.0.2.10",
    ["Max Fan Speed (0-7)"] = "7",
    ["Poll Interval (seconds)"] = "60",
    ["Log Mode"] = "Off",
  }
  if props then for k, v in pairs(props) do p[k] = v end end
  local ok = sim.load_driver(FAN_LUA, { xml = FAN_XML, deviceId = 100, properties = p })
  t.ok(ok, "fan loaded: " .. tostring(sim.errors[1]))
  t.eq(#sim.errors, 0, "fan init had no errors")
end

local function build_query_result_frame(propBytes)
  local env = sim.env
  local qr  = env.PBBytesField(env.QRF_PROPERTIES, propBytes)
  local r2  = env.PBBytesField(env.R2F_QUERY_RESULT, qr)
  local root = env.PBBytesField(env.RF_ROOT2, r2)
  return env.SlipEncode(root)
end

local function decode_committed_props(frame)
  local env = sim.env
  -- Strip leading/trailing 0xC0 SLIP markers and unescape.
  local inner = frame:gsub("^" .. string.char(0xC0), ""):gsub(string.char(0xC0) .. "$", "")
  local raw = env.SlipDecode(inner)
  t.ok(raw ~= nil, "SLIP decode succeeded")
  local props = {}
  env.PBWalk(raw, 1, #raw, function(fn, wt, val)
    if fn == env.RF_ROOT2 and wt == 2 then
      env.PBWalk(val, 1, #val, function(fn2, wt2, val2)
        if fn2 == env.R2F_COMMIT and wt2 == 2 then
          env.PBWalk(val2, 1, #val2, function(fn3, wt3, val3)
            if fn3 == env.CF_PROPERTIES and wt3 == 2 then
              env.PBWalk(val3, 1, #val3, function(pfn, pwt, pval)
                props[pfn] = pval
              end)
            end
          end)
        end
      end)
    end
  end)
  return props
end

t.test("haiku fan: bind, query on online, chunked SLIP RX updates fan + light", function()
  load_fan()
  t.eq(sim._store["Driver Version"], "405", "fan version bumped to 405")

  sim.call("OnNetworkBindingChanged", 6001, true)
  t.ok(#sim.net.connects >= 1, "NetConnect triggered on bind")
  t.eq(sim.net.connects[#sim.net.connects].port, 31415, "connects to BAF port 31415")

  -- Register a child light first via HK_REGISTER
  sim.exec("HK_REGISTER", { CHILD_ID = "200" })
  local hello = sim.last_sent("HK_HELLO")
  t.ok(hello ~= nil and hello.id == 200, "HK_HELLO sent to registered child")

  sim.net.sent = {}
  sim.sent = {}
  sim.call("OnConnectionStatusChanged", 6001, 31415, "ONLINE")
  t.eq(sim._store["Connection Status"], "ONLINE", "Connection Status updated")
  t.ok(#sim.net.sent >= 1, "RequestFullStatus sent Query ALL frame")

  local env = sim.env
  local caps = env.PBVarintField(env.PF_CAP_HAS_LIGHT, 1)
  local pBytes = table.concat({
    env.PBBytesField(env.PF_NAME, "Living Room Haiku"),
    env.PBBytesField(env.PF_MAC_ADDRESS, "20:F8:5E:00:00:11"),
    env.PBBytesField(env.PF_CAPABILITIES, caps),
    env.PBVarintField(env.PF_FAN_MODE, 1),
    env.PBVarintField(env.PF_SPEED, 5),
    env.PBVarintField(env.PF_REVERSE_ENABLE, 1),
    env.PBVarintField(env.PF_WHOOSH_ENABLE, 1),
    env.PBVarintField(env.PF_LIGHT_MODE, 1),
    env.PBVarintField(env.PF_LIGHT_BRIGHTNESS_PERCENT, 75),
  })
  local frame = build_query_result_frame(pBytes)

  -- Split across two TCP chunks to verify RX reassembly.
  local mid = math.floor(#frame / 2)
  sim.sent = {}
  sim.net_receive(6001, frame:sub(1, mid))
  t.eq(sim._store["Fan Name (SenseME App Name)"], "", "partial frame waits for 0xC0")
  sim.net_receive(6001, frame:sub(mid + 1))

  t.eq(sim._store["Fan Name (SenseME App Name)"], "Living Room Haiku", "fan name updated")
  t.eq(sim._store["Fan MAC Address"], "20:F8:5E:00:00:11", "MAC updated")
  t.eq(sim._store["Has Light Kit"], "Yes", "light kit capability detected")

  local spd = sim.last_sent("CURRENT_SPEED")
  t.ok(spd ~= nil and spd.params.SPEED == "5", "CURRENT_SPEED 5 pushed to proxy")
  t.ok(sim.last_sent("ON") ~= nil, "fan ON pushed to proxy")

  local hk = sim.last_sent("HK_LIGHT")
  t.ok(hk ~= nil and hk.id == 200, "HK_LIGHT pushed to child 200")
  t.eq(hk.params.POWER, "ON", "child power ON")
  t.eq(hk.params.LEVEL, "75", "child brightness 75")
  t.eq(hk.params.HASLIGHT, "1", "child hasLight=1")
  t.eq(hk.params.ONLINE, "1", "child online=1")
end)

t.test("haiku fan: proxy commands, light link, and LUA_ACTION unwrap", function()
  load_fan()
  sim.call("OnConnectionStatusChanged", 6001, 31415, "ONLINE")
  sim.net.sent = {}

  sim.call("ReceivedFromProxy", 5001, "SET_SPEED", { SPEED = "4" })
  local c1 = decode_committed_props(sim.net.sent[#sim.net.sent].data)
  t.eq(c1[sim.env.PF_FAN_MODE], 1, "SET_SPEED commits FAN_MODE=1")
  t.eq(c1[sim.env.PF_SPEED], 4, "SET_SPEED commits SPEED=4")

  sim.call("ReceivedFromProxy", 5001, "SET_DIRECTION", { DIRECTION = "REVERSE" })
  local c2 = decode_committed_props(sim.net.sent[#sim.net.sent].data)
  t.eq(c2[sim.env.PF_REVERSE_ENABLE], 1, "SET_DIRECTION commits reverse=1")

  sim.exec("HK_LIGHT_CMD", { CMD = "SET_LEVEL", LEVEL = "40" })
  local c3 = decode_committed_props(sim.net.sent[#sim.net.sent].data)
  t.eq(c3[sim.env.PF_LIGHT_MODE], 1, "HK_LIGHT_CMD commits LIGHT_MODE=1")
  t.eq(c3[sim.env.PF_LIGHT_BRIGHTNESS_PERCENT], 40, "HK_LIGHT_CMD commits brightness=40")

  -- Regression check for LUA_ACTION unwrapping in ExecuteCommand.
  sim.exec("LUA_ACTION", { ACTION = "ACTION_WHOOSH_ON" })
  local c4 = decode_committed_props(sim.net.sent[#sim.net.sent].data)
  t.eq(c4[sim.env.PF_WHOOSH_ENABLE], 1, "LUA_ACTION ACTION_WHOOSH_ON commits whoosh=1")

  sim.sent = {}
  sim.call("OnConnectionStatusChanged", 6001, 31415, "OFFLINE")
  local offEvt = sim.last_sent("ONLINE_CHANGED")
  t.ok(offEvt ~= nil and offEvt.params.STATE == "false", "OFFLINE notifies ONLINE_CHANGED false")
end)

t.test("haiku light child: auto-register, state updates, and proxy commands", function()
  local ok = sim.load_driver(LGT_LUA, {
    xml = LGT_XML,
    deviceId = 300,
    before = function(s) s.bind(300, 1, 100) end,
  })
  t.ok(ok, "light loaded: " .. tostring(sim.errors[1]))
  t.eq(#sim.errors, 0, "light init had no errors")

  sim.advance(3000)
  local reg = sim.last_sent("HK_REGISTER")
  t.ok(reg ~= nil and reg.id == 100 and reg.params.CHILD_ID == "300", "child registers on startup timer")

  sim.sent = {}
  sim.exec("HK_LIGHT", { POWER = "ON", LEVEL = "60", HASLIGHT = "1", ONLINE = "1", FANNAME = "Porch Fan" })
  t.eq(sim._store["Fan"], "Porch Fan", "Fan property set from parent name")
  t.eq(sim._store["Light Kit Detected"], "Yes", "Light Kit Detected Yes")
  t.eq(sim._store["Status"], "Online", "Status Online")
  local onChanged = sim.last_sent("ONLINE_CHANGED")
  t.ok(onChanged ~= nil and onChanged.params.STATE == "true", "proxy ONLINE_CHANGED true")
  local lvl = sim.last_sent("LIGHT_LEVEL")
  t.ok(lvl ~= nil and lvl.params == 60, "proxy LIGHT_LEVEL 60")

  sim.sent = {}
  sim.call("ReceivedFromProxy", 5001, "SET_LEVEL", { LEVEL = "35" })
  local lcmd = sim.last_sent("HK_LIGHT_CMD")
  t.ok(lcmd ~= nil and lcmd.id == 100, "SET_LEVEL forwards HK_LIGHT_CMD to parent")
  t.eq(lcmd.params.CMD, "SET_LEVEL", "CMD preserved")
  t.eq(lcmd.params.LEVEL, "35", "LEVEL forwarded")

  sim.sent = {}
  sim.exec("LUA_ACTION", { ACTION = "ACTION_REFRESH" })
  local poll = sim.last_sent("HK_POLL")
  t.ok(poll ~= nil and poll.id == 100, "Refresh action sends HK_POLL to parent")
end)

t.finish("haiku-senseme")
