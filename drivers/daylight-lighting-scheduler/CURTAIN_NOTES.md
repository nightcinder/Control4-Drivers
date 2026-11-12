# DLS curtain automation (1.9.0, UNTESTED)

Optional layer that drives SwitchBot Curtain blind proxies from the same sun, cloud and time-of-day data the lights use.
Nothing moves until the master property **Curtain Automation** is set to On (default Off).

## Setup

1. Find each SwitchBot Curtain child proxy ID in Composer.
2. Add a `curtains` list to the room entry in **Rooms JSON**:

```json
"curtains":[{"id":1234,"name":"Den West","facing_deg":270,
  "open_level":100,"closed_level":0,
  "open_at":"sunrise+15","close_at":"sunset+30",
  "glare_threshold":0.35,"glare_position":25}]
```

| Field | Default | Meaning |
|---|---|---|
| `id` | required | Blind proxy ID (must be a SwitchBot Curtain child) |
| `facing_deg` | room `facing_deg` | Compass direction the window faces |
| `open_level` / `closed_level` | 100 / 0 | Control4 level for fully open / fully closed |
| `open_at` / `close_at` | `sunrise+15` / `sunset+30` | Times as `HH:MM` or `sunrise±min` / `sunset±min` |
| `glare_threshold` | 0.35 | Direct-sun index at which the curtain drops to `glare_position` |
| `glare_position` | 25 | Openness (0 to 100 percent) used while glare is above threshold |

## Rules (each 5-minute Update pass)

- Before `open_at`, at or after `close_at`, or with the sun below the horizon: closed.
- Direct-sun index = max(0, cos(sun azimuth - facing)) x sin(sun elevation) x cloud transmittance. At or above the threshold: `glare_position`.
- Otherwise: open.
- Not evaluated while presence is Away.
- `times` do not wrap past midnight. `close_at` must be later than `open_at` on the same day.

## Command limits

- A curtain is commanded only when its target moved by at least 10 points since its last command, and at least 15 minutes have passed since that command.
- All curtains together: at most 200 commands per local day.
- Commands are sent through the existing 250 ms send queue.
- Fully open or closed targets send `OPEN` or `CLOSE` (only when `open_level` is 100 and `closed_level` is 0). Anything else sends `SET_POSITION` with `POSITION` = level.
- SwitchBot takes 3 to 5 s per command, so position feedback arrives late.

## Known limits and open questions

- Curtain state is not persisted. After a driver restart, each curtain gets one command on the first pass.
- The driver does not read the blind's actual position. A manual move is not corrected until the target changes by 10 points.
- Parameter name `POSITION` for `SET_POSITION` and the `OPEN`/`CLOSE` names are taken from the SwitchBot Curtain child driver; not verified against the live proxy.
- Whether a level of 100 means open depends on the blind's calibration; check `open_level`/`closed_level` with one curtain first.
- Debug output: set Debug to On and look for `curtain command`, `curtain held` and `curtain skipped`.
