# Control4-Drivers

Custom Control4 DriverWorks drivers in Lua 5.1. Source is in `drivers/<name>/` (`driver.xml` plus `driver.lua`, icons in `www/`). Built, ready-to-import packages are committed in `c4z/`. Helper services and tooling are in `tools/`. See `README.md` for the driver list and per-driver notes.

This repo is public. Never add secrets, tokens, hostnames, IP addresses or personal values (coordinates, addresses). Drivers ship with blank defaults. `python tools/check_public.py` scans for these and CI runs it.

## Build and test
1. `git pull --ff-only`.
2. Edit source under `drivers/<name>/`.
3. Bump the version by hand: the `Driver Version` property `<default>` in the `.xml` and `DRIVER_VERSION` in the `.lua`, same string in both. Scheme is `major.minor.patch`: patch + 1 for every change, never reuse a number. Raise the minor only when the owner asks for a new feature set, the major only for a breaking rewrite.
4. `python tools/build_c4z.py <name>` (`--dry-run` checks and reports without writing). It runs the pre-flight checks (`tools/check_c4z.py`), then the c4sim smoke, command and property pumps and the whole simulator test suite, then writes `c4z/<package>.c4z`. It bumps the XML `<version>` (an integer Composer compares) and `<modified>` itself, so never edit those two by hand.
5. Commit the source and the rebuilt `.c4z` together. A bumped source with an unbuilt package counts as untested.

Checks you can run on their own:
- `python tools/check_c4z.py --all` (pre-flight: Lua 5.1 syntax, sandbox APIs, duplicate handlers, command and event params, and that the committed `.c4z` matches the source at HEAD).
- `python tools/test_check_c4z.py`, `python tools/test_check_public.py`.
- `python tools/c4sim/run.py smoke|commands|props|test all` (see `docs/c4sim.md`). Needs `lua` and `luac5.1` on PATH. Without them the build prints "skipped" and does not refuse. `C4SIM_SKIP=1` bypasses the hook.
- CI (`.github/workflows/ci.yml`) runs all of the above plus the bridge helper tests on every push and PR, with `TZ=America/New_York` (the DLS tests pin local-clock times). On Windows do NOT set `TZ` yourself: the C runtime misreads it and DLS tests fail. The Windows clock is already Eastern.

## Driver conventions
- Filenames stay stable across versions. Composer updates a driver in place only when the new `.c4z` has the same file name and a higher XML `<version>`. `PACKAGE_NAMES` in `tools/build_c4z.py` maps folder to package name.
- `driver.xml` starts directly with `<devicedata>` (no XML declaration) or Composer will not parse it.
- Every driver has a read-only `Driver Version` property.
- Secrets: `<type>STRING</type>` plus `<password>true</password>`. Never `<type>PASSWORD</type>`, which crashes Composer's property lookup.
- Every `<command>` `<description>` uses `NAME` once and `PARAM1`..`PARAMn` once each (check CD001, see `docs/composer-update-notes.md`).
- A driver cannot add or remove proxies at runtime. Use a child driver instead.
- The standalone Moen driver needs Control4's `drivers-common-public` (`C4_COMMON_PUBLIC=<clone> python tools/build_c4z.py moen-smart-shower`).
- Say plainly what is untested (not imported in Composer, no hardware test, simulator only). Commit messages say "untested" when it applies.

## Git
- Tested code and its built `.c4z` go to `main` (`git push origin HEAD:main`) or merge by PR.
- Unfinished or untested code goes to a branch (`wip/<topic>`). Keep `main` clean.
- Commit only files you changed on purpose.

## Do not
- Never write into the Composer driver folder. The owner imports `.c4z` files into Composer himself, so hand over the built package and stop.
- Never push commands or changes to the live controller (EA-1) without asking the owner first. Reads are fine.
- Do not tell the owner to remove old or superseded drivers from Composer. Leave them in place.
- Do not add ESPHome Control4 drivers here, and do not build, commit, recreate or review copies of them. They are a third-party (Finite Labs) release that lives outside this repo.
- Only free or self-built drivers. Never decrypt or modify encrypted vendor drivers.
- Do not touch Notion, Portainer, liesa or live hardware from driver work. The main session handles those.
- Keep summaries short.
