# Jellyfin Now Playing (Control4 driver)

Driver package: `c4z/jellyfin.c4z` (source in `drivers/jellyfin/`), version 0.1.0.

**Status: UNTESTED.** Built and syntax-checked offline only (Lua 5.1 parse, XML well-formed, zip contents). Nothing has run in Composer or Director yet.

It polls a Jellyfin server for the active playback session and publishes what is on the TV as driver variables. It can send play, pause, stop, next, previous and seek commands to that session. It uses only the Jellyfin REST API, so it does not depend on the Shield, the Plex/YouTube TV apps, or any cloud service.

## Setup

1. In Jellyfin, open **Dashboard > API Keys**, click **+**, name it (for example `Control4`), and copy the key.
2. In Composer, add the driver (`jellyfin.c4z`). Set the properties:
   - **Server URL**: for example `http://<server-ip>:8096`. A missing scheme is treated as `http://`.
   - **API Key**: the key from step 1. This is a plain STRING property, so Composer shows it unmasked. Do not share the project file.
   - **Poll Interval Seconds**: default 4 (range 2 to 60).
   - **Target User Or Device Filter** (optional): case-insensitive substring matched against the Jellyfin user name, device name and client name. Leave blank to use any session.
   - **Allow Self-Signed TLS**: On only if the server uses a self-signed HTTPS certificate.
   - **Debug Log**: On to print request paths and decisions to the Composer log. The key is never logged.
3. Run the **Test Connection** action. Status should read `OK: <ServerName> <Version>` and **Server Name** fills in.

Authentication sends `Authorization: MediaBrowser Token="<key>"`. If the server answers 401 or 403, the driver retries once with `X-Emby-Token` and keeps whichever form works.

## How the active session is chosen

Each poll calls `GET /Sessions?activeWithinSeconds=960`. The driver keeps sessions that have a `NowPlayingItem` and that match the optional filter. Of those, a playing session beats a paused one, and ties go to the most recent `LastActivityDate`. Transport commands target that session.

## Properties

| Property | Type | Notes |
|---|---|---|
| Server URL | STRING | Required |
| API Key | STRING | Required, not masked |
| Poll Interval Seconds | RANGED_INTEGER 2 to 60 | Default 4 |
| Target User Or Device Filter | STRING | Optional |
| Allow Self-Signed TLS | LIST Off/On | Default Off |
| Debug Log | LIST Off/On | Default Off |
| Server Name | STRING, read-only | Filled by Test Connection |
| Status | STRING, read-only | Current state or last error |
| Driver Version | STRING, read-only | 0.1.0 |

## Variables

All are STRING and read-only in the driver. Each is written only when its value changes.

| Variable | Example |
|---|---|
| Play State | `Playing`, `Paused`, `Stopped` |
| Now Playing Title | Series name for episodes, title for movies, track for audio |
| Now Playing Subtitle | `S02E05 Episode name`, year for movies, album for audio |
| Now Playing Summary | Title and subtitle joined with ` - ` |
| Artist | Audio only |
| Year | Production year |
| Media Type | Jellyfin item type: `Episode`, `Movie`, `Audio`, and so on |
| Position / Position Seconds | `1:02:33` / `3753` |
| Runtime / Runtime Seconds | `1:45:00` / `6300` |
| Client / Device / User | Session client, device name and user name |
| Artwork URL | `<server>/Items/<id>/Images/Primary?maxWidth=480&quality=90` (empty if the item has no primary image) |
| Item Id / Session Id | Jellyfin GUIDs |

The Artwork URL does not include the API key. Whether Jellyfin serves that image without authentication has not been confirmed.

## Events

| ID | Name | Fires when |
|---|---|---|
| 1 | Play State Changed | Play State changes |
| 2 | Playback Started | Playback starts or resumes |
| 3 | Playback Stopped | Playback stops or the session disappears |
| 4 | Now Playing Item Changed | The item on the TV changes |

## Commands and actions

Programming commands (the names are normalized, so `Play/Pause`, `Play Pause` and `PLAY_PAUSE` are equivalent):

- **Play/Pause**: `POST /Sessions/{id}/Playing/PlayPause`
- **Play**: `POST /Sessions/{id}/Playing/Unpause`
- **Pause**: `POST /Sessions/{id}/Playing/Pause`
- **Stop**: `POST /Sessions/{id}/Playing/Stop`
- **Next** / **Previous**: `POST /Sessions/{id}/Playing/NextTrack` / `PreviousTrack`
- **Seek To Percent** (Percent 0 to 100): `POST /Sessions/{id}/Playing/Seek?seekPositionTicks=<ticks>`. Ticks are computed from the item runtime.

Actions: **Test Connection** (`GET /System/Info`) and **Refresh Now** (poll immediately).

After a successful transport command, the driver polls again after 0.5 seconds.

## Reliability

- Poll requests are not overlapped. A 20-second watchdog clears a request that has not returned and schedules a new poll.
- Errors are shown in Status: `Auth failed`, `Cannot reach server`, or `Server returned HTTP <code>`.
- Changing Server URL, API Key or TLS resets the auth form and polls at once.

## Build

```
python tools\build_c4z.py jellyfin
```

This writes `c4z/jellyfin.c4z` containing `driver.xml` and `driver.lua`. The driver has no icons yet, so the XML has no `<small>`/`<large>` image tags. Add them under `drivers/jellyfin/www/icons/` if Composer shows a blank icon.

## UNTESTED (verify in Composer and Director)

- The XML schema for `<events>`, the `C4:FireEvent` call, and whether events live under `<config>`.
- `C4:AddVariable` / `C4:SetVariable` behavior for driver variables, including after a restart.
- `LIST` property syntax (`<items>`) and `RANGED_INTEGER` bounds.
- The `ExecuteCommand` string that Composer passes for each programming command (the code normalizes names, so either form should work).
- The Jellyfin endpoints and parameters: `/Playing/Seek` with `seekPositionTicks`, `/Items/{id}/Images/Primary`, and whether images need auth.
- `Authorization: MediaBrowser Token=` versus `X-Emby-Token`, against the real server version.
- Behavior with several simultaneous sessions, and with a paused session that is still on screen.
- Poll load on the server at 4 seconds.
- Whether the poll timer keeps running correctly across Composer restarts and network drops.

## Plex variant plan

Build `drivers/plex/` as a sibling that copies this file's structure:

1. Keep the same variable names, event IDs, command names, `request()` and `pickSession()` pattern, so Composer programming and any UI carries over unchanged.
2. Swap the transport. Plex uses `GET /status/sessions` with an `X-Plex-Token` header, and `/player/playback/*` for control. Plex needs a client identifier. Plex sessions expose `ratingKey`, `grandparentTitle`, `parentIndex` and `index`, which map onto the same title/subtitle fields.
3. Add a Plex server URL and token property. Store the token as a STRING too.
4. Build with `python tools\build_c4z.py plex` once the folder exists.

## Tracearr (later, docs only)

If Tracearr exposes session or history data, it could feed the same variables. Nothing is implemented for it.
