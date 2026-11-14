# Shield bridge

HTTP bridge between the Shield TV Bridge Control4 driver (drivers/shield-tv-bridge) and one or more NVIDIA Shield TVs.
Keys, sleep and wake go over the Android TV Remote v2 protocol; app launch, foreground app and now playing go over ADB.

Needs a data folder with config.json (see the keys in bridge.py load_config), a paired v2 client cert (cert.pem, key.pem) and an ADB key pair (adbkey, adbkey.pub; created on first run).
Pair the v2 client once with androidtvremote2 (async_start_pairing / async_finish_pairing; the PIN shows on the TV).

    docker build -t shield-bridge:0.1.0 tools/shield-bridge
    docker run -d --name shield-bridge --restart unless-stopped -p 8790:8790 -v /path/to/data:/data shield-bridge:0.1.0

Self test (no network): python bridge.py --selftest
Token and certs never go in git.
