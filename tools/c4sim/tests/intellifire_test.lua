local sim = require("c4sim")
local t   = require("t")

local IF_LUA = "drivers/intellifire/IntelliFire_driver.lua"
local IF_XML = "drivers/intellifire/IntelliFire_driver.xml"

local API_KEY = "0123456789abcdef0123456789abcdef"
local CHALLENGE = "aabbccddeeff00112233445566778899"

local function load_if()
  local ok = sim.load_driver(IF_LUA, {
    xml = IF_XML,
    deviceId = 100,
    properties = {
      ["Fireplace IP Address"] = "192.0.2.30",
      ["API User ID"] = "user1",
      ["API Key"] = API_KEY,
      ["Poll Interval (seconds)"] = "20",
      ["Log Mode"] = "Off",
    },
    before = function(s)
      s.queue_http("/poll", '{"power":0,"pilot":1,"height":2}', 200)
    end,
  })
  t.ok(ok, "intellifire loaded: " .. tostring(sim.errors[1]))
  t.eq(#sim.errors, 0, "intellifire init had no errors")
end

t.test("intellifire: poll state, FireEventByID transitions, and page hello", function()
  load_if()
  t.eq(sim._store["Driver Version"], "215", "version bumped to 215")

  -- Pump initial poll queued during OnDriverLateInit.
  sim.advance(0)
  t.eq(#sim.events, 0, "initial poll does not fire power events")

  -- Advance past 10s poll cooldown, then poll with power=1, height=3 (Flame4).
  sim.advance(10000)
  sim.queue_http("/poll", '{"power":1,"pilot":1,"height":3}', 200)
  sim.exec("UI_REFRESH", {})
  sim.advance(0)

  t.eq(#sim.events, 1, "power 0->1 fires EVT_FIRE_ON (1)")
  t.eq(sim.events[1].id, 1, "event id is 1")
  local ic = sim.last_sent("ICON_CHANGED")
  t.ok(ic ~= nil and ic.params.icon == "Flame4", "tile icon updated to Flame4")

  -- Page build checks.
  sim.exec("UI_HELLO_3", {})
  t.eq(sim._store["Web Page Status"], "Page build 3 OK", "build 3 OK")
  sim.exec("UI_HELLO_1", {})
  t.ok(string.find(sim._store["Web Page Status"] or "", "PAGE IS STALE", 1, true) ~= nil, "stale page flagged")

  -- Next poll transitions power 1->0 and fires EVT_FIRE_OFF (2).
  sim.events = {}
  sim.advance(10000)
  sim.queue_http("/poll", '{"power":0,"pilot":0,"height":0}', 200)
  sim.exec("UI_REFRESH", {})
  sim.advance(0)
  t.eq(#sim.events, 1, "power 1->0 fires EVT_FIRE_OFF (2)")
  t.eq(sim.events[1].id, 2, "event id is 2")
end)

t.test("intellifire: double-SHA256 challenge signing and debounced flame height", function()
  load_if()
  sim.advance(0)
  sim.advance(10000)
  sim.queue_http("/poll", '{"power":1,"pilot":1,"height":1}', 200)
  sim.exec("UI_REFRESH", {})
  sim.advance(0)

  -- Rapid taps on UI_FLAME_2 then UI_FLAME_5 collapse into one flame_height=4 after 700ms.
  sim.http = {}
  sim.queue_http("/get_challenge", CHALLENGE, 200)
  sim.queue_http("/post", "OK", 200)
  sim.exec("UI_FLAME_2", {})
  sim.exec("UI_FLAME_5", {})
  t.eq(#sim.http, 0, "debounced flame command not sent before 700ms")

  -- Advance 700ms so OnFlameDebounceTimer fires via _G[handlerName], then pump /get_challenge and /post.
  sim.advance(700)
  sim.advance(0)

  t.eq(#sim.http, 2, "challenge GET followed by signed POST")
  t.eq(sim.http[1].method, "GET", "step 1 is GET /get_challenge")
  t.eq(sim.http[2].method, "POST", "step 2 is POST /post")

  local expectedSig = sim.env.ComputeCommandSigning(CHALLENGE, API_KEY, "flame_height", 4)
  local expectedBody = "command=flame_height&value=4&user=user1&response=" .. expectedSig
  t.eq(sim.http[2].body, expectedBody, "POST body matches nested SHA-256 signature")
end)

t.finish("intellifire")
