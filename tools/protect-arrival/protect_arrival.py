#!/usr/bin/env python3
"""UniFi Protect garage-camera vehicle event -> DLS arrival trigger.

A vehicle detected by the Garage camera means a car actually entered the garage, which is the
local equivalent of Tailwind's auto-open event: the Tailwind local API has no trigger source, but
the Protect smart-detect event does. Driveway is optional (it fires for any car).

Env (EnvironmentFile):
  PROTECT_URL      https://unifi.onyxlens.com
  PROTECT_USER     UniFi OS user with Protect access
  PROTECT_PASS     password
  PROTECT_CAMERAS  Garage            comma-separated camera names (default Garage)
  PROTECT_VERIFY   0                 verify the controller TLS certificate (default 0)
  ARRIVAL_URL      http://dls-presence:8731/arrival
  ARRIVAL_TOKEN    shared secret, same as in dls-presence.env
  POLL_SEC         3
  MAX_AGE_SEC      180               ignore events older than this (poller was down)

Usage: protect_arrival.py [--test [--minutes N]]
"""
import http.cookiejar
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("PROTECT_URL", "").rstrip("/")
USER = os.environ.get("PROTECT_USER", "")
PASS = os.environ.get("PROTECT_PASS", "")
CAMERAS = [c.strip() for c in os.environ.get("PROTECT_CAMERAS", "Garage").split(",") if c.strip()]
VERIFY = os.environ.get("PROTECT_VERIFY", "0") == "1"
ARRIVAL_URL = os.environ.get("ARRIVAL_URL", "http://127.0.0.1:8731/arrival")
ARRIVAL_TOKEN = os.environ.get("ARRIVAL_TOKEN", "")
POLL = float(os.environ.get("POLL_SEC", "3"))
MAX_AGE = float(os.environ.get("MAX_AGE_SEC", "180"))
HEARTBEAT = "/tmp/protect-heartbeat"

ctx = ssl.create_default_context()
if not VERIFY:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(cj), urllib.request.HTTPSHandler(context=ctx)
)


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def beat():
    try:
        with open(HEARTBEAT, "w") as fh:
            fh.write(str(time.time()))
    except OSError:
        pass


def request(path, data=None):
    req = urllib.request.Request(
        URL + path, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with opener.open(req, timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def login():
    # One attempt only: UniFi OS locks out an IP after a few failed/hasty logins (HTTP 429).
    cj.clear()
    body = json.dumps({"username": USER, "password": PASS, "remember": True}).encode()
    st, out = request("/api/auth/login", body)
    if st != 200:
        raise RuntimeError(f"login HTTP {st}: {out[:120]!r}")
    log(f"logged in to {URL}")


def api(path, retry=True):
    st, out = request(path)
    if st in (401, 403) and retry:
        login()
        st, out = request(path)
    if st != 200:
        raise RuntimeError(f"GET {path} HTTP {st}: {out[:120]!r}")
    return json.loads(out)


def camera_names():
    return {c["id"]: c.get("name", "?") for c in api("/proxy/protect/api/cameras")}


def event_matches(e, names, wanted):
    if e.get("type") != "smartDetectZone":
        return False
    if "vehicle" not in (e.get("smartDetectTypes") or []):
        return False
    return names.get(e.get("camera")) in wanted


def arrival():
    req = urllib.request.Request(
        ARRIVAL_URL,
        data=b"{}",
        headers={"X-Arrival-Token": ARRIVAL_TOKEN, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)


def iso(ms):
    return time.strftime("%F %H:%M:%S", time.localtime(ms / 1000))


def main():
    if "--test" in sys.argv:
        minutes = 60
        if "--minutes" in sys.argv:
            minutes = int(sys.argv[sys.argv.index("--minutes") + 1])
        login()
        names = camera_names()
        wanted = set(CAMERAS)
        end = int(time.time() * 1000)
        start = end - minutes * 60000
        evs = api(f"/proxy/protect/api/events?start={start}&end={end}&limit=300")
        found = 0
        for e in sorted(evs, key=lambda e: e.get("start", 0)):
            if event_matches(e, names, wanted):
                found += 1
                log(
                    f"MATCH {names.get(e['camera'])} {iso(e['start'])} "
                    f"{e.get('smartDetectTypes')} score={e.get('score')} id={e.get('id')}"
                )
        log(f"{found} matching vehicle event(s) in {minutes} min (cameras {', '.join(CAMERAS)})")
        return
    if not (URL and USER and PASS):
        sys.exit("PROTECT_URL/PROTECT_USER/PROTECT_PASS must be set")
    if not ARRIVAL_TOKEN:
        sys.exit("ARRIVAL_TOKEN is empty: it must match dls-presence.env")
    login()
    names, names_at = camera_names(), time.time()
    wanted = set(CAMERAS)
    missing = wanted - set(names.values())
    if missing:
        log(f"warning: camera(s) not found: {', '.join(sorted(missing))}")
    log(f"watching {', '.join(CAMERAS)} for vehicle smart-detect events")
    startup_ms = int(time.time() * 1000)
    seen, last_fire = set(), 0.0
    while True:
        beat()
        try:
            now = int(time.time() * 1000)
            if time.time() - names_at > 3600:
                names, names_at = camera_names(), time.time()
            start = now - 180000
            evs = api(f"/proxy/protect/api/events?start={start}&end={now}&limit=300")
            for e in sorted(evs, key=lambda e: e.get("start", 0)):
                eid = e.get("id")
                if not eid or eid in seen:
                    continue
                seen.add(eid)
                if len(seen) > 2000:
                    seen = set(list(seen)[-1000:])
                if e.get("start", 0) < startup_ms:
                    continue
                if not event_matches(e, names, wanted):
                    continue
                age = (now - e["start"]) / 1000
                if age > MAX_AGE:
                    log(f"skip stale {names.get(e['camera'])} {iso(e['start'])} age {age:.0f}s")
                    continue
                if time.time() - last_fire < 60:
                    log("skip (cooldown)")
                    continue
                last_fire = time.time()
                try:
                    res = arrival()
                    log(
                        f"arrival POST: {res} ({names.get(e['camera'])} vehicle {iso(e['start'])})"
                    )
                except Exception as exc:
                    log(f"arrival POST failed: {type(exc).__name__}: {exc}")
            time.sleep(POLL)
        except Exception as exc:
            log(f"protect error: {type(exc).__name__}: {exc}")
            time.sleep(10)
            try:
                login()
                names, names_at = camera_names(), time.time()
            except Exception as exc2:
                log(f"re-login failed: {type(exc2).__name__}: {exc2}")


if __name__ == "__main__":
    main()
