# DLS / Room Light Helper: responsibility split and interface (draft spec)

Status: DRAFT. Design only, no driver code changed by this document.
Drivers covered: `drivers/daylight-lighting-scheduler` (DLS, v1.10.1) and
`drivers/room-light-helper` (RLH, v1.1.1).
UNTESTED: both drivers are UNTESTED on hardware in their recent versions. Every step
in section 8 must be tested in Composer and in a c4sim script before the next step starts.

## 1. Goal

Light levels come from one place (DLS) for the time of day, and on/off decisions for an
occupied room come from one place (RLH). Occupancy is never overridden by phone-based
HOME/AWAY. Neither driver has to guess what the other one is doing.

## 2. Responsibility split

| Concern | Owner | Notes |
|---|---|---|
| Schedule and time-of-day levels, wake / wind-down / night envelope | DLS | Computes the target level per room. |
| Night level | DLS | Each room has its own `Night Level (%)` (decision 3). |
| Cloud-cover gain, curtains | DLS | |
| Per-light manual-override holds (level change > 8 holds that light, default 120 min) | DLS | Holds are per light. A hold does not block vacancy-off (decision 1). |
| HOME / AWAY | DLS | Only affects UNOCCUPIED rooms (section 6). |
| Fixed "someone's-home" lamps | DLS | Run only in unoccupied rooms. |
| Occupancy sources (ESPHome presence, UniFi, Life360, Roborock) | Poller, then RLH | Poller combines sources into one `OCC` state per room (section 3a). |
| On / off decisions from occupancy | RLH | REQUEST_ON, RELEASE, Off Delay, Quick Off Delay. |
| Per-room "Auto-On From Occupancy" mode | RLH | Off for bedrooms (section 6). |
| Hold / enable mode, pre-off dim, manual-off lockout | RLH | |
| On-delay for noisy sensors | RLH | |
| Occupied / vacant variable and events | RLH | Published for DLS. |
| Persisted source state across reloads | RLH | See section 7. |
| Time of day, lux-to-brightness | DLS | RLH keeps lux only as a fallback (section 4). |
| Presence Lighting (vacancy latch, Vacancy Delay, occupancy watch) in DLS | Retired | Removed after RLH works (section 9). |

## 3. Interfaces: RLH to DLS

Published on the RLH device. DLS reads them through a variable listener on each room's
RLH device id, which goes in the Rooms JSON as `"helper":{"dev":<id>}`. Listener support
across two drivers in one project is unverified; test it in step 4.

| Name | Type | Meaning |
|---|---|---|
| `ROOM_OCCUPIED` (variable) | 0 / 1 | 1 while at least one active source is held. Set on every source change. |
| `ROOM_OCCUPIED_CHANGED` (event) | event | Fired on each 0 to 1 or 1 to 0 change. |
| `HELPER_TARGET` (variable) | 0-100 | Level RLH last ramped to. Used by DLS to recognise its own ramps (section 5). |
| `HELPER_RAMP_STAMP` (variable) | epoch seconds | When the last RLH ramp was sent. |

Example: Laundry sensor fires, RLH sets `ROOM_OCCUPIED = 1` and fires
`ROOM_OCCUPIED_CHANGED`. DLS listener sees 1 and clears the away gate for Laundry.

## 3a. Occupancy transport (decision 2)

The dls-presence poller (`tools/dls-presence`, runs on liesa) already pushes
`PRESENCE HOME|AWAY <token>` over TCP to the Control4 controller. It becomes the transport
for per-room occupancy too. Today it sends only HOME/AWAY.

Proposed line: `OCC <room> OCC|VAC <token>`

- `<room>` is the Rooms JSON key (for example `Kitchen`, `Laundry`, `MasterBed`). Use the
  same name in the poller config, the Rooms JSON and the sensor mapping.
- The poller ORs all sources for a room (ESPHome presence, UniFi, Life360) into one state.
  RLH therefore sees one source per room, named `poller`.
- DLS is the only TCP listener. It parses `OCC` and forwards `REQUEST_ON (poller)` or
  `RELEASE (poller)` with `SendToDevice` to that room's RLH. RLH never listens on a port.
- `PRESENCE HOME|AWAY` keeps its current meaning and handling in DLS.
- Open item: how ESPHome readings reach the poller (section 10, question 1).

## 4. Interfaces: DLS to RLH

Sent with `C4:SendToDevice` to the RLH device id. These are new RLH commands.

| Command | Params | Meaning |
|---|---|---|
| `SET_TARGET_LEVEL` | `Level` (0-100), `Cct` (optional, K) | DLS's computed target for this room now. RLH ramps to it when a source is active. |
| `SET_HOLD` | `Active` (0/1), `Until` (epoch seconds) | A DLS override hold covers this room. RLH does not ramp while a hold is active. |

Example: DLS recalculates at 18:05 and computes Kitchen = 62%. It sends
`SET_TARGET_LEVEL` with `Level=62`. Kitchen RLH stores 62 and ramps only if the light is
on and owned by RLH.

Rules for RLH:
- `SET_TARGET_LEVEL` replaces lux scaling. A target older than 30 min is treated as missing.
- With no fresh target, RLH uses its existing lux scaling. This keeps RLH usable when DLS
  is disabled.
- `SET_LUX` stays for compatibility but is ignored while a fresh target exists.
- DLS pushes a target on every recalculation, and on `SET_HOLD` changes.

Existing RLH commands kept unchanged: `REQUEST_ON (Source)`, `RELEASE (Source)`,
`RELEASE_ALL`, `SET_LUX (Lux)`.

## 5. Override interplay

DLS treats any level change larger than 8 points on the light's LIGHT_LEVEL variable (1001)
as a manual change. RLH ramps the same variable, so without a fix every RLH ramp would
start a DLS hold.

Fix (echo suppression): a level change is not a manual change when both hold:
1. The new level is within 3 points of `HELPER_TARGET` on the RLH device, and
2. `HELPER_RAMP_STAMP` is less than 120 s old.

Sequence A, manual change at the wall:
1. Light level goes 0 to 60 and no RLH ramp matches.
2. DLS sets `light.overrideUntil = now + Override Hold (min)`.
3. DLS sends `SET_HOLD(Active=1, Until=...)` to RLH.
4. RLH keeps its occupancy bookkeeping but does not ramp the light.
5. When the last source releases, RLH turns the light off and clears the hold. A manual
   hold does not block vacancy-off (decision 1).

Sequence B, RLH ramp:
1. Target changes from 40 to 62. RLH ramps and writes `HELPER_TARGET=62` and `HELPER_RAMP_STAMP`.
2. Variable goes to 62. DLS sees a match and does not start a hold.

Sequence C, hold expiry:
1. DLS clears `light.overrideUntil` and sends `SET_HOLD(Active=0)`.
2. The next DLS `Update` sends the target again. The light ramps back to the schedule.

## 6. AWAY versus occupancy, and per-room policy

Rule: room occupancy overrides HOME / AWAY. RLH ignores HOME / AWAY entirely. If a room
is occupied, DLS skips that room's AWAY behavior: no fixed away lamp and no 0-level
enforcement. The room uses the normal schedule level. Reason: a phone can report AWAY
while the owner's parents are home.

Per-room mode `Auto-On From Occupancy` (decision 3):
- On (default for every room except bedrooms): occupancy turns the light on at the target
  level and off after Off Delay.
- Off (bedrooms): occupancy never turns the light on by itself. The room still counts as
  occupied, so it skips AWAY behavior and its off timers and vacancy logic still run. The
  light turns on only by hand. Once a manually-on light is in an occupied room, RLH owns
  it and turns it off after vacancy (Off Delay).

Worked example, Away mode on:
- Kitchen has an away lamp (480 min, 30%, off 22:30).
- 19:00: parents walk into Kitchen. The sensor goes 1. The poller sends `OCC Kitchen OCC`,
  DLS forwards `REQUEST_ON (poller)`, and RLH sets `ROOM_OCCUPIED=1`. DLS skips the Kitchen
  away lamp. Kitchen follows the schedule level, currently 62%, via `SET_TARGET_LEVEL`.
- 21:40: they leave. The sensor goes 0. The poller sends `OCC Kitchen VAC`, RLH releases
  after Off Delay and turns the light off. `ROOM_OCCUPIED=0`. DLS applies the away lamp
  to Kitchen again.
- 23:00: Kitchen empty. Away lamp is off (window ended at 22:30). No 0-level enforcement
  is needed because the light is already off.

## 7. Failure modes

| Failure | Behaviour | Fix |
|---|---|---|
| RLH reload | Sources are forgotten and the light stays as it is. An owned light can stay on with no owner and no timer. | Persist sources and timestamps (PersistData). On startup, restore unexpired sources. If the light is on and no source is restored, start the Off Delay. |
| DLS reload | Holds (`overrideUntil`) are lost. Away state is already persisted. | Persist per-light holds with their expiry. Re-send `SET_HOLD` on startup. |
| Repeat `REQUEST_ON` | Source timestamp is not refreshed, so the source auto-releases at 120 min while the person is still there. | Refresh the timestamp on every request from a source. |
| Stuck-on sensor | A repeating "on" refreshes the timestamp forever, so the room never clears. | Sensor sources refresh only on a 0 to 1 transition. A stuck-on sensor then hits Source Timeout and logs it. |
| Sensor device offline | Reading is unknown, not vacant. | Keep the last state until Source Timeout. Log the offline reading. |
| Poller down or no `OCC` lines | Rooms look frozen. | Source Timeout clears sources. Poller heartbeat is logged by DLS. |
| DLS off-window versus RLH turning on at night | DLS enforces 0 in a vacant room during its off window. | Occupied rooms are exempt from off-enforcement and use their room's `Night Level (%)`, not 0. Auto-On Off rooms never turn on from occupancy. |
| DLS disabled or no target | RLH has no target. | Falls back to lux scaling (section 4). |

## 8. Rollout (small steps, each tested in Composer and c4sim)

1. RLH: refresh source timestamp on every request; sensor sources refresh only on 0 to 1
   transition. Test: c4sim sends repeated `REQUEST_ON` and checks the timeout.
2. RLH: PersistData for sources, plus startup reconciliation. Test: c4sim reload with a
   source active, then check the light and the Off Delay.
3. RLH: `SET_TARGET_LEVEL` with lux fallback and 30 min freshness. Test: c4sim sets a
   target and checks the ramp level.
4. RLH: publish `ROOM_OCCUPIED`, `ROOM_OCCUPIED_CHANGED`, `HELPER_TARGET`,
   `HELPER_RAMP_STAMP`. Test: c4sim reads the variables after each source change.
5. DLS: push `SET_TARGET_LEVEL` on each recalculation for rooms with a `helper` entry.
   Test: c4sim checks the level the helper receives.
6. DLS: echo suppression (section 5) and the AWAY occupancy gate (section 6). Test: c4sim
   runs the Kitchen example and checks no hold starts on a helper ramp.
7. DLS and RLH: `SET_HOLD` push. Test: c4sim sets a manual change and checks that RLH does
   not ramp until expiry.
8. Poller `OCC` line, DLS parser and forwarding, `Auto-On From Occupancy` per room. Test:
   c4sim sends `OCC` lines, and a bedroom with Auto-On off stays off on occupancy.
9. Retire DLS Presence Lighting (section 9), after steps 1 to 8 are proven.

## 9. Retiring DLS Presence Lighting

Remove after step 8 is proven in Composer:
- Properties `Presence Lighting`, `Vacancy Delay (min)`, `Vacancy Overrides Manual Hold`.
- Per-room `occ.vacancyDelaySec`, `occ.invert`, and `latchVacant` handling.
- Functions `presenceOn`, `parseOcc`, `startVacancyTimer`, `onOccupancy`, `resetOccupancy`.
- The vacancy block in `Update()`.
- `PRESENCE_NOTES.md` (replace with a pointer to this spec).
Keep `occupied(room)` only as a thin reader of the RLH `ROOM_OCCUPIED` variable. Keep the
raw sensor fields in Rooms JSON only if RLH cannot read them.

## 10. Open questions

1. ESPHome ingestion path: Home Assistant / MQTT, ESPHome native API, or HTTP into the
   poller. Also decide which sensor maps to which room name.
2. Stuck-on sensor: is 120 min (Source Timeout) right, or a shorter per-sensor timeout?
3. Keep lux scaling in RLH permanently as a fallback, or remove it after step 5?
