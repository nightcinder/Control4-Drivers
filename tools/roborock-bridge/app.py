#!/usr/bin/env python3
"""Roborock LAN bridge.

Polls one Roborock vacuum through python-roborock (at most every 60 s) and
serves a small HTTP JSON API on the LAN.

  python app.py login   one-time email-code login; writes DATA_FILE (mode 600)
  python app.py serve   HTTP API + poller (default)
"""
import asyncio
import json
import logging
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_FILE = os.environ.get("ROBOROCK_DATA", "/data/roborock.json")
PORT = int(os.environ.get("PORT", "8788"))
# Status poll cadence. Idle uses POLL_INTERVAL (floor 15 s). While the robot is cleaning or returning,
# POLL_ACTIVE (default 5 s, floor 5 s) is used so the driver sees state changes quickly. Each poll is one
# python-roborock status read; the library prefers the local LAN link, so this is not a cloud call per poll
# unless the local link is down. If cloud rate limits appear in the log, raise POLL_ACTIVE.
POLL_INTERVAL = max(15, int(os.environ.get("POLL_INTERVAL", "60")))
POLL_ACTIVE = max(5, int(os.environ.get("POLL_ACTIVE", "5")))
MAX_AGE = 300
ROOMS_REFRESH_SECONDS = 600
MAP_REFRESH_ACTIVE = 15     # seconds between map fetches while the robot is cleaning
MAP_REFRESH_IDLE = 300      # seconds between map fetches otherwise
MAP_MAX_AGE = 120           # current_room is null when the cached map is older than this
ACTIONS = {"start", "stop", "pause", "dock", "clean_rooms"}
MAX_BODY = 4096

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("roborock-bridge")

state_lock = threading.Lock()
STATE = {"state": None, "battery": None, "error": None, "rooms": [],
         "last_success": None, "last_error": None}
RUNTIME = {"loop": None, "props": None}
MAP = {"segment": None, "at": None}  # latest vacuum_room from the parsed map and its fetch time


def load_saved():
    try:
        with open(DATA_FILE, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def save_saved(payload):
    os.makedirs(os.path.dirname(DATA_FILE) or ".", exist_ok=True)
    tmp = DATA_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, DATA_FILE)


def _name(value):
    if value is None:
        return None
    return getattr(value, "name", None) or str(value)


async def login_flow():
    from roborock.web_api import RoborockApiClient

    email = input("Roborock account email: ").strip()
    api = RoborockApiClient(username=email)
    await api.request_code()
    print("A login code was emailed to that address.")
    code = input("Code: ").strip()
    user_data = await api.code_login(code)
    raw = user_data.as_dict() if hasattr(user_data, "as_dict") else vars(user_data)
    save_saved({"username": email, "user_data": raw})
    print(f"Saved login to {DATA_FILE} (mode 600). Nothing secret was printed.")


async def build_manager(saved):
    from roborock.data import UserData
    from roborock.devices.device_manager import UserParams, create_device_manager

    user_data = UserData.from_dict(saved["user_data"])
    params = UserParams(username=saved["username"], user_data=user_data)
    return await create_device_manager(params)


async def poll_once(manager):
    for device in await manager.get_devices():
        props = getattr(device, "v1_properties", None)
        if props is None:
            continue
        await props.status.refresh()
        st = props.status
        snap = {"state": _name(st.state), "battery": st.battery,
                "error": _name(getattr(st, "error_code", None))}
        return props, snap
    raise RuntimeError("no v1 vacuum found on this account")


async def load_rooms(props):
    """Return the map's rooms as [{"id": segment_id, "name": room_name}, ...]."""
    await props.rooms.refresh()
    return [{"id": seg, "name": room.name}
            for seg, room in sorted(props.rooms.room_map.items())]


def _is_cleaning(state):
    return bool(state) and "clean" in str(state).lower()


async def map_loop():
    """Refresh the parsed map so current_room tracks the robot.

    python-roborock sets MapData.vacuum_room (the segment id under the robot)
    when it parses the map. The map is fetched every MAP_REFRESH_ACTIVE seconds
    while cleaning and every MAP_REFRESH_IDLE seconds otherwise.
    """
    while True:
        wait = MAP_REFRESH_IDLE
        props = RUNTIME["props"]
        if props is None:
            wait = 5
        else:
            try:
                await props.map_content.refresh()
                map_data = props.map_content.map_data
                segment = getattr(map_data, "vacuum_room", None) if map_data is not None else None
                with state_lock:
                    MAP["segment"] = segment
                    MAP["at"] = time.time()
                    cleaning = _is_cleaning(STATE["state"])
                if cleaning:
                    wait = MAP_REFRESH_ACTIVE
            except Exception as exc:  # map is optional; status keeps working
                log.warning("map refresh failed: %s", type(exc).__name__)
                with state_lock:
                    MAP["segment"] = None
                    if _is_cleaning(STATE["state"]):
                        wait = MAP_REFRESH_ACTIVE
        # Sleep in 2 s slices so a clean that starts during an idle sleep
        # triggers an immediate map refresh instead of waiting out the idle wait.
        slept = 0.0
        while slept < wait:
            step = min(2.0, wait - slept)
            await asyncio.sleep(step)
            slept += step
            if wait > MAP_REFRESH_ACTIVE:
                with state_lock:
                    busy = _is_cleaning(STATE["state"]) or str(STATE["state"]).lower() == "returning"
                if busy:
                    break


async def poller(saved):
    manager = None
    rooms_at = 0.0  # time of the last room refresh (0 = never)
    wait = POLL_INTERVAL
    asyncio.ensure_future(map_loop())
    while True:
        try:
            if manager is None:
                manager = await build_manager(saved)
            props, snap = await poll_once(manager)
            RUNTIME["props"] = props
            busy = _is_cleaning(snap["state"]) or str(snap["state"]).lower() == "returning"
            wait = POLL_ACTIVE if busy else POLL_INTERVAL
            with state_lock:
                STATE.update(snap)
                STATE["last_success"] = time.time()
                STATE["last_error"] = None
            if time.time() - rooms_at >= ROOMS_REFRESH_SECONDS:
                rooms_at = time.time()  # on failure, also wait the full interval
                try:
                    rooms = await load_rooms(props)
                    with state_lock:
                        STATE["rooms"] = rooms
                except Exception as exc:  # room list is optional; status keeps working
                    log.warning("room refresh failed: %s", type(exc).__name__)
        except Exception as exc:  # keep polling; never log secrets
            log.warning("poll failed: %s", type(exc).__name__)
            with state_lock:
                STATE["last_error"] = type(exc).__name__
            wait = POLL_INTERVAL
            if manager is not None:
                try:
                    await manager.close()
                except Exception:
                    pass
                manager = None
        await asyncio.sleep(wait)


async def run_command(action, rooms):
    from roborock.roborock_typing import RoborockCommand as C

    props = RUNTIME["props"]
    if props is None:
        raise RuntimeError("device not ready")
    send = props.command.send
    if action == "start":
        await send(C.APP_START)
    elif action == "stop":
        await send(C.APP_STOP)
    elif action == "pause":
        await send(C.APP_PAUSE)
    elif action == "dock":
        await send(C.APP_CHARGE)
    elif action == "clean_rooms":
        await send(C.APP_SEGMENT_CLEAN, [{"segments": rooms, "repeat": 1}])


def health_payload():
    if load_saved() is None:
        return 503, {"status": "unhealthy",
                     "reason": "not logged in: run 'python app.py login' first",
                     "sources": {}}
    with state_lock:
        last = STATE["last_success"]
        last_error = STATE["last_error"]
    age = None if last is None else round(time.time() - last, 1)
    ok = age is not None and age < MAX_AGE
    body = {"status": "ok" if ok else "unhealthy",
            "sources": {"device_poll": {"last_success_age_s": age, "last_error": last_error}}}
    if not ok:
        body["reason"] = "no successful device poll in the last 300 s"
    return (200 if ok else 503), body


def _current_room():
    """{"id": segment, "name": str|None} for the robot's room, or None if unknown."""
    try:
        with state_lock:
            segment, at = MAP["segment"], MAP["at"]
            rooms = list(STATE["rooms"] or [])
        if segment is None or at is None or time.time() - at > MAP_MAX_AGE:
            return None
        name = next((r["name"] for r in rooms if r["id"] == segment), None)
        return {"id": segment, "name": name}
    except Exception:  # never let the room lookup break /state
        return None


def state_payload():
    if load_saved() is None:
        return 503, {"error": "not logged in: run 'python app.py login' first"}
    with state_lock:
        body = dict(STATE)
    last = body.pop("last_success")
    body["last_success_age_s"] = None if last is None else round(time.time() - last, 1)
    body["current_room"] = _current_room()
    # Not derivable from python-roborock 7.22.0 for v1 vacuums: the v1 map parser
    # gives only room bounding boxes (no pixel counts) and never fills
    # MapData.cleaned_rooms. Left as null rather than estimated.
    body["room_progress_pct"] = None
    body["run_progress_pct"] = None
    return 200, body


def parse_command(raw):
    data = json.loads(raw or b"{}")
    action = data.get("action")
    if action not in ACTIONS:
        raise ValueError("action must be one of start, stop, pause, dock, clean_rooms")
    rooms = data.get("rooms", [])
    if action == "clean_rooms":
        if not isinstance(rooms, list) or not rooms or not all(
                isinstance(r, int) and not isinstance(r, bool) for r in rooms):
            raise ValueError("clean_rooms needs a non-empty list of integer room ids")
    return action, rooms


class Handler(BaseHTTPRequestHandler):
    server_version = "roborock-bridge/0.2.2"

    def log_message(self, fmt, *args):  # no per-request logs
        return

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(*health_payload())
        elif self.path == "/state":
            self._send(*state_payload())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/command":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > MAX_BODY:
                self._send(413, {"error": "body too large"})
                return
            action, rooms = parse_command(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self._send(400, {"error": "invalid command body"})
            return
        loop = RUNTIME["loop"]
        if loop is None or RUNTIME["props"] is None:
            self._send(409, {"error": "device not ready"})
            return
        try:
            asyncio.run_coroutine_threadsafe(run_command(action, rooms), loop).result(timeout=30)
        except Exception as exc:
            log.warning("command %s failed: %s", action, type(exc).__name__)
            self._send(502, {"error": "device command failed", "type": type(exc).__name__})
            return
        self._send(202, {"ok": True, "action": action, "rooms": rooms})


def serve():
    saved = load_saved()
    loop = asyncio.new_event_loop()
    RUNTIME["loop"] = loop
    if saved is None:
        log.warning("not logged in; run 'python app.py login'. /health will return 503.")
    else:
        threading.Thread(target=loop.run_until_complete, args=(poller(saved),),
                         daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if mode == "login":
        asyncio.run(login_flow())
    elif mode == "serve":
        serve()
    else:
        print("usage: python app.py [login|serve]", file=sys.stderr)
        sys.exit(2)
