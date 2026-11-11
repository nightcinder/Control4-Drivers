--[[==============================================================================
	Big Ass Fans - Haiku / i6 (BAF i6 protocol) - Control4 Driver
	Unofficial / community driver. Not affiliated with or supported by
	Big Ass Fans or Control4.

	PROTOCOL VERSION 2 (rebuilt): Big Ass Fans replaced the old plaintext
	"SenseME" UDP protocol with a new protocol (referred to as "i6") on
	Haiku fans running firmware 3.0+ and on all i6-series fans. That
	protocol is:
	  - Plain TCP (no TLS) to port 31415 on the fan's IP.
	  - Messages are Protocol Buffers (proto2), wrapped in SLIP framing
	    (RFC 1055: 0xC0 frame delimiter, 0xDB escape byte).
	  - Top-level message is `Root { optional Root2 root2 = 2; }` with
	    `Root2 { Commit commit = 2; Query query = 3; QueryResult query_result = 4; }`.
	  - Discovery is normally done via mDNS/Zeroconf (_api._tcp.local.),
	    which Control4 DriverWorks has no API for, so this driver instead
	    connects directly to the fan's configured IP address (matching how
	    every Control4 IP driver already works - one instance per device).

	This Lua file hand-implements the minimal protobuf wire format needed
	(varint + length-delimited fields only - that's all this protocol
	uses) since DriverWorks Lua has no protobuf library available.

	References (public, reverse-engineered, non-vendor docs):
	  https://github.com/jfroy/aiobafi6 (protocol + wire framing + .proto schema)
	  https://github.com/bdraco/aiosenseme (predecessor library; its README
	    documents that BAF changed protocols, which is what led here)
	  https://bruce.pennypacker.org/2015/07/17/hacking-bigass-fans-with-senseme/
	    (the OLD protocol this driver no longer uses - kept for context only)

	FAN proxy protocol (confirmed against Control4's official DriverWorks
	Proxy Protocol reference and a real production fan driver's source):
	  Commands (Navigator -> driver): ON, OFF, TOGGLE, SET_SPEED (SPEED =
	    discrete step 0..discrete_levels, NOT a percent), CYCLE_SPEED_UP,
	    CYCLE_SPEED_DOWN, SET_DIRECTION, TOGGLE_DIRECTION, GET_CURRENT_STATE.
	  Notifications (driver -> Navigator): "ON"/"OFF" (bare, no params),
	    "CURRENT_SPEED" with { SPEED = step }.
	  driver.xml MUST declare <capabilities><discrete_levels>N</discrete_levels>
	  </capabilities> or Navigator never registers the fan proxy as speed-
	  capable at all - it silently falls back to showing only the LIGHT_V2
	  proxy (filed under "Lights", no speed control). This was the root
	  cause of that exact symptom on first deploy of this driver.
================================================================================]]

-- ===================== Globals / Config ============================
-- v400: FAN-ONLY driver. A driver cannot add or remove a proxy at runtime, so the light
-- lives in a separate optional child driver ("Haiku SenseME Light", light_v2 proxy), one per
-- fan that has a light kit. The child binds to this driver's "Light Kit Link" connection (5002)
-- and talks to it with C4:SendToDevice (same pattern as SwitchBot Cloud / Curtain).
--   child -> fan : HK_REGISTER {CHILD_ID}, HK_LIGHT_CMD {CMD=ON|OFF|TOGGLE|SET_LEVEL, LEVEL}, HK_POLL
--   fan -> child : HK_LIGHT {POWER, LEVEL, HASLIGHT, ONLINE, FANNAME}, HK_HELLO
-- The fan keeps the TCP connection, parsing, and light-kit auto-detection (Has Light Kit property).

g_ip          = "0.0.0.0"
g_name        = ""          -- reported by the fan itself once connected
g_mac         = ""
-- g_hasLight is the LIVE, per-device detected capability (from the fan's own
-- protobuf Capabilities.has_light field) - purely informational in the combo
-- (driver-level) property; auto-synced to the read-only "Has Light
-- Kit" property below so Composer shows the true hardware state.
g_hasLight    = true
g_maxSpeed    = 7
g_pollInt     = 60
g_logMode     = "Off"

FAN_BINDING   = 5001
LINK_BINDING  = 5002   -- provider connection the child light driver binds to
NET_BINDING   = 6001
TCP_PORT      = 31415

-- BAF i6 protobuf field numbers (see proto/aiobafi6.proto)
PF_NAME                     = 1
PF_MODEL                    = 2
PF_FIRMWARE_VERSION         = 7
PF_MAC_ADDRESS              = 8
PF_CAPABILITIES             = 17
PF_CAP_HAS_LIGHT            = 4   -- nested inside Capabilities (field 17)
PF_FAN_MODE                 = 43  -- enum OffOnAuto: OFF=0 ON=1 AUTO=2
PF_REVERSE_ENABLE           = 44  -- bool
PF_SPEED_PERCENT            = 45  -- int32 0-100
PF_SPEED                    = 46  -- int32 0-7
PF_WHOOSH_ENABLE            = 58  -- bool
PF_LIGHT_MODE                = 68  -- enum OffOnAuto
PF_LIGHT_BRIGHTNESS_PERCENT = 69  -- int32 0-100
PF_LIGHT_BRIGHTNESS_LEVEL   = 70  -- int32 0-16
PF_IP_ADDRESS                = 120 -- string

-- Root2 / Commit / Query / QueryResult field numbers
-- Keep in sync with <version> in driver.xml; shown in the read-only "Driver Version" property
DRIVER_VERSION    = "401"

RF_ROOT2          = 2
R2F_COMMIT        = 2
R2F_QUERY         = 3
R2F_QUERY_RESULT  = 4
CF_PROPERTIES     = 3
QF_PROPERTY_QUERY = 1
QRF_PROPERTIES    = 2

g_fanState    = { power = "OFF", speed = 0, whoosh = "OFF", reverse = false }
g_lightState  = { power = "OFF", level = 0 }
g_fanMode     = nil   -- raw OffOnAuto value last reported by the fan
g_children    = {}    -- child light drivers that sent HK_REGISTER

g_rxBuffer     = ""    -- raw (unescaped) bytes accumulated from the TCP stream
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

-- ===================== Minimal protobuf (varint + length-delimited only) =========
-- BAF's i6 protocol only ever uses wire types 0 (varint) and 2
-- (length-delimited: strings, bytes, embedded messages). No fixed32/64
-- fields are used by anything this driver needs, but the generic walker
-- below still skips them safely (wire types 1 and 5) so unknown/future
-- fields never break parsing.

function PBWriteVarint(value)
	value = math.floor(value)
	if value < 0 then value = 0 end -- this protocol never sends negative values we set
	local out = {}
	repeat
		local b = value % 128
		value = math.floor(value / 128)
		if value > 0 then b = b + 128 end
		table.insert(out, string.char(b))
	until value == 0
	return table.concat(out)
end

-- Returns value, nextPos. `data` is a Lua string, 1-indexed.
function PBReadVarint(data, pos)
	local result = 0
	local mult = 1
	while true do
		local b = string.byte(data, pos)
		if b == nil then return nil, pos end -- truncated
		pos = pos + 1
		result = result + (b % 128) * mult
		if b < 128 then break end
		mult = mult * 128
	end
	return result, pos
end

function PBTag(fieldNum, wireType)
	return PBWriteVarint(fieldNum * 8 + wireType)
end

-- Encode a single varint-wire-type field (int32 / bool / enum).
function PBVarintField(fieldNum, value)
	local v = value
	if v == true then v = 1 elseif v == false then v = 0 end
	return PBTag(fieldNum, 0) .. PBWriteVarint(v)
end

-- Encode a length-delimited field from raw bytes (string or nested message bytes).
function PBBytesField(fieldNum, bytes)
	return PBTag(fieldNum, 2) .. PBWriteVarint(#bytes) .. bytes
end

-- Walk a protobuf message byte range, invoking cb(fieldNum, wireType, value)
-- for every field. For wireType==2, `value` is the raw sub-slice (string or
-- submessage bytes). For wireType==0, `value` is the decoded varint number.
-- Unsupported/unused wire types (1, 5) are skipped safely.
function PBWalk(data, startPos, endPos, cb)
	local pos = startPos
	while pos <= endPos do
		local tag
		tag, pos = PBReadVarint(data, pos)
		if tag == nil then break end
		local fieldNum = math.floor(tag / 8)
		local wireType = tag % 8
		if wireType == 0 then
			local val
			val, pos = PBReadVarint(data, pos)
			if val == nil then break end
			cb(fieldNum, wireType, val)
		elseif wireType == 2 then
			local len
			len, pos = PBReadVarint(data, pos)
			if len == nil or pos + len - 1 > endPos then break end
			local sub = string.sub(data, pos, pos + len - 1)
			cb(fieldNum, wireType, sub)
			pos = pos + len
		elseif wireType == 1 then
			pos = pos + 8
		elseif wireType == 5 then
			pos = pos + 4
		else
			break -- deprecated group encoding - not used by this protocol
		end
	end
end

-- ===================== SLIP framing (RFC 1055) ============================
function SlipEncode(bytes)
	local out = { string.char(0xC0) }
	for i = 1, #bytes do
		local b = string.byte(bytes, i)
		if b == 0xC0 then
			table.insert(out, string.char(0xDB, 0xDC))
		elseif b == 0xDB then
			table.insert(out, string.char(0xDB, 0xDD))
		else
			table.insert(out, string.char(b))
		end
	end
	table.insert(out, string.char(0xC0))
	return table.concat(out)
end

function SlipDecode(escaped)
	local out = {}
	local i = 1
	local n = #escaped
	while i <= n do
		local b = string.byte(escaped, i)
		if b == 0xDB then
			i = i + 1
			local b2 = string.byte(escaped, i)
			if b2 == 0xDC then
				table.insert(out, string.char(0xC0))
			elseif b2 == 0xDD then
				table.insert(out, string.char(0xDB))
			else
				return nil -- invalid escape sequence
			end
		else
			table.insert(out, string.char(b))
		end
		i = i + 1
	end
	return table.concat(out)
end

-- ===================== BAF i6 message builders ============================

-- Root{ root2: { query: { property_query: 0 (ALL) } } }
function BuildQueryAll()
	local query = PBVarintField(QF_PROPERTY_QUERY, 0) -- ALL = 0
	local root2 = PBBytesField(R2F_QUERY, query)
	local root  = PBBytesField(RF_ROOT2, root2)
	return SlipEncode(root)
end

-- propFields: array of {field=N, val=V} varint fields to set on Properties.
-- Root{ root2: { commit: { properties: { <propFields...> } } } }
function BuildCommit(propFields)
	local propBytes = {}
	for _, f in ipairs(propFields) do
		table.insert(propBytes, PBVarintField(f.field, f.val))
	end
	local properties = table.concat(propBytes)
	local commit = PBBytesField(CF_PROPERTIES, properties)
	local root2  = PBBytesField(R2F_COMMIT, commit)
	local root   = PBBytesField(RF_ROOT2, root2)
	return SlipEncode(root)
end

-- Parses one Properties submessage into a plain Lua table.
function ParseProperties(bytes)
	local p = {}
	local seen = {}
	PBWalk(bytes, 1, #bytes, function(fn, wt, val)
		table.insert(seen, tostring(fn) .. "=" .. ((wt == 0) and tostring(val) or ("wt" .. tostring(wt))))
		if fn == PF_NAME and wt == 2 then p.name = val
		elseif fn == PF_MODEL and wt == 2 then p.model = val
		elseif fn == PF_FIRMWARE_VERSION and wt == 2 then p.firmware_version = val
		elseif fn == PF_MAC_ADDRESS and wt == 2 then p.mac_address = val
		elseif fn == PF_IP_ADDRESS and wt == 2 then p.ip_address = val
		elseif fn == PF_FAN_MODE and wt == 0 then p.fan_mode = val
		elseif fn == PF_REVERSE_ENABLE and wt == 0 then p.reverse_enable = (val ~= 0)
		elseif fn == PF_SPEED_PERCENT and wt == 0 then p.speed_percent = val
		elseif fn == PF_SPEED and wt == 0 then p.speed = val
		elseif fn == PF_WHOOSH_ENABLE and wt == 0 then p.whoosh_enable = (val ~= 0)
		elseif fn == PF_LIGHT_MODE and wt == 0 then p.light_mode = val
		elseif fn == PF_LIGHT_BRIGHTNESS_PERCENT and wt == 0 then p.light_brightness_percent = val
		elseif fn == PF_LIGHT_BRIGHTNESS_LEVEL and wt == 0 then p.light_brightness_level = val
		elseif fn == PF_CAPABILITIES and wt == 2 then
			PBWalk(val, 1, #val, function(fn2, wt2, val2)
				if fn2 == PF_CAP_HAS_LIGHT and wt2 == 0 then p.has_light = (val2 ~= 0) end
			end)
		end
	end)
	p._seen = table.concat(seen, ",")
	return p
end

-- Parses a full (unescaped) Root message. Returns an array of Properties
-- tables (one per Properties submessage found in query_result).
function ParseRootMessage(bytes)
	local results = {}
	PBWalk(bytes, 1, #bytes, function(fn, wt, val)
		if fn == RF_ROOT2 and wt == 2 then
			PBWalk(val, 1, #val, function(fn2, wt2, val2)
				LOG("RX Root2 field " .. tostring(fn2) .. " wt " .. tostring(wt2))
				if fn2 == R2F_QUERY_RESULT and wt2 == 2 then
					PBWalk(val2, 1, #val2, function(fn3, wt3, val3)
						if fn3 == QRF_PROPERTIES and wt3 == 2 then
							table.insert(results, ParseProperties(val3))
						end
					end)
				elseif fn2 == R2F_COMMIT and wt2 == 2 then
					-- Some fans push app-side changes as a Commit instead of a QueryResult
					PBWalk(val2, 1, #val2, function(fn3, wt3, val3)
						if fn3 == CF_PROPERTIES and wt3 == 2 then
							table.insert(results, ParseProperties(val3))
						end
					end)
				end
			end)
		end
	end)
	return results
end

-- ===================== Driver lifecycle ============================
function OnDriverInit()
	LoadProperties()
	C4:UpdateProperty("Driver Version", DRIVER_VERSION)
	LOG("OnDriverInit - IP=" .. g_ip .. " Name=" .. g_name)
end

function OnDriverLateInit()
	LoadProperties()
	C4:UpdateProperty("Driver Version", DRIVER_VERSION)
	LOG("Driver version " .. DRIVER_VERSION)
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
	g_hasLight = (Properties["Has Light Kit"] == "Yes")
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

-- ===================== Network connection management (TCP) ============================
-- Unlike the old SenseME UDP protocol, the i6 protocol is a persistent TCP
-- connection per fan (matching how every real client, including the BAF
-- app's mDNS-resolved connection, talks to exactly one fan at a time).
-- Since discovery normally happens via mDNS - which DriverWorks has no API
-- for - this driver connects directly to the configured Fan IP Address.

function BindTo(sIP)
	if (sIP == nil or sIP == "" or sIP == "0.0.0.0") then
		LOG("No fan IP configured - not connecting.")
		return
	end
	if (sIP == g_boundIP and g_netOnline) then return end
	LOG("Connecting (TCP) to " .. sIP .. ":" .. TCP_PORT)
	local ok, err = pcall(function()
		C4:CreateNetworkConnection(NET_BINDING, sIP)
	end)
	if (not ok) then
		LOG("CreateNetworkConnection failed: " .. tostring(err))
		return
	end
	g_boundIP = sIP
	g_rxBuffer = ""
	local ok2, err2 = pcall(function() C4:NetConnect(NET_BINDING, TCP_PORT, "TCP") end)
	if (not ok2) then
		LOG("NetConnect (TCP) failed: " .. tostring(err2))
	end
end

function OnNetworkBindingChanged(idBinding, bIsBound)
	if (idBinding ~= NET_BINDING) then return end
	LOG("OnNetworkBindingChanged: bound=" .. tostring(bIsBound))
	g_netBound = bIsBound
	if (bIsBound and g_boundIP ~= nil) then
		pcall(function() C4:NetConnect(NET_BINDING, TCP_PORT, "TCP") end)
	end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if (idBinding ~= NET_BINDING) then return end
	LOG("OnConnectionStatusChanged: " .. tostring(strStatus))
	local wasOnline = g_netOnline
	g_netOnline = (strStatus == "ONLINE")
	C4:UpdateProperty("Connection Status", tostring(strStatus))
	NotifyOnline(g_netOnline)
	if (g_netOnline and not wasOnline) then
		g_rxBuffer = ""
		RequestFullStatus()
	end
end

-- Low-level TCP send. All outbound traffic goes through here.
function SendTCP(frameBytes)
	if (not g_netOnline) then
		LOG("Cannot send, not connected to fan yet.")
		return
	end
	local ok, err = pcall(function()
		C4:SendToNetwork(NET_BINDING, TCP_PORT, frameBytes)
	end)
	if (not ok) then
		LOG("SendTCP failed: " .. tostring(err))
	end
end

function RequestFullStatus()
	if (g_ip == nil or g_ip == "" or g_ip == "0.0.0.0") then
		LOG("Cannot query, fan IP not configured.")
		return
	end
	LOG("Sending Query ALL")
	SendTCP(BuildQueryAll())
end

-- "Rediscover" no longer means broadcast discovery (the i6 protocol uses
-- mDNS for that, which isn't available from DriverWorks). Since each
-- driver instance already targets one known fan IP, "rediscover" instead
-- forces a clean reconnect + full property refresh.
function ForceReconnect()
	LOG("Forcing reconnect to " .. tostring(g_ip))
	g_boundIP = nil
	g_netOnline = false
	BindTo(g_ip)
end

function CommitProperties(propFields)
	SendTCP(BuildCommit(propFields))
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

-- ===================== Receiving from the fan (TCP + SLIP + protobuf) ========
-- Confirmed signature: ReceivedFromNetwork(idBinding, nPort, strData)
function ReceivedFromNetwork(idBinding, nPort, data)
	if (idBinding ~= NET_BINDING) then return end
	LOG("RX <- " .. tostring(#tostring(data)) .. " bytes")

	g_rxBuffer = g_rxBuffer .. tostring(data)

	-- Frames are delimited by 0xC0. Extract every complete frame
	-- (0xC0 ... 0xC0) currently in the buffer; keep any trailing partial
	-- frame for the next TCP segment.
	while true do
		local startIdx = string.find(g_rxBuffer, string.char(0xC0), 1, true)
		if (startIdx == nil) then
			g_rxBuffer = ""
			break
		end
		local endIdx = string.find(g_rxBuffer, string.char(0xC0), startIdx + 1, true)
		if (endIdx == nil) then
			-- incomplete frame - keep from the start marker onward
			g_rxBuffer = string.sub(g_rxBuffer, startIdx)
			break
		end
		if (endIdx == startIdx + 1) then
			-- empty frame, skip it
			g_rxBuffer = string.sub(g_rxBuffer, endIdx)
		else
			local escaped = string.sub(g_rxBuffer, startIdx + 1, endIdx - 1)
			local raw = SlipDecode(escaped)
			g_rxBuffer = string.sub(g_rxBuffer, endIdx)
			if (raw ~= nil) then
				local ok, err = pcall(function() HandleRootMessage(raw) end)
				if (not ok) then
					LOG("Failed to parse message: " .. tostring(err))
				end
			else
				LOG("Bad SLIP frame, discarded.")
			end
		end
	end
end

function HandleRootMessage(rawBytes)
	local propsList = ParseRootMessage(rawBytes)
	for _, p in ipairs(propsList) do
		LOG("RX props (field=value): " .. tostring(p._seen))
		ApplyProperties(p)
	end
end

function ApplyProperties(p)
	local changed = false

	if (p.name ~= nil and (g_name == nil or g_name == "")) then
		g_name = p.name
		C4:UpdateProperty("Fan Name (SenseME App Name)", g_name)
	end
	if (p.mac_address ~= nil and p.mac_address ~= g_mac) then
		g_mac = p.mac_address
		C4:UpdateProperty("Fan MAC Address", g_mac)
	end
	local lightDirty = false
	if (p.has_light ~= nil) then
		-- Auto-detected from the fan's own reported Capabilities.has_light bit.
		if (p.has_light ~= g_hasLight) then
			g_hasLight = p.has_light
			C4:UpdateProperty("Has Light Kit", p.has_light and "Yes" or "No")
			LOG("Fan-reported light kit capability: " .. (p.has_light and "Yes" or "No"))
			lightDirty = true
		end
	end

	local fanPowerChanged = false
	local fanSpeedChanged = false
	if (p.fan_mode ~= nil) then
		g_fanMode = p.fan_mode
		local newPower = (p.fan_mode == 1 or p.fan_mode == 2) and "ON" or "OFF" -- OffOnAuto: 1 = ON, 2 = AUTO (running); both count as on
		fanPowerChanged = true -- always renotify so Navigator's fan tile stays in sync
		if (newPower ~= g_fanState.power) then changed = true end
		g_fanState.power = newPower
	end
	if (p.speed ~= nil) then
		fanSpeedChanged = true
		if (p.speed ~= g_fanState.speed) then changed = true end
		g_fanState.speed = p.speed
	end
	if (p.whoosh_enable ~= nil) then
		g_fanState.whoosh = p.whoosh_enable and "ON" or "OFF"
	end
	if (p.reverse_enable ~= nil) then
		g_fanState.reverse = p.reverse_enable
	end

	if (p.light_mode ~= nil) then
		local newLPower = (p.light_mode == 1) and "ON" or "OFF"
		if (newLPower ~= g_lightState.power) then lightDirty = true end
		g_lightState.power = newLPower
	end
	if (p.light_brightness_percent ~= nil and p.light_brightness_percent ~= g_lightState.level) then
		g_lightState.level = p.light_brightness_percent
		lightDirty = true
	end

	if (fanPowerChanged) then
		NotifyFanPower()
	end
	if (fanPowerChanged or fanSpeedChanged) then
		NotifyFanSpeed()
	end
	if (lightDirty) then
		NotifyLight()
	end
end

-- ===================== Proxy notifications (device -> Navigator) ============================
function NotifyOnline(bOnline)
	local sState = bOnline and "true" or "false"
	C4:SendToProxy(FAN_BINDING, "ONLINE_CHANGED", { STATE = sState }, "NOTIFY")
	NotifyLight()
end

-- Per the official Control4 Fan Protocol Notifications (ON / OFF / CURRENT_SPEED
-- / DIRECTION), CURRENT_SPEED takes a discrete step number (0..discrete_levels
-- as declared in driver.xml <capabilities><discrete_levels>), NOT a percentage.
-- Sending the wrong notification name/shape here is what caused Navigator to
-- never register the fan proxy as speed-capable in the first place.
function NotifyFanSpeed()
	local step = g_fanState.speed
	if (g_fanState.power ~= "ON") then step = 0 end
	if (step < 0) then step = 0 end
	if (step > g_maxSpeed) then step = g_maxSpeed end
	C4:SendToProxy(FAN_BINDING, "CURRENT_SPEED", { SPEED = tostring(step) }, "NOTIFY")
end

function NotifyFanPower()
	C4:SendToProxy(FAN_BINDING, g_fanState.power, {}, "NOTIFY") -- "ON" or "OFF" is itself the notification name
end

-- Push the light state to every child light driver bound to the Light Kit Link.
function NotifyLight(onlyChild)
	local lvl = g_lightState.level
	if (g_lightState.power ~= "ON") then lvl = 0 end
	local params = {
		POWER = g_lightState.power, LEVEL = tostring(lvl),
		HASLIGHT = g_hasLight and "1" or "0", ONLINE = g_netOnline and "1" or "0",
		FANNAME = tostring(g_name),
	}
	if (onlyChild) then SendToChild(onlyChild, "HK_LIGHT", params) return end
	for _, id in ipairs(ChildIds()) do SendToChild(id, "HK_LIGHT", params) end
end

function SendToChild(childId, cmd, params)
	pcall(function() C4:SendToDevice(childId, cmd, params or {}) end)
end

function ChildIds()
	local seen, list = {}, {}
	for id in pairs(g_children) do seen[id] = true; list[#list + 1] = id end
	local ok, bound = pcall(function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), LINK_BINDING) end)
	if (ok and type(bound) == "table") then
		for rawId in pairs(bound) do
			local id = tonumber(rawId)
			if (id and not seen[id]) then seen[id] = true; list[#list + 1] = id end
		end
	end
	return list
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
	if (idBinding == LINK_BINDING and bIsBound and otherDeviceId) then
		g_children[tonumber(otherDeviceId)] = true
		SendToChild(tonumber(otherDeviceId), "HK_HELLO", {})
		NotifyLight(tonumber(otherDeviceId))
	end
end

-- percent (0-100) -> fan step (0-g_maxSpeed)
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
	end
end

function FanProxyCommand(cmd, p)
	if (cmd == "ON") then
		CommitProperties({ { field = PF_FAN_MODE, val = 1 } })
	elseif (cmd == "OFF") then
		CommitProperties({ { field = PF_FAN_MODE, val = 0 } })
	elseif (cmd == "TOGGLE") then
		local newMode = (g_fanState.power == "ON") and 0 or 1
		CommitProperties({ { field = PF_FAN_MODE, val = newMode } })
	elseif (cmd == "SET_SPEED") then
		-- Navigator sends SPEED as a discrete step (0..discrete_levels), not a percent.
		local step = math.floor(tonumber(p.SPEED) or tonumber(p.LEVEL) or 0)
		if (step < 0) then step = 0 end
		if (step > g_maxSpeed) then step = g_maxSpeed end
		CommitProperties({
			{ field = PF_FAN_MODE, val = (step > 0) and 1 or 0 },
			{ field = PF_SPEED, val = step },
		})
	elseif (cmd == "CYCLE_SPEED_UP" or cmd == "INC_SPEED") then
		local step = math.min(g_fanState.speed + 1, g_maxSpeed)
		CommitProperties({ { field = PF_FAN_MODE, val = 1 }, { field = PF_SPEED, val = step } })
	elseif (cmd == "CYCLE_SPEED_DOWN" or cmd == "DEC_SPEED") then
		local step = math.max(g_fanState.speed - 1, 0)
		CommitProperties({ { field = PF_FAN_MODE, val = (step > 0) and 1 or 0 }, { field = PF_SPEED, val = step } })
	elseif (cmd == "GET_CURRENT_STATE" or cmd == "GET_STATE") then
		NotifyFanPower()
		NotifyFanSpeed()
	elseif (cmd == "SET_DIRECTION") then
		local dir = tostring(p.DIRECTION or ""):upper()
		local reverse = (dir == "REVERSE" or dir == "REV")
		CommitProperties({ { field = PF_REVERSE_ENABLE, val = reverse } })
	elseif (cmd == "TOGGLE_DIRECTION") then
		CommitProperties({ { field = PF_REVERSE_ENABLE, val = not g_fanState.reverse } })
	else
		LOG("Unhandled fan proxy command: " .. tostring(cmd))
	end
end

function LightLinkCommand(cmd, p)
	if (cmd == "ON") then
		CommitProperties({ { field = PF_LIGHT_MODE, val = 1 } })
	elseif (cmd == "OFF") then
		CommitProperties({ { field = PF_LIGHT_MODE, val = 0 } })
	elseif (cmd == "TOGGLE") then
		local newMode = (g_lightState.power == "ON") and 0 or 1
		CommitProperties({ { field = PF_LIGHT_MODE, val = newMode } })
	elseif (cmd == "SET_LEVEL" or cmd == "RAMP_TO_LEVEL") then
		local lvl = math.floor(tonumber(p.LEVEL) or 0)
		CommitProperties({
			{ field = PF_LIGHT_MODE, val = (lvl > 0) and 1 or 0 },
			{ field = PF_LIGHT_BRIGHTNESS_PERCENT, val = lvl },
		})
	else
		LOG("Unhandled light command: " .. tostring(cmd))
	end
end

-- ===================== Driver commands / Composer actions ============================
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	LOG("ExecuteCommand: " .. tostring(strCommand))

	if (strCommand == "HK_REGISTER") then
		local cid = tonumber(tParams.CHILD_ID)
		if (cid) then
			g_children[cid] = true
			SendToChild(cid, "HK_HELLO", {})
			NotifyLight(cid)
			RequestFullStatus()
		end

	elseif (strCommand == "HK_LIGHT_CMD") then
		LightLinkCommand(tostring(tParams.CMD or ""), tParams)

	elseif (strCommand == "HK_POLL") then
		RequestFullStatus()
		local cid = tonumber(tParams.CHILD_ID)
		if (cid) then NotifyLight(cid) end

	elseif (strCommand == "Rediscover Fan" or strCommand == "ACTION_REDISCOVER") then
		ForceReconnect()

	elseif (strCommand == "Set Whoosh Mode") then
		local state = tostring(tParams["State"] or "OFF"):upper()
		CommitProperties({ { field = PF_WHOOSH_ENABLE, val = (state == "ON") } })

	elseif (strCommand == "ACTION_WHOOSH_ON") then
		CommitProperties({ { field = PF_WHOOSH_ENABLE, val = true } })

	elseif (strCommand == "ACTION_WHOOSH_OFF") then
		CommitProperties({ { field = PF_WHOOSH_ENABLE, val = false } })

	elseif (strCommand == "Set Fan Direction") then
		local dir = tostring(tParams["Direction"] or "FWD"):upper()
		CommitProperties({ { field = PF_REVERSE_ENABLE, val = (dir == "REV" or dir == "REVERSE") } })

	elseif (strCommand == "ACTION_PRINT_DEBUG") then
		print("=== Haiku (i6) Driver Debug ===")
		print("IP: " .. g_ip .. "  Name: " .. g_name .. "  MAC: " .. g_mac)
		print("Bound: " .. tostring(g_netBound) .. "  Online: " .. tostring(g_netOnline))
		print("Fan mode(raw)=" .. tostring(g_fanMode) .. " power=" .. g_fanState.power .. " speed=" .. g_fanState.speed ..
			" whoosh=" .. g_fanState.whoosh .. " reverse=" .. tostring(g_fanState.reverse))
		print("Light power=" .. g_lightState.power .. " level=" .. g_lightState.level)
	end
end
