-- c4sim: in-house Control4 driver simulator (logic only).
-- Lua 5.1 and 5.4 compatible. No goto, no bitwise ops, no integer division.
local unpack = table.unpack or unpack
local loadstr = loadstring or load

local sim = {}
local C4 = {}
sim.C4 = C4

local Timer = {}
Timer.__index = Timer
function Timer:Cancel()
  self.cancelled = true
end

local UNITS = { MILLISECONDS = 1, SECONDS = 1000, MINUTES = 60000, HOURS = 3600000 }

local function first_line(s)
  return (tostring(s or ""):match("^[^\r\n]*")) or ""
end

local function add_warn(msg)
  if not sim._seen[msg] then
    sim._seen[msg] = true
    sim.warnings[#sim.warnings + 1] = msg
  end
end

local function record_error(where, e)
  local s = tostring(e)
  sim.errors[#sim.errors + 1] = where .. ": " .. first_line(s)
  sim.tracebacks[#sim.tracebacks + 1] = s
end

local function handler(e)
  return debug.traceback(tostring(e), 2)
end

-- Call fn(...) under xpcall; errors go to sim.errors. Returns true on success.
local function xcall(where, fn, ...)
  local n = select("#", ...)
  local args = { ... }
  local ok, res = xpcall(function() return fn(unpack(args, 1, n)) end, handler)
  if ok then return true, res end
  record_error(where, res)
  return false
end

local function vkey(d, v)
  return tostring(d) .. ":" .. tostring(v)
end

local function unescape(s)
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&apos;", "'")
  s = s:gsub("&amp;", "&")
  return s
end

-- Properties: reads come from sim._store; direct writes (Properties.X = v)
-- are recorded in sim.props_direct, UpdateProperty writes are not.
local function make_proxy()
  return setmetatable({}, {
    __index = function(_, k) return sim._store[k] end,
    __newindex = function(_, k, v)
      sim.props_direct[k] = true
      sim._store[k] = v
    end,
    -- Lua 5.4 only (5.1 ignores __pairs): pairs(Properties) walks the store.
    __pairs = function() return next, sim._store, nil end,
  })
end

function sim.reset(deviceId)
  sim.now_ms = 0
  sim.deviceId = deviceId or 1
  sim.timers = {}
  sim.named = {}
  sim.seq = 0
  sim.sent = {}
  sim.events = {}
  sim.props = {}
  sim.props_api = {}
  sim.props_direct = {}
  sim.listeners = {}
  sim.prints = {}
  sim.logs = {}
  sim.errors = {}
  sim.tracebacks = {}
  sim.warnings = {}
  sim._seen = {}
  sim.vars = {}
  sim.binds = {}
  sim.dvars = {}
  sim.persist = {}
  sim._store = {}
  sim.xml_names = {}
  sim.env = nil
  sim.epoch = 1767225600          -- sim os.time() origin (2026-01-01 UTC)
  sim.http = {}                   -- every url* request, in order
  sim._http_queue = {}            -- responses queued by sim.queue_http
  sim._http_pending = {}          -- requests waiting for the next advance
  sim.http_timeouts = {}
  sim.net = { sent = {}, connects = {}, disconnects = {}, connections = {}, servers = {} }
  sim.ui = {}
  sim.prop_lists = {}
  -- Drop common-library stubs so the next driver gets fresh ones and their warnings.
  for _, n in ipairs(sim._stub_loaded or {}) do package.loaded[n] = nil end
  sim._stub_loaded = {}
  sim.Properties = make_proxy()
  _G.Properties = sim.Properties
end

function sim.now()
  return sim.now_ms
end

local function add_timer(ms, fn, repeating, name)
  local d = tonumber(ms) or 0
  if d < 0 then d = 0 end
  sim.seq = sim.seq + 1
  local t = setmetatable({ due = sim.now_ms + d, fn = fn, seq = sim.seq, name = name }, Timer)
  if repeating then
    t.every = (d > 0) and d or 1
  end
  sim.timers[#sim.timers + 1] = t
  return t
end

-- Fire due timers in time order up to now+ms. Repeating timers re-arm.
function sim.advance(ms)
  local target = sim.now_ms + (tonumber(ms) or 0)
  local count = 0
  sim._pump_http()
  while true do
    local live, best = {}, nil
    for _, t in ipairs(sim.timers) do
      if not t.cancelled then
        live[#live + 1] = t
        if t.due <= target and (best == nil or t.due < best.due or (t.due == best.due and t.seq < best.seq)) then
          best = t
        end
      end
    end
    sim.timers = live
    if not best then break end
    count = count + 1
    if count > 100000 then
      record_error("advance", "too many timer firings (runaway repeating timer?)")
      break
    end
    if best.due > sim.now_ms then sim.now_ms = best.due end
    if best.every then
      best.due = best.due + best.every
    else
      best.cancelled = true
    end
    xcall("timer", best.fn)
    sim._pump_http()
  end
  sim.now_ms = target
end

local function compile(src, chunkname, env)
  if setfenv then
    local f, err = loadstr(src, chunkname)
    if f then setfenv(f, env) end
    return f, err
  end
  return load(src, chunkname, "t", env)
end

local function build_env()
  local env = setmetatable({}, { __index = _G })
  env.C4 = C4
  env.Properties = sim.Properties
  -- os.time() follows the simulated clock, so timeouts and lux age work under advance().
  local realos = os
  env.os = setmetatable({ time = function(t)
    if t then return realos.time(t) end
    return sim.epoch + math.floor(sim.now_ms / 1000)
  end }, { __index = realos })
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    sim.prints[#sim.prints + 1] = table.concat(parts, "\t")
  end
  return env
end

-- Call a global driver function by name (if defined) under pcall.
function sim.call(name, ...)
  local env = sim.env
  if not env then return false end
  local f = env[name]
  if type(f) ~= "function" then return false end
  return xcall(name, f, ...)
end

function sim.set_var(deviceId, varId, value)
  sim.vars[vkey(deviceId, varId)] = value
end

function sim.fire_var(deviceId, varId, value)
  sim.set_var(deviceId, varId, value)
  sim.call("OnWatchedVariableChanged", deviceId, varId, tostring(value))
end

function sim.bind(deviceId, bindingId, value)
  sim.binds[vkey(deviceId, bindingId)] = value
end

function sim.exec(cmdName, tParams)
  if type(sim.env and sim.env.ExecuteCommand) ~= "function" then
    record_error("ExecuteCommand", "ExecuteCommand is not defined")
    return false
  end
  return sim.call("ExecuteCommand", cmdName, tParams or {})
end

function sim.last_sent(cmd)
  for i = #sim.sent, 1, -1 do
    if sim.sent[i].cmd == cmd then return sim.sent[i] end
  end
  return nil
end

function sim.count_sent(cmd)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.cmd == cmd then n = n + 1 end
  end
  return n
end

local function parse_props(xml)
  local list = {}
  for block in xml:gmatch("<property[%s>](.-)</property>") do
    local name = block:match("<name>%s*(.-)%s*</name>")
    if name then
      local def = block:match("<default[^>]*>(.-)</default>") or ""
      list[#list + 1] = { name = unescape(name), default = unescape(def) }
    end
  end
  return list
end

local function sibling_xml(path)
  local dir = path:match("^(.*)[/\\][^/\\]*$")
  if not dir then return nil end
  local f = io.open(dir .. "/driver.xml", "rb")
  if not f then return nil end
  f:close()
  return dir .. "/driver.xml"
end

-- Load a driver: defaults from driver.xml (opts.xml or sibling driver.xml),
-- then opts.properties overrides, then OnDriverInit, OnDriverLateInit and
-- OnPropertyChanged(name) for each property.
function sim.load_driver(path, opts)
  opts = opts or {}
  sim.reset(opts.deviceId)
  -- Reload support: keep PersistData from an earlier load and continue the simulated clock from start_ms.
  if opts.persist then sim.persist = opts.persist end
  if opts.start_ms then sim.now_ms = opts.start_ms end
  if opts.before then opts.before(sim) end  -- runs after reset, before OnDriverInit (bind, set_var)
  local f = io.open(path, "rb")
  if not f then
    record_error("load", "cannot open " .. tostring(path))
    return false
  end
  local src = f:read("*a")
  f:close()

  local order, seen = {}, {}
  local function add_name(n)
    if not seen[n] then
      seen[n] = true
      order[#order + 1] = n
    end
  end
  local xmlpath = opts.xml or sibling_xml(path)
  if xmlpath then
    local xf = io.open(xmlpath, "rb")
    if xf then
      local xml = xf:read("*a")
      xf:close()
      for _, p in ipairs(parse_props(xml)) do
        sim._store[p.name] = p.default
        sim.xml_names[#sim.xml_names + 1] = p.name
        add_name(p.name)
      end
    end
  end
  for k, v in pairs(opts.properties or {}) do
    sim._store[k] = v
    add_name(k)
  end

  sim.env = build_env()
  local chunk, err = compile(src, "@" .. path, sim.env)
  if not chunk then
    record_error("compile", err)
    return false
  end
  xcall("load", chunk)
  sim.call("OnDriverInit")
  sim.call("OnDriverLateInit")
  for _, name in ipairs(order) do
    sim.call("OnPropertyChanged", name)
  end
  return #sim.errors == 0
end

-- ---- C4 API ----

function C4:GetTime()
  return sim.now_ms
end

function C4:SetTimer(ms, fn, repeating)
  return add_timer(ms, fn, repeating, nil)
end

-- AddTimer(name, time, units, repeating): fires global OnTimerExpired(name).
function C4:AddTimer(name, time, units, repeating)
  local mult = UNITS[string.upper(tostring(units or "SECONDS"))] or 1000
  if sim.named[name] then sim.named[name]:Cancel() end
  local tm = add_timer((tonumber(time) or 0) * mult, function()
    local env = sim.env
    if env and type(env.OnTimerExpired) == "function" then
      xcall("OnTimerExpired", env.OnTimerExpired, name)
    end
  end, repeating, name)
  sim.named[name] = tm
  return tm
end

function C4:KillTimer(name)
  if sim.named[name] then
    sim.named[name]:Cancel()
    sim.named[name] = nil
  end
end

function C4:KillAllTimers()
  for _, t in ipairs(sim.timers) do t.cancelled = true end
  sim.named = {}
end

function C4:GetDeviceID()
  return sim.deviceId
end

function C4:UpdateProperty(name, value)
  sim._store[name] = value
  sim.props_api[name] = true
  sim.props[#sim.props + 1] = { name = name, value = value, t = sim.now_ms }
end

function C4:SendToDevice(id, cmd, params)
  sim.sent[#sim.sent + 1] = { kind = "device", id = id, cmd = cmd, params = params, t = sim.now_ms }
end

function C4:SendToProxy(id, cmd, params)
  sim.sent[#sim.sent + 1] = { kind = "proxy", id = id, cmd = cmd, params = params, t = sim.now_ms }
end

function C4:FireEvent(id)
  sim.events[#sim.events + 1] = { id = id, t = sim.now_ms }
end

function C4:FireEventByID(id)
  sim.events[#sim.events + 1] = { id = id, t = sim.now_ms }
end

function C4:RegisterVariableListener(deviceId, varId)
  sim.listeners[#sim.listeners + 1] = { device = deviceId, var = varId }
end

function C4:UnregisterVariableListener(deviceId, varId)
  local keep = {}
  for _, l in ipairs(sim.listeners) do
    if not (l.device == deviceId and l.var == varId) then keep[#keep + 1] = l end
  end
  sim.listeners = keep
end

function C4:GetDeviceVariable(deviceId, varId)
  return sim.vars[vkey(deviceId, varId)]
end

function C4:GetBoundProviderDevice(deviceId, bindingId)
  return sim.binds[vkey(deviceId, bindingId)]
end

function C4:GetBoundConsumerDevices()
  return {}
end

function C4:SetVariable(name, value)
  sim.dvars[name] = value
end

function C4:AddVariable(name, value)
  sim.dvars[name] = value
end

local function join_args(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  return table.concat(parts, " ")
end

function C4:DebugLog(...)
  sim.logs[#sim.logs + 1] = "debug: " .. join_args(...)
end

function C4:ErrorLog(...)
  sim.logs[#sim.logs + 1] = "error: " .. join_args(...)
end

function C4:PersistGetValue(key)
  return sim.persist[key]
end

function C4:PersistSetValue(key, value)
  sim.persist[key] = value
end

-- Any other C4:Name call is a no-op that records a warning.
setmetatable(C4, {
  __index = function(_, name)
    if type(name) ~= "string" then return nil end
    return function()
      add_warn("unstubbed C4:" .. name)
      return nil
    end
  end,
})

_G.C4 = C4
sim.reset(1)

-- Helper so tests can reach the sandbox globals.
sim.first_line = first_line

-- ---- JSON (pure Lua, written for the simulator) ----
-- JsonEncode: arrays are tables with keys 1..n; other tables encode as objects with sorted keys.
-- JsonDecode: errors with a message on bad input (no nil-return convention).
local function json_str(s)
  local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
  return '"' .. (s:gsub('[%c"\\]', function(c)
    return map[c] or string.format("\\u%04x", c:byte())
  end)) .. '"'
end

local function json_is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    if k > n then n = k end
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

local function json_enc(v, out)
  local tv = type(v)
  if tv == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif v % 1 == 0 and math.abs(v) < 2 ^ 53 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.14g", v) end
  elseif tv == "string" then out[#out + 1] = json_str(v)
  elseif tv == "table" then
    local arr, n = json_is_array(v)
    if arr then
      out[#out + 1] = "["
      for i = 1, n do
        if i > 1 then out[#out + 1] = "," end
        json_enc(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k, val in pairs(v) do keys[#keys + 1] = { k = k, s = tostring(k), v = val } end
      table.sort(keys, function(a, b) return a.s < b.s end)
      out[#out + 1] = "{"
      for i, e in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = json_str(e.s) .. ":"
        json_enc(e.v, out)
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = "null"
  end
end

function JsonEncode(v)
  local out = {}
  json_enc(v, out)
  return table.concat(out)
end

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local JSON_ESC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

function JsonDecode(s)
  s = tostring(s)
  local pos = 1
  local value
  local function fail(msg) error("JsonDecode: " .. msg .. " at byte " .. pos, 0) end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
  local function str()
    pos = pos + 1
    local buf = {}
    while true do
      local j = s:find('["\\]', pos)
      if not j then fail("unterminated string") end
      buf[#buf + 1] = s:sub(pos, j - 1)
      pos = j
      if s:sub(pos, pos) == '"' then
        pos = pos + 1
        break
      end
      local e = s:sub(pos + 1, pos + 1)
      if e == "u" then
        local cp = tonumber(s:sub(pos + 2, pos + 5), 16)
        if not cp then fail("bad \\u escape") end
        buf[#buf + 1] = utf8_char(cp)  -- surrogate pairs are not joined
        pos = pos + 6
      elseif JSON_ESC[e] then
        buf[#buf + 1] = JSON_ESC[e]
        pos = pos + 2
      else
        fail("bad escape")
      end
    end
    return table.concat(buf)
  end
  local function arr()
    pos = pos + 1
    local t, n = {}, 0
    ws()
    if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
    while true do
      n = n + 1
      t[n] = value()
      ws()
      local c = s:sub(pos, pos)
      pos = pos + 1
      if c == "]" then return t end
      if c ~= "," then fail("expected , or ]") end
    end
  end
  local function obj()
    pos = pos + 1
    local t = {}
    ws()
    if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
    while true do
      ws()
      if s:sub(pos, pos) ~= '"' then fail("expected key") end
      local k = str()
      ws()
      if s:sub(pos, pos) ~= ":" then fail("expected :") end
      pos = pos + 1
      t[k] = value()
      ws()
      local c = s:sub(pos, pos)
      pos = pos + 1
      if c == "}" then return t end
      if c ~= "," then fail("expected , or }") end
    end
  end
  value = function()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then return obj() end
    if c == "[" then return arr() end
    if c == '"' then return str() end
    if s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
    if s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
    if s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
    local tok = s:match("^-?%d+%.?%d*[eE][-+]?%d+", pos) or s:match("^-?%d+%.?%d*", pos)
    if not tok then fail("unexpected character") end
    pos = pos + #tok
    return tonumber(tok)
  end
  local v = value()
  ws()
  if pos <= #s then fail("trailing data") end
  return v
end

-- ---- Base64 (arithmetic only: no bitwise ops in 5.1) ----
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

function Base64Encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a or 0) * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

function Base64Decode(s)
  local out, bits, nbits = {}, 0, 0
  for ch in tostring(s):gmatch(".") do
    local v = B64_INDEX[ch]
    if v then
      bits = bits * 64 + v
      nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        out[#out + 1] = string.char(math.floor(bits / 2 ^ nbits) % 256)
        bits = bits % 2 ^ nbits
      end
    end
  end
  return table.concat(out)
end

-- ---- HTTP: url* calls are recorded in sim.http and answered on advance() ----
-- Callback shape: callback(context, data, code, headers, err). Argument order for urlDo
-- and urlPost follows the usual DriverWorks layout; check the SDK before relying on it.
local function http_request(method, url, headers, body, callback, context)
  local req = { method = method, url = tostring(url), headers = headers, body = body, t = sim.now_ms }
  sim.http[#sim.http + 1] = req
  sim._http_pending[#sim._http_pending + 1] = { req = req, callback = callback, context = context }
  return #sim.http
end

-- queue_http(pattern, body, code, headers): the next request whose URL matches the Lua pattern gets this reply.
function sim.queue_http(pattern, body, code, headers)
  sim._http_queue[#sim._http_queue + 1] = { pattern = pattern, body = body, code = code or 200, headers = headers }
end

function sim._pump_http()
  while #sim._http_pending > 0 do
    local job = table.remove(sim._http_pending, 1)
    local resp
    for i, q in ipairs(sim._http_queue) do
      if job.req.url:find(q.pattern) then
        resp = table.remove(sim._http_queue, i)
        break
      end
    end
    local data, code, headers, err = nil, 0, nil, nil
    if resp then
      data, code, headers = resp.body, resp.code, resp.headers
    else
      add_warn("no queued http response for " .. job.req.method .. " " .. job.req.url)
      err = "no sim response queued"
    end
    if job.callback then xcall("http callback", job.callback, job.context, data, code, headers or {}, err) end
  end
end

function urlGet(url, headers, callback, context)
  return http_request("GET", url, headers, nil, callback, context)
end

function urlPost(url, body, headers, callback, context)
  return http_request("POST", url, headers, body, callback, context)
end

function urlDo(method, url, headers, callback, context, body)
  return http_request(string.upper(tostring(method)), url, headers, body, callback, context)
end

function urlSetTimeout(ticket, seconds)
  sim.http_timeouts[#sim.http_timeouts + 1] = { ticket = ticket, seconds = seconds }
end

-- ---- Network: recorded in sim.net; sim.net_receive feeds ReceivedFromNetwork ----
local function net_connect(binding, address, protocol)
  sim.net.connections[binding] = { address = address, protocol = protocol }
  return true
end
function CreateNetworkConnection(binding, address, protocol)
  return net_connect(binding, address, protocol)
end
function NetConnect(binding, port, protocol)
  sim.net.connects[#sim.net.connects + 1] = { binding = binding, port = port, protocol = protocol }
  return true
end
function SendToNetwork(binding, port, data)
  sim.net.sent[#sim.net.sent + 1] = { binding = binding, port = port, data = data, t = sim.now_ms }
end
function NetDisconnect(binding, port)
  sim.net.disconnects[#sim.net.disconnects + 1] = { binding = binding, port = port }
end
function CreateServer(port, protocol)
  sim.net.servers[port] = protocol or "tcp"
  return true
end
function DestroyServer(port)
  sim.net.servers[port] = nil
end

-- sim.net_receive(bindingId, data): calls ReceivedFromNetwork(binding, port, data) with the last port used by NetConnect.
function sim.net_receive(bindingId, data)
  local port = 0
  for _, c in ipairs(sim.net.connects) do
    if c.binding == bindingId then port = c.port end
  end
  local f = (sim.env and sim.env.ReceivedFromNetwork) or _G.ReceivedFromNetwork
  if type(f) == "function" then xcall("ReceivedFromNetwork", f, bindingId, port, data) end
end

-- ---- Misc UI and system ----
function SendDataToUI(...)
  sim.ui[#sim.ui + 1] = { ... }
end

function UpdatePropertyList(name, list)
  sim.prop_lists[name] = list
end

function GetControllerNetworkAddress()
  return "127.0.0.1"
end

-- ---- Common-library fallbacks: drivers-common-public.* modules that are not on the path ----
-- Real files on package.path win (this searcher is appended last). Stub calls return nil and warn.
local function stub_common(name)
  add_warn("stubbed common-library module " .. name)
  sim._stub_loaded[#sim._stub_loaded + 1] = name
  return setmetatable({}, {
    __index = function()
      return function()
        add_warn("stubbed common-library module " .. name)
        return nil
      end
    end,
  })
end
do
  local searchers = package.searchers or package.loaders
  table.insert(searchers, function(name)
    if type(name) == "string" and name:find("^drivers%-common%-public") then
      return function(n) return stub_common(n) end, name
    end
    return nil
  end)
end

-- Drivers call most of these as C4:Name(...) and some as globals. Both forms reach the same stub.
do
  local names = { "JsonEncode", "JsonDecode", "Base64Encode", "Base64Decode", "urlGet", "urlPost", "urlDo",
    "urlSetTimeout", "CreateNetworkConnection", "NetConnect", "SendToNetwork", "NetDisconnect", "CreateServer",
    "DestroyServer", "SendDataToUI", "UpdatePropertyList", "GetControllerNetworkAddress" }
  for _, n in ipairs(names) do
    local fn = _G[n]
    C4[n] = function(_, ...) return fn(...) end
  end
end

return sim
