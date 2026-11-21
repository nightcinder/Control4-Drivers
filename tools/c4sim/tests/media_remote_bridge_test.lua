local sim = require("c4sim")
local t   = require("t")

local MRB_LUA = "drivers/media-remote-bridge-untested/driver.lua"
local MRB_XML = "drivers/media-remote-bridge-untested/driver.xml"

local AUTH_HDR = "Authorization: Bearer tok-mrb-123\r\n"

local function load_mrb(extraProps)
  local p = {
    ["Server Port"] = "8765",
    ["Server Token"] = "tok-mrb-123",
    ["Active Room"] = "Upstairs",
    ["Lock Room"] = "Off",
    ["Upstairs Device ID"] = "401",
    ["Downstairs Device ID"] = "402",
    ["Log Mode"] = "Off",
  }
  if extraProps then for k, v in pairs(extraProps) do p[k] = v end end
  local ok = sim.load_driver(MRB_LUA, {
    xml = MRB_XML,
    deviceId = 100,
    properties = p,
    before = function(s)
      s.set_device_vars(401, {
        ["1"] = { name = "CURRENT_VOLUME", value = "35" },
        ["2"] = { name = "IS_MUTED", value = "0" },
        ["3"] = { name = "POWER_STATE", value = "1" },
      })
      s.set_device_vars(402, {
        ["1"] = { name = "CURRENT_VOLUME", value = "20" },
        ["2"] = { name = "IS_MUTED", value = "1" },
        ["3"] = { name = "POWER_STATE", value = "0" },
      })
    end,
  })
  t.ok(ok, "mrb loaded: " .. tostring(sim.errors[1]))
  t.eq(#sim.errors, 0, "mrb init had no errors")
end

local nextHandle = 10
local function send_http(rawReq, chunked)
  nextHandle = nextHandle + 1
  local h = nextHandle
  if chunked then
    local mid = math.floor(#rawReq / 2)
    sim.call("OnServerDataIn", h, rawReq:sub(1, mid), "192.0.2.80", 50000)
    sim.call("OnServerDataIn", h, rawReq:sub(mid + 1), "192.0.2.80", 50000)
  else
    sim.call("OnServerDataIn", h, rawReq, "192.0.2.80", 50000)
  end
  local reply = sim.net.server_sent[#sim.net.server_sent]
  return reply and reply.data or "", h
end

t.test("media-remote-bridge: auth, chunked status, nowplaying TTL, toggle, volume, room switch", function()
  load_mrb()
  t.eq(sim.net.servers[8765], "tcp", "TCP server created on port 8765")

  -- Unauthorized request -> 401 and client closed.
  local r401, h1 = send_http("GET /v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
  t.ok(string.find(r401, "401 Unauthorized", 1, true) ~= nil, "missing token returns 401")
  t.eq(sim.net.server_closed[#sim.net.server_closed].handle, h1, "client connection closed after reply")

  -- Chunked authorized GET /v1/status returns Upstairs status and variables.
  local r200 = send_http("GET /v1/status HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n", true)
  t.ok(string.find(r200, "200 OK", 1, true) ~= nil, "chunked status returns 200 OK")
  t.ok(string.find(r200, '"active_room":"Upstairs"', 1, true) ~= nil, "active_room Upstairs")
  t.ok(string.find(r200, '"volume":35', 1, true) ~= nil, "Upstairs volume 35")

  -- POST /v1/nowplaying sets fresh playing=true; toggle pauses and updates guess to false.
  local rNp = send_http("POST /v1/nowplaying?room=Upstairs&title=Track%201&artist=Band&app=Plex&playing=1 HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  t.ok(string.find(rNp, "200 OK", 1, true) ~= nil, "nowplaying accepted")

  sim.sent = {}
  send_http("POST /v1/command/toggle HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  local pauseCmd = sim.last_sent("PAUSE")
  t.ok(pauseCmd ~= nil and pauseCmd.id == 401, "toggle with playing=1 sends PAUSE to Upstairs (401)")

  -- Advance past NOWPLAYING_MAX_AGE (45s) so nowplaying expires and toggle uses playGuess (false -> PLAY).
  sim.advance(46000)
  sim.sent = {}
  send_http("POST /v1/command/toggle HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  local playCmd = sim.last_sent("PLAY")
  t.ok(playCmd ~= nil and playCmd.id == 401, "toggle after TTL expiry uses tracked guess -> PLAY")

  -- Volume set valid (60) vs out of range (150).
  sim.sent = {}
  send_http("POST /v1/command/volume_set?level=60 HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  local volCmd = sim.last_sent("SET_VOLUME_LEVEL")
  t.ok(volCmd ~= nil and volCmd.id == 401 and volCmd.params.LEVEL == 60, "volume_set 60 sent to 401")

  local rBadVol = send_http("POST /v1/command/volume_set?level=150 HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  t.ok(string.find(rBadVol, "400 Bad Request", 1, true) ~= nil, "volume_set 150 returns 400")

  -- Switch active room to Downstairs and send next -> SKIP_FWD to 402.
  send_http("POST /v1/command/set_active_room?room=Downstairs HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  t.eq(sim._store["Active Room"], "Downstairs", "Active Room switched to Downstairs")
  sim.sent = {}
  send_http("POST /v1/command/next HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  local nextCmd = sim.last_sent("SKIP_FWD")
  t.ok(nextCmd ~= nil and nextCmd.id == 402, "next sends SKIP_FWD to Downstairs (402)")

  -- Oversized payload (> 16384 bytes) returns 413.
  local r413 = send_http("GET /v1/status HTTP/1.1\r\nX-Pad: " .. string.rep("A", 16500) .. "\r\n\r\n")
  t.ok(string.find(r413, "413 Payload Too Large", 1, true) ~= nil, "oversized request returns 413")
end)

t.test("media-remote-bridge: Lock Room prevents room switching", function()
  load_mrb({ ["Lock Room"] = "On" })
  local rLock = send_http("POST /v1/command/set_active_room?room=Downstairs HTTP/1.1\r\n" .. AUTH_HDR .. "\r\n")
  t.ok(string.find(rLock, "400 Bad Request", 1, true) ~= nil, "locked room rejects set_active_room")
  t.eq(sim._store["Active Room"], "Upstairs", "Active Room remains Upstairs")
end)

t.finish("media-remote-bridge")
