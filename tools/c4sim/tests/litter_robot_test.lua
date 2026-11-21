local sim = require("c4sim")
local t   = require("t")

local LR_LUA = "drivers/litter-robot/driver.lua"
local LR_XML = "drivers/litter-robot/driver.xml"

t.test("litter-robot: baseline, cat visits, settle wait, threshold reset, drawer full, unreachable", function()
  local startSec = 10000
  local ok = sim.load_driver(LR_LUA, {
    xml = LR_XML,
    deviceId = 100,
    start_ms = startSec * 1000,
    properties = {
      ["Bridge Host"] = "192.0.2.60",
      ["Bridge Port"] = "8793",
      ["Poll Interval"] = "15",
      ["Visits Before Clean"] = "2",
      ["Settle Minutes"] = "10",
      ["Log Mode"] = "Print",
    },
    before = function(s)
      s.queue_http("/status", string.format(
        '{"ok":true,"status":"ready","visits_since_reset":0,"last_visit_ts":%d,"cat_in_box":false,"drawer_full":false,"waste_drawer_pct":25.0}',
        startSec - 1200
      ), 200)
    end,
  })
  t.ok(ok, "litter-robot loaded: " .. tostring(sim.errors[1]))
  t.eq(sim._store["Driver Version"], "1.0.6", "version bumped to 1.0.6")

  -- Initial poll runs at 1s.
  sim.advance(1000)
  t.eq(sim._store["Status"], "Connected", "Connected after initial poll")
  t.eq(sim._store["Drawer Level"], "25.0%", "Drawer Level formatted")
  t.eq(#sim.events, 0, "baseline poll fires no events")

  -- Second poll: 2 visits detected, but last_visit_ts is only 60s ago (< 10m settle) -> fires 2 visit events, not threshold.
  local recentTs = sim.env.os.time() - 60
  sim.queue_http("/status", string.format(
    '{"ok":true,"status":"ready","visits_since_reset":2,"last_visit_ts":%d,"cat_in_box":false,"drawer_full":false,"waste_drawer_pct":30.0}',
    recentTs
  ), 200)
  sim.advance(15000)
  t.eq(#sim.events, 2, "2 new visits fire 2 Cat Visit Detected events")
  t.eq(sim.events[1].id, "Cat Visit Detected", "Cat Visit Detected fired by name")
  t.eq(sim._store["Visits Since Clean"], "2", "Visits Since Clean = 2")

  -- Third poll after settle window (last_visit_ts 700s ago) + drawer_full=true -> fires Drawer Full + Visit Threshold Reached + POST /reset-visits.
  sim.events = {}
  local settledTs = sim.env.os.time() - 700
  sim.queue_http("/status", string.format(
    '{"ok":true,"status":"drawer_full","visits_since_reset":2,"last_visit_ts":%d,"cat_in_box":false,"drawer_full":true,"waste_drawer_pct":95.0}',
    settledTs
  ), 200)
  sim.queue_http("/reset%-visits", '{"ok":true}', 200)
  sim.advance(15000)
  sim.advance(0)

  local seen = {}
  for _, e in ipairs(sim.events) do seen[e.id] = true end
  t.ok(seen["Drawer Full"], "Drawer Full event fired")
  t.ok(seen["Visit Threshold Reached"], "Visit Threshold Reached event fired after settle")
  t.eq(sim._store["Visits Since Clean"], "0", "POST /reset-visits reset counter to 0")

  -- Regression check for forward-declared logmsg in fire() when C4:FireEvent errors.
  local origFire = sim.env.C4.FireEvent
  sim.env.C4.FireEvent = function() error("simulated FireEvent error") end
  sim.prints = {}
  sim.exec("LUA_ACTION", { ACTION = "FIRE_TEST_THRESHOLD" })
  sim.env.C4.FireEvent = origFire
  t.eq(#sim.errors, 0, "fire() error branch logs via forward-declared logmsg without nil error")
  local loggedErr = false
  for _, p in ipairs(sim.prints) do
    if string.find(p, "FireEvent(Visit Threshold Reached) failed", 1, true) then loggedErr = true end
  end
  t.ok(loggedErr, "fire() failure logged via logmsg")

  -- Unreachable transition fires Bridge Unreachable once.
  sim.events = {}
  sim.queue_http("/status", "", 500, nil, "connection refused")
  sim.advance(15000)
  t.eq(sim._store["Status"], "Bridge unreachable", "Status Bridge unreachable")
  t.eq(#sim.events, 1, "Bridge Unreachable event fired")
  t.eq(sim.events[1].id, "Bridge Unreachable", "event name is Bridge Unreachable")
end)

t.finish("litter-robot")
