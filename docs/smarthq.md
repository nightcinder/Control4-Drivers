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

## Version 0.3.0: parent and child drivers (UNTESTED in Composer)

The single driver (`drivers/smarthq`, 0.2.x) stays in place. 0.3.0 splits it into three drivers. Nothing here has been run in Composer or Director.

| Driver | Package | Role |
|---|---|---|
| SmartHQ Bridge | `c4z/smarthq-bridge.c4z` | Parent. Polls `GET /inventory` on the liesa bridge (172.21.1.157:8789) every Poll Interval seconds and pushes each appliance's state to its children. Action: Refresh Now. Event: Bridge Unreachable. |
| SmartHQ Appliance | `c4z/smarthq-appliance.c4z` | Child, one per appliance. Set Appliance Type (Oven, Beverage Center, Dishwasher, Refrigerator, Washer, Dryer) and Appliance ID. Read-only state properties. Events: Oven Preheated, Oven Timer Done, Dishwasher Done, Washer Done, Dryer Done, Door Left Open. |
| SmartHQ Hood Light | `c4z/smarthq-hood-light.c4z` | Child, one for the hood. A light_v2 proxy with off, dim and high. Writes go through the parent (`POST /appliances/{id}/command`, the same call as 0.2.x). |

Door Left Open fires once per opening after Door Open Alert Minutes (default 2, 0 turns it off). The timing follows the parent poll, so it is only as exact as Poll Interval (default 60 s).

### Binding the children in Composer (by hand)

1. Add the SmartHQ Bridge driver to the project. Set Host, Port and Poll Interval if they differ from the defaults.
2. Add one SmartHQ Appliance driver per appliance. Set Appliance Type and paste the Appliance ID from `GET /inventory` (oven D828C9B3D140, beverage center D828C947C21D, dishwasher D828C9B56AC7, fridge D828C9814D8C, washer D828C98E297F, dryer D828C972D59D).
3. Add the SmartHQ Hood Light driver. Its Appliance ID defaults to the hood, D828C9A77374. Place it in the Downstairs room.
4. In Connections for each child (Appliance and Hood Light), bind "SmartHQ Bridge" to the SmartHQ Bridge driver. The children find the parent only through this binding.
5. Wait one poll interval. Each child's Status should change to "Updated" (appliances) or "Hood light ..." (hood).

### Unverified

- Oven state names (preheat detection) and oven cook-time units are guesses. Check the real values on a live oven before trusting Oven Preheated or Oven Timer Done.
- Dishwasher, washer and dryer "Done" events fire when the operating state goes from active to idle. "Active" means any state not in the idle list in the bridge parent (STATUS_DASH, STATUS_OFF, NA, and similar). Those names are unverified.
- The hood light level feedback uses `LIGHT_CHANGED` with LEVEL, which is not confirmed for light_v2. ON and OFF match the 0.2.x driver. Check that the light's slider follows the hood.
- Nothing here has been sent to a real appliance during testing. The only write is the hood light, and it has not been exercised in 0.3.0.
