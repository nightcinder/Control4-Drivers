# c4sim: Control4 driver simulator

Logic-only simulator for driver Lua. Code is in `tools/c4sim/`.

## Run

    python tools/c4sim/run.py smoke all
    python tools/c4sim/run.py smoke room-light-helper
    python tools/c4sim/run.py test all

Output is terse: `ok <dir>`, `ERR <dir>: <first error line>`, `warn <dir>: ...`.
Exit code is non-zero on any ERR or failed test.

## Build hook

`tools/build_c4z.py` runs the smoke and `tests/<name>_test.lua` (name with `_` for `-`) after its pre-flight checks.
Success prints at most two lines. An ERR or failed test refuses the build. No `lua` means one "skipped" line and no
refusal. `C4SIM_SKIP=1` bypasses it.

## Write a test

Create `tools/c4sim/tests/<name>_test.lua`:

    local sim = require("c4sim")
    local t = require("t")
    local C4 = sim.C4

    t.test("timer fires once", function()
      sim.reset(1)
      local n = 0
      C4:SetTimer(1000, function() n = n + 1 end)
      sim.advance(1000)
      t.eq(n, 1, "fired")
    end)

    t.finish("my")

Load a driver with `sim.load_driver("drivers/x/driver.lua", {xml=..., properties={...}, before=function(s) ... end})`.
`before` runs after reset and before OnDriverInit, so bind devices and set variables there (see `tests/room_light_helper_test.lua`).

## API

`sim.load_driver`, `sim.reset`, `sim.now`, `sim.advance(ms)`, `sim.exec(cmd, params)`, `sim.set_var`, `sim.fire_var`,
`sim.bind`, `sim.last_sent`, `sim.count_sent`, `sim.queue_http(pattern, body, code)`, `sim.net_receive(binding, data)`.
Logs: `sim.sent`, `sim.props`, `sim.events`, `sim.logs`, `sim.errors`, `sim.warnings`, `sim.prints`, `sim.http`, `sim.net`, `sim.ui`.

## Stubbed

- Timers, UpdateProperty, SendToDevice/Proxy, FireEvent, variable listeners, GetDeviceVariable, bindings, GetTime,
  variables, Debug/ErrorLog, Persist. Print is captured. Other `C4:Name` calls return nil and warn.
- JsonEncode/JsonDecode (pure Lua; decode errors on bad input; surrogate pairs not joined).
- Base64Encode/Base64Decode.
- urlGet/urlPost/urlDo/urlSetTimeout: each request goes into `sim.http`. Answers come from `sim.queue_http`
  (Lua pattern on URL) and are delivered on `advance()`. Callback is `(context, data, code, headers, err)`.
  An unqueued request gets code 0 and a warning.
- CreateNetworkConnection/NetConnect/SendToNetwork/NetDisconnect/CreateServer/DestroyServer: recorded in `sim.net`.
- SendDataToUI, UpdatePropertyList (recorded), GetControllerNetworkAddress (returns `127.0.0.1`).
- Each of these works as `C4:Name(...)` and as a global.
- `os.time()` in a driver follows the simulated clock (2026-01-01 UTC plus `advance` time).
- `pairs(Properties)` works under Lua 5.4 (`__pairs`).
- `require("drivers-common-public.*")` loads a stub when no real file is on the path. Calls return nil, and smoke
  prints `warn <dir>: stubbed common-library module X`.

## Known limits

- Logic only: no Composer wiring, bindings, or device behaviour.
- Control4's Lua runtime is older than 5.4. Code targets 5.1 and 5.4; the tests were run under 5.4.
- Url and network argument orders follow the usual DriverWorks layout. Check the SDK before relying on exact signatures.
- driver.xml is the sibling file unless `opts.xml` is given.
