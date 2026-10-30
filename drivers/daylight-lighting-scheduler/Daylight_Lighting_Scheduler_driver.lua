--[[
  Daylight Lighting Scheduler (DLS)
  DRIVER_VERSION: 1.7.0

  Drives Lutron (brightness only) and LIFX (brightness + color temp) lights from
  sun position, optional cloud cover, and a time-of-day envelope. Lux / occupancy
  sensors can be added per room later without changing the architecture.

  UNVERIFIED against live hardware: the SET_COLOR_TARGET parameter names/mode,
  and override detection on ramp feedback. Turn Debug on for the first run.
]]

DRIVER_VERSION = "1.7.0"
LIGHT_LEVEL_VAR = 1001            -- light proxy LIGHT_LEVEL variable id

local rooms = {}                  -- parsed rooms
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
  light.lastLevel = level
  light.lastCmd = os.time()
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
-- main update
---------------------------------------------------------------------------
local function occupied(room)
  if not room.occ then return true end
  local v = tostring(C4:GetDeviceVariable(room.occ.dev, room.occ.var) or "")
  v = v:lower()
  return not (v == "0" or v == "false" or v == "off" or v == "" or v == "unoccupied")
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
      for _, l in ipairs(room.lights) do
        local target = (active and cfg and l.id == tonumber(cfg.light)) and clamp(tonumber(cfg.level) or 30, 1, 100) or 0
        if l.lastLevel == nil or math.abs(l.lastLevel - target) >= 1 then
          sendLevel(l, target, rampMs)
          if target > 0 and l.kind == "lifx" then sendCCT(l, cctAway, rampMs) end
        end
        if target > 0 then n = n + 1 end
      end
    end
    setStatus(string.format("Away | someone's-home lamps: %d | %s", n, os.date("%H:%M", now)))
    return
  end

  for _, room in ipairs(rooms) do
    if room.overrideUntil and now >= room.overrideUntil then
      room.overrideUntil = nil
      dbg("override expired", room.name)
    end
    if minNow < noon - 60 then room.dayTriggered = false end   -- reset each morning
    local dayActive = dayOk(room.days, now)

    -- optional sunrise-based wake ramp (fixed event, off unless enabled)
    local inWake = false
    local w = room.wake
    if w and w.enabled and dayOk(w.days or room.days, now) then
      local ws = resolveTimeSpec(w.at, now, lat, lon)
      local we = resolveTimeSpec(w.stop, now, lat, lon)
      if ws and we then
        inWake = (minNow >= ws and minNow < we)
        if inWake and not room.overrideUntil then
          local frac = clamp((minNow - ws) / math.max(1, tonumber(w.ramp_min) or 30), 0, 1)
          local lvl = math.max(1, (tonumber(w.level) or 40) * frac)
          for _, l in ipairs(room.lights) do
            local v = clamp(lvl * l.scale, 1, 100)
            if not l.lastLevel or math.abs(v - l.lastLevel) >= 2 then sendLevel(l, v, 60000) end
            n = n + 1
          end
        elseif (not inWake) and room.wasInWake and not room.overrideUntil then
          for _, l in ipairs(room.lights) do sendLevel(l, 0, rampMs) end
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
            dbg("daylight trigger", room.name, string.format("D=%.2f", D))
          end
        end
        inWindow = room.dayTriggered and offMin ~= nil and minNow < offMin
      elseif scheduled then
        if onMin <= offMin then inWindow = (minNow >= onMin and minNow < offMin)
        else inWindow = (minNow >= onMin or minNow < offMin) end
      end
      if not dayActive then inWindow = false end

      if scheduled and room.wasInWindow and not inWindow then
        local offMs = room.off_ramp_min and (room.off_ramp_min * 60000) or rampMs
        for _, l in ipairs(room.lights) do sendLevel(l, 0, offMs) end
        room.offFadeUntil = now + math.ceil(offMs / 1000) + 30   -- keep 'follow' from fighting the fade-out
        dbg("scheduled off", room.name, "fade min", tostring(offMs / 60000))
      end
      room.wasInWindow = inWindow

      if inWindow and occupied(room) then
        local level, cct = ComputeRoomTarget(room, now, lat, lon)
        for _, l in ipairs(room.lights) do
          local lv = level
          if l.windows or l.window_gain or l.facing_deg or l.max_level then lv = ComputeRoomTarget(room, now, lat, lon, l) end
          local v = clamp(lv * l.scale, 1, 100)
          local isOn = curLevel(l) > 0
          if scheduled or isOn then       -- follow mode only touches lights that are already on
            if not l.lastLevel or math.abs(v - l.lastLevel) >= 2 or not isOn then
              sendLevel(l, v, rampMs)
            end
            if l.kind == "lifx" and cct and (not l.lastCCT or math.abs(cct - l.lastCCT) >= 50) then
              sendCCT(l, cct, rampMs)
            end
            n = n + 1
          end
        end
      elseif room.follow and not inWindow and dayActive and not (room.offFadeUntil and now < room.offFadeUntil) then
        -- outside the on/off schedule: only track daylight for lights that are already on
        local level, cct = ComputeRoomTarget(room, now, lat, lon)
        for _, l in ipairs(room.lights) do
          if curLevel(l) > 0 then
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
  setStatus(string.format("OK %s | lights driven: %d | rooms held: %d | cloud: %s",
    os.date("%H:%M", now), n, held, cloudPct and (math.floor(cloudPct) .. "%") or "n/a"))
end

---------------------------------------------------------------------------
-- override detection
---------------------------------------------------------------------------
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if idVariable ~= LIGHT_LEVEL_VAR then return end
  local room = lightIndex[idDevice]
  if not room then return end
  local light
  for _, l in ipairs(room.lights) do if l.id == idDevice then light = l end end
  if not light or not light.lastLevel then return end
  local now = os.time()
  if light.ignoreUntil and now <= light.ignoreUntil then return end
  local v = tonumber(strValue) or 0
  if math.abs(v - light.lastLevel) > 8 then
    local holdSec = (tonumber(Properties["Override Hold (min)"]) or 120) * 60
    room.overrideUntil = math.max(room.overrideUntil or 0, now + holdSec)   -- never shorten a scene hold
    dbg("manual change detected, holding", room.name, "for min", tostring(holdSec / 60))
  end
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

local function loadRooms()
  rooms, lightIndex = {}, {}
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
      occ = (r.occ and r.occ.dev and r.occ.dev > 0) and { dev = r.occ.dev, var = r.occ.var or 1000 } or nil,
      lights = {},
    }
    for _, l in ipairs(r.lights or {}) do
      local id = tonumber(l.id) or 0
      if id > 0 then
        local light = { id = id, kind = l.kind or "lutron", scale = clamp(tonumber(l.scale) or 1, 0.05, 1), max_level = tonumber(l.max_level), window_gain = tonumber(l.window_gain), facing_deg = tonumber(l.facing_deg), windows = parseWindows(l.windows), cct_min = tonumber(l.cct_min) or 1500, cct_max = tonumber(l.cct_max) or 4000 }
        table.insert(room.lights, light)
        lightIndex[id] = room
        C4:UnregisterVariableListener(id, LIGHT_LEVEL_VAR)
        C4:RegisterVariableListener(id, LIGHT_LEVEL_VAR)
      end
    end
    if #room.lights > 0 then table.insert(rooms, room) end
  end
  dbg("rooms loaded", tostring(#rooms))
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
  loadRooms()
  startTimers()
  startPresenceServer()
  pollCloud()
  C4:SetTimer(15000, function() Update() end, false)   -- first pass after loads settle
end

function OnPropertyChanged(name)
  if name == "Rooms JSON" then loadRooms()
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
  for _, r in ipairs(rooms) do for _, l in ipairs(r.lights) do l.lastLevel, l.lastCCT = nil, nil end end
end

local function setPresence(state)
  local away = (tostring(state or ""):lower() == "away")
  if away == presenceAway then return end
  presenceAway = away
  if PersistData then PersistData.presenceAway = away end
  C4:UpdateProperty("Presence", away and "Away" or "Home")
  if away then
    for _, r in ipairs(rooms) do
      r.overrideUntil = nil
      for _, l in ipairs(r.lights) do l.lastLevel, l.lastCCT = nil, nil end
    end
  else
    releaseAll()          -- arriving home: drop scene/Off holds, resume the schedule
  end
  Update()
end

function startPresenceServer()
  if serverHandle then pcall(function() C4:DestroyServer() end) serverHandle = nil end
  local port = tonumber(Properties["Presence Port"]) or 0
  if port > 0 and C4.CreateServer then serverHandle = C4:CreateServer(port) end
end

-- one line per message:  PRESENCE HOME|AWAY [token]
function OnServerDataIn(nHandle, strData, strClientAddress, nClientPort)
  for line in tostring(strData):gmatch("[^\r\n]+") do
    local cmd, arg, tok = line:match("^(%S+)%s+(%S+)%s*(%S*)")
    local want = Properties["Presence Token"] or ""
    local reply = "ERR\r\n"
    if cmd and cmd:upper() == "PRESENCE" and (want == "" or tok == want) then
      setPresence(arg)
      reply = "OK\r\n"
    end
    pcall(function() C4:ServerSend(nHandle, reply) end)
  end
  pcall(function() C4:ServerCloseClient(nHandle) end)
end
function OnServerConnectionStatusChanged(nHandle, nPort, strStatus) end

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
