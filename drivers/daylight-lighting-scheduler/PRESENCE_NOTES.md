# DLS presence lighting (driver 1.10.1) - UNTESTED

Status: first slice written, not yet run against any hardware. Nothing changes until Nick sets
**Presence Lighting = On**. With it Off, the driver behaves exactly as 1.7.0.

## What it does (when Presence Lighting = On)

- A room with an `occ` binding becomes **vacant** only after its sensor has read empty continuously for
  `vacancyDelaySec` (room setting; default = driver property **Vacancy Delay (min)**, 10 min). A brief sensor
  drop-out does not cut the lights, because any "occupied" reading cancels the pending vacancy at once.
- Occupied again -> the room is occupied immediately and the schedule may turn the lights on at the level
  DLS already computes for the time of day and daylight (no separate per-period level in this slice).
- Vacant -> lights in that room ramp to 0 over the normal ramp time (or `off_ramp_min` if set on the room
  path; this slice uses the ramp time). The room stays dark until occupied again.
- Turn-on is still gated by the schedule window (`on` / `off` / `on_daylight`) and the day list. Presence
  does not turn lights on outside their window.
- Manual override: a manual change to a light (or a scene hold) holds the room as before. While the room is
  vacant, that hold does **not** keep the lights on unless **Vacancy Overrides Manual Hold = On**. Default Off,
  which means a hold keeps lights on until it expires even when the room is empty (see open questions).
- Wake ramp and daylight-follow mode are also suppressed while the room is vacant.
- Away (whole-house HOME/AWAY from the presence bridge) still takes precedence, as before.

## Rooms JSON additions

```json
{"name":"Laundry","type":"lifx_only","on":"sunset-15","off":"23:00",
 "occ":{"dev":1234,"var":1000,"vacancyDelaySec":600,"invert":false},
 "lux":{"dev":1234,"var":1001,"target":200},
 "lights":[{"id":480,"kind":"lifx"}]}
```

- `occ.dev` / `occ.var`: Control4 device id and variable id of the ESPHome occupancy/presence variable.
  Existing 1.7.0 fields, unchanged.
- `occ.vacancyDelaySec` (new): seconds before vacancy is confirmed. Minimum 10.
- `occ.invert` (new): true if the variable reads "1/true/on/open" when the room is EMPTY.
- `lux` (existing): optional illuminance closed loop. Point it at the ESPHome lux variable if the sensor
  exposes it. Untested with the Everything Presence sensors.

Room `occ` with no `dev` is ignored (room is always treated as occupied).

## Driver properties (new)

| Property | Default | Meaning |
|---|---|---|
| Presence Lighting | Off | Master enable for occupancy-driven on/off. |
| Vacancy Delay (min) | 10 | Default vacancy delay for rooms without `vacancyDelaySec`. |
| Vacancy Overrides Manual Hold | Off | Whether vacancy turns lights off even inside a manual or scene hold. |

## Binding the ESPHome driver variables (for Nick, once sensors arrive)

1. Add one Finite Labs ESPHome driver instance per sensor (control4-esphome, AGPL-3.0). One instance per device.
2. Note the Control4 device id of each ESPHome instance (Device Settings in Composer).
3. In Composer, open the ESPHome instance's Variables tab. The binary presence sensor appears as a
   contact-style variable and any illuminance sensor appears as a read-only number variable. Note the
   variable id (the number in the Variables list, not the name). Confirm the exact ESPHome entity names
   once the sensors are on the network.
4. Put `{"dev": <device id>, "var": <variable id>}` into the room's `occ` (and `lux` if used).
5. Check the actual value strings in Debug output (`occupied` / `vacancy confirmed` lines). If the sensor
   reports Open/Closed or another string, adjust `parseOcc` or use `invert`. Not yet known.

## Untested

- Every item above. The vacancy latch and timer (`startVacancyTimer`, `onOccupancy`, `resetOccupancy`).
- Variable listener delivery from ESPHome contact variables (value strings are a guess: "0/1/true/false/
  on/off" are treated as the two states).
- Vacate ramp to 0 and the interaction with light-level feedback (`curLevel` > 0 repeats the 0 command each
  pass until the feedback catches up).
- Interaction with the existing override detection and scene holds.
- Rooms JSON editor (tools/rooms-json-editor) does not yet offer the new `occ` fields. Edit the JSON by hand
  for now.

## Open questions for Nick

1. Exact ESPHome entity names and whether the presence sensor reports 0/1 or Open/Closed through Control4.
2. Should a manual light change while the room is vacant (e.g. someone turns on a bathroom light and
   leaves) switch off after the vacancy delay? That is the current Vacancy Overrides Manual Hold = Off
   behaviour in reverse. Decide the default.
3. Per-period on-level (e.g. dimmer after bed time while occupied) is not implemented. Current levels
   come from the existing time-of-day envelope and daylight model. Is that enough?
4. Laundry and pantry: want turn-on to require a minimum dwell (e.g. ignore pass-throughs) before lights
   come on? Not implemented.
5. Bathrooms: longer vacancy delay (e.g. 20 min) may be wanted. Set per room in Rooms JSON.
