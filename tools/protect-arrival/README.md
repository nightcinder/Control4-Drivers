# Protect arrival trigger

UniFi Protect garage-camera vehicle detection -> dls-presence `/arrival`. This is the local
equivalent of Tailwind's auto-open: the car actually entered the garage, so a manual door open
with no car does not force HOME. It fired at 17:34:00 on 2026-11-17 (person+vehicle, score 94),
84 seconds before Life360 reported HOME.

## Setup

- `secrets/protect.env` (mode 0600) on liesa: `PROTECT_URL`, `PROTECT_USER`, `PROTECT_PASS`
  (a UniFi OS user with Protect access; the unpoller user works), `PROTECT_CAMERAS=Garage`,
  `ARRIVAL_URL=http://dls-presence:8731/arrival`, `ARRIVAL_TOKEN` (same as dls-presence.env).
- Container `protect-arrival` in the `automation-pollers` Portainer stack; it polls the Protect
  events API every 3 s and posts once per vehicle event (60 s cooldown).
- Test without firing: `python3 protect_arrival.py --test --minutes 60` (prints matching events).
- The Garage camera (G5 Bullet) sees a car inside; the Driveway camera (G4 Pro) sees any car on
  the drive. Neither model does license-plate recognition, so this identifies a vehicle, not a plate.
- The Tailwind watcher is now a close-edge fallback only (`OPEN_TRIGGER=0`); the Protect event is
  the primary arrival signal.
