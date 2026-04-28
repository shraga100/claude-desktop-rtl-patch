<#
.SYNOPSIS
    Explicit network updater for Claude Desktop RTL Patcher.

.DESCRIPTION
    THIS IS THE ONLY SCRIPT IN THIS PACKAGE THAT CONTACTS THE NETWORK.
    install.ps1 and patch.ps1 are purely local and never download code.

    This script:
      1. Fetches the latest (or specified) release manifest from GitHub.
      2. Downloads each listed file from the same GitHub release.
      3. Verifies every file's SHA-256 against the manifest before writing anything.
      4. Asks for confirmation before replacing local files.
      5. Replaces local files ONLY after ALL verifications pass.

    If any hash check fails, the update is aborted and no local files are changed.

    TRUST MODEL AND LIMITATIONS:
    This script implements Trust-On-First-Use (TOFU) against GitHub Releases over
    HTTPS. The manifest.json and the script files are downloaded from the same
    release, so a compromised release would compromise both. Specifically:

      * The SHA-256 hashes protect integrity within a single release (detect
        partial downloads, CDN corruption, man-in-the-middle on the file body).
      * They do NOT protect against a malicious actor who controls the GitHub
        repo/release and publishes a backdoored release with matching hashes.
      * This is acceptable for a community tool installed with explicit user intent,
        but users who require supply-chain guarantees beyond TOFU should review the
        source code on the tagged commit before running this updater.

    A stronger alternative (not yet implemented):
      * The maintainer signs the manifest with a GPG key whose public key is
        embedded in this script, and this script verifies the GPG signature
        before trusting any SHA-256 hash in the manifest.

.PARAMETER Force
    Skip both confirmation prompts. All hash checks still run.
    Does NOT skip the TOFU acknowledgment — use -AcceptTofu for that.

.PARAMETER AcceptTofu
    Explicitly acknowledge the Trust-On-First-Use trust model and skip the
    TOFU warning prompt. Required when running non-interactively (e.g. CI).
    By requiring an explicit flag, this makes the TOFU risk an opt-in choice
    rather than something silently accepted by running the script.

.PARAMETER ReleaseTag
    Download a specific release tag (e.g. "v1.2.0") instead of the latest.

.EXAMPLE
    .\update-local-patcher.ps1 -AcceptTofu
    .\update-local-patcher.ps1 -Force -AcceptTofu
    .\update-local-patcher.ps1 -AcceptTofu -ReleaseTag v1.2.0
#>
param(
    [switch]$Force,
    [switch]$AcceptTofu,
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

# ── TOFU acknowledgment gate ────────────────────────────────────────────────
# This script uses Trust-On-First-Use (TOFU): it trusts whatever GitHub
# publishes under the latest release tag over HTTPS. SHA-256 hashes guard
# against transit corruption but NOT against a malicious release published by
# whoever controls the GitHub repo. You must explicitly acknowledge this model
# before the script proceeds — either via -AcceptTofu or an interactive prompt.
if (-not $AcceptTofu) {
    Write-Host "  TRUST MODEL: Trust-On-First-Use (TOFU)" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  SHA-256 hashes verify integrity of files within a release." -ForegroundColor Yellow
    Write-Host "  They do NOT protect against a malicious release published" -ForegroundColor Yellow
    Write-Host "  by whoever controls the GitHub repository." -ForegroundColor Yellow
    Write-Host "  To review source before trusting, visit:" -ForegroundColor Yellow
    Write-Host "    https://github.com/$RepoOwner/$RepoName/releases" -ForegroundColor Cyan
    Write-Host ""
    $tofuAnswer = Read-Host "Type 'I understand TOFU' to continue, or press Enter to cancel"
    if ($tofuAnswer -ne 'I understand TOFU') {
        Write-Host "Update cancelled (TOFU not acknowledged)." -ForegroundColor Yellow
        Write-Host "Re-run with -AcceptTofu to skip this prompt." -ForegroundColor DarkGray
        exit 0
    }
    Write-Host ""
}

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
