# roborock-bridge (0.2.3)

Small LAN HTTP bridge around python-roborock (pinned 7.22.0). Polls the vacuum every 60 s, and every 5 s while it is cleaning, returning or busy at the dock.

0.2.3 is NOT yet built or deployed on liesa and its new parts (cleaning mode, progress fields) are not yet checked on the vacuum. See "Bridge 0.2.3 notes" below.

## Files
- app.py: `login` mode and `serve` mode
- test_app.py: unit tests (no vacuum and no python-roborock needed): `python -m unittest discover -s tools/roborock-bridge -p "test_*.py"`
- requirements.txt, Dockerfile (python:3.12-slim, non-root uid 10001)
- compose.roborock.yml: service definition only, to paste under `services:` in ../docker-compose.yml. Do not paste it until you have tested it.
- data/: volume for roborock.json (mode 600). Holds login tokens. Never commit it.

## Build
    docker build -t roborock-bridge:0.2.3 $HOME/automation-pollers/roborock-bridge

The build path is the one used for 0.1.0 (from the stack notes). Confirm it on liesa before building.

## One-time login
The container user is uid 10001, so give it ownership of data/ first:

    sudo chown 10001:10001 $HOME/automation-pollers/roborock-bridge/data
    cd $HOME/automation-pollers
    docker run --rm -it -v $HOME/automation-pollers/roborock-bridge/data:/data roborock-bridge:0.2.3 python app.py login

The login file from 0.1.0 is still valid; this step is only needed if the data/ folder is missing.

Enter the account email, then the code from the email. The file /data/roborock.json is written with mode 600.

## Enable the service
1. Paste the contents of roborock-bridge/compose.roborock.yml under `services:` in docker-compose.yml.
2. Start it: `docker compose --profile roborock up -d roborock-bridge`
3. Check: `curl -s http://liesa:8788/health`

## API
- GET /health: 200 if the last successful poll is under 300 s old, else 503. Includes the age per source.
- GET /state: state, battery, error, rooms (id and name per segment), last_success_age_s, and (0.2.0):
  - `current_room`: `{"id": segment_id, "name": "..."}` or null. From python-roborock's parsed map (`MapData.vacuum_room`). The map is fetched every 15 s while cleaning and every 300 s otherwise, and null is returned when the cached map is older than 120 s or the room cannot be determined.
  - `room_progress_pct` and `run_progress_pct`: always null in 0.2.0 (see Bridge 0.2.0 notes).
  - 0.2.3: `error_code` (number), `in_cleaning`, `clean_time_s`, `clean_area_m2`, `clean_percent`, `cleaning_mode` (vacuum, vac_and_mop, mop, custom, smart_mode or null), `water_mode`, `fan_speed`, `mop_route`, `cleaning_modes` (the modes this vacuum has), `run_progress_pct` (the vacuum's own `clean_percent`, null on models without it), `run_progress_source` ("device" or null), `mode_restore_pending`, `bridge_version`.
- POST /command: `{"action":"start|stop|pause|dock|clean_rooms|set_mode","rooms":[ids],"mode":"vacuum|vac_and_mop|mop"}`. `rooms` is required for clean_rooms. `mode` is optional on start and clean_rooms (for that job only) and required on set_mode (lasting). Answers: 202 accepted, 400 bad body, 409 vacuum not ready, 422 the vacuum does not have that mode, 502 the vacuum refused or did not answer.

There is no authentication. The port is published on the LAN, so anyone on the LAN can command the vacuum. Keep it off the internet.

## Open items
- 0.2.3 on the real vacuum: `set_clean_motor_mode` accepted, the mode put back after the job, `clean_percent` reported or null, `clean_area` unit (the library says mm2), state names during a whole run.

## Bridge 0.2.3 notes (v0.7.0 driver)

- Per-job cleaning mode. The mode (suction, water, mop route) is a lasting setting on the vacuum, there is no per-job option. For `start` or `clean_rooms` with a `mode` the bridge reads the current codes, sets the mode with python-roborock's own mode table (`get_cleaning_mode_parameters`), starts the job, and puts the saved codes back when the job has ended. The current suction level, water level and route are kept where they fit the mode, so "vacuum" only turns the water off.
- When is the job over: the job was seen running, the state is charging, charging_complete, charging_problem, docked or idle, and `in_cleaning` is 0 (so a recharge in the middle of a job does not restore early). A job never seen running is restored after 180 s. After 8 hours the setting is put back anyway unless the robot is cleaning.
- The saved codes are also written to `/data/mode_restore.json` (next to the login file; set `ROBOROCK_RESTORE` to move it), so a container restart in the middle of a job still restores. The file holds three numbers and no secrets.
- If the job does not start, the mode is put back at once. A `start` or `clean_rooms` without a mode first puts back a setting that is still waiting, unless a job is running or paused.
- `set_mode` is a lasting change and drops any waiting restore.
- If the vacuum refuses `set_clean_motor_mode`, the three older commands are tried (`set_custom_mode`, `set_water_box_custom_mode`, `set_mop_mode`).
- State names: the bridge sends python-roborock's `RoborockStateCode` names in lower case (`returning_home`, `charging_complete`, ...). `state` in /state is always passed through the same lower-case, underscore form the bridge uses for its own checks. The live 0.2.2 bridge showed `"state": "charging"` on the dock (2026-11-16). The old code compared with `returning`, which never matched, so fast polling stopped when the robot turned for home. Fixed: returning and dock service states poll at POLL_ACTIVE.
- After each command the status is polled again 2, 8 and 20 s later, so /state follows the robot without waiting up to 60 s.
- A command that times out (30 s) is now cancelled instead of running on after the caller was told it failed.
- /health carries `version`.
- Deploy by hand on liesa: copy app.py to the build folder, `docker build -t roborock-bridge:0.2.3 <folder>`, change the image line of the roborock-bridge service to `roborock-bridge:0.2.3`, recreate the service, then `curl -s http://liesa:8788/state` and look for `"bridge_version": "0.2.3"`. The data volume and login file are unchanged.

## Bridge 0.2.0 notes (v0.5.0 driver)

- Added `current_room` to /state, read from `MapData.vacuum_room` in python-roborock 7.22.0 (the library's own robot-position lookup in the parsed map). Not tested on a vacuum.
- `room_progress_pct` is null. The v1 map parser gives room bounding boxes but no per-room pixel counts, and it never fills `MapData.cleaned_rooms`, so a per-room percentage cannot be derived from the library.
- `run_progress_pct` is null for the same reason (it needs the room area in pixels).
- The map fetch is a separate task (`map_loop`) so it runs on its own 15 s / 300 s schedule, not on the 60 s status poll.
- Image tag: roborock-bridge:0.2.0. Stack change: the compose file image line. Run `docker build` on liesa, then recreate the container (see the Portainer stack steps in docs/roborock.md).

## Bridge 0.1.0 notes (v0.4.0 driver)

The bridge is unchanged in this release, so the image stays roborock-bridge:0.1.0. There is no mop mode field and no current_room in /state. The driver's Laundry Room Entered and Left events are computed in the driver from the clean_rooms target (see docs/roborock.md).
