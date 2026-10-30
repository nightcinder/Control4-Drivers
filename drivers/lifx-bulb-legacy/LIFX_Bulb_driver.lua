--[[==============================================================================
	LIFX (LAN Protocol) - Control4 Driver
	Unofficial / community driver. Not affiliated with or supported by
	LIFX or Control4. Local-network control only - no LIFX Cloud dependency.

	Architecture reference: LIFX_Driver_Architecture.md (2026-08-16), written
	against:
	  - LIFX LAN Protocol vendor docs (lan.developer.lifx.com) - binary frame
	    layout, message types, HSBK encoding. CONFIRMED, golden-vector tested
	    (see BuildFrame comment below).
	  - Control4's own official sample: driver_development_training/
	    sample_light_driver (github.com/snap-one/docs-driverworks) - confirms
	    the EC/OPC/RFP dispatch pattern, SET_BRIGHTNESS_TARGET / LIGHT_
	    BRIGHTNESS_CHANGING / LIGHT_BRIGHTNESS_CHANGED contract, SYNCHRONIZE,
	    ONLINE_CHANGED{STATE=<bool>}, and C4:SetTimer(ms, functionRef) for
	    one-shot closures.
	  - The Haiku SenseME driver in this project (verified/field-tested) -
	    confirms C4:CreateNetworkConnection / C4:NetConnect / C4:SendToNetwork
	    rebind pattern, OnConnectionStatusChanged / OnNetworkBindingChanged
	    signatures, and C4:AddTimer(ms, units, repeat, "FunctionName") for
	    repeating named timers.

	KNOWN UNVERIFIED ITEMS (see architecture doc Section 0 for full detail -
	grep this file for "U1" / "U2" to find every call site gated on these):

	  U1 - The exact parameter names for the live (non-preset) SET_COLOR_TARGET
	       command and LIGHT_COLOR_CHANGED/CHANGING notifies are NOT confirmed.
	       The published Proxy/Protocol guide only documents the *preset*
	       variant. The color layer below is a best-effort scaffold, wrapped
	       in pcall, that logs every raw SET_COLOR_TARGET call so the real
	       contract can be captured from a live Navigator color-wheel drag.
	       Brightness/on-off control does NOT depend on U1 and works today.

	  U2 - Whether ReceivedFromNetwork(idBinding, nPort, data) exposes the
	       UDP sender's source IP is NOT confirmed. If it doesn't (as assumed
	       here, matching the Haiku driver's confirmed 3-arg signature),
	       broadcast discovery can learn a bulb's SERIAL but not its IP, and
	       the installer must run "Re-resolve IP" (a timer-driven unicast
	       sweep) or enter the IP manually. See RequestDiscoveryBroadcast /
	       HandleStateService / StartUnicastSweep.

	Verify both in Composer/DriverEditor before relying on color or
	fully-automatic discovery in production; see the accompanying Cowork
	test plan.
================================================================================]]

DRIVER_VERSION = "1.0.6"

-- ===================== Bindings / constants ============================
LIGHT_BINDING = 5001
NET_BINDING   = 6001
UDP_PORT      = 56700

-- ===================== LIFX message types (CONFIRMED - C2) =============
MSG_GET_SERVICE         = 2
MSG_STATE_SERVICE       = 3
MSG_GET_HOST_FIRMWARE   = 14
MSG_STATE_HOST_FIRMWARE = 15
MSG_GET_POWER           = 20
MSG_SET_POWER           = 21
MSG_STATE_POWER         = 22
MSG_GET_LABEL           = 23
MSG_STATE_LABEL         = 25
MSG_GET_VERSION         = 32
MSG_STATE_VERSION       = 33
MSG_ACKNOWLEDGEMENT     = 45
MSG_GET_COLOR           = 101
MSG_SET_COLOR           = 102
MSG_LIGHT_STATE         = 107
MSG_GET_LIGHT_POWER     = 116
MSG_SET_LIGHT_POWER     = 117
MSG_STATE_LIGHT_POWER   = 118

-- ===================== Dispatch tables (Snap One EC/OPC/RFP pattern) ====
EC  = {}   -- ExecuteCommand handlers (Composer actions / driver commands)
OPC = {}   -- OnPropertyChanged handlers
RFP = {}   -- ReceivedFromProxy handlers

-- ===================== Config (loaded from Properties) ==================
g_addressMode = "Auto (discover)"
g_ip          = "0.0.0.0"
g_serial      = ""     -- 6-byte binary target
g_serialHex   = ""     -- "d073d5001337" display form
g_bulbType    = "Color (RGBW)"
g_minKelvin   = 1500
g_maxKelvin   = 9000
g_defaultRate = 500
g_pollInt     = 20
g_logMode     = "Off"

-- ===================== Runtime state =====================================
g_source = 2
g_seq    = 0
g_pending = {}          -- [seq] = { msgType=, frame=, sentAt=, retries= }
g_failureCount = 0

g_state = {
	power = 0, hue = 0, sat = 0, bri = 0, kelvin = 3500,
	label = "", vendor = nil, product = nil, firmwareVersion = nil,
}

g_rxBuffer   = ""
g_boundIP    = nil
g_netBound   = false
g_netOnline  = false
g_bulbOnline = false
g_missedPolls = 0

-- BUG FOUND VIA LIVE TESTING (2026-08-17, real EA-1, ~46 min wall-clock +
-- isolation tests): C4:AddTimer's REPEATING mode never fires a callback on
-- this Director, regardless of unit ("SECONDS" or "MILLISECONDS") or
-- interval. AddTimer itself returns a real, valid, non-nil timer ID (the
-- registration call succeeds), but the named-function callback is never
-- invoked - confirmed by watching g_seq (incremented once per outbound
-- frame) stay completely flat across 46 real minutes with a 20s poll
-- interval (expected ~130 increments from polling alone; got 0), and by a
-- direct isolated repro: a throwaway AddTimer(2000, "MILLISECONDS", true,
-- ...) counter stayed at 0 after 20+ real seconds. C4:SetTimer (one-shot,
-- closure/function-ref based) was tested the same way and DOES fire
-- correctly and asynchronously after real elapsed time. Mitigation: every
-- timer below that used to be AddTimer-based now self-reschedules with a
-- plain C4:SetTimer call at the end of its own callback, gated on an
-- "active" boolean flag instead of an AddTimer-returned ID. This is a
-- confirmed-working pattern, not a guess - see architecture doc Section 10
-- for the full isolation writeup.
g_pollTimerId      = nil   -- kept for Print Debug Info / diagnostics only
g_pollingActive    = false
g_retryTimerId     = nil   -- kept for Print Debug Info / diagnostics only
g_retrySweepActive = false
g_reconnectTimerId = nil   -- kept for Print Debug Info / diagnostics only
g_reconnectBackoff = 30

g_discoverySweepActive = false
g_sweepTimerId = nil       -- kept for Print Debug Info / diagnostics only
g_sweepBase    = nil
g_sweepOctet   = 0

g_colorLayerEnabled = true   -- auto-disabled on first hard failure, see color layer section

g_lastNotifiedBrightnessPct = nil
g_lastNotifiedColorMode = nil
g_lastNotifiedX = nil
g_lastNotifiedY = nil

-- ===================== Logging helper ============================
function LOG(msg)
	if (g_logMode == "Print" or g_logMode == "Print and Log") then
		print("[LIFX] " .. tostring(msg))
	end
	if (g_logMode == "Log" or g_logMode == "Print and Log") then
		pcall(function() C4:DebugLog("[LIFX] " .. tostring(msg)) end)
	end
end

-- ===================== Byte packing helpers (CONFIRMED - addresses U3) ==
-- Hand-rolled little-endian packing/unpacking so this driver does not
-- depend on string.pack/string.unpack (Lua 5.3+ only, and the Director's
-- exact Lua version is unconfirmed - see architecture doc U3). Lua strings
-- are 8-bit clean so these binary blobs pass through SendToNetwork /
-- ReceivedFromNetwork unmodified.

function u8(n)
	return string.char((n or 0) % 256)
end

function u16le(n)
	n = math.floor((n or 0)) % 0x10000
	return string.char(n % 256, math.floor(n / 256) % 256)
end

function u32le(n)
	-- NOTE: deliberately does not use "% 0x100000000" anywhere - a fengari
	-- smoke test caught that this literal does not behave as a same-valued
	-- modulus on every Lua runtime tested, which is exactly the kind of
	-- cross-version risk flagged in the architecture doc (U3). Extracting
	-- each byte via floor()/%256 individually sidesteps the giant literal
	-- entirely and only ever depends on %256, which is safe everywhere.
	n = math.floor(n or 0)
	if (n < 0) then n = 0 end
	return string.char(
		n % 256,
		math.floor(n / 256) % 256,
		math.floor(n / 65536) % 256,
		math.floor(n / 16777216) % 256
	)
end

function zeros(n)
	return string.rep("\0", n)
end

function rdU8(s, i)
	return (string.byte(s, i) or 0), i + 1
end

function rdU16(s, i)
	local b0, b1 = string.byte(s, i), string.byte(s, i + 1)
	return (b0 or 0) + ((b1 or 0) * 256), i + 2
end

function rdU32(s, i)
	local b0, b1, b2, b3 = string.byte(s, i), string.byte(s, i + 1), string.byte(s, i + 2), string.byte(s, i + 3)
	return (b0 or 0) + ((b1 or 0) * 256) + ((b2 or 0) * 65536) + ((b3 or 0) * 16777216), i + 4
end

function rdBytes(s, i, n)
	return string.sub(s, i, i + n - 1), i + n
end

-- ===================== Hex <-> bytes (bulb serial / MAC) ================
function HexToBytes(sHex)
	if (sHex == nil) then return nil end
	sHex = sHex:gsub("[^0-9a-fA-F]", "")
	if (#sHex < 12) then return nil end
	local out = {}
	for i = 1, 12, 2 do
		table.insert(out, string.char(tonumber(sHex:sub(i, i + 1), 16)))
	end
	return table.concat(out)
end

function BytesToHex(sBytes)
	if (sBytes == nil) then return "" end
	local out = {}
	for i = 1, #sBytes do
		table.insert(out, string.format("%02x", string.byte(sBytes, i)))
	end
	return table.concat(out)
end

function SetSerialFromHex(sHex)
	-- BUG FOUND VIA LIVE TESTING (2026-08-17): HexToBytes() returns nil for
	-- any string shorter than 12 hex chars, including "" and nil. This used
	-- to leave g_serial/g_serialHex completely untouched whenever the "Bulb
	-- Serial (MAC)" property was cleared (e.g. by an installer pointing
	-- Manual mode at a different physical bulb and clearing the stale
	-- serial to force re-learning). Confirmed live: clearing the property
	-- in Composer produced the generic "Property changed" log line but
	-- g_serial/g_serialHex remained the OLD value - every subsequent
	-- unicast command (GetColor/GetVersion/SetColor/...) kept addressing
	-- the LIFX `target` field to the wrong bulb's MAC, which real LIFX
	-- firmware silently ignores (does not reply to a targeted unicast
	-- frame whose target doesn't match its own MAC). This produced total,
	-- silent unicast command failure against a real bulb at a valid IP,
	-- with no error and no "ignoring reply" log line (the source-check in
	-- HandleFrame returns before any logging happens on a genuine timeout/
	-- no-reply-at-all case) - very hard to diagnose without raw protocol
	-- tracing via the Lua console. Fixed: an empty/invalid sHex now
	-- explicitly clears the serial so BuildFrame's `target` reverts to
	-- nil, which real LIFX devices DO respond to regardless of MAC.
	local b = HexToBytes(sHex)
	if (b ~= nil) then
		g_serial = b
		g_serialHex = BytesToHex(b)
	else
		g_serial = ""
		g_serialHex = ""
	end
end

-- ===================== Misc utilities ============================
function RoundHalfUp(n)
	return math.floor(n + 0.5)
end

function RoundTo(n, decimals)
	local mult = 10 ^ decimals
	return math.floor(n * mult + 0.5) / mult
end

function Clamp(n, lo, hi)
	if (n < lo) then return lo end
	if (n > hi) then return hi end
	return n
end

function TableCount(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

function DumpTable(t)
	if (type(t) ~= "table") then return tostring(t) end
	local parts = {}
	for k, v in pairs(t) do
		table.insert(parts, tostring(k) .. "=" .. tostring(v))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- UNVERIFIED API (not exercised by the Haiku reference driver, only listed
-- in the DriverWorks API index). Wrapped defensively with a fallback.
function SafeGetTime()
	local ok, t = pcall(function() return C4:GetTime() end)
	if (ok and type(t) == "number") then return t end
	return os.time() * 1000
end

function SafeGetDeviceID()
	local ok, id = pcall(function() return C4:GetDeviceID() end)
	if (ok and type(id) == "number") then return id end
	return os.time() % 100000
end

function ComputeSource()
	-- Per LIFX docs (C4): source must never be 0 or 1. Forced into [2, 0xFFFFFFFF].
	-- Avoids the giant hex literal 0xFFFFFFFE for the same cross-version
	-- safety reason documented in u32le() above; math.huge-safe modulus
	-- against a value built from two smaller literals instead.
	local id = SafeGetDeviceID()
	local range = 4294967294  -- 0xFFFFFFFE, written as a decimal literal
	local s = (id % range) + 2
	return math.floor(s)
end

-- ===================== HSBK scaling (CONFIRMED - C3) ============================
-- Pure integer scaling per LIFX docs. This is NOT colorimetry (no XY/RGB
-- math happens here) - see the Color Layer section for that boundary, which
-- is explicitly delegated to the light_v2 proxy's own conversion commands
-- rather than hand-rolled, per the architecture doc's guardrail.

function DegToU16Hue(deg)
	local u = RoundHalfUp(0x10000 * (deg or 0) / 360) % 0x10000
	if (u < 0) then u = u + 0x10000 end
	return u
end

function U16HueToDeg(u16)
	return RoundTo(((u16 or 0) * 360) / 0x10000, 2)
end

function FracToU16(f)
	f = Clamp(f or 0, 0, 1)
	return RoundHalfUp(0xFFFF * f)
end

function U16ToFrac(u16)
	return RoundTo((u16 or 0) / 0xFFFF, 4)
end

-- ===================== LIFX frame builder / parser (CONFIRMED - C1) =====
-- BuildFrame(msgType, payload, opts)
--   opts.tagged        boolean, default false (true = addressed to all devices)
--   opts.target        6-byte binary serial, or nil for broadcast/all-zero
--   opts.ack_required  boolean, default false
--   opts.res_required  boolean, default false
--   opts.sequence      uint8, caller-supplied so it can be tracked
--   opts.source        uint32, defaults to g_source
-- returns the wire-format string.
--
-- Golden vector (CONFIRMED - LIFX "Encoding a LIFX packet" worked example):
-- BuildFrame(MSG_SET_COLOR, <reserved(1)+HSBK(21845,65535,65535,3500)+dur(0)>,
--   { target = HexToBytes("d073d5001337"), ack_required = true, sequence = 1, source = 2 })
-- must equal (hex):
--   3100001402000000d073d500133700000000000000000201
--   0000000000000000660000000055 55ffffffffac0d00000000
-- (whitespace above is just for readability; see the fengari smoke test.)

function BuildFrame(msgType, payload, opts)
	opts = opts or {}
	payload = payload or ""
	local size = 36 + #payload
	local tagged = opts.tagged and true or false
	local target = opts.target
	local ack = opts.ack_required and true or false
	local res = opts.res_required and true or false
	local seq = opts.sequence or 0
	local source = opts.source or g_source

	-- protocol(1024, 12 bits) | addressable(1 bit, always 1) | tagged(1 bit) | origin(2 bits, always 0)
	local protoWord = 0x0400 + 0x1000 + (tagged and 0x2000 or 0)

	local targetField = target
	if (targetField == nil) then
		targetField = zeros(6)
	elseif (#targetField < 6) then
		targetField = targetField .. zeros(6 - #targetField)
	elseif (#targetField > 6) then
		targetField = string.sub(targetField, 1, 6)
	end

	local frame =
		u16le(size) ..
		u16le(protoWord) ..
		u32le(source) ..
		targetField .. zeros(2) ..                              -- target (8 bytes total)
		zeros(6) ..                                              -- frame address reserved
		u8((res and 1 or 0) + (ack and 2 or 0)) ..
		u8(seq) ..
		zeros(8) ..                                              -- protocol header reserved
		u16le(msgType) ..
		zeros(2)                                                  -- protocol header trailing reserved

	return frame .. payload
end

-- ParseHeader(data) -> header table, or nil if data is too short to contain
-- a full 36-byte header. header.payloadStart is a 1-based index into `data`.
function ParseHeader(data)
	if (#data < 36) then return nil end
	local pos = 1
	local size, protoWord, source, target, flags, sequence, msgType

	size, pos      = rdU16(data, pos)
	protoWord, pos = rdU16(data, pos)
	source, pos    = rdU32(data, pos)
	target, pos    = rdBytes(data, pos, 8)
	pos = pos + 6                                -- frame address reserved
	flags, pos     = rdU8(data, pos)
	sequence, pos  = rdU8(data, pos)
	pos = pos + 8                                -- protocol header reserved
	msgType, pos   = rdU16(data, pos)
	pos = pos + 2                                -- protocol header trailing reserved

	return {
		size = size,
		tagged = (math.floor(protoWord / 0x2000) % 2) == 1,
		source = source,
		target = string.sub(target, 1, 6),
		res_required = (flags % 2) == 1,
		ack_required = (math.floor(flags / 2) % 2) == 1,
		sequence = sequence,
		msgType = msgType,
		payloadStart = pos,
	}
end

-- ===================== Sequence / pending-ack tracking (CONFIRMED - C4) =
function NextSequence()
	g_seq = (g_seq % 255) + 1
	return g_seq
end

function TrackPending(seq, msgType, frame)
	g_pending[seq] = { msgType = msgType, frame = frame, sentAt = SafeGetTime(), retries = 0 }
end

function ClearPending(seq)
	g_pending[seq] = nil
end

-- ===================== Transport layer (CONFIRMED - C12, lifted from the
-- field-validated Haiku SenseME driver almost verbatim) ===================
-- C4:SendToNetwork has no per-call destination address, so the driver keeps
-- track of which IP the binding is currently pointed at (g_boundIP) and
-- re-binds whenever the destination changes. Two destinations are ever
-- used: the bulb's unicast IP and the subnet broadcast address.

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
	-- BUG FOUND VIA LIVE TESTING (2026-08-17): this used to be the only
	-- writer of the "Connection Status" property, driven purely off the UDP
	-- socket BINDING state. UDP is connectionless, so once bound this stays
	-- "ONLINE" essentially forever - it does NOT mean the bulb itself is
	-- reachable. Confirmed live: pointed a real bulb's "Bulb IP Address" at
	-- an unused address on the same subnet and waited 2.5 minutes (well
	-- past 3 missed polls); "Connection Status" stayed stuck on "ONLINE"
	-- the whole time because the socket bind itself never failed, even
	-- though the bulb was completely unreachable. This meant installers had
	-- NO way to see a truly offline bulb from the property alone - the only
	-- signal was the internal g_bulbOnline flag driving the proxy's
	-- ONLINE_CHANGED event (Navigator-side), which isn't visible here.
	-- Fixed: SetBulbOnline() is now the sole writer of "Connection Status",
	-- reflecting actual bulb reachability (poll success/failure), not raw
	-- transport state. If the transport itself drops, treat that as an
	-- immediate bulb-offline condition too, since nothing can reach the
	-- bulb without it.
	if (not g_netOnline) then
		SetBulbOnline(false)
	end
end

function SendUDP(sIP, sData)
	BindTo(sIP)
	LOG("TX -> " .. tostring(sIP) .. ":" .. UDP_PORT .. " (" .. #sData .. " bytes)")
	local ok, err = pcall(function()
		C4:SendToNetwork(NET_BINDING, UDP_PORT, sData)
	end)
	if (not ok) then
		LOG("SendUDP failed: " .. tostring(err))
	end
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

-- ===================== Discovery (CONFIRMED core + UNVERIFIED U2) =======
function SendGetService(bBroadcast, sOverrideIP)
	local seq = NextSequence()
	local frame = BuildFrame(MSG_GET_SERVICE, "", {
		tagged = bBroadcast and true or false,
		target = nil,
		ack_required = false,
		res_required = false,
		sequence = seq,
	})
	local dest = sOverrideIP
	if (dest == nil) then
		dest = bBroadcast and BroadcastAddressFor(g_ip) or g_ip
	end
	SendUDP(dest, frame)
end

function RequestDiscoveryBroadcast()
	LOG("Broadcasting LIFX discovery (GetService)")
	SendGetService(true, nil)
end

-- Fallback B (architecture Section 2.4): timer-driven unicast sweep, one
-- address per 40ms tick, ~10s per /24. Never runs automatically - only via
-- the "Re-resolve IP" action - because it is comparatively noisy.
function SweepBaseFor(sIP)
	-- BUG FOUND VIA LIVE TESTING (2026-08-16): "0.0.0.0" (the property
	-- default / not-yet-discovered sentinel) matches the digits-only regex
	-- below just fine, so this used to happily return "0.0.0" and the
	-- installer-facing "Re-resolve IP" action would sweep 0.0.0.1-254
	-- instead of refusing to start. BroadcastAddressFor() already guarded
	-- against this; this function did not. Confirmed live: "Starting
	-- unicast discovery sweep on 0.0.0.0/24" appeared in the driver log
	-- the first time Re-resolve IP ran with no IP configured yet.
	if (sIP == nil or sIP == "" or sIP == "0.0.0.0") then
		return nil
	end
	local a, b, c = sIP:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
	if (a == nil) then return nil end
	return a .. "." .. b .. "." .. c
end

function StartUnicastSweep()
	local base = SweepBaseFor(g_ip)
	if (base == nil) then
		LOG("Cannot start unicast sweep: no usable subnet base (set Bulb IP Address to any host on the target subnet first, e.g. the controller's own IP)")
		return
	end
	StopUnicastSweep()
	g_sweepBase = base
	g_sweepOctet = 1
	g_discoverySweepActive = true
	LOG("Starting unicast discovery sweep on " .. base .. ".0/24")
	-- AddTimer's repeating mode does not fire on this Director (see the
	-- comment on the globals block above) - self-reschedule via SetTimer
	-- instead. OnSweepTimer() re-arms itself at the end of each tick.
	C4:SetTimer(40, OnSweepTimer)
end

function StopUnicastSweep()
	g_discoverySweepActive = false
	if (g_sweepTimerId ~= nil) then
		pcall(function() C4:KillTimer(g_sweepTimerId) end)
		g_sweepTimerId = nil
	end
end

function OnSweepTimer(idTimer)
	if (not g_discoverySweepActive) then
		StopUnicastSweep()
		return
	end
	if (g_sweepOctet > 254) then
		LOG("Unicast discovery sweep complete")
		StopUnicastSweep()
		if (g_ip ~= nil and g_ip ~= "0.0.0.0") then BindTo(g_ip) end
		return
	end
	local target = g_sweepBase .. "." .. g_sweepOctet
	g_sweepOctet = g_sweepOctet + 1
	SendGetService(false, target)
	if (g_discoverySweepActive) then
		C4:SetTimer(40, OnSweepTimer)
	end
end

function HandleSweepDiscoveryReply(serialHex)
	local candidateIP = g_boundIP
	LOG("Sweep found LIFX device serial=" .. serialHex .. " at " .. tostring(candidateIP))
	if (g_serial == "" or serialHex == g_serialHex) then
		g_serial = HexToBytes(serialHex) or g_serial
		g_serialHex = serialHex
		g_ip = candidateIP
		pcall(function() C4:UpdateProperty("Bulb IP Address", g_ip) end)
		pcall(function() C4:UpdateProperty("Bulb Serial (MAC)", g_serialHex) end)
		StopUnicastSweep()
		SetBulbOnline(true)
	end
end

-- ===================== Outbound message senders (CONFIRMED - C2, C5) ====
function SendToBulb(msgType, payload, bAckRequired)
	if (g_ip == nil or g_ip == "" or g_ip == "0.0.0.0") then
		LOG("Cannot send (no IP configured): type=" .. tostring(msgType))
		return
	end
	local seq = NextSequence()
	local frame = BuildFrame(msgType, payload or "", {
		tagged = false,
		target = (g_serial ~= "" and g_serial or nil),
		ack_required = bAckRequired and true or false,
		res_required = false,
		sequence = seq,
	})
	if (bAckRequired) then
		TrackPending(seq, msgType, frame)
	end
	SendUDP(g_ip, frame)
	return seq
end

function SendGetColor()
	SendToBulb(MSG_GET_COLOR, "", false)
end

function SendSetColor(hue, sat, bri, kelvin, durationMs)
	local payload = zeros(1) .. u16le(hue) .. u16le(sat) .. u16le(bri) .. u16le(kelvin) .. u32le(durationMs or 0)
	SendToBulb(MSG_SET_COLOR, payload, true)
end

function SendSetLightPower(level, durationMs)
	local payload = u16le(level) .. u32le(durationMs or 0)
	SendToBulb(MSG_SET_LIGHT_POWER, payload, true)
end

function SendGetVersion()
	SendToBulb(MSG_GET_VERSION, "", false)
end

function SendGetHostFirmware()
	SendToBulb(MSG_GET_HOST_FIRMWARE, "", false)
end

function SendGetLabel()
	SendToBulb(MSG_GET_LABEL, "", false)
end

-- ===================== Retransmit sweep (CONFIRMED pattern - C5, Section 3.4)
function OnRetryTimer(idTimer)
	local now = SafeGetTime()
	for seq, entry in pairs(g_pending) do
		if ((now - entry.sentAt) >= 500) then
			if (entry.retries >= 2) then
				LOG("Giving up on seq=" .. tostring(seq) .. " type=" .. tostring(entry.msgType) .. " (no ack after 2 retries)")
				g_pending[seq] = nil
				g_failureCount = g_failureCount + 1
			else
				entry.retries = entry.retries + 1
				entry.sentAt = now
				LOG("Retransmit seq=" .. tostring(seq) .. " attempt=" .. tostring(entry.retries))
				SendUDP(g_ip, entry.frame)
			end
		end
	end
	-- Self-reschedule (AddTimer's repeating mode does not fire on this
	-- Director - see the comment on the globals block above).
	if (g_retrySweepActive) then
		C4:SetTimer(500, OnRetryTimer)
	end
end

-- ===================== Receive / frame parsing (CONFIRMED - Section 3.1) =
-- UDP datagrams may arrive concatenated or fragmented across callbacks, so
-- incoming bytes are buffered and frames are consumed using the `size`
-- field as a length prefix. A corrupt/oversized size flushes the buffer
-- rather than looping forever.
--
-- U2 (UNVERIFIED): this signature (idBinding, nPort, data) matches the
-- Haiku reference driver's confirmed usage. If the Director's actual
-- ReceivedFromNetwork exposes additional arguments (e.g. a source IP),
-- they will simply be ignored by this 3-parameter declaration - Lua does
-- not error on extra call-site arguments. Log a one-time capture during a
-- broadcast reply to check for this (see the Cowork test plan).
function ReceivedFromNetwork(idBinding, nPort, data)
	if (idBinding ~= NET_BINDING) then return end
	g_rxBuffer = g_rxBuffer .. tostring(data or "")

	while (true) do
		if (#g_rxBuffer < 36) then break end
		local hdr = ParseHeader(g_rxBuffer)
		if (hdr == nil) then break end
		if (hdr.size < 36 or hdr.size > 1024) then
			LOG("Corrupt frame (size=" .. tostring(hdr.size) .. "), flushing receive buffer")
			g_rxBuffer = ""
			break
		end
		if (#g_rxBuffer < hdr.size) then break end   -- wait for the rest of the frame

		local payload = string.sub(g_rxBuffer, hdr.payloadStart, hdr.size)
		g_rxBuffer = string.sub(g_rxBuffer, hdr.size + 1)
		HandleFrame(hdr, payload)
	end
end

function HandleFrame(hdr, payload)
	if (hdr.source ~= g_source) then return end
	ClearPending(hdr.sequence)

	if (hdr.msgType == MSG_STATE_SERVICE) then
		HandleStateService(hdr, payload)
		return
	end

	-- Identity guard: the bulb's identity is its serial, not its IP
	-- (architecture Section 1). Any reply claiming to be from a different
	-- serial than the one configured is dropped.
	if (g_serial ~= "" and hdr.target ~= g_serial) then
		LOG("Ignoring reply from unexpected serial " .. BytesToHex(hdr.target))
		return
	end

	SetBulbOnline(true)

	if (hdr.msgType == MSG_LIGHT_STATE) then
		HandleLightState(hdr, payload)
	elseif (hdr.msgType == MSG_STATE_POWER or hdr.msgType == MSG_STATE_LIGHT_POWER) then
		HandleStatePower(hdr, payload)
	elseif (hdr.msgType == MSG_STATE_VERSION) then
		HandleStateVersion(hdr, payload)
	elseif (hdr.msgType == MSG_STATE_HOST_FIRMWARE) then
		HandleStateHostFirmware(hdr, payload)
	elseif (hdr.msgType == MSG_STATE_LABEL) then
		HandleStateLabel(hdr, payload)
	elseif (hdr.msgType == MSG_ACKNOWLEDGEMENT) then
		-- no-op; ClearPending already handled it above
	else
		LOG("Unhandled LIFX message type " .. tostring(hdr.msgType))
	end
end

function HandleStateService(hdr, payload)
	local service, pos = rdU8(payload, 1)
	local port = rdU32(payload, pos)
	local serialHex = BytesToHex(hdr.target)

	LOG("Discovery reply: serial=" .. serialHex .. " service=" .. tostring(service) .. " port=" .. tostring(port))

	if (g_discoverySweepActive) then
		HandleSweepDiscoveryReply(serialHex)
		return
	end

	if (g_serial == "" or hdr.target == g_serial) then
		g_serial = hdr.target
		g_serialHex = serialHex
		pcall(function() C4:UpdateProperty("Bulb Serial (MAC)", g_serialHex) end)
		SetBulbOnline(true)
		-- U2 (UNVERIFIED): if ReceivedFromNetwork's real signature exposes
		-- the UDP sender's IP, capture it here to auto-populate "Bulb IP
		-- Address". As written (3-arg confirmed signature), this handler
		-- cannot learn the IP from a broadcast reply alone - Auto mode
		-- still requires "Re-resolve IP" (unicast sweep) or manual entry
		-- once the serial is known. See architecture Sections 2.3-2.4.
	end
end

function HandleLightState(hdr, payload)
	-- hue(u16) sat(u16) bri(u16) kelvin(u16) reserved(2) power(u16) label(32) reserved(8)
	local pos = 1
	local hue, sat, bri, kelvin, power
	hue, pos    = rdU16(payload, pos)
	sat, pos    = rdU16(payload, pos)
	bri, pos    = rdU16(payload, pos)
	kelvin, pos = rdU16(payload, pos)
	pos = pos + 2
	power, pos  = rdU16(payload, pos)
	local label = rdBytes(payload, pos, 32) or ""
	label = label:gsub("%z.*$", "")

	g_state.hue = hue
	g_state.sat = sat
	g_state.bri = bri
	g_state.kelvin = kelvin
	g_state.power = power
	if (label ~= "") then
		g_state.label = label
		pcall(function() C4:UpdateProperty("Bulb Label", label) end)
	end

	NotifyBrightnessFromState()
	NotifyColorFromState()
end

function HandleStatePower(hdr, payload)
	local level = rdU16(payload, 1)
	g_state.power = level
	NotifyBrightnessFromState()
end

function HandleStateVersion(hdr, payload)
	local vendor, pos = rdU32(payload, 1)
	local product = rdU32(payload, pos)
	g_state.vendor = vendor
	g_state.product = product
	pcall(function() C4:UpdateProperty("Product ID", tostring(product)) end)
	LOG("StateVersion: vendor=" .. tostring(vendor) .. " product=" .. tostring(product) ..
		" (cross-check against the LIFX Product Registry to confirm color/CCT capability)")
end

function HandleStateHostFirmware(hdr, payload)
	local pos = 1 + 8 + 8   -- skip build(u64, 8 bytes) + reserved(8 bytes)
	local minor, major
	minor, pos = rdU16(payload, pos)
	major, pos = rdU16(payload, pos)
	local sVersion = tostring(major) .. "." .. tostring(minor)
	g_state.firmwareVersion = sVersion
	pcall(function() C4:UpdateProperty("Firmware Version", sVersion) end)
end

function HandleStateLabel(hdr, payload)
	local label = rdBytes(payload, 1, 32) or ""
	label = label:gsub("%z.*$", "")
	if (label ~= "") then
		g_state.label = label
		pcall(function() C4:UpdateProperty("Bulb Label", label) end)
	end
end

-- ===================== Online state ============================
function SetBulbOnline(bOnline)
	if (bOnline) then
		g_missedPolls = 0
		g_reconnectBackoff = 30
		StopReconnectTimer()
	end
	if (bOnline == g_bulbOnline) then return end
	g_bulbOnline = bOnline
	NotifyOnline(bOnline)
	-- Sole writer of the "Connection Status" property - see the comment in
	-- OnConnectionStatusChanged for why this moved here instead of being
	-- driven off the raw UDP socket binding state.
	pcall(function() C4:UpdateProperty("Connection Status", bOnline and "ONLINE" or "OFFLINE") end)
	if (not bOnline) then
		ScheduleReconnect()
	end
end

-- CONFIRMED (C6): official sample passes a Lua boolean for STATE, not the
-- string "true"/"false" that the older Haiku driver used - follow the
-- newer official sample here.
function NotifyOnline(bOnline)
	pcall(function()
		C4:SendToProxy(LIGHT_BINDING, "ONLINE_CHANGED", { STATE = bOnline and true or false })
	end)
end

-- ===================== Brightness notify (CONFIRMED - C6) ================
function BrightnessPctFromState()
	if (g_state.power == 0) then return 0 end
	return RoundHalfUp((g_state.bri / 0xFFFF) * 100)
end

function NotifyBrightnessFromState()
	local pct = BrightnessPctFromState()
	if (g_lastNotifiedBrightnessPct ~= nil and math.abs(pct - g_lastNotifiedBrightnessPct) < 1) then
		return
	end
	g_lastNotifiedBrightnessPct = pct
	pcall(function()
		C4:SendToProxy(LIGHT_BINDING, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = pct })
	end)
end

-- ===================== Proxy command handlers (RFP) - CONFIRMED (C6, C7) =
-- Dispatch-table pattern lifted from Snap One's official sample_light_driver
-- rather than the if/else chain the older Haiku driver used.

function RFP.SYNCHRONIZE(idBinding, strCommand, tParams, args)
	NotifyOnline(g_bulbOnline)
	NotifyBrightnessFromState()
	NotifyColorFromState()
	SendGetColor()
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, strCommand, tParams, args)
	local target = tonumber(tParams.LIGHT_BRIGHTNESS_TARGET)
	local rate = tonumber(tParams.RATE) or g_defaultRate
	if (target == nil) then
		-- Legacy pre-3.3.0 shape (C7): LEVEL/TIME instead of
		-- LIGHT_BRIGHTNESS_TARGET/RATE, selected when supports_target=False.
		target = tonumber(tParams.LEVEL)
		rate = tonumber(tParams.TIME) or rate
	end
	if (target == nil) then return end

	local current = BrightnessPctFromState()
	pcall(function()
		C4:SendToProxy(LIGHT_BINDING, "LIGHT_BRIGHTNESS_CHANGING",
			{ LIGHT_BRIGHTNESS_CURRENT = current, LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
	end)

	if (target <= 0) then
		SendSetLightPower(0, rate)
	else
		if (g_state.power == 0) then
			SendSetLightPower(65535, 0)
		end
		local bri = FracToU16(target / 100)
		SendSetColor(g_state.hue, g_state.sat, bri, g_state.kelvin, rate)
	end

	ScheduleVerify(rate)
end

function RFP.ON(idBinding, strCommand, tParams, args)
	SendSetLightPower(65535, g_defaultRate)
	ScheduleVerify(g_defaultRate)
end

function RFP.OFF(idBinding, strCommand, tParams, args)
	SendSetLightPower(0, g_defaultRate)
	ScheduleVerify(g_defaultRate)
end

function RFP.TOGGLE(idBinding, strCommand, tParams, args)
	if (g_state.power == 0) then
		RFP.ON(idBinding, strCommand, tParams, args)
	else
		RFP.OFF(idBinding, strCommand, tParams, args)
	end
end

function RFP.SET_BRIGHTNESS_RATE_DEFAULT(idBinding, strCommand, tParams, args)
	local rate = tonumber(tParams.RATE)
	if (rate ~= nil) then g_defaultRate = rate end
end
RFP.SET_COLOR_RATE_DEFAULT = RFP.SET_BRIGHTNESS_RATE_DEFAULT

-- Deprecated in OS 3.3+ (C7) but accepted defensively rather than left
-- unhandled, since the EA-1's exact OS version relative to this driver is
-- worth confirming rather than assuming.
RFP.GET_LIGHT_LEVEL = RFP.SYNCHRONIZE
RFP.GET_CONNECTED_STATE = RFP.SYNCHRONIZE
RFP.GET_PROPERTIES = RFP.SYNCHRONIZE

-- Legacy pre-3.3 path (C7): SET_LEVEL / RAMP_TO_LEVEL with LEVEL/TIME params,
-- confirmed against the Haiku driver's own light_sample.c4i-verified usage.
function RFP.SET_LEVEL(idBinding, strCommand, tParams, args)
	tParams.LIGHT_BRIGHTNESS_TARGET = tParams.LIGHT_BRIGHTNESS_TARGET or tParams.LEVEL
	tParams.RATE = tParams.RATE or tParams.TIME
	RFP.SET_BRIGHTNESS_TARGET(idBinding, strCommand, tParams, args)
end
RFP.RAMP_TO_LEVEL = RFP.SET_LEVEL

-- ===================== Color layer (U1 - UNVERIFIED) =====================
-- Everything in this section depends on parameter names that are NOT
-- confirmed against a live light_v2 proxy (architecture doc Section 0, U1).
-- The published Proxy/Protocol guide only documents the color-PRESET
-- variant of SET_COLOR_TARGET; the live color-wheel variant's exact
-- parameter keys and the conversion-call shape are now BOTH CONFIRMED,
-- resolved live on 2026-08-17 via a real Navigator color-wheel drag plus
-- Snap One's official Light V2 Conversion Commands reference
-- (https://snap-one.github.io/docs-driverworks-proxyprotocol-lightv2/).
--
-- What was wrong in the original scaffold: this used to call
-- C4:SendUIRequest(LIGHT_BINDING, "ColorXYtoHSV", {X=x, Y=y}, true) and
-- treat the return as an XML-ish table with .ChildNodes. That call never
-- threw an error but always returned nil - confirmed live via a direct
-- console test (C4:SendUIRequest existed, pcall succeeded, result was
-- nil). The reason: SendUIRequest is for driver-to-driver requests, where
-- the RECEIVING driver must implement its own `UIRequest` function to
-- produce a response - it has nothing to do with the Light V2 conversion
-- helpers. Confirmed via the official docs, the real API is a plain C4:
-- method call:
--   C4:ColorHSVtoXY(h, s, v, gamut)  -> returns x, y
--   C4:ColorXYtoHSV(x, y, gamut)     -> returns h, s, v
-- h is degrees (0-360); s/v are fractions (0-1), matching this driver's
-- existing HSBK fraction convention elsewhere (the docs don't give a
-- separate scale param for h/s/v the way some other conversion functions
-- do, and s/v are conventionally the same 0-1 scale in HSV notation - a
-- reasonable inference, not a guess about the call shape itself, which is
-- confirmed). gamut = "srgb" needs no separate primaries/whitepoint per
-- the docs.
--
-- Brightness/on-off control (previous section) never depended on any of
-- this and has worked independently since the beginning.

-- hueDeg (0-360), satFrac (0-1), briFrac (0-1) -> x, y (or nil, nil on failure)
function HSVtoXY(hueDeg, satFrac, briFrac)
	if (not g_colorLayerEnabled) then return nil, nil end
	local ok, x, y = pcall(function() return C4:ColorHSVtoXY(hueDeg, satFrac, briFrac, "srgb") end)
	if (not ok) then
		LOG("ColorHSVtoXY failed (" .. tostring(x) .. ") - disabling color layer for this session")
		g_colorLayerEnabled = false
		return nil, nil
	end
	return x, y
end

function XYtoHSV(x, y)
	if (not g_colorLayerEnabled) then return nil, nil end
	local ok, hue, sat = pcall(function() return C4:ColorXYtoHSV(x, y, "srgb") end)
	if (not ok) then
		LOG("ColorXYtoHSV failed (" .. tostring(hue) .. ") - disabling color layer for this session")
		g_colorLayerEnabled = false
		return nil, nil
	end
	return hue, sat
end

function EmitColorChanged(tColor)
	-- Epsilon suppression per architecture Section 5.2 (color_trace_tolerance).
	local mode = tColor.LIGHT_COLOR_CURRENT_MODE
	local x = tColor.LIGHT_COLOR_CURRENT_X
	local y = tColor.LIGHT_COLOR_CURRENT_Y
	if (mode == g_lastNotifiedColorMode and
	    (x == nil or (g_lastNotifiedX ~= nil and math.abs(x - g_lastNotifiedX) < 0.001)) and
	    (y == nil or (g_lastNotifiedY ~= nil and math.abs(y - g_lastNotifiedY) < 0.001))) then
		return
	end
	g_lastNotifiedColorMode = mode
	g_lastNotifiedX = x
	g_lastNotifiedY = y
	pcall(function() C4:SendToProxy(LIGHT_BINDING, "LIGHT_COLOR_CHANGED", tColor) end)
end

function NotifyColorFromState()
	if (not g_colorLayerEnabled) then return end
	if (g_bulbType == "Dimmable Only") then return end

	if (g_state.sat == 0 or g_bulbType == "Tunable White") then
		-- CCT mode - report kelvin directly, no XY conversion needed.
		EmitColorChanged({
			LIGHT_COLOR_CURRENT_MODE = 1,   -- 1 = CCT, per C10
			LIGHT_COLOR_CURRENT_CORRELATED_TEMPERATURE = g_state.kelvin,
		})
		return
	end

	local hueDeg = U16HueToDeg(g_state.hue)
	local satFrac = U16ToFrac(g_state.sat)
	local briFrac = U16ToFrac(g_state.bri)
	local x, y = HSVtoXY(hueDeg, satFrac, briFrac)
	if (x == nil) then return end
	EmitColorChanged({
		LIGHT_COLOR_CURRENT_MODE = 0,       -- 0 = Full Color, per C10
		LIGHT_COLOR_CURRENT_X = x,
		LIGHT_COLOR_CURRENT_Y = y,
	})
end

function RFP.SET_COLOR_TARGET(idBinding, strCommand, tParams, args)
	-- Log every call verbatim regardless of enabled state - this is the
	-- primary mechanism for resolving U1 during a DriverEditor session.
	LOG("SET_COLOR_TARGET raw params: " .. DumpTable(tParams))

	if (not g_colorLayerEnabled or g_bulbType == "Dimmable Only") then
		LOG("SET_COLOR_TARGET ignored (color layer disabled or bulb is Dimmable Only)")
		return
	end

	local rate = tonumber(tParams.LIGHT_COLOR_TARGET_RATE) or g_defaultRate   -- C9: confirmed key name

	-- CONFIRMED live 2026-08-17 via a real Navigator color-wheel drag, e.g.
	-- {LIGHT_COLOR_TARGET_RATE=0, LIGHT_COLOR_TARGET_MODE=0,
	--  LIGHT_COLOR_TARGET_Y=0.411117, LIGHT_COLOR_TARGET_X=0.360329} -
	-- exactly the guessed names, no change needed here. CCT mode (MODE=1)
	-- was not exercised live (the test bulb's wheel drag only produced
	-- MODE=0/X/Y); LIGHT_COLOR_TARGET_CORRELATED_TEMPERATURE is kept as the
	-- CCT-mode key name by analogy to the confirmed preset naming (C10) but
	-- is not itself independently confirmed - low risk, since an incorrect
	-- guess here just means tonumber(nil)=nil and the mode==1 branch below
	-- falls back to the bulb's current kelvin rather than sending garbage.
	local mode = tonumber(tParams.LIGHT_COLOR_TARGET_MODE)
	local cct  = tonumber(tParams.LIGHT_COLOR_TARGET_CORRELATED_TEMPERATURE)
	local x    = tonumber(tParams.LIGHT_COLOR_TARGET_X)
	local y    = tonumber(tParams.LIGHT_COLOR_TARGET_Y)

	if (cct ~= nil or mode == 1) then
		cct = Clamp(cct or g_state.kelvin, g_minKelvin, g_maxKelvin)
		SendSetColor(g_state.hue, 0, g_state.bri, cct, rate)
		ScheduleVerify(rate)
		return
	end

	if (x ~= nil and y ~= nil) then
		local hueDeg, satFrac = XYtoHSV(x, y)
		if (hueDeg == nil) then
			LOG("XYtoHSV conversion failed - cannot apply SET_COLOR_TARGET")
			return
		end
		SendSetColor(DegToU16Hue(hueDeg), FracToU16(satFrac), g_state.bri, g_state.kelvin, rate)
		ScheduleVerify(rate)
		return
	end

	LOG("SET_COLOR_TARGET: could not identify color parameters from tParams - contract unconfirmed (U1). " ..
		"Capture this log line's raw params from a live Navigator color-wheel drag to resolve it.")
end

-- ===================== ReceivedFromProxy dispatcher (CONFIRMED - C6) =====
-- Matches the official Snap One sample's handler shape exactly, including
-- the ARGS XML-parsing step (used by some proxies for extra structured
-- data) - wrapped in pcall here since not every command carries ARGS.
function ReceivedFromProxy(idBinding, strCommand, tParams)
	strCommand = strCommand or ''
	tParams = tParams or {}
	local args = {}
	if (tParams.ARGS) then
		local ok, parsedArgs = pcall(function() return C4:ParseXml(tParams.ARGS) end)
		if (ok and parsedArgs and parsedArgs.ChildNodes) then
			for _, v in pairs(parsedArgs.ChildNodes) do
				args[v.Attributes.name] = v.Value
			end
		end
		tParams.ARGS = nil
	end

	LOG("ReceivedFromProxy [" .. tostring(idBinding) .. "] " .. tostring(strCommand))

	local success, ret
	if (type(RFP[strCommand]) == 'function') then
		success, ret = pcall(RFP[strCommand], idBinding, strCommand, tParams, args)
	elseif (type(RFP[idBinding]) == 'function') then
		success, ret = pcall(RFP[idBinding], idBinding, strCommand, tParams, args)
	else
		LOG("Unhandled proxy command: " .. tostring(strCommand))
		return
	end

	if (success == false) then
		LOG("ReceivedFromProxy error: " .. tostring(ret) .. " (" .. tostring(strCommand) .. ")")
	end
	return ret
end

-- ===================== Driver lifecycle ============================
function LoadProperties()
	g_addressMode = Properties["Address Mode"] or g_addressMode
	local ip = Properties["Bulb IP Address"]
	if (ip ~= nil and ip ~= "") then g_ip = ip end
	SetSerialFromHex(Properties["Bulb Serial (MAC)"])
	g_bulbType    = Properties["Bulb Type"] or g_bulbType
	g_minKelvin   = tonumber(Properties["Min Kelvin"]) or g_minKelvin
	g_maxKelvin   = tonumber(Properties["Max Kelvin"]) or g_maxKelvin
	g_defaultRate = tonumber(Properties["Default Ramp Rate (ms)"]) or g_defaultRate
	g_pollInt     = tonumber(Properties["Poll Interval (seconds)"]) or g_pollInt
	g_logMode     = Properties["Log Mode"] or g_logMode
end

function OnDriverInit()
	LoadProperties()
	g_source = ComputeSource()
	LOG("OnDriverInit - source=" .. tostring(g_source) .. " ip=" .. tostring(g_ip))
end

function OnDriverLateInit(driverInitType)
	LoadProperties()

	if (g_addressMode ~= "Manual" and (g_ip == nil or g_ip == "0.0.0.0" or g_ip == "")) then
		BindTo(BroadcastAddressFor("0.0.0.0"))
	else
		BindTo(g_ip)
	end

	NotifyOnline(false)
	StartRetrySweep()
	StartPolling()

	if (g_ip ~= nil and g_ip ~= "0.0.0.0" and g_ip ~= "") then
		SendGetVersion()
		SendGetHostFirmware()
		SendGetLabel()
		SendGetColor()
	elseif (g_addressMode ~= "Manual") then
		RequestDiscoveryBroadcast()
	end
end

function OnDriverDestroyed()
	StopPolling()
	StopRetrySweep()
	StopReconnectTimer()
	StopUnicastSweep()
end

function OnPropertyChanged(strProperty)
	local value = Properties[strProperty]
	LoadProperties()
	LOG("Property changed: " .. tostring(strProperty) .. " = " .. tostring(value))

	local handler = OPC[strProperty]
	if (type(handler) == 'function') then
		local success, ret = pcall(handler, value)
		if (success == false) then
			LOG("OnPropertyChanged error: " .. tostring(ret) .. " (" .. tostring(strProperty) .. ")")
		end
	end
end

-- Property names contain spaces/parens, so these must be bracket-assigned
-- (Lua's `function t.name(...)` sugar only accepts bare identifiers).
OPC["Bulb IP Address"] = function(value)
	-- BUG FOUND VIA LIVE TESTING (2026-08-17, 4 real bulbs added in one
	-- session): this handler only ever called SendGetColor(), never
	-- SendGetVersion()/SendGetHostFirmware(). OnDriverLateInit sends those
	-- two once, but only if Bulb IP Address is ALREADY populated at driver
	-- init time - the ordinary installer workflow (add the device, THEN
	-- type in its IP) sets the property AFTER init, so this handler was the
	-- only other place those requests could come from, and it never sent
	-- them. Net effect: Firmware Version and Product ID stayed blank
	-- forever on every bulb configured this way, even though Connection
	-- Status correctly reached ONLINE and Bulb Label populated fine (the
	-- label rides along on the GetColor/LightState reply, so it never
	-- exposed this gap). Confirmed against 3 of 4 real bulbs in this
	-- session - only the one bulb whose Firmware/Product had been populated
	-- via a one-off manual console command earlier showed real values.
	if (value ~= nil and value ~= "0.0.0.0" and value ~= "") then
		BindTo(value)
		SendGetVersion()
		SendGetHostFirmware()
		SendGetColor()
	end
end

OPC["Address Mode"] = function(value)
	if (value ~= "Manual") then RequestDiscoveryBroadcast() end
end

OPC["Poll Interval (seconds)"] = function(value)
	StartPolling()
end

-- ===================== Polling / retry / reconnect timers ================
-- Repeating named timers use C4:AddTimer(ms, units, repeat, "FunctionName"),
-- CONFIRMED via the field-validated Haiku driver. One-shot timers with a
-- closure use C4:SetTimer(ms, functionRef), CONFIRMED via the official
-- Snap One sample_light_driver (DebugPrintTimer = C4:SetTimer(...)).

function StartPolling()
	StopPolling()
	if (g_pollInt <= 0) then return end
	g_pollingActive = true
	-- Per-instance jitter (0-2s) so multiple bulb driver instances don't
	-- all poll in lockstep (architecture Section 9 risk mitigation).
	local jitterMs = SafeGetDeviceID() % 2000
	C4:SetTimer(jitterMs, OnPollTimer)
end

function StopPolling()
	g_pollingActive = false
	if (g_pollTimerId ~= nil) then
		pcall(function() C4:KillTimer(g_pollTimerId) end)
		g_pollTimerId = nil
	end
end

function OnPollTimer(idTimer)
	if (not g_pollingActive) then return end
	if (g_ip == nil or g_ip == "" or g_ip == "0.0.0.0") then
		if (g_addressMode ~= "Manual") then RequestDiscoveryBroadcast() end
	else
		g_missedPolls = g_missedPolls + 1
		if (g_missedPolls >= 3) then
			SetBulbOnline(false)
		end
		SendGetColor()
	end
	-- Self-reschedule (AddTimer's repeating mode does not fire on this
	-- Director - see the comment on the globals block above).
	if (g_pollingActive and g_pollInt > 0) then
		C4:SetTimer(g_pollInt * 1000, OnPollTimer)
	end
end

function StartRetrySweep()
	StopRetrySweep()
	g_retrySweepActive = true
	C4:SetTimer(500, OnRetryTimer)
end

function StopRetrySweep()
	g_retrySweepActive = false
	if (g_retryTimerId ~= nil) then
		pcall(function() C4:KillTimer(g_retryTimerId) end)
		g_retryTimerId = nil
	end
end

function ScheduleReconnect()
	StopReconnectTimer()
	LOG("Scheduling re-discovery in " .. tostring(g_reconnectBackoff) .. "s")
	-- Already logically one-shot (this used AddTimer(..., repeat=false,
	-- ...) before), but AddTimer never fires at all on this Director
	-- regardless of the repeat flag - use the confirmed-working SetTimer.
	C4:SetTimer(g_reconnectBackoff * 1000, OnReconnectTimer)
	g_reconnectBackoff = math.min(g_reconnectBackoff * 2, 300)
end

function StopReconnectTimer()
	if (g_reconnectTimerId ~= nil) then
		pcall(function() C4:KillTimer(g_reconnectTimerId) end)
		g_reconnectTimerId = nil
	end
end

function OnReconnectTimer(idTimer)
	if (g_bulbOnline) then return end
	LOG("Attempting re-discovery")
	if (g_addressMode == "Manual") then
		SendGetColor()
	else
		RequestDiscoveryBroadcast()
	end
	ScheduleReconnect()
end

function ScheduleVerify(delayMs)
	local delay = (delayMs or g_defaultRate) + 250
	C4:SetTimer(delay, OnVerifyTimer)
end

function OnVerifyTimer(idTimer)
	SendGetColor()
end

-- ===================== ExecuteCommand / driver actions ============================
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	LOG("ExecuteCommand: " .. tostring(strCommand))

	if (strCommand == 'LUA_ACTION') then
		if (tParams.ACTION) then
			strCommand = tParams.ACTION
			tParams.ACTION = nil
		end
	end

	if (type(EC[strCommand]) == 'function') then
		local success, ret = pcall(EC[strCommand], tParams)
		if (success == false) then
			LOG("ExecuteCommand error: " .. tostring(ret) .. " (" .. tostring(strCommand) .. ")")
		end
		return ret
	else
		LOG("Unhandled command: " .. tostring(strCommand))
	end
end

-- Command/action names contain spaces and parens, so these are bracket-
-- assigned rather than using the `function EC.Name(...)` dot-sugar.
EC["Discover Bulbs"] = function(tParams)
	RequestDiscoveryBroadcast()
end
EC.ACTION_DISCOVER = EC["Discover Bulbs"]

EC["Re-resolve IP"] = function(tParams)
	if (g_addressMode == "Manual") then
		LOG("Re-resolve IP skipped: Address Mode is Manual")
		return
	end
	StartUnicastSweep()
end
EC.ACTION_REDISCOVER = EC["Re-resolve IP"]

-- "Breathe" identify implemented as a brightness blink using only the
-- confirmed message set (SetLightPower) rather than SetWaveform (103),
-- which the architecture doc's core message list (Section 3.5) does not
-- include. Blinks twice, then restores the previous power state.
EC["Identify (breathe)"] = function(tParams)
	local savedPower = g_state.power
	SendSetLightPower(65535, 150)
	C4:SetTimer(300, function() SendSetLightPower(0, 150) end)
	C4:SetTimer(600, function() SendSetLightPower(65535, 150) end)
	C4:SetTimer(900, function() SendSetLightPower(savedPower, 150) end)
end
EC.ACTION_IDENTIFY = EC["Identify (breathe)"]

EC["Refresh State"] = function(tParams)
	SendGetColor()
	if (g_state.firmwareVersion == nil) then SendGetHostFirmware() end
	if (g_state.product == nil) then SendGetVersion() end
end
EC.ACTION_REFRESH = EC["Refresh State"]

EC["Print Debug Info"] = function(tParams)
	print("=== LIFX Driver Debug (v" .. DRIVER_VERSION .. ") ===")
	print("IP: " .. tostring(g_ip) .. "  Serial: " .. tostring(g_serialHex) .. "  AddressMode: " .. tostring(g_addressMode))
	print("BulbType: " .. tostring(g_bulbType) .. "  ColorLayerEnabled: " .. tostring(g_colorLayerEnabled))
	print("NetBound: " .. tostring(g_netBound) .. "  NetOnline: " .. tostring(g_netOnline) .. "  BulbOnline: " .. tostring(g_bulbOnline))
	print("Power: " .. tostring(g_state.power) .. "  Hue: " .. tostring(g_state.hue) ..
		"  Sat: " .. tostring(g_state.sat) .. "  Bri: " .. tostring(g_state.bri) .. "  Kelvin: " .. tostring(g_state.kelvin))
	print("Pending: " .. tostring(TableCount(g_pending)) .. "  Failures: " .. tostring(g_failureCount))
	print("PollingActive: " .. tostring(g_pollingActive) .. "  PollInterval: " .. tostring(g_pollInt) ..
		"s  MissedPolls: " .. tostring(g_missedPolls) .. "  RetrySweepActive: " .. tostring(g_retrySweepActive))
	print("g_seq (outbound frame counter, sanity-check against poll interval x uptime): " .. tostring(g_seq))
end
EC.ACTION_PRINT_DEBUG = EC["Print Debug Info"]
