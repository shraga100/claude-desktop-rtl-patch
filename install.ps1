<#
.SYNOPSIS
    Local installer for Claude Desktop RTL Patcher.
    Runs patch.ps1 from the SAME directory as this script.
    Does NOT contact the network. Does NOT download patch.ps1.

.DESCRIPTION
    Trust model: you explicitly downloaded a release archive or cloned the repo.
    install.ps1 runs only what is already on disk — no irm, no GitHub calls.

    To update to a newer release, run update-local-patcher.ps1 instead.
    That is the ONLY script in this package that contacts the network,
    and it verifies every file hash before replacing anything.

.PARAMETER Auto
    Passed through to patch.ps1 to enable non-interactive auto-patch mode.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Auto
#>
param([switch]$Auto)

$ErrorActionPreference = 'Stop'

# Resolve script directory robustly (works for both file execution and dot-source).
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$PatcherPath = Join-Path $ScriptDir "patch.ps1"

# ── Preflight: patch.ps1 must be present ────────────────────────────────────
if (-not (Test-Path -LiteralPath $PatcherPath)) {
    Write-Host ""
    Write-Host "ERROR: patch.ps1 not found next to install.ps1." -ForegroundColor Red
    Write-Host "  Expected: $PatcherPath" -ForegroundColor Red
    Write-Host ""
    Write-Host "This installer only works from a complete release package." -ForegroundColor Yellow
    Write-Host "  1. Download a release archive from:" -ForegroundColor Yellow
    Write-Host "       https://github.com/shraga100/claude-desktop-rtl-patch/releases" -ForegroundColor Cyan
    Write-Host "  2. Extract the archive and run install.ps1 from the extracted folder." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To update an existing installation, run update-local-patcher.ps1 instead." -ForegroundColor Yellow
    exit 1
}

# ── Elevation: relaunch THIS script as admin if needed ──────────────────────
# We relaunch install.ps1 (not patch.ps1) so the preflight check runs again
# under the elevated context with the same ScriptDir. No remote code involved.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Write-Host "  source: local file — $($MyInvocation.MyCommand.Path)" -ForegroundColor DarkGray
    $selfPath = $MyInvocation.MyCommand.Path
    $autoArg  = if ($Auto) { ' -Auto' } else { '' }
    Start-Process -FilePath PowerShell.exe -Verb RunAs `
        -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$selfPath`"$autoArg"
    Exit
}

# ── Run local patcher ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Claude RTL Patcher — local install" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Script : $PatcherPath" -ForegroundColor DarkGray
Write-Host "  Network: NONE (purely local)" -ForegroundColor DarkGray
Write-Host ""

$autoSwitch = if ($Auto) { @('-Auto') } else { @() }
& PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File $PatcherPath @autoSwitch
