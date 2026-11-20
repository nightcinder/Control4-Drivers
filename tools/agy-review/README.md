# agy-review: optional advisory review before `git push`

Asks Google's Antigravity CLI (`agy`) to review the diff you are about to push. It prints findings. It never blocks a push.

## Turn it on for one push

    AGY_REVIEW=1 git push

Without `AGY_REVIEW=1` the hook does nothing and costs nothing.

## Install

From the repo root, in PowerShell:

    powershell -File tools\agy-review\install-hook.ps1

It refuses to overwrite an existing pre-push hook unless you add `-Force`. Add `-Uninstall` to remove it.

## Rules the script follows

- It runs only the official `agy` binary, on this machine, while you wait. No schedules, no loops, no gateway.
- The prompt is a fixed file (`review-prompt.txt`). The diff is given to the model as data.
- One review per push. At most 5 reviews per day (`-MaxPerDay`). The counter is written before the call.
- Diffs over 60000 bytes are skipped. `c4z` and `dist` are left out of the diff.
- Before anything is sent, added lines are scanned for secrets, private keys, private IPs and `.local`, `.lan` and `.internal` host names. If one is found, nothing is sent.
- If agy answers with 403, 429, "disabled", "violation" or a quota error, the script writes a `LOCK` file in its state folder and stops. Nothing runs again until you read the message and delete `LOCK` yourself.
- Any script error is ignored and the push goes ahead.

## What it checks

Lua 5.1 errors, timer, listener and socket cleanup, missing `pcall`, XML and Lua name mismatches, Driver Version and DRIVER_VERSION bump, the NAME/PARAM command rule, secrets in a public repo, unintended behavior, missing tests. Style is ignored. Maximum 8 findings.

## Tests

    powershell -File tools\agy-review\Test-AgyReview.ps1

Uses a fake `agy`. It does not call Google and uses no quota.

## Not tested

A real `git push` through the installed hook, and interactive use.
