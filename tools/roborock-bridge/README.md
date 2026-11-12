# roborock-bridge (0.1.0, UNTESTED against a real vacuum)

Small LAN HTTP bridge around python-roborock (pinned 7.22.0). Polls the vacuum at most every 60 s.

## Files
- app.py: `login` mode and `serve` mode
- requirements.txt, Dockerfile (python:3.12-slim, non-root uid 10001)
- compose.roborock.yml: service definition only, to paste under `services:` in ../docker-compose.yml. Do not paste it until you have tested it.
- data/: volume for roborock.json (mode 600). Holds login tokens. Never commit it.

## Build
    docker build -t roborock-bridge:0.1.0 /home/liesa/automation-pollers/roborock-bridge

## One-time login
The container user is uid 10001, so give it ownership of data/ first:

    sudo chown 10001:10001 /home/liesa/automation-pollers/roborock-bridge/data
    cd /home/liesa/automation-pollers
    docker run --rm -it -v /home/liesa/automation-pollers/roborock-bridge/data:/data roborock-bridge:0.1.0 python app.py login

Enter the account email, then the code from the email. The file /data/roborock.json is written with mode 600.

## Enable the service
1. Paste the contents of roborock-bridge/compose.roborock.yml under `services:` in docker-compose.yml.
2. Start it: `docker compose --profile roborock up -d roborock-bridge`
3. Check: `curl -s http://liesa:8788/health`

## API
- GET /health: 200 if the last successful poll is under 300 s old, else 503. Includes the age per source.
- GET /state: state, battery, error, rooms (empty for now), last_success_age_s
- POST /command: `{"action":"start|stop|pause|dock|clean_rooms","rooms":[ids]}`. `rooms` is required for clean_rooms.

There is no authentication. The port is published on the LAN, so anyone on the LAN can command the vacuum. Keep it off the internet.

## Open items
- Verify against a real vacuum: state/battery field names, APP_SEGMENT_CLEAN parameter shape, UserData.from_dict.
- Room and segment listing is not implemented.
