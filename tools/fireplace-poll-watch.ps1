<#
.SYNOPSIS
Read-only watcher for the IntelliFire local /poll endpoint.

.DESCRIPTION
Sends ONLY an HTTP GET to http://<Ip>/poll every IntervalSec seconds.
Never sends commands, never POSTs, never calls /get_challenge or /post.
Prints a timestamped line only when a field value changes.

HOW TO USE
 1. Run:  powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\fireplace-poll-watch.ps1" -Ip <fireplace IP>
 2. Wait for the "baseline" line.
 3. Flip the WALL SWITCH on. Wait about 60 seconds (ignition takes time).
 4. Flip the WALL SWITCH off. Wait about 60 seconds.
 5. Note which field name changed on each flip. Press Ctrl+C to stop.

Fields in -Ignore are not printed (they change constantly and are noise).
Use -MaxSeconds 10 for a short test run.
#>
param(
    [Parameter(Mandatory = $true)][string]$Ip,
    [int]$IntervalSec = 2,
    [int]$TimeoutSec = 3,
    [int]$MaxSeconds = 0,
    [string[]]$Ignore = @('uptime', 'connection_quality')
)

$ErrorActionPreference = 'Stop'
$url = "http://$Ip/poll"
$prev = $null
$start = Get-Date

while ($true) {
    if ($MaxSeconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $MaxSeconds) { break }

    $stamp = Get-Date -Format 'HH:mm:ss'
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec $TimeoutSec
        $raw = $resp.Content
        if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
        $cur = $raw | ConvertFrom-Json
    }
    catch {
        Write-Host "$stamp  poll failed: $($_.Exception.Message)"
        Start-Sleep -Seconds $IntervalSec
        continue
    }

    $curMap = @{}
    foreach ($p in $cur.PSObject.Properties) {
        if ($Ignore -contains $p.Name) { continue }
        $curMap[$p.Name] = ($p.Value | ConvertTo-Json -Compress)
    }

    if ($null -eq $prev) {
        $summary = ($curMap.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        Write-Host "$stamp  baseline: $summary"
    }
    else {
        foreach ($k in $curMap.Keys) {
            if ($prev[$k] -ne $curMap[$k]) {
                Write-Host "$stamp  ${k}: $($prev[$k]) -> $($curMap[$k])"
            }
        }
    }
    $prev = $curMap

    Start-Sleep -Seconds $IntervalSec
}
