-- Media Remote Bridge - Control4 driver v0.2.0
-- Listener and dispatch follow Daylight_Lighting_Scheduler_driver.lua (C4:CreateServer,
-- OnServerDataIn, C4:ServerSend, C4:ServerCloseClient). The HTTP request parsing on top of
-- the raw TCP stream is NOT from a reference driver: DLS speaks a plain line protocol.
-- Anything not confirmed by a reference is marked TODO(verify). See README.md.

VERSION = "0.2.0"

local LOG_PREFIX = "[MediaRemoteBridge " .. VERSION .. "] "
local ROOM_NAMES = { "Upstairs", "Downstairs" }
local DEFAULT_PORT = 8765
local MAX_REQUEST_BYTES = 16384

local serverHandle = nil
local clients = {}              -- nHandle -> request bytes received so far

---------------------------------------------------------------------------
-- Logging and status (style of Yale_AssureLock2 / IntelliFire: "Log Mode" property)
---------------------------------------------------------------------------
local function LOG(msg)
    local s = LOG_PREFIX .. tostring(msg)
    local mode = Properties["Log Mode"] or "Off"
    if mode == "Print" or mode == "Print and Log" then print(s) end
    if mode == "Log" or mode == "Print and Log" then C4:DebugLog(s) end
end

local function setStatus(s)
    pcall(function() C4:UpdateProperty("Status", s) end)
end

---------------------------------------------------------------------------
-- Pure Lua helpers (no Control4 API)
---------------------------------------------------------------------------
local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function jsonString(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n"
        elseif c == "\r" then return "\\r"
        elseif c == "\t" then return "\\t"
        end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

-- Flat tables of strings, numbers and booleans only.
local function jsonEncode(t)
    local parts = {}
    for k, v in pairs(t) do
        local tv = type(v)
        local val
        if tv == "string" then val = jsonString(v)
        elseif tv == "number" or tv == "boolean" then val = tostring(v)
        else val = "null" end
        parts[#parts + 1] = jsonString(tostring(k)) .. ":" .. val
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local function urlDecode(s)
    s = s:gsub("%+", " ")
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

local function parseQuery(qs)
    local out = {}
    if not qs or qs == "" then return out end
    for pair in qs:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=?(.*)$")
        if k then out[urlDecode(k)] = urlDecode(v or "") end
    end
    return out
end

local function splitTarget(target)
    local path, qs = target:match("^([^?]*)%?(.*)$")
    if path then return path, qs end
    return target, ""
end

---------------------------------------------------------------------------
-- Room devices
---------------------------------------------------------------------------
-- The references do not enumerate devices by name (C4:GetDevices is not used anywhere in them).
-- DLS takes device IDs from configuration, so room IDs come from the "<Room> Device ID" properties.
local function roomDeviceId(roomName)
    local v = tonumber(Properties[roomName .. " Device ID"])
    if v and v > 0 then return v end
    return nil
end

local function activeRoomName()
    return Properties["Active Room"] or "Upstairs"
end

-- TODO(verify): room-level media command names and parameter keys. DLS only sends
-- RAMP_TO_LEVEL and SET_COLOR_TARGET to light devices; nothing in the references covers media rooms.
local function sendToActiveRoom(command, params)
    local roomName = activeRoomName()
    local deviceId = roomDeviceId(roomName)
    if not deviceId then
        return false, "device id not set for " .. roomName .. " (set '" .. roomName .. " Device ID')"
    end
    local ok, err = pcall(function() C4:SendToDevice(deviceId, command, params or {}) end)
    if not ok then return false, tostring(err) end
    return true
end

---------------------------------------------------------------------------
-- Per-command handlers (stubs: log, send, return a result table)
---------------------------------------------------------------------------
local function result(command, ok, extra, err)
    local t = { command = command, ok = ok and true or false }
    if err then t.error = err end
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end

local function cmdPlay(q)
    LOG("play")
    local ok, err = sendToActiveRoom("PLAY", {}) -- TODO(verify): PLAY
    return result("play", ok, nil, err)
end

local function cmdPause(q)
    LOG("pause")
    local ok, err = sendToActiveRoom("PAUSE", {}) -- TODO(verify): PAUSE
    return result("pause", ok, nil, err)
end

local function cmdToggle(q)
    LOG("toggle")
    local ok, err = sendToActiveRoom("TOGGLE_PLAY", {}) -- TODO(verify): TOGGLE_PLAY
    return result("toggle", ok, nil, err)
end

local function cmdNext(q)
    LOG("next")
    local ok, err = sendToActiveRoom("NEXT", {}) -- TODO(verify): NEXT
    return result("next", ok, nil, err)
end

local function cmdPrev(q)
    LOG("prev")
    local ok, err = sendToActiveRoom("PREVIOUS", {}) -- TODO(verify): PREVIOUS
    return result("prev", ok, nil, err)
end

local function cmdMute(q)
    LOG("mute")
    local ok, err = sendToActiveRoom("MUTE_ON", {}) -- TODO(verify): MUTE_ON
    return result("mute", ok, nil, err)
end

local function cmdUnmute(q)
    LOG("unmute")
    local ok, err = sendToActiveRoom("MUTE_OFF", {}) -- TODO(verify): MUTE_OFF
    return result("unmute", ok, nil, err)
end

local function cmdVolumeUp(q)
    LOG("volume_up")
    local ok, err = sendToActiveRoom("VOLUME_UP", {}) -- TODO(verify): VOLUME_UP
    return result("volume_up", ok, nil, err)
end

local function cmdVolumeDown(q)
    LOG("volume_down")
    local ok, err = sendToActiveRoom("VOLUME_DOWN", {}) -- TODO(verify): VOLUME_DOWN
    return result("volume_down", ok, nil, err)
end

local function cmdVolumeSet(q)
    local level = tonumber(q.level)
    if not level or level < 0 or level > 100 then
        return result("volume_set", false, nil, "level must be 0-100")
    end
    LOG("volume_set " .. level)
    -- TODO(verify): command name and param key for absolute volume (SET_VOLUME_LEVEL / LEVEL)
    local ok, err = sendToActiveRoom("SET_VOLUME_LEVEL", { LEVEL = level })
    return result("volume_set", ok, { level = level }, err)
end

local function cmdSetActiveRoom(q)
    local room = q.room
    if room ~= "Upstairs" and room ~= "Downstairs" then
        return result("set_active_room", false, nil, "room must be Upstairs or Downstairs")
    end
    if Properties["Lock Room"] == "On" then
        return result("set_active_room", false, nil, "room is locked")
    end
    LOG("set_active_room " .. room)
    -- TODO(verify): C4:UpdateProperty on a writable LIST property; no reference does this.
    pcall(function() C4:UpdateProperty("Active Room", room) end)
    return result("set_active_room", true, { room = room })
end

local COMMANDS = {
    play = cmdPlay,
    pause = cmdPause,
    toggle = cmdToggle,
    next = cmdNext,
    prev = cmdPrev,
    mute = cmdMute,
    unmute = cmdUnmute,
    volume_up = cmdVolumeUp,
    volume_down = cmdVolumeDown,
    volume_set = cmdVolumeSet,
    set_active_room = cmdSetActiveRoom,
}

local function cmdStatus()
    return {
        ok = true,
        command = "status",
        version = VERSION,
        active_room = activeRoomName(),
        lock_room = Properties["Lock Room"] or "Off",
        -- TODO(verify): now-playing source (device variable id for the room). C4:GetDeviceVariable
        -- is confirmed by DLS, but no reference gives a media-room variable id.
        now_playing = "unknown",
    }
end

---------------------------------------------------------------------------
-- HTTP over the raw server stream
---------------------------------------------------------------------------
local STATUS_TEXT = {
    [200] = "OK", [400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found",
    [405] = "Method Not Allowed", [413] = "Payload Too Large",
}

local function httpReply(nHandle, code, tBody)
    local body = jsonEncode(tBody)
    local head = "HTTP/1.1 " .. tostring(code) .. " " .. (STATUS_TEXT[code] or "Error") .. "\r\n"
        .. "Content-Type: application/json\r\n"
        .. "Content-Length: " .. tostring(#body) .. "\r\n"
        .. "Connection: close\r\n\r\n"
    -- Same send-then-close pattern as DLS OnServerDataIn.
    pcall(function() C4:ServerSend(nHandle, head .. body) end)
    pcall(function() C4:ServerCloseClient(nHandle) end)
    clients[nHandle] = nil
end

-- Returns nil while the request is incomplete, { bad = true } if malformed,
-- otherwise { method, target, headers, body }. Header names are lower-cased.
local function parseRequest(buf)
    local hdrEnd = buf:find("\r\n\r\n", 1, true)
    if not hdrEnd then return nil end
    local head = buf:sub(1, hdrEnd - 1)
    local rest = buf:sub(hdrEnd + 4)
    local reqLine = head:match("^([^\r\n]*)") or ""
    local method, target = reqLine:match("^(%u+)%s+(%S+)%s+HTTP/%d%.%d$")
    if not method then return { bad = true } end

    local headers = {}
    local headerBlock = head:match("\r\n(.*)$") or ""
    for line in headerBlock:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then headers[k:lower()] = v end
    end

    local clen = tonumber(headers["content-length"] or "0")
    if not clen or clen < 0 then return { bad = true } end
    if #rest < clen then return nil end
    return { method = method, target = target, headers = headers, body = rest:sub(1, clen) }
end

-- Token check. Expects "Authorization: Bearer <Server Token>".
local function authorized(headers)
    local expected = trim(Properties["Server Token"] or "")
    if expected == "" then return false end
    return headers["authorization"] == "Bearer " .. expected
end

-- Routes:
--   GET  /v1/status
--   POST /v1/command/<name>?level=<0-100>   (level only used by volume_set)
--   POST /v1/command/set_active_room?room=Upstairs|Downstairs
local function handleRequest(nHandle, req)
    if not authorized(req.headers) then
        return httpReply(nHandle, 401, { ok = false, error = "unauthorized" })
    end

    local path, qs = splitTarget(req.target)
    local q = parseQuery(qs)

    if path == "/v1/status" then
        if req.method ~= "GET" then
            return httpReply(nHandle, 405, { ok = false, error = "use GET" })
        end
        return httpReply(nHandle, 200, cmdStatus())
    end

    local name = path:match("^/v1/command/([%w_]+)$")
    if name then
        if req.method ~= "POST" then
            return httpReply(nHandle, 405, { ok = false, error = "use POST" })
        end
        local fn = COMMANDS[name]
        if not fn then
            return httpReply(nHandle, 404, { ok = false, error = "unknown command" })
        end
        local res = fn(q)
        return httpReply(nHandle, res.ok and 200 or 400, res)
    end

    return httpReply(nHandle, 404, { ok = false, error = "not found" })
end

-- Called by the Director with raw bytes from a connected client (DLS pattern).
-- Bytes are buffered per client until a full request has arrived.
function OnServerDataIn(nHandle, strData, strClientAddress, nClientPort)
    local buf = (clients[nHandle] or "") .. tostring(strData)
    if #buf > MAX_REQUEST_BYTES then
        return httpReply(nHandle, 413, { ok = false, error = "request too large" })
    end
    clients[nHandle] = buf
    local req = parseRequest(buf)
    if req == nil then return end                       -- incomplete, wait for more bytes
    if req.bad then
        return httpReply(nHandle, 400, { ok = false, error = "malformed request" })
    end
    handleRequest(nHandle, req)
end

-- TODO(verify): the exact status string the Director sends when a client disconnects.
function OnServerConnectionStatusChanged(nHandle, nPort, strStatus)
    if tostring(strStatus):lower():find("clos", 1, true) then
        clients[nHandle] = nil
    end
end

local function stopServer()
    if serverHandle ~= nil then
        -- DLS calls C4:DestroyServer() with no arguments. TODO(verify) that this is correct.
        pcall(function() C4:DestroyServer() end)
        serverHandle = nil
    end
    clients = {}
end

local function startServer()
    stopServer()
    local port = tonumber(Properties["Server Port"]) or DEFAULT_PORT
    if port <= 0 then
        setStatus("Server disabled (port 0)")
        return
    end
    -- Same call DLS uses. Its return value is the server handle.
    local ok, handle = pcall(function() return C4:CreateServer(port) end)
    if not ok or handle == nil then
        LOG("could not start server on port " .. tostring(port) .. ": " .. tostring(handle))
        setStatus("Server failed on port " .. tostring(port))
        return
    end
    serverHandle = handle
    setStatus("Listening on port " .. tostring(port))
    LOG("listening on port " .. tostring(port))
end

---------------------------------------------------------------------------
-- Driver lifecycle (entry points as used by DLS)
---------------------------------------------------------------------------
local function logStatus()
    LOG("active room " .. activeRoomName() .. ", lock room " .. tostring(Properties["Lock Room"]))
    for _, name in ipairs(ROOM_NAMES) do
        LOG("room " .. name .. " device id " .. tostring(roomDeviceId(name) or "not set"))
    end
    LOG("server handle " .. tostring(serverHandle))
end

function OnDriverInit() end

function OnDriverLateInit()
    pcall(function() C4:UpdateProperty("Driver Version", VERSION) end)
    LOG("late init")
    startServer()
end

function OnDriverDestroyed()
    stopServer()
end

function OnPropertyChanged(strProperty)
    if strProperty == "Server Port" then
        startServer()
    elseif strProperty == "Active Room" or strProperty == "Lock Room" then
        LOG(strProperty .. " = " .. tostring(Properties[strProperty]))
    elseif strProperty == "Log Mode" then
        LOG("log mode = " .. tostring(Properties["Log Mode"]))
    end
end

function ExecuteCommand(strCommand, tParams)
    if strCommand == "LUA_ACTION" then
        local a = tParams and tParams.ACTION
        if a == "LogStatus" then
            logStatus()
        elseif a == "RestartServer" then
            startServer()
        end
    end
end
