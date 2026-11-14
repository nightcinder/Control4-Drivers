# Follow-me lighting in DLS: interface spec (FINAL)

Status: FINAL design, agreed with the owner 2026-11-14. Supersedes the earlier draft that split
on/off decisions into Room Light Helper (RLH). No code is changed by this document.
Covers: `drivers/daylight-lighting-scheduler` (DLS, v1.10.1), `tools/dls-presence/dls_presence.py`
(poller, v1.3.0, runs on liesa), `tools/c4sim`. RLH (`drivers/room-light-helper`) stays as it is.
UNTESTED: nothing here is proven on hardware. Section 2 must pass before any driver code is written.

## 1. Design in one paragraph

Follow-me lighting is ONE driver: DLS. Presence decides WHETHER a room's lights are on. Time of
day and lux decide HOW they look. The robot is just another occupant. The poller combines all
sources per room and sends `OCC <roomKey> 1|0 <src> <token>` lines over the existing TCP port.
DLS turns a room on at its own computed level and fades it off after the room empties. DLS never
reads sensors for follow rooms, and the poller never chooses a level.

| Concern | Owner |
|---|---|
| Raw sources (ESPHome, robot, UniFi, Life360), combining, stuck-on, dock rule | Poller |
| HOME / AWAY decision | Poller decides, DLS stores and applies it |
| Per-room state machine, off delay, fades, holds, AWAY filter, silence timeout | DLS |
| Level, CCT, night level, cloud gain, optional `lux` closed loop | DLS (unchanged maths) |

## 2. FIRST: verification step V1 (blocks all other work)

Question: when DLS ramps ONE dimmer by device id, what level feedback comes back on variable
1001 (`LIGHT_LEVEL`)? The override exemption in section 7 depends on the answer.

Procedure (Composer Lua tab of DLS, one Lutron dimmer and one LIFX light, ids from Rooms JSON):

```lua
C4:RegisterVariableListener(ID, 1001)
local t0 = os.time()
OnWatchedVariableChanged = function(d, v, s) print(os.time() - t0, d, v, s) end   -- temporary
C4:SendToDevice(ID, "RAMP_TO_LEVEL", { LEVEL = 40, TIME = 5000 })    -- run A
C4:SendToDevice(ID, "RAMP_TO_LEVEL", { LEVEL = 0,  TIME = 30000 })   -- run B
```

Record for each run and each light kind:
1. Number of feedback values: one (final only), one (target at ramp start), or many (intermediate).
2. Final value: exactly the target, or off by up to N points.
3. Delay from command to first and to last feedback value.
4. Run B again, press the keypad at about 10 s. What value arrives, and when?
5. Run B, then send `RAMP_TO_LEVEL 40` at 10 s. Does the light climb from its current level?

Decision table (defaults assume the first row):

| Result | Consequence |
|---|---|
| Final or start value only, within 2 points | Use section 7 as written (`BAND = 8`, `PAD = 10 s`). |
| Many intermediate values | Section 7 rule 2 (range test) is required, not optional. |
| Final value off by more than 8 | Raise `BAND` to the measured error + 3. |
| No feedback at all for a light kind | That kind cannot have manual detection. No holds for it. |

Restore the driver (reload) after the test. Write the results into `PRESENCE_NOTES.md`.

## 3. OCC wire protocol

Transport: TCP to the DLS `Presence Port` (default 8730), same as today. One connection per
batch. The poller writes all lines in ONE `sendall`, then reads replies until DLS closes the
socket. DLS answers one reply line per input line, in order, then closes (current behaviour).
DLS must process only complete lines; a batch is under 1 KB.

Grammar (ASCII, fields split by one or more spaces, lines end `\r\n`, max 120 chars):

```
line     = presence | occ | hello
presence = "PRESENCE" SP ("HOME" | "AWAY") SP token              ; unchanged
occ      = "OCC" SP roomKey SP ("1" | "0") SP src SP token
hello    = "HELLO" SP bootId SP count SP token                   ; first line of a snapshot
roomKey  = 1*32( ALPHA | DIGIT | "_" | "-" )                     ; compared case-insensitive
src      = name *( "," name )                                    ; no spaces
bootId   = 1*16 DIGIT                                            ; poller start time, epoch s
count    = 1*3 DIGIT                                             ; number of OCC lines that follow
token    = 1*64 VCHAR                                            ; must equal Presence Token
```

`src` names:
- State `1`: the active sources, highest priority first. Names: `esp`, `robot`. Example `esp,robot`.
- State `0`: one reason: `clear` (all sources 0), `dock` (robot docked), `stuck` (section 9.1),
  `unknown` (no source reachable for 3 min).

Token: always the LAST field. For `OCC` and `HELLO` an empty `Presence Token` property rejects
every line (`ERR AUTH`). `PRESENCE` keeps today's rule (empty property accepts any). The token is
clear text on the LAN; it stops accidents, not attackers. Never log it.

Replies:

| Reply | Meaning | Poller action |
|---|---|---|
| `OK` | Line accepted (also for a repeat with no change) | none |
| `OK RESYNC` | Accepted, but DLS has no snapshot since it started | send a snapshot now |
| `ERR AUTH` | Token wrong or empty | log once, keep retrying every 60 s, alert after 30 min |
| `ERR ROOM` | `roomKey` not in Rooms JSON, or room has no `presence` | log once per key, keep going |
| `ERR SYNTAX` | Anything else. Old drivers reply plain `ERR` | log; plain `ERR` to `OCC` = driver too old |

Snapshot = `PRESENCE` line, `HELLO`, then one `OCC` line for EVERY configured room, in one batch:

```
PRESENCE HOME s3cret
HELLO 1794670000 3 s3cret
OCC Kitchen 1 esp s3cret
OCC Laundry 0 clear s3cret
OCC Office 1 esp,robot s3cret
```

Timing rules:
- Change: send the single changed `OCC` line at once (target under 1 s from the sensor event).
- Heartbeat: a full snapshot every 60 s (`OCC_REPEAT_SEC`), changed or not.
- Reconnect: after ANY failed or short send (exception, fewer replies than lines), poller start,
  or `OK RESYNC`, the next send is a full snapshot. Retry after 5 s, then 10, 20, max 60 s.
- Silence: DLS records the time of the last accepted `HELLO` or `OCC`. After 180 s without one
  (`Occupancy Silence (sec)`, default 180), every follow room is treated as `OCC <room> 0 unknown`.
  Lights then go off by the normal off delay and fade, not instantly. Status shows `Presence feed lost`.
  A HOLD with all lights off is kept when the vacancy reason is silence, `unknown` or `stuck`; only a confirmed `0 clear` or `0 dock` plus the off delay, a manual on, or AWAY ends it.
- A `HELLO` with `count` N: rooms not named in the next N lines are set vacant.
- Order inside a batch is the order of effect. `PRESENCE` comes first so the AWAY filter is current.

## 4. Rooms JSON additions

IMPORTANT: the top-level key `follow` already exists in DLS (schedule "follow mode": only touch
lights that are already on). It keeps that meaning. All new settings live in a new `presence`
object. A room without `presence` behaves exactly as in v1.10.1.

```json
{ "name": "Kitchen", "key": "Kitchen",
  "presence": { "follow": true, "offDelaySec": 180, "robotOffDelaySec": 90,
                "fadeInSec": 2, "fadeOutSec": 30, "nightLevel": 20,
                "sources": ["esp", "robot"] },
  "lights": [ { "id": 123, "kind": "lutron" } ] }
```

| Key | Type | Default | Valid | Meaning |
|---|---|---|---|---|
| `key` (room level) | string | `name` with every char outside `[A-Za-z0-9_-]` removed | 1-32 chars, unique ignoring case | `roomKey` on the wire. |
| `presence.follow` | bool | `false` | true / false | `true`: occupancy turns lights on and off. `false`: occupancy never turns lights ON (bedrooms); vacancy still turns them off. |
| `presence.offDelaySec` | int | 180 | 10-3600 | Wait after the room empties before the fade starts. |
| `presence.robotOffDelaySec` | int | 90 | 10-3600 | Off delay when the last active source was `robot` only. |
| `presence.fadeInSec` | number | 2 | 0-60 | Ramp time for turn-on and re-entry. |
| `presence.fadeOutSec` | number | 30 | 0-300 | Ramp to 0 after the off delay. 0 = instant. |
| `presence.nightLevel` | int | Property `Night Level (%)` (20) | 0-100 | Level when occupied inside the room's off window. 0 = stay off at night. |
| `presence.sources` | string list | `["esp","robot"]` | subset of `esp`, `robot`, no repeats | Allow-list and priority. A source not listed is ignored for this room. |

Validation (in `loadRooms`): a wrong type or out-of-range number uses the default and adds
`Rooms JSON warning: <room>.<key>` to Status; the room still loads. Duplicate `key`, or a `key`
with illegal characters, disables `presence` for the later room and warns. A room with both
`presence` and the legacy `occ` object uses `presence`; `occ` is ignored with a warning.
`presence` requires at least one light. Unknown keys inside `presence` are ignored.
Robot entries (section 9.2) must equal the roborock-bridge `rooms[].name` (any letter case), e.g. `"Living room"`.

## 5. Room state machine (DLS, one per room with `presence`)

`occIn` = last accepted OCC state after the allow-list (`sources`) and the AWAY filter (section 8).

| State | Meaning | Lights |
|---|---|---|
| `VACANT` | Nobody there | Off. DLS sends nothing (schedule, wake and away lamps still apply as today). |
| `OCCUPIED` | `occIn = 1`, or the off delay is still running | On at the DLS target (section 6). |
| `FADING` | Off delay expired, ramp to 0 running | Ramping to 0 over `fadeOutSec`. |
| `HOLD` | Occupied, and the user turned the lights off by hand | Off. DLS will not turn them on. |

| # | From | Event | To | Action |
|---|---|---|---|---|
| T1 | VACANT | `occIn` 0 to 1, `follow=true` | OCCUPIED | Ramp each light without a hold to target over `fadeInSec`. Target 0: send nothing. |
| T2 | VACANT | `occIn` 0 to 1, `follow=false` | OCCUPIED | Send nothing. |
| T3 | OCCUPIED | `occIn` 1 to 0 | OCCUPIED | Start off timer: `robotOffDelaySec` if last `src` was exactly `robot`, else `offDelaySec`. |
| T4 | OCCUPIED | `occIn` 0 to 1, timer running | OCCUPIED | Cancel the timer. No ramp. |
| T5 | OCCUPIED | Off timer expires | FADING | Clear all holds in the room. Ramp every light with level > 0 to 0 over `fadeOutSec`. Start fade timer `fadeOutSec + 2 s`. |
| T6 | FADING | `occIn` 0 to 1 | OCCUPIED | As T1 (for `follow=false`: ramp back to each light's level before the fade). |
| T7 | FADING | Fade timer expires | VACANT | None. |
| T8 | OCCUPIED | Manual off (section 7) of the last light that was on | HOLD | Mark `offHold` on that light. |
| T9 | OCCUPIED | Manual off of one light, others still on | OCCUPIED | Mark `offHold` on that light only. |
| T10 | HOLD | `occIn` 1 to 0, then off timer expires | VACANT | Clear `offHold` and holds. Fade any light still on (T5 ramp). |
| T11 | HOLD | Manual on of any light | OCCUPIED | Clear that light's `offHold`; it gets the normal per-light hold (`Override Hold (min)`). |
| T12 | FADING | Manual change of any light | OCCUPIED | Per-light hold on that light. Other lights keep fading. Off timer restarts at `offDelaySec`. |
| T13 | any | `PRESENCE AWAY` | per section 8 | People sources drop out; rooms left without `robot` run T5 at once. |
| T14 | any | DLS start or Rooms JSON change | VACANT | No ramps for 180 s or until the first snapshot. Then rooms with `occIn = 0` and a light on run T5. |

Notes:
- In OCCUPIED, `Update()` keeps the lights on the moving DLS target as today (holds excepted).
- T10 means a manual-off hold has NO time limit. It ends only when the room is confirmed vacant
  (off delay passed) or the user turns a light on. Reason: "off for a film" must stay off.
  A HOLD with all lights off is kept when the vacancy reason is silence, `unknown` or `stuck`; only a confirmed `0 clear` or `0 dock` plus the off delay, a manual on, or AWAY ends it.
- A manual level change (not to 0) in OCCUPIED is the existing per-light hold: DLS stops
  adjusting that light for `Override Hold (min)`. It does NOT block T5 (vacancy always wins).
- A manual ON in VACANT is the existing per-light hold. When it expires and `occIn` is still 0,
  the room runs T5. (A room whose sensor misses people needs a sensor fix, not a longer hold.)
- Persist `state`, `offHold` and hold expiries per room in `PersistData` so T14 can restore HOLD.

## 6. Level, time of day, night

- Target level and CCT come from the existing DLS calculation, including `min_level`,
  `max_level`, cloud gain, per-light `scale`, and the optional per-room `lux` closed loop.
- Inside the room's off window (after `off`, before the next `on`), an OCCUPIED follow room uses
  `presence.nightLevel` instead of 0. `nightLevel = 0` keeps the room dark at night.
- Outside the off window, a computed target of 0 (enough daylight) keeps the lights off while
  OCCUPIED. When the target later rises above 0 the next `Update()` turns them on over `fadeInSec`.
- Off-enforcement (`offEnforce`) is skipped for a room in OCCUPIED, FADING or HOLD.
- Wake windows and scenes are unchanged. A scene hold (`room.overrideUntil`) blocks T1 ramps but
  not T5.

## 7. Own ramps versus manual changes

Today `sendLevel` sets `light.lastLevel` and `light.ignoreUntil = now + ramp + 10 s`; any
feedback more than 8 points from `lastLevel` after that is a manual change. Kept, with additions:

1. `sendLevel` also stores `light.rampFrom` (level before the command) and `light.rampTo`.
   `ignoreUntil = now + ceil(ms / 1000) + PAD` (`PAD = 10 s`).
2. Inside the ignore window: feedback `v` is OWN if
   `min(rampFrom, rampTo) - BAND <= v <= max(rampFrom, rampTo) + BAND` (`BAND = 8`). Otherwise it
   is MANUAL, even inside the window. (Today all feedback in the window is ignored, so a keypad
   press during a 30 s fade is lost.)
3. After the window: MANUAL if `abs(v - lastLevel) > BAND` (unchanged).
4. Manual off = MANUAL with `v == 0` and `lastLevel > 0` while the room is OCCUPIED: T8 / T9.
5. Known gap: a press inside the window that lands inside the ramp range (for example raise to
   20 during a 60 to 0 fade) is not seen. V1 item 4 measures this. If V1 shows only final values,
   then ANY feedback before `ignoreUntil - PAD` that is not within `BAND` of `rampTo` is MANUAL.
6. Every own ramp goes through `sendLevel`. No other code path may send `RAMP_TO_LEVEL`.

## 8. HOME / AWAY

- `PRESENCE HOME|AWAY` keeps its meaning, persistence and the existing away behaviour.
- AWAY filter: while AWAY, DLS drops every source except `robot` from `src` before computing
  `occIn`. `OCC Kitchen 1 esp` counts as 0. `OCC Kitchen 1 esp,robot` counts as 1 with `src = robot`.
  Reason: with nobody home, a people sensor reading 1 is a pet, a fan or a stuck sensor.
- The robot lights its room while AWAY, at the normal target, with `robotOffDelaySec`.
- On AWAY: rooms left with `occIn = 0` go straight to FADING (T13). `offHold` and holds clear
  (as holds do today).
- On HOME: DLS re-evaluates the last received `src` per room at once; it does not wait for the
  next heartbeat. Rooms with people sources become OCCUPIED (T1).
- Away lamps and the "someone's-home" behaviour run only in rooms that are VACANT.
- Guests while the phones are away: set HOME by hand (`SetPresence`). No automatic rule.

## 9. Poller rules (dls_presence.py)

Per room, each poll or event:
1. Read every source: `True`, `False`, or `None` (unknown). `None` is ignored, as today.
2. Robot: if the robot is docked (or charging, or state unknown for 3 min), the robot source is
   `False` for EVERY room, whatever room it last reported. Reason `dock` if nothing else is active.
3. Room is `1` if any known source is `True`. All sources `None` for 180 s: send `0 unknown`.
4. `src` = active source names in the room's priority order.
5. No extra debounce in the poller: the sensor and DLS `offDelaySec` already do it.

### 9.1 Decision 1: stuck-on sensor timeout

Default: an `esp` source that reads `1` continuously for `STUCK_ON_MIN = 240` minutes, with no
other evidence of activity in that room, is treated as `None` (unknown) until it reads `0` once.
"Other evidence" resets the timer: a 0-to-1 edge on the device's PIR entity (`pir` key), or any
edge on another source for the same room. Room override: `stuckOnMin` (0 = never time out).
When it trips: log, send one alert through `notify()`, and send `OCC <room> 0 stuck` if nothing
else is active. Reasons:
- It lives in the poller because only the poller sees single sources; DLS sees the OR.
- 240 min, not RLH's 120: mmWave correctly holds 1 for a person sitting still, and a film or a
  working session runs past 2 hours. Four hours with zero PIR motion is almost never a person.
- The cost of a wrong trip is low: lights fade over 30 s and any movement (PIR edge) restores them.
- The cost of no timeout is a room lit for days. AWAY already masks it while nobody is home.
- A robot source cannot stick: the dock rule clears it.

### 9.2 Decision 2: ESPHome ingestion = native API subscription

Chosen: the poller subscribes to each device with `aioesphomeapi` (ESPHome native API, port 6053).
- Push, not poll: state changes arrive in well under 1 s. REST would need the `web_server`
  component on every device plus polling (latency = poll interval, or SSE handling by hand).
- No broker and no Home Assistant needed. MQTT needs a broker on liesa and the `mqtt` component
  flashed onto every sensor; two more things that can fail.
- Everything Presence firmware ships with the native API on; nothing to reflash. The API allows
  several clients, so Home Assistant can stay connected too.
- A dropped connection is seen at once and maps to `None` (unknown), which REST polling cannot
  tell from "no change".
- The poller venv already carries `aiohttp` / asyncio for Life360; this is one more package.
Cost: one asyncio thread with a reconnect loop per device (`ReconnectLogic`), and a pinned
`aioesphomeapi` version, because the library changes often.

Config (`/etc/dls-presence.env` plus one JSON file, mode 0600):

| Key | Default | Meaning |
|---|---|---|
| `ROOMS_FILE` | `/etc/dls-presence.rooms.json` | Room to source map. Unset or missing = no OCC lines (v1.3.0 behaviour). |
| `OCC_REPEAT_SEC` | 60 | Snapshot heartbeat. |
| `STUCK_ON_MIN` | 240 | Section 9.1. |
| `SRC_UNKNOWN_SEC` | 180 | All sources unknown this long = `0 unknown`. |
| `ESPHOME_PORT` | 6053 | Default API port. |
| `ROBOT_URL` | empty | Status URL of `tools/roborock-bridge` (state + current room). May be the bridge base URL (`http://liesa:8788`) or the full `/state` URL. Empty = no robot source. Stale bridge data (`last_success_age_s` of 180 s or more, or `state` null) counts as no status. The exact fields are NOT checked in this spec: confirm against the bridge in package A. |
| `ROBOT_POLL_SEC` | 15 | Robot poll interval. |

```json
{ "rooms": {
    "Kitchen": { "sources": ["esp", "robot"], "stuckOnMin": 240,
      "esp": [ { "host": "ep-kitchen.lan", "key": "<api encryption key>",
                 "entity": "occupancy", "pir": "pir" } ],
      "robot": ["Kitchen"] },
    "Laundry": { "esp": [ { "host": "ep-laundry.lan", "key": "<key>", "entity": "occupancy" } ] } } }
```

`entity` and `pir` are binary_sensor object ids. Several `esp` entries in one room are ORed.
`robot` lists the robot's room / segment names that map to this room. Room keys must equal the
DLS `key`. `/health` gains one entry per ESPHome device and one for the robot (stale = disconnected
or unknown for 3x its interval).

### 9.3 Decision 3: no lux fallback

Follow-me in DLS has NO lux fallback of the RLH kind (lux-to-level scaling when no target
exists). Reasons: DLS always has a target (sun position needs no sensor), so there is nothing to
fall back from; two level sources are what this redesign removes; and a lux sensor in a lit room
reads its own light. What stays: the optional per-room `lux` closed loop already in DLS
(`"lux":{"dev":..,"var":..,"target":..}`) keeps trimming the level, because it is part of "how the
lights look". RLH keeps its own lux scaling unchanged until it is retired.

## 10. Failure modes

| Failure | Behaviour |
|---|---|
| Poller down, liesa down, network cut | 180 s silence: all rooms `0 unknown`, off delay, fade. Wall control still works. |
| DLS reload / controller reboot | T14. First line gets `OK RESYNC`; snapshot arrives within seconds. |
| One ESPHome device offline | Source `None`; other sources still count. Alone for 180 s: `0 unknown`. |
| Sensor stuck at 1 | Section 9.1. |
| Robot stopped, paused or in error | Not a moving robot, so not an occupant (a stranded robot must not keep a room lit). Only states containing `clean`, `return`, `going`, `mopping` or `segment` count as occupant. `Charger-disconnected`, `dock`, `charging`, `emptying`, `washing` and `drying` count as docked. Robot state unknown for 3 min = docked. |
| Wrong token | `ERR AUTH`, feed lost after 180 s, alert after 30 min. |
| Room key mismatch | `ERR ROOM` logged by the poller; that room never becomes occupied. |
| Old driver, new poller | Plain `ERR` to `OCC`. Poller logs once; `PRESENCE` keeps working. |

## 11. Room Light Helper: migration and compatibility

- RLH is NOT changed and NOT removed now. The earlier plan (`SET_TARGET_LEVEL`, `SET_HOLD`,
  `ROOM_OCCUPIED`, `HELPER_TARGET`) is dropped. DLS and RLH do not talk to each other.
- One owner per room. A room with a `presence` object in DLS must not be driven by an RLH
  instance: remove that RLH's programming (`REQUEST_ON` / `RELEASE`) or unbind its light first.
  A room still on RLH must have no `presence` object.
- Known and accepted until migration: in an RLH room, an RLH ramp can look like a manual change
  to DLS and start a per-light hold (today's behaviour).
- Value mapping when a room moves: RLH `Off Delay (sec)` to `offDelaySec`; `Quick Off Delay` to
  `robotOffDelaySec`; `Fade In (sec)` (RLH default 5) to `fadeInSec`; `Fade Out (sec)` to
  `fadeOutSec`; lux scaling and `Fallback Level` have no equivalent (section 9.3).
- Order: Laundry first (one dimmer, one sensor), then Kitchen, then the rest, one room per step.
- Legacy DLS `Presence Lighting` (`occ`, `latchVacant`, `Vacancy Delay (min)`) stays, default
  Off, for rooms without `presence`. Remove it and RLH only after every room has run on
  `presence` for two weeks.

## 12. TEST CASES

Fixture unless stated: token `tok`; HOME; Rooms JSON has `Kitchen` (light 101, `follow=true`,
`offDelaySec=180`, `robotOffDelaySec=90`, `fadeInSec=2`, `fadeOutSec=30`, `nightLevel=20`) and
`MasterBed` (light 201, `follow=false`); DLS target for Kitchen is 60; time is in the on window;
a snapshot was already received. "ramp(id, L, ms)" = `SendToDevice(id, "RAMP_TO_LEVEL", {LEVEL=L, TIME=ms})`.

DLS (c4sim):
1. Send `OCC Kitchen 1 esp tok`. Expect reply `OK`, ramp(101, 60, 2000), state OCCUPIED.
2. After 1: send `OCC Kitchen 0 clear tok`, advance 179 s. Expect no ramp. Advance 2 s. Expect
   ramp(101, 0, 30000), state FADING. Advance 32 s. Expect state VACANT.
3. After 1: send `0 clear`, advance 100 s, send `1 esp`, advance 300 s. Expect no ramp to 0.
4. In FADING (case 2 at +185 s): send `OCC Kitchen 1 esp tok`. Expect ramp(101, 60, 2000), OCCUPIED.
5. Send `OCC Kitchen 1 robot tok`, then `OCC Kitchen 0 dock tok`. Expect ramp to 0 at 90 s, not 180 s.
6. Send `OCC MasterBed 1 esp tok`. Expect `OK`, no ramp, OCCUPIED. Feed light 201 level 50
   (manual on), then `OCC MasterBed 0 clear tok`, advance 181 s. Expect ramp(201, 0, 30000).
7. Send `OCC Kitchen 1 esp bad`. Expect `ERR AUTH`, no ramp. Same with `Presence Token` empty.
8. Send `OCC Garage 1 esp tok` (no such room). Expect `ERR ROOM`. Send `OCC Kitchen 2 esp tok`
   and `OCC Kitchen 1 tok`. Expect `ERR SYNTAX` for both.
9. Send `PRESENCE AWAY tok`. Expect `OK` and Presence = Away (regression for v1.10.1 behaviour).
10. Batch `PRESENCE HOME tok` / `HELLO 100 2 tok` / `OCC Kitchen 1 esp tok` / `OCC MasterBed 0 clear tok`
    in one write. Expect four `OK` replies in order and ramp(101, 60, 2000).
11. Reload the driver, send `OCC Kitchen 1 esp tok`. Expect `OK RESYNC`. Send a snapshot, then
    the same line again. Expect `OK`.
12. After 1: advance 181 s with no lines. Expect Status `Presence feed lost`; at 361 s
    ramp(101, 0, 30000). With a snapshot every 60 s for 10 min instead: expect no ramp to 0.
13. After 1 (wait 15 s): feed light 101 level 0. Expect state HOLD, no ramp. Send a snapshot with `OCC Kitchen 1 esp tok` every 60 s for 3 h. Expect state HOLD throughout and no ramp. Send `OCC Kitchen 0 clear tok`, advance 181 s. Expect state VACANT and no ramp (nothing was on). Send `OCC Kitchen 1 esp tok`. Expect ramp(101, 60, 2000), state OCCUPIED.
13b. As 13 up to HOLD, then send nothing for 400 s. Expect Status `Presence feed lost` and state HOLD. Send a snapshot with `OCC Kitchen 1 esp tok`. Expect no ramp, state HOLD. Then `0 clear`, advance 181 s: VACANT. (Silence, `unknown` and `stuck` are not a confirmed vacancy for T10.)
14. Fresh start. After 1 (wait 15 s): feed light 101 level 0 (state HOLD), then feed light 101 level 40. Expect state OCCUPIED, per-light hold on 101, no ramp. Send `OCC Kitchen 0 clear tok`, advance 181 s. Expect ramp(101, 0, 30000), state FADING; 32 s later VACANT.
15. After 1 (wait 15 s): feed light 101 level 90. Expect per-light hold, no ramp when the target
    changes. Send `0 clear`, advance 181 s. Expect ramp(101, 0, 30000) (vacancy beats the hold).
16. After 1: feed light 101 levels 20, 40, 60 within 2 s. Expect no hold (own ramp, section 7 rule 2).
17. In FADING at +10 s: feed light 101 level 100. Expect a per-light hold, state OCCUPIED, no
    further ramp for light 101.
18. `PRESENCE AWAY`, then `OCC Kitchen 1 esp tok`. Expect `OK`, no ramp, VACANT. Then
    `OCC Kitchen 1 esp,robot tok`. Expect ramp(101, 60, 2000). Then `OCC Kitchen 1 esp tok`,
    advance 91 s. Expect ramp(101, 0, 30000).
19. After 1: send `PRESENCE AWAY tok`. Expect ramp(101, 0, 30000) with no 180 s wait.
20. While AWAY with last line `OCC Kitchen 1 esp tok`: send `PRESENCE HOME tok`. Expect
    ramp(101, 60, 2000) with no new OCC line.
21. Clock in Kitchen's off window. Send `1 esp`. Expect ramp(101, 20, 2000). With `nightLevel=0`:
    expect no ramp, and off-enforcement sends nothing.
22. DLS target is 0 in daytime. Send `1 esp`. Expect no ramp, OCCUPIED. Raise target to 30, run
    `Update()`. Expect ramp(101, 30, 2000).
23. Rooms JSON with `offDelaySec: "x"`, `fadeOutSec: 999`, and two rooms with key `kitchen` /
    `Kitchen`. Expect defaults 180 and 30, a Status warning, and `presence` off for the second room.
24. Room with top-level `"follow": true` and no `presence`. Send `OCC <room> 1 esp tok`. Expect
    `ERR ROOM` and unchanged schedule-follow behaviour.

Poller (Python, pure functions with a fake clock and fake sources):
25. Kitchen sources esp=True, robot=None. Expect line `OCC Kitchen 1 esp tok`.
26. esp=True, robot in Kitchen and cleaning. Expect `src` `esp,robot`. With `sources` order
    `["robot","esp"]`: expect `robot,esp`.
27. Robot last room Kitchen, state docked, esp=False. Expect `OCC Kitchen 0 dock tok`.
28. esp=None for 179 s: expect no change of state sent. At 180 s: `OCC Kitchen 0 unknown tok`.
29. esp=True for 240 min with no PIR edge: expect `OCC Kitchen 0 stuck tok` and one `notify`.
    Then esp=False, esp=True: expect `OCC Kitchen 1 esp tok`. With a PIR edge at 200 min: no trip
    before 440 min. With `stuckOnMin=0`: never trips.
30. No change for 60 s. Expect one batch: `PRESENCE`, `HELLO <bootId> <n>`, n `OCC` lines.
31. Fake server closes after 2 of 5 replies. Expect the next send to be a full snapshot, after 5 s.
32. Fake server replies `OK RESYNC`. Expect a full snapshot sent at once.
33. Fake server replies plain `ERR` to `OCC`. Expect one log line, `PRESENCE` still sent, no crash.
34. `ROOMS_FILE` unset. Expect only `PRESENCE` lines, byte-identical to v1.3.0.
35. esp flips False to True. Expect the single `OCC` line sent in under 1 s (not at the next poll).

## 13. Implementation task split

Three independent work packages. Each is coded against sections 3 to 9 only. V1 (section 2) runs
first and may change `BAND` / `PAD` for package B.

| Pkg | Work | Files |
|---|---|---|
| A | Poller: room model, ESPHome native API source, robot source, dock and stuck rules, OCC lines, snapshot, resync, health. Tests 25-35. Bump to v1.4.0. | `tools/dls-presence/dls_presence.py`, new `tools/dls-presence/test_dls_presence.py`, new `tools/dls-presence/rooms.example.json`, `tools/dls-presence/dls-presence.service` (only if the env changes) |
| B | DLS: `presence` parsing and validation, line parser and replies, state machine, silence timer, AWAY filter, night level, ramp exemption, persistence. New property `Occupancy Silence (sec)`. Bump to v1.11.0. | `drivers/daylight-lighting-scheduler/Daylight_Lighting_Scheduler_driver.lua`, `Daylight_Lighting_Scheduler_driver.xml`, `PRESENCE_NOTES.md` |
| C | c4sim: server-data-in injection with reply capture, virtual clock for timers, light feedback injection, `SendToDevice` recorder. Tests 1-24, written from this spec, not from package B's code. | `tools/c4sim/c4sim.lua` (only if a hook is missing), new `tools/c4sim/tests/dls_presence_spec.lua` |

Not in any package: RLH, live hardware, liesa deployment. Those follow after A, B and C pass.
