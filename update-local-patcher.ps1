<#
.SYNOPSIS
    Explicit network updater for Claude Desktop RTL Patcher.

.DESCRIPTION
    THIS IS THE ONLY SCRIPT IN THIS PACKAGE THAT CONTACTS THE NETWORK.
    install.ps1 and patch.ps1 are purely local and never download code.

    This script:
      1. Fetches the latest (or specified) release manifest from GitHub.
      2. Downloads each listed file.
      3. Verifies every file's SHA-256 against the manifest.
      4. Asks for confirmation before replacing anything on disk.
      5. Replaces local files ONLY after ALL verifications pass.

    If any hash check fails, the update is aborted and no local files are changed.

.PARAMETER Force
    Skip both confirmation prompts. All hash checks still run.

.PARAMETER ReleaseTag
    Download a specific release tag (e.g. "v1.2.0") instead of the latest.

.EXAMPLE
    .\update-local-patcher.ps1
    .\update-local-patcher.ps1 -Force
    .\update-local-patcher.ps1 -ReleaseTag v1.2.0
#>
param(
    [switch]$Force,
    [string]$ReleaseTag = ''
)

$ErrorActionPreference = 'Stop'

$RepoOwner    = 'shraga100'
$RepoName     = 'claude-desktop-rtl-patch'
$ManifestName = 'manifest.json'

# Resolve directory of THIS script (where we will write updated files).
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  NETWORK UPDATER  --  downloads code from the internet" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Repository : https://github.com/$RepoOwner/$RepoName" -ForegroundColor Cyan
Write-Host "  Target dir : $ScriptDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Every file is verified against its SHA-256 hash from the" -ForegroundColor DarkGray
Write-Host "  published release manifest before anything is written to disk." -ForegroundColor DarkGray
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Download and verify the latest patcher release? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Update cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Temp file tracker for cleanup on any failure path.
$TempFiles = [System.Collections.Generic.List[string]]::new()

function Remove-TempFiles {
    foreach ($f in $TempFiles) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    # ── Step 1: Determine release tag ────────────────────────────────────────
    if (-not $ReleaseTag) {
        Write-Host "[1/4] Fetching latest release info from GitHub API..." -ForegroundColor Cyan
        $apiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
        try {
            $releaseInfo = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
        } catch {
            throw "GitHub API request failed: $($_.Exception.Message). Check your internet connection."
        }
        $ReleaseTag = $releaseInfo.tag_name
        if (-not $ReleaseTag) { throw "Could not determine latest release tag from GitHub API response." }
        Write-Host "       Latest release : $ReleaseTag" -ForegroundColor Green
    } else {
        Write-Host "[1/4] Using specified release tag: $ReleaseTag" -ForegroundColor Cyan
    }

    # ── Step 2: Download manifest ─────────────────────────────────────────────
    Write-Host "[2/4] Downloading release manifest..." -ForegroundColor Cyan
    $baseUrl     = "https://github.com/$RepoOwner/$RepoName/releases/download/$ReleaseTag"
    $manifestUrl = "$baseUrl/$ManifestName"
    $tmpManifest = Join-Path $env:TEMP ("claude_rtl_manifest_" + [Guid]::NewGuid().ToString('N') + ".json")
    $TempFiles.Add($tmpManifest)

    try {
        Invoke-WebRequest -Uri $manifestUrl -OutFile $tmpManifest -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "Failed to download manifest from:`n  $manifestUrl`nError: $($_.Exception.Message)`n`nEnsure a '$ManifestName' is published with release $ReleaseTag."
    }
    Write-Host "       Manifest downloaded: $manifestUrl" -ForegroundColor Green

    $manifest = Get-Content -LiteralPath $tmpManifest -Raw | ConvertFrom-Json
    if (-not $manifest.files) { throw "Manifest is missing the required 'files' section." }

    $fileNames = $manifest.files | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name

    # ── Step 3: Download + verify each file ──────────────────────────────────
    Write-Host "[3/4] Downloading and verifying $($fileNames.Count) file(s)..." -ForegroundColor Cyan
    $verified = @{}   # fileName -> tmpPath

    foreach ($fileName in $fileNames) {
        $entry = $manifest.files.$fileName
        $expectedHash = if ($entry.sha256) { $entry.sha256.ToLower() } else { $null }
        if (-not $expectedHash) {
            throw "Manifest entry for '$fileName' is missing the 'sha256' field. Refusing to install unverified file."
        }

        $fileUrl = "$baseUrl/$fileName"
        $tmpFile = Join-Path $env:TEMP ("claude_rtl_upd_" + [Guid]::NewGuid().ToString('N') + "_$fileName")
        $TempFiles.Add($tmpFile)

        Write-Host "       Downloading $fileName ..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $fileUrl -OutFile $tmpFile -UseBasicParsing -ErrorAction Stop
        } catch {
            throw "Failed to download '$fileName' from:`n  $fileUrl`nError: $($_.Exception.Message)"
        }

        $actualHash = (Get-FileHash -LiteralPath $tmpFile -Algorithm SHA256).Hash.ToLower()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 MISMATCH for '$fileName'!`n  Expected : $expectedHash`n  Actual   : $actualHash`n`nUpdate aborted. The downloaded file does not match the published manifest hash."
        }
        Write-Host "       $fileName : SHA-256 OK ($actualHash)" -ForegroundColor Green
        $verified[$fileName] = $tmpFile
    }

    # ── Step 4: Final confirmation + replace ─────────────────────────────────
    Write-Host "[4/4] All $($verified.Count) file(s) verified." -ForegroundColor Green

    if (-not $Force) {
        Write-Host ""
        Write-Host "Files to be replaced:" -ForegroundColor White
        foreach ($fn in $verified.Keys) {
            Write-Host "  $ScriptDir\$fn" -ForegroundColor Gray
        }
        Write-Host ""
        $confirm2 = Read-Host "Replace local files with verified downloads? (y/N)"
        if ($confirm2 -ne 'y' -and $confirm2 -ne 'Y') {
            Write-Host "Update cancelled at final confirmation. No files changed." -ForegroundColor Yellow
            Remove-TempFiles
            exit 0
        }
    }

    foreach ($fn in $verified.Keys) {
        $tmpFile = $verified[$fn]
        $dest    = Join-Path $ScriptDir $fn
        try {
            Copy-Item -LiteralPath $tmpFile -Destination $dest -Force -ErrorAction Stop
            Write-Host "  Updated : $dest" -ForegroundColor Green
        } catch {
            throw "Failed to replace '$dest': $($_.Exception.Message)"
        }
    }

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  UPDATE COMPLETE -- Release $ReleaseTag installed." -ForegroundColor Green
    Write-Host "  Run install.ps1 to apply the updated patcher to Claude." -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Update aborted. No local files were modified." -ForegroundColor Yellow
} finally {
    Remove-TempFiles
}
