-- LIFX LAN Light driver for Control4 (Light V2 proxy)
-- DRIVER_VERSION is bumped inside this file; the filename stays the same.
DRIVER_VERSION = "1.1.1"

local PROXY    = 5001
local NET_BCAST = 6001   -- UDP broadcast / discovery connection
local NET_BULB  = 6002   -- optional unicast connection when "Bulb IP" is set
local PORT      = 56700
local SOURCE_ID = 1397311310 -- any value other than 0/1

local MSG = {
  GetService = 2, StateService = 3,
  GetLabel = 23, StateLabel = 25,
  GetVersion = 32, StateVersion = 33,
  Get = 101, SetColor = 102, LightState = 107,
  SetLightPower = 117, StatePower = 118,
}

-- ---------------------------------------------------------------- state
local S = {
  hue = 0, sat = 0, bri = 65535, kelvin = 3500, power = false,
  known = false,
}
-- Product registry (LIFX). Unknown single-zone products default to colour, 1500-9000K.
local PRODUCT_DEFAULT = { color = true, kmin = 1500, kmax = 9000 }
local PRODUCTS = {}
local function addProducts(color, kmin, kmax, ...)
  for _, pid in ipairs({ ... }) do PRODUCTS[pid] = { color = color, kmin = kmin, kmax = kmax } end
end
addProducts(true, 2500, 9000, 1,2,3,14,20,21,22,23,24,25,26,27,28,29,30,33,36,37,40,43,44,45,46)
addProducts(true, 2700, 6500, 15,191,192)
addProducts(false, 2500, 9000, 39,50,60)          -- 50/60 = Mini Day & Dusk
addProducts(false, 2700, 6500, 10,11,18,19)
addProducts(false, 2700, 2700, 12,13,51,54,61,66,87,88,127,128,133,134)
addProducts(false, 2200, 6500, 67,81,96)
addProducts(false, 2200, 2200, 82,86,100,102)
addProducts(false, 2000, 2000, 85,101)
addProducts(false, 1500, 9000, 113,114,125,126,131,132)
local caps = { color = true, kmin = 2500, kmax = 9000 }  -- until the model is known
local modelPid = nil
local found = {}          -- mac -> label (discovery results)
local seq = 0
local pollTimer = nil
local lastNotified = ""

local function dbg(...)
  if Properties and Properties["Debug Mode"] == "On" then print("[LIFX]", ...) end
end

local function setStatus(s)
  C4:UpdateProperty("Status", s)
end

-- ---------------------------------------------------------------- byte helpers (no bit ops: works on Lua 5.1)
local function u16(v) v = math.floor(v) % 65536; return string.char(v % 256, math.floor(v / 256)) end
local function u32(v)
  v = math.floor(v) % 4294967296
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function rd16(s, i) return s:byte(i) + 256 * s:byte(i + 1) end
local function hex2bin(h)
  local out = {}
  for pair in h:gmatch("%x%x") do out[#out + 1] = string.char(tonumber(pair, 16)) end
  return table.concat(out)
end
local function bin2hex(b)
  local out = {}
  for i = 1, #b do out[#out + 1] = string.format("%02x", b:byte(i)) end
  return table.concat(out)
end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function round(v) return math.floor(v + 0.5) end

-- ---------------------------------------------------------------- color math
local function toLinear(c) if c <= 0.04045 then return c / 12.92 end return ((c + 0.055) / 1.055) ^ 2.4 end
local function toSrgb(c) if c <= 0.0031308 then return 12.92 * c end return 1.055 * (c ^ (1 / 2.4)) - 0.055 end

-- hue 0..360, sat 0..1 (value fixed at 1) -> CIE xy
function HSToXY(h, s)
  h = h % 360
  local c = s
  local hp = h / 60
  local x = c * (1 - math.abs(hp % 2 - 1))
  local r, g, b = 0, 0, 0
  if hp < 1 then r, g = c, x elseif hp < 2 then r, g = x, c elseif hp < 3 then g, b = c, x
  elseif hp < 4 then g, b = x, c elseif hp < 5 then r, b = x, c else r, b = c, x end
  local m = 1 - c
  r, g, b = toLinear(r + m), toLinear(g + m), toLinear(b + m)
  local X = 0.4124 * r + 0.3576 * g + 0.1805 * b
  local Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
  local Z = 0.0193 * r + 0.1192 * g + 0.9505 * b
  local sum = X + Y + Z
  if sum == 0 then return 0.3127, 0.3290 end
  return X / sum, Y / sum
end

-- CIE xy -> hue 0..360, sat 0..1 (brightness handled separately)
function XYToHS(x, y)
  if y <= 0.0001 then return 0, 0 end
  local Y = 1.0
  local X, Z = (x / y) * Y, ((1 - x - y) / y) * Y
  local r = 3.2406 * X - 1.5372 * Y - 0.4986 * Z
  local g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
  local b = 0.0557 * X - 0.2040 * Y + 1.0570 * Z
  r, g, b = math.max(r, 0), math.max(g, 0), math.max(b, 0)
  local mx = math.max(r, g, b)
  if mx <= 0 then return 0, 0 end
  r, g, b = toSrgb(r / mx), toSrgb(g / mx), toSrgb(b / mx)
  local hi, lo = math.max(r, g, b), math.min(r, g, b)
  local d = hi - lo
  local h = 0
  if d > 0 then
    if hi == r then h = ((g - b) / d) % 6 elseif hi == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h * 60
  end
  local s = 0
  if hi > 0 then s = d / hi end
  return h % 360, s
end

-- Kelvin -> xy on the Planckian locus (Kim et al. cubic spline, 1667K-25000K)
function KelvinToXY(T)
  T = clamp(T, 1667, 25000)
  local x
  if T <= 4000 then
    x = -0.2661239e9 / T ^ 3 - 0.2343589e6 / T ^ 2 + 0.8776956e3 / T + 0.179910
  else
    x = -3.0258469e9 / T ^ 3 + 2.1070379e6 / T ^ 2 + 0.2226347e3 / T + 0.240390
  end
  local y
  if T <= 2222 then y = -1.1063814 * x ^ 3 - 1.34811020 * x ^ 2 + 2.18555832 * x - 0.20219683
  elseif T <= 4000 then y = -0.9549476 * x ^ 3 - 1.37418593 * x ^ 2 + 2.09137015 * x - 0.16748867
  else y = 3.0817580 * x ^ 3 - 5.87338670 * x ^ 2 + 3.75112997 * x - 0.37001483 end
  return x, y
end

-- xy -> Kelvin (McCamy)
function XYToKelvin(x, y)
  local n = (x - 0.3320) / (0.1858 - y)
  return 437 * n ^ 3 + 3601 * n ^ 2 + 6861 * n + 5517
end

-- ---------------------------------------------------------------- LIFX packets
local function buildPacket(msgType, payload, opts)
  opts = opts or {}
  payload = payload or ""
  seq = (seq + 1) % 256
  local target = opts.mac and hex2bin(opts.mac) or ""
  target = target .. string.rep("\0", 8 - #target)
  local flags = (opts.res and 1 or 0) + (opts.ack and 2 or 0)
  -- protocol 1024 | addressable (bit 12) | tagged (bit 13)
  local field = 1024 + 4096 + (opts.tagged and 8192 or 0)
  return u16(36 + #payload) .. u16(field) .. u32(SOURCE_ID)
      .. target .. string.rep("\0", 6) .. string.char(flags) .. string.char(seq)
      .. string.rep("\0", 8) .. u16(msgType) .. "\0\0"
      .. payload
end

local function bulbMac()
  local m = (Properties["Bulb MAC"] or ""):lower():gsub("[^%x]", "")
  if #m == 12 then return m end
  return nil
end

local function unicast()
  local ip = Properties["Bulb IP"] or ""
  return ip ~= "" and ip or nil
end

local function send(pkt)
  if unicast() then
    C4:SendToNetwork(NET_BULB, PORT, pkt)
  else
    C4:SendToNetwork(NET_BCAST, PORT, pkt)
  end
end

local function sendBroadcast(pkt) C4:SendToNetwork(NET_BCAST, PORT, pkt) end

local function sendVersion()
  if bulbMac() then send(buildPacket(MSG.GetVersion, "", { mac = bulbMac(), res = true })) end
end

local cmdGen, lastCmd, lastGetGen = 0, 0, 0

local function sendGet()
  lastGetGen = cmdGen  -- a state reply only counts if no command was sent after this Get
  if bulbMac() then
    send(buildPacket(MSG.Get, "", { mac = bulbMac(), res = true }))
  else
    -- Bulbs ignore untagged requests that carry no MAC. A tagged GetService is always
    -- answered, and the reply tells us the MAC so every later message can be addressed.
    send(buildPacket(MSG.GetService, "", { tagged = true, res = true }))
  end
end

-- Replies to our own sets arrive late and out of order and bounced the UI back to old values: no replies for sets,
-- ignore state for a few seconds after a command, then resync once with a Get.
local function markCmd()
  lastCmd = os.time()
  cmdGen = cmdGen + 1
  local g = cmdGen
  C4:SetTimer(3500, function() if g == cmdGen then sendGet() end end, false)
end

local function sendColor(hue, sat, bri, kelvin, ms)
  local payload = "\0" .. u16(hue) .. u16(sat) .. u16(bri) .. u16(kelvin) .. u32(ms or 0)
  markCmd()
  send(buildPacket(MSG.SetColor, payload, { mac = bulbMac(), res = false }))
end

local function sendPower(on, ms)
  markCmd()
  send(buildPacket(MSG.SetLightPower, u16(on and 65535 or 0) .. u32(ms or 0), { mac = bulbMac(), res = false }))
end

-- ---------------------------------------------------------------- proxy feedback
local function notifyState()
  local pct = 0
  if S.power then pct = round(S.bri * 100 / 65535) end
  local mode, x, y
  if (not caps.color) or S.sat < 3300 then   -- white-only bulb, or <~5% saturation: white / CCT
    mode = 1
    x, y = KelvinToXY(S.kelvin)
  else
    mode = 0
    x, y = HSToXY(S.hue * 360 / 65535, S.sat / 65535)
  end
  local sig = string.format("%d|%d|%d|%.4f|%.4f", pct, mode, S.kelvin, x, y)
  if sig == lastNotified then return end
  lastNotified = sig
  C4:SendToProxy(PROXY, "LIGHT_LEVEL", tostring(pct))
  C4:SendToProxy(PROXY, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = pct })
  C4:SendToProxy(PROXY, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
    LIGHT_COLOR_CURRENT_MODE = mode,
  })
  dbg("notify", sig)
end

local function applyProduct(pid)
  modelPid = pid
  local c = PRODUCTS[pid] or PRODUCT_DEFAULT
  caps = { color = c.color, kmin = c.kmin, kmax = c.kmax }
  local cct = caps.kmin < caps.kmax
  pcall(function()
    C4:UpdateProperty("Bulb Model", "product " .. pid .. (caps.color and ", colour" or ", white only")
      .. (cct and string.format(", %d-%dK", caps.kmin, caps.kmax) or ", fixed white"))
  end)
  pcall(function()
    C4:SendToProxy(PROXY, "DYNAMIC_CAPABILITIES_CHANGED", {
      supports_color = tostring(caps.color),
      supports_color_correlated_temperature = tostring(cct),
      color_correlated_temperature_min = caps.kmin,
      color_correlated_temperature_max = caps.kmax,
    })
  end)
  S.kelvin = clamp(S.kelvin, caps.kmin, caps.kmax)
  lastNotified = ""
  dbg("model", pid, caps.color, caps.kmin, caps.kmax)
  if S.known then notifyState() end
end

-- ---------------------------------------------------------------- commands from the proxy
local function pickNumber(t, ...)
  for _, k in ipairs({ ... }) do
    local v = tonumber(t[k])
    if v then return v end
  end
  return nil
end

local function setLevel(pct, ms)
  pct = clamp(pct, 0, 100)
  if pct <= 0 then
    S.power = false
    sendPower(false, ms)
  else
    S.bri = round(pct * 65535 / 100)
    if not S.power then
      -- set brightness instantly, then fade the power on so it doesn't flash the old level
      sendColor(S.hue, S.sat, S.bri, S.kelvin, 0)
      S.power = true
      sendPower(true, ms)
    else
      sendColor(S.hue, S.sat, S.bri, S.kelvin, ms)
    end
  end
  notifyState()
end

local function setColorFromProxy(p)
  local ms = pickNumber(p, "LIGHT_COLOR_TARGET_RATE", "RATE") or 0
  local mode = pickNumber(p, "LIGHT_COLOR_TARGET_MODE", "LIGHT_COLOR_TARGET_COLOR_MODE")
  local x = pickNumber(p, "LIGHT_COLOR_TARGET_X")
  local y = pickNumber(p, "LIGHT_COLOR_TARGET_Y")
  if not (x and y) then
    print("[LIFX] SET_COLOR_TARGET without X/Y - params follow, please report:")
    for k, v in pairs(p) do print("   ", k, v) end
    return
  end
  -- Control4's light_v2 proxy can rewrite the target mode to 0 (xy) even for white/CCT requests.
  -- A point on/near the Planckian locus is a white request: treat it as CCT so it never becomes a saturated tint.
  local nearWhite = false
  do
    local k = XYToKelvin(x, y)
    if k >= 1500 and k <= 9000 then
      local lx, ly = KelvinToXY(k)
      nearWhite = ((x - lx) ^ 2 + (y - ly) ^ 2) ^ 0.5 < 0.015
    end
  end
  if mode == 1 or nearWhite or not caps.color then
    S.kelvin = clamp(round(XYToKelvin(x, y)), caps.kmin, caps.kmax)
    S.sat = 0
  else
    local h, s = XYToHS(x, y)
    S.hue = round(h * 65535 / 360)
    S.sat = round(s * 65535)
    if S.sat < 3300 then S.sat = 0 end
  end
  sendColor(S.hue, S.sat, S.bri, S.kelvin, ms)
  notifyState()
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  dbg("proxy cmd", strCommand)
  if Properties["Debug Mode"] == "On" then for k, v in pairs(tParams) do dbg("   ", k, v) end end

  if strCommand == "ON" then
    local ms = pickNumber(tParams, "RATE", "LIGHT_BRIGHTNESS_TARGET_RATE") or 0
    local lvl = pickNumber(tParams, "LEVEL", "LIGHT_BRIGHTNESS_TARGET")
    setLevel(lvl or round(S.bri * 100 / 65535), ms)
  elseif strCommand == "OFF" then
    S.power = false
    sendPower(false, pickNumber(tParams, "RATE", "LIGHT_BRIGHTNESS_TARGET_RATE") or 0)
    notifyState()
  elseif strCommand == "TOGGLE" then
    if S.power then ReceivedFromProxy(idBinding, "OFF", {}) else ReceivedFromProxy(idBinding, "ON", {}) end
  elseif strCommand == "SET_BRIGHTNESS_TARGET" or strCommand == "RAMP_TO_LEVEL" or strCommand == "SET_LEVEL" then
    local lvl = pickNumber(tParams, "LIGHT_BRIGHTNESS_TARGET", "LEVEL", "BRIGHTNESS")
    local ms = pickNumber(tParams, "RATE", "TIME", "LIGHT_BRIGHTNESS_TARGET_RATE") or 0
    if lvl then setLevel(lvl, ms) end
  elseif strCommand == "SET_COLOR_TARGET" then
    setColorFromProxy(tParams)
  elseif strCommand == "GET_CONNECTED_STATE" then
    C4:SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = "true" })
  elseif strCommand == "SET_BRIGHTNESS_STOP" or strCommand == "SET_COLOR_STOP" then
    sendGet()
  else
    dbg("unhandled proxy command", strCommand)
  end
end

-- ---------------------------------------------------------------- network receive
local function handleLightState(data)
  if not modelPid then sendVersion() end
  if cmdGen ~= lastGetGen or os.time() - lastCmd < 3 then return end  -- stale echo of a recent command
  S.hue = rd16(data, 37)
  S.sat = rd16(data, 39)
  S.bri = rd16(data, 41)
  S.kelvin = rd16(data, 43)
  S.power = rd16(data, 47) > 0
  S.known = true
  setStatus("Online")
  notifyState()
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  if not strData or #strData < 36 then return end
  local msgType = rd16(strData, 33)
  local mac = bin2hex(strData:sub(9, 14))
  dbg("rx", idBinding, "type", msgType, "from", mac)

  if msgType == MSG.StateService then
    if not found[mac] then
      found[mac] = mac
      -- ask this bulb for its label (addressed by MAC so only it answers)
      sendBroadcast(buildPacket(MSG.GetLabel, "", { mac = mac, res = true }))
    end
    if unicast() and not bulbMac() then
      C4:UpdateProperty("Bulb MAC", mac)
      sendGet()   -- now addressed by MAC
    end
  elseif msgType == MSG.StateLabel then
    local raw = strData:sub(37, 68)
    local n = #raw
    for i = 1, #raw do
      if raw:byte(i) == 0 then n = i - 1; break end
    end
    found[mac] = raw:sub(1, n)
  elseif msgType == MSG.LightState then
    local mine = bulbMac()
    if idBinding == NET_BULB or mine == nil or mine == mac then
      if mine == nil and not unicast() then return end -- unconfigured broadcast mode: ignore strangers
      handleLightState(strData)
    end
  elseif msgType == MSG.StateVersion then
    local mine = bulbMac()
    if idBinding == NET_BULB or mine == mac then
      applyProduct(rd16(strData, 41) + 65536 * rd16(strData, 43))
    end
  elseif msgType == MSG.StatePower then
    local mine = bulbMac()
    if idBinding == NET_BULB or mine == mac then
      S.power = rd16(strData, 37) > 0
      notifyState()
    end
  end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  dbg("connection", idBinding, nPort, strStatus)
end

-- ---------------------------------------------------------------- discovery
local function refreshBulbList()
  local items = {}
  local macs = {}
  for mac in pairs(found) do macs[#macs + 1] = mac end
  table.sort(macs)
  for _, mac in ipairs(macs) do
    local label = found[mac]
    if label == mac or label == "" then label = "LIFX" end
    items[#items + 1] = string.format("%s (%s)", label, mac)
  end
  if #items == 0 then
    C4:UpdatePropertyList("Select Bulb", "(none found - see Debug Mode)", "(none found - see Debug Mode)")
    setStatus("Discovery found no bulbs")
  else
    C4:UpdatePropertyList("Select Bulb", table.concat(items, ","), items[1])
    setStatus(string.format("Discovered %d bulb(s); pick one in Select Bulb", #items))
  end
end

function DiscoverBulbs()
  found = {}
  setStatus("Discovering...")
  for _ = 1, 3 do  -- UDP is lossy; send a few times
    sendBroadcast(buildPacket(MSG.GetService, "", { tagged = true, res = true }))
  end
  C4:SetTimer(2500, function() refreshBulbList() end, false)
  C4:SetTimer(4500, function() refreshBulbList() end, false)  -- catch late label replies
end

function IdentifyBulb()
  local ms = 400
  local h, s, b, k, p = S.hue or 0, S.sat or 0, S.bri or 65535, S.kelvin or 3500, S.power
  sendPower(true, 0)
  for i = 0, 5 do
    C4:SetTimer(i * ms + 50, function()
      if i % 2 == 0 then sendColor(0, 65535, 65535, 3500, 0) else sendColor(43690, 65535, 65535, 3500, 0) end
    end, false)
  end
  C4:SetTimer(6 * ms + 200, function()
    sendColor(h, s, b, k, 0)
    sendPower(p, 0)
  end, false)
end

-- ---------------------------------------------------------------- connection + polling
local function deriveBroadcast()
  local configured = Properties["Broadcast Address"] or ""
  if configured ~= "" then return configured end
  local ok, ip = pcall(function() return C4:GetControllerNetworkAddress() end)
  if ok and type(ip) == "string" then
    local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if a then return string.format("%s.%s.%s.255", a, b, c) end  -- assumes /24
  end
  return "255.255.255.255"
end

local function connect()
  local bc = deriveBroadcast()
  dbg("broadcast address", bc)
  C4:CreateNetworkConnection(NET_BCAST, bc, "UDP")
  C4:NetConnect(NET_BCAST, PORT, "UDP")
  local ip = unicast()
  if ip then
    C4:CreateNetworkConnection(NET_BULB, ip, "UDP")
    C4:NetConnect(NET_BULB, PORT, "UDP")
  end
end

local function startPolling()
  if pollTimer then pollTimer:Cancel() end
  local secs = tonumber(Properties["Poll Seconds"]) or 15
  pollTimer = C4:SetTimer(secs * 1000, function()
    if bulbMac() or unicast() then
      sendGet()
      if not modelPid then sendVersion() end
    end
  end, true)
end

local function applyConfig()
  modelPid = nil
  connect()
  startPolling()
  if bulbMac() or unicast() then
    setStatus("Connecting...")
    sendGet()   -- with no MAC yet this is a tagged GetService that teaches us the MAC
  else
    setStatus("Not configured - run Discover Bulbs")
  end
end

-- ---------------------------------------------------------------- lifecycle / properties / actions
function OnDriverInit()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
end

function OnDriverLateInit()
  C4:SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = "true" })
  applyConfig()
  if not bulbMac() and not unicast() then
    C4:SetTimer(3000, function() DiscoverBulbs() end, false)
  end
end

function OnDriverDestroyed()
  if pollTimer then pollTimer:Cancel() end
end

function OnPropertyChanged(strProperty)
  local value = Properties[strProperty]
  if strProperty == "Select Bulb" then
    local mac = tostring(value):match("%((%x%x%x%x%x%x%x%x%x%x%x%x)%)")
    if mac then
      C4:UpdateProperty("Bulb MAC", mac)
    end
  elseif strProperty == "Bulb MAC" or strProperty == "Bulb IP"
      or strProperty == "Broadcast Address" or strProperty == "Poll Seconds" then
    applyConfig()
  end
end

function ExecuteCommand(strCommand, tParams)
  if strCommand == "LUA_ACTION" and tParams and tParams.ACTION then strCommand = tParams.ACTION end
  if strCommand == "DiscoverBulbs" then DiscoverBulbs()
  elseif strCommand == "IdentifyBulb" then IdentifyBulb() end
end
