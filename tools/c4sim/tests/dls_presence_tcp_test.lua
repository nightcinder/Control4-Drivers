-- DLS presence server (port 8730) client handling: a client that drops mid-line, a reconnect, and port
-- rebinding. Checks the per-client line buffer is dropped, the room state survives, and one server is
-- bound at a time.
-- Run: python tools/c4sim/run.py test dls_presence_tcp
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local TOK = "tok"
local VAR = 1001
local SEC = 1000
local EPOCH = 1767225600

local function local_sec(h, m)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local ROOMS = '[{"name":"Kitchen","key":"Kitchen","on":"18:00","off":"22:30","presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"nightLevel":20,"sources":["esp"]},"lights":[{"id":101,"kind":"lutron"}]}]'

-- Server hooks: replies and closes are recorded per client handle; create/destroy counts show binding.
local replies, closed = {}, {}
local creates, destroys, lastPort = 0, 0, nil
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) closed[#closed + 1] = handle end
C4.CreateServer = function(_, port) creates = creates + 1 lastPort = port return "server" end
C4.DestroyServer = function() destroys = destroys + 1 return true end

local function start()
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Rooms JSON"] = ROOMS, ["Latitude"] = "40", ["Longitude"] = "-75", ["Presence Lighting"] = "On", ["Presence Token"] = TOK, ["Presence Port"] = "8730" },
    start_ms = local_sec(12, 0) * SEC,
    before = function(s) s.set_var(101, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  -- One empty snapshot, like the poller's first HELLO: afterwards OCC lines answer plain OK.
  replies, closed = {}, {}
  sim.call("OnServerDataIn", 9, "HELLO 1 0 " .. TOK .. "\r\n", "192.0.2.5", 50000)
  t.eq(table.concat(replies), "OK\r\n", "the empty snapshot was accepted")
  replies, closed = {}, {}
end

-- One TCP write from one client handle; returns the reply text for this write only.
local function send(handle, data)
  replies = {}
  sim.call("OnServerDataIn", handle, data, "192.0.2.5", 50000)
  return table.concat(replies)
end

local function disconnect(handle)
  sim.call("OnServerConnectionStatusChanged", handle, 8730, "Disconnected")
end

local function roomState()
  local p = sim.persist.presence
  return type(p) == "table" and type(p.Kitchen) == "table" and p.Kitchen.state or nil
end

t.test("1: a client dropping mid-line does not leak its partial line", function()
  sim.reset(1)
  start()
  t.eq(send(1, "OCC Kitchen 1 esp " .. TOK .. "\r\n"), "OK\r\n", "a full line is answered")
  t.eq(roomState(), "OCCUPIED", "the room state was recorded")

  t.eq(send(2, "OCC Kitchen 1 esp to"), "", "a partial line waits for its newline")
  disconnect(2)
  closed = {}
  t.eq(send(2, "PRESENCE HOME " .. TOK .. "\r\n"), "OK\r\n", "the reused handle starts a clean session")
  t.eq(#closed, 1, "the completed line closed that client")
  t.eq(roomState(), "OCCUPIED", "the drop did not disturb the room state")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.test("2: a reconnect after an oversized unread line parses its own data", function()
  sim.reset(1)
  start()
  local r = send(1, string.rep("X", 3000))       -- never terminated, over the 2048 byte line guard
  t.ok(r:find("ERR SYNTAX", 1, true) ~= nil, "the oversized buffer was rejected")
  disconnect(1)
  t.eq(send(1, "PRESENCE HOME " .. TOK .. "\r\n"), "OK\r\n", "the new session is not polluted")
  t.eq(send(3, "OCC Kitchen 1 esp " .. TOK .. "\r\n"), "OK\r\n", "a third client parses cleanly")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.test("3: changing the port re-binds once and tears the old binding down", function()
  sim.reset(1)
  creates, destroys, lastPort = 0, 0, nil
  start()
  local c0, d0 = creates, destroys                -- load itself binds (and rebinds for the property change)
  t.ok(c0 >= 1, "a server was created at load")
  t.eq(lastPort, 8730, "bound on the configured port")
  t.eq(c0 - d0, 1, "exactly one live binding after load")

  sim.Properties["Presence Port"] = 8731
  sim.call("OnPropertyChanged", "Presence Port")
  t.eq(creates - c0, 1, "re-bound after the port change")
  t.eq(destroys - d0, 1, "the old binding went first")
  t.eq(lastPort, 8731, "bound on the new port")

  sim.call("OnPropertyChanged", "Presence Port")  -- the same port again
  t.eq(creates - c0, 2, "re-bound again")
  t.eq(destroys - d0, 2, "and torn down again")
  t.eq(creates - destroys, 1, "exactly one live binding")

  sim.Properties["Presence Port"] = 0
  sim.call("OnPropertyChanged", "Presence Port")
  t.eq(destroys - d0, 3, "port 0 closes the server")
  t.eq(creates - destroys, 0, "nothing left bound")

  sim.Properties["Presence Port"] = 8730
  sim.call("OnPropertyChanged", "Presence Port")
  t.eq(creates - destroys, 1, "bound again")

  sim.call("OnDriverDestroyed")
  t.eq(destroys - d0, 4, "OnDriverDestroyed tears the server down")
  t.eq(creates - destroys, 0, "nothing left bound after destroy")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.finish("dls-presence-tcp")
