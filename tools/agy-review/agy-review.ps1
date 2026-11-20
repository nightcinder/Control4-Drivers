<#
Advisory diff review with agy (Antigravity CLI) for this repo. Windows PowerShell 5.1.
Called by tools/agy-review/pre-push. It NEVER blocks a push: every path exits 0.

Safety rules (Google's Antigravity terms allow the official agy binary run locally, not reuse of its login by other tools):
- Opt-in: the hook only calls this script when AGY_REVIEW=1.
- Local only: it runs the official agy binary as a child process. No gateway, no remote call, no token handling.
- Fixed prompt: the prompt text is the one line below plus review-prompt.txt. Only the diff changes.
- One run per push, no retries, at most -MaxPerDay runs a day, diff size capped.
- Circuit breaker: if agy answers with a 403, 429, quota or terms error, a LOCK file is written and every later run is skipped until you delete it.
- Nothing is sent if the added lines look like they hold a secret, a private key or an IP address.
#>
param(
    [string]$RepoRoot = '',
    [string[]]$RefLines = $null,
    [string]$StateDir = '',
    [string]$AgyPath = '',
    [string]$Model = 'gemini-4-hydrogen-high',
    [int]$MaxPerDay = 5,
    [int]$MaxDiffBytes = 60000,
    [int]$TimeoutSec = 300,
    [switch]$DryRun
)

function Say([string]$m) { Write-Host ('[agy-review] ' + $m) }
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-FirstFindingsObject([string]$text) {
    # The model sometimes prints more than one JSON document. Return the first object that has a findings list.
    $depth = 0; $start = -1; $inStr = $false; $esc = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false } elseif ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true; continue }
        if ($ch -eq '{') {
            if ($depth -eq 0) { $start = $i }
            $depth++
        } elseif ($ch -eq '}') {
            if ($depth -gt 0) {
                $depth--
                if ($depth -eq 0 -and $start -ge 0) {
                    $cand = $text.Substring($start, $i - $start + 1)
                    try {
                        $o = $cand | ConvertFrom-Json
                        if ($o.PSObject.Properties['findings']) { return $o }
                    } catch { }
                    $start = -1
                }
            }
        }
    }
    return $null
}

try {
    if (-not $RepoRoot) { $RepoRoot = (git rev-parse --show-toplevel).Trim() }
    if (-not $StateDir) { $StateDir = Join-Path $env:USERPROFILE '.agy-review' }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $lock = Join-Path $StateDir 'LOCK'
    if (Test-Path -LiteralPath $lock) {
        Say ('disabled: ' + ([System.IO.File]::ReadAllText($lock)).Trim() + ' Delete ' + $lock + ' to turn it back on.')
        exit 0
    }

    if ($null -eq $RefLines) {
        $RefLines = @()
        $txt = [Console]::In.ReadToEnd()
        if ($txt) { $RefLines = $txt -split "`r?`n" }
    }

    # ---- build the diff for every ref being pushed
    $zero = '0000000000000000000000000000000000000000'
    $parts = New-Object System.Collections.ArrayList
    foreach ($line in $RefLines) {
        if (-not $line -or -not $line.Trim()) { continue }
        $f = $line.Trim() -split '\s+'
        if ($f.Count -lt 4) { continue }
        $local = $f[1]; $remote = $f[3]
        if ($local -eq $zero) { continue }
        $base = $remote
        if ($remote -eq $zero) {
            $base = (git -C $RepoRoot merge-base origin/main $local 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $base) { Say 'no base commit to compare with, skipped.'; continue }
            $base = ([string]$base).Trim()
        }
        $d = git -C $RepoRoot diff --no-color -M $base $local -- . ':(exclude)c4z' ':(exclude)dist' 2>$null
        if ($LASTEXITCODE -ne 0) { Say 'could not build the diff, skipped.'; continue }
        if ($d) { [void]$parts.Add(($d -join "`n")) }
    }
    $diff = ($parts -join "`n")
    if (-not $diff.Trim()) { Say 'no code changes to review.'; exit 0 }

    $bytes = $Utf8.GetByteCount($diff)
    if ($bytes -gt $MaxDiffBytes) { Say ('diff is ' + $bytes + ' bytes, over the ' + $MaxDiffBytes + ' byte limit: skipped.'); exit 0 }

    # ---- nothing leaves this machine if the added lines look sensitive
    $patterns = @(
        '(?i)(password|passwd|secret|api[_-]?key|token|bearer)\s*[:=]\s*["''][^"'']{8,}',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b',
        '(?i)\b[a-z0-9-]+\.(local|lan|internal)\b'
    )
    foreach ($l in ($diff -split "`n")) {
        if (-not $l.StartsWith('+') -or $l.StartsWith('+++')) { continue }
        $check = $l.Replace('127.0.0.1', 'localhost').Replace('0.0.0.0', 'anyhost')
        foreach ($p in $patterns) {
            if ($check -match $p) { Say 'the diff may add a secret, host name or IP address: review skipped, nothing was sent.'; exit 0 }
        }
    }

    # ---- daily cap
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $countFile = Join-Path $StateDir 'count.json'
    $count = 0
    if (Test-Path -LiteralPath $countFile) {
        try {
            $c = [System.IO.File]::ReadAllText($countFile) | ConvertFrom-Json
            if ($c.date -eq $today) { $count = [int]$c.count }
        } catch { $count = 0 }
    }
    if ($count -ge $MaxPerDay) { Say ('daily cap reached (' + $MaxPerDay + ' runs): skipped.'); exit 0 }

    # ---- scratch folder with the fixed prompt, the schema and the diff
    $work = Join-Path $StateDir 'work'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    Copy-Item -LiteralPath (Join-Path $here 'review-prompt.txt') -Destination (Join-Path $work 'REVIEW.md')
    Copy-Item -LiteralPath (Join-Path $here 'review-schema.json') -Destination (Join-Path $work 'schema.json')
    [System.IO.File]::WriteAllText((Join-Path $work 'diff.patch'), $diff, $Utf8)

    if ($DryRun) { Say ('dry run: would review ' + $bytes + ' bytes with ' + $Model + '. Nothing was sent.'); exit 0 }

    if (-not $AgyPath) {
        $cmd = Get-Command agy -ErrorAction SilentlyContinue
        if ($cmd) { $AgyPath = $cmd.Source } else { $AgyPath = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.EXE' }
    }
    if (-not (Test-Path -LiteralPath $AgyPath)) { Say 'agy not found: skipped.'; exit 0 }

    # count the attempt before the call, so a crash cannot cause a retry loop
    [System.IO.File]::WriteAllText($countFile, (@{ date = $today; count = ($count + 1) } | ConvertTo-Json -Compress), $Utf8)

    Say ('reviewing ' + $bytes + ' bytes with ' + $Model + ' (run ' + ($count + 1) + ' of ' + $MaxPerDay + ' today)...')
    $agyArgs = @(
        '--model', $Model,
        '--output-format', 'json',
        '--json-schema', (Join-Path $work 'schema.json'),
        '--print-timeout', ([string]$TimeoutSec + 's'),
        '-p', 'Read REVIEW.md in the current directory and follow it exactly. The change to review is in diff.patch in the same directory.'
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $errFile = Join-Path $work 'stderr.txt'
    Push-Location $work
    try {
        $out = (& $AgyPath @agyArgs 2>$errFile | Out-String)
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevEap
    }
    $out = $out.Trim()
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    $all = $out + [Environment]::NewLine + $err
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'last-review.json'), $out, $Utf8)
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'last-review.err'), $err, $Utf8)

    # ---- circuit breaker: stop on any account, quota or terms error
    $bad = '(?i)\b(403|429)\b|disabled in this account|violation of|PERMISSION_DENIED|RESOURCE_EXHAUSTED|rate limit|quota'
    if (($code -ne 0 -or $all.Length -lt 800) -and ($all -match $bad)) {
        $msg = 'agy answered with an account, quota or terms error on ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + '. Check the account before using it again.'
        [System.IO.File]::WriteAllText($lock, $msg, $Utf8)
        Say ('STOPPED: ' + $msg + ' Delete ' + $lock + ' to turn the review back on. The push goes ahead.')
        exit 0
    }
    if ($code -ne 0) { Say ('agy failed (exit ' + $code + '), review skipped. The push goes ahead.'); exit 0 }

    # ---- show the result
    $show = $out
    $json = $null
    try { $json = $out | ConvertFrom-Json } catch { $json = $null }
    foreach ($prop in @('response', 'result')) {
        if ($json -and $json.PSObject.Properties[$prop] -and ($json.$prop -is [string])) {
            $inner = ([string]$json.$prop).Trim()
            if (-not $inner) {
                $why = ''
                if ($out -match 'denied_actions') { $why = ' It tried to run a command, which headless mode does not allow.' }
                Say ('agy returned an empty answer, so there is no review.' + $why + ' The push goes ahead.')
                exit 0
            }
            $show = $inner
            $json = Get-FirstFindingsObject $inner
            break
        }
    }
    if ($json -and $json.PSObject.Properties['findings']) {
        Say ('summary: ' + $json.summary)
        $n = 0
        foreach ($x in @($json.findings)) {
            $n++
            Say ('  [' + $x.severity + '] ' + $x.file + ':' + $x.line + ' ' + $x.issue + ' -> ' + $x.suggestion)
        }
        if ($n -eq 0) { Say '  no findings.' }
    } else {
        if ($show.Length -gt 3000) { $show = $show.Substring(0, 3000) + ' ...' }
        Say 'could not read the answer as JSON. Raw answer:'
        Write-Host $show
    }
    exit 0} catch {
    Say ('review failed and was skipped: ' + $_.Exception.Message)
    exit 0
}