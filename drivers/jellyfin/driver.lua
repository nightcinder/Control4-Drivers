--[[
  Jellyfin Now Playing (Control4 DriverWorks, OS 3.x)
  Version: 0.1.0  (UNTESTED on real Composer/Director; see docs/jellyfin.md)

  Polls GET {Server URL}/Sessions and publishes the chosen session's now-playing data as driver variables.
  Transport commands go to POST {Server URL}/Sessions/{SessionId}/Playing/{Command}.
  The API key is a plain STRING property (Composer cannot mask it). It is never written to the log.
  A future Plex driver should reuse the same variable names (see docs/jellyfin.md).
]]

local DRIVER_VERSION = "0.1.0"
local TICKS_PER_SECOND = 10000000
local WATCHDOG_SECONDS = 20
local DEFAULT_POLL_SECONDS = 4
local RETRY_NOT_CONFIGURED_SECONDS = 30
local ACTIVE_WITHIN_SECONDS = 960

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
  authHeaderMode = "Authorization",   -- switches to "X-Emby-Token" if the first form gets 401/403
  activeSessionId = "",
  itemId = "",
  playState = "",
  runtimeTicks = 0,
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
    pcall(function() print("[Jellyfin] " .. tostring(msg)) end)
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

local function configured()
  return serverBase() ~= "" and prop("API Key") ~= ""
end

local function authHeaders()
  local key = prop("API Key")
  local h = { ["Accept"] = "application/json" }
  if state.authHeaderMode == "X-Emby-Token" then
    h["X-Emby-Token"] = key
  else
    h["Authorization"] = 'MediaBrowser Token="' .. key .. '"'
  end
  return h
end

local function tlsOptions()
  if prop("Allow Self-Signed TLS") == "On" then
    return { ssl_verifypeer = 0, ssl_verifyhost = 0 }
  end
  return {}
end

-- ============================================================================
-- HTTP. Handlers receive (data, httpCode, err). A 401/403 on the first auth form
-- is retried once with the other form (Authorization <-> X-Emby-Token).
-- ============================================================================
local function request(method, path, handler, retried)
  local url = serverBase() .. path
  local opts = tlsOptions()
  local headers = authHeaders()
  debugLog(method .. " " .. path)

  local function onReply(_, data, code, _, err)
    code = tonumber(code) or 0
    if (code == 401 or code == 403) and not retried and state.authHeaderMode == "Authorization" then
      state.authHeaderMode = "X-Emby-Token"
      debugLog("auth rejected, retrying with X-Emby-Token form")
      request(method, path, handler, true)
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
-- Formatting and session selection
-- ============================================================================
local function fmtTime(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- Returns title, subtitle, artist for the item shown on the TV.
local function describeItem(item)
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

local function artworkUrl(item)
  if type(item.ImageTags) == "table" and item.ImageTags.Primary and item.Id then
    return serverBase() .. "/Items/" .. tostring(item.Id) .. "/Images/Primary?maxWidth=480&quality=90"
  end
  return ""
end

local function matchesFilter(s, filter)
  if filter == "" then return true end
  local f = string.lower(filter)
  local user = string.lower(tostring(s.UserName or ""))
  local device = string.lower(tostring(s.DeviceName or "") .. " " .. tostring(s.Client or ""))
  return string.find(user, f, 1, true) ~= nil or string.find(device, f, 1, true) ~= nil
end

-- Playing sessions beat paused ones; ties go to the most recent LastActivityDate (ISO strings compare correctly).
local function pickSession(sessions)
  local filter = prop("Target User Or Device Filter")
  local best, bestPlaying, bestActivity = nil, false, ""
  for _, s in ipairs(sessions) do
    if type(s) == "table" and type(s.NowPlayingItem) == "table" and matchesFilter(s, filter) then
      local playing = not (type(s.PlayState) == "table" and s.PlayState.IsPaused == true)
      local activity = tostring(s.LastActivityDate or "")
      if best == nil or (playing and not bestPlaying) or (playing == bestPlaying and activity > bestActivity) then
        best, bestPlaying, bestActivity = s, playing, activity
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

-- Applies one /Sessions reply. Returns a short text for the Status property.
local function applySessions(sessions)
  local s = pickSession(sessions)
  local prevState, prevItem = state.playState, state.itemId

  if s == nil then
    state.activeSessionId = ""
    state.itemId = ""
    state.runtimeTicks = 0
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

  local item = s.NowPlayingItem
  local ps = type(s.PlayState) == "table" and s.PlayState or {}
  local newState = (ps.IsPaused == true) and "Paused" or "Playing"
  local title, subtitle, artist = describeItem(item)
  local runTicks = tonumber(item.RunTimeTicks) or 0
  local posSec = (tonumber(ps.PositionTicks) or 0) / TICKS_PER_SECOND
  local itemId = tostring(item.Id or "")

  state.activeSessionId = tostring(s.Id or "")
  state.itemId = itemId
  state.runtimeTicks = runTicks
  state.playState = newState

  setVar("Play State", newState)
  setVar("Session Id", state.activeSessionId)
  setVar("Now Playing Title", title)
  setVar("Now Playing Subtitle", subtitle)
  if title ~= "" and subtitle ~= "" then
    setVar("Now Playing Summary", title .. " - " .. subtitle)
  else
    setVar("Now Playing Summary", title)
  end
  setVar("Artist", artist)
  setVar("Year", item.ProductionYear or "")
  setVar("Media Type", item.Type or "")
  setVar("Position", fmtTime(posSec))
  setVar("Position Seconds", math.floor(posSec))
  setVar("Runtime", fmtTime(runTicks / TICKS_PER_SECOND))
  setVar("Runtime Seconds", math.floor(runTicks / TICKS_PER_SECOND))
  setVar("Client", s.Client or "")
  setVar("Device", s.DeviceName or "")
  setVar("User", s.UserName or "")
  setVar("Item Id", itemId)
  setVar("Artwork URL", artworkUrl(item))

  if newState ~= prevState then
    fireEvent(EVENT_STATE_CHANGED)
    if newState == "Playing" then fireEvent(EVENT_PLAYBACK_STARTED) end
  end
  if itemId ~= prevItem then fireEvent(EVENT_ITEM_CHANGED) end

  local text = title
  if subtitle ~= "" then text = text .. " - " .. subtitle end
  return newState .. ": " .. text
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

local function reportHttpError(code, err)
  if code == 401 or code == 403 then
    setStatus("Auth failed: check API Key")
  elseif code == 0 then
    setStatus("Cannot reach server: " .. tostring(err or "no response"))
  else
    setStatus("Server returned HTTP " .. tostring(code))
  end
end

local function onSessions(data, code, err)
  state.inflight = false
  if code >= 200 and code < 300 then
    local sessions, decodeErr = jsonDecode(data or "")
    if type(sessions) ~= "table" then
      setStatus("Unexpected reply from server")
      debugLog("decode error: " .. tostring(decodeErr))
    else
      state.lastOk = os.time()
      setStatus("Connected: " .. applySessions(sessions))
    end
  else
    reportHttpError(code, err)
  end
  schedulePoll(pollSeconds())
end

pollNow = function()
  if not configured() then
    setStatus("Not configured: set Server URL and API Key")
    schedulePoll(RETRY_NOT_CONFIGURED_SECONDS)
    return
  end
  if state.inflight then return end
  state.inflight = true
  state.inflightSince = os.time()
  request("GET", "/Sessions?activeWithinSeconds=" .. ACTIVE_WITHIN_SECONDS, onSessions)
end

-- ============================================================================
-- Actions and commands
-- ============================================================================
local function testConnection()
  if not configured() then
    setStatus("Not configured: set Server URL and API Key")
    return
  end
  setStatus("Testing connection...")
  request("GET", "/System/Info", function(data, code, err)
    if code >= 200 and code < 300 then
      local info = jsonDecode(data or "")
      if type(info) == "table" then
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

local function sendTransport(command, query)
  local sid = state.activeSessionId
  if sid == "" or not string.find(sid, "^[%w%-]+$") then
    setStatus("No active session to control")
    return
  end
  request("POST", "/Sessions/" .. sid .. "/Playing/" .. command .. (query or ""), function(_, code, err)
    if code >= 200 and code < 300 then
      schedulePoll(0.5)
    else
      reportHttpError(code, err)
    end
  end)
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
  if state.runtimeTicks <= 0 then
    setStatus("Seek unavailable: runtime unknown")
    return
  end
  local ticks = math.floor(state.runtimeTicks * pct / 100)
  sendTransport("Seek", "?seekPositionTicks=" .. string.format("%.0f", ticks))
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
  state.authHeaderMode = "Authorization"
  armWatchdog()
  schedulePoll(1)
end

function OnDriverDestroyed()
  pcall(function() if state.pollTimer then state.pollTimer:Cancel() end end)
  pcall(function() if state.watchdogTimer then state.watchdogTimer:Cancel() end end)
end

function OnPropertyChanged(name)
  if name == "Server URL" or name == "API Key" or name == "Allow Self-Signed TLS" then
    state.authHeaderMode = "Authorization"
    schedulePoll(1)
  elseif name == "Poll Interval Seconds" or name == "Target User Or Device Filter" then
    schedulePoll(1)
  end
end
