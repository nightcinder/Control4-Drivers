--[[==============================================================================
	IntelliFire (Hearth & Home Technologies IFT-WFM Wi-Fi Module) - Control4 Driver
	Unofficial / community driver. Not affiliated with or supported by
	Hearth & Home Technologies or Control4.

	Fireplace this driver was written for exposes only: OFF / PILOT / FLAME ON,
	plus a flame-height level. It does not attempt to model fan, accessory
	light, or thermostat features that some other IntelliFire units have.

	================================================================================
	PROTOCOL - reverse-engineered, non-vendor docs
	================================================================================
	IntelliFire's local module runs a small HTTP/JSON API on the LAN (TCP port
	80, plain HTTP, no TLS):
	  GET  /poll           -> JSON status blob, no auth required to read
	  GET  /get_challenge  -> returns a hex-encoded challenge/nonce, no auth
	  POST /post           -> control endpoint, requires a signed request (see below)
	  GET  /get_serial      -> device identity (not used by this driver)

	Reference material (public, reverse-engineered, non-vendor):
	  https://github.com/jeeftor/intellifire4py  (the de-facto community client;
	     used as the basis for the Home Assistant, Hubitat, and openHAB
	     integrations for this hardware)
	  https://www.home-assistant.io/integrations/intellifire/
	  https://community.home-assistant.io/t/intellifire-wifi-fireplace-module-hearth-and-home/366883

	/poll returns a flat JSON object. Confirmed fields (from intellifire4py's
	published example) include: power (0/1 main flame), pilot (0/1 standing
	pilot), height (0-4 flame level), light, fanspeed, thermostat, setpoint,
	timer, timeremaining, temperature, battery, errors (array), firmware_version.

	CONTROL / SIGNING - KNOWN UNCERTAINTY, READ BEFORE RELYING ON THIS DRIVER:
	Local writes to /post require a user_id + api_key pulled once from the
	IntelliFire cloud account (iftapi.net) - see intellifire4py's docs for
	get_user_id()/get_fireplace_api_key(). Those two values are entered as
	driver properties below; this driver does NOT implement the cloud login
	flow itself (that surface is less publicly documented and this driver
	only reuses DriverWorks network primitives already confirmed elsewhere
	in this project's Haiku driver, rather than guessing at higher-level
	HTTP-client API signatures).

	The exact request-signing scheme for /post is reconstructed from public,
	independent reverse-engineering writeups (not a single authoritative
	vendor doc) as:
	  1. GET /get_challenge -> hex string "challenge"
	  2. payload = "command=<cmd>&value=<val>"
	  3. response = SHA256( bytes(challenge_hex) .. bytes(apikey_hex) .. payload )
	     ...as a hex digest
	  4. POST /post  body: "command=<cmd>&value=<val>&user=<user_id>&response=<response_hex>"
	This is the best-effort, most consistent description available from public
	sources at the time of writing. It has NOT been verified against a live
	unit by the author of this file. Test against your own fireplace (Log
	Mode = "Print and Log" will show the exact request/response bytes) before
	relying on it, and be ready to adjust ComputeCommandSigning() if your
	firmware's /post rejects the signed request.

	SHA-256 is implemented in pure Lua below (portable, no bitwise-operator or
	bit-library dependency, since Control4's exact Lua runtime/version isn't
	publicly documented). The SHA-256 math itself has been independently
	verified against the FIPS 180-4 test vectors and Python's hashlib -
	only the "what do we feed into it" step above carries protocol risk, not
	the hash implementation itself.

	Control4 DriverWorks API usage in this file (network layer, proxy
	notification names/params) intentionally mirrors the already-checked
	patterns from this project's Haiku_SenseME_driver.lua:
	  - C4:CreateNetworkConnection / C4:NetConnect / C4:SendToNetwork /
	    ReceivedFromNetwork / OnConnectionStatusChanged / OnNetworkBindingChanged
	  - C4:SendToProxy(...,"NOTIFY") / ONLINE_CHANGED / LIGHT_LEVEL pattern,
	    confirmed against Control4's official light_sample.c4i.
	This driver deliberately does NOT use C4:urlGet/C4:urlPost-style helpers,
	since this project has not independently confirmed their exact call
	signature; a raw TCP socket + hand-built HTTP/1.1 request/response is used
	instead, reusing only already-confirmed primitives.
================================================================================]]

-- ===================== Globals / Config ============================
g_ip         = "0.0.0.0"
g_userId     = ""      -- iftapi.net user_id (see header notes)
g_apiKey     = ""      -- fireplace-specific api_key, hex string (see header notes)
g_pollInt    = 20
g_logMode    = "Off"

FIREPLACE_BINDING = 5001
NET_BINDING       = 6001
HTTP_PORT         = 80

g_state = { power = 0, pilot = 0, height = 0, connected_seen = false }

g_rxBuffer     = ""
g_pendingReq   = nil     -- { kind = "poll"|"challenge"|"post", callback = fn }
g_reqQueue     = {}
g_pollTimerId  = nil
g_netBound     = false
g_netOnline    = false
g_boundIP      = nil

-- ===================== Logging helper ============================
function LOG(msg)
	if (g_logMode == "Print" or g_logMode == "Print and Log") then
		print("[IntelliFire] " .. tostring(msg))
	end
	if (g_logMode == "Log" or g_logMode == "Print and Log") then
		C4:DebugLog("[IntelliFire] " .. tostring(msg))
	end
end

-- ===================== Driver lifecycle ============================
function OnDriverInit()
	LoadProperties()
	LOG("OnDriverInit - IP=" .. g_ip)
end

function OnDriverLateInit()
	LoadProperties()
	BindTo(g_ip)
	StartPolling()
	NotifyOnline(false)
end

function OnDriverDestroyed()
	StopPolling()
end

function LoadProperties()
	g_ip      = Properties["Fireplace IP Address"] or g_ip
	g_userId  = Properties["API User ID"] or g_userId
	g_apiKey  = Properties["API Key"] or g_apiKey
	g_pollInt = tonumber(Properties["Poll Interval (seconds)"]) or g_pollInt
	g_logMode = Properties["Log Mode"] or g_logMode
end

function OnPropertyChanged(strProperty)
	LoadProperties()
	LOG("Property changed: " .. strProperty)

	if (strProperty == "Fireplace IP Address") then
		BindTo(g_ip)
		QueuePoll()
	elseif (strProperty == "Poll Interval (seconds)") then
		StopPolling()
		StartPolling()
	end
end

-- ===================== Network connection management ============================
-- Same low-level pattern as this project's Haiku driver: a single TCP binding
-- (declared in driver.xml, id=6001) re-bound to the fireplace's IP. HTTP
-- requests are hand-built and sent with C4:SendToNetwork; responses arrive
-- via ReceivedFromNetwork and are parsed by hand.

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
		pcall(function() C4:NetConnect(NET_BINDING, HTTP_PORT, "TCP") end)
	end
end

function OnNetworkBindingChanged(idBinding, bIsBound)
	if (idBinding ~= NET_BINDING) then return end
	LOG("OnNetworkBindingChanged: bound=" .. tostring(bIsBound))
	g_netBound = bIsBound
	if (bIsBound) then
		pcall(function() C4:NetConnect(NET_BINDING, HTTP_PORT, "TCP") end)
	end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if (idBinding ~= NET_BINDING) then return end
	LOG("OnConnectionStatusChanged: " .. tostring(strStatus))
	g_netOnline = (strStatus == "ONLINE")
	C4:UpdateProperty("Connection Status", tostring(strStatus))
	if (g_netOnline) then
		DrainQueue()
	else
		NotifyOnline(false)
	end
end

function NotifyOnline(bOnline)
	local sState = bOnline and "true" or "false"
	C4:SendToProxy(FIREPLACE_BINDING, "ONLINE_CHANGED", { STATE = sState }, "NOTIFY")
end

-- ===================== HTTP request/response plumbing ============================
-- Every call is queued and sent one at a time (the module is a small embedded
-- HTTP server; issuing overlapping requests is asking for trouble). Each
-- request is built as a raw HTTP/1.1 message with "Connection: close" so we
-- can rely on Content-Length to know when the body is complete.

function QueueRequest(sMethod, sPath, sBody, fCallback)
	table.insert(g_reqQueue, { method = sMethod, path = sPath, body = sBody, callback = fCallback })
	if (g_netOnline and g_pendingReq == nil) then
		DrainQueue()
	end
end

function DrainQueue()
	if (g_pendingReq ~= nil) then return end
	if (#g_reqQueue == 0) then return end
	if (g_ip == nil or g_ip == "" or g_ip == "0.0.0.0") then
		LOG("Cannot send request, Fireplace IP not configured")
		g_reqQueue = {}
		return
	end

	local req = table.remove(g_reqQueue, 1)
	g_pendingReq = req

	local sReq
	if (req.method == "GET") then
		sReq = "GET " .. req.path .. " HTTP/1.1\r\n" ..
		       "Host: " .. g_ip .. "\r\n" ..
		       "Connection: close\r\n\r\n"
	else -- POST
		local body = req.body or ""
		sReq = "POST " .. req.path .. " HTTP/1.1\r\n" ..
		       "Host: " .. g_ip .. "\r\n" ..
		       "Content-Type: application/x-www-form-urlencoded\r\n" ..
		       "Content-Length: " .. tostring(#body) .. "\r\n" ..
		       "Connection: close\r\n\r\n" .. body
	end

	g_rxBuffer = ""
	LOG("HTTP TX -> " .. req.method .. " " .. req.path)
	local ok, err = pcall(function()
		C4:SendToNetwork(NET_BINDING, HTTP_PORT, sReq)
	end)
	if (not ok) then
		LOG("SendToNetwork failed: " .. tostring(err))
		FinishPendingRequest(nil, nil)
	end
end

function ReceivedFromNetwork(idBinding, nPort, data)
	if (idBinding ~= NET_BINDING) then return end
	g_rxBuffer = g_rxBuffer .. tostring(data)

	local headerEnd = g_rxBuffer:find("\r\n\r\n", 1, true)
	if (headerEnd == nil) then return end -- headers not fully received yet

	local headers = g_rxBuffer:sub(1, headerEnd - 1)
	local bodySoFar = g_rxBuffer:sub(headerEnd + 4)

	local statusCode = headers:match("HTTP/1%.[01]%s+(%d+)")
	local contentLength = tonumber(headers:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))

	if (contentLength ~= nil) then
		if (#bodySoFar < contentLength) then return end -- wait for more
		local body = bodySoFar:sub(1, contentLength)
		FinishPendingRequest(statusCode, body)
	else
		-- No content-length given; assume the connection closing (or a
		-- reasonable idle gap) marks the end. Since we always send
		-- "Connection: close", treat whatever we have as final once we
		-- see the double-CRLF and some body, or an explicit 0-length reply.
		FinishPendingRequest(statusCode, bodySoFar)
	end
end

function FinishPendingRequest(statusCode, body)
	local req = g_pendingReq
	g_pendingReq = nil
	g_rxBuffer = ""

	if (req ~= nil and req.callback ~= nil) then
		local ok, err = pcall(req.callback, statusCode, body)
		if (not ok) then
			LOG("Request callback error: " .. tostring(err))
		end
	end

	if (statusCode ~= nil) then
		if (not g_state.connected_seen) then
			g_state.connected_seen = true
		end
		NotifyOnline(true)
	end

	DrainQueue()
end

-- ===================== Polling (/poll) ============================
function StartPolling()
	StopPolling()
	if (g_pollInt <= 0) then return end
	g_pollTimerId = C4:AddTimer(g_pollInt * 1000, "SECONDS", true, "OnPollTimer")
	QueuePoll()
end

function StopPolling()
	if (g_pollTimerId ~= nil) then
		pcall(function() C4:KillTimer(g_pollTimerId) end)
		g_pollTimerId = nil
	end
end

function OnPollTimer(idTimer)
	QueuePoll()
end

function QueuePoll()
	QueueRequest("GET", "/poll", nil, OnPollResponse)
end

-- /poll returns a flat JSON object. Rather than pull in a general JSON
-- parser, this pulls known numeric/string fields out with simple patterns -
-- same philosophy as the field-based parsing in this project's Haiku driver.
function JsonNumberField(sBody, sKey)
	local v = sBody:match('"' .. sKey .. '"%s*:%s*"?(-?%d+%.?%d*)"?')
	if (v == nil) then return nil end
	return tonumber(v)
end

function OnPollResponse(statusCode, body)
	if (statusCode == nil or body == nil) then
		LOG("Poll failed (no response)")
		NotifyOnline(false)
		return
	end
	if (statusCode ~= "200") then
		LOG("Poll returned status " .. tostring(statusCode))
		return
	end

	local power  = JsonNumberField(body, "power")
	local pilot  = JsonNumberField(body, "pilot")
	local height = JsonNumberField(body, "height")

	local changed = false
	if (power ~= nil and power ~= g_state.power) then g_state.power = power; changed = true end
	if (pilot ~= nil and pilot ~= g_state.pilot) then g_state.pilot = pilot; changed = true end
	if (height ~= nil and height ~= g_state.height) then g_state.height = height; changed = true end

	if (changed) then
		NotifyFlameLevel()
	end
end

-- ===================== Control (/get_challenge + /post) ============================
-- See header notes: the signing scheme below is a best-effort reconstruction
-- from public reverse-engineering writeups, not vendor-confirmed.

function SendFireplaceCommand(sCmd, nVal)
	if (g_apiKey == nil or g_apiKey == "" or g_userId == nil or g_userId == "") then
		LOG("Cannot send command '" .. sCmd .. "': API User ID / API Key not configured")
		return
	end
	QueueRequest("GET", "/get_challenge", nil, function(statusCode, body)
		if (statusCode ~= "200" or body == nil or body == "") then
			LOG("get_challenge failed, status=" .. tostring(statusCode))
			return
		end
		local challengeHex = body:gsub("%s+", "")
		local payload = "command=" .. sCmd .. "&value=" .. tostring(nVal)
		local responseHex = ComputeCommandSigning(challengeHex, g_apiKey, payload)
		if (responseHex == nil) then
			LOG("Failed to compute command signing (bad hex in challenge/api key?)")
			return
		end
		local postBody = payload .. "&user=" .. g_userId .. "&response=" .. responseHex
		QueueRequest("POST", "/post", postBody, function(sc, b)
			LOG("POST /post [" .. sCmd .. "=" .. tostring(nVal) .. "] -> status=" .. tostring(sc))
			QueuePoll() -- refresh state shortly after a write
		end)
	end)
end

function ComputeCommandSigning(challengeHex, apiKeyHex, payload)
	local challengeBytes = HexToRawBytes(challengeHex)
	local apiKeyBytes = HexToRawBytes(apiKeyHex)
	if (challengeBytes == nil or apiKeyBytes == nil) then return nil end
	return Sha256Hex(challengeBytes .. apiKeyBytes .. payload)
end

function HexToRawBytes(hex)
	if (hex == nil) then return nil end
	local out = {}
	local i = 1
	while (i + 1 <= #hex) do
		local byteVal = tonumber(hex:sub(i, i + 1), 16)
		if (byteVal == nil) then return nil end
		out[#out + 1] = string.char(byteVal)
		i = i + 2
	end
	return table.concat(out)
end

-- ===================== Proxy notifications (device -> Navigator) ============================
-- Confirmed against Control4's official light_sample.c4i:
--   C4:SendToProxy(idBinding, "LIGHT_LEVEL", <scalar value>, "NOTIFY")
-- Flame height (0-4) is mapped to a light_v2 percentage level (0-100).

function HeightToPercent(nHeight)
	local pct = math.floor((nHeight / 4) * 100 + 0.5)
	if (pct < 0) then pct = 0 end
	if (pct > 100) then pct = 100 end
	return pct
end

function PercentToHeight(nPercent)
	if (nPercent == nil) then return 0 end
	local h = math.floor((nPercent / 100) * 4 + 0.5)
	if (h < 0) then h = 0 end
	if (h > 4) then h = 4 end
	return h
end

function NotifyFlameLevel()
	local lvl = 0
	if (g_state.power == 1) then
		lvl = HeightToPercent(g_state.height)
	end
	C4:SendToProxy(FIREPLACE_BINDING, "LIGHT_LEVEL", lvl, "NOTIFY")
end

-- ===================== Proxy commands (Navigator -> device) ============================
function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	LOG("ReceivedFromProxy [" .. tostring(idBinding) .. "] " .. tostring(strCommand))

	if (strCommand == "GET_CONNECTED_STATE") then
		NotifyOnline(g_netOnline)
		return
	end

	if (idBinding == FIREPLACE_BINDING) then
		FireplaceProxyCommand(strCommand, tParams)
	end
end

-- ON = light-switch style "turn the fireplace on": ensure pilot is lit, then
-- start the main flame. If the pilot isn't already on, real units need a
-- brief purge/ignition delay before they'll accept the main-flame command;
-- this uses a short timer for that case (see header notes - not vendor
-- confirmed timing, adjust PILOT_TO_FLAME_DELAY_MS if your unit needs longer).
PILOT_TO_FLAME_DELAY_MS = 5000

function FireplaceProxyCommand(cmd, p)
	if (cmd == "ON") then
		TurnFlameOn()
	elseif (cmd == "OFF") then
		SendFireplaceCommand("power", 0)
		SendFireplaceCommand("pilot", 0)
	elseif (cmd == "TOGGLE") then
		if (g_state.power == 1) then
			SendFireplaceCommand("power", 0)
			SendFireplaceCommand("pilot", 0)
		else
			TurnFlameOn()
		end
	elseif (cmd == "SET_LEVEL" or cmd == "RAMP_TO_LEVEL") then
		local pct = tonumber(p.LEVEL) or 0
		local height = PercentToHeight(pct)
		if (pct <= 0) then
			SendFireplaceCommand("power", 0)
			SendFireplaceCommand("pilot", 0)
		else
			SendFireplaceCommand("height", height)
			TurnFlameOn()
		end
	else
		LOG("Unhandled fireplace proxy command: " .. tostring(cmd))
	end
end

function TurnFlameOn()
	if (g_state.pilot == 1) then
		SendFireplaceCommand("power", 1)
	else
		SendFireplaceCommand("pilot", 1)
		C4:AddTimer(PILOT_TO_FLAME_DELAY_MS, "MILLISECONDS", false, "OnIgnitionDelayComplete")
	end
end

function OnIgnitionDelayComplete(idTimer)
	SendFireplaceCommand("power", 1)
end

-- ===================== Driver commands / Composer actions ============================
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	LOG("ExecuteCommand: " .. tostring(strCommand))

	if (strCommand == "Set Pilot" or strCommand == "ACTION_PILOT_ON" or strCommand == "ACTION_PILOT_OFF") then
		local state = tParams["State"]
		if (strCommand == "ACTION_PILOT_ON") then state = "ON" end
		if (strCommand == "ACTION_PILOT_OFF") then state = "OFF" end
		if (state == "ON") then
			SendFireplaceCommand("pilot", 1)
		else
			-- turning pilot off also implies the main flame can't stay lit
			SendFireplaceCommand("power", 0)
			SendFireplaceCommand("pilot", 0)
		end

	elseif (strCommand == "ACTION_REFRESH_STATUS") then
		QueuePoll()

	elseif (strCommand == "ACTION_PRINT_DEBUG") then
		print("=== IntelliFire Driver Debug ===")
		print("IP: " .. g_ip)
		print("Bound: " .. tostring(g_netBound) .. "  Online: " .. tostring(g_netOnline))
		print("power=" .. tostring(g_state.power) .. " pilot=" .. tostring(g_state.pilot) .. " height=" .. tostring(g_state.height))
	end
end

--[[==============================================================================
	Pure-Lua SHA-256 (portable: arithmetic-only bit ops, no bitwise operators
	or bit library required). Verified against the FIPS 180-4 / Python
	hashlib test vectors ("", "abc", the standard pangram, and a >64-byte
	multi-block input) during development of this driver.
================================================================================]]
local SHA256_MOD = 4294967296 -- 2^32

local function sha256_band(a, b)
	local r, p = 0, 1
	a = a % SHA256_MOD; b = b % SHA256_MOD
	while a > 0 and b > 0 do
		local ab, bb = a % 2, b % 2
		if ab == 1 and bb == 1 then r = r + p end
		a = (a - ab) / 2
		b = (b - bb) / 2
		p = p * 2
	end
	return r
end

local function sha256_bxor(a, b)
	local r, p = 0, 1
	a = a % SHA256_MOD; b = b % SHA256_MOD
	while a > 0 or b > 0 do
		local ab, bb = a % 2, b % 2
		if ab ~= bb then r = r + p end
		a = (a - ab) / 2
		b = (b - bb) / 2
		p = p * 2
	end
	return r
end

local function sha256_bxor3(a, b, c)
	return sha256_bxor(sha256_bxor(a, b), c)
end

local function sha256_bnot(a)
	return (SHA256_MOD - 1) - (a % SHA256_MOD)
end

local function sha256_rrotate(x, n)
	x = x % SHA256_MOD
	local right = math.floor(x / (2 ^ n))
	local left = (x % (2 ^ n)) * (2 ^ (32 - n))
	return (left + right) % SHA256_MOD
end

local function sha256_rshift(x, n)
	return math.floor((x % SHA256_MOD) / (2 ^ n))
end

local function sha256_addmod(...)
	local s = 0
	for _, v in ipairs({ ... }) do s = s + v end
	return s % SHA256_MOD
end

local SHA256_K = {
	0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
	0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
	0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
	0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
	0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
	0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
	0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
	0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

function Sha256Hex(msg)
	local h0,h1,h2,h3,h4,h5,h6,h7 =
		0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
		0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19

	local bitLen = #msg * 8

	msg = msg .. string.char(0x80)
	while (#msg % 64) ~= 56 do
		msg = msg .. string.char(0)
	end

	for i = 7, 0, -1 do
		local shift = i * 8
		local byteVal
		if shift >= 32 then
			byteVal = 0 -- message lengths used by this driver never approach 2^32 bits
		else
			byteVal = math.floor(bitLen / (2 ^ shift)) % 256
		end
		msg = msg .. string.char(byteVal)
	end

	for chunkStart = 1, #msg, 64 do
		local w = {}
		for i = 0, 15 do
			local o = chunkStart + i * 4
			local b1, b2, b3, b4 = string.byte(msg, o, o + 3)
			w[i] = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
		end
		for i = 16, 63 do
			local s0 = sha256_bxor3(sha256_rrotate(w[i-15], 7), sha256_rrotate(w[i-15], 18), sha256_rshift(w[i-15], 3))
			local s1 = sha256_bxor3(sha256_rrotate(w[i-2], 17), sha256_rrotate(w[i-2], 19), sha256_rshift(w[i-2], 10))
			w[i] = sha256_addmod(w[i-16], s0, w[i-7], s1)
		end

		local a,b,c,d,e,f,g,h = h0,h1,h2,h3,h4,h5,h6,h7

		for i = 0, 63 do
			local S1 = sha256_bxor3(sha256_rrotate(e,6), sha256_rrotate(e,11), sha256_rrotate(e,25))
			local ch = sha256_bxor(sha256_band(e,f), sha256_band(sha256_bnot(e), g))
			local temp1 = sha256_addmod(h, S1, ch, SHA256_K[i+1], w[i])
			local S0 = sha256_bxor3(sha256_rrotate(a,2), sha256_rrotate(a,13), sha256_rrotate(a,22))
			local maj = sha256_bxor3(sha256_band(a,b), sha256_band(a,c), sha256_band(b,c))
			local temp2 = sha256_addmod(S0, maj)

			h = g
			g = f
			f = e
			e = sha256_addmod(d, temp1)
			d = c
			c = b
			b = a
			a = sha256_addmod(temp1, temp2)
		end

		h0 = sha256_addmod(h0, a); h1 = sha256_addmod(h1, b); h2 = sha256_addmod(h2, c); h3 = sha256_addmod(h3, d)
		h4 = sha256_addmod(h4, e); h5 = sha256_addmod(h5, f); h6 = sha256_addmod(h6, g); h7 = sha256_addmod(h7, h)
	end

	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0,h1,h2,h3,h4,h5,h6,h7)
end
