-- DLS 1.16.15 regression: 23:45 scheduled off edge must not be suppressed by pre-command feedback on
-- already-lit lights, offEnforce re-holding on nil/low lastLevel, a scene hold across reload, or
-- PR_VACANT blocking a non-follow presence room's off edge.
-- Run: uv run python tools/c4sim/run.py test dls_off_edge
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600
local TOK = "tok"

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end

local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000)
  return table.concat(replies)
end

local function ramps(id)
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then out[#out + 1] = s.params.LEVEL end
  end
  return out
end

local function has_level(id, level)
  for _, lv in ipairs(ramps(id)) do
    if lv == level then return true end
  end
  return false
end

local function has_lt(id, ceiling)
  for _, lv in ipairs(ramps(id)) do
    if lv < ceiling then return true end
  end
  return false
end

local DOWNSTAIRS = '[{"name":"Downstairs","type":"mixed","follow":true,"on_daylight":0.3,"off":"23:45","off_ramp_min":30,' ..
  '"lights":[{"id":331,"kind":"lutron","scale":0.55},{"id":476,"kind":"lifx"}]}]'

local DOWNSTAIRS_SCENE = '[{"name":"Downstairs","type":"mixed","follow":true,"on_daylight":0.3,"off":"23:45","off_ramp_min":30,' ..
  '"scenes":{"Evening":{"levels":{"476":50}}},"lights":[{"id":331,"kind":"lutron","scale":0.55},{"id":476,"kind":"lifx"}]}]'

local DEN_NONFOLLOW = '[{"name":"Den","key":"Den","on":"18:00","off":"23:45","off_ramp_min":30,' ..
  '"presence":{"follow":false,"offDelaySec":180,"fadeInSec":2,"fadeOutSec":30,"sources":["robot"]},' ..
  '"lights":[{"id":476,"kind":"lifx"}]}]'

t.test("1: pre-first-command feedback on already-lit lights does not latch a hold or drop 23:45 off", function()
  sim.reset(1)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = {
      ["Enabled"] = "On",
      ["Update Interval (min)"] = "5",
      ["Ramp Time (sec)"] = "90",
      ["Override Hold (min)"] = "120",
      ["Presence Lighting"] = "On",
      ["Cloud Cover Source"] = "None (assume clear)",
      ["Latitude"] = "40",
      ["Longitude"] = "-75",
      ["Rooms JSON"] = DOWNSTAIRS,
    },
    start_ms = local_sec(22, 36) * SEC,
    before = function(s)
      s.set_var(476, VAR, "20")
      s.set_var(331, VAR, "11")
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))

  -- Feedback arrives right after load before the first Update() has set lastLevel.
  sim.fire_var(476, VAR, "20")
  sim.fire_var(331, VAR, "11")
  t.ok(not (sim.persist.holds and sim.persist.holds.Downstairs), "no spurious hold persisted on baseline feedback")

  sim.advance(68 * MIN)                                -- 23:44:00
  sim.sent = {}
  sim.advance(35 * MIN)                                -- 00:19:00, past 23:45 off edge + 30-min fade

  t.ok(has_level(476, 0), "LIFX 476 ramped off to 0 after 23:45")
  t.ok(has_level(331, 0), "Lutron 331 ramped off to 0 after 23:45")
end)

t.test("2: persisted per-light hold across reload expires after 23:45 without infinite offEnforce re-hold", function()
  sim.reset(1)
  local load_ts = EPOCH + local_sec(22, 36)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = {
      ["Enabled"] = "On",
      ["Update Interval (min)"] = "5",
      ["Ramp Time (sec)"] = "90",
      ["Override Hold (min)"] = "120",
      ["Presence Lighting"] = "On",
      ["Cloud Cover Source"] = "None (assume clear)",
      ["Latitude"] = "40",
      ["Longitude"] = "-75",
      ["Rooms JSON"] = DOWNSTAIRS,
    },
    persist = {
      daylightFired = { Downstairs = os.date("%Y%m%d", load_ts) },
      holds = { Downstairs = { ["476"] = { u = load_ts + 120 * 60, o = false } } },
    },
    start_ms = local_sec(22, 36) * SEC,
    before = function(s)
      s.set_var(476, VAR, "20")
      s.set_var(331, VAR, "11")
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))

  sim.advance(79 * MIN)                                -- 23:55:00 (hold on 476 valid until 00:36)
  t.ok(not has_level(476, 0), "476 held while override active")
  t.ok(has_lt(331, 11), "331 started its 23:45 off fade")

  sim.sent = {}
  sim.advance(60 * MIN)                                -- 00:55:00 (past 00:36 expiry)
  t.ok(has_level(476, 0), "476 sent 0 by offEnforce after hold expired")
  local held476 = sim.persist.holds and sim.persist.holds.Downstairs and sim.persist.holds.Downstairs["476"]
  t.ok(held476 == nil, "476 is not re-held in PersistData.holds")
end)

t.test("3: scene hold persisted across reload still runs the 23:45 off edge when it expires", function()
  sim.reset(1)
  local props = {
    ["Enabled"] = "On",
    ["Update Interval (min)"] = "5",
    ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "120",
    ["Scene Hold (min)"] = "240",
    ["Presence Lighting"] = "On",
    ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "40",
    ["Longitude"] = "-75",
    ["Rooms JSON"] = DOWNSTAIRS_SCENE,
  }
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = props,
    start_ms = local_sec(21, 0) * SEC,
    before = function(s)
      s.set_var(331, VAR, "11")
      s.set_var(476, VAR, "50")
    end,
  })
  t.ok(ok, "initial load: " .. tostring(sim.errors[1]))

  sim.advance(20 * SEC)                                -- 21:00:20, settling Update triggers dayTriggered
  sim.exec("ApplyScene", { ROOM = "Downstairs", SCENE = "Evening" })
  local persist = sim.persist
  t.ok(persist.roomHolds and persist.roomHolds.Downstairs ~= nil, "scene hold persisted")

  ok = sim.load_driver(DRV, {
    xml = XML,
    properties = props,
    persist = persist,
    start_ms = local_sec(22, 36) * SEC,
    before = function(s)
      s.set_var(331, VAR, "11")
      s.set_var(476, VAR, "50")
    end,
  })
  t.ok(ok, "reload: " .. tostring(sim.errors[1]))

  sim.sent = {}
  sim.advance(68 * MIN)                                -- 23:44:00 (scene hold valid until 01:00:20)
  t.ok(not has_level(476, 0), "476 stays held while scene hold is active inside the on window")

  -- 1.16.22: a hold set before the off edge no longer outlasts it. The restored scene hold (wasInWindow kept
  -- across the reload) is cleared at 23:45 and the room fades, long before the hold would have expired.
  sim.sent = {}
  sim.advance(71 * MIN)                                -- 00:55:00
  t.ok(has_lt(476, 50), "476 started ramping down at the 23:45 off edge")
  t.ok(has_level(476, 0), "476 reached 0 before the old scene hold expiry")
end)

t.test("4: vacant non-follow presence room with a lit light still runs the 23:45 scheduled off", function()
  sim.reset(1)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = {
      ["Enabled"] = "On",
      ["Update Interval (min)"] = "1",
      ["Ramp Time (sec)"] = "90",
      ["Presence Lighting"] = "On",
      ["Presence Token"] = TOK,
      ["Presence Port"] = "8730",
      ["Cloud Cover Source"] = "None (assume clear)",
      ["Latitude"] = "40",
      ["Longitude"] = "-75",
      ["Rooms JSON"] = DEN_NONFOLLOW,
    },
    start_ms = local_sec(23, 40) * SEC,
    before = function(s) s.set_var(476, VAR, "20") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))

  t.eq(send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Den", "0", "clear", TOK)),
    "OK\r\nOK\r\nOK\r\n", "snapshot accepted")

  sim.advance(4 * MIN)                                 -- 23:44:00
  sim.sent = {}
  sim.advance(35 * MIN)                                -- 00:19:00, past 23:45 off edge + 30-min fade

  t.ok(has_lt(476, 20), "476 started ramping down at 23:45")
  t.ok(has_level(476, 0), "476 reached 0 in vacant non-follow room")
end)

t.finish("dls-off-edge")
