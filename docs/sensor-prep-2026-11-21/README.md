# Sensor prep for Saturday 2026-11-21

Drafts for the first Everything Presence sensor. Three sensors arrive (two Pro, one One); the
first one goes in **Laundry** (Lutron dimmer id 568). Nothing here is live yet, and both drafts
still contain `<<FILL: ...>>` placeholders, so the checker test fails until they are filled.

## The two files

| File | Where it goes | What it is |
|---|---|---|
| `dls-presence.rooms.laundry.draft.json` | `rooms.json` for `tools/dls-presence` on liesa | The whole file, with one `Laundry` room. Holds `host`, `key`, `entity` and `pir`, because this is the only place those live. |
| `ea1.rooms-json.laundry.draft.json` | **Rooms JSON** property of the Daylight Lighting Scheduler on the EA-1 | The `Laundry` room object only. Only `presence.sources` changes (`robot` becomes `esp`, `robot`); everything else is the current repo copy. Host, key, entity and pir must **not** appear here. |

Both are needed. The scheduler only acts on a source that is listed in the room's
`presence.sources`, and `tools/dls-presence` only connects to a sensor that is listed in the
room's `esp` list with a host and an entity.

## 1. Fill the dls-presence draft

Edit `dls-presence.rooms.laundry.draft.json` and replace every marker:

- `host`: the sensor's ESPHome hostname or IP once it is on the network.
- `key`: the ESPHome **API encryption key** (32 bytes, base64, 44 characters). Copy it from the
  sensor's ESPHome config; do not put it in this repo.
- `entity`: the `binary_sensor` object_id that reports occupancy. Confirm it with
  `--esp-check` (below) after the host and key are in; it is a guess until then.
- `pir`: the `binary_sensor` object_id of the PIR/motion sensor. **Delete the whole `pir` line**
  if the sensor has no separate PIR object. Leaving the marker in fails the check.

Find the real object_ids on liesa, with the host and key already filled in:

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

- **Great room**: two Pro sensors, so the room's `esp` list gets **two** entries, one per sensor.
  Add both entries to the `dls-presence` file; the EA-1 room just lists `"esp"` once in
  `presence.sources`.
- **Master bedroom**: one One sensor, same shape as Laundry.
- Only the room **key** has to exist on both sides; the sensor entries are dls-presence only.
- Delete `pir` for any sensor that has no separate PIR object.
- Keep the sensor entries out of the EA-1 Rooms JSON. It is a room-level allow-list, nothing more.

## Checking the drafts

```
python tools/c4sim/run.py test sensor_prep_placeholders
```

As committed this prints a `skip ... placeholders` line and passes, so `python tools/c4sim/run.py
test all` stays green for everyone. To make the unfilled placeholders an error, run it in strict
mode (this is what to use on Saturday before applying anything):

```
# PowerShell
$env:SENSOR_PREP_STRICT = "1"; python tools/c4sim/run.py test sensor_prep_placeholders
# bash
SENSOR_PREP_STRICT=1 python tools/c4sim/run.py test sensor_prep_placeholders
```

Strict mode lists every remaining marker with its JSON path. The second, always-on case fills a
copy of both drafts in memory with fake values and checks the structure: the room key, the
`sources` lists, a non-empty `host`/`key`/`entity`, the `robot` room name, and light 568 plus
`"esp"` in the EA-1 object.

## Do not commit

Filled drafts contain the API key, hostnames and IP addresses. This repo is public. Apply the
filled values on liesa and the EA-1, then leave the committed drafts with their placeholders (or
delete the filled copies).
