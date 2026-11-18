# Roborock Vacuum (LAN Bridge) 0.7.0

Status: the driver logic is tested in c4sim (`tools/c4sim/tests/roborock_test.lua`). Room clean from Control4 was checked on the vacuum with 0.6.2. Everything new in 0.7.0 (cleaning mode, progress, the new events and commands) is NOT yet checked on the vacuum or in Composer.

The driver talks to the Roborock LAN HTTP bridge in `tools/roborock-bridge` (runs on liesa, port 8788). It polls the bridge and sends commands. The per-job cleaning mode and the progress fields need bridge 0.2.3. With an older bridge the driver still works; mode commands are refused and progress shows n/a.

## Bridge

- Base URL: `http://192.0.2.10:8788` (set with the Bridge Host and Bridge Port properties)
- `GET /state` returns `state`, `battery`, `error`, `rooms`, `current_room`, `last_error`, and with bridge 0.2.3 also `error_code`, `cleaning_mode`, `water_mode`, `fan_speed`, `clean_area_m2`, `clean_time_s`, `run_progress_pct`, `mode_restore_pending`, `bridge_version`
- `POST /command` with `{"action": "start|stop|pause|dock|clean_rooms|set_mode", "rooms": [ids], "mode": "vacuum|vac_and_mop|mop"}`

## Properties

| Property | Type | Default | Notes |
|---|---|---|---|
| Bridge Host | string | 192.0.2.10 | Bridge address |
| Bridge Port | 1-65535 | 8788 | Bridge port |
| Poll Interval | 5-3600 s | 15 | The driver polls every 5 s while the robot is cleaning, returning or busy at the dock |
| Laundry Room ID | 0-9999 | 0 | Room id for the laundry events (21 in this home); 0 turns them off |
| Low Battery Threshold | 1-100 % | 20 | Battery Low fires at or below this value |
| Log Mode | Off, Print, Log, Print and Log | Off | Print goes to the console, Log goes to the error log |
| Status | read-only | | Connected, Bridge unreachable, or the last command for a few seconds |
| State | read-only | | Bridge state string |
| Activity | read-only | | 0.7.0: one word for the state: cleaning, paused, returning, docked, idle, error, offline or other (see State names) |
| Battery | read-only | | Battery percent |
| Last Error | read-only | | Bridge poll error, or the vacuum error name |
| Driver Version | read-only | 0.7.0 | |
| Bridge Version | read-only | | 0.7.0: from /state; "older than 0.2.3" when the bridge does not send it |
| Last Command | read-only | | 0.7.0: time and result of the last command (sent, skipped, rejected, not sent) |
| Vacuum Error | read-only | None | 0.7.0: readable error and code, e.g. "Main brush jammed (code 5)" |
| Cleaning Mode | read-only | Unknown | 0.7.0: the vacuum's current mode, suction and water level. "for this job only" is added while a per-job mode is waiting to be put back |
| Run Progress | read-only | n/a | 0.7.0: whole-job percent while a job runs. "(device)" is the vacuum's own number; "(estimate)" is the driver's estimate (see Progress) |
| Cleaned Area | read-only | n/a | 0.7.0: area of the current or last job |
| Clean Time | read-only | n/a | 0.7.0: time of the current or last job |
| Last Full Clean | read-only | Not seen yet | 0.7.0: when the last whole-home job finished on the dock (used by the Start Full Clean guard) |
| Active Room | read-only | Unknown | Room under the robot; "Docked" on the dock; "<Room> (target)" during a room job |
| Room Progress | read-only | n/a | Per-room percent. Always n/a: the library has no per-room data |
| Web Page Status | read-only | Not opened yet | Set when the web view page reports its build |

## Variables

- `VACUUM_STATE` (string), `VACUUM_BATTERY` (number), `VACUUM_ERROR` (string, the error name, "none" when there is none)
- `UI_STATE` (string): JSON snapshot read by the web view page
- `ACTIVE_ROOM` (string), `ROOM_PROGRESS` (number, always 0)
- 0.7.0: `RUN_PROGRESS` (number 0-100; 0 when there is no job or no figure)
- 0.7.0: `CLEANING_MODE` (string: vacuum, vac_and_mop, mop, custom, smart_mode or empty)
- 0.7.0: `VACUUM_ERROR_TEXT` (string, e.g. "Main brush jammed"; "None" when there is none)
- 0.7.0: `VACUUM_ERROR_CODE` (number, 0 when there is none)
- 0.7.0: `IS_CLEANING` (bool: the state is a cleaning state), `IS_DOCKED` (bool: on the dock), `JOB_ACTIVE` (bool: from cleaning start until docked or stopped, pause and returning included)

- 0.7.0: `VACUUM_ACTIVITY` (string: cleaning, paused, returning, docked, idle, error, offline, other). Use this in conditionals; `VACUUM_STATE` has many more values

The variables are created with `C4:AddVariable` and written with `C4:SetVariable` before an event fires, so a program on Error Raised can read `VACUUM_ERROR_TEXT`.

## Programming commands

| Command | Parameters | Notes |
|---|---|---|
| Start | | Start or resume with the vacuum's own setting |
| Start Full Clean | Mode; Skip If Cleaned Within Hours (0-168) | 0.7.0. Whole-home job. With hours above 0 the job is skipped when a full clean finished within that time, or when a job is already running |
| Clean Rooms | Rooms; Mode | Rooms: ids (`16,17`) or room names from the vacuum's map (`Kitchen, Living room`). 0.7.0 adds Mode and names |
| Set Cleaning Mode | Mode | 0.7.0. Lasting change of the vacuum's own setting |
| Pause, Stop | | |
| Dock | | Return to dock. 0.7.0: safe to call at any time. When the robot is already on the dock (and no job is running and no start was sent in the last 3 minutes) nothing is sent and Last Command shows "Dock skipped: already on the dock". The check uses the last polled state, so a job started from the Roborock app in the last minute or so (bridge idle poll 60 s plus the driver poll) can be missed and the Dock skipped |

0.6.3: every command is accepted by its code (`START_FULL_CLEAN`) or its Composer name (`Start Full Clean`), also through `LUA_ACTION` and `ReceivedFromProxy`. An unknown command is logged as "unhandled command".

Mode is Device Setting (no change), Vacuum Only, Vacuum and Mop, or Mop Only. On Start Full Clean and Clean Rooms it applies to that job only: the bridge saves the vacuum's setting, sets the mode, starts the job and puts the setting back when the job has ended. Mop Only needs a vacuum that can mop without suction; if the vacuum does not have the mode the command is rejected (see Last Command) and nothing starts.

Refresh Now (action) re-reads the bridge state.

Room ids in this home: Study 16, Living room 17, Kitchen 18, Hall 19, Lounge 20, Laundry 21.

## Events

| ID | Event | Fires when |
|---|---|---|
| 1 | Cleaning Started | A job starts (first cleaning state). Once per job, not again after a pause |
| 2 | Cleaning Finished | A job has ended and the robot rests on the dock (charging, charging_complete) |
| 3 | Error Raised | Bridge reports a new error (not `none`) |
| 4 | Battery Low | Battery is at or below the threshold; fires once until the battery rises above it |
| 5 | Bridge Unreachable | Bridge request fails or returns a 5xx code; fires once per outage |
| 6 | Laundry Room Entered | While cleaning, the bridge's current room becomes the Laundry Room ID. If current_room is null: cleaning starts on a run targeting only that ID |
| 7 | Laundry Room Left | While cleaning, the current room changes away from the Laundry Room ID, or the job ends |
| 8 | Laundry Room Clean Started | The bridge accepts a clean job that includes the Laundry Room ID |
| 9 | Laundry Room Clean Finished | That job ends (on the dock, or stopped) |
| 10 | Docked | 0.7.0: the robot arrives on the dock from anywhere else |
| 11 | Error Cleared | 0.7.0: the error goes back to `none` |

0.7.0 fires every event by its name (`C4:FireEvent("Cleaning Started")`). Before 0.7.0 the driver passed the id number, which does not fire the event in Composer (the same fault as litter-robot before 1.0.2). The ids and names of events 1-9 are unchanged, so existing programs stay.

## State names

The bridge sends python-roborock's state names in lower case with underscores. The driver also accepts upper case and spaces or hyphens.

- Cleaning: any name with `clean` or `mopping` in it (`cleaning`, `segment_cleaning`, `zoned_cleaning`, `spot_cleaning`, `segment_mopping`, `zoned_mopping`, `clean_mop_cleaning`, ...)
- Returning: `returning_home`, `returning`, `docking`, `going_to_wash_the_mop`, `back_to_dock_washing_duster`
- Docked (resting): `charging`, `charging_complete`, `charging_problem`, `air_drying_stopping`, `docked`, `fully_charged`
- At the dock but busy: `emptying_the_bin`, `washing_the_mop`, `washing_the_mop_2`, `attaching_the_mop`, `detaching_the_mop`. Docked fires, the job is not finished yet
- Stopped: `idle` ends the job without Cleaning Finished
- `paused` and `error` keep the job open
- Recharge in the middle of a job: `charging` with `in_cleaning` above 0 and the battery below 100 keeps the job open (Docked fires, Cleaning Finished does not). `charging_complete` or a full battery always ends the job, and so does arriving on the dock after this driver sent Stop or Dock in that job

Activity (property) and `VACUUM_ACTIVITY` (variable) put all 43 python-roborock state names into eight words:

| Activity | States |
|---|---|
| error | `error`, or any state while the vacuum reports an error code |
| cleaning | `cleaning`, `spot_cleaning`, `zoned_cleaning`, `segment_cleaning`, and every `..._mopping` and `clean_mop_...` state |
| paused | `paused` |
| returning | `returning_home`, `docking`, `going_to_wash_the_mop`, `back_to_dock_washing_duster` |
| docked | `charging`, `charging_complete`, `charging_problem`, `air_drying_stopping`, `emptying_the_bin`, `washing_the_mop`, `washing_the_mop_2`, `attaching_the_mop`, `detaching_the_mop` |
| idle | `idle`, `charger_disconnected` |
| offline | `device_offline` |
| other | `starting`, `going_to_target`, `mapping`, `manual_mode`, `remote_control_active`, `updating`, `shutting_down`, `in_call`, `egg_attack`, `patrol`, `locked`, `unknown`, and any new name |

Seen on the live bridge (0.2.2, read on 2026-11-16, robot on the dock): `"state": "charging"`, `"error": "none"`, battery 100. No other state has been logged from a real run yet.

Before 0.7.0 the driver looked for `returning` and `docked`, which the bridge never sends. Cleaning Finished only fired when one poll went straight from cleaning to charging, and Laundry Room Clean Finished fired when the robot started for home. Both now fire on the dock.

These names come from reading python-roborock 7.22.0 (`RoborockStateCode`), not from a logged run. To confirm in a real run: `segment_cleaning` for a room job, `cleaning` for a whole-home job, `returning_home`, `charging` and `charging_complete` on the dock, the state after Stop (`idle` expected), and whether this dock reports `emptying_the_bin`. The State property shows the exact text.

## Progress

- Room Progress stays n/a. python-roborock has no per-room cleaned data.
- Run Progress with "(device)": the vacuum's own `clean_percent`. Only some models report it. To be confirmed on this vacuum.
- Run Progress with "(estimate)": cleaned area of this job divided by the cleaned area of the last finished job of the same kind (whole home, or the same room list). It is capped at 99. The first job of each kind shows n/a because there is nothing to compare with. Jobs that were stopped or sent home early are not used as a reference (a Dock sent while the robot is already returning home does not count as sent home early). The web page marks an estimate with "~" and "est.".

## Web view and tile icons

- Proxy: uibutton on binding 5001. Page: `www/vacuum2.html`, build 4 (file name kept from build 3, so the device does not need to be added again).
- 0.7.0 adds a Mode line, a "Mode for the next clean" selector (shown with bridge 0.2.3) and the job percent in the Progress field.
- The page sends `UI_START`, `UI_PAUSE`, `UI_DOCK`, `UI_STOP`, `UI_CLEAN_ROOMS_<ids>`, `UI_REFRESH`, `UI_HELLO_<build>`, and with a mode `UI_RUN_<VACUUM|VACMOP|MOP>_START` or `UI_RUN_<mode>_ROOMS_<ids>`.
- If Web Page Status shows "PAGE IS STALE: page 3", Navigator is still showing the cached old page. The old page keeps working with this driver. If it does not refresh, rename the page to vacuum3.html (file, `web_view_url` and the Lua header) in a later release.
- Tile icon states: Default, Cleaning, Docked (any dock state), Error.

## Composer programs (outlines)

Start on Away:

    When <house goes to Away>:
      Roborock -> Start Full Clean (Mode: Vacuum Only, Skip If Cleaned Within Hours: 20)

    For rooms only:  Roborock -> Clean Rooms (Rooms: Kitchen, Hall; Mode: Vacuum and Mop)

Dock on arrival:

    When <someone arrives / house goes to Home>:
      Roborock -> Dock          (no condition needed: it does nothing when the robot is already docked)

    When Roborock event Docked fires:   (optional: tell someone, turn a light off)

Error alert:

    When Roborock event Error Raised fires:
      Send push "Vacuum: " + Roborock VACUUM_ERROR_TEXT      (VACUUM_ERROR_CODE has the number)

    When Roborock event Error Cleared fires:   (optional)
      Send push "Vacuum error cleared"

    When Roborock event Bridge Unreachable fires:   (optional)

## Installing 0.7.0

1. Build and start bridge 0.2.3 on liesa first (see `tools/roborock-bridge/README.md`).
2. In Composer run "Add or Update Driver" with `c4z/roborock.c4z`. The proxy and web view URL are unchanged, so the device stays.
3. Check Driver Version 0.7.0, Bridge Version 0.2.3, Cleaning Mode not "Unknown".
4. Existing programs on Start, Stop, Pause, Dock and Clean Rooms keep working. Clean Rooms without a Mode behaves as before.

## History

- 0.7.0 (2026-11-16): per-job cleaning mode, Run Progress, state names fixed, events 10 and 11, Start Full Clean, Set Cleaning Mode, room names in Clean Rooms, error text and code, Last Command, Activity / VACUUM_ACTIVITY, events fired by name, Dock skipped when already docked, a recharge in the middle of a job no longer ends it. Bridge 0.2.3.
- 0.6.3: Composer command names and LUA_ACTION accepted in ExecuteCommand; ReceivedFromProxy added.
- 0.6.2: Laundry Room Clean Started fires when the bridge accepts the job. Adaptive polling.
- 0.6.0: Room field shows Docked and the target room. Events 8 and 9.
- 0.5.1: events moved to devicedata level so Composer lists them.
- 0.5.0: Active Room from the bridge's parsed map (bridge 0.2.0). Page vacuum2.html.
- 0.4.0: Laundry Room Entered and Left (run-target rule).
- 0.3.0: rooms in the UI snapshot, UI_CLEAN_ROOMS.
- 0.2.0: uibutton proxy, web view and tile icons. A changed proxy needs the device to be deleted and added again.
