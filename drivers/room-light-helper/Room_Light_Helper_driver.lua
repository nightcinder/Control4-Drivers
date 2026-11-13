--[[
  Room Light Helper v1.2.3 (Control4 DriverWorks, OS 3.x)
  One instance per room. Laundry is the first room.
  Changelog:
    1.2.3 - Room Light ID is a RANGED_INTEGER (plain INTEGER made Composer throw 'Error creating property')
    1.2.2 - light is chosen by typing its device ID (Room Light ID); the Composer device selector was unusable
    1.2.1  Room Light device selector now lists light proxies (fixes 'Error creating property').
           The Room Light property is DEVICE_SELECTOR with an items list (light_v2.c4i, light.c4i)
           and multiselect. The helper reads the first number from it.
    1.2.0  The room light is now chosen with a device selector (Room Light property) instead
           of a binding. Light Connection 5001 removed; the property holds the light's device ID.
    1.1.2  Packaging fix: XML now declares its script (driver.lua), combo and empty
           proxies/capabilities so Composer lists the driver for import.
    1.1.1  Commands moved from Actions to programmable Commands (Request On, Release,
           Release All, Set Lux) so they accept parameters in Composer Programming. Set Lux
           Lux param is RANGED_INTEGER 0-100000 (NUMBER is not a DriverWorks param type).
           OnDriverDestroyed cancels the off timer and the check timer. OnPropertyChanged
           re-runs ensureLightListener. The check timer runs every 10 s until the light
           listener registers, then every 60 s.
           controlmethod is still "none"; its effect on Composer is UNVERIFIED.
    1.1.0  Off Delay default 180 s. New Quick-Release Sources (default Roborock) with
           Quick Off Delay (90 s). The last source to release uses the quick delay when its
           name is in that list. Timeouts and Release All always use Off Delay.
    1.0.0  First release.

  Other programming calls the helper with a Source name:
    Request On (Source), Release (Source), Release All, Set Lux (Lux).
  The helper keeps a set of active sources. The first request turns the bound light on to a
  level picked from lux (darker room = brighter light). If the light was already on, the helper
  leaves it alone and never turns it off. When the last source releases, the light goes off
  after Off Delay, but only if the helper turned it on. A new request cancels a pending off.
  Each source auto-releases after Source Timeout (min), with a log line.

  Room Light ID: plain integer property (typed in Composer) holding the room light's device ID. No binding.
  State is in memory. A driver reload forgets the sources and leaves the light as it is.

  Not in v1: keypad holds, away mode, DLS integration. Max Level is a plain property.
]]

local DRIVER_VERSION = "1.2.3"
local CHECK_FAST_MS = 10000   -- check timer while the light listener is not registered
local CHECK_SLOW_MS = 60000   -- check timer once the listener is registered
local LIGHT_LEVEL_VAR = 1001          -- light proxy LIGHT_LEVEL variable id
local RAMP_MS = 1500
local RELAMP_MIN_CHANGE = 10
local EVENT_ON_BY_HELPER = 1
local EVENT_OFF_BY_HELPER = 2
local EVENT_SOURCE_TIMEOUT = 3

local sources = {}          -- source name -> os.time() of its request
local sourceCount = 0
local helperOn = false      -- helper turned the light on and has not turned it off
local lastLevel = nil
local lux = nil
local luxTime = 0
local offTimer = nil
local checkTimer = nil
local checkInterval = nil   -- ms the current checkTimer was created with
local listenedId = nil

local function dbg(msg)
  if Properties["Debug"] == "On" then print("[RoomLight] " .. tostring(msg)) end
end

local function logf(msg)
  C4:ErrorLog("[Room Light Helper " .. tostring(Properties["Room Name"]) .. "] " .. tostring(msg))
end

local function num(name, default)
  local v = tonumber(Properties[name])
  if v == nil then return default end
  return v
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Light device ID from the Room Light ID property; nil when empty, 0 or not a number (no light selected).
local function getLightId()
  local id = tonumber(Properties["Room Light ID"] or "")
  if id == nil or id == 0 then return nil end
  return id
end

local function getLightLevel()
  local id = getLightId()
  if not id or id == 0 then return nil end
  return tonumber(C4:GetDeviceVariable(id, LIGHT_LEVEL_VAR))
end

-- Level from lux: Max Level at or below Lux Low, Min Level at or above Lux High, linear between.
-- Falls back to Fallback Level when there is no lux reading or it is older than Lux Max Age.
local function computeLevel()
  local minL = num("Min Level", 20)
  local maxL = num("Max Level", 100)
  if minL > maxL then minL, maxL = maxL, minL end
  local fallback = clamp(num("Fallback Level", 60), minL, maxL)
  local maxAgeSec = num("Lux Max Age (min)", 30) * 60
  if lux == nil or (os.time() - luxTime) > maxAgeSec then
    return fallback
  end
  local lowL = num("Lux Low", 20)
  local highL = num("Lux High", 300)
  local level
  if lux <= lowL then
    level = maxL
  elseif lux >= highL then
    level = minL
  else
    local t = (lux - lowL) / (highL - lowL)
    level = maxL + (minL - maxL) * t
  end
  return math.floor(clamp(level, minL, maxL) + 0.5)
end

local function rampTo(level)
  local id = getLightId()
  if not id or id == 0 then
    logf("No light selected: set the Room Light ID property")
    return false
  end
  C4:SendToDevice(id, "RAMP_TO_LEVEL", { LEVEL = level, TIME = RAMP_MS })
  lastLevel = level
  dbg("Ramp to " .. level)
  return true
end

local function lightOff()
  local id = getLightId()
  if id and id ~= 0 then C4:SendToDevice(id, "OFF", {}) end
  lastLevel = nil
end

local function refreshLightState()
  local level = getLightLevel()
  local state = "Idle"
  if level and level > 0 then
    state = helperOn and "On by helper" or "On externally"
  end
  C4:UpdateProperty("Light State", state)
end

local function refreshAll()
  local names = {}
  for name in pairs(sources) do names[#names + 1] = name end
  table.sort(names)
  C4:UpdateProperty("Active Sources", #names > 0 and table.concat(names, ", ") or "None")
  local status
  if sourceCount > 0 then
    status = "Active: " .. sourceCount .. " source(s)"
  elseif offTimer then
    status = "Off pending"
  else
    status = "Idle"
  end
  C4:UpdateProperty("Status", status)
  refreshLightState()
end

local function cancelOffTimer()
  if offTimer then
    offTimer:Cancel()
    offTimer = nil
  end
end

-- True when the source name is in the comma-separated Quick-Release Sources list (case-insensitive).
local function isQuickSource(name)
  local target = trim(name):lower()
  for item in string.gmatch(tostring(Properties["Quick-Release Sources"] or ""), "[^,]+") do
    if trim(item):lower() == target and target ~= "" then return true end
  end
  return false
end

-- Off delay for the last source to release: quick delay for quick-release sources, else Off Delay.
local function offDelayFor(name)
  if isQuickSource(name) then return num("Quick Off Delay (sec)", 90) end
  return num("Off Delay (sec)", 180)
end

local function scheduleOff(delaySec)
  cancelOffTimer()
  if not helperOn then
    refreshAll()
    return
  end
  local delay = math.max(0, delaySec)
  offTimer = C4:SetTimer(delay * 1000, function()
    offTimer = nil
    if sourceCount == 0 and helperOn then
      helperOn = false
      lightOff()
      dbg("Off after delay")
      C4:FireEvent(EVENT_OFF_BY_HELPER)
    end
    refreshAll()
  end)
  dbg("Off scheduled in " .. delay .. " s")
  refreshAll()
end

local function requestOn(name)
  if name == "" then
    logf("Request On ignored: empty Source")
    return
  end
  cancelOffTimer()
  if sourceCount == 0 then
    if helperOn then
      -- Light still on from an earlier request whose off was pending: re-ramp only on a real change.
      local target = computeLevel()
      if lastLevel and math.abs(target - lastLevel) >= RELAMP_MIN_CHANGE then rampTo(target) end
    else
      local level = getLightLevel()
      if level and level > 0 then
        helperOn = false
        dbg("Light already on; leaving it alone")
      else
        if rampTo(computeLevel()) then
          helperOn = true
          C4:FireEvent(EVENT_ON_BY_HELPER)
        end
      end
    end
  end
  if not sources[name] then
    sources[name] = os.time()
    sourceCount = sourceCount + 1
  end
  dbg("Request from " .. name .. " (" .. sourceCount .. " active)")
  refreshAll()
end

local function releaseSource(name)
  if name == "" then
    logf("Release ignored: empty Source")
    return
  end
  if not sources[name] then
    dbg("Release for inactive source " .. name)
    return
  end
  sources[name] = nil
  sourceCount = sourceCount - 1
  dbg("Released " .. name)
  if sourceCount == 0 then
    scheduleOff(offDelayFor(name))
  else
    refreshAll()
  end
end

local function releaseAll()
  sources = {}
  sourceCount = 0
  dbg("Release All")
  scheduleOff(num("Off Delay (sec)", 180))
end

local function setLux(value)
  local v = tonumber(value)
  if v == nil then
    logf("Set Lux ignored, not a number: " .. tostring(value))
    return
  end
  lux = v
  luxTime = os.time()
  dbg("Lux " .. v)
  if sourceCount > 0 and helperOn and lastLevel then
    local target = computeLevel()
    if math.abs(target - lastLevel) >= RELAMP_MIN_CHANGE then rampTo(target) end
  end
  refreshAll()
end

local function checkTimeouts()
  local limit = num("Source Timeout (min)", 120) * 60
  local now = os.time()
  local expired = {}
  for name, since in pairs(sources) do
    if now - since >= limit then expired[#expired + 1] = name end
  end
  if #expired == 0 then return end
  for _, name in ipairs(expired) do
    sources[name] = nil
    sourceCount = sourceCount - 1
    logf("Source timeout: auto-released '" .. name .. "' after " .. (limit / 60) .. " min")
    C4:FireEvent(EVENT_SOURCE_TIMEOUT)
  end
  -- Safety timeouts always use Off Delay, never the quick delay.
  if sourceCount == 0 then scheduleOff(num("Off Delay (sec)", 180)) else refreshAll() end
end

-- Listen for light level changes once a light is selected (re-run from OnPropertyChanged and at startup;
-- switching lights unregisters the old device's listener first).
local function ensureLightListener()
  local id = getLightId()
  if not id or id == 0 then
    if listenedId then
      pcall(C4.UnregisterVariableListener, C4, listenedId, LIGHT_LEVEL_VAR)
      listenedId = nil
    end
    return
  end
  if id ~= listenedId then
    if listenedId then pcall(C4.UnregisterVariableListener, C4, listenedId, LIGHT_LEVEL_VAR) end
    C4:RegisterVariableListener(id, LIGHT_LEVEL_VAR)
    listenedId = id
    refreshAll()
  end
end

-- (Re)create the check timer: fast until the light listener is registered, slow after.
local function setCheckInterval(ms)
  if checkTimer and checkInterval == ms then return end
  if checkTimer then checkTimer:Cancel() end
  checkInterval = ms
  checkTimer = C4:SetTimer(ms, function()
    checkTimeouts()
    ensureLightListener()
    setCheckInterval(listenedId and CHECK_SLOW_MS or CHECK_FAST_MS)
  end, true)
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if idVariable ~= LIGHT_LEVEL_VAR then return end
  local level = tonumber(strValue) or 0
  if level == 0 and helperOn then
    -- Light went off outside the helper: stop owning it.
    helperOn = false
    lastLevel = nil
    dbg("Light turned off externally")
  end
  refreshLightState()
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "REQUEST_ON" then
    requestOn(trim(tParams.Source))
  elseif strCommand == "RELEASE" then
    releaseSource(trim(tParams.Source))
  elseif strCommand == "RELEASE_ALL" then
    releaseAll()
  elseif strCommand == "SET_LUX" then
    setLux(tParams.Lux)
  else
    dbg("Unknown command " .. tostring(strCommand))
  end
end

function OnDriverInit()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
end

function OnDriverLateInit()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
  ensureLightListener()
  setCheckInterval(listenedId and CHECK_SLOW_MS or CHECK_FAST_MS)
  refreshAll()
end

function OnPropertyChanged(name)
  ensureLightListener()
  setCheckInterval(listenedId and CHECK_SLOW_MS or CHECK_FAST_MS)
  refreshAll()
end

function OnDriverDestroyed()
  cancelOffTimer()
  if checkTimer then
    checkTimer:Cancel()
    checkTimer = nil
    checkInterval = nil
  end
  -- Sources are in memory only; no other timers are kept per source.
end
