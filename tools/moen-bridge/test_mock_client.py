#!/usr/bin/env python3
"""Exercise moen_bridge.py in --mock mode over TCP. No hardware or HomeKit needed.

It starts the bridge itself with a temporary config, runs every command, checks
the safety rules, then stops the bridge. Exit code 0 means all checks passed.
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import json
import os
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "moen_bridge.py")

PASSED = 0


def check(cond: bool, label: str) -> None:
    global PASSED
    if not cond:
        raise AssertionError(f"FAILED: {label}")
    PASSED += 1
    print(f"  ok  {label}")


class Client:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.r = reader
        self.w = writer
        self.last_state: dict[str, Any] | None = None
        self.last_seq = 0

    async def send_raw(self, text: str) -> None:
        self.w.write((text + "\n").encode())
        await self.w.drain()

    async def send(self, obj: dict[str, Any]) -> None:
        await self.send_raw(json.dumps(obj))

    async def line(self, timeout: float = 5.0) -> dict[str, Any]:
        raw = await asyncio.wait_for(self.r.readline(), timeout)
        if not raw:
            raise EOFError("connection closed")
        msg = json.loads(raw)
        if msg.get("event") == "state":
            check(msg["seq"] >= self.last_seq, "seq never goes backwards")
            self.last_seq = msg["seq"]
            self.last_state = msg
        return msg

    async def until(self, pred: Callable[[dict[str, Any]], bool], timeout: float = 5.0) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise AssertionError("timed out waiting for a matching line")
            msg = await self.line(left)
            if msg["event"] == "error" or pred(msg):
                return msg

    async def ok(self, obj: dict[str, Any], pred: Callable[[dict[str, Any]], bool], label: str) -> dict[str, Any]:
        await self.send(obj)
        msg = await self.until(lambda m: m["event"] == "error" or (m["event"] == "state" and pred(m)))
        check(msg["event"] == "state", f"{label} (got {msg})")
        check(pred(msg), label)
        return msg

    async def err(self, obj: dict[str, Any] | str, substr: str, label: str) -> None:
        if isinstance(obj, str):
            await self.send_raw(obj)
        else:
            await self.send(obj)
        msg = await self.until(lambda m: m["event"] == "error")
        check(msg["event"] == "error" and substr in msg["msg"], f"{label} (got {msg})")


async def connect(port: int) -> Client:
    for _ in range(100):
        try:
            r, w = await asyncio.open_connection("127.0.0.1", port)
            return Client(r, w)
        except OSError:
            await asyncio.sleep(0.1)
    raise RuntimeError(f"bridge not listening on port {port}")


def write_config(path: str, extra: dict[str, Any] | None = None) -> None:
    cfg: dict[str, Any] = {
        "pairing_file": "/nonexistent/unused-in-mock.json",
        "bind": "127.0.0.1",
        "min_f": 80,
        "max_f": 120,
        "write_heater_active_on_start": False,
        "presets": [
            {"n": 1, "title": "Hot", "temp_f": 117, "outlets": [1, 2]},
            {"n": 2, "title": "Comfortable", "temp_f": 108, "outlets": [1, 2]},
        ],
    }
    cfg.update(extra or {})
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)


def start_bridge(cfg_path: str, port: int, log_path: str) -> subprocess.Popen:
    log_fh = open(log_path, "w", encoding="utf-8")
    return subprocess.Popen(
        [sys.executable, BRIDGE, "--mock", "--config", cfg_path, "--port", str(port),
         "--log-level", "INFO"],
        stdout=log_fh, stderr=subprocess.STDOUT)


async def run_main_suite(port: int, cfg_path: str) -> None:
    c = await connect(port)
    print("startup and safety")
    first = json.loads(await c.r.readline())
    check(first["event"] == "state" and first["shower_connected"] is True, "state line sent on connect")
    check(first["on"] is False, "shower starts off")
    check(first["max_f"] == 120 and first["min_f"] == 80, "limits reported")
    check(len(first["presets"]) == 2, "default presets present")
    check(first["target_f"] == 100 and first["current_f"] == 84, "mock start values are 100F target, 84F current")

    await c.err({"cmd": "set_temp", "f": 110}, "shower not running", "set_temp refused while off")
    await c.ok({"cmd": "get_state"}, lambda m: m["on"] is False, "get_state does not start water")

    print("outlets")
    await c.ok({"cmd": "outlet", "n": 1, "on": True}, lambda m: m["outlets"] == [True, False], "outlet 1 on")
    await c.err({"cmd": "outlet", "n": 3, "on": True}, "n must be 1 or 2", "outlet 3 rejected")
    await c.err({"cmd": "outlet", "n": 1, "on": "yes"}, "on must be true or false", "outlet value must be bool")
    await c.ok({"cmd": "outlet", "n": 2, "on": True}, lambda m: m["outlets"] == [True, True], "outlet 2 on")

    print("on / temperature clamping")
    await c.ok({"cmd": "on"}, lambda m: m["on"] is True and m["target_f"] == 100 and m["outlets"] == [True, True],
               "on uses current target and outlets")
    await c.ok({"cmd": "set_temp", "f": 130}, lambda m: m["target_f"] == 120, "130F clamped to 120F")
    await c.ok({"cmd": "set_temp", "f": 50}, lambda m: m["target_f"] == 80, "50F clamped to 80F")
    await c.ok({"cmd": "set_temp", "f": 110}, lambda m: m["target_f"] == 110, "set_temp 110F")

    print("presets")
    await c.ok({"cmd": "off"}, lambda m: m["on"] is False, "off")
    await c.ok({"cmd": "preset", "n": 1}, lambda m: m["on"] is True and m["target_f"] == 117
               and m["outlets"] == [True, True] and m["active_preset"] == 1, "preset 1 starts Hot 117F")
    await c.ok({"cmd": "off"}, lambda m: m["on"] is False, "off again")
    await c.err({"cmd": "preset", "n": 9}, "no such preset", "unknown preset rejected")
    await c.ok({"cmd": "preset", "n": 2}, lambda m: m["on"] is True and m["target_f"] == 108
               and m["active_preset"] == 2, "preset 2 starts Comfortable 108F")

    print("set_preset (config only, must not start water)")
    await c.ok({"cmd": "off"}, lambda m: m["on"] is False, "off before set_preset")
    await c.ok({"cmd": "set_preset", "n": 3, "title": "Test", "temp_f": 130, "outlets": [2]},
               lambda m: len(m["presets"]) == 3 and m["presets"][2]["temp_f"] == 120
               and m["presets"][2]["outlets"] == [2] and m["on"] is False,
               "set_preset clamps 130F to 120F and does not start water")
    with open(cfg_path, encoding="utf-8") as fh:
        saved = json.load(fh)
    check(any(p["n"] == 3 and p["temp_f"] == 120 and p["outlets"] == [2] for p in saved["presets"]),
          "set_preset written to config file")
    check(not os.path.exists(cfg_path + ".tmp"), "no temp file left behind")
    await c.err({"cmd": "set_preset", "n": 0, "title": "x", "temp_f": 100, "outlets": []},
                "n must be a positive integer", "set_preset rejects n=0")
    await c.err({"cmd": "set_preset", "n": 4, "title": "x", "temp_f": 100, "outlets": [3]},
                "outlets must be", "set_preset rejects outlet 3")
    await c.ok({"cmd": "preset", "n": 3}, lambda m: m["on"] is True and m["target_f"] == 120
               and m["outlets"] == [False, True] and m["active_preset"] == 3, "preset 3 runs at 120F, outlet 2 only")
    await c.ok({"cmd": "off"}, lambda m: m["on"] is False, "off")

    print("errors and robustness")
    await c.err("not json", "bad json", "bad json answered with error, connection kept")
    await c.err({"cmd": "dance"}, "unknown cmd", "unknown cmd rejected")
    await c.err({"foo": 1}, "missing cmd", "missing cmd rejected")
    await c.err({"cmd": "set_temp", "f": "hot"}, "shower not running", "set_temp refused while off, before type check")

    print("mock drift")
    await c.ok({"cmd": "on"}, lambda m: m["on"] is True, "on")
    before = c.last_state["current_f"]
    await asyncio.sleep(3.5)
    await c.send({"cmd": "get_state"})
    while True:  # read everything queued, including drift broadcasts; the reply comes last
        try:
            await c.line(0.5)
        except TimeoutError:
            break
    check(c.last_state["on"] is True, "get_state while running reports on")
    check(c.last_state["current_f"] != before,
          f"water temperature drifts ({before}F -> {c.last_state['current_f']}F)")
    await c.ok({"cmd": "off"}, lambda m: m["on"] is False, "off after drift test")
    await c.ok({"cmd": "get_state"}, lambda m: m["on"] is False, "still off after waiting (no spontaneous start)")
    await asyncio.sleep(2.5)
    await c.ok({"cmd": "get_state"}, lambda m: m["on"] is False, "still off after waiting 2.5 s")

    c.w.close()


async def run_allowed_clients_check(port: int, tmpdir: str) -> None:
    print("allowed_clients")
    cfg_path = os.path.join(tmpdir, "allowed.json")
    write_config(cfg_path, {"allowed_clients": ["203.0.113.9"]})
    log_path = os.path.join(tmpdir, "allowed.log")
    proc = start_bridge(cfg_path, port, log_path)
    try:
        c = await connect(port)
        try:
            data = await asyncio.wait_for(c.r.readline(), 5)
        except ConnectionResetError:
            data = b""
        check(data == b"", "client not in allowed_clients is disconnected")
        c.w.close()
    finally:
        proc.terminate()
        proc.wait(5)


def run_unit_checks(tmpdir: str) -> None:
    """In-process checks of the current-temperature rules. No sockets, no HomeKit."""
    print("current temperature (in-process)")
    import logging
    sys.path.insert(0, HERE)
    import moen_bridge as mb

    def cfg_with(source: str) -> dict[str, Any]:
        cfg = copy.deepcopy(mb.DEFAULT_CONFIG)
        cfg["current_temp_source"] = source
        return cfg

    def published_f(b: Any) -> int:
        return mb.c_to_f(b.values[mb.IID_CURRENT_TEMP_C])

    # 1. Under "poll", a temperature event is ignored; other events still apply.
    hk = mb.HomeKitShower(cfg_with("poll"))
    hk.values = {mb.IID_FAUCET_ACTIVE: True, mb.IID_CURRENT_TEMP_C: mb.f_to_c(71)}
    hk._on_event({(1, mb.IID_CURRENT_TEMP_C): {"value": mb.f_to_c(108)}})
    check(published_f(hk) == 71, "poll mode: iid 13 from an event is ignored")
    hk._on_event({(1, mb.IID_TARGET_TEMP_C): {"value": mb.f_to_c(110)}})
    check(hk.values[mb.IID_TARGET_TEMP_C] == mb.f_to_c(110), "poll mode: other events still applied")

    # 2. Under "events", the same event is published.
    hk2 = mb.HomeKitShower(cfg_with("events"))
    hk2.values = {mb.IID_FAUCET_ACTIVE: True, mb.IID_CURRENT_TEMP_C: mb.f_to_c(71)}
    hk2._on_event({(1, mb.IID_CURRENT_TEMP_C): {"value": mb.f_to_c(108)}})
    check(published_f(hk2) == 108, "events mode: iid 13 from an event is published")

    # 3. Shower off, alternating polls 108/71 never change the published value.
    b = mb.MockShower(cfg_with("poll"))
    b.values = {mb.IID_FAUCET_ACTIVE: False, mb.IID_CURRENT_TEMP_C: mb.f_to_c(71)}
    seen = []
    for f in [108, 71, 108, 71, 108, 71]:
        b._apply({mb.IID_CURRENT_TEMP_C: mb.f_to_c(f)}, "poll")
        seen.append(published_f(b))
    check(set(seen) == {71}, f"debounce: alternating readings never publish ({seen})")

    # 4. Shower off, a 2 F change seen in two consecutive polls is published.
    b._apply({mb.IID_CURRENT_TEMP_C: mb.f_to_c(108)}, "poll")
    check(published_f(b) == 71, "debounce: one reading of 108 is not enough")
    b._apply({mb.IID_CURRENT_TEMP_C: mb.f_to_c(108)}, "command-poll")
    check(published_f(b) == 108, "debounce: same value in two consecutive polls is published")

    # 5. A change smaller than 2 F is never published while off.
    b.values[mb.IID_CURRENT_TEMP_C] = mb.f_to_c(71)
    b._prev_poll_f = None
    for _ in range(3):
        b._apply({mb.IID_CURRENT_TEMP_C: mb.f_to_c(72)}, "poll")
    check(published_f(b) == 71, "debounce: 1 F change is not published while off")

    # 6. Shower running: no debounce, a single reading is published.
    b.values[mb.IID_FAUCET_ACTIVE] = True
    b._apply({mb.IID_CURRENT_TEMP_C: mb.f_to_c(90)}, "poll")
    check(published_f(b) == 90, "shower on: a single poll reading is published at once")

    # 7. Log lines for published changes are rate limited to one per second.
    records: list[logging.LogRecord] = []

    class _Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            records.append(record)

    handler = _Capture(level=logging.INFO)
    old_level = mb.log.level
    mb.log.setLevel(logging.INFO)
    mb.log.addHandler(handler)
    try:
        b2 = mb.MockShower(cfg_with("poll"))
        b2.values = {mb.IID_FAUCET_ACTIVE: True, mb.IID_CURRENT_TEMP_C: mb.f_to_c(71)}
        for f in [108, 71, 108, 71, 108]:
            b2._apply({mb.IID_CURRENT_TEMP_C: mb.f_to_c(f)}, "command-poll")
    finally:
        mb.log.removeHandler(handler)
        mb.log.setLevel(old_level)
    lines = [r.getMessage() for r in records if "current_f now" in r.getMessage()]
    check(len(lines) == 1, f"log: flapping values produce one line per second ({len(lines)})")
    check("iid 13" in lines[0] and "source command-poll" in lines[0] and "raw" in lines[0],
          "log: line carries iid, source and raw Celsius")

    # 8. Config validation rejects unknown values.
    bad = os.path.join(tmpdir, "bad-source.json")
    with open(bad, "w", encoding="utf-8") as fh:
        json.dump({"current_temp_source": "both"}, fh)
    try:
        mb.load_config(bad)
        rejected = False
    except SystemExit:
        rejected = True
    check(rejected, "config: current_temp_source other than poll/events is rejected")
    check(mb.load_config(os.path.join(tmpdir, "missing.json"))["current_temp_source"] == "poll",
          "config: default current_temp_source is poll")


async def run_device_command_checks(tmpdir: str) -> None:
    """In-process checks of the state-aware device commands. Every write is recorded, none is sent."""
    print("device commands (in-process, every HomeKit write recorded)")
    import logging
    sys.path.insert(0, HERE)
    import moen_bridge as mb

    class Recording(mb.MockShower):
        def __init__(self, cfg: dict[str, Any]) -> None:
            super().__init__(cfg)
            self.writes: list[tuple[int, Any]] = []
            self.fail: dict[int, str] = {}        # iid -> HomeKit status raised on its next write
            self.on_fail: Callable[[int], None] | None = None

        async def _write(self, iid: int, value: Any) -> None:
            self.writes.append((iid, value))
            if iid in self.fail:
                status = self.fail.pop(iid)
                if self.on_fail is not None:
                    self.on_fail(iid)
                raise mb.BackendError(status)
            await super()._write(iid, value)

    class Capture(logging.Handler):
        def __init__(self) -> None:
            super().__init__(level=logging.INFO)
            self.lines: list[tuple[int, str]] = []

        def emit(self, record: logging.LogRecord) -> None:
            self.lines.append((record.levelno, record.getMessage()))

    def setup(values: dict[int, Any]) -> tuple[Any, Any]:
        cfg = copy.deepcopy(mb.DEFAULT_CONFIG)
        cfg.update({
            "min_f": 80, "max_f": 120, "write_heater_active_on_start": True,
            "presets": [
                {"n": 1, "title": "Hot", "temp_f": 117, "outlets": [1, 2]},
                {"n": 2, "title": "Comfortable", "temp_f": 108, "outlets": [1, 2]},
                {"n": 3, "title": "Side", "temp_f": 100, "outlets": [2]},
            ],
        })
        b = Recording(cfg)
        b.connected = True
        b.values = dict(values)
        return b, mb.Bridge(cfg, os.path.join(tmpdir, "device-cmds.json"), b)

    def shower(on: bool, target_f: int, outlets: tuple[bool, bool]) -> dict[int, Any]:
        return {mb.IID_FAUCET_ACTIVE: on, mb.IID_HEATER_ACTIVE: on,
                mb.IID_TARGET_TEMP_C: mb.f_to_c(target_f),
                mb.IID_OUTLET_IID[1]: outlets[0], mb.IID_OUTLET_IID[2]: outlets[1],
                mb.IID_CURRENT_TEMP_C: mb.f_to_c(95)}

    async def run(br: Any, msg: dict[str, Any]) -> None:
        await br._execute(msg, "test")

    async def refused(br: Any, msg: dict[str, Any], substr: str, label: str) -> None:
        try:
            await br._execute(msg, "test")
        except mb.CmdError as exc:
            check(substr in str(exc), f"{label} ({exc})")
            return
        check(False, f"{label} (no error raised)")

    T = mb.IID_TARGET_TEMP_C
    F = mb.IID_FAUCET_ACTIVE
    H = mb.IID_HEATER_ACTIVE
    O1 = mb.IID_OUTLET_IID[1]
    O2 = mb.IID_OUTLET_IID[2]

    print("preset while running")
    b, br = setup(shower(True, 100, (True, True)))
    await run(br, {"cmd": "preset", "n": 1})
    check(b.writes == [(T, mb.f_to_c(117))],
          f"preset while running, same outlets: only the target temp is written ({b.writes})")
    check(bool(b.values[F]), "preset while running, same outlets: water still on")
    b, br = setup(shower(True, 117, (True, True)))
    await run(br, {"cmd": "preset", "n": 1})
    check(b.writes == [], f"preset while running, nothing changed: no writes ({b.writes})")
    b, br = setup(shower(True, 117, (True, False)))
    await run(br, {"cmd": "preset", "n": 3})
    check(b.writes == [(T, mb.f_to_c(100)), (O2, 1), (O1, 0)],
          f"preset while running, outlet switch: new valve opens before old one closes ({b.writes})")
    check(bool(b.values[F]), "preset while running, outlet switch: water still on")

    print("preset while off")
    b, br = setup(shower(False, 100, (False, False)))
    await run(br, {"cmd": "preset", "n": 1})
    check(b.writes == [(T, mb.f_to_c(117)), (O1, 1), (O2, 1), (H, 1), (F, 1)],
          f"preset while off: temp, outlets, then heater and water on ({b.writes})")
    b, br = setup(shower(True, 117, (True, True)))
    br.cfg["presets"].append({"n": 4, "title": "Empty", "temp_f": 100, "outlets": []})
    await refused(br, {"cmd": "preset", "n": 4}, "has no outlets",
                  "preset with no outlets refused while running")
    check(b.writes == [], "refused preset wrote nothing")

    print("on")
    b, br = setup(shower(True, 108, (True, True)))
    await run(br, {"cmd": "on"})
    check(b.writes == [], f"on while running: no start write, nothing written ({b.writes})")
    b, br = setup(shower(False, 108, (True, False)))
    await run(br, {"cmd": "on"})
    check(b.writes == [(H, 1), (F, 1)], f"on while off: heater then water on ({b.writes})")

    print("set_temp and outlet")
    b, br = setup(shower(True, 110, (True, True)))
    await run(br, {"cmd": "set_temp", "f": 110})
    check(b.writes == [], "set_temp to the current target: no write")
    await run(br, {"cmd": "set_temp", "f": 105})
    check(b.writes == [(T, mb.f_to_c(105))], f"set_temp changes only the target ({b.writes})")
    b.writes.clear()
    await run(br, {"cmd": "outlet", "n": 1, "on": True})
    check(b.writes == [], "outlet already on: no write")
    await run(br, {"cmd": "outlet", "n": 2, "on": False})
    check(b.writes == [(O2, 0)], f"outlet 2 off while outlet 1 is open: written ({b.writes})")
    await refused(br, {"cmd": "outlet", "n": 1, "on": False}, "last open outlet",
                  "closing the last open outlet while running is refused")
    check(b.writes == [(O2, 0)], "refused outlet wrote nothing")

    print("faucet off is written only by off")
    b, br = setup(shower(False, 100, (True, True)))
    await run(br, {"cmd": "preset", "n": 3})          # starts the water, outlet 2 only
    await run(br, {"cmd": "outlet", "n": 1, "on": True})
    await run(br, {"cmd": "set_temp", "f": 90})
    await run(br, {"cmd": "outlet", "n": 2, "on": False})
    await run(br, {"cmd": "preset", "n": 2})
    await run(br, {"cmd": "on"})
    before_off = list(b.writes)
    check(not any(i == F and not v for i, v in before_off),
          "no faucet=0 write in any command sent while running")
    check(bool(b.values[F]), "water still on before off")
    await run(br, {"cmd": "off"})
    check(b.writes[len(before_off):] == [(F, 0)],
          f"off writes faucet 0 and nothing else ({b.writes[len(before_off):]})")

    print("HomeKit errors")
    cap = Capture()
    old_level = mb.log.level
    mb.log.setLevel(logging.INFO)
    mb.log.addHandler(cap)
    try:
        b, br = setup(shower(True, 100, (True, False)))
        b.fail[T] = "HomeKit status -70410"
        failed = False
        try:
            await run(br, {"cmd": "preset", "n": 1})
        except mb.BackendError:
            failed = True
        check(failed, "a failed write is reported to the client")
        check(bool(b.values[F]) and (F, 0) not in b.writes, "failed target write while running: water still on")
        warns = [m for lvl, m in cap.lines if lvl == logging.WARNING]
        check(any("target temp" in m and "-70410" in m for m in warns),
              "warning names the characteristic and the status")
        check(any("wanted preset 1" in m and "state before" in m and "target=" in m for m in warns),
              "warning carries the wanted state and the state before")
        check(not any("is OFF now" in m for m in warns), "no water-off warning when the water stayed on")

        cap.lines.clear()
        b, br = setup(shower(True, 117, (True, False)))
        b.fail[O1] = "HomeKit status -70410"
        b.on_fail = lambda iid: b.values.__setitem__(F, False)   # the shower stops during the command
        failed = False
        try:
            await run(br, {"cmd": "preset", "n": 3})   # target 117->100, open outlet 2, close outlet 1 (fails)
        except mb.BackendError:
            failed = True
        check(failed, "a failed outlet write is reported to the client")
        warns = [m for lvl, m in cap.lines if lvl == logging.WARNING]
        check(any("is OFF now" in m and "not restarted" in m for m in warns),
              "water that stopped during the command: warning, no automatic restart")
        check((F, 1) not in b.writes, "no automatic restart of the water")
    finally:
        mb.log.removeHandler(cap)
        mb.log.setLevel(old_level)


async def main_async(port: int) -> None:
    tmpdir = tempfile.mkdtemp(prefix="moen-bridge-test-")
    run_unit_checks(tmpdir)
    await run_device_command_checks(tmpdir)
    cfg_path = os.path.join(tmpdir, "test-config.json")
    write_config(cfg_path)
    log_path = os.path.join(tmpdir, "bridge.log")
    proc = start_bridge(cfg_path, port, log_path)
    try:
        await run_main_suite(port, cfg_path)
    except Exception:
        with open(log_path, encoding="utf-8") as fh:
            print("--- bridge log tail ---")
            print("".join(fh.readlines()[-40:]))
        raise
    finally:
        proc.terminate()
        proc.wait(5)
    await run_allowed_clients_check(port + 1, tmpdir)
    print(f"\nALL {PASSED} CHECKS PASSED (log dir: {tmpdir})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8799)
    args = ap.parse_args()
    asyncio.run(main_async(args.port))


if __name__ == "__main__":
    main()
