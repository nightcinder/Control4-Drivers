# IntelliFire Fireplace Driver — Test & Refinement Brief

For the Cowork session already testing `Haiku_SenseME_driver`. This driver
follows the same conventions (same author, same project) but talks HTTP/JSON
over TCP instead of ASCII-over-UDP, and has one genuinely unverified piece:
the local command-signing scheme. That's priority #1 below.

## Files
- `IntelliFire_driver.lua` / `IntelliFire_driver.xml` — source, same pattern as the Haiku driver
- `IntelliFire_driver.c4z` — packaged driver (`driver.xml` + `driver.lua` + `www/documentation.rtf` + `icons/*.png` at root, verified against Control4's own `drivers-driverpackager` manifest format — every path the XML references was checked to exist in the archive)

## What's confirmed vs. not

**Confirmed / low risk:**
- XML structure diffed element-by-element against `Haiku_SenseME_driver.xml` (the known-working reference in this project) — no new element names, matching property types (`STRING`/`LIST` only — an earlier `PASSWORD` type I'd used for API Key was removed since it doesn't appear in the reference driver), matching boolean casing conventions.
- Network/proxy primitives (`C4:CreateNetworkConnection`, `C4:SendToNetwork`, `ReceivedFromNetwork`, `C4:SendToProxy(...,"NOTIFY")`) are the same ones already working in the Haiku driver — just TCP/80 instead of UDP/31415.
- The pure-Lua SHA-256 implementation is verified byte-for-byte against Python's `hashlib` (empty string, `"abc"`, the standard pangram, and a 130-byte multi-block input) and cross-checked for the exact `challenge + api_key + payload` composition used by `SendFireplaceCommand`.
- `.c4z` packaging validated: every file the XML references (`icons/*.png`, `www/documentation.rtf`, `driver.lua`) is confirmed present at the exact path inside the zip.

**NOT confirmed — this is the real unknown:**
- The `/post` command-signing scheme itself (`SHA256(challenge_bytes + apikey_bytes + "command=X&value=Y")` → hex, sent as `command=X&value=Y&user=<id>&response=<hex>`) is reconstructed from public reverse-engineering writeups about this hardware (the `intellifire4py` project and related community integrations), not a single confirmed spec. **This has never been tested against a live fireplace.** If the module rejects `/post`, this is where to start debugging.
- The `PILOT_TO_FLAME_DELAY_MS` (5000ms) ignition delay is a guess, not a measured value.
- Whether `/poll` ever omits `Content-Length` (the driver has a fallback path for that, but it's unexercised).

## Prerequisites before testing control (not just polling)
You need, per fireplace:
1. **Fireplace IP** — static/reserved recommended.
2. **API User ID** and **API Key** from the IntelliFire cloud account (iftapi.net). These are NOT fetched by the driver — pull them once via the `intellifire4py` Python library (`IntelliFireAPICloud.login()` → `get_user_id()` / `get_fireplace_api_key()`) or by inspecting the Home Assistant IntelliFire integration's diagnostics if that's already set up on the network.

Reading `/poll` (status only) needs no auth — that part can be tested immediately with just the IP.

## Test sequence

1. **Install & bind**
   - Load `IntelliFire_driver.c4z` (or the loose `.xml`/`.lua` in DriverEditor).
   - Set `Fireplace IP Address`. Leave `API User ID`/`API Key` blank for step 2.
   - Set `Log Mode` = `Print and Log` for the whole session — every HTTP request/response gets logged.

2. **Read-only polling (no auth required)**
   - Confirm `Connection Status` property flips to `ONLINE` within one poll interval (default 20s).
   - Confirm the light_v2 proxy in Navigator shows a level reflecting current flame height (0% if fireplace is off).
   - Manually change flame height from the physical remote/app and confirm the driver's poll picks it up within ~20s and Navigator's level updates via `NotifyFlameLevel()`.
   - **If this step fails**: check `/poll`'s actual JSON keys against what `JsonNumberField` expects (`power`, `pilot`, `height`) — field names could differ by firmware/model. Log Mode will show the raw response body.

3. **Control — the risky part**
   - Fill in `API User ID` / `API Key`.
   - From Navigator, turn the fireplace ON. Watch the log for:
     - `GET /get_challenge` → should return 200 + a hex string.
     - `POST /post` with a `pilot=1` (if pilot wasn't already on) or `power=1` command.
   - **If `/post` returns non-200 or the fireplace doesn't respond**: this is almost certainly the signing scheme. Options to try, roughly in order of likely fix:
     a. Swap the byte order in `ComputeCommandSigning` (e.g., `apikey + challenge + payload` instead of `challenge + apikey + payload`).
     b. Check whether `payload` should be URL-encoded differently, or whether the command name differs from `power`/`pilot`/`height` (try dumping a raw capture from the official IntelliFire app hitting the same fireplace, if that's feasible on this network, to get ground truth on both field names and signing).
     c. Check whether the response needs to be the raw digest bytes rather than a hex string somewhere in the request.
   - Once ON works, test OFF, and test flame-height changes via the light_v2 dimmer level (0–100% → height 0–4).
   - Test the `Set Pilot` Composer command directly (independent of the ON/OFF flow) — this exercises the pilot-only state the driver deliberately didn't fold into ON/OFF.

4. **Ignition delay tuning**
   - If pilot wasn't already lit and you commanded ON, the driver waits `PILOT_TO_FLAME_DELAY_MS` (5s) before sending the main-flame command. Watch whether the fireplace's actual purge/ignition sequence is longer or shorter than that in practice, and adjust the constant near the top of `driver.lua` if needed.

5. **Failure/edge cases worth exercising**
   - Fireplace IP unreachable/wrong — confirm `Connection Status` reflects it and the driver doesn't hang or spam retries destructively.
   - Rapid back-to-back Navigator commands (e.g., dragging the dimmer slider) — the driver serializes requests through a single queue (`g_reqQueue`); confirm nothing gets dropped or the queue doesn't back up unbounded.
   - Driver restart while the fireplace is mid-ignition — confirm state resyncs correctly on the next poll.

## What "fixed" looks like
By the end, the goal is: `ComputeCommandSigning` produces requests the real `/post` endpoint accepts, `PILOT_TO_FLAME_DELAY_MS` reflects reality, and the `/poll` field names are confirmed against a live response. Please leave inline comments or update the header block in `driver.lua` (same style as the existing "Known remaining uncertainty" notes in `Haiku_SenseME_driver.lua`) documenting whatever gets confirmed or corrected, so the driver's own header stays an accurate record of what's verified vs. assumed.
