#!/usr/bin/env python3
"""Local bridge between a Control4 driver and a U by Moen shower (HomeKit).

The shower is controlled over HomeKit with aiohomekit. Control4 talks to this
bridge over TCP using one JSON object per line (UTF-8). See README.md.

Run on the Linux host:  python moen_bridge.py --config /home/liesa/moen-bridge.json
Test without hardware:  python moen_bridge.py --mock --config /path/to/test.json
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import copy
import json
import logging
import os
import time
from typing import Any

log = logging.getLogger("moen_bridge")

# HomeKit ids for the shower (accessory 1), verified on the real device.
AID = 1
IID_FAUCET_ACTIVE = 9            # shower water on/off (read/write)
IID_HEATER_ACTIVE = 12           # heater active (read/write)
IID_CURRENT_TEMP_C = 13          # current water temperature, Celsius (read)
IID_TARGET_TEMP_C = 16           # heating threshold = target temperature, Celsius (read/write)
IID_OUTLET_IID = {1: 18, 2: 23}  # valve active per outlet (read/write)
POLL_IIDS = [9, 12, 13, 16, 18, 23]

HARD_MAX_F = 120                 # absolute ceiling, whatever the config says
MAX_LINE = 4096                  # longest accepted protocol line, in bytes
FAST_POLL_SECONDS = 1.0          # poll rate right after a command ...
FAST_POLL_WINDOW = 10.0          # ... for this many seconds
DEVICE_CMDS = {"on", "off", "set_temp", "outlet", "preset"}

DEFAULT_CONFIG: dict[str, Any] = {
    "pairing_file": "/home/liesa/moen-hk.json",
    "pairing_alias": "moen",
    "bind": "0.0.0.0",
    "port": 8765,
    "allowed_clients": [],
    "min_f": 80,
    "max_f": 120,
    "poll_interval": 5,
    "write_heater_active_on_start": False,
    "presets": [
        {"n": 1, "title": "Hot", "temp_f": 117, "outlets": [1, 2]},
        {"n": 2, "title": "Comfortable", "temp_f": 108, "outlets": [1, 2]},
    ],
}


class CmdError(Exception):
    """A client-visible error. Sent back to the client as an error line."""


class BackendError(Exception):
    """A HomeKit or backend failure."""


def f_to_c(f: int) -> float:
    return round((f - 32) * 5 / 9, 2)


def c_to_f(c: float) -> int:
    return int(round(c * 9 / 5 + 32))


def clamp_f(f: int, cfg: dict[str, Any]) -> int:
    """Clamp a Fahrenheit target into [min_f, min(max_f, HARD_MAX_F)]."""
    hi = min(int(cfg["max_f"]), HARD_MAX_F)
    return max(int(cfg["min_f"]), min(hi, int(f)))


def normalize_preset(p: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any]:
    return {
        "n": int(p["n"]),
        "title": str(p.get("title", ""))[:40],
        "temp_f": clamp_f(int(p["temp_f"]), cfg),
        "outlets": sorted({int(x) for x in p.get("outlets", []) if int(x) in (1, 2)}),
    }


def load_config(path: str) -> dict[str, Any]:
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            cfg.update(json.load(fh))
        log.info("loaded config %s", path)
    else:
        log.warning("config %s not found, using built-in defaults", path)
    if int(cfg["min_f"]) > int(cfg["max_f"]):
        raise SystemExit("config error: min_f is greater than max_f")
    cfg["presets"] = [normalize_preset(p, cfg) for p in cfg["presets"]]
    return cfg


def save_config(path: str, cfg: dict[str, Any]) -> None:
    """Write the config atomically: write a temp file, then replace."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    log.info("config saved to %s", path)


class ShowerBackend:
    """Common state and helpers. Subclasses implement run() and _write()."""

    def __init__(self, cfg: dict[str, Any]) -> None:
        self.cfg = cfg
        self.connected = False
        self.values: dict[int, Any] = {}     # iid -> last known value
        self.on_change = lambda: None        # set by Bridge
        self._wake: asyncio.Event | None = None
        self._fast_until = 0.0

    def _set_connected(self, flag: bool) -> None:
        if flag != self.connected:
            self.connected = flag
            log.info("shower %s", "connected" if flag else "disconnected")
            self.on_change()

    def _apply(self, changes: dict[int, Any]) -> None:
        changed = False
        for iid, val in changes.items():
            if self.values.get(iid) != val:
                self.values[iid] = val
                changed = True
        if changed:
            self.on_change()

    def outlets_on(self) -> list[bool]:
        return [bool(self.values.get(IID_OUTLET_IID[1])),
                bool(self.values.get(IID_OUTLET_IID[2]))]

    async def write(self, iid: int, value: Any, why: str) -> None:
        """Every HomeKit write goes through here so that it is logged."""
        log.info("HomeKit write aid=%d iid=%d value=%r (%s)", AID, iid, value, why)
        try:
            await self._write(iid, value)
        except Exception as exc:
            log.warning("HomeKit write failed iid=%d: %s", iid, exc)
            self._set_connected(False)
            if self._wake is not None:
                self._wake.set()
            raise BackendError(str(exc)) from exc
        self._apply({iid: value})

    def request_fast_poll(self) -> None:
        self._fast_until = time.monotonic() + FAST_POLL_WINDOW
        if self._wake is not None:
            self._wake.set()

    async def _write(self, iid: int, value: Any) -> None:
        raise NotImplementedError

    async def run(self) -> None:
        raise NotImplementedError

    async def close(self) -> None:
        return None


class MockShower(ShowerBackend):
    """In-memory shower for testing. Water temperature drifts toward the target while running."""

    MOCK_IIDS = {IID_FAUCET_ACTIVE, IID_HEATER_ACTIVE, IID_TARGET_TEMP_C,
                 IID_OUTLET_IID[1], IID_OUTLET_IID[2]}

    async def run(self) -> None:
        self._wake = asyncio.Event()
        self._apply({
            IID_FAUCET_ACTIVE: False,
            IID_HEATER_ACTIVE: False,
            IID_CURRENT_TEMP_C: f_to_c(84),
            IID_TARGET_TEMP_C: f_to_c(100),
            IID_OUTLET_IID[1]: False,
            IID_OUTLET_IID[2]: False,
        })
        self._set_connected(True)
        log.warning("MOCK mode: no real shower is involved")
        while True:
            await asyncio.sleep(1.0)
            self._drift()

    def _drift(self) -> None:
        cur = self.values.get(IID_CURRENT_TEMP_C, f_to_c(84))
        if self.values.get(IID_FAUCET_ACTIVE):
            target = self.values.get(IID_TARGET_TEMP_C, cur)
            step = max(-0.5, min(0.5, target - cur))
        else:
            step = max(-0.2, min(0.2, f_to_c(72) - cur))
        if abs(step) > 0.005:
            self._apply({IID_CURRENT_TEMP_C: round(cur + step, 2)})

    async def _write(self, iid: int, value: Any) -> None:
        if iid not in self.MOCK_IIDS:
            raise BackendError(f"mock: iid {iid} not supported")


class HomeKitShower(ShowerBackend):
    """Talks to the real shower over HomeKit (aiohomekit). Imports are lazy."""

    def __init__(self, cfg: dict[str, Any]) -> None:
        super().__init__(cfg)
        self._stack: contextlib.AsyncExitStack | None = None
        self._ctrl: Any = None
        self._azc: Any = None
        self._browser: Any = None
        self._pairing: Any = None
        self._unsub: Any = None

    async def _ensure_controller(self) -> None:
        if self._pairing is not None:
            return
        # The pairing file holds secrets: it is read here and never logged.
        with open(self.cfg["pairing_file"], "r", encoding="utf-8") as fh:
            pairing_data = json.load(fh)
        from aiohomekit import Controller
        from zeroconf import ServiceListener
        from zeroconf.asyncio import AsyncServiceBrowser, AsyncZeroconf

        class _Listener(ServiceListener):
            def add_service(self, zc, type_, name):
                pass

            def remove_service(self, zc, type_, name):
                pass

            def update_service(self, zc, type_, name):
                pass

        # The zeroconf browser must exist before the Controller starts.
        self._azc = AsyncZeroconf()
        self._browser = AsyncServiceBrowser(
            self._azc.zeroconf, ["_hap._tcp.local.", "_hap._udp.local."], listener=_Listener())
        self._stack = contextlib.AsyncExitStack()
        self._ctrl = await self._stack.enter_async_context(
            Controller(async_zeroconf_instance=self._azc))
        self._pairing = self._ctrl.load_pairing(self.cfg["pairing_alias"], pairing_data)
        self._unsub = self._pairing.dispatcher_connect(self._on_event)
        del pairing_data

    def _on_event(self, changes: Any) -> None:
        """Push events from the accessory. Called in the event loop; must not block."""
        if not isinstance(changes, dict) or not changes:
            # Empty event = connection (re)established. Resync by polling now.
            if self._wake is not None:
                self._wake.set()
            return
        updates: dict[int, Any] = {}
        for key, data in changes.items():
            try:
                aid, iid = key
            except (TypeError, ValueError):
                continue
            if aid == AID and isinstance(data, dict) and "value" in data:
                updates[iid] = data["value"]
        if updates:
            self._apply(updates)

    async def _read_all(self) -> dict[int, Any]:
        res = await self._pairing.get_characteristics([(AID, iid) for iid in POLL_IIDS])
        out: dict[int, Any] = {}
        for (aid, iid), data in res.items():
            if aid == AID and isinstance(data, dict) and "value" in data:
                out[iid] = data["value"]
        return out

    async def _write(self, iid: int, value: Any) -> None:
        res = await self._pairing.put_characteristics([(AID, iid, value)])
        if isinstance(res, dict):
            for _key, data in res.items():
                if isinstance(data, dict) and data.get("status", 0) != 0:
                    raise BackendError(f"HomeKit status {data['status']}")

    async def _connect(self) -> None:
        await self._ensure_controller()
        last: Exception | None = None
        for attempt in range(3):
            try:
                accs = await self._pairing.list_accessories_and_characteristics()
                log.info("accessory list ok (%d accessories)", len(accs))
                break
            except Exception as exc:  # AccessoryDisconnectedError on first try is normal
                last = exc
                log.info("accessory list attempt %d failed: %s", attempt + 1, exc)
                await asyncio.sleep(2)
        else:
            raise ConnectionError(f"accessory list failed: {last}")
        try:
            await self._pairing.subscribe([(AID, iid) for iid in POLL_IIDS])
        except Exception as exc:
            log.warning("subscribe failed, polling only: %s", exc)
        self._apply(await self._read_all())
        self._set_connected(True)

    async def run(self) -> None:
        self._wake = asyncio.Event()
        backoff = 2.0
        while True:
            if not self.connected:
                try:
                    await self._connect()
                    backoff = 2.0
                except Exception as exc:
                    log.warning("connect failed: %s; retry in %.0fs", exc, backoff)
                    self._set_connected(False)
                    await asyncio.sleep(backoff)
                    backoff = min(60.0, backoff * 2)
                    continue
            try:
                self._apply(await self._read_all())
            except Exception as exc:
                log.warning("poll failed: %s", exc)
                self._set_connected(False)
                continue
            interval = (FAST_POLL_SECONDS if time.monotonic() < self._fast_until
                        else float(self.cfg["poll_interval"]))
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._wake.wait(), interval)
            self._wake.clear()

    async def close(self) -> None:
        if self._unsub is not None:
            self._unsub()
        if self._stack is not None:
            await self._stack.aclose()
        if self._browser is not None:
            await self._browser.async_cancel()
        if self._azc is not None:
            await self._azc.async_close()


class Bridge:
    """TCP JSON server. Owns the state published to clients and the command rules."""

    def __init__(self, cfg: dict[str, Any], cfg_path: str, backend: ShowerBackend) -> None:
        self.cfg = cfg
        self.cfg_path = cfg_path
        self.backend = backend
        backend.on_change = self.publish
        self.clients: set[asyncio.StreamWriter] = set()
        self.seq = 0
        self._last_key: str | None = None
        self.lock = asyncio.Lock()

    # ----- state -----

    def _clamp(self, f: int) -> int:
        return clamp_f(f, self.cfg)

    def _core(self) -> dict[str, Any]:
        b = self.backend
        target_c = b.values.get(IID_TARGET_TEMP_C)
        cur_c = b.values.get(IID_CURRENT_TEMP_C)
        target_f = c_to_f(target_c) if target_c is not None else None
        on = bool(b.values.get(IID_FAUCET_ACTIVE, False))
        outlets = b.outlets_on()
        active = 0
        if on and target_f is not None:
            on_set = [n for n, v in enumerate(outlets, 1) if v]
            for p in self.cfg["presets"]:
                if p["temp_f"] == target_f and p["outlets"] == on_set:
                    active = p["n"]
                    break
        return {
            "shower_connected": b.connected,
            "on": on,
            "current_f": c_to_f(cur_c) if cur_c is not None else None,
            "target_f": target_f,
            "outlets": outlets,
            "active_preset": active,
            "presets": [{"n": p["n"], "title": p["title"], "temp_f": p["temp_f"],
                         "outlets": p["outlets"]} for p in self.cfg["presets"]],
            "max_f": self.cfg["max_f"],
            "min_f": self.cfg["min_f"],
        }

    def _state_line(self) -> bytes:
        return (json.dumps({"event": "state", **self._core(), "seq": self.seq}) + "\n").encode()

    def publish(self, force: bool = False) -> None:
        """Broadcast the state to every client if it changed (or if forced)."""
        core = self._core()
        key = json.dumps(core, sort_keys=True)
        if key == self._last_key and not force:
            return
        self._last_key = key
        self.seq += 1
        line = (json.dumps({"event": "state", **core, "seq": self.seq}) + "\n").encode()
        for w in list(self.clients):
            if w.is_closing():
                self.clients.discard(w)
                continue
            try:
                w.write(line)
            except Exception:
                self.clients.discard(w)

    @staticmethod
    def _send(writer: asyncio.StreamWriter, obj: dict[str, Any]) -> None:
        with contextlib.suppress(Exception):
            writer.write((json.dumps(obj) + "\n").encode())

    # ----- command helpers -----

    def _parse_f(self, value: Any) -> int:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise CmdError("temperature must be a number")
        return self._clamp(int(round(value)))

    def _find_preset(self, n: Any) -> dict[str, Any]:
        for p in self.cfg["presets"]:
            if p["n"] == n:
                return p
        raise CmdError("no such preset")

    async def _apply_settings(self, target_f: int, outlets_on: list[int]) -> None:
        """Write the target temperature and outlet valves. Never starts the water."""
        await self.backend.write(IID_TARGET_TEMP_C, f_to_c(self._clamp(target_f)), "target temp")
        for n, iid in IID_OUTLET_IID.items():
            await self.backend.write(iid, 1 if n in outlets_on else 0, f"outlet {n}")

    async def _start_water(self) -> None:
        """SAFETY: the ONLY code that writes faucet-active = 1 (water on).

        Called only from the 'on' and 'preset' commands. UNVERIFIED on real
        hardware: whether iid 9 alone is enough. The heater write (iid 12) is
        optional and controlled by write_heater_active_on_start.
        """
        if self.cfg["write_heater_active_on_start"]:
            await self.backend.write(IID_HEATER_ACTIVE, 1, "heater active on start")
        await self.backend.write(IID_FAUCET_ACTIVE, 1, "WATER ON, explicit on/preset command")

    async def _cmd_on(self) -> None:
        target_c = self.backend.values.get(IID_TARGET_TEMP_C)
        if target_c is None:
            raise CmdError("target temperature unknown")
        outlets_on = [n for n, v in enumerate(self.backend.outlets_on(), 1) if v]
        await self._apply_settings(c_to_f(target_c), outlets_on)
        await self._start_water()

    async def _cmd_preset(self, msg: dict[str, Any]) -> None:
        p = self._find_preset(msg.get("n"))
        await self._apply_settings(p["temp_f"], p["outlets"])
        await self._start_water()

    def _cmd_set_preset(self, msg: dict[str, Any]) -> None:
        n = msg.get("n")
        if isinstance(n, bool) or not isinstance(n, int) or n < 1:
            raise CmdError("n must be a positive integer")
        title = msg.get("title")
        if not isinstance(title, str):
            raise CmdError("title must be a string")
        temp_f = self._parse_f(msg.get("temp_f"))
        outlets = msg.get("outlets", [])
        if not isinstance(outlets, list) or any(
                isinstance(x, bool) or x not in (1, 2) for x in outlets):
            raise CmdError("outlets must be a list of 1 and/or 2")
        new = {"n": n, "title": title[:40], "temp_f": temp_f,
               "outlets": sorted({int(x) for x in outlets})}
        old = self.cfg["presets"]
        presets = sorted([p for p in old if p["n"] != n] + [new], key=lambda p: p["n"])
        self.cfg["presets"] = presets
        try:
            save_config(self.cfg_path, self.cfg)
        except OSError as exc:
            self.cfg["presets"] = old
            raise CmdError("could not save config") from exc
        log.info("preset %d saved: %r %dF outlets=%s", n, new["title"], temp_f, new["outlets"])

    async def _execute(self, msg: dict[str, Any], ip: str) -> None:
        cmd = msg.get("cmd")
        if not isinstance(cmd, str):
            raise CmdError("missing cmd")
        if cmd in DEVICE_CMDS and not self.backend.connected:
            raise CmdError("shower not connected")
        log.info("cmd %s from %s %s", cmd, ip, {k: v for k, v in msg.items() if k != "cmd"})
        if cmd == "get_state":
            return
        if cmd == "on":
            await self._cmd_on()
        elif cmd == "off":
            await self.backend.write(IID_FAUCET_ACTIVE, 0, "water off")
        elif cmd == "set_temp":
            if not self.backend.values.get(IID_FAUCET_ACTIVE):
                raise CmdError("shower not running")
            f = self._parse_f(msg.get("f"))
            await self.backend.write(IID_TARGET_TEMP_C, f_to_c(f), "set_temp")
        elif cmd == "outlet":
            n = msg.get("n")
            if isinstance(n, bool) or n not in (1, 2):
                raise CmdError("n must be 1 or 2")
            on = msg.get("on")
            if not isinstance(on, bool):
                raise CmdError("on must be true or false")
            await self.backend.write(IID_OUTLET_IID[n], 1 if on else 0, f"outlet {n}")
        elif cmd == "preset":
            await self._cmd_preset(msg)
        elif cmd == "set_preset":
            self._cmd_set_preset(msg)
        else:
            raise CmdError("unknown cmd")

    # ----- TCP server -----

    async def _handle_line(self, line: bytes, writer: asyncio.StreamWriter, ip: str) -> None:
        try:
            msg = json.loads(line.decode("utf-8"))
            if not isinstance(msg, dict):
                raise ValueError("not an object")
        except (UnicodeDecodeError, ValueError):
            self._send(writer, {"event": "error", "msg": "bad json, expected one object per line"})
            return
        async with self.lock:
            try:
                await self._execute(msg, ip)
            except CmdError as exc:
                self._send(writer, {"event": "error", "msg": str(exc)})
                return
            except BackendError as exc:
                log.warning("command %s failed: %s", msg.get("cmd"), exc)
                self._send(writer, {"event": "error", "msg": f"device error: {exc}"})
                return
            except Exception:
                log.exception("command %s failed", msg.get("cmd"))
                self._send(writer, {"event": "error", "msg": "internal error"})
                return
            if msg.get("cmd") == "get_state":
                writer.write(self._state_line())
                return
            if msg.get("cmd") in DEVICE_CMDS:
                self.backend.request_fast_poll()
            self.publish(force=True)   # the fresh state line answers the command

    async def _handle_client(self, reader: asyncio.StreamReader,
                             writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        ip = peer[0] if peer else "?"
        allowed = self.cfg.get("allowed_clients") or []
        if allowed and ip not in allowed:
            log.warning("rejected client %s (not in allowed_clients)", ip)
            writer.close()
            return
        log.info("client connected %s", ip)
        self.clients.add(writer)
        writer.write(self._state_line())
        try:
            while True:
                try:
                    line = await reader.readline()
                except ValueError:
                    self._send(writer, {"event": "error", "msg": "line too long"})
                    break
                except (ConnectionError, OSError):
                    break
                if not line:
                    break
                await self._handle_line(line, writer, ip)
        finally:
            self.clients.discard(writer)
            writer.close()
            log.info("client disconnected %s", ip)

    async def _serve(self) -> None:
        server = await asyncio.start_server(
            self._handle_client, self.cfg["bind"], int(self.cfg["port"]), limit=MAX_LINE)
        log.info("listening on %s:%s", self.cfg["bind"], self.cfg["port"])
        async with server:
            await server.serve_forever()

    async def run(self) -> None:
        self.publish(force=True)
        task = asyncio.create_task(self.backend.run())

        def _report(t: asyncio.Task) -> None:
            if not t.cancelled() and t.exception() is not None:
                log.error("shower backend stopped: %s", t.exception())

        task.add_done_callback(_report)
        try:
            await self._serve()
        finally:
            task.cancel()
            await self.backend.close()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="U by Moen shower bridge for Control4")
    ap.add_argument("--config", default=os.path.join(here, "moen-bridge.json"),
                    help="path to the JSON config file")
    ap.add_argument("--mock", action="store_true",
                    help="simulate the shower in memory (no HomeKit needed)")
    ap.add_argument("--port", type=int, default=None, help="override the config port")
    ap.add_argument("--log-level", default="INFO",
                    choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    return ap.parse_args(argv)


async def _amain(args: argparse.Namespace) -> None:
    cfg = load_config(args.config)
    if args.port is not None:
        cfg["port"] = args.port
    backend: ShowerBackend = MockShower(cfg) if args.mock else HomeKitShower(cfg)
    bridge = Bridge(cfg, args.config, backend)
    await bridge.run()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=getattr(logging, args.log_level),
                        format="%(asctime)s %(levelname)s %(message)s")
    try:
        asyncio.run(_amain(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
