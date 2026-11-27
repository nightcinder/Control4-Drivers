-- DLS wake ramp across several rooms: two rooms ramp together, a room with a broken wake spec and a
-- held room are skipped without blocking the others or raising.
-- Run: python tools/c4sim/run.py test dls_wake_multiroom
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC, MIN = 1000, 60000
local EPOCH = 1767225600
local THU = '["thu"]'                          -- 2026-01-01 is a Thursday

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

local function wake(at, extra)
  return '"wake":{"enabled":true,"at":"' .. at .. '","stop":"sunrise+30","ramp_min":30,"level":35,"days":' .. THU .. '}' .. (extra or "")
end

local function room(name, id, at, extra)
  return '{"name":"' .. name .. '",' .. wake(at, extra) .. ',"lights":[{"id":' .. id .. ',"kind":"lutron"}]}'
end

local function load(rooms)
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = LAT, ["Longitude"] = LON },
    start_ms = local_sec(7, 5) * SEC,
    before = function(s) s.set_var(337, VAR, "0") s.set_var(338, VAR, "0") s.set_var(339, VAR, "0") end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

-- 1.17.14: a Lutron wake ramp is one Fade Dimmer, so one command counts as a ramp
local function wakeLevels(id)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL > 0 then n = n + 1 end
    if s.id == id - 1 and s.cmd == "Fade Dimmer" and tonumber(s.params["Intensity"]) > 0 then n = n + 1 end   -- 1.17.14
  end
  return n
end

local function highest(id)
  local top = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL > top then top = s.params.LEVEL end
    if s.id == id - 1 and s.cmd == "Fade Dimmer" and tonumber(s.params["Intensity"]) > top then top = tonumber(s.params["Intensity"]) end   -- 1.17.14
  end
  return top
end

local function sentZero(id)
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL == 0 then return true end
  end
  return false
end

local TWO = '[' .. room("Main", 337, "sunrise-15") .. "," .. room("Second", 338, "sunrise-15") .. ']'
local BROKEN = '[' .. room("Main", 337, "sunrise-15") .. "," .. room("Spare", 338, "not-a-time") .. ']'
local HELD = '[' .. room("Main", 337, "sunrise-15") .. "," .. room("Held", 339, "sunrise-15", ',"scenes":{"Off":{"off":true}}') .. ']'

t.test("1: two rooms with wake ramps both ramp in the same window", function()
  sim.reset(1)
  load(TWO)
  sim.advance(60 * MIN)                        -- 07:05 -> 08:05, wake window is about 07:10 to 07:55
  t.ok(wakeLevels(337) >= 1, "room Main ramped (" .. wakeLevels(337) .. " levels)")
  t.ok(wakeLevels(338) >= 1, "room Second ramped (" .. wakeLevels(338) .. " levels)")
  t.ok(highest(337) >= 10 and highest(338) >= 10, "both rooms climbed to a real level")
  t.ok(sentZero(337) and sentZero(338), "both rooms went off when their wake window ended")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.test("2: a room whose wake spec cannot be resolved does not block the other room", function()
  sim.reset(1)
  load(BROKEN)
  sim.advance(60 * MIN)
  t.ok(wakeLevels(337) >= 1, "the healthy room still ramped")
  t.eq(wakeLevels(338), 0, "the room with the broken wake window stayed put")
  t.eq(#sim.errors, 0, "the broken spec raised nothing")
  -- 1.17.11 (N5): the bad spec is now named in Status ("Rooms JSON warning: ... | OK ...")
  t.ok(tostring(sim._store["Status"]):find("OK ", 1, true) ~= nil, "the driver kept running")
  t.ok(tostring(sim._store["Status"]):find("Spare.wake.at (bad time", 1, true) ~= nil, "the bad spec is warned")
end)

t.test("3: a held room does not block another room's wake ramp", function()
  sim.reset(1)
  load(HELD)
  sim.advance(20 * SEC)                        -- first Update
  sim.exec("ApplyScene", { ROOM = "Held", SCENE = "Off" })   -- room hold until its next on time
  t.ok(sim.persist.roomHolds ~= nil and sim.persist.roomHolds.Held ~= nil, "the Held room is held")
  sim.sent = {}
  sim.advance(60 * MIN)
  t.eq(wakeLevels(339), 0, "the held room did not ramp")
  t.ok(wakeLevels(337) >= 1, "the other room still ramped")
  t.eq(#sim.errors, 0, "no Lua errors")
end)

t.finish("dls-wake-multiroom")
