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
