-- UniFi Outlet (child) driver for Control4 OS 3.4.x. Version 1.0.0 (UNTESTED on hardware).
-- One instance per outlet. Bound to the UniFi Controller parent over connection 1. The relay proxy (5001)
-- sends CLOSE (= outlet ON), OPEN (= outlet OFF) and TOGGLE to the parent; the parent polls state and pushes
-- it back as UO_STATUS. Relay notifications: CLOSED = ON, OPENED = OFF.
-- Proxy choice: "relay" (class RELAY), the same native on/off proxy family the repo uses for relay-style devices.

local DRIVER_VERSION = "1.0.0"
local CONTROLLER_BINDING = 1
local PROXY_BINDING = 5001

local g_state = nil  -- true = ON, false = OFF, nil = unknown

local function prop(name) return (Properties and Properties[name]) or "" end

local function logv(msg)
  print("[UniFi Outlet] " .. tostring(msg))
end

local function myKey()
  local idx = tonumber(prop("Outlet Index")) or 1
  return prop("Device ID") .. ":" .. idx
end

local function parentId()
  local ok, id = pcall(function() return C4:GetBoundProviderDevice(C4:GetDeviceID(), CONTROLLER_BINDING) end)
  if ok and id and tonumber(id) and tonumber(id) > 0 then return tonumber(id) end
  return nil
end

local function sendToParent(cmd, params)
  local pid = parentId()
  if not pid then
    logv("Parent UniFi Controller is not bound to connection 1")
    return false
  end
  local ok = pcall(function() C4:SendToDevice(pid, cmd, params or {}) end)
  return ok
end

local function publish()
  local text = g_state == nil and "Unknown" or (g_state and "On" or "Off")
  pcall(function() C4:UpdateProperty("Outlet State", text) end)
  if g_state == nil then return end
  pcall(function() C4:SendToProxy(PROXY_BINDING, g_state and "CLOSED" or "OPENED", {}, "NOTIFY") end)
end

local function register()
  if prop("Device ID") == "" then
    logv("Set Device ID and Outlet Index (copy them from the UniFi Controller 'Discovered Outlets' property)")
    return
  end
  local cid = C4:GetDeviceID()
  sendToParent("UO_REGISTER", { CHILD_ID = tostring(cid), KEY = myKey() })
end

-- Page-free relay commands from Navigator / Composer / programming
local RFP = {}
RFP.CLOSE = function() sendToParent("UO_COMMAND", { KEY = myKey(), ACTION = "ON" }) end
RFP.OPEN = function() sendToParent("UO_COMMAND", { KEY = myKey(), ACTION = "OFF" }) end
RFP.TOGGLE = function() sendToParent("UO_COMMAND", { KEY = myKey(), ACTION = "TOGGLE" }) end
RFP.SYNCHRONIZE = function() publish() end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if idBinding == PROXY_BINDING and RFP[strCommand] then RFP[strCommand](tParams) end
end

function OnDriverInit()
  pcall(function() C4:UpdateProperty("Driver Version", DRIVER_VERSION) end)
end

function OnDriverLateInit()
  pcall(function() C4:UpdateProperty("Driver Version", DRIVER_VERSION) end)
  pcall(function() C4:SetTimer(3000, function() register() end) end)
end

function OnPropertyChanged(strProperty)
  if strProperty == "Device ID" or strProperty == "Outlet Index" then register() end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "UO_STATUS" then
    if tostring(tParams.KEY or "") ~= myKey() then return end
    if tParams.STATE == "ON" then g_state = true
    elseif tParams.STATE == "OFF" then g_state = false
    else g_state = nil end
    publish()
    return
  end
  if strCommand == "UO_REFRESH" then register(); return end
  logv("Unhandled ExecuteCommand: " .. tostring(strCommand))
end
