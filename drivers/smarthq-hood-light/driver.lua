--[[
  SmartHQ Hood Light (child) for Control4 DriverWorks, OS 3.4.x
  Version: 0.3.2  (UNTESTED in Composer/Director; see docs/smarthq.md)

  The hood light as a light_v2 proxy (binding 5001), so it can sit in a room for lighting automation.
  Levels: off=0, dim=33, high=100. A Control4 ON sends high. SET_LEVEL and RAMP_TO_LEVEL: 0 sends off,
  1-66 sends dim, 67-100 sends high.
  Bind its "SmartHQ Bridge" connection to the SmartHQ Bridge (parent) driver. The parent does the
  actual write (POST /appliances/{hood}/command on the liesa bridge) and sends the new state back.

  Messages (C4:SendToDevice):
    to parent:   SH_REGISTER {CHILD_ID, APPLIANCE_ID, KIND = "hood"}
                 SH_HOOD_CMD {CHILD_ID, APPLIANCE_ID, LEVEL = off|dim|on}
    from parent: SH_STATUS {STATE = OFF|DIM|HIGH, FAN, ONLINE}, SH_PARENT {REACHABLE}, SH_HELLO {}

  Feedback to Control4: ON / OFF notifies, and LIGHT_CHANGED with LEVEL (0, 33 or 100) for dim and high.
  The LIGHT_CHANGED name and its LEVEL param are UNVERIFIED for light_v2: check in Composer that the
  light's level slider follows the hood. ON and OFF are the same as the 0.2.x driver.
]]

local DRIVER_VERSION = "0.3.2"
local BRIDGE_BINDING = 1
local PROXY_BINDING = 5001
local APPLIANCE_KIND = "hood"

local lastLevel = nil   -- "off", "dim" or "on" as last reported to Control4

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
  print("SmartHQ hood: " .. tostring(text))
end

local function sendToParent(cmd, params)
  local ok, pid = pcall(function() return C4:GetBoundProviderDevice(C4:GetDeviceID(), BRIDGE_BINDING) end)
  pid = ok and tonumber(pid) or nil
  if not pid or pid <= 0 then
    setStatus("Not connected: bind SmartHQ Bridge in Connections")
    return false
  end
  pcall(function() C4:SendToDevice(pid, cmd, params or {}) end)
  return true
end

local function register()
  local appId = prop("Appliance ID")
  if appId == "" then setStatus("Set the Appliance ID"); return end
  local cid = 0
  pcall(function() cid = C4:GetDeviceID() end)
  if sendToParent("SH_REGISTER", { CHILD_ID = tostring(cid), APPLIANCE_ID = appId, KIND = APPLIANCE_KIND }) then
    setStatus("Waiting for SmartHQ Bridge")
  end
end

-- ============================================================================
-- Light feedback to Control4
-- ============================================================================
local function notifyLevel(level)
  if level == lastLevel then return end
  local wasOn = lastLevel ~= nil and lastLevel ~= "off"
  local nowOn = level ~= "off"
  lastLevel = level
  pcall(function()
    if nowOn then
      if not wasOn then C4:SendToProxy(PROXY_BINDING, "ON", {}, "NOTIFY") end
    else
      C4:SendToProxy(PROXY_BINDING, "OFF", {}, "NOTIFY")
    end
    local pct = (level == "dim") and 33 or (level == "on" and 100 or 0)
    C4:SendToProxy(PROXY_BINDING, "LIGHT_CHANGED", { LEVEL = tostring(pct) }, "NOTIFY")
  end)
end

-- Parent sends STATE as OFF, DIM or HIGH (ERD HOOD_LIGHT_LEVEL names).
local function applyStatus(s)
  local st = string.upper(s.STATE or "")
  local level
  if st == "HIGH" or st == "ON" then level = "on"
  elseif st == "DIM" then level = "dim"
  elseif st == "OFF" then level = "off"
  else return end   -- unknown or empty: keep the last level
  setStatus("Hood light " .. st:lower() .. ", fan " .. (s.FAN or "?"))
  notifyLevel(level)
end

-- ============================================================================
-- Commands from Navigator / programming
-- ============================================================================
local function sendLevel(level)
  local cid = 0
  pcall(function() cid = C4:GetDeviceID() end)
  sendToParent("SH_HOOD_CMD", { CHILD_ID = tostring(cid), APPLIANCE_ID = prop("Appliance ID"), LEVEL = level })
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then return end
  tParams = tParams or {}
  if strCommand == "ON" then
    sendLevel("on")
  elseif strCommand == "OFF" then
    sendLevel("off")
  elseif strCommand == "SET_LEVEL" or strCommand == "RAMP_TO_LEVEL" then
    local lvl = tonumber(tParams.LEVEL) or 0
    if lvl <= 0 then sendLevel("off")
    elseif lvl <= 66 then sendLevel("dim")
    else sendLevel("on")
    end
  end
end

-- ============================================================================
-- Driver callbacks
-- ============================================================================
function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "SH_STATUS" then
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
  if name == "Appliance ID" then
    lastLevel = nil
    register()
  end
end
