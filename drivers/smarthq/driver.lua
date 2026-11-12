--[[
  SmartHQ Bridge (Control4 DriverWorks, OS 3.4.x)
  Version: 0.2.1  (fixes proxy declaration and icon path; 0.2.0 adds hood light control; UNTESTED on real Composer/Director; see docs/smarthq.md)

  Client for the LAN HTTP bridge on liesa:
    GET {base}/health
    GET {base}/appliances
    GET {base}/appliances/{id}/state
  The only control is POST {base}/appliances/{hood}/command for the hood light
  (v0.2.0). Oven and dishwasher stay read-only.
  Oven field names come from a real reply. Dishwasher names are NOT confirmed
  (no dishwasher was online when this was written), so they are matched from a list of guesses.
]]

local DRIVER_VERSION = "0.2.1"
local HOOD_LIGHT_PROXY = 5001
local DEFAULT_HOST = "172.21.1.157"
local DEFAULT_PORT = "8789"
local DEFAULT_POLL_SECONDS = 60
local MIN_POLL_SECONDS = 30
local INFLIGHT_TIMEOUT_SECONDS = 30

local EVENT_OVEN_PREHEATED = 1
local EVENT_OVEN_TIMER_DONE = 2
local EVENT_DISHWASHER_DONE = 3
local EVENT_BRIDGE_UNREACHABLE = 4

local ALL_VARIABLES = {
  "Oven State", "Oven Temperature", "Oven Timer Remaining",
  "Dishwasher State", "Dishwasher Time Remaining", "Hood Light",
}

-- Dishwasher key guesses (UNCONFIRMED). The first key present in the reply wins.
local DISH_STATE_KEYS = { "dishwasher_cycle_state", "cycle_state", "dishwasher_state" }
local DISH_TIME_KEYS = { "dishwasher_time_remaining_s", "cycle_time_remaining_s", "time_remaining_s" }

-- Cook states that mean "not running". Matched as substrings of the upper-cased state.
local IDLE_WORDS = { "DASH", "OFF", "IDLE", "DONE", "NONE", "NO_MODE", "READY" }

local state = {
  pollTimer = nil,
  inflight = false,
  inflightSince = 0,
  reachable = nil,
  ovenPreheating = nil,
  ovenTimer = nil,
  dishActive = nil,
  dishDone = nil,
}
local lastProps = {}
local lastVars = {}
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

local function setVar(name, value)
  value = tostring(value or "")
  if lastVars[name] == value then return end
  lastVars[name] = value
  pcall(function() C4:SetVariable(name, value) end)
end

local function setStatus(text)
  text = tostring(text or "")
  if text == lastStatus then return end
  lastStatus = text
  setProp("Status", text)
end

local function logMsg(msg)
  local mode = prop("Log Mode")
  if mode == "Print" then
    pcall(function() print("[SmartHQ] " .. tostring(msg)) end)
  elseif mode == "Log" then
    pcall(function() C4:ErrorLog("[SmartHQ] " .. tostring(msg)) end)
  end
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
-- Value helpers
-- ============================================================================
local function pick(t, ...)
  if type(t) ~= "table" then return nil end
  for i = 1, select("#", ...) do
    local v = t[select(i, ...)]
    if v ~= nil and v ~= "" then return v end
  end
  return nil
end

local function num(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) end
  return nil
end

local function isTrue(v)
  return v == true or v == 1 or v == "true"
end

local function isActiveState(s)
  if s == nil or s == "" then return false end
  local u = string.upper(tostring(s))
  for _, w in ipairs(IDLE_WORDS) do
    if string.find(u, w, 1, true) then return false end
  end
  return true
end

local function formatSeconds(sec)
  sec = math.floor(sec)
  if sec <= 0 then return "0:00" end
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local function stamp()
  return os.date("%H:%M:%S")
end

-- ============================================================================
-- HTTP
-- ============================================================================
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

local function setReachable(ok, text)
  if ok == false and state.reachable ~= false then
    fireEvent(EVENT_BRIDGE_UNREACHABLE)
  end
  state.reachable = ok
  setStatus(text)
end

-- ============================================================================
-- Appliance state
-- ============================================================================
-- Oven fields are CONFIRMED from a real reply (upper cavity). Lower cavity fields are logged only.
local function applyOven(s)
  local cook = pick(s, "upper_cook_state")
  local temp = num(pick(s, "upper_current_temp_f"))
  local timer = num(pick(s, "upper_timer_remaining_s"))
  local preheat = isTrue(s.upper_preheating)
  if cook == nil and temp == nil and timer == nil then
    logMsg("oven reply has none of the expected upper_* fields")
    return
  end
  cook = cook or ""
  local active = isActiveState(cook)

  setVar("Oven State", cook)
  setVar("Oven Temperature", temp and (tostring(temp) .. " F") or "")
  setVar("Oven Timer Remaining", timer and formatSeconds(timer) or "")

  -- Preheated: preheating flag drops while the oven is in an active (baking) state.
  if state.ovenPreheating == true and preheat == false and active then
    fireEvent(EVENT_OVEN_PREHEATED)
  end
  -- Timer done: remaining time falls from above zero to zero while the oven is active.
  if state.ovenTimer and state.ovenTimer > 0 and timer == 0 and active then
    fireEvent(EVENT_OVEN_TIMER_DONE)
  end
  state.ovenPreheating = preheat
  state.ovenTimer = timer
end

-- Dishwasher field names are NOT confirmed. Guessed keys, plus a cycle_done flag if the bridge sends one.
local function applyDishwasher(s)
  local st = pick(s, unpack(DISH_STATE_KEYS))
  local timeLeft = num(pick(s, unpack(DISH_TIME_KEYS)))
  local doneRaw = s.cycle_done
  if st == nil and timeLeft == nil and doneRaw == nil then
    logMsg("dishwasher reply has none of the expected fields")
    return
  end
  st = st or ""
  local active = isActiveState(st)
  local done = isTrue(doneRaw)

  setVar("Dishwasher State", st)
  setVar("Dishwasher Time Remaining", timeLeft and formatSeconds(timeLeft) or "")

  local finished = false
  if state.dishActive == true and not active then finished = true end
  if state.dishDone == false and done then finished = true end
  if finished then fireEvent(EVENT_DISHWASHER_DONE) end
  state.dishActive = active
  state.dishDone = done
end

local function readOven(id, done)
  if id == "" then
    done()
    return
  end
  httpGet("/appliances/" .. id .. "/state", function(data, code, err)
    if code == 200 then
      local s = jsonDecode(data or "")
      if type(s) == "table" then
        applyOven(s)
      else
        logMsg("oven reply was not JSON")
      end
    else
      logMsg("oven state HTTP " .. tostring(code) .. " " .. tostring(err or ""))
    end
    done()
  end)
end

local function readDishwasher(id, done)
  if id == "" then
    done()
    return
  end
  httpGet("/appliances/" .. id .. "/state", function(data, code, err)
    if code == 200 then
      local s = jsonDecode(data or "")
      if type(s) == "table" then
        applyDishwasher(s)
      else
        logMsg("dishwasher reply was not JSON")
      end
    else
      logMsg("dishwasher state HTTP " .. tostring(code) .. " " .. tostring(err or ""))
    end
    done()
  end)
end

-- ============================================================================
-- ============================================================================
-- Hood light (v0.2.0, UNTESTED). Only the light is writable; see docs/smarthq.md.
-- ============================================================================
local hoodOn = nil

local function applyHood(s)
  local level = tostring(s.light_level or "")
  setVar("Hood Light", level)
  local on = (level ~= "" and level ~= "OFF")
  if on ~= hoodOn then
    hoodOn = on
    pcall(function() C4:SendToProxy(HOOD_LIGHT_PROXY, on and "ON" or "OFF", {}, "NOTIFY") end)
  end
end

local function readHood(id, done)
  if id == "" then done(); return end
  httpGet("/appliances/" .. id .. "/state", function(data, code)
    if code == 200 then
      local s = jsonDecode(data or "")
      if type(s) == "table" then applyHood(s) end
    end
    done()
  end)
end

-- level is "off", "dim" or "on" (on sends HIGH on the bridge).
local function hoodCommand(level)
  local id = prop("Hood Appliance ID")
  if id == "" then setStatus("Set Hood Appliance ID first"); return end
  local body = '{"action":"light","level":"' .. level .. '"}'
  local ok, perr = pcall(function()
    C4:urlPost(baseUrl() .. "/appliances/" .. id .. "/command", body,
      { ["Content-Type"] = "application/json" }, false,
      function(_, data, code, _, err)
        local n = tonumber(code) or 0
        if n ~= 200 then
          setStatus("Hood light failed: HTTP " .. tostring(n) .. " " .. tostring(err or ""))
          return
        end
        local s = jsonDecode(data or "")
        if type(s) == "table" then applyHood(s) end
      end, {})
  end)
  if not ok then setStatus("Hood light failed: " .. tostring(perr)) end
end

-- Light proxy commands from Navigator / programming.
function ReceivedFromProxy(idBinding, strCommand, tParams)
  if idBinding ~= HOOD_LIGHT_PROXY then return end
  if strCommand == "ON" then
    hoodCommand("on")
  elseif strCommand == "OFF" then
    hoodCommand("off")
  elseif strCommand == "SET_LEVEL" then
    local lvl = tonumber((tParams or {}).LEVEL) or 0
    if lvl <= 0 then hoodCommand("off")
    elseif lvl <= 50 then hoodCommand("dim")
    else hoodCommand("on") end
  end
end

-- Polling
-- ============================================================================
local function poll()
  if state.inflight and os.time() - state.inflightSince < INFLIGHT_TIMEOUT_SECONDS then
    return
  end
  state.inflight = true
  state.inflightSince = os.time()
  httpGet("/health", function(data, code, err)
    if code == 200 then
      local h = jsonDecode(data or "")
      local age = type(h) == "table" and num(h.last_success_age_s) or nil
      local text = "Connected, polled " .. stamp()
      if age then text = text .. ", bridge data age " .. tostring(age) .. " s" end
      setReachable(true, text)
      readOven(prop("Oven Appliance ID"), function()
        readDishwasher(prop("Dishwasher Appliance ID"), function()
          readHood(prop("Hood Appliance ID"), function()
            state.inflight = false
          end)
        end)
      end)
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
      state.inflight = false
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

-- Lists the bridge appliances. Always logs id, type and name, and fills Discovered Appliances.
local function discover()
  httpGet("/appliances", function(data, code, err)
    if code ~= 200 then
      setStatus("Discover failed: HTTP " .. tostring(code))
      return
    end
    local list = jsonDecode(data or "")
    if type(list) ~= "table" then
      setStatus("Discover failed: reply was not JSON")
      return
    end
    local lines = {}
    for _, a in ipairs(list) do
      if type(a) == "table" then
        local line = tostring(a.id) .. " | " .. tostring(a.type) .. " | " .. tostring(a.name)
          .. " | online=" .. tostring(a.online)
        lines[#lines + 1] = line
        pcall(function() C4:ErrorLog("[SmartHQ] appliance " .. line) end)
      end
    end
    setProp("Discovered Appliances", table.concat(lines, "\n"))
    setStatus("Discovered " .. #lines .. " appliance(s)")
  end)
end

-- ============================================================================
-- Driver callbacks
-- ============================================================================
function ExecuteCommand(strCommand, tParams)
  if strCommand == "DISCOVER" then
    discover()
  elseif strCommand == "REFRESH_NOW" then
    poll()
  elseif strCommand == "HOOD_LIGHT_ON" then
    hoodCommand("on")
  elseif strCommand == "HOOD_LIGHT_OFF" then
    hoodCommand("off")
  end
end

function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  for _, n in ipairs(ALL_VARIABLES) do
    pcall(function() C4:AddVariable(n, "", "STRING") end)
  end
  setStatus("Starting")
end

function OnDriverLateInit()
  schedulePoll(1)
end

function OnDriverDestroyed()
  pcall(function() if state.pollTimer then state.pollTimer:Cancel() end end)
end

function OnPropertyChanged(name)
  if name == "Host" or name == "Port" or name == "Oven Appliance ID" or name == "Dishwasher Appliance ID" or name == "Hood Appliance ID" then
    state.inflight = false
    schedulePoll(1)
  elseif name == "Poll Interval" then
    schedulePoll(pollSeconds())
  end
end
