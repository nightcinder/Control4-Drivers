-- DLS curtain rate limits (1.9.0): the 15 min per-curtain cooldown, the 200 commands per local day cap,
-- and the cap resetting at local midnight.
-- Run: python tools/c4sim/run.py test dls_curtain_limits
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600

-- Point the longitude at the machine's timezone so local clock time is roughly solar time: the sun
-- tests then do not depend on where the test runs.
local OFFSET_H = os.difftime(os.time(), os.time(os.date("!*t", os.time()))) / 3600
local LAT, LON = "40", tostring(OFFSET_H * 15)

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local CURTAIN_CMDS = { OPEN = true, CLOSE = true, SET_POSITION = true }

-- Curtain commands sent, optionally for one proxy id only.
local function curtainCmds(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if CURTAIN_CMDS[s.cmd] and (id == nil or s.id == id) then n = n + 1 end
  end
  return n
end

local function lastCurtainCmd(id)
  for i = #sim.sent, 1, -1 do
    local s = sim.sent[i]
    if s.id == id and CURTAIN_CMDS[s.cmd] then return s end
  end
  return nil
end

local function load(rooms, h, m)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = LAT, ["Longitude"] = LON, ["Curtain Automation"] = "On" },
    start_ms = local_sec(h, m) * SEC,
    before = function(s) s.set_var(337, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

-- One curtain that is in glare (threshold 0) or fully open (threshold 1) at noon.
local function glareRoom(threshold)
  return '[{"name":"Den","on":"18:00","off":"23:00","curtains":[{"id":493,"name":"Den West","facing_deg":0,"open_at":"08:00","close_at":"20:00","glare_threshold":' .. threshold .. ',"glare_position":25}],"lights":[{"id":337,"kind":"lutron"}]}]'
end

-- n curtains spread over one room, all closed at night (no sun on the window).
local function manyCurtains(n)
  local list = {}
  for i = 1, n do
    list[i] = string.format('{"id":%d,"name":"C%d","facing_deg":0,"open_at":"08:00","close_at":"20:00"}', 1000 + i, i)
  end
  return '[{"name":"Hall","on":"18:00","off":"23:00","curtains":[' .. table.concat(list, ",") .. '],"lights":[{"id":337,"kind":"lutron"}]}]'
end

t.test("1: a second curtain command inside the 15 min cooldown is skipped", function()
  sim.reset(1)
  load(glareRoom(0), 12, 0)
  sim.advance(20 * SEC)                          -- first Update pass at 12:00:15
  t.eq(curtainCmds(493), 1, "the first pass commands the curtain once")
  local first = lastCurtainCmd(493)
  t.ok(first.cmd == "SET_POSITION" and first.params.POSITION == 25, "it went to the glare position")

  sim.sent = {}
  sim.Properties["Rooms JSON"] = glareRoom(1)    -- the same curtain now targets fully open (a 75 point move)
  sim.call("OnPropertyChanged", "Rooms JSON")
  sim.advance(5 * SEC)                           -- the 2 s Update kicked by the property change
  t.eq(curtainCmds(493), 0, "a target change inside the cooldown sends nothing")
  sim.exec("LUA_ACTION", { ACTION = "RecalcNow" })
  t.eq(curtainCmds(493), 0, "a forced recalculation inside the cooldown sends nothing")

  sim.advance(16 * MIN)                          -- past the 900 s cooldown
  t.eq(curtainCmds(493), 1, "the command goes out once the cooldown has passed")
  local second = lastCurtainCmd(493)
  t.ok(second.cmd == "OPEN", "the cooldown-expired command opened the curtain")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.test("2: the 200 per day cap stops further commands and resets at local midnight", function()
  sim.reset(1)
  load(manyCurtains(201), 23, 0)                 -- night: every curtain targets closed
  sim.advance(20 * SEC)
  t.eq(curtainCmds(), 200, "exactly the daily cap was sent")
  t.eq(curtainCmds(1001), 1, "the first curtain was commanded")
  t.eq(curtainCmds(1200), 1, "curtain 200 was commanded")
  t.eq(curtainCmds(1201), 0, "curtain 201 was held by the cap")

  sim.advance(30 * MIN)                          -- 23:30, still the same local day
  t.eq(curtainCmds(1201), 0, "still held later the same day")

  sim.sent = {}
  sim.advance((local_sec(0, 5) + 86400 - local_sec(23, 0)) * SEC)   -- 00:05 the next day
  t.eq(curtainCmds(1201), 1, "the cap reset at local midnight, so the blocked curtain runs")
  t.eq(curtainCmds(), 1, "nothing else was re-sent (targets did not move)")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.finish("dls-curtain-limits")
