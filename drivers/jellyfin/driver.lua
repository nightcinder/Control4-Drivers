--[[
  Media Server Now Playing: Jellyfin or Plex (Control4 DriverWorks, OS 3.x)
  Version: 0.2.0  (UNTESTED on real Composer/Director; Plex backend unverified; see docs/jellyfin.md)

  Server Type = Jellyfin: polls GET {Server URL}/Sessions, sends POST {Server URL}/Sessions/{SessionId}/Playing/{Cmd}.
  Server Type = Plex:     polls GET {Server URL}/status/sessions, sends GET {Server URL}/player/playback/{cmd}.
  Both backends publish the same driver variables, events and commands.
  The API key / Plex token is a plain STRING property (Composer cannot mask it). It is never written to the log.
  Plex artwork URLs contain the token, so the Artwork URL variable carries it too.
]]

local DRIVER_VERSION = "0.2.0"
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

local ITEM_VARIABLES = {
  "Now Playing Title", "Now Playing Subtitle", "Now Playing Summary", "Artist", "Year", "Media Type",
  "Position", "Position Seconds", "Runtime", "Runtime Seconds", "Client", "Device", "User",
  "Artwork URL", "Item Id",
}
local ALL_VARIABLES = { "Play State", "Session Id" }
for _, n in ipairs(ITEM_VARIABLES) do ALL_VARIABLES[#ALL_VARIABLES + 1] = n end

local state = {
  pollTimer = nil,
  watchdogTimer = nil,
  inflight = false,
  inflightSince = 0,
  lastOk = 0,
  authMode = "Authorization",   -- Jellyfin only: switches to "X-Emby-Token" if the first form gets 401/403
  activeSessionId = "",
  activeClientId = "",          -- Plex only: the player's machineIdentifier, used as the target client
  itemId = "",
  playState = "",
  runSec = 0,
  commandId = 0,                -- Plex only: increments on each playback command
}
local lastVars = {}
local lastProps = {}
local lastStatus = ""

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

local function setStatus(text)
  text = tostring(text or "")
  if text == lastStatus then return end
  lastStatus = text
  setProp("Status", text)
end

local function serverBase()
  local u = prop("Server URL")
  u = u:gsub("/+$", "")
  if u ~= "" and not string.find(u, "^https?://") then u = "http://" .. u end
  return u
end

local function token()
  return prop("API Key / Plex Token")
end

local function configured()
  return serverBase() ~= "" and token() ~= ""
end

local function serverType()
  if prop("Server Type") == "Plex" then return "Plex" end
  return "Jellyfin"
end

local function tlsOptions()
  if prop("Allow Self-Signed TLS") == "On" then
    return { ssl_verifypeer = 0, ssl_verifyhost = 0 }
  end
  return {}
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
-- Backends. Each one knows its own paths, auth headers, reply parsing and transport.
-- parse() returns a list of normalized sessions with the fields:
--   id, clientId, user, device, client, paused, posSec, runSec, itemId, mediaType,
--   title, subtitle, artist, year, artwork, activity
-- transport(action, session, offsetMs) returns method, path, extra headers, query.
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
  parse = function(data)
    local out = {}
    if type(data) ~= "table" then return out end
    for _, s in ipairs(data) do
      if type(s) == "table" and type(s.NowPlayingItem) == "table" then
        local item = s.NowPlayingItem
        local ps = type(s.PlayState) == "table" and s.PlayState or {}
        local title, subtitle, artist = jellyfinDescribe(item)
        local art = ""
        if type(item.ImageTags) == "table" and item.ImageTags.Primary and item.Id then
          art = serverBase() .. "/Items/" .. tostring(item.Id) .. "/Images/Primary?maxWidth=480&quality=90"
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
  parse = function(data)
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
        if thumb ~= "" then art = serverBase() .. thumb .. "?X-Plex-Token=" .. token() end
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
  transport = function(action, s, offsetMs)
    state.commandId = state.commandId + 1
    local q = "?commandID=" .. state.commandId
    if action == "Seek" then
      q = q .. "&offset=" .. string.format("%.0f", offsetMs)
    end
    return "GET", "/player/playback/" .. PLEX_COMMANDS[action],
      { ["X-Plex-Target-Client-Identifier"] = s.clientId }, q
  end,
}

local function backend()
  return BACKENDS[serverType()]
end

-- ============================================================================
-- HTTP. Handlers receive (data, httpCode, err). Jellyfin only: a 401/403 on the
-- first auth form is retried once with the other form (Authorization <-> X-Emby-Token).
-- ============================================================================
local function request(method, path, handler, extraHeaders, retried)
  local b = backend()
  local url = serverBase() .. path
  local opts = tlsOptions()
  local headers = b.headers(token(), state.authMode)
  for k, v in pairs(extraHeaders or {}) do headers[k] = v end
  debugLog(method .. " " .. path)

  local function onReply(_, data, code, _, err)
    code = tonumber(code) or 0
    if (code == 401 or code == 403) and not retried and b.canRetryAuth and state.authMode == "Authorization" then
      state.authMode = "X-Emby-Token"
      debugLog("auth rejected, retrying with X-Emby-Token form")
      request(method, path, handler, extraHeaders, true)
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

local function reportHttpError(code, err)
  if code == 401 or code == 403 then
    setStatus("Auth failed: check API Key / Plex Token")
  elseif code == 0 then
    setStatus("Cannot reach server: " .. tostring(err or "no response"))
  else
    setStatus("Server returned HTTP " .. tostring(code))
  end
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

-- Playing sessions beat paused ones; ties go to the most recent activity (Jellyfin only; ISO strings compare correctly).
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

-- Applies the chosen normalized session (or nil for nothing playing). Returns a short text for Status.
local function applySession(s)
  local prevState, prevItem = state.playState, state.itemId

  if s == nil then
    state.active = nil
    state.activeSessionId = ""
    state.activeClientId = ""
    state.itemId = ""
    state.runSec = 0
    state.playState = "Stopped"
    setVar("Play State", "Stopped")
    setVar("Session Id", "")
    clearItemVars()
    if prevState == "Playing" or prevState == "Paused" then
      fireEvent(EVENT_STATE_CHANGED)
      fireEvent(EVENT_PLAYBACK_STOPPED)
    end
    return "nothing playing"
  end

  local newState = s.paused and "Paused" or "Playing"
  state.active = s
  state.activeSessionId = s.id
  state.activeClientId = s.clientId
  state.itemId = s.itemId
  state.runSec = s.runSec
  state.playState = newState

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

  if newState ~= prevState then
    fireEvent(EVENT_STATE_CHANGED)
    if newState == "Playing" then fireEvent(EVENT_PLAYBACK_STARTED) end
  end
  if s.itemId ~= prevItem then fireEvent(EVENT_ITEM_CHANGED) end

  return newState .. ": " .. join(s.title, s.subtitle)
end

-- ============================================================================
-- Polling and watchdog
-- ============================================================================
local pollNow, watchdogTick   -- defined below (forward declarations for the timers)

local function pollSeconds()
  local n = tonumber(prop("Poll Interval Seconds")) or DEFAULT_POLL_SECONDS
  if n < 2 then n = 2 end
  if n > 60 then n = 60 end
  return n
end

local function schedulePoll(seconds)
  if state.pollTimer then pcall(function() state.pollTimer:Cancel() end) end
  state.pollTimer = C4:SetTimer(math.floor(seconds * 1000), function()
    state.pollTimer = nil
    pollNow()
  end)
end

local function armWatchdog()
  if state.watchdogTimer then pcall(function() state.watchdogTimer:Cancel() end) end
  state.watchdogTimer = C4:SetTimer(WATCHDOG_SECONDS * 1000, function()
    watchdogTick()
  end)
end

watchdogTick = function()
  if state.inflight and os.time() - state.inflightSince >= WATCHDOG_SECONDS then
    state.inflight = false
    setStatus("No reply from server within " .. WATCHDOG_SECONDS .. "s")
    debugLog("watchdog reset a stuck request")
    schedulePoll(pollSeconds())
  end
  armWatchdog()
end

local function onPoll(data, code, err)
  state.inflight = false
  if code >= 200 and code < 300 then
    local decoded, decodeErr = jsonDecode(data or "")
    if type(decoded) ~= "table" then
      setStatus("Unexpected reply from server")
      debugLog("decode error: " .. tostring(decodeErr))
    else
      state.lastOk = os.time()
      setStatus("Connected: " .. applySession(pickSession(backend().parse(decoded))))
    end
  else
    reportHttpError(code, err)
  end
  schedulePoll(pollSeconds())
end

pollNow = function()
  if not configured() then
    setStatus("Not configured: set Server URL and API Key / Plex Token")
    schedulePoll(RETRY_NOT_CONFIGURED_SECONDS)
    return
  end
  if state.inflight then return end
  state.inflight = true
  state.inflightSince = os.time()
  request("GET", backend().pollPath(), onPoll)
end

-- ============================================================================
-- Actions and commands
-- ============================================================================
local function testConnection()
  if not configured() then
    setStatus("Not configured: set Server URL and API Key / Plex Token")
    return
  end
  setStatus("Testing connection...")
  request("GET", backend().testPath(), function(data, code, err)
    if code >= 200 and code < 300 then
      local info = jsonDecode(data or "")
      if serverType() == "Plex" then
        local mc = type(info) == "table" and info.MediaContainer or {}
        setStatus("OK: Plex " .. tostring(type(mc) == "table" and mc.version or "server"))
      elseif type(info) == "table" then
        setProp("Server Name", tostring(info.ServerName or ""))
        setStatus("OK: " .. tostring(info.ServerName or "server") .. " " .. tostring(info.Version or ""))
      else
        setStatus("Connected, but the reply was not JSON")
      end
    else
      reportHttpError(code, err)
    end
  end)
end

local function sendTransport(action, offsetMs)
  local s = state.active
  if s == nil or s.id == "" or not string.find(s.id, "^[%w%-]+$") then
    setStatus("No active session to control")
    return
  end
  if serverType() == "Plex" and not string.find(s.clientId, "^[%w%-]+$") then
    setStatus("No Plex player to control")
    return
  end
  local method, path, extra, query = backend().transport(action, s, offsetMs or 0)
  request(method, path .. query, function(_, code, err)
    if code >= 200 and code < 300 then
      schedulePoll(0.5)
    else
      reportHttpError(code, err)
    end
  end, extra)
end

local function seekToPercent(params)
  local pct = nil
  if type(params) == "table" then
    pct = tonumber(params["Percent"] or params["PERCENT"] or params["percent"])
  end
  if not pct or pct < 0 or pct > 100 then
    setStatus("Seek needs Percent between 0 and 100")
    return
  end
  if state.runSec <= 0 then
    setStatus("Seek unavailable: runtime unknown")
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
  elseif key == "REFRESH_NOW" then pollNow()
  else debugLog("unknown command " .. key)
  end
end

-- ============================================================================
-- Driver lifecycle
-- ============================================================================
function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  ensureVariables()
  setStatus("Starting")
end

function OnDriverLateInit()
  state.authMode = "Authorization"
  armWatchdog()
  schedulePoll(1)
end

function OnDriverDestroyed()
  pcall(function() if state.pollTimer then state.pollTimer:Cancel() end end)
  pcall(function() if state.watchdogTimer then state.watchdogTimer:Cancel() end end)
end

function OnPropertyChanged(name)
  if name == "Server Type" then
    applySession(nil)
    state.authMode = "Authorization"
    schedulePoll(1)
  elseif name == "Server URL" or name == "API Key / Plex Token" or name == "Allow Self-Signed TLS" then
    state.authMode = "Authorization"
    schedulePoll(1)
  elseif name == "Poll Interval Seconds" or name == "Target User Or Device Filter" then
    schedulePoll(1)
  end
end
