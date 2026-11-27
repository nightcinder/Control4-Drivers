#!/usr/bin/env python3
"""DLS presence bridge v1.6.2 - feeds the Daylight Lighting Scheduler (Control4 EA-1) Home/Away and per-room occupancy.

Household (PRESENCE, v1.3.0 behaviour):
  unifi   - phone present in UniFi Poller metrics in Prometheus (stdlib only)
  life360 - member's Life360 place/location says home (needs the `life360` + `aiohttp` packages, e.g. in a venv;
            used as published, unmodified; the API is unofficial and may stop working at any time)
Household is HOME if ANY person is home; a person is home if ANY of their known sources says so.

Per-room occupancy (v1.4.0, spec docs/room-presence-dls-interface.md sections 3-9), only when ROOMS_FILE exists:
  esp    - ESPHome binary_sensor via the native API (aioesphomeapi, imported lazily)
  robot  - tools/roborock-bridge status (GET ROBOT_URL, JSON with state and current_room.name)
  Sends `OCC <roomKey> 1|0 <src> <token>` lines, HELLO snapshots every OCC_REPEAT_SEC, resync and backoff.

  python3 dls_presence.py --discover                # list matching UniFi series
  python3 dls_presence.py --status                  # print each person/source once, no push
  python3 dls_presence.py --l360                    # Life360 members: place name, fix age, home? (no coordinates)
  python3 dls_presence.py --notify-test             # send a test alert through NOTIFY_SMTP/NOTIFY_TO
  python3 dls_presence.py                           # run forever (systemd)
Env:  PROM_URL (default http://localhost:9090)  EA1_HOST  EA1_PORT (8730)  DLS_TOKEN (REQUIRED, no default; must equal the driver's Presence Token property)
      PHONE_NAME (default Pixel-11-Pro)  AWAY_AFTER_MIN (default 5)  POLL_SEC (default 30)
      PEOPLE       optional JSON list, e.g. [{"name":"Nick","unifi":"Pixel-11-Pro","life360":"Nick"}]
                   default: one person built from PHONE_NAME (+ LIFE360_MEMBER if set)
      LIFE360_TOKEN   the LIFE360_AUTH_TOKEN cookie value (Bearer)
      LIFE360_MEMBER  member first name (or id) for the default person
      LIFE360_HOME_NAME   comma-separated Life360 place name(s) that mean home (required unless HOME_LAT/HOME_LON set)
      HOME_LAT/HOME_LON/HOME_RADIUS_M   optional: also count as home when within the radius (default 150 m)
      LIFE360_POLL_SEC (default 120)  LIFE360_STALE_MIN (default 45: older fixes are ignored)
      NOTIFY_TO (e.g. idrac@mailrise.xyz; empty = no alerts)  NOTIFY_SMTP (default localhost:8025)  NOTIFY_FROM
      LIFE360_ALERT_AFTER_MIN (default 30: alert once Life360 has failed this long; repeats every 6 h, plus a recovery notice)
      DLS_ALERT_AFTER_MIN (default 10: alert once the DLS link has refused/failed sends this long; repeats every 6 h, plus a recovery notice)
      FRESH_PORT (default 8731, 0 = off)  FRESH_BIND (default 127.0.0.1)
      ROOMS_FILE (default /etc/dls-presence.rooms.json; missing = no OCC lines, v1.3.0 behaviour)
      OCC_REPEAT_SEC (60)  STUCK_ON_MIN (240)  SRC_UNKNOWN_SEC (180)  ESPHOME_PORT (6053)
      ROBOT_URL (roborock-bridge, e.g. http://liesa:8788 or .../state; empty = no robot source)  ROBOT_POLL_SEC (15)
  GET /health  -> JSON per source: seconds since last successful poll, poll interval, stale flag.
                  HTTP 200 when all sources are fresh, 503 if any is stale (older than 3x its poll interval).
  GET /metrics -> v1.6.0 Prometheus gauges: dls_presence_lux{room,sensor,entity} (ESPHome sensors with unit lx),
                  dls_presence_occupancy / dls_presence_motion{room,sensor,entity}, dls_presence_room_occupancy{room},
                  dls_presence_sensor_up{sensor}, dls_presence_home. Unknown values are left out.
"""
import csv, json, math, os, re, smtplib, socket, sys, threading, time, urllib.parse, urllib.request
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.6.2"  # v1.6.2: tracking entity counts as motion; night stuck rule (rooms.json "night")
# was 1.6.1:  # v1.6.1: UniFi with no client series is unknown (None), not away; _last_ok only on data
PROM = os.environ.get("PROM_URL", "http://localhost:9090").rstrip("/")
HOST = os.environ.get("EA1_HOST", "")
PORT = int(os.environ.get("EA1_PORT", "8730"))
TOKEN = os.environ.get("DLS_TOKEN", "").strip()  # required; no default on purpose
PHONE = os.environ.get("PHONE_NAME", "Pixel-11-Pro")
AWAY_AFTER = float(os.environ.get("AWAY_AFTER_MIN", "5")) * 60
POLL = float(os.environ.get("POLL_SEC", "30"))
LABELS = ("name", "hostname")

L360_TOKEN = os.environ.get("LIFE360_TOKEN", "").strip()
L360_MEMBER = os.environ.get("LIFE360_MEMBER", "")
L360_HOME_NAMES = {n.strip().lower() for n in os.environ.get("LIFE360_HOME_NAME", "").split(",") if n.strip()}
L360_POLL = float(os.environ.get("LIFE360_POLL_SEC", "120"))
L360_STALE = float(os.environ.get("LIFE360_STALE_MIN", "45")) * 60
HOME_LAT = os.environ.get("HOME_LAT")
HOME_LON = os.environ.get("HOME_LON")
HOME_RADIUS = float(os.environ.get("HOME_RADIUS_M", "150"))

NOTIFY_TO = os.environ.get("NOTIFY_TO", "").strip()
NOTIFY_SMTP = os.environ.get("NOTIFY_SMTP", "localhost:8025").strip()
NOTIFY_FROM = os.environ.get("NOTIFY_FROM", "dls-presence@liesa").strip()
L360_ALERT_AFTER = float(os.environ.get("LIFE360_ALERT_AFTER_MIN", "30")) * 60
DLS_ALERT_AFTER = float(os.environ.get("DLS_ALERT_AFTER_MIN", "10")) * 60

# v1.4.0 per-room occupancy
ROOMS_FILE = os.environ.get("ROOMS_FILE", "/etc/dls-presence.rooms.json")
OCC_REPEAT_SEC = float(os.environ.get("OCC_REPEAT_SEC", "60"))
STUCK_ON_MIN = float(os.environ.get("STUCK_ON_MIN", "240"))
SRC_UNKNOWN_SEC = float(os.environ.get("SRC_UNKNOWN_SEC", "180"))
ESPHOME_PORT = int(os.environ.get("ESPHOME_PORT", "6053"))
ROBOT_URL = os.environ.get("ROBOT_URL", "").strip()
ROBOT_POLL = float(os.environ.get("ROBOT_POLL_SEC", "15"))
TICK_SEC = 0.5
ROBOT_STALE = 180.0
AUTH_RETRY_SEC = 60.0
AUTH_ALERT_AFTER = 30 * 60.0
BACKOFF = (5, 10, 20, 60)
ALL_SOURCES = ("esp", "robot")
KEY_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")

_warned = set()

EVENT_LOG = os.environ.get("EVENT_LOG", "")  # optional CSV timeline: source transitions, state changes, arrival triggers
_fresh_lock = threading.Lock()
FRESH_PORT = int(os.environ.get("FRESH_PORT", "8731"))
FRESH_BIND = os.environ.get("FRESH_BIND", "127.0.0.1")
# Arrival endpoint: an external trigger (Tailwind garage door close, phone shortcut) forces HOME when the
# household is currently away. The hold covers the phone's slow Wi-Fi association after Android Auto.
ARRIVAL_TOKEN = os.environ.get("ARRIVAL_TOKEN", "").strip()
FORCED_HOME_SEC = float(os.environ.get("FORCED_HOME_SEC", "900"))
_force_home_until = 0.0
_wake = threading.Event()
_last_state = None
_started = time.time()
_last_ok = {"unifi": None, "life360": None}  # time of last successful poll per source
_extra_health = {}  # name -> {"last_ok", "ok", "poll_s"}: ESPHome devices and the robot bridge


def warn_once(key, msg):
    if key not in _warned:
        _warned.add(key)
        print(msg, flush=True)


def record(kind, person="", source="", value="", detail=""):
    """Append one row to EVENT_LOG. Never raises: measurement must not break presence."""
    if not EVENT_LOG:
        return
    try:
        with _fresh_lock:
            new = not os.path.exists(EVENT_LOG) or os.path.getsize(EVENT_LOG) == 0
            with open(EVENT_LOG, "a", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh)
                if new:
                    w.writerow(["ts", "kind", "person", "source", "value", "detail"])
                w.writerow([time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()), kind, person, source, value, detail])
    except Exception as e:
        warn_once("event-log", f"event log write failed: {type(e).__name__}: {e}")


def record_sources(detail, prev):
    """One row per source value that changed since the last poll; returns the new snapshot."""
    for person, srcs in detail.items():
        for src, val in srcs.items():
            key = (person, src)
            if key not in prev or prev[key] != val:
                record("source", person, src, "" if val is None else str(val).lower())
            prev[key] = val
    return prev


def people():
    raw = os.environ.get("PEOPLE")
    if raw:
        return json.loads(raw)
    p = {"name": "default", "unifi": PHONE}
    if L360_MEMBER:
        p["life360"] = L360_MEMBER
    return [p]


# ---------------------------------------------------------------- UniFi
def prom(query):
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=15) as r:
        return json.load(r)["data"]["result"]


def unifi_present(phone):
    try:
        # v1.6.1: an exporter with no client series at all (unpoller down, scrape failing) is unknown, not "away".
        # Before, the empty per-phone result returned False and stamped _last_ok, so the house read AWAY and
        # /health stayed green. _last_ok is stamped only when the exporter really answered with data.
        total = prom("count(unpoller_client_uptime_seconds)")
        if not total or float(total[0]["value"][1]) <= 0:
            warn_once("unifi-empty", "prometheus: no unpoller_client_uptime_seconds series; UniFi presence unknown")
            return None
        _last_ok["unifi"] = time.time()
        for lab in LABELS:
            q = f'count(unpoller_client_uptime_seconds{{{lab}=~"(?i){phone}"}})'
            res = prom(q)
            if res and float(res[0]["value"][1]) > 0:
                return True
        return False
    except Exception as e:
        print("prometheus error:", e, flush=True)
        return None


# ---------------------------------------------------------------- Life360
def haversine_m(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def notify(subject, body):
    """Email an alert (e.g. to Mailrise -> Discord). Never raises; returns True if sent."""
    if not NOTIFY_TO:
        return False
    try:
        host, _, port = NOTIFY_SMTP.partition(":")
        msg = EmailMessage()
        msg["From"], msg["To"], msg["Subject"] = NOTIFY_FROM, NOTIFY_TO, subject
        msg.set_content(body)
        with smtplib.SMTP(host or "localhost", int(port or 25), timeout=10) as smtp:
            smtp.send_message(msg)
        print("notify sent:", subject, flush=True)
        return True
    except Exception as e:
        print("notify failed:", type(e).__name__, str(e)[:100], flush=True)
        return False


_l360_fail = {"since": None, "alerted": 0.0, "down": False}


def _l360_ok():
    _last_ok["life360"] = time.time()
    f = _l360_fail
    if f["down"]:
        notify("DLS presence: Life360 recovered", "Life360 is responding again; presence is using both sources.")
    f["since"], f["alerted"], f["down"] = None, 0.0, False


def _l360_failed(name, detail):
    f = _l360_fail
    now = time.time()
    f["since"] = f["since"] or now
    if now - f["since"] >= L360_ALERT_AFTER and now - f["alerted"] >= 6 * 3600:
        sent = notify(f"DLS presence: Life360 failing ({name})",
                      f"Life360 has failed for {int((now - f['since']) / 60)} min: {name} {detail}\n"
                      "Presence continues on UniFi only. If this is Unauthorized/LoginError, put a fresh LIFE360_AUTH_TOKEN "
                      "cookie value in LIFE360_TOKEN in /etc/dls-presence.env and restart dls-presence.")
        f["alerted"] = now
        f["down"] = f["down"] or sent


_l360 = {"members": {}, "next": 0.0}
_l360_lock = threading.Lock()


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _l360_fetch():
    """One poll using the published life360 client as-is. Returns {key: {...}} keyed by lowercase first name and id."""
    import asyncio
    import aiohttp
    from life360 import Life360

    async def run():
        out = {}
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as s:
            api = Life360(s, max_retries=1, authorization=f"Bearer {L360_TOKEN}")
            for c in await api.get_circles():
                for m in await api.get_circle_members(c["id"]):
                    loc = m.get("location") or {}
                    ts = _num(loc.get("timestamp"))
                    if ts and ts > 1e12:
                        ts /= 1000.0
                    rec = {
                        "first": (m.get("firstName") or "").strip(),
                        "lat": _num(loc.get("latitude")), "lon": _num(loc.get("longitude")),
                        "ts": ts, "place": (loc.get("name") or "").strip(),
                        "acc": _num(loc.get("accuracy")),
                    }
                    out[str(m.get("id"))] = rec
                    if rec["first"]:
                        out[rec["first"].lower()] = rec
        return out

    return asyncio.run(run())


def _l360_refresh():
    now = time.time()
    with _l360_lock:
        if now < _l360["next"]:
            return
        _l360["next"] = now + L360_POLL  # provisional; adjusted on error
    try:
        data = _l360_fetch()
        with _l360_lock:
            _l360["members"] = data
        _l360_ok()
    except ImportError as e:
        warn_once("l360-imp", f"life360: package missing ({e}); run under the venv python. Source disabled")
        with _l360_lock:
            _l360["next"] = now + 3600
    except Exception as e:
        name = type(e).__name__
        wait = L360_POLL
        if name == "RateLimited":
            wait = max(L360_POLL, float(getattr(e, "retry_after", 0) or 0))
            print(f"life360: rate limited, backing off {int(wait)}s", flush=True)
        elif name in ("Unauthorized", "LoginError"):
            wait = 600
            print(f"life360: {name} - token expired/blocked? replace LIFE360_TOKEN. Retrying in 10 min", flush=True)
        else:
            print(f"life360 error: {name}: {str(e)[:120].replace(L360_TOKEN, '<tok>')}", flush=True)
        with _l360_lock:
            _l360["next"] = now + wait
            # keep last good data; staleness check below discards it if too old
        if name != "RateLimited":
            _l360_failed(name, str(e)[:120].replace(L360_TOKEN, "<tok>"))


def _l360_home(rec):
    """True/False for a member record, None if the fix is missing or stale."""
    if not rec or not rec.get("ts"):
        return None
    if time.time() - rec["ts"] > L360_STALE:
        return None
    if not L360_HOME_NAMES and (HOME_LAT is None or HOME_LON is None):
        warn_once("l360-home", "life360: set LIFE360_HOME_NAME (comma-separated place names) or HOME_LAT/HOME_LON; source disabled")
        return None
    if rec["place"].lower() in L360_HOME_NAMES:
        return True
    if HOME_LAT is not None and HOME_LON is not None and rec["lat"] is not None and rec["lon"] is not None:
        if haversine_m(rec["lat"], rec["lon"], float(HOME_LAT), float(HOME_LON)) <= HOME_RADIUS:
            return True
    return False


def life360_present(member):
    if not L360_TOKEN or not member:
        return None
    _l360_refresh()
    with _l360_lock:
        rec = _l360["members"].get(str(member).lower()) or _l360["members"].get(str(member))
    return _l360_home(rec)


# ---------------------------------------------------------------- combine
def person_state(p):
    srcs = {}
    if p.get("unifi"):
        srcs["unifi"] = unifi_present(p["unifi"])
    if p.get("life360"):
        srcs["life360"] = life360_present(p["life360"])
    known = [v for v in srcs.values() if v is not None]
    if not known:
        return None, srcs
    return any(known), srcs


def household():
    states, detail = [], {}
    for p in people():
        st, srcs = person_state(p)
        detail[p.get("name", "?")] = srcs
        if st is not None:
            states.append(st)
    if not states:
        return None, detail  # nothing reachable: keep last state
    return any(states), detail


# ---------------------------------------------------------------- freshness
def set_health(name, ok, poll_s, reason=None):
    h = _extra_health.setdefault(name, {"last_ok": None, "ok": False, "poll_s": poll_s})
    h["ok"], h["poll_s"] = ok, poll_s
    if ok:
        h["last_ok"] = time.time()
        h.pop("reason", None)
    elif reason:
        h["reason"] = reason
    else:
        h.pop("reason", None)


def freshness():
    """Per configured source: seconds since its last successful poll; stale if older than 3x its poll interval."""
    now = time.time()
    used = {
        "unifi": (any(p.get("unifi") for p in people()), POLL),
        "life360": (any(p.get("life360") for p in people()) and bool(L360_TOKEN), L360_POLL),
    }
    out = {}
    for name, (on, poll) in used.items():
        if not on:
            continue
        last = _last_ok[name]
        age = now - (last if last else _started)  # never polled yet: age counts from startup
        out[name] = {"last_ok_age_s": round(age), "poll_s": poll, "ever_ok": last is not None, "stale": age > 3 * poll}
    for name, h in list(_extra_health.items()):
        last = h["last_ok"]
        age = now - (last if last else _started)
        entry = {"last_ok_age_s": round(age), "poll_s": h["poll_s"], "ever_ok": last is not None,
                 "stale": (not h["ok"]) or age > 3 * h["poll_s"]}
        if h.get("reason"):
            entry["reason"] = h["reason"]
        out[name] = entry
    return out


# ---------------------------------------------------------------- status view
def _tail_events(n=25):
    """Most recent EVENT_LOG rows, newest first. Empty when logging is off."""
    if not EVENT_LOG or not os.path.exists(EVENT_LOG):
        return []
    try:
        with open(EVENT_LOG, newline="", encoding="utf-8") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            # read a bounded tail: the log is append-only and never rotated
            start = max(0, size - 65536)
            fh.seek(start)
            chunk = fh.read()
    except Exception:
        return []
    lines = chunk.splitlines()
    if start > 0 and lines:
        lines = lines[1:]                      # drop the partial first line
    rows = list(csv.reader(lines))
    if rows and rows[0] and rows[0][0] == "ts":
        hdr, body = rows[0], rows[1:]
    else:                                      # tail started past the header line
        hdr, body = ["ts", "kind", "person", "source", "value", "detail"], rows
    body = [r for r in body if len(r) == len(hdr)]   # drop a half-written trailing row
    out = [dict(zip(hdr, r)) for r in body[-n:]]
    out.reverse()
    return out


def _status_snapshot():
    now = time.time()
    srcs = freshness()
    return {
        "ok": not any(v["stale"] for v in srcs.values()),
        "state": _last_state,
        "forced_until": _force_home_until if _force_home_until > now else None,
        "sources": srcs,
        "events": _tail_events(25),
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now)),
    }


_STATUS_CSS = """
body{font:14px/1.45 -apple-system,Segoe UI,Roboto,sans-serif;background:#11141a;color:#e6e9ef;margin:0;padding:24px}
h1{font-size:18px;margin:0 0 4px}h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#8b95a7;margin:24px 0 8px}
.big{font-size:34px;font-weight:600;letter-spacing:.04em}.home{color:#67d08a}.away{color:#e0b45c}.unknown{color:#8b95a7}
table{border-collapse:collapse;width:100%;max-width:1000px}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #232833;font-variant-numeric:tabular-nums}
th{color:#8b95a7;font-weight:500;font-size:12px}.stale{color:#e06c75}.ok{color:#67d08a}.muted{color:#8b95a7}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
"""


def _esc(v):
    return (str(v) if v is not None else "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _status_html(snap):
    state = snap["state"] or "unknown"
    cls = {"HOME": "home", "AWAY": "away"}.get(state, "unknown")
    forced = ""
    if snap["forced_until"]:
        forced = f' <span class="muted">forced HOME for {int(snap["forced_until"] - time.time())}s</span>'
    src_rows = "".join(
        f'<tr><td>{_esc(name)}</td><td class="{"ok" if h["ever_ok"] and not h["stale"] else "stale"}">'
        f'{"ok" if h["ever_ok"] and not h["stale"] else ("stale" if h["ever_ok"] else "never")}</td>'
        f'<td>{h["last_ok_age_s"]}s</td><td>{h["poll_s"]}s</td></tr>'
        for name, h in sorted(snap["sources"].items())
    )
    ev_rows = "".join(
        f'<tr><td><code>{_esc(e.get("ts"))}</code></td><td>{_esc(e.get("kind"))}</td><td>{_esc(e.get("person"))}</td>'
        f'<td>{_esc(e.get("source"))}</td><td>{_esc(e.get("value"))}</td></tr>'
        for e in snap["events"]
    ) or '<tr><td colspan="5" class="muted">no events recorded (EVENT_LOG unset)</td></tr>'
    return f"""<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="15">
<title>DLS presence</title><style>{_STATUS_CSS}</style></head><body>
<h1>Daylight Lighting Scheduler — presence</h1>
<div class="big {cls}">{_esc(state)}</div>{forced}
<div class="muted">generated {_esc(snap["generated"])} · refreshes every 15s</div>
<h2>Sources</h2><table><tr><th>source</th><th>state</th><th>last ok</th><th>poll</th></tr>{src_rows}</table>
<h2>Recent events</h2><table><tr><th>time</th><th>kind</th><th>person</th><th>source</th><th>value</th></tr>{ev_rows}</table>
</body></html>"""


_esp_watcher = None  # v1.6.0: the running EsphomeWatcher, for GET /metrics


def _prom_esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def metrics_text(esp=None):
    """v1.6.0: Prometheus exposition for GET /metrics (lux, occupancy, sensor links, household state)."""
    esp = esp if esp is not None else _esp_watcher
    lines = ["# HELP dls_presence_up 1 while dls_presence is running.", "# TYPE dls_presence_up gauge",
             f'dls_presence_up{{version="{VERSION}"}} 1']
    if _last_state in ("HOME", "AWAY"):
        lines += ["# HELP dls_presence_home Household presence last sent to DLS (1 HOME, 0 AWAY).",
                  "# TYPE dls_presence_home gauge", f"dls_presence_home {int(_last_state == 'HOME')}"]
    if esp is not None:
        lines += esp.metrics()
    return "\n".join(lines) + "\n"


class _FreshHandler(BaseHTTPRequestHandler):
    def _token_ok(self):
        if not ARRIVAL_TOKEN:
            return False
        got = self.headers.get("X-Arrival-Token", "")
        if not got:
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got = (q.get("token") or [""])[0]
        return got == ARRIVAL_TOKEN

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/health", "/freshness"):
            srcs = freshness()
            stale = any(s["stale"] for s in srcs.values())
            self._json(503 if stale else 200, {"ok": not stale, "sources": srcs})
            return
        if path == "/state":
            if not self._token_ok():
                self._json(403, {"ok": False, "error": "forbidden"})
                return
            self._json(200, {"ok": True, "state": _last_state,
                             "forced_until": _force_home_until if _force_home_until > time.time() else None})
            return
        if path == "/status.json":
            self._json(200, _status_snapshot())
            return
        if path == "/metrics":
            body = metrics_text().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.rstrip("/") == "/status":
            body = _status_html(_status_snapshot()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        global _force_home_until
        if self.path.split("?")[0] != "/arrival":
            self.send_error(404)
            return
        if not self._token_ok():
            self._json(403, {"ok": False, "error": "forbidden"})
            return
        now = time.time()
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        except Exception:
            body = {}
        if _last_state == "HOME":
            record("trigger", source=self.client_address[0], value="noop", detail=json.dumps(body))
            self._json(200, {"ok": True, "action": "noop", "state": "HOME"})
            return
        _force_home_until = now + FORCED_HOME_SEC
        _wake.set()
        print(time.strftime("%F %T"), f"arrival trigger: forced HOME for {FORCED_HOME_SEC:g}s", flush=True)
        record("trigger", source=self.client_address[0], value="forced", detail=json.dumps(body))
        self._json(200, {"ok": True, "action": "forced", "until": _force_home_until})

    def log_message(self, *args):
        pass


def start_freshness():
    if FRESH_PORT <= 0:
        return
    srv = ThreadingHTTPServer((FRESH_BIND, FRESH_PORT), _FreshHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"freshness endpoint: http://{FRESH_BIND}:{FRESH_PORT}/health  arrival: POST /arrival", flush=True)


# ---------------------------------------------------------------- EA-1
def send(state):
    with socket.create_connection((HOST, PORT), timeout=10) as s:
        s.sendall(f"PRESENCE {state} {TOKEN}\r\n".encode())
        s.settimeout(5)
        try:
            return s.recv(64).decode().strip()
        except socket.timeout:
            return "(no reply)"


def ea1_batch(lines):
    """Write all lines in one sendall, then read replies until DLS closes. Raises OSError on connection failure."""
    payload = "".join(line + "\r\n" for line in lines).encode()
    buf = b""
    with socket.create_connection((HOST, PORT), timeout=10) as s:
        s.sendall(payload)
        s.settimeout(5)
        while True:
            # a complete reply (one newline-terminated line per line sent) ends the read even if the peer
            # keeps the socket open, so a driver that does not close promptly costs no 5 s timeout
            if buf.endswith(b"\n") and sum(1 for x in buf.split(b"\n") if x.strip()) >= len(lines):
                break
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
    if buf and not buf.endswith(b"\n"):
        raise OSError("truncated reply")
    replies = [x.strip() for x in buf.decode(errors="replace").split("\n") if x.strip()]
    if len(replies) < len(lines):
        raise OSError(f"short reply ({len(replies)} of {len(lines)})")
    return replies


# ---------------------------------------------------------------- per-room config
class RoomCfg:
    def __init__(self, key, sources, stuck_min, esp, robot, night=None):
        self.key = key
        # v1.6.2: optional night rule (from_min, to_min, stuck_min): inside the window an occupancy sensor that
        # reads 1 with no motion (PIR or tracking) for stuck_min counts as vacant. Static mmWave alone held the
        # Living Room "occupied" all night on 2026-11-26/27 with nobody there.
        self.night = night
        self.sources = list(sources)       # priority order, allow-list
        self.stuck_min = float(stuck_min)  # 0 = never time out
        self.esp = list(esp)               # [{"host", "key", "entity", "pir"}]
        self.robot = list(robot)           # robot room names mapped to this room


def _hhmm(v):
    """v1.6.2: "HH:MM" -> minutes after midnight."""
    h, m = str(v).split(":")
    h, m = int(h), int(m)
    if not (0 <= h < 24 and 0 <= m < 60):
        raise ValueError(f"bad time {v!r}")
    return h * 60 + m


def in_night(cfg, now):
    """v1.6.2: is local time inside the room's night window (may wrap midnight)?"""
    if not getattr(cfg, "night", None):
        return False
    lt = time.localtime(now)
    m = lt.tm_hour * 60 + lt.tm_min
    fm, tm, _ = cfg.night
    return (fm <= m < tm) if fm <= tm else (m >= fm or m < tm)


def load_rooms(path, log=print):
    """Rooms JSON -> {key: RoomCfg}. Missing file or no rooms = {} (no OCC lines). Bad rooms are skipped with a log line."""
    if not path or not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if not isinstance(doc, dict):
        log("rooms: root JSON must be an object")
        return {}
    rooms_obj = doc.get("rooms")
    if rooms_obj is None:
        return {}
    if not isinstance(rooms_obj, dict):
        log("rooms: 'rooms' must be an object")
        return {}
    out = {}
    for key, c in rooms_obj.items():
        if not isinstance(key, str) or not KEY_RE.match(key):
            log(f"rooms: skipped key {key!r} (1-32 chars of A-Z a-z 0-9 _ -)")
            continue
        if key.lower() in {k.lower() for k in out}:
            log(f"rooms: skipped duplicate key {key!r}")
            continue
        if not isinstance(c, dict):
            log(f"rooms: skipped {key!r} (entry must be an object)")
            continue
        src = c.get("sources", list(ALL_SOURCES))
        if (not isinstance(src, list)
                or any(not isinstance(s, str) or s not in ALL_SOURCES for s in src)
                or len(set(src)) != len(src)):
            log(f"rooms: {key}.sources invalid, using default")
            src = list(ALL_SOURCES)
        stuck = c.get("stuckOnMin", STUCK_ON_MIN)
        if not isinstance(stuck, (int, float)) or isinstance(stuck, bool) or stuck < 0:
            log(f"rooms: {key}.stuckOnMin invalid, using default")
            stuck = STUCK_ON_MIN
        raw_esp = c.get("esp")
        esp = []
        if raw_esp is not None:
            if not isinstance(raw_esp, list):
                log(f"rooms: {key}.esp invalid, ignoring")
            else:
                for d in raw_esp:
                    if (isinstance(d, dict) and isinstance(d.get("host"), str) and d["host"].strip()
                            and isinstance(d.get("entity"), str) and d["entity"].strip()
                            and (d.get("key") is None or isinstance(d.get("key"), str))
                            and (d.get("pir") is None or isinstance(d.get("pir"), str))
                            and (d.get("track") is None or isinstance(d.get("track"), str))):
                        esp.append(d)
                    else:
                        log(f"rooms: {key}.esp entry invalid, ignored")
        raw_robot = c.get("robot")
        robot = []
        if raw_robot is not None:
            if isinstance(raw_robot, list) and all(isinstance(r, str) and r.strip() for r in raw_robot):
                robot = list(raw_robot)
            else:
                log(f"rooms: {key}.robot invalid, ignoring")
        has_esp = "esp" in src and bool(esp)
        has_robot = "robot" in src and bool(robot)
        if not src or (("esp" in c or "robot" in c) and not (has_esp or has_robot)):
            log(f"rooms: skipped {key!r} (no usable sources)")
            continue
        night = None
        raw_night = c.get("night")
        if raw_night is not None:
            try:
                fm, tm = _hhmm(raw_night["from"]), _hhmm(raw_night["to"])
                ns = float(raw_night.get("stuckOnMin", 10))
                if ns <= 0:
                    raise ValueError("stuckOnMin must be > 0")
                night = (fm, tm, ns)
            except Exception as e:
                log(f"rooms: {key}.night invalid ({e}), ignored")
        out[key] = RoomCfg(key, src, stuck, esp, robot, night)
    return out


# ---------------------------------------------------------------- room state
class RoomTracker:
    """Combines one room's sources into (state, src). Section 3 (src names), 9.1 (stuck), 9.2 (unknown), 9 (dock)."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.on_since = None
        self.evidence = None
        self.tripped = False
        self.last_esp = None
        self.last_pir = None
        self.last_robot = None
        self.unknown_since = None
        self.last_out = None

    def evaluate(self, now, esp, pir, robot, docked):
        """esp, pir, robot: True/False/None. robot is None when the room does not use it. Returns a dict."""
        stuck_event = False
        if esp is True and self.last_esp is not True:
            self.on_since = now
        if esp is not True:
            self.on_since = None
        if esp is False:
            self.tripped = False
        # other evidence (PIR rising edge, any robot edge in this room) restores a stuck sensor and resets the stuck timer
        if pir is True and self.last_pir is not True:
            self.evidence, self.tripped = now, False
        elif pir is True and in_night(self.cfg, now):
            self.evidence = now   # v1.6.2: at night, ongoing motion/tracking keeps the stuck timer reset
        if robot is not None and self.last_robot is not None and robot != self.last_robot:
            self.evidence, self.tripped = now, False
        self.last_esp = esp
        if pir is not None:
            self.last_pir = pir
        if robot is not None:
            self.last_robot = robot

        night = in_night(self.cfg, now)
        limit = self.cfg.night[2] if night else self.cfg.stuck_min   # v1.6.2
        if limit > 0 and esp is True and not self.tripped and self.on_since is not None:
            base = max(self.on_since, self.evidence or 0.0)
            if now - base >= limit * 60:
                self.tripped = True
                stuck_event = True
        esp_eff = None if self.tripped else esp
        rob_eff = robot if "robot" in self.cfg.sources else None
        values = {"esp": esp_eff, "robot": rob_eff}
        active = [s for s in self.cfg.sources if values.get(s) is True]

        if active:
            out = (1, ",".join(active))
            self.unknown_since = None
        else:
            esp_unknown = ("esp" in self.cfg.sources and bool(self.cfg.esp)
                           and esp_eff is None and not self.tripped)
            none_all = esp_eff is None and rob_eff is None and not self.tripped
            unknown = esp_unknown or none_all
            if unknown:
                if self.unknown_since is None:
                    self.unknown_since = now
            else:
                self.unknown_since = None
            if unknown and now - self.unknown_since < SRC_UNKNOWN_SEC:
                out = self.last_out or (0, "unknown")  # sources unknown but not yet 3 min: hold last state
            elif self.tripped:
                out = (0, "stuck")
            elif esp_unknown:
                out = (0, "unknown")
            elif docked and "robot" in self.cfg.sources:
                out = (0, "dock")
            elif none_all:
                out = (0, "unknown")
            else:
                out = (0, "clear")
        self.last_out = out
        return {"state": out[0], "src": out[1], "stuck": stuck_event, "night": night}


def robot_state_url(url):
    """ROBOT_URL may be the bridge base URL or the full /state URL. The bridge serves exactly GET /state."""
    u = urllib.parse.urlsplit(url.strip())
    path = u.path.rstrip("/")
    if not path.endswith("/state"):
        path += "/state"
    return urllib.parse.urlunsplit((u.scheme, u.netloc, path, "", ""))


def parse_robot_state(body):
    """Bridge /state JSON -> (state, room name or None). ValueError when the bridge has no fresh device poll."""
    if not isinstance(body, dict):
        raise ValueError("bridge /state is not a JSON object: %.200r" % (body,))
    age = body.get("last_success_age_s")
    if body.get("state") is None or not isinstance(age, (int, float)) or isinstance(age, bool) or age >= ROBOT_STALE:
        # Say why, with the raw values (truncated), so the log shows a bridge that is still starting
        # (state None, age None) apart from a stale poll (age >= ROBOT_STALE) or a changed payload.
        raise ValueError("bridge has no fresh robot status: state=%.200r last_success_age_s=%.200r" % (body.get("state"), age))
    cr = body.get("current_room")
    name = cr.get("name") if isinstance(cr, dict) else None
    return str(body["state"]), (name.strip() if isinstance(name, str) and name.strip() else None)


class RobotSource:
    """Robot as seen by the poller. Only a moving robot counts as an occupant: docked, charging, paused, error, idle or no good poll for ROBOT_STALE counts as docked (section 9 rule 2)."""

    def __init__(self, started=None):
        self.started = time.time() if started is None else started
        self.last_ok = None
        self.state = ""
        self.room = None
        self.lock = threading.Lock()

    def observe(self, now, state, room):
        with self.lock:
            self.last_ok, self.state, self.room = now, str(state or ""), room

    def docked(self, now):
        with self.lock:
            last, st = self.last_ok, self.state.lower()
        if last is None:
            return now - self.started >= ROBOT_STALE
        if now - last >= ROBOT_STALE:
            return True
        if st == "charger_disconnected":
            return True            # off the dock and not moving: not an occupant
        if any(w in st for w in ("dock", "charg", "emptying", "wash", "drying")):
            return True
        # only a moving robot is an occupant (paused, error, idle and stranded robots must not latch a room on)
        return not any(w in st for w in ("clean", "return", "going", "mopping", "segment"))

    def room_value(self, now, names):
        """True if the robot is in one of `names`; False if docked or elsewhere; None only before the first poll."""
        with self.lock:
            last, room = self.last_ok, self.room
        if last is None and now - self.started < ROBOT_STALE:
            return None
        if self.docked(now):
            return False
        return bool(room) and str(room).lower() in {str(n).lower() for n in names}


class RobotWatcher:
    def __init__(self, url, poll, robot, log=print, fetch=None, sleep=time.sleep):
        self.url, self.poll, self.robot, self.log = url, poll, robot, log
        self.fetch = fetch or self._default_fetch
        self.sleep = sleep

    def _default_fetch(self):
        with urllib.request.urlopen(self.url, timeout=10) as r:
            return json.load(r)

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        warned = False
        had_ok = False
        backoff = min(1.0, self.poll) if self.poll > 0 else 0.0
        while True:
            try:
                body = self.fetch()
                state, room = parse_robot_state(body)
                self.robot.observe(time.time(), state, room)
                set_health("robot", True, self.poll)
                had_ok = True
                warned = False
            except Exception as e:
                set_health("robot", False, self.poll)
                if not warned:
                    detail = f" ({str(e)[:200]})" if isinstance(e, ValueError) and str(e) else ""
                    prefix = "waiting for first poll: " if not had_ok else ""
                    self.log(f"robot bridge: {prefix}{type(e).__name__}{detail}; robot treated as docked until it answers")
                    warned = True
            if had_ok:
                wait = self.poll
            else:
                wait = backoff
                backoff = min(self.poll, max(backoff * 2, 1.0))
            self.sleep(wait)


class EsphomeWatcher:
    """One asyncio thread per ESPHome device (native API, push). Lost connection = None (unknown)."""

    def __init__(self, room_esp, port=ESPHOME_PORT, log=print):
        self.port, self.log = port, log
        self.lock = threading.Lock()
        self.state = {}      # (host, object_id) -> True / False / None
        self.lux = {}        # v1.6.0: (host, object_id) -> float lux / None (sensors with unit "lx"), for /metrics only
        self.up = {}         # v1.6.0: host -> True while the native API connection is up
        self.room_devs = {}  # roomKey -> [(host, entity, pir)]
        self.room_tracks = {}  # v1.6.2: roomKey -> [(host, track entity)], combined with PIR as motion evidence
        self.devs = {}       # host -> {"key": str, "objs": set}
        for key, devs in room_esp.items():
            self.room_devs[key] = []
            for d in devs:
                host = d["host"]
                self.room_devs[key].append((host, d["entity"], d.get("pir")))
                dev = self.devs.setdefault(host, {"key": d.get("key") or "", "objs": set()})
                dev["objs"].add(d["entity"])
                if d.get("pir"):
                    dev["objs"].add(d["pir"])
                if d.get("track"):
                    dev["objs"].add(d["track"])
                    self.room_tracks.setdefault(key, []).append((host, d["track"]))

    def start(self):
        import asyncio
        for host, dev in self.devs.items():
            threading.Thread(target=lambda h=host, d=dev: asyncio.run(self._device_loop(h, d)), daemon=True).start()

    def _set_all(self, host, value):
        with self.lock:
            for (h, oid) in list(self.state):
                if h == host:
                    self.state[(h, oid)] = value
            for (h, oid) in list(self.lux):
                if h == host:
                    self.lux[(h, oid)] = None
            self.up[host] = False

    async def _device_loop(self, host, dev):
        import asyncio
        try:
            import aioesphomeapi  # lazy: only needed when a room has esp devices
        except ImportError:
            self.log(f"esp {host}: aioesphomeapi not installed; this device stays unknown")
            set_health(f"esp:{host}", False, 60)
            return
        delay = 5
        while True:
            cli = None
            failed = False
            try:
                cli = aioesphomeapi.APIClient(host, self.port, "", noise_psk=dev["key"] or None)
                await cli.connect(login=True)
                entities, _services = await cli.list_entities_services()
                keys = {e.key: e.object_id for e in entities
                        if type(e).__name__ == "BinarySensorInfo" and e.object_id in dev["objs"]}
                missing = dev["objs"] - set(keys.values())
                missing_reason = None
                if missing:
                    have = sorted(e.object_id for e in entities if type(e).__name__ == "BinarySensorInfo")
                    self.log(f"esp {host}: no binary_sensor {sorted(missing)}; device has {have}")
                    missing_reason = f"esp:{host} missing binary_sensor: {', '.join(sorted(missing))}"

                # v1.6.0: illuminance sensors (unit lx) are read too, only for the Prometheus /metrics endpoint
                lux_keys = {e.key: e.object_id for e in entities
                            if type(e).__name__ == "SensorInfo" and getattr(e, "unit_of_measurement", "") == "lx"}

                def on_state(st, keys=keys, lux_keys=lux_keys):
                    k = getattr(st, "key", None)
                    loid = lux_keys.get(k)
                    if loid is not None:
                        v = getattr(st, "state", None)
                        ok = not getattr(st, "missing_state", False) and isinstance(v, (int, float)) and math.isfinite(v)
                        with self.lock:
                            self.lux[(host, loid)] = float(v) if ok else None
                        return
                    oid = keys.get(k)
                    if oid is None:
                        return
                    val = None if getattr(st, "missing_state", False) else bool(getattr(st, "state", False))
                    with self.lock:
                        self.state[(host, oid)] = val

                with self.lock:
                    for oid in dev["objs"]:
                        self.state.setdefault((host, oid), None)
                    for loid in lux_keys.values():
                        self.lux.setdefault((host, loid), None)
                    self.up[host] = True
                res = cli.subscribe_states(on_state)
                if asyncio.iscoroutine(res):
                    await res
                delay = 5
                while cli.is_connected:
                    set_health(f"esp:{host}", not missing, 60, reason=missing_reason)
                    await asyncio.sleep(1)
                raise ConnectionError("disconnected")
            except Exception as e:
                failed = True
                self._set_all(host, None)
                set_health(f"esp:{host}", False, 60)
                self.log(f"esp {host}: {type(e).__name__}; retry in {delay} s")
            finally:
                if cli is not None:
                    try:
                        await cli.disconnect()
                    except Exception:
                        pass
            if failed:
                await asyncio.sleep(delay)
                delay = min(delay * 2, 60)

    def readings(self):
        """{roomKey: (esp, pir)}: any device True = True; all unknown = None; else False."""
        def combine(vals):
            if any(v is True for v in vals):
                return True
            if all(v is None for v in vals):
                return None
            return False

        out = {}
        with self.lock:
            for key, devs in self.room_devs.items():
                esp = combine([self.state.get((h, e)) for h, e, _p in devs])
                pir_vals = [self.state.get((h, p)) for h, _e, p in devs if p]
                pir_vals += [self.state.get(t) for t in self.room_tracks.get(key, [])]   # v1.6.2
                out[key] = (esp, combine(pir_vals))
        return out

    def metrics(self):
        """v1.6.0: Prometheus text lines. Unknown values (no connection, missing state) are left out."""
        def lbl(**kw):
            return "{" + ",".join(f'{k}="{_prom_esc(v)}"' for k, v in kw.items()) + "}"

        lines = [
            "# HELP dls_presence_lux ESPHome illuminance sensor reading (lx) per room and sensor.",
            "# TYPE dls_presence_lux gauge",
        ]
        occ, pir, room_occ = [], [], []
        with self.lock:
            for room, devs in sorted(self.room_devs.items()):
                for host in sorted({h for h, _e, _p in devs}):
                    for (h, oid), v in sorted(self.lux.items()):
                        if h == host and v is not None:
                            lines.append(f"dls_presence_lux{lbl(room=room, sensor=host, entity=oid)} {v:g}")
                for host, ent, p in devs:
                    v = self.state.get((host, ent))
                    if v is not None:
                        occ.append(f"dls_presence_occupancy{lbl(room=room, sensor=host, entity=ent)} {int(v)}")
                    if p:
                        v = self.state.get((host, p))
                        if v is not None:
                            pir.append(f"dls_presence_motion{lbl(room=room, sensor=host, entity=p)} {int(v)}")
            up = sorted(self.up.items())
        for room, (esp, _pir) in sorted(self.readings().items()):
            if esp is not None:
                room_occ.append(f"dls_presence_room_occupancy{lbl(room=room)} {int(esp)}")
        lines += ["# HELP dls_presence_occupancy ESPHome occupancy binary_sensor (1 occupied) per room and sensor.",
                  "# TYPE dls_presence_occupancy gauge"] + occ
        lines += ["# HELP dls_presence_motion ESPHome PIR binary_sensor (1 motion) per room and sensor.",
                  "# TYPE dls_presence_motion gauge"] + pir
        lines += ["# HELP dls_presence_room_occupancy ESPHome room occupancy as combined for DLS (any sensor 1).",
                  "# TYPE dls_presence_room_occupancy gauge"] + room_occ
        lines += ["# HELP dls_presence_sensor_up 1 while the ESPHome native API connection is up.",
                  "# TYPE dls_presence_sensor_up gauge"]
        lines += [f"dls_presence_sensor_up{lbl(sensor=h)} {int(bool(v))}" for h, v in up]
        return lines


# ---------------------------------------------------------------- OCC poller
class Poller:
    """Per-room OCC lines to DLS. Pure logic: sources, transport, notify, clock and log are injected."""

    def __init__(self, rooms, *, token, transport, notify, log=print, clock=time.time,
                 esp=None, robot=None, occ_repeat=None):
        self.rooms = rooms
        self.trackers = {k: RoomTracker(c) for k, c in rooms.items()}
        self.token, self.transport, self.notify, self.log, self.clock = token, transport, notify, log, clock
        self.esp, self.robot = esp, robot
        self.occ_repeat = OCC_REPEAT_SEC if occ_repeat is None else occ_repeat
        self.boot_id = int(clock())
        self.presence = None
        self.presence_pending = False
        self._presence_lock = threading.Lock()
        self.sent = {}  # roomKey -> (state, src) last accepted by DLS
        self.need_snapshot = True
        self.last_snapshot = None
        self.next_try = 0.0
        self.fail_idx = 0
        self.link_since = None      # first failed send of the current outage
        self.link_alerted = 0.0     # last time the outage email went out
        self.link_down = False      # an outage email was sent and not yet recovered
        self.auth_since = None
        self.auth_alerted = False
        self._logged = set()

    def set_presence(self, state):
        with self._presence_lock:
            if state != self.presence:
                self.presence, self.presence_pending = state, True

    def _once(self, key, msg):
        if key not in self._logged:
            self._logged.add(key)
            self.log(msg)

    def _pline(self, state=None):
        if state is None:
            with self._presence_lock:
                state = self.presence
        return f"PRESENCE {state} {self.token}"

    def _occ(self, key, out):
        return f"OCC {key} {out[0]} {out[1]} {self.token}"

    def _snapshot_lines(self, cur, presence=None):
        lines = [self._pline(presence)] if presence is not None else []
        lines.append(f"HELLO {self.boot_id} {len(cur)} {self.token}")
        lines += [self._occ(k, cur[k]) for k in self.trackers]
        return lines

    def _evaluate(self, now):
        readings = self.esp.readings() if self.esp is not None else {}
        cur = {}
        for key, tr in self.trackers.items():
            cfg = tr.cfg
            esp, pir = readings.get(key, (None, None))
            if "esp" not in cfg.sources:
                esp = pir = None
            rob, docked = None, False
            if "robot" in cfg.sources and self.robot is not None:
                rob = self.robot.room_value(now, cfg.robot)
                docked = self.robot.docked(now)
            r = tr.evaluate(now, esp, pir, rob, docked)
            if r["stuck"] and r.get("night"):   # v1.6.2: expected at night, log only (no alert)
                self.log(f"{key}: night rule, esp read 1 for {cfg.night[2]:g} min with no motion; sending 0 stuck")
            elif r["stuck"]:
                self.log(f"{key}: esp read 1 for {cfg.stuck_min:g} min with no motion; sending 0 stuck")
                self.notify("DLS presence: sensor stuck on",
                            f"{key}: occupancy sensor read 1 for {cfg.stuck_min:g} min with no PIR motion or other "
                            "activity. Treated as vacant until it reads 0 again or motion is seen.")
            cur[key] = (r["state"], r["src"])
        return cur

    def tick(self, now=None):
        now = self.clock() if now is None else now
        if not self.trackers:  # no rooms: presence only, same as v1.3.0
            with self._presence_lock:
                pending, pres = self.presence_pending, self.presence
            if pending and now >= self.next_try:
                self._send(now, [self._pline(pres)], {}, False, [], pres)
            return
        cur = self._evaluate(now)
        if now < self.next_try:
            return
        snapshot = self.need_snapshot or self.last_snapshot is None or now - self.last_snapshot >= self.occ_repeat
        if snapshot:
            with self._presence_lock:
                pres = self.presence
            self._send(now, self._snapshot_lines(cur, pres), cur, True, list(cur), pres)
            return
        changed = [k for k in cur if cur[k] != self.sent.get(k)]
        with self._presence_lock:
            pending, pres = self.presence_pending, self.presence
        sent_pres = pres if pending else None
        lines = [self._pline(pres)] if pending else []
        lines += [self._occ(k, cur[k]) for k in changed]
        if lines:
            self._send(now, lines, cur, False, changed, sent_pres)

    def _fail(self, now, why):
        self.need_snapshot = True
        wait = BACKOFF[min(self.fail_idx, len(BACKOFF) - 1)]
        self.fail_idx += 1
        self.next_try = now + wait
        self.log(f"DLS send {why}; retry in {wait} s with a full snapshot")
        self.link_since = self.link_since or now
        if now - self.link_since >= DLS_ALERT_AFTER and now - self.link_alerted >= 6 * 3600:
            sent = self.notify(
                "DLS presence: link down",
                f"DLS has refused or not accepted presence lines for {int((now - self.link_since) / 60)} min "
                f"({why}) at {HOST or 'EA-1'}:{PORT}.\n"
                "DLS keeps the last presence and per-room state, then shows 'Presence feed lost' after 180 s. "
                "Check the EA-1 is up and the DLS driver is running: the presence listener only opens after a clean "
                "driver load, and a load error leaves it loaded but dead (see the driver's Status property).")
            self.link_alerted = now
            self.link_down = self.link_down or sent

    def _send(self, now, lines, cur, snapshot, changed, sent_presence=None):
        try:
            replies = self.transport(lines)
        except Exception as e:
            return self._fail(now, f"failed ({type(e).__name__})")
        if len(replies) < len(lines):
            return self._fail(now, f"short reply ({len(replies)} of {len(lines)})")
        self.fail_idx = 0
        if self.link_down:
            self.notify("DLS presence: link recovered",
                        f"DLS is accepting presence lines again after {int((now - (self.link_since or now)) / 60)} min down.")
        self.link_since, self.link_alerted, self.link_down = None, 0.0, False
        auth = resync = False
        for line, rep in zip(lines, replies):
            head = line.split(" ", 1)[0]
            rep = rep.strip()
            key = line.split()[1] if head == "OCC" else None
            if rep == "OK":
                continue
            if rep == "OK RESYNC":
                resync = True
            elif rep == "ERR AUTH":
                auth = True
            elif rep == "ERR ROOM":
                self._once(f"room:{key}", f"DLS: room key {key} is not in Rooms JSON or has no presence")
            elif head == "OCC" and rep == "ERR":
                self._once("old", "DLS driver too old: plain ERR to OCC (needs DLS v1.11.0+); PRESENCE only")
            else:
                self._once(f"err:{head}:{rep}", f"DLS replied {rep!r} to {head}")
        if auth:
            self.need_snapshot = True
            self.next_try = now + AUTH_RETRY_SEC
            self._once("auth", "DLS rejected the Presence Token (ERR AUTH); retrying every 60 s")
            self.auth_since = self.auth_since or now
            if now - self.auth_since >= AUTH_ALERT_AFTER and not self.auth_alerted:
                self.auth_alerted = True
                self.notify("DLS presence: token rejected",
                            "DLS has rejected the Presence Token for 30 min. Check DLS_TOKEN against the driver's "
                            "Presence Token property. Room occupancy is not reaching DLS.")
            return
        self.auth_since, self.auth_alerted = None, False
        if sent_presence is not None and any(line.startswith("PRESENCE ") for line in lines):
            with self._presence_lock:
                if self.presence == sent_presence:
                    self.presence_pending = False
        if snapshot:
            self.need_snapshot = False
            self.last_snapshot = now
            self.sent.update(cur)
        else:
            for k in changed:
                self.sent[k] = cur[k]
        if resync and not snapshot and self.trackers:
            self.need_snapshot = True
            with self._presence_lock:
                pres = self.presence
            self._send(now, self._snapshot_lines(cur, pres), cur, True, list(cur), pres)


# ---------------------------------------------------------------- main
def presence_loop(poller):
    """Household presence (v1.3.0 rules) on its own thread, so a slow Prometheus or Life360 call never delays OCC lines."""
    global _force_home_until, _last_state
    last, away_since = None, None
    prev_detail = {}
    while True:
        try:
            now = time.time()
            src_home, detail = household()
            record_sources(detail, prev_detail)
            forced = now < _force_home_until
            if src_home is True:
                _force_home_until = 0.0               # a real source agrees; drop the hold
                forced = False
            here = True if forced else src_home
            if here is None:
                print("no presence source reachable:", detail, flush=True)
            else:
                if here:
                    away_since = None
                    want = "HOME"
                else:
                    away_since = away_since or now
                    want = "AWAY" if now - away_since >= AWAY_AFTER else last
                if want and want != last:
                    poller.set_presence(want)
                    print(time.strftime("%F %T"), "->", want, detail, flush=True)
                    last = want
                    _last_state = want
                    record("state", value=want, detail=json.dumps({"sources": detail, "forced": forced}))
        except Exception as e:
            print(f"presence loop: {type(e).__name__}: {e}", flush=True)
        _wake.wait(POLL)
        _wake.clear()


def run_rooms(rooms):
    global _esp_watcher
    esp_rooms = {k: c.esp for k, c in rooms.items() if c.esp}
    esp = EsphomeWatcher(esp_rooms, log=print) if esp_rooms else None
    if esp is not None:
        esp.start()
    _esp_watcher = esp
    robot = None
    if ROBOT_URL and any("robot" in c.sources and c.robot for c in rooms.values()):
        robot = RobotSource()
        RobotWatcher(robot_state_url(ROBOT_URL), ROBOT_POLL, robot).start()
    poller = Poller(rooms, token=TOKEN, transport=ea1_batch, notify=notify, log=print, esp=esp, robot=robot)
    threading.Thread(target=presence_loop, args=(poller,), daemon=True).start()
    while True:
        poller.tick()
        time.sleep(TICK_SEC)


def discover():
    for q in ('{__name__=~"unpoller_client.*"}',):
        res = prom(q)
        seen = set()
        for r in res:
            m = r["metric"]
            key = (m.get("name"), m.get("hostname"), m.get("mac"))
            if PHONE.lower() in " ".join(str(v) for v in m.values()).lower() and key not in seen:
                seen.add(key); print(m)
        print(f"{len(seen)} matching client(s)")


def esp_check():
    """--esp-check: connect to every configured ESPHome device and print its binary_sensor object_ids and states."""
    rooms = load_rooms(ROOMS_FILE)
    devs = [(name, d) for name, c in rooms.items() for d in (c.esp or [])]
    if not devs:
        print(f"no esp devices configured in {ROOMS_FILE}")
        return
    import asyncio
    try:
        import aioesphomeapi  # noqa: F401
    except ImportError:
        print("aioesphomeapi is not installed: pip install -r requirements.txt")
        return

    async def one(name, d):
        import aioesphomeapi
        host = d["host"]
        cli = aioesphomeapi.APIClient(host, ESPHOME_PORT, "", noise_psk=d.get("key") or None)
        states = {}
        try:
            await cli.connect(login=True)
            ents, _ = await cli.list_entities_services()
            bins = [e for e in ents if type(e).__name__ == "BinarySensorInfo"]
            print(f"{name} {host}: " + ", ".join(sorted(e.object_id for e in bins)))
            want = {d.get("entity"), d.get("pir")} - {None}

            def on_state(st):
                oid = {e.key: e.object_id for e in bins}.get(getattr(st, "key", None))
                if oid:
                    states[oid] = getattr(st, "state", None) if not getattr(st, "missing_state", False) else None

            res = cli.subscribe_states(on_state)
            if asyncio.iscoroutine(res):
                await res
            await asyncio.sleep(2)
            for oid in sorted(want):
                print(f"  {oid}: {states.get(oid, 'no state received')}")
        except Exception as e:
            print(f"{name} {host}: {type(e).__name__}: {e}")
        finally:
            try:
                await cli.disconnect()
            except Exception:
                pass

    async def run():
        for name, d in devs:
            await one(name, d)

    asyncio.run(run())


def l360_report():
    if not L360_TOKEN:
        sys.exit("LIFE360_TOKEN not set")
    for k, rec in _l360_fetch().items():
        if k.isdigit() or "-" in k:
            continue  # skip the id-keyed duplicates
        age = (time.time() - rec["ts"]) / 60 if rec["ts"] else None
        print(f"{rec['first']}: place={rec['place'] or '(none)'} fix_age_min={age if age is None else round(age, 1)} "
              f"acc_m={rec['acc']} home={_l360_home(rec)}")


def main():
    if "--notify-test" in sys.argv:
        ok = notify("DLS presence: test alert", "Test from dls_presence.py --notify-test.")
        sys.exit(0 if ok else "no alert sent: set NOTIFY_TO (and check NOTIFY_SMTP)")
    if "--discover" in sys.argv:
        return discover()
    if "--l360" in sys.argv:
        return l360_report()
    if "--esp-check" in sys.argv:
        return esp_check()
    if "--status" in sys.argv:
        here, detail = household()
        print("household:", {True: "HOME", False: "AWAY", None: "UNKNOWN"}[here], detail)
        return
    if not TOKEN:
        sys.exit("DLS_TOKEN is not set: export it in /etc/dls-presence.env (must match the driver's Presence Token)")
    if not HOST:
        sys.exit("set EA1_HOST to the EA-1 IP address")
    start_freshness()
    print(f"dls_presence v{VERSION} starting", flush=True)
    rooms = load_rooms(ROOMS_FILE)
    if rooms:
        print(f"per-room occupancy: {len(rooms)} room(s) from {ROOMS_FILE}", flush=True)
        return run_rooms(rooms)
    print("no rooms file: household PRESENCE only (v1.3.0 behaviour)", flush=True)
    global _last_state
    last_sent, away_since = None, None
    prev_detail = {}
    while True:
        here, detail = household()
        record_sources(detail, prev_detail)
        if here is None:
            print("no presence source reachable:", detail, flush=True)
            time.sleep(POLL)
            continue
        now = time.time()
        if here:
            away_since = None
            want = "HOME"
        else:
            away_since = away_since or now
            want = "AWAY" if now - away_since >= AWAY_AFTER else last_sent
        if want and want != last_sent:
            try:
                print(time.strftime("%F %T"), "->", want, send(want), detail, flush=True)
                last_sent = want
                _last_state = want
                record("state", value=want, detail=json.dumps({"sources": detail}))
            except Exception as e:
                print("EA-1 send failed, will retry:", e, flush=True)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
