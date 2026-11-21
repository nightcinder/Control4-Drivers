-- SwitchBot Cloud (parent) and SwitchBot Curtain (child): property masking, signing safety,
-- manual child compatibility (dual-motor paired & Second Device), and safe child auto-creation.
-- Run: python tools/c4sim/run.py test switchbot
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

local PARENT_LUA = "drivers/switchbot-cloud/SwitchBot_Cloud_driver.lua"
local PARENT_XML = "drivers/switchbot-cloud/SwitchBot_Cloud_driver.xml"
local CHILD_LUA = "drivers/switchbot-curtain/SwitchBot_Curtain_driver.lua"
local CHILD_XML = "drivers/switchbot-curtain/SwitchBot_Curtain_driver.xml"

-- Wrap C4:urlGet / C4:urlPost because the driver passes the DriverWorks bNoCache flag before the callback.
local function install_http_wrappers()
  C4.urlGet = function(_, url, headers, a, b)
    return urlGet(url, headers, type(a) == "function" and a or b, 0)
  end
  C4.urlPost = function(_, url, body, headers, a, b)
    return urlPost(url, body, headers, type(a) == "function" and a or b, 0)
  end
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function prop_block(xml, name)
  for blk in xml:gmatch("<property>(.-)</property>") do
    local pname = blk:match("<name>%s*(.-)%s*</name>")
    if pname == name then return blk end
  end
  return nil
end

local function expected_version(xmlPath)
  local xml = read_file(xmlPath)
  local blk = prop_block(xml, "Driver Version") or ""
  return blk:match("<default>%s*(.-)%s*</default>")
end

-- Sample SwitchBot /v1.1/devices JSON:
--   Lounge pair: master (SB-LOUNGE-M) + paired follower (SB-LOUNGE-S, group=true, master=false)
--   Den West: single motor (SB-DEN-WEST)
--   Optional extra curtain: Bedroom (SB-BEDROOM)
local function devices_json(include_bedroom, include_unpaired_extra)
  local items = {
    '{"deviceId":"SB-LOUNGE-M","deviceName":"Lounge","deviceType":"Curtain","group":true,"master":true}',
    '{"deviceId":"SB-LOUNGE-S","deviceName":"Lounge Sub","deviceType":"Curtain","group":true,"master":false}',
    '{"deviceId":"SB-DEN-WEST","deviceName":"Den West","deviceType":"Curtain","group":false,"master":false}',
  }
  if include_bedroom then
    items[#items + 1] = '{"deviceId":"SB-BEDROOM","deviceName":"Bedroom, Main","deviceType":"Curtain3","group":false,"master":false}'
  end
  if include_unpaired_extra then
    items[#items + 1] = '{"deviceId":"SB-HALL-1","deviceName":"Hall Left","deviceType":"Curtain"}'
    items[#items + 1] = '{"deviceId":"SB-HALL-2","deviceName":"Hall Right","deviceType":"Curtain"}'
  end
  return '{"statusCode":100,"message":"success","body":{"deviceList":[' .. table.concat(items, ",") .. ']}}'
end

local function start_parent(opts)
  opts = opts or {}
  install_http_wrappers()
  local added, bound_calls = {}, {}
  local ok = sim.load_driver(PARENT_LUA, {
    xml = PARENT_XML,
    deviceId = opts.deviceId or 10,
    properties = opts.properties or {
      Token = "fake-token-xyz",
      Secret = "fake-secret-abc",
      ["Auto Create Children"] = opts.autoCreate or "Off",
    },
    before = function()
      local bound = opts.bound or {}
      C4.GetBoundConsumerDevices = function() return bound end
      C4.RoomGetId = function() return opts.roomId ~= nil and opts.roomId or 42 end
      local nextId = opts.nextId or 200
      C4.AddDevice = function(_, driverFile, roomId, name, cb)
        local rec = { driverFile = driverFile, roomId = roomId, name = name, cb = cb }
        added[#added + 1] = rec
        if opts.deferAddDevice then return end
        local id = opts.addDeviceReturnZero and 0 or nextId
        nextId = nextId + 1
        rec.id = id
        if cb then cb(id) end
      end
      C4.Bind = function(_, pid, pbind, cid, cbind, cls)
        bound_calls[#bound_calls + 1] = { pid = pid, pbind = pbind, cid = cid, cbind = cbind, cls = cls }
        if opts.updateBoundOnBind ~= false and cid and cid > 0 then
          bound[cid] = "Auto Child"
        end
      end
    end,
  })
  t.ok(ok, "parent load: " .. tostring(sim.errors[1]))
  if not opts.keepStartupHttp then
    -- Drain any discover() HTTP calls fired by OnPropertyChanged during load_driver.
    for _ = 1, 4 do
      sim.queue_http("/devices$", devices_json(false), 200)
    end
    sim.advance(0)
    sim._http_queue = {}
  end
  return added, bound_calls
end

t.test("Token and Secret use STRING with password=true in SwitchBot_Cloud_driver.xml", function()
  local xml = read_file(PARENT_XML)
  for _, pname in ipairs({ "Token", "Secret" }) do
    local blk = prop_block(xml, pname)
    t.ok(blk ~= nil, pname .. " property exists")
    t.eq(blk:match("<type>%s*(.-)%s*</type>"), "STRING", pname .. " keeps STRING type (PASSWORD type crashes Composer)")
    t.eq(blk:match("<password>%s*(.-)%s*</password>"), "true", pname .. " sets <password>true</password>")
  end
  local auto = prop_block(xml, "Auto Create Children")
  t.ok(auto ~= nil, "Auto Create Children exists")
  t.eq(auto:match("<default>%s*(.-)%s*</default>"), "Off", "Auto Create Children defaults to Off for live safety")
end)

t.test("Token and Secret are never written to prints or logs", function()
  start_parent({ properties = { Token = "tok-never-log-123", Secret = "sec-never-log-456" } })
  sim.queue_http("/devices$", devices_json(false), 200)
  sim.exec("DISCOVER", {})
  sim.advance(0)
  for _, line in ipairs(sim.prints) do
    t.ok(line:find("tok-never-log-123", 1, true) == nil, "Token not in prints")
    t.ok(line:find("sec-never-log-456", 1, true) == nil, "Secret not in prints")
  end
  for _, line in ipairs(sim.logs) do
    t.ok(line:find("tok-never-log-123", 1, true) == nil, "Token not in logs")
    t.ok(line:find("sec-never-log-456", 1, true) == nil, "Secret not in logs")
  end
  t.eq(sim._store["Driver Version"], expected_version(PARENT_XML), "parent Driver Version matches XML")
end)

t.test("Auto Create Off (default) never calls AddDevice on startup or Discover", function()
  local added = start_parent({ autoCreate = "Off", keepStartupHttp = true })
  -- Even after 65s and a full discovery, nothing is created while Auto Create Children is Off.
  for _ = 1, 4 do sim.queue_http("/devices$", devices_json(true), 200) end
  sim.advance(65000)
  t.eq(#added, 0, "no auto-create at startup")
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("DISCOVER", {})
  sim.advance(0)
  t.eq(#added, 0, "no auto-create on Discover Devices")
  t.eq(#sim.errors, 0, "no errors")
end)

t.test("Existing Lounge + Den West manual bindings are never duplicated by Create Missing Children or Auto Create On", function()
  local bound = { [101] = "Lounge", [102] = "Den West" }
  local added, bound_calls = start_parent({ autoCreate = "On", bound = bound, roomId = 15 })
  -- Existing manual children register their device IDs (Lounge master + Den West).
  sim.exec("SB_REGISTER", { CHILD_ID = "101", IDS = "SB-LOUNGE-M" })
  sim.exec("SB_REGISTER", { CHILD_ID = "102", IDS = "SB-DEN-WEST" })
  -- Advance past the 60s grace period; post-grace discover runs with Bedroom absent.
  sim.queue_http("/devices$", devices_json(false), 200)
  sim.advance(65000)
  -- Lounge master (registered), Lounge follower (group=true, master=false), Den West (registered) => 0 created!
  t.eq(#added, 0, "zero children created when Lounge + Den West already registered and follower skipped")
  t.eq(#bound_calls, 0, "zero extra Bind calls")

  -- Now a new Bedroom curtain appears in SwitchBot Cloud; manual action creates ONLY Bedroom.
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("LUA_ACTION", { ACTION = "CREATE_CHILDREN" })
  sim.advance(0)
  t.eq(#added, 1, "only the missing Bedroom curtain is created")
  t.eq(added[1].driverFile, "switchbot-curtain.c4z", "child driver filename")
  t.eq(added[1].roomId, 15, "room id from C4:RoomGetId")
  t.eq(added[1].name, "SwitchBot Bedroom, Main", "display name prefixed with SwitchBot")
  t.eq(#bound_calls, 1, "Bind called once")
  t.eq(bound_calls[1].pid, 10, "parent device id")
  t.eq(bound_calls[1].cid, 200, "child device id")
  t.eq(bound_calls[1].cls, "SWITCHBOT_CLOUD", "binding class")

  -- Before the 10s SB_CONFIGURE timer fires, a second Create Missing Children must not duplicate Bedroom.
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("CREATE_CHILDREN", {})
  sim.advance(0)
  t.eq(#added, 1, "pendingCreates/unregistered gate prevents duplicate AddDevice")

  -- After 10s, SB_CONFIGURE is sent with comma-stripped option matching SB_DEVICES.
  sim.advance(10000)
  local cfg = sim.last_sent("SB_CONFIGURE")
  t.ok(cfg ~= nil, "SB_CONFIGURE sent")
  t.eq(cfg.id, 200, "sent to created child")
  t.eq(cfg.params.DEVICE, "Bedroom  Main [SB-BEDROOM]", "DEVICE matches dropdown option")
  t.ok(cfg.params.LIST:find("Bedroom  Main [SB-BEDROOM]", 1, true) ~= nil, "LIST includes option")

  -- Child registers SB-BEDROOM; subsequent Create Missing Children creates nothing.
  sim.exec("SB_REGISTER", { CHILD_ID = "200", IDS = "SB-BEDROOM" })
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("CREATE_CHILDREN", {})
  sim.advance(0)
  t.eq(#added, 1, "no duplicates after child registered")
end)

t.test("Two unpaired motors registered via Device + Second Device on one child are both skipped", function()
  local bound = { [101] = "Lounge", [102] = "Den West", [103] = "Hall" }
  local added = start_parent({ autoCreate = "Off", bound = bound })
  sim.exec("SB_REGISTER", { CHILD_ID = "101", IDS = "SB-LOUNGE-M" })
  sim.exec("SB_REGISTER", { CHILD_ID = "102", IDS = "SB-DEN-WEST" })
  sim.exec("SB_REGISTER", { CHILD_ID = "103", IDS = "SB-HALL-1,SB-HALL-2" })
  sim.queue_http("/devices$", devices_json(false, true), 200)
  sim.exec("CREATE_CHILDREN", {})
  sim.advance(0)
  t.eq(#added, 0, "neither motor in Second Device child is duplicated")
end)

t.test("Auto-create waits and sends SB_HELLO when a bound child has not registered yet", function()
  -- Bound child 102 has not sent SB_REGISTER yet!
  local bound = { [101] = "Lounge", [102] = "Den West" }
  local added = start_parent({ autoCreate = "Off", bound = bound })
  sim.exec("SB_REGISTER", { CHILD_ID = "101", IDS = "SB-LOUNGE-M" })
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("CREATE_CHILDREN", {})
  sim.advance(0)
  t.eq(#added, 0, "creation blocked while bound child 102 is unregistered")
  local hello = sim.last_sent("SB_HELLO")
  t.ok(hello ~= nil and hello.id == 102, "SB_HELLO sent to unregistered bound child 102")
end)

t.test("Auto-create fails closed when RoomGetId returns 0 or AddDevice returns 0", function()
  local added0 = start_parent({ autoCreate = "Off", roomId = 0 })
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("CREATE_CHILDREN", {})
  sim.advance(0)
  t.eq(#added0, 0, "AddDevice not called when roomId is 0")

  local addedFail, boundFail = start_parent({ autoCreate = "Off", roomId = 7, addDeviceReturnZero = true })
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("CREATE_CHILDREN", {})
  sim.advance(0)
  t.eq(#addedFail, 3, "AddDevice attempted for 3 non-follower devices (Lounge follower skipped)")
  t.eq(#boundFail, 0, "Bind not called when AddDevice returns 0")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.test("OnDriverDestroyed cancels pending SB_CONFIGURE timers cleanly", function()
  start_parent({ autoCreate = "Off", roomId = 9 })
  sim.queue_http("/devices$", devices_json(true), 200)
  sim.exec("CREATE_CHILDREN", {})
  sim.advance(0)
  -- Immediately destroy before the 10s SB_CONFIGURE timer fires.
  sim.call("OnDriverDestroyed")
  sim.advance(60000)
  for _, tm in ipairs(sim.timers) do
    t.ok(tm.cancelled == true, "no uncancelled timer remains after OnDriverDestroyed")
  end
  t.eq(sim.count_sent("SB_CONFIGURE"), 0, "SB_CONFIGURE cancelled on destroy")
end)

t.test("SwitchBot Curtain handles SB_CONFIGURE without breaking manual children", function()
  local ok = sim.load_driver(CHILD_LUA, {
    xml = CHILD_XML,
    deviceId = 200,
    before = function(s)
      s.bind(200, 1, 10)
    end,
  })
  t.ok(ok, "child load: " .. tostring(sim.errors[1]))
  t.eq(sim._store["Driver Version"], expected_version(CHILD_XML), "child Driver Version matches XML")

  -- Auto-created child with Device=None accepts SB_CONFIGURE and registers SB-BEDROOM.
  sim.exec("SB_CONFIGURE", {
    DEVICE = "Bedroom  Main [SB-BEDROOM]",
    LIST = "None,Lounge [SB-LOUNGE-M],Bedroom  Main [SB-BEDROOM]",
  })
  t.eq(sim._store.Device, "Bedroom  Main [SB-BEDROOM]", "Device property updated")
  local reg = sim.last_sent("SB_REGISTER")
  t.ok(reg ~= nil and reg.id == 10, "SB_REGISTER sent to parent")
  t.eq(reg.params.IDS, "SB-BEDROOM", "registered SB-BEDROOM")

  -- Second SB_CONFIGURE must NOT overwrite an already-configured child Device.
  sim.exec("SB_CONFIGURE", {
    DEVICE = "Other [SB-OTHER]",
    LIST = "None,Other [SB-OTHER]",
  })
  t.eq(sim._store.Device, "Bedroom  Main [SB-BEDROOM]", "existing Device preserved")

  -- Blind proxy Open / Close / Set Position / Invert Level / Low Battery still work.
  sim.call("ReceivedFromProxy", 5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 25 })
  sim.advance(1000)
  local cmd = sim.last_sent("SB_COMMAND")
  t.ok(cmd ~= nil, "SB_COMMAND sent")
  t.eq(cmd.params.COMMAND, "setPosition", "setPosition")
  t.eq(cmd.params.PARAMETER, "0,ff,25", "position 25 with Invert Level False")

  sim.exec("SB_STATUS", { DEVICE_ID = "SB-BEDROOM", POSITION = "25", MOVING = "false", BATTERY = "15" })
  t.eq(sim._store.Battery, 15, "Battery updated as number")
  t.eq(#sim.events, 1, "Low Battery event fired when below threshold 20")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.finish("switchbot")
