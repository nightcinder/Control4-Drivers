--[[
  SmartHQ Bridge (parent) for Control4 DriverWorks, OS 3.4.x
  Version: 0.3.0  (UNTESTED in Composer/Director; see docs/smarthq.md)

  Polls the LAN HTTP bridge on liesa (read-only, except the hood light write):
    GET  {base}/inventory                     every Poll Interval seconds, all appliances
    POST {base}/appliances/{hood id}/command  {"action":"light","level":"off|dim|on"}

  Child drivers bind to this driver in Composer Connections, connection "SmartHQ Bridge":
    SmartHQ Appliance  (one child per oven, beverage center, dishwasher, fridge, washer or dryer)
    SmartHQ Hood Light (one child for the hood light)

  Messages (C4:SendToDevice):
    from child: SH_REGISTER {CHILD_ID, APPLIANCE_ID, KIND}
                SH_HOOD_CMD {CHILD_ID, APPLIANCE_ID, LEVEL = off|dim|on}
    to child:   SH_STATUS {ONLINE, ACTIVE, STATE, DOOR, TEMP, FREEZER, SETPOINT, TIME, CYCLE, LIGHT, FAN, REMOTE, ALERT}
                SH_PARENT {REACHABLE}
                SH_HELLO {}  (sent at startup so children register again after a parent restart)
]]

local DRIVER_VERSION = "0.3.2"
local DEFAULT_HOST = "172.21.1.157"
local DEFAULT_PORT = "8789"
local DEFAULT_POLL_SECONDS = 60
local MIN_POLL_SECONDS = 30
local INFLIGHT_TIMEOUT_SECONDS = 30
local BRIDGE_BINDING = 1          -- connection id used by the child drivers
local EVENT_BRIDGE_UNREACHABLE = 1
local HOOD_LEVELS = { off = true, dim = true, on = true }

-- Machine states that mean "not running". Anything else counts as active. UNVERIFIED names.
local IDLE_STATES = {
  [""] = true, ["NA"] = true, ["NONE"] = true, ["OFF"] = true, ["IDLE"] = true,
  ["STATUS_OFF"] = true, ["STATUS_DASH"] = true, ["UNKNOWN"] = true,
}

local state = {
  pollTimer = nil,
  inflight = false,
  inflightSince = 0,
  reachable = nil,
  children = {},   -- [child device id] = { appliance = "D828...", kind = "oven" | "hood" | ... }
  latest = {},     -- [appliance id] = flat status table (all strings), built by flatten()
}

-- ============================================================================
-- Small helpers
-- ============================================================================
local function trim(s)
  if s == nil then return "" end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function prop(name)
  local v = nil
  pcall(function() v = Properties[name] end)
  return trim(v)
end

local function setProp(name, value)
  pcall(function() Properties[name] = tostring(value or "") end)
end

local function stamp()
  return os.date("%H:%M:%S")
end

local function logMsg(msg)
  local mode = prop("Log Mode")
  if mode == "Print" then print("SmartHQ " .. stamp() .. ": " .. tostring(msg))
  elseif mode == "Log" then pcall(function() C4:ErrorLog("SmartHQ: " .. tostring(msg)) end)
  end
end

local function setStatus(text)
  setProp("Status", text)
  logMsg(text)
end

local function fireEvent(id)
  logMsg("event " .. tostring(id))
  pcall(function() C4:FireEvent(id) end)
end

local function pollSeconds()
  local s = tonumber(prop("Poll Interval")) or DEFAULT_POLL_SECONDS
  if s < MIN_POLL_SECONDS then s = MIN_POLL_SECONDS end
  return s
end

local function baseUrl()
  local host = prop("Host")
  if host == "" then host = DEFAULT_HOST end
  local port = prop("Port")
  if port == "" then port = DEFAULT_PORT end
  return "http://" .. host .. ":" .. port
end

-- handler(data, code, err). code 0 means no response.
local function httpGet(path, handler)
  local url = baseUrl() .. path
  local function onReply(_, data, code, _, err)
    handler(data, tonumber(code) or 0, err)
  end
  local ok, perr = pcall(function()
    C4:urlGet(url, {}, false, onReply, {})
  end)
  if not ok then
    handler(nil, 0, tostring(perr))
  end
end

-- ============================================================================
-- Minimal JSON decoder (copied from the 0.2.x driver; no external library).
-- ============================================================================
-- ============================================================================
-- Minimal JSON decoder (no external library). Returns value, or nil + error.
-- JSON null is dropped (nil), so arrays are compacted.
-- ============================================================================
local function utf8Char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local ESCAPES = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }

function jsonDecode(str)
  local pos = 1
  local parseValue

  local function skipWs()
    pos = string.find(str, "[^ \t\r\n]", pos) or (#str + 1)
  end

  local function parseString()
    if string.sub(str, pos, pos) ~= '"' then error("expected string at " .. pos) end
    local out = {}
    pos = pos + 1
    while true do
      local s = string.find(str, '["\\]', pos)
      if not s then error("unterminated string") end
      out[#out + 1] = string.sub(str, pos, s - 1)
      if string.sub(str, s, s) == '"' then
        pos = s + 1
        break
      end
      local esc = string.sub(str, s + 1, s + 1)
      if esc == "u" then
        out[#out + 1] = utf8Char(tonumber(string.sub(str, s + 2, s + 5), 16) or 63)
        pos = s + 6
      else
        out[#out + 1] = ESCAPES[esc] or esc
        pos = s + 2
      end
    end
    return table.concat(out)
  end

  local function parseNumber()
    local s, e = string.find(str, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then error("bad number at " .. pos) end
    pos = e + 1
    return tonumber(string.sub(str, s, e))
  end

  parseValue = function()
    skipWs()
    local c = string.sub(str, pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      skipWs()
      if string.sub(str, pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skipWs()
        local key = parseString()
        skipWs()
        pos = pos + 1 -- colon
        obj[key] = parseValue()
        skipWs()
        local d = string.sub(str, pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then error("expected , or } at " .. pos) end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      skipWs()
      if string.sub(str, pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = parseValue()
        skipWs()
        local d = string.sub(str, pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then error("expected , or ] at " .. pos) end
      end
    elseif c == '"' then
      return parseString()
    elseif c == "t" then
      pos = pos + 4
      return true
    elseif c == "f" then
      pos = pos + 5
      return false
    elseif c == "n" then
      pos = pos + 4
      return nil
    end
    return parseNumber()
  end

  local ok, result = pcall(parseValue)
  if not ok then return nil, tostring(result) end
  return result
end


-- ============================================================================
-- Inventory -> flat status (one table per appliance, every value a string)
-- ============================================================================
-- Field names come from GET /inventory (raw ERD names). Only the ERDs listed here are read.
-- Decoded ERDs arrive as {decoded=..., raw=...}; plain ones arrive as bare values.

local function erdText(item, name)
  local v = (item.erds or {})[name]
  if v == nil then return "" end
  if type(v) == "table" then
    if v.decoded ~= nil then return tostring(v.decoded) end
    return ""
  end
  return tostring(v)
end

-- "FridgeSetPoints(fridge=39, freezer=37)" -> "39", "37"
local function fridgePair(item, name)
  local s = erdText(item, name)
  return s:match("fridge=(%-?%d+)") or "", s:match("freezer=(%-?%d+)") or ""
end

local function doorText(raw)
  local u = string.upper(raw or "")
  if u == "OPEN" then return "Open" end
  if u == "CLOSED" or u == "CLOSE" then return "Closed" end
  return raw or ""
end

local function isActive(s)
  return not IDLE_STATES[string.upper(s or "")]
end

local function flatten(item)
  local t = item.type or ""
  local f = {
    ONLINE = item.online and "true" or "false",
    ACTIVE = "false", STATE = "", DOOR = "", TEMP = "", FREEZER = "", SETPOINT = "",
    TIME = "", CYCLE = "", LIGHT = "", FAN = "", REMOTE = "", ALERT = "",
  }
  if t == "oven" then
    f.STATE = erdText(item, "UPPER_OVEN_CURRENT_STATE")
    f.ACTIVE = isActive(f.STATE) and "true" or "false"
    f.TEMP = erdText(item, "UPPER_OVEN_DISPLAY_TEMPERATURE")
    f.TIME = erdText(item, "UPPER_OVEN_COOK_TIME_REMAINING")
    f.CYCLE = erdText(item, "UPPER_OVEN_COOK_MODE")
    f.LIGHT = erdText(item, "UPPER_OVEN_LIGHT")
    f.REMOTE = erdText(item, "UPPER_OVEN_REMOTE_ENABLED")
  elseif t == "beverage_center" or t == "fridge" then
    local fridge, freezer = fridgePair(item, "CURRENT_TEMPERATURE")
    local setFridge = fridgePair(item, "TEMPERATURE_SETTING")
    f.TEMP = fridge
    f.FREEZER = freezer
    f.SETPOINT = setFridge
    f.DOOR = doorText(erdText(item, "DOOR_STATUS"))
    f.LIGHT = erdText(item, "INTERIOR_LIGHT")
    if t == "fridge" then f.ALERT = erdText(item, "ICE_MAKER_BUCKET_STATUS") end
  elseif t == "dishwasher" then
    f.STATE = erdText(item, "DISHWASHER_CYCLE_STATE")
    f.ACTIVE = isActive(erdText(item, "DISHWASHER_OPERATING_MODE")) and "true" or "false"
    f.DOOR = doorText(erdText(item, "DISHWASHER_DOOR_STATUS"))
    f.CYCLE = erdText(item, "DISHWASHER_CYCLE")
    f.TIME = erdText(item, "DISHWASHER_TIME_REMAINING")
  elseif t == "washer" or t == "dryer" then
    f.STATE = erdText(item, "LAUNDRY_MACHINE_STATE")
    f.ACTIVE = isActive(f.STATE) and "true" or "false"
    f.DOOR = doorText(erdText(item, "LAUNDRY_DOOR"))
    f.CYCLE = erdText(item, "LAUNDRY_CYCLE")
    f.TIME = erdText(item, "LAUNDRY_TIME_REMAINING")
    f.REMOTE = erdText(item, "LAUNDRY_REMOTE_STATUS")
    if t == "dryer" then
      f.TEMP = erdText(item, "LAUNDRY_DRYER_TEMPERATURENEW_OPTION")
      if erdText(item, "LAUNDRY_DRYER_BLOCKED_VENT_FAULT") == "true" then f.ALERT = "Blocked vent" end
    end
  elseif t == "hood" then
    f.STATE = erdText(item, "HOOD_LIGHT_LEVEL")
    f.LIGHT = f.STATE
    f.FAN = erdText(item, "HOOD_FAN_SPEED")
  end
  return f
end

-- Same keys as flatten() for the hood, built from the POST reply (/appliances/{id}/state fields).
local function hoodFlat(s)
  return {
    ONLINE = s.online and "true" or "false",
    ACTIVE = "false", DOOR = "", TEMP = "", FREEZER = "", SETPOINT = "", TIME = "",
    CYCLE = "", REMOTE = "", ALERT = "",
    STATE = tostring(s.light_level or ""),
    LIGHT = tostring(s.light_level or ""),
    FAN = tostring(s.fan_speed or ""),
  }
end

-- ============================================================================
-- Pushing status to children
-- ============================================================================
local function sendToChild(cid, cmd, params)
  pcall(function() C4:SendToDevice(cid, cmd, params or {}) end)
end

local function pushReachable(cid)
  sendToChild(cid, "SH_PARENT", { REACHABLE = state.reachable and "true" or "false" })
end

-- Sends the latest status for one registered child (or nothing if the appliance has no data yet).
local function pushTo(cid)
  local reg = state.children[cid]
  if not reg then return end
  pushReachable(cid)
  local flat = state.latest[reg.appliance]
  if flat then sendToChild(cid, "SH_STATUS", flat) end
end

local function pushAll()
  for cid in pairs(state.children) do pushTo(cid) end
end

local function setReachable(ok, text)
  if ok == false and state.reachable ~= false then
    fireEvent(EVENT_BRIDGE_UNREACHABLE)
  end
  state.reachable = ok
  setStatus(text)
  pushAll()
end

-- ============================================================================
-- Polling
-- ============================================================================
local function applyInventory(list)
  local count = 0
  for _, item in ipairs(list) do
    if type(item) == "table" and type(item.id) == "string" then
      state.latest[item.id] = flatten(item)
      count = count + 1
    end
  end
  pushAll()
  return count
end

local function poll()
  if state.inflight and os.time() - state.inflightSince < INFLIGHT_TIMEOUT_SECONDS then
    return
  end
  state.inflight = true
  state.inflightSince = os.time()
  httpGet("/inventory", function(data, code, err)
    state.inflight = false
    if code == 200 then
      local list = jsonDecode(data or "")
      if type(list) ~= "table" then
        setReachable(false, "Bridge reply was not JSON")
        return
      end
      local n = applyInventory(list)
      setReachable(true, "Connected, polled " .. stamp() .. ", " .. tostring(n) .. " appliances")
    else
      local why = "HTTP " .. tostring(code)
      if code == 0 then why = "no response: " .. tostring(err or "") end
      if code == 503 then
        local h = jsonDecode(data or "")
        if type(h) == "table" and h.last_error then
          why = why .. ", last_error: " .. tostring(h.last_error)
        end
      end
      setReachable(false, "Bridge not usable (" .. why .. ")")
    end
  end)
end

-- Defined after poll() so the timer closure can call it.
local function schedulePoll(seconds)
  if state.pollTimer then
    pcall(function() state.pollTimer:Cancel() end)
    state.pollTimer = nil
  end
  state.pollTimer = C4:SetTimer(math.floor(seconds * 1000), function()
    state.pollTimer = nil
    schedulePoll(pollSeconds())
    poll()
  end)
end

-- ============================================================================
-- Hood light write (the only write this driver makes). Reuses the 0.2.x logic.
-- ============================================================================
local function hoodCommand(replyCid, applianceId, level)
  if applianceId == "" then setStatus("Hood light: no appliance ID"); return end
  if not HOOD_LEVELS[level] then setStatus("Hood light: bad level " .. tostring(level)); return end
  local body = '{"action":"light","level":"' .. level .. '"}'
  local ok, perr = pcall(function()
    C4:urlPost(baseUrl() .. "/appliances/" .. applianceId .. "/command", body,
      { ["Content-Type"] = "application/json" }, false,
      function(_, data, code, _, err)
        local n = tonumber(code) or 0
        if n ~= 200 then
          setStatus("Hood light failed: HTTP " .. tostring(n) .. " " .. tostring(err or ""))
          return
        end
        local s = jsonDecode(data or "")
        if type(s) == "table" then
          state.latest[applianceId] = hoodFlat(s)
          pushAll()
        end
      end, {})
  end)
  if not ok then setStatus("Hood light failed: " .. tostring(perr)) end
end

-- ============================================================================
-- Child messages
-- ============================================================================
local function onRegister(tParams)
  local cid = tonumber(tParams.CHILD_ID or "")
  if not cid then return end
  local appId = trim(tParams.APPLIANCE_ID or "")
  if appId == "" then
    state.children[cid] = nil
    return
  end
  state.children[cid] = { appliance = appId, kind = trim(tParams.KIND or "") }
  pushTo(cid)
end

local function onHoodCommand(tParams)
  local cid = tonumber(tParams.CHILD_ID or "")
  local reg = cid and state.children[cid]
  if not reg or reg.kind ~= "hood" then
    logMsg("hood command from an unregistered child ignored")
    return
  end
  hoodCommand(cid, reg.appliance, trim(tParams.LEVEL or ""))
end

-- ============================================================================
-- Driver callbacks
-- ============================================================================
local function helloChildren()
  local ok, bound = pcall(function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), BRIDGE_BINDING) end)
  if ok and type(bound) == "table" then
    for id in pairs(bound) do
      local cid = tonumber(id)
      if cid then sendToChild(cid, "SH_HELLO", {}) end
    end
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "REFRESH_NOW" then
    poll()
  elseif strCommand == "SH_REGISTER" then
    onRegister(tParams)
  elseif strCommand == "SH_HOOD_CMD" then
    onHoodCommand(tParams)
  end
end

function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  setStatus("Starting")
end

function OnDriverLateInit()
  schedulePoll(1)
  -- Children may still be starting; ask them to register once the timer runs.
  pcall(function() C4:SetTimer(5000, function() helloChildren() end) end)
end

function OnDriverDestroyed()
  pcall(function() if state.pollTimer then state.pollTimer:Cancel() end end)
end

function OnPropertyChanged(name)
  if name == "Host" or name == "Port" then
    state.inflight = false
    schedulePoll(1)
  elseif name == "Poll Interval" then
    schedulePoll(pollSeconds())
  end
end
