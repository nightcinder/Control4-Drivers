-- Shield TV Bridge - Control4 DriverWorks driver (Lua 5.1)
-- Version 1.5.1
-- Controls an NVIDIA Shield TV through an HTTP/JSON bridge on a Linux host.
-- Presents one media_service primary proxy (5001: keys, power, HDMI output, Navigator
-- Now Playing), an avswitch proxy (5002) with 25 mini app slots (3051-3075), and a uibutton
-- proxy (5003, "Shield Remote") that opens the phone remote web page www/remote1.html.
-- The App N Package properties are fallbacks, used only when no mini app is bound to the slot.

local DRIVER_VERSION = "1.5.2"

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
local lastAwake = nil
local lastNowKey = nil
local publishRemoteState   -- forward declaration (Shield Remote page, defined below)
local fetchInlineArt       -- forward declaration
local publishArt           -- forward declaration (sets the UI_ART variable)
-- Art diagnostics the Shield Remote page reports back (shown in Web Page Status).
local UI_ART_STATUS = {
  UI_ART_OK = "art shown",
  UI_ART_ERR = "art failed to load",
  UI_ART_NONE = "no art received",
}
local artInline = { key = "", data = "" }   -- art path and its data: URI for the Shield Remote page
local roomMuted = nil      -- room mute state for the page (nil = unknown)
local roomVolume = nil

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

-- Code point to UTF-8 bytes (Lua 5.1 has no utf8 library). Bad or lone surrogate codes give "?".
local function utf8char(code)
  if not code or code < 0 or (code >= 0xD800 and code <= 0xDFFF) or code > 0x10FFFF then return "?" end
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

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
        -- \uXXXX to UTF-8 (surrogate pairs joined); 1.5.0: was "?" for anything non-ASCII.
        local code = tonumber(s:sub(i + 2, i + 5), 16)
        if code and code >= 0xD800 and code <= 0xDBFF and s:sub(i + 6, i + 7) == "\\u" then
          local lo = tonumber(s:sub(i + 8, i + 11), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = utf8char(code)
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
  if base == "" then return nil end
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
  local url = bridgeUrl(path, query)
  if not url then
    logMsg(LOG_WARN, "Bridge URL is not set")
    pcall(onDone or function() end, nil, 0, "Bridge URL is not set")
    return
  end
  pcall(function() C4:urlSetTimeout(10) end)
  local ok, err = pcall(function()
    C4:urlGet(url, authHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
      local okCb, cbErr = pcall(onDone or function() end, strData, responseCode, strError)
      if not okCb then logMsg(LOG_ERROR, "GET %s callback error: %s", path, tostring(cbErr)) end
    end)
  end)
  if not ok then logMsg(LOG_ERROR, "GET %s failed: %s", path, tostring(err)) end
end

local function httpPost(path, query, onDone)
  local url = bridgeUrl(path, query)
  if not url then
    logMsg(LOG_WARN, "Bridge URL is not set")
    pcall(onDone or function() end, nil, 0, "Bridge URL is not set")
    return
  end
  pcall(function() C4:urlSetTimeout(10) end)
  local ok, err = pcall(function()
    C4:urlPost(url, "", authHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
      local okCb, cbErr = pcall(onDone or function() end, strData, responseCode, strError)
      if not okCb then logMsg(LOG_ERROR, "POST %s callback error: %s", path, tostring(cbErr)) end
      logMsg(LOG_TRACE, "POST %s -> %s", path, tostring(responseCode))
    end)
  end)
  if not ok then logMsg(LOG_ERROR, "POST %s failed: %s", path, tostring(err)) end
end

-- Fills the Shield Name drop-down from the bridge (GET /v1/shields). Bridges older than
-- 0.4.0 answer 404, in which case the list from driver.xml stays as it is.
local function refreshShieldList()
  local base = trim(prop("Bridge URL")):gsub("/+$", "")
  if base == "" then return end
  pcall(function() C4:urlSetTimeout(10) end)
  local ok, err = pcall(function()
    C4:urlGet(base .. "/v1/shields", authHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
      pcall(function()
        if tonumber(responseCode) ~= 200 or not strData then
          logMsg(LOG_WARN, "Shield list unavailable (code %s)", tostring(responseCode))
          return
        end
        local arr = strData:match('"shields"%s*:%s*%[(.-)%]') or ""
        local names = {}
        for n in arr:gmatch('"(.-)"') do names[#names + 1] = n end
        if #names == 0 then return end
        local cur, pick = shieldName(), names[1]
        for _, n in ipairs(names) do
          if n == cur then pick = cur break end
        end
        C4:UpdatePropertyList("Shield Name", table.concat(names, ","), pick)
        logMsg(LOG_INFO, "Shield list from bridge: %s (selected %s)", table.concat(names, ", "), pick)
      end)
    end)
  end)
  if not ok then logMsg(LOG_ERROR, "Shield list request failed: %s", tostring(err)) end
end

-- ---------------------------------------------------------------- status and Now Playing

local function setConnected(state)
  if connectedSent == state then return end
  connectedSent = state
  C4:UpdateProperty("Connected To Bridge", state and "true" or "false")
  C4:SendToProxy(PROXY_MEDIA, "ONLINE_CHANGED", { STATE = state })
  logMsg(LOG_INFO, "Bridge connection is now %s", state and "online" or "offline")
end

local APP_LABELS = {
  ["com.plexapp.android"] = "Plex",
  ["com.google.android.youtube.tv"] = "YouTube",
  ["com.google.android.youtube.tvkids"] = "YouTube Kids",
  ["com.google.android.youtube.tvunplugged"] = "YouTube TV",
  ["com.netflix.ninja"] = "Netflix",
  ["com.disney.disneyplus"] = "Disney+",
  ["com.amazon.amazonvideo.livingroom"] = "Prime Video",
  ["com.hulu.livingroomplus"] = "Hulu",
  ["com.wbd.stream"] = "Max",
  ["com.hbo.hbonow"] = "Max",
  ["com.apple.atve.androidtv.appletv"] = "Apple TV",
  ["com.spotify.tv.android"] = "Spotify",
  ["org.jellyfin.androidtv"] = "Jellyfin",
  ["org.xbmc.kodi"] = "Kodi",
  ["tv.twitch.android.app"] = "Twitch",
  ["com.cbs.ott"] = "Paramount+",
  ["com.peacocktv.peacockandroid"] = "Peacock",
  ["com.fubo.firetv.screen"] = "Fubo",
  ["com.crunchyroll.crunchyroid"] = "Crunchyroll",
  ["com.aspiro.tidal"] = "TIDAL",
  ["com.google.android.tvlauncher"] = "SHIELD Home",
  ["com.google.android.leanbacklauncher"] = "SHIELD Home",
  ["com.android.tv.settings"] = "Settings",
}

local function appLabel(pkg)
  if not pkg or pkg == "" then return "" end
  if APP_LABELS[pkg] then return APP_LABELS[pkg] end
  local tail = string.match(pkg, "([^%.]+)$") or pkg
  if tail == "android" or tail == "livingroom" or tail == "tv" then
    local prev = string.match(pkg, "([^%.]+)%.[^%.]+$")
    if prev and prev ~= "com" and prev ~= "org" and prev ~= "tv" then
      tail = prev
    end
  end
  return (tail:gsub("^%l", string.upper))
end

-- Returns the item to show: playing/paused media when titled, or the foreground app when awake.
local function nowPlayingFor(st)
  if st.awake == false then return nil end
  local np = st.np or {}
  local npTitle = np.title or ""
  local show = false
  if np.state == "playing" and npTitle ~= "" then
    show = true
  elseif np.state == "paused" and npTitle ~= "" and np.app and np.app ~= "" and np.app == st.app then
    show = true
  end
  if show then
    local npApp = (np.app and np.app ~= "") and np.app or (st.app or "")
    local artist = np.artist or ""
    if artist == "" then artist = appLabel(npApp) end
    return {
      title = npTitle,
      artist = artist,
      album = np.album or "",
      state = np.state or "",
    }
  end
  if st.awake == true and st.app and st.app ~= "" then
    return {
      title = appLabel(st.app),
      artist = "SHIELD TV",
      album = "",
      state = "paused",
    }
  end
  return nil
end

-- ---------------------------------------------------------------- Navigator Now Playing (media_service 5001)
-- Data comes from the bridge (ADB media session). No length or position is available,
-- so no progress is published. Queue, dashboard and media info follow the v8 test driver
-- that showed correctly in Navigator.

local npCurrent = nil        -- { title, artist, album, state, art } or nil when nothing to show

-- Cover art is served by the bridge at <Bridge URL>/art/<id>; mode picks plain or base64 URL.
local function artUrl(path, plain)
  if not path or path == "" then return "" end
  local base = string.gsub(trim(prop("Bridge URL")), "/+$", "")
  if base == "" then return "" end
  local url = base .. path
  if not plain and prop("Cover Art Mode") ~= "Plain URL" then
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
    local img = artUrl(npCurrent.art, true)
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
  if publishRemoteState then publishRemoteState(false) end
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
    if npSelected or npCurrent ~= nil then npPublishAll() end
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
  lastAwake = st.awake
  if st.awake == false then
    npSelected = false
  end
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
  if key == lastNowKey then
    if st.awake == false and not npCurrent and not npSelected then
      npStopTimer()
    end
    return
  end
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
  if npCurrent and not npTimer then
    npStartTimer()
  elseif not npCurrent and not npSelected then
    npStopTimer()
  end
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

-- Mini app variables checked in order; the first valid value wins.
local MINIAPP_VARS = { "UM_NV_SHIELD", "UM_SUNBRITE_TV", "UM_AMAZON" }

-- Returns a trimmed package name that is safe to put in a launch url, or nil.
local function safePackage(s)
  if type(s) ~= "string" then return nil end
  local p = trim(s)
  if p == "" then return nil end
  if not string.match(p, "^[%w_%.]+$") then return nil end
  return p
end

-- vars is { [id] = { name = ..., value = ... } } or a plain { NAME = "value" } map.
local function miniAppPackage(vars)
  if type(vars) ~= "table" then return nil end
  local byName = {}
  for k, v in pairs(vars) do
    if type(v) == "table" then
      if type(v.name) == "string" then byName[v.name] = v.value end
    elseif type(k) == "string" then
      byName[k] = v
    end
  end
  for _, name in ipairs(MINIAPP_VARS) do
    local pkg = safePackage(byName[name])
    if pkg then return pkg end
  end
  return nil
end

-- Device id of the mini app bound to this input, or nil.
local function boundMiniApp(input)
  local n = tonumber(input)
  if not n then return nil end
  local ok, dev = pcall(function() return C4:GetBoundProviderDevice(C4:GetDeviceID(), n) end)
  if not ok or dev == nil or dev == 0 or dev == "" then return nil end
  return dev
end

-- Package to launch for an input, and where it came from ("miniapp", "property" or nil).
local function packageForInput(input)
  local slot = slotFromInput(input)
  if not slot then return nil, nil end
  local dev = boundMiniApp(input)
  if dev then
    local ok, vars = pcall(function() return C4:GetDeviceVariables(dev) end)
    if ok then
      local pkg = miniAppPackage(vars)
      if pkg then return pkg, "miniapp" end
    end
  end
  local raw = trim(prop("App " .. slot .. " Package"))
  if raw == "" then return nil, nil end
  local pkg = safePackage(raw)
  if not pkg then
    logMsg(LOG_WARN, "App slot %d package has disallowed characters", slot)
    return nil, nil
  end
  return pkg, "property"
end

-- Writes "Bound Apps": each MiniApp slot with a usable mini app value, or "none".
local function refreshBoundApps()
  local parts = {}
  for slot = 1, 25 do
    local dev = boundMiniApp(3050 + slot)
    if dev then
      local ok, vars = pcall(function() return C4:GetDeviceVariables(dev) end)
      local pkg = ok and miniAppPackage(vars) or nil
      if pkg then parts[#parts + 1] = "MiniApp " .. slot .. "=" .. pkg end
    end
  end
  local text = (#parts > 0) and table.concat(parts, "; ") or "none"
  pcall(function() C4:UpdateProperty("Bound Apps", text) end)
end

local function switchToInput(input, output)
  local slot = slotFromInput(input)
  if not slot then
    logMsg(LOG_WARN, "Input %s is not an app slot", tostring(input))
    return
  end
  local pkg, source = packageForInput(input)
  if not pkg then
    logMsg(LOG_WARN, "App slot %d has no package set", slot)
    return
  end
  logMsg(LOG_INFO, "Launching app slot %d (%s, from %s)", slot, pkg, source)
  if lastAwake == false then
    httpPost("/v1/wake", nil, nil)
  end
  httpPost("/v1/launch", "package=" .. pkg, nil)
  C4:SendToProxy(PROXY_SWITCH, "INPUT_OUTPUT_CHANGED", { INPUT = input, OUTPUT = output })
end

local BUTTON_LABEL_KEY = BUTTON_VALUES

-- ---------------------------------------------------------------- Navigator UI (Tabs & Screens)

local function xmlUnesc(s)
  s = tostring(s or "")
  s = string.gsub(s, "&quot;", '"')
  s = string.gsub(s, "&apos;", "'")
  s = string.gsub(s, "&lt;", "<")
  s = string.gsub(s, "&gt;", ">")
  s = string.gsub(s, "&amp;", "&")
  return s
end

local function parseNavArgs(tParams)
  local args = {}
  local raw = tParams and tParams.ARGS
  if type(raw) ~= "string" or raw == "" then return args end
  if C4 and C4.ParseXml then
    local ok, parsed = pcall(function() return C4:ParseXml(raw) end)
    if ok and type(parsed) == "table" and type(parsed.ChildNodes) == "table" then
      for _, node in pairs(parsed.ChildNodes) do
        if node.Attributes and node.Attributes.name then
          args[node.Attributes.name] = node.Value or ""
        end
      end
      return args
    end
  end
  for k, v in string.gmatch(raw, '<arg%s+name=["\']([^"\']+)["\'][^>]*>(.-)</arg>') do
    args[k] = xmlUnesc(v)
  end
  return args
end

local function sendNavData(tParams, data)
  if tParams and tParams.NAVID and tParams.SEQ then
    C4:SendToProxy(PROXY_NOWPLAYING, "DATA_RECEIVED", {
      NAVID = tParams.NAVID,
      SEQ = tParams.SEQ,
      DATA = data or "",
    })
  end
end

local function navListItemXml(id, title, subtitle, isHeader, actionId)
  local out = { "<item>" }
  if id and id ~= "" then
    out[#out + 1] = "<id>" .. xmlEsc(id) .. "</id>"
  end
  out[#out + 1] = "<title>" .. xmlEsc(title or "") .. "</title>"
  if subtitle and subtitle ~= "" then
    out[#out + 1] = "<subtitle>" .. xmlEsc(subtitle) .. "</subtitle>"
  end
  if isHeader then
    out[#out + 1] = "<isHeader>true</isHeader>"
  elseif actionId and actionId ~= "" then
    out[#out + 1] = "<default_action>" .. xmlEsc(actionId) .. "</default_action>"
    out[#out + 1] = "<actions_list>" .. xmlEsc(actionId) .. "</actions_list>"
  end
  out[#out + 1] = "</item>"
  return table.concat(out)
end

local REMOTE_UI_ITEMS = {
  { header = true, title = "Navigation" },
  { id = "DPAD_CENTER", title = "Select (OK)" },
  { id = "DPAD_UP", title = "Up" },
  { id = "DPAD_DOWN", title = "Down" },
  { id = "DPAD_LEFT", title = "Left" },
  { id = "DPAD_RIGHT", title = "Right" },
  { id = "HOME", title = "Home" },
  { id = "BACK", title = "Back" },
  { id = "MENU", title = "Menu" },
  { header = true, title = "Playback" },
  { id = "MEDIA_PLAY", title = "Play" },
  { id = "MEDIA_PAUSE", title = "Pause" },
  { id = "__nowplaying__", title = "Now Playing", subtitle = "Open playback controls" },
}

local function buildRemoteListXml()
  local parts = { "<List>" }
  for _, it in ipairs(REMOTE_UI_ITEMS) do
    parts[#parts + 1] = navListItemXml(it.id, it.title, it.subtitle, it.header, "RemotePress")
  end
  parts[#parts + 1] = "</List>"
  return table.concat(parts)
end

-- Display name of a bound mini app device, or nil.
local function miniAppName(input)
  local dev = boundMiniApp(input)
  if not dev or not C4.GetDeviceDisplayName then return nil end
  local ok, name = pcall(function() return C4:GetDeviceDisplayName(tonumber(dev)) end)
  if ok and type(name) == "string" and trim(name) ~= "" then return trim(name) end
  return nil
end

-- 1.5.0: the Watch page is Apps only (the Remote key list is gone; the D-pad lives in the
-- Shield Remote web page driver). Lists bound mini apps first-class, App N Package as fallback.
local function buildAppsListXml()
  local parts = { "<List>",
    navListItemXml("__nowplaying__", "Now Playing", "Open playback controls", false, "RemotePress"),
    navListItemXml(nil, "Apps", nil, true) }
  local count, seen = 0, {}
  for slot = 1, 25 do
    local input = 3050 + slot
    local pkg = packageForInput(input)
    if pkg and not seen[pkg] then
      seen[pkg] = true
      count = count + 1
      parts[#parts + 1] = navListItemXml(pkg, miniAppName(input) or appLabel(pkg), nil, false, "AppLaunchUI")
    end
  end
  if count == 0 then
    parts[#parts + 1] = navListItemXml(nil, "No apps configured", "Bind mini apps or set App N Package in Composer", false)
  end
  parts[#parts + 1] = "</List>"
  return table.concat(parts)
end

local function ensureRoomSelected(roomId)
  local rid = tonumber(roomId)
  if rid and C4.GetBoundConsumerDevices then
    local ok, devs = pcall(function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), PROXY_NOWPLAYING) end)
    local proxyId = (ok and type(devs) == "table") and next(devs) or nil
    if proxyId and C4.SendToDevice then
      pcall(function() C4:SendToDevice(rid, "SELECT_VIDEO_DEVICE", { deviceid = proxyId }) end)
    end
  end
  if lastAwake == false then
    httpPost("/v1/wake", nil, nil)
  end
  npSelected = true
  npPublishAll()
  npStartTimer()
end

-- ---------------------------------------------------------------- Shield Remote web page (1.5.0)
-- uibutton proxy 5003 opens www/remote3.html. The page sends parameter-free UI_* commands
-- (UI_KEY_<KEY>, UI_VOL_UP/DOWN, UI_MUTE, UI_REFRESH, UI_HELLO_<build>) and reads the UI_STATE
-- variable / SendDataToUI snapshot. Opening the page (SELECT on 5003) never sends a key.
local PROXY_REMOTE = 5003
local PAGE_BUILD = 3            -- must match PAGE_BUILD in www/remote3.html (file renamed per release)
local uiSeq = 0

local REMOTE_KEYS = {
  DPAD_UP = true, DPAD_DOWN = true, DPAD_LEFT = true, DPAD_RIGHT = true, DPAD_CENTER = true,
  BACK = true, HOME = true, MENU = true,
  MEDIA_PLAY = true, MEDIA_PAUSE = true, MEDIA_PLAY_PAUSE = true, MEDIA_NEXT = true,
  MEDIA_PREVIOUS = true, MEDIA_REWIND = true, MEDIA_FAST_FORWARD = true,
}

local function myProxyId()
  if not C4.GetBoundConsumerDevices then return nil end
  local ok, devs = pcall(function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), PROXY_NOWPLAYING) end)
  return (ok and type(devs) == "table") and tonumber((next(devs))) or nil
end

-- True when the room's current video/watch source is this Shield.
local function roomIsOnMe(roomId)
  local pid = myProxyId()
  if not pid then return true end   -- unknown: do not force a source change
  local ok, v = pcall(function() return C4:GetDeviceVariable(tonumber(roomId), VAR_CURRENT_SELECTED_DEVICE) end)
  return ok and tonumber(v) == pid
end

local function jsonEsc(s)
  s = tostring(s or "")
  s = string.gsub(s, '[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", string.byte(c))
  end)
  return '"' .. s .. '"'
end

local remoteStateText = nil

publishRemoteState = function(force)
  local it = npCurrent or {}
  if fetchInlineArt then fetchInlineArt(it.art or "") end
  local awake = "null"
  if lastAwake == true then awake = "true" elseif lastAwake == false then awake = "false" end
  local text = "{" .. table.concat({
    '"title":' .. jsonEsc(it.title),
    '"artist":' .. jsonEsc(it.artist),
    '"album":' .. jsonEsc(it.album),
    '"state":' .. jsonEsc(it.state),
    '"art":' .. jsonEsc(artUrl(it.art, true)),
    '"app":' .. jsonEsc(appLabel(lastApp)),
    '"awake":' .. awake,
  }, ",") .. "}"
  local extra = string.format('"muted":%s,"vol":%s,"artKey":%s',
    roomMuted == nil and "null" or tostring(roomMuted),
    roomVolume and tostring(roomVolume) or "null",
    jsonEsc(artInline.key or ""))
  local fullText = text .. extra
  if force or fullText ~= remoteStateText then
    remoteStateText = fullText
    uiSeq = uiSeq + 1
    local head = string.format('{"t":"shieldremote","seq":%d,"build":%d,"linked":true,"np":%s,%s',
      uiSeq, PAGE_BUILD, text, extra)
    -- 1.5.1: the art no longer rides here; it has its own UI_ART variable (SendDataToUI never
    -- reached the Navigator web view, so the 1.5.0 artData copy was never seen).
    pcall(function() C4:SetVariable("UI_STATE", head .. "}") end)
    pcall(function() C4:SendDataToUI(head .. "}") end)
  end
end

-- UI_ART variable: {"t":"shieldart","key":<art path>,"data":<data: URI or "">}, set only on change.
local artVarText = nil
publishArt = function(force)
  local text = '{"t":"shieldart","key":' .. jsonEsc(artInline.key or "") ..
    ',"data":' .. jsonEsc(artInline.data or "") .. "}"
  if force or text ~= artVarText then
    artVarText = text
    pcall(function() C4:SetVariable("UI_ART", text) end)
  end
end

-- Inline art: the web view will not load http images, so fetch a small JPEG thumbnail from the
-- bridge (/art/<id>?w=320, bridge 0.4.3+) and send it to the page as a data: URI in UI_ART.
local ART_WIDTH = 320
local ART_MAX_BYTES = 60000
fetchInlineArt = function(path)
  if path == "" then
    if artInline.key ~= "" then artInline = { key = "", data = "" }; publishArt(false); publishRemoteState(false) end
    return
  end
  if path == artInline.key then return end
  -- A request that never called back is retried after 15 s.
  if path == artInline.pending and os.time() - (artInline.pendingAt or 0) < 15 then return end
  artInline.pending = path
  artInline.pendingAt = os.time()
  local base = string.gsub(trim(prop("Bridge URL")), "/+$", "")
  if base == "" then return end
  pcall(function()
    C4:urlGet(base .. path .. "?w=" .. ART_WIDTH, {}, false, function(ticket, data, code, headers, err)
      if artInline.pending ~= path then return end
      artInline.pending = nil
      local n = data and #data or 0
      if tonumber(code) == 200 and n > 0 and n <= ART_MAX_BYTES then
        local ctype = "image/jpeg"
        if type(headers) == "table" then
          for k, v in pairs(headers) do
            if string.lower(tostring(k)) == "content-type" then ctype = tostring(v) end
          end
        end
        artInline = { key = path, data = "data:" .. ctype .. ";base64," .. C4:Base64Encode(data) }
      else
        logMsg(LOG_DEBUG, "Inline art skipped (code %s, %d bytes)", tostring(code), n)
        artInline = { key = path, data = "" }
      end
      publishArt(false)
      publishRemoteState(false)
    end)
  end)
end

local function remoteKey(tParams)
  local key = trim(tParams.KEY or "")
  if not REMOTE_KEYS[key] then
    logMsg(LOG_WARN, "Shield Remote key %s not allowed", key)
    return
  end
  local rid = tonumber(tParams.ROOMID or "")
  if rid and not roomIsOnMe(rid) then
    -- First press with the room on another source (or off): select the Shield and wake it, drop the key.
    logMsg(LOG_INFO, "Shield Remote: selecting Shield in room %d (key %s dropped)", rid, key)
    ensureRoomSelected(rid)
    return
  end
  if lastAwake == false then httpPost("/v1/wake", nil, nil) end
  enqueueKey(key)
end

local ROOM_VOLUME = { UI_VOL_UP = "PULSE_VOL_UP", UI_VOL_DOWN = "PULSE_VOL_DOWN", UI_MUTE = "MUTE_TOGGLE" }

local function myRoomId()
  local ok, r = pcall(function() return C4:RoomGetId() end)
  return ok and tonumber(r) or nil
end

-- Room mute/volume state for the page: find the room's variables by name and watch them.
local roomAudio = { room = nil, mute = nil, vol = nil }

local function truthy(v)
  local s = string.lower(trim(tostring(v or "")))
  return s == "1" or s == "true" or s == "on"
end

local function watchRoomAudio()
  local rid = myRoomId()
  if not rid then return end
  local ok, vars = pcall(function() return C4:GetDeviceVariables(rid) end)
  if not ok or type(vars) ~= "table" then return end
  local names = {}
  for id, v in pairs(vars) do
    if type(v) == "table" and type(v.name) == "string" then
      local n = string.upper(v.name)
      names[#names + 1] = v.name .. "=" .. tostring(id)
      if not roomAudio.mute and string.find(n, "MUTE", 1, true) then
        roomAudio.mute = tonumber(id); roomMuted = truthy(v.value)
      elseif n == "CURRENT_VOLUME" or (not roomAudio.vol and string.find(n, "VOLUME", 1, true)
          and not string.find(n, "DEVICE", 1, true) and tonumber(v.value)) then
        roomAudio.vol = tonumber(id); roomVolume = tonumber(v.value)
      end
    end
  end
  roomAudio.room = rid
  logMsg(LOG_DEBUG, "Room %d variables: %s", rid, table.concat(names, ", "))
  for _, id in ipairs({ roomAudio.mute, roomAudio.vol }) do
    pcall(function() C4:RegisterVariableListener(rid, id) end)
  end
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  local ok, err = pcall(function()
    local dev, var = tonumber(idDevice), tonumber(idVariable)
    if var == VAR_CURRENT_SELECTED_DEVICE then npRefreshSelection() end
    if dev ~= roomAudio.room then return end
    if var == roomAudio.mute then roomMuted = truthy(strValue); publishRemoteState(false)
    elseif var == roomAudio.vol then roomVolume = tonumber(strValue); publishRemoteState(false) end
  end)
  if not ok then logMsg(LOG_ERROR, "OnWatchedVariableChanged error: %s", tostring(err)) end
end

-- Handles one UI_* command from the Shield Remote page.
local function handleUi(cmd)
  if string.sub(cmd, 1, 7) == "UI_KEY_" then
    remoteKey({ KEY = string.sub(cmd, 8), ROOMID = myRoomId() })
  elseif ROOM_VOLUME[cmd] then
    local rid = myRoomId()
    if rid then pcall(function() C4:SendToDevice(rid, ROOM_VOLUME[cmd], {}) end) end
    if cmd == "UI_MUTE" and not roomAudio.mute then
      -- No room mute variable to watch: flip our own idea of it so the icon still follows.
      roomMuted = not (roomMuted == true)
      publishRemoteState(false)
    end
  elseif cmd == "UI_REFRESH" then
    publishArt(true)
    publishRemoteState(true)
  elseif UI_ART_STATUS[cmd] then
    pcall(function() C4:UpdateProperty("Web Page Status", "Page build " .. PAGE_BUILD .. " OK, " .. UI_ART_STATUS[cmd]) end)
  elseif string.sub(cmd, 1, 9) == "UI_HELLO_" then
    local b = string.sub(cmd, 10)
    if tonumber(b) == PAGE_BUILD then
      pcall(function() C4:UpdateProperty("Web Page Status", "Page build " .. b .. " OK") end)
    else
      pcall(function() C4:UpdateProperty("Web Page Status",
        "PAGE IS STALE: page " .. b .. ", driver expects " .. PAGE_BUILD) end)
    end
    publishArt(true)
    publishRemoteState(true)
  else
    logMsg(LOG_DEBUG, "Unhandled UI command %s", cmd)
  end
end

function ExecuteCommand(strCommand, tParams)
  local ok, err = pcall(function()
    local cmd = tostring(strCommand or "")
    if string.sub(cmd, 1, 3) == "UI_" then handleUi(cmd) end
  end)
  if not ok then logMsg(LOG_ERROR, "ExecuteCommand error: %s", tostring(err)) end
end

local NAV_TABS_XML = table.concat({
  "<Tabs>",
  "<Tab><Id>Apps</Id><Name>Apps</Name><IconId>device</IconId><ScreenId>AppsScreen</ScreenId></Tab>",
  "</Tabs>",
})

-- ---------------------------------------------------------------- proxy commands

function ReceivedFromProxy(idBinding, strCommand, tParams)
  local ok, err = pcall(function()
    tParams = tParams or {}
    local cmd = tostring(strCommand or "")

    -- Shield Remote tile/page (uibutton 5003): UI_* commands act; SELECT and anything else only republish.
    if tonumber(idBinding) == PROXY_REMOTE then
      if string.sub(cmd, 1, 3) == "UI_" then handleUi(cmd) else publishRemoteState(true) end
      return
    end

    -- Mini app PASSTHROUGH: unwrap the inner remote key and handle it like a 5001 key.
    if cmd == "PASSTHROUGH" then
      local inner = tostring(tParams.PASSTHROUGH_COMMAND or "")
      if inner == "" then
        logMsg(LOG_DEBUG, "PASSTHROUGH without a command (dropped)")
        return
      end
      cmd = inner
      idBinding = PROXY_MEDIA
    end

    if INPUT_COMMANDS[cmd] and tParams.INPUT ~= nil then
      switchToInput(tParams.INPUT, tParams.OUTPUT)
      npSelected = true
      npPublishAll()
      npStartTimer()
      return
    end

    -- Navigator Now Playing proxy (media_service, 5001)
    if idBinding == PROXY_NOWPLAYING then
      if cmd == "DEVICE_SELECTED" or cmd == "GetDashboard" or cmd == "GetQueue" then
        npPublishAll()
        if cmd == "DEVICE_SELECTED" then
          if lastAwake == false then
            logMsg(LOG_INFO, "Shield asleep on source select; waking")
            httpPost("/v1/wake", nil, nil)
          end
          npSelected = true
          npStartTimer()
        end
        return ""
      elseif cmd == "TabsCommand" then
        logMsg(LOG_DEBUG, "TabsCommand (nav=%s)", tostring(tParams.NAVID or ""))
        sendNavData(tParams, NAV_TABS_XML)
        return
      elseif cmd == "GetRemoteScreen" then
        logMsg(LOG_DEBUG, "GetRemoteScreen (nav=%s)", tostring(tParams.NAVID or ""))
        sendNavData(tParams, buildRemoteListXml())
        return
      elseif cmd == "GetAppsScreen" then
        logMsg(LOG_DEBUG, "GetAppsScreen (nav=%s)", tostring(tParams.NAVID or ""))
        sendNavData(tParams, buildAppsListXml())
        return
      elseif cmd == "RemotePress" then
        local args = parseNavArgs(tParams)
        local key = trim(args.id or "")
        logMsg(LOG_DEBUG, "RemotePress id=%s", key)
        if key == "__nowplaying__" then
          ensureRoomSelected(tParams.ROOMID)
          sendNavData(tParams, "<NextScreen>#nowplaying</NextScreen>")
        elseif key ~= "" then
          if lastAwake == false then httpPost("/v1/wake", nil, nil) end
          enqueueKey(key)
          sendNavData(tParams, "")
        else
          sendNavData(tParams, "")
        end
        return
      elseif cmd == "AppLaunchUI" then
        local args = parseNavArgs(tParams)
        local pkg = trim(args.id or "")
        logMsg(LOG_INFO, "AppLaunchUI package=%s", pkg)
        if pkg ~= "" and string.match(pkg, "^[%w_%.]+$") then
          ensureRoomSelected(tParams.ROOMID)
          httpPost("/v1/launch", "package=" .. pkg, nil)
          sendNavData(tParams, "<NextScreen>#nowplaying</NextScreen>")
        else
          sendNavData(tParams, "")
        end
        return
      elseif cmd == "DESTROY_NAV" or cmd == "DESTROY_NAVIGATOR" then
        logMsg(LOG_DEBUG, "%s (nav=%s)", cmd, tostring(tParams.NAVID or ""))
        return
      elseif cmd == "SELECT_SOURCE" or cmd == "RESELECT_SOURCE" then
        npPublishAll()
        return
      elseif cmd == "DEVICE_DESELECTED" then
        logMsg(LOG_DEBUG, "DEVICE_DESELECTED (no action)")
        return
      elseif cmd == "OFF" then
        npSelected = false
        npStopTimer()   -- then falls through to the sleep command below
      elseif cmd == "ToggleShuffle" or cmd == "ToggleRepeat" or cmd == "NowPlayingCommand" then
        return
      end
      -- Dashboard buttons: ScanRev / ScanFwd use the Shield's rewind / fast-forward keys.
      local scanKey = { ScanRevPress = "MEDIA_REWIND", ScanRevRelease = "MEDIA_REWIND",
                        ScanFwdPress = "MEDIA_FAST_FORWARD", ScanFwdRelease = "MEDIA_FAST_FORWARD" }
      if scanKey[cmd] then
        -- hold the key while the button is held, so scanning is continuous
        httpPost("/v1/key", "name=" .. scanKey[cmd] .. "&dir=" .. (string.find(cmd, "Press") and "start" or "end"), nil)
        return
      end
    end

    -- Press-and-hold OK (Shield needs a long press on OK to move favorites)
    if cmd == "START_ENTER" or cmd == "STOP_ENTER" then
      httpPost("/v1/key", "name=DPAD_CENTER&dir=" .. (cmd == "START_ENTER" and "start" or "end"), nil)
      return
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

    if string.sub(cmd, 1, 4) == "END_" then
      logMsg(LOG_TRACE, "Ignoring key release %s", cmd)
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
  -- Snapshot for the Shield Remote page (must stay visible so the page can subscribe).
  pcall(function() C4:AddVariable("UI_STATE", "", "STRING", true, false) end)
  pcall(function() C4:AddVariable("UI_ART", "", "STRING", true, false) end)
  applyLogSettings()
end

function OnDriverLateInit()
  local ok, err = pcall(function()
    applyLogSettings()
    C4:UpdateProperty("Connected To Bridge", "false")
    npSetVars()
    npRegisterRooms()
    refreshBoundApps()
    watchRoomAudio()
    refreshShieldList()
    startPolling()
    pollStatus()
  end)
  if not ok then logMsg(LOG_ERROR, "Late init error: %s", tostring(err)) end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  local n = tonumber(idBinding)
  if not n or n < INPUT_MIN or n > INPUT_MAX then return end
  local ok, err = pcall(refreshBoundApps)
  if not ok then logMsg(LOG_ERROR, "Binding change error: %s", tostring(err)) end
end

function OnPropertyChanged(strProperty)
  local ok, err = pcall(function()
    if strProperty == "Log Level" or strProperty == "Log Mode" then
      applyLogSettings()
    elseif strProperty == "Poll Seconds" or strProperty == "Bridge URL"
        or strProperty == "Bridge Token" or strProperty == "Shield Name" then
      if strProperty == "Bridge URL" or strProperty == "Bridge Token" then refreshShieldList() end
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
