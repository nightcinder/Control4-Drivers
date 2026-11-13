# DLS / Room Light Helper: responsibility split and interface (draft spec)

Status: DRAFT. Design only, no driver code changed by this document.
Drivers covered: `drivers/daylight-lighting-scheduler` (DLS, v1.10.1) and
`drivers/room-light-helper` (RLH, v1.1.1).
Both drivers are UNTESTED on hardware in their recent versions. Every step below
must be tested in Composer and in a c4sim script before the next step starts.

## 1. Goal

Light levels come from one place (DLS) for the time of day, and on/off decisions
for an occupied room come from one place (RLH). Occupancy is never overridden by
phone-based HOME/AWAY. Neither driver has to guess what the other one is doing.

## 2. Responsibility split

| Concern | Owner | Notes |
|---|---|---|
| Schedule and time-of-day levels, wake / wind-down / night envelope | DLS | Computes the target level per room. |
| Cloud-cover gain, curtains | DLS | |
| Per-light manual-override holds (level change > 8 holds that light, default 120 min) | DLS | Holds are per light, not per room. |
| HOME / AWAY | DLS | Only affects UNOCCUPIED rooms (see section 6). |
| Fixed "someone's-home" lamps | DLS | Run only in unoccupied rooms. |
| Occupancy sources (sensors, Roborock, others) | RLH | One RLH instance per room. |
| On / off decisions from occupancy | RLH | REQUEST_ON, RELEASE, Off Delay, Quick Off Delay. |
| Hold / enable mode, pre-off dim, manual-off lockout | RLH | |
| On-delay for noisy sensors | RLH | |
| Occupied / vacant variable and events | RLH | Published for DLS. |
| Persisted source state across reloads | RLH | New; see section 7. |
| Night mode, time of day, lux-to-brightness | DLS | RLH stops owning these. Lux stays only as a fallback (section 4). |
| Presence Lighting (vacancy latch, Vacancy Delay, occupancy watch) in DLS | Retired | Stays off, removed after RLH works (section 9). |

## 3. Interfaces: RLH to DLS

Published on the RLH device. DLS reads them through a variable listener on each
room's RLH device id, which goes in the Rooms JSON as `"helper":{"dev":<id>}`.

| Name | Type | Meaning |
|---|---|---|
| `ROOM_OCCUPIED` (variable) | 0 / 1 | 1 while at least one active source is held. Set on every source change. |
| `ROOM_OCCUPIED_CHANGED` (event) | event | Fired on each 0 to 1 or 1 to 0 change. |
| `HELPER_TARGET` (variable) | 0-100 | Level RLH last ramped to. Used by DLS to recognise its own ramps (section 5). |
| `HELPER_RAMP_STAMP` (variable) | epoch seconds | When the last RLH ramp was sent. |

Example: Laundry sensor fires, RLH sets `ROOM_OCCUPIED = 1` and fires
`ROOM_OCCUPIED_CHANGED`. DLS listener sees 1 and clears the away gate for Laundry.

## 4. Interfaces: DLS to RLH

Sent with `C4:SendToDevice` to the RLH device id. These are new RLH commands.

| Command | Params | Meaning |
|---|---|---|
| `SET_TARGET_LEVEL` | `Level` (0-100), `Cct` (optional, K) | DLS's computed target for this room now. RLH ramps to it when a source is active. |
| `SET_HOLD` | `Active` (0/1), `Until` (epoch seconds) | A DLS override hold covers this room. RLH does not ramp while a hold is active. |

Example: DLS recalculates at 18:05 and computes Kitchen = 62%. It sends
`SET_TARGET_LEVEL` with `Level=62`. Kitchen RLH stores 62 and ramps only if the
light is on and owned by RLH.

Rules for RLH:
- `SET_TARGET_LEVEL` replaces lux scaling. A target older than 30 min is treated
  as missing.
- With no fresh target, RLH uses its existing lux scaling. This keeps RLH usable
  when DLS is disabled.
- `SET_LUX` stays as a command for compatibility but is ignored while a fresh
  target exists.
- DLS pushes a target on every recalculation, and on `SET_HOLD` changes.

Existing RLH commands kept unchanged: `REQUEST_ON (Source)`, `RELEASE (Source)`,
`RELEASE_ALL`, `SET_LUX (Lux)`.

## 5. Override interplay

DLS currently treats any level change larger than 8 points on the light's
LIGHT_LEVEL variable (1001) as a manual change. RLH ramps the same variable, so
without a fix every RLH ramp would start a DLS hold.

Fix (echo suppression): a level change is not a manual change when all of these hold:
1. The new level is within 3 points of `HELPER_TARGET` on the RLH device, and
2. `HELPER_RAMP_STAMP` is less than 120 s old.

Sequence A, manual change at the wall:
1. Light level goes 0 to 60 and no RLH ramp matches.
2. DLS sets `light.overrideUntil = now + Override Hold (min)`.
3. DLS sends `SET_HOLD(Active=1, Until=...)` to RLH.
4. RLH keeps its occupancy bookkeeping but does not ramp the light.
5. RLH still turns the light off when its last source releases (see open question 1).

Sequence B, RLH ramp:
1. Target changes from 40 to 62. RLH ramps and writes `HELPER_TARGET=62` and `HELPER_RAMP_STAMP`.
2. Variable goes to 62. DLS sees a match and does not start a hold.

Sequence C, hold expiry:
1. DLS clears `light.overrideUntil` and sends `SET_HOLD(Active=0)`.
2. The next DLS `Update` sends the target again. The light ramps back to the schedule.

## 6. AWAY versus occupancy: rule and worked example

Rule: room occupancy overrides HOME / AWAY. RLH ignores HOME / AWAY entirely.
If a room is occupied, DLS skips that room's AWAY behavior. That means no fixed
away lamp and no 0-level enforcement. The room uses the normal schedule level.

Reason: a phone can report AWAY while the owner's parents are home.

Worked example, Away mode on:
- Kitchen has an away lamp (480 min, 30%, off 22:30).
- 19:00: parents walk into Kitchen. The sensor goes 1. RLH sets `ROOM_OCCUPIED=1`.
  DLS sees the event and skips the Kitchen away lamp. Kitchen follows the schedule
  level, currently 62%, via `SET_TARGET_LEVEL`.
- 21:40: they leave. The sensor goes 0. RLH releases after Off Delay and turns the
  light off. `ROOM_OCCUPIED=0`. DLS applies the away lamp to Kitchen again.
- 23:00: Kitchen empty. Away lamp is off (window ended at 22:30). No 0-level
  enforcement is needed because the light is already off.

## 7. Failure modes

| Failure | Behaviour | Fix |
|---|---|---|
| RLH reload | Sources are forgotten and the light stays as it is. An owned light can stay on with no owner and no timer. | Persist sources and timestamps (PersistData). On startup, restore unexpired sources. If the light is on and no source is restored, start the Off Delay. |
| DLS reload | Holds (`overrideUntil`) are lost. Away state is persisted already. | Persist per-light holds with their expiry. Re-send `SET_HOLD` on startup. |
| Repeat `REQUEST_ON` | Source timestamp is not refreshed (only new sources are stamped), so the source auto-releases at 120 min while the person is still there. | Refresh the timestamp on every request from a source. |
| Stuck-on sensor | A repeating "on" refreshes the timestamp forever, so the room never clears. | Sensor sources refresh only on a 0 to 1 transition. A stuck-on sensor then hits Source Timeout and logs it. |
| Sensor device offline | Reading is unknown, not vacant. | Keep the last state until Source Timeout. Log the offline reading. |
| DLS off-window versus RLH turning on at night | DLS enforces 0 in a vacant room during its off window. An occupied room must not be forced to 0. | Occupied rooms are exempt from off-enforcement and use the night level (`Night Level (%)`), not 0. Vacant rooms keep today's enforcement. |
| DLS disabled or no target | RLH has no target. | Falls back to lux scaling (section 4). |

## 8. Rollout (small steps, each tested in Composer and c4sim)

1. RLH: refresh source timestamp on every request; sensor sources refresh only on
   0 to 1 transition. Test: c4sim sends repeated `REQUEST_ON` and checks the timeout.
2. RLH: PersistData for sources, plus startup reconciliation. Test: c4sim reload
   with a source active, then check the light and the Off Delay.
3. RLH: `SET_TARGET_LEVEL` with lux fallback and 30 min freshness. Test: c4sim
   sets a target and checks the ramp level.
4. RLH: publish `ROOM_OCCUPIED`, `ROOM_OCCUPIED_CHANGED`, `HELPER_TARGET`,
   `HELPER_RAMP_STAMP`. Test: c4sim reads the variables after each source change.
5. DLS: push `SET_TARGET_LEVEL` on each recalculation for rooms with a `helper`
   entry. Test: c4sim checks the level the helper receives. Lights still driven by
   DLS for rooms without a helper.
6. DLS: echo suppression (section 5) and the AWAY occupancy gate (section 6).
   Test: c4sim runs the Kitchen example and checks no hold starts on a helper ramp.
7. DLS and RLH: `SET_HOLD` push. Test: c4sim sets a manual change and checks that
   RLH does not ramp until expiry.
8. Retire DLS Presence Lighting (section 9), after steps 1 to 7 are proven.

## 9. Retiring DLS Presence Lighting

Remove after step 7 is proven in Composer:
- Properties `Presence Lighting`, `Vacancy Delay (min)`, `Vacancy Overrides Manual Hold`.
- Per-room `occ.vacancyDelaySec`, `occ.invert`, and `latchVacant` handling.
- Functions `presenceOn`, `parseOcc`, `startVacancyTimer`, `onOccupancy`, `resetOccupancy`.
- The vacancy block in `Update()`.
- `PRESENCE_NOTES.md` (replace with a pointer to this spec).
Keep `occupied(room)` only as a thin reader of the RLH `ROOM_OCCUPIED` variable.
Keep the raw sensor fields in Rooms JSON only if RLH cannot read them.

## 10. Open questions (max 5)

1. Does a DLS manual hold block vacancy-off in RLH? Proposal: no. Vacancy turns the
   light off and clears the hold, the same as the 1.10 "Vacancy Overrides Manual
   Hold = On" setting. Needs a decision.
2. Transport for occupancy: variable listener on the RLH device (proposed) or a
   `SendToDevice` event. Confirm that DriverWorks supports the listener across
   two drivers in the same project.
3. Night level for occupied rooms: `Night Level (%)` for every room, or a per-room
   value? Some rooms (hallway) may need 0 at night even when occupied.
4. Stuck-on sensor: is 120 min (Source Timeout) right, or a shorter per-sensor timeout?
5. Keep lux scaling in RLH permanently as a fallback, or remove it after step 5?
