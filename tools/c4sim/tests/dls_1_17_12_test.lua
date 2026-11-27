-- DLS 1.17.12: remote log resend loop (2026-11-26 live case).
-- 1.17.11 was loaded at 23:28:40, two minutes before the 23:30 off. Loki then showed "scheduled off Downstairs" and
-- step 1 of both fades every 15 s for 40 min. The lighting ran once; the copies came from the remote log: every
-- post reached Loki (Alloy answered 204) but the callback counted as failed, so the whole buffer was re-posted.
-- Run: python tools/c4sim/run.py test dls_1_17_12
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
local DOWN = { 480, 478, 476 }
local LIV = { 331, 333, 335 }

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
local function levels(id)
  local out = {}
  for _, s in ipairs(sim.sent) do
    if s.id == id and s.cmd == "RAMP_TO_LEVEL" then out[#out + 1] = tonumber(s.params.LEVEL) end
  end
  return out
end
local function last(id) local lv = levels(id) return lv[#lv] end
local function mirror(ids)
  for _, id in ipairs(ids) do
    local v = last(id)
    if v then sim.set_var(id, VAR, tostring(v)) end
  end
end
local function nprinted(s)
  local n = 0
  for _, p in ipairs(sim.prints or {}) do if tostring(p):find(s, 1, true) then n = n + 1 end end
  return n
end
local function nposted(s)
  local n = 0
  for _, r in ipairs(sim.http) do
    local b = r.body or ""
    local i = 1
    while true do
      local a, e = b:find(s, i, true)
      if not a then break end
      n, i = n + 1, e + 1
    end
  end
  return n
end
-- every remote log post gets this reply (2xx with a non-empty error string reproduces the live requeue)
local function answer(n, code, err)
  for _ = 1, n do sim.queue_http("loki", "", code, nil, err) end
end

local ROOMS = '[{"name":"Downstairs","type":"lutron","on":"18:00","off":"23:30","off_ramp_min":30,' ..
  '"min_level":20,"max_level":20,"lights":[{"id":480,"kind":"lutron"},{"id":478,"kind":"lutron"},{"id":476,"kind":"lutron"}]},' ..
  '{"name":"Living Room","key":"LivingRoom","type":"lutron","on":"18:00","off":"23:30","off_ramp_min":30,' ..
  '"min_level":20,"max_level":20,"presence":{"graceSec":0,"arrival":false,"follow":true,"offDelaySec":1200,' ..
  '"fadeInSec":2,"fadeOutSec":30,"nightLevel":5,"sources":["esp"]},' ..
  '"lights":[{"id":331,"kind":"lutron"},{"id":333,"kind":"lutron"},{"id":335,"kind":"lutron"}]}]'

local function load(at, persist, levelsAt)
  local props = {
    ["Enabled"] = "On", ["Update Interval (min)"] = "1", ["Ramp Time (sec)"] = "90",
    ["Override Hold (min)"] = "120", ["Scene Hold (min)"] = "240", ["Cloud Cover Source"] = "None (assume clear)",
    ["Latitude"] = "40.8", ["Longitude"] = "-81.5", ["Presence"] = "Home", ["Presence Lighting"] = "On",
    ["Debug"] = "On", ["Presence Port"] = "8730", ["Presence Token"] = TOK, ["Rooms JSON"] = ROOMS,
    ["Remote Log URL"] = "http://loki.test/push",
  }
  local ok = sim.load_driver(DRV, { xml = XML, properties = props, start_ms = at * SEC, persist = persist,
    before = function(s)
      for _, id in ipairs(DOWN) do s.set_var(id, VAR, tostring(levelsAt)) end
      for _, id in ipairs(LIV) do s.set_var(id, VAR, tostring(levelsAt)) end
    end })
  t.ok(ok, "load: " .. tostring(sim.errors[1]))
  send(ln("PRESENCE", "HOME", TOK) .. ln("HELLO", "1", "1", TOK) .. ln("OCC", "LivingRoom", "1", "esp", TOK))
  return ok
end

t.test("version 1.17.12 or later", function()
  load(local_sec(12, 0), nil, 0)
  t.ok(tostring(sim.env.DRIVER_VERSION):match("^1%.17%.1%d$") ~= nil, "DRIVER_VERSION 1.17.1x")
end)

t.test("live 2026-11-26: reload at 23:28, off at 23:30, occupied Living Room, Update every 15 s for 40 min", function()
  load(local_sec(23, 20), nil, 20)
  answer(400, 204, "No Content")
  for _ = 1, 8 * 4 do                                -- 23:20 -> 23:28, in window
    send(ln("OCC", "LivingRoom", "1", "esp", TOK))
    sim.advance(15 * SEC)
    mirror(DOWN) mirror(LIV)
  end
  local saved = sim.persist
  t.ok(type(saved.wasInWindow) == "table" and saved.wasInWindow.Downstairs ~= nil, "in-window state persisted")
  load(local_sec(23, 28), saved, 20)                 -- the 23:28 reload
  answer(400, 204, "No Content")
  sim.prints, sim.sent, sim.http = {}, {}, {}
  for _ = 1, 40 * 4 do                               -- 23:28 -> 00:08, event-driven passes every 15 s
    send(ln("OCC", "LivingRoom", "1", "esp", TOK))
    sim.call("Update")
    sim.advance(15 * SEC)
    mirror(DOWN) mirror(LIV)
  end
  t.eq(nprinted("scheduled off Downstairs"), 1, "Downstairs off edge once")
  t.eq(nprinted("presence off edge, occupied: glide to night level Living Room"), 1, "Living Room glide once")
  t.eq(nprinted("step 1 of"), 6, "step 1 sent once per light")
  for _, id in ipairs(DOWN) do t.eq(last(id), 0, "Downstairs " .. id .. " faded to 0") end
  for _, id in ipairs(LIV) do t.eq(last(id), 5, "Living Room " .. id .. " glided to night level 5") end
  t.ok(#sim.http > 10, "remote log posted (" .. #sim.http .. ")")
  t.eq(nposted("scheduled off Downstairs"), 1, "the off edge line is posted once, not re-posted every 15 s")
  t.eq(nposted("off fade step Downstairs 480 level 19 step 1 of 30"), 1, "step 1 line posted once")
end)

t.test("remote log: a line is posted at most 1 + 3 times while posts keep failing, and the reason is logged", function()
  load(local_sec(12, 0), nil, 0)
  answer(200, 500, "")
  sim.advance(10 * 60 * SEC)
  local n = nposted("dls loaded version")
  t.ok(n >= 2 and n <= 4, "load line posted 2..4 times, got " .. n)
  t.ok(nposted("remote log post failed") >= 1, "failure reason sent to the remote log")
  t.ok(nposted("remote log post failed") <= 4, "failure reason not repeated every post")
end)

t.finish("dls-1-17-12")
