<#
Installs the pre-push hook into this clone. Run it yourself, once:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\agy-review\install-hook.ps1
Use -Uninstall to remove it, -Force to replace a hook that is already there.
#>
param([switch]$Uninstall, [switch]$Force)
$root = (git rev-parse --show-toplevel).Trim()
$hooks = (git -C $root rev-parse --git-path hooks).Trim()
if (-not [System.IO.Path]::IsPathRooted($hooks)) { $hooks = Join-Path $root $hooks }
$dest = Join-Path $hooks 'pre-push'
if ($Uninstall) {
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest; Write-Host 'pre-push hook removed.' } else { Write-Host 'no pre-push hook to remove.' }
    exit 0
}
if ((Test-Path -LiteralPath $dest) -and -not $Force) { Write-Host ('A pre-push hook already exists at ' + $dest + '. Use -Force to replace it.'); exit 1 }
New-Item -ItemType Directory -Force -Path $hooks | Out-Null
$text = [System.IO.File]::ReadAllText((Join-Path $root 'tools\agy-review\pre-push')) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Installed ' + $dest + '. It only runs when you push with AGY_REVIEW=1.')