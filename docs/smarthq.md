# SmartHQ Bridge (Control4 driver)

Version 0.1.0. UNTESTED on real Composer or Director. Read-only: no control commands.

Reads appliance state from the LAN HTTP bridge running on liesa.

## Bridge

- Base URL: `http://172.21.1.157:8789` (driver properties `Host` and `Port`)
- `GET /health`: 200 when healthy, 503 when stale or not logged in
- `GET /appliances`: list of `{id, type, name, online}`
- `GET /appliances/{id}/state`: flat JSON of readable values

## Properties

| Property | Type | Notes |
|---|---|---|
| Host, Port | string, 1-65535 | Defaults to the bridge above |
| Oven Appliance ID | string | Paste from Discovered Appliances |
| Dishwasher Appliance ID | string | Paste from Discovered Appliances |
| Discovered Appliances | read-only | Filled by the Discover Appliances action: `id \| type \| name \| online` |
| Poll Interval | 30-3600 s | Default 60 |
| Log Mode | Off / Print / Log | Print goes to the driver console, Log goes to the error log |
| Status | read-only | Last poll result |
| Oven State, Oven Temperature, Oven Timer Remaining | read-only | Also driver variables |
| Dishwasher State, Dishwasher Time Remaining | read-only | Also driver variables |

The dropdown for the appliance IDs is a free-text field in this version. Control4 cannot fill a LIST property at run time from Lua, so copy the ID from Discovered Appliances.

## Actions

- Discover Appliances: calls `/appliances`, logs id, type and name for each, fills Discovered Appliances.
- Refresh Now: polls immediately.

## Events

1. Oven Preheated: preheating flag goes from true to false while the oven is in an active state.
2. Oven Timer Done: oven timer goes from above zero to zero while the oven is active.
3. Dishwasher Done: dishwasher goes from active to idle, or `cycle_done` goes from false to true.
4. Bridge Unreachable: fires once when the bridge stops responding or health is not 200.

## Confirmed fields (oven, upper cavity)

Seen in a real reply from oven `D828C9B3D140` (online):

- `upper_current_temp_f`, `upper_target_temp_f` (numbers, showed 0 while idle)
- `upper_cook_mode` (returned as a Python repr string, not parsed; not used)
- `upper_cook_state` (for example `STATUS_DASH` when idle)
- `upper_preheating` (boolean)
- `upper_timer_remaining_s` (seconds, 0 when idle)

Lower cavity fields are present (`lower_current_temp_f`, `lower_target_temp_f`, `lower_cook_mode`, `lower_cook_state`, `lower_preheating`, `lower_timer_remaining_s`). The driver does not use them yet. `lower_timer_remaining_s` was null.

## Unconfirmed

- All dishwasher fields. No dishwasher was online when this was written. The driver tries `dishwasher_cycle_state`, `cycle_state`, `dishwasher_state`, `dishwasher_time_remaining_s`, `cycle_time_remaining_s`, `time_remaining_s`, and `cycle_done`.
- Whether `cycle_done` is sent by the bridge. If not, the Dishwasher Done event depends on the active-to-idle transition only.
- The oven state strings for an active bake or preheat. Only the idle value `STATUS_DASH` was seen.
- Whether the Oven Timer Done heuristic also fires when the oven is switched off with a timer running.
- Discover output in Composer. Icons are copied from the Jellyfin driver as placeholders.

## Build

`python tools/build_c4z.py drivers/smarthq` writes `c4z/`. Not run in this version; see the commit notes.

## Version 0.2.0: hood light (UNTESTED)

Adds control of the GE Cafe vent hood light through the bridge. Nothing else is writable.

- Property `Hood Appliance ID`: the hood MAC address, `D828C9A77374` on the current install. Set it in Composer.
- Proxy `Hood Light` (type `light_v2`, binding 5001): ON sends `level:"on"` (HIGH), OFF sends `level:"off"`. SET_LEVEL 1 to 50 sends `dim`, above 50 sends `on`. The light state follows the polled hood state. The notify calls (`ON`/`OFF` via `C4:SendToProxy`) are UNCONFIRMED against the Control4 light_v2 spec.
- Programming actions: `Hood Light On`, `Hood Light Off`.
- Variable `Hood Light` holds the bridge `light_level` string.

Bridge side (liesa, `smarthq-bridge` 0.2.0): `POST /appliances/{id}/command` with `{"action":"light","level":"off|dim|on"}`. Hood only. Anything else returns 400. The bridge sets ERD `HOOD_LIGHT_LEVEL` (0x5b02) through the SDK's `async_set_erd_value`, then returns the hood state.

Confirmed on the real hood (read on 2026-11-12 with the SDK, before this change): `HOOD_LIGHT_LEVEL` = OFF. Availability raw `07` means off, dim and high are available; there is no med level. `HOOD_FAN_SPEED` = OFF. The `HOOD_ACTUAL_LIGHT_LEVEL` and `HOOD_REQUESTED_LIGHT_LEVEL` ERDs are not populated by this hood.

Untested: the write has not been sent to the real hood. Confirm that the light turns on, dims and turns off, and that the hood state follows, before relying on it.
