# Control4-Drivers

Unofficial Control4 DriverWorks drivers for smart home devices without official Control4 support, reverse-engineered from public protocol documentation and community integrations (Home Assistant, Hubitat, openHAB). Built and tested with a licensed Control4 EA-1 controller (OS 3.4.x) running Composer Pro.

Each driver is Lua source (`.lua`) plus a Composer definition (`.xml`) in its own folder under `drivers/`, with icons in `www/`. Ready-to-import `.c4z` packages are committed in `c4z/`. Rebuild them with `tools/build_c4z.py` (see [Building](#building)).

Not affiliated with Control4 or the respective device manufacturers. All drivers are free and open source. None need a paid driver or a cloud subscription from a third party.

## Drivers

Versions are the XML `<version>` (what Composer compares), with the Lua `DRIVER_VERSION` in parentheses where it differs. "Untested" means the file header says it has not been run against real hardware or a real Director.

| Folder | Driver | Version | Package (`c4z/`) | Notes |
|---|---|---|---|---|
| `daylight-lighting-scheduler` | Daylight Lighting Scheduler | 5 (1.10.1) | `daylight_lighting_scheduler.c4z` | Sun-based light and curtain scheduling |
| `lifx-lan` | LIFX LAN Light | 12 (1.1.1) | `lifx_lan.c4z` | Local UDP, no cloud |
| `haiku-senseme-fan` | Haiku Fan (parent) | 401 | `Haiku_SenseME_Fan.c4z` | Fan only |
| `haiku-senseme-light` | Haiku Fan Light (child) | 400 | `Haiku_SenseME_Light.c4z` | Optional, one per fan with a light kit |
| `intellifire` | IntelliFire Fireplace | 211 | `IntelliFire_driver.c4z` | Web view tile, untested items noted below |
| `moen-smart-shower` | Moen Smart Shower, standalone (cloud) | 208 | `Moen_Smart_Shower_Standalone_driver_v200.c4z` | Depends on Moen's cloud service |
| `moenshower` | Moen Smart Shower, web view (local bridge) | 306 | `moenshower.c4z` | Uses `tools/moen-bridge` over HomeKit |
| `yale-assure-lock-2` | Yale Assure Lock 2 (Wi-Fi Smart Module) | 118 | `Yale_AssureLock2.c4z` | |
| `switchbot-cloud` | SwitchBot Cloud (parent) | 4 (2.1.0) | `switchbot-cloud.c4z` | Token, API, polling |
| `switchbot-curtain` | SwitchBot Curtain (child) | 15 (2.1.1) | `switchbot-curtain.c4z` | One per window |
| `roborock` | Roborock Vacuum | 10 (0.5.1) | `roborock.c4z` | Uses `tools/roborock-bridge`, untested |
| `smarthq-bridge` | SmartHQ Hub (parent) | 10 (0.3.3) | `smarthq-bridge.c4z` | Uses `tools/smarthq-bridge`, untested |
| `smarthq-appliance` | SmartHQ Appliance (child) | 2 (0.3.1) | `smarthq-appliance.c4z` | Oven, fridge, dishwasher and more, untested |
| `smarthq-hood-light` | SmartHQ Hood Light (child) | 2 (0.3.1) | `smarthq-hood-light.c4z` | Light proxy, untested |
| `smarthq` | SmartHQ Bridge (first single-driver version) | 4 (0.2.2) | `smarthq.c4z` | Replaced by the parent and child set above |
| `jellyfin` | Media Server Now Playing (Jellyfin and Plex) | 5 (0.3.0) | `media_server.c4z` | Untested, Plex backend unverified |
| `media-remote-bridge-untested` | Media Remote Bridge | 9 (0.4.4) | `MediaRemoteBridge.c4z` | For the phone and watch remote app, untested |
| `unifi-controller` | UniFi PDU Controls (parent) | 16 (1.0.12) | `UniFi_PDU_Controls.c4z` | PDU Pro and Plug outlets, untested. Renamed from `UniFi_Controller.c4z`, so Composer treats it as a new driver: delete the old one and re-add |
| `unifi-outlet` | UniFi Outlet (child relay) | 3 (1.0.2) | `UniFi_Outlet.c4z` | One per outlet, untested |
| `lifx-bulb-legacy` | LIFX Bulb (earlier driver, kept for reference) | 107 (1.0.6) | not built | Replaced by LIFX LAN |

`haiku-senseme/` and `haiku-senseme-nolight/` hold only old icons from the retired combined Haiku packages. They are in git history for rollback.

### Daylight Lighting Scheduler

Drives Lutron (brightness only) and LIFX (brightness and color temperature) lights from sun position, optional cloud cover (Open-Meteo, no key) and a time-of-day curve. Each room lists its lights in the **Rooms JSON** property. Only lights listed there are controlled.

- Per room: on and off times (clock or `sunset-15` style), daylight-triggered on, fade-off length, window facing and strength, keypad scenes, optional sunrise wake-up, "away" lamp, and an optional `curtains` list
- Per light: `scale` (Lutron lights only), `max_level` (this light's own cap; overrides the room's `max_level` when set), and its own windows
- Manual changes hold per light (not per room), so changing one lamp does not delay the scheduled off of the others. Keypad scene holds stay room-level
- Presence (Home/Away) is pushed in over TCP by `tools/dls-presence`. Arriving home or going away releases manual holds
- Optional curtain automation (property **Curtain Automation**, off by default) sends open, close and set-position to SwitchBot Curtain blind proxies
- Set **Latitude** and **Longitude** after adding the driver. They are blank by default
- Occupancy and lux fields (`occ`, `lux`) exist in the room JSON but are untested against real sensors
- Edit the Rooms JSON with `tools/rooms-json-editor`. See `drivers/daylight-lighting-scheduler/PRESENCE_NOTES.md` and `CURTAIN_NOTES.md`

### LIFX LAN Light

Local LIFX control over the LAN protocol (UDP 56700), with no cloud login. Discovery, on/off, brightness, HSV color and Kelvin color temperature through the Light V2 proxy. Detects each bulb's model from LIFX's product registry, so white-only bulbs (Mini Day & Dusk) hide the color tab and get the right temperature range. Near-white color targets are treated as color temperature, which stops bulbs turning pink when a scheduler sends white.

### Haiku Fan and Haiku Fan Light

Controls Big Ass Fans Haiku fans (firmware 3.0 and later, and i6-series fans) over the local "i6" protocol: plain TCP to port 31415, Protocol Buffers wrapped in SLIP framing. This replaced the old plaintext UDP SenseME protocol, which new firmware no longer speaks.

- **Haiku Fan** (parent) exposes a `FAN` proxy and syncs changes made in the Big Ass Fans app
- **Haiku Fan Light** (child) is optional, one per fan with a light kit, and exposes a `LIGHT_V2` proxy. A driver cannot add or remove proxies at runtime, so the light is a separate driver instead of a toggle
- The old combined and no-light packages are retired

### IntelliFire Wi-Fi Fireplace

Controls IntelliFire Wi-Fi fireplace modules (IFT-WFM) over the local HTTP/JSON API, with three states (off, pilot, flame) and variable flame height.

- The Navigator tile is a web view button whose icon follows the flame height, pilot or on state. It replaces the earlier thermostat and light proxy approaches
- Requests go through `C4:url()` instead of a raw socket, because the module handles only one connection and answers `/poll` slowly (about 5 s)
- Known open risk: the `/post` command-signing scheme (`SHA256(challenge + api_key + payload)`) is reconstructed from community reverse-engineering (`intellifire4py` and related integrations), not vendor documentation
- Recent releases (205 to 211) are marked untested in their commits
- See `drivers/intellifire/IntelliFire_Cowork_Test_Plan.md` for the test sequence, prerequisites (fireplace IP, API user ID and key from the IntelliFire cloud account) and what is confirmed versus assumed

### Moen Smart Shower (two drivers)

- **Standalone** (`moen-smart-shower`) talks to Moen's cloud service directly and needs no bridge. It can stop working when Moen's service limits are exceeded. **Needs Control4's `drivers-common-public` library at build time** (see below)
- **Web view** (`moenshower`) shows a Navigator tile with a web view page and talks to the shower locally through `tools/moen-bridge`, a small Python service that pairs with the shower over HomeKit (aiohomekit) and serves a TCP JSON-lines protocol (default port 8791). Presets are Hot and Comfortable. Back up the bridge's HomeKit pairing file and never commit it

### Yale Assure Lock 2

Driver for the Yale Assure Lock 2 with the Wi-Fi smart module.

### SwitchBot Cloud (parent) and SwitchBot Curtain (child)

Two drivers. **SwitchBot Cloud** holds the API Token and Secret, signs and sends every request to the SwitchBot cloud API v1.1 (needs a SwitchBot Hub; there is no local API), and polls status for all curtains. One **SwitchBot Curtain** per window binds to it and exposes a `blind` proxy plus `Open`, `Close` and `Set Position` programming commands, so the lighting scheduler can drive it. 2.0.0 replaced the earlier standalone driver (last standalone version 1.0.11, commit cbfd60e).

Setup:
- Get the token and secret in the SwitchBot app: Profile, Preferences, About, tap the app version 10 times, then Developer Options. Add one **SwitchBot Cloud** driver and paste them into **Token** and **Secret**. One token covers every hub and floor
- Run **Discover Devices** on the parent to list device IDs (paired motors are tagged `master of pair` / `paired`)
- Add a **SwitchBot Curtain** per window and bind its **SwitchBot Cloud** connection to the parent in Connections (a one-time manual step). **Device** is then a drop-down of the discovered curtains by name. For curtains paired in the SwitchBot app, pick the master alone
- **Second Device** is only for two unpaired motors on one window: every command goes to both, status is combined (moving if either moves, position averaged, lowest battery)
- **Invert Level** (per child) defaults to off (SwitchBot position 100 = open). Set True if a curtain reports 0 = open. It depends on how each motor was calibrated in the SwitchBot app
- The parent polls every 300 s by default. After a command the child shows the expected level at once, sends only the last of rapid presses (0.8 s debounce), and asks the parent for status every few seconds until the curtain stops, ignoring SwitchBot's stale just-after-command status. The account limit is 10,000 API calls per day
- Parent and child talk with `C4:SendToDevice` (`SB_REGISTER`, `SB_COMMAND`, `SB_POLL` to the parent; `SB_STATUS`, `SB_PARENT_STATUS`, `SB_HELLO` back), with the connection class `SWITCHBOT_CLOUD` linking them
- Navigator icons are original generic curtain artwork drawn by `tools/switchbot-curtain/make_icons.py` into `www/icons/`. The `controller://driver/switchbot-curtain/...` path assumes the package is named `switchbot-curtain.c4z`
- Offline signing test: `lua5.1 tools/switchbot-curtain/test_signing.lua drivers/switchbot-cloud/SwitchBot_Cloud_driver.lua` (SHA-256, HMAC-SHA256, Base64 and signature checks, no network)
- Still unknown: the proxy's notification names for opening and closing motion, so Navigator jumps to the expected level on a press instead of showing movement. Token and Secret are plain STRING properties, not masked

### Roborock Vacuum

Talks to the Roborock LAN HTTP bridge in `tools/roborock-bridge` (default port 8788). Start, stop, pause, dock and room clean, plus a Navigator web view with state-based tile icons. It fires Room Entered and Room Left events for the room the vacuum is in, which can drive lighting programs. Untested against a real vacuum. See `docs/roborock.md`.

### SmartHQ (GE Cafe appliances)

A parent and child set that reads GE SmartHQ appliances through the LAN HTTP bridge in `tools/smarthq-bridge` (default port 8789):

- **SmartHQ Hub** (parent) polls the bridge for every appliance and sends the one write the bridge supports, the vent hood light
- **SmartHQ Appliance** (child) shows one appliance (oven, beverage center, dishwasher, refrigerator, washer or dryer) as read-only state, variables and events
- **SmartHQ Hood Light** (child) is a `light_v2` proxy (off, dim, high) so the hood light can sit in a room for lighting automation

Bind each child's **SmartHQ Bridge** connection to the parent in Connections. All untested on real Composer, and some dishwasher field names are unconfirmed. `smarthq/` is the first single-driver version, kept for reference. See `docs/smarthq.md`.

### Media Server Now Playing (Jellyfin and Plex)

One driver for Jellyfin or Plex (or both, each on its own poll timer). It finds the active playback session, publishes now-playing data as driver variables and events, and sends transport commands back to the server. Untested on a real Director, and the Plex side is entirely unverified. See `docs/jellyfin.md`.

### Media Remote Bridge

Exposes a small HTTP/JSON API on the controller that sends room-level media commands to the Upstairs or Downstairs room, and accepts now-playing reports pushed by a Shield poller. It is the Control4 end of the phone and watch remote app (separate repo, `nightcinder/c4-media-remote`). Untested. See its own README.

### UniFi PDU Controls (parent) and UniFi Outlet (child)

Exposes UniFi power outlets (USP PDU Pro, USP Plug) to Control4 as on/off relays. Untested on hardware.

Setup: on the UniFi console, create a local admin account for Control4 (a Viewer role cannot switch outlets). Add a **UniFi PDU Controls** driver, set Host, Username and Password (leave Controller Type on Auto). Add one **UniFi Outlet** per outlet, bind its **UniFi Controller** connection to the parent, then enter the Device ID and Outlet Index copied from the parent's Discovered Outlets property. The web view page needs a Director reboot after a page-address change. Proxy changes need delete and re-add. The API paths and outlet fields are unverified; see `docs/unifi-outlet.md`.

### LIFX Bulb, earlier driver

The first LIFX driver from this project. LIFX LAN replaced it. Kept for reference and not built.

## Tools

- `tools/build_c4z.py`: packages driver folders into `.c4z` files
- `tools/rooms-json-editor/`: plain-language editor for the scheduler's Rooms JSON (single HTML file, works offline), plus `rooms.json`, the saved config
- `tools/dls-presence/`: Home/Away reporter for the scheduler (Python). Reads a phone's Wi-Fi presence from UniFi Poller metrics in Prometheus and, optionally, Life360, and runs as a container on the home server (a systemd unit file is included too). See the docstring at the top of `dls_presence.py` for settings
- `tools/moen-bridge/`: HomeKit-to-TCP bridge for the web view Moen driver (Python, systemd). See its README
- `tools/roborock-bridge/`: Docker LAN HTTP bridge around python-roborock. See its README
- `tools/smarthq-bridge/`: Docker LAN HTTP bridge around `gehomesdk`. See its README
- `tools/switchbot-curtain/`: icon generator and offline signing test for the SwitchBot drivers
- `tools/make_unifi_icons.py`, `tools/fireplace-poll-watch.ps1`: helper scripts for the UniFi icons and for watching the fireplace module's poll timing

The bridges keep login tokens and pairing files in `data/` folders or home directories that are never committed.

## Building

```
python3 tools/build_c4z.py                       # all drivers
python3 tools/build_c4z.py lifx-lan intellifire  # some
```

Output goes to `c4z/`, which is committed so the repo always holds ready-to-import packages next to the source. Rebuild and commit the matching `.c4z` with every driver change. Import the `.c4z` in Composer Pro with Driver, Add or Update Driver.

Composer updates an installed driver in place only when the new `.c4z` has the same file name as the original install, and only when the XML `<version>` is higher. `PACKAGE_NAMES` in `tools/build_c4z.py` maps a folder to the name it was first installed under (for example `lifx-lan` builds `lifx_lan.c4z`). Folders not listed build under their own name, so add an entry before rebuilding a driver that was installed under a different name. See `docs/composer-update-notes.md` for the full list of update rules.

### Control4 helper files (Moen standalone only)

The standalone Moen driver uses Control4's open-source Lua library `drivers-common-public` (JSON, URL, timer and websocket helpers), published by Control4 / Snap One on GitHub (`snap-one/drivers-common-public`, see its `LICENSE.md`). Those files are Control4's code, so this repo does not carry copies of them.

To build that driver, clone the library and point the build script at it:

```
git clone https://github.com/snap-one/drivers-common-public ~/drivers-common-public
C4_COMMON_PUBLIC=~/drivers-common-public python3 tools/build_c4z.py moen-smart-shower
```

The script copies the seven files the driver needs (`global/handlers.lua`, `global/lib.lua`, `global/timer.lua`, `global/url.lua`, `module/json.lua`, `module/metrics.lua`, `module/websocket.lua`) into the package under `drivers-common-public/`. Without that variable it skips Moen and says why.

## Not included

- UniFi Protect, Google TV Notifications and other third-party drivers installed alongside these are made by other people and are not part of this repo
- Throwaway test drivers used while developing (the `c4z/shield_nowplaying_test*.c4z` files are experiments, not releases)

## Conventions

- Filenames stay stable across versions. Version numbers bump inside the XML (`<version>` and `<modified>`) and in the Lua `DRIVER_VERSION`, never by renaming
- Every driver exposes a read-only **Driver Version** property, and `driver.xml` starts directly with `<devicedata>` (no XML declaration), or Composer will not parse it
- New drivers are diffed element by element against the Haiku driver (the known-working reference) for XML structure and Lua API usage
- Code comments and test docs separate confirmed behavior from unverified assumptions, and commits say "untested" when they are
- `.c4z` files are committed in `c4z/` on purpose, next to the `.xml` and `.lua` source
- Personal values (coordinates, tokens, addresses) are not committed. Drivers ship with blank defaults
- `tools/rooms-json-editor/index.html` and the Claude artifact page of the same editor are kept identical. Update `rooms.json`, run `python3 sync_rooms.py`, then `./make_artifact.sh` to produce the exact file for the artifact