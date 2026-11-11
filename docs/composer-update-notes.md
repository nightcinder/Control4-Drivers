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
