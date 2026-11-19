# Control4-Drivers

Custom Control4 Lua drivers. Source is in `drivers/<name>/`, built packages in `c4z/`. This repo is public: never add secrets, hostnames or IP addresses to any file.

## Build and test
1. `git pull --ff-only`
2. Edit source under `drivers/<name>/`. Drivers are Lua 5.1.
3. Run the simulator tests in `tools/c4sim/tests` if the driver has them.
4. `python tools\build_c4z.py <name>`. The build must succeed. The package lands in `c4z/<name>.c4z`.
5. Bump the driver version: set `Driver Version` `<default>` in the `.xml` and `DRIVER_VERSION` in the `.lua` by hand. `tools\build_c4z.py` bumps the XML `<version>` and `<modified>` itself on every build, so never edit those two by hand.

## Git
- Complete, tested code and its built `.c4z` go to `main` (`git push origin HEAD:main`).
- Unfinished or untested code goes to a branch: `git push origin HEAD:wip/<topic>`. Keep `main` clean.
- Commit only files you changed on purpose.

## Rules
- Never write into the Composer driver folder. The owner imports `.c4z` files into Composer himself.
- Only free or self-built drivers. Never decrypt or modify encrypted vendor drivers.
- Every `<command>` `<description>` uses `NAME` once and `PARAM1`..`PARAMn` once each (see `docs/composer-update-notes.md`; `check_c4z.py` check CD001 enforces it).
- ESPHome drivers live in `C:\control4-esphome` and are a third-party release. Do not build, commit, recreate or review ESPHome driver copies unless asked.
- Do not tell the owner to remove old drivers from Composer.
- Do not touch Notion, Portainer, liesa or live hardware. The main session handles those.
- Keep summaries short. State plainly what is untested (not imported in Composer, no hardware test, simulator only).
