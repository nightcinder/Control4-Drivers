# c4sim: Control4 driver simulator

Logic-only simulator for driver Lua. Code is in `tools/c4sim/`.

## Run

    python tools/c4sim/run.py smoke all
    python tools/c4sim/run.py smoke room-light-helper
    python tools/c4sim/run.py test all

Output is terse: `ok <dir>`, `ERR <dir>: <first error line>`, `warn <dir>: ...`.
Exit code is non-zero on any ERR or failed test.

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

To test a driver, call `sim.load_driver("drivers/x/driver.lua", {xml=...})` and check `Properties` and `sim.sent`.

## API

`sim.load_driver`, `sim.reset`, `sim.now`, `sim.advance(ms)`, `sim.exec(cmd, params)`, `sim.set_var`, `sim.fire_var`, `sim.bind`, `sim.last_sent`, `sim.count_sent`. Logs: `sim.sent`, `sim.props`, `sim.events`, `sim.errors`, `sim.warnings`, `sim.prints`.

## Stubbed

Timers, UpdateProperty, SendToDevice, SendToProxy, FireEvent, variable listeners, GetDeviceVariable, GetBoundProviderDevice, GetDeviceID, GetTime, SetVariable, AddVariable, Debug/ErrorLog, Persist get/set. Print is captured. Other `C4:Name` calls return nil and warn.

## Known limits

- Logic only; no Composer wiring, bindings, or device behaviour.
- Control4's Lua runtime is older than 5.4. Code targets 5.1 and 5.4.
- Not stubbed: JSON, sockets, url*, Base64/Hex, ParseXml, UI calls.
- `pairs(Properties)` returns nothing (proxy).
- driver.xml is the sibling file unless `opts.xml` is given.
