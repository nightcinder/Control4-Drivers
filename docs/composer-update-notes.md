# Composer in-place update notes

Lessons learned getting custom drivers to update in place in Composer Pro
("Add or Update Driver") instead of needing delete and re-add.

1. **Package file name must match the installed "Device File".**
   Driver Information shows Name, Version, Modified Date and Device File.
   Composer only updates in place when the new .c4z has the same file name as
   the Device File. A different name creates a second, separate driver entry
   (this caused the duplicate Haiku SenseME drivers).
   `tools/build_c4z.py` keeps a `PACKAGE_NAMES` map from driver folder to the
   original package name. Add an entry for every new driver.
2. **Bump `<version>` in driver.xml on every release**, and update `<modified>`.
   Composer ignores a package whose XML version is not higher. The Lua
   `VERSION` / `DRIVER_VERSION` constant is separate; keep them aligned.
3. **driver.xml must begin directly with `<devicedata>`.**
   No `<?xml ...?>` declaration and no leading comment. Otherwise Composer
   shows "INFO: Unable to find/parse config data file." and the update fails.
4. **Expose a read-only "Driver Version" property** set from Lua in
   OnDriverInit / OnDriverLateInit, so you can see which code is running.
   Composer reloads Lua live on update; no Director restart is needed.
5. **Packages contain only** driver.xml, driver.lua (and www/ if used).
   The build skips *.md, build.sh and top-level tools/.
6. **A driver cannot add or remove proxies at runtime**, so optional
   capabilities (e.g. Haiku fan light) need a separate or child driver.
7. Dropping a .c4z into the Documents\Control4\Drivers folder does not
   auto-update; use "Add or Update Driver" manually.

Verified: media-remote-bridge 0.4.4 (XML version 9) updated both an old 0.4.1
instance and a new 0.4.3 instance in place with no Director restart.

## Haiku SenseME split (v400, 2026-11-11, untested on hardware)

The combined (`Haiku_SenseME_i6`) and no-light (`Haiku_SenseME_i6_NoLight`) packages are retired (still in git history for rollback).
Replacement: `Haiku_SenseME_Fan.c4z` (fan proxy only, owns the TCP link to the fan) plus an optional `Haiku_SenseME_Light.c4z`
(light_v2 proxy, one per fan that has a light kit). Same parent/child pattern as SwitchBot Cloud / Curtain.

Migration per fan:
1. Add the new Fan driver to the same room, set Fan IP Address. Check "Has Light Kit" flips to Yes/No after connecting.
2. Fan with a light kit: add the Light driver, then in Connections bind its "Haiku Fan" to the new fan's "Light Kit Link".
3. Rebind Composer programming, room Lighting/Comfort bindings and Navigator groups from the old driver's Light/Fan to the new ones.
4. Delete the old Haiku SenseME Fan instance (fans with no Driver Version row are on the very old driver), then remove the old driver entries.
Only one driver can hold the fan's TCP connection reliably, so remove the old instance before testing the new one.

## Pre-flight

`tools/check_c4z.py` checks a driver folder (and its c4z/ package, if one exists) before it ships:

- **a** driver.xml starts directly with `<devicedata>` (no BOM, `<?xml?>` declaration or comment) and parses.
- **b** `<version>` is an integer, and is greater than the HEAD version when the source changed, and greater than the c4z version when the source differs from the c4z. `--no-version-check` skips the ordering part.
- **c** `<modified>` changed when the source changed since HEAD.
- **d** the Lua passes `luac -p`.
- **e** the Lua defines OnDriverInit, and every `<action><command>` name appears in the Lua.
- **f** a "Driver Version" property has a `<default>` equal to the Lua DRIVER_VERSION / VERSION constant, and the Lua writes it.
- **g** the package name matches an existing c4z/ file exactly (case-sensitive). Warns when a differently named c4z exists for the same driver.
- **h** the package holds only driver.xml, driver.lua, www/ and icons the XML references, and every referenced icon exists.
- **j** no `Properties[...] = ...` writes in the Lua. Those change the Lua table only. Use `C4:UpdateProperty(name, value)`.

    python tools/check_c4z.py --all --no-version-check
    python tools/check_c4z.py drivers/<name>

`tools/build_c4z.py` runs the checks before it builds each driver and refuses to build a driver that fails any of them.

**Auto-bump.** If the driver's source (ignoring `<version>` and `<modified>`) differs from the existing c4z/<name>.c4z, the build sets `<version>` to max(XML version, HEAD version, c4z version) + 1 and `<modified>` to the local time, in the file's existing format. Unchanged source is not bumped. A version bumped by hand is raised once more by this rule.

    python tools/build_c4z.py --dry-run [<name> ...]

`--dry-run` runs the bump plan and all checks, and reports what would be bumped and built. It writes nothing.
