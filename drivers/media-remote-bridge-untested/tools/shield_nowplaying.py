#!/usr/bin/env python3
# version 0.6 (2026-11-11): keep paused now-playing while content is still on the TV
"""Push Shield now-playing state to the Media Remote Bridge driver.

Every poll interval, for each configured Shield, this runs
    adb -s HOST:5555 shell dumpsys media_session
takes the first session in "Sessions Stack" with active=true (the stack is
most-recent-first) and POSTs it to the bridge:
    POST /v1/nowplaying?room=..&title=..&artist=..&app=..&playing=1|0

room_auto (optional config section): when exactly one Shield is playing, that room becomes the
Control4 active room; otherwise the room of the phone (UniFi AP, read from Prometheus) is used.
Switches only after the desired room has been stable for stable_cycles polls, and never while the
driver is locked. See room_auto_cycle().

Standard library only. The token is read from an environment variable (or a
file) named in the config; it is never stored in the config or logged.

Usage:
    python shield_nowplaying.py CONFIG.json           run forever
    python shield_nowplaying.py CONFIG.json --once    poll once, print parsed state, no POST
    python shield_nowplaying.py --selftest            check the Plex/Jellyfin parsers on sample JSON

Optional "plex" and "jellyfin" config sections let the poller replace the Shield's
title/artist with what the media server reports (see README). Their tokens are read
from files named in the config and are never printed or logged.
"""

import argparse
import json
import os
import re
import socket
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
    "org.jellyfin.androidtv": "Jellyfin",
}

PLAYBACK_PLAYING = 3          # PlaybackState.STATE_PLAYING; 2 is paused
ERROR_REPEAT_SECONDS = 300    # repeat an identical adb error this often at most
ENRICH_TIMEOUT_SECONDS = 3    # per media server request
ENRICH_CACHE_SECONDS = 4      # at most one media server request per Shield in this window
PLEX_APP = "com.plexapp.android"
PLEX_LIVE_STATES = ("playing", "paused", "buffering")

HEADER_RE = re.compile(r"^(\s*)\S.*\(userId=\d+\)\s*$")
ACTIVE_RE = re.compile(r"^active=(true|false)$")
PACKAGE_RE = re.compile(r"^package=(\S+)$")
STATE_RE = re.compile(r"^state=PlaybackState \{state=(-?\d+)")
DESCRIPTION_RE = re.compile(r"description=(.*)$")


class AdbError(Exception):
    pass


class EnrichError(Exception):
    """A media server lookup failed. The message never contains a URL, token or key."""
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
        app = APP_NAMES.get(package) or ("Jellyfin" if is_jellyfin(package) else package.split(".")[-1])
    return {
        "session": header,
        "package": package,
        "state": state,
        "playing": playing,
        "title": title,
        "artist": artist,
        "app": app,
        "enriched": False,
        "source": "shield",
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


def is_jellyfin(package):
    return package == "org.jellyfin.androidtv" or "jellyfin" in package.lower()


def ip_only(endpoint):
    """Host part of 'a.b.c.d', 'a.b.c.d:port' or '[v6]:port'."""
    s = (endpoint or "").strip()
    if s.startswith("["):
        return s[1:s.find("]")] if "]" in s else s
    if s.count(":") == 1:
        return s.split(":")[0]
    return s


def read_secret(path):
    if not path:
        raise EnrichError("secret file not configured")
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            value = f.read().strip()
    except OSError:
        raise EnrichError("secret file unreadable")
    if not value:
        raise EnrichError("secret file is empty")
    return value


def http_get_json(url, headers):
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=ENRICH_TIMEOUT_SECONDS) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        raise EnrichError("server returned HTTP %d" % e.code)
    except urllib.error.URLError as e:
        if isinstance(e.reason, socket.timeout):
            raise EnrichError("request timed out")
        raise EnrichError("server unreachable (%s)" % type(e.reason).__name__)
    except socket.timeout:
        raise EnrichError("request timed out")
    except OSError as e:
        raise EnrichError("server unreachable (%s)" % type(e).__name__)
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        raise EnrichError("server sent invalid JSON")


def episode_label(season, number, title):
    """'S7E3 - Title', omitting whichever of season, episode or title is missing."""
    code = ""
    if season not in (None, ""):
        code += "S%s" % season
    if number not in (None, ""):
        code += "E%s" % number
    if code and title:
        return code + " - " + title
    return code or (title or "")


def plex_info(meta):
    player = meta.get("Player") or {}
    kind = meta.get("type")
    if kind == "episode":
        title = meta.get("grandparentTitle") or meta.get("title") or ""
        artist = episode_label(meta.get("parentIndex"), meta.get("index"), meta.get("title"))
    elif kind == "movie":
        title = meta.get("title") or ""
        year = meta.get("year")
        artist = str(year) if year else ""
    else:
        title = meta.get("title") or ""
        artist = meta.get("grandparentTitle") or meta.get("parentTitle") or ""
    return {"title": title, "artist": artist, "playing": player.get("state") == "playing"}


def parse_plex_sessions(data, shield_ip):
    """Return {title, artist, playing} for the Shield's Plex session, or None if there is none."""
    if not isinstance(data, dict):
        raise EnrichError("unexpected JSON from server")
    items = (data.get("MediaContainer") or {}).get("Metadata") or []
    live = [m for m in items
            if isinstance(m, dict) and (m.get("Player") or {}).get("state") in PLEX_LIVE_STATES]
    chosen = None
    if shield_ip:
        for m in live:
            if (m["Player"].get("address") or "") == shield_ip:
                chosen = m
                break
    if chosen is None:
        for m in live:
            p = m["Player"]
            text = ("%s %s" % (p.get("title") or "", p.get("product") or "")).upper()
            if "SHIELD" in text:
                chosen = m
                break
    return plex_info(chosen) if chosen is not None else None


def jellyfin_info(session):
    item = session.get("NowPlayingItem") or {}
    ps = session.get("PlayState") or {}
    kind = item.get("Type")
    if kind == "Episode":
        title = item.get("SeriesName") or item.get("Name") or ""
        artist = episode_label(item.get("ParentIndexNumber"), item.get("IndexNumber"), item.get("Name"))
    elif kind == "Movie":
        title = item.get("Name") or ""
        year = item.get("ProductionYear")
        artist = str(year) if year else ""
    else:
        title = item.get("Name") or ""
        artist = item.get("SeriesName") or item.get("Album") or ""
    paused = ps.get("IsPaused")
    playing = (not paused) if isinstance(paused, bool) else None
    return {"title": title, "artist": artist, "playing": playing}


def parse_jellyfin_sessions(data, shield_ip):
    """Return {title, artist, playing} for the Shield's Jellyfin session, or None if there is none."""
    if not isinstance(data, list):
        raise EnrichError("unexpected JSON from server")
    live = [s for s in data if isinstance(s, dict) and s.get("NowPlayingItem")]
    chosen = None
    if shield_ip:
        for s in live:
            if ip_only(s.get("RemoteEndPoint")) == shield_ip:
                chosen = s
                break
    if chosen is None:
        candidates = [s for s in live
                      if "android tv" in ("%s %s" % (s.get("DeviceName") or "", s.get("Client") or "")).lower()]
        if len(candidates) == 1:
            chosen = candidates[0]
    return jellyfin_info(chosen) if chosen is not None else None


def fetch_plex(sec, shield_ip):
    token = read_secret(sec.get("token_file"))
    data = http_get_json(sec["url"].rstrip("/") + "/status/sessions",
                         {"X-Plex-Token": token, "Accept": "application/json"})
    return parse_plex_sessions(data, shield_ip)


def fetch_jellyfin(sec, shield_ip):
    key = read_secret(sec.get("key_file"))
    data = http_get_json(sec["url"].rstrip("/") + "/Sessions",
                         {"Authorization": 'MediaBrowser Token="%s"' % key,
                          "X-Emby-Token": key, "Accept": "application/json"})
    return parse_jellyfin_sessions(data, shield_ip)


def note_enrich_error(room, text, state, quiet):
    line = "%s: %s; using Shield values" % (room, text)
    if quiet:
        print(line, file=sys.stderr)
        return
    key = ("enrich-err", room, text)
    now = time.monotonic()
    last = state.get(key)
    if last is None or now - last >= ERROR_REPEAT_SECONDS:
        log(line)
        state[key] = now


def enrich_info(cfg, sh, info, state, quiet=False):
    """Replace the Shield's title/artist with the media server's view when it has one."""
    out = dict(info)
    out["enriched"] = False
    out["source"] = "shield"
    package = info.get("package") or ""
    if package == PLEX_APP and (cfg.get("plex") or {}).get("url"):
        source = "plex"
    elif is_jellyfin(package) and (cfg.get("jellyfin") or {}).get("url"):
        source = "jellyfin"
    else:
        return out
    room = sh["room"]
    key = ("enrich", room)
    now = time.monotonic()
    cached = state.get(key)
    if cached is not None and now - cached[0] < ENRICH_CACHE_SECONDS:
        match = cached[1]
    else:
        match = None
        try:
            ip = ip_only(sh["host"])
            if source == "plex":
                match = fetch_plex(cfg["plex"], ip)
            else:
                match = fetch_jellyfin(cfg["jellyfin"], ip)
        except EnrichError as e:
            note_enrich_error(room, "%s enrichment: %s" % (source, e), state, quiet)
        except Exception as e:  # enrichment must never break the poll
            note_enrich_error(room, "%s enrichment: unexpected %s" % (source, type(e).__name__), state, quiet)
        state[key] = (now, match)
    if match is None:
        return out
    if match["title"]:
        out["title"] = match["title"]
    out["artist"] = match["artist"]
    if match["playing"] is not None:
        out["playing"] = match["playing"]
    out["enriched"] = True
    out["source"] = source
    return out


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


ROOM_AUTO_DEFAULTS = {
    "enabled": False,
    "phone_name": "",
    "prometheus_url": "",
    "ap_rooms": {},
    "stable_cycles": 3,
    "phone_cache_seconds": 20,
}


def room_auto_config(cfg):
    ra = dict(ROOM_AUTO_DEFAULTS)
    ra.update(cfg.get("room_auto") or {})
    ra["stable_cycles"] = max(1, int(ra["stable_cycles"]))
    return ra


def room_for_ap(ra, ap):
    """Room for a UniFi AP name, or None when the AP is not in the map."""
    if not ap:
        return None
    return (ra.get("ap_rooms") or {}).get(ap)


def phone_ap(ra, state):
    """AP name the phone is associated with, from UniFi Poller metrics in Prometheus. None when not found."""
    now = time.monotonic()
    cached = state.get("room_auto_phone")
    if cached is not None and now - cached[0] < ra["phone_cache_seconds"]:
        return cached[1]
    ap = None
    name = ra.get("phone_name") or ""
    try:
        if not name or not re.match(r"^[A-Za-z0-9_. -]+$", name):
            raise EnrichError("phone_name not configured")
        base = ra["prometheus_url"].rstrip("/")
        for label in ("name", "hostname"):
            q = 'unpoller_client_uptime_seconds{%s=~"(?i)%s"}' % (label, name)
            data = http_get_json(base + "/api/v1/query?" + urllib.parse.urlencode({"query": q}),
                                 {"Accept": "application/json"})
            for series in ((data or {}).get("data") or {}).get("result") or []:
                m = series.get("metric") or {}
                if m.get("wired") == "false" and m.get("ap_name"):
                    ap = m["ap_name"]
                    break
            if ap:
                break
    except EnrichError as e:
        report_error("room_auto", "phone lookup: %s" % e, state)
    except Exception as e:
        report_error("room_auto", "phone lookup: unexpected %s" % type(e).__name__, state)
    state["room_auto_phone"] = (now, ap)
    return ap


def desired_room(playing_rooms, phone_room):
    """(room, reason). Exactly one playing room wins; otherwise the phone's room decides."""
    if len(playing_rooms) == 1:
        return playing_rooms[0], "%s is playing" % playing_rooms[0]
    why = "both rooms playing" if len(playing_rooms) > 1 else "nothing playing"
    if phone_room:
        return phone_room, "%s; phone is in %s" % (why, phone_room)
    return None, "%s; phone location unknown" % why


def room_auto_decision(cfg, infos, state):
    """(desired room, reason) for this poll. A room with no adb state counts as not playing."""
    ra = room_auto_config(cfg)
    playing = [sh["room"] for sh in cfg["shields"] if (infos.get(sh["room"]) or {}).get("playing")]
    ap = phone_ap(ra, state)
    return desired_room(playing, room_for_ap(ra, ap))


def auto_stable(auto, desired, stable_cycles):
    """True when desired has held for stable_cycles polls and differs from the room last applied."""
    if desired is None:
        auto["candidate"], auto["count"] = None, 0
        return False
    if desired == auto["candidate"]:
        auto["count"] += 1
    else:
        auto["candidate"], auto["count"] = desired, 1
    return auto["count"] >= stable_cycles and desired != auto["applied"]


def auto_apply(auto, desired, get_status, set_room):
    """Make the driver show desired unless it is locked or already there. Returns a short action string."""
    try:
        status = get_status()
    except Exception as e:
        return "skip: controller unreachable (%s)" % type(e).__name__
    if not isinstance(status, dict):
        return "skip: unexpected status"
    if str(status.get("lock_room", "Off")) == "On":
        return "skip: room is locked"
    if status.get("active_room") == desired:
        auto["applied"] = desired
        return "already on %s" % desired
    try:
        set_room(desired)
    except Exception as e:
        return "switch failed (%s)" % type(e).__name__
    auto["applied"] = desired
    return "switched to %s" % desired


def bridge_call(cfg, token, method, path, query=None):
    url = cfg["bridge_base_url"].rstrip("/") + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, data=b"" if method == "POST" else None, method=method,
                                 headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = resp.read().decode("utf-8", "replace")
    return json.loads(body) if body.strip() else {}


def room_auto_cycle(cfg, token, infos, state):
    ra = room_auto_config(cfg)
    if not ra["enabled"]:
        return
    desired, reason = room_auto_decision(cfg, infos, state)
    sig = (desired, reason)
    if state.get("room_auto_sig") != sig:
        state["room_auto_sig"] = sig
        log("room_auto: desired %s (%s)" % (desired or "none", reason))
    auto = state.setdefault("room_auto", {"candidate": None, "count": 0, "applied": None})
    if not auto_stable(auto, desired, ra["stable_cycles"]):
        return
    action = auto_apply(
        auto, desired,
        lambda: bridge_call(cfg, token, "GET", "/v1/status"),
        lambda room: bridge_call(cfg, token, "POST", "/v1/command/set_active_room", {"room": room}))
    if state.get("room_auto_action") != action:
        state["room_auto_action"] = action
        log("room_auto: %s" % action)


def _room_auto_sim(desireds, applied=None, status=None, stable=3):
    """Replay per-poll desired rooms through the same logic. Returns (rooms POSTed, action strings)."""
    if status is None:
        status = {"lock_room": "Off", "active_room": "Downstairs"}
    posts, actions = [], []
    auto = {"candidate": None, "count": 0, "applied": applied}

    def get_status():
        if isinstance(status, Exception):
            raise status
        return dict(status)

    for d in desireds:
        if auto_stable(auto, d, stable):
            actions.append(auto_apply(auto, d, get_status, posts.append))
    return posts, actions


# --- Paused "now playing" hold ------------------------------------------------
# The Shield's media session can be released while content is still on screen
# (an app drops its session while paused). When no active session is seen, keep
# reporting the last real session with playing=False, so the card stays up.
# It is cleared when the Shield is back on its home screen, or after
# HOLD_CAP_SECONDS of continuous holding. If adb keeps failing, the last report
# is re-sent for up to ADB_HOLD_SECONDS, then left to go stale.
HOLD_CAP_SECONDS = 6 * 3600
ADB_HOLD_SECONDS = 180
FOREGROUND_CHECK_SECONDS = 20
HOME_PACKAGES = ("com.google.android.tvlauncher", "com.google.android.apps.tv.launcherx")
FOREGROUND_RE = re.compile(r"mResumedActivity:.*?\s([A-Za-z][\w.]*)/")


def new_hold_slot():
    return {"info": None, "held_since": None, "adb_fail_since": None, "fg": None, "fg_at": None}


def has_session(info):
    """True when the parsed info describes a real app session (not the empty placeholder)."""
    return bool(info.get("app") or info.get("title"))


def is_home_package(package):
    """True for the TV home screen / launcher, which means the content is gone.
    Dream (screensaver) and systemui foregrounds do not count."""
    if not package:
        return False
    return package in HOME_PACKAGES or "launcher" in package.lower()


def foreground_package(adb, serial):
    """Package of the activity in front on the Shield, or None if it cannot be read."""
    try:
        text = run_adb(adb, serial, "shell", "dumpsys", "activity", "activities")
    except AdbError:
        return None
    m = FOREGROUND_RE.search(text)
    return m.group(1) if m else None


def held_copy(slot):
    """The last real session, marked paused (playing=False, so room_auto treats it as not playing)."""
    held = dict(slot["info"])
    held["playing"] = False
    return held


def clear_hold(slot):
    """Forget the held session; return the empty info that tells the driver nothing is playing."""
    slot["info"] = None
    slot["held_since"] = None
    slot["fg"] = None
    slot["fg_at"] = None
    return build_info(None, None, None, "")


def hold_expired(slot, now):
    """Start the hold clock on first use and report whether the 6 h cap has passed."""
    if slot["held_since"] is None:
        slot["held_since"] = now
    return now - slot["held_since"] >= HOLD_CAP_SECONDS


def hold_or_clear(slot, now, get_foreground):
    """No active session on the TV. Keep the last real session as paused, unless the
    Shield is on its home screen or the hold has run past HOLD_CAP_SECONDS."""
    if slot["info"] is None:
        return build_info(None, None, None, "")
    if hold_expired(slot, now):
        return clear_hold(slot)
    if slot["fg_at"] is None or now - slot["fg_at"] >= FOREGROUND_CHECK_SECONDS:
        slot["fg"] = get_foreground()
        slot["fg_at"] = now
    if is_home_package(slot["fg"]):
        return clear_hold(slot)
    return held_copy(slot)


def hold_through_adb_error(slot, now):
    """An adb call failed. Re-send the last real session (paused) for up to
    ADB_HOLD_SECONDS of consecutive failures, then return None so it goes stale."""
    if slot["info"] is None:
        return None
    if slot["adb_fail_since"] is None:
        slot["adb_fail_since"] = now
    if hold_expired(slot, now):
        return clear_hold(slot)
    if now - slot["adb_fail_since"] >= ADB_HOLD_SECONDS:
        return None
    return held_copy(slot)


def room_report(slot, now, live, get_foreground):
    """What to post for one room this cycle.
    live is the parsed (and enriched) session info, or None after an adb error.
    Returns None when nothing should be posted."""
    if live is None:
        return hold_through_adb_error(slot, now)
    slot["adb_fail_since"] = None
    if has_session(live):
        # a real session (playing or paused) replaces whatever was held
        slot["info"] = live
        slot["held_since"] = None
        slot["fg_at"] = None
        return live
    return hold_or_clear(slot, now, get_foreground)


def poll_once(cfg, token, state):
    adb = cfg["adb"]
    base = cfg["bridge_base_url"]
    heartbeat = float(cfg["heartbeat_seconds"])
    infos = {}
    for sh in cfg["shields"]:
        room = sh["room"]
        host = sh["host"]
        if is_placeholder(host):
            continue
        serial = serial_for(host)
        slot = state.setdefault(("held", room), new_hold_slot())
        try:
            live = parse_media_session(run_adb(adb, serial, "shell", "dumpsys", "media_session"))
        except AdbError as e:
            report_error(room, str(e), state)
            adb_connect(adb, serial)  # retry on the next cycle
            live = None  # adb failed: keep re-sending the held session for a while
        except Exception as e:  # unexpected output: log, never crash
            report_error(room, "could not parse dumpsys: %s" % e, state)
            live = None
        else:
            live = enrich_info(cfg, sh, live, state)
        info = room_report(slot, time.monotonic(), live, lambda: foreground_package(adb, serial))
        if info is None:
            continue  # nothing to hold: let the report go stale as before
        infos[room] = info
        payload = (info["title"], info["artist"], info["app"], info["playing"])
        now = time.monotonic()
        prev = state.get(room)
        if prev is not None and prev["payload"] == payload and now - prev["sent"] < heartbeat:
            continue
        if post_state(base, token, room, info):
            if prev is None or prev["payload"] != payload:
                log("%s: %s" % (room, describe(info)))
            state[room] = {"payload": payload, "sent": now}
    try:
        room_auto_cycle(cfg, token, infos, state)
    except Exception as e:
        report_error("room_auto", "unexpected error: %s" % type(e).__name__, state)


def run_once(cfg):
    state = {}
    infos = {}
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
        info = enrich_info(cfg, sh, info, state, quiet=True)
        infos[room] = info
        out = dict(info)
        out["room"] = room
        out["host"] = host
        out["query"] = build_query(room, info)
        print(json.dumps(out, indent=2))
    if room_auto_config(cfg)["enabled"]:
        desired, reason = room_auto_decision(cfg, infos, state)
        print(json.dumps({"room_auto_desired": desired, "reason": reason}, indent=2))


def selftest():
    """Feed sample Plex and Jellyfin JSON through the parsers. No network, no adb, no token."""
    shield = "172.21.1.186"
    plex_episode = {"MediaContainer": {"size": 2, "Metadata": [
        {"type": "episode", "title": "Time for a Wedding!", "grandparentTitle": "Example Show",
         "parentIndex": 7, "index": 3, "year": 2019,
         "Player": {"address": "172.21.1.186", "state": "playing",
                    "title": "SHIELD Android TV", "product": "Plex for Android (TV)"}},
        {"type": "movie", "title": "Other Movie", "year": 2001,
         "Player": {"address": "172.21.1.50", "state": "playing",
                    "title": "Living Room Browser", "product": "Plex Web"}},
    ]}}
    plex_movie = {"MediaContainer": {"size": 1, "Metadata": [
        {"type": "movie", "title": "Example Movie", "year": 2019, "ratingKey": "1234",
         "Player": {"address": "172.21.1.186", "state": "paused",
                    "title": "SHIELD Android TV", "product": "Plex for Android (TV)"}},
    ]}}
    plex_other_only = {"MediaContainer": {"size": 1, "Metadata": [
        {"type": "movie", "title": "Other Movie", "year": 2001,
         "Player": {"address": "172.21.1.50", "state": "playing",
                    "title": "Living Room Browser", "product": "Plex Web"}},
    ]}}
    jf_episode = [
        {"Id": "s1", "DeviceName": "Shield", "Client": "Jellyfin Android TV",
         "RemoteEndPoint": "172.21.1.186",
         "NowPlayingItem": {"Type": "Episode", "SeriesName": "Example Show", "Name": "Time for a Wedding!",
                            "ParentIndexNumber": 7, "IndexNumber": 3},
         "PlayState": {"IsPaused": False, "PositionTicks": 123456789}},
        {"Id": "s2", "DeviceName": "Laptop", "Client": "Jellyfin Web",
         "RemoteEndPoint": "172.21.1.50:51122",
         "NowPlayingItem": {"Type": "Movie", "Name": "Other Movie", "ProductionYear": 2001},
         "PlayState": {"IsPaused": False}},
    ]
    jf_movie = [
        {"Id": "s3", "DeviceName": "Shield TV", "Client": "Jellyfin Android TV",
         "RemoteEndPoint": "172.21.1.186:41234",
         "NowPlayingItem": {"Type": "Movie", "Name": "Example Movie", "ProductionYear": 2019},
         "PlayState": {"IsPaused": True}},
    ]
    jf_fallback = [
        {"Id": "s4", "DeviceName": "Living Room Android TV", "Client": "Jellyfin Android TV",
         "RemoteEndPoint": "10.0.0.9",
         "NowPlayingItem": {"Type": "Episode", "SeriesName": "Example Show", "Name": "Pilot",
                            "ParentIndexNumber": 1, "IndexNumber": 1},
         "PlayState": {"IsPaused": False}},
    ]
    # paused-hold helpers: drive room_report through scripted polls (time, live info, foreground)
    def shown(info):
        return None if info is None else [info["title"], info["playing"]]

    def run_hold(steps):
        slot = new_hold_slot()
        return [shown(room_report(slot, now, live, lambda fg=fg: fg)) for now, live, fg in steps]

    hold_empty = build_info(None, None, None, "")
    hold_play = build_info("ActivityRecord{1 u0 com.plexapp.android/.Main t9}", "com.plexapp.android",
                           PLAYBACK_PLAYING, "Example Movie,2019")
    hold_pause = build_info("ActivityRecord{1 u0 com.plexapp.android/.Main t9}", "com.plexapp.android",
                            2, "Example Movie,2019")
    hold_other = build_info("ActivityRecord{2 u0 com.google.android.youtube.tv/.X t8}",
                            "com.google.android.youtube.tv", PLAYBACK_PLAYING, "Other Clip,Channel")
    hold_saver = "com.android.systemui"
    hold_home = "com.google.android.tvlauncher"
    cases = [
        ("plex episode",
         parse_plex_sessions(plex_episode, shield),
         {"title": "Example Show", "artist": "S7E3 - Time for a Wedding!", "playing": True}),
        ("plex movie paused",
         parse_plex_sessions(plex_movie, shield),
         {"title": "Example Movie", "artist": "2019", "playing": False}),
        ("plex no session on shield",
         parse_plex_sessions(plex_other_only, shield),
         None),
        ("jellyfin episode",
         parse_jellyfin_sessions(jf_episode, shield),
         {"title": "Example Show", "artist": "S7E3 - Time for a Wedding!", "playing": True}),
        ("jellyfin movie paused",
         parse_jellyfin_sessions(jf_movie, shield),
         {"title": "Example Movie", "artist": "2019", "playing": False}),
        ("jellyfin fallback by device name",
         parse_jellyfin_sessions(jf_fallback, shield),
         {"title": "Example Show", "artist": "S1E1 - Pilot", "playing": True}),
        ("episode label without season",
         episode_label(None, 3, "Pilot"),
         "E3 - Pilot"),
        ("room_auto one room playing", desired_room(["Upstairs"], "Downstairs")[0], "Upstairs"),
        ("room_auto both playing uses phone", desired_room(["Upstairs", "Downstairs"], "Downstairs")[0], "Downstairs"),
        ("room_auto both playing, phone unknown", desired_room(["Upstairs", "Downstairs"], None)[0], None),
        ("room_auto neither playing uses phone", desired_room([], "Upstairs")[0], "Upstairs"),
        ("room_auto unknown AP no change", desired_room([], room_for_ap({"ap_rooms": {"Kitchen": "Downstairs"}}, "Mystery"))[0], None),
        ("room_auto hysteresis holds", _room_auto_sim(["Upstairs", "Upstairs", "Downstairs", "Upstairs", "Upstairs"], applied="Downstairs")[0], []),
        ("room_auto switches once", _room_auto_sim(["Upstairs"] * 6, applied="Downstairs")[0], ["Upstairs"]),
        ("room_auto lock on blocks", _room_auto_sim(["Upstairs"] * 4, applied="Downstairs", status={"lock_room": "On", "active_room": "Downstairs"})[0], []),
        ("room_auto controller down blocks", _room_auto_sim(["Upstairs"] * 4, applied="Downstairs", status=OSError("down"))[0], []),
        ("room_auto already on, no POST", _room_auto_sim(["Upstairs"] * 4, applied="Downstairs", status={"lock_room": "Off", "active_room": "Upstairs"})[0], []),
        ("foreground package from dumpsys", FOREGROUND_RE.search("  mResumedActivity: ActivityRecord{ab12 u0 com.plexapp.android/tv.plex.app.MainActivity t4013}").group(1), "com.plexapp.android"),
        ("home screen detected, dream not", [is_home_package("com.google.android.tvlauncher"), is_home_package("com.android.systemui")], [True, False]),
        ("hold: session vanishes, shown paused", run_hold([(0, hold_play, hold_saver), (4, hold_empty, hold_saver)]), [["Example Movie", True], ["Example Movie", False]]),
        ("hold: launcher clears it", run_hold([(0, hold_play, hold_saver), (4, hold_empty, hold_home), (8, hold_empty, hold_saver)]), [["Example Movie", True], ["", False], ["", False]]),
        ("hold: adb failure keeps report, then stale", run_hold([(0, hold_play, hold_saver), (20, None, hold_saver), (170, None, hold_saver), (200, None, hold_saver)]), [["Example Movie", True], ["Example Movie", False], ["Example Movie", False], None]),
        ("hold: 6 h cap then clear", run_hold([(0, hold_play, hold_saver), (10, hold_empty, hold_saver), (10 + HOLD_CAP_SECONDS - 1, hold_empty, hold_saver), (10 + HOLD_CAP_SECONDS, hold_empty, hold_saver)]), [["Example Movie", True], ["Example Movie", False], ["Example Movie", False], ["", False]]),
        ("hold: new session replaces held", run_hold([(0, hold_play, hold_saver), (5, hold_empty, hold_saver), (10, hold_other, hold_saver), (15, hold_empty, hold_saver)]), [["Example Movie", True], ["Example Movie", False], ["Other Clip", True], ["Other Clip", False]]),
        ("hold: adb failure with nothing held posts nothing", run_hold([(0, None, hold_saver)]), [None]),
        ("hold: paused live session stays paused", run_hold([(0, hold_pause, hold_saver)]), [["Example Movie", False]]),
    ]
    failed = 0
    for name, got, want in cases:
        ok = got == want
        failed += 0 if ok else 1
        print("%-34s %s  %s" % (name, "PASS" if ok else "FAIL", json.dumps(got)))
    print("%d of %d passed" % (len(cases) - failed, len(cases)))
    return 0 if failed == 0 else 1


def kuma_ping(cfg, state):
    """Heartbeat to an Uptime Kuma push monitor (optional: config key kuma_push_url).
    Sent at most once a minute, only after a poll cycle finished without raising."""
    url = cfg.get("kuma_push_url")
    if not url:
        return
    now = time.time()
    if now - state.get("_kuma_sent", 0) < 60:
        return
    state["_kuma_sent"] = now
    try:
        urllib.request.urlopen(url, timeout=5).read()
    except Exception as e:
        log("kuma heartbeat failed: %s" % e)
def main(argv=None):
    ap = argparse.ArgumentParser(description="Push Shield now-playing to the Media Remote Bridge.")
    ap.add_argument("config", nargs="?", help="JSON config file (see shield_nowplaying.example.json)")
    ap.add_argument("--once", action="store_true", help="poll once and print the parsed state; do not POST")
    ap.add_argument("--selftest", action="store_true", help="check the Plex and Jellyfin parsers on sample JSON")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.config:
        ap.error("a config file is required (unless --selftest)")

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
                kuma_ping(cfg, state)
            except Exception as e:  # a bad cycle must not stop the loop
                log("unexpected error: %s" % e)
            time.sleep(float(cfg["poll_seconds"]))
    except KeyboardInterrupt:
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
