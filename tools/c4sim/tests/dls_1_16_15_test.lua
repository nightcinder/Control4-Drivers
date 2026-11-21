-- DLS 1.16.15 regression tests: defects A, B and robustness gaps D1-D3.
-- Written before fixing the driver (red-then-green).
-- Run: uv run python tools/c4sim/run.py test dls_1_16_15
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

local replies = {}
C4.ServerSend = function(_, handle, data) replies[#replies + 1] = tostring(data) end
C4.ServerCloseClient = function(_, handle) end
local function ln(...) return table.concat({ ... }, " ") .. "\r\n" end
local function send(data)
  replies = {}
  sim.call("OnServerDataIn", 1, data, "192.0.2.5", 50000)
  return table.concat(replies)
end
local function snap_one(room, state, src)
  return ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", room, state, src, TOK)
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

local function start(rooms, at, extra, before)
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "5", ["Ramp Time (sec)"] = "90",
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

local PR_NOFOLLOW = '[{"name":"Kitchen","key":"Kitchen","on":"06:00","off":"22:00","min_level":60,"max_level":60,' ..
  '"presence":{"follow":false,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'

local PR_BOTH = '[{"name":"Kitchen","key":"Kitchen","on":"06:00","off":"22:00","min_level":60,"max_level":60,' ..
  '"presence":{"follow":true,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5},' ..
  '"lights":[{"id":101,"kind":"lutron"}]},' ..
  '{"name":"Hall","key":"Hall","on":"06:00","off":"22:00","min_level":60,"max_level":60,' ..
  '"presence":{"follow":false,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5},' ..
  '"lights":[{"id":102,"kind":"lutron"}]}]'

local PR_DEN_OFF_RAMP = '[{"name":"Den","key":"Den","on":"18:00","off":"23:45","off_ramp_min":30,' ..
  '"min_level":60,"max_level":60,"presence":{"follow":false,"offDelaySec":10,"fadeInSec":2,"fadeOutSec":5},' ..
  '"lights":[{"id":101,"kind":"lutron"}]}]'

local PLAIN_DEN_2 = '[{"name":"Den","on":"18:00","off":"23:00","lights":[{"id":337,"kind":"lutron"},{"id":338,"kind":"lutron"}]}]'

local OCC_ROOM = '[{"name":"Hall","on":"06:00","off":"22:00","min_level":60,"max_level":60,' ..
  '"occ":{"dev":900,"var":1000,"vacancyDelaySec":10},' ..
  '"lights":[{"id":337,"kind":"lutron"}]}]'

t.test("A1: non-follow presence room lights immediately on VACANT -> OCCUPIED", function()
  start(PR_NOFOLLOW, local_sec(13, 0), { ["Presence Lighting"] = "On", ["Update Interval (min)"] = "5" },
    function(s) s.set_var(101, VAR, "0") end)
  send(snap_one("Kitchen", "0", "clear"))
  sim.advance(20 * SEC)
  t.eq(ons(101), 0, "vacant non-follow room stays dark")

  sim.sent = {}
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.eq(ons(101), 1, "lights commanded in the same tick on VACANT -> OCCUPIED")
end)

t.test("A2: non-follow presence room lights immediately when reconcile opens gate", function()
  start(PR_NOFOLLOW, local_sec(13, 0), { ["Presence Lighting"] = "On", ["Update Interval (min)"] = "5" },
    function(s) s.set_var(101, VAR, "0") end)
  sim.sent = {}
  send(snap_one("Kitchen", "1", "esp"))
  t.eq(ons(101), 1, "lights commanded in the same tick when reconcile opens the gate")
end)

t.test("A3: follow presence room gets only one command (no double send)", function()
  start(PR_BOTH, local_sec(13, 0), { ["Presence Lighting"] = "On", ["Update Interval (min)"] = "5" },
    function(s) s.set_var(101, VAR, "0") s.set_var(102, VAR, "0") end)
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "2", TOK)
    .. ln("OCC", "Kitchen", "0", "clear", TOK) .. ln("OCC", "Hall", "0", "clear", TOK))
  sim.advance(20 * SEC)

  sim.sent = {}
  send(ln("OCC", "Kitchen", "1", "esp", TOK))
  t.eq(ons(101), 1, "follow room receives one command on OCC")

  sim.sent = {}
  send(ln("OCC", "Hall", "1", "esp", TOK))
  t.eq(ons(101), 0, "follow room does not get a second command when non-follow room updates")
end)

t.test("B: vacancy fade cancels active stepped off-fade (off_ramp_min 30)", function()
  start(PR_DEN_OFF_RAMP, local_sec(23, 43), { ["Presence Lighting"] = "On", ["Update Interval (min)"] = "1" },
    function(s) s.set_var(101, VAR, "60") end)
  send(snap_one("Den", "1", "esp"))
  sim.advance(20 * SEC)
  sim.set_var(101, VAR, "60")
  sim.sent = {}

  sim.advance(2 * 60 * SEC)                              -- 23:45:20: past 23:45 off edge
  t.ok(ons(101) >= 1, "stepped off-fade started above 0")
  sim.set_var(101, VAR, "58")
  sim.sent = {}

  send(ln("OCC", "Den", "0", "clear", TOK))
  sim.advance(12 * SEC)                                  -- past 10 s offDelaySec -> prStartFade
  t.ok(offs(101) >= 1, "vacancy fade commanded 0")
  sim.set_var(101, VAR, "0")
  sim.advance(8 * SEC)                                   -- fade finishes -> PR_VACANT
  sim.sent = {}

  sim.advance(180 * SEC)                                 -- 3 more 60 s off-fade step ticks
  t.eq(ons(101), 0, "no stepped off-fade command above 0 after vacancy fade")
end)

t.test("D1: sendQ wraps callbacks in pcall, logs errors, and keeps draining", function()
  _G.DLS_TEST_SYNC = nil
  start(PLAIN_DEN_2, local_sec(19, 0), { ["Update Interval (min)"] = "1" },
    function(s) s.set_var(337, VAR, "40") s.set_var(338, VAR, "40") end)

  local origSend = C4.SendToDevice
  local calls = 0
  C4.SendToDevice = function(self, id, cmd, params)
    calls = calls + 1
    if calls == 1 then error("simulated send failure") end
    return origSend(self, id, cmd, params)
  end

  sim.sent = {}
  sim.prints = {}
  sim.errors = {}
  sim.advance(2010)                                      -- 2 s Update enqueues 337 and 338
  sim.advance(900)                                       -- 3 ticks: 1st raises, 2nd sends 338, 3rd cancels timer
  local sent338 = count_ramps(338, 1, nil)

  sim.sent = {}
  sim.set_var(337, VAR, "0")
  sim.exec("LUA_ACTION", { ACTION = "RecalcNow" })
  sim.advance(600)
  local sent337After = count_ramps(337, 1, nil)

  C4.SendToDevice = origSend
  _G.DLS_TEST_SYNC = true

  t.eq(#sim.errors, 0, "no uncaught error in sendQ timer: " .. tostring(sim.errors[1]))
  t.eq(sent338, 1, "second queued command still ran after first failed")
  local logged = false
  for _, line in ipairs(sim.prints) do
    if line:find("sendQ failed", 1, true) and line:find("simulated send failure", 1, true) then
      logged = true
      break
    end
  end
  t.ok(logged, "sendQ error was logged via print")
  t.eq(sent337After, 1, "sendQ restarted cleanly for subsequent commands")
end)

t.test("D2: startVacancyTimer callback uses safeUpdate (catches Update errors)", function()
  start(OCC_ROOM, local_sec(13, 0), { ["Presence Lighting"] = "On", ["Update Interval (min)"] = "5" },
    function(s) s.set_var(337, VAR, "0") s.set_var(900, 1000, "0") end)
  sim.advance(3 * SEC)                                   -- let 2 s property-change Update pass
  sim.errors = {}
  sim.prints = {}
  sim.env.Update = function() error("vacancy update boom") end
  sim.advance(9 * SEC)                                   -- 10 s vacancy timer fires before 15 s settle timer

  t.eq(#sim.errors, 0, "no uncaught error from vacancy timer: " .. tostring(sim.errors[1]))
  local logged = false
  for _, line in ipairs(sim.prints) do
    if line:find("[DLS] Update failed:", 1, true) and line:find("vacancy update boom", 1, true) then
      logged = true
      break
    end
  end
  t.ok(logged, "safeUpdate caught and logged Update error in vacancy timer")
end)

t.test("D3: OnDriverDestroyed cancels sendTimer and clears sendQ", function()
  _G.DLS_TEST_SYNC = nil
  start(PLAIN_DEN_2, local_sec(19, 0), { ["Update Interval (min)"] = "1" },
    function(s) s.set_var(337, VAR, "40") s.set_var(338, VAR, "40") end)
  sim.sent = {}
  sim.errors = {}
  sim.advance(2010)                                      -- enqueues both commands onto sendQ
  sim.call("OnDriverDestroyed")
  sim.advance(2000)
  local afterCount = #sim.sent

  _G.DLS_TEST_SYNC = true

  t.eq(afterCount, 0, "no queued commands sent after OnDriverDestroyed")
  t.eq(#sim.errors, 0, "no errors after OnDriverDestroyed: " .. tostring(sim.errors[1]))
end)

t.finish("dls-1-16-15")
