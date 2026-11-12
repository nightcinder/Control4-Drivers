# smarthq-bridge 0.2.0

LAN HTTP JSON API for GE SmartHQ appliances (Cafe, etc.), built on `gehomesdk` 2026.8.0.

**Status: untested against real appliances.** ERD field names marked "unconfirmed" below were not verified on hardware.

## First-time login

Run once, from the compose project folder (`/home/liesa/automation-pollers`). Prompts for email, password, and an MFA code if SmartHQ asks for one. The password is not stored.

```
mkdir -p smarthq-bridge/data && sudo chown 10001:10001 smarthq-bridge/data
docker compose -f docker-compose.yml -f smarthq-bridge/compose.smarthq.yml run --rm -it smarthq-bridge python app.py login
```

This writes `smarthq-bridge/data/smarthq.json` (mode 600) containing the username, region and refresh token only.

## Enabling the service

`compose.smarthq.yml` is a standalone fragment. Merge it with the main file using `-f` (do not edit `docker-compose.yml`):

```
docker compose -f docker-compose.yml -f smarthq-bridge/compose.smarthq.yml --profile smarthq up -d smarthq-bridge
```

Build the image first if needed: `docker build -t smarthq-bridge:0.2.0 smarthq-bridge`.

## API (port 8789, LAN only)

| Route | Result |
|---|---|
| `GET /health` | 200 when appliance data is under 5 min old. 503 otherwise, with `status` text (not logged in, no data yet, or stale) and `last_success_age_s`. |
| `GET /appliances` | List of `{id, type, name, online}`. `id` is the appliance MAC address (unconfirmed as the API key; see below). |
| `GET /appliances/{id}/state` | Flat JSON of readable values. Ovens: `upper_*` / `lower_*` current temp, target temp, cook mode and state, `preheating`, timer remaining. Dishwashers: `cycle_state`, `cycle_done`, `time_remaining_s`, `door_status`. Hood: `light_level` (OFF, DIM or HIGH; ERD HOOD_LIGHT_LEVEL) and `fan_speed`. |
| `POST /appliances/{id}/command` | The only write. Body `{"action":"light","level":"off"|"dim"|"on"}`, where `on` sends HIGH. Hood only; anything else returns 400. Sends the SDK's `async_set_erd_value` for HOOD_LIGHT_LEVEL, waits about 2 s, and returns the hood state. Returns 502 if the SDK write fails. UNTESTED against the real hood. |

## ERD fields used

Confirmed to exist as names in `gehomesdk` 2026.8.0 `erd_codes.py`:
- Oven: `UPPER_OVEN_` / `LOWER_OVEN_` `CURRENT_STATE`, `DISPLAY_TEMPERATURE`, `COOK_MODE`, `COOK_TIME_REMAINING`, `KITCHEN_TIMER`
- Oven preheat: `preheating` is derived from `CURRENT_STATE` being one of `BAKE_PREHEAT`, `CONV_BAKE_PREHEAT`, `CONV_MULTI_BAKE_PREHEAT`, `CONV_ROAST_BAKE_PREHEAT` (confirmed enum names; the mapping to real appliance behaviour is not verified)
- Dishwasher: `DISHWASHER_CYCLE_STATE`, `DISHWASHER_TIME_REMAINING`, `DISHWASHER_DOOR_STATUS`
- Hood (0.2.0): `HOOD_LIGHT_LEVEL` (0x5b02, enum `ErdHoodLightLevel`: OFF, DIM, HIGH, MED). Read from the real hood on 2026-11-12: value OFF, availability raw `07` (off, dim, high; no med). `HOOD_FAN_SPEED` (0x5b00) read as OFF. `HOOD_ACTUAL_LIGHT_LEVEL` / `HOOD_REQUESTED_LIGHT_LEVEL` (0x5b17/0x5b18) are not populated by this hood, so the write uses `HOOD_LIGHT_LEVEL`.

Unconfirmed:
- `cycle_done` is not a dedicated ERD. It is derived in memory: it becomes true when the cycle state moves from an active state to idle (`CYCLE_INACTIVE` or `NA`), and clears when a new cycle starts. It resets to false on restart.
- Oven target temperature reads `temperature` from the decoded cook-setting object. That attribute name was not confirmed.
- Oven `preheated` (finished preheating) has no confirmed field. Only `preheating` is provided.
- Oven and range appliance type names are matched by substring (`OVEN` or `RANGE`).
- Appliance id is the MAC address. The SDK's `mac_addr` property was confirmed; using it as the URL key is a design choice.

## Notes

- The data volume is owned by UID 10001 (the container user). Keep `data/` out of git and out of the image; `.dockerignore` excludes it.
- The refresh token is rewritten to `smarthq.json` if the SDK rotates it (the attribute name is unconfirmed).
- Logs contain no credentials. Errors are logged by exception type only.
