-- UniFi PDU Controls (parent, file UniFi_Controller) driver for Control4 OS 3.4.x. Version 1.0.12 (UNTESTED on hardware).
-- Logs in to a UniFi controller, polls power outlets (USP PDU Pro, USP Plug), serves UniFi Outlet child
-- drivers over a connection, and shows a uibutton web view page listing every outlet with tap-to-toggle.
-- UNVERIFIED: API paths, outlet JSON fields, PUT body, cookie/CSRF handling, self-signed certificate
-- handling (TLS_OPTIONS key names). Raw responses are logged at Debug level (secrets masked).

local DRIVER_VERSION = "1.0.12"
-- The UniFi console uses a self-signed certificate that Control4 cannot verify, so certificate checks are
-- turned off for this controller only. Passed as the 6th argument (options) of C4:urlGet / urlPost / urlPut
-- (signature confirmed from the Snap One drivers-common-public url.lua). The key names are curl-style and
-- UNVERIFIED on OS 3.4; if verification still fails, check these keys first.
local TLS_OPTIONS = { ssl_verifypeer = 0, ssl_verifyhost = 0 }
local PAGE_FILE = "outlets4.html"   -- renamed every page release (Navigator caches controller:// pages)
local PAGE_BUILD = "4"              -- must match the page's PAGE_BUILD and web_view_url in driver.xml
local UI_BINDING = 5001
local CONTROLLER_BINDING = 1        -- child-facing connection on this driver
local MAX_UI_OUTLETS = 32

local g_mode = nil          -- "unifi_os" or "legacy" after a good login
local g_prefix = ""         -- "/proxy/network" on UniFi OS, "" on legacy
local g_cookies = {}        -- name -> value, only TOKEN / unifises / csrf_token
local g_csrf = nil
local g_loggedIn = false
local g_loginInFlight = false
local g_loginWaiters = {}
local g_outlets = {}        -- ordered list of outlet records
local g_outletByKey = {}; local g_devWatts = {}
local g_raw = {}            -- devId -> { id, name, overrides = array used as the PUT base, source }
local g_children = {}       -- child device id -> outlet key
local g_writeQueue = {}
local g_writeBusy = false
local g_loginWatch = nil
local g_timer = nil          -- keeps a reference so Lua does not garbage-collect the timer
local g_gen = 0             -- poll timer generation
local g_uiSeq = 0
local g_status = "Not configured"
local g_clientNames = {}    -- lowercase MAC -> alias or hostname, from rest/user
local g_clientsAt = nil     -- os.time() of the last client fetch (throttle: 10 minutes)

local function prop(name) return (Properties and Properties[name]) or "" end

local function logv(msg, debugOnly)
  local mode = prop("Log Mode")
  if mode == "Off" or mode == "" then return end
  if debugOnly and mode ~= "Debug" then return end
  local s = "[UniFi] " .. tostring(msg)
  print(s)
  pcall(function() C4:DebugLog(s) end)
end

-- Removes the password and session values from any text before it is logged.
local function plainReplace(s, needle, rep)
  if needle == nil or needle == "" then return s end
  local out, i = "", 1
  while true do
    local a, b = string.find(s, needle, i, true)
    if not a then return out .. string.sub(s, i) end
    out = out .. string.sub(s, i, a - 1) .. rep
    i = b + 1
  end
end

local function mask(text)
  text = tostring(text or "")
  text = plainReplace(text, prop("Password"), "***")
  for _, v in pairs(g_cookies) do text = plainReplace(text, v, "***") end
  if g_csrf then text = plainReplace(text, g_csrf, "***") end
  return text
end

local function setStatus(text)
  g_status = text
  pcall(function() C4:UpdateProperty("Connection Status", text) end)
end

-- ============================================================================
-- Minimal JSON (self-contained so the package has no external library)
-- ============================================================================
local function jsonDecode(s)
  local pos = 1
  local parseValue
  local function ws() pos = string.find(s, "[^ \t\r\n]", pos) or (#s + 1) end
  local function parseString()
    pos = pos + 1
    local out = {}
    while true do
      local e = string.find(s, '["\\]', pos)
      if not e then error("unterminated string") end
      out[#out + 1] = string.sub(s, pos, e - 1)
      if string.sub(s, e, e) == '"' then pos = e + 1; break end
      local n = string.sub(s, e + 1, e + 1)
      if n == "u" then
        local code = tonumber(string.sub(s, e + 2, e + 5), 16) or 63
        out[#out + 1] = code < 128 and string.char(code) or "?"
        pos = e + 6
      else
        local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
        out[#out + 1] = map[n] or n
        pos = e + 2
      end
    end
    return table.concat(out)
  end
  parseValue = function()
    ws()
    local c = string.sub(s, pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      ws()
      if string.sub(s, pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        ws()
        local k = parseString()
        ws(); pos = pos + 1          -- skip ':'
        obj[k] = parseValue()
        ws()
        local d = string.sub(s, pos, pos); pos = pos + 1
        if d == "}" then break end
      end
      return obj
    elseif c == "[" then
      pos = pos + 1
      local arr, n = {}, 0
      ws()
      if string.sub(s, pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        n = n + 1
        arr[n] = parseValue()
        ws()
        local d = string.sub(s, pos, pos); pos = pos + 1
        if d == "]" then break end
      end
      return arr
    elseif c == '"' then
      return parseString()
    elseif string.sub(s, pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif string.sub(s, pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif string.sub(s, pos, pos + 3) == "null" then pos = pos + 4; return nil
    end
    local num = string.match(s, "^-?%d+%.?%d*[eE][-+]?%d+", pos) or string.match(s, "^-?%d+%.?%d*", pos)
    if not num then error("bad JSON at " .. pos) end
    pos = pos + #num
    return tonumber(num)
  end
  local ok, result = pcall(parseValue)
  if ok then return result end
  return nil
end

local function jsonEncode(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then return string.format("%.14g", v) end
  if t == "string" then
    return '"' .. string.gsub(v, '[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == "\\" then return "\\\\" end
      if c == "\n" then return "\\n" end
      return string.format("\\u%04x", string.byte(c))
    end) .. '"'
  end
  if t == "table" then
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n == #v then
      local parts = {}
      for i = 1, #v do parts[i] = jsonEncode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = jsonEncode(k) .. ":" .. jsonEncode(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function copyTable(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copyTable(v) end
  return out
end

-- ============================================================================
-- Session: login, cookies, CSRF
-- ============================================================================
local function getHeader(hdrs, name)
  if type(hdrs) ~= "table" then return nil end
  for k, v in pairs(hdrs) do
    if string.lower(tostring(k)) == name then return v end
  end
  return nil
end

-- Keeps only the session cookies and the CSRF token from a response.
local function captureSession(hdrs)
  local setCookie = getHeader(hdrs, "set-cookie")
  local texts = {}
  if type(setCookie) == "table" then texts = setCookie elseif setCookie then texts = { setCookie } end
  for _, text in ipairs(texts) do
    for name, value in string.gmatch(tostring(text), "([%w_%-]+)=([^;,%s]+)") do
      if name == "TOKEN" or name == "unifises" or name == "csrf_token" then g_cookies[name] = value end
    end
  end
  local csrf = getHeader(hdrs, "x-updated-csrf-token") or getHeader(hdrs, "x-csrf-token")
  if csrf and csrf ~= "" then g_csrf = tostring(csrf) end
end

local function cookieHeader()
  local parts = {}
  for name, value in pairs(g_cookies) do parts[#parts + 1] = name .. "=" .. value end
  return table.concat(parts, "; ")
end

local function baseUrl()
  local port = prop("Port")
  if port == "" then port = "443" end
  return "https://" .. prop("Host") .. ":" .. port
end

local function finishLogin(ok, msg)
  g_loginInFlight = false
  local waiters = g_loginWaiters
  g_loginWaiters = {}
  if not ok then setStatus(msg or "Login failed") end
  for _, cb in ipairs(waiters) do pcall(cb, ok) end
end

local function login(cb)
  if g_loggedIn then cb(true); return end
  table.insert(g_loginWaiters, cb)
  if g_loginInFlight then return end
  g_loginInFlight = true
  pcall(function()
    g_loginWatch = C4:SetTimer(20000, function()
      if g_loginInFlight then
        logv("login watchdog fired: no response in 20 s from " .. baseUrl(), false)
        finishLogin(false, "Login timed out: no response from " .. baseUrl())
      end
    end)
  end)
  if prop("Host") == "" or prop("Username") == "" or prop("Password") == "" then
    finishLogin(false, "Set Host, Username and Password")
    return
  end
  local choice = prop("Controller Type")
  local candidates = {
    { mode = "unifi_os", login = "/api/auth/login", prefix = "/proxy/network" },
    { mode = "legacy", login = "/api/login", prefix = "" },
  }
  if choice == "UniFi OS" then candidates = { candidates[1] } elseif choice == "Legacy" then candidates = { candidates[2] } end

  local function try(i)
    if i > #candidates then finishLogin(false, "Login failed (check host, admin account, Controller Type)"); return end
    local c = candidates[i]
    g_cookies, g_csrf = {}, nil
    local body = jsonEncode({ username = prop("Username"), password = prop("Password"), remember = false })
    local headers = { Accept = "application/json", ["Content-Type"] = "application/json" }
    setStatus("Logging in (" .. c.mode .. ")...")
    logv("login attempt " .. c.mode .. " " .. baseUrl() .. c.login, false)
    local ok, err = pcall(function()
      C4:urlPost(baseUrl() .. c.login, body, headers, false, function(_, data, code, hdrs, e)
        logv("login " .. c.mode .. " HTTP " .. tostring(code) .. " " .. mask(e or ""), false)
        if tonumber(code) == 200 then
          captureSession(hdrs)
          if next(g_cookies) ~= nil then
            g_mode, g_prefix, g_loggedIn = c.mode, c.prefix, true
            finishLogin(true)
            return
          end
        end
        try(i + 1)
      end, TLS_OPTIONS)
    end)
    if not ok then logv("login call error: " .. mask(err), false); try(i + 1) end
  end
  try(1)
end

-- Sends one API request. path is relative to the base path, for example "/api/s/default/stat/device".
local function apiCall(method, path, body, cb, isRetry)
  local url = baseUrl() .. g_prefix .. path
  local headers = { Accept = "application/json", ["Content-Type"] = "application/json" }
  if next(g_cookies) ~= nil then headers.Cookie = cookieHeader() end
  if g_csrf then headers["X-CSRF-Token"] = g_csrf end
  local function handler(_, data, code, hdrs, err)
    captureSession(hdrs)
    logv(method .. " " .. path .. " -> HTTP " .. tostring(code), false)
    logv("raw: " .. mask(string.sub(tostring(data or ""), 1, 2000)), true)
    local c = tonumber(code) or 0
    if (c == 401 or c == 403) and not isRetry then
      g_loggedIn = false
      login(function(ok)
        if ok then apiCall(method, path, body, cb, true) else cb(c, data, err) end
      end)
      return
    end
    cb(c, data, err)
  end
  local ok, e = pcall(function()
    if method == "GET" then
      C4:urlGet(url, headers, false, handler, TLS_OPTIONS)
    elseif method == "POST" then
      C4:urlPost(url, body or "", headers, false, handler, TLS_OPTIONS)
    else
      -- PUT. C4:urlPut exists with the same signature as urlPost (confirmed from drivers-common-public url.lua).
      C4:urlPut(url, body or "", headers, false, handler, TLS_OPTIONS)
    end
  end)
  if not ok then cb(0, nil, mask(tostring(e))) end
end

-- ============================================================================
-- Discovery and state
-- ============================================================================
local function isPowerDevice(d)
  if type(d) ~= "table" then return false end
  if type(d.outlet_table) == "table" and #d.outlet_table > 0 then return true end
  if type(d.outlet_overrides) == "table" and #d.outlet_overrides > 0 then return true end
  return d.model == "USPPDUP" or d.model == "USPPLUG"
end

local function findEntry(list, index)
  if type(list) ~= "table" then return nil end
  for _, e in ipairs(list) do
    if tonumber(e.index) == index then return e end
  end
  return nil
end

-- True when a name is a bare MAC address, which the controller sends when a device is tied to an outlet.
local function isMacName(s)
  return type(s) == "string" and string.match(s, "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function buildFromDevices(devices)
  g_outlets, g_outletByKey, g_raw = {}, {}, {}; g_devWatts = {}
  for _, d in ipairs(devices) do
    if isPowerDevice(d) then
      local devId = tostring(d._id or d.mac or d.name or "unknown")
      local devName = tostring(d.name or d.model or devId); if d.outlet_ac_power_consumption ~= nil then g_devWatts[devId] = tonumber(d.outlet_ac_power_consumption) end
      local tbl = type(d.outlet_table) == "table" and d.outlet_table or {}
      local ovr = type(d.outlet_overrides) == "table" and d.outlet_overrides or nil
      local base = ovr or tbl
      g_raw[devId] = { id = devId, name = devName, overrides = copyTable(base), source = ovr and "outlet_overrides" or "outlet_table" }
      local indices = {}
      for _, e in ipairs(tbl) do indices[#indices + 1] = tonumber(e.index) end
      if ovr then for _, e in ipairs(ovr) do indices[#indices + 1] = tonumber(e.index) end end
      if #indices == 0 and type(d.relay_state) == "boolean" then indices[1] = 1 end
      -- A device with one outlet (USP Plug) uses the device name, since the plug's outlet cannot be renamed in UniFi.
      local uniq, nOutlets = {}, 0
      for _, i in ipairs(indices) do
        if i and not uniq[i] then uniq[i] = true; nOutlets = nOutlets + 1 end
      end
      local seen = {}
      for _, idx in ipairs(indices) do
        if idx and not seen[idx] then
          seen[idx] = true
          local t = findEntry(tbl, idx)
          local o = findEntry(ovr, idx)
          local state = (t and t.relay_state) or (o and o.relay_state) or d.relay_state
          local name = (o and o.name) or (t and t.name) or ("Outlet " .. idx)
          if nOutlets == 1 then name = devName end
          local watts = nil; if t and t.outlet_power ~= nil then watts = tonumber(t.outlet_power) end; local rec = { key = devId .. ":" .. idx, devId = devId, devName = devName, index = idx,
                        name = tostring(name), on = state == true, watts = watts }
          -- Keep the controller's MAC name so the display name can be resolved from client names later.
          if isMacName(rec.name) then rec.mac = rec.name end
          table.insert(g_outlets, rec)
          g_outletByKey[rec.key] = rec
        end
      end
    end
  end
end

-- True when at least one outlet is named only by a MAC address.
local function anyMacOutlet()
  for _, o in ipairs(g_outlets) do
    if o.mac then return true end
  end
  return false
end

-- Client names are refetched at most every 10 minutes.
local function clientsStale()
  return g_clientsAt == nil or (os.time() - g_clientsAt) >= 600
end

-- Loads GET rest/user into g_clientNames (lowercase MAC -> name, else hostname). Calls done() exactly once,
-- even on failure, so outlet refresh never depends on it. A failed or empty response keeps the previous names.
local function fetchClients(done)
  g_clientsAt = os.time()
  local finished = false
  local function finish()
    if not finished then
      finished = true
      done()
    end
  end
  local ok, e = pcall(function()
    apiCall("GET", "/api/s/" .. prop("Site") .. "/rest/user", nil, function(code, data)
      if code ~= 200 then logv("client names: HTTP " .. tostring(code) .. ", keeping previous names", false) end
      pcall(function()
        local obj = (code == 200) and jsonDecode(data or "") or nil
        if type(obj) ~= "table" or type(obj.data) ~= "table" then return end
        local names, count = {}, 0
        for _, c in ipairs(obj.data) do
          if type(c) == "table" and type(c.mac) == "string" then
            local label = nil
            if type(c.name) == "string" and c.name ~= "" then
              label = c.name
            elseif type(c.hostname) == "string" and c.hostname ~= "" then
              label = c.hostname
            end
            if label then
              names[string.lower(c.mac)] = label
              count = count + 1
            end
          end
        end
        g_clientNames = names
        logv("client names: " .. count .. " loaded", false)
      end)
      finish()
    end)
  end)
  if not ok then
    logv("client names: request error " .. mask(tostring(e)), false)
    finish()
  end
end

-- Sets each MAC-named outlet's display name to its client name, or leaves the MAC when none is known.
-- Runs on every device refresh, so it always uses the newest loaded names.
local function applyClientNames()
  for _, o in ipairs(g_outlets) do
    if o.mac then o.name = g_clientNames[string.lower(o.mac)] or o.mac end
  end
end

local function refreshDevices(cb)
  apiCall("GET", "/api/s/" .. prop("Site") .. "/stat/device", nil, function(code, data)
    local obj = (code == 200) and jsonDecode(data or "") or nil
    if type(obj) ~= "table" or type(obj.data) ~= "table" then
      cb(false, "device read failed (HTTP " .. tostring(code) .. ")")
      return
    end
    buildFromDevices(obj.data)
    -- Client names are loaded before this poll's names are applied when a fetch is due, so the first poll
    -- already shows them. The fetch is skipped unless an outlet is MAC-named and the list is stale.
    if anyMacOutlet() and clientsStale() then
      fetchClients(function()
        applyClientNames()
        cb(true)
      end)
    else
      applyClientNames()
      cb(true)
    end
  end)
end

local function discoveredText()
  local lines = {}
  for _, o in ipairs(g_outlets) do
    lines[#lines + 1] = o.key .. "  " .. o.devName .. " / " .. o.name .. " (" .. (o.on and "ON" or "OFF") .. ")"
  end
  return table.concat(lines, "\n")
end

local function publishUi()
  g_uiSeq = g_uiSeq + 1
  local list = {}
  for i, o in ipairs(g_outlets) do
    if i <= MAX_UI_OUTLETS then
      list[#list + 1] = { n = i, key = o.key, device = o.devName, name = o.name, on = o.on, watts = o.watts, total_watts = g_devWatts[o.devId] }
    end
  end
  local json = jsonEncode({ t = "unifi", seq = g_uiSeq, build = PAGE_BUILD, version = DRIVER_VERSION,
                            online = g_loggedIn, status = g_status, outlets = list })
  pcall(function() C4:SetVariable("UI_STATE", json) end)
  pcall(function() C4:SendDataToUI(json) end)
end

local function notifyChildren()
  for childId, key in pairs(g_children) do
    local o = g_outletByKey[key]
    local state = o and (o.on and "ON" or "OFF") or "UNKNOWN"
    pcall(function() C4:SendToDevice(tonumber(childId), "UO_STATUS", { KEY = key, STATE = state }) end)
  end
end

-- ============================================================================
-- Writes (serialized) and polling
-- ============================================================================
local processWrites
local schedulePoll

-- Writes one outlet. Re-reads the device first, then sends the FULL outlet array with only the target changed.
local function doWrite(job, cb)
  refreshDevices(function(ok, msg)
    if not ok then cb(false, msg); return end
    local o = g_outletByKey[job.key]
    if not o then cb(false, "outlet not found: " .. tostring(job.key)); return end
    local want = job.on
    if want == nil then want = not o.on end          -- TOGGLE resolved against fresh state
    if want == o.on then cb(true, "already " .. (o.on and "ON" or "OFF")); return end
    local raw = g_raw[o.devId]
    if not raw then cb(false, "device missing"); return end
    local arr = copyTable(raw.overrides)
    local e = findEntry(arr, o.index)
    if not e then
      if raw.source == "outlet_overrides" then cb(false, "outlet index not in outlet_overrides; refusing partial update"); return end
      e = { index = o.index, name = o.mac or o.name }
      table.insert(arr, e)
    end
    e.relay_state = want
    local body = jsonEncode({ outlet_overrides = arr })
    apiCall("PUT", "/api/s/" .. prop("Site") .. "/rest/device/" .. raw.id, body, function(code)
      if code == 200 then cb(true, "set " .. (want and "ON" or "OFF")) else cb(false, "PUT HTTP " .. tostring(code)) end
    end)
  end)
end

processWrites = function()
  if g_writeBusy or #g_writeQueue == 0 then return end
  g_writeBusy = true
  local job = table.remove(g_writeQueue, 1)
  login(function(ok)
    if not ok then
      g_writeBusy = false
      processWrites()
      return
    end
    doWrite(job, function(success, msg)
      logv("write " .. tostring(job.key) .. " from " .. tostring(job.src) .. ": " .. tostring(msg), false)
      if not success then setStatus("Command failed: " .. tostring(msg)) end
      g_writeBusy = false
      schedulePoll(2)            -- re-poll shortly so the tile shows the real state
      processWrites()
    end)
  end)
end

local function queueWrite(key, on, src)
  table.insert(g_writeQueue, { key = key, on = on, src = src })
  processWrites()
end

local function pollOnce()
  login(function(ok)
    if not ok then publishUi(); return end
    refreshDevices(function(success, msg)
      if success then
        setStatus("Connected: " .. #g_outlets .. " outlet(s)")
        pcall(function() C4:UpdateProperty("Discovered Outlets", discoveredText()) end)
        notifyChildren()
      else
        setStatus(msg)
      end
      publishUi()
    end)
  end)
end

schedulePoll = function(delay)
  g_gen = g_gen + 1
  local my = g_gen
  local seconds = delay or tonumber(prop("Poll Interval Seconds")) or 30
  pcall(function()
    g_timer = C4:SetTimer(seconds * 1000, function()
      if my ~= g_gen then return end
      pollOnce()
      schedulePoll(tonumber(prop("Poll Interval Seconds")) or 30)
    end)
  end)
end

-- ============================================================================
-- Page commands (parameter-free, from the web view) and proxy events
-- ============================================================================
local EC = {}
local RFP = {}

-- UI_OUTLET_<n>_ON / _OFF, where n is the position in the snapshot. Page confirms OFF before sending.
for n = 1, MAX_UI_OUTLETS do
  EC["UI_OUTLET_" .. n .. "_ON"] = function()
    local o = g_outlets[n]
    if not o then logv("UI outlet " .. n .. " no longer exists; refresh the page", false); return end
    queueWrite(o.key, true, "page")
  end
  EC["UI_OUTLET_" .. n .. "_OFF"] = function()
    local o = g_outlets[n]
    if not o then logv("UI outlet " .. n .. " no longer exists; refresh the page", false); return end
    queueWrite(o.key, false, "page")
  end
end

EC["UI_REFRESH"] = function() schedulePoll(1) end

-- Tile tap (SELECT) and Composer sync only republish state. They never switch anything.
RFP.SELECT = function() publishUi() end
RFP.SYNCHRONIZE = function() publishUi() end

-- Page build check: the page sends UI_HELLO_<build> on load.
local function helloCheck(build)
  if tostring(build) == PAGE_BUILD then
    pcall(function() C4:UpdateProperty("Web Page Status", "Page build " .. build .. " OK") end)
  else
    pcall(function() C4:UpdateProperty("Web Page Status", "PAGE IS STALE: page " .. tostring(build) .. ", driver expects " .. PAGE_BUILD) end)
  end
  publishUi()
end

function OnDriverInit()
  pcall(function() C4:UpdateProperty("Driver Version", DRIVER_VERSION) end)
  pcall(function() C4:AddVariable("UI_STATE", "", "STRING", true, false) end)
end

function OnDriverLateInit()
  pcall(function() C4:UpdateProperty("Driver Version", DRIVER_VERSION) end)
  pcall(function() C4:UpdateProperty("Web Page Status", "Page build " .. PAGE_BUILD .. " (not yet loaded)") end)
  setStatus("Starting")
  publishUi()
  schedulePoll(5)
end

function OnPropertyChanged(strProperty)
  if strProperty == "Host" or strProperty == "Port" or strProperty == "Username" or
     strProperty == "Password" or strProperty == "Site" or strProperty == "Controller Type" then
    g_loggedIn = false
    g_cookies, g_csrf = {}, nil
    schedulePoll(2)
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if idBinding == UI_BINDING and RFP[strCommand] then RFP[strCommand](idBinding, strCommand, tParams) end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  logv("ExecuteCommand: " .. tostring(strCommand), true)
  if strCommand == "LUA_ACTION" then
    local a = tostring(tParams.ACTION or "")
    logv("LUA_ACTION " .. a, false)
    if EC[a] then return EC[a](tParams) end
    return
  end
  if EC[strCommand] then return EC[strCommand](tParams) end
  local hello = string.match(strCommand, "^UI_HELLO_(.+)$")
  if hello then return helloCheck(hello) end

  -- From the child drivers
  if strCommand == "UO_REGISTER" then
    local childId = tostring(tParams.CHILD_ID or "")
    if childId ~= "" and tParams.KEY then
      g_children[childId] = tostring(tParams.KEY)
      local o = g_outletByKey[tParams.KEY]
      pcall(function()
        C4:SendToDevice(tonumber(childId), "UO_STATUS", { KEY = tParams.KEY, STATE = o and (o.on and "ON" or "OFF") or "UNKNOWN" })
      end)
    end
    return
  end
  if strCommand == "UO_COMMAND" then
    local action = tostring(tParams.ACTION or "")
    local on = nil
    if action == "ON" then on = true elseif action == "OFF" then on = false end
    queueWrite(tostring(tParams.KEY or ""), on, "child")
    return
  end
  logv("Unhandled ExecuteCommand: " .. tostring(strCommand), false)
end
