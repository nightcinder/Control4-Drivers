--[[==============================================================================
	Moen Smart Shower / U by Moen Digital Shower Valve - Control4 Driver
	STANDALONE VERSION - no external Python bridge required.
	Unofficial / community driver. Not affiliated with or supported by
	Moen, Fortune Brands, or Control4.

	Same project/author as Moen_Smart_Shower_driver.lua (the bridge-based
	version), Haiku_SenseME_driver.lua, and IntelliFire_driver.lua.

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
MASTER_BINDING  = 5001

AUTH_RETRY_SECONDS = 15
WS_RECONNECT_SECONDS = 5
PENDING_SEND_TIMEOUT_SECONDS = 10

-- ===================== Globals / Config ============================
g_email          = ''
g_password       = ''
g_configuredSerial = ''
g_pollInterval   = 20
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

g_thermostatCapsSent = false  -- ALLOWED_HVAC_MODES_CHANGED sent once
g_extrasSetupSignature = nil  -- last preset-list signature sent via EXTRAS_SETUP_CHANGED

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
	LOG ('OnDriverInit')
end

-- SAFETY: this function (and everything it calls) must never call
-- Action_ShowerOn. It only authenticates and starts polling/subscribing -
-- see the safety rule in the file header.
function OnDriverLateInit ()
	LoadProperties ()
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
	g_logMode          = Properties ['Log Mode'] or g_logMode
	g_tempMin          = tonumber (Properties ['Target Temp Min (F)']) or g_tempMin
	g_tempMax          = tonumber (Properties ['Target Temp Max (F)']) or g_tempMax

	g_outletPos [1] = tonumber (Properties ['Outlet 1 Position']) or g_outletPos [1]
	g_outletPos [2] = tonumber (Properties ['Outlet 2 Position']) or g_outletPos [2]
	g_outletPos [3] = tonumber (Properties ['Outlet 3 Position']) or g_outletPos [3]
	g_outletPos [4] = tonumber (Properties ['Outlet 4 Position']) or g_outletPos [4]
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
	if (g_cloudAuthenticated) then
		CancelTimer ('MoenPollTimer')
		SetTimer ('MoenPollTimer', g_pollInterval * ONE_SECOND, PollDeviceDetails, true)
	end
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
	if (g_ws) then
		g_ws:delete ()
		g_ws = nil
	end
	NotifyOnline (false)
	StartAuthFlow ()
end

function NotifyOnline (bOnline)
	local sState = bOnline and 'true' or 'false'
	C4:SendToProxy (MASTER_BINDING, 'ONLINE_CHANGED', { STATE = sState }, 'NOTIFY')
end

-- ===================== REST auth / polling chain ============================
-- UNCHANGED FROM v102 - protocol layer is out of scope for this version.
function AuthHeaders ()
	return { ['User-Token'] = g_token }
end

function StartAuthFlow ()
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

	local firstTime = (next (g_device) == nil)
	g_device = data
	g_cloudAuthenticated = true
	g_lastError = ''

	if (firstTime) then
		SetTimer ('MoenPollTimer', g_pollInterval * ONE_SECOND, PollDeviceDetails, true)
	end

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
	if (g_device.mode == 'paused-by-preset' and g_device.active_preset) then
		SendControlEvent ('shower_on', { preset = tostring (g_device.active_preset) })
	else
		SendControlEvent ('shower_on', { preset = '0' })
	end
end

function Action_ShowerOff ()
	SendControlEvent ('shower_off', {})
end

function Action_Resume ()
	local activePreset = g_device.active_preset
	if (activePreset == nil) then
		LOG ('Cannot resume: no active_preset known')
		return
	end
	SendControlEvent ('shower_on', { preset = tostring (activePreset) })
end

function Action_SetTemperature (tempF)
	SendControlEvent ('temperature_set', { target_temperature = math.floor (tempF + 0.5) })
end

function Action_SetOutlet (position, active)
	local outlets = g_device.outlets or {}
	local outletStates = {}
	for _, o in ipairs (outlets) do
		local isActive = o.active or false
		if (o.position == position) then isActive = active end
		table.insert (outletStates, { position = o.position, active = isActive })
	end
	SendControlEvent ('outlets_set', { outlets = outletStates })
end

function Action_ActivatePreset (position)
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
		ready_pauses_water = preset.ready_pauses_water or false,
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

-- ===================== Proxy sync (Moen state -> Navigator, Thermostat + Extras) ====
function SyncProxiesFromState ()
	local mode = g_device.mode or 'unknown'
	local isRunning = (mode ~= 'off' and mode ~= 'paused-by-preset' and mode ~= 'unknown')

	-- One-time notification (the allowed-modes list doesn't change at
	-- runtime for this device).
	if (not g_thermostatCapsSent) then
		C4:SendToProxy (MASTER_BINDING, 'ALLOWED_HVAC_MODES_CHANGED', { Modes = 'Off,Heat' }, 'NOTIFY')
		g_thermostatCapsSent = true
	end

	C4:SendToProxy (MASTER_BINDING, 'TEMPERATURE_CHANGED',
		{ TEMPERATURE = tostring (g_device.current_temperature or g_tempMin), SCALE = 'F' }, 'NOTIFY')
	C4:SendToProxy (MASTER_BINDING, 'HEAT_SETPOINT_CHANGED',
		{ SETPOINT = tostring (ClampTemp (g_device.target_temperature)), SCALE = 'F' }, 'NOTIFY')
	C4:SendToProxy (MASTER_BINDING, 'HVAC_MODE_CHANGED',
		{ MODE = (isRunning and 'Heat' or 'Off') }, 'NOTIFY')

	SyncExtras (mode, isRunning)

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
	C4:UpdateProperty ('Cloud Status', cloudStr)

	C4:UpdateProperty ('Pusher Status', g_wsSubscribed and 'Connected / subscribed' or 'Connecting...')
end

-- Extras: one Switch ("Shower") + one Button per real preset (never a fixed
-- 4-slot layout - this account has 2). EXTRAS_SETUP_CHANGED (the layout) is
-- only re-sent when the preset list actually changes shape, matching the
-- signature-diffing pattern v102 used for AUX_NAMES_CHANGED.
-- EXTRAS_STATE_CHANGED (current values) is sent on every sync.
--
-- <extras_setup>/<extras_state> XML DOCUMENT shape confirmed against a REAL
-- working example (snap-one/docs-driverworks, sample_drivers/thermostat_v2/
-- "get extras setup.xml" - an actual Ecobee-class thermostat_v2 driver's
-- payload).
--
-- SendToProxy PARAMETER KEY FIX (found live, first real-device test):
-- v200's first live pass sent these as C4:SendToProxy(id, 'EXTRAS_SETUP_
-- CHANGED', {extras_setup = xml}, 'NOTIFY') - i.e. used the UI-facing field
-- name (extras_setup/extras_state) as the Lua table key. Result: Extras tab
-- rendered (has_extras/capabilities were fine) but stayed EMPTY - the proxy
-- never got the XML. Root cause: per the DriverWorks Thermostat Notifications
-- doc, EXTRAS_SETUP_CHANGED/EXTRAS_STATE_CHANGED's actual wire PARAMETER is
-- literally named "XML" - "extras_setup"/"extras_state" is only the name it
-- comes through as ON THE UI SIDE, not the SendToProxy call's parameter key.
-- This is also the exact convention v102's own pool code already used for
-- its XML notifications (POOL_HEATMODE_LIST_CHANGED / POOL_HEATMODE_CHANGED
-- both send {XML = ...}) - missed carrying that pattern over the first time.
-- Fixed below to {XML = ...} for both calls.
function BuildExtrasSetupXml ()
	local presets = g_device.presets or {}
	local parts = {
		'<extras_setup>',
		'<extra>',
		'<section label="Shower">',
		'<object type="switch" id="shower_switch" label="Shower" command="ExtrasShowerToggle"/>',
	}
	for _, p in ipairs (presets) do
		-- id/command both carry the preset's REAL Moen position number, never
		-- a loop index - same rule v102 followed for aux item IDs. Per
		-- Nick's request: the object's "label" (the static row text) reads
		-- "Preset N" while the button itself is labeled with the live Moen
		-- preset title ("Hot", "Comfortable", etc, never hardcoded here) -
		-- previously both said the live title, which read as duplicated.
		table.insert (parts, '<object type="button" id="preset_' .. tostring (p.position) ..
			'" label="Preset ' .. tostring (p.position) ..
			'" command="ExtrasPreset_' .. tostring (p.position) .. '">' ..
			'<buttontext>' .. ExtrasXMLEncode (PresetDisplayName (p)) .. '</buttontext></object>')
	end
	table.insert (parts, '</section>')
	table.insert (parts, '</extra>')
	table.insert (parts, '</extras_setup>')
	return table.concat (parts)
end

function BuildExtrasStateXml (mode, isRunning)
	local presets = g_device.presets or {}
	local activePreset = g_device.active_preset

	local parts = { '<extras_state>', '<extra>' }
	table.insert (parts, '<object id="shower_switch" value="' .. (isRunning and 'true' or 'false') .. '"/>')
	for _, p in ipairs (presets) do
		local isActive = (activePreset ~= nil and tostring (activePreset) == tostring (p.position))
		table.insert (parts, '<object id="preset_' .. tostring (p.position) ..
			'" value="' .. (isActive and 'true' or 'false') .. '"/>')
	end
	table.insert (parts, '</extra>')
	table.insert (parts, '</extras_state>')
	return table.concat (parts)
end

function SyncExtras (mode, isRunning)
	local presets = g_device.presets or {}

	local sigParts = {}
	for _, p in ipairs (presets) do
		table.insert (sigParts, tostring (p.position) .. ':' .. PresetDisplayName (p))
	end
	local signature = table.concat (sigParts, ',')

	if (signature ~= g_extrasSetupSignature) then
		C4:SendToProxy (MASTER_BINDING, 'EXTRAS_SETUP_CHANGED', { XML = BuildExtrasSetupXml () }, 'NOTIFY')
		g_extrasSetupSignature = signature
		LOG ('Sent EXTRAS_SETUP_CHANGED (' .. tostring (#presets) .. ' preset button(s))')
	end

	C4:SendToProxy (MASTER_BINDING, 'EXTRAS_STATE_CHANGED', { XML = BuildExtrasStateXml (mode, isRunning) }, 'NOTIFY')
end

-- ===================== Proxy commands (Navigator -> this driver) ============================
RFP = RFP or {}

-- Thermostat + Extras proxy command dispatch. GET_CONNECTED_STATE is the
-- same command name already proven for the pool proxy in v102 (this part of
-- the convention is confirmed cross-proxy). SET_HVAC_MODE/SET_HEAT_SETPOINT
-- are the inferred names described in the .xml header and the file header
-- above - unrecognized commands fall through to the else branch and are
-- logged, never acted on.
RFP [MASTER_BINDING] = function (idBinding, strCommand, tParams, args)
	if (strCommand == 'GET_CONNECTED_STATE') then
		NotifyOnline (g_cloudAuthenticated)
		return
	end

	-- ---- Extras: on/off switch ----
	if (strCommand == 'ExtrasShowerToggle') then
		local wantOn = tostring (tParams and (tParams.value or tParams.VALUE)) == 'true'
		if (wantOn) then Action_ShowerOn () else Action_ShowerOff () end
		return
	end

	-- ---- Extras: preset buttons (command carries the real position number) ----
	local presetPos = strCommand and tostring (strCommand):match ('^ExtrasPreset_(%d+)$')
	if (presetPos ~= nil) then
		Action_ActivatePreset (tonumber (presetPos))
		return
	end

	-- ---- Native thermostat controls ----
	-- Command NAMES (SET_MODE_HVAC, SET_SETPOINT_HEAT) are confirmed from
	-- the DriverWorks "Thermostat Unhandled Commands" reference page - v200/
	-- v201 had these as SET_HVAC_MODE/SET_HEAT_SETPOINT (wrong word order,
	-- never actually seen fire). Parameter key NAMES (MODE, SETPOINT) are
	-- still inferred by symmetry with the matching outbound notification -
	-- if wrong, the else branch below logs the real strCommand.
	if (strCommand == 'SET_MODE_HVAC') then
		local wantOn = (tostring (tParams.MODE) == 'Heat')
		if (wantOn) then
			Action_ShowerOn ()
		else
			Action_ShowerOff ()
		end

	elseif (strCommand == 'SET_SETPOINT_HEAT') then
		local temp = ClampTemp (tParams.SETPOINT)
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

	else
		LOG ('Unhandled thermostat/extras proxy command: ' .. tostring (strCommand) ..
			' - if this fires from a real Navigator tap, it names the real command; fix the RFP branch above to match')
		if (tParams) then
			for k, v in pairs (tParams) do
				LOG ('  param ' .. tostring (k) .. ' = ' .. tostring (v))
			end
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

EC ['ACTION_PRINT_DEBUG'] = function ()
	print ('=== Moen Smart Shower Standalone Driver Debug (v202) ===')
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
	print ('extras_setup_signature=' .. tostring (g_extrasSetupSignature))
end
