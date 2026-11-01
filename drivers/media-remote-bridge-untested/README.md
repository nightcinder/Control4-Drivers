# Media Remote Bridge

Control4 driver skeleton (v0.4.0). It exposes a small HTTP/JSON API on the controller that sends room-level media commands to the Upstairs or Downstairs room, and accepts now-playing reports pushed by a Shield poller (`tools/shield_nowplaying.py`).

## Files

- `driver.xml` - driver definition, properties, actions (layout follows the Daylight Lighting Scheduler driver)
- `driver.lua` - lifecycle, listener, request routing, command stubs
- `build.sh` - packages the two files into `MediaRemoteBridge.c4z`

File names stay the same across versions. Bump `VERSION` in `driver.lua` instead of renaming files.

## Build

    ./build.sh

Build result for 0.2.0: `MediaRemoteBridge.c4z` built (driver.xml, driver.lua). `driver.xml` parses as well-formed XML. `driver.lua` passes `luac5.1 -p`.

## Setup (Composer)

1. Set `Server Port` (default 8765) and `Server Token`.
2. Set `Upstairs Device ID` and `Downstairs Device ID` to the room device IDs.
3. Set `Active Room` and `Lock Room` as needed. Use `Log Mode` to turn on logging.

## API

- `GET /v1/status` - returns version, active room, lock state, now-playing
  - Always: `version`, `active_room`, `lock_room`, `now_playing`, `volume`, `muted`, `power`, `source_id`, `source` (as before).
  - When the active room has a now-playing report at most 45 seconds old, also: `np_title`, `np_artist`, `np_app` (strings), `np_playing` (boolean). `now_playing` becomes `title - artist`, or `title`, or `app`, whichever exists first; otherwise it keeps the source name.
- `POST /v1/command/<name>` with header `Authorization: Bearer <Server Token>`
  - `play`, `pause`, `toggle`, `next`, `prev`, `mute`, `unmute`, `volume_up`, `volume_down`
  - `volume_set?level=0-100`
  - `set_active_room?room=Upstairs|Downstairs` (refused when Lock Room is On)
- `POST /v1/nowplaying?room=Upstairs|Downstairs&title=..&artist=..&app=..&playing=1|0` with the same Bearer header
  - Query values are URL-decoded (`%XX` and `+` as space). Reply `{"ok":true,"command":"nowplaying"}`.
  - Stores the report per room with a timestamp. If `title`, `artist` and `app` are all empty, clears that room.
  - Room state is in memory only; it is lost on driver restart.

Unauthenticated requests get 401. An empty `Server Token` refuses every request. Wrong method gets 405, unknown route 404, bad command args 400.

## Confirmed from reference drivers

Reference files are on the user's machine under `c4ref\drivers\`.

- XML layout: `<devicedata>` with `<control>lua_gen</control>`, `<driver>DriverWorks</driver>`, `<combo>`, `<proxies />`, `<capabilities />`, and the `<config>` block holding `<script file="driver.lua" />`, `<properties>`, `<actions>`. Source: `daylight-lighting-scheduler\Daylight_Lighting_Scheduler_driver.xml`.
- Property types `STRING`, `LIST` (with `<items><item>`), `RANGED_INTEGER` (with `<minimum>`, `<maximum>`), `<readonly>`, `<default>`. Source: the same DLS XML.
- No `PASSWORD` or masked property type appears in any reference. `Server Token` is `STRING`, as DLS does for `Presence Token`. Source: `daylight-lighting-scheduler\Daylight_Lighting_Scheduler_driver.xml`, `yale-assure-lock-2\Yale_AssureLock2_driver.xml`, `intellifire\IntelliFire_driver.xml`.
- Lifecycle entry points: `OnDriverInit`, `OnDriverLateInit`, `OnDriverDestroyed`, `OnPropertyChanged(strProperty)`, `ExecuteCommand(strCommand, tParams)` with actions arriving as `LUA_ACTION` plus `tParams.ACTION`. Source: `daylight-lighting-scheduler\Daylight_Lighting_Scheduler_driver.lua`.
- Property access: `Properties["Name"]`. Property writes: `C4:UpdateProperty(name, value)`, which does not fire `OnPropertyChanged`. Source: DLS Lua; `yale-assure-lock-2\Yale_AssureLock2_driver.lua` (the comment on the auto-select `StartPolling` call).
- Logging: a `LIST` property `Log Mode` (`Off`, `Print`, `Log`, `Print and Log`) gating `print(...)` and `C4:DebugLog(...)`. Source: `yale-assure-lock-2\Yale_AssureLock2_driver.lua`, `intellifire\IntelliFire_driver.xml`.
- Server: `C4:CreateServer(port)` returns a handle. `OnServerDataIn(nHandle, strData, strClientAddress, nClientPort)` receives raw bytes. Replies use `C4:ServerSend(nHandle, data)` followed by `C4:ServerCloseClient(nHandle)`. Also `OnServerConnectionStatusChanged(nHandle, nPort, strStatus)` and `C4:DestroyServer()`. Source: DLS Lua. DLS speaks a raw line protocol, not HTTP.
- Device addressing: devices are addressed by numeric ID from configuration, with `C4:SendToDevice(idDevice, idCommand, tParams)`. Source: DLS Lua. No reference enumerates devices by name.
- Device variables: `C4:GetDeviceVariable(idDevice, idVariable)`. Source: DLS Lua.
- Timers: `C4:SetTimer(ms, fn, repeating)` with `:Cancel()`. Source: `yale-assure-lock-2\Yale_AssureLock2_driver.lua`, `lifx-lan\LIFX_LAN_driver.lua`.
- Lua 5.1 compatible code. Source: comment in `lifx-lan\LIFX_LAN_driver.lua` ("no bit ops: works on Lua 5.1").

## Not from references (written for this driver)

- HTTP request parsing on top of the raw stream: request line, headers, `Content-Length` body, 16 KB buffer cap, 400/413 on bad input. DLS does not do this; the pattern is mine.
- JSON encoder (`jsonEncode`) and query parser (`parseQuery`, `urlDecode`). Pure Lua, flat objects only.

## Unverified (TODO(verify) in source)

Room-level media commands:
1. `PLAY`, `PAUSE`, `TOGGLE_PLAY`, `NEXT`, `PREVIOUS`, `MUTE_ON`, `MUTE_OFF`, `VOLUME_UP`, `VOLUME_DOWN`, `SET_VOLUME_LEVEL` and its `LEVEL` key. The references only send `RAMP_TO_LEVEL` and `SET_COLOR_TARGET` to lights.
2. Whether a room device accepts these commands directly or needs a sub-device.

Now-playing:
3. The source for now-playing. `C4:GetDeviceVariable` is confirmed, but no media-room variable ID is known. The stub returns `"unknown"`.

Server:
4. `C4:DestroyServer()` with no arguments (copied from DLS; not explained there).
5. The status string sent to `OnServerConnectionStatusChanged` on client disconnect.
6. Behavior when a client sends headers but never the body. No timeout is implemented.
7. Whether the Director delivers a full request in one `OnServerDataIn` call or several. The buffering handles both, but the split behavior is unconfirmed.

Properties and room IDs:
8. `Upstairs Device ID` and `Downstairs Device ID` use a `RANGED_INTEGER` 0-999999. That maximum is a placeholder I chose, not a confirmed limit.
9. Writing a writable `LIST` property (`Active Room`) with `C4:UpdateProperty`. No reference does this.
10. The room lookup by name no longer uses a Control4 call. Name-to-ID is a configuration step. Automatic discovery by name is not confirmed by any reference.

## Shield now-playing poller

`tools/shield_nowplaying.py` (Python 3, standard library only) reads what each Nvidia Shield is playing and pushes it to `POST /v1/nowplaying`. It runs `adb -s HOST:5555 shell dumpsys media_session`, takes the first session with `active=true`, and posts the title, artist, app and playing state for that Shield's room. It posts when the content changes and every 20 seconds as a heartbeat. adb errors are logged in one line and retried; the script does not exit on them.

Setup:

1. Copy `tools/shield_nowplaying.example.json` to a local `tools/shield_nowplaying.json` and set `bridge_base_url` (controller address and `Server Port`). Set `adb` to the adb path. Replace the `REPLACE_...` host with the real IP, or delete that entry. Entries whose host starts with `REPLACE` are skipped.
2. Set the bridge token in an environment variable named by `token_env` (default `MEDIA_BRIDGE_TOKEN`), or point `token_file` at a file that holds only the token. The token is never written to the config or the log.
3. Enable ADB debugging on each Shield. Test with `--once`, which reads the device and prints the parsed state without posting.

Commands:

    python tools\shield_nowplaying.py tools\shield_nowplaying.json --once   # parse only, no POST
    python tools\shield_nowplaying.py tools\shield_nowplaying.json          # run forever

Run it as a scheduled task or service on a machine that can reach both the Shields and the controller. The script does not install itself as a service.

## Operational notes

- Changing `Server Port` restarts the listener through `OnPropertyChanged`. Changing `Server Token` takes effect on the next request.
- `Log Status` and `Restart Server` are Composer actions.
- Do not use a real token in source or in this repository. Set it in Composer.
