# Shield bridge

HTTP bridge between the Shield TV Bridge Control4 driver (drivers/shield-tv-bridge) and one or more NVIDIA Shield TVs.
Keys, sleep and wake go over the Android TV Remote v2 protocol; app launch, foreground app and now playing go over ADB.

Needs a data folder with config.json (see the keys in bridge.py load_config), a paired v2 client cert (cert.pem, key.pem) and an ADB key pair (adbkey, adbkey.pub; created on first run).
Pair the v2 client once with androidtvremote2 (async_start_pairing / async_finish_pairing; the PIN shows on the TV).

    docker build -t shield-bridge:0.1.0 tools/shield-bridge
    docker run -d --name shield-bridge --restart unless-stopped -p 8790:8790 -v /path/to/data:/data shield-bridge:0.1.0

Self test (no network): python bridge.py --selftest
Token and certs never go in git.

## Cover art

`art.resolve()` tries, in order: the Plex thumb the session already carries, a Plex session
lookup by title, the Spotify catalogue, then an iTunes lookup by title and artist, then the
playing app's own icon from its APK, then a generic streaming-box tile.

Set these in `config.json` under `art` to enable the Spotify step (it is skipped when empty):

```json
"art": {
  "spotify_client_id": "…",
  "spotify_client_secret": "…"
}
```

Create the app at developer.spotify.com/dashboard (Web API). Development mode requires the app
owner to hold Spotify Premium and allows five allowlisted users; client-credentials is enough for
`GET /search`, which is all this step uses. Because Spotify is the app actually playing, its
catalogue matches remixes and live versions that an Apple lookup resolves to the wrong release.
