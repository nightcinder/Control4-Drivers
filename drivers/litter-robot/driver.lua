--[[
  Whisker Litter-Robot 4 cat visit counter via LAN HTTP bridge (Control4 DriverWorks, OS 3.4.x)
  Version: 1.0.2  (UNTESTED on real Composer/Director)

  Polls GET /status on litter-bridge every Poll Interval seconds (5 s minimum).
  The bridge counts cat visits. When visits_since_reset >= Visits Before Clean AND the box is
  ready (not cat_in_box) AND Settle Minutes have passed since the last visit, the driver fires
  Visit Threshold Reached once and POSTs /reset-visits. Event 2 fires once; a failed reset is
  retried without firing the event again.
]]

local DRIVER_VERSION = "1.0.2"
local DEFAULT_HOST = "172.21.1.157"
local DEFAULT_PORT = "8793"
local DEFAULT_POLL = 15
local MIN_POLL = 5
local RETRY_SECONDS = 30
local COMMAND_RECHECK_SECONDS = 3
local HTTP_TIMEOUT_SECONDS = 10

local EVT_VISIT = 1
local EVT_THRESHOLD = 2
local EVT_DRAWER_FULL = 3
local EVT_UNREACHABLE = 4

local EVENT_NAMES = {
  [EVT_VISIT] = "Cat Visit Detected",
  [EVT_THRESHOLD] = "Visit Threshold Reached",
  [EVT_DRAWER_FULL] = "Drawer Full",
  [EVT_UNREACHABLE] = "Bridge Unreachable",
}

local VAR_VISITS = "VISITS_SINCE_CLEAN"
local VAR_STATUS = "ROBOT_STATUS"

local state = {
  baselined = false,      -- first good poll sets the visit baseline without firing events
  visits = 0,
  lastVisitTs = nil,
  status = "",
  catInBox = false,
  drawerFull = false,
  unreachable = false,
  busy = false,
  pollTimer = nil,
  thresholdFired = false, -- event 2 has fired; waiting for a successful reset
  resetPending = false,
}

-- ============================================================================
-- Helpers
-- ============================================================================
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function prop(name)
  local ok, v = pcall(function() return Properties[name] end)
  if not ok then return "" end
  return trim(v)
end

local function setProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value or "")) end)
end

local function setVar(name, value)
  pcall(function() C4:SetVariable(name, tostring(value or "")) end)
end

local function fire(id)
  local name = EVENT_NAMES[id] or tostring(id)
  local ok, err = pcall(function() C4:FireEvent(name) end)
  if not ok then
    logmsg("FireEvent(" .. name .. ") failed: " .. tostring(err))
  end
end

local function logmsg(msg)
  local mode = prop("Log Mode")
  local line = "[litter-robot " .. DRIVER_VERSION .. "] " .. msg
  if mode == "Print" or mode == "Print and Log" then
    print(line)
  end
  if mode == "Log" or mode == "Print and Log" then
    pcall(function() C4:ErrorLog(line) end)
  end
end

local function bridgeBase()
  local host = prop("Bridge Host")
  if host == "" then host = DEFAULT_HOST end
  local port = tonumber(prop("Bridge Port")) or tonumber(DEFAULT_PORT)
  return "http://" .. host .. ":" .. tostring(port)
end

local function pollSeconds()
  local s = tonumber(prop("Poll Interval")) or DEFAULT_POLL
  if s < MIN_POLL then s = MIN_POLL end
  return s
end

-- Flat JSON field readers for the bridge's /status body.
local function strField(body, key)
  return string.match(body, '"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function numField(body, key)
  local s = string.match(body, '"' .. key .. '"%s*:%s*(-?[%d%.]+)')
  return tonumber(s)
end

local function boolField(body, key)
  return string.match(body, '"' .. key .. '"%s*:%s*true') ~= nil
end

-- ============================================================================
-- HTTP
-- ============================================================================
local function httpRequest(method, path, body, cb)
  local url = bridgeBase() .. path
  local headers = { ["Accept"] = "application/json" }

  local function onReply(_, data, code, _, err)
    code = tonumber(code) or 0
    local ok = (code >= 200 and code < 300)
    cb(ok, data, code, err)
  end

  pcall(function() C4:urlSetTimeout(HTTP_TIMEOUT_SECONDS) end)

  local ok, perr = pcall(function()
    if method == "POST" then
      headers["Content-Type"] = "application/json"
      C4:urlPost(url, body or "", headers, false, onReply)
    else
      C4:urlGet(url, headers, false, onReply)
    end
  end)
  if not ok then
    cb(false, nil, 0, tostring(perr))
  end
end

-- ============================================================================
-- Status and threshold
-- ============================================================================
local function setUnreachable(reason)
  setProp("Status", "Bridge unreachable")
  setProp("Last Error", tostring(reason))
  if not state.unreachable then
    state.unreachable = true
    logmsg("bridge unreachable: " .. tostring(reason))
    fire(EVT_UNREACHABLE)
  end
end

local sendReset

local function checkThreshold()
  if not state.baselined then return end
  if state.thresholdFired then
    if not state.resetPending then sendReset() end
    return
  end
  local need = tonumber(prop("Visits Before Clean")) or 2
  if state.visits < need then return end
  if state.catInBox or (state.status ~= "ready" and state.status ~= "drawer_full") then return end
  local settle = (tonumber(prop("Settle Minutes")) or 10) * 60
  if os.time() - (state.lastVisitTs or 0) < settle then return end

  state.thresholdFired = true
  logmsg("visit threshold reached: " .. tostring(state.visits) .. " visits")
  fire(EVT_THRESHOLD)
  sendReset()
end

function sendReset()
  if state.resetPending then return end
  state.resetPending = true
  httpRequest("POST", "/reset-visits", "", function(ok, _, code, err)
    state.resetPending = false
    if ok then
      state.thresholdFired = false
      state.visits = 0
      setProp("Visits Since Clean", "0")
      setVar(VAR_VISITS, "0")
      logmsg("visit counter reset")
    else
      local reason = err
      if reason == nil or reason == "" then reason = "HTTP " .. tostring(code) end
      setProp("Last Error", "reset failed: " .. tostring(reason))
      logmsg("reset failed: " .. tostring(reason))
    end
  end)
end

local function applyStatus(body)
  if not boolField(body, "ok") then
    local err = strField(body, "error") or "bridge reports not ok"
    setProp("Status", "Bridge error")
    setProp("Last Error", err)
    logmsg("bridge not ok: " .. err)
    return
  end

  local visits = numField(body, "visits_since_reset") or 0
  local status = strField(body, "status") or ""
  local catInBox = boolField(body, "cat_in_box")
  local drawerFull = boolField(body, "drawer_full")
  local drawerPct = numField(body, "waste_drawer_pct")

  if state.baselined and visits > state.visits then
    for _ = 1, (visits - state.visits) do fire(EVT_VISIT) end
    logmsg("cat visit detected, total " .. tostring(visits))
  end
  if state.baselined and drawerFull and not state.drawerFull then
    logmsg("drawer full")
    fire(EVT_DRAWER_FULL)
  end

  state.baselined = true
  state.visits = visits
  state.lastVisitTs = numField(body, "last_visit_ts")
  state.status = status
  state.catInBox = catInBox
  state.drawerFull = drawerFull
  state.unreachable = false

  setProp("Status", "Connected")
  setProp("Last Error", "")
  setProp("Robot Status", status)
  setProp("Visits Since Clean", tostring(visits))
  setProp("Drawer Level", drawerPct and string.format("%.1f%%", drawerPct) or "n/a")
  setVar(VAR_VISITS, tostring(visits))
  setVar(VAR_STATUS, status)

  checkThreshold()
end

-- ============================================================================
-- Polling
-- ============================================================================
local poll

local function schedule(seconds)
  if state.pollTimer then
    pcall(function() state.pollTimer:Cancel() end)
    state.pollTimer = nil
  end
  state.pollTimer = C4:SetTimer(math.floor(seconds * 1000), function()
    state.pollTimer = nil
    poll()
  end)
end

function poll()
  if state.busy then
    schedule(COMMAND_RECHECK_SECONDS)
    return
  end
  state.busy = true
  httpRequest("GET", "/status", nil, function(ok, data, code, err)
    state.busy = false
    if ok and data and data ~= "" then
      applyStatus(data)
      schedule(pollSeconds())
    else
      local reason = err
      if reason == nil or reason == "" then reason = "HTTP " .. tostring(code) end
      setUnreachable(reason)
      schedule(RETRY_SECONDS)
    end
  end)
end

-- ============================================================================
-- Commands
-- ============================================================================
function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "RESET_VISITS" then
    logmsg("manual reset requested")
    sendReset()
  elseif strCommand == "REFRESH" then
    schedule(1)
  elseif strCommand == "FIRE_TEST_THRESHOLD" then
    logmsg("test threshold fired (bridge counter unchanged)")
    fire(EVT_THRESHOLD)
  end
end

-- ============================================================================
-- Driver lifecycle
-- ============================================================================
local function ensureVariables()
  local defs = {
    { VAR_VISITS, "NUMBER" },
    { VAR_STATUS, "STRING" },
  }
  for _, d in ipairs(defs) do
    pcall(function() C4:AddVariable(d[1], "", d[2], true, false) end)
  end
end

function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  ensureVariables()
  setProp("Status", "Starting")
end

function OnDriverLateInit()
  schedule(1)
end

function OnDriverDestroyed()
  if state.pollTimer then
    pcall(function() state.pollTimer:Cancel() end)
    state.pollTimer = nil
  end
end

function OnPropertyChanged(name)
  if name == "Bridge Host" or name == "Bridge Port" or name == "Poll Interval" then
    state.unreachable = false
    schedule(1)
  end
end
