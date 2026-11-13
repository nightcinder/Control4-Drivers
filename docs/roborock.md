# Roborock Vacuum (LAN Bridge) 0.5.1

Status: UNTESTED. Written against the Control4 OS 3.4.x Lua API but not run on a real Composer or Director.

0.5.1: events moved to devicedata level so Composer lists them. The 7 custom events are now a direct child of devicedata (not inside config), matching the moenshower driver.

Talks to a Roborock LAN HTTP bridge (already running on liesa). The driver polls the bridge and sends commands. Version 0.2.0 adds a Navigator web view and state-based tile icons (see Web view below).

## Bridge

- Base URL: `http://172.21.1.157:8788` (set with the Bridge Host and Bridge Port properties)
- `GET /state` returns `state`, `battery`, `error`, `rooms`, `last_error`, `last_success_age_s`
- `POST /command` with `{"action": "start|stop|pause|dock|clean_rooms", "rooms": [ids]}`

## Properties

| Property | Type | Default | Notes |
|---|---|---|---|
| Bridge Host | string | 172.21.1.157 | Bridge address |
| Bridge Port | 1-65535 | 8788 | Bridge port |
| Poll Interval | 30-3600 s | 60 | Minimum is 30 |
| Low Battery Threshold | 1-100 % | 20 | Battery Low fires at or below this value |
| Log Mode | Off, Print, Log, Print and Log | Off | Print goes to the console, Log goes to the error log |
| Status | read-only | | Connected, Bridge unreachable, or the last command sent |
| State | read-only | | Bridge state string |
| Battery | read-only | | Battery percent |
| Last Error | read-only | | Last error or last_error from the bridge |
| Active Room | read-only | Unknown | v0.5.0: name of the room under the robot (bridge current_room); Unknown when the bridge reports null |
| Room Progress | read-only | n/a | v0.5.0: room_progress_pct from the bridge; n/a in bridge 0.2.0 (always null) |
| Driver Version | read-only | 0.5.1 | |
| Web Page Status | read-only | Not opened yet | Set when the web view page reports its build |

## Variables

- `VACUUM_STATE` (string)
- `VACUUM_BATTERY` (number)
- `VACUUM_ERROR` (string)
- `UI_STATE` (string): JSON snapshot read by the web view page (added in 0.2.0; v0.5.0 adds `activeRoom` and `roomProgress`)
- `ACTIVE_ROOM` (string): v0.5.0, room name under the robot, "" when unknown
- `ROOM_PROGRESS` (number): v0.5.0, 0-100; 0 when the bridge reports null (see the Room Progress property)

## Programming commands

- Start, Stop, Pause, Dock
- Clean Rooms, with a `Rooms` parameter: comma-separated room ids, for example `1,3,5`

Refresh Now (action) re-reads the bridge state.

## Events

| ID | Event | Fires when |
|---|---|---|
| 1 | Cleaning Started | State moves into a cleaning state |
| 2 | Cleaning Finished | State moves from a cleaning state to `docked` or `charging` |
| 3 | Error Raised | Bridge reports a new error (not `none`) |
| 4 | Battery Low | Battery is at or below the threshold; fires once until the battery rises above it |
| 5 | Bridge Unreachable | Bridge request fails or returns a non-2xx code; fires once per outage |
| 6 | Laundry Room Entered | v0.5.0: while cleaning, the bridge's current room becomes the Laundry Room ID. If current_room is null, the v0.4.0 rule applies (cleaning starts on a run targeting only that ID) |
| 7 | Laundry Room Left | v0.5.0: while cleaning, the current room changes away from the Laundry Room ID, or cleaning ends (docked, charging or idle; not on pause) |

## Build

Package with `tools/build_c4z.py` (the folder is `drivers/roborock`). Not built in this change.

## Web view and tile icons (0.2.0, UNTESTED)

- Proxy: uibutton on binding 5001 (no network connection; the driver calls the bridge over HTTP itself).
- Web view: `www/vacuum2.html` (v0.5.0; was vacuum1), opened from `controller://driver/roborock/vacuum2.html`. Dark theme, no external libraries or fonts.
- The page shows the bridge state, battery percent with a bar, last error, and a Connected / Bridge unreachable pill.
- Buttons: Start, Pause, Dock, Stop (large touch targets). Start is disabled for 3 seconds after a tap so it cannot fire twice. Dock and Stop need no confirmation.
- The page sends `UI_START`, `UI_PAUSE`, `UI_DOCK`, `UI_STOP`, `UI_REFRESH` and `UI_HELLO_<build>` through `ExecuteCommand`. Each call that changes or reads state publishes a new `UI_STATE` snapshot (`{"t":"rbrock","seq":...}`).
- Tile icon states: Default (idle, returning or unknown), Cleaning (any cleaning state), Docked (docked or charging), Error (bridge error code other than none). The icon is sent with `ICON_CHANGED` on binding 5001 only when it changes. While the bridge is unreachable the icon falls back to Default.
- Icons are simple original vector-style drawings made for this driver (no brand artwork). Sizes 70, 90, 300, 512 and 1024 under `www/icons/device/<state>/`, plus `icons/device_sm.png` and `icons/device_lg.png`.

### Installing 0.2.0 in Composer

1. Delete the existing Roborock device. A changed proxy is only applied when the device is added again.
2. Run "Add or Update Driver" with `c4z/roborock.c4z`. The package name is unchanged, so the driver updates in place.
3. Add the device again and set Bridge Host and Bridge Port.
4. Open the tile. The page build check should show "Page build 1 OK" in Web Page Status.

If the page shows "PAGE IS STALE", the page file and the driver build do not match. Bump both the page file name and `UI_BUILD` together.

### Page file names

The page file name changes with each page release (vacuum1, vacuum2, ...) because Navigator caches `controller://` pages. `web_view_url` in driver.xml, `UI_BUILD` in driver.lua and the file in `www/` must match.

## v0.5.0 notes (2026-11-12)

- Active room: the bridge (0.2.0) reads `MapData.vacuum_room` from python-roborock's parsed map and returns it as `current_room`. The driver shows it as the Active Room property, the ACTIVE_ROOM variable, and the "Room" value on the web page (page is now vacuum2.html, build 3).
- Room Progress: not implemented. The library exposes no per-room cleaned data for v1 vacuums, so the bridge returns null and the page shows n/a. A real estimate needs a per-room pixel count from the map image, which is not done yet.
- Laundry Room Entered / Left now follow the current room while it is known. The v0.4.0 run-target rule is still the fallback when current_room is null.
- Fixed in this release: `isLaundryOnlyRun` was called in `applyState` before its `local function` declaration, so the call would have hit a nil global on every cleaning start. It is now forward-declared.
- Installing: delete and re-add the device in Composer only if the proxy or web view changed (it did: vacuum2.html). Run "Add or Update Driver" with `c4z/roborock.c4z`.
- Bridge: image `roborock-bridge:0.2.0`. In the Portainer stack (stack id 21), change the roborock-bridge image line to `roborock-bridge:0.2.0` and redeploy the stack (or recreate that service). Build the image on liesa first with `docker build -t roborock-bridge:0.2.0 /home/liesa/automation-pollers/roborock-bridge`.
- Untested on hardware. Syntax checks: `python -m py_compile` on app.py and `luac -p` on driver.lua both pass.

## v0.4.0 notes (2026-11-12)

- Mop option: NOT added. The bridge sends clean_rooms through APP_SEGMENT_CLEAN with no mode field. python-roborock 7.22.0 can set fan power and water mode (StatusTrait.set_cleaning_mode), but those are persistent device settings, not per-run options. Restoring them after a run is untested, so no mode field was added.
- Active room: NOT available. The v1 status and rooms traits expose the room list and the raw robot position, with no current segment, so /state has no current_room and the driver has no ACTIVE_ROOM variable.
- Laundry fallback (driver only, bridge unchanged): set the Laundry Room ID property to the laundry room segment id. Laundry Room Entered (event 6) fires on cleaning start when the run targets only that id. Laundry Room Left (event 7) fires when that run ends (docked, charging or idle; not on pause or returning). Other runs fire nothing. Untested on hardware.
- Battery and error were checked: Battery Low, Error Raised and the page's battery and last-error text are correct. No change.
