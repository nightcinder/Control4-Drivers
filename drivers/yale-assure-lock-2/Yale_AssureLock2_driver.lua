--[[==============================================================================
	Yale Assure Lock 2 (Wi-Fi Smart Module) - Control4 DriverWorks Driver
	Unofficial / community driver. Not affiliated with or supported by
	Yale, ASSA ABLOY, August Home, or Control4.

	================================================================================
	WHY THIS DRIVER IS CLOUD-BASED
	================================================================================
	The Assure Lock 2 Wi-Fi Smart Module does NOT expose a local LAN API. It
	maintains an outbound connection to the Yale Access (formerly August)
	cloud and is controlled exclusively through that cloud. There is no local
	HTTP/JSON endpoint to talk to, so - unlike this project's IntelliFire and
	Haiku drivers, which are LAN-local - this driver makes HTTPS calls out to
	the vendor cloud. Consequences you should understand before deploying:

	  * Lock/unlock latency depends on WAN + cloud round trip (typically
	    1-4 seconds, occasionally much worse).
	  * If your internet is down, the lock cannot be operated from Control4.
	  * The API used here is NOT a published, supported vendor API. It is the
	    private app API, documented only by community reverse engineering.
	    Yale can change or break it at any time without notice.

	================================================================================
	API REFERENCE USED
	================================================================================
	Endpoints, headers, auth flow and JSON field names in this driver were taken
	from the yalexs Python library, which is the de-facto reference client and
	the basis for the Home Assistant "August/Yale Access" integration:
	    https://github.com/Yale-Libs/yalexs
	Specifically yalexs/const.py, yalexs/api_common.py, yalexs/lock.py,
	yalexs/pin.py, yalexs/activity.py and yalexs/authenticator_common.py.

	Base URL:  https://api-production.august.com
	Required headers on every call:
	    x-august-api-key : d9984f29-07a6-816e-e1c9-44ec9d1be431
	    x-august-branding: "yale" (Yale Access account) or "august" (August account)
	    x-august-access-token: <JWT>      (once authenticated)
	    Accept-Version: 0.0.1             (4.0.0 for the activities endpoint)
	    Content-Type: application/json; charset=UTF-8
	    x-august-country: US

	Endpoints this driver uses (all confirmed in yalexs/api_common.py):
	    POST /session                        -> sign in, returns token in headers
	    POST /validation/email|phone         -> request 2FA code
	    POST /validate/email|phone           -> submit 2FA code
	    GET  /users/locks/mine               -> lock discovery
	    GET  /users/houses/mine              -> also used to refresh the token
	    GET  /locks/{lockId}                 -> full detail (battery, doorState, name)
	    GET  /locks/{lockId}/status          -> lightweight status poll
	    PUT  /remoteoperate/{lockId}/lock    -> lock
	    PUT  /remoteoperate/{lockId}/unlock  -> unlock
	    GET  /locks/{lockId}/pins            -> keypad PIN codes (READ ONLY, see below)
	    GET  /houses/{houseId}/activities    -> event history

	================================================================================
	KNOWN GAP - PIN CODE WRITES ARE NOT IMPLEMENTED
	================================================================================
	The Control4 lock proxy sends ADD_USER / EDIT_USER / DELETE_USER. There is
	NO confirmed endpoint in yalexs (or in any other reference client reviewed)
	for creating, editing or deleting a PIN on this API - only GET /locks/{id}/pins
	for reading them. Rather than guess at a request shape and fire unverified
	writes at a door lock, those three commands are deliberately stubbed: they
	log clearly and do nothing. REQUEST_USERS (read/list) is fully implemented.
	If you capture the app's real create/delete calls (e.g. with a proxy), the
	only place to fill in is AddUser()/EditUser()/DeleteUser() below - the proxy
	plumbing around them is already done.

	CORROBORATED: Cinegration's paid commercial driver for this same lock
	(yale_lock_cin.c4z, v20231003) also declares can_add_remove_user,
	can_edit_user and can_edit_user_pin all false. So this is not a gap in
	this driver's research - PIN writes appear to be genuinely unavailable on
	this API, and a shipping commercial product reached the same conclusion.
	Those three capability keys are now declared here too, which is the proper
	way to express it: Navigator hides the controls instead of showing buttons
	that quietly do nothing.

	================================================================================
	DRIVERWORKS APIs USED - all verified against Snap One's own published code
	================================================================================
	  C4:url()  chainable HTTP client. Verified against
	  snap-one/drivers-common-public/global/url.lua (urlDo):
	      local t = C4:url()
	      t:SetOptions({ fail_on_error = false, timeout = n })
	      t:OnDone(function (transfer, responses, errCode, errMsg) ... end)
	      t:Get(url, headers) / t:Post(url, data, headers)
	      t:Put(url, data, headers) / t:Delete(url, headers)
	  On success errCode == 0 and the result is in
	  responses[#responses].body / .code / .headers.
	  Requires Control4 OS 3.0.0+ (url.lua gates it on VersionCheck('3.0.0')).
	  An EA-1 on any shipping OS3 build meets this.

	  C4:SetTimer(delayMs, function (timer, skips) end, bRepeating) -> timer object
	  with :Cancel(). Verified against
	  snap-one/drivers-common-public/global/timer.lua (SetTimer/CancelTimer).

	  C4:SendToProxy(idBinding, sNotify, tParams, "NOTIFY") - same pattern already
	  in use in this project's Haiku and IntelliFire drivers.

	  Lock proxy commands / notifications / capability keys are taken from
	  https://snap-one.github.io/docs-driverworks-proxyprotocol-lock
	  Contact proxy notifications (OPENED/CLOSED) from
	  https://snap-one.github.io/docs-driverworks-proxyprotocol-contact

	CONNECTIONS - VERIFIED as of v101. The lock proxy docs publish no example
	connections block, so v100 guessed. Both Control4's own lock.c4i proxy
	definition and Cinegration's shipping yale_lock_cin.c4z declare the lock
	binding as id 5001 / facing 6 / TYPE 2 / classname LOCK. v100 had
	<type>1</type>, which was wrong; v101 corrects it and adds <hidden>True</hidden>.
	CONTACT_SENSOR / type 1 for DoorSense is documented in the contact proxy
	reference and is unchanged.

	JSON is parsed by the small pure-Lua decoder at the bottom of this file
	(no external module dependency; Control4 does not expose a global JSON
	library to standalone drivers). It was unit-tested against the real response
	shapes from the endpoints above before shipping.

	================================================================================
	FIRST-TIME SETUP (in Composer -> driver Properties/Actions)
	================================================================================
	  1. Set Brand, Login Method, Username, Password.
	  2. Run action "1 - Sign In / Request Verification Code".
	     Yale emails/texts you a 6-digit code.
	  3. Put that code in the "Verification Code" property, then run
	     "2 - Submit Verification Code".
	  4. Run "3 - Discover Locks". Copy the printed Lock ID into "Lock ID".
	  5. The driver starts polling automatically. Password can be blanked out
	     afterwards; the access token is what is persisted and reused.
================================================================================]]

-- ===================== Constants ============================
DRIVER_VERSION   = "117"

API_BASE         = "https://api-production.august.com"

--[[
	API KEYS - this is the single most fragile thing in the driver.

	The Yale Access API requires an x-august-api-key identifying the client
	application. These are not issued to individuals (developer.august.com is a
	paid partnership program), so community clients reuse the mobile app's key.
	Yale rotates and REVOKES them, and when that happens every request fails
	with HTTP 403 {"code":"Forbidden","message":"API key is not valid"} - which
	looks exactly like a bad password if you only read the status code.

	That is not hypothetical. v102 shipped d9984f29-... , taken from the current
	yalexs source, and it was already revoked. Probed live 2026-09-03 with a
	deliberately invalid account so no real credentials were involved:

	    d9984f29-07a6-816e-e1c9-44ec9d1be431 -> 403 "API key is not valid"
	    7cab4bbd-2693-4fc1-b99b-dec0fb20f9d4 -> 200   (yalexs calls this the OLD key)
	    66814fd9-af2c-426c-9710-b37e7eadfb51 -> 200   (yalexs yale_august brand key)

	So the driver no longer trusts a single hardcoded value. It carries the
	known keys in preference order and, on a 403 that names the API key,
	automatically advances to the next one and retries. The working key is
	persisted. If they are ALL revoked some day, set the "API Key" property
	manually to a current one and the rotation is bypassed.
]]
API_KEYS = {
	"7cab4bbd-2693-4fc1-b99b-dec0fb20f9d4",   -- verified accepted 2026-09-03
	"66814fd9-af2c-426c-9710-b37e7eadfb51",   -- verified accepted 2026-09-03
	"d9984f29-07a6-816e-e1c9-44ec9d1be431",   -- verified REVOKED  2026-09-03
}

HDR_API_KEY      = "x-august-api-key"
HDR_ACCESS_TOKEN = "x-august-access-token"
HDR_BRANDING     = "x-august-branding"
HDR_COUNTRY      = "x-august-country"

USER_AGENT       = "August/Luna-22.17.0 (Android; SDK 31; gphone64_arm64)"
ACCEPT_VERSION   = "0.0.1"
ACTIVITY_VERSION = "4.0.0"

LOCK_BINDING     = 5001
CONTACT_BINDING  = 300

HTTP_TIMEOUT     = 20      -- seconds, for ordinary reads

--[[
	Remote lock/unlock is NOT a fast call. The cloud has to wake the lock's
	Wi-Fi radio, actuate the bolt and wait for it to report back. v104 used the
	same 20s timeout as a read and failed live with

	    PUT /remoteoperate/{id}/lock -> code=0 err=Error 28: Timeout was reached

	(cURL 28 = operation timed out). yalexs has async variants of these
	endpoints precisely because the synchronous ones are slow, so the driver
	now uses them: the request returns as soon as the command is accepted and
	the resulting state is picked up by the status reads scheduled afterwards.
	The longer timeout below is the backstop for the accept itself.
]]
OPERATE_TIMEOUT  = 60      -- seconds, for /remoteoperate
OPERATE_QUERY    = "?v=2.3.1&type=async"   -- yalexs API_LOCK_ASYNC_URL / API_UNLOCK_ASYNC_URL

-- After firing a command, re-read status on this ladder (ms). Async means the
-- bolt is still moving when the HTTP call returns, so one read is not enough.
OPERATE_SETTLE_MS = { 3000, 8000, 15000, 25000 }

--[[
	TRANSITIONAL RE-READ CAP (v110).

	A status of kAugLockState_Locking / _Unlocking / _Unlatching means the bolt
	is mid-travel, so the driver re-reads in 4s rather than publishing a
	half-state. That re-read is itself a status read, so if the cloud keeps
	reporting a transitional status the chain re-arms itself forever: a 4-second
	poll loop against the Yale API with nothing to stop it. Measured steady-state
	traffic is 1 request/min; an unbroken transitional chain would be 15/min
	indefinitely.

	Cap the chain. After this many consecutive transitional reads, give up, log
	it, and let the ordinary poll interval take over - a lock that has been
	"locking" for half a minute is stuck, not busy, and hammering the API will
	not unstick it. The counter resets the moment a non-transitional status
	arrives.
]]
MAX_TRANSITIONAL_READS = 6
TRANSITIONAL_RETRY_MS  = 4000

--[[
	IN-FLIGHT GUARD (v110).

	Status reads arrive from four independent sources - the poll timer, the
	settle ladder, the transitional re-read, and the manual refresh action -
	and nothing stopped them overlapping. Overlapping reads waste requests and
	can apply an older response after a newer one. Only one status read is in
	flight at a time; the guard self-clears if a callback is ever lost so a
	dropped response cannot wedge polling permanently.
]]
STATUS_INFLIGHT_MAX_MS = 45000

--[[
	UNREACHABLE IS NOT A LOCK STATE (v112).

	A Wi-Fi lock sleeps its radio, and while it sleeps the cloud answers
	{"status":"unknown"}. v106-v111 mapped that to "unknown" and published it
	straight to the lock proxy, so a perfectly healthy lock flapped

	    LOCK_STATUS_CHANGED -> unknown        (radio asleep)
	    LOCK_STATUS_CHANGED -> locked         (a few seconds later, after wakeup)

	every time it dozed. Navigator renders that flap, and a lock tile sitting in
	Unknown is not a tile anyone trusts or can operate confidently.

	"The cloud cannot reach the lock right now" is a statement about the
	CONNECTION, not about the bolt. The bolt has not moved. So the driver now
	holds the last known lock state and reports the connection instead, via
	ONLINE_CHANGED - which is exactly what that notification is for. Only if the
	lock stays unreachable across this many consecutive reads does the driver
	admit it genuinely does not know.
]]
MAX_UNREACHABLE_READS = 5

--[[
	WAKEUP. A Wi-Fi lock sleeps its radio to save battery, and while it is
	asleep the cloud has no fresh state and returns a literal

	    {"status":"unknown"}

	That is a real, expected value - not an unmapped vocabulary string - and it
	is what this lock returned on a cold poll. yalexs handles it with

	    /remoteoperate/{lock_id}/status?v=2.3.1&type=async&intent=wakeup

	which asks the cloud to wake the lock and refresh. The driver now fires that
	when it sees "unknown", then re-reads. Rate limited, because waking the
	radio costs battery and there is no point doing it on every poll of a lock
	that is genuinely unreachable.
]]
WAKEUP_QUERY     = "?v=2.3.1&type=async&intent=wakeup"
WAKEUP_MIN_GAP_MS = 5 * 60 * 1000   -- at most one wakeup per 5 minutes
g_lastWakeupMs   = nil

-- Battery thresholds. The API reports `battery` as a float 0.0-1.0.
-- These map onto the proxy's three-state BATTERY_STATUS.
BATTERY_WARNING_PCT  = 40
BATTERY_CRITICAL_PCT = 15

-- Token is refreshed on this cadence by re-calling GET /users/houses/mine,
-- which returns a fresh JWT in the response headers (yalexs does the same).
TOKEN_REFRESH_MS = 12 * 60 * 60 * 1000   -- 12 hours

-- ===================== Runtime state ============================
g_brand        = "Yale Access"
g_loginMethod  = "email"
g_username     = ""
g_password     = ""
g_vcode        = ""
g_lockId       = ""
g_houseId      = ""
g_pollInt      = 60
g_historyLimit = 20
g_logMode      = "Off"
g_apiKeyProp   = ""      -- manual override; blank means use the rotation above
g_apiKeyIndex  = 1

g_installId    = nil
g_token        = nil
g_tokenExpires = nil
g_authState    = "Not signed in"

g_lockStatus   = "unknown"   -- proxy vocabulary: unknown|locked|unlocked|fault
g_doorState    = "unknown"   -- closed|open|disabled|unknown
g_batteryPct   = nil
g_batteryState = nil
g_hasDoorsense = false
g_online       = false

--[[
	The driver only notifies the proxy when state CHANGES. That is efficient but
	fragile: if a notification is lost - most plausibly the first one after a
	Director restart, sent before the proxy is ready to receive it - the driver
	believes it has already reported "locked" and never says so again, so the
	proxy can sit on "unknown" indefinitely while the driver is perfectly
	healthy. Re-asserting the current state every N polls makes that self-heal.
]]
STATE_REASSERT_EVERY = 10
g_pollCount    = 0
g_forceReassert = false

g_pollTimer    = nil
g_transitionalReads = 0
g_unreachableReads  = 0
g_statusInFlight    = false
g_statusInFlightAt  = 0
g_tokenTimer   = nil
g_settleTimer  = nil

-- ===================== Logging ============================
function LOG(msg)
	local s = "[YaleLock2] " .. tostring(msg)
	if (g_logMode == "Print" or g_logMode == "Print and Log") then print(s) end
	if (g_logMode == "Log" or g_logMode == "Print and Log") then C4:DebugLog(s) end
end

-- Never let a credential reach the log.
function Redact(s)
	if (s == nil or s == "") then return "<empty>" end
	return "<" .. tostring(#tostring(s)) .. " chars>"
end

-- ===================== Driver lifecycle ============================
function OnDriverInit()
	LoadProperties()
	LoadPersisted()
end

function OnDriverLateInit()
	LoadProperties()
	LoadPersisted()
	LOG("Driver v" .. DRIVER_VERSION .. " late init. Auth state: " .. g_authState)

	PublishCapabilities()
	NotifyOnline(false)

	if (HaveToken()) then
		-- The token survived the restart, so the driver IS signed in. Say so:
		-- g_authState is only set by the sign-in flow, so after a Director
		-- restart it kept its "Not signed in" initial value and PrintDebug
		-- reported that while the driver was happily polling with a valid
		-- token - a diagnostic that lies about a working driver is worse than
		-- no diagnostic.
		UpdateAuthState("Authenticated")
		StartPolling()
		StartTokenRefresh()
	else
		UpdateAuthState("Not signed in - run action 1")
	end
end

function OnDriverDestroyed()
	StopPolling()
	if (g_tokenTimer ~= nil) then pcall(function() g_tokenTimer:Cancel() end); g_tokenTimer = nil end
	if (g_settleTimer ~= nil) then pcall(function() g_settleTimer:Cancel() end); g_settleTimer = nil end
	CancelSettleLadder()
end

function LoadProperties()
	g_brand        = Properties["Brand"] or g_brand
	g_loginMethod  = string.lower(Properties["Login Method"] or g_loginMethod)
	g_username     = Properties["Username"] or ""
	g_password     = Properties["Password"] or ""
	g_vcode        = Properties["Verification Code"] or ""
	g_lockId       = Properties["Lock ID"] or ""
	g_houseId      = Properties["House ID"] or ""
	g_pollInt      = tonumber(Properties["Poll Interval (seconds)"]) or 60
	g_historyLimit = tonumber(Properties["History Items"]) or 20
	g_logMode      = Properties["Log Mode"] or "Off"
	g_apiKeyProp   = TrimStr(Properties["API Key"] or "")

	if (g_pollInt < 15) then g_pollInt = 15 end        -- don't hammer the cloud
	if (g_historyLimit < 1) then g_historyLimit = 1 end
	if (g_historyLimit > 100) then g_historyLimit = 100 end
end

function OnPropertyChanged(strProperty)
	LoadProperties()
	LOG("Property changed: " .. tostring(strProperty))

	if (strProperty == "Poll Interval (seconds)") then
		if (HaveToken()) then StartPolling() end
	elseif (strProperty == "Lock ID") then
		g_lockStatus = "unknown"
		if (HaveToken() and g_lockId ~= "") then
			StartPolling()
			RefreshDetail()
		end
	end
end

-- ===================== Persisted values ============================
-- Access token / install id survive driver restarts so the 2FA dance is a
-- one-time cost. C4:PersistSetValue is wrapped in pcall throughout: if it is
-- unavailable on some OS build the driver still runs, it just re-prompts for
-- sign-in after a restart rather than silently erroring.
function PersistSet(key, value)
	local ok, err = pcall(function() C4:PersistSetValue(key, value) end)
	if (not ok) then LOG("PersistSetValue('" .. key .. "') failed: " .. tostring(err)) end
end

function PersistGet(key)
	local ok, val = pcall(function() return C4:PersistGetValue(key) end)
	if (ok) then return val end
	return nil
end

function LoadPersisted()
	local ki = tonumber(PersistGet("api_key_index"))
	if (ki ~= nil and ki >= 1 and ki <= #API_KEYS) then g_apiKeyIndex = ki end
	g_installId    = PersistGet("install_id")
	g_token        = PersistGet("access_token")
	g_tokenExpires = PersistGet("token_expires")
	if (g_houseId == "" or g_houseId == nil) then
		g_houseId = PersistGet("house_id") or ""
	end
	if (g_installId == nil or g_installId == "") then
		g_installId = NewInstallId()
		PersistSet("install_id", g_installId)
	end
end

function HaveToken()
	return (g_token ~= nil and g_token ~= "")
end

-- The API only requires installId to be a stable opaque string per client.
-- yalexs uses uuid4; this generates the same shape.
function NewInstallId()
	local seed = os.time()
	local okT, t = pcall(function() return C4:GetTime() end)
	if (okT and type(t) == "number") then seed = seed + (t % 1000000) end
	math.randomseed(seed)
	local tmpl = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return (string.gsub(tmpl, "[xy]", function(c)
		local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
		return string.format("%x", v)
	end))
end

function UpdateAuthState(s)
	g_authState = s
	pcall(function() C4:UpdateProperty("Auth State", s) end)
	LOG("Auth state: " .. s)
end

-- ===================== HTTP layer ============================
function BrandingValue()
	-- yalexs/const.py: Brand.YALE_ACCESS -> branding "yale"; Brand.AUGUST -> "august".
	-- Both share the same base URL, api key and header names.
	if (g_brand == "August") then return "august" end
	return "yale"
end

-- A non-empty "API Key" property pins the key and disables rotation.
function CurrentApiKey()
	if (g_apiKeyProp ~= nil and g_apiKeyProp ~= "") then return g_apiKeyProp end
	return API_KEYS[g_apiKeyIndex] or API_KEYS[1]
end

function BuildHeaders(bAuth, sAcceptVersion)
	local h = {
		[HDR_API_KEY]   = CurrentApiKey(),
		[HDR_BRANDING]  = BrandingValue(),
		[HDR_COUNTRY]   = "US",
		["Accept-Version"] = sAcceptVersion or ACCEPT_VERSION,
		["Content-Type"]   = "application/json; charset=UTF-8",
		["User-Agent"]     = USER_AGENT,
		["Accept"]         = "application/json",
	}
	if (bAuth ~= false and HaveToken()) then
		h[HDR_ACCESS_TOKEN] = g_token
	end
	return h
end

function HeaderValue(tHeaders, sName)
	if (type(tHeaders) ~= "table") then return nil end
	local want = string.lower(sName)
	for k, v in pairs(tHeaders) do
		if (type(k) == "string" and string.lower(k) == want) then return v end
	end
	return nil
end

--[[ ApiRequest
	method   "GET"|"POST"|"PUT"|"DELETE"
	path     e.g. "/locks/ABC/status" (appended to API_BASE) or a full URL
	tBody    table -> encoded as JSON, or nil
	fDone    function(bOk, nCode, tHeaders, tJson, sRaw, sErr)
	tOpt     { auth = false, acceptVersion = "4.0.0" }
]]
function ApiRequest(method, path, tBody, fDone, tOpt)
	tOpt = tOpt or {}
	local url = path
	if (string.sub(path, 1, 4) ~= "http") then url = API_BASE .. path end

	local headers = BuildHeaders(tOpt.auth, tOpt.acceptVersion)
	local data = ""
	if (tBody ~= nil) then data = JsonEncode(tBody) end

	LOG("HTTP " .. method .. " " .. url .. ((tBody ~= nil) and (" body=" .. SafeBodyForLog(tBody)) or ""))

	local okCreate, err = pcall(function()
		local t = C4:url()
		t:SetOptions({ fail_on_error = false, timeout = (tOpt.timeout or HTTP_TIMEOUT) })
		t:OnDone(function(transfer, responses, errCode, errMsg)
			local code, rHeaders, rBody = 0, {}, ""
			if (errCode == 0 and type(responses) == "table" and #responses > 0) then
				local last = responses[#responses]
				code     = last.code or 0
				rHeaders = last.headers or {}
				rBody    = last.body or ""
			end

			local sErr = errMsg
			if (errCode ~= 0 and sErr == nil) then sErr = "transfer error " .. tostring(errCode) end

			local tJson = nil
			if (rBody ~= nil and rBody ~= "") then
				local okJ, parsed = pcall(JsonDecode, rBody)
				if (okJ) then tJson = parsed end
			end

			local bOk = (sErr == nil and code >= 200 and code < 300)

			-- The API returns a JSON error envelope, e.g.
			--   {"code":"Forbidden","message":"API key is not valid"}
			-- v102 logged only the status code, which made a revoked API key
			-- indistinguishable from a bad password. Always surface the message.
			local sApiMsg = nil
			if (type(tJson) == "table" and type(tJson.message) == "string") then
				sApiMsg = tJson.message
			end

			LOG("HTTP <- " .. method .. " " .. url .. " code=" .. tostring(code) ..
			    (sApiMsg and (" msg=\"" .. sApiMsg .. "\"") or "") ..
			    (sErr and (" err=" .. tostring(sErr)) or ""))

			-- Revoked/invalid API key: rotate to the next known key and retry the
			-- same request once per key. Only when the key is not pinned by the
			-- "API Key" property.
			local bKeyRejected = (sErr == nil and code == 403 and sApiMsg ~= nil and
			                      string.find(string.lower(sApiMsg), "api key", 1, true) ~= nil)
			if (bKeyRejected and (g_apiKeyProp == nil or g_apiKeyProp == "")) then
				local nAttempt = (tOpt.attempt or 1)
				if (nAttempt < #API_KEYS) then
					local nNext = (g_apiKeyIndex % #API_KEYS) + 1
					LOG("API key rejected (\"" .. sApiMsg .. "\"); rotating key " ..
					    tostring(g_apiKeyIndex) .. " -> " .. tostring(nNext) .. " and retrying")
					g_apiKeyIndex = nNext
					PersistSet("api_key_index", tostring(nNext))
					local tRetry = {}
					for k, v in pairs(tOpt) do tRetry[k] = v end
					tRetry.attempt = nAttempt + 1
					ApiRequest(method, path, tBody, fDone, tRetry)
					return
				end
				UpdateAuthState("All known API keys rejected - set the API Key property")
				LOG("Every key in API_KEYS was rejected. Yale has rotated them again; " ..
				    "find a current x-august-api-key and put it in the API Key property.")
			end

			-- Only a request that actually CARRIED a token can have its token
			-- rejected. v102 fired this on the unauthenticated /session call too,
			-- producing a misleading "Token rejected" line before the real one.
			local bWasAuthed = (tOpt.auth ~= false and HaveToken())
			if (sErr == nil and bWasAuthed and (code == 401 or code == 403)) then
				UpdateAuthState("Token rejected (" .. tostring(code) .. ") - re-run action 1")
			end

			NotifyOnline(sErr == nil and code ~= 0)

			if (fDone ~= nil) then
				local okCb, cbErr = pcall(fDone, bOk, code, rHeaders, tJson, rBody, sErr)
				if (not okCb) then LOG("Response handler error: " .. tostring(cbErr)) end
			end
		end)

		if (method == "GET") then
			t:Get(url, headers)
		elseif (method == "POST") then
			t:Post(url, data, headers)
		elseif (method == "PUT") then
			t:Put(url, data, headers)
		elseif (method == "DELETE") then
			t:Delete(url, headers)
		else
			t:Custom(url, method, data, headers)
		end
	end)

	if (not okCreate) then
		LOG("C4:url() call failed: " .. tostring(err))
		if (fDone ~= nil) then pcall(fDone, false, 0, {}, nil, "", tostring(err)) end
	end
end

function SafeBodyForLog(tBody)
	local copy = {}
	for k, v in pairs(tBody) do
		if (k == "password" or k == "code") then
			copy[k] = Redact(v)
		else
			copy[k] = v
		end
	end
	return JsonEncode(copy)
end

-- ===================== Authentication ============================
-- Flow (yalexs/authenticator_async.py):
--   POST /session {installId, identifier, password}
--     identifier == "<email|phone>:<username>"
--     response headers carry x-august-access-token
--     body: { expiresAt, vPassword, vInstallId }
--       vPassword == false -> wrong password
--       vInstallId == false -> this installId is not yet validated; send a
--                              2FA code and validate it, then call /session again
function ActionSignIn()
	LoadProperties()
	if (g_username == "" or g_password == "") then
		LOG("Username and Password must both be set before signing in.")
		UpdateAuthState("Username/Password missing")
		return
	end
	if (g_installId == nil or g_installId == "") then
		g_installId = NewInstallId()
		PersistSet("install_id", g_installId)
	end

	UpdateAuthState("Signing in...")
	local body = {
		installId  = g_installId,
		identifier = g_loginMethod .. ":" .. g_username,
		password   = g_password,
	}

	ApiRequest("POST", "/session", body, function(bOk, code, headers, tJson, raw, sErr)
		if (sErr ~= nil) then
			UpdateAuthState("Sign-in failed: " .. tostring(sErr))
			return
		end
		if (code == 401 or code == 403) then
			local msg = (type(tJson) == "table" and tJson.message) or nil
			if (msg ~= nil) then
				UpdateAuthState("Sign-in rejected (" .. tostring(code) .. "): " .. tostring(msg))
			else
				UpdateAuthState("Sign-in rejected (" .. tostring(code) .. ") - check username/password")
			end
			return
		end
		if (not bOk or type(tJson) ~= "table") then
			UpdateAuthState("Sign-in failed, HTTP " .. tostring(code))
			return
		end

		local tok = HeaderValue(headers, HDR_ACCESS_TOKEN) or HeaderValue(headers, "x-access-token")
		if (tok ~= nil and tok ~= "") then
			g_token = tok
			PersistSet("access_token", tok)
		end
		if (tJson.expiresAt ~= nil) then
			g_tokenExpires = tostring(tJson.expiresAt)
			PersistSet("token_expires", g_tokenExpires)
			pcall(function() C4:UpdateProperty("Token Expires", g_tokenExpires) end)
		end

		if (tJson.vPassword == false) then
			UpdateAuthState("Bad password")
			return
		end

		if (tJson.vInstallId == false) then
			UpdateAuthState("Verification required - sending code")
			SendVerificationCode()
			return
		end

		UpdateAuthState("Authenticated")

		-- The password is only ever needed for this /session call. From here on
		-- the driver uses the persisted JWT and refreshes it against
		-- /users/houses/mine. Leaving the plaintext password sitting in a driver
		-- property means it also lands in every project backup, so clear it.
		-- Re-enter it only if you need to sign in again from scratch.
		if (Properties["Password"] ~= nil and Properties["Password"] ~= "") then
			pcall(function() C4:UpdateProperty("Password", "") end)
			g_password = ""
			LOG("Sign-in succeeded - Password property cleared. The stored token " ..
			    "is used from now on; re-enter the password only to sign in again.")
		end

		OnAuthenticated()
	end, { auth = false })
end

function SendVerificationCode()
	local path = "/validation/" .. g_loginMethod
	local body
	if (g_loginMethod == "phone") then
		-- smsHashString is a fixed constant in yalexs used for Android SMS autofill.
		body = { smsHashString = "anY0ZsRmXw+", value = g_username }
	else
		body = { value = g_username }
	end

	ApiRequest("POST", path, body, function(bOk, code, headers, tJson, raw, sErr)
		if (bOk) then
			UpdateAuthState("Code sent to " .. g_loginMethod .. " - enter it, then run action 2")
		else
			UpdateAuthState("Failed to send code (HTTP " .. tostring(code) .. ")")
		end
	end)
end

function ActionSubmitCode()
	LoadProperties()
	if (g_vcode == "") then
		LOG("Verification Code property is empty.")
		return
	end
	local path = "/validate/" .. g_loginMethod
	local body = { [g_loginMethod] = g_username, code = tostring(g_vcode) }

	UpdateAuthState("Validating code...")
	ApiRequest("POST", path, body, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk) then
			UpdateAuthState("Code rejected (HTTP " .. tostring(code) .. ")")
			return
		end
		-- Clear the one-time code out of the project so it isn't left lying around.
		pcall(function() C4:UpdateProperty("Verification Code", "") end)
		g_vcode = ""
		-- Re-run /session; installId is now validated so this returns the real token.
		ActionSignIn()
	end)
end

function OnAuthenticated()
	StartTokenRefresh()
	if (g_lockId == "") then
		ActionDiscoverLocks()
	else
		StartPolling()
		RefreshDetail()
	end
end

-- GET /users/houses/mine returns a fresh JWT in the response headers.
function RefreshAccessToken()
	if (not HaveToken()) then return end
	ApiRequest("GET", "/users/houses/mine", nil, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk) then
			LOG("Token refresh failed, HTTP " .. tostring(code))
			return
		end
		local tok = HeaderValue(headers, HDR_ACCESS_TOKEN) or HeaderValue(headers, "x-access-token")
		if (tok ~= nil and tok ~= "" and tok ~= g_token) then
			g_token = tok
			PersistSet("access_token", tok)
			LOG("Access token refreshed")
		end
		-- Opportunistically learn the house id, needed for history.
		if (g_houseId == "" and type(tJson) == "table") then
			local h = tJson[1]
			if (type(h) == "table") then
				local hid = h.HouseID or h.houseID or h.houseId
				if (hid ~= nil) then
					g_houseId = tostring(hid)
					PersistSet("house_id", g_houseId)
					pcall(function() C4:UpdateProperty("House ID", g_houseId) end)
				end
			end
		end
	end)
end

function StartTokenRefresh()
	if (g_tokenTimer ~= nil) then pcall(function() g_tokenTimer:Cancel() end) end
	local ok, t = pcall(function()
		return C4:SetTimer(TOKEN_REFRESH_MS, function(timer, skips) RefreshAccessToken() end, true)
	end)
	if (ok) then g_tokenTimer = t else LOG("Token refresh timer failed: " .. tostring(t)) end
end

function ActionClearCredentials()
	g_token, g_tokenExpires = nil, nil
	PersistSet("access_token", "")
	PersistSet("token_expires", "")
	StopPolling()
	UpdateAuthState("Cleared - run action 1")
	pcall(function() C4:UpdateProperty("Token Expires", "") end)
end

-- ===================== Discovery ============================
function ActionDiscoverLocks()
	if (not HaveToken()) then
		LOG("Not authenticated; run action 1 first.")
		return
	end
	ApiRequest("GET", "/users/locks/mine", nil, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk or type(tJson) ~= "table") then
			LOG("Lock discovery failed, HTTP " .. tostring(code))
			return
		end
		-- Response is a map of lockId -> { LockName, HouseID, UserType, ... }
		local lines, firstId, count = {}, nil, 0
		for id, info in pairs(tJson) do
			if (type(info) == "table") then
				count = count + 1
				local nm = tostring(info.LockName or "?")
				local hid = tostring(info.HouseID or "")
				table.insert(lines, nm .. "  |  " .. tostring(id) .. "  |  house " .. hid)
				if (firstId == nil) then
					firstId = tostring(id)
					if (hid ~= "") then
						g_houseId = hid
						PersistSet("house_id", hid)
						pcall(function() C4:UpdateProperty("House ID", hid) end)
					end
				end
			end
		end

		table.sort(lines)
		local summary = table.concat(lines, "\n")
		-- If a lock was already configured, discovery must not leave polling off.
		EnsurePolling()
		LOG("Discovered " .. count .. " lock(s):\n" .. summary)
		print("=== Yale Assure Lock 2 - discovered locks ===")
		print(summary)
		pcall(function() C4:UpdateProperty("Discovered Locks", summary) end)

		-- Auto-select when there is exactly one lock on the account.
		if (count == 1 and g_lockId == "" and firstId ~= nil) then
			g_lockId = firstId
			pcall(function() C4:UpdateProperty("Lock ID", firstId) end)
			LOG("Auto-selected the only lock on this account: " .. firstId)
			--[[
				DO NOT remove the StartPolling() below "because OnPropertyChanged
				will handle it". It will not.

				C4:UpdateProperty() updates the property but does NOT invoke
				OnPropertyChanged - that callback fires only when a human edits
				the property in Composer. v101 removed these two calls as a
				redundant-looking cleanup, and the result was that a freshly
				authenticated driver auto-selected its lock and then never polled
				at all: no status, no battery, no lock name, Lock stuck on
				"Unknown" forever. Confirmed live - the log after auto-select
				showed no "Property changed: Lock ID" line and no subsequent
				GET /locks/... request.
			]]
			StartPolling()
		end
	end)
end

-- ===================== Status polling ============================
-- Idempotent: starts the poll loop if it should be running and isn't.
-- Cheap to call from anywhere that might have just made polling possible.
function EnsurePolling()
	if (not HaveToken()) then return end
	if (g_lockId == nil or g_lockId == "") then return end
	if (g_pollTimer ~= nil) then return end
	LOG("Polling was not running but should be - starting it")
	StartPolling()
end

function StartPolling()
	StopPolling()
	if (g_lockId == "" or not HaveToken()) then return end
	local ok, t = pcall(function()
		return C4:SetTimer(g_pollInt * 1000, function(timer, skips) RefreshStatus() end, true)
	end)
	if (ok) then g_pollTimer = t else LOG("Poll timer failed: " .. tostring(t)) end
	RefreshDetail()
end

function StopPolling()
	if (g_pollTimer ~= nil) then
		pcall(function() g_pollTimer:Cancel() end)
		g_pollTimer = nil
	end
end

-- Lightweight poll: GET /locks/{id}/status -> { status, doorState, ... }

-- Milliseconds from the Director clock, falling back to os.time() seconds.
function NowMs()
	local ok, t = pcall(function() return C4:GetTime() end)
	if (ok and type(t) == "number") then return t end
	return os.time() * 1000
end

function RefreshStatus()
	if (g_lockId == "" or not HaveToken()) then return end

	-- One status read at a time. The guard expires so a lost callback cannot
	-- wedge polling for the life of the driver.
	if (g_statusInFlight) then
		if ((NowMs() - g_statusInFlightAt) < STATUS_INFLIGHT_MAX_MS) then
			LOG("Status read already in flight - skipping this one")
			return
		end
		LOG("Previous status read never completed - clearing the in-flight guard")
	end
	g_statusInFlight   = true
	g_statusInFlightAt = NowMs()

	g_pollCount = g_pollCount + 1
	if ((g_pollCount % STATE_REASSERT_EVERY) == 0) then
		g_forceReassert = true
	end
	ApiRequest("GET", "/locks/" .. g_lockId .. "/status", nil, function(bOk, code, headers, tJson, raw, sErr)
		g_statusInFlight = false
		if (not bOk or type(tJson) ~= "table") then
			if (bOk) then LOG("Status read returned unparseable body: " .. tostring(raw)) end
			return
		end
		if (tJson.status == nil) then
			LOG("Status read had no 'status' field. Raw body: " .. tostring(raw))
		end
		ApplyStatusJson(tJson, nil, nil)
	end)
end

-- Full detail: GET /locks/{id} -> battery, LockStatus{status,doorState}, name, firmware
function RefreshDetail()
	if (g_lockId == "" or not HaveToken()) then return end
	ApiRequest("GET", "/locks/" .. g_lockId, nil, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk or type(tJson) ~= "table") then return end

		if (tJson.LockName ~= nil) then
			pcall(function() C4:UpdateProperty("Lock Name", tostring(tJson.LockName)) end)
		end
		if (tJson.currentFirmwareVersion ~= nil) then
			pcall(function() C4:UpdateProperty("Firmware Version", tostring(tJson.currentFirmwareVersion)) end)
		end
		if (tJson.HouseID ~= nil and g_houseId == "") then
			g_houseId = tostring(tJson.HouseID)
			PersistSet("house_id", g_houseId)
			pcall(function() C4:UpdateProperty("House ID", g_houseId) end)
		end
		if (type(tJson.battery) == "number") then
			ApplyBattery(tJson.battery)
		end
		if (type(tJson.LockStatus) == "table") then
			ApplyStatusJson(tJson.LockStatus, nil, nil)
		end
	end)
end

-- status/doorState string vocabularies are lifted verbatim from yalexs/lock.py.
LOCKED_STATUS = {
	["lock"] = true, ["locked"] = true, ["secure"] = true, ["securemode"] = true,
	["kAugLockState_Locked"] = true, ["kAugLockState_SecureMode"] = true,
}
UNLOCKED_STATUS = {
	["unlock"] = true, ["unlocked"] = true, ["kAugLockState_Unlocked"] = true,
	["unlatched"] = true, ["kAugLockState_Unlatched"] = true,
}
TRANSITIONAL_STATUS = {
	["kAugLockState_Locking"] = true, ["kAugLockState_Unlocking"] = true,
	["kAugLockState_Unlatching"] = true,
}
JAMMED_STATUS = {
	["kAugLockState_UnknownStaticPosition"] = true,
	["FAILED_BRIDGE_ERROR_LOCK_JAMMED"] = true,
}
CLOSED_STATUS = { ["closed"] = true, ["kAugLockDoorState_Closed"] = true, ["kAugDoorState_Closed"] = true }
OPEN_STATUS   = { ["open"] = true, ["kAugLockDoorState_Open"] = true, ["kAugDoorState_Open"] = true }
DISABLED_STATUS = { ["init"] = true, ["kAugDoorState_Init"] = true, [""] = true }

function MapLockStatus(s)
	if (s == nil) then return "unknown" end
	if (LOCKED_STATUS[s]) then return "locked" end
	if (UNLOCKED_STATUS[s]) then return "unlocked" end
	if (JAMMED_STATUS[s]) then return "fault" end
	if (TRANSITIONAL_STATUS[s]) then return "transitional" end
	return "unknown"
end

function MapDoorState(s)
	if (s == nil) then return "unknown" end
	if (CLOSED_STATUS[s]) then return "closed" end
	if (OPEN_STATUS[s]) then return "open" end
	if (DISABLED_STATUS[s]) then return "disabled" end
	return "unknown"
end

function ApplyStatusJson(t, sDescription, sSource)
	local rawLock = t.status
	local rawDoor = t.doorState

	local mapped = MapLockStatus(rawLock)
	local bUnreachable = false
	if (mapped == "unknown") then
		if (rawLock == nil or rawLock == "" or rawLock == "unknown") then
			-- The lock's radio is asleep or unreachable, so the cloud has no
			-- current state. This says nothing about where the bolt is.
			bUnreachable = true
			g_unreachableReads = g_unreachableReads + 1
			LOG("Lock is unreachable (status=" .. tostring(rawLock) .. ") - read " ..
			    tostring(g_unreachableReads) .. "/" .. tostring(MAX_UNREACHABLE_READS) ..
			    "; requesting a wakeup and holding the last known state (" ..
			    tostring(g_lockStatus) .. ")")
			NotifyOnline(false)
			RequestWakeup()
			if (g_unreachableReads < MAX_UNREACHABLE_READS) then
				-- Hold the last known lock state; do not publish "unknown".
				-- DoorSense is equally unknowable right now, so leave it too.
				return
			end
			LOG("Lock has been unreachable for " .. tostring(MAX_UNREACHABLE_READS) ..
			    " consecutive reads - reporting Unknown to the proxy")
		else
			-- A string the yalexs-derived vocabularies do not cover. Name it, so
			-- the tables can actually be extended.
			LOG("Unrecognised lock status from API: '" .. tostring(rawLock) ..
			    "' (doorState=" .. tostring(rawDoor) .. "). If this is a real state, " ..
			    "add it to LOCKED_STATUS / UNLOCKED_STATUS / TRANSITIONAL_STATUS.")
		end
	end
	if (mapped == "transitional") then
		-- Lock is mid-travel. Don't publish a half-state; re-read shortly - but
		-- only so many times, or the chain becomes a self-sustaining 4s poll.
		g_transitionalReads = g_transitionalReads + 1
		if (g_transitionalReads > MAX_TRANSITIONAL_READS) then
			LOG("Lock has reported a transitional status (" .. tostring(rawLock) .. ") for " ..
			    tostring(MAX_TRANSITIONAL_READS) .. " consecutive reads - it is stuck, not busy. " ..
			    "Backing off to the normal " .. tostring(g_pollInt) .. "s poll.")
			-- Deliberately NOT reset here. Zeroing the counter would let the
			-- next ordinary poll start a fresh chain, so a permanently stuck
			-- lock would re-arm six reads every poll interval for ever. The
			-- counter is cleared only by a status that has actually settled.
		else
			LOG("Lock is transitional (" .. tostring(rawLock) .. "), re-reading in " ..
			    tostring(TRANSITIONAL_RETRY_MS / 1000) .. "s (" ..
			    tostring(g_transitionalReads) .. "/" .. tostring(MAX_TRANSITIONAL_READS) .. ")")
			ScheduleSettleRead(TRANSITIONAL_RETRY_MS)
		end
	elseif (mapped ~= g_lockStatus or g_forceReassert) then
		if (mapped == g_lockStatus) then
			LOG("Re-asserting lock state to the proxy: " .. tostring(mapped))
		end
		g_lockStatus = mapped
		NotifyLockStatus(mapped, sDescription, sSource)
	end

	if (mapped ~= "transitional") then g_transitionalReads = 0 end
	if (not bUnreachable) then
		if (g_unreachableReads > 0) then
			LOG("Lock is reachable again after " .. tostring(g_unreachableReads) .. " unreachable read(s)")
		end
		g_unreachableReads = 0
		NotifyOnline(true)
	end

	local bWasReassert = g_forceReassert
	if (rawDoor ~= nil) then
		local d = MapDoorState(rawDoor)
		if (d ~= "disabled" and d ~= "unknown") then g_hasDoorsense = true end
		local bChanged = (d ~= g_doorState)
		if (bChanged or g_forceReassert) then
			g_doorState = d
			NotifyDoorState(d, (not bChanged))
		end
	end
	if (bWasReassert) then g_forceReassert = false end
end

function ScheduleSettleRead(ms)
	if (g_settleTimer ~= nil) then pcall(function() g_settleTimer:Cancel() end) end
	local ok, t = pcall(function()
		return C4:SetTimer(ms, function(timer, skips) RefreshStatus() end, false)
	end)
	if (ok) then g_settleTimer = t end
end

function ApplyBattery(fBattery)
	local pct = math.floor((fBattery * 100) + 0.5)
	if (pct < 0) then pct = 0 end
	if (pct > 100) then pct = 100 end
	g_batteryPct = pct
	pcall(function() C4:UpdateProperty("Battery Level", tostring(pct) .. "%") end)

	local state = "normal"
	if (pct <= BATTERY_CRITICAL_PCT) then
		state = "critical"
	elseif (pct <= BATTERY_WARNING_PCT) then
		state = "warning"
	end

	if (state ~= g_batteryState or g_forceReassert) then
		g_batteryState = state
		C4:SendToProxy(LOCK_BINDING, "BATTERY_STATUS_CHANGED", { BATTERY_STATUS = state }, "NOTIFY")
		LOG("Battery " .. pct .. "% -> " .. state)
	end
end

-- ===================== Proxy notifications ============================
function NotifyOnline(bOnline)
	if (bOnline == g_online) then return end
	g_online = bOnline
	C4:SendToProxy(LOCK_BINDING, "ONLINE_CHANGED", { STATE = tostring(bOnline) }, "NOTIFY")
end

function NotifyLockStatus(sStatus, sDescription, sSource)
	local p = { LOCK_STATUS = sStatus }
	if (sDescription ~= nil) then p.LAST_ACTION_DESCRIPTION = sDescription end
	if (sSource ~= nil) then
		p.SOURCE = sSource
		-- MANUAL drives the LockedManually / UnlockedManually proxy events.
		p.MANUAL = (sSource == "manual" or sSource == "keypad")
	end
	LOG("LOCK_STATUS_CHANGED -> " .. sStatus .. (sDescription and (" (" .. sDescription .. ")") or ""))
	C4:SendToProxy(LOCK_BINDING, "LOCK_STATUS_CHANGED", p, "NOTIFY")
end

--[[
	CONTACT PROXY POLARITY - settled. Do not "fix" this back.

	contactsingle_contactswitch_c4 renders a CLOSED contact as an OPEN door.
	The notification names describe the CONTACT; the UI shows the DOOR; on this
	OS version those are opposites. So a shut door is reported with OPENED.

	This took three attempts, and both wrong ones came from bad instrumentation
	rather than bad reasoning:

	  v109  flipped this table AND the "Invert Sensor" checkbox was unticked in
	        the same sitting. Either change alone corrects the reading; together
	        they cancel, so the door still read backwards and the flip looked
	        like the mistake.
	  v111  concluded from that cancellation that the flip WAS the mistake and
	        reverted it to the "obvious" mapping. Still backwards.
	  v115  restored the flip, on the only evidence that is actually valid here
	        (below).

	THE ONLY VALID EVIDENCE IS NAVIGATOR OR THE PHYSICAL DOOR.

	Composer's "State:" field on the contact device is INERT with respect to
	this driver. Verified 2026-09-04: it did not move for a real,
	log-confirmed, driver-originated CLOSED notification, and it did not move
	for a log-confirmed OPENED one either. The only thing that changes it is
	toggling the Invert Sensor checkbox. Reading it as live feedback is what
	produced the v111 reversal - do not repeat that.

	What settled it: with v114 sending CLOSED for a shut door, Invert Sensor
	confirmed UNCHECKED, and Navigators freshly refreshed, the owner reported
	Navigator showing the front door as OPEN while it was physically shut.
	Hence closed -> OPENED.

	LEAVE "Invert Sensor" UNCHECKED. The driver compensates, so ticking the box
	re-breaks a correct reading.
]]
DOOR_STATE_NOTIFY = { open = "CLOSED", closed = "OPENED" }

-- The "remains in state" variants, for the periodic re-assert. OPENED/CLOSED
-- describe a transition that did not actually happen on a re-assert. These
-- carry the same inversion as the table above, and a test pins them together.
DOOR_STATE_ASSERT = { open = "STATE_CLOSED", closed = "STATE_OPENED" }

function NotifyDoorState(sState, bReassert)
	local map = bReassert and DOOR_STATE_ASSERT or DOOR_STATE_NOTIFY
	local notify = map[sState]
	if (notify == nil) then
		-- "disabled" means no DoorSense magnet is paired; nothing to report.
		LOG("Door state -> " .. tostring(sState) .. " (not reported)")
		return
	end
	LOG("Door state -> " .. sState .. " (sending " .. notify .. " to the contact proxy)")
	C4:SendToProxy(CONTACT_BINDING, notify, {}, "NOTIFY")
end

-- Capability keys come from the lock proxy reference. Only the ones this
-- driver can actually honour are advertised as true, so Navigator does not
-- render settings screens that would do nothing.
function PublishCapabilities()
	local caps = {
		has_settings              = "false",   -- no confirmed settings endpoints on this API
		has_admin_code            = "false",
		has_auto_lock_time        = "false",
		has_custom_settings       = "false",
		has_language              = "false",
		has_lock_modes            = "false",
		has_log_failed_attempts   = "false",
		has_log_item_count        = "false",
		has_one_touch_locking     = "false",
		has_schedule_lockout      = "false",
		has_shutout_timer         = "false",
		has_volume                = "false",
		has_wrong_code_attempts   = "false",
		has_daily_schedule        = "false",
		has_date_range_schedule   = "false",
		has_internal_history      = "true",    -- REQUEST_HISTORY is implemented
		is_management_only        = "false",
		max_users                 = "250",     -- Assure Lock 2 published capacity

		-- Not in the published proxy reference; found in Cinegration's shipping
		-- yale_lock_cin.c4z, which sets all three false for this same lock.
		-- These make Navigator hide the add/edit/delete credential controls
		-- rather than offer buttons that do nothing. See KNOWN GAP in the header.
		can_add_remove_user       = "false",
		can_edit_user             = "false",
		can_edit_user_pin         = "false",
	}
	for k, v in pairs(caps) do
		C4:SendToProxy(LOCK_BINDING, "CAPABILITY_CHANGED", { NAME = k, VALUE = v }, "NOTIFY")
	end
end

-- ===================== Lock control ============================
function RemoteOperate(sOp)
	if (g_lockId == "") then
		LOG("Cannot " .. sOp .. ": Lock ID is not set.")
		return
	end
	if (not HaveToken()) then
		LOG("Cannot " .. sOp .. ": not authenticated.")
		return
	end

	local path = "/remoteoperate/" .. g_lockId .. "/" .. sOp .. OPERATE_QUERY
	-- Start the settle ladder immediately: with the async endpoint the bolt may
	-- well finish moving before the HTTP response is even parsed, and if the
	-- request times out we still want the real state rather than a stale one.
	ScheduleSettleLadder()
	ApiRequest("PUT", path, nil, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk) then
			LOG(sOp .. " failed, HTTP " .. tostring(code) .. " " .. tostring(sErr) ..
			    " - the settle reads will report the lock's actual state")
			return
		end
		if (type(tJson) == "table") then
			-- The operate response carries the resulting status and doorState,
			-- plus info.action describing what happened.
			local desc, src = nil, "remote"
			if (type(tJson.info) == "table" and tJson.info.action ~= nil) then
				desc = tostring(tJson.info.action)
			end
			ApplyStatusJson(tJson, desc, src)
		end
	end, { timeout = OPERATE_TIMEOUT })
end

-- Several delayed status reads rather than one. Each timer is independent so a
-- later read is not cancelled by an earlier one (ScheduleSettleRead keeps only
-- the most recent timer, which is right for transitional states but wrong here).
g_settleTimers = {}
function ScheduleSettleLadder()
	CancelSettleLadder()
	for _, ms in ipairs(OPERATE_SETTLE_MS) do
		local key = ms
		local ok, t = pcall(function()
			return C4:SetTimer(ms, function(timer, skips)
				-- A one-shot timer that has fired is dead; drop it so the table
				-- reflects what is actually pending rather than growing a list
				-- of expired handles that later Cancel() calls walk over.
				g_settleTimers[key] = nil
				RefreshStatus()
			end, false)
		end)
		if (ok and t ~= nil) then g_settleTimers[key] = t end
	end
end

function CancelSettleLadder()
	for k, t in pairs(g_settleTimers) do
		pcall(function() t:Cancel() end)
		g_settleTimers[k] = nil
	end
end

-- How many settle reads are still pending. Diagnostic only.
function PendingSettleCount()
	local n = 0
	for _ in pairs(g_settleTimers) do n = n + 1 end
	return n
end

-- Ask the cloud to wake the lock's radio and refresh its state.
function RequestWakeup()
	if (g_lockId == "" or not HaveToken()) then return end

	local nowMs = NowMs()

	if (g_lastWakeupMs ~= nil and (nowMs - g_lastWakeupMs) < WAKEUP_MIN_GAP_MS) then
		LOG("Wakeup suppressed (last one was " ..
		    tostring(math.floor((nowMs - g_lastWakeupMs) / 1000)) .. "s ago, minimum gap is " ..
		    tostring(WAKEUP_MIN_GAP_MS / 1000) .. "s)")
		return
	end
	g_lastWakeupMs = nowMs

	local path = "/remoteoperate/" .. g_lockId .. "/status" .. WAKEUP_QUERY
	LOG("Requesting lock wakeup")
	ScheduleSettleLadder()
	ApiRequest("PUT", path, nil, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk) then
			LOG("Wakeup request failed, HTTP " .. tostring(code) .. " " .. tostring(sErr))
			return
		end
		if (type(tJson) == "table" and tJson.status ~= nil) then
			ApplyStatusJson(tJson, nil, nil)
		end
	end, { timeout = OPERATE_TIMEOUT })
end

-- ===================== History ============================
function RequestHistory()
	if (g_houseId == "") then
		LOG("Cannot fetch history: House ID unknown. Run action 3 - Discover Locks.")
		return
	end
	if (not HaveToken()) then return end

	local path = "/houses/" .. g_houseId .. "/activities?limit=" .. tostring(g_historyLimit)
	ApiRequest("GET", path, nil, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk) then
			LOG("History fetch failed, HTTP " .. tostring(code))
			return
		end
		local list = tJson
		if (type(list) == "table" and type(list.events) == "table") then list = list.events end
		if (type(list) ~= "table") then return end

		local xml = { "<lock_history>" }
		local n = 0
		for i, ev in ipairs(list) do
			if (type(ev) == "table") then
				-- Only this lock's events; house activities cover every device.
				local devId = ev.deviceID or ev.deviceId
				if (devId == nil or tostring(devId) == g_lockId) then
					n = n + 1
					local epochMs = tonumber(ev.dateTime) or tonumber(ev.timestamp) or 0
					local secs = math.floor(epochMs / 1000)
					local d = os.date("*t", secs)
					local sDate = string.format("%02d/%02d/%04d", d.month, d.day, d.year)
					local sTime = string.format("%02d:%02d:%02d", d.hour, d.min, d.sec)

					local action = tostring(ev.action or "unknown")
					local who = ""
					local cu = ev.callingUser or ev.user
					if (type(cu) == "table") then
						who = TrimStr(tostring(cu.FirstName or "") .. " " .. tostring(cu.LastName or ""))
					end
					local msg = DescribeAction(action)
					if (who ~= "") then msg = msg .. " by " .. who end

					table.insert(xml, "\t<history_item>")
					table.insert(xml, "\t\t<history_id>" .. tostring(n) .. "</history_id>")
					table.insert(xml, "\t\t<date>" .. XmlEscape(sDate) .. "</date>")
					table.insert(xml, "\t\t<time>" .. XmlEscape(sTime) .. "</time>")
					table.insert(xml, "\t\t<message>" .. XmlEscape(msg) .. "</message>")
					table.insert(xml, "\t\t<source>" .. XmlEscape(SourceForAction(action)) .. "</source>")
					table.insert(xml, "\t</history_item>")
				end
			end
		end
		table.insert(xml, "</lock_history>")

		local payload = table.concat(xml, "\n")
		LOG("HISTORY: " .. tostring(n) .. " item(s) for this lock")
		C4:SendToProxy(LOCK_BINDING, "HISTORY", payload, "NOTIFY")
	end, { acceptVersion = ACTIVITY_VERSION })
end

-- Action strings from yalexs/activity.py.
ACTION_TEXT = {
	lock = "Locked", unlock = "Unlocked", unlatch = "Unlatched",
	locking = "Locking", unlocking = "Unlocking", unlatching = "Unlatching",
	jammed = "Jammed",
	auto_lock = "Auto-locked", onetouchlock = "One-touch locked",
	manual_lock = "Locked manually", manual_unlock = "Unlocked manually",
	manual_unlatch = "Unlatched manually",
	pin_lock = "Locked by keypad PIN", pin_unlock = "Unlocked by keypad PIN",
	pin_unlatch = "Unlatched by keypad PIN",
	finger_lock = "Locked by fingerprint", finger_unlock = "Unlocked by fingerprint",
	remote_lock = "Locked remotely", remote_unlock = "Unlocked remotely",
	remote_unlatch = "Unlatched remotely",
	ble_lock = "Locked by Bluetooth", ble_unlock = "Unlocked by Bluetooth",
	ble_unlatch = "Unlatched by Bluetooth",
	rf_lock = "Locked by RF", rf_unlock = "Unlocked by RF",
	rf_secure = "Secured by RF", rf_unlatch = "Unlatched by RF",
	homekey_lock = "Locked by HomeKey", homekey_unlock = "Unlocked by HomeKey",
	homekey_unlatch = "Unlatched by HomeKey",
	dooropen = "Door opened", doorclosed = "Door closed",
	associated_bridge_online = "Wi-Fi module online",
	associated_bridge_offline = "Wi-Fi module offline",
}

KEYPAD_ACTIONS = {
	onetouchlock = true, pin_lock = true, pin_unlock = true, pin_unlatch = true,
	finger_lock = true, finger_unlock = true,
}
MANUAL_ACTIONS = { manual_lock = true, manual_unlock = true, manual_unlatch = true }
REMOTE_ACTIONS = { remote_lock = true, remote_unlock = true, remote_unlatch = true }

function DescribeAction(a)
	return ACTION_TEXT[a] or a
end

function SourceForAction(a)
	if (KEYPAD_ACTIONS[a]) then return "keypad" end
	if (MANUAL_ACTIONS[a]) then return "manual" end
	if (REMOTE_ACTIONS[a]) then return "remote" end
	if (a == "auto_lock") then return "auto" end
	return "lock"
end

-- ===================== Users / PIN codes ============================
-- READ path only. See the KNOWN GAP note in the file header.
function RequestUsers()
	if (g_lockId == "" or not HaveToken()) then return end
	ApiRequest("GET", "/locks/" .. g_lockId .. "/pins", nil, function(bOk, code, headers, tJson, raw, sErr)
		if (not bOk) then
			LOG("PIN fetch failed, HTTP " .. tostring(code))
			return
		end
		local list = tJson
		if (type(list) == "table" and type(list.loaded) == "table") then list = list.loaded end
		if (type(list) ~= "table") then return end

		local xml = { "<lock_users>" }
		local n = 0
		for i, p in ipairs(list) do
			if (type(p) == "table") then
				n = n + 1
				local name = TrimStr(tostring(p.firstName or "") .. " " .. tostring(p.lastName or ""))
				if (name == "") then name = "User " .. tostring(n) end
				-- The proxy wants an integer user_id; the API's _id is a Mongo-style
				-- string. Use the keypad slot when present (stable and numeric),
				-- otherwise the ordinal. The API id is kept in the local map below
				-- so a future write implementation can translate back.
				local uid = tonumber(p.slot) or n
				g_pinIdBySlot[uid] = tostring(p._id or "")

				table.insert(xml, "\t<user>")
				table.insert(xml, "\t\t<user_id>" .. tostring(uid) .. "</user_id>")
				table.insert(xml, "\t\t<user_name>" .. XmlEscape(name) .. "</user_name>")
				table.insert(xml, "\t\t<passcode>" .. XmlEscape(tostring(p.pin or "")) .. "</passcode>")
				table.insert(xml, "\t\t<is_active>" .. ((p.state == "loaded" or p.state == "active") and "true" or "false") .. "</is_active>")
				table.insert(xml, "\t\t<schedule_type>daily</schedule_type>")
				table.insert(xml, "\t\t<is_restricted_schedule>" .. ((p.accessType ~= nil and p.accessType ~= "always") and "true" or "false") .. "</is_restricted_schedule>")
				table.insert(xml, "\t</user>")
			end
		end
		table.insert(xml, "</lock_users>")

		LOG("USERS: " .. tostring(n) .. " PIN code(s)")
		C4:SendToProxy(LOCK_BINDING, "USERS", table.concat(xml, "\n"), "NOTIFY")
	end)
end

g_pinIdBySlot = {}

-- Deliberate stubs. Do not "fix" these by guessing an endpoint - operating a
-- door lock's credential list on an unverified request shape is not worth it.
function AddUser(tParams)
	LOG("ADD_USER received but not implemented: no confirmed Yale Access API " ..
	    "endpoint exists for creating a PIN. Add the code in the Yale Access app. " ..
	    "Requested user: " .. tostring(tParams and tParams.USER_NAME))
end

function EditUser(tParams)
	LOG("EDIT_USER received but not implemented (no confirmed API endpoint). " ..
	    "Edit the code in the Yale Access app.")
end

function DeleteUser(tParams)
	LOG("DELETE_USER received but not implemented (no confirmed API endpoint). " ..
	    "Delete the code in the Yale Access app.")
end

-- ===================== Proxy command dispatch ============================
function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	LOG("ReceivedFromProxy [" .. tostring(idBinding) .. "] " .. tostring(strCommand))

	if (strCommand == "GET_CONNECTED_STATE") then
		C4:SendToProxy(idBinding, "ONLINE_CHANGED", { STATE = tostring(g_online) }, "NOTIFY")
		return
	end

	if (idBinding ~= LOCK_BINDING) then return end

	if (strCommand == "LOCK" or strCommand == "CLOSE") then
		RemoteOperate("lock")

	elseif (strCommand == "UNLOCK" or strCommand == "OPEN") then
		RemoteOperate("unlock")

	elseif (strCommand == "TOGGLE") then
		if (g_lockStatus == "locked") then RemoteOperate("unlock") else RemoteOperate("lock") end

	elseif (strCommand == "REQUEST_CAPABILITIES") then
		PublishCapabilities()

	elseif (strCommand == "REQUEST_SETTINGS" or strCommand == "REQUEST_CUSTOM_SETTINGS") then
		-- Advertised as unsupported via capabilities; answer with an empty doc
		-- so a UI that asks anyway doesn't sit waiting.
		C4:SendToProxy(LOCK_BINDING, "SETTINGS", "<lock_settings></lock_settings>", "NOTIFY")

	elseif (strCommand == "REQUEST_HISTORY") then
		RequestHistory()

	elseif (strCommand == "REQUEST_USERS") then
		RequestUsers()

	elseif (strCommand == "ADD_USER") then
		AddUser(tParams)

	elseif (strCommand == "EDIT_USER") then
		EditUser(tParams)

	elseif (strCommand == "DELETE_USER") then
		DeleteUser(tParams)

	else
		LOG("Unhandled lock proxy command: " .. tostring(strCommand))
	end
end

-- ===================== Composer commands / actions ============================
--[[
	IMPORTANT - how Composer actually dispatches <actions>.

	Composer does NOT call ExecuteCommand with the action's <command> string.
	It calls ExecuteCommand("LUA_ACTION", { ACTION = "<command>" }). v101
	compared strCommand directly against "ACTION_SIGN_IN" and friends, so every
	action button silently did nothing. Confirmed live on an EA-1: pressing the
	action buttons produced only

	    [YaleLock2] ExecuteCommand: LUA_ACTION

	repeatedly, with Auth State never leaving "Not signed in".

	This was invisible to the offline test harness because the harness invoked
	ExecuteCommand("ACTION_SIGN_IN", {}) directly - it tested the branch, not the
	dispatch. The harness now calls it the way Composer does.

	<commands> (the <config><commands> block) DO arrive as their own name, so
	both shapes are normalised here.
]]
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}

	if (strCommand == "LUA_ACTION") then
		local action = tParams["ACTION"] or tParams["Action"] or tParams["action"]
		if (action ~= nil and action ~= "") then
			strCommand = tostring(action)
		else
			LOG("LUA_ACTION received with no ACTION parameter. Params: " .. DescribeParams(tParams))
			return
		end
	end

	LOG("ExecuteCommand: " .. tostring(strCommand))

	if (strCommand == "ACTION_SIGN_IN") then
		ActionSignIn()
	elseif (strCommand == "ACTION_SUBMIT_CODE") then
		ActionSubmitCode()
	elseif (strCommand == "ACTION_DISCOVER") then
		ActionDiscoverLocks()
	elseif (strCommand == "ACTION_REFRESH_STATUS") then
		-- An explicit refresh from a human bypasses the wakeup rate limit.
		g_lastWakeupMs = nil
		RefreshDetail()
		RefreshStatus()
	elseif (strCommand == "ACTION_REFRESH_HISTORY") then
		RequestHistory()
	elseif (strCommand == "ACTION_REFRESH_USERS") then
		RequestUsers()
	elseif (strCommand == "ACTION_REFRESH_TOKEN") then
		RefreshAccessToken()
	elseif (strCommand == "ACTION_CLEAR_CREDENTIALS") then
		ActionClearCredentials()
	elseif (strCommand == "ACTION_PRINT_DEBUG") then
		PrintDebug()
	elseif (strCommand == "Lock") then
		RemoteOperate("lock")
	elseif (strCommand == "Unlock") then
		RemoteOperate("unlock")
	else
		-- Never fail silently again. If a command arrives that this driver does
		-- not recognise, say so and dump what came with it.
		LOG("Unhandled ExecuteCommand: '" .. tostring(strCommand) .. "' params: " .. DescribeParams(tParams))
	end
end

-- Renders a params table for the log, redacting anything credential-shaped.
function DescribeParams(tParams)
	if (type(tParams) ~= "table") then return tostring(tParams) end
	local keys = {}
	for k in pairs(tParams) do table.insert(keys, tostring(k)) end
	if (#keys == 0) then return "{}" end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		local v = tParams[k]
		local lk = string.lower(k)
		if (lk == "password" or lk == "code" or lk == "passcode") then v = Redact(v) end
		table.insert(out, k .. "=" .. tostring(v))
	end
	return "{ " .. table.concat(out, ", ") .. " }"
end

function PrintDebug()
	print("=== Yale Assure Lock 2 driver v" .. DRIVER_VERSION .. " ===")
	print("Brand:          " .. tostring(g_brand) .. " (branding header: " .. BrandingValue() .. ")")
	print("API key:        " .. tostring(CurrentApiKey()) ..
	      ((g_apiKeyProp ~= nil and g_apiKeyProp ~= "") and "  (pinned by property)"
	                                                    or ("  (rotation slot " .. tostring(g_apiKeyIndex) .. " of " .. tostring(#API_KEYS) .. ")")))
	print("Auth state:     " .. tostring(g_authState))
	print("Token:          " .. Redact(g_token))
	print("Token expires:  " .. tostring(g_tokenExpires))
	print("Install ID:     " .. tostring(g_installId))
	print("Lock ID:        " .. tostring(g_lockId))
	print("House ID:       " .. tostring(g_houseId))
	print("Lock status:    " .. tostring(g_lockStatus))
	print("Door state:     " .. tostring(g_doorState) .. " (doorsense seen: " .. tostring(g_hasDoorsense) .. ")")
	print("Battery:        " .. tostring(g_batteryPct) .. "% -> " .. tostring(g_batteryState))
	print("Online:         " .. tostring(g_online))
	print("Poll interval:  " .. tostring(g_pollInt) .. "s (poll timer running: " ..
	      tostring(g_pollTimer ~= nil) .. ", polls so far: " .. tostring(g_pollCount) .. ")")
	print("Status read:    in flight: " .. tostring(g_statusInFlight) ..
	      ", pending settle reads: " .. tostring(PendingSettleCount()) ..
	      ", consecutive transitional reads: " .. tostring(g_transitionalReads))
end

-- ===================== Small helpers ============================
function TrimStr(s)
	return (string.gsub(tostring(s), "^%s*(.-)%s*$", "%1"))
end

function XmlEscape(s)
	s = tostring(s or "")
	s = string.gsub(s, "&", "&amp;")
	s = string.gsub(s, "<", "&lt;")
	s = string.gsub(s, ">", "&gt;")
	s = string.gsub(s, '"', "&quot;")
	s = string.gsub(s, "'", "&apos;")
	return s
end

--[[==============================================================================
	Minimal JSON encode/decode, pure Lua, no dependencies.
	Control4 does not expose a JSON library to a standalone driver (the
	drivers-common-public JSON module is only available to drivers that embed
	that library), so this is self-contained. Decoder handles the full JSON
	grammar including nested objects/arrays, escapes and \uXXXX (encoded to
	UTF-8). Encoder covers the flat request bodies this driver sends.
	Unit-tested against the real /session, /locks/{id}, /pins and /activities
	response shapes before shipping.
================================================================================]]
local function json_error(str, pos, msg)
	error("JSON parse error at position " .. tostring(pos) .. ": " .. msg, 0)
end

local json_escape_map = {
	['"'] = '"', ["\\"] = "\\", ["/"] = "/", ["b"] = "\b",
	["f"] = "\f", ["n"] = "\n", ["r"] = "\r", ["t"] = "\t",
}

local function json_codepoint_to_utf8(n)
	if (n < 0x80) then
		return string.char(n)
	elseif (n < 0x800) then
		return string.char(0xC0 + math.floor(n / 0x40), 0x80 + (n % 0x40))
	elseif (n < 0x10000) then
		return string.char(0xE0 + math.floor(n / 0x1000),
		                   0x80 + (math.floor(n / 0x40) % 0x40),
		                   0x80 + (n % 0x40))
	else
		return string.char(0xF0 + math.floor(n / 0x40000),
		                   0x80 + (math.floor(n / 0x1000) % 0x40),
		                   0x80 + (math.floor(n / 0x40) % 0x40),
		                   0x80 + (n % 0x40))
	end
end

local function json_skip_ws(str, pos)
	local _, e = string.find(str, "^[ \t\r\n]*", pos)
	return (e or pos - 1) + 1
end

local json_parse_value

local function json_parse_string(str, pos)
	pos = pos + 1 -- skip opening quote
	local out = {}
	while true do
		local c = string.sub(str, pos, pos)
		if (c == "") then json_error(str, pos, "unterminated string") end
		if (c == '"') then
			return table.concat(out), pos + 1
		elseif (c == "\\") then
			local esc = string.sub(str, pos + 1, pos + 1)
			if (esc == "u") then
				local hex = string.sub(str, pos + 2, pos + 5)
				local n = tonumber(hex, 16)
				if (n == nil) then json_error(str, pos, "bad \\u escape") end
				pos = pos + 6
				-- Surrogate pair
				if (n >= 0xD800 and n <= 0xDBFF and string.sub(str, pos, pos + 1) == "\\u") then
					local lo = tonumber(string.sub(str, pos + 2, pos + 5), 16)
					if (lo ~= nil and lo >= 0xDC00 and lo <= 0xDFFF) then
						n = 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
						pos = pos + 6
					end
				end
				table.insert(out, json_codepoint_to_utf8(n))
			else
				local m = json_escape_map[esc]
				if (m == nil) then json_error(str, pos, "bad escape \\" .. tostring(esc)) end
				table.insert(out, m)
				pos = pos + 2
			end
		else
			-- Consume a run of ordinary characters at once.
			local s, e = string.find(str, '^[^"\\]+', pos)
			if (s == nil) then json_error(str, pos, "unterminated string") end
			table.insert(out, string.sub(str, s, e))
			pos = e + 1
		end
	end
end

local function json_parse_number(str, pos)
	local s, e = string.find(str, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
	if (s == nil) then json_error(str, pos, "bad number") end
	local n = tonumber(string.sub(str, s, e))
	if (n == nil) then json_error(str, pos, "bad number") end
	return n, e + 1
end

local function json_parse_object(str, pos)
	local obj = {}
	pos = json_skip_ws(str, pos + 1)
	if (string.sub(str, pos, pos) == "}") then return obj, pos + 1 end
	while true do
		pos = json_skip_ws(str, pos)
		if (string.sub(str, pos, pos) ~= '"') then json_error(str, pos, "expected key string") end
		local key
		key, pos = json_parse_string(str, pos)
		pos = json_skip_ws(str, pos)
		if (string.sub(str, pos, pos) ~= ":") then json_error(str, pos, "expected ':'") end
		local val
		val, pos = json_parse_value(str, pos + 1)
		obj[key] = val
		pos = json_skip_ws(str, pos)
		local c = string.sub(str, pos, pos)
		if (c == ",") then
			pos = pos + 1
		elseif (c == "}") then
			return obj, pos + 1
		else
			json_error(str, pos, "expected ',' or '}'")
		end
	end
end

local function json_parse_array(str, pos)
	local arr = {}
	pos = json_skip_ws(str, pos + 1)
	if (string.sub(str, pos, pos) == "]") then return arr, pos + 1 end
	local n = 0
	while true do
		local val
		val, pos = json_parse_value(str, pos)
		n = n + 1
		arr[n] = val
		pos = json_skip_ws(str, pos)
		local c = string.sub(str, pos, pos)
		if (c == ",") then
			pos = pos + 1
		elseif (c == "]") then
			return arr, pos + 1
		else
			json_error(str, pos, "expected ',' or ']'")
		end
	end
end

json_parse_value = function(str, pos)
	pos = json_skip_ws(str, pos)
	local c = string.sub(str, pos, pos)
	if (c == "{") then
		return json_parse_object(str, pos)
	elseif (c == "[") then
		return json_parse_array(str, pos)
	elseif (c == '"') then
		return json_parse_string(str, pos)
	elseif (string.sub(str, pos, pos + 3) == "true") then
		return true, pos + 4
	elseif (string.sub(str, pos, pos + 4) == "false") then
		return false, pos + 5
	elseif (string.sub(str, pos, pos + 3) == "null") then
		-- Lua tables cannot hold nil values; JSON null becomes the sentinel
		-- below so "key present but null" is distinguishable from "absent".
		return JSON_NULL, pos + 4
	else
		return json_parse_number(str, pos)
	end
end

JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })

function JsonDecode(str)
	if (type(str) ~= "string" or str == "") then return nil end
	local val, pos = json_parse_value(str, 1)
	return val
end

local json_encode_escapes = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function json_encode_string(s)
	s = string.gsub(tostring(s), '[%c"\\]', function(c)
		return json_encode_escapes[c] or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. s .. '"'
end

function JsonEncode(v)
	local t = type(v)
	if (v == nil or v == JSON_NULL) then
		return "null"
	elseif (t == "boolean") then
		return tostring(v)
	elseif (t == "number") then
		if (v ~= v or v == math.huge or v == -math.huge) then return "null" end
		if (v == math.floor(v)) then return string.format("%d", v) end
		return string.format("%.14g", v)
	elseif (t == "string") then
		return json_encode_string(v)
	elseif (t == "table") then
		-- Array if keys are 1..n, otherwise object.
		local n = 0
		for _ in pairs(v) do n = n + 1 end
		local isArray = (n > 0)
		for i = 1, n do
			if (v[i] == nil) then isArray = false; break end
		end
		local parts = {}
		if (isArray) then
			for i = 1, n do table.insert(parts, JsonEncode(v[i])) end
			return "[" .. table.concat(parts, ",") .. "]"
		else
			local keys = {}
			for k in pairs(v) do table.insert(keys, tostring(k)) end
			table.sort(keys)
			for _, k in ipairs(keys) do
				table.insert(parts, json_encode_string(k) .. ":" .. JsonEncode(v[k]))
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
	end
	return "null"
end
