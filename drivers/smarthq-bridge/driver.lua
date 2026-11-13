--[[
  SmartHQ Bridge (parent) for Control4 DriverWorks, OS 3.4.x
  Version: 0.3.6  (UNTESTED in Composer/Director; see docs/smarthq.md)

  0.3.6: creates missing child devices at runtime (C4:AddDevice) after each good /inventory
    poll, binds them to this driver, and sends them SH_CONFIGURE. Property "Auto Create Children"
    (On/Off, default On). Action "Discover Children" runs the same step once. Nothing is deleted.

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
                SH_CONFIGURE {APPLIANCE_ID, APPLIANCE_TYPE}  (sent once to a child this driver created)
]]

local DRIVER_VERSION = "0.3.6"
local DEFAULT_HOST = "172.21.1.157"
local DEFAULT_PORT = "8789"
local DEFAULT_POLL_SECONDS = 60
local MIN_POLL_SECONDS = 30
local INFLIGHT_TIMEOUT_SECONDS = 30
local BRIDGE_BINDING = 1          -- connection id used by the child drivers
local EVENT_BRIDGE_UNREACHABLE = 1
local HOOD_LEVELS = { off = true, dim = true, on = true }

-- Auto-create (0.3.6). Driver filenames must match the .c4z packages Composer has installed.
local CHILD_DRIVER_BY_KIND = {
  oven = "smarthq-appliance.c4z",
  beverage_center = "smarthq-appliance.c4z",
  dishwasher = "smarthq-appliance.c4z",
  fridge = "smarthq-appliance.c4z",
  washer = "smarthq-appliance.c4z",
  dryer = "smarthq-appliance.c4z",
  hood = "smarthq-hood-light.c4z",
}
local APPLIANCE_TYPE_NAME = {
  oven = "Oven", beverage_center = "Beverage Center", dishwasher = "Dishwasher",
  fridge = "Refrigerator", washer = "Washer", dryer = "Dryer",
}
local CHILD_BINDING_CLASS = "SMARTHQ_BRIDGE"  -- connection class on both sides (parent id 1, child id 1)
local AUTO_CREATE_GRACE_SECONDS = 60          -- after startup, let hand-added children register first
local PENDING_CREATE_SECONDS = 120            -- an AddDevice that never calls back is retried after this
local CONFIGURE_DELAY_MS = 10000              -- wait after Bind before sending SH_CONFIGURE
local pendingCreates = {}                     -- [appliance id] = os.time() while AddDevice is in flight
local startedAt = 0

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
  pcall(function() C4:UpdateProperty(name, tostring(value or "")) end)
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

-- ============================================================================
-- Auto-create child devices (0.3.6)
-- Runs after each good /inventory poll. Creates one child per appliance that has
-- no child yet. "Has a child" = a registered child with that Appliance ID, or an
-- AddDevice still in flight. Never deletes anything.
-- ============================================================================
local function boundChildren()
  local ok, bound = pcall(function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), BRIDGE_BINDING) end)
  if not ok or type(bound) ~= "table" then return nil end
  return bound
end

local function childKnownFor(appId)
  local t = pendingCreates[appId]
  if t and os.time() - t < PENDING_CREATE_SECONDS then return true end
  for _, reg in pairs(state.children) do
    if reg.appliance == appId then return true end
  end
  return false
end

local function createChild(item, kind, driverFile)
  local appId = item.id
  local label = trim(item.nickname or item.name or "")
  if label == "" then label = (APPLIANCE_TYPE_NAME[kind] or kind) .. " " .. appId:sub(-4) end
  local name = "SmartHQ " .. label
  local roomId = nil
  pcall(function() roomId = C4:RoomGetId() end)
  roomId = tonumber(roomId)
  if not roomId or roomId == 0 then
    logMsg("auto-create skipped for " .. appId .. ": no room id from C4:RoomGetId()")
    return
  end
  pendingCreates[appId] = os.time()
  local ok, err = pcall(function()
    C4:AddDevice(driverFile, roomId, name, function(newId)
      pendingCreates[appId] = nil
      local id = tonumber(newId)
      if not id or id == 0 then
        logMsg("auto-create failed for " .. appId .. " (" .. driverFile .. "): AddDevice returned 0")
        return
      end
      C4:Bind(C4:GetDeviceID(), BRIDGE_BINDING, id, BRIDGE_BINDING, CHILD_BINDING_CLASS)
      logMsg("auto-created " .. driverFile .. " id " .. tostring(id) .. " for appliance " .. appId)
      C4:SetTimer(CONFIGURE_DELAY_MS, function()
        sendToChild(id, "SH_CONFIGURE", { APPLIANCE_ID = appId, APPLIANCE_TYPE = APPLIANCE_TYPE_NAME[kind] or "" })
      end)
    end)
  end)
  if not ok then
    pendingCreates[appId] = nil
    logMsg("auto-create error for " .. appId .. ": " .. tostring(err))
  end
end

local function autoCreateChildren(list, manual)
  if not manual and prop("Auto Create Children") == "Off" then return end
  if os.time() - startedAt < AUTO_CREATE_GRACE_SECONDS then return end
  local bound = boundChildren()
  if not bound then return end

  -- Forget registrations whose child is no longer bound (owner deleted it), so a
  -- missing child is created again while Auto Create is On.
  local live, liveCount = {}, 0
  for k in pairs(bound) do
    local n = tonumber(k)
    if n then live[n] = true; liveCount = liveCount + 1 end
  end
  local registered = 0
  for cid in pairs(state.children) do
    if not live[cid] then
      state.children[cid] = nil
      logMsg("child " .. tostring(cid) .. " is no longer bound; forgotten")
    else
      registered = registered + 1
    end
  end
  -- A bound child that has not registered yet might be the appliance we are about to create.
  -- Wait for it, so a hand-added child is never duplicated.
  if liveCount > registered then
    logMsg("auto-create waiting: " .. tostring(liveCount - registered) .. " bound child(ren) not registered yet")
    return
  end

  for _, item in ipairs(list) do
    if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
      local kind = trim(item.type or "")
      local driverFile = CHILD_DRIVER_BY_KIND[kind]
      if driverFile and not childKnownFor(item.id) then
        createChild(item, kind, driverFile)
      end
    end
  end
end

local function poll()
  if state.inflight and os.time() - state.inflightSince < INFLIGHT_TIMEOUT_SECONDS then
    return
  end
  state.inflight = true
  state.inflightSince = os.time()
  local manual = state.manualDiscover
  state.manualDiscover = false
  httpGet("/inventory", function(data, code, err)
    state.inflight = false
    if code == 200 then
      local list = jsonDecode(data or "")
      if type(list) ~= "table" then
        setReachable(false, "Bridge reply was not JSON")
        return
      end
      local n = applyInventory(list)
      local okCreate, errCreate = pcall(autoCreateChildren, list, manual)
      if not okCreate then logMsg("auto-create error: " .. tostring(errCreate)) end
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
-- Manual action: list every appliance from GET /inventory so IDs can be copied.
-- Writes "id | type | nickname" entries to the read-only "Appliance List" property
-- and logs each one (logs only show when Log Mode is Print or Log).
local function listAppliances()
  setProp("Appliance List", "Fetching")
  httpGet("/inventory", function(data, code, err)
    if code ~= 200 then
      setProp("Appliance List", "Failed: HTTP " .. tostring(code))
      logMsg("list appliances failed: HTTP " .. tostring(code) .. " " .. tostring(err or ""))
      return
    end
    local list = jsonDecode(data or "")
    if type(list) ~= "table" then
      setProp("Appliance List", "Failed: reply was not JSON")
      logMsg("list appliances failed: reply was not JSON")
      return
    end
    local entries = {}
    for _, item in ipairs(list) do
      if type(item) == "table" and type(item.id) == "string" then
        local line = item.id .. " | " .. tostring(item.type or "?") .. " | " .. tostring(item.nickname or item.name or "")
        table.insert(entries, line)
        logMsg("appliance " .. line)
      end
    end
    setProp("Appliance List", #entries > 0 and table.concat(entries, " ; ") or "No appliances")
    logMsg("listed " .. tostring(#entries) .. " appliance(s) at " .. stamp())
  end)
end

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
  if strCommand == "LUA_ACTION" then strCommand = tParams.ACTION end
  logMsg("command " .. tostring(strCommand))
  if strCommand == "REFRESH_NOW" then
    poll()
  elseif strCommand == "LIST_APPLIANCES" then
    listAppliances()
  elseif strCommand == "DISCOVER_CHILDREN" then
    -- Manual: runs the create step even when Auto Create Children is Off.
    state.manualDiscover = true
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
  startedAt = os.time()
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
