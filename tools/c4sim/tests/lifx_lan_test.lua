local sim = require("c4sim")
local t   = require("t")

local LIFX_LUA = "drivers/lifx-lan/LIFX_LAN_driver.lua"
local LIFX_XML = "drivers/lifx-lan/LIFX_LAN_driver.xml"

local function u16(v)
  v = math.floor(v) % 65536
  return string.char(v % 256, math.floor(v / 256))
end

local function u32(v)
  v = math.floor(v) % 4294967296
  return string.char(
    v % 256,
    math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256,
    math.floor(v / 16777216) % 256
  )
end

local function rd16(s, i)
  return s:byte(i) + 256 * s:byte(i + 1)
end

local function hex2bin(h)
  return (h:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end))
end

local function build_lifx_pkt(msgType, macHex, payload)
  payload = payload or ""
  local size = 36 + #payload
  local target = hex2bin(macHex) .. "\0\0"
  return u16(size)
    .. u16(1024)
    .. u32(12345)
    .. target
    .. "\0\0\0\0\0\0"
    .. string.char(0, 1)
    .. "\0\0\0\0\0\0\0\0"
    .. u16(msgType)
    .. "\0\0"
    .. payload
end

t.test("lifx-lan: unicast config, LightState, StateVersion, proxy commands, echo suppression", function()
  local ok = sim.load_driver(LIFX_LUA, {
    xml = LIFX_XML,
    deviceId = 100,
    properties = {
      ["Bulb MAC"] = "d073d5010203",
      ["Bulb IP"] = "192.0.2.50",
      ["Broadcast Address"] = "192.0.2.255",
      ["Poll Seconds"] = "15",
    },
  })
  t.ok(ok, "lifx loaded: " .. tostring(sim.errors[1]))

  -- Deliver StateVersion (type 33) for product 50 (Mini Day & Dusk: white-only, 2500-9000K).
  local verPayload = u32(1) .. u32(50) .. u32(0)
  sim.net_receive(6002, build_lifx_pkt(33, "d073d5010203", verPayload))
  t.ok(string.find(sim._store["Bulb Model"] or "", "product 50, white only, 2500-9000K", 1, true) ~= nil,
       "StateVersion updates Bulb Model and capabilities")
  local cap = sim.last_sent("DYNAMIC_CAPABILITIES_CHANGED")
  t.ok(cap ~= nil and cap.params.supports_color == "false", "DYNAMIC_CAPABILITIES_CHANGED sent")

  -- Switch to product 27 (A19 colour, 2500-9000K) and deliver LightState (type 107).
  sim.net_receive(6002, build_lifx_pkt(33, "d073d5010203", u32(1) .. u32(27) .. u32(0)))
  local lsPayload = u16(21845) .. u16(65535) .. u16(32768) .. u16(3500) .. u16(0) .. u16(65535) .. ("Desk Lamp" .. string.rep("\0", 23)) .. string.rep("\0", 8)
  sim.sent = {}
  sim.net_receive(6002, build_lifx_pkt(107, "d073d5010203", lsPayload))
  t.eq(sim._store["Status"], "Online", "LightState marks Status Online")
  local lvl = sim.last_sent("LIGHT_LEVEL")
  t.ok(lvl ~= nil and lvl.params == "50", "50% brightness reported to proxy")
  local col = sim.last_sent("LIGHT_COLOR_CHANGED")
  t.ok(col ~= nil and col.params.LIGHT_COLOR_CURRENT_COLOR_MODE == 0, "saturated colour mode=0")

  -- Proxy command ON/SET_LEVEL sends SetColor (102) and suppresses stale echo for 3s.
  sim.net.sent = {}
  sim.call("ReceivedFromProxy", 5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "250" })
  t.ok(#sim.net.sent >= 1, "SET_BRIGHTNESS_TARGET sent packet")
  t.eq(rd16(sim.net.sent[#sim.net.sent].data, 33), 102, "sent SetColor (type 102)")

  -- Stale LightState arriving 1s later is ignored due to markCmd() 3s window + 3.5s sendGet().
  sim.advance(1000)
  sim.net_receive(6002, build_lifx_pkt(107, "d073d5010203", lsPayload))
  t.eq(sim.last_sent("LIGHT_LEVEL").params, "80", "stale LightState echo ignored during 3.5s settle")

  -- After 3.5s settle timer fires sendGet(), next LightState is accepted.
  sim.advance(3000)
  sim.net_receive(6002, build_lifx_pkt(107, "d073d5010203", lsPayload))
  t.eq(sim.last_sent("LIGHT_LEVEL").params, "50", "LightState accepted after settle sendGet()")

  -- OFF command sends SetLightPower (117) with power=0.
  sim.net.sent = {}
  sim.call("ReceivedFromProxy", 5001, "OFF", {})
  t.eq(rd16(sim.net.sent[#sim.net.sent].data, 33), 117, "OFF sends SetLightPower (type 117)")
  t.eq(rd16(sim.net.sent[#sim.net.sent].data, 37), 0, "SetLightPower payload is 0")
end)

t.test("lifx-lan: colour helpers HSToXY/XYToHS and KelvinToXY/XYToKelvin round-trip", function()
  sim.load_driver(LIFX_LUA, { xml = LIFX_XML })
  local env = sim.env
  local x, y = env.HSToXY(120, 1.0)
  local h, s = env.XYToHS(x, y)
  t.ok(math.abs(h - 120) <= 5 and s > 0.8, "HSToXY -> XYToHS round-trips green")

  local kx, ky = env.KelvinToXY(4000)
  local k = env.XYToKelvin(kx, ky)
  t.ok(math.abs(k - 4000) <= 150, "KelvinToXY -> XYToKelvin round-trips 4000K")
end)

t.finish("lifx-lan")
