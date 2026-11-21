# Sensor prep for Saturday 2026-11-21

Drafts for the first Everything Presence sensor. Three sensors arrive (two Pro, one One); the
first one goes in **Laundry** (Lutron dimmer id 568). Nothing here is live yet:
`dls-presence.rooms.laundry.draft.json` still contains **3 `<<FILL: ...>>` placeholders** (`host`,
`key`, `pir`), so strict mode fails until they are filled.

Verified ESPHome `object_id`s:

- **Everything Presence One**: `binary_sensor` `object_id`s `occupancy`, `mmwave`, `pir` (use
  `"entity": "occupancy"`, `"pir": "pir"`).
- **Everything Presence Pro**: `binary_sensor` `object_id`s `occupancy`, `mmwave_presence`,
  `motion`, `zone_N_presence`, plus `sensor` `zone_N_target_count` (use `"entity": "occupancy"`,
  `"pir": "motion"` or delete `"pir"`).

## The two files

| File | Where it goes | What it is |
|---|---|---|
| `dls-presence.rooms.laundry.draft.json` | `rooms.json` for `tools/dls-presence` on liesa | The whole file, with one `Laundry` room. Holds `host`, `key`, `entity` (`"occupancy"` pre-filled) and `pir`, because this is the only place those live. |
| `ea1.rooms-json.laundry.draft.json` | **Rooms JSON** property of the Daylight Lighting Scheduler on the EA-1 | The `Laundry` room object only. Only `presence.sources` changes (`robot` becomes `esp`, `robot`); everything else is the current repo copy. Host, key, entity and pir must **not** appear here. |

Both are needed. The scheduler only acts on a source that is listed in the room's
`presence.sources`, and `tools/dls-presence` only connects to a sensor that is listed in the
room's `esp` list with a host and an entity.

## 1. Fill the dls-presence draft

`"entity": "occupancy"` is already pre-filled because both Everything Presence One and Everything
Presence Pro share that `binary_sensor` `object_id`. Edit `dls-presence.rooms.laundry.draft.json`
and replace the 3 remaining markers (`host`, `key`, `pir`):

- `host`: the sensor's ESPHome hostname or IP once it is on the network.
- `key`: ESPHome Noise API encryption key (44-char base64, 32 bytes). Port `6053` is unencrypted
  out of the box unless the sensor is adopted in the ESPHome dashboard (`esphome.onyxlens.com`):
  set `"key": ""` (or omit `"key"`) when unadopted, or paste the 44-char base64 Noise key when
  adopted (`tools/dls-presence/dls_presence.py` passes `noise_psk=dev["key"] or None`). Do not
  put real keys in this repo.
- `entity`: pre-filled as `"occupancy"` (shared by both EP One and EP Pro).
- `pir`: `"pir"` for Everything Presence One, `"motion"` for Everything Presence Pro, or **delete the
  whole `pir` line** if you do not want a separate PIR/motion sensor trigger. Leaving the marker in
  fails the check.

Note on ESPHome 2026.7+: newer ESPHome omits `object_id` on the wire and derives it from the entity
name. Live `dls-presence` runs `aioesphomeapi 46.30.1`, whose `APIClient.list_entities_services()`
already calls `device_info_and_list_entities()` and `_fill_object_ids_if_needed(...)`, so `object_id`
derivation is handled automatically without changing `dls_presence.py`.

Still run `--esp-check` on liesa once the sensor is online (with `host` and `key` filled in) to
verify connectivity and live `binary_sensor` states:

```
python3 tools/dls-presence/dls_presence.py --esp-check
```

It connects to every configured device and prints the `binary_sensor` object_ids and their
states. A device with no `host` or `entity` is skipped by the loader, so it will not appear.

## 2. Apply it on liesa

The draft holds only the `Laundry` room. Do not copy it over the live `rooms.json` if that file
has other rooms: merge the `Laundry` object into the live file instead. Then restart the
`dls-presence` service and watch its log for the first `OCC Laundry ...` line when someone walks
in. If the room is missing from the log, the loader skipped it: check the `host`/`entity` pair
and the room key (1-32 characters of `A-Z a-z 0-9 _ -`).

## 3. Apply it on the EA-1

1. Composer Pro, Daylight Lighting Scheduler, Properties, **Rooms JSON**.
2. Replace the existing `Laundry` object with `ea1.rooms-json.laundry.draft.json`
   (`presence.sources` becomes `["esp", "robot"]`; sensor details stay out of this property).
3. Save, then set **Presence Lighting** to On when you are ready to test. With it Off the driver
   ignores occupancy.
4. Bring `tools/rooms-json-editor/rooms.json` back in line with the EA-1 copy, because the repo
   copy, the editor and the artifact page are kept identical. The editor does not offer the
   `occ`/`lux` fields yet, but `presence.sources` can be edited there.

Check the result in the driver's **Status** property and Debug output: an occupied Laundry should
show `OCC Laundry 1 esp`, and the vacancy delay should fade the dimmer only after the room has
read empty for 180 s.

## The other two sensors

Same pattern, one room at a time:

- **Great room**: two Everything Presence Pro sensors, so the room's `esp` list gets **two**
  entries, one per sensor (`"entity": "occupancy"`, `"pir": "motion"` or omit `"pir"`; verified Pro
  `binary_sensor` `object_id`s are `occupancy`, `mmwave_presence`, `motion`, `zone_N_presence`,
  plus `sensor` `zone_N_target_count`). Add both entries to the `dls-presence` file; the EA-1 room
  just lists `"esp"` once in `presence.sources`.
- **Master bedroom**: one Everything Presence One sensor, same shape as Laundry
  (`"entity": "occupancy"`, `"pir": "pir"`; verified One `binary_sensor` `object_id`s are
  `occupancy`, `mmwave`, `pir`).
- For each sensor, set `"key": ""` (or omit `"key"`) if unadopted on port `6053`, or set the
  44-char base64 Noise key if adopted in `esphome.onyxlens.com`.
- Only the room **key** has to exist on both sides; the sensor entries are dls-presence only.
- Delete `pir` for any sensor if you do not want a separate PIR/motion trigger.
- Keep the sensor entries out of the EA-1 Rooms JSON. It is a room-level allow-list, nothing more.

## Checking the drafts

```
python tools/c4sim/run.py test sensor_prep_placeholders
```

As committed this prints a `skip ... 3 placeholder(s)` line (`host`, `key`, `pir`) and passes all
3 test cases, so `python tools/c4sim/run.py test all` stays green for everyone. To make the
unfilled placeholders an error, run it in strict mode (this is what to use on Saturday before
applying anything):

```
# PowerShell
$env:SENSOR_PREP_STRICT = "1"; python tools/c4sim/run.py test sensor_prep_placeholders
# bash
SENSOR_PREP_STRICT=1 python tools/c4sim/run.py test sensor_prep_placeholders
```

Strict mode lists every remaining marker with its JSON path (3 markers in
`dls-presence.rooms.laundry.draft.json`: `rooms.Laundry.esp[1].host`, `rooms.Laundry.esp[1].key`,
`rooms.Laundry.esp[1].pir`). Case 2 fills a copy of both drafts in memory with an adopted EP One
shape (`entity: "occupancy"`, 44-char base64 `key`, `pir: "pir"`) and checks the structure (the
room key, `sources`, `robot` room name, and light 568 plus `"esp"` in the EA-1 object); case 3
checks an unadopted EP Pro shape (`entity: "occupancy"`, empty `key: ""`, `pir: "motion"`).

## Do not commit

Filled drafts contain the API key, hostnames and IP addresses. This repo is public. Apply the
filled values on liesa and the EA-1, then leave the committed drafts with their placeholders (or
delete the filled copies).
