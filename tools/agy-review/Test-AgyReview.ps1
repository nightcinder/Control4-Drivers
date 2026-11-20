<#
Offline tests for agy-review.ps1. Uses a fake agy and a throwaway git repo. Nothing is sent anywhere.
Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\agy-review\Test-AgyReview.ps1
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'agy-review.ps1'
$root = Join-Path $env:TEMP ('agy-review-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$repo = Join-Path $root 'repo'
New-Item -ItemType Directory -Force -Path $repo | Out-Null
$zero = '0000000000000000000000000000000000000000'
$script:pass = 0
$script:fail = 0

function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host ('PASS: ' + $name) } else { $script:fail++; Write-Host ('FAIL: ' + $name) }
}

# fake agy (a .cmd file written line by line)
$fake = Join-Path $root 'fake-agy.cmd'
$fakeLines = @(
    '@echo off',
    'echo called>>"%FAKE_AGY_LOG%"',
    'if "%FAKE_AGY_MODE%"=="403" goto e403',
    'if "%FAKE_AGY_MODE%"=="fail" goto efail',
    'if "%FAKE_AGY_MODE%"=="wrapped" goto ewrapped',
    'if "%FAKE_AGY_MODE%"=="empty" goto eempty',
    'if "%FAKE_AGY_MODE%"=="double" goto edouble',
    'echo {"summary":"Looks fine","findings":[{"severity":"low","file":"drivers/x/x.lua","line":3,"issue":"unused local","suggestion":"remove it"}]}',
    'exit /b 0',
    ':e403',
    'echo Error: PERMISSION_DENIED 403 This service has been disabled in this account for violation of Terms of Service.',
    'exit /b 1',
    ':efail',
    'echo boom',
    'exit /b 3',
    ':ewrapped',
    'echo {"status":"SUCCESS","response":"{\"summary\":\"Wrapped ok\",\"findings\":[]}"}',
    'exit /b 0',
    ':edouble',
    'echo {"status":"SUCCESS","response":"{\"summary\":\"Double ok\",\"findings\":[]}\n{\"findings\":[]}"}',
    'exit /b 0',
    ':eempty',
    'echo {"status":"SUCCESS","response":"","denied_actions":[{"action":"command"}]}',
    'exit /b 0'
)
[System.IO.File]::WriteAllText($fake, (($fakeLines -join "`r`n") + "`r`n"))

# throwaway repo
Set-Location $repo
git init -q 2>&1 | Out-Null
git config user.email 't@example.com'
git config user.name 't'
git config core.autocrlf false
function New-Commit([string]$file, [string]$content) {
    $p = Join-Path $repo $file
    New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
    [System.IO.File]::WriteAllText($p, $content)
    git add -A 2>&1 | Out-Null
    git commit -q -m x 2>&1 | Out-Null
    return (git rev-parse HEAD).Trim()
}
$c1 = New-Commit 'a.lua' "print(1)`n"
$c2 = New-Commit 'a.lua' "print(1)`nprint(2)`n"
$c3 = New-Commit 'b.lua' ('local password = "supersecretvalue1"' + "`n")
$c4 = New-Commit 'c.lua' ('local host = "10.' + '1.2.3"' + "`n")
$c5 = New-Commit 'd.lua' ('local h = "127.0.0.1"' + "`n")
$c6 = New-Commit 'c4z/x.c4z' "binary-ish`n"

function Invoke-Review([string]$Name, [string]$New, [string]$Old, [string]$Mode = 'ok', [string[]]$Extra = @(), [scriptblock]$Prep = $null) {
    $state = Join-Path $root ('state-' + $Name)
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $log = Join-Path $root ('calls-' + $Name + '.txt')
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
    if ($Prep) { & $Prep $state }
    $env:FAKE_AGY_MODE = $Mode
    $env:FAKE_AGY_LOG = $log
    $ref = 'refs/heads/x ' + $New + ' refs/heads/x ' + $Old
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -RepoRoot $repo -RefLines $ref -StateDir $state -AgyPath $fake @Extra 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $calls = 0
    if (Test-Path -LiteralPath $log) { $calls = @(Get-Content -LiteralPath $log).Count }
    return [pscustomobject]@{ Out = $out; Code = $code; Calls = $calls; State = $state }
}

# 1 normal run
$r = Invoke-Review 'ok' $c2 $c1
Check 'normal run shows the findings' (($r.Out -match 'Looks fine') -and ($r.Out -match 'unused local'))
Check 'normal run calls agy once and exits 0' (($r.Calls -eq 1) -and ($r.Code -eq 0))
Check 'normal run counts one run today' ((Get-Content -Raw (Join-Path $r.State 'count.json')) -match '"count":1')
Check 'normal run writes no lock' (-not (Test-Path (Join-Path $r.State 'LOCK')))

# 2 lock present
$r = Invoke-Review 'locked' $c2 $c1 'ok' @() { param($s) [System.IO.File]::WriteAllText((Join-Path $s 'LOCK'), 'test lock.') }
Check 'lock file disables the review' (($r.Out -match 'disabled') -and ($r.Calls -eq 0) -and ($r.Code -eq 0))

# 3 and 4 account error trips the breaker, then stays off
$r = Invoke-Review 'b403' $c2 $c1 '403'
Check '403 answer writes the lock and the push goes ahead' (($r.Out -match 'STOPPED') -and (Test-Path (Join-Path $r.State 'LOCK')) -and ($r.Code -eq 0))
$r = Invoke-Review 'b403' $c2 $c1 'ok'
Check 'after a 403 the next run does not call agy' (($r.Calls -eq 0) -and ($r.Out -match 'disabled'))

# 5 other failure fails open, no lock
$r = Invoke-Review 'fail' $c2 $c1 'fail'
Check 'ordinary failure fails open without a lock' (($r.Out -match 'agy failed') -and (-not (Test-Path (Join-Path $r.State 'LOCK'))) -and ($r.Code -eq 0))

# 6 daily cap
$r = Invoke-Review 'cap' $c2 $c1 'ok' @() { param($s) $d = (Get-Date).ToString('yyyy-MM-dd'); [System.IO.File]::WriteAllText((Join-Path $s 'count.json'), ('{"date":"' + $d + '","count":5}')) }
Check 'daily cap stops the review' (($r.Out -match 'daily cap') -and ($r.Calls -eq 0))

# 7 oversize
$r = Invoke-Review 'big' $c2 $c1 'ok' @('-MaxDiffBytes', '10')
Check 'oversize diff is skipped' (($r.Out -match 'over the') -and ($r.Calls -eq 0))

# 8 secret
$r = Invoke-Review 'secret' $c3 $c2
Check 'added secret blocks the send' (($r.Out -match 'secret') -and ($r.Calls -eq 0))

# 9 ip address
$r = Invoke-Review 'ip' $c4 $c3
Check 'added IP address blocks the send' (($r.Out -match 'IP address') -and ($r.Calls -eq 0))

# 10 loopback is fine
$r = Invoke-Review 'loop' $c5 $c4
Check 'loopback address is allowed' ($r.Calls -eq 1)

# 11 package-only change
$r = Invoke-Review 'pkg' $c6 $c5
Check 'change to c4z only has nothing to review' (($r.Out -match 'no code changes') -and ($r.Calls -eq 0))

# 12 deleted ref
$r = Invoke-Review 'del' $zero $c2
Check 'deleting a branch has nothing to review' (($r.Out -match 'no code changes') -and ($r.Calls -eq 0))

# 13 dry run
$r = Invoke-Review 'dry' $c2 $c1 'ok' @('-DryRun')
Check 'dry run builds the bundle but never calls agy' (($r.Out -match 'dry run') -and ($r.Calls -eq 0) -and (-not (Test-Path (Join-Path $r.State 'count.json'))))
Check 'dry run writes the fixed prompt files' ((Test-Path (Join-Path $r.State 'work\REVIEW.md')) -and (Test-Path (Join-Path $r.State 'work\diff.patch')) -and (Test-Path (Join-Path $r.State 'work\schema.json')))

# real agy output format: answer wrapped in a response string
$r = Invoke-Review 'wrapped' $c2 $c1 'wrapped'
Check 'real output format (response string) is read' (($r.Out -match 'Wrapped ok') -and ($r.Out -match 'no findings'))
$r = Invoke-Review 'empty' $c2 $c1 'empty'
Check 'empty answer with a denied command is reported' (($r.Out -match 'empty answer') -and ($r.Out -match 'tried to run a command') -and ($r.Code -eq 0))

$r = Invoke-Review 'double' $c2 $c1 'double'
Check 'two JSON documents in one answer: the first with findings is used' (($r.Out -match 'Double ok') -and ($r.Out -match 'no findings'))

# 14 new branch with no base
$r = Invoke-Review 'newbranch' $c2 $zero
Check 'new branch with no origin/main fails open' (($r.Out -match 'no base commit') -and ($r.Calls -eq 0) -and ($r.Code -eq 0))

Set-Location $env:TEMP
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ('Summary: ' + $script:pass + ' passed, ' + $script:fail + ' failed (total ' + ($script:pass + $script:fail) + ')')
if ($script:fail -gt 0) { exit 1 }
exit 0