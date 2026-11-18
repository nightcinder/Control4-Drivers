#!/usr/bin/env python3
"""Tailwind iQ3 garage door -> DLS arrival trigger.

Polls the Tailwind local API (no cloud) and, when a garage door closes, POSTs the
dls-presence /arrival endpoint. That endpoint forces HOME only if the household is
currently AWAY, so a door close on the way out is a no-op. Closing the door on
arrival turns the lights on immediately instead of waiting for the phone to leave
Android Auto and join home Wi-Fi.

Env (EnvironmentFile):
  TAILWIND_IP      LAN address of the iQ3 (required)
  TAILWIND_TOKEN   6-digit Local Control Key from web.gotailwind.com
  ARRIVAL_URL      http://127.0.0.1:8731/arrival
  ARRIVAL_TOKEN    shared secret, same as in dls-presence.env
  POLL_SEC         3
  OPEN_TRIGGER     0: only close (recommended); 1: also an open edge

Usage: tailwind_arrival.py [--once]
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

IP = os.environ.get("TAILWIND_IP", "").strip()
TOKEN = os.environ.get("TAILWIND_TOKEN", "").strip()
ARRIVAL_URL = os.environ.get("ARRIVAL_URL", "http://127.0.0.1:8731/arrival").strip()
ARRIVAL_TOKEN = os.environ.get("ARRIVAL_TOKEN", "").strip()
POLL = float(os.environ.get("POLL_SEC", "3"))
OPEN_TRIGGER = os.environ.get("OPEN_TRIGGER", "1") == "1"
ENV_FILE = os.environ.get("ENV_FILE", "/run/tailwind.env")
HEARTBEAT = "/tmp/tailwind-heartbeat"


def beat():
    try:
        with open(HEARTBEAT, "w") as fh:
            fh.write(str(time.time()))
    except OSError:
        pass


def read_token():
    """The key is added to the mounted env file after the container starts, so re-read it while empty."""
    try:
        with open(ENV_FILE, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if line.startswith("TAILWIND_TOKEN="):
                    return line.split("=", 1)[1].strip().strip('"\'')
    except OSError:
        pass
    return ""


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def api(payload, timeout=4.0):
    req = urllib.request.Request(
        f"http://{IP}/json",
        data=json.dumps(payload).encode(),
        headers={"TOKEN": TOKEN, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def doors():
    body = api({"version": "0.1", "data": {"type": "get", "name": "dev_st"}})
    data = body.get("data") or {}
    out = {}
    for name, rec in data.items():
        if name.startswith("door") and isinstance(rec, dict):
            out[name] = str(rec.get("status", "")).lower()
    return out


def arrival(payload):
    req = urllib.request.Request(
        ARRIVAL_URL,
        data=json.dumps(payload).encode(),
        headers={"X-Arrival-Token": ARRIVAL_TOKEN, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=4) as r:
        return json.load(r)


def main():
    global TOKEN
    if not IP:
        sys.exit("TAILWIND_IP is empty: set it to the iQ3 LAN address in the environment file")
    if "--once" in sys.argv:
        if not TOKEN:
            TOKEN = read_token()
        if not TOKEN:
            sys.exit("TAILWIND_TOKEN is empty: copy the 6-digit Local Control Key from web.gotailwind.com")
        print(json.dumps(doors(), indent=2))
        return
    if not ARRIVAL_TOKEN:
        sys.exit("ARRIVAL_TOKEN is empty: it must match dls-presence.env")
    warned = 0.0
    while not TOKEN:
        TOKEN = read_token()
        if TOKEN:
            log("TAILWIND_TOKEN loaded")
            break
        if time.time() - warned > 300:
            log(f"waiting for TAILWIND_TOKEN in {ENV_FILE} (web.gotailwind.com -> Local Control Key)")
            warned = time.time()
        beat()
        time.sleep(20)
    prev = None
    fails = 0
    last_fire = 0.0
    while True:
        beat()
        try:
            cur = doors()
            if prev is None:
                log("tailwind doors: " + ", ".join(f"{k}={v}" for k, v in sorted(cur.items())))
            else:
                for name, status in sorted(cur.items()):
                    was = prev.get(name)
                    if was == status:
                        continue
                    log(f"{name}: {was} -> {status}")
                    close_edge = was == "open" and status == "close"
                    open_edge = OPEN_TRIGGER and was == "close" and status == "open"
                    if (close_edge or open_edge) and ARRIVAL_TOKEN:
                        now = time.time()
                        if now - last_fire < 20:
                            log("arrival skipped (cooldown)")
                            continue
                        last_fire = now
                        try:
                            res = arrival({"reason": "tailwind-" + ("open" if open_edge else "close"), "door": name})
                            log(f"arrival POST ({'open' if open_edge else 'close'} edge): {res}")
                        except Exception as e:
                            log(f"arrival POST failed: {type(e).__name__}: {e}")
            prev = cur
            fails = 0
            time.sleep(POLL)
        except urllib.error.HTTPError as e:
            fails += 1
            body = e.read().decode("utf-8", "replace")[:120]
            log(f"tailwind HTTP {e.code}: {body}")
            time.sleep(min(60, 5 * fails))
        except Exception as e:
            fails += 1
            log(f"tailwind error: {type(e).__name__}: {e}")
            time.sleep(min(60, 5 * fails))


if __name__ == "__main__":
    main()
