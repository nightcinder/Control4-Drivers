--[[
  SmartHQ Appliance (child) for Control4 DriverWorks, OS 3.4.x
  Version: 0.3.2  (UNTESTED in Composer/Director; see docs/smarthq.md)

  One instance = one appliance: oven, beverage center, dishwasher, refrigerator, washer or dryer.
  It has no network code. Bind its "SmartHQ Bridge" connection to the SmartHQ Bridge (parent) driver.
  Read-only: the child only displays state and fires events.

  Messages (C4:SendToDevice):
    to parent:   SH_REGISTER {CHILD_ID, APPLIANCE_ID, KIND}
    from parent: SH_STATUS {ONLINE, ACTIVE, STATE, DOOR, TEMP, FREEZER, SETPOINT, TIME, CYCLE, LIGHT, REMOTE, ALERT, ...}
                 SH_PARENT {REACHABLE}
                 SH_HELLO {}  (parent restarted: register again)

  Events: Oven Preheated, Oven Timer Done, Dishwasher Done, Washer Done, Dryer Done, Door Left Open.
  Door Left Open fires once per opening, when the door has been open for Door Open Alert Minutes
  (0 turns it off). Updates come from the parent poll, so the timing is only as fine as Poll Interval.
]]

local DRIVER_VERSION = "0.3.2"
local BRIDGE_BINDING = 1

local EVENT_OVEN_PREHEATED = 1
local EVENT_OVEN_TIMER_DONE = 2
local EVENT_DISHWASHER_DONE = 3
local EVENT_WASHER_DONE = 4
local EVENT_DRYER_DONE = 5
local EVENT_DOOR_LEFT_OPEN = 6

-- Property "Appliance Type" -> the KIND sent to the parent.
local KIND_BY_TYPE = {
  ["Oven"] = "oven",
  ["Beverage Center"] = "beverage_center",
  ["Dishwasher"] = "dishwasher",
  ["Refrigerator"] = "fridge",
  ["Washer"] = "washer",
  ["Dryer"] = "dryer",
}

-- Last values seen, so events fire on changes only. Empty until the first status arrives.
local prev = nil
local doorOpenSince = nil   -- os.time() when the door was first seen open
local doorAlerted = false

-- ============================================================================
-- Helpers
-- ============================================================================
local function trim(s)
  if s == nil then return "" end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function prop(name)
  local v = nil
  pcall(function() v = Properties[name] end)
  return trim(v)
end

local function setProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value or "")) end)
end

local function setStatus(text)
  setProp("Status", text)
  print("SmartHQ child: " .. tostring(text))
end

local function fireEvent(id)
  pcall(function() C4:FireEvent(id) end)
end

local function formatTemp(s)
  if s == nil or s == "" then return "" end
  return tostring(s) .. " F"
end

-- Seconds -> "2h 05m" or "37m". Zero or unknown gives "".
local function formatSeconds(s)
  local n = tonumber(s or "")
  if not n or n <= 0 then return "" end
  local h = math.floor(n / 3600)
  local m = math.floor((n % 3600) / 60)
  if h > 0 then return string.format("%dh %02dm", h, m) end
  return string.format("%dm", m)
end

local function kindOf()
  return KIND_BY_TYPE[prop("Appliance Type")] or ""
end

-- ============================================================================
-- Parent link
-- ============================================================================
local function parentId()
  local ok, id = pcall(function() return C4:GetBoundProviderDevice(C4:GetDeviceID(), BRIDGE_BINDING) end)
  id = ok and tonumber(id) or nil
  if id and id > 0 then return id end
  return nil
end

local function register()
  local appId = prop("Appliance ID")
  local kind = kindOf()
  if kind == "" then setStatus("Choose an Appliance Type"); return end
  if appId == "" then setStatus("Set the Appliance ID"); return end
  local pid = parentId()
  if not pid then
    setStatus("Not connected: bind SmartHQ Bridge in Connections")
    return
  end
  local cid = 0
  pcall(function() cid = C4:GetDeviceID() end)
  pcall(function()
    C4:SendToDevice(pid, "SH_REGISTER", { CHILD_ID = tostring(cid), APPLIANCE_ID = appId, KIND = kind })
  end)
  setStatus("Waiting for SmartHQ Bridge")
end

-- ============================================================================
-- Status from the parent
-- ============================================================================
local function applyStatus(s)
  local kind = kindOf()
  local active = s.ACTIVE == "true"
  local nowTime = tonumber(s.TIME or "") or 0

  setProp("State", s.STATE or "")
  setProp("Door", s.DOOR or "")
  setProp("Temperature", formatTemp(s.TEMP))
  setProp("Freezer Temperature", formatTemp(s.FREEZER))
  setProp("Time Remaining", formatSeconds(s.TIME))
  setProp("Cycle", s.CYCLE or "")
  setProp("Alert", s.ALERT or "")

  -- Events compare with the previous update. The first update only records values.
  if prev then
    if kind == "oven" then
      local wasPre = string.find(string.upper(prev.state), "PREHEAT", 1, true) ~= nil
      local isPre = string.find(string.upper(s.STATE or ""), "PREHEAT", 1, true) ~= nil
      if wasPre and not isPre and active then fireEvent(EVENT_OVEN_PREHEATED) end
      if prev.active and prev.time > 0 and nowTime == 0 then fireEvent(EVENT_OVEN_TIMER_DONE) end
    elseif (kind == "dishwasher" or kind == "washer" or kind == "dryer") and prev.active and not active then
      if kind == "dishwasher" then fireEvent(EVENT_DISHWASHER_DONE)
      elseif kind == "washer" then fireEvent(EVENT_WASHER_DONE)
      else fireEvent(EVENT_DRYER_DONE)
      end
    end
  end

  -- Door left open: fires once per opening.
  local alertMin = tonumber(prop("Door Open Alert Minutes")) or 0
  if (s.DOOR or "") == "Open" then
    if not doorOpenSince then doorOpenSince = os.time() end
    if alertMin > 0 and not doorAlerted and os.time() - doorOpenSince >= alertMin * 60 then
      doorAlerted = true
      fireEvent(EVENT_DOOR_LEFT_OPEN)
    end
  else
    doorOpenSince = nil
    doorAlerted = false
  end

  prev = { state = s.STATE or "", active = active, time = nowTime }
  setStatus("Updated " .. os.date("%H:%M:%S"))
end

-- ============================================================================
-- Driver callbacks
-- ============================================================================
function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "SH_STATUS" then
    if (tParams.ONLINE or "") == "false" then
      setStatus("Appliance offline (bridge reports it)")
    end
    applyStatus(tParams)
  elseif strCommand == "SH_PARENT" then
    if (tParams.REACHABLE or "") == "false" then setStatus("SmartHQ Bridge unreachable") end
  elseif strCommand == "SH_HELLO" then
    register()
  end
end

function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
  setStatus("Starting")
end

function OnDriverLateInit()
  register()
end

function OnPropertyChanged(name)
  if name == "Appliance ID" or name == "Appliance Type" then
    prev = nil
    doorOpenSince = nil
    doorAlerted = false
    register()
  end
end
