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

	Control4 DriverWorks API usage in this file (network layer) mirrors the
	already-checked patterns from this project's Haiku_SenseME_driver.lua:
	  - C4:CreateNetworkConnection / C4:NetConnect / C4:SendToNetwork /
	    ReceivedFromNetwork / OnConnectionStatusChanged / OnNetworkBindingChanged
	  - Proxy notifications now use the thermostatV2 pattern (CONNECTION /
	    HVAC_MODE_CHANGED / HVAC_STATE_CHANGED / HEAT_SETPOINT_CHANGED /
	    ALLOWED_HVAC_MODES_CHANGED / SCALE_CHANGED), confirmed against a real
	    published thermostatV2 driver (bphillips09/Control4-HA-Thermostat) -
	    see the dated header note further down for why this changed from an
	    earlier light_v2 version of this driver.
	This driver deliberately does NOT use C4:urlGet/C4:urlPost-style helpers,
	since this project has not independently confirmed their exact call
	signature; a raw TCP socket + hand-built HTTP/1.1 request/response is used
	instead, reusing only already-confirmed primitives.

	================================================================================
	COWORK TEST SESSION (2026-08-15) - sandboxed logic/protocol testing, NO LIVE
	FIREPLACE AVAILABLE. This driver was loaded into a Lua runtime with the
	Control4 C4:* API stubbed out and exercised against a scripted mock HTTP
	server standing in for the fireplace's module. What that confirmed vs.
	still leaves open:

	CONFIRMED in this session:
	  - driver.lua loads and runs cleanly under Lua 5.1 semantics (no syntax
	    errors, OnDriverInit/OnDriverLateInit execute without runtime errors).
	  - Sha256Hex() matches Python hashlib.sha256 exactly across 11 vectors,
	    including a 512-byte multi-block input, block-boundary sizes (55/56/
	    63/64 bytes), and inputs with embedded 0x00 and high-bit-set bytes
	    (the shape of real hex-decoded challenge/API-key bytes) - the earlier
	    FIPS 180-4 claim in this header is now cross-checked with adversarial
	    byte content, not just ASCII test strings.
	  - ComputeCommandSigning() is internally self-consistent: for every
	    challenge/api-key/command/value combination tried, the hex `response`
	    field in the POST /post body exactly equals
	    SHA256(challenge_bytes .. apikey_bytes .. "command=X&value=Y") computed
	    independently in Python. The code correctly implements the documented
	    scheme - what's STILL NOT verified is whether Hearth & Home's firmware
	    actually expects that scheme. No live IFT-WFM module was available to
	    test against, so this remains the real open risk described above.
	  - /poll parsing (JsonNumberField, Content-Length handling, the no-
	    Content-Length fallback path, and TCP responses split across multiple
	    ReceivedFromNetwork calls/packet boundaries) all parse correctly and
	    update g_state / NotifyFlameLevel as expected.
	  - ON (cold pilot), ON (pilot already lit - no ignition delay scheduled),
	    OFF, TOGGLE, SET_LEVEL(>0), SET_LEVEL(0), and the ignition-delay timer
	    path (OnIgnitionDelayComplete) all drive the expected sequence of
	    commands with correct payloads.
	  - No IP configured: DrainQueue logs and discards the queue rather than
	    retrying unboundedly; setting the IP later via OnPropertyChanged
	    correctly rebinds and resumes polling.
	  - Driver restart mid-ignition: since a Control4 driver restart is a
	    fresh Lua VM (no persisted globals), there is no stale in-flight state
	    to desync - the next /poll after restart fully resyncs g_state from
	    whatever the real device reports. Not a code path that can meaningfully
	    "get it wrong" given this driver's architecture.

	CONFIRMED, MINOR BEHAVIORAL QUIRKS (not correctness bugs, but real and
	reproducible - worth knowing about):
	  1. Duplicate poll after multi-command actions: OFF (power=0 then pilot=0)
	     and SET_LEVEL>0 (height=X then power=1) each call SendFireplaceCommand
	     twice back-to-back. Each command's POST /post callback independently
	     calls QueuePoll(), so a single OFF or SET_LEVEL press produces TWO
	     /poll refreshes instead of one. Each command's request/response pair
	     is still correctly matched (own challenge, own signature - no cross-
	     contamination), so this is wasted traffic, not wrong behavior.
	  2. SET_LEVEL is not debounced: dragging the Navigator dimmer fires one
	     SendFireplaceCommand pair per intermediate value with no coalescing/
	     cancellation. g_reqQueue serializes and eventually converges to the
	     correct final height (verified: 5 rapid drags -> 9 queued requests,
	     29 total wire round-trips, final height correct), so nothing is lost
	     or corrupted - it's just more chatter than strictly necessary.

	STILL NOT CONFIRMED (unchanged from before this session - needs a live
	IFT-WFM module to close out):
	  - Whether /post actually accepts this signing scheme on real firmware.
	  - PILOT_TO_FLAME_DELAY_MS (5000ms) as a real-world ignition duration.
	  - Whether /poll's JSON field names (power/pilot/height) match your
	    firmware version.

	================================================================================
	LIVE HARDWARE TEST (2026-08-15, later same day) - real IFT-WFM module at
	172.21.1.149, driven through Control4 Composer Pro, not the sandbox.

	CONFIRMED against the real unit:
	  - /poll and /get_challenge respond exactly as documented above: /poll's
	    JSON field names (power/pilot/height, plus serial/fw_ver_str/etc.)
	    match JsonNumberField's expectations with no firmware discrepancy,
	    and /get_challenge returns a clean unwrapped 32-char hex string.

	BUG FOUND AND FIXED - reconnect handling:
	  Symptom reported from Composer: "Connection Status" went ONLINE once,
	  then dropped to OFFLINE and never flipped back, and the "Pilot On"
	  action did nothing after that.
	  Root cause: driver.xml sets keep_connection=False and every request is
	  built with "Connection: close", so the module (correctly) closes the
	  TCP socket after every single response. Control4 reports that as
	  OnConnectionStatusChanged(..., "OFFLINE") after EVERY request - not
	  just on real failures. The old DrainQueue()/QueueRequest() only ever
	  called C4:NetConnect() once, during the initial BindTo/
	  OnNetworkBindingChanged sequence. Once the first request completed and
	  the socket closed, nothing ever reconnected, so every later poll and
	  every Composer command just piled up silently in g_reqQueue forever.
	  Reproduced in the sandbox harness by simulating the same connect ->
	  request -> disconnect cycle Control4 actually does (earlier sandbox
	  testing only ever simulated a single persistent ONLINE state and
	  missed this).
	  Fix: DrainQueue() now checks g_netOnline before popping the queue; if
	  not connected, it calls C4:NetConnect() and returns, relying on
	  OnConnectionStatusChanged("ONLINE") to call DrainQueue() again once
	  reconnected. QueueRequest()'s gate no longer requires g_netOnline to
	  attempt a drain, since DrainQueue() itself now handles the
	  disconnected case. Verified in the sandbox harness that polls and
	  commands issued while disconnected now correctly wait for reconnect
	  and then send, instead of being silently dropped.
	================================================================================
PROXY REWRITE (2026-08-15, third session) - light_v2 -> thermostatV2

Switched from light_v2 to thermostatV2. Reason: light_v2-bound devices are
pulled into a room's Lighting group by Navigator/Composer (that's driven by
proxy type, not by the composer_categories/navigator_categories XML tags
below), so "All Lights Off" scenes and lighting keypads would silently also
control the fireplace. Checked how commercial Control4 fireplace drivers
handle this (the Elite Fire Proflame2 driver on drivercentral.io) - they use
"familiar thermostat style controls" for exactly this reason. Also checked a
real, published thermostatV2 driver (bphillips09/Control4-HA-Thermostat on
GitHub) to confirm actual proxy command/notification names rather than
guessing, since Control4's own docs-driverworks sample repo has no
thermostat sample, only light_sample.c4i.

Mapping:
  - SET_MODE_HVAC (MODE="Heat"/"Off") -> TurnFlameOn() / power+pilot off,
    same ignition sequence as the old ON/OFF/TOGGLE handlers.
  - SET_SETPOINT_HEAT (SETPOINT=1-5) -> flame height 0-4 via
    SetpointToHeight(). This is a re-purposed intensity dial, not a real
    temperature - setpoint_heat_min/max_f capabilities are 1/5 to match the
    fireplace's real 5 flame-height levels (as printed on IntelliFire's own
    remote: levels 1-5), not a 0-100 percentage. Changed from 0-100 to 1-5
    on 2026-08-16 per user request, once the intensity-dial framing was
    understood - no reason to make users guess what percentage maps to
    which of the 5 real flame-height steps.
  - Connection state now also reported via the proxy's own CONNECTION
    notification (SendToProxy(...,"CONNECTION",{CONNECTED=...})), in
    addition to the existing read-only "Connection Status" property, so
    Navigator's thermostat card can show connect state directly.
  - Pilot on/off remains a separate Composer command/action (ACTION_PILOT_ON/
    OFF, "Set Pilot" command) - thermostatV2 has no "pilot" concept, same as
    light_v2 didn't either.
  - This hardware has no ambient temperature sensor, so no TEMPERATURE_CHANGED
    is ever sent; the current-temperature readout on the thermostat card is
    expected to show blank/unavailable. Not a bug.

NOT YET LIVE-VERIFIED: this rewrite has been sandbox-tested (dispatch logic,
state transitions, notification params) but NOT yet confirmed against real
Navigator/Composer thermostat card rendering - unlike the reconnect and
whitespace fixes above, which were both confirmed live. Load this version and
check that the thermostat card behaves sensibly before relying on it.
================================================================================
LIVE FOLLOW-UP (2026-08-15, fourth session) - stuck-pending-request bug

After loading v104, live testing showed Connection Status pinned OFFLINE and
no thermostat state ever updating. Root-caused live via Composer's Lua
console: g_pendingReq was stuck non-nil with g_netOnline false and an empty
g_reqQueue - a request had gone out, the socket dropped before a full
response came back, and OnConnectionStatusChanged's OFFLINE branch never
cleared g_pendingReq. Since DrainQueue() bails immediately whenever
g_pendingReq ~= nil, nothing could ever be sent again. This is not specific
to the thermostatV2 rewrite - it's a latent gap in the original reconnect
fix, just never previously triggered in exactly this way (a v103->v104
package swap while a request happened to be in flight seems to have
triggered it here, but the same race could occur on any single request
given this hardware's Connection: close design).

Confirmed fix live: manually clearing g_pendingReq via the Lua console
immediately unstuck it - the next poll succeeded and returned real state
(power=0, pilot=0, height=4). v105 makes that recovery automatic instead of
requiring a console command: OnConnectionStatusChanged's OFFLINE branch now
clears g_pendingReq and requeues the interrupted request when this happens.
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

-- Whether g_state reflects a real, polled response from the fireplace yet,
-- as opposed to just the hardcoded placeholder defaults above. See the
-- OnDriverLateInit/OnPollResponse notes (2026-08-16, ninth session) for why
-- this exists.
g_haveRealState = false

-- g_desiredPower/g_desiredHeight track the target of the most recent
-- command still awaiting hardware confirmation (nil = nothing pending,
-- last reconcile poll matched or gave up). See OnPollResponse/
-- ScheduleReconcilePoll notes (2026-08-16, sixth session) for why this
-- exists: a single poll 1.5s after a command is often too early - real
-- ignition/purge takes much longer than that - and treating that stale
-- poll as ground truth silently reverted the optimistic Navigator update
-- back to the old state while the fireplace was still audibly igniting.
g_desiredPower      = nil
g_desiredHeight     = nil
g_reconcileAttempts = 0
MAX_RECONCILE_ATTEMPTS  = 14   -- ~1.5s + 13*2s =~ 27.5s of retrying before giving up
RECONCILE_RETRY_MS      = 2000

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
	C4:SendToProxy(FIREPLACE_BINDING, "ALLOWED_HVAC_MODES_CHANGED", { MODES = "Off,Heat" }, "NOTIFY")
	C4:SendToProxy(FIREPLACE_BINDING, "SCALE_CHANGED", { SCALE = "FAHRENHEIT" }, "NOTIFY")
	-- REAL BUG FOUND LIVE (2026-08-16, ninth session): this used to call
	-- NotifyThermostatState() right here, announcing g_state's hardcoded
	-- placeholder values (height=0 -> a "1" on the 1-5 dial) as if they
	-- were real - before StartPolling()'s very first poll (fired a moment
	-- ago, still in flight) has actually heard back from the fireplace.
	-- User reported the flame-height dial "defaulting to 1" after setting
	-- Heat - this is why: Navigator's first-ever look at the setpoint was
	-- this made-up placeholder, not the fireplace's real height. Same
	-- principle already applied to CONNECTION (never announced true until
	-- a real response completes) now applies here too: say nothing about
	-- mode/setpoint until OnPollResponse has real data to report. See
	-- g_haveRealState below - the first successful poll now always
	-- announces itself (even if the real values happen to equal the
	-- placeholder defaults), so Navigator still gets an authoritative
	-- state a moment later, just never a guessed one.
end

function OnDriverDestroyed()
	StopPolling()
end

-- Trims leading/trailing whitespace. Confirmed live (2026-08-15) that a
-- copy-pasted API Key with trailing spaces silently breaks HexToRawBytes
-- inside ComputeCommandSigning (returns nil -> "bad hex in challenge/api
-- key?" in the log) with no indication that whitespace was the culprit.
-- Trimming defensively here means a stray space from copy/paste can't
-- cause that again.
function TrimWhitespace(s)
	if (s == nil) then return s end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function LoadProperties()
	g_ip      = Properties["Fireplace IP Address"] or g_ip
	g_userId  = TrimWhitespace(Properties["API User ID"]) or g_userId
	g_apiKey  = TrimWhitespace(Properties["API Key"]) or g_apiKey
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

g_offlineNotifyTimerId = nil
OFFLINE_NOTIFY_GRACE_MS = 4000

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if (idBinding ~= NET_BINDING) then return end
	LOG("OnConnectionStatusChanged: " .. tostring(strStatus))
	g_netOnline = (strStatus == "ONLINE")
	C4:UpdateProperty("Connection Status", tostring(strStatus))
	if (g_netOnline) then
		-- Back online - cancel any pending "really offline" notification;
		-- whatever OFFLINE blip preceded this was just the normal
		-- per-request reconnect cycle, not a real outage. See the grace-
		-- timer notes in the else branch below for why this matters.
		if (g_offlineNotifyTimerId ~= nil) then
			pcall(function() C4:KillTimer(g_offlineNotifyTimerId) end)
			g_offlineNotifyTimerId = nil
		end
		DrainQueue()
	else
		-- BUG FOUND LIVE (2026-08-15, fourth session): if the socket drops
		-- while a request is still in flight (g_pendingReq ~= nil) - e.g. the
		-- module closes its end before ReceivedFromNetwork ever assembles a
		-- full response - this handler used to leave g_pendingReq stuck
		-- forever. DrainQueue() refuses to send anything while g_pendingReq
		-- ~= nil, so the driver would silently stop working (Connection
		-- Status pinned OFFLINE, no more polls, no more commands) even
		-- though OnNetworkBindingChanged/OnConnectionStatusChanged kept
		-- firing normally and nothing else looked wrong. Confirmed live
		-- against the real fireplace: g_pendingReq was a live table,
		-- g_netOnline was false, g_reqQueue was empty - permanently stuck
		-- until a Lua console command manually cleared it. Put the
		-- interrupted request back at the front of the queue so it's
		-- retried instead of silently lost, and proactively try to
		-- reconnect right away rather than waiting for the next poll timer.
		if (g_pendingReq ~= nil) then
			LOG("Connection dropped mid-request - requeuing and reconnecting")
			table.insert(g_reqQueue, 1, g_pendingReq)
			g_pendingReq = nil
		end

		-- REAL BUG FOUND LIVE (2026-08-16, eighth session): this hardware
		-- closes the TCP connection after EVERY single request (Connection:
		-- close - see DrainQueue notes below), so this OFFLINE branch fires
		-- constantly during completely normal operation, not just on real
		-- outages. It used to call NotifyOnline(false) unconditionally
		-- every time, which sent CONNECTION=false to the proxy after
		-- essentially every command and every poll. User reported the
		-- thermostat card on their iPad appearing then immediately
		-- disappearing right after setting Heat - that lines up exactly
		-- with the request cycle SET_MODE_HVAC triggers (get_challenge,
		-- then post, each ending in a disconnect): the Control4 App
		-- apparently reacts to CONNECTION=false by hiding the device
		-- outright rather than just greying it out. Fixed the same way as
		-- the reconcile-poll lag (ScheduleReconcilePoll, v108): debounce.
		-- A "really offline" notification only fires if the connection is
		-- STILL down OFFLINE_NOTIFY_GRACE_MS later - comfortably longer
		-- than one reconnect+request round trip - so the normal per-request
		-- blips never reach the proxy at all, only genuine outages do.
		if (g_offlineNotifyTimerId == nil) then
			g_offlineNotifyTimerId = C4:AddTimer(OFFLINE_NOTIFY_GRACE_MS, "MILLISECONDS", false, "OnOfflineGraceTimer")
		end
		DrainQueue()
	end
end

function OnOfflineGraceTimer(idTimer)
	g_offlineNotifyTimerId = nil
	if (not g_netOnline) then
		NotifyOnline(false)
	end
end

function NotifyOnline(bOnline)
	local sConnected = bOnline and "true" or "false"
	C4:SendToProxy(FIREPLACE_BINDING, "CONNECTION", { CONNECTED = sConnected }, "NOTIFY")
end

-- ===================== HTTP request/response plumbing ============================
-- Every call is queued and sent one at a time (the module is a small embedded
-- HTTP server; issuing overlapping requests is asking for trouble). Each
-- request is built as a raw HTTP/1.1 message with "Connection: close" so we
-- can rely on Content-Length to know when the body is complete.

function QueueRequest(sMethod, sPath, sBody, fCallback)
	table.insert(g_reqQueue, { method = sMethod, path = sPath, body = sBody, callback = fCallback })
	if (g_pendingReq == nil) then
		DrainQueue()
	end
end

-- IMPORTANT: this module's HTTP server does not keep connections alive --
-- every request/response cycle ends with the socket closing (we send our
-- own "Connection: close", and keep_connection is False in driver.xml).
-- Control4 reports that as OnConnectionStatusChanged(..., "OFFLINE") after
-- EVERY single request. Confirmed against a live unit during testing: the
-- very first request succeeds, the connection drops right after (expected),
-- and without the reconnect below, nothing ever gets sent again -- queued
-- polls and commands (e.g. "Pilot On") pile up in g_reqQueue forever.
function DrainQueue()
	if (g_pendingReq ~= nil) then return end
	if (#g_reqQueue == 0) then return end
	if (g_ip == nil or g_ip == "" or g_ip == "0.0.0.0") then
		LOG("Cannot send request, Fireplace IP not configured")
		g_reqQueue = {}
		return
	end

	if (not g_netOnline) then
		LOG("Not connected, reconnecting before draining queue")
		local ok, err = pcall(function() C4:NetConnect(NET_BINDING, HTTP_PORT, "TCP") end)
		if (not ok) then
			LOG("NetConnect failed: " .. tostring(err))
		end
		return -- OnConnectionStatusChanged("ONLINE") will call DrainQueue() again
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

-- CONFIRMED LIVE (2026-08-15, fifth session): a single Navigator action can
-- fire multiple SendFireplaceCommand() calls (e.g. "Off" = power=0 AND
-- pilot=0), and each one used to trigger its own immediate QueuePoll().
-- Since every single request on this connection requires its own reconnect
-- (Connection: close - see DrainQueue notes above), that meant 2-3 full
-- serialized reconnect+request cycles stacked back to back before Navigator
-- ever saw a confirmed state change - the reported ~20s lag. Debouncing to
-- ONE reconcile poll, fired a moment after the last command in a burst,
-- cuts that roughly in half without losing the real confirmation.
--
-- CONFIRMED LIVE (2026-08-16, sixth session): a single one-shot poll wasn't
-- enough either. Real ignition (purge -> trial ignition -> flame-sense
-- confirm) audibly takes noticeably longer than the 1.5s debounce delay -
-- user reported clicking Heat, immediately hearing the ignition beeps, but
-- Navigator never showing Heat as on. Root cause: the poll at 1.5s still
-- caught the fireplace mid-ignition (power still 0 on the real hardware),
-- and OnPollResponse trusted that stale snapshot as ground truth, silently
-- reverting the optimistic g_state.power=1 back to 0 - the exact opposite
-- of what should happen right after a command was just sent. Fixed by
-- tracking the desired end state (g_desiredPower/g_desiredHeight) alongside
-- the optimistic update, and having OnPollResponse keep re-polling every
-- RECONCILE_RETRY_MS instead of accepting a mismatched poll immediately,
-- up to MAX_RECONCILE_ATTEMPTS tries (~27s total, generously covering the
-- real hardware's ignition delay). Only once the poll actually matches the
-- desired state - or the retry budget runs out (e.g. a genuine failure) -
-- does the optimistic value get treated as settled/replaced.
g_reconcileTimerId = nil

function ScheduleReconcilePoll()
	if (g_reconcileTimerId ~= nil) then
		pcall(function() C4:KillTimer(g_reconcileTimerId) end)
	end
	g_reconcileAttempts = 0
	g_reconcileTimerId = C4:AddTimer(1500, "MILLISECONDS", false, "OnReconcilePollTimer")
end

function OnReconcilePollTimer(idTimer)
	g_reconcileTimerId = nil
	QueuePoll()
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

	-- Still waiting to confirm a recently-issued command? Don't let a poll
	-- that hasn't caught up yet (hardware still igniting/purging) stomp the
	-- optimistic UI back to the old state - keep quietly re-checking on a
	-- short interval instead, up to the retry budget.
	if (g_desiredPower ~= nil) then
		local matchesPower  = (power == g_desiredPower)
		local matchesHeight = (g_desiredHeight == nil) or (height == g_desiredHeight)
		if (matchesPower and matchesHeight) then
			g_desiredPower = nil
			g_desiredHeight = nil
		else
			g_reconcileAttempts = g_reconcileAttempts + 1
			if (g_reconcileAttempts < MAX_RECONCILE_ATTEMPTS) then
				LOG("Hardware hasn't confirmed the last command yet (attempt " ..
					g_reconcileAttempts .. "/" .. MAX_RECONCILE_ATTEMPTS ..
					") - rechecking in " .. RECONCILE_RETRY_MS .. "ms")
				g_reconcileTimerId = C4:AddTimer(RECONCILE_RETRY_MS, "MILLISECONDS", false, "OnReconcilePollTimer")
				return
			else
				LOG("Gave up waiting for hardware to confirm the last command - showing real state")
				g_desiredPower = nil
				g_desiredHeight = nil
			end
		end
	end

	-- The very first successful poll always announces its state to the
	-- proxy, even if the real values happen to equal g_state's hardcoded
	-- placeholder defaults (power=0/height=0) - otherwise Navigator would
	-- never hear an authoritative mode/setpoint at all in that case, since
	-- nothing would look "changed" from the placeholder. See the
	-- OnDriverLateInit notes above for why this replaced announcing the
	-- placeholder immediately at driver init.
	local changed = false
	if (not g_haveRealState) then
		g_haveRealState = true
		changed = true
	end
	if (power ~= nil and power ~= g_state.power) then g_state.power = power; changed = true end
	if (pilot ~= nil and pilot ~= g_state.pilot) then g_state.pilot = pilot; changed = true end
	if (height ~= nil and height ~= g_state.height) then g_state.height = height; changed = true end

	if (changed) then
		NotifyThermostatState()
	end
end

-- ===================== Control (/get_challenge + /post) ============================
-- CONFIRMED LIVE (2026-08-15, fourth session): the originally reverse-engineered
-- signing scheme below got a real 403 Forbidden from the actual fireplace
-- firmware (IFTwifi 0.3.12+hw2+iftapi.net) - captured via Composer's Lua
-- console against the live unit. Replaced with the actual algorithm read
-- straight out of intellifire4py 4.5.4's local_api.py (_construct_payload),
-- the de-facto reference client, rather than another guess. Two things were
-- wrong before:
--   1. The hash-input payload needs a "post:" prefix ("post:command=X&value=Y")
--      that is NOT part of the actual wire-body payload sent in the POST.
--   2. The real scheme is a NESTED double SHA-256:
--        inner = SHA256(apiKeyBytes .. challengeBytes .. payloadBytes)          (raw digest)
--        response = SHA256(apiKeyBytes .. innerDigestBytes) as hex
--      Previously this was a single SHA256(challengeBytes .. apiKeyBytes .. payload)
--      - wrong byte order AND missing the nesting entirely.

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
		local responseHex = ComputeCommandSigning(challengeHex, g_apiKey, sCmd, nVal)
		if (responseHex == nil) then
			LOG("Failed to compute command signing (bad hex in challenge/api key?)")
			return
		end
		local wireBody = "command=" .. sCmd .. "&value=" .. tostring(nVal)
		local postBody = wireBody .. "&user=" .. g_userId .. "&response=" .. responseHex
		QueueRequest("POST", "/post", postBody, function(sc, b)
			LOG("POST /post [" .. sCmd .. "=" .. tostring(nVal) .. "] -> status=" .. tostring(sc))
			ScheduleReconcilePoll() -- debounced refresh - see notes above
		end)
	end)
end

function ComputeCommandSigning(challengeHex, apiKeyHex, sCmd, nVal)
	local challengeBytes = HexToRawBytes(challengeHex)
	local apiKeyBytes = HexToRawBytes(apiKeyHex)
	if (challengeBytes == nil or apiKeyBytes == nil) then return nil end
	local hashPayload = "post:command=" .. sCmd .. "&value=" .. tostring(nVal)
	local innerDigest = Sha256Raw(apiKeyBytes .. challengeBytes .. hashPayload)
	return Sha256Hex(apiKeyBytes .. innerDigest)
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
-- thermostatV2 notification names/params confirmed against a real, published
-- thermostatV2 driver (bphillips09/Control4-HA-Thermostat on GitHub) rather
-- than guessed, since Control4's own sample repo has no thermostat sample.
-- Flame height (0-4, 5 real hardware levels) is mapped 1:1 to a heat-setpoint
-- of 1-5 - a re-purposed intensity dial, not a real temperature. Changed
-- from a 0-100 percentage to 1-5 on 2026-08-16 so the Navigator dial shows
-- the same 5 steps the fireplace's own remote uses, instead of forcing users
-- to guess what percentage lands on which flame-height level. The setpoint
-- always reflects the last-set height even while Mode=Off (height is not
-- reset by turning the mode off), matching how the real remote remembers
-- its flame-height level across power cycles.

function HeightToSetpoint(nHeight)
	local sp = (nHeight or 0) + 1
	if (sp < 1) then sp = 1 end
	if (sp > 5) then sp = 5 end
	return sp
end

function SetpointToHeight(nSetpoint)
	if (nSetpoint == nil) then return 0 end
	local h = math.floor(nSetpoint + 0.5) - 1
	if (h < 0) then h = 0 end
	if (h > 4) then h = 4 end
	return h
end

function NotifyThermostatState()
	local mode = "Off"
	if (g_state.power == 1) then mode = "Heat" end
	local sp = HeightToSetpoint(g_state.height)
	C4:SendToProxy(FIREPLACE_BINDING, "HVAC_MODE_CHANGED", { MODE = mode }, "NOTIFY")
	C4:SendToProxy(FIREPLACE_BINDING, "HVAC_STATE_CHANGED", { STATE = mode }, "NOTIFY")
	C4:SendToProxy(FIREPLACE_BINDING, "HEAT_SETPOINT_CHANGED", { SETPOINT = sp, SCALE = "FAHRENHEIT" }, "NOTIFY")
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

-- ON = light-switch style "turn the fireplace on". Previously this sent
-- "pilot=1", waited PILOT_TO_FLAME_DELAY_MS, then sent "power=1" - an
-- invented two-step sequence based on a guess about real ignition hardware,
-- never vendor-confirmed. CORRECTED (2026-08-15, fourth session) against
-- intellifire4py's actual control.py: the reference client's flame_on()
-- does nothing but send power=1 directly - no separate pilot step, no
-- artificial delay. The firmware handles its own purge/trial-ignition/
-- flame-sense sequence internally once it receives power=1. Kept
-- TurnFlameOn() as a named function (rather than inlining) since Pilot
-- On/Off is still exposed separately via its own Composer command/action.
function FireplaceProxyCommand(cmd, p)
	if (cmd == "SET_MODE_HVAC") then
		local mode = p.MODE
		if (mode == "Heat") then
			-- Optimistic local update: reflect the change in Navigator right
			-- away instead of waiting on a full network round trip (each of
			-- which needs its own reconnect - see DrainQueue notes). The
			-- debounced reconcile poll a moment later confirms/corrects this
			-- against the real device.
			g_state.power = 1
			-- Track what we're waiting for so OnPollResponse knows not to
			-- trust an early poll that still shows the fireplace mid-
			-- ignition - see the reconcile notes above OnPollResponse.
			g_desiredPower = 1
			g_desiredHeight = nil
			NotifyThermostatState()
			TurnFlameOn()
		else -- "Off" (or anything unrecognized - fail safe to off)
			g_state.power = 0
			g_state.pilot = 0
			g_desiredPower = 0
			g_desiredHeight = nil
			NotifyThermostatState()
			SendFireplaceCommand("power", 0)
			SendFireplaceCommand("pilot", 0)
		end
	elseif (cmd == "SET_SETPOINT_HEAT") then
		-- REAL BUG FOUND (2026-08-16, seventh session): the real thermostatV2
		-- SET_SETPOINT_HEAT command from Navigator/the Control4 App sends
		-- CELSIUS and FAHRENHEIT params, NOT a "SETPOINT" param - confirmed
		-- against bphillips09/Control4-HA-Thermostat's real RFP.SET_SETPOINT_HEAT
		-- handler (tParams["CELSIUS"]/tParams["FAHRENHEIT"]). "SETPOINT" is
		-- only the param name used in the driver->proxy HEAT_SETPOINT_CHANGED
		-- notify direction, not the incoming command. This driver originally
		-- read p.SETPOINT here, which was never exercised against a real
		-- Navigator/App call (only hand-built Lua console test calls that
		-- happened to use whatever param name was assumed) - it was always
		-- nil, so every drag of the setpoint dial silently fell back to the
		-- default (1) no matter where the user actually dragged it, which is
		-- why the setpoint control looked broken/unresponsive in the app.
		-- Since our scale is fixed at FAHRENHEIT (can_change_scale=false),
		-- that's the primary field; CELSIUS and the old SETPOINT name are
		-- kept as fallbacks for robustness.
		local sp = tonumber(p.FAHRENHEIT) or tonumber(p.CELSIUS) or tonumber(p.SETPOINT) or 1
		local height = SetpointToHeight(sp)
		g_state.power = 1
		g_state.height = height
		g_desiredPower = 1
		g_desiredHeight = height
		NotifyThermostatState()
		-- "flame_height" is the real local /post command name (confirmed
		-- against intellifire4py's const.py) - "height" is only the /poll
		-- response field name, a different string for the same concept.
		SendFireplaceCommand("flame_height", height)
		TurnFlameOn()
	elseif (cmd == "SET_SCALE") then
		-- The setpoint here is a re-purposed 1-5 intensity dial, not a
		-- real temperature, so there's nothing to actually convert - just
		-- acknowledge whatever scale Navigator asked for.
		C4:SendToProxy(FIREPLACE_BINDING, "SCALE_CHANGED", { SCALE = p.SCALE or "FAHRENHEIT" }, "NOTIFY")
	else
		LOG("Unhandled fireplace proxy command: " .. tostring(cmd))
	end
end

function TurnFlameOn()
	SendFireplaceCommand("power", 1)
end

-- ===================== Driver commands / Composer actions ============================
--[[
	Composer dispatches <actions> as ExecuteCommand("LUA_ACTION", {ACTION=...}),
	NOT as the action's <command> string. Without the normalisation below, every
	action button in the Actions tab silently does nothing: strCommand is the
	literal "LUA_ACTION", matches none of the branches, and falls off the end.

	Confirmed on a live EA-1 with this project's Yale driver, which had the same
	defect - the Lua log showed only repeated "ExecuteCommand: LUA_ACTION" lines
	while nothing happened. This project's LIFX driver already normalises it the
	same way; IntelliFire, both Haiku drivers and Moen did not.

	<commands> (e.g. "Set Pilot") DO arrive under their own name, which is why
	the command worked while the four action buttons did not.
]]
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}

	if (strCommand == "LUA_ACTION") then
		if (tParams.ACTION ~= nil and tParams.ACTION ~= "") then
			strCommand = tostring(tParams.ACTION)
			tParams.ACTION = nil
		else
			LOG("LUA_ACTION received with no ACTION parameter - ignoring")
			return
		end
	end

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

	else
		LOG("Unhandled ExecuteCommand: '" .. tostring(strCommand) .. "'")
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

function Sha256Words(msg)
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

	return h0,h1,h2,h3,h4,h5,h6,h7
end

function Sha256Hex(msg)
	local h0,h1,h2,h3,h4,h5,h6,h7 = Sha256Words(msg)
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0,h1,h2,h3,h4,h5,h6,h7)
end

-- Raw 32-byte digest (not hex) - needed because the real IntelliFire
-- signing scheme nests SHA-256 (hashes the raw digest bytes of an inner
-- hash as input to an outer hash), confirmed against intellifire4py's
-- actual local_api.py source (see ComputeCommandSigning below).
function Sha256Raw(msg)
	local h0,h1,h2,h3,h4,h5,h6,h7 = Sha256Words(msg)
	local function w32(v)
		return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
		                   math.floor(v / 256) % 256, v % 256)
	end
	return w32(h0)..w32(h1)..w32(h2)..w32(h3)..w32(h4)..w32(h5)..w32(h6)..w32(h7)
end
