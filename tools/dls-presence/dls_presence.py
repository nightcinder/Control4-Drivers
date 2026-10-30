#!/usr/bin/env python3
"""DLS presence bridge v1.2.1 - tells the Daylight Lighting Scheduler (Control4 EA-1) when you are Home/Away.

Sources (each returns True=here, False=not here, None=unknown/unavailable):
  unifi   - phone present in UniFi Poller metrics in Prometheus (stdlib only)
  life360 - member's Life360 place/location says home (needs the `life360` + `aiohttp` packages, e.g. in a venv;
            used as published, unmodified; the API is unofficial and may stop working at any time)
Household is HOME if ANY person is home; a person is home if ANY of their known sources says so.
Unavailable sources (None) are ignored, so an outage in one source never forces AWAY on its own.

  python3 dls_presence.py --discover                # list matching UniFi series
  python3 dls_presence.py --status                  # print each person/source once, no push
  python3 dls_presence.py --l360                    # Life360 members: place name, fix age, home? (no coordinates)
  python3 dls_presence.py --notify-test             # send a test alert through NOTIFY_SMTP/NOTIFY_TO
  python3 dls_presence.py                           # run forever (systemd)
Env:  PROM_URL (default http://localhost:9090)  EA1_HOST  EA1_PORT (8730)  DLS_TOKEN (the driver's Presence Token)
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
"""
import json, math, os, smtplib, socket, sys, threading, time, urllib.parse, urllib.request
from email.message import EmailMessage

VERSION = "1.2.1"
PROM = os.environ.get("PROM_URL", "http://localhost:9090").rstrip("/")
HOST = os.environ.get("EA1_HOST", "")
PORT = int(os.environ.get("EA1_PORT", "8730"))
TOKEN = os.environ.get("DLS_TOKEN", "2mdjxh5ynJBUkwIoMmH4RwCcBz8gmTSA")
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

_warned = set()


def warn_once(key, msg):
    if key not in _warned:
        _warned.add(key)
        print(msg, flush=True)


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


# ---------------------------------------------------------------- EA-1
def send(state):
    with socket.create_connection((HOST, PORT), timeout=10) as s:
        s.sendall(f"PRESENCE {state} {TOKEN}\r\n".encode())
        s.settimeout(5)
        try:
            return s.recv(64).decode().strip()
        except socket.timeout:
            return "(no reply)"


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
    if "--status" in sys.argv:
        here, detail = household()
        print("household:", {True: "HOME", False: "AWAY", None: "UNKNOWN"}[here], detail)
        return
    if not HOST:
        sys.exit("set EA1_HOST to the EA-1 IP address")
    print(f"dls_presence v{VERSION} starting", flush=True)
    last_sent, away_since = None, None
    while True:
        here, detail = household()
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
            except Exception as e:
                print("EA-1 send failed, will retry:", e, flush=True)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
