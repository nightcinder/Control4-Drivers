# Control4-Drivers

Unofficial Control4 DriverWorks drivers for smart home devices without official Control4 support, reverse-engineered from public protocol documentation and community integrations (Home Assistant, Hubitat, openHAB). Built and tested with a licensed Control4 EA-1 controller running Composer Pro.

Each driver ships as Lua source (`.lua`) + Composer definition (`.xml`) in its own folder under `drivers/`, with icons and docs in `www/`. Package one into a `.c4z` for Composer with `tools/build_c4z.py` (see [Building](#building)).

Not affiliated with Control4 or the respective device manufacturers.

## Drivers

| Folder | Driver | Version (XML) |
|---|---|---|
| `drivers/daylight-lighting-scheduler` | Daylight Lighting Scheduler | 2 (v1.7.0 in Lua) |
| `drivers/lifx-lan` | LIFX LAN Light | 12 |
| `drivers/haiku-senseme` | Haiku SenseME Fan | 321 |
| `drivers/haiku-senseme-nolight` | Haiku SenseME Fan (No Light Kit) | 101 |
| `drivers/intellifire` | IntelliFire Fireplace (Wi-Fi Module) | 115 |
| `drivers/moen-smart-shower` | Moen Smart Shower (U by Moen), standalone | 203 |
| `drivers/yale-assure-lock-2` | Yale Assure Lock 2 (Wi-Fi Smart Module) | 117 |
| `drivers/switchbot-cloud` | SwitchBot Cloud (parent: token, API, polling) | 4 (v2.1.0 in Lua) |
| `drivers/switchbot-curtain` | SwitchBot Curtain (child of SwitchBot Cloud) | 15 (v2.1.1 in Lua) |
| `drivers/lifx-bulb-legacy` | LIFX Bulb (earlier driver, kept for reference) | 107 |

### Daylight Lighting Scheduler (`Daylight_Lighting_Scheduler_driver`)

Drives Lutron (brightness only) and LIFX (brightness and color temperature) lights from sun position, optional cloud cover (Open-Meteo, no key) and a time-of-day curve. Each room lists its lights in the **Rooms JSON** property. Only lights listed there are controlled; remove a light from the list to stop controlling it.

- Per room: on and off times (clock or `sunset-15` style), daylight-triggered on, fade-off length, window facing and strength, manual-change hold, keypad scenes, optional sunrise wake-up, "away" lamp
- Per light: `scale` (Lutron lights only, share of the room level), `max_level` (this light's own cap; overrides the room's `max_level` when set, otherwise the room's applies), and its own windows
- Presence (Home/Away) is pushed in over TCP by `tools/dls-presence`
- Set **Latitude** and **Longitude** after adding the driver. They are blank by default
- Occupancy and lux sensor fields (`occ`, `lux`) exist in the room JSON but are untested against real sensors
- Edit the Rooms JSON with `tools/rooms-json-editor`

### LIFX LAN Light (`LIFX_LAN_driver`)

Local LIFX control over the LAN protocol (UDP 56700), with no cloud login. Discovery, on/off, brightness, HSV color and Kelvin color temperature through the Light V2 proxy. Detects each bulb's model from LIFX's product registry, so white-only bulbs (Mini Day & Dusk) hide the color tab and get the right temperature range. Near-white color targets are treated as color temperature, which stops bulbs turning pink when a scheduler sends white.

### Haiku SenseME Fan (`Haiku_SenseME_driver`, `Haiku_SenseME_NoLight_driver`)

Controls Big Ass Fans Haiku/SenseME fans (Haiku, Haiku H, Haiku L, Haiku C) over the local SenseME UDP protocol (port 31415, plain ASCII). The No Light Kit variant leaves out the light proxy.

- Exposes `FAN` and `LIGHT_V2` proxies to Control4
- Used as the reference implementation for this project's other drivers
- Known open question: the exact FAN proxy notification name sent back to Navigator (currently `SPEED`, by analogy), unconfirmed against an official Control4 sample driver

### IntelliFire Wi-Fi Fireplace (`IntelliFire_driver`)

Controls IntelliFire Wi-Fi fireplace modules (IFT-WFM) over the local HTTP/JSON API, with three states (off, pilot, flame) and variable flame height.

- Exposes a `LIGHT_V2` proxy: ON/OFF drives the main flame, level drives flame height; pilot-only is a Composer command
- Known open risk: the `/post` command-signing scheme (`SHA256(challenge + api_key + payload)`) is reconstructed from community reverse-engineering (`intellifire4py` and related integrations), not vendor documentation
- See `IntelliFire_Cowork_Test_Plan.md` for the test sequence, prerequisites (fireplace IP, API user ID and key from the IntelliFire cloud account) and what is confirmed versus assumed

### Moen Smart Shower (`Moen_Smart_Shower_Standalone_driver`)

Standalone driver for U by Moen smart showers. **Needs Control4's `drivers-common-public` library at build time** (see below).

### Yale Assure Lock 2 (`Yale_AssureLock2_driver`)

Driver for the Yale Assure Lock 2 with the Wi-Fi smart module.

### SwitchBot Cloud (parent) and SwitchBot Curtain (child)

Two drivers. **SwitchBot Cloud** (`SwitchBot_Cloud_driver`) holds the API Token and Secret, signs and sends every request to the SwitchBot cloud API v1.1 (needs a SwitchBot Hub; there is no local API), and polls status for all curtains. One **SwitchBot Curtain** (`SwitchBot_Curtain_driver`) per window binds to it and exposes a `blind` proxy plus `Open`, `Close` and `Set Position` programming commands, so the lighting scheduler can drive it later. 2.0.0 replaced the earlier standalone driver (last standalone version 1.0.11, commit cbfd60e).

Setup:
- Get the token and secret in the SwitchBot app: Profile, Preferences, About, tap the app version 10 times, then Developer Options. Add one **SwitchBot Cloud** driver and paste them into **Token** and **Secret**. One token covers every hub and floor
- Run **Discover Devices** on the parent to list device IDs (paired motors are tagged `master of pair` / `paired`)
- Add a **SwitchBot Curtain** per window and bind its **SwitchBot Cloud** connection to the parent in Connections (a one-time manual step). **Device** is then a drop-down of the discovered curtains by name (the parent runs Discover on its own when the Token is set). Curtains paired in the SwitchBot app: pick the master alone
- **Second Device** is only for two unpaired motors on one window: every command goes to both, status is combined (moving if either moves, position averaged, lowest battery)
- **Invert Level** (per child) defaults to off (SwitchBot position 100 = open, as on Den West). Set True if a curtain reports 0 = open; the Lounge pair needs True. It depends on how each motor was calibrated in the SwitchBot app
- The parent polls every 300 s by default; after a command the child shows the expected level at once, sends only the last of rapid presses (0.8 s debounce), and asks the parent for status every few seconds until the curtain stops, ignoring SwitchBot's stale just-after-command status; the account limit is 10,000 API calls per day
- Parent and child talk with `C4:SendToDevice` (`SB_REGISTER`, `SB_COMMAND`, `SB_POLL` to the parent; `SB_STATUS`, `SB_PARENT_STATUS`, `SB_HELLO` back), with the connection class `SWITCHBOT_CLOUD` linking them
- Navigator icons are original generic curtain artwork drawn by `tools/switchbot-curtain/make_icons.py` into `www/icons/`; the `controller://driver/switchbot-curtain/...` path assumes the package is named `switchbot-curtain.c4z`
- Offline signing test: `lua5.1 tools/switchbot-curtain/test_signing.lua drivers/switchbot-cloud/SwitchBot_Cloud_driver.lua` (SHA-256, HMAC-SHA256, Base64 and signature checks, no network)
- Unverified: the parent/child link (binding class, `GetBoundProviderDevice`, `SendToDevice`) has only been run against a simulation, not a live Control4. The blind proxy notifications follow the open-source Control4-HA-Blinds driver; the proxy's notification names for opening/closing motion are unknown, so Navigator jumps to the expected level on a press instead of showing movement. Signature is sent without uppercasing, per SwitchBot's samples. Token and Secret are plain STRING properties, not masked

### LIFX Bulb, earlier driver (`LIFX_Bulb_driver`)

The first LIFX driver from this project. LIFX LAN replaced it. Kept for reference.

## Tools

- `tools/build_c4z.py`: packages driver folders into `.c4z` files
- `tools/rooms-json-editor/`: plain-language editor for the scheduler's Rooms JSON (single HTML file, works offline), plus `rooms.json`, the saved config
- `tools/switchbot-curtain/`: offline signing test for the SwitchBot Curtain driver
- `tools/dls-presence/`: Home/Away reporter for the scheduler (Python, runs as a systemd service on a home server). Reads a phone's Wi-Fi presence from UniFi Poller metrics in Prometheus and, optionally, Life360. See the docstring at the top of `dls_presence.py` for settings

## Building

```
python3 tools/build_c4z.py                       # all drivers
python3 tools/build_c4z.py lifx-lan intellifire  # some
```

Output goes to `dist/` (ignored by git). Import the `.c4z` in Composer Pro with Driver, Add or Update Driver.

Composer updates an installed driver in place only when the new `.c4z` has the same file name as the original install. `PACKAGE_NAMES` in `tools/build_c4z.py` maps a folder to the name it was first installed under (for example `lifx-lan` builds `lifx_lan.c4z`). Folders not listed build under their own name, so add an entry before rebuilding a driver that was installed under a different name.

### Control4 helper files (Moen only)

The Moen driver uses Control4's open-source Lua library `drivers-common-public` (JSON, URL, timer and websocket helpers), published by Control4 / Snap One on GitHub (`snap-one/drivers-common-public`, see its `LICENSE.md`). Those files are Control4's code, so this repo does not carry copies of them: they would go stale and would need Control4's license notices kept with them.

To build the Moen driver, clone the library and point the build script at it:

```
git clone https://github.com/snap-one/drivers-common-public ~/drivers-common-public
C4_COMMON_PUBLIC=~/drivers-common-public python3 tools/build_c4z.py moen-smart-shower
```

The script copies the seven files the driver needs (`global/handlers.lua`, `global/lib.lua`, `global/timer.lua`, `global/url.lua`, `module/json.lua`, `module/metrics.lua`, `module/websocket.lua`) into the package under `drivers-common-public/`. Without that variable it skips Moen and says why. If that address has moved, search GitHub for `drivers-common-public`.

## Not included

- UniFi Protect, Google TV Notifications and other third-party drivers installed alongside these are made by other people and are not part of this repo
- Throwaway test drivers used while developing

## Conventions

- Filenames stay stable across versions. Version numbers bump inside the XML (`<version>`), and inside the Lua header where there is one, never by renaming
- New drivers are diffed element by element against the Haiku driver (the known-working reference) for XML structure and Lua API usage
- Code comments and test docs separate confirmed behavior from unverified assumptions
- `.c4z` files are build artifacts, not committed. The repo keeps the `.xml` and `.lua` source plus `www/`
- Personal values (coordinates, tokens, addresses) are not committed. Drivers ship with blank defaults
- `tools/rooms-json-editor/index.html` and the Claude artifact page of the same editor are kept identical. Update `rooms.json`, run `python3 sync_rooms.py`, then `./make_artifact.sh` to produce the exact file for the artifact
