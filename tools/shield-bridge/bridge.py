#!/usr/bin/env python3
"""NVIDIA Shield TV HTTP bridge for Control4 drivers.

Run:      python3 bridge.py [config.json]
Selftest: python3 bridge.py --selftest   (stdlib only, no network)
"""

from __future__ import annotations

import asyncio
import contextlib
import hmac
import io
import json
import logging
import re
import sys
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from aiohttp import web

VERSION = "0.3.0"
CLIENT_NAME = "shield-bridge"
HEALTH_INTERVAL = 2.0
BACKOFF_MIN = 1.0
BACKOFF_MAX = 30.0
SHELL_TIMEOUT = 15.0
ALLOWED_KEYS = frozenset({
    "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_CENTER", "BACK", "HOME", "MENU",
    "MEDIA_PLAY", "MEDIA_PAUSE", "MEDIA_PLAY_PAUSE", "MEDIA_NEXT", "MEDIA_PREVIOUS",
    "MEDIA_REWIND", "MEDIA_FAST_FORWARD", "SLEEP", "WAKEUP", "POWER", "VOLUME_UP",
    "VOLUME_DOWN", "MUTE", "CHANNEL_UP", "CHANNEL_DOWN",
})
PACKAGE_RE = re.compile(r"[A-Za-z0-9_.]+")
WAKE_RE = re.compile(r"mWakefulness=(\w+)")
FOCUS_RE = re.compile(r"\bu\d+ ([A-Za-z0-9_.]+)/")
PACKAGE_LINE_RE = re.compile(r"\bpackage=([A-Za-z0-9_.]+)")
PLAYBACK_RE = re.compile(r"PlaybackState \{state=(\d+)")
DESCRIPTION_KEY = "description="
PLAYING_CODES = frozenset({3, 6})  # 6 = buffering, reported as playing
PAUSED_CODE = 2
CODE_NAMES = {3: "playing", 6: "playing", 2: "paused", 1: "stopped"}

log = logging.getLogger("shield-bridge")


class LinkDown(RuntimeError):
    """A transport is not connected, or failed while running a command."""


# ---------------------------------------------------------------- parsers

def parse_wakefulness(text: str) -> bool | None:
    """True when dumpsys reports mWakefulness=Awake; None when the line is absent."""
    match = WAKE_RE.search(text)
    return None if match is None else match.group(1) == "Awake"


def parse_focus(text: str) -> str | None:
    """Package of the focused window, from a 'mCurrentFocus' line; None if unparsable."""
    match = FOCUS_RE.search(text)
    return match.group(1) if match else None


def _clean(value: str) -> str | None:
    value = value.strip()
    return None if value in ("", "null") else value


def _split_metadata(rest: str) -> tuple[str | None, str | None, str | None]:
    """Split 'title, artist, album' from the right, so titles may contain commas."""
    parts = rest.rsplit(", ", 2)
    if len(parts) == 3:
        title, artist, album = parts
    elif len(parts) == 2:
        title, artist, album = parts[0], parts[1], "null"
    else:
        title, artist, album = rest, "null", "null"
    return _clean(title), _clean(artist), _clean(album)


@dataclass
class _Session:
    package: str
    code: int | None = None
    meta: tuple[str | None, str | None, str | None] | None = None


def _first(sessions: list[_Session], codes: frozenset[int] | set[int]) -> _Session | None:
    return next((s for s in sessions if s.code in codes), None)


def parse_media_session(text: str) -> dict[str, Any]:
    """Pick the active media session: playing/buffering first, then paused, else none."""
    sessions: list[_Session] = []
    for raw in text.splitlines():
        line = raw.strip()
        pkg = PACKAGE_LINE_RE.search(line)
        if pkg:
            sessions.append(_Session(pkg.group(1)))
            continue
        if not sessions:
            continue
        current = sessions[-1]
        playback = PLAYBACK_RE.search(line)
        if playback and current.code is None:
            current.code = int(playback.group(1))
        if current.meta is None and "metadata:" in line and DESCRIPTION_KEY in line:
            current.meta = _split_metadata(line.split(DESCRIPTION_KEY, 1)[1])
    chosen = _first(sessions, PLAYING_CODES) or _first(sessions, {PAUSED_CODE})
    if chosen is None:
        return {"app": None, "state": "none", "title": None, "artist": None, "album": None}
    title, artist, album = chosen.meta or (None, None, None)
    assert chosen.code is not None
    return {"app": chosen.package, "state": CODE_NAMES[chosen.code],
            "title": title, "artist": artist, "album": album}


# ---------------------------------------------------------------- config

@dataclass(frozen=True)
class ShieldConfig:
    name: str
    host: str
    adb_port: int


@dataclass(frozen=True)
class Config:
    listen_host: str
    listen_port: int
    token: str
    shields: dict[str, ShieldConfig]
    cert: str
    key: str
    adbkey: str
    poll_seconds: float
    art: dict[str, Any] = field(default_factory=dict)


def load_config(path: Path) -> Config:
    """Read the JSON config; relative cert/key/adbkey paths resolve next to the file."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    base = path.resolve().parent
    shields = {
        name: ShieldConfig(name, str(s["host"]), int(s.get("adb_port", 5555)))
        for name, s in raw.get("shields", {}).items()
    }
    if not shields:
        raise ValueError("config must define at least one shield")
    return Config(
        listen_host=str(raw.get("listen_host", "0.0.0.0")),
        listen_port=int(raw.get("listen_port", 8790)),
        token=str(raw.get("token", "")),
        shields=shields,
        cert=str(base / raw.get("cert", "cert.pem")),
        key=str(base / raw.get("key", "key.pem")),
        adbkey=str(base / raw.get("adbkey", "adbkey")),
        poll_seconds=float(raw.get("poll_seconds", 2)),
        art=dict(raw.get("art", {})),
    )


# ---------------------------------------------------------------- connections

class Link:
    """One persistent connection, re-opened forever with exponential backoff."""

    def __init__(self, label: str, connect: Callable[[], Awaitable[None]],
                 close: Callable[[], Awaitable[None]], healthy: Callable[[], bool]) -> None:
        self.label = label
        self.up = False
        self._connect = connect
        self._close = close
        self._healthy = healthy
        self._dirty = False
        self._kick = asyncio.Event()

    def fail(self, reason: object) -> None:
        """Mark the link down (sync, safe from request handlers); run() reconnects."""
        if self.up:
            log.warning("%s lost: %s", self.label, reason)
        self.up = False
        self._dirty = True
        self._kick.set()

    async def run(self) -> None:
        backoff = BACKOFF_MIN
        while True:
            if self.up and not self._healthy():
                self.fail("health check failed")
            if self._dirty:
                self._dirty = False
                await self._close_quietly()
            if not self.up:
                try:
                    await self._connect()
                except Exception as exc:
                    log.warning("%s connect failed (%s); retry in %.0fs", self.label, exc, backoff)
                    await self._wait(backoff)
                    backoff = min(BACKOFF_MAX, backoff * 2)
                    continue
                self.up = True
                backoff = BACKOFF_MIN
                log.info("%s connected", self.label)
            await self._wait(HEALTH_INTERVAL)

    async def close(self) -> None:
        self.up = False
        await self._close_quietly()

    async def _close_quietly(self) -> None:
        try:
            await self._close()
        except Exception as exc:
            log.debug("%s close: %s", self.label, exc)

    async def _wait(self, seconds: float) -> None:
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(self._kick.wait(), seconds)
        self._kick.clear()


class Shield:
    """Both transports and the polled state for one Shield TV."""

    def __init__(self, cfg: ShieldConfig, bridge: Config) -> None:
        self.cfg = cfg
        self._bridge = bridge
        self._remote: Any = None
        self._dev: Any = None
        self._adb_lock = asyncio.Lock()
        self.v2 = Link(f"{cfg.name} v2", self._v2_connect, self._v2_close, self._v2_healthy)
        self.adb = Link(f"{cfg.name} adb", self._adb_connect, self._adb_close, self._adb_healthy)
        self.awake: bool | None = None
        self.app: str | None = None
        self.now_playing: dict[str, Any] = parse_media_session("")
        self.art_path = ""
        self._art_key: tuple[Any, ...] | None = None
        self._art_task: asyncio.Task[None] | None = None
        self.art = self._make_art(bridge)
        self._tasks: list[asyncio.Task[None]] = []

    def start(self) -> None:
        coros = (self.v2.run(), self.adb.run(), self._poll_loop())
        self._tasks = [asyncio.create_task(c) for c in coros]

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        await self.v2.close()
        await self.adb.close()

    def status(self) -> dict[str, Any]:
        return {"shield": self.cfg.name, "v2_connected": self.v2.up, "adb_connected": self.adb.up,
                "awake": self.awake, "app": self.app, "now_playing": self.now_playing,
                "art": self.art_path, "version": VERSION}

    # -- Remote v2 (key presses)
    async def _v2_connect(self) -> None:
        from androidtvremote2 import AndroidTVRemote

        remote = AndroidTVRemote(CLIENT_NAME, self._bridge.cert, self._bridge.key, self.cfg.host)
        try:
            await remote.async_generate_cert_if_missing()
            await remote.async_connect()
        except Exception:
            with contextlib.suppress(Exception):
                remote.disconnect()
            raise
        self._remote = remote

    async def _v2_close(self) -> None:
        remote, self._remote = self._remote, None
        if remote is not None:
            remote.disconnect()

    def _v2_healthy(self) -> bool:
        return self._remote is not None and bool(getattr(self._remote, "is_available", True))

    def send_key(self, key: str, direction: str = "SHORT") -> None:
        if not self.v2.up or self._remote is None:
            raise LinkDown("remote v2 not connected")
        try:
            self._remote.send_key_command(key, direction)
        except Exception as exc:
            self.v2.fail(exc)
            raise LinkDown(f"remote v2 send failed: {exc}") from exc

    # -- ADB over TCP (launch, state, wake fallback)
    async def _adb_connect(self) -> None:
        from adb_shell.adb_device_async import AdbDeviceTcpAsync
        from adb_shell.auth.sign_pythonrsa import PythonRSASigner

        signer = PythonRSASigner.FromRSAKeyPath(self._bridge.adbkey)
        dev = AdbDeviceTcpAsync(self.cfg.host, self.cfg.adb_port, default_transport_timeout_s=9.0)
        try:
            await dev.connect(rsa_keys=[signer], auth_timeout_s=10.0)
        except Exception:
            with contextlib.suppress(Exception):
                await dev.close()
            raise
        self._dev = dev

    async def _adb_close(self) -> None:
        dev, self._dev = self._dev, None
        if dev is not None:
            await dev.close()

    def _adb_healthy(self) -> bool:
        return self._dev is not None and bool(getattr(self._dev, "available", True))

    async def adb_shell(self, command: str) -> str:
        if not self.adb.up or self._dev is None:
            raise LinkDown("adb not connected")
        async with self._adb_lock:
            try:
                return await asyncio.wait_for(self._dev.shell(command), SHELL_TIMEOUT)
            except Exception as exc:
                self.adb.fail(exc)
                raise LinkDown(f"adb command failed: {exc}") from exc

    async def wake(self) -> str:
        try:
            self.send_key("WAKEUP")
            return "v2"
        except LinkDown as exc:
            log.info("%s: v2 wake unavailable (%s); using ADB", self.cfg.name, exc)
        await self.adb_shell("input keyevent KEYCODE_WAKEUP")
        return "adb"

    async def launch(self, package: str) -> str:
        if not PACKAGE_RE.fullmatch(package):
            raise ValueError("invalid package name")
        return await self.adb_shell(
            f"monkey -p {package} -c android.intent.category.LEANBACK_LAUNCHER 1")

    # -- cover art
    def _make_art(self, bridge: Config) -> Any:
        try:
            from art import ArtResolver
        except Exception as exc:  # art is optional; the bridge works without Pillow
            log.warning("cover art disabled: %s", exc)
            return None
        return ArtResolver(bridge.art, Path(bridge.adbkey).resolve().parent / "art-cache", self._pull_apk)

    async def _pull_apk(self, package: str) -> bytes | None:
        listing = await self.adb_shell(f"pm path {package}")
        paths = re.findall(r"package:(\S+\.apk)", listing)
        if not paths:
            return None
        remote = next((p for p in paths if p.endswith("base.apk")), paths[0])
        if not self.adb.up or self._dev is None:
            raise LinkDown("adb not connected")
        buf = io.BytesIO()
        async with self._adb_lock:
            try:
                await asyncio.wait_for(self._dev.pull(remote, buf), 180.0)
            except Exception as exc:
                self.adb.fail(exc)
                raise LinkDown(f"adb pull failed: {exc}") from exc
        return buf.getvalue()

    async def _resolve_art(self, key: tuple[Any, ...]) -> None:
        app, title, artist, album = key
        art_id = await self.art.resolve(app, title, artist, album)
        if key == self._art_key:
            self.art_path = f"/art/{art_id}" if art_id else ""

    def _update_art(self) -> None:
        np = self.now_playing
        if self.art is None or np.get("state") not in ("playing", "paused") or not np.get("title"):
            self._art_key, self.art_path = None, ""
            return
        key = (np.get("app") or self.app or "", np.get("title") or "", np.get("artist") or "",
               np.get("album") or "")
        if key == self._art_key:
            return
        self._art_key, self.art_path = key, ""
        if self._art_task is not None and not self._art_task.done():
            self._art_task.cancel()
        self._art_task = asyncio.create_task(self._resolve_art(key))

    # -- polling
    async def _poll_loop(self) -> None:
        while True:
            try:
                await self.poll_once()
            except Exception as exc:  # the poller must never die
                log.debug("%s poll: %s", self.cfg.name, exc)
            await asyncio.sleep(self._bridge.poll_seconds)

    async def poll_once(self) -> None:
        if not self.adb.up:
            return
        try:
            wake_text = await self.adb_shell("dumpsys power | grep mWakefulness=")
            focus_text = await self.adb_shell("dumpsys window | grep mCurrentFocus")
            media_text = await self.adb_shell("dumpsys media_session")
        except LinkDown:
            return  # keep the last good state
        awake = parse_wakefulness(wake_text)
        if awake is not None:
            self.awake = awake
        self.app = parse_focus(focus_text)
        self.now_playing = parse_media_session(media_text)
        self._update_art()


# ---------------------------------------------------------------- HTTP

def token_ok(header: str, token: str) -> bool:
    """Constant-time check of 'Authorization: Bearer <token>'. Empty token refuses all."""
    if not token:
        return False
    return hmac.compare_digest(header.encode(), f"Bearer {token}".encode())


def make_app(bridge: Config, shields: dict[str, Shield]) -> web.Application:
    from aiohttp import web

    default = next(iter(shields))

    def error(status: int, message: str) -> web.Response:
        return web.json_response({"ok": False, "error": message}, status=status)

    @web.middleware
    async def guard(request: web.Request, handler: Any) -> web.StreamResponse:
        if request.path == "/healthz" or request.path.startswith("/art/"):
            return await handler(request)
        if not token_ok(request.headers.get("Authorization", ""), bridge.token):
            return error(401, "unauthorized")
        shield = shields.get(request.query.get("shield", default))
        if shield is None:
            return error(404, "unknown shield")
        request["shield"] = shield
        return await handler(request)

    async def status(request: web.Request) -> web.Response:
        return web.json_response(request["shield"].status())

    async def key(request: web.Request) -> web.Response:
        name = request.query.get("name", "")
        if name not in ALLOWED_KEYS:
            return error(400, "unknown key name")
        try:
            d = {"start": "START_LONG", "end": "END_LONG"}.get(request.query.get("dir", ""), "SHORT")
            request["shield"].send_key(name, d)
        except LinkDown as exc:
            return error(503, str(exc))
        return web.json_response({"ok": True, "key": name})

    async def wake(request: web.Request) -> web.Response:
        try:
            via = await request["shield"].wake()
        except LinkDown as exc:
            return error(503, str(exc))
        return web.json_response({"ok": True, "via": via})

    async def sleep(request: web.Request) -> web.Response:
        try:
            request["shield"].send_key("SLEEP")
        except LinkDown as exc:
            return error(503, str(exc))
        return web.json_response({"ok": True})

    async def launch(request: web.Request) -> web.Response:
        package = request.query.get("package", "")
        try:
            output = await request["shield"].launch(package)
        except ValueError:
            return error(400, "invalid package name")
        except LinkDown as exc:
            return error(503, str(exc))
        if "Events injected" not in output:
            return web.json_response(
                {"ok": False, "error": "launch failed", "output": output[-300:]}, status=502)
        return web.json_response({"ok": True})

    async def art_image(request: web.Request) -> web.Response:
        art_id = request.match_info["art_id"]
        for shield in shields.values():
            found = shield.art.get(art_id) if shield.art is not None else None
            if found:
                return web.Response(body=found[0], content_type=found[1],
                                    headers={"Cache-Control": "max-age=3600"})
        return web.Response(status=404)

    async def healthz(_request: web.Request) -> web.Response:
        return web.json_response({"ok": True})

    async def start_shields(_app: web.Application) -> None:
        for shield in shields.values():
            shield.start()

    async def stop_shields(_app: web.Application) -> None:
        for shield in shields.values():
            await shield.stop()

    app = web.Application(middlewares=[guard])
    app.router.add_get("/v1/status", status)
    app.router.add_post("/v1/key", key)
    app.router.add_post("/v1/wake", wake)
    app.router.add_post("/v1/sleep", sleep)
    app.router.add_post("/v1/launch", launch)
    app.router.add_get("/healthz", healthz)
    app.router.add_get("/art/{art_id}", art_image)
    app.on_startup.append(start_shields)
    app.on_cleanup.append(stop_shields)
    return app


# ---------------------------------------------------------------- main

def ensure_adb_key(path: str) -> None:
    if Path(path).exists() and Path(path + ".pub").exists():
        return
    from adb_shell.auth.keygen import keygen

    keygen(path)
    log.info("generated ADB key pair at %s", path)


SAMPLE_PAUSED = """\
  Sessions Stack - have 2 sessions:
    package=com.plexapp.android
    state=PlaybackState {state=1, position=0}
    metadata: size=3, description=Home, null, null
    package=com.spotify.music
    state=PlaybackState {state=2, position=41000}
    metadata: size=22, description=how it starts, elijah, null
"""

SAMPLE_MIXED = SAMPLE_PAUSED + """\
    package=com.google.android.youtube.tv
    state=PlaybackState {state=3, position=1200}
    metadata: size=22, description=Hello, world, The Band, Album Name
"""

SAMPLE_STOPPED = """\
    package=com.plexapp.android
    state=PlaybackState {state=1, position=0}
    metadata: size=3, description=Home, null, null
"""


def selftest() -> int:
    paused = {"app": "com.spotify.music", "state": "paused",
              "title": "how it starts", "artist": "elijah", "album": None}
    playing = {"app": "com.google.android.youtube.tv", "state": "playing",
               "title": "Hello, world", "artist": "The Band", "album": "Album Name"}
    none = {"app": None, "state": "none", "title": None, "artist": None, "album": None}
    cases: list[tuple[str, object, object]] = [
        ("wake awake", parse_wakefulness("  mWakefulness=Awake"), True),
        ("wake asleep", parse_wakefulness("mWakefulness=Asleep"), False),
        ("wake absent", parse_wakefulness(""), None),
        ("focus", parse_focus("mCurrentFocus=Window{1a2 u0 com.plexapp.android/com.plexapp.Main}"),
         "com.plexapp.android"),
        ("focus null", parse_focus("mCurrentFocus=null"), None),
        ("media paused", parse_media_session(SAMPLE_PAUSED), paused),
        ("media playing wins over paused", parse_media_session(SAMPLE_MIXED), playing),
        ("media stopped is none", parse_media_session(SAMPLE_STOPPED), none),
        ("media empty", parse_media_session(""), none),
        ("token ok", token_ok("Bearer abc", "abc"), True),
        ("token wrong", token_ok("Bearer abd", "abc"), False),
        ("token empty refuses all", token_ok("Bearer ", ""), False),
        ("package ok", bool(PACKAGE_RE.fullmatch("com.plexapp.android")), True),
        ("package injection refused", bool(PACKAGE_RE.fullmatch("x;rm -rf /")), False),
    ]
    failed = 0
    for label, got, want in cases:
        if got != want:
            failed += 1
            print(f"FAIL {label}: got {got!r}, want {want!r}")
    print(f"selftest: {len(cases) - failed}/{len(cases)} passed")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    bridge = load_config(Path(argv[1] if len(argv) > 1 else "config.json"))
    if not bridge.token:
        log.warning("token is empty: every request will be refused")
    ensure_adb_key(bridge.adbkey)
    from aiohttp import web

    shields = {name: Shield(cfg, bridge) for name, cfg in bridge.shields.items()}
    web.run_app(make_app(bridge, shields), host=bridge.listen_host,
                port=bridge.listen_port, print=None)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
