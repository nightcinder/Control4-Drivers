# Roborock Vacuum (LAN Bridge) 0.1.0

Status: UNTESTED. Written against the Control4 OS 3.4.x Lua API but not run on a real Composer or Director.

Talks to a Roborock LAN HTTP bridge (already running on liesa). The driver polls the bridge and sends commands. There is no web view.

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
| Driver Version | read-only | 0.1.0 | |

## Variables

- `VACUUM_STATE` (string)
- `VACUUM_BATTERY` (number)
- `VACUUM_ERROR` (string)

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

## Build

Package with `tools/build_c4z.py` (the folder is `drivers/roborock`). Not built in this change.
