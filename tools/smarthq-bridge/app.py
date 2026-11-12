#!/usr/bin/env python3
"""SmartHQ (GE Cafe) LAN bridge: a small JSON API over the gehomesdk library.

Usage:
  python app.py login    one-time interactive login; writes CREDS_PATH (mode 600)
  python app.py          run the HTTP API on port 8789 (default)

No credentials are read from the environment or written to logs. The password
is only used for the login command and is never stored.

Version 0.2.0 adds one narrow write, POST /appliances/{id}/command, which only
switches the hood light (ERD HOOD_LIGHT_LEVEL). Everything else is read-only.

UNTESTED against real appliances.
"""
import asyncio
import getpass
import json
import os
import sys
import threading
import time
from datetime import timedelta
from enum import Enum
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

import aiohttp
from gehomesdk import (
    EVENT_APPLIANCE_INITIAL_UPDATE,
    EVENT_APPLIANCE_UPDATE_RECEIVED,
    ErdCode,
    GeSmartHqLogin,
    GeWebsocketClient,
)
from gehomesdk.erd.values.hood.common_enums import ErdHoodLightLevel

CREDS_PATH = os.environ.get("SMARTHQ_CREDS", "/data/smarthq.json")
PORT = int(os.environ.get("SMARTHQ_PORT", "8789"))
MAX_AGE_S = 300      # /health is 503 when the last data is older than this
RETRY_S = 30         # pause before reconnecting, and while waiting for login
REFRESH_S = 60       # ask every appliance for a full update this often

STATE = {"last_success": None, "error": None, "appliances": 0}
LOCK = threading.Lock()
# Dishwasher cycle tracking, keyed by appliance id (mac address).
DW_SEEN_ACTIVE = set()
DW_DONE = set()

OVEN_PREHEAT_STATES = {
    "BAKE_PREHEAT", "CONV_BAKE_PREHEAT", "CONV_MULTI_BAKE_PREHEAT", "CONV_ROAST_BAKE_PREHEAT",
}
DW_IDLE_STATES = {None, "NA", "CYCLE_INACTIVE"}


# ---------------------------------------------------------------- credentials

def load_creds():
    try:
        with open(CREDS_PATH) as f:
            data = json.load(f)
        if data.get("refresh_token") and data.get("username"):
            return data
    except (OSError, ValueError):
        pass
    return None


def save_creds(data):
    os.makedirs(os.path.dirname(CREDS_PATH), exist_ok=True)
    tmp = CREDS_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, CREDS_PATH)
    os.chmod(CREDS_PATH, 0o600)


async def _login():
    email = input("SmartHQ account email: ").strip()
    password = getpass.getpass("SmartHQ password: ")
    region = os.environ.get("SMARTHQ_REGION", "US")
    async with aiohttp.ClientSession() as session:
        login = GeSmartHqLogin(session)
        result = await login.async_login(email, password, region)
        del password
        if getattr(result, "mfa_required", False):
            methods = list(result.mfa_methods or []) or ["email"]
            await login.async_send_code(methods[0])
            code = input(f"Verification code sent via {methods[0]}: ").strip()
            token = await login.async_submit_code(code)
        else:
            token = result.token
    refresh = token.get("refresh_token") if isinstance(token, dict) else None
    if not refresh:
        raise SystemExit("login finished but no refresh token was returned")
    save_creds({"username": email, "region": region, "refresh_token": refresh})
    print(f"Saved login to {CREDS_PATH} (mode 600). Start or restart the service.")


# ---------------------------------------------------------- appliance reading

def _plain(value):
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, Enum):
        return value.name
    if isinstance(value, timedelta):
        return int(value.total_seconds())
    return str(value)


def _get(app, name):
    code = getattr(ErdCode, name, None)
    if code is None:
        return None
    try:
        return app.get_erd_value(code)
    except Exception:
        return None


def _kind(app):
    t = app.appliance_type
    n = t.name if t is not None else ""
    if "OVEN" in n or "RANGE" in n:
        return "oven"
    if "DISH" in n:
        return "dishwasher"
    return n.lower() or "unknown"


def _oven_fields(app, pfx):
    key = pfx.split("_")[0].lower()          # UPPER_OVEN -> upper
    state = _get(app, f"{pfx}_CURRENT_STATE")
    state_name = state.name if isinstance(state, Enum) else _plain(state)
    setting = _get(app, f"{pfx}_COOK_MODE")
    # UNCONFIRMED: attribute names on the decoded cook-setting object.
    target = getattr(setting, "temperature", None)
    mode = getattr(setting, "cook_mode", None) or setting
    fields = {
        f"{key}_current_temp_f": _plain(_get(app, f"{pfx}_DISPLAY_TEMPERATURE")),
        f"{key}_target_temp_f": _plain(target),
        f"{key}_cook_mode": _plain(mode),
        f"{key}_cook_state": _plain(state_name),
        f"{key}_preheating": state_name in OVEN_PREHEAT_STATES,
        f"{key}_timer_remaining_s": _plain(
            _get(app, f"{pfx}_COOK_TIME_REMAINING") or _get(app, f"{pfx}_KITCHEN_TIMER")
        ),
    }
    if all(v is None for v in fields.values()):
        return {}
    return fields


def _dishwasher_fields(app):
    state = _get(app, "DISHWASHER_CYCLE_STATE")
    name = state.name if isinstance(state, Enum) else None
    return {
        "cycle_state": _plain(name if name else state),
        "cycle_done": app.mac_addr in DW_DONE,  # derived in memory, see README
        "time_remaining_s": _plain(_get(app, "DISHWASHER_TIME_REMAINING")),
        "door_status": _plain(_get(app, "DISHWASHER_DOOR_STATUS")),
    }


def _cycle_name(app):
    state = _get(app, "DISHWASHER_CYCLE_STATE")
    return state.name if isinstance(state, Enum) else None


def _track_dishwashers(client):
    for app in list(client.appliances.values()):
        if _kind(app) != "dishwasher":
            continue
        mac = app.mac_addr
        name = _cycle_name(app)
        if name in DW_IDLE_STATES:
            if mac in DW_SEEN_ACTIVE:
                DW_SEEN_ACTIVE.discard(mac)
                DW_DONE.add(mac)
        else:
            DW_SEEN_ACTIVE.add(mac)
            DW_DONE.discard(mac)


# Hood light: the only write this bridge makes. Levels confirmed from the real
# hood's HOOD_LIGHT_LEVEL ERD (0x5b02) availability: off, dim, high. "on" -> HIGH.
HOOD_LIGHT_LEVELS = {
    "off": ErdHoodLightLevel.OFF,
    "dim": ErdHoodLightLevel.DIM,
    "on": ErdHoodLightLevel.HIGH,
}


def _hood_fields(app):
    return {
        "light_level": _plain(_get(app, "HOOD_LIGHT_LEVEL")),
        "fan_speed": _plain(_get(app, "HOOD_FAN_SPEED")),
    }


def _state_of(app):
    kind = _kind(app)
    out = {"id": app.mac_addr, "type": kind, "online": bool(app.available)}
    if kind == "oven":
        out.update(_oven_fields(app, "UPPER_OVEN"))
        out.update(_oven_fields(app, "LOWER_OVEN"))
    elif kind == "dishwasher":
        out.update(_dishwasher_fields(app))
    elif kind == "hood":
        out.update(_hood_fields(app))
    return out


def _erd_map(app):
    # Every ERD the library has cached for this appliance. Decoded values where
    # the library decodes them; raw hex kept alongside anything it could not.
    out = {}
    for code in sorted(app.known_properties, key=lambda c: str(getattr(c, "name", c))):
        name = str(getattr(code, "name", code))
        try:
            val = app.get_erd_value(code)
        except Exception:
            continue
        plain = _plain(val)
        if isinstance(plain, str) and not isinstance(val, (str, Enum)):
            out[name] = {"decoded": plain, "raw": app.get_raw_erd_value(code)}
        else:
            out[name] = plain
    return out


def _inventory_item(app):
    erds = _erd_map(app)
    nick = erds.get("NICKNAME")
    if isinstance(nick, dict):
        nick = nick.get("decoded")
    atype = app.appliance_type
    return {
        "id": app.mac_addr,
        "appliance_type": atype.name if atype is not None else None,
        "type": _kind(app),
        "nickname": nick if isinstance(nick, str) else None,
        "name": getattr(app, "name", None) or app.mac_addr,
        "online": bool(app.available),
        "erds": erds,
    }


def _client():
    with LOCK:
        return STATE.get("client")


# ------------------------------------------------------------ websocket side

async def _on_update(*_args, **_kwargs):
    # gehomesdk schedules event handlers as coroutines; a plain def raised TypeError.
    STATE["last_success"] = time.time()
    c = _client()
    if c is not None:
        try:
            _track_dishwashers(c)
            STATE["appliances"] = len(c.appliances)
        except Exception:
            pass


async def _refresh_loop(client, creds):
    while True:
        await asyncio.sleep(REFRESH_S)
        for app in list(client.appliances.values()):
            try:
                await app.async_request_update()
            except Exception:
                pass
        # UNCONFIRMED attribute: the SDK may rotate the refresh token.
        rt = getattr(client, "refresh_token", None)
        if rt and rt != creds.get("refresh_token"):
            creds["refresh_token"] = rt
            save_creds(creds)


async def _bridge(creds):
    async with aiohttp.ClientSession() as session:
        client = GeWebsocketClient(
            creds["username"], "", creds.get("region", "US"),
            event_loop=asyncio.get_running_loop(),
            refresh_token=creds["refresh_token"],
        )
        client.add_event_handler(EVENT_APPLIANCE_INITIAL_UPDATE, _on_update)
        client.add_event_handler(EVENT_APPLIANCE_UPDATE_RECEIVED, _on_update)
        with LOCK:
            STATE["client"] = client
        refresher = asyncio.ensure_future(_refresh_loop(client, creds))
        try:
            await client.async_get_credentials_and_run(session)
        finally:
            refresher.cancel()
            with LOCK:
                STATE["client"] = None


def _bridge_thread():
    while True:
        creds = load_creds()
        if creds is None:
            STATE["error"] = "not logged in"
            time.sleep(RETRY_S)
            continue
        try:
            asyncio.run(_bridge(creds))
            STATE["error"] = "client stopped"
        except Exception as exc:  # keep the message short; never log secrets
            STATE["error"] = type(exc).__name__
        time.sleep(RETRY_S)


# ---------------------------------------------------------------- HTTP side

class Handler(BaseHTTPRequestHandler):
    server_version = "smarthq-bridge/0.2"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body):
        data = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _health(self):
        last = STATE["last_success"]
        age = None if last is None else round(time.time() - last, 1)
        if load_creds() is None:
            code, status = 503, "not logged in: run 'python app.py login' once"
        elif age is None:
            code, status = 503, "no appliance data received yet"
        elif age > MAX_AGE_S:
            code, status = 503, "appliance data is stale"
        else:
            code, status = 200, "ok"
        self._send(code, {
            "status": status,
            "last_success_age_s": age,
            "appliances": STATE["appliances"],
            "last_error": STATE["error"],
        })

    def do_POST(self):
        # Single allowed write: POST /appliances/{hood id}/command {"action":"light","level":...}
        parts = urlparse(self.path).path.rstrip("/").split("/")
        if len(parts) != 4 or parts[1] != "appliances" or parts[3] != "command":
            return self._send(400, {"error": "unsupported write"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(max(length, 0), 4096)) or b"{}")
        except (ValueError, TypeError):
            return self._send(400, {"error": "body must be JSON"})
        if not isinstance(body, dict) or body.get("action") != "light":
            return self._send(400, {"error": "only action light is supported"})
        level = body.get("level")
        if level not in HOOD_LIGHT_LEVELS:
            return self._send(400, {"error": "level must be off, dim or on"})
        c = _client()
        if c is None:
            return self._send(503, {"error": "not connected", "last_error": STATE["error"]})
        want = unquote(parts[2])
        app = c.appliances.get(want) or next(
            (a for a in c.appliances.values() if a.mac_addr == want), None)
        if app is None or _kind(app) != "hood":
            return self._send(400, {"error": "light command is only for the hood"})
        try:
            # The SDK's own set call; the library encodes the enum to the ERD bytes.
            asyncio.run_coroutine_threadsafe(
                app.async_set_erd_value(ErdCode.HOOD_LIGHT_LEVEL, HOOD_LIGHT_LEVELS[level]),
                c.loop,
            ).result(timeout=20)
        except Exception as exc:
            return self._send(502, {"error": "write failed", "detail": type(exc).__name__})
        time.sleep(2)  # the hood reports its new level by push update
        return self._send(200, _state_of(app))

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        if path == "/health":
            return self._health()
        if path == "/inventory":
            # Read-only: every appliance on the account, with its cached ERDs.
            c = _client()
            if c is None:
                return self._send(503, {"error": "not connected", "last_error": STATE["error"]})
            return self._send(200, [_inventory_item(a) for a in list(c.appliances.values())])
        if path == "/appliances":
            c = _client()
            if c is None:
                return self._send(503, {"error": "not connected", "last_error": STATE["error"]})
            items = [
                {"id": a.mac_addr, "type": _kind(a), "name": getattr(a, "name", None) or a.mac_addr,
                 "online": bool(a.available)}
                for a in list(c.appliances.values())
            ]
            return self._send(200, items)
        parts = path.split("/")
        if len(parts) == 4 and parts[1] == "appliances" and parts[3] == "state":
            c = _client()
            if c is None:
                return self._send(503, {"error": "not connected", "last_error": STATE["error"]})
            want = unquote(parts[2])
            app = c.appliances.get(want) or next(
                (a for a in c.appliances.values() if a.mac_addr == want), None)
            if app is None:
                return self._send(404, {"error": "unknown appliance"})
            return self._send(200, _state_of(app))
        return self._send(404, {"error": "not found"})


def main(argv):
    if len(argv) > 1 and argv[1] == "login":
        asyncio.run(_login())
        return 0
    threading.Thread(target=_bridge_thread, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"smarthq-bridge listening on :{PORT}", file=sys.stderr)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
