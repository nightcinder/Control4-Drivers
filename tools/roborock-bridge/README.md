# roborock-bridge (0.2.0, UNTESTED against a real vacuum)

Small LAN HTTP bridge around python-roborock (pinned 7.22.0). Polls the vacuum at most every 60 s.

## Files
- app.py: `login` mode and `serve` mode
- requirements.txt, Dockerfile (python:3.12-slim, non-root uid 10001)
- compose.roborock.yml: service definition only, to paste under `services:` in ../docker-compose.yml. Do not paste it until you have tested it.
- data/: volume for roborock.json (mode 600). Holds login tokens. Never commit it.

## Build
    docker build -t roborock-bridge:0.2.0 /home/liesa/automation-pollers/roborock-bridge

The build path is the one used for 0.1.0 (from the stack notes). Confirm it on liesa before building.

## One-time login
The container user is uid 10001, so give it ownership of data/ first:

    sudo chown 10001:10001 /home/liesa/automation-pollers/roborock-bridge/data
    cd /home/liesa/automation-pollers
    docker run --rm -it -v /home/liesa/automation-pollers/roborock-bridge/data:/data roborock-bridge:0.2.0 python app.py login

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
- POST /command: `{"action":"start|stop|pause|dock|clean_rooms","rooms":[ids]}`. `rooms` is required for clean_rooms.

There is no authentication. The port is published on the LAN, so anyone on the LAN can command the vacuum. Keep it off the internet.

## Open items
- Verify against a real vacuum: state/battery field names, APP_SEGMENT_CLEAN parameter shape, UserData.from_dict.
- Room and segment listing is not implemented.

## Bridge 0.2.0 notes (v0.5.0 driver)

- Added `current_room` to /state, read from `MapData.vacuum_room` in python-roborock 7.22.0 (the library's own robot-position lookup in the parsed map). Not tested on a vacuum.
- `room_progress_pct` is null. The v1 map parser gives room bounding boxes but no per-room pixel counts, and it never fills `MapData.cleaned_rooms`, so a per-room percentage cannot be derived from the library.
- `run_progress_pct` is null for the same reason (it needs the room area in pixels).
- The map fetch is a separate task (`map_loop`) so it runs on its own 15 s / 300 s schedule, not on the 60 s status poll.
- Image tag: roborock-bridge:0.2.0. Stack change: the compose file image line. Run `docker build` on liesa, then recreate the container (see the Portainer stack steps in docs/roborock.md).

## Bridge 0.1.0 notes (v0.4.0 driver)

The bridge is unchanged in this release, so the image stays roborock-bridge:0.1.0. There is no mop mode field and no current_room in /state. The driver's Laundry Room Entered and Left events are computed in the driver from the clean_rooms target (see docs/roborock.md).
