--[[
  Daylight Lighting Scheduler (DLS)
  DRIVER_VERSION: 1.11.6

  1.11.6: per-light manual holds are saved in PersistData, so a driver reload (Composer import, project
  refresh) no longer loses them and re-sends the scheduled off over a light the user just turned on.
  Off enforcement holds a light that is on while DLS's last command to it was off (missed feedback)
  instead of sending 0 again. The scheduled-off latch survives local midnight, so it can still retry
  until the next on edge.
  1.11.5: command descriptions show device name and parameter values in Composer programming.
  1.11.4: an on_daylight room's daylight trigger (and the date it fired) is saved in PersistData and restored after a restart or Rooms JSON save when still valid for the day cycle, so an off time after midnight is not sent early.
  1.11.3: manual off inside the on-window stays off until the next on edge (not the hold timer); a manual off at 8% or
  less sets a hold; a Rooms JSON save or restart inside the off window sends the pending off; on_daylight rooms with an
  off time after midnight run through midnight (trigger kept until that time).
  1.11.2: manual change made while a scheduled-off (or any non-presence) ramp is running is no longer swallowed as DLS's own feedback: a level moving against the ramp now sets the per-light hold, so off enforcement no longer re-sends 0 on the user.
1.11.1: Fable review fixes: manual off just after an auto-on now holds; a light turned on during/after a DLS fade is adopted instead of faded again; feed silence/unknown/stuck no longer end a manual-off hold; Enabled=Off and scene hold block presence ramps; HELLO count tolerates rooms DLS lacks; Presence Lighting/Vacancy Delay change no longer fades occupied rooms; persisted presence data type-guarded.
  1.11.0 (UNTESTED): follow-me presence. Rooms JSON "presence" object per room; OCC lines from the poller
  (Presence Port, same TCP port as PRESENCE) drive a per-room state machine VACANT / OCCUPIED / FADING / HOLD.
  Silence (Property "Occupancy Silence (sec)", default 180) = vacant. Night level per room, manual off in an
  occupied room = hold, own ramps are told apart from manual changes by level range. AWAY keeps only robot
  presence. Rooms without "presence" are unchanged. See docs/room-presence-dls-interface.md.

  1.10.1: arrival home and away release per-light manual holds (light.overrideUntil) as well as room holds.
  1.10.0 (UNTESTED): manual-change holds are now per light (light.overrideUntil) instead of per room, so a
  manual change to one light no longer delays the scheduled off of the other lights in its room. Scene /
  Off-scene holds stay room-level. Scheduled off is enforced again (re-sent at most every 5 min per light
  while the room is still off-window) for lights whose hold has expired or whose off command was dropped.

  1.9.0 (UNTESTED): optional curtain automation (Property "Curtain Automation", off by default; per-room
  "curtains" list in Rooms JSON; SwitchBot Curtain blind proxies get OPEN / CLOSE / SET_POSITION). See
  CURTAIN_NOTES.md in this folder.

  1.8.0 (UNTESTED): presence-based lighting (Properties "Presence Lighting", "Vacancy Delay (min)",
  "Vacancy Overrides Manual Hold"; per-room occ.vacancyDelaySec / occ.invert). Off by default, in which case
  behaviour matches 1.7.0. See PRESENCE_NOTES.md in this folder.

  Drives Lutron (brightness only) and LIFX (brightness + color temp) lights from
  sun position, optional cloud cover, and a time-of-day envelope. Lux / occupancy
  sensors can be added per room later without changing the architecture.

  UNVERIFIED against live hardware: the SET_COLOR_TARGET parameter names/mode,
  and override detection on ramp feedback. Turn Debug on for the first run.
]]

DRIVER_VERSION = "1.11.6"
LIGHT_LEVEL_VAR = 1001            -- light proxy LIGHT_LEVEL variable id

local rooms = {}                  -- parsed rooms
local curtains = {}               -- parsed curtains (1.9.0), independent of rooms
local curtainState = {}           -- proxy id -> { target = last commanded %, at = os.time() } (kept across reloads)
local curtainDay, curtainSentToday = nil, 0
local lightIndex = {}             -- device id -> room
local cloudPct = nil              -- last cloud cover (0-100) or nil
local cloudStamp = 0
local sunEvents = { day = nil }   -- cached sunrise/sunset for local date
local mainTimer, cloudTimer
local cloudTicket

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function dbg(...)
  if Properties["Debug"] == "On" then print("[DLS] " .. table.concat({...}, " ")) end
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function lerp(a, b, t) return a + (b - a) * t end
local function smooth(t) t = clamp(t, 0, 1) return t * t * (3 - 2 * t) end
local function rad(d) return d * math.pi / 180 end
local function deg(r) return r * 180 / math.pi end
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function setStatus(s) C4:UpdateProperty("Status", s) end

local function parseHM(s)
  local h, m = tostring(s or ""):match("^(%d+):(%d+)$")
  if not h then return nil end
  return tonumber(h) * 60 + tonumber(m)
end

local DAYNAMES = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
local function dayOk(list, now)
  if type(list) ~= "table" then return true end
  local name = DAYNAMES[os.date("*t", now).wday]   -- wday: 1 = Sunday
  for _, d in ipairs(list) do
    if tostring(d):lower():sub(1, 3) == name then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- sun position (NOAA-style low-precision; good to ~0.1 deg)
---------------------------------------------------------------------------
function SunPosition(utc, lat, lon)
  local jd = utc / 86400 + 2440587.5
  local n = jd - 2451545.0
  local L = (280.460 + 0.9856474 * n) % 360
  local g = rad((357.528 + 0.9856003 * n) % 360)
  local lam = rad(L + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g))
  local eps = rad(23.439 - 0.0000004 * n)
  local dec = math.asin(math.sin(eps) * math.sin(lam))
  local ra = atan2(math.cos(eps) * math.sin(lam), math.cos(lam))
  local gmst = (18.697374558 + 24.06570982441908 * n) % 24
  local H = rad(((gmst * 15 + lon) - deg(ra)) % 360)   -- local hour angle
  local la = rad(lat)
  local sinEl = math.sin(la) * math.sin(dec) + math.cos(la) * math.cos(dec) * math.cos(H)
  local el = deg(math.asin(clamp(sinEl, -1, 1)))
  local az = (deg(atan2(math.sin(H), math.cos(H) * math.sin(la) - math.tan(dec) * math.cos(la))) + 180) % 360
  return el, az
end

local sunCache = { key = nil }
local function SunPositionCached(utc, lat, lon)
  local key = math.floor(utc / 60)
  if sunCache.key ~= key or sunCache.lat ~= lat or sunCache.lon ~= lon then
    sunCache.el, sunCache.az = SunPosition(utc, lat, lon)
    sunCache.key, sunCache.lat, sunCache.lon = key, lat, lon
  end
  return sunCache.el, sunCache.az
end

local function localMidnight(t)
  local d = os.date("*t", t)
  return os.time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
end

-- returns sunrise, sunset as minutes after local midnight (or nil in polar cases)
local function computeSunEvents(now, lat, lon)
  local m0 = localMidnight(now)
  local rise, set
  local prev = SunPosition(m0, lat, lon)
  for m = 5, 1440, 5 do
    local el = SunPosition(m0 + m * 60, lat, lon)
    if prev < -0.833 and el >= -0.833 and not rise then rise = m end
    if prev >= -0.833 and el < -0.833 then set = m end
    prev = el
  end
  return rise, set
end

local function dayEvents(now, lat, lon)
  local key = os.date("%Y-%m-%d", now)
  if sunEvents.day ~= key then
    sunEvents.rise, sunEvents.set = computeSunEvents(now, lat, lon)
    sunEvents.day = key
    dbg("sunrise/sunset minutes", tostring(sunEvents.rise), tostring(sunEvents.set))
  end
  return sunEvents.rise, sunEvents.set
end

-- "HH:MM", "sunrise+30", "sunset-45" -> minutes after local midnight
local function resolveTimeSpec(spec, now, lat, lon)
  if not spec then return nil end
  local hm = parseHM(spec)
  if hm then return hm end
  local what, sign, off = tostring(spec):match("^(sun%a+)([%+%-]?)(%d*)$")
  local rise, set = dayEvents(now, lat, lon)
  local base = (what == "sunrise" and rise) or (what == "sunset" and set)
  if not base then return nil end
  off = tonumber(off) or 0
  if sign == "-" then off = -off end
  return base + off
end

---------------------------------------------------------------------------
-- curves
---------------------------------------------------------------------------
-- brightness envelope for the time of day, 0..100
local function baseLevel(minNow)
  local wake = parseHM(Properties["Wake Time"]) or 390
  local wind = parseHM(Properties["Wind-down Start"]) or 1260
  local bed  = parseHM(Properties["Bed Time"]) or 1350
  local night = tonumber(Properties["Night Level (%)"]) or 20
  if minNow >= bed or minNow < wake then return night end
  if minNow >= wind then return lerp(100, night, (minNow - wind) / math.max(1, bed - wind)) end
  return 100
end

-- daylight index 0..1 for clear sky at this sun elevation
local function clearDaylight(el)
  if el <= -6 then return 0 end
  if el < 0 then return 0.1 * (el + 6) / 6 end
  return math.min(1, 0.1 + 0.95 * math.sqrt(math.sin(rad(el))))
end

local function cloudTransmittance(pct)
  if not pct then return 1 end
  local c = clamp(pct / 100, 0, 1)
  return 1 - 0.75 * (c ^ 3.4)
end

-- circadian color temperature for LIFX-only rooms
local function circadianCCT(el, minNow)
  local lo = tonumber(Properties["CCT Min (K)"]) or 2200
  local hi = tonumber(Properties["CCT Max (K)"]) or 4000
  local k = lerp(lo, hi, smooth(el / 35))
  local wind = parseHM(Properties["Wind-down Start"]) or 1260
  local bed  = parseHM(Properties["Bed Time"]) or 1350
  local wake = parseHM(Properties["Wake Time"]) or 390
  if minNow >= wind or minNow < wake then
    k = lo
  end
  return k
end

-- Kim et al. Planckian locus approximation (1667K-25000K)
function CCTtoXY(T)
  T = clamp(T, 1667, 25000)
  local x
  if T <= 4000 then
    x = -0.2661239e9 / T^3 - 0.2343589e6 / T^2 + 0.8776956e3 / T + 0.179910
  else
    x = -3.0258469e9 / T^3 + 2.1070379e6 / T^2 + 0.2226347e3 / T + 0.240390
  end
  local y
  if T <= 2222 then
    y = -1.1063814 * x^3 - 1.34811020 * x^2 + 2.18555832 * x - 0.20219683
  elseif T <= 4000 then
    y = -0.9549476 * x^3 - 1.37418593 * x^2 + 2.09137015 * x - 0.16748867
  else
    y = 3.0817580 * x^3 - 5.87338670 * x^2 + 3.75112997 * x - 0.37001483
  end
  return x, y
end

---------------------------------------------------------------------------
-- target calculation for one room
---------------------------------------------------------------------------
-- windows = { {facing = <deg from north>, gain = 0..1}, ... }
-- returns fraction of the electric level still needed (1 = no daylight help)
local function windowsRemaining(windows, el, az, D)
  local rem = 1
  for _, w in ipairs(windows) do
    local orient = 1
    if w.facing and el > 0 then
      orient = 0.5 + 0.5 * math.max(0, math.cos(rad(az - w.facing)))
    end
    rem = rem * (1 - clamp(w.gain, 0, 1) * D * orient)
  end
  return rem
end

function ComputeRoomTarget(room, now, lat, lon, light)
  local el, az = SunPositionCached(now, lat, lon)
  local d = os.date("*t", now)
  local minNow = d.hour * 60 + d.min
  local base = baseLevel(minNow)

  local D = clearDaylight(el) * cloudTransmittance(cloudPct)
  local windows = (light and light.windows) or room.windows
  if not windows then
    local gain = (light and light.window_gain) or room.window_gain
    local facing = (light and light.facing_deg) or room.facing_deg
    windows = { { facing = facing, gain = gain } }
  end
  local level = base * windowsRemaining(windows, el, az, D)

  -- optional closed loop when a lux sensor is bound
  if room.lux and not light then
    local lux = tonumber(C4:GetDeviceVariable(room.lux.dev, room.lux.var))
    if lux then
      local prev = room.luxLevel or level
      local err = (room.lux.target - lux) / room.lux.target
      room.luxLevel = clamp(prev + 30 * err, room.min_level, base)
      level = room.luxLevel
    end
  end

  -- a light's own max_level overrides the room's; otherwise the room's applies
  local maxLv = (light and light.max_level) or room.max_level
  level = clamp(level, math.min(room.min_level, maxLv), maxLv)

  local cct
  if room.type == "lifx_only" then
    cct = circadianCCT(el, minNow)
  elseif room.type == "mixed" then
    cct = tonumber(Properties["Mixed Room CCT (K)"]) or 2700
  end
  return level, cct, el, az, D
end

---------------------------------------------------------------------------
-- light commands
---------------------------------------------------------------------------
-- Presence: HOME / AWAY pushed in from outside (command or TCP line). Away suspends the schedule, turns
-- everything off and optionally runs a small "someone's home" lamp per room:  "away":{"light":480,"level":30,"off":"22:30"}
local presenceAway = false
local serverHandle = nil

local sendQ, sendTimer = {}, nil
local function enqueue(fn)
  if DLS_TEST_SYNC then fn() return end            -- test hook only
  sendQ[#sendQ + 1] = fn
  if not sendTimer then
    sendTimer = C4:SetTimer(250, function(t)        -- one device command per 250 ms
      local f = table.remove(sendQ, 1)
      if f then f() else t:Cancel() sendTimer = nil end
    end, true)
  end
end

local function sendLevel(light, level, ms)
  local lvl = math.floor(level + 0.5)
  enqueue(function() C4:SendToDevice(light.id, "RAMP_TO_LEVEL", { LEVEL = lvl, TIME = ms }) end)
  light.rampFrom = tonumber(C4:GetDeviceVariable(light.id, LIGHT_LEVEL_VAR)) or 0   -- section 7 rule 1
  light.rampTo = lvl
  light.settled = nil
  light.lastLevel = level
  light.lastCmd = os.time()
  light.rampEnd = os.time() + math.ceil(ms / 1000)
  light.fbLast = light.rampFrom
  light.ignoreUntil = os.time() + math.ceil(ms / 1000) + 10
  dbg("level", tostring(light.id), tostring(math.floor(level + 0.5)), "ms", tostring(ms))
end

local function sendCCT(light, kelvin, ms)
  local k = clamp(kelvin, light.cct_min or 1500, light.cct_max or 4000)
  local x, y = CCTtoXY(k)
  local mode = (Properties["Color Command Mode"] == "xy (mode 0)") and 0 or 1
  enqueue(function()
    C4:SendToDevice(light.id, "SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_X = x,
      LIGHT_COLOR_TARGET_Y = y,
      LIGHT_COLOR_TARGET_MODE = mode,
      LIGHT_COLOR_TARGET_RATE = ms,
    })
  end)
  light.lastCCT = k
  light.ignoreUntil = math.max(light.ignoreUntil or 0, os.time() + math.ceil(ms / 1000) + 10)
  dbg("cct", tostring(light.id), tostring(math.floor(k)), "xy", string.format("%.4f,%.4f", x, y))
end

local function curLevel(light)
  return tonumber(C4:GetDeviceVariable(light.id, LIGHT_LEVEL_VAR)) or 0
end

---------------------------------------------------------------------------
-- follow-me presence (1.11.0, UNTESTED). Rooms JSON "presence" object; spec docs/room-presence-dls-interface.md.
-- Room states: VACANT (follow rooms drive nothing), OCCUPIED (lights on at the DLS target), FADING (off delay
-- expired, ramping to 0), HOLD (occupied and turned off by hand: stays off until vacancy or a manual on).
---------------------------------------------------------------------------
local PR_VACANT, PR_OCCUPIED, PR_FADING, PR_HOLD = "VACANT", "OCCUPIED", "FADING", "HOLD"
local OWN_BAND = 8                -- section 7: own-ramp range and manual threshold, in level points
local PRES_SOURCES = { esp = true, robot = true }
local presenceByKey = {}          -- lower-case roomKey -> room (rooms with a valid presence object)
local presenceWarn = ""           -- Rooms JSON warnings for presence, shown in Status
local gateOpen, gateUntil = false, 0  -- T14: no ramps until the first snapshot, or 180 s after start / Rooms JSON change
local snapshotSeen = false        -- a HELLO was accepted since DLS started (OK RESYNC until then)
local snapshot = nil              -- { left = N, seen = {} } while a HELLO batch is being read
local lastAcceptedAt = 0          -- last accepted HELLO or OCC (silence timer, section 3)
local silenceTripped = false
local presenceTimer = nil

local function latlon() return tonumber(Properties["Latitude"]), tonumber(Properties["Longitude"]) end
local function silenceSec() return tonumber(Properties["Occupancy Silence (sec)"]) or 180 end
local function minuteOf(now) local d = os.date("*t", now) return d.hour * 60 + d.min end
local function isLightOn(l) return curLevel(l) > 0 or (l.lastLevel or 0) > 0 end
local function anyOn(room)
  for _, l in ipairs(room.lights) do if isLightOn(l) then return true end end
  return false
end
local function anyHeld(room)
  for _, l in ipairs(room.lights) do if l.overrideUntil or l.offHold then return true end end
  return false
end
local function prUnconfirmed(src) return src == "unknown" or src == "stuck" end
local function presenceStatusPrefix()
  local s = ""
  if silenceTripped and next(presenceByKey) then s = s .. "Presence feed lost | " end
  if presenceWarn ~= "" then s = s .. "Rooms JSON warning: " .. presenceWarn .. " | " end
  return s
end

-- 1.11.6: per-light manual holds survive a driver reload (Composer import or project refresh). Without this a
-- reload forgot the hold and the first tick inside the off window (or off enforcement) turned the light off
-- again straight after the user had turned it on by hand.
local function saveHolds()
  if not PersistData then return end
  local t = {}
  for _, room in ipairs(rooms) do
    local rh = nil
    for _, l in ipairs(room.lights) do
      if l.overrideUntil or l.offHold then
        rh = rh or {}
        rh[tostring(l.id)] = { u = l.overrideUntil or 0, o = (l.offHold == true) }
      end
    end
    if rh then t[room.name] = rh end
  end
  PersistData.holds = t
end

local function prSave()
  if not PersistData then return end
  local t = {}
  for _, room in ipairs(rooms) do
    if room.pr then
      local holds = {}
      for _, l in ipairs(room.lights) do if l.offHold then holds[#holds + 1] = l.id end end
      t[room.pr.key] = { state = room.pr.state, offHold = holds }
    end
  end
  PersistData.presence = t
  saveHolds()                                  -- 1.11.6: keep per-light manual holds with it
end

-- T1/T2 window test: is the room inside its on window (section 6 uses the off window for night level)?
local function prInWindow(room, now, lat, lon)
  if not dayOk(room.days, now) then return false end
  local minNow = minuteOf(now)
  if room.on_daylight then
    local offMin = resolveTimeSpec(room.off or "23:00", now, lat, lon)
    return room.dayTriggered == true and offMin ~= nil and minNow < offMin
  end
  local onMin = resolveTimeSpec(room.on, now, lat, lon)
  local offMin = resolveTimeSpec(room.off, now, lat, lon)
  if onMin == nil or offMin == nil then return true end
  if onMin <= offMin then return minNow >= onMin and minNow < offMin end
  return minNow >= onMin or minNow < offMin
end

-- OCCUPIED follow room: lights at the DLS target (in window) or nightLevel (off window). Holds are respected.
local function presenceDrive(room, now, inWindow)
  local pr = room.pr
  local lat, lon = latlon()
  if not (lat and lon and gateOpen and pr.follow and pr.state == PR_OCCUPIED and Properties["Enabled"] == "On") then return end
  if room.overrideUntil and now < room.overrideUntil then return end   -- scene hold blocks presence ramps
  if inWindow == nil then inWindow = prInWindow(room, now, lat, lon) end
  local lvl, cct
  if inWindow then lvl, cct = ComputeRoomTarget(room, now, lat, lon) else lvl = pr.nightLevel end
  local fadeMs = math.floor(pr.fadeInSec * 1000 + 0.5)
  for _, l in ipairs(room.lights) do
    if not l.overrideUntil and not l.offHold then
      local lv = lvl
      if inWindow and (l.windows or l.window_gain or l.facing_deg or l.max_level) then
        lv = ComputeRoomTarget(room, now, lat, lon, l)
      end
      if lv < 1 then
        if (l.lastLevel or 0) > 0 then sendLevel(l, 0, fadeMs) end
      else
        local v = clamp(lv * l.scale, 1, 100)
        if l.lastLevel == nil or math.abs(v - l.lastLevel) >= 2 then sendLevel(l, v, fadeMs) end
        if l.kind == "lifx" and cct and (not l.lastCCT or math.abs(cct - l.lastCCT) >= 50) then
          sendCCT(l, cct, fadeMs)
        end
      end
    end
  end
end

-- T5 / T10: clear every hold in the room and fade all lights that are on to 0 over fadeOutSec.
local function prStartFade(room, now)
  local pr = room.pr
  if not gateOpen then return end                    -- no ramps while the gate is closed (reconcile does it)
  room.overrideUntil = nil
  for _, l in ipairs(room.lights) do l.overrideUntil, l.offHold = nil, nil end
  pr.offAt = nil
  local ms = math.floor(pr.fadeOutSec * 1000 + 0.5)
  local any = false
  for _, l in ipairs(room.lights) do
    if isLightOn(l) then
      any = true
      l.preFade = math.max(curLevel(l), l.lastLevel or 0)
      sendLevel(l, 0, ms)
    end
  end
  if any then
    pr.state = PR_FADING
    pr.fadeAt = now + math.ceil(ms / 1000) + 2
  else
    pr.state = PR_VACANT
  end
  dbg("presence fade", room.name, any and "fading" or "nothing on")
  prSave()
end

-- Occupancy edge handling (T1-T4, T6, T13). immediate = AWAY command: rooms left empty fade at once.
local function prSetOcc(room, now, newOcc, src, immediate)
  local pr = room.pr
  local was = pr.occIn
  pr.occIn = newOcc
  if newOcc then
    pr.lastOnSrc = src
    pr.offAt = nil                                                  -- T4
    if not was then
      if pr.state == PR_VACANT then
        pr.state = PR_OCCUPIED                                      -- T1 / T2
        presenceDrive(room, now)
      elseif pr.state == PR_FADING then
        pr.state = PR_OCCUPIED                                      -- T6
        if pr.follow then
          presenceDrive(room, now)
        elseif gateOpen then
          for _, l in ipairs(room.lights) do
            if l.preFade and l.preFade > 0 and not l.overrideUntil then
              sendLevel(l, l.preFade, math.floor(pr.fadeInSec * 1000 + 0.5))
            end
          end
        end
      end
    end
  elseif immediate and (pr.state == PR_OCCUPIED or pr.state == PR_HOLD) then
    prStartFade(room, now)                                          -- T13
  elseif (pr.state == PR_OCCUPIED or pr.state == PR_HOLD)
     and (was or (pr.state == PR_HOLD and not pr.offAt and not prUnconfirmed(src))) then
    local delay = (pr.lastOnSrc == "robot") and pr.robotOffDelaySec or pr.offDelaySec
    pr.offAt = now + delay                                          -- T3 / T10
    pr.offConfirmed = not prUnconfirmed(src)
  end
  prSave()
end

-- Turn the raw source (rawOcc, rawSrc) into occIn: allow-list, then the AWAY filter (section 8).
local function prRecompute(room, now, immediate)
  local pr = room.pr
  local occ, src = false, pr.rawSrc or "clear"
  if pr.rawOcc then
    local kept = {}
    for name in (pr.rawSrc or ""):gmatch("[^,]+") do
      if pr.allow[name] then kept[#kept + 1] = name end
    end
    if presenceAway then
      for _, n in ipairs(kept) do if n == "robot" then occ, src = true, "robot" end end
    elseif #kept > 0 then
      occ, src = true, table.concat(kept, ",")
    end
  end
  prSetOcc(room, now, occ, src, immediate)
end

-- Gate opens (snapshot or timeout): bring every room to the state its occupancy now implies.
local function prReconcile(now)
  for _, room in ipairs(rooms) do
    local pr = room.pr
    if pr then
      if pr.occIn then
        pr.offAt = nil
        if pr.state ~= PR_HOLD then
          pr.state = PR_OCCUPIED
          presenceDrive(room, now)
        end
      elseif pr.state == PR_HOLD and not anyOn(room) then
        -- restored manual-off hold (T14): only a confirmed vacancy plus the off delay ends it (T10)
        if prUnconfirmed(pr.rawSrc) then
          pr.offAt = nil
        elseif not pr.offAt then
          pr.offAt, pr.offConfirmed = now + pr.offDelaySec, true
        end
      else
        pr.offAt = nil
        if pr.state ~= PR_VACANT and anyOn(room) then
          prStartFade(room, now)
        else
          pr.state = PR_VACANT
          for _, l in ipairs(room.lights) do l.offHold = nil end   -- no off hold outlives a vacancy
        end
      end
    end
  end
  prSave()
end

-- Manual change on a presence room (section 7 rule 4 onwards). v = new level.
local function prManual(room, light, v, now)
  local pr = room.pr
  local base = light.lastLevel or 0
  if v == 0 and pr.state == PR_OCCUPIED and base > 0 then           -- manual off in an occupied room: T8 / T9
    light.offHold = true
    light.lastLevel = 0
    local others = false
    for _, o in ipairs(room.lights) do if o ~= light and isLightOn(o) then others = true end end
    if not others then pr.state = PR_HOLD end
    dbg("presence manual off, hold", room.name, tostring(light.id))
    prSave()
    return
  end
  light.lastLevel = v
  if v > 0 and light.offHold then                                   -- T11
    light.offHold = nil
    if pr.state == PR_HOLD then pr.state = PR_OCCUPIED end
  end
  if pr.state == PR_FADING then                                     -- T12
    pr.state = PR_OCCUPIED
    pr.offAt = now + pr.offDelaySec
  end
  local holdSec = (tonumber(Properties["Override Hold (min)"]) or 120) * 60
  light.overrideUntil = math.max(light.overrideUntil or 0, now + holdSec)
  dbg("presence manual change, light hold", room.name, tostring(light.id))
  prSave()
end

-- 1 s timer: off delays, fades, feed silence (section 3), gate timeout (T14), vacancy fade for manual-on lights.
local function presenceTick()
  local now = os.time()
  if not gateOpen and now >= gateUntil then
    gateOpen = true
    dbg("presence gate open (timeout)")
    prReconcile(now)
  end
  if now - lastAcceptedAt >= silenceSec() and not silenceTripped then
    silenceTripped = true
    dbg("presence feed lost")
    for _, room in ipairs(rooms) do
      if room.pr then
        room.pr.rawOcc, room.pr.rawSrc = false, "unknown"
        prRecompute(room, now, false)
      end
    end
    Update()   -- refresh Status now so "Presence feed lost" shows without waiting for the main timer
  end
  if not gateOpen then return end
  for _, room in ipairs(rooms) do
    local pr = room.pr
    if pr then
      if pr.offAt and now >= pr.offAt and (pr.state == PR_OCCUPIED or pr.state == PR_HOLD) then
        if Properties["Enabled"] ~= "On" then
          pr.offAt = pr.offAt or now        -- retried by presenceTick
        elseif pr.state == PR_HOLD and not pr.offConfirmed and not anyOn(room) then
          pr.offAt = nil          -- not a confirmed vacancy: the manual-off hold stays (lights are off)
        else
          prStartFade(room, now)
        end
      end
      if pr.state == PR_FADING and pr.fadeAt and now >= pr.fadeAt then
        pr.state, pr.fadeAt = PR_VACANT, nil
        prSave()
      end
      -- a manual-on light in a vacant follow room fades once its hold has expired (section 5 note)
      if pr.state == PR_VACANT and pr.follow and not pr.occIn and not presenceAway
         and not room.overrideUntil and not (room.wake and room.wake.enabled)
         and anyOn(room) and not anyHeld(room) and Properties["Enabled"] == "On" then
        local wait, adopt = false, false
        for _, l in ipairs(room.lights) do
          local cur = curLevel(l)
          if l.lastCmd and l.lastLevel == 0 and cur > OWN_BAND then   -- DLS faded it and it is on again
            if now <= (l.ignoreUntil or 0) then wait = true            -- let late feedback arrive first
            else
              l.lastLevel = cur
              l.overrideUntil = now + (tonumber(Properties["Override Hold (min)"]) or 120) * 60
              adopt = true
            end
          end
        end
        if adopt then prSave() elseif not wait then prStartFade(room, now) end
      end
    end
  end
end

-- Rooms JSON "presence" object: validated with defaults; warnings name <room>.<key>.
local function presenceKey(r)
  if r.key ~= nil then
    local k = tostring(r.key)
    if #k >= 1 and #k <= 32 and k:match("^[%w_%-]+$") then return k end
    return nil
  end
  local k = (tostring(r.name or "")):gsub("[^%w_%-]", "")
  if #k == 0 then k = "Room" end
  return k:sub(1, 32)
end

local function parsePresence(r, room, warns)
  local p = r.presence
  local function warn(k) warns[#warns + 1] = room.name .. "." .. k end
  local function num(k, def, lo, hi, isInt)
    local raw = p[k]
    if raw == nil then return def end
    local v = tonumber(raw)
    if v == nil or v < lo or v > hi or (isInt and v ~= math.floor(v)) then warn(k) return def end
    return v
  end
  local follow = false
  if p.follow ~= nil then
    if type(p.follow) == "boolean" then follow = p.follow else warn("follow") end
  end
  local list = p.sources
  if list == nil then list = { "esp", "robot" } end
  local allow = {}
  if type(list) ~= "table" then
    warn("sources")
    list = { "esp", "robot" }
  end
  for _, s in ipairs(list) do
    if PRES_SOURCES[s] and not allow[s] then allow[s] = true else warn("sources") end
  end
  return {
    key = room.key, follow = follow, allow = allow,
    offDelaySec = num("offDelaySec", 180, 10, 3600, true),
    robotOffDelaySec = num("robotOffDelaySec", 90, 10, 3600, true),
    fadeInSec = num("fadeInSec", 2, 0, 60, false),
    fadeOutSec = num("fadeOutSec", 30, 0, 300, false),
    nightLevel = num("nightLevel", tonumber(Properties["Night Level (%)"]) or 20, 0, 100, true),
    state = PR_VACANT, occIn = false, rawOcc = false, rawSrc = "unknown", lastOnSrc = "",
  }
end

---------------------------------------------------------------------------
-- main update
---------------------------------------------------------------------------
-- Presence lighting (1.8.0, UNTESTED). Master property "Presence Lighting" defaults Off; while Off, occupancy
-- behaves exactly as in 1.7.0 (raw sensor value gates turn-on only, nothing is turned off).
-- While On: a room becomes VACANT only after its sensor has read empty continuously for occ.vacancyDelaySec
-- (latch, so brief sensor drop-outs do not cut the lights); it becomes occupied again immediately.
local function presenceOn() return Properties["Presence Lighting"] == "On" end

local function parseOcc(v, room)
  v = tostring(v or ""):lower()
  local on = not (v == "0" or v == "false" or v == "off" or v == "" or v == "unoccupied")
  if room and room.occ and room.occ.invert then on = not on end
  return on
end

local function occupied(room)
  if not room.occ then return true end
  if presenceOn() then return not room.latchVacant end
  return parseOcc(C4:GetDeviceVariable(room.occ.dev, room.occ.var), room)
end

local function startVacancyTimer(room)
  if room.vacancyTimer then return end
  room.vacancyTimer = C4:SetTimer(room.occ.delaySec * 1000, function()
    room.vacancyTimer = nil
    local v = C4:GetDeviceVariable(room.occ.dev, room.occ.var)
    if v ~= nil and presenceOn() and not parseOcc(v, room) then
      room.latchVacant = true
      dbg("vacancy confirmed", room.name)
      Update()
    end
  end, false)
end

local function onOccupancy(room, occNow)
  if not presenceOn() then return end
  if occNow then
    if room.vacancyTimer then room.vacancyTimer:Cancel() room.vacancyTimer = nil end
    if room.latchVacant then dbg("occupied", room.name) end
    room.latchVacant = false
    Update()
  elseif not room.latchVacant then
    startVacancyTimer(room)
  end
end

-- re-derive latch state from the sensor's current value (startup, Rooms JSON or presence settings changed)
local function resetOccupancy()
  for _, room in ipairs(rooms) do
    if room.occ then
      if room.vacancyTimer then room.vacancyTimer:Cancel() room.vacancyTimer = nil end
      room.latchVacant = false                      -- assume occupied until a vacancy is confirmed
      local v = C4:GetDeviceVariable(room.occ.dev, room.occ.var)
      if v ~= nil and presenceOn() and not parseOcc(v, room) then startVacancyTimer(room) end
    end
  end
end

---------------------------------------------------------------------------
-- curtains (1.9.0, UNTESTED). Master property "Curtain Automation" defaults Off; while Off nothing is sent.
-- Rooms JSON entry: "curtains":[{"id":<SwitchBot Curtain proxy id>,"name":"...","facing_deg":180,
--   "open_level":100,"closed_level":0,"open_at":"sunrise+15","close_at":"sunset+30",
--   "glare_threshold":0.35,"glare_position":25}]
-- Target is openness 0..100 (0 = closed, 100 = open). Openness maps to a level between closed_level and
-- open_level. Rules (evaluated each Update pass, not while Away):
--   before open_at, at/after close_at, or sun below horizon  -> closed (0)
--   direct sun on the window >= glare_threshold              -> glare_position
--   otherwise                                                -> open (100)
-- Direct-sun index = max(0, cos(sun azimuth - facing)) * sin(sun elevation) * cloud transmittance.
-- Rate limits: a curtain is commanded only when its target moved by >= CURTAIN_MIN_CHANGE points since its
-- last command AND at least CURTAIN_MIN_GAP_SEC has passed; all curtains together get at most
-- CURTAIN_DAILY_CAP commands per local day. The cooldown and daily cap are not configurable on purpose.
---------------------------------------------------------------------------
local CURTAIN_MIN_GAP_SEC = 900
local CURTAIN_MIN_CHANGE = 10
local CURTAIN_DAILY_CAP = 200

local function curtainsOn() return Properties["Curtain Automation"] == "On" end

local function parseCurtains(list, room)
  if type(list) ~= "table" then return {} end
  local out = {}
  for _, c in ipairs(list) do
    local id = tonumber(c.id) or 0
    if id > 0 then
      out[#out + 1] = {
        id = id,
        name = c.name or room.name,
        facing = tonumber(c.facing_deg) or room.facing_deg,
        open_level = clamp(tonumber(c.open_level) or 100, 0, 100),
        closed_level = clamp(tonumber(c.closed_level) or 0, 0, 100),
        open_at = c.open_at or "sunrise+15",
        close_at = c.close_at or "sunset+30",
        glare_threshold = clamp(tonumber(c.glare_threshold) or 0.35, 0, 1),
        glare_position = clamp(tonumber(c.glare_position) or 25, 0, 100),
      }
    end
  end
  return out
end

-- returns target openness (0..100) and a short reason, or nil when the sun times cannot be resolved
local function curtainTarget(c, now, lat, lon)
  local el, az = SunPositionCached(now, lat, lon)
  local d = os.date("*t", now)
  local minNow = d.hour * 60 + d.min
  local openMin = resolveTimeSpec(c.open_at, now, lat, lon)
  local closeMin = resolveTimeSpec(c.close_at, now, lat, lon)
  if not openMin or not closeMin then return nil, "sun times unavailable" end
  if minNow < openMin or minNow >= closeMin or el <= 0 then return 0, "night" end
  local glare = 0
  if c.facing then
    glare = math.max(0, math.cos(rad(az - c.facing))) * math.sin(rad(el)) * cloudTransmittance(cloudPct)
  end
  if glare >= c.glare_threshold then
    return c.glare_position, string.format("glare %.2f", glare)
  end
  return 100, string.format("open, glare %.2f", glare)
end

local function sendCurtain(c, pct)
  enqueue(function()
    if pct >= 100 and c.open_level == 100 then
      C4:SendToDevice(c.id, "OPEN", {})
    elseif pct <= 0 and c.closed_level == 0 then
      C4:SendToDevice(c.id, "CLOSE", {})
    else
      local level = c.closed_level + (c.open_level - c.closed_level) * pct / 100
      C4:SendToDevice(c.id, "SET_POSITION", { POSITION = math.floor(level + 0.5) })
    end
  end)
  dbg("curtain command", c.name, tostring(c.id), "openness", tostring(pct))
end

local function runCurtains(now, lat, lon)
  if not curtainsOn() or #curtains == 0 then return end
  local today = os.date("%Y-%m-%d", now)
  if curtainDay ~= today then curtainDay, curtainSentToday = today, 0 end
  for _, c in ipairs(curtains) do
    local target, why = curtainTarget(c, now, lat, lon)
    if target == nil then
      dbg("curtain skipped", c.name, why)
    else
      target = math.floor(target + 0.5)
      local st = curtainState[c.id] or {}
      curtainState[c.id] = st
      local moved = (st.target == nil) or (math.abs(target - st.target) >= CURTAIN_MIN_CHANGE)
      local cooled = (st.at == nil) or (now - st.at >= CURTAIN_MIN_GAP_SEC)
      if moved and cooled and curtainSentToday < CURTAIN_DAILY_CAP then
        sendCurtain(c, target)
        st.target, st.at = target, now
        curtainSentToday = curtainSentToday + 1
      elseif moved then
        dbg("curtain held (cooldown or cap)", c.name, tostring(target), why)
      end
    end
  end
end

function Update()
  if Properties["Enabled"] ~= "On" then setStatus("Disabled") return end
  local lat = tonumber(Properties["Latitude"])
  local lon = tonumber(Properties["Longitude"])
  if not (lat and lon) then setStatus("Bad lat/lon") return end

  local now = os.time()
  local d = os.date("*t", now)
  local minNow = d.hour * 60 + d.min
  local rampMs = (tonumber(Properties["Ramp Time (sec)"]) or 90) * 1000
  local n, held = 0, 0
  local rise, set = dayEvents(now, lat, lon)
  local noon = (rise and set) and math.floor((rise + set) / 2) or 720

  if presenceAway then
    local cctAway = tonumber(Properties["Mixed Room CCT (K)"]) or 2700
    for _, room in ipairs(rooms) do
      local cfg = room.away
      local active = false
      if cfg then
        local onMin = resolveTimeSpec(room.on or "sunset-30", now, lat, lon)
        local offMin = resolveTimeSpec(cfg.off or room.off or "22:30", now, lat, lon)
        if onMin and offMin then
          if onMin <= offMin then active = (minNow >= onMin and minNow < offMin)
          else active = (minNow >= onMin or minNow < offMin) end
        end
      end
      if not (room.pr and room.pr.state ~= PR_VACANT) then       -- occupied presence rooms are driven below
      for _, l in ipairs(room.lights) do
        local target = (active and cfg and l.id == tonumber(cfg.light)) and clamp(tonumber(cfg.level) or 30, 1, 100) or 0
        if l.lastLevel == nil or math.abs(l.lastLevel - target) >= 1 then
          sendLevel(l, target, rampMs)
          if target > 0 and l.kind == "lifx" then sendCCT(l, cctAway, rampMs) end
        end
        if target > 0 then n = n + 1 end
      end
      end
    end
    for _, room in ipairs(rooms) do
      if room.pr and room.pr.state == PR_OCCUPIED then presenceDrive(room, now) end   -- robot in an AWAY house
    end
    setStatus(presenceStatusPrefix() .. string.format("Away | someone's-home lamps: %d | %s", n, os.date("%H:%M", now)))
    return
  end

  local lightsHeld = 0
  for _, room in ipairs(rooms) do
    local holdsChanged = false
    if room.overrideUntil and now >= room.overrideUntil then
      room.overrideUntil = nil
      dbg("override expired", room.name)
    end
    for _, l in ipairs(room.lights) do
      if l.overrideUntil and now >= l.overrideUntil then
        l.overrideUntil = nil
        holdsChanged = true
        dbg("light override expired", room.name, tostring(l.id))
      end
      if l.overrideUntil then lightsHeld = lightsHeld + 1 end
    end
    if holdsChanged then saveHolds() end
    -- reset each morning; 1.11.3: an on_daylight room whose off time is after midnight keeps its trigger until that time
    -- 1.11.6: the scheduled-off latch is cleared at the next on edge, not at midnight, so a light turned on again
    -- after midnight is still put back off
    local keepWrap = false
    if room.on_daylight and room.off then
      local o = resolveTimeSpec(room.off, now, lat, lon)
      keepWrap = o ~= nil and o < noon and minNow < o
    end
    if minNow < noon - 60 and not keepWrap then room.dayTriggered = false end
    local dayActive = dayOk(room.days, now)

    -- presence: lights go off once the room is confirmed vacant. A manual hold keeps them on unless
    -- "Vacancy Overrides Manual Hold" is On (scene holds are cleared the same way in that case).
    if presenceOn() and room.occ and room.latchVacant
       and (not room.overrideUntil or Properties["Vacancy Overrides Manual Hold"] == "On") then
      room.overrideUntil = nil
      for _, l in ipairs(room.lights) do
        if Properties["Vacancy Overrides Manual Hold"] == "On" then l.overrideUntil = nil end
        if not l.overrideUntil and curLevel(l) > 0 then sendLevel(l, 0, rampMs) end
      end
      saveHolds()
    end

    -- optional sunrise-based wake ramp (fixed event, off unless enabled)
    local inWake = false
    local w = room.wake
    if w and w.enabled and dayOk(w.days or room.days, now) and (not presenceOn() or occupied(room)) then
      local ws = resolveTimeSpec(w.at, now, lat, lon)
      local we = resolveTimeSpec(w.stop, now, lat, lon)
      if ws and we then
        inWake = (minNow >= ws and minNow < we)
        if inWake and not room.overrideUntil then
          local frac = clamp((minNow - ws) / math.max(1, tonumber(w.ramp_min) or 30), 0, 1)
          local lvl = math.max(1, (tonumber(w.level) or 40) * frac)
          for _, l in ipairs(room.lights) do
            if not l.overrideUntil then
              local v = clamp(lvl * l.scale, 1, 100)
              if not l.lastLevel or math.abs(v - l.lastLevel) >= 2 then sendLevel(l, v, 60000) end
              n = n + 1
            end
          end
        elseif (not inWake) and room.wasInWake and not room.overrideUntil then
          for _, l in ipairs(room.lights) do if not l.overrideUntil then sendLevel(l, 0, rampMs) end end
          dbg("wake window ended", room.name)
        end
      end
    end
    room.wasInWake = inWake

    if room.overrideUntil then
      held = held + 1
    elseif not inWake then
      local onMin  = resolveTimeSpec(room.on, now, lat, lon)
      local offSpec = room.off or (room.on_daylight and "23:00") or nil
      local offMin = resolveTimeSpec(offSpec, now, lat, lon)
      local scheduled = (onMin ~= nil and offMin ~= nil) or (room.on_daylight ~= nil and offMin ~= nil)
      local inWindow = true
      if room.on_daylight then
        if not room.dayTriggered and minNow >= noon then
          local el = SunPositionCached(now, lat, lon)
          local D = clearDaylight(el) * cloudTransmittance(cloudPct)
          if D < room.on_daylight then
            room.dayTriggered = true
            if type(PersistData) == "table" then                       -- 1.11.4: the trigger survives a restart or Rooms JSON save
              if type(PersistData.daylightFired) ~= "table" then PersistData.daylightFired = {} end
              PersistData.daylightFired[room.name] = os.date("%Y%m%d", now)
            end
            dbg("daylight trigger", room.name, string.format("D=%.2f", D))
          end
        end
        if offMin ~= nil and offMin < noon then   -- 1.11.3: off time after midnight: open from the trigger to midnight, then to off
          inWindow = room.dayTriggered and (minNow >= noon or minNow < offMin)
        else
          inWindow = room.dayTriggered and offMin ~= nil and minNow < offMin
        end
      elseif scheduled then
        if onMin <= offMin then inWindow = (minNow >= onMin and minNow < offMin)
        else inWindow = (minNow >= onMin or minNow < offMin) end
      end
      if not dayActive then inWindow = false end

      -- presence rooms (1.11.0): a follow room is driven by its presence state only; a non-follow room keeps the
      -- schedule except while FADING or HOLD
      local prOwns = room.pr and room.pr.follow
      local prBlocks = room.pr and not room.pr.follow and (room.pr.state == PR_FADING or room.pr.state == PR_HOLD)
      if prOwns then
        if room.pr.state == PR_OCCUPIED then presenceDrive(room, now, inWindow) end
        room.wasInWindow = inWindow
      elseif prBlocks then
        room.wasInWindow = inWindow
      else
      -- 1.11.3: the first tick after load (Rooms JSON save or restart) inside the off window counts as a pending off edge
      if scheduled and not inWindow and (room.wasInWindow or (room.wasInWindow == nil and not room.pr
          and (minNow >= offMin or minNow < noon - 60))) then
        local offMs = room.off_ramp_min and (room.off_ramp_min * 60000) or rampMs
        for _, l in ipairs(room.lights) do
          if not l.overrideUntil then sendLevel(l, 0, offMs) end
        end
        room.offEnforce = true
        room.offFadeUntil = now + math.ceil(offMs / 1000) + 30   -- keep 'follow' from fighting the fade-out
        dbg("scheduled off", room.name, "fade min", tostring(offMs / 60000))
      end
      if inWindow and not room.wasInWindow and not room.pr then      -- 1.11.3: the on edge clears manual-off holds
        for _, l in ipairs(room.lights) do l.offHold = nil end
      end
      room.wasInWindow = inWindow
      if inWindow then room.offEnforce = nil end

      -- 1.11.2 settle check: once an off ramp has finished, a light that sits well above 0 was turned on by hand
      -- (feedback during the ramp can be swallowed as our own), so hold it instead of letting enforcement undo it
      for _, l in ipairs(room.lights) do
        if l.rampTo == 0 and l.rampEnd and now > l.rampEnd + 3 and not l.settled and not l.overrideUntil then
          l.settled = true
          if curLevel(l) > OWN_BAND then
            l.overrideUntil = now + (tonumber(Properties["Override Hold (min)"]) or 120) * 60
            saveHolds()
            dbg("light on after off ramp, holding", room.name, tostring(l.id))
          end
        end
      end

      -- off enforcement: lights whose hold expired (or whose off was dropped) are re-sent off,
      -- at most once per 5 min per light, while the room is still off-window.
      -- 1.11.6: if the light is on while DLS's own last command to it was off (a missed manual-on event),
      -- hold it instead of sending 0 over the user again.
      if room.offEnforce and not presenceOn() and not (room.offFadeUntil and now < room.offFadeUntil) then
        for _, l in ipairs(room.lights) do
          if not l.overrideUntil and curLevel(l) > 0 and (not l.lastEnforce or now - l.lastEnforce >= 300) then
            if (l.lastLevel or 0) <= OWN_BAND and not (l.rampEnd and now <= l.rampEnd + 60) then
              l.overrideUntil = now + (tonumber(Properties["Override Hold (min)"]) or 120) * 60
              saveHolds()
              dbg("light on after DLS off, holding", room.name, tostring(l.id))
            else
              l.lastEnforce = now
              sendLevel(l, 0, rampMs)
              dbg("enforce off", room.name, tostring(l.id))
            end
          end
        end
      end

      if inWindow and occupied(room) then
        local level, cct = ComputeRoomTarget(room, now, lat, lon)
        for _, l in ipairs(room.lights) do
          local lv = level
          if l.windows or l.window_gain or l.facing_deg or l.max_level then lv = ComputeRoomTarget(room, now, lat, lon, l) end
          local v = clamp(lv * l.scale, 1, 100)
          local isOn = curLevel(l) > 0
          if (scheduled or isOn) and not l.overrideUntil and not l.offHold then       -- follow mode only touches lights that are already on
            if not l.lastLevel or math.abs(v - l.lastLevel) >= 2 or not isOn then
              sendLevel(l, v, rampMs)
            end
            if l.kind == "lifx" and cct and (not l.lastCCT or math.abs(cct - l.lastCCT) >= 50) then
              sendCCT(l, cct, rampMs)
            end
            n = n + 1
          end
        end
      elseif room.follow and not inWindow and dayActive and not (room.offFadeUntil and now < room.offFadeUntil)
             and (not presenceOn() or occupied(room)) then
        -- outside the on/off schedule: only track daylight for lights that are already on
        local level, cct = ComputeRoomTarget(room, now, lat, lon)
        for _, l in ipairs(room.lights) do
          if curLevel(l) > 0 and not l.overrideUntil then
            local lv = level
            if l.windows or l.window_gain or l.facing_deg or l.max_level then lv = ComputeRoomTarget(room, now, lat, lon, l) end
            local v = clamp(lv * l.scale, 1, 100)
            if not l.lastLevel or math.abs(v - l.lastLevel) >= 3 then sendLevel(l, v, rampMs) end
            if l.kind == "lifx" and cct and (not l.lastCCT or math.abs(cct - l.lastCCT) >= 50) then
              sendCCT(l, cct, rampMs)
            end
            n = n + 1
          end
        end
      end
      end
    end
  end
  runCurtains(now, lat, lon)
  setStatus(presenceStatusPrefix() .. string.format("OK %s | lights driven: %d | rooms held: %d | lights held: %d | cloud: %s",
    os.date("%H:%M", now), n, held, lightsHeld, cloudPct and (math.floor(cloudPct) .. "%") or "n/a"))
end

---------------------------------------------------------------------------
-- override detection
---------------------------------------------------------------------------
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  for _, r in ipairs(rooms) do
    if r.occ and r.occ.dev == idDevice and r.occ.var == idVariable then
      if strValue ~= nil then onOccupancy(r, parseOcc(strValue, r)) end
      return
    end
  end
  if idVariable ~= LIGHT_LEVEL_VAR then return end
  local room = lightIndex[idDevice]
  if not room then return end
  local light
  for _, l in ipairs(room.lights) do if l.id == idDevice then light = l end end
  if not light then return end
  local now = os.time()
  local v = tonumber(strValue) or 0
  -- section 7: inside the ignore window, feedback inside the range between start and target is our own ramp
  if light.ignoreUntil and now <= light.ignoreUntil then
    local from, to = light.rampFrom or 0, light.rampTo or 0
    if not room.pr then
      -- 1.11.2: only feedback that moves with the ramp is ours; a level moving against it (e.g. 0 -> 30 during a
      -- scheduled-off ramp to 0) is a hand on the dimmer and falls through to the hold below
      local own = true
      local from, to = light.rampFrom or 0, light.rampTo or 0
      if light.fbLast then
        if to < from and v > light.fbLast + OWN_BAND then own = false end
        if to > from and v < light.fbLast - OWN_BAND then own = false end
      end
      -- once the ramp is over (2 s settle) only the target level is ours
      if own and light.rampEnd and now > light.rampEnd + 2 and math.abs(v - to) > OWN_BAND then own = false end
      if own then light.fbLast = v return end
    else
      local own = v >= math.min(from, to) - OWN_BAND and v <= math.max(from, to) + OWN_BAND
      -- once the ramp is over (2 s settle) only the target level is ours
      if own and light.rampEnd and now > light.rampEnd + 2 and math.abs(v - to) > OWN_BAND then own = false end
      -- feedback moving against the ramp direction is a hand on the dimmer
      if own and light.fbLast then
        if to < from and v > light.fbLast + OWN_BAND then own = false end
        if to > from and v < light.fbLast - OWN_BAND then own = false end
      end
      if own then light.fbLast = v return end
    end
  elseif light.lastLevel then
    if math.abs(v - light.lastLevel) <= OWN_BAND and not (v == 0 and light.lastLevel > 0) then return end   -- 1.11.3: a manual off is never DLS's own feedback
  elseif not room.pr or math.abs(v) <= OWN_BAND then
    return                                   -- never ramped (baseline 0 for presence rooms)
  end
  if room.pr then return prManual(room, light, v, now) end
  -- 1.11.3: a manual off inside the on-window stays off until the next on edge, not just until the hold expires
  if v == 0 and room.wasInWindow then light.offHold = true
  elseif v > 0 then light.offHold = nil end
  local holdSec = (tonumber(Properties["Override Hold (min)"]) or 120) * 60
  light.overrideUntil = math.max(light.overrideUntil or 0, now + holdSec)   -- per light; never shorten a hold
  saveHolds()
  dbg("manual change detected, holding light", tostring(light.id), room.name, "for min", tostring(holdSec / 60))
end

---------------------------------------------------------------------------
-- cloud cover (Open-Meteo, no API key)
---------------------------------------------------------------------------
local function pollCloud()
  if Properties["Cloud Cover Source"] ~= "Open-Meteo (internet)" then cloudPct = nil return end
  local url = string.format(
    "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&current=cloud_cover&timezone=auto",
    Properties["Latitude"], Properties["Longitude"])
  cloudTicket = C4:urlGet(url)
end

function ReceivedAsync(ticketId, strData, responseCode, tHeaders, strError)
  if ticketId ~= cloudTicket then return end
  cloudTicket = nil
  if strError or tonumber(responseCode) ~= 200 then
    dbg("cloud fetch failed", tostring(strError), tostring(responseCode))
    return                                  -- keep last known value
  end
  local ok, data = pcall(function() return C4:JsonDecode(strData, false) end)
  if ok and type(data) == "table" and data.current and data.current.cloud_cover then
    cloudPct = tonumber(data.current.cloud_cover)
    cloudStamp = os.time()
    dbg("cloud cover", tostring(cloudPct))
  end
end

---------------------------------------------------------------------------
-- config
---------------------------------------------------------------------------
local function parseWindows(list)
  if type(list) ~= "table" then return nil end
  local out = {}
  for _, w in ipairs(list) do
    out[#out + 1] = { facing = tonumber(w.facing), gain = clamp(tonumber(w.gain) or 0.3, 0, 1) }
  end
  if #out == 0 then return nil end
  return out
end

local function loadRooms(closeGate)
  for _, r in ipairs(rooms) do
    if r.vacancyTimer then r.vacancyTimer:Cancel() r.vacancyTimer = nil end
  end
  rooms, lightIndex = {}, {}
  presenceByKey, presenceWarn = {}, ""
  local warns = {}
  if closeGate then gateOpen, gateUntil = false, os.time() + 180 end   -- T14
  local ok, data = pcall(function() return C4:JsonDecode(Properties["Rooms JSON"], false) end)
  if not ok or type(data) ~= "table" then setStatus("Rooms JSON invalid") return end
  for _, r in ipairs(data) do
    local room = {
      name = r.name or "Room", type = r.type or "lifx_only",
      window_gain = clamp(tonumber(r.window_gain) or 0.6, 0, 1),
      facing_deg = tonumber(r.facing_deg),
      min_level = tonumber(r.min_level) or 5,
      max_level = tonumber(r.max_level) or 100,
      away = r.away, on = r.on, off = r.off, off_ramp_min = tonumber(r.off_ramp_min), scenes = r.scenes, days = r.days, windows = parseWindows(r.windows), follow = (r.follow == true), on_daylight = tonumber(r.on_daylight), wake = r.wake,
      lux = (r.lux and r.lux.dev and r.lux.dev > 0) and { dev = r.lux.dev, var = r.lux.var or 1000, target = tonumber(r.lux.target) or 200 } or nil,
      occ = (r.occ and r.occ.dev and r.occ.dev > 0) and {
        dev = r.occ.dev, var = r.occ.var or 1000,
        delaySec = math.max(10, tonumber(r.occ.vacancyDelaySec) or (tonumber(Properties["Vacancy Delay (min)"]) or 10) * 60),
        invert = (r.occ.invert == true),
      } or nil,
      lights = {},
    }
    local savedHolds = (type(PersistData) == "table" and type(PersistData.holds) == "table")
      and PersistData.holds[room.name] or nil
    for _, l in ipairs(r.lights or {}) do
      local id = tonumber(l.id) or 0
      if id > 0 then
        local light = { id = id, kind = l.kind or "lutron", scale = clamp(tonumber(l.scale) or 1, 0.05, 1), max_level = tonumber(l.max_level), window_gain = tonumber(l.window_gain), facing_deg = tonumber(l.facing_deg), windows = parseWindows(l.windows), cct_min = tonumber(l.cct_min) or 1500, cct_max = tonumber(l.cct_max) or 4000 }
        local sh = type(savedHolds) == "table" and savedHolds[tostring(id)] or nil
        if type(sh) == "table" then
          local u = tonumber(sh.u)
          if u and u > os.time() then light.overrideUntil = u end   -- 1.11.6: the hold had not expired when the driver reloaded
          if sh.o == true then light.offHold = true end
        end
        table.insert(room.lights, light)
        lightIndex[id] = room
        C4:UnregisterVariableListener(id, LIGHT_LEVEL_VAR)
        C4:RegisterVariableListener(id, LIGHT_LEVEL_VAR)
      end
    end
    if #room.lights > 0 then table.insert(rooms, room) end
    -- 1.11.4: restore the daylight trigger after a restart or Rooms JSON save. Valid only if it fired today, or
    -- yesterday evening for a room whose off time is after midnight and not yet reached. Bad data is ignored.
    if room.on_daylight and type(PersistData) == "table" and type(PersistData.daylightFired) == "table" then
      local fired = PersistData.daylightFired[room.name]
      if type(fired) == "string" then
        local nowT = os.time()
        local offMin = resolveTimeSpec(room.off or "23:00", nowT, latlon())
        local firedToday = fired == os.date("%Y%m%d", nowT)
        local firedYesterdayWrap = fired == os.date("%Y%m%d", nowT - 86400) and offMin ~= nil and offMin < 720
          and minuteOf(nowT) < offMin
        if firedToday or firedYesterdayWrap then room.dayTriggered = true end
      end
    end
    if type(r.presence) == "table" then
      local key = presenceKey(r)
      if #room.lights == 0 then warns[#warns + 1] = room.name .. ".presence (needs a light)"
      elseif not key then warns[#warns + 1] = room.name .. ".key"
      elseif presenceByKey[key:lower()] then warns[#warns + 1] = room.name .. ".key (duplicate)"
      else
        room.key = key
        room.pr = parsePresence(r, room, warns)
        if room.occ then warns[#warns + 1] = room.name .. ".occ (ignored, presence in use)" end
        room.occ = nil
        presenceByKey[key:lower()] = room
        local saved = PersistData and type(PersistData.presence) == "table" and PersistData.presence[key]
        if type(saved) == "table" then                       -- T14: restore HOLD and its per-light off holds
          if saved.state == PR_HOLD then room.pr.state = PR_HOLD end
          for _, id in ipairs(type(saved.offHold) == "table" and saved.offHold or {}) do
            for _, l in ipairs(room.lights) do if l.id == id then l.offHold = true end end
          end
        end
      end
    end
    if room.occ and #room.lights > 0 then
      C4:UnregisterVariableListener(room.occ.dev, room.occ.var)
      C4:RegisterVariableListener(room.occ.dev, room.occ.var)
    end
  end
  curtains = {}
  for _, r in ipairs(data) do
    for _, c in ipairs(parseCurtains(r.curtains, { name = r.name or "Room", facing_deg = tonumber(r.facing_deg) })) do
      curtains[#curtains + 1] = c
    end
  end
  resetOccupancy()
  presenceWarn = table.concat(warns, "; ")
  dbg("rooms loaded", tostring(#rooms), "curtains", tostring(#curtains))
end

local function startTimers()
  if mainTimer then mainTimer:Cancel() end
  if cloudTimer then cloudTimer:Cancel() end
  local mins = tonumber(Properties["Update Interval (min)"]) or 5
  mainTimer = C4:SetTimer(mins * 60 * 1000, function() Update() end, true)
  local cm = tonumber(Properties["Cloud Poll Interval (min)"]) or 20
  cloudTimer = C4:SetTimer(cm * 60 * 1000, function() pollCloud() end, true)
end

---------------------------------------------------------------------------
-- driver lifecycle
---------------------------------------------------------------------------
function OnDriverInit() end

function OnDriverLateInit()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
  if PersistData and PersistData.presenceAway == true then presenceAway = true end
  C4:UpdateProperty("Presence", presenceAway and "Away" or "Home")
  lastAcceptedAt = os.time()
  loadRooms(true)
  startTimers()
  if presenceTimer then presenceTimer:Cancel() end
  presenceTimer = C4:SetTimer(1000, function() presenceTick() end, true)
  startPresenceServer()
  pollCloud()
  C4:SetTimer(15000, function() Update() end, false)   -- first pass after loads settle
end

function OnPropertyChanged(name)
  if name == "Rooms JSON" then loadRooms(true)
  elseif name == "Presence Lighting" or name == "Vacancy Delay (min)" then loadRooms(true)
  elseif name == "Latitude" or name == "Longitude" then sunEvents.day = nil pollCloud()
  elseif name == "Update Interval (min)" or name == "Cloud Poll Interval (min)" then startTimers()
  elseif name == "Cloud Cover Source" then pollCloud()
  elseif name == "Presence Port" then startPresenceServer() end
  if name ~= "Status" and name ~= "Driver Version" and name ~= "Presence" then
    for _, r in ipairs(rooms) do for _, l in ipairs(r.lights) do l.lastLevel, l.lastCCT = nil, nil end end
    C4:SetTimer(2000, function() Update() end, false)
  end
end

-- Scenes: a keypad/Control4 event calls ApplyScene (ROOM, SCENE). The scene sets the listed lights (usually
-- the LIFX lamps; Lutron zones are set by the Lutron scene itself) and holds the room off the schedule.
--   normal scene : hold for "Scene Hold (min)" (default 240), then back to automatic
--   off scene    : everything off, held until the room's next scheduled on time (sunset / daylight trigger)
local function nextOnTime(room, now, lat, lon)
  local onMin
  if room.on_daylight then onMin = 720 else onMin = resolveTimeSpec(room.on or "sunset-15", now, lat, lon) or 1080 end
  local t = localMidnight(now) + onMin * 60
  if t <= now then t = t + 86400 end
  return t
end

local function applyScene(roomName, sceneName)
  local lat, lon = tonumber(Properties["Latitude"]), tonumber(Properties["Longitude"])
  local now = os.time()
  for _, room in ipairs(rooms) do
    if room.name == roomName then
      local sc = room.scenes and room.scenes[sceneName]
      if not sc then print("[DLS] unknown scene " .. tostring(sceneName) .. " in " .. roomName) return end
      local rampMs = (tonumber(Properties["Ramp Time (sec)"]) or 90) * 1000
      local sceneMs = tonumber(sc.ramp_ms) or 2000
      if sc.off then
        for _, l in ipairs(room.lights) do sendLevel(l, 0, sceneMs) end
        room.overrideUntil = nextOnTime(room, now, lat, lon)
        room.dayTriggered = false
      else
        local _, cct = ComputeRoomTarget(room, now, lat, lon)
        for _, l in ipairs(room.lights) do
          local pct = sc.levels and (sc.levels[tostring(l.id)] or sc.levels[l.id])
          if pct ~= nil then
            pct = clamp(tonumber(pct) or 0, 0, 100)
            sendLevel(l, pct, sceneMs)
            if pct > 0 and l.kind == "lifx" and cct then sendCCT(l, cct, sceneMs) end
          end
        end
        local holdMin = tonumber(sc.hold_min) or tonumber(Properties["Scene Hold (min)"]) or 240
        room.overrideUntil = now + holdMin * 60
      end
      dbg("scene", roomName, sceneName, "held until", tostring(room.overrideUntil))
      setStatus(string.format("Scene %s/%s applied %s", roomName, sceneName, os.date("%H:%M", now)))
      return
    end
  end
  print("[DLS] unknown room " .. tostring(roomName))
end

local function releaseAll()
  for _, r in ipairs(rooms) do r.overrideUntil = nil end
  for _, r in ipairs(rooms) do for _, l in ipairs(r.lights) do l.overrideUntil, l.offHold, l.lastLevel, l.lastCCT = nil, nil, nil, nil end end
  for _, r in ipairs(rooms) do
    if r.pr and r.pr.state == PR_HOLD then r.pr.state = r.pr.occIn and PR_OCCUPIED or PR_VACANT end
  end
  saveHolds()
end

local function setPresence(state)
  local away = (tostring(state or ""):lower() == "away")
  if away == presenceAway then return end
  presenceAway = away
  if PersistData then PersistData.presenceAway = away end
  C4:UpdateProperty("Presence", away and "Away" or "Home")
  local now = os.time()
  if away then
    for _, r in ipairs(rooms) do
      r.overrideUntil = nil
      for _, l in ipairs(r.lights) do
        l.overrideUntil, l.offHold = nil, nil
        if not r.pr then l.lastLevel, l.lastCCT = nil, nil end    -- presence rooms keep their ramp baseline
      end
    end
  else
    releaseAll()          -- arriving home: drop scene/Off holds, resume the schedule
  end
  for _, r in ipairs(rooms) do
    if r.pr then prRecompute(r, now, away) end    -- AWAY: rooms left empty fade at once; HOME: re-evaluate
  end
  Update()
end

function startPresenceServer()
  if serverHandle then pcall(function() C4:DestroyServer() end) serverHandle = nil end
  local port = tonumber(Properties["Presence Port"]) or 0
  if port > 0 and C4.CreateServer then serverHandle = C4:CreateServer(port) end
end

-- Lines (section 3): PRESENCE HOME|AWAY token | HELLO bootId count token | OCC room 1|0 src token
local serverBuf = {}              -- client handle -> text after the last newline (processed when complete)
local MAX_LINE = 120

-- A HELLO snapshot is complete when its N OCC lines have arrived: rooms not named in them are vacant.
local function finishSnapshot(now)
  local done = snapshot
  snapshot = nil
  for _, room in ipairs(rooms) do
    if room.pr and not done.seen[room.key:lower()] then
      room.pr.rawOcc, room.pr.rawSrc = false, "clear"
      prRecompute(room, now, false)
    end
  end
  if not gateOpen then
    gateOpen = true
    dbg("presence gate open (snapshot)")
    prReconcile(now)
  end
end

local function replyFor(line, now)
  local t = {}
  for w in line:gmatch("%S+") do t[#t + 1] = w end
  if #t == 0 then return nil end
  if #line > MAX_LINE then return "ERR SYNTAX" end
  local verb = t[1]:upper()
  local want = Properties["Presence Token"] or ""
  if verb ~= "OCC" and snapshot then snapshot = nil end
  if verb == "PRESENCE" then
    if want ~= "" and t[#t] ~= want then return "ERR AUTH" end
    local arg = t[2] and t[2]:upper()
    if (#t ~= 2 and #t ~= 3) or (arg ~= "HOME" and arg ~= "AWAY") then return "ERR SYNTAX" end
    setPresence(arg)
    return "OK"
  elseif verb == "HELLO" then
    if want == "" or t[#t] ~= want then return "ERR AUTH" end
    if #t ~= 4 or not t[2]:match("^%d+$") or #t[2] > 16 or not t[3]:match("^%d+$") or #t[3] > 3 then
      return "ERR SYNTAX"
    end
    snapshot = { left = tonumber(t[3]), seen = {} }
    snapshotSeen = true
    lastAcceptedAt = now
    silenceTripped = false
    if snapshot.left == 0 then finishSnapshot(now) end
    return "OK"
  elseif verb == "OCC" then
    if want == "" or t[#t] ~= want then return "ERR AUTH" end
    if #t ~= 5 or (t[3] ~= "1" and t[3] ~= "0") or not t[2]:match("^[%w_%-]+$")
       or not t[4]:match("^[%w_%-,]+$") or t[4]:find(",,", 1, true)
       or t[4]:sub(1, 1) == "," or t[4]:sub(-1) == "," then
      return "ERR SYNTAX"
    end
    local room = presenceByKey[t[2]:lower()]
    if not room then
      if snapshot and snapshot.left > 0 then
        snapshot.left = snapshot.left - 1
        if snapshot.left == 0 then finishSnapshot(now) end
      end
      return "ERR ROOM"
    end
    room.pr.rawOcc, room.pr.rawSrc = (t[3] == "1"), t[4]
    lastAcceptedAt = now
    silenceTripped = false
    prRecompute(room, now, false)
    if snapshot and snapshot.left > 0 then
      snapshot.seen[room.key:lower()] = true
      snapshot.left = snapshot.left - 1
      if snapshot.left == 0 then finishSnapshot(now) end
    end
    if not snapshotSeen then return "OK RESYNC" end
    return "OK"
  end
  return "ERR SYNTAX"
end

-- One reply per complete line, in order, sent in one write; the socket is closed once nothing is left unread.
function OnServerDataIn(nHandle, strData, strClientAddress, nClientPort)
  local buf = (serverBuf[nHandle] or "") .. tostring(strData)
  local now = os.time()
  local out, pos = {}, 1
  while true do
    local s, e = buf:find("\n", pos, true)
    if not s then break end
    local line = buf:sub(pos, s - 1):gsub("\r$", "")
    pos = e + 1
    local reply = replyFor(line, now)
    if reply then out[#out + 1] = reply .. "\r\n" end
  end
  local rest = buf:sub(pos)
  if #rest > 2048 then rest = "" out[#out + 1] = "ERR SYNTAX\r\n" end
  serverBuf[nHandle] = (rest ~= "") and rest or nil
  if #out > 0 then pcall(function() C4:ServerSend(nHandle, table.concat(out)) end) end
  if not serverBuf[nHandle] then pcall(function() C4:ServerCloseClient(nHandle) end) end
end
function OnServerConnectionStatusChanged(nHandle, nPort, strStatus) serverBuf[nHandle] = nil end

function ExecuteCommand(strCommand, tParams)
  if strCommand == "LUA_ACTION" then
    local a = tParams and tParams.ACTION
    if a == "RecalcNow" then Update()
    elseif a == "ReleaseAll" then releaseAll() Update()
    elseif a == "LogStatus" then
      local lat, lon = tonumber(Properties["Latitude"]), tonumber(Properties["Longitude"])
      local el, az = SunPosition(os.time(), lat, lon)
      print(string.format("[DLS] sun el=%.1f az=%.1f cloud=%s", el, az, tostring(cloudPct)))
      for _, r in ipairs(rooms) do
        local lv, k = ComputeRoomTarget(r, os.time(), lat, lon)
        print(string.format("[DLS] %s (%s): target %.0f%% cct=%s held=%s", r.name, r.type, lv, tostring(k and math.floor(k)), tostring(r.overrideUntil ~= nil)))
      end
    end
  elseif strCommand == "SetPresence" then
    setPresence(tParams and tParams.PRESENT)
  elseif strCommand == "ApplyScene" then
    applyScene(tParams and tParams.ROOM, tParams and tParams.SCENE)
  elseif strCommand == "Release Room Override" or strCommand == "ReleaseRoomOverride" then
    for _, r in ipairs(rooms) do
      if r.name == (tParams and tParams.ROOM) then r.overrideUntil = nil
        for _, l in ipairs(r.lights) do l.lastLevel, l.lastCCT = nil, nil end end
    end
    Update()
  end
end
