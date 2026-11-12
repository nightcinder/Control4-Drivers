# ESPHome Control4 driver (Finite Labs, OSS build, untested)

`c4z/esphome.c4z` is the upstream release asset, copied unchanged.

- Source: https://github.com/finitelabs/control4-esphome, release tag `v20261111`, asset `esphome.c4z`
- SHA-256: `daba10836d21a6e59393b2da795c96f08b20bad8a2c637166b1d117c08ae56d7`
- License: AGPL-3.0 (upstream `LICENSE`)
- This repo does not contain the driver source. Rebuilding from source is not done here.

## Setup notes

- Set the driver's **Automatic Updates** property to **Off** if you modify the driver. The driver checks GitHub about every 30 minutes and can replace a modified copy.
- Enable the ESPHome native API (port 6053) in the Everything Presence firmware.

## Untested

- Nothing from this package has run on a controller.
- Everything Presence entity mapping and zones are not confirmed.
- ESPHome native API port 6053 must be enabled in the EP firmware.
