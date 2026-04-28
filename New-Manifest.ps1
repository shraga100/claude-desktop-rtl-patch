<#
.SYNOPSIS
    Generates manifest.json with SHA-256 hashes of all releasable scripts.
    Run this before tagging a release.

.EXAMPLE
    .\New-Manifest.ps1 -Version v1.3.0
#>
param(
    [Parameter(Mandatory)][string]$Version
)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Files = @('patch.ps1', 'install.ps1', 'update-local-patcher.ps1')

$fileEntries = [ordered]@{}
foreach ($f in $Files) {
    $path = Join-Path $ScriptDir $f
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "WARNING: $f not found — skipping." -ForegroundColor Yellow
        continue
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    $fileEntries[$f] = [ordered]@{ sha256 = $hash }
    Write-Host "  $f : $hash" -ForegroundColor Green
}

$manifest = [ordered]@{
    version = $Version
    files   = $fileEntries
}

$outPath = Join-Path $ScriptDir "manifest.json"
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host ""
Write-Host "manifest.json written to: $outPath" -ForegroundColor Cyan
