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
