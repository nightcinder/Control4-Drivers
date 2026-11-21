local sim = require("c4sim")
local t   = require("t")

local YALE_LUA = "drivers/yale-assure-lock-2/Yale_AssureLock2_driver.lua"
local YALE_XML = "drivers/yale-assure-lock-2/Yale_AssureLock2_driver.xml"

t.test("yale-assure-lock-2: detail + status poll, DoorSense inversion, battery warning, remoteoperate settle ladder", function()
  local ok = sim.load_driver(YALE_LUA, {
    xml = YALE_XML,
    deviceId = 100,
    persist = {
      access_token = "yale-jwt-token",
      install_id = "11111111-2222-4333-8444-555555555555",
    },
    properties = {
      Brand = "Yale Access",
      ["Login Method"] = "Email",
      Username = "owner@example.test",
      Password = "pw",
      ["Lock ID"] = "LOCK100",
      ["Poll Interval (seconds)"] = "60",
    },
    before = function(s)
      s.queue_http("/locks/LOCK100$", '{"LockName":"Front Door","currentFirmwareVersion":"2.1.9","HouseID":"H1","battery":0.35,"LockStatus":{"status":"kAugLockState_Locked","doorState":"kAugDoorState_Closed"}}', 200)
      s.queue_http("/locks/LOCK100/status", '{"status":"kAugLockState_Locked","doorState":"kAugDoorState_Closed"}', 200)
    end,
  })
  t.ok(ok, "yale loaded: " .. tostring(sim.errors[1]))
  t.eq(#sim.errors, 0, "no init errors")

  -- Pump initial RefreshDetail and RefreshStatus requests issued during OnDriverLateInit.
  sim.advance(0)

  t.eq(sim._store["Lock Name"], "Front Door", "Lock Name updated from detail")
  t.eq(sim._store["Firmware Version"], "2.1.9", "Firmware Version updated")
  t.eq(sim._store["House ID"], "H1", "House ID updated and persisted")
  t.eq(sim._store["Battery Level"], "35%", "Battery Level 35%")

  local bat = sim.last_sent("BATTERY_STATUS_CHANGED")
  t.ok(bat ~= nil and bat.params.BATTERY_STATUS == "warning", "35% battery notifies warning")

  local ls = sim.last_sent("LOCK_STATUS_CHANGED")
  t.ok(ls ~= nil and ls.params.LOCK_STATUS == "locked", "LOCK_STATUS_CHANGED locked")

  -- DoorSense contact binding 300 has inverted polarity: closed door -> OPENED notification.
  local sawContactOpened = false
  for _, s in ipairs(sim.sent) do
    if s.id == 300 and s.cmd == "OPENED" then sawContactOpened = true end
  end
  t.ok(sawContactOpened, "closed door sends OPENED on contact binding 300")

  -- Proxy UNLOCK command sends PUT /remoteoperate/LOCK100/unlock and arms 4 settle reads.
  sim.sent = {}
  sim.http = {}
  sim.queue_http("/remoteoperate/LOCK100/unlock", '{"status":"kAugLockState_Unlocked","doorState":"kAugDoorState_Open","info":{"action":"remote_unlock"}}', 200)
  sim.call("ReceivedFromProxy", 5001, "UNLOCK", {})
  t.eq(sim.env.PendingSettleCount(), 4, "4 settle ladder timers scheduled")
  sim.advance(0)

  t.eq(sim.http[1].method, "PUT", "remoteoperate uses PUT via C4:url()")
  local ls2 = sim.last_sent("LOCK_STATUS_CHANGED")
  t.ok(ls2 ~= nil and ls2.params.LOCK_STATUS == "unlocked", "remoteoperate updates status to unlocked")

  local sawContactClosed = false
  for _, s in ipairs(sim.sent) do
    if s.id == 300 and s.cmd == "CLOSED" then sawContactClosed = true end
  end
  t.ok(sawContactClosed, "open door sends CLOSED on contact binding 300")

  -- Unreachable read holds last known state (unlocked) and requests a wakeup.
  sim.sent = {}
  sim.http = {}
  sim.queue_http("intent=wakeup", '{"status":"kAugLockState_Unlocked"}', 200)
  sim.env.ApplyStatusJson({ status = "unknown" }, nil, nil)
  t.eq(sim.env.g_lockStatus, "unlocked", "single unreachable read holds last known state")
  t.ok(#sim.http >= 1 and string.find(sim.http[1].url, "intent=wakeup", 1, true) ~= nil,
       "unreachable read triggers async wakeup PUT")

  -- JSON_NULL sentinel check.
  local obj = sim.env.JsonDecode('{"pin":null,"ok":true}')
  t.eq(obj.pin, sim.env.JSON_NULL, "JsonDecode parses null into JSON_NULL sentinel")
end)

t.finish("yale-assure-lock-2")
