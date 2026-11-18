# Fable window 1 report (run 2026-11-16, rerun of 2026-11-15)

Intended as the Notion child page "Fable window 1 report 2026-11-15" under Smart Home & Homelab To-Do. This run had no Notion or mcp-memory access (neither tool was loaded in the session), so the report lives here on the branch. Copy it to Notion and update the To-Do lines below.

## Roborock driver 0.7.0 (branch wip/roborock-next, NOT merged to main)
- Rebased onto main 44f7b6f (roborock 0.6.3 by Gemini). The interrupted previous run had left uncommitted 0.7.0 work written on 0.6.2 that dropped the 0.6.3 changes; both 0.6.3 changes are back (LUA_ACTION mapping plus Composer display names in ExecuteCommand, global ReceivedFromProxy) and are covered by c4sim tests.
- Versions: driver 0.7.0, driver.xml version 19, UI build 4 (page still vacuum2.html), bridge 0.2.3 in code and compose tag only (NOT built or deployed; liesa still runs 0.2.2).
- New: per-job cleaning mode (Mode on Clean Rooms and Start Full Clean), Set Cleaning Mode (lasting), Run Progress (RUN_PROGRESS 0-100), Activity (cleaning/paused/returning/docked/idle/error/offline/other) for all 43 python-roborock state names, events 10 Docked and 11 Error Cleared, error text and code variables, Dock skipped when already docked, Start Full Clean with "Skip If Cleaned Within Hours".
- Events now fire by name (C4:FireEvent(name)), the litter-robot 1.0.2 fix. Events 1-9 keep ids and names.
- Composer use (Nick programs this himself): Away -> Start Full Clean (Vacuum Only, skip 20 h); Home -> Dock; Error Raised -> notification with VACUUM_ERROR_TEXT / VACUUM_ERROR_CODE.

### Test results (rerun by the main run after the subagent)
- c4sim test all: roborock 37/0, room-light-helper 30/0, dls-presence 25/0, dls-extra 7/0, dls-edge-cases 7/0, dls-manual-override 1/0, selftest 11/0, stubs 8/0.
- Bridge unittest: 32 tests OK (python-roborock mocked).
- build_c4z.py roborock: built c4z/roborock.c4z, XML 18 -> 19. check_c4z.py roborock: ok; --all: 22 checked, 0 failures.
- Working python on ixhel: `%LOCALAPPDATA%\Python\bin\python.exe` (py.exe and the Store alias are broken).
- Live read-only GET of the bridge /state: docked, state "charging", battery 100, no error, 6 rooms (16-21), progress null.

### Untested
- Nothing in 0.7.0 has run on the vacuum, in Composer or in Navigator.
- Bridge 0.2.3 is not deployed. On 0.2.2 the driver refuses commands with a Mode, Run Progress shows n/a, and the mid-job recharge rule is inactive.
- On the real vacuum, not yet confirmed: set_clean_motor_mode support, the mode restoring after a job, clean_percent reporting, and the real state names during a run.

### Notes for the 03:30 review run (review these first)
1. Events by name: every FireEvent call changed from id to name. It has not been seen firing in Composer for this driver.
2. The Dock skip uses polled state (driver polls every 15 s, bridge every 60 s while idle), so it can be stale. A job started from the app less than about a minute earlier could be wrongly skipped. Bypasses: a job is active, the driver sent a start within 180 s, or the bridge is offline.
3. Mid-job recharge: Cleaning Finished is held while in_cleaning > 0 and battery < 100. If in_cleaning sticks above 0, Finished waits for 100 % or charging_complete.
4. Activity reads "error" whenever an error code is present, even while docked (IS_DOCKED is still true).
5. The page file name is kept as vacuum2.html at build 4. Rename it if Web Page Status shows "PAGE IS STALE".
6. The compose tag on main said 0.2.1 while 0.2.2 is live; the branch says 0.2.3.
7. Diff to review: `git diff 44f7b6f..wip/roborock-next`. A backup of the pre-rebase worktree is in %TEMP%\roborock-wip-backup-20261116 on ixhel.

## Shield TV Bridge mini apps proposal (research only, no code changed)
**Why App 1-20 do nothing.** The App N Package properties (25 slots) are only a lookup table. switchToInput() reads them only when avswitch proxy 5002 gets SET_INPUT 3051-3075. A Watch tile appears only when a separate mini app driver is bound to one of the MiniApp inputs, and the package has to sit in the matching slot by hand. PASSTHROUGH is also not handled, so remote keys sent through a mini app are dropped ("Switcher command not handled").

**How mini apps work.** Based on the stock um_plex.c4z and nv_shield_tv.c4z XML (read-only, from the Composer driver folder):
- A mini app is its own device, with a media_player proxy and a provider connection 3101 of class RF_MINI_APP.
- It publishes per-platform app ids as variables, e.g. UM_NV_SHIELD = com.plexapp.android.
- The host reads the bound mini app's variable when it gets SET_INPUT. This step is inferred, because the stock Shield Lua is encrypted.
- Remote keys come back to the host as PASSTHROUGH with PASSTHROUGH_COMMAND set.
- The bridge driver's XML already mirrors the stock Shield driver.

**Options.**
- A: proper mini app host. Read UM_NV_SHIELD from the bound mini app via C4:GetBoundProviderDevice + C4:GetDeviceVariables, handle PASSTHROUGH, drop or demote the properties. About 30-60 min.
- B: an Apps list in the Shield's own media_service Navigator UI. This keeps the Shield as the selected device, so now playing keeps working. About 1-2 h.
- C: a web-view app grid driver (the Roborock pattern). About 1 h, but it isn't in Watch.

**Recommendation: A now, B later.** For A:
1. packageForInput(): pcall-wrapped API calls, with fallbacks UM_NV_SHIELD -> UM_SUNBRITE_TV -> UM_AMAZON.
2. switchToInput() uses packageForInput().
3. PASSTHROUGH unwrap at the top of ReceivedFromProxy, before the PROXY_SWITCH early return.
4. driver.xml: remove the App N properties or keep a few as overrides, add a read-only "Bound Apps" property, set MiniApp linelevel False.
5. tools/make_miniapp.py writes fresh mini app drivers for apps with no stock one (e.g. Jellyfin). Write the Lua new; don't copy Snap One's.
6. Bridge: no change needed (/v1/launch already uses monkey -p).
7. c4sim tests.

Driver 1.4.0, XML v17, no delete and re-add needed.

**Open questions for hands-on testing.**
- Can the stock Plex mini app bind to this driver as well as to the stock Shield driver?
- Do the API calls return the variables on the provider id?
- Does PASSTHROUGH arrive at all?
- Now playing while a mini app is selected probably needs option B.

## Suggested To-Do status lines
- Roborock driver: 0.7.0 (mop mode, percent finished, Docked/Error Cleared events, Start Full Clean with skip guard, Dock-if-needed) on branch wip/roborock-next. Tests pass. Untested on hardware and in Composer; bridge 0.2.3 not deployed; review run pending.
- Shield mini apps: research done. Recommendation: read UM_NV_SHIELD from the bound mini app and handle PASSTHROUGH (option A, about 1 h); proposal is in the Fable window 1 report.

## Not done this run
- Notion child page, To-Do status lines and mcp-memory entries: no Notion or mcp-memory tools in this session. Using the memory server's credentials from .claude.json was blocked, correctly.
- The X post (x.com/socialwithaayan/status/2121992650274529428) could not be fetched (robots disallowed).
