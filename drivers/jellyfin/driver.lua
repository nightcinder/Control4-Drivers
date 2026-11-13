--[[
  Media Server Now Playing: Jellyfin and Plex together (Control4 DriverWorks, OS 3.x)
  Version: 0.3.0  (UNTESTED on real Composer/Director)

  Each enabled backend is polled on its own timer, with its own URL, key, status and last result.
  Jellyfin: GET {Jellyfin URL}/Sessions, POST {base}/Sessions/{SessionId}/Playing/{Cmd}.
  Plex:     GET {Plex URL}/status/sessions, GET {base}/player/playback/{cmd}.
  The active view is a PLAYING session (sticky while it keeps playing), otherwise a PAUSED one.
  Only the active view drives the now-playing variables, events and transport commands.
  API keys and Plex tokens are plain STRING properties (Composer cannot mask them).
  They are never written to the log. Plex artwork URLs contain the token, so the Artwork URL variable carries it too.
]]

local DRIVER_VERSION = "0.3.0"
local TICKS_PER_SECOND = 10000000
local WATCHDOG_SECONDS = 20
local DEFAULT_POLL_SECONDS = 4
local RETRY_NOT_CONFIGURED_SECONDS = 30
local ACTIVE_WITHIN_SECONDS = 960
local PLEX_CLIENT_ID = "control4-media-server-driver"

local EVENT_STATE_CHANGED = 1
local EVENT_PLAYBACK_STARTED = 2
local EVENT_PLAYBACK_STOPPED = 3
local EVENT_ITEM_CHANGED = 4

local BKEYS = { "Jellyfin", "Plex" }
local CONF = {
  Jellyfin = { enable = "Jellyfin Enabled", url = "Jellyfin URL", key = "Jellyfin API Key" },
  Plex = { enable = "Plex Enabled", url = "Plex URL", key = "Plex Token" },
}

local ITEM_VARIABLES = {
  "Now Playing Title", "Now Playing Subtitle", "Now Playing Summary", "Artist", "Year", "Media Type",
  "Position", "Position Seconds", "Runtime", "Runtime Seconds", "Client", "Device", "User",
  "Artwork URL", "Item Id",
}
local ALL_VARIABLES = { "Play State", "Session Id", "ACTIVE_SOURCE" }
for _, n in ipairs(ITEM_VARIABLES) do ALL_VARIABLES[#ALL_VARIABLES + 1] = n end

-- Per-backend state: each backend has its own status, timers, auth form and last result.
local bs = {}
for _, k in ipairs(BKEYS) do
  bs[k] = {
    status = "", inflight = false, inflightSince = 0, authMode = "Authorization",
    best = nil, pollTimer = nil, commandId = 0, lastOk = 0,
  }
end

-- Driver-wide state: which backend the now-playing view comes from.
local state = {
  activeKey = "", active = nil,
  playState = "", itemId = "", runSec = 0,
  primed = false, watchdogTimer = nil,
}
local lastVars = {}
local lastProps = {}
local lastStatus = ""

local pollBackend, reselect, watchdogTick   -- defined below

-- ============================================================================
-- Small helpers
-- ============================================================================
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function join(a, b)
  if a == "" then return b end
  if b == "" then return a end
  return a .. " - " .. b
end

local function prop(name)
  local v = nil
  pcall(function() v = Properties[name] end)
  return trim(v)
end

local function setProp(name, value)
  value = tostring(value or "")
  if lastProps[name] == value then return end
  lastProps[name] = value
  pcall(function() C4:UpdateProperty(name, value) end)
end

local function debugLog(msg)
  if prop("Debug Log") == "On" then
    pcall(function() print("[MediaServer] " .. tostring(msg)) end)
  end
end

local function logAlways(msg)
  pcall(function() print("[MediaServer] " .. tostring(msg)) end)
end

local function enabled(k)
  return prop(CONF[k].enable) == "On"
end

local function baseOf(k)
  local u = (prop(CONF[k].url):gsub("/+$", ""))
  if u ~= "" and not string.find(u, "^https?://") then u = "http://" .. u end
  return u
end

local function keyOf(k)
  return prop(CONF[k].key)
end

local function configured(k)
  return baseOf(k) ~= "" and keyOf(k) ~= ""
end

local function tlsOptions()
  if prop("Allow Self-Signed TLS") == "On" then
    return { ssl_verifypeer = 0, ssl_verifyhost = 0 }
  end
  return {}
end

-- Status property: "Jellyfin: OK | Plex: HTTP 401", or "Not configured" when neither is enabled.
local function statusLine()
  local parts = {}
  for _, k in ipairs(BKEYS) do
    if enabled(k) then
      local st = bs[k].status
      if st == "" then st = "starting" end
      parts[#parts + 1] = k .. ": " .. st
    end
  end
  if #parts == 0 then return "Not configured" end
  return table.concat(parts, " | ")
end

local function refreshStatus()
  local text = statusLine()
  if text == lastStatus then return end
  lastStatus = text
  setProp("Status", text)
end

local function setBackendStatus(k, text)
  bs[k].status = tostring(text or "")
  refreshStatus()
end

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

local function jsonDecode(str)
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
-- Formatting
-- ============================================================================
local function fmtTime(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- ============================================================================
-- Backends. Each one is stateless: it takes a config table cfg = {base, key}
-- and, where needed, its own per-backend state table st. Nothing reads a global
-- server type. parse() returns normalized sessions with the fields:
--   id, clientId, user, device, client, paused, posSec, runSec, itemId, mediaType,
--   title, subtitle, artist, year, artwork, activity
-- transport(action, session, offsetMs, st) returns method, path, extra headers, query.
-- ============================================================================
local BACKENDS = {}

-- Jellyfin ------------------------------------------------------------------
local JELLYFIN_COMMANDS = {
  PlayPause = "PlayPause", Unpause = "Unpause", Pause = "Pause", Stop = "Stop",
  NextTrack = "NextTrack", PreviousTrack = "PreviousTrack",
}

local function jellyfinDescribe(item)
  local t = tostring(item.Type or "")
  local title = tostring(item.Name or "")
  local subtitle, artist = "", ""
  if t == "Episode" then
    title = tostring(item.SeriesName or item.Name or "")
    local se = ""
    if item.ParentIndexNumber and item.IndexNumber then
      se = string.format("S%02dE%02d", item.ParentIndexNumber, item.IndexNumber)
    end
    subtitle = trim(se .. " " .. tostring(item.Name or ""))
  elseif t == "Audio" then
    artist = tostring((type(item.Artists) == "table" and item.Artists[1]) or item.AlbumArtist or "")
    subtitle = tostring(item.Album or "")
  else
    subtitle = item.ProductionYear and tostring(item.ProductionYear) or ""
  end
  return title, subtitle, artist
end

BACKENDS.Jellyfin = {
  name = "Jellyfin",
  headers = function(key, mode)
    local h = { ["Accept"] = "application/json" }
    if mode == "X-Emby-Token" then
      h["X-Emby-Token"] = key
    else
      h["Authorization"] = 'MediaBrowser Token="' .. key .. '"'
    end
    return h
  end,
  canRetryAuth = true,
  pollPath = function() return "/Sessions?activeWithinSeconds=" .. ACTIVE_WITHIN_SECONDS end,
  testPath = function() return "/System/Info" end,
  parse = function(data, cfg)
    local out = {}
    if type(data) ~= "table" then return out end
    for _, s in ipairs(data) do
      if type(s) == "table" and type(s.NowPlayingItem) == "table" then
        local item = s.NowPlayingItem
        local ps = type(s.PlayState) == "table" and s.PlayState or {}
        local title, subtitle, artist = jellyfinDescribe(item)
        local art = ""
        if type(item.ImageTags) == "table" and item.ImageTags.Primary and item.Id then
          art = cfg.base .. "/Items/" .. tostring(item.Id) .. "/Images/Primary?maxWidth=480&quality=90"
        end
        out[#out + 1] = {
          id = tostring(s.Id or ""), clientId = "", user = tostring(s.UserName or ""),
          device = tostring(s.DeviceName or ""), client = tostring(s.Client or ""),
          paused = ps.IsPaused == true,
          posSec = (tonumber(ps.PositionTicks) or 0) / TICKS_PER_SECOND,
          runSec = (tonumber(item.RunTimeTicks) or 0) / TICKS_PER_SECOND,
          itemId = tostring(item.Id or ""), mediaType = tostring(item.Type or ""),
          title = title, subtitle = subtitle, artist = artist,
          year = item.ProductionYear and tostring(item.ProductionYear) or "",
          artwork = art, activity = tostring(s.LastActivityDate or ""),
        }
      end
    end
    return out
  end,
  transport = function(action, s, offsetMs)
    if action == "Seek" then
      return "POST", "/Sessions/" .. s.id .. "/Playing/Seek", {},
        "?seekPositionTicks=" .. string.format("%.0f", offsetMs * 10000)
    end
    return "POST", "/Sessions/" .. s.id .. "/Playing/" .. JELLYFIN_COMMANDS[action], {}, ""
  end,
}

-- Plex ----------------------------------------------------------------------
local PLEX_COMMANDS = {
  PlayPause = "playPause", Unpause = "play", Pause = "pause", Stop = "stop",
  NextTrack = "skipNext", PreviousTrack = "skipPrevious", Seek = "seekTo",
}

BACKENDS.Plex = {
  name = "Plex",
  headers = function(key)
    return {
      ["Accept"] = "application/json",
      ["X-Plex-Token"] = key,
      ["X-Plex-Client-Identifier"] = PLEX_CLIENT_ID,
    }
  end,
  canRetryAuth = false,
  pollPath = function() return "/status/sessions" end,
  testPath = function() return "/identity" end,
  parse = function(data, cfg)
    local out = {}
    local mc = type(data) == "table" and data.MediaContainer or nil
    local meta = type(mc) == "table" and mc.Metadata or nil
    if type(meta) ~= "table" then return out end
    for _, m in ipairs(meta) do
      if type(m) == "table" then
        local p = type(m.Player) == "table" and m.Player or {}
        local u = type(m.User) == "table" and m.User or {}
        local se = type(m.Session) == "table" and m.Session or {}
        local t = tostring(m.type or "")
        local mTitle = tostring(m.title or "")
        local gTitle = tostring(m.grandparentTitle or "")
        local pTitle = tostring(m.parentTitle or "")
        local title, subtitle, artist = mTitle, "", ""
        if t == "episode" then
          title = gTitle ~= "" and gTitle or mTitle
          subtitle = join(pTitle, mTitle)
        elseif t == "track" then
          artist = gTitle
          subtitle = pTitle
        else
          subtitle = m.year and tostring(m.year) or ""
        end
        local thumb = tostring(m.thumb or "")
        local art = ""
        if thumb ~= "" then art = cfg.base .. thumb .. "?X-Plex-Token=" .. cfg.key end
        out[#out + 1] = {
          id = tostring(se.id or ""), clientId = tostring(p.machineIdentifier or ""),
          user = tostring(u.title or ""), device = tostring(p.title or ""), client = tostring(p.product or ""),
          paused = tostring(p.state or "") == "paused",
          posSec = (tonumber(m.viewOffset) or 0) / 1000,
          runSec = (tonumber(m.duration) or 0) / 1000,
          itemId = tostring(m.ratingKey or ""), mediaType = t,
          title = title, subtitle = subtitle, artist = artist,
          year = m.year and tostring(m.year) or "",
          artwork = art, activity = "",
        }
      end
    end
    return out
  end,
  transport = function(action, s, offsetMs, st)
    st.commandId = st.commandId + 1
    local q = "?commandID=" .. st.commandId
    if action == "Seek" then
      q = q .. "&offset=" .. string.format("%.0f", offsetMs)
    end
    return "GET", "/player/playback/" .. PLEX_COMMANDS[action],
      { ["X-Plex-Target-Client-Identifier"] = s.clientId }, q
  end,
}

-- ============================================================================
-- HTTP for one backend k. Jellyfin only: a 401/403 on the first auth form is
-- retried once with the other form (Authorization <-> X-Emby-Token).
-- The handler receives (data, httpCode, err).
-- ============================================================================
local function request(k, method, path, handler, extraHeaders, retried)
  local b = BACKENDS[k]
  local st = bs[k]
  local url = baseOf(k) .. path
  local opts = tlsOptions()
  local headers = b.headers(keyOf(k), st.authMode)
  for hk, hv in pairs(extraHeaders or {}) do headers[hk] = hv end
  debugLog(k .. " " .. method .. " " .. path)

  local function onReply(_, data, code, _, err)
    code = tonumber(code) or 0
    if (code == 401 or code == 403) and not retried and b.canRetryAuth and st.authMode == "Authorization" then
      st.authMode = "X-Emby-Token"
      debugLog(k .. ": auth rejected, retrying with X-Emby-Token form")
      request(k, method, path, handler, extraHeaders, true)
      return
    end
    handler(data, code, err)
  end

  local ok, perr = pcall(function()
    if method == "POST" then
      C4:urlPost(url, "", headers, false, onReply, opts)
    else
      C4:urlGet(url, headers, false, onReply, opts)
    end
  end)
  if not ok then
    handler(nil, 0, tostring(perr))
  end
end

local function errorText(code)
  if code == 0 then return "Unreachable" end
  return "HTTP " .. tostring(code)
end

-- ============================================================================
-- Session selection
-- ============================================================================
local function matchesFilter(s, filter)
  if filter == "" then return true end
  local f = string.lower(filter)
  return string.find(string.lower(s.user), f, 1, true) ~= nil
    or string.find(string.lower(s.device .. " " .. s.client), f, 1, true) ~= nil
end

-- Best session of ONE backend: playing beats paused; ties go to the most recent activity.
-- The Target User Or Device Filter applies here, so it covers both backends.
local function pickSession(list)
  local filter = prop("Target User Or Device Filter")
  local best, bestPlaying, bestActivity = nil, false, ""
  for _, s in ipairs(list) do
    if matchesFilter(s, filter) then
      local playing = not s.paused
      if best == nil or (playing and not bestPlaying) or (playing == bestPlaying and s.activity > bestActivity) then
        best, bestPlaying, bestActivity = s, playing, s.activity
      end
    end
  end
  return best
end

-- ============================================================================
-- Driver variables (set only when the value changes) and events
-- ============================================================================
local function ensureVariables()
  for _, name in ipairs(ALL_VARIABLES) do
    pcall(function() C4:AddVariable(name, "", "STRING", true, false) end)
  end
end

local function setVar(name, value)
  value = tostring(value or "")
  if lastVars[name] == value then return end
  lastVars[name] = value
  pcall(function() C4:SetVariable(name, value) end)
end

local function clearItemVars()
  for _, n in ipairs(ITEM_VARIABLES) do setVar(n, "") end
end

local function fireEvent(id)
  pcall(function() C4:FireEvent(id) end)
end

-- Publishes the chosen session of backend k (or nil for nothing playing).
-- Events fire only on changes of the active view, and never on the first state after load.
local function applySession(k, s)
  local fire = state.primed
  state.primed = true
  local prevState, prevItem = state.playState, state.itemId

  if s == nil then
    state.activeKey = ""
    state.active = nil
    state.itemId = ""
    state.runSec = 0
    state.playState = "Stopped"
    setVar("Play State", "Stopped")
    setVar("Session Id", "")
    setVar("ACTIVE_SOURCE", "None")
    setProp("Active Source", "None")
    clearItemVars()
    if fire and (prevState == "Playing" or prevState == "Paused") then
      fireEvent(EVENT_STATE_CHANGED)
      fireEvent(EVENT_PLAYBACK_STOPPED)
    end
    return
  end

  local newState = s.paused and "Paused" or "Playing"
  state.activeKey = k
  state.active = s
  state.itemId = s.itemId
  state.runSec = s.runSec
  state.playState = newState

  setVar("ACTIVE_SOURCE", k)
  setProp("Active Source", k)
  setVar("Play State", newState)
  setVar("Session Id", s.id)
  setVar("Now Playing Title", s.title)
  setVar("Now Playing Subtitle", s.subtitle)
  setVar("Now Playing Summary", join(s.title, s.subtitle))
  setVar("Artist", s.artist)
  setVar("Year", s.year)
  setVar("Media Type", s.mediaType)
  setVar("Position", fmtTime(s.posSec))
  setVar("Position Seconds", math.floor(s.posSec))
  setVar("Runtime", fmtTime(s.runSec))
  setVar("Runtime Seconds", math.floor(s.runSec))
  setVar("Client", s.client)
  setVar("Device", s.device)
  setVar("User", s.user)
  setVar("Item Id", s.itemId)
  setVar("Artwork URL", s.artwork)

  if fire then
    if newState ~= prevState then
      fireEvent(EVENT_STATE_CHANGED)
      if newState == "Playing" then fireEvent(EVENT_PLAYBACK_STARTED) end
    end
    if s.itemId ~= prevItem then fireEvent(EVENT_ITEM_CHANGED) end
  end
end

-- Chooses the active view from the per-backend results.
-- Playing beats paused. Among several candidates the current active backend wins (sticky).
reselect = function()
  local playing, paused = {}, {}
  for _, k in ipairs(BKEYS) do
    local s = enabled(k) and bs[k].best or nil
    if s ~= nil then
      if s.paused then paused[#paused + 1] = k else playing[#playing + 1] = k end
    end
  end
  local function choose(list)
    for _, k in ipairs(list) do
      if k == state.activeKey then return k end
    end
    return list[1]
  end
  local pick = nil
  if #playing > 0 then
    pick = choose(playing)
  elseif #paused > 0 then
    pick = choose(paused)
  end
  if pick then
    applySession(pick, bs[pick].best)
  else
    applySession(nil, nil)
  end
  refreshStatus()
end

-- ============================================================================
-- Polling (one timer per backend) and watchdog
-- ============================================================================
local function pollSeconds()
  local n = tonumber(prop("Poll Interval Seconds")) or DEFAULT_POLL_SECONDS
  if n < 2 then n = 2 end
  if n > 60 then n = 60 end
  return n
end

local function cancelPoll(k)
  local st = bs[k]
  if st.pollTimer then pcall(function() st.pollTimer:Cancel() end) end
  st.pollTimer = nil
end

local function schedulePoll(k, seconds)
  local st = bs[k]
  cancelPoll(k)
  st.pollTimer = C4:SetTimer(math.floor(seconds * 1000), function()
    st.pollTimer = nil
    pollBackend(k)
  end)
end

local function armWatchdog()
  if state.watchdogTimer then pcall(function() state.watchdogTimer:Cancel() end) end
  state.watchdogTimer = C4:SetTimer(WATCHDOG_SECONDS * 1000, function()
    watchdogTick()
  end)
end

watchdogTick = function()
  local changed = false
  for _, k in ipairs(BKEYS) do
    local st = bs[k]
    if st.inflight and os.time() - st.inflightSince >= WATCHDOG_SECONDS then
      st.inflight = false
      st.best = nil
      changed = true
      setBackendStatus(k, "no reply within " .. WATCHDOG_SECONDS .. "s")
      debugLog(k .. ": watchdog reset a stuck request")
      schedulePoll(k, pollSeconds())
    end
  end
  if changed then reselect() end
  armWatchdog()
end

local function onPoll(k, data, code, err)
  local st = bs[k]
  st.inflight = false
  if code >= 200 and code < 300 then
    local decoded, decodeErr = jsonDecode(data or "")
    if type(decoded) ~= "table" then
      st.best = nil
      setBackendStatus(k, "unexpected reply")
      debugLog(k .. " decode error: " .. tostring(decodeErr))
    else
      st.lastOk = os.time()
      st.best = pickSession(BACKENDS[k].parse(decoded, { base = baseOf(k), key = keyOf(k) }))
      setBackendStatus(k, "OK")
    end
  else
    st.best = nil
    setBackendStatus(k, errorText(code))
    debugLog(k .. " poll failed: HTTP " .. tostring(code) .. " " .. tostring(err or ""))
  end
  reselect()
  schedulePoll(k, pollSeconds())
end

pollBackend = function(k)
  local st = bs[k]
  if not enabled(k) then
    cancelPoll(k)
    st.best = nil
    st.status = ""
    reselect()
    return
  end
  if not configured(k) then
    st.best = nil
    setBackendStatus(k, "not configured")
    reselect()
    schedulePoll(k, RETRY_NOT_CONFIGURED_SECONDS)
    return
  end
  if st.inflight then return end
  st.inflight = true
  st.inflightSince = os.time()
  request(k, "GET", BACKENDS[k].pollPath(), function(data, code, err)
    onPoll(k, data, code, err)
  end)
end

-- ============================================================================
-- Actions and commands
-- ============================================================================
local function testConnection()
  local any = false
  for _, k in ipairs(BKEYS) do
    if enabled(k) then
      any = true
      if not configured(k) then
        setBackendStatus(k, "not configured")
      else
        setBackendStatus(k, "testing")
        request(k, "GET", BACKENDS[k].testPath(), function(data, code, err)
          if code >= 200 and code < 300 then
            local info = jsonDecode(data or "")
            if k == "Jellyfin" and type(info) == "table" then
              setProp("Server Name", tostring(info.ServerName or ""))
            end
            setBackendStatus(k, "OK")
          else
            setBackendStatus(k, errorText(code))
            debugLog(k .. " test failed: HTTP " .. tostring(code) .. " " .. tostring(err or ""))
          end
        end)
      end
    end
  end
  if not any then logAlways("Test Connection: no backend is enabled") end
  refreshStatus()
end

-- Sends a transport command to the ACTIVE backend, using its own session id.
local function sendTransport(action, offsetMs)
  local k = state.activeKey
  local s = state.active
  if k == "" or s == nil or s.id == "" or not string.find(s.id, "^[%w%-]+$") then
    logAlways("transport " .. tostring(action) .. ": no active session, nothing sent")
    return
  end
  if k == "Plex" and not string.find(s.clientId, "^[%w%-]+$") then
    logAlways("transport " .. tostring(action) .. ": no Plex player to control, nothing sent")
    return
  end
  local method, path, extra, query = BACKENDS[k].transport(action, s, offsetMs or 0, bs[k])
  request(k, method, path .. query, function(_, code, err)
    if code >= 200 and code < 300 then
      schedulePoll(k, 0.5)
    else
      setBackendStatus(k, errorText(code))
      debugLog(k .. " transport failed: HTTP " .. tostring(code) .. " " .. tostring(err or ""))
    end
  end, extra)
end

local function seekToPercent(params)
  local pct = nil
  if type(params) == "table" then
    pct = tonumber(params["Percent"] or params["PERCENT"] or params["percent"])
  end
  if not pct or pct < 0 or pct > 100 then
    logAlways("Seek needs Percent between 0 and 100")
    return
  end
  if state.runSec <= 0 then
    logAlways("Seek unavailable: runtime unknown")
    return
  end
  sendTransport("Seek", math.floor(state.runSec * 1000 * pct / 100))
end

-- Command names are normalized, so "Play/Pause", "Play Pause" and "PLAY_PAUSE" all work.
function ExecuteCommand(strCommand, tParams)
  local key = string.upper((string.gsub(trim(strCommand), "[^%w]+", "_")))
  if key == "PLAY_PAUSE" then sendTransport("PlayPause")
  elseif key == "PLAY" then sendTransport("Unpause")
  elseif key == "PAUSE" then sendTransport("Pause")
  elseif key == "STOP" then sendTransport("Stop")
  elseif key == "NEXT" then sendTransport("NextTrack")
  elseif key == "PREVIOUS" then sendTransport("PreviousTrack")
  elseif key == "SEEK_TO_PERCENT" then seekToPercent(tParams)
  elseif key == "TEST_CONNECTION" then testConnection()
  elseif key == "REFRESH_NOW" then
    for _, k in ipairs(BKEYS) do schedulePoll(k, 0.5) end
  else debugLog("unknown command " .. key)
  end
end

-- ============================================================================
-- Driver lifecycle
-- ============================================================================
function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  setProp("Active Source", "None")
  ensureVariables()
  refreshStatus()
end

function OnDriverLateInit()
  for _, k in ipairs(BKEYS) do bs[k].authMode = "Authorization" end
  armWatchdog()
  for _, k in ipairs(BKEYS) do schedulePoll(k, 1) end
end

function OnDriverDestroyed()
  for _, k in ipairs(BKEYS) do cancelPoll(k) end
  pcall(function() if state.watchdogTimer then state.watchdogTimer:Cancel() end end)
end

-- Restarts one backend after its enable flag, URL or key changed.
local function restartBackend(k)
  bs[k].authMode = "Authorization"
  bs[k].best = nil
  bs[k].inflight = false
  if not enabled(k) then bs[k].status = "" end
  reselect()
  schedulePoll(k, 1)
end

function OnPropertyChanged(name)
  if name == "Jellyfin Enabled" or name == "Jellyfin URL" or name == "Jellyfin API Key" then
    restartBackend("Jellyfin")
  elseif name == "Plex Enabled" or name == "Plex URL" or name == "Plex Token" then
    restartBackend("Plex")
  elseif name == "Allow Self-Signed TLS" then
    for _, k in ipairs(BKEYS) do restartBackend(k) end
  elseif name == "Poll Interval Seconds" then
    for _, k in ipairs(BKEYS) do
      if enabled(k) then schedulePoll(k, 1) end
    end
  elseif name == "Target User Or Device Filter" then
    reselect()
  end
  refreshStatus()
end
