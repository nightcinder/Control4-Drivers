local sim = require("c4sim")
local t   = require("t")

local JF_LUA = "drivers/jellyfin/driver.lua"
local JF_XML = "drivers/jellyfin/driver.xml"

local JF_PLAYING_JSON = '[{' ..
  '"Id":"sess-jf-1","UserName":"Nick","DeviceName":"Living Room Shield","Client":"Jellyfin Android TV",' ..
  '"PlayState":{"IsPaused":false,"PositionTicks":600000000},' ..
  '"NowPlayingItem":{' ..
    '"Id":"item-101","Type":"Episode","SeriesName":"Severance",' ..
    '"ParentIndexNumber":1,"IndexNumber":2,"Name":"Half Loop",' ..
    '"RunTimeTicks":18000000000,"ProductionYear":2022,' ..
    '"ImageTags":{"Primary":"tag1"}' ..
  '}' ..
'}]'

local PLEX_PAUSED_JSON = '{"MediaContainer":{"Metadata":[{' ..
  '"type":"movie","title":"Dune","year":2021,"ratingKey":"rk99",' ..
  '"viewOffset":120000,"duration":9000000,"thumb":"/library/metadata/99/thumb",' ..
  '"Player":{"state":"paused","machineIdentifier":"plex-client-1","title":"Apple TV","product":"Plex"},' ..
  '"User":{"title":"Nick"},' ..
  '"Session":{"id":"plex-sess-1"}' ..
'}]}}'

t.test("jellyfin: dual-backend priority, variables, events, transport, and LUA_ACTION unwrap", function()
  local ok = sim.load_driver(JF_LUA, {
    xml = JF_XML,
    deviceId = 100,
    properties = {
      ["Jellyfin Enabled"] = "On",
      ["Jellyfin URL"] = "http://192.0.2.40:8096",
      ["Jellyfin API Key"] = "jf-api-key",
      ["Plex Enabled"] = "On",
      ["Plex URL"] = "http://192.0.2.41:32400",
      ["Plex Token"] = "plex-tok",
      ["Poll Interval Seconds"] = "4",
    },
    before = function(s)
      s.queue_http("/Sessions", "[]", 200)
      s.queue_http("/status/sessions", '{"MediaContainer":{}}', 200)
    end,
  })
  t.ok(ok, "jellyfin loaded: " .. tostring(sim.errors[1]))
  t.eq(sim._store["Driver Version"], "0.3.2", "version bumped to 0.3.2")

  -- Startup poll runs at 1s and primes baseline state without firing events.
  sim.advance(1500)
  t.eq(sim._store["Active Source"], "None", "initial Active Source None")
  t.eq(#sim.events, 0, "priming poll fires no events")

  -- Next poll: Jellyfin is Playing while Plex is Paused -> Playing wins.
  sim.queue_http("/Sessions", JF_PLAYING_JSON, 200)
  sim.queue_http("/status/sessions", PLEX_PAUSED_JSON, 200)
  sim.advance(4000)

  t.eq(sim._store["Active Source"], "Jellyfin", "playing Jellyfin beats paused Plex")
  t.eq(sim.dvars["Play State"], "Playing", "Play State Playing")
  t.eq(sim.dvars["Now Playing Title"], "Severance", "SeriesName used for episode title")
  t.eq(sim.dvars["Now Playing Subtitle"], "S01E02 Half Loop", "SxxExx subtitle formatted")
  t.eq(sim.dvars["Position"], "1:00", "Position 60s -> 1:00")
  t.eq(sim.dvars["Runtime"], "30:00", "Runtime 1800s -> 30:00")

  local seenEv = {}
  for _, e in ipairs(sim.events) do seenEv[e.id] = true end
  t.ok(seenEv[1], "Play State Changed (1) fired")
  t.ok(seenEv[2], "Playback Started (2) fired")
  t.ok(seenEv[4], "Now Playing Item Changed (4) fired")

  -- Regression check: LUA_ACTION unwrapping for PLAY_PAUSE and TEST_CONNECTION.
  sim.http = {}
  sim.queue_http("/Playing/PlayPause", "", 204)
  sim.exec("LUA_ACTION", { ACTION = "PLAY_PAUSE" })
  sim.advance(0)
  t.ok(#sim.http >= 1 and sim.http[1].method == "POST", "LUA_ACTION PLAY_PAUSE sent POST")
  t.ok(string.find(sim.http[1].url, "/Sessions/sess-jf-1/Playing/PlayPause", 1, true) ~= nil,
       "transport targets active Jellyfin session")

  -- Seek To Percent command (50% of 1800s = 900s = 9000000000 ticks).
  sim.http = {}
  sim.queue_http("/Playing/Seek", "", 204)
  sim.exec("Seek To Percent", { Percent = "50" })
  sim.advance(0)
  t.ok(string.find(sim.http[1].url, "seekPositionTicks=9000000000", 1, true) ~= nil,
       "Seek To Percent computes 50% ticks")

  -- TEST_CONNECTION action updates Server Name from /System/Info.
  sim.queue_http("/System/Info", '{"ServerName":"CinemaJF"}', 200)
  sim.queue_http("/identity", '{"MediaContainer":{}}', 200)
  sim.exec("LUA_ACTION", { ACTION = "TEST_CONNECTION" })
  sim.advance(0)
  t.eq(sim._store["Server Name"], "CinemaJF", "Server Name populated from /System/Info")

  -- When both backends stop, Playback Stopped (3) fires.
  sim.events = {}
  sim.queue_http("/Sessions", "[]", 200)
  sim.queue_http("/status/sessions", '{"MediaContainer":{}}', 200)
  sim.exec("LUA_ACTION", { ACTION = "REFRESH_NOW" })
  sim.advance(500)
  t.eq(sim._store["Active Source"], "None", "Active Source reset to None")
  local sawStop = false
  for _, e in ipairs(sim.events) do if e.id == 3 then sawStop = true end end
  t.ok(sawStop, "Playback Stopped (3) fired")
end)

t.finish("jellyfin")
