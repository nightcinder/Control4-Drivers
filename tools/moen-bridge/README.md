# moen-bridge

Local bridge between a Control4 driver and a U by Moen shower. It talks to the
shower over HomeKit (aiohomekit) and exposes a TCP JSON-lines protocol.

## WARNING: pairing file

`~/moen-hk.json` (the HomeKit pairing file) holds the keys for the shower.
Never commit it, copy it into the repo, or share it. Keep it on the Linux host only.

## Install on the Linux host

Python 3.14 venv at `/home/liesa/hk` with `aiohomekit` and `zeroconf` installed.

```bash
cp moen_bridge.py /home/liesa/
cp config.example.json /home/liesa/moen-bridge.json
sudo cp moen-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now moen-bridge
journalctl -u moen-bridge -f
```

## Test (port 8765)

```bash
printf '{"cmd":"get_state"}\n' | nc -q 1 127.0.0.1 8765
(echo '{"cmd":"preset","n":1}'; sleep 2) | nc 127.0.0.1 8765
(echo '{"cmd":"off"}'; sleep 2) | nc 127.0.0.1 8765
```

The bridge sends a `state` line on connect and after every change.

## Offline test

On any machine with Python 3:

```bash
python moen_bridge.py --mock --config /tmp/test.json --port 8799
python test_mock_client.py --port 8799
```

## Commands

Each command gets a fresh `state` line, or an `error` line.
`get_state`, `on`, `off`, `set_temp`, `outlet`, `preset`, `set_preset`.
Water only starts from `on` or `preset`.
While the water is running, `on`, `preset`, `set_temp` and `outlet` write only the
values that differ from the shower's current state. A preset never stops the water:
a new outlet opens before an old one closes, and `outlet` refuses to close the last
open valve while running. Only `off` writes faucet Active = 0. Every write and every
skipped value is logged at INFO.

## Config: write_heater_active_on_start

Default: `true`. Starting the shower requires both the Faucet Active
characteristic (iid 9) and the heater Active characteristic (iid 12) set to 1.
Writing iid 9 alone does not start the water. Verified on real hardware
2026-11-07. Leave this `true`; set it to `false` only for testing.

## Config: current_temp_source

Default: `"poll"`. Controls where `current_f` (the water temperature, HomeKit
iid 13) comes from.

- `"poll"`: iid 13 values that arrive as HomeKit push events are ignored.
  Only the bridge's own reads (the periodic poll and the fast poll after a
  command) update `current_f`. While the shower is off, a new `current_f` is
  published only if it differs from the last published value by 2 F or more
  AND the same value was read in two consecutive polls. Alternating readings
  therefore never change the published state.
- `"events"`: the previous behaviour. Event values for iid 13 are published
  directly, with no debounce.

Every change of the published `current_f` is logged at INFO with the source
(`poll`, `command-poll`, `event`), the raw Celsius value and the iid. At most
one such line is written per second. Use the journal to compare what the
shower reports through each path. Target and other values are not affected by
this setting, and it does not change any water safety rule.
