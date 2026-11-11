--[[
  Haiku SenseME Light (child) driver for Control4 (OS 3.4.x)
  Version: 4.0.0 (package version 400)
  One instance = the light kit of one Big Ass Fans Haiku / i6 fan. It has no network settings: bind its
  "Haiku Fan" connection to the "Light Kit Link" connection of that fan's "Haiku SenseME Fan" driver.

  Messages (C4:SendToDevice, arrive in ExecuteCommand):
    to fan:   HK_REGISTER {CHILD_ID}, HK_LIGHT_CMD {CMD=ON|OFF|TOGGLE|SET_LEVEL, LEVEL}, HK_POLL {CHILD_ID}
    from fan: HK_LIGHT {POWER, LEVEL, HASLIGHT, ONLINE, FANNAME}, HK_HELLO
]]

local DRIVER_VERSION = "400"
local PROXY_BINDING = 5001
local FAN_LINK = 1

local state = { power = "OFF", level = 0, online = false, hasLight = nil }

local function prop(name)
  local ok, v = pcall(function() return Properties[name] end)
  if ok then return v end
  return nil
end

local function setProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value)) end)
end

local function parentId()
  local ok, id = pcall(function() return C4:GetBoundProviderDevice(C4:GetDeviceID(), FAN_LINK) end)
  id = ok and tonumber(id) or nil
  if id and id > 0 then return id end
  return nil
end

local function sendToFan(cmd, params)
  local pid = parentId()
  if not pid then
    setProp("Status", "Not connected: bind Haiku Fan in Connections")
    return false
  end
  pcall(function() C4:SendToDevice(pid, cmd, params or {}) end)
  return true
end

local function myId()
  local cid = 0
  pcall(function() cid = C4:GetDeviceID() end)
  return tostring(cid)
end

local function register()
  if sendToFan("HK_REGISTER", { CHILD_ID = myId() }) then setProp("Status", "Waiting for fan") end
end

local function notifyProxy()
  local lvl = state.level
  if state.power ~= "ON" then lvl = 0 end
  pcall(function() C4:SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = state.online and "true" or "false" }, "NOTIFY") end)
  pcall(function() C4:SendToProxy(PROXY_BINDING, "LIGHT_LEVEL", lvl, "NOTIFY") end)
end

function OnDriverInit()
  setProp("Driver Version", DRIVER_VERSION)
end

function OnDriverLateInit()
  setProp("Driver Version", DRIVER_VERSION)
  setProp("Status", "Starting")
  -- Give the fan driver a moment to start, then register.
  pcall(function() C4:SetTimer(3000, function() register() end) end)
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  if idBinding == FAN_LINK then
    if bIsBound then register() else setProp("Fan", "Not connected: bind Haiku Fan in Connections") end
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" then
    strCommand = tParams.ACTION
    if strCommand == nil then return end
  end
  if strCommand == "HK_HELLO" then
    register()
  elseif strCommand == "HK_LIGHT" then
    state.power = (tParams.POWER == "ON") and "ON" or "OFF"
    state.level = tonumber(tParams.LEVEL) or 0
    state.online = (tParams.ONLINE == "1")
    state.hasLight = (tParams.HASLIGHT == "1")
    setProp("Fan", (tParams.FANNAME and tParams.FANNAME ~= "") and tParams.FANNAME or "Connected")
    setProp("Light Kit Detected", state.hasLight and "Yes" or "No")
    setProp("Status", state.online and (state.hasLight and "Online" or "Online, fan reports no light kit") or "Fan offline")
    notifyProxy()
  elseif strCommand == "ACTION_REFRESH" or strCommand == "Refresh Status" then
    sendToFan("HK_POLL", { CHILD_ID = myId() })
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  if idBinding ~= PROXY_BINDING then return end
  if strCommand == "GET_CONNECTED_STATE" or strCommand == "GET_LIGHT_LEVEL" then
    notifyProxy()
  elseif strCommand == "ON" or strCommand == "OFF" or strCommand == "TOGGLE" then
    sendToFan("HK_LIGHT_CMD", { CMD = strCommand })
  elseif strCommand == "SET_LEVEL" or strCommand == "RAMP_TO_LEVEL" then
    sendToFan("HK_LIGHT_CMD", { CMD = "SET_LEVEL", LEVEL = tostring(math.floor(tonumber(tParams.LEVEL) or 0)) })
  end
end
