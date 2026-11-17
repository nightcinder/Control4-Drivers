-- DLS feature coverage the older suites did not touch: wake ramp, away lamps, the two LUA actions,
-- curtain glare/open targets, and OnDriverDestroyed timer cleanup.
-- Run: python tools/c4sim/run.py test dls_features
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4
_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local U = 337
local SEC = 1000
local EPOCH = 1767225600

local function local_sec(h, m, s)
  return os.time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = s or 0 }) - EPOCH
end
local realdate = os.date
os.date = function(fmt, when)
  if when == nil then when = EPOCH + math.floor(sim.now_ms / 1000) end
  return realdate(fmt, when)
end

local function sent(id, cmd, level)
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == cmd and (level == nil or s.params.LEVEL == level) then return true end
  end
  return false
end

local function any_sent(id, cmd)
  for _, s in ipairs(sim.sent) do if s.id == id and s.cmd == cmd then return true end end
  return false
end

local function load(rooms, h, m, vars, extra)
  local properties = { ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90", ["Rooms JSON"] = rooms, ["Latitude"] = "40", ["Longitude"] = "-75" }
  for k, v in pairs(extra or {}) do properties[k] = v end
  local ok = sim.load_driver(DRV, {
    xml = XML,
    properties = properties,
    start_ms = local_sec(h, m) * SEC,
    before = function(s)
      for id, lvl in pairs(vars or {}) do s.set_var(id, VAR, lvl) end
    end,
  })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
end

t.test("wake ramp runs inside its window and goes off when it ends", function()
  sim.reset(1)
  load('[{"name":"Upstairs","off":"22:30","wake":{"enabled":true,"at":"sunrise-15","stop":"sunrise+30","ramp_min":30,"level":35,"days":["thu"]},"lights":[{"id":337,"kind":"lutron"}]}]', 7, 5, { [U] = 0 })
  sim.advance(60 * 60 * SEC)                   -- 07:05 -> 08:05; sunrise is 07:25
  local n = 0
  for _, s in ipairs(sim.sent) do if s.id == U and s.cmd == "RAMP_TO_LEVEL" and s.params.LEVEL > 0 then n = n + 1 end end
  t.ok(n >= 1, "wake levels sent")
  t.ok(sent(U, "RAMP_TO_LEVEL", 0), "wake end sent 0")
end)

t.test("wake is skipped on a day not in its days list", function()
  sim.reset(1)
  load('[{"name":"Upstairs","off":"22:30","wake":{"enabled":true,"at":"sunrise-15","stop":"sunrise+30","ramp_min":30,"level":35,"days":["mon"]},"lights":[{"id":337,"kind":"lutron"}]}]', 7, 5, { [U] = 0 })
  sim.advance(60 * 60 * SEC)
  t.eq(#sim.sent, 0, "nothing sent on a non-wake day")
end)

t.test("away lamps use the away config, then go off at the away off time", function()
  sim.reset(1)
  load('[{"name":"Downstairs","follow":true,"on":"18:00","off":"23:45","away":{"light":480,"level":30,"off":"22:30"},"lights":[{"id":480,"kind":"lutron"},{"id":478,"kind":"lutron"}]}]', 20, 0, { [480] = 40, [478] = 40 })
  sim.exec("SetPresence", { PRESENT = "AWAY" })
  t.ok(sent(480, "RAMP_TO_LEVEL", 30), "away lamp at 30")
  t.ok(sent(478, "RAMP_TO_LEVEL", 0), "other light off")
  sim.sent = {}
  sim.advance(3 * 60 * 60 * SEC)               -- 23:00, past away off 22:30
  t.ok(sent(480, "RAMP_TO_LEVEL", 0), "away lamp off after its time")
end)

t.test("ReleaseAll drops a manual hold; LogStatus prints the summary", function()
  sim.reset(1)
  load('[{"name":"Upstairs","on":"18:00","off":"22:30","lights":[{"id":337,"kind":"lutron"}]}]', 19, 0, { [U] = 40 })
  sim.advance(70 * SEC)
  sim.advance(7 * 60 * SEC)
  sim.fire_var(U, VAR, "55")
  sim.advance(60 * SEC)
  t.ok(type(sim.persist.holds) == "table" and sim.persist.holds.Upstairs ~= nil, "hold set")
  sim.sent = {}
  sim.exec("LUA_ACTION", { ACTION = "ReleaseAll" })
  t.ok(sent(U, "RAMP_TO_LEVEL") and not sent(U, "RAMP_TO_LEVEL", 55), "schedule drove the light again")
  local h = type(sim.persist.holds) == "table" and sim.persist.holds.Upstairs
  t.ok(h == nil or next(h) == nil, "persisted hold cleared")
  sim.prints = {}
  sim.exec("LUA_ACTION", { ACTION = "LogStatus" })
  local found = false
  for _, p in ipairs(sim.prints) do if p:find("%[DLS%] sun") then found = true end end
  t.ok(found, "LogStatus printed the sun line")
end)

t.test("curtains: glare position and open command", function()
  sim.reset(1)
  load('[{"name":"Den","on":"18:00","off":"23:00","curtains":[{"id":493,"name":"Glare","facing_deg":180,"open_at":"08:00","close_at":"20:00","glare_threshold":0,"glare_position":25},{"id":499,"name":"Open","facing_deg":0,"open_at":"08:00","close_at":"20:00","glare_threshold":1,"glare_position":25}],"lights":[{"id":337,"kind":"lutron"}]}]', 12, 0, {}, { ["Curtain Automation"] = "On" })
  sim.advance(20 * SEC)
  local glare, open = false, false
  for _, s in ipairs(sim.sent) do
    if s.id == 493 and s.cmd == "SET_POSITION" and s.params.POSITION == 25 then glare = true end
    if s.id == 499 and s.cmd == "OPEN" then open = true end
  end
  t.ok(glare, "glare curtain went to its glare position")
  t.ok(open, "clear curtain opened")
end)

t.test("OnDriverDestroyed stops the timers", function()
  sim.reset(1)
  load('[{"name":"Upstairs","on":"18:00","off":"22:30","lights":[{"id":337,"kind":"lutron"}]}]', 19, 0, { [U] = 40 })
  sim.advance(20 * SEC)                        -- first tick sends the target
  t.ok(any_sent(U, "RAMP_TO_LEVEL"), "timer was running")
  sim.call("OnDriverDestroyed")
  sim.sent = {}
  sim.advance(10 * 60 * SEC)
  t.eq(#sim.sent, 0, "no sends after destroy")
end)

t.finish("dls-features")
