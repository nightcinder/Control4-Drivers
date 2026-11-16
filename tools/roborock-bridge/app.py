#!/usr/bin/env python3
"""Roborock LAN bridge.

Polls one Roborock vacuum through python-roborock (at most every 60 s) and
serves a small HTTP JSON API on the LAN.

  python app.py login   one-time email-code login; writes DATA_FILE (mode 600)
  python app.py serve   HTTP API + poller (default)

0.2.3: per-run cleaning mode (vacuum / vac_and_mop / mop). The mode is a
persistent device setting, so the bridge saves the previous fan, water and
route codes, sets the mode, starts the job, and puts the saved codes back when
the job has ended. /state also carries the cleaning mode, clean area, clean
time and the device's own clean percent (when the vacuum reports one).
"""
import asyncio
import json
import logging
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.2.3"
DATA_FILE = os.environ.get("ROBOROCK_DATA", "/data/roborock.json")
# Saved fan / water / route codes waiting to be put back after a per-run mode job. Not secret.
RESTORE_FILE = os.environ.get(
    "ROBOROCK_RESTORE", os.path.join(os.path.dirname(DATA_FILE) or ".", "mode_restore.json"))
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
ACTIONS = {"start", "stop", "pause", "dock", "clean_rooms", "set_mode"}
MODES = ("vacuum", "vac_and_mop", "mop")
MAX_BODY = 4096
COMMAND_TIMEOUT = 30
WAKE_DELAYS = (2, 8, 20)    # extra status polls this many seconds after a command
RESTORE_GRACE = 180         # restore after this long when the job was never seen running
RESTORE_MAX_AGE = 8 * 3600  # restore anyway after this long, unless the robot is cleaning right now

# State names are the lower-case python-roborock RoborockStateCode names.
RETURNING_STATES = {"returning", "returning_home", "docking", "going_to_wash_the_mop",
                    "back_to_dock_washing_duster"}
DOCK_SERVICE_STATES = {"emptying_the_bin", "washing_the_mop", "washing_the_mop_2",
                       "attaching_the_mop", "detaching_the_mop"}
# A job is over in these states (docked or stopped on the floor).
END_STATES = {"charging", "charging_complete", "charging_problem", "docked", "idle", "air_drying_stopping"}

# Mode codes that are kept from the current setting when a per-run mode is applied.
KEEP_FAN_CODES = {101, 102, 103, 104, 108}   # quiet, balanced, turbo, max, max_plus
SKIP_WATER_CODES = {200, 204, 209}           # off, custom (per room), smart
SKIP_ROUTE_CODES = {302, 306}                # custom (per room), smart
MODE_KEYS = ("fan_power", "water_box_mode", "mop_mode")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("roborock-bridge")

state_lock = threading.Lock()
STATE = {"state": None, "battery": None, "error": None, "rooms": [],
         "last_success": None, "last_error": None}
RUNTIME = {"loop": None, "props": None, "wake": None}
MAP = {"segment": None, "at": None}  # latest vacuum_room from the parsed map and its fetch time
RESTORE = {"pending": None}          # {"prev": {codes}, "mode": str, "at": epoch, "seen_active": bool}


class ModeUnsupported(Exception):
    """The vacuum does not offer the requested cleaning mode."""


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def save_json(path, payload):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load_saved():
    return load_json(DATA_FILE)


def save_saved(payload):
    save_json(DATA_FILE, payload)


def _name(value):
    if value is None:
        return None
    return getattr(value, "name", None) or str(value)


def _int(value):
    """int(value), or None when it is missing or not a number (enums are ints)."""
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _safe(fn):
    """Optional status extras must never break the poll."""
    try:
        return fn()
    except Exception:
        return None


def _norm(state):
    return str(state or "").strip().lower().replace(" ", "_").replace("-", "_")


def _is_cleaning(state):
    s = _norm(state)
    return "clean" in s or "mopping" in s


def _is_busy(state):
    """Cleaning, on the way back, or busy at the dock: poll fast."""
    s = _norm(state)
    return _is_cleaning(s) or s in RETURNING_STATES or s in DOCK_SERVICE_STATES


def status_snapshot(st):
    """Flat /state fields from a python-roborock StatusTrait. Extras are None when not reported."""
    # "state" is always the lower-case underscore name (segment_cleaning, returning_home, ...) or None.
    state_name = _name(getattr(st, "state", None))
    snap = {"state": None if state_name is None else _norm(state_name), "battery": st.battery,
            "error": _name(getattr(st, "error_code", None))}
    snap["error_code"] = _int(getattr(st, "error_code", None))
    snap["in_cleaning"] = _int(getattr(st, "in_cleaning", None))
    snap["clean_time_s"] = _int(getattr(st, "clean_time", None))
    area = _int(getattr(st, "clean_area", None))       # mm2 in the library
    snap["clean_area_m2"] = None if area is None else round(area / 1000000, 2)
    pct = _int(getattr(st, "clean_percent", None))     # only on models with a clean estimate
    snap["clean_percent"] = pct if pct is not None and 0 <= pct <= 100 else None
    snap["cleaning_mode"] = _safe(lambda: st.current_cleaning_mode_name)
    snap["water_mode"] = _safe(lambda: st.water_mode_name)
    snap["fan_speed"] = _safe(lambda: st.fan_speed_name)
    snap["mop_route"] = _safe(lambda: st.mop_route_name)
    snap["cleaning_modes"] = _safe(lambda: [str(m.value) for m in st.cleaning_mode_options]) or []
    return snap


def merge_mode_params(mode, base, prev):
    """Mode codes to send for a high-level mode.

    base is the library's default for the mode ({"fan_power", "water_box_mode"[, "mop_mode"]}).
    The current suction, water level and route are kept where they still fit the mode, so a
    per-run mode changes as little as possible.
    """
    out = dict(base)
    fan = prev.get("fan_power")
    if mode in ("vacuum", "vac_and_mop") and fan in KEEP_FAN_CODES:
        out["fan_power"] = fan
    water = prev.get("water_box_mode")
    if mode in ("vac_and_mop", "mop") and isinstance(water, int) and water not in SKIP_WATER_CODES:
        out["water_box_mode"] = water
    route = prev.get("mop_mode")
    if "mop_mode" in out and isinstance(route, int) and route not in SKIP_ROUTE_CODES:
        out["mop_mode"] = route
    return out


def restore_due(pending, state, in_cleaning, now):
    """True when the saved mode should be put back now."""
    age = now - pending.get("at", 0)
    s = _norm(state)
    if s in END_STATES and in_cleaning in (None, 0):
        if pending.get("seen_active") or age > RESTORE_GRACE:
            return True
    return age > RESTORE_MAX_AGE and not _is_cleaning(s)


def _set_pending(pending):
    with state_lock:
        RESTORE["pending"] = pending
    try:
        if pending is None:
            if os.path.exists(RESTORE_FILE):
                os.remove(RESTORE_FILE)
        else:
            save_json(RESTORE_FILE, pending)
    except OSError as exc:  # the in-memory copy still restores unless the container restarts
        log.warning("mode restore file not updated: %s", type(exc).__name__)


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
        return props, status_snapshot(props.status)
    raise RuntimeError("no v1 vacuum found on this account")


async def load_rooms(props):
    """Return the map's rooms as [{"id": segment_id, "name": room_name}, ...]."""
    await props.rooms.refresh()
    return [{"id": seg, "name": room.name}
            for seg, room in sorted(props.rooms.room_map.items())]


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
                    busy = _is_busy(STATE["state"])
                if busy:
                    break


async def send_mode_codes(props, codes):
    """Set fan, water and route codes. One combined command, or the three older ones if it is refused."""
    from roborock.roborock_typing import RoborockCommand as C

    send = props.command.send
    params = {k: codes[k] for k in MODE_KEYS if isinstance(codes.get(k), int)}
    try:
        await send(C.SET_CLEAN_MOTOR_MODE, [params])
        return
    except Exception as exc:
        log.warning("set_clean_motor_mode failed (%s); trying the single-setting commands", type(exc).__name__)
    await send(C.SET_CUSTOM_MODE, [params["fan_power"]])
    await send(C.SET_WATER_BOX_CUSTOM_MODE, [params["water_box_mode"]])
    if "mop_mode" in params:
        await send(C.SET_MOP_MODE, [params["mop_mode"]])


def default_mode_params(props, mode):
    """The library's codes for a high-level mode. Raises ModeUnsupported when the vacuum lacks it."""
    from roborock import get_cleaning_mode_parameters, resolve_cleaning_mode
    from roborock.exceptions import RoborockUnsupportedFeature

    try:
        return dict(get_cleaning_mode_parameters(resolve_cleaning_mode(mode), props.device_features)[0])
    except RoborockUnsupportedFeature as exc:
        raise ModeUnsupported(mode) from exc


async def apply_mode(props, mode, per_run):
    """Set the cleaning mode. per_run=True saves the previous codes so the poller puts them back
    after the job; per_run=False is a lasting change and drops any saved codes."""
    st = props.status
    await st.refresh()
    prev = {k: _int(getattr(st, k, None)) for k in MODE_KEYS}
    want = merge_mode_params(mode, default_mode_params(props, mode), prev)
    if per_run and (prev["fan_power"] is None or prev["water_box_mode"] is None):
        raise RuntimeError("current mode unknown, so it could not be restored")
    changed = any(prev.get(k) != v for k, v in want.items())
    if changed:
        await send_mode_codes(props, want)
    with state_lock:
        pending = RESTORE["pending"]
    if not per_run:
        if pending is not None:
            _set_pending(None)
    elif pending is not None:
        # A second per-run job before the first was restored: keep the first saved codes.
        _set_pending(dict(pending, mode=mode, at=time.time(), seen_active=False))
    elif changed:
        # Only the settings this job changed are saved, so the restore sends nothing else.
        _set_pending({"prev": {k: prev[k] for k in want if prev.get(k) is not None},
                      "mode": mode, "at": time.time(), "seen_active": False})
    if changed:
        try:
            await st.refresh()
            with state_lock:
                STATE.update(status_snapshot(st))
        except Exception as exc:
            log.warning("status refresh after mode change failed: %s", type(exc).__name__)
        await asyncio.sleep(1)
    return changed


async def restore_mode(props):
    """Put back the codes saved by a per-run mode job. Keeps the saved codes when the send fails."""
    with state_lock:
        pending = RESTORE["pending"]
    if pending is None:
        return False
    try:
        await send_mode_codes(props, pending["prev"])
    except Exception as exc:
        log.warning("mode restore failed, will retry: %s", type(exc).__name__)
        return False
    _set_pending(None)
    log.info("cleaning mode restored after a per-run %s job", pending.get("mode"))
    return True


async def maybe_restore(props, snap):
    with state_lock:
        pending = RESTORE["pending"]
    if pending is None:
        return
    state = snap.get("state")
    if not pending.get("seen_active") and (_is_busy(state) or _norm(state) == "paused"):
        pending = dict(pending, seen_active=True)
        _set_pending(pending)
    if restore_due(pending, state, snap.get("in_cleaning"), time.time()):
        if await restore_mode(props):
            try:
                await props.status.refresh()
                with state_lock:
                    STATE.update(status_snapshot(props.status))
            except Exception as exc:
                log.warning("status refresh after mode restore failed: %s", type(exc).__name__)


async def _sleep_or_wake(wait):
    wake = RUNTIME["wake"]
    try:
        await asyncio.wait_for(wake.wait(), timeout=wait)
    except asyncio.TimeoutError:
        pass
    wake.clear()


async def poller(saved):
    manager = None
    rooms_at = 0.0  # time of the last room refresh (0 = never)
    wait = POLL_INTERVAL
    RUNTIME["wake"] = asyncio.Event()
    asyncio.ensure_future(map_loop())
    while True:
        try:
            if manager is None:
                manager = await build_manager(saved)
            props, snap = await poll_once(manager)
            RUNTIME["props"] = props
            wait = POLL_ACTIVE if _is_busy(snap["state"]) else POLL_INTERVAL
            with state_lock:
                STATE.update(snap)
                STATE["last_success"] = time.time()
                STATE["last_error"] = None
            await maybe_restore(props, snap)
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
        await _sleep_or_wake(wait)


def _wake_soon():
    """Poll again shortly after a command so /state follows the robot without waiting a full interval."""
    wake = RUNTIME.get("wake")
    if wake is None:
        return
    loop = asyncio.get_running_loop()
    for delay in WAKE_DELAYS:
        loop.call_later(delay, wake.set)


async def run_command(action, rooms, mode=None):
    from roborock.roborock_typing import RoborockCommand as C

    props = RUNTIME["props"]
    if props is None:
        raise RuntimeError("device not ready")
    send = props.command.send
    try:
        if action == "set_mode":
            await apply_mode(props, mode, per_run=False)
            return
        mode_set = False
        if action in ("start", "clean_rooms"):
            if mode:
                mode_set = True
                await apply_mode(props, mode, per_run=True)
            else:
                # A job without a mode must run with the user's own setting, so a restore that is
                # still waiting is done first (not while a job is running or paused: start resumes it).
                with state_lock:
                    waiting = RESTORE["pending"] is not None
                    active = _is_busy(STATE["state"]) or _norm(STATE["state"]) == "paused"
                if waiting and not active:
                    await restore_mode(props)
        try:
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
        except Exception:
            if mode_set:  # the job did not start, so put the mode back now
                await restore_mode(props)
            raise
    finally:
        _wake_soon()


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
    body = {"status": "ok" if ok else "unhealthy", "version": VERSION,
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
        pending = RESTORE["pending"]
    last = body.pop("last_success")
    body["last_success_age_s"] = None if last is None else round(time.time() - last, 1)
    body["current_room"] = _current_room()
    # Not derivable from python-roborock 7.22.0 for v1 vacuums: the v1 map parser
    # gives only room bounding boxes (no pixel counts) and never fills
    # MapData.cleaned_rooms. Left as null rather than estimated.
    body["room_progress_pct"] = None
    # The whole-job percent is the vacuum's own clean_percent, on models that report one.
    # Null otherwise; the driver may then estimate from clean_area_m2 and says so.
    pct = body.get("clean_percent")
    body["run_progress_pct"] = pct
    body["run_progress_source"] = None if pct is None else "device"
    body["mode_restore_pending"] = pending is not None
    body["bridge_version"] = VERSION
    return 200, body


def parse_command(raw):
    data = json.loads(raw or b"{}")
    if not isinstance(data, dict):
        raise ValueError("body must be a JSON object")
    action = data.get("action")
    if action not in ACTIONS:
        raise ValueError("action must be one of start, stop, pause, dock, clean_rooms, set_mode")
    rooms = data.get("rooms", [])
    if action == "clean_rooms":
        if not isinstance(rooms, list) or not rooms or not all(
                isinstance(r, int) and not isinstance(r, bool) for r in rooms):
            raise ValueError("clean_rooms needs a non-empty list of integer room ids")
    mode = data.get("mode")
    if mode is not None and mode not in MODES:
        raise ValueError("mode must be one of vacuum, vac_and_mop, mop")
    if action == "set_mode" and mode is None:
        raise ValueError("set_mode needs a mode")
    if action not in ("start", "clean_rooms", "set_mode"):
        mode = None
    return action, rooms, mode


class Handler(BaseHTTPRequestHandler):
    server_version = "roborock-bridge/" + VERSION

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
            action, rooms, mode = parse_command(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self._send(400, {"error": "invalid command body"})
            return
        loop = RUNTIME["loop"]
        if loop is None or RUNTIME["props"] is None:
            self._send(409, {"error": "device not ready"})
            return
        future = asyncio.run_coroutine_threadsafe(run_command(action, rooms, mode), loop)
        try:
            future.result(timeout=COMMAND_TIMEOUT)
        except ModeUnsupported:
            self._send(422, {"error": "mode not supported by this vacuum", "mode": mode})
            return
        except Exception as exc:
            future.cancel()  # on a timeout, do not let the command run on after the caller was told it failed
            log.warning("command %s failed: %s", action, type(exc).__name__)
            self._send(502, {"error": "device command failed", "type": type(exc).__name__})
            return
        self._send(202, {"ok": True, "action": action, "rooms": rooms, "mode": mode})


def serve():
    saved = load_saved()
    loop = asyncio.new_event_loop()
    RUNTIME["loop"] = loop
    try:
        pending = load_json(RESTORE_FILE)
        if isinstance(pending, dict) and isinstance(pending.get("prev"), dict):
            RESTORE["pending"] = pending
            log.info("a per-run mode restore is pending from before the restart")
    except (OSError, ValueError) as exc:
        log.warning("mode restore file not read: %s", type(exc).__name__)
    if saved is None:
        log.warning("not logged in; run 'python app.py login'. /health will return 503.")
    else:
        threading.Thread(target=loop.run_until_complete, args=(poller(saved),),
                         daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if arg == "login":
        asyncio.run(login_flow())
    elif arg == "serve":
        serve()
    else:
        print("usage: python app.py [login|serve]", file=sys.stderr)
        sys.exit(2)
