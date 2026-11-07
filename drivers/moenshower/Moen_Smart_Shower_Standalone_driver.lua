--[[==============================================================================
	Moen Smart Shower / U by Moen Digital Shower Valve - Control4 Driver
	STANDALONE VERSION - no external Python bridge required.
	Unofficial / community driver. Not affiliated with or supported by
	Moen, Fortune Brands, or Control4.

	Same project/author as Moen_Smart_Shower_driver.lua (the bridge-based
	version), Haiku_SenseME_driver.lua, and IntelliFire_driver.lua.

	================================================================================
	v300: UI BUTTON + WEB VIEW (replaces Thermostat + Extras)
	================================================================================
	The thermostatV2 proxy made the shower read as a second thermostat in the
	room. v300 swaps it for a uibutton proxy whose Navigator tile opens a
	bundled page (www/shower<N>.html). The page and driver talk like this:
	  driver -> page: ONE variable, UI_STATE, holding a JSON snapshot of the
	                  whole shower (also sent with C4:SendDataToUI). Every
	                  snapshot carries a fresh seq number so the page can drop
	                  Navigator's duplicate deliveries.
	  page -> driver: PARAMETER-FREE commands (UI_SHOWER_ON, UI_PRESET_2,
	                  UI_TEMP_SET_104, UI_OUTLET_1_ON, ...) so nothing is lost
	                  in Navigator's param translation. The value lives in the
	                  command name; EC entries are registered in loops below.
	  page build:     the page sends UI_HELLO_<build> on open; a mismatch with
	                  PAGE_BUILD logs "PAGE IS STALE" (Navigator caches pages,
	                  so the page FILE is renamed every page release).
	Also new: SHOWER_RUNNING / SHOWER_MODE / CURRENT_TEMP / TARGET_TEMP /
	ACTIVE_PRESET variables, Shower Started / Ready / Stopped events, a
	Running icon state, and a faster poll only while the water is on
	("Running Poll Interval"). The protocol layer and every Action_*
	function are unchanged. Safety rule unchanged: nothing the page does on
	open, refresh or reconnect can turn water on - only an explicit Start,
	preset tap or outlet-on tap.

	================================================================================
	v200 CHANGE FROM v102 - PROXY/UI LAYER ONLY, PROTOCOL LAYER UNTOUCHED
	================================================================================
	v201: fixes a bug found on the FIRST live test against the real device -
	Extras tab rendered but was empty because SyncExtras sent the XML under
	the wrong SendToProxy parameter key (extras_setup/extras_state instead of
	the real wire key, "XML" - see the note at SyncExtras below and the .xml
	header for the full explanation). Also replaced the shower icon with a
	clearer rain-showerhead design.

	v202: (1) repackaged under the ORIGINAL file name - v200/v201 were
	packaged with version suffixes on the outer .c4z, which broke Composer's
	"update the existing bound device" matching and is why the icon change
	in v201 never actually reached the real device. (2) added hvac_modes
	capability (see .xml) so the native thermostat card gets an Off/Heat
	toggle, not just the Extras switch. (3) fixed the inbound RFP command
	names - SET_MODE_HVAC / SET_SETPOINT_HEAT, not SET_HVAC_MODE /
	SET_HEAT_SETPOINT - found via the DriverWorks "Thermostat Unhandled
	Commands" reference page. (4) Extras preset buttons now show "Preset N"
	as the row label and the live Moen preset title as the button text,
	instead of the live title in both places.
	================================================================================
	v102 modeled the shower as a Pool/Spa proxy: on/off was a pool "heat mode"
	and presets only existed as Composer actions, invisible in Navigator - the
	one thing the user actually interacts with wasn't in the UI at all. v200
	moves to a Thermostat proxy with the Extras framework (has_extras,
	EXTRAS_SETUP_CHANGED/EXTRAS_STATE_CHANGED), which gives Navigator a native
	on/off switch plus one button per real preset (pulled live from the Moen
	API, never hardcoded) - see the .xml header's decision record for the full
	writeup of why, including the live-tested capabilities-block-placement fix
	that made Composer accept a thermostatV2 proxy in the first place.

	NONE of the REST auth/polling chain or the Pusher WebSocket control path
	changed in this version - that logic is proven (see
	Moen_Smart_Shower_Test_Plan_RECONSTRUCTED.md) and out of scope per this
	project's rules. Only SyncProxiesFromState (now split into thermostat
	notifications + SyncExtras) and the RFP/EC command surface changed.
	Action_ShowerOn/Action_ShowerOff/Action_Resume/Action_SetTemperature/
	Action_SetOutlet/Action_ActivatePreset are REUSED UNCHANGED from v102 -
	they contain the proven Moen payload construction and were deliberately
	not touched.

	INBOUND THERMOSTAT COMMAND NAMES (SET_HVAC_MODE, SET_HEAT_SETPOINT) ARE
	AN INFERENCE, not confirmed from the DriverWorks docs (which document the
	outbound _CHANGED notifications in full but not the inbound SET_ commands
	for this specific proxy). Inferred by analogy with every other proxy
	already proven in this project (SET_LEVEL/light_v2, SET_POOL_HEATMODE
	SET_POOL_SETPOINT/SET_AUX_MODE/pool - all follow "SET_" + the matching
	_CHANGED notification's base name). If wrong, RFP's else-branch logs the
	real strCommand instead of silently failing - check the log during the
	Phase 1 acceptance test and fix in one pass if needed. Extras command
	names (below) are NOT a guess - they're strings this driver defines
	itself in the extras_setup XML it sends, so whatever we put in the
	"command" attribute is exactly what comes back through RFP.

	================================================================================
	WHY THIS VERSION EXISTS / HOW IT DIFFERS FROM THE BRIDGE VERSION (v100/v102 history)
	================================================================================
	The original Moen_Smart_Shower_driver.lua offloaded all cloud/HTTPS/Pusher-
	WebSocket work to a separate always-on Python process ("the bridge") because,
	at the time it was written, this project had only confirmed raw TCP/UDP as
	available DriverWorks network primitives - TLS and WebSocket framing were
	unconfirmed.

	That bridge was built, deployed, and live-tested end to end against a real
	account and a real shower (see Moen_Smart_Shower_Test_Plan.md) - it works.
	This standalone version exists because it turns out Control4 DOES ship an
	official, supported client-side WebSocket module as part of the public
	"drivers-common-public" library (github.com/control4/drivers-common-public,
	module/websocket.lua), alongside the documented C4:urlGet/C4:urlPost HTTPS
	functions. That removes the reason for the external bridge: this driver now
	does the Moen REST auth/polling AND the Pusher WebSocket control directly,
	running entirely on the Control4 controller. No separate machine needed.

	CONFIRMED LIVE (v102, re-confirmed unchanged in v200): this standalone
	transport genuinely works against a real Director - Cloud Status:
	Authenticated, Pusher Status: Connected/subscribed, observed live in
	Composer Pro against the real EA-1. The bridge version's Moen protocol
	logic (endpoints, field names, control payloads, and critically the "must
	wait for pusher_internal:subscription_succeeded before sending a client-
	event, or Pusher silently drops it" fix) is carried over exactly.

	================================================================================
	REQUIRED PROJECT FILES (see this driver's setup notes)
	================================================================================
	This driver requires the following files from control4/drivers-common-public
	(MIT-style public library, intended for exactly this kind of reuse) to be
	present in the SAME DriverEditor project, at these exact relative paths,
	so that Lua's require('drivers-common-public.global.url') etc. resolve:
	  drivers-common-public/global/handlers.lua
	  drivers-common-public/global/lib.lua
	  drivers-common-public/global/timer.lua
	  drivers-common-public/global/url.lua
	  drivers-common-public/module/json.lua
	  drivers-common-public/module/metrics.lua
	  drivers-common-public/module/websocket.lua
	These were fetched verbatim from that public repo and are NOT modified.

	NOTE ON DISPATCH STYLE: drivers-common-public/global/handlers.lua defines
	the actual Control4 entry-point functions (ExecuteCommand, OnPropertyChanged,
	ReceivedFromProxy, OnConnectionStatusChanged, ReceivedFromNetwork) itself,
	dispatching by table lookup (EC[cmd], OPC[prop], RFP[binding], etc.) rather
	than a single if/elseif chain. This driver follows that convention - it does
	NOT redefine those 5 functions directly, it populates the dispatch tables.
	This is required because module/websocket.lua's dynamic network binding
	relies on OCS[]/RFN[] already being wired up by handlers.lua. UNCHANGED
	from v102 - Extras taps arrive as strCommand values into the SAME
	RFP[MASTER_BINDING] function pool commands used to use, not a separate
	PRX_CMD table (that convention was only used by the Phase 0 throwaway
	driver, which didn't use handlers.lua at all).

	================================================================================
	MOEN CLOUD API - unchanged from v102/bridge version, ported 1:1
	================================================================================
	  GET  https://www.moen-iot.com/v2/authenticate?email=..&password=..  -> {token}
	  GET  https://www.moen-iot.com/v3/credentials      (header User-Token) -> {app_key, cluster}
	  GET  https://www.moen-iot.com/v2/showers          (header User-Token) -> [devices]
	  GET  https://www.moen-iot.com/v5/showers/{serial} (header User-Token) -> device detail incl. "channel"
	  POST https://www.moen-iot.com/v3/pusher-auth      (header User-Token, body socket_id=&channel_name=) -> {auth}
	  WSS  wss://ws-<cluster>.pusher.com/app/<app_key>?protocol=7&client=c4lua&version=1.0
	    -> control frames: {"event":"client-state-desired","channel":"private-<channel>",
	                         "data":{"type":"control","data":{"action":"<action>","params":{...}}}}
	Actions: shower_on {preset}, shower_off {}, shower_set {..full preset payload..}
	(activates a preset AND turns shower on), temperature_set {target_temperature},
	outlets_set {outlets:[{position,active},...]}.
	Modes seen live: off, adjusting, ready. (pause / paused-by-preset not yet
	exercised live - see Test Plan.)

	Unlike the bridge, this driver holds ONE persistent Pusher WebSocket
	connection open for the life of the driver (reconnecting with a short
	delay if it drops) instead of opening a fresh one per command - this
	should make control noticeably snappier than the bridge's ~1-4s-per-command
	reconnect pattern, while keeping the same "never send a client- event
	before subscription_succeeded" safety rule that fixed the bridge's
	multi-outlet preset bug.

	================================================================================
	SAFETY RULE (unchanged, still the most important comment in this file):
	nothing in this driver may send shower_on as a side effect of driver load,
	reconnect, property change, or state resync. OnDriverLateInit only ever
	calls StartAuthFlow/NotifyOnline(false) - never Action_ShowerOn. Every
	Action_ShowerOn call site below is reachable only from an explicit,
	user-initiated command (RFP proxy command or EC Composer command).
================================================================================]]

require ('drivers-common-public.global.handlers')
require ('drivers-common-public.global.timer')
require ('drivers-common-public.global.url')
WebSocket = require ('drivers-common-public.module.websocket')
-- JSON is already made global by global/url.lua (via global/lib.lua)

-- ===================== Constants ============================
-- Keep in sync with <version> in driver.xml; shown in the read-only "Driver Version" property
DRIVER_VERSION = "303"
API_BASE_URL       = 'https://www.moen-iot.com'
API_AUTHENTICATE   = '/v2/authenticate'
API_CREDENTIALS    = '/v3/credentials'
API_SHOWERS        = '/v2/showers'
API_SHOWER_DETAIL  = '/v5/showers/%s'
API_PUSHER_AUTH    = '/v3/pusher-auth'
PUSHER_CHANNEL_PREFIX = 'private-'

-- v200: single Thermostat+Extras proxy instead of Pool. See the decision
-- record in Moen_Smart_Shower_Standalone_driver.xml for why. Outlets are no
-- longer pushed to the UI at all (SyncExtras below only publishes the on/off
-- switch and preset buttons); Action_SetOutlet is retained and reachable via
-- the "Set Outlet" Composer command for programming use.
MASTER_BINDING  = 5001     -- v300: uibutton proxy (was thermostatV2)

-- Web view page. RENAME THE FILE AND BUMP BOTH VALUES ON EVERY PAGE CHANGE
-- (Navigator caches controller:// pages; a query string does not bust it).
-- driver.xml's web_view_url must point at the same file.
PAGE_FILE  = 'shower2.html'
PAGE_BUILD = '2'

AUTH_RETRY_SECONDS = 15
WS_RECONNECT_SECONDS = 5
PENDING_SEND_TIMEOUT_SECONDS = 10

-- ===================== Globals / Config ============================
g_email          = ''
g_password       = ''
g_configuredSerial = ''
g_pollInterval   = 20
g_runningPollInterval = 4  -- used only while the water is on
g_activePollInterval  = nil -- interval the repeating poll timer is running at
g_logMode        = 'Off'
g_tempMin        = 60
g_tempMax        = 115
-- Outlet slot->position properties, kept for "Set Outlet" and to interpret
-- the API - unchanged from v102, just no longer feed a UI aux list.
g_outletPos      = { 1, 2, 3, 4 }

g_token          = nil
g_pusherKey      = nil
g_pusherCluster  = nil
g_serial         = nil
g_device         = {}      -- last decoded /v5/showers/{serial} response
g_cloudAuthenticated = false
g_lastError      = ''

g_ws             = nil
g_wsSubscribed   = false
g_socketId       = nil
g_channelName    = nil
g_pendingSends   = {}

g_online        = false
g_uiSeq         = 0        -- bumped on every UI_STATE publish (page dedupes on it)
g_lastMode      = nil      -- previous mode, for Started/Ready/Stopped events
g_lastIcon      = nil

-- ===================== Logging helper ============================
function LOG(msg)
	if (g_logMode == 'Print' or g_logMode == 'Print and Log') then
		print ('[MoenShowerSA] ' .. tostring (msg))
	end
	if (g_logMode == 'Log' or g_logMode == 'Print and Log') then
		C4:DebugLog ('[MoenShowerSA] ' .. tostring (msg))
	end
end

-- ===================== Driver lifecycle ============================
function OnDriverInit ()
	LoadProperties ()
	C4:UpdateProperty("Driver Version", DRIVER_VERSION)
	-- UI_STATE must be visible (hidden=false) or the page cannot subscribe.
	C4:AddVariable ('UI_STATE', '', 'STRING', true, false)
	C4:AddVariable ('SHOWER_RUNNING', '0', 'BOOL', true, false)
	C4:AddVariable ('SHOWER_MODE', 'unknown', 'STRING', true, false)
	C4:AddVariable ('CURRENT_TEMP', '0', 'NUMBER', true, false)
	C4:AddVariable ('TARGET_TEMP', '0', 'NUMBER', true, false)
	C4:AddVariable ('ACTIVE_PRESET', '0', 'NUMBER', true, false)
	LOG ('OnDriverInit')
end

-- SAFETY: this function (and everything it calls) must never call
-- Action_ShowerOn. It only authenticates and starts polling/subscribing -
-- see the safety rule in the file header.
function OnDriverLateInit ()
	LoadProperties ()
	C4:UpdateProperty("Driver Version", DRIVER_VERSION)
	NotifyOnline (false)
	StartAuthFlow ()
end

function OnDriverDestroyed ()
	CancelTimer ('MoenPollTimer')
	CancelTimer ('MoenAuthRetryTimer')
	CancelTimer ('MoenWSReconnectTimer')
	CancelTimer ('MoenSendTimeoutCheck')
	if (g_ws) then
		g_ws:delete ()
		g_ws = nil
	end
end

function LoadProperties ()
	g_email            = Properties ['Moen Account Email'] or g_email
	g_password         = Properties ['Moen Account Password'] or g_password
	g_configuredSerial = Properties ['Device Serial Number Override'] or g_configuredSerial
	g_pollInterval     = tonumber (Properties ['Poll Interval (seconds)']) or g_pollInterval
	g_runningPollInterval = tonumber (Properties ['Running Poll Interval (seconds)']) or g_runningPollInterval
	g_logMode          = Properties ['Log Mode'] or g_logMode
	g_tempMin          = tonumber (Properties ['Target Temp Min (F)']) or g_tempMin
	g_tempMax          = tonumber (Properties ['Target Temp Max (F)']) or g_tempMax

	g_outletPos [1] = tonumber (Properties ['Outlet 1 Position']) or g_outletPos [1]
	g_outletPos [2] = tonumber (Properties ['Outlet 2 Position']) or g_outletPos [2]
	g_outletPos [3] = tonumber (Properties ['Outlet 3 Position']) or g_outletPos [3]
	g_outletPos [4] = tonumber (Properties ['Outlet 4 Position']) or g_outletPos [4]
	g_transport        = Properties ['Transport'] or g_transport
	g_bridgeHost       = Properties ['Bridge Host'] or g_bridgeHost
	g_bridgePort       = tonumber (Properties ['Bridge Port']) or g_bridgePort
end

-- ===================== Property change dispatch (handlers.lua convention) ==========
OPC = OPC or {}

OPC ['Moen_Account_Email'] = function (value)
	g_email = value
	LOG ('Email changed - restarting auth')
	RestartEverything ()
end

OPC ['Moen_Account_Password'] = function (value)
	g_password = value
	LOG ('Password changed - restarting auth')
	RestartEverything ()
end

OPC ['Device_Serial_Number_Override'] = function (value)
	g_configuredSerial = value
	RestartEverything ()
end

OPC ['Poll_Interval_(seconds)'] = function (value)
	g_pollInterval = tonumber (value) or g_pollInterval
	g_activePollInterval = nil
	if (g_cloudAuthenticated) then UpdatePollRate () end
end

OPC ['Running_Poll_Interval_(seconds)'] = function (value)
	g_runningPollInterval = tonumber (value) or g_runningPollInterval
	g_activePollInterval = nil
	if (g_cloudAuthenticated) then UpdatePollRate () end
end

OPC ['Log_Mode'] = function (value)
	g_logMode = value
end

OPC ['Target_Temp_Min_(F)'] = function (value)
	g_tempMin = tonumber (value) or g_tempMin
	SyncProxiesFromState ()
end

OPC ['Target_Temp_Max_(F)'] = function (value)
	g_tempMax = tonumber (value) or g_tempMax
	SyncProxiesFromState ()
end

OPC ['Outlet_1_Position'] = function (value) g_outletPos [1] = tonumber (value) or g_outletPos [1] end
OPC ['Outlet_2_Position'] = function (value) g_outletPos [2] = tonumber (value) or g_outletPos [2] end
OPC ['Outlet_3_Position'] = function (value) g_outletPos [3] = tonumber (value) or g_outletPos [3] end
OPC ['Outlet_4_Position'] = function (value) g_outletPos [4] = tonumber (value) or g_outletPos [4] end

function RestartEverything ()
	Bridge_Stop ()
	CancelTimer ('MoenPollTimer')
	CancelTimer ('MoenAuthRetryTimer')
	CancelTimer ('MoenWSReconnectTimer')
	CancelTimer ('MoenSendTimeoutCheck')
	g_pendingSends = {}
	g_wsSubscribed = false
	g_socketId = nil
	g_channelName = nil
	g_token = nil
	g_cloudAuthenticated = false
	g_activePollInterval = nil
	if (g_ws) then
		g_ws:delete ()
		g_ws = nil
	end
	NotifyOnline (false)
	StartAuthFlow ()
end

-- v300: the uibutton proxy has no online notification; online state now
-- rides in UI_STATE so the page can show "Offline" instead of stale data.
function NotifyOnline (bOnline)
	local changed = (g_online ~= bOnline)
	g_online = bOnline
	if (changed) then PublishUI () end
end

-- Repeating poll at the idle rate, or the faster running rate while the
-- water is on. Only restarts the timer when the wanted rate changes.
function UpdatePollRate ()
	local want = IsRunning () and g_runningPollInterval or g_pollInterval
	if (want == nil or want < 2) then want = 2 end
	if (want == g_activePollInterval) then return end
	g_activePollInterval = want
	CancelTimer ('MoenPollTimer')
	SetTimer ('MoenPollTimer', want * ONE_SECOND, PollDeviceDetails, true)
	LOG ('Poll interval now ' .. tostring (want) .. 's')
end

function IsRunning ()
	local mode = g_device.mode or 'unknown'
	return (mode ~= 'off' and mode ~= 'paused-by-preset' and mode ~= 'unknown')
end

-- ===================== REST auth / polling chain ============================
-- UNCHANGED FROM v102 - protocol layer is out of scope for this version.
function AuthHeaders ()
	return { ['User-Token'] = g_token }
end

function StartAuthFlow ()
	-- v302: Local Bridge transport replaces the cloud start-up path.
	if (IsBridge ()) then
		Bridge_Start ()
		return
	end
	g_cloudAuthenticated = false
	C4:UpdateProperty ('Cloud Status', 'Authenticating...')
	if (g_email == '' or g_password == '') then
		g_lastError = 'Moen Account Email/Password not configured'
		LOG (g_lastError)
		C4:UpdateProperty ('Cloud Status', 'Not configured (missing email/password)')
		return
	end
	local url = API_BASE_URL .. API_AUTHENTICATE
		.. '?email=' .. URLEncode (g_email) .. '&password=' .. URLEncode (g_password)
	urlGet (url, {}, OnAuthenticateResponse)
end

function ScheduleAuthRetry ()
	g_cloudAuthenticated = false
	C4:UpdateProperty ('Cloud Status', 'Retrying... (' .. tostring (g_lastError) .. ')')
	SetTimer ('MoenAuthRetryTimer', AUTH_RETRY_SECONDS * ONE_SECOND, StartAuthFlow)
end

function OnAuthenticateResponse (strError, code, headers, data, context, url)
	if (strError or code ~= 200 or type (data) ~= 'table' or not data.token) then
		g_lastError = 'authenticate failed: ' .. tostring (strError or code)
		LOG (g_lastError)
		ScheduleAuthRetry ()
		return
	end
	g_token = data.token
	LOG ('Authenticated with Moen cloud')
	urlGet (API_BASE_URL .. API_CREDENTIALS, AuthHeaders (), OnCredentialsResponse)
end

function OnCredentialsResponse (strError, code, headers, data, context, url)
	if (code == 401) then
		g_token = nil
		StartAuthFlow ()
		return
	end
	if (strError or code ~= 200 or type (data) ~= 'table') then
		g_lastError = 'credentials failed: ' .. tostring (strError or code)
		LOG (g_lastError)
		ScheduleAuthRetry ()
		return
	end
	g_pusherKey = data.app_key
	g_pusherCluster = data.cluster
	ResolveSerial ()
end

function ResolveSerial ()
	if (g_configuredSerial ~= nil and g_configuredSerial ~= '') then
		g_serial = g_configuredSerial
		PollDeviceDetails ()
	else
		urlGet (API_BASE_URL .. API_SHOWERS, AuthHeaders (), OnShowersResponse)
	end
end

function OnShowersResponse (strError, code, headers, data, context, url)
	if (code == 401) then
		g_token = nil
		StartAuthFlow ()
		return
	end
	if (strError or code ~= 200 or type (data) ~= 'table' or data [1] == nil) then
		g_lastError = 'no showers found on account'
		LOG (g_lastError)
		ScheduleAuthRetry ()
		return
	end
	g_serial = data [1].serial_number
	LOG ('Auto-selected shower serial ' .. tostring (g_serial))
	PollDeviceDetails ()
end

function PollDeviceDetails ()
	if (IsBridge ()) then
		Bridge_Send ({ cmd = 'get_state' })
		return
	end
	local path = string.format (API_SHOWER_DETAIL, g_serial)
	urlGet (API_BASE_URL .. path, AuthHeaders (), OnDeviceDetailsResponse)
end

function OnDeviceDetailsResponse (strError, code, headers, data, context, url)
	if (code == 401) then
		g_token = nil
		StartAuthFlow ()
		return
	end
	if (strError or code ~= 200 or type (data) ~= 'table') then
		g_cloudAuthenticated = false
		g_lastError = 'device details failed: ' .. tostring (strError or code)
		LOG (g_lastError)
		C4:UpdateProperty ('Cloud Status', 'Error: ' .. g_lastError)
		ScheduleAuthRetry ()
		return
	end

	g_device = data
	g_cloudAuthenticated = true
	g_lastError = ''

	UpdatePollRate ()

	if (g_channelName == nil and data.channel) then
		g_channelName = PUSHER_CHANNEL_PREFIX .. data.channel
		EnsureWebSocket ()
	end

	SyncProxiesFromState ()
	NotifyOnline (true)
end

-- ===================== Pusher WebSocket (persistent connection) ============================
-- UNCHANGED FROM v102.
function EnsureWebSocket ()
	if (g_ws ~= nil) then return end
	if (g_pusherKey == nil or g_pusherCluster == nil) then return end

	local url = string.format ('wss://ws-%s.pusher.com/app/%s?protocol=7&client=c4lua&version=1.0',
		g_pusherCluster, g_pusherKey)

	LOG ('Opening Pusher WebSocket: ' .. url)
	g_ws = WebSocket:new (url)
	g_ws:SetEstablishedFunction (OnWSEstablished)
	g_ws:SetProcessMessageFunction (OnWSMessage)
	g_ws:SetOfflineFunction (OnWSOffline)
	g_ws:SetClosedByRemoteFunction (OnWSOffline)
	g_ws:Start ()
end

function OnWSEstablished (ws)
	LOG ('Pusher WebSocket handshake established, waiting for connection_established event')
end

function OnWSOffline (ws)
	LOG ('Pusher WebSocket offline/closed')
	g_wsSubscribed = false
	g_socketId = nil
	g_ws = nil
	C4:UpdateProperty ('Pusher Status', 'Disconnected')
	SetTimer ('MoenWSReconnectTimer', WS_RECONNECT_SECONDS * ONE_SECOND, EnsureWebSocket)
end

function OnWSMessage (ws, data)
	local ok, msg = pcall (function () return JSON:decode (data) end)
	if (not ok or type (msg) ~= 'table') then
		LOG ('Failed to decode Pusher message: ' .. tostring (data))
		return
	end

	local event = msg.event

	if (event == 'pusher:connection_established') then
		local ok2, inner = pcall (function () return JSON:decode (msg.data or '{}') end)
		if (ok2 and type (inner) == 'table' and inner.socket_id) then
			g_socketId = inner.socket_id
			LOG ('Pusher connection established, socket_id=' .. tostring (g_socketId))
			GetPusherAuthAndSubscribe ()
		end

	elseif (event == 'pusher_internal:subscription_succeeded') then
		g_wsSubscribed = true
		LOG ('Pusher channel subscribed: ' .. tostring (g_channelName))
		C4:UpdateProperty ('Pusher Status', 'Connected / subscribed')
		FlushPendingSends ()

	elseif (event == 'pusher:error') then
		LOG ('Pusher error: ' .. tostring (msg.data))

	elseif (event == 'pusher:ping') then
		if (g_ws) then
			g_ws:Send (JSON:encode ({ event = 'pusher:pong', data = {} }))
		end
	end
	-- Server-pushed device state events (if any) are intentionally ignored here -
	-- this driver relies on REST polling (PollDeviceDetails) for state, same as
	-- the bridge version. Could be added later to reduce state latency further.
end

function GetPusherAuthAndSubscribe ()
	local url = API_BASE_URL .. API_PUSHER_AUTH
	local hdrs = AuthHeaders ()
	hdrs ['Content-Type'] = 'application/x-www-form-urlencoded'
	local body = 'socket_id=' .. URLEncode (g_socketId) .. '&channel_name=' .. URLEncode (g_channelName)
	urlPost (url, body, hdrs, OnPusherAuthResponse)
end

function OnPusherAuthResponse (strError, code, headers, data, context, url)
	if (strError or code ~= 200 or type (data) ~= 'table' or not data.auth) then
		LOG ('pusher-auth failed: ' .. tostring (strError or code))
		return
	end
	if (g_ws == nil) then return end
	local sub = { event = 'pusher:subscribe', data = { channel = g_channelName, auth = data.auth } }
	g_ws:Send (JSON:encode (sub))
end

-- ===================== Control event sending (with subscription-wait fix) ==========
-- UNCHANGED FROM v102. This is the direct Lua port of the fix proven in
-- moen_shower_bridge.py's send_control_event(): NEVER send a "client-"
-- prefixed event until Pusher has confirmed pusher_internal:subscription_succeeded,
-- or Pusher can silently drop it (this was the root cause of a real bug: a
-- multi-outlet preset only turning on one of two outlets).
function SendControlEvent (action, params)
	if (g_ws ~= nil and g_wsSubscribed) then
		DoSendControlEvent (action, params)
		return
	end

	table.insert (g_pendingSends, { action = action, params = params })
	LOG ('Queued control event (waiting on subscription): ' .. action)

	if (g_ws == nil) then
		EnsureWebSocket ()
	end

	SetTimer ('MoenSendTimeoutCheck', PENDING_SEND_TIMEOUT_SECONDS * ONE_SECOND, CheckPendingSendTimeout)
end

function DoSendControlEvent (action, params)
	local frame = {
		event = 'client-state-desired',
		channel = g_channelName,
		data = { type = 'control', data = { action = action, params = params } },
	}
	g_ws:Send (JSON:encode (frame))
	LOG ('Sent control event: ' .. action)
	SetTimer ('MoenPostCommandRefresh', 1500, PollDeviceDetails)
end

function FlushPendingSends ()
	local queued = g_pendingSends
	g_pendingSends = {}
	CancelTimer ('MoenSendTimeoutCheck')
	for _, item in ipairs (queued) do
		DoSendControlEvent (item.action, item.params)
	end
end

function CheckPendingSendTimeout ()
	if (#g_pendingSends == 0) then return end
	if (g_wsSubscribed) then
		FlushPendingSends ()
		return
	end
	LOG ('WARNING: dropping ' .. #g_pendingSends .. ' queued command(s) - Pusher subscription never confirmed in time')
	g_pendingSends = {}
end

-- ===================== High-level Moen actions ============================
-- UNCHANGED FROM v102 - reused as-is per the plan ("reuse those functions
-- unchanged - they contain the proven payload construction"). Every one of
-- these is reachable only from an explicit RFP proxy command or EC Composer
-- command below - never from driver load/reconnect/property-change/resync.
function Action_ShowerOn ()
	if (IsBridge ()) then Bridge_Power (true) return end
	if (g_device.mode == 'paused-by-preset' and g_device.active_preset) then
		SendControlEvent ('shower_on', { preset = tostring (g_device.active_preset) })
	else
		SendControlEvent ('shower_on', { preset = '0' })
	end
end

function Action_ShowerOff ()
	if (IsBridge ()) then Bridge_Power (false) return end
	SendControlEvent ('shower_off', {})
end

function Action_Resume ()
	if (IsBridge ()) then Bridge_Power (true) return end
	local activePreset = g_device.active_preset
	if (activePreset == nil) then
		LOG ('Cannot resume: no active_preset known')
		return
	end
	SendControlEvent ('shower_on', { preset = tostring (activePreset) })
end

function Action_SetTemperature (tempF)
	if (IsBridge ()) then Bridge_SetTemperature (tempF) return end
	SendControlEvent ('temperature_set', { target_temperature = math.floor (tempF + 0.5) })
end

function Action_SetOutlet (position, active)
	if (IsBridge ()) then Bridge_Outlet (position, active) return end
	local outlets = g_device.outlets or {}
	local outletStates = {}
	for _, o in ipairs (outlets) do
		local isActive = o.active or false
		if (o.position == position) then isActive = active end
		table.insert (outletStates, { position = o.position, active = isActive })
	end
	SendControlEvent ('outlets_set', { outlets = outletStates })
end

-- v301: forcePause (keypad starts only) sends ready_pauses_water = true so
-- the water stops at temperature instead of running until someone arrives.
function Action_ActivatePreset (position, forcePause)
	if (IsBridge ()) then
		if (forcePause == true) then
			LOG ('Keypad pause-when-ready is not supported by the Local Bridge; preset runs normally')
		end
		Bridge_Preset (position)
		return
	end
	local presets = g_device.presets or {}
	local preset
	for _, p in ipairs (presets) do
		if (p.position == position) then preset = p end
	end
	if (preset == nil) then
		LOG ('Preset ' .. tostring (position) .. ' not found on device')
		return
	end
	local params = {
		active_preset = position,
		title = preset.title or '',
		greeting = preset.greeting or '',
		target_temperature = preset.target_temperature or 100,
		outlets = preset.outlets or {},
		timer_enabled = preset.timer_enabled or false,
		timer_length = preset.timer_length or 600,
		timer_ends_shower = preset.timer_ends_shower or false,
		timer_sounds_alert = (preset.timer_sounds_alert ~= false),
		ready_pauses_water = (forcePause == true) or preset.ready_pauses_water or false,
		ready_pushes_notification = preset.ready_pushes_notification or false,
		ready_sounds_alert = (preset.ready_sounds_alert ~= false),
	}
	-- Sending shower_set alone activates the preset AND turns the shower on -
	-- do not also send shower_on (matches api.py's activate_preset() note).
	SendControlEvent ('shower_set', params)
end

-- ===================== Temperature bounds helper ============================
-- UNCHANGED FROM v102.
function ClampTemp (t)
	t = tonumber (t)
	if (t == nil) then return g_tempMin end
	if (t < g_tempMin) then return g_tempMin end
	if (t > g_tempMax) then return g_tempMax end
	return t
end

-- ===================== Preset display helper ============================
-- Extras buttons must show the live preset title, never a hardcoded name -
-- presets are per-account and user-editable in the Moen app (this account
-- currently has 2, not 4 - do not assume a fixed count either).
function PresetDisplayName (p)
	if (p.title ~= nil and p.title ~= '') then return p.title end
	return 'Preset ' .. tostring (p.position)
end

-- ===================== Outlet display names ============================
-- No longer used by the UI (outlets aren't in Navigator in v200), kept for
-- ACTION_PRINT_DEBUG and possible future Composer-programming use.
OUTLET_ICON_NAMES = {
	[0] = 'Shower Head', [1] = 'Rain Shower', [2] = 'Hand Shower',
	[3] = 'Body Spray', [4] = 'Valve', [5] = 'Water Feature', [6] = 'Tub Spout',
}

function OutletDisplayName (o)
	if (o.name ~= nil and o.name ~= '') then return o.name end
	if (o.icon_index ~= nil and OUTLET_ICON_NAMES [o.icon_index] ~= nil) then
		return OUTLET_ICON_NAMES [o.icon_index]
	end
	return 'Outlet ' .. tostring (o.position)
end

-- ===================== Simple XML text-escaping helper ============================
-- XMLEncode was previously provided transitively via drivers-common-public;
-- kept explicit here so Extras label/text building never depends on preset
-- titles happening to be XML-safe (they're free-text in the Moen app).
function ExtrasXMLEncode (s)
	s = tostring (s or '')
	s = s:gsub ('&', '&amp;')
	s = s:gsub ('<', '&lt;')
	s = s:gsub ('>', '&gt;')
	s = s:gsub ('"', '&quot;')
	return s
end

-- ===================== State sync (Moen state -> page, variables, events) ====
function SyncProxiesFromState ()
	local mode = g_device.mode or 'unknown'
	local isRunning = IsRunning ()

	-- Events fire on transitions only, never on the first state after load.
	if (g_lastMode ~= nil and g_lastMode ~= mode) then
		local wasRunning = (g_lastMode ~= 'off' and g_lastMode ~= 'paused-by-preset' and g_lastMode ~= 'unknown')
		if (isRunning and not wasRunning) then C4:FireEvent ('Shower Started') end
		if (mode == 'ready') then C4:FireEvent ('Shower Ready') end
		if (mode == 'off' and g_lastMode ~= 'unknown') then C4:FireEvent ('Shower Stopped') end
	end
	g_lastMode = mode

	C4:SetVariable ('SHOWER_RUNNING', isRunning and '1' or '0')
	C4:SetVariable ('SHOWER_MODE', mode)
	C4:SetVariable ('CURRENT_TEMP', tostring (math.floor ((tonumber (g_device.current_temperature) or 0) + 0.5)))
	C4:SetVariable ('TARGET_TEMP', tostring (math.floor ((tonumber (g_device.target_temperature) or 0) + 0.5)))
	C4:SetVariable ('ACTIVE_PRESET', tostring (tonumber (g_device.active_preset) or 0))

	local icon = isRunning and 'Running' or 'Default'
	if (icon ~= g_lastIcon) then
		C4:SendToProxy (MASTER_BINDING, 'ICON_CHANGED',
			{ icon = icon, icon_description = isRunning and 'Shower running' or 'Shower off' }, 'NOTIFY')
		g_lastIcon = icon
	end

	PublishUI ()
	UpdateKeyLeds ()

	C4:UpdateProperty ('Shower Mode', mode)
	C4:UpdateProperty ('Device Serial Number', g_serial or '')
	C4:UpdateProperty ('Device Name', g_device.name or '')

	local cloudStr
	if (not g_cloudAuthenticated) then
		cloudStr = 'Not authenticated with Moen'
	else
		cloudStr = 'Authenticated'
	end
	if (g_lastError ~= nil and g_lastError ~= '') then
		cloudStr = cloudStr .. ' (last error: ' .. g_lastError .. ')'
	end
	C4:UpdateProperty ('Cloud Status', IsBridge () and 'Not used (Local Bridge)' or cloudStr)

	C4:UpdateProperty ('Pusher Status', IsBridge () and 'Not used (Local Bridge)' or (g_wsSubscribed and 'Connected / subscribed' or 'Connecting...'))
end

-- ===================== Web view state ============================
-- One JSON snapshot of everything the page draws. Arrays are always real
-- Lua arrays (possibly empty); the page accepts {} or [] for an empty list.
function BuildUIState ()
	local presets = {}
	for _, p in ipairs (g_device.presets or {}) do
		local outs = {}
		for _, o in ipairs (p.outlets or {}) do
			if (type (o) == 'table' and o.active ~= false and o.position ~= nil) then
				table.insert (outs, tonumber (o.position) or o.position)
			end
		end
		table.insert (presets, {
			pos = tonumber (p.position) or p.position,
			title = PresetDisplayName (p),
			temp = tonumber (p.target_temperature),
			outlets = outs,
			timer = (p.timer_enabled and tonumber (p.timer_length)) or nil,
		})
	end
	local outlets = {}
	for _, o in ipairs (g_device.outlets or {}) do
		table.insert (outlets, {
			pos = tonumber (o.position) or o.position,
			name = OutletDisplayName (o),
			icon = tonumber (o.icon_index),
			on = (o.active == true),
		})
	end
	g_uiSeq = g_uiSeq + 1
	return {
		t = 'moen',
		seq = g_uiSeq,
		build = PAGE_BUILD,
		online = (g_online and (IsBridge () or g_cloudAuthenticated)) and true or false,
		configured = (IsBridge () and g_bridgeHost ~= '') or (g_email ~= '' and g_password ~= ''),
		linked = (IsBridge () and g_bridgeLinked or g_wsSubscribed) and true or false,
		err = g_lastError or '',
		name = g_device.name or '',
		mode = g_device.mode or 'unknown',
		running = IsRunning (),
		cur = tonumber (g_device.current_temperature),
		tgt = tonumber (g_device.target_temperature),
		min = g_tempMin,
		max = g_tempMax,
		active = tonumber (g_device.active_preset),
		presets = presets,
		outlets = outlets,
	}
end

function PublishUI ()
	local ok, json = pcall (function () return JSON:encode (BuildUIState ()) end)
	if (not ok) then
		LOG ('PublishUI encode failed: ' .. tostring (json))
		return
	end
	C4:SetVariable ('UI_STATE', json)
	pcall (C4.SendDataToUI, C4, json)
end

-- ===================== Proxy commands (Navigator -> this driver) ============================
RFP = RFP or {}

RFP [MASTER_BINDING] = function (idBinding, strCommand, tParams, args)
	-- v300: the uibutton proxy may send SELECT when the tile is tapped. It is
	-- deliberately NOT a toggle - opening the page must never start water.
	if (strCommand == 'SELECT') then
		PublishUI ()
		return
	end
	LOG ('Unhandled uibutton proxy command: ' .. tostring (strCommand))
	if (tParams) then
		for k, v in pairs (tParams) do
			LOG ('  param ' .. tostring (k) .. ' = ' .. tostring (v))
		end
	end
end

g_deferredTemp = nil
function OnDeferredSetTemp ()
	if (g_deferredTemp ~= nil) then
		Action_SetTemperature (g_deferredTemp)
		g_deferredTemp = nil
	end
end

g_pendingOutletPos = nil
g_pendingOutletState = nil

function OnDeferredSetOutlet ()
	if (g_pendingOutletPos ~= nil) then
		Action_SetOutlet (g_pendingOutletPos, g_pendingOutletState)
		g_pendingOutletPos = nil
		g_pendingOutletState = nil
	end
end

-- ===================== Local Bridge transport (v302) ============================
-- Talks to a small TCP bridge on the LAN (JSON lines, default port 8765)
-- instead of Moen's cloud. Selected by the "Transport" property. The cloud
-- code above is unchanged and remains selectable as "Moen Cloud".
-- SAFETY: connecting, reconnecting, the state line the bridge sends on
-- connect, page open, UI_REFRESH and the tile tap never start water. Only an
-- explicit Action_* call (shower on, resume, preset, outlet on) sends on/preset.
-- Setpoint changes are ignored while the shower is not running.
-- The bridge has no "pause when ready" flag, so the keypad force-pause option
-- is ignored on this transport (logged).
OCS = OCS or {}   -- handlers.lua dispatch tables; the bridge uses binding 7001
RFN = RFN or {}
BRIDGE_BINDING         = 7001   -- dynamic network binding, outside the websocket module's scan range
BRIDGE_RECONNECT_FIRST = 5
BRIDGE_RECONNECT_MAX   = 60
g_transport     = 'Local Bridge'
g_bridgeHost    = ''
g_bridgePort    = 8765
g_bridgeStatus  = 'Unknown'
g_bridgeWanted  = false
g_bridgeLinked  = false
g_bridgeBuffer  = ''
g_bridgeBackoff = BRIDGE_RECONNECT_FIRST

function IsBridge ()
	return (g_transport == 'Local Bridge')
end

function Bridge_SetStatus (s)
	g_bridgeStatus = s
	C4:UpdateProperty ('Bridge Status', s)
	LOG ('Bridge: ' .. s)
end

function OnlineNow ()
	if (IsBridge ()) then
		return (g_bridgeLinked and g_device.shower_connected == true) and true or false
	end
	return g_cloudAuthenticated
end

function Bridge_Start ()
	g_bridgeWanted = true
	if (g_bridgeHost == nil or g_bridgeHost == '') then
		Bridge_SetStatus ('Set Bridge Host to the IP of the bridge machine')
		return
	end
	Bridge_Connect ()
end

function Bridge_Connect ()
	if (not g_bridgeWanted or g_bridgeHost == '') then return end
	CancelTimer ('MoenBridgeReconnect')
	g_bridgeBuffer = ''
	OCS [BRIDGE_BINDING] = Bridge_OnConnectionStatus
	RFN [BRIDGE_BINDING] = Bridge_OnData
	C4:CreateNetworkConnection (BRIDGE_BINDING, g_bridgeHost, 'TCP')
	C4:NetConnect (BRIDGE_BINDING, g_bridgePort)
	Bridge_SetStatus ('Connecting to ' .. g_bridgeHost .. ':' .. tostring (g_bridgePort))
end

function Bridge_Stop ()
	g_bridgeWanted = false
	CancelTimer ('MoenBridgeReconnect')
	if (g_bridgeLinked and g_bridgeHost ~= '') then
		pcall (function () C4:NetDisconnect (BRIDGE_BINDING, g_bridgePort) end)
	end
	OCS [BRIDGE_BINDING] = nil
	RFN [BRIDGE_BINDING] = nil
	g_bridgeLinked = false
	g_bridgeBuffer = ''
	g_bridgeBackoff = BRIDGE_RECONNECT_FIRST
end

function Bridge_ScheduleReconnect ()
	local delay = g_bridgeBackoff
	g_bridgeBackoff = math.min (g_bridgeBackoff * 2, BRIDGE_RECONNECT_MAX)
	Bridge_SetStatus ('Disconnected; retrying in ' .. delay .. 's')
	SetTimer ('MoenBridgeReconnect', delay * ONE_SECOND, Bridge_Connect)
end

function Bridge_OnConnectionStatus (idBinding, nPort, strStatus)
	if (strStatus == 'ONLINE') then
		g_bridgeLinked = true
		g_bridgeBackoff = BRIDGE_RECONNECT_FIRST
		g_bridgeBuffer = ''
		Bridge_SetStatus ('Connected; waiting for state')
		Bridge_Send ({ cmd = 'get_state' })
	else
		g_bridgeLinked = false
		g_bridgeBuffer = ''
		NotifyOnline (false)
		if (g_bridgeWanted) then Bridge_ScheduleReconnect () end
	end
end

-- Line buffering: TCP delivers arbitrary chunks; split on \n only.
function Bridge_OnData (idBinding, nPort, strData)
	g_bridgeBuffer = g_bridgeBuffer .. (strData or '')
	if (#g_bridgeBuffer > 65536) then g_bridgeBuffer = '' end
	while (true) do
		local nl = string.find (g_bridgeBuffer, '\n', 1, true)
		if (nl == nil) then break end
		local line = string.sub (g_bridgeBuffer, 1, nl - 1)
		g_bridgeBuffer = string.sub (g_bridgeBuffer, nl + 1)
		line = string.gsub (line, '\r$', '')
		if (line ~= '') then Bridge_OnLine (line) end
	end
end

function Bridge_OnLine (line)
	local ok, msg = pcall (function () return C4:JsonDecode (line) end)
	if (not ok or type (msg) ~= 'table') then
		LOG ('Bridge: could not decode line')
		return
	end
	if (msg.event == 'state') then
		Bridge_OnState (msg)
	elseif (msg.event == 'error') then
		Bridge_SetStatus ('Bridge error: ' .. tostring (msg.msg))
	end
end

-- Maps the bridge state line onto g_device, so SyncProxiesFromState, the
-- web view snapshot (BuildUIState) and the keypad logic work unchanged.
function Bridge_OnState (msg)
	g_device = g_device or {}
	g_device.shower_connected = (msg.shower_connected == true)
	g_device.mode = (msg.on == true) and 'adjusting' or 'off'
	g_device.current_temperature = msg.current_f
	g_device.target_temperature = msg.target_f
	g_device.active_preset = msg.active_preset
	g_tempMin = tonumber (msg.min_f) or g_tempMin
	g_tempMax = tonumber (msg.max_f) or g_tempMax

	g_device.outlets = {}
	for i, v in ipairs (msg.outlets or {}) do
		table.insert (g_device.outlets, { position = i, active = (v == true) })
	end

	g_device.presets = {}
	for _, p in ipairs (msg.presets or {}) do
		local outl = {}
		for _, n in ipairs (p.outlets or {}) do
			table.insert (outl, { position = tonumber (n), active = true })
		end
		table.insert (g_device.presets, {
			position = tonumber (p.n),
			title = p.title or '',
			target_temperature = p.temp_f,
			outlets = outl,
		})
	end

	if (g_bridgeStatus ~= 'Connected') then Bridge_SetStatus ('Connected') end
	NotifyOnline (OnlineNow ())
	SyncProxiesFromState ()
end

function Bridge_Send (tCmd)
	if (not g_bridgeLinked) then
		LOG ('Bridge not connected; command dropped: ' .. tostring (tCmd.cmd))
		return false
	end
	local ok, s = pcall (function () return C4:JsonEncode (tCmd) end)
	if (not ok or s == nil) then return false end
	C4:SendToNetwork (BRIDGE_BINDING, g_bridgePort, s .. '\n')
	return true
end

-- Explicit user actions only. The optimistic mode is corrected by the next
-- state line from the bridge.
function Bridge_Power (wantOn)
	if (Bridge_Send ({ cmd = (wantOn and 'on' or 'off') })) then
		g_device = g_device or {}
		g_device.mode = wantOn and 'adjusting' or 'off'
		SyncProxiesFromState ()
	end
end

function Bridge_SetTemperature (tempF)
	if (not IsRunning ()) then
		LOG ('Setpoint change ignored: shower is not running')
		return
	end
	Bridge_Send ({ cmd = 'set_temp', f = math.floor (ClampTemp (tempF) + 0.5) })
end

function Bridge_Outlet (position, active)
	Bridge_Send ({ cmd = 'outlet', n = position, on = (active == true) })
end

function Bridge_Preset (position)
	if (Bridge_Send ({ cmd = 'preset', n = position })) then
		g_device = g_device or {}
		g_device.mode = 'adjusting'
		SyncProxiesFromState ()
	end
end

OPC = OPC or {}
OPC ['Transport'] = function (value)
	g_transport = value or g_transport
	RestartEverything ()
end
OPC ['Bridge_Host'] = function (value)
	g_bridgeHost = value or ''
	RestartEverything ()
end
OPC ['Bridge_Port'] = function (value)
	g_bridgePort = tonumber (value) or g_bridgePort
	RestartEverything ()
end

-- ===================== Driver commands / Composer actions ============================
EC = EC or {}

EC ['Shower_On'] = function () Action_ShowerOn () end
EC ['ACTION_SHOWER_ON'] = function () Action_ShowerOn () end

EC ['Shower_Off'] = function () Action_ShowerOff () end
EC ['ACTION_SHOWER_OFF'] = function () Action_ShowerOff () end

EC ['Set_Temperature'] = function (tParams)
	local temp = ClampTemp (tParams ['Temperature'])
	local mode = g_device.mode or 'off'
	if (mode == 'off') then
		Action_ShowerOn ()
		g_deferredTemp = temp
		SetTimer ('MoenDeferredSetTemp', 800, OnDeferredSetTemp)
	elseif (mode == 'paused-by-preset') then
		Action_Resume ()
		g_deferredTemp = temp
		SetTimer ('MoenDeferredSetTemp', 800, OnDeferredSetTemp)
	else
		Action_SetTemperature (temp)
	end
end

EC ['Set_Outlet'] = function (tParams)
	local position = tonumber (tParams ['Outlet'])
	local wantOn = (tostring (tParams ['State']) == 'ON')
	if (position == nil) then
		LOG ('Set Outlet command received with no/invalid Outlet param')
		return
	end
	local mode = g_device.mode or 'off'
	if (wantOn and (mode == 'off' or mode == 'paused-by-preset')) then
		Action_ShowerOn ()
		g_pendingOutletPos = position
		g_pendingOutletState = wantOn
		SetTimer ('MoenDeferredSetOutlet', 800, OnDeferredSetOutlet)
	else
		Action_SetOutlet (position, wantOn)
	end
end

EC ['Activate_Preset'] = function (tParams)
	local posStr = tParams ['Position'] or '1'
	Action_ActivatePreset (tonumber (posStr) or 1)
end

EC ['ACTION_PRESET_1'] = function () Action_ActivatePreset (1) end
EC ['ACTION_PRESET_2'] = function () Action_ActivatePreset (2) end
EC ['ACTION_PRESET_3'] = function () Action_ActivatePreset (3) end
EC ['ACTION_PRESET_4'] = function () Action_ActivatePreset (4) end

EC ['Resume_Paused_Shower'] = function () Action_Resume () end
EC ['ACTION_RESUME'] = function () Action_Resume () end

EC ['Refresh_Status'] = function () PollDeviceDetails () end
EC ['ACTION_REFRESH_STATUS'] = function () PollDeviceDetails () end


-- ===================== Keypad keys (v301) ============================
-- Keypad buttons bind straight to these connections in Composer (no
-- programming). Same proven pattern as the AnacommSystems fanspeed and
-- keypadsecurity drivers:
--   tap  = DO_PUSH then DO_CLICK (some keypads also send DO_RELEASE - one
--          physical press must count once)
--   hold = DO_PUSH, hold timer fires while the key is still down, then
--          DO_RELEASE (ignored)
--   LED  = BUTTON_COLORS {ON_COLOR, OFF_COLOR} (NOTIFY) + MATCH_LED_STATE
--          with STATE "True"/"False" as WORDS ("1"/"0" is silently ignored).
--          Updates are paced 75 ms apart and only sent when they change.
-- Bindings 901-904 = Preset Key 1-4, 905 = Shower Key.
--
-- SAFETY (keypads are usually outside the shower):
--   * a key only ever starts water from an explicit tap
--   * "Keypad Pause When Ready" sends the preset with ready_pauses_water,
--     so remote starts stop at temperature and wait
--   * a preset key does nothing while a DIFFERENT preset is running unless
--     "If Another Preset Is Running" says otherwise - nobody standing in the
--     shower gets their temperature changed by a stray tap elsewhere
--   * hold on any key always stops the shower
PRESET_KEY_FIRST = 901
PRESET_KEY_LAST  = 904
SHOWER_KEY       = 905
OPTIMISTIC_SECONDS = 15

g_key = { held = {}, armed = {}, lastLed = {} }
g_keyOptimistic = nil   -- { preset = n|nil, running = bool, at = os.time() }
g_ledQueue = {}

local function propYes (name, default)
	local v = Properties [name]
	if (v == nil or v == '') then return default end
	return (v == 'Yes')
end

local function holdMs ()
	local ms = tonumber (Properties ['Key Hold Time (ms)']) or 1000
	if (ms < 300) then ms = 300 end
	return ms
end

local function colorHex (name, fallback)
	local r, g, b = tostring (Properties [name] or fallback):match ('(%d+)%s*,%s*(%d+)%s*,%s*(%d+)')
	if (r == nil) then r, g, b = fallback:match ('(%d+),(%d+),(%d+)') end
	local function c (x) x = math.max (0, math.min (255, tonumber (x) or 0)); return string.format ('%02x', x) end
	return c (r) .. c (g) .. c (b)
end

function KeyPresetPosition (binding)
	local n = binding - PRESET_KEY_FIRST + 1
	return tonumber (Properties ['Preset Key ' .. n .. ' Preset']) or n
end

-- Live state, overlaid for a few seconds by what a key just asked for, so
-- the LED answers the press immediately instead of after the next poll.
function KeyViewState ()
	local mode = g_device.mode or 'unknown'
	local running = IsRunning ()
	local paused = (mode == 'paused-by-preset')
	local active = tonumber (g_device.active_preset)
	local o = g_keyOptimistic
	if (o ~= nil) then
		local agrees = (o.running and (running or paused) and (o.preset == nil or o.preset == active))
			or ((not o.running) and mode == 'off')
		if (agrees or os.time () - o.at > OPTIMISTIC_SECONDS) then
			g_keyOptimistic = nil
		else
			return { mode = o.running and 'adjusting' or 'off', on = o.running, preset = o.preset or active }
		end
	end
	return { mode = mode, on = (running or paused), preset = active }
end

local function stageColor (view)
	if (view.mode == 'ready' or view.mode == 'paused-by-preset') then
		return colorHex ('Ready Color', '0,255,0')
	end
	return colorHex ('Warming Color', '255,140,0')
end

function KeyLedFor (binding, view)
	local lit = false
	if (binding == SHOWER_KEY) then
		lit = view.on
	else
		lit = view.on and view.preset == KeyPresetPosition (binding)
	end
	return {
		on = lit and stageColor (view) or colorHex ('Ready Color', '0,255,0'),
		off = colorHex ('Idle Color', '0,0,0'),
		state = lit and 'True' or 'False',
	}
end

local function flushLedQueue ()
	local item = table.remove (g_ledQueue, 1)
	if (item == nil) then return end
	C4:SendToProxy (item.binding, 'BUTTON_COLORS',
		{ ON_COLOR = { COLOR_STR = item.led.on }, OFF_COLOR = { COLOR_STR = item.led.off } }, 'NOTIFY')
	C4:SendToProxy (item.binding, 'MATCH_LED_STATE', { STATE = item.led.state })
	if (#g_ledQueue > 0) then
		SetTimer ('MoenKeyLedPace', 75, flushLedQueue)
	end
end

function UpdateKeyLeds (force, onlyBinding)
	local view = KeyViewState ()
	for b = PRESET_KEY_FIRST, SHOWER_KEY do
		if (onlyBinding == nil or onlyBinding == b) then
			local led = KeyLedFor (b, view)
			local sig = led.on .. '/' .. led.off .. '/' .. led.state
			if (force or g_key.lastLed [b] ~= sig) then
				g_key.lastLed [b] = sig
				for i = #g_ledQueue, 1, -1 do
					if (g_ledQueue [i].binding == b) then table.remove (g_ledQueue, i) end
				end
				table.insert (g_ledQueue, { binding = b, led = led })
			end
		end
	end
	if (#g_ledQueue > 0 and Timer ['MoenKeyLedPace'] == nil) then
		flushLedQueue ()
	end
end

-- ---- what a tap / hold does ----
function KeyStop (why)
	LOG ('Key: stop shower (' .. why .. ')')
	g_keyOptimistic = { running = false, at = os.time () }
	Action_ShowerOff ()
end

function KeyStartPreset (position)
	if (not g_cloudAuthenticated) then
		LOG ('Key ignored: not connected to Moen')
		return
	end
	local found = false
	for _, p in ipairs (g_device.presets or {}) do
		if (tonumber (p.position) == position) then found = true end
	end
	if (not found) then
		LOG ('Key ignored: Moen has no preset in position ' .. tostring (position))
		return
	end
	LOG ('Key: start preset ' .. position)
	g_keyOptimistic = { running = true, preset = position, at = os.time () }
	Action_ActivatePreset (position, propYes ('Keypad Pause When Ready', true))
end

function KeyTap (binding)
	local view = KeyViewState ()
	local mode = g_device.mode or 'unknown'

	if (binding == SHOWER_KEY) then
		if (mode == 'paused-by-preset') then
			LOG ('Shower key: resume')
			g_keyOptimistic = { running = true, preset = view.preset, at = os.time () }
			Action_Resume ()
		elseif (view.on) then
			KeyStop ('Shower key tap while running')
		else
			local last = tonumber (g_device.active_preset) or tonumber (Properties ['Preset Key 1 Preset']) or 1
			KeyStartPreset (last)
		end
	else
		local mine = KeyPresetPosition (binding)
		if (not view.on) then
			KeyStartPreset (mine)
		elseif (view.preset == mine) then
			if (mode == 'paused-by-preset') then
				LOG ('Preset key: resume preset ' .. mine)
				g_keyOptimistic = { running = true, preset = mine, at = os.time () }
				Action_Resume ()
			else
				KeyStop ('tap on the running preset')
			end
		elseif (Properties ['If Another Preset Is Running'] == 'Switch to this preset') then
			KeyStartPreset (mine)
		else
			LOG ('Preset key ' .. mine .. ' ignored: preset ' .. tostring (view.preset) .. ' is running')
			UpdateKeyLeds (true, binding)
		end
	end
	PublishUI ()
	UpdateKeyLeds ()
end

function KeyHold (binding)
	local view = KeyViewState ()
	if (view.on or (g_device.mode or 'off') ~= 'off') then
		KeyStop ('hold')
	else
		LOG ('Key hold ignored: shower already off')
	end
	PublishUI ()
	UpdateKeyLeds ()
end

-- ---- raw keypad traffic ----
local function onPush (b)
	g_key.held [b] = false
	g_key.armed [b] = true
	SetTimer ('MoenKeyHold' .. b, holdMs (), function ()
		if (g_key.armed [b]) then
			g_key.held [b] = true
			KeyHold (b)
		end
	end)
end

local function onUp (b, cmd)
	CancelTimer ('MoenKeyHold' .. b)
	local wasArmed, wasHeld = g_key.armed [b], g_key.held [b]
	g_key.armed [b] = nil
	g_key.held [b] = nil
	if (not wasArmed) then return end   -- second up-message of one press, or stray release
	if (wasHeld) then return end        -- hold already handled while the key was down
	KeyTap (b)
end

for b = PRESET_KEY_FIRST, SHOWER_KEY do
	RFP [b] = function (idBinding, strCommand, tParams)
		local cmd = string.upper (tostring (strCommand or ''))
		if (cmd == 'DO_PUSH') then onPush (idBinding)
		elseif (cmd == 'DO_CLICK' or cmd == 'DO_RELEASE') then onUp (idBinding, cmd)
		elseif (cmd == 'REQUEST_BUTTON_COLORS') then UpdateKeyLeds (true, idBinding)
		else LOG ('Key ' .. idBinding .. ' unhandled: ' .. cmd) end
	end
	OBC = OBC or {}
	OBC [b] = function (idBinding, strClass, bIsBound)
		g_key.lastLed [idBinding] = nil
		if (bIsBound) then UpdateKeyLeds (true, idBinding) end
	end
end

OPC ['Idle_Color']    = function () UpdateKeyLeds (true) end
OPC ['Warming_Color'] = function () UpdateKeyLeds (true) end
OPC ['Ready_Color']   = function () UpdateKeyLeds (true) end
for n = 1, 4 do
	OPC ['Preset_Key_' .. n .. '_Preset'] = function () UpdateKeyLeds (true) end
end

EC ['ACTION_REPAINT_KEYS'] = function () UpdateKeyLeds (true) end

-- ===================== Web view commands (page -> driver) ============================
-- All parameter-free; any value is carried in the command name. Each one
-- republishes UI_STATE straight away so the page's "Sending..." clears even
-- if Moen's state hasn't changed yet; the post-command poll follows.
EC ['UI_REFRESH'] = function ()
	PublishUI ()
	if (IsBridge () or g_cloudAuthenticated) then PollDeviceDetails () end
end
EC ['UI_SHOWER_ON']  = function () Action_ShowerOn ();  PublishUI () end
EC ['UI_SHOWER_OFF'] = function () Action_ShowerOff (); PublishUI () end
EC ['UI_RESUME']     = function () Action_Resume ();    PublishUI () end

for i = 0, 16 do
	EC ['UI_PRESET_' .. i] = function () Action_ActivatePreset (i); PublishUI () end
	EC ['UI_OUTLET_' .. i .. '_ON']  = function () EC ['Set_Outlet'] ({ Outlet = tostring (i), State = 'ON' });  PublishUI () end
	EC ['UI_OUTLET_' .. i .. '_OFF'] = function () EC ['Set_Outlet'] ({ Outlet = tostring (i), State = 'OFF' }); PublishUI () end
end

-- Temperature from the page only applies while the water is running; the
-- page also greys the stepper out when it isn't. It never starts water.
for t = 40, 130 do
	EC ['UI_TEMP_SET_' .. t] = function ()
		if (IsRunning ()) then
			Action_SetTemperature (ClampTemp (t))
		else
			LOG ('Ignored page temperature ' .. t .. ' - shower not running')
		end
		PublishUI ()
	end
end

-- The page announces its build when it opens. Navigator caches pages, so a
-- mismatch means the tablet is showing an old page.
for b = 1, 99 do
	EC ['UI_HELLO_' .. b] = function ()
		if (tostring (b) == PAGE_BUILD) then
			C4:UpdateProperty ('Web Page Status', 'Page build ' .. b .. ' OK')
			LOG ('Web page opened, build ' .. b)
		else
			C4:UpdateProperty ('Web Page Status', 'PAGE IS STALE: page ' .. b .. ', driver expects ' .. PAGE_BUILD)
			print ('[MoenShowerSA] PAGE IS STALE: page build ' .. b .. ', driver expects ' .. PAGE_BUILD)
		end
		PublishUI ()
	end
end

EC ['ACTION_PRINT_DEBUG'] = function ()
	print ('=== Moen Smart Shower Standalone Driver Debug (v' .. DRIVER_VERSION .. ') ===')
	print ('cloud_authenticated=' .. tostring (g_cloudAuthenticated) ..
		' ws_subscribed=' .. tostring (g_wsSubscribed) ..
		' last_error=' .. tostring (g_lastError))
	print ('serial=' .. tostring (g_serial) .. ' channel=' .. tostring (g_channelName))
	print ('mode=' .. tostring (g_device.mode) ..
		' current_temp=' .. tostring (g_device.current_temperature) ..
		' target_temp=' .. tostring (g_device.target_temperature) ..
		' active_preset=' .. tostring (g_device.active_preset))
	local outlets = g_device.outlets or {}
	for _, o in ipairs (outlets) do
		print ('outlet position=' .. tostring (o.position) .. ' active=' .. tostring (o.active) ..
			' name=' .. tostring (OutletDisplayName (o)))
	end
	local presets = g_device.presets or {}
	for _, p in ipairs (presets) do
		print ('preset position=' .. tostring (p.position) .. ' title=' .. tostring (p.title))
	end
	print ('pending sends queued=' .. tostring (#g_pendingSends))
	print ('page=' .. PAGE_FILE .. ' build=' .. PAGE_BUILD .. ' ui_seq=' .. tostring (g_uiSeq) ..
		' poll=' .. tostring (g_activePollInterval) .. 's')
end
