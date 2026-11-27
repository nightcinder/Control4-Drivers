-- DLS 1.16.13 audit: one test per reported defect, findings 1-7. Each test builds the trigger sequence from
-- the finding and asserts what the driver SHOULD do, so a failure confirms the defect and a pass shows the
-- finding was wrong. Nothing is fixed here and no other file is touched.
-- Run: uv run python tools/c4sim/run.py test dls_agy_findings
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

_G.DLS_TEST_SYNC = true

local DRV = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua"
local XML = "drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.xml"
local VAR = 1001
local SEC = 1000
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

-- Presence server hooks (same shape as the other DLS tests).
local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000)
  return table.concat(replies)
end
local function snapshot(kstate, ksrc)
  return ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "Kitchen", kstate, ksrc, TOK)
end

local function fired(name)
  for _, e in ipairs(sim.events or {}) do if e.id == name then return true end end
  return false
end

local function count_ramps(id, lo, hi)
  local n = 0
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then
      local lv = s.params.LEVEL
      if (lo == nil or lv >= lo) and (hi == nil or lv <= hi) then n = n + 1 end
    end
  end
  return n
end
local function ons(id) return count_ramps(id, 1, nil) end
local function offs(id) return count_ramps(id, 0, 0) end

local function setprop(name, value)
  sim.Properties[name] = value
  sim.call("OnPropertyChanged", name)
end

local function start(rooms, at, extra, before)
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "120", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "51.5", ["Longitude"] = "-0.1", ["Presence"] = "Home",
    ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = rooms,
  }
  for k, v in pairs(extra or {}) do props[k] = v end
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, before = before })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  sim.sent = {}
  return ok
end

-- Rooms fixtures.
local PLAIN_30  = '[{"name":"Study","on":"06:00","off":"22:00","min_level":30,"max_level":30,"lights":[{"id":337,"kind":"lutron"}]}]'
local PLAIN_80  = '[{"name":"Study","on":"06:00","off":"22:00","min_level":80,"max_level":80,"lights":[{"id":337,"kind":"lutron"}]}]'
local PLAIN_10  = '[{"name":"Study","on":"06:00","off":"22:00","min_level":10,"max_level":10,"lights":[{"id":337,"kind":"lutron"}]}]'
local PLAIN_60  = '[{"name":"Study","on":"06:00","off":"22:00","min_level":60,"max_level":60,"lights":[{"id":337,"kind":"lutron"}]}]'

local PR_FOLLOW = '[{"name":"Kitchen","key":"Kitchen","on":"06:00","off":"22:00","min_level":60,"max_level":60,' ..
  '"presence":{"warnLevelPct":0,"graceSec":0,"arrival":false,"follow":true,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'
local PR_NOFOLLOW = '[{"name":"Kitchen","key":"Kitchen","on":"06:00","off":"22:00","min_level":60,"max_level":60,' ..
  '"presence":{"warnLevelPct":0,"graceSec":0,"arrival":false,"follow":false,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'
local OCC_ROOM = '[{"name":"Hall","on":"06:00","off":"22:00","min_level":60,"max_level":60,' ..
  '"occ":{"dev":900,"var":1000,"vacancyDelaySec":10},' ..
  '"lights":[{"id":337,"kind":"lutron"}]}]'

-- Finding 1: OnWatchedVariableChanged clears light.pending on ANY feedback that differs from the pending level
-- before the own-ramp filter runs. A light that stalls mid-ramp must still be tracked, so it is flagged offline.
t.test("finding 1: mid-ramp feedback keeps the pending confirmation", function()
  start(PLAIN_30, local_sec(19, 0), { ["Ramp Time (sec)"] = "90", ["Light Timeout (sec)"] = "120" },
    function(s) s.set_var(337, VAR, "0") end)
  sim.advance(2500)                                      -- first pass commands 30 at +2 s
  t.ok(count_ramps(337, 30, 30) >= 1, "first command sent")
  sim.set_var(337, VAR, "30")                            -- the light confirms once: fbSeen latches
  sim.advance(3 * SEC)
  t.ok(sim.persist.lightSeen and sim.persist.lightSeen["337"], "the light has confirmed before")

  sim.set_var(337, VAR, "0")                             -- dark again, so the next ramp starts at 0
  setprop("Rooms JSON", PLAIN_80)                        -- new target 80 over 90 s
  sim.advance(3 * SEC)                                   -- the 2 s Update sends 80
  t.ok(count_ramps(337, 80, 80) >= 1, "80 commanded with the pending confirmation armed")
  sim.fire_var(337, VAR, "20")                           -- dimmer reports 20 mid-ramp, then stalls there
  sim.events = {}
  sim.advance(140 * SEC)                                 -- well past the 120 s Light Timeout
  t.ok(fired("Light Not Responding"), "a light that stalls mid-ramp is still flagged offline")
end)

-- Finding 2: sendLevel sets the pending deadline to now + Light Timeout without the ramp time, so a healthy
-- light that reports only at the end of a long ramp is declared offline before it ever had a chance.
t.test("finding 2: a long ramp is not mistaken for a dead light", function()
  start(PLAIN_10, local_sec(19, 0), { ["Ramp Time (sec)"] = "120", ["Light Timeout (sec)"] = "30" },
    function(s) s.set_var(337, VAR, "0") end)
  sim.advance(2500)                                      -- first pass commands 10 at +2 s
  t.ok(count_ramps(337, 10, 10) >= 1, "first command sent")
  sim.set_var(337, VAR, "10")                            -- confirms once (fbSeen)
  sim.advance(3 * SEC)
  t.ok(sim.persist.lightSeen and sim.persist.lightSeen["337"], "the light has confirmed before")

  sim.set_var(337, VAR, "0")
  setprop("Rooms JSON", PLAIN_30)                        -- 30 over a 120 s ramp, timeout 30 s
  sim.advance(3 * SEC)
  t.ok(count_ramps(337, 30, 30) >= 1, "30 commanded over a 120 s ramp")
  sim.events = {}
  sim.advance(125 * SEC)                                 -- the device only reports when the ramp completes
  sim.set_var(337, VAR, "30")                            -- ramp finished: target reached
  sim.advance(3 * SEC)
  t.ok(not fired("Light Not Responding"), "a healthy light is not flagged before its ramp completes")
end)

-- Finding 3: a non-follow presence room is faded to 0 on vacancy (state VACANT), and the next Update takes the
-- "in window and occupied" branch (occupied() is true for a pr room) and switches the vacant room back on.
t.test("finding 3: a vacant non-follow presence room stays dark", function()
  start(PR_NOFOLLOW, local_sec(13, 0), { ["Presence Lighting"] = "On" },
    function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("1", "esp"))                             -- occupied: the schedule drives the room
  sim.advance(20 * SEC)
  t.ok(ons(101) >= 1, "occupied room lit by the schedule")
  sim.set_var(101, VAR, "60")
  sim.advance(3 * SEC)

  sim.sent = {}
  send(ln("OCC", "Kitchen", "0", "clear", TOK))          -- vacuum: off delay, then fade to 0
  sim.advance(12 * SEC)
  t.ok(offs(101) >= 1, "vacancy fade sent")
  sim.set_var(101, VAR, "0")
  sim.advance(10 * SEC)                                  -- FADING -> VACANT
  sim.sent = {}
  sim.advance(120 * SEC)                                 -- two schedule passes while the room is empty
  t.eq(ons(101), 0, "a vacant non-follow presence room is not turned back on by the schedule")
end)

-- Finding 4: Release Room Override clears the per-light hold but leaves room.pr.state == HOLD and never calls
-- prSave, so the occupied room keeps being treated as held (and the stale HOLD survives a reload).
t.test("finding 4: releasing the room override clears a presence HOLD", function()
  start(PR_FOLLOW, local_sec(13, 0), { ["Presence Lighting"] = "On" },
    function(s) s.set_var(101, VAR, "0") end)
  send(snapshot("1", "esp"))
  sim.advance(20 * SEC)
  sim.set_var(101, VAR, "60")
  sim.advance(3 * SEC)

  sim.fire_var(101, VAR, "0")                            -- hand off in an occupied room -> HOLD
  sim.advance(2 * SEC)
  local held = sim.persist.presence and sim.persist.presence.Kitchen
  t.eq(held and held.state, "HOLD", "manual off parked the room in HOLD")

  sim.sent = {}
  sim.exec("Release Room Override", { ROOM = "Kitchen" })
  t.ok(ons(101) >= 1, "the released occupied room is driven again")
  local after = sim.persist.presence and sim.persist.presence.Kitchen
  t.ok(after and after.state ~= "HOLD", "the persisted presence hold is cleared")
end)

-- Finding 5: OnWatchedVariableChanged returns early for a non-pr room when light.lastLevel is nil, so a manual
-- on before the first command is ignored and the vacancy enforcement switches the light straight back off.
t.test("finding 5: a manual on is honoured before the first command", function()
  start(OCC_ROOM, local_sec(23, 0), { ["Presence Lighting"] = "On" },
    function(s) s.set_var(337, VAR, "0") s.set_var(900, 1000, "0") end)
  sim.advance(20 * SEC)                                  -- outside the on window: no command, lastLevel stays nil
  t.eq(count_ramps(337, nil, nil), 0, "no level was ever commanded")
  sim.sent = {}
  sim.fire_var(337, VAR, "55")                           -- hand on the dimmer
  sim.advance(65 * SEC)                                  -- next schedule pass with the room confirmed vacant
  t.eq(offs(337), 0, "the manual on is held, not undone by the vacancy latch")
end)

-- Finding 6: switching Presence Lighting Off then On does not re-read occupancy, so a stale room.latchVacant
-- survives and the next Update turns off a room that is occupied.
t.test("finding 6: Presence Lighting off/on re-reads occupancy", function()
  start(OCC_ROOM, local_sec(13, 0), { ["Presence Lighting"] = "On" },
    function(s) s.set_var(337, VAR, "0") s.set_var(900, 1000, "0") end)
  sim.advance(12 * SEC)                                  -- vacancy confirmed: latchVacant = true
  setprop("Presence Lighting", "Off")
  sim.fire_var(900, 1000, "1")                           -- someone enters while presence lighting is Off
  sim.sent = {}
  sim.advance(2 * 60 * SEC)                              -- the schedule lights the occupied room
  t.ok(ons(337) >= 1, "the schedule lights the room while Presence Lighting is Off")
  sim.set_var(337, VAR, "60")
  sim.advance(2 * SEC)

  sim.sent = {}
  setprop("Presence Lighting", "On")
  sim.advance(30 * SEC)
  t.eq(offs(337), 0, "switching Presence Lighting back On does not turn off an occupied room")
end)

-- Finding 7: LogStatus passes nil Latitude/Longitude straight into SunPosition, which raises on rad(lat), so
-- the command aborts. It must report instead of erroring when lat/lon are empty.
t.test("finding 7: LogStatus tolerates empty Latitude/Longitude", function()
  start(PLAIN_60, local_sec(13, 0), { ["Latitude"] = "", ["Longitude"] = "" },
    function(s) s.set_var(337, VAR, "0") end)
  sim.prints = {}
  sim.errors = {}
  local ok = sim.exec("LUA_ACTION", { ACTION = "LogStatus" })
  t.ok(ok, "LogStatus completes with empty Latitude/Longitude (no arithmetic on nil)")
  t.eq(#sim.errors, 0, "no driver error was logged")
end)

t.finish("dls-agy-findings")
