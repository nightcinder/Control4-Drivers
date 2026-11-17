#!/usr/bin/env python3
"""Tailwind cloud probe: refresh the Keycloak token and look for the door activity feed.

The local API has no trigger source. The phone/web activity log does; this finds the endpoint and
shows whether the label (auto-open / app / automation / "Somebody") is available. Read-only GETs.

The refresh token is the seed from the 1Password Environment "Portainer" (synced into the stack
env by tools/sync-env.ps1). Keycloak may rotate it; the new one is stored in /data/refresh_token,
which wins on the next run.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

ACCOUNT = "https://account.gotailwind.com"
TOKEN_URL = f"{ACCOUNT}/realms/tailwind/protocol/openid-connect/token"
CLIENT = "tailwind_web"
API = "https://connect.gotailwind.com/api/v2"
DATA = "/data/refresh_token"

DEV = "_94_b5_55_19_18_a0_"
PROBES = [
    "/notifications?limit=10",
    "/devices",
    "/client-config",
    f"/device/{DEV}/events",
    f"/device/{DEV}/activity",
    f"/device/{DEV}/logs",
    f"/device/{DEV}/history",
    f"/devices/{DEV}/events",
    f"/devices/{DEV}/activity",
    f"/device/events?device_id={DEV}",
    "/logs",
    "/user/logs",
    "/user/notifications",
    "/messages",
    "/notice/list",
    "/event/list",
    "/activity/list",
    "/garage/events",
    "/door/events",
    "/device/status",
    "/device/list",
]


def redact(obj):
    if isinstance(obj, dict):
        return {k: ("<redacted>" if "token" in k.lower() or "secret" in k.lower() else redact(v))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj


def load_token():
    try:
        with open(DATA, encoding="utf-8") as fh:
            t = fh.read().strip()
            if t:
                return t
    except OSError:
        pass
    return os.environ.get("TAILWIND_REFRESH_TOKEN", "").strip()


def save_token(token):
    try:
        os.makedirs(os.path.dirname(DATA), exist_ok=True)
        tmp = DATA + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(token)
        os.chmod(tmp, 0o600)
        os.replace(tmp, DATA)
    except OSError as e:
        print(f"warn: could not save rotated refresh token: {e}", flush=True)


def refresh(token):
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token", "client_id": CLIENT,
        "refresh_token": token, "scope": "openid",
    }).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"token refresh HTTP {e.code}: {body}")


def get(path, access):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + access, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def main():
    token = load_token()
    if not token:
        print("TAILWIND_REFRESH_TOKEN is empty: add it to the 1Password Environment Portainer and run "
              "tools/sync-env.ps1 -Stack automation-pollers", flush=True)
        return
    try:
        tok = refresh(token)
    except Exception as e:
        print(f"refresh failed: {e}", flush=True)
        return
    access = tok.get("access_token")
    if not access:
        print("refresh response has no access_token", flush=True)
        return
    if tok.get("refresh_token") and tok["refresh_token"] != token:
        save_token(tok["refresh_token"])
        print("refresh token rotated and saved to /data/refresh_token", flush=True)
    print(f"token refresh ok (expires_in={tok.get('expires_in')})", flush=True)
    for path in PROBES:
        st, body = get(path, access)
        if st == 200 and path.startswith("/devices"):
            pass
        try:
            obj = json.loads(body)
            preview = json.dumps(redact(obj))[:1200]
        except Exception:
            preview = body[:300]
        print(f"\n== {path} {st}\n{preview}", flush=True)


if __name__ == "__main__":
    main()
