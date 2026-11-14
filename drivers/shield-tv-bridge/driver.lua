-- Shield TV Bridge - Control4 DriverWorks driver (Lua 5.1)
-- Version 1.2.0
-- Controls an NVIDIA Shield TV through an HTTP/JSON bridge on a Linux host.
-- Presents one media_service primary proxy (5001: keys, power, HDMI output, Navigator
-- Now Playing) and an avswitch proxy (5002) with 25 app slots.

local DRIVER_VERSION = "1.2.0"

local PROXY_NOWPLAYING = 5001   -- media_service (primary): remote keys, power, AV output, Navigator Now Playing
local PROXY_SWITCH = 5002       -- avswitch: app slots
local PROXY_MEDIA = 5001        -- same proxy (no separate media_player proxy)
local VAR_CURRENT_SELECTED_DEVICE = 1000
local NP_REPUBLISH_MS = 10000
local INPUT_MIN = 3051
local INPUT_MAX = 3075
local FAIL_LIMIT = 3
local KEY_QUEUE_MAX = 50

-- A message is printed or logged when its level is at or below Log Level.
local LOG_ALERT, LOG_ERROR, LOG_WARN, LOG_INFO, LOG_TRACE, LOG_DEBUG = 0, 1, 2, 3, 4, 5

local KEY_MAP = {
  PLAY = "MEDIA_PLAY",
  PAUSE = "MEDIA_PAUSE",
  STOP = "MEDIA_PAUSE",
  SKIP_FWD = "MEDIA_NEXT",
  SKIP_REV = "MEDIA_PREVIOUS",
  SCAN_FWD = "MEDIA_FAST_FORWARD",
  SCAN_REV = "MEDIA_REWIND",
  UP = "DPAD_UP",
  DOWN = "DPAD_DOWN",
  LEFT = "DPAD_LEFT",
  RIGHT = "DPAD_RIGHT",
  ENTER = "DPAD_CENTER",
  HOME = "HOME",
  RECALL = "BACK",
}

-- Commands whose key comes from a user-chosen button property.
local BUTTON_PROPS = {
  CANCEL = "CANCEL Button",
  MENU = "MENU Button",
  INFO = "INFO Button",
}
local BUTTON_VALUES = { Home = "HOME", Back = "BACK", Menu = "MENU" }

-- Volume and mute belong to the room receiver, so they are ignored here.
local IGNORED_AUDIO = {
  START_VOL_UP = true, STOP_VOL_UP = true, PULSE_VOL_UP = true,
  START_VOL_DOWN = true, STOP_VOL_DOWN = true, PULSE_VOL_DOWN = true,
  MUTE_TOGGLE = true, MUTE_ON = true, MUTE_OFF = true,
}

local INPUT_COMMANDS = { SET_INPUT = true, SELECT_INPUT = true, SELECT_SOURCE = true, INPUT = true }

-- Runtime state
local logLevel = LOG_WARN
local logMode = "Off"
local pollTimer = nil
local keyTimer = nil
local keyCooling = false
local keyQueue = {}
local failCount = 0
local connectedSent = nil
local lastApp = nil
local lastNowKey = nil

-- ---------------------------------------------------------------- helpers

local function trim(s)
  local r = tostring(s or "")
  r = r:gsub("^%s+", "")
  r = r:gsub("%s+$", "")
  return r
end

local function prop(name)
  if type(Properties) ~= "table" then return "" end
  local v = Properties[name]
  if v == nil then return "" end
  return tostring(v)
end

local function clampInt(v, lo, hi, dflt)
  local n = tonumber(v)
  if not n then return dflt end
  n = math.floor(n)
  if n < lo then n = lo end
  if n > hi then n = hi end
  return n
end

local function logMsg(level, fmt, ...)
  if logMode == "Off" or level > logLevel then return end
  local okFmt, msg = pcall(string.format, fmt, ...)
  if not okFmt then msg = tostring(fmt) end
  msg = "[ShieldBridge] " .. msg
  if logMode == "Print" or logMode == "Print and Log" then
    print(msg)
  end
  if logMode == "Log" or logMode == "Print and Log" then
    pcall(function()
      if C4.DebugLog then
        C4:DebugLog(msg)
      else
        C4:ErrorLog(msg)
      end
    end)
  end
end

local function applyLogSettings()
  local digits = string.match(prop("Log Level"), "^%s*(%d+)")
  logLevel = tonumber(digits or "") or LOG_WARN
  local mode = trim(prop("Log Mode"))
  if mode == "" then mode = "Off" end
  logMode = mode
end

-- ---------------------------------------------------------------- JSON (flat, no library)

-- startPos is the index of the opening quote. Returns decoded text and the
-- index of the closing quote.
local function parseJsonString(s, startPos)
  local out = {}
  local i = startPos + 1
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "\\" then
      local nx = s:sub(i + 1, i + 1)
      if nx == "n" then
        out[#out + 1] = "\n"
      elseif nx == "t" then
        out[#out + 1] = "\t"
      elseif nx == "r" then
        out[#out + 1] = "\r"
      elseif nx == "u" then
        local code = tonumber(s:sub(i + 2, i + 5), 16)
        if code and code < 128 then
          out[#out + 1] = string.char(code)
        else
          out[#out + 1] = "?"
        end
        i = i + 4
      else
        out[#out + 1] = nx
      end
      i = i + 2
    elseif ch == '"' then
      return table.concat(out), i
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out), n
end

-- Returns the index of the first character of the value for a key, or nil.
local function findValueStart(s, key)
  if not s then return nil end
  local _, _, p = string.find(s, '"' .. key .. '"%s*:%s*()')
  return p
end

local function jsonString(s, key)
  local p = findValueStart(s, key)
  if not p or s:sub(p, p) ~= '"' then return nil end
  local v = parseJsonString(s, p)
  return v
end

local function jsonBool(s, key)
  local p = findValueStart(s, key)
  if not p then return nil end
  if s:sub(p, p + 3) == "true" then return true end
  if s:sub(p, p + 4) == "false" then return false end
  return nil
end

-- Returns the raw text of a nested object value, honouring quoted strings.
local function jsonObjectRaw(s, key)
  local p = findValueStart(s, key)
  if not p or s:sub(p, p) ~= "{" then return nil end
  local depth, i, n = 0, p, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' then
      local _, j = parseJsonString(s, i)
      i = j
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return s:sub(p, i) end
    end
    i = i + 1
  end
  return nil
end

-- Parses /v1/status. Top-level keys are read from the body with the
-- now_playing object removed, so "app" is never taken from the nested object.
local function parseStatus(body)
  local np = {}
  local top = body
  local nowRaw = jsonObjectRaw(body, "now_playing")
  if nowRaw then
    local a, b = string.find(body, nowRaw, 1, true)
    if a then
      top = body:sub(1, a - 1) .. body:sub(b + 1)
    end
    np = {
      app = jsonString(nowRaw, "app"),
      state = jsonString(nowRaw, "state"),
      title = jsonString(nowRaw, "title"),
      artist = jsonString(nowRaw, "artist"),
      album = jsonString(nowRaw, "album"),
    }
  end
  return {
    app = jsonString(top, "app"),
    art = jsonString(top, "art"),
    awake = jsonBool(top, "awake"),
    v2 = jsonBool(top, "v2_connected"),
    adb = jsonBool(top, "adb_connected"),
    np = np,
  }
end

-- ---------------------------------------------------------------- HTTP

local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function shieldName()
  return trim(prop("Shield Name"))
end

-- Builds base + path + ?query&shield=<name>.
local function bridgeUrl(path, query)
  local base = trim(prop("Bridge URL"))
  base = base:gsub("/+$", "")
  local q = "shield=" .. urlEncode(shieldName())
  if query and query ~= "" then
    q = query .. "&" .. q
  end
  return base .. path .. "?" .. q
end

local function authHeaders()
  return {
    ["Authorization"] = "Bearer " .. trim(prop("Bridge Token")),
    ["Accept"] = "application/json",
  }
end

local function httpGet(path, query, onDone)
  pcall(function() C4:urlSetTimeout(10) end)
  local url = bridgeUrl(path, query)
  local ok, err = pcall(function()
    C4:urlGet(url, authHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
      local okCb, cbErr = pcall(onDone or function() end, strData, responseCode, strError)
      if not okCb then logMsg(LOG_ERROR, "GET %s callback error: %s", path, tostring(cbErr)) end
    end)
  end)
  if not ok then logMsg(LOG_ERROR, "GET %s failed: %s", path, tostring(err)) end
end

local function httpPost(path, query, onDone)
  pcall(function() C4:urlSetTimeout(10) end)
  local url = bridgeUrl(path, query)
  local ok, err = pcall(function()
    C4:urlPost(url, "", authHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
      local okCb, cbErr = pcall(onDone or function() end, strData, responseCode, strError)
      if not okCb then logMsg(LOG_ERROR, "POST %s callback error: %s", path, tostring(cbErr)) end
      logMsg(LOG_TRACE, "POST %s -> %s", path, tostring(responseCode))
    end)
  end)
  if not ok then logMsg(LOG_ERROR, "POST %s failed: %s", path, tostring(err)) end
end

-- ---------------------------------------------------------------- status and Now Playing

local function setConnected(state)
  if connectedSent == state then return end
  connectedSent = state
  C4:UpdateProperty("Connected To Bridge", state and "true" or "false")
  C4:SendToProxy(PROXY_MEDIA, "ONLINE_CHANGED", { STATE = state })
  logMsg(LOG_INFO, "Bridge connection is now %s", state and "online" or "offline")
end

-- Returns the item to show: playing always, paused only when it belongs to the foreground app.
local function nowPlayingFor(st)
  local np = st.np or {}
  local show = false
  if np.state == "playing" then
    show = true
  elseif np.state == "paused" and np.app and np.app ~= "" and np.app == st.app then
    show = true
  end
  if not show then return nil end
  return {
    title = np.title or "",
    artist = np.artist or "",
    album = np.album or "",
    state = np.state or "",
  }
end

-- ---------------------------------------------------------------- Navigator Now Playing (media_service 5001)
-- Data comes from the bridge (ADB media session). No length or position is available,
-- so no progress is published. Queue, dashboard and media info follow the v8 test driver
-- that showed correctly in Navigator.

local npCurrent = nil        -- { title, artist, album, state, art } or nil when nothing to show

-- Cover art is served by the bridge at <Bridge URL>/art/<id>; mode picks plain or base64 URL.
local function artUrl(path)
  if not path or path == "" then return "" end
  local base = string.gsub(trim(prop("Bridge URL")), "/+$", "")
  local url = base .. path
  if prop("Cover Art Mode") == "Base64 URL" then
    return C4:Base64Encode(url)
  end
  return url
end
local npTimer = nil
local npSelected = false

local function xmlEsc(s)
  s = tostring(s or "")
  s = string.gsub(s, "&", "&amp;")
  s = string.gsub(s, "<", "&lt;")
  s = string.gsub(s, ">", "&gt;")
  return s
end

local function npEvent(name, evtargs)
  C4:SendToProxy(PROXY_NOWPLAYING, "SEND_EVENT", {
    NAVID = nil, ROOMS = nil, NAME = name, EVTARGS = evtargs, QUEUEID = 10100,
  }, "COMMAND")
end

local function npItemXml(title, subtitle, isHeader)
  return "<item><title>" .. xmlEsc(title) .. "</title><subtitle>" .. xmlEsc(subtitle)
    .. "</subtitle><duration></duration><isHeader>" .. (isHeader and "true" or "false")
    .. "</isHeader></item>"
end

local function npSendMediaInfo()
  local it = npCurrent or {}
  C4:SendToProxy(PROXY_NOWPLAYING, "UPDATE_MEDIA_INFO", {
    TITLE = it.title or "",
    ALBUM = it.album or "",
    ARTIST = it.artist or "",
    GENRE = "",
    IMAGEURL = artUrl(it.art),
  }, "COMMAND", true)
end

local function npSendQueue()
  local list = npItemXml("Now Playing", "", true)
  if npCurrent then
    local sub = npCurrent.artist or ""
    if sub == "" then sub = npCurrent.album or "" end
    local item = npItemXml(npCurrent.title or "", sub, false)
    local img = artUrl(npCurrent.art)
    if img ~= "" then
      local tag = '<image_list width="512" height="512">' .. xmlEsc(img) .. "</image_list></item>"
      item = string.gsub(item, "</item>$", function() return tag end)
    end
    list = list .. item
  end
  list = list .. npItemXml("Service", "", true)
  local tags = "<can_shuffle>false</can_shuffle><can_repeat>false</can_repeat>"
    .. "<shufflemode>false</shufflemode><repeatmode>false</repeatmode>"
  npEvent("QueueChanged", "<List>" .. list .. "</List><NowPlayingIndex>" .. (npCurrent and "1" or "0")
    .. "</NowPlayingIndex><NowPlaying>" .. tags .. "</NowPlaying>")
end

local function npSendDashboard()
  local playing = npCurrent and npCurrent.state == "playing"
  npEvent("DashboardChanged", "<Items>" .. (playing and "SkipRev Rew Pause Ff SkipFwd"
    or "SkipRev Rew Play Ff SkipFwd") .. "</Items>")
end

local function npSetVars()
  local state = "Not Playing"
  if npCurrent then
    state = (npCurrent.state == "playing") and "Playing" or "Paused"
  end
  pcall(function()
    C4:SetVariable("Play State", state)
    C4:SetVariable("Media Type", "")
    C4:SetVariable("Service", "")
  end)
end

local function npPublishAll()
  npSetVars()
  npSendMediaInfo()
  npSendQueue()
  npSendDashboard()
end

local function npStopTimer()
  if npTimer then
    pcall(function() npTimer:Cancel() end)
    npTimer = nil
  end
end

local function npStartTimer()
  npStopTimer()
  npTimer = C4:SetTimer(NP_REPUBLISH_MS, function()
    if npSelected then npPublishAll() end
  end, true)
end

local function npRoomSelectsMe(roomId)
  local ok, v = pcall(function()
    return C4:GetDeviceVariable(roomId, VAR_CURRENT_SELECTED_DEVICE)
  end)
  return ok and tonumber(v) ~= nil and tonumber(v) == tonumber(C4:GetDeviceID())
end

local npRoomIds = {}

local function npRefreshSelection()
  local any = false
  for _, id in ipairs(npRoomIds) do
    if npRoomSelectsMe(id) then any = true end
  end
  if any and not npSelected then
    npSelected = true
    npPublishAll()
    npStartTimer()
  elseif (not any) and npSelected then
    npSelected = false
    npStopTimer()
  end
end

local function npRegisterRooms()
  npRoomIds = {}
  local rooms = C4:GetDevicesByC4iName("roomdevice.c4i") or {}
  for k, v in pairs(rooms) do
    local id = tonumber(k) or tonumber(v)
    if id then table.insert(npRoomIds, id) end
  end
  for _, id in ipairs(npRoomIds) do
    C4:RegisterVariableListener(id, VAR_CURRENT_SELECTED_DEVICE)
  end
  npRefreshSelection()
end

function OnVariableChanged(idDevice, idVariable, strValue)
  if tonumber(idVariable) == VAR_CURRENT_SELECTED_DEVICE then
    npRefreshSelection()
  end
end

local function handleStatus(st)
  local app = st.app or ""
  if app ~= lastApp then
    lastApp = app
    C4:UpdateProperty("Current App", app)
  end

  local item = nowPlayingFor(st)
  local key = ""
  if item then
    key = item.title .. "|" .. item.artist .. "|" .. item.album .. "|" .. item.state .. "|" .. tostring(st.art or "")
  end
  if key == lastNowKey then return end
  lastNowKey = key

  local title, artist, album = "", "", ""
  if item then
    title, artist, album = item.title, item.artist, item.album
  end
  local display = ""
  if title ~= "" and artist ~= "" then
    display = title .. " - " .. artist
  elseif title ~= "" then
    display = title
  elseif artist ~= "" then
    display = artist
  end
  C4:UpdateProperty("Now Playing", display)
  if item then
    npCurrent = { title = title, artist = artist, album = album, state = item.state, art = st.art or "" }
  else
    npCurrent = nil
  end
  npPublishAll()
  logMsg(LOG_DEBUG, "Now playing: %s", display)
end

local function onStatusReply(strData, responseCode, strError)
  local code = tonumber(responseCode) or 0
  if code == 200 and strData and strData ~= "" then
    failCount = 0
    setConnected(true)
    handleStatus(parseStatus(strData))
  else
    failCount = failCount + 1
    logMsg(LOG_WARN, "Status poll failed (code %s, %s), failures=%d",
      tostring(responseCode), tostring(strError), failCount)
    if failCount >= FAIL_LIMIT then
      setConnected(false)
    end
  end
end

local function pollStatus()
  httpGet("/v1/status", nil, onStatusReply)
end

-- ---------------------------------------------------------------- timers

local function stopPolling()
  if pollTimer then
    pcall(function() pollTimer:Cancel() end)
    pollTimer = nil
  end
end

local function startPolling()
  stopPolling()
  local secs = clampInt(prop("Poll Seconds"), 2, 30, 3)
  pollTimer = C4:SetTimer(secs * 1000, function()
    local ok, err = pcall(pollStatus)
    if not ok then logMsg(LOG_ERROR, "Poll error: %s", tostring(err)) end
  end, true)
end

-- ---------------------------------------------------------------- key queue

local pumpKeys  -- forward declaration

local function scheduleCooldown()
  local ms = clampInt(prop("Command Delay Milliseconds"), 100, 1000, 150)
  keyCooling = true
  keyTimer = C4:SetTimer(ms, function()
    keyTimer = nil
    keyCooling = false
    local ok, err = pcall(pumpKeys)
    if not ok then logMsg(LOG_ERROR, "Key queue error: %s", tostring(err)) end
  end, false)
end

pumpKeys = function()
  if keyCooling then return end
  local keyName = table.remove(keyQueue, 1)
  if not keyName then return end
  logMsg(LOG_DEBUG, "Key %s", keyName)
  httpPost("/v1/key", "name=" .. keyName, nil)
  scheduleCooldown()
end

local function enqueueKey(keyName)
  if #keyQueue >= KEY_QUEUE_MAX then
    logMsg(LOG_WARN, "Key queue full, dropping %s", keyName)
    return
  end
  table.insert(keyQueue, keyName)
  pumpKeys()
end

-- ---------------------------------------------------------------- app switching

local function slotFromInput(v)
  local n = tonumber(v)
  if not n then return nil end
  n = math.floor(n)
  if n < INPUT_MIN or n > INPUT_MAX then return nil end
  return n - 3050
end

local function switchToInput(input, output)
  local slot = slotFromInput(input)
  if not slot then
    logMsg(LOG_WARN, "Input %s is not an app slot", tostring(input))
    return
  end
  local pkg = trim(prop("App " .. slot .. " Package"))
  if pkg == "" then
    logMsg(LOG_WARN, "App slot %d has no package set", slot)
    return
  end
  if not string.match(pkg, "^[%w_%.]+$") then
    logMsg(LOG_WARN, "App slot %d package has disallowed characters", slot)
    return
  end
  logMsg(LOG_INFO, "Launching app slot %d (%s)", slot, pkg)
  httpPost("/v1/launch", "package=" .. pkg, nil)
  C4:SendToProxy(PROXY_SWITCH, "INPUT_OUTPUT_CHANGED", { INPUT = input, OUTPUT = output })
end

local BUTTON_LABEL_KEY = BUTTON_VALUES

-- ---------------------------------------------------------------- proxy commands

function ReceivedFromProxy(idBinding, strCommand, tParams)
  local ok, err = pcall(function()
    tParams = tParams or {}
    local cmd = tostring(strCommand or "")

    if INPUT_COMMANDS[cmd] and tParams.INPUT ~= nil then
      switchToInput(tParams.INPUT, tParams.OUTPUT)
      return
    end

    -- Navigator Now Playing proxy (media_service, 5001)
    if idBinding == PROXY_NOWPLAYING then
      if cmd == "DEVICE_SELECTED" or cmd == "GetDashboard" or cmd == "GetQueue" then
        npPublishAll()
        if cmd == "DEVICE_SELECTED" then
          npSelected = true
          npStartTimer()
        end
        return ""
      elseif cmd == "DEVICE_DESELECTED" then
        npSelected = false
        npStopTimer()
        return
      elseif cmd == "OFF" then
        npSelected = false
        npStopTimer()   -- then falls through to the sleep command below
      elseif cmd == "ToggleShuffle" or cmd == "ToggleRepeat" or cmd == "NowPlayingCommand" then
        return
      end
      -- Dashboard buttons: ScanRev / ScanFwd use the Shield's rewind / fast-forward keys.
      if cmd == "ScanRev" then cmd = "SCAN_REV"
      elseif cmd == "ScanFwd" then cmd = "SCAN_FWD" end
    end

    if idBinding == PROXY_SWITCH then
      logMsg(LOG_DEBUG, "Switcher command %s not handled", cmd)
      return
    end

    if IGNORED_AUDIO[cmd] then
      logMsg(LOG_TRACE, "Ignoring audio command %s", cmd)
      return
    end

    if cmd == "ON" then
      httpPost("/v1/wake", nil, nil)
      return
    end
    if cmd == "OFF" then
      httpPost("/v1/sleep", nil, nil)
      return
    end

    local propName = BUTTON_PROPS[cmd]
    if propName then
      local keyName = BUTTON_LABEL_KEY[trim(prop(propName))]
      if keyName then
        enqueueKey(keyName)
      else
        logMsg(LOG_WARN, "No key mapped for %s (check %s)", cmd, propName)
      end
      return
    end

    local mapped = KEY_MAP[cmd]
    if mapped then
      enqueueKey(mapped)
      return
    end

    logMsg(LOG_DEBUG, "Unknown command %s on binding %s", cmd, tostring(idBinding))
  end)
  if not ok then
    logMsg(LOG_ERROR, "ReceivedFromProxy error: %s", tostring(err))
  end
end

-- ---------------------------------------------------------------- DriverWorks lifecycle

function OnDriverInit()
  pcall(function() C4:UpdateProperty("Driver Version", DRIVER_VERSION) end)
  applyLogSettings()
end

function OnDriverLateInit()
  local ok, err = pcall(function()
    applyLogSettings()
    C4:UpdateProperty("Connected To Bridge", "false")
    npSetVars()
    npRegisterRooms()
    startPolling()
    pollStatus()
  end)
  if not ok then logMsg(LOG_ERROR, "Late init error: %s", tostring(err)) end
end

function OnPropertyChanged(strProperty)
  local ok, err = pcall(function()
    if strProperty == "Log Level" or strProperty == "Log Mode" then
      applyLogSettings()
    elseif strProperty == "Poll Seconds" or strProperty == "Bridge URL"
        or strProperty == "Bridge Token" or strProperty == "Shield Name" then
      startPolling()
    end
  end)
  if not ok then logMsg(LOG_ERROR, "Property change error: %s", tostring(err)) end
end

function OnDriverDestroyed()
  stopPolling()
  npStopTimer()
  if keyTimer then
    pcall(function() keyTimer:Cancel() end)
    keyTimer = nil
  end
  keyQueue = {}
  keyCooling = false
end
