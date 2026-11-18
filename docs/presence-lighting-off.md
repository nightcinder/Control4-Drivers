# Presence Lighting Off — what should happen to follow-me rooms?

Status: recommendation, not yet implemented. Open audit decision from the 1.11.x DLS review.

## The question

`Presence Lighting` is the master switch for follow-me lighting. When it is set to **Off**, what
should happen to a room that follow-me has already turned on?

1. **Park it** — leave every light exactly as it is, remember the room's state, and resume when the
   master switch goes back On.
2. **Release it** — drop the room out of presence control and hand it back to the normal DLS schedule
   (daylight ramp, room on/off window, night level).

## Recommendation: release, do not park

Turn every follow-me room back to the schedule the moment `Presence Lighting` goes Off.

### Why

- **Park leaves lights stranded.** With presence Off, the follow-me state machine stops driving the
  room, so nothing will ever turn that light off — not the occupancy timer (it is not running), not
  the room's scheduled off (presence overrides it while the room is OCCUPIED). A room lit by a sensor
  reading that has since gone stale stays lit until somebody notices. That is exactly the failure an
  installer is trying to stop when they reach for this switch.
- **The switch means "stop trusting presence", not "freeze the house".** The installer flips it when
  the sensor is misbehaving, during a party, or when guests are staying. In all three cases the
  expected behaviour is "go back to the schedule", not "keep whatever presence decided".
- **Release is self-healing.** The schedule is deterministic and already handles every case the
  driver supports (on window, off window, daylight, night level, away). Parking invents a second,
  parallel state with its own resume rules — more code, more edge cases, and the resume has to decide
  what to do with lights that were manually changed in the meantime.
- **Re-enabling is already correct.** On the next tick after `Presence Lighting` returns to On, each
  room recomputes from the live sensor through `prRecompute`. Nothing needs to be remembered, so
  parking buys nothing.

### What "release" means precisely

| Situation when the switch goes Off | Behaviour |
| --- | --- |
| Room is OCCUPIED because of presence | Room drops to VACANT; schedule takes over on the next update tick |
| Room is FADING (off delay expired) | Fade is cancelled; schedule takes over |
| Room is in HOLD (turned off by hand) | Hold is preserved — the user asked for it |
| Light has a per-light manual hold | Preserved — a manual change is user intent, not presence state |
| Room is away-driven | Unaffected; Away is a separate mode |

Manual holds are the deliberate exception: the switch is about presence, not about undoing what a
person did by hand. Anything presence itself decided is released.

### Implementation sketch

In `OnPropertyChanged` for `Presence Lighting`, when the new value is Off:

1. For every room with `room.pr`: cancel `pr.fadeAt`/`pr.offAt`, clear `pr.occIn`, set
   `pr.state = PR_VACANT` unless the room is in HOLD or every light carries a manual hold.
2. Keep `room.overrideUntil`, `light.overrideUntil` and `light.offHold` untouched.
3. `prSave()` once at the end, then fire the existing `Room Vacant` event per room that actually
   changed, so automation sees the release.
4. Let the next `update()` tick put the room where the schedule says it belongs — no direct light
   commands from this handler.

### Tests to add (c4sim)

- `dls_presence_off_release`: room OCCUPIED by presence, flip `Presence Lighting` Off, assert the
  room is VACANT, then advance to the room's scheduled off and assert the light goes off.
- `dls_presence_off_hold`: room in HOLD with a manual off; flip Off; assert the hold survives.
- `dls_presence_off_back_on`: flip Off then On with the sensor still occupied; assert the room comes
  back to OCCUPIED on the next tick, with no light command sent while the switch was Off.
- `dls_presence_off_fading`: room FADING when the switch goes Off; assert the fade is cancelled and
  the schedule (not the fade) decides the level.

## Also shipped this week (for context)

- `DLS 1.13.0` — presence UI properties (`Presence Room`, `Presence Follow`, `Presence Off Delay (sec)`,
  read-only `Presence Room State`), overrides persisted in `PersistData`.
- `DLS 1.14.0` — offline-light alert (`Light Timeout (sec)`, `Offline Lights`, events
  `Light Not Responding` / `Light Responding Again`).
- `DLS 1.15.0` — vacation pattern (`Vacation Pattern`, `Vacation Jitter (min)`), deterministic per-day
  off-time jitter clamped at noon.
- `dls-presence` — `/status` and `/status.json` (presence state, source health, event timeline),
  routed at `presence.onyxlens.com` behind Traefik + Authentik.
