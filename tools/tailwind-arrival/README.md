# Tailwind arrival trigger

Polls the Tailwind iQ3 garage door controller on the LAN (local API, no cloud) and calls the
dls-presence `/arrival` endpoint when a garage door closes. The bridge forces HOME for 15 minutes
only when the household is currently AWAY, which covers the phone's slow return to home Wi-Fi
after Android Auto. A door close while leaving is a no-op because the house is still HOME.

## Setup

1. Copy the 6-digit Local Control Key from web.gotailwind.com (Local Control Key) into
   `/home/liesa/automation-pollers/secrets/tailwind.env` as `TAILWIND_TOKEN=`.
2. The same file needs `ARRIVAL_TOKEN` matching `dls-presence.env`.
3. The container is `tailwind-arrival` in the `automation-pollers` Portainer stack. It mounts
   this directory at `/app`, the env file at `/run/tailwind.env`, and talks to
   `http://dls-presence:8731/arrival` on the `monitoring` network.
4. The script re-reads `TAILWIND_TOKEN` while it is empty, so adding the key does not need a
   container restart.

Test: `docker logs -f tailwind-arrival` while opening and closing the garage door. An open edge
logs `door1: close -> open` and the arrival POST result (`noop` when already home). `OPEN_TRIGGER=1`
(default) fires on the open edge; set 0 to use only the close edge. A 20 s cooldown stops the
open+close pair firing twice.

The dls-presence side: `POST /arrival` with `X-Arrival-Token`; `GET /state` returns the current
state and force expiry. The endpoint is on the freshness port (8731), token-protected.
