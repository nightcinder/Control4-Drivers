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

return sim
