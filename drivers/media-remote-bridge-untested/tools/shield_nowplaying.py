#!/usr/bin/env python3
"""Push Shield now-playing state to the Media Remote Bridge driver.

Every poll interval, for each configured Shield, this runs
    adb -s HOST:5555 shell dumpsys media_session
takes the first session in "Sessions Stack" with active=true (the stack is
most-recent-first) and POSTs it to the bridge:
    POST /v1/nowplaying?room=..&title=..&artist=..&app=..&playing=1|0

Standard library only. The token is read from an environment variable (or a
file) named in the config; it is never stored in the config or logged.

Usage:
    python shield_nowplaying.py CONFIG.json           run forever
    python shield_nowplaying.py CONFIG.json --once    poll once, print parsed state, no POST
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

APP_NAMES = {
    "com.google.android.youtube.tvunplugged": "YouTube TV",
    "com.spotify.tv.android": "Spotify",
    "com.plexapp.android": "Plex",
    "com.google.android.youtube.tv": "YouTube",
    "com.netflix.ninja": "Netflix",
}

PLAYBACK_PLAYING = 3          # PlaybackState.STATE_PLAYING; 2 is paused
ERROR_REPEAT_SECONDS = 300    # repeat an identical adb error this often at most

HEADER_RE = re.compile(r"^(\s*)\S.*\(userId=\d+\)\s*$")
ACTIVE_RE = re.compile(r"^active=(true|false)$")
PACKAGE_RE = re.compile(r"^package=(\S+)$")
STATE_RE = re.compile(r"^state=PlaybackState \{state=(-?\d+)")
DESCRIPTION_RE = re.compile(r"description=(.*)$")


class AdbError(Exception):
    pass


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg, flush=True)


def load_config(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        cfg = json.load(f)
    for key in ("adb", "bridge_base_url", "shields"):
        if key not in cfg:
            raise ValueError("config is missing key: " + key)
    cfg.setdefault("token_env", "MEDIA_BRIDGE_TOKEN")
    cfg.setdefault("token_file", "")
    cfg.setdefault("poll_seconds", 4)
    cfg.setdefault("heartbeat_seconds", 20)
    return cfg


def load_token(cfg):
    if cfg["token_file"]:
        with open(cfg["token_file"], "r", encoding="utf-8-sig") as f:
            return f.read().strip()
    return os.environ.get(cfg["token_env"], "").strip()


def is_placeholder(host):
    return host.upper().startswith("REPLACE")


def serial_for(host):
    return host if ":" in host else host + ":5555"


def run_adb(adb, serial, *args):
    cmd = [adb, "-s", serial] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as e:
        raise AdbError("cannot run adb: %s" % e)
    out = r.stdout.decode("utf-8", "replace")
    if r.returncode != 0 or out.lstrip().startswith("error:"):
        err = (r.stderr or b"").decode("utf-8", "replace") or out
        raise AdbError("adb failed (exit %d): %s" % (r.returncode, " ".join(err.split())[:200]))
    return out


def adb_connect(adb, serial):
    try:
        subprocess.run([adb, "connect", serial], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


def build_info(header, package, state, description):
    playing = state == PLAYBACK_PLAYING
    if package is None and header:
        tokens = header.split()
        package = (tokens[1] if len(tokens) > 1 else tokens[0]).split("/")[0]
    title, artist = "", ""
    if description:
        parts = [p.strip() for p in description.split(",", 2)]
        if parts[0] != "null":
            title = parts[0]
        if len(parts) > 1 and parts[1] != "null":
            artist = parts[1]
    app = ""
    if package:
        app = APP_NAMES.get(package, package.split(".")[-1])
    return {
        "session": header,
        "package": package,
        "state": state,
        "playing": playing,
        "title": title,
        "artist": artist,
        "app": app,
    }


def parse_media_session(text):
    """Return the first active session as a dict. No active session gives an empty, not-playing dict."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if "Sessions Stack" in line:
            start = i
            break
    if start is None:
        raise ValueError("no 'Sessions Stack' in dumpsys output")

    # Session headers are the lines ending in "(userId=N)" at the indent of the first one.
    blocks = []
    indent = None
    current = None
    for line in lines[start + 1:]:
        if not line.strip():
            continue
        lead = len(line) - len(line.lstrip(" "))
        if indent is None:
            if not HEADER_RE.match(line):
                continue
            indent = lead
        if lead < indent:
            break  # left the session list
        if lead == indent and HEADER_RE.match(line):
            current = {"header": line.strip(), "lines": []}
            blocks.append(current)
        elif current is not None:
            current["lines"].append(line.strip())

    for block in blocks:
        active = False
        package = None
        state = None
        description = ""
        for line in block["lines"]:
            m = ACTIVE_RE.match(line)
            if m:
                active = m.group(1) == "true"
                continue
            m = PACKAGE_RE.match(line)
            if m and package is None:
                package = m.group(1)
                continue
            m = STATE_RE.match(line)
            if m and state is None:
                state = int(m.group(1))
                continue
            if line.startswith("metadata:"):
                m = DESCRIPTION_RE.search(line)
                if m:
                    description = m.group(1).strip()
        if active:
            return build_info(block["header"], package, state, description)

    return build_info(None, None, None, "")


def build_query(room, info):
    return urllib.parse.urlencode({
        "room": room,
        "title": info["title"],
        "artist": info["artist"],
        "app": info["app"],
        "playing": "1" if info["playing"] else "0",
    })


def describe(info):
    if not info["app"] and not info["title"]:
        return "nothing playing"
    state = "playing" if info["playing"] else "paused"
    text = info["title"]
    if info["artist"]:
        text = text + " - " + info["artist"] if text else info["artist"]
    return "%s on %s%s" % (state, info["app"] or "unknown app", (": " + text) if text else "")


def post_state(base, token, room, info):
    url = base.rstrip("/") + "/v1/nowplaying?" + build_query(room, info)
    req = urllib.request.Request(url, data=b"", method="POST",
                                 headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            resp.read()
            return resp.status == 200
    except urllib.error.HTTPError as e:
        log("%s: bridge returned HTTP %d" % (room, e.code))
    except (urllib.error.URLError, OSError) as e:
        log("%s: bridge unreachable: %s" % (room, e))
    return False


def report_error(room, msg, state):
    slot = state.setdefault(("err", room), {"msg": None, "at": 0.0})
    now = time.monotonic()
    if msg != slot["msg"] or now - slot["at"] >= ERROR_REPEAT_SECONDS:
        log("%s: %s" % (room, msg))
        slot["msg"] = msg
        slot["at"] = now


def poll_once(cfg, token, state):
    adb = cfg["adb"]
    base = cfg["bridge_base_url"]
    heartbeat = float(cfg["heartbeat_seconds"])
    for sh in cfg["shields"]:
        room = sh["room"]
        host = sh["host"]
        if is_placeholder(host):
            continue
        serial = serial_for(host)
        try:
            info = parse_media_session(run_adb(adb, serial, "shell", "dumpsys", "media_session"))
        except AdbError as e:
            report_error(room, str(e), state)
            adb_connect(adb, serial)  # retry on the next cycle
            continue
        except Exception as e:  # unexpected output: log, never crash
            report_error(room, "could not parse dumpsys: %s" % e, state)
            continue

        payload = (info["title"], info["artist"], info["app"], info["playing"])
        now = time.monotonic()
        prev = state.get(room)
        if prev is not None and prev["payload"] == payload and now - prev["sent"] < heartbeat:
            continue
        if post_state(base, token, room, info):
            if prev is None or prev["payload"] != payload:
                log("%s: %s" % (room, describe(info)))
            state[room] = {"payload": payload, "sent": now}


def run_once(cfg):
    for sh in cfg["shields"]:
        room = sh["room"]
        host = sh["host"]
        if is_placeholder(host):
            print(json.dumps({"room": room, "host": host, "skipped": "placeholder host"}))
            continue
        try:
            info = parse_media_session(run_adb(cfg["adb"], serial_for(host), "shell", "dumpsys", "media_session"))
        except Exception as e:
            print(json.dumps({"room": room, "host": host, "error": str(e)}))
            continue
        out = dict(info)
        out["room"] = room
        out["host"] = host
        out["query"] = build_query(room, info)
        print(json.dumps(out, indent=2))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Push Shield now-playing to the Media Remote Bridge.")
    ap.add_argument("config", help="JSON config file (see shield_nowplaying.example.json)")
    ap.add_argument("--once", action="store_true", help="poll once and print the parsed state; do not POST")
    args = ap.parse_args(argv)

    try:
        cfg = load_config(args.config)
    except (OSError, ValueError) as e:
        print("config error: %s" % e, file=sys.stderr)
        return 2

    if args.once:
        run_once(cfg)
        return 0

    try:
        token = load_token(cfg)
    except OSError as e:
        print("token file error: %s" % e, file=sys.stderr)
        return 2
    if not token:
        print("no bridge token: set environment variable %s (or token_file in the config)"
              % cfg["token_env"], file=sys.stderr)
        return 2

    names = ", ".join("%s=%s" % (s["room"], s["host"]) for s in cfg["shields"])
    log("started; shields: " + names)
    state = {}
    try:
        while True:
            try:
                poll_once(cfg, token, state)
            except Exception as e:  # a bad cycle must not stop the loop
                log("unexpected error: %s" % e)
            time.sleep(float(cfg["poll_seconds"]))
    except KeyboardInterrupt:
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
