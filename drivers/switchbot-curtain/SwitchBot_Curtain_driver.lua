--[[
  SwitchBot Curtain driver for Control4 (OS 3.4.x)
  Version: 1.0.4
  UNTESTED against a live Control4 system or live SwitchBot account.
  Only the crypto/JSON helpers are exercised offline (tests/test_signing.lua).

  One driver instance = one SwitchBot curtain/blind (Device ID property).
  Target API: https://api.switch-bot.com/v1.1
  Never log Token or Secret.
]]

local DRIVER_VERSION = "1.0.4"
local API_BASE = "https://api.switch-bot.com/v1.1"
local PROXY_BINDING = 5001
local SUPPORTED_TYPES = { ["Curtain"] = true, ["Curtain3"] = true, ["Blind Tilt"] = true }
local MIN_POLL_SECONDS = 60
local DEFAULT_POLL_SECONDS = 300
local POST_COMMAND_POLL_MS = 15000
local MAX_BACKOFF_SECONDS = 3600

-- ============================================================================
-- Crypto: pure Lua 5.1 (no bit library assumed). SHA-256, HMAC-SHA256, Base64.
-- Exposed as global SwitchBotCrypto so tests/test_signing.lua can exercise it.
-- ============================================================================
SwitchBotCrypto = {}
local SC = SwitchBotCrypto

local floor = math.floor
local TWO32 = 4294967296

local function bitop(a, b, fn)
  local r, p = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if fn(x, y) == 1 then r = r + p end
    a = floor(a / 2)
    b = floor(b / 2)
    p = p * 2
  end
  return r
end

local function bxor(a, b)
  return bitop(a, b, function(x, y) if x ~= y then return 1 else return 0 end end)
end

local function band(a, b)
  return bitop(a, b, function(x, y) if x == 1 and y == 1 then return 1 else return 0 end end)
end

local function rotr(x, n)
  local low = x % (2 ^ n)
  return floor(x / (2 ^ n)) + low * (2 ^ (32 - n))
end

local function shr(x, n)
  return floor(x / (2 ^ n))
end

local function add32(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return s % TWO32
end

local function not32(x)
  return (TWO32 - 1) - x
end

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function word_be(s, i)
  local a, b, c, d = string.byte(s, i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function be_bytes(w)
  local d = floor(w / 16777216) % 256
  local c = floor(w / 65536) % 256
  local b = floor(w / 256) % 256
  local a = w % 256
  return string.char(d, c, b, a)
end

-- Returns the raw 32-byte SHA-256 digest of msg.
function SC.sha256_raw(msg)
  local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  }
  local bitlen = #msg * 8
  local padded = msg .. "\128"
  while (#padded % 64) ~= 56 do padded = padded .. "\0" end
  local hi = floor(bitlen / TWO32)
  local lo = bitlen % TWO32
  padded = padded .. be_bytes(hi) .. be_bytes(lo)

  for chunk = 1, #padded, 64 do
    local w = {}
    for i = 0, 15 do w[i] = word_be(padded, chunk + i * 4) end
    for i = 16, 63 do
      local x = w[i - 15]
      local s0 = bxor(bxor(rotr(x, 7), rotr(x, 18)), shr(x, 3))
      local y = w[i - 2]
      local s1 = bxor(bxor(rotr(y, 17), rotr(y, 19)), shr(y, 10))
      w[i] = add32(w[i - 16], s0, w[i - 7], s1)
    end

    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for i = 0, 63 do
      local S1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
      local ch = bxor(band(e, f), band(not32(e), g))
      local temp1 = add32(h, S1, ch, K[i + 1], w[i])
      local S0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local temp2 = add32(S0, maj)
      h = g
      g = f
      f = e
      e = add32(d, temp1)
      d = c
      c = b
      b = a
      a = add32(temp1, temp2)
    end
    H[1] = add32(H[1], a); H[2] = add32(H[2], b)
    H[3] = add32(H[3], c); H[4] = add32(H[4], d)
    H[5] = add32(H[5], e); H[6] = add32(H[6], f)
    H[7] = add32(H[7], g); H[8] = add32(H[8], h)
  end

  local out = {}
  for i = 1, 8 do out[i] = be_bytes(H[i]) end
  return table.concat(out)
end

-- Returns the raw 32-byte HMAC-SHA256 of msg under key.
function SC.hmac_sha256_raw(key, msg)
  if #key > 64 then key = SC.sha256_raw(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local kb = string.byte(key, i)
    ipad[i] = string.char(bxor(kb, 0x36))
    opad[i] = string.char(bxor(kb, 0x5c))
  end
  local inner = SC.sha256_raw(table.concat(ipad) .. msg)
  return SC.sha256_raw(table.concat(opad) .. inner)
end

function SC.to_hex(raw)
  return (string.gsub(raw, ".", function(ch) return string.format("%02x", string.byte(ch)) end))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function SC.base64(data)
  local out = {}
  for i = 1, #data, 3 do
    local b1 = string.byte(data, i)
    local b2 = string.byte(data, i + 1)
    local b3 = string.byte(data, i + 2)
    local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
    local c1 = floor(n / 262144) % 64
    local c2 = floor(n / 4096) % 64
    local c3 = floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = string.sub(B64, c1 + 1, c1 + 1)
    out[#out + 1] = string.sub(B64, c2 + 1, c2 + 1)
    out[#out + 1] = b2 and string.sub(B64, c3 + 1, c3 + 1) or "="
    out[#out + 1] = b3 and string.sub(B64, c4 + 1, c4 + 1) or "="
  end
  return table.concat(out)
end

-- SwitchBot signature: base64(HMAC-SHA256(key = secret, msg = token .. t .. nonce)).
-- NOTE: the official Python/JS samples do NOT uppercase the base64 output, so we
-- don't either (the request spec said uppercase; see README "Open questions").
function SC.sign(token, secret, t, nonce)
  return SC.base64(SC.hmac_sha256_raw(secret, token .. t .. nonce))
end

-- ============================================================================
-- Minimal JSON decoder (Control4 has no guaranteed JSON library).
-- Errors are raised with error(); callers wrap in pcall.
-- ============================================================================
local JSON = {}
SC.JSON = JSON

function JSON.decode(str)
  local pos = 1
  local function perr(msg) error("json: " .. msg .. " at " .. pos, 0) end
  local function ws() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end

  local parseValue
  local function parseString()
    pos = pos + 1
    local buf = {}
    local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    while true do
      local c = str:sub(pos, pos)
      if c == "" then perr("unterminated string") end
      if c == '"' then
        pos = pos + 1
        break
      elseif c == "\\" then
        local e = str:sub(pos + 1, pos + 1)
        if e == "u" then
          local code = tonumber(str:sub(pos + 2, pos + 5), 16)
          if not code then perr("bad unicode escape") end
          buf[#buf + 1] = (code < 128) and string.char(code) or "?"
          pos = pos + 6
        else
          local r = escapes[e]
          if not r then perr("bad escape") end
          buf[#buf + 1] = r
          pos = pos + 2
        end
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(buf)
  end

  parseValue = function()
    ws()
    local c = str:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      ws()
      if str:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        ws()
        if str:sub(pos, pos) ~= '"' then perr("expected key") end
        local k = parseString()
        ws()
        if str:sub(pos, pos) ~= ":" then perr("expected colon") end
        pos = pos + 1
        obj[k] = parseValue()
        ws()
        local d = str:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then perr("expected , or }") end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr, n = {}, 0
      ws()
      if str:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        n = n + 1
        arr[n] = parseValue()
        ws()
        local d = str:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then perr("expected , or ]") end
      end
    elseif c == '"' then
      return parseString()
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      local num = str:match("^-?%d+%.?%d*[eE][-+]?%d+", pos) or str:match("^-?%d+%.?%d*", pos)
      if not num then perr("unexpected character") end
      pos = pos + #num
      return tonumber(num)
    end
  end

  local v = parseValue()
  ws()
  if pos <= #str then perr("trailing data") end
  return v
end

-- ============================================================================
-- Driver state and helpers
-- ============================================================================
local state = {
  failures = 0,        -- consecutive failed API calls, drives backoff
  busy = false,
  pollTimer = nil,
  lastLevel = nil,
}

local function prop(name)
  local ok, v = pcall(function() return Properties[name] end)
  if ok then return v end
  return nil
end

local function setProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value)) end)
end

local function setStatus(text)
  setProp("Status", text)
  pcall(function() print("[SwitchBot Curtain] " .. text) end)
end

-- Confirmed on a live Curtain (2026-11-04): with Invert Level False, Control4 100 = open matches
-- SwitchBot slidePosition 100 = open, so the default is False. Set True only if a curtain is reversed.
local function invertLevel()
  return (prop("Invert Level") or "False") == "True"
end

-- Control4 level (100 = open) <-> SwitchBot position (100 = open on the tested Curtain).
local function levelToPosition(level)
  if invertLevel() then return 100 - level end
  return level
end

local function positionToLevel(pos)
  if invertLevel() then return 100 - pos end
  return pos
end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function pollSeconds()
  local n = tonumber(prop("Poll Interval Seconds")) or DEFAULT_POLL_SECONDS
  if n < MIN_POLL_SECONDS then n = MIN_POLL_SECONDS end
  return n
end

local function randomNonce()
  return string.format("%08x%08x", math.random(0, 2147483647), math.random(0, 2147483647))
end

-- ============================================================================
-- HTTP. Single place to adapt if OS 3.4 callback signatures differ.
-- Callback signature assumed: (ticketId, strData, responseCode, tHeaders, strError)
-- ============================================================================
local function stamp()
  local ok, v = pcall(os.date, "%H:%M:%S")
  return ok and v or "--:--:--"
end

local function apiRequest(method, path, body, callback)
  local token, secret = prop("Token") or "", prop("Secret") or ""
  if token == "" or secret == "" then
    setStatus("Not configured: set Token and Secret")
    return
  end
  local t = tostring(floor(os.time() * 1000))
  local nonce = randomNonce()
  local headers = {
    Authorization = token,
    sign = SC.sign(token, secret, t, nonce),
    t = t,
    nonce = nonce,
    ["Content-Type"] = "application/json; charset=utf8",
  }
  local url = API_BASE .. path
  local function handler(_, strData, code, _, strError)
    print("SwitchBot " .. stamp() .. ": " .. method .. " " .. path .. " -> HTTP " .. tostring(code)
      .. (strError and (" error: " .. tostring(strError)) or "")
      .. " body: " .. string.sub(tostring(strData or ""), 1, 200))
    callback(code, strData, strError)
  end
  print("SwitchBot " .. stamp() .. ": " .. method .. " " .. path .. " sent")
  local ok, err = pcall(function()
    if method == "GET" then
      C4:urlGet(url, headers, false, handler)
    else
      C4:urlPost(url, body or "", headers, false, handler)
    end
  end)
  if not ok then
    callback(0, nil, tostring(err))
  end
end

-- ============================================================================
-- Status / backoff
-- ============================================================================
local schedulePoll

local function noteFailure(reason)
  state.failures = state.failures + 1
  setStatus(reason)
  schedulePoll(true)
end

local function noteSuccess()
  state.failures = 0
  setStatus("Online")
end

-- Chooses the next poll delay. Errors back off exponentially.
schedulePoll = function(afterError)
  if state.pollTimer then pcall(function() state.pollTimer:Cancel() end) end
  local delay = pollSeconds()
  if afterError and state.failures > 0 then
    delay = clamp(delay * (2 ^ clamp(state.failures, 1, 6)), MIN_POLL_SECONDS, MAX_BACKOFF_SECONDS)
  end
  local ok, timer = pcall(function()
    return C4:SetTimer(delay * 1000, function()
      state.pollTimer = nil
      SwitchBot_PollStatus()
      schedulePoll(false) -- re-arm the regular interval
    end)
  end)
  if ok then state.pollTimer = timer end
end

local function handleCommon(code, strData, strError, onOk)
  if code == 429 then
    return noteFailure("Rate limited")
  elseif code == 401 or code == 403 then
    return noteFailure("Auth failed")
  elseif not code or code == 0 then
    return noteFailure("Network error: " .. tostring(strError or "no response"))
  elseif code >= 500 then
    return noteFailure("Server error " .. tostring(code))
  end
  local ok, obj = pcall(JSON.decode, strData or "")
  if not ok or type(obj) ~= "table" then
    return noteFailure("Malformed response")
  end
  if obj.statusCode ~= 100 then
    if obj.statusCode == 401 or obj.statusCode == 402 then
      return noteFailure("Auth failed")
    end
    if obj.statusCode == 152 then
      return noteFailure("Device not found: check Device ID")
    end
    if obj.statusCode == 161 or obj.statusCode == 171 then
      return noteFailure("Device offline")
    end
    return noteFailure("API error " .. tostring(obj.statusCode))
  end
  noteSuccess()
  if onOk then onOk(obj) end
end

function SwitchBot_PollStatus()
  local id = prop("Device ID") or ""
  if id == "" then
    setStatus("Set Device ID (use Discover Devices)")
    return
  end
  apiRequest("GET", "/devices/" .. id .. "/status", nil, function(code, strData, strError)
    handleCommon(code, strData, strError, function(obj)
      local body = type(obj.body) == "table" and obj.body or {}
      if type(body.slidePosition) == "number" then
        local level = clamp(positionToLevel(body.slidePosition), 0, 100)
        state.lastLevel = level
        pcall(function() C4:SendToProxy(PROXY_BINDING, "LEVEL_CHANGED", { LEVEL = level, TARGET = level }) end)
      end
      if type(body.battery) == "number" then
        setProp("Battery", body.battery)
        local threshold = tonumber(prop("Low Battery Threshold")) or 20
        if body.battery < threshold then
          pcall(function() C4:FireEventByID(1) end)
        end
      end
    end)
  end)
end

-- Send a command to the device, then poll once shortly afterwards.
local function sendCommand(command, parameter)
  local id = prop("Device ID") or ""
  if id == "" then
    setStatus("Set Device ID (use Discover Devices)")
    return
  end
  local cmdType = "command"
  local body = '{"command":"' .. command .. '","parameter":"' .. (parameter or "default") ..
    '","commandType":"' .. cmdType .. '"}'
  apiRequest("POST", "/devices/" .. id .. "/commands", body, function(code, strData, strError)
    handleCommon(code, strData, strError, function() end)
    if state.failures == 0 then
      pcall(function() C4:SetTimer(POST_COMMAND_POLL_MS, function() SwitchBot_PollStatus() end) end)
    end
  end)
end

local function modeParam()
  local m = prop("Mode") or "ff"
  if m ~= "ff" and m ~= "0" and m ~= "1" then m = "ff" end
  return m
end

local function setLevel(level)
  level = clamp(math.floor(tonumber(level) or 0), 0, 100)
  state.lastLevel = level
  local pos = levelToPosition(level)
  sendCommand("setPosition", "0," .. modeParam() .. "," .. tostring(pos))
end

-- ============================================================================
-- Discovery
-- ============================================================================
local function discover()
  apiRequest("GET", "/devices", nil, function(code, strData, strError)
    handleCommon(code, strData, strError, function(obj)
      local body = type(obj.body) == "table" and obj.body or {}
      local list = type(body.deviceList) == "table" and body.deviceList or {}
      local lines = {}
      for _, d in ipairs(list) do
        if type(d) == "table" and SUPPORTED_TYPES[tostring(d.deviceType)] then
          lines[#lines + 1] = string.format("%s | %s | %s", tostring(d.deviceName), tostring(d.deviceId), tostring(d.deviceType))
        end
      end
      local text = #lines > 0 and table.concat(lines, "  ;  ") or "No curtain/blind devices found"
      setProp("Discovered Devices", text)
      pcall(function() print("[SwitchBot Curtain] Discovered devices (name | id | type):\n" .. text) end)
    end)
  end)
end

-- ============================================================================
-- Control4 entry points
-- ============================================================================
function OnDriverInit()
  pcall(function() math.randomseed(os.time()) end)
  setProp("Driver Version", DRIVER_VERSION)
  setStatus("Starting")
  if (prop("Token") or "") ~= "" then
    SwitchBot_PollStatus()
  end
  schedulePoll(false)
end

function OnPropertyChanged(strProperty)
  if strProperty == "Token" or strProperty == "Secret" or strProperty == "Device ID"
    or strProperty == "Poll Interval Seconds" then
    state.failures = 0
    SwitchBot_PollStatus()
    schedulePoll(false)
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  -- Composer dispatches <actions> as ExecuteCommand("LUA_ACTION", {ACTION = <command>}).
  if strCommand == "LUA_ACTION" then
    strCommand = tParams.ACTION
    if strCommand == nil then
      print("SwitchBot: LUA_ACTION with no ACTION parameter, ignoring")
      return
    end
  end
  print("SwitchBot " .. stamp() .. ": ExecuteCommand " .. tostring(strCommand))
  if strCommand == "ACTION_OPEN" then strCommand = "Open"
  elseif strCommand == "ACTION_CLOSE" then strCommand = "Close"
  elseif strCommand == "ACTION_REFRESH" then
    SwitchBot_PollStatus()
    return
  end
  if strCommand == "Discover Devices" or strCommand == "DISCOVER" then
    discover()
  elseif strCommand == "Open" or strCommand == "OPEN" then
    sendCommand("turnOn", "default")
  elseif strCommand == "Close" or strCommand == "CLOSE" then
    sendCommand("turnOff", "default")
  elseif strCommand == "Stop" or strCommand == "STOP" then
    sendCommand("pause", "default")
  elseif strCommand == "Set Position" or strCommand == "SET_POSITION" then
    setLevel(tParams.LEVEL or tParams.Level or tParams.level)
  end
end

-- Proxy (shade) commands from Composer, UI and programming.
function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "OPEN" then
    sendCommand("turnOn", "default")
  elseif strCommand == "CLOSE" then
    sendCommand("turnOff", "default")
  elseif strCommand == "STOP" then
    sendCommand("pause", "default")
  elseif strCommand == "SET_LEVEL_TARGET" then
    -- Blind proxy: LEVEL_TARGET carries 0-100, or an open/closed marker (unverified names).
    local t = tParams.LEVEL_TARGET
    if t == "LEVEL_TARGET_OPEN" then
      sendCommand("turnOn", "default")
    elseif t == "LEVEL_TARGET_CLOSED" then
      sendCommand("turnOff", "default")
    else
      setLevel(t)
    end
  elseif strCommand == "TOGGLE" then
    if (state.lastLevel or 0) > 0 then
      sendCommand("turnOff", "default")
    else
      sendCommand("turnOn", "default")
    end
  elseif strCommand == "SET_LEVEL" then
    setLevel(tParams.LEVEL)
  end
end
