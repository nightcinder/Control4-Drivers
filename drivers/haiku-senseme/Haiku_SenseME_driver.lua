--[[==============================================================================
	Big Ass Fans - Haiku (SenseME) - Control4 Driver
	Unofficial / community driver. Not affiliated with or supported by
	Big Ass Fans or Control4.

	SenseME protocol (application layer): plain-ASCII commands over UDP port
	31415. Commands to the fan look like:    <FanName;FAN;SPD;SET;3>
	Responses from the fan look like:        (FanName;FAN;SPD;ACTUAL;3)
	Multiple parenthesized groups can arrive concatenated in one packet.
	Protocol reference (public, reverse-engineered, non-vendor docs):
	  https://bruce.pennypacker.org/2015/07/17/hacking-bigass-fans-with-senseme/
	  https://github.com/TomFaulkner/SenseMe
	  https://github.com/bdraco/aiosenseme

	Control4 DriverWorks API usage in this file (network layer, proxy
	notification names/params) has been checked against:
	  - Control4's own official sample: sample_drivers/light_sample.c4i
	    (github.com/control4/docs-driverworks) - confirms ONLINE_CHANGED,
	    LIGHT_LEVEL notify pattern, SET_LEVEL/RAMP_TO_LEVEL param names,
	    GET_CONNECTED_STATE handling.
	  - Two independent real-world UDP driver snippets (SendToNetwork /
	    ReceivedFromNetwork / OnConnectionStatusChanged / OnNetworkBindingChanged
	    signatures) from public Control4 driver repos.
	  - finitelabs/control4-esphome (active, maintained) confirming the FAN
	    proxy uses a "SPEED" param name for SET_SPEED.

	Known remaining uncertainty: the exact FAN proxy notification name(s) this
	driver should push back to Navigator (FanState/Speed) are NOT confirmed
	against an official Control4 fan sample (none is published, unlike
	light_v2). This driver uses the same pattern light_v2 uses (a single
	scalar notify per changed value) as its best-effort analogue. Verify
	against DriverEditor's proxy autocomplete for your OS version before
	relying on this in production.
================================================================================]]

-- ===================== Globals / Config ============================
g_ip          = "0.0.0.0"
g_name        = ""          -- SenseME device name, as shown in the SenseME app
g_mac         = ""
g_hasLight    = true
g_maxSpeed    = 7
g_pollInt     = 60
g_logMode     = "Off"

FAN_BINDING   = 5001
LIGHT_BINDING = 5002
NET_BINDING   = 6001
UDP_PORT      = 31415

g_fanState    = { power = "OFF", speed = 0, whoosh = "OFF", direction = "FWD" }
g_lightState  = { power = "OFF", level = 0 }

g_rxBuffer     = ""
g_pollTimerId  = nil
g_netBound     = false   -- OnNetworkBindingChanged state
g_netOnline    = false   -- OnConnectionStatusChanged state
g_boundIP      = nil     -- last IP passed to C4:CreateNetworkConnection

-- ===================== Logging helper ============================
function LOG(msg)
	if (g_logMode == "Print" or g_logMode == "Print and Log") then
		print("[Haiku] " .. tostring(msg))
	end
	if (g_logMode == "Log" or g_logMode == "Print and Log") then
		C4:DebugLog("[Haiku] " .. tostring(msg))
	end
end

-- ===================== Driver lifecycle ============================
function OnDriverInit()
	LoadProperties()
	LOG("OnDriverInit - IP=" .. g_ip .. " Name=" .. g_name)
end

function OnDriverLateInit()
	LoadProperties()
	BindTo(g_ip)
	StartPolling()
	NotifyOnline(false) -- will flip true once OnConnectionStatusChanged reports ONLINE
end

function OnDriverDestroyed()
	StopPolling()
end

function LoadProperties()
	g_ip       = Properties["Fan IP Address"] or g_ip
	g_name     = Properties["Fan Name (SenseME App Name)"] or g_name
	g_mac      = Properties["Fan MAC Address"] or g_mac
	g_hasLight = (Properties["Has Light Kit"] ~= "No")
	g_maxSpeed = tonumber(Properties["Max Fan Speed (0-7)"]) or 7
	g_pollInt  = tonumber(Properties["Poll Interval (seconds)"]) or 60
	g_logMode  = Properties["Log Mode"] or "Off"
end

function OnPropertyChanged(strProperty)
	LoadProperties()
	LOG("Property changed: " .. strProperty)

	if (strProperty == "Fan IP Address") then
		BindTo(g_ip)
		RequestFullStatus()
	elseif (strProperty == "Poll Interval (seconds)") then
		StopPolling()
		StartPolling()
	end
end

-- ===================== Network connection management ============================
-- Control4's DriverWorks network API is connectionless-agnostic: a binding
-- (declared in driver.xml, id=6001 here) is pointed at a specific destination
-- IP with C4:CreateNetworkConnection(idBinding, ipAddress), then put into UDP
-- mode with C4:NetConnect(idBinding, port, 'UDP'). Sends after that go through
-- C4:SendToNetwork(idBinding, nPort, strData) - there is no per-call address
-- parameter, so to switch between broadcast (discovery) and unicast (normal
-- control) traffic we have to re-bind the connection each time the target
-- changes.

function BindTo(sIP)
	if (sIP == nil or sIP == "") then sIP = "0.0.0.0" end
	if (sIP == g_boundIP) then return end
	LOG("Binding network connection to " .. sIP)
	local ok, err = pcall(function()
		C4:CreateNetworkConnection(NET_BINDING, sIP)
	end)
	if (not ok) then
		LOG("CreateNetworkConnection failed: " .. tostring(err))
		return
	end
	g_boundIP = sIP
	if (g_netBound) then
		pcall(function() C4:NetConnect(NET_BINDING, UDP_PORT, "UDP") end)
	end
end

function OnNetworkBindingChanged(idBinding, bIsBound)
	if (idBinding ~= NET_BINDING) then return end
	LOG("OnNetworkBindingChanged: bound=" .. tostring(bIsBound))
	g_netBound = bIsBound
	if (bIsBound) then
		pcall(function() C4:NetConnect(NET_BINDING, UDP_PORT, "UDP") end)
	end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if (idBinding ~= NET_BINDING) then return end
	LOG("OnConnectionStatusChanged: " .. tostring(strStatus))
	g_netOnline = (strStatus == "ONLINE")
	C4:UpdateProperty("Connection Status", tostring(strStatus))
	NotifyOnline(g_netOnline)
end

function NotifyOnline(bOnline)
	local sState = bOnline and "true" or "false"
	C4:SendToProxy(FAN_BINDING, "ONLINE_CHANGED", { STATE = sState }, "NOTIFY")
	if (g_hasLight) then
		C4:SendToProxy(LIGHT_BINDING, "ONLINE_CHANGED", { STATE = sState }, "NOTIFY")
	end
end

-- Low-level UDP send. All outbound traffic goes through here.
function SendUDP(sIP, sData)
	BindTo(sIP)
	LOG("TX -> " .. sIP .. ":" .. UDP_PORT .. "  " .. sData)
	local ok, err = pcall(function()
		C4:SendToNetwork(NET_BINDING, UDP_PORT, sData)
	end)
	if (not ok) then
		LOG("SendUDP failed: " .. tostring(err))
	end
end

function SendToFan(sPayload)
	if (g_ip == nil or g_ip == "" or g_ip == "0.0.0.0") then
		LOG("Cannot send, fan IP not configured: " .. sPayload)
		return
	end
	SendUDP(g_ip, sPayload)
end

-- Broadcast a discovery request on the local /24. The fan(s) reply with
-- their name/MAC/model in the payload (source IP of the reply is NOT exposed
-- by this network API), so discovery confirms the correct fan/name/MAC but
-- you still need to enter the fan's static/reserved IP address yourself.
function RequestDiscovery()
	local bcast = BroadcastAddressFor(g_ip)
	SendUDP(bcast, "<ALL;DEVICE;ID;GET>")
	-- rebind back to the configured unicast IP for normal traffic
	BindTo(g_ip)
end

function BroadcastAddressFor(sIP)
	if (sIP == nil or sIP == "" or sIP == "0.0.0.0") then
		return "255.255.255.255"
	end
	local a, b, c = sIP:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
	if (a == nil) then
		return "255.255.255.255"
	end
	return a .. "." .. b .. "." .. c .. ".255"
end

function RequestFullStatus()
	if (g_name == nil or g_name == "") then
		RequestDiscovery()
		return
	end
	SendToFan("<" .. g_name .. ";GETALL>")
end

-- ===================== Polling ============================
function StartPolling()
	StopPolling()
	if (g_pollInt <= 0) then return end
	g_pollTimerId = C4:AddTimer(g_pollInt * 1000, "SECONDS", true, "OnPollTimer")
end

function StopPolling()
	if (g_pollTimerId ~= nil) then
		pcall(function() C4:KillTimer(g_pollTimerId) end)
		g_pollTimerId = nil
	end
end

function OnPollTimer(idTimer)
	RequestFullStatus()
end

-- ===================== Receiving from the fan ============================
-- Confirmed signature: ReceivedFromNetwork(idBinding, nPort, strData)
-- (no source-address parameter is provided by this API).
function ReceivedFromNetwork(idBinding, nPort, data)
	if (idBinding ~= NET_BINDING) then return end
	LOG("RX <- port " .. tostring(nPort) .. "  " .. tostring(data))

	g_rxBuffer = g_rxBuffer .. tostring(data)
	for group in g_rxBuffer:gmatch("%(([^%(%)]*)%)") do
		ParseResponseGroup(group)
	end
	g_rxBuffer = ""
end

-- A group looks like: FanName;FAN;SPD;ACTUAL;3
function ParseResponseGroup(sGroup)
	local fields = {}
	for f in sGroup:gmatch("[^;]+") do
		table.insert(fields, f)
	end
	if (#fields < 3) then return end

	local name = fields[1]
	if (g_name == nil or g_name == "") then
		g_name = name
		C4:UpdateProperty("Fan Name (SenseME App Name)", g_name)
	end

	-- Discovery response: Name;DEVICE;ID;MAC
	if (fields[2] == "DEVICE" and fields[3] == "ID") then
		if (fields[4] ~= nil) then
			g_mac = fields[4]
			C4:UpdateProperty("Fan MAC Address", g_mac)
		end
		return
	end

	if (fields[2] == "FAN") then
		HandleFanField(fields)
	elseif (fields[2] == "LIGHT") then
		HandleLightField(fields)
	end
end

function HandleFanField(f)
	local sub = f[3]
	local val = f[#f]

	if (sub == "PWR") then
		g_fanState.power = val
		NotifyFanPower()
	elseif (sub == "SPD") then
		local n = tonumber(val)
		if (n ~= nil) then
			g_fanState.speed = n
			NotifyFanSpeed()
		end
	elseif (sub == "WHOOSH") then
		g_fanState.whoosh = val
	elseif (sub == "DIR") then
		g_fanState.direction = val
	end
end

function HandleLightField(f)
	local sub = f[3]
	local val = f[#f]

	if (sub == "PWR") then
		g_lightState.power = val
		NotifyLightLevelFromPower()
	elseif (sub == "LEVEL") then
		local n = tonumber(val)
		if (n ~= nil) then
			g_lightState.level = n
			NotifyLightLevel()
		end
	end
end

-- ===================== Proxy notifications (device -> Navigator) ============================
-- Pattern confirmed against Control4's official light_sample.c4i:
--   C4:SendToProxy(idBinding, "LIGHT_LEVEL", <scalar value>, "NOTIFY")
-- The FAN proxy's equivalent notify name is NOT officially confirmed (no
-- published fan sample exists); "SPEED" is used here by analogy to the
-- confirmed "SPEED" *command* param name used by real fan drivers. Verify
-- in DriverEditor and adjust if your OS build expects something else.

function NotifyFanPower()
	if (g_fanState.power ~= "ON") then
		C4:SendToProxy(FAN_BINDING, "SPEED", 0, "NOTIFY")
	else
		NotifyFanSpeed()
	end
end

function NotifyFanSpeed()
	local pct = SpeedToPercent(g_fanState.speed)
	if (g_fanState.power ~= "ON") then pct = 0 end
	C4:SendToProxy(FAN_BINDING, "SPEED", pct, "NOTIFY")
end

function NotifyLightLevel()
	local lvl = g_lightState.level
	if (g_lightState.power ~= "ON") then lvl = 0 end
	C4:SendToProxy(LIGHT_BINDING, "LIGHT_LEVEL", lvl, "NOTIFY")
end

function NotifyLightLevelFromPower()
	local lvl = (g_lightState.power == "ON") and g_lightState.level or 0
	C4:SendToProxy(LIGHT_BINDING, "LIGHT_LEVEL", lvl, "NOTIFY")
end

-- ===================== Speed <-> percent mapping ============================
function SpeedToPercent(nSpeed)
	if (g_maxSpeed <= 0) then return 0 end
	local pct = math.floor((nSpeed / g_maxSpeed) * 100 + 0.5)
	if (pct < 0) then pct = 0 end
	if (pct > 100) then pct = 100 end
	return pct
end

function PercentToSpeed(nPercent)
	if (nPercent == nil) then return 0 end
	local step = math.floor((nPercent / 100) * g_maxSpeed + 0.5)
	if (step < 0) then step = 0 end
	if (step > g_maxSpeed) then step = g_maxSpeed end
	return step
end

-- ===================== Proxy commands (Navigator -> device) ============================
function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	LOG("ReceivedFromProxy [" .. tostring(idBinding) .. "] " .. tostring(strCommand))

	if (strCommand == "GET_CONNECTED_STATE") then
		NotifyOnline(g_netOnline)
		return
	end

	if (idBinding == FAN_BINDING) then
		FanProxyCommand(strCommand, tParams)
	elseif (idBinding == LIGHT_BINDING) then
		LightProxyCommand(strCommand, tParams)
	end
end

function FanProxyCommand(cmd, p)
	if (cmd == "ON") then
		SendToFan("<" .. g_name .. ";FAN;PWR;ON>")
	elseif (cmd == "OFF") then
		SendToFan("<" .. g_name .. ";FAN;PWR;OFF>")
	elseif (cmd == "TOGGLE") then
		if (g_fanState.power == "ON") then
			SendToFan("<" .. g_name .. ";FAN;PWR;OFF>")
		else
			SendToFan("<" .. g_name .. ";FAN;PWR;ON>")
		end
	elseif (cmd == "SET_SPEED") then
		local pct = tonumber(p.SPEED) or tonumber(p.LEVEL) or 0
		local step = PercentToSpeed(pct)
		SendToFan("<" .. g_name .. ";FAN;SPD;SET;" .. step .. ">")
	elseif (cmd == "INC_SPEED") then
		local step = math.min(g_fanState.speed + 1, g_maxSpeed)
		SendToFan("<" .. g_name .. ";FAN;SPD;SET;" .. step .. ">")
	elseif (cmd == "DEC_SPEED") then
		local step = math.max(g_fanState.speed - 1, 0)
		SendToFan("<" .. g_name .. ";FAN;SPD;SET;" .. step .. ">")
	else
		LOG("Unhandled fan proxy command: " .. tostring(cmd))
	end
end

function LightProxyCommand(cmd, p)
	if (cmd == "ON") then
		SendToFan("<" .. g_name .. ";LIGHT;PWR;ON>")
	elseif (cmd == "OFF") then
		SendToFan("<" .. g_name .. ";LIGHT;PWR;OFF>")
	elseif (cmd == "TOGGLE") then
		if (g_lightState.power == "ON") then
			SendToFan("<" .. g_name .. ";LIGHT;PWR;OFF>")
		else
			SendToFan("<" .. g_name .. ";LIGHT;PWR;ON>")
		end
	elseif (cmd == "SET_LEVEL" or cmd == "RAMP_TO_LEVEL") then
		local lvl = tonumber(p.LEVEL) or 0
		SendToFan("<" .. g_name .. ";LIGHT;LEVEL;SET;" .. math.floor(lvl) .. ">")
	else
		LOG("Unhandled light proxy command: " .. tostring(cmd))
	end
end

-- ===================== Driver commands / Composer actions ============================
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	LOG("ExecuteCommand: " .. tostring(strCommand))

	if (strCommand == "Rediscover Fan" or strCommand == "ACTION_REDISCOVER") then
		RequestDiscovery()

	elseif (strCommand == "Set Whoosh Mode") then
		local state = tParams["State"] or "OFF"
		SendToFan("<" .. g_name .. ";FAN;WHOOSH;" .. state .. ">")

	elseif (strCommand == "ACTION_WHOOSH_ON") then
		SendToFan("<" .. g_name .. ";FAN;WHOOSH;ON>")

	elseif (strCommand == "ACTION_WHOOSH_OFF") then
		SendToFan("<" .. g_name .. ";FAN;WHOOSH;OFF>")

	elseif (strCommand == "Set Fan Direction") then
		local dir = tParams["Direction"] or "FWD"
		SendToFan("<" .. g_name .. ";FAN;DIR;SET;" .. dir .. ">")

	elseif (strCommand == "ACTION_PRINT_DEBUG") then
		print("=== Haiku Driver Debug ===")
		print("IP: " .. g_ip .. "  Name: " .. g_name .. "  MAC: " .. g_mac)
		print("Bound: " .. tostring(g_netBound) .. "  Online: " .. tostring(g_netOnline))
		print("Fan power=" .. g_fanState.power .. " speed=" .. g_fanState.speed)
		print("Light power=" .. g_lightState.power .. " level=" .. g_lightState.level)
	end
end
