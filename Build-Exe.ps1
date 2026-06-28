<#
.SYNOPSIS
    Compiles SystemInfo-GUI.ps1 to SystemInfo.exe, injecting the self-update
    token at build time so it lands in the exe but never in the tracked source.

.DESCRIPTION
    The private-repo self-update needs a GitHub token. We never commit it: the
    source keeps `$script:UpdateToken = ''`, and this script substitutes the real
    value (read from the gitignored update-token.txt) into a TEMP copy that is
    what actually gets compiled. The temp copy is deleted afterwards.

    The token should be a FINE-GRAINED PAT scoped to ONLY this repo with
    read-only "Contents" permission. Anyone who extracts the distributed exe can
    read it, so keep its blast radius minimal and rotate it if leaked.

    Run this instead of calling Invoke-ps2exe directly whenever you ship a build.
#>
[CmdletBinding()]
param(
    [string]$Source    = (Join-Path $PSScriptRoot 'SystemInfo-GUI.ps1'),
    [string]$Output    = (Join-Path $PSScriptRoot 'SystemInfo.exe'),
    [string]$TokenFile = (Join-Path $PSScriptRoot 'update-token.txt')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    throw "ps2exe is not installed. Run: Install-Module ps2exe -Scope CurrentUser"
}

$script = Get-Content -LiteralPath $Source -Raw

$token = ''
if (Test-Path -LiteralPath $TokenFile) {
    $token = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
}
if ($token) {
    if ($token -match "[`r`n']") { throw "update-token.txt contains a newline or quote - paste only the bare token." }
    Write-Host "Injecting update token (len $($token.Length)) from $TokenFile" -ForegroundColor Cyan
    $patched = $script -replace "(?m)^\$script:UpdateToken\s*=\s*''", "`$script:UpdateToken = '$token'"
    if ($patched -eq $script) { throw "Could not find the `$script:UpdateToken = '' line to inject into." }
} else {
    Write-Host "WARNING: no update-token.txt found - building WITHOUT a self-update token." -ForegroundColor Yellow
    Write-Host "         The Check for Updates button will fail against the private repo." -ForegroundColor Yellow
    $patched = $script
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("SystemInfo-build-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
try {
    Set-Content -LiteralPath $temp -Value $patched -Encoding UTF8
    Invoke-ps2exe $temp $Output -noConsole
    Write-Host "Built $Output" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
