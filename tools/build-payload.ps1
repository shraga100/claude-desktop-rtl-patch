<#
.SYNOPSIS
    Assembles the renderer RTL payload from src/ and injects it into patch.ps1.
.DESCRIPTION
    Single source of truth for the injected JS is src/rtl-core.js (pure, tested)
    plus src/rtl-payload.js (DOM layer / IIFE). This script:
      1. Reads src/rtl-core.js and strips its module.exports guard.
      2. Inlines that core into src/rtl-payload.js at the /*__RTL_CORE__*/ marker.
      3. Validates the assembled blob with `node --check`.
      4. Replaces the region between the CLAUDE RTL PATCH START/END markers inside
         patch.ps1's $RTL_INJECTION_CODE here-string.
      5. Checks src/asar-patch.cjs (ASCII only, `node --check`, no here-string
         terminator) and splices it between the CLAUDE RTL ASAR HELPER START/END
         markers inside patch.ps1's $ASAR_HELPER_CODE here-string.
      6. Splices src/translate.js (guard stripped, ASCII only, `node --check`) between
         the CLAUDE RTL TRANSLATE START/END markers inside patch.ps1's
         $RTL_TRANSLATE_CODE here-string; patch.ps1 inlines it into the renderer
         payload only when translation is enabled.
      7. Splices src/main-payload.js (guard stripped, ASCII only, `node --check`)
         between the CLAUDE RTL MAIN PATCH START/END markers inside patch.ps1's
         $MAIN_INJECTION_CODE here-string.
      8. Writes patch.ps1 back as UTF-8 (no BOM), LF line endings.

    After running this you MUST re-sign:  tools/sign-release.ps1
    then commit patch.ps1 + patch.ps1.sig together.

    NOTE: keep this script ASCII-only. PowerShell 5.1 reads BOM-less .ps1 files
    using the system ANSI code page; non-ASCII bytes (e.g. an em-dash) corrupt and
    break parsing on Hebrew/RTL locales.
.NOTES
    Maintainer-only build tool. Run:  npm run build   (or directly).
#>
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$corePath   = Join-Path $repoRoot 'src\rtl-core.js'
$payPath    = Join-Path $repoRoot 'src\rtl-payload.js'
$helperPath = Join-Path $repoRoot 'src\asar-patch.cjs'
$transPath  = Join-Path $repoRoot 'src\translate.js'
$mainPath   = Join-Path $repoRoot 'src\main-payload.js'
$patchPath  = Join-Path $repoRoot 'patch.ps1'

foreach ($p in @($corePath, $payPath, $helperPath, $transPath, $mainPath, $patchPath)) {
    if (-not (Test-Path $p)) { Write-Host "Missing: $p" -ForegroundColor Red; exit 1 }
}

# Read sources, normalize to LF.
function Read-Lf([string]$path) {
    return ([IO.File]::ReadAllText($path)) -replace "`r`n", "`n"
}

# Strips the CommonJS export guard (kept only for unit tests).
function Strip-Guard([string]$text) {
    $i = $text.IndexOf("if (typeof module !==")
    if ($i -ge 0) { return $text.Substring(0, $i).TrimEnd() + "`n" }
    return $text
}

# Fails the build unless the text is ASCII only (patch.ps1 is read as ANSI by PS 5.1)
# and cannot terminate the here-string it is embedded in.
function Assert-Embeddable([string]$text, [string]$name) {
    if ($text -match '[^\x00-\x7F]') {
        Write-Host "$name contains non-ASCII characters - aborting, patch.ps1 untouched." -ForegroundColor Red; exit 1
    }
    if ($text -match "(?m)^'@") {
        Write-Host "$name has a line starting with '@ (here-string terminator) - aborting." -ForegroundColor Red; exit 1
    }
}

function Check-Syntax([string]$text, [string]$name) {
    $f = Join-Path $repoRoot '.payload-check.tmp.js'
    [IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding $false))
    & node --check $f
    $ok = $?
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    if (-not $ok) { Write-Host "node --check failed on $name - aborting, patch.ps1 untouched." -ForegroundColor Red; exit 1 }
}

$core   = Strip-Guard (Read-Lf $corePath)
$pay    = Read-Lf $payPath
$trans  = Strip-Guard (Read-Lf $transPath)
$mainJs = Strip-Guard (Read-Lf $mainPath)

# Inline the core into the payload's placeholder.
$marker = '/*__RTL_CORE__*/'
if ($pay.IndexOf($marker) -lt 0) {
    Write-Host "Placeholder $marker not found in rtl-payload.js" -ForegroundColor Red; exit 1
}
$payInlined = $pay.Replace($marker, $core.TrimEnd("`n"))
$transMarker = '/*__RTL_TRANSLATE_CODE__*/'
if ($payInlined.IndexOf($transMarker) -lt 0) {
    Write-Host "Placeholder $transMarker not found in rtl-payload.js" -ForegroundColor Red; exit 1
}

# Wrap with the section markers expected inside patch.ps1.
$block = "// --- CLAUDE RTL PATCH START ---`n" + $payInlined.TrimEnd("`n") + "`n// --- CLAUDE RTL PATCH END ---"

# Validate syntax before touching patch.ps1. Keep the temp file inside the repo
# (system TEMP can be sandbox-protected against cleanup).
Check-Syntax $payInlined 'the renderer payload'
Check-Syntax ($payInlined.Replace($transMarker, $trans.TrimEnd("`n"))) 'the renderer payload with translation'
Assert-Embeddable $trans 'src/translate.js'
Check-Syntax $trans 'src/translate.js'
Assert-Embeddable $mainJs 'src/main-payload.js'
Check-Syntax $mainJs 'src/main-payload.js'

# Splice the block into patch.ps1 between the markers (inclusive).
$patch = Read-Lf $patchPath
$pattern = '(?s)// --- CLAUDE RTL PATCH START ---.*?// --- CLAUDE RTL PATCH END ---'
if (-not [regex]::IsMatch($patch, $pattern)) {
    Write-Host "RTL PATCH markers not found in patch.ps1" -ForegroundColor Red; exit 1
}
# Use a MatchEvaluator so '$' in the JS is not interpreted as a replacement token.
$evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block }
$updated = [regex]::Replace($patch, $pattern, $evaluator, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Translation layer: inlined by patch.ps1 into the renderer payload only when enabled.
$transBlock = "// --- CLAUDE RTL TRANSLATE START ---`n" + $trans.TrimEnd("`n") + "`n// --- CLAUDE RTL TRANSLATE END ---"
$transPattern = '(?s)// --- CLAUDE RTL TRANSLATE START ---.*?// --- CLAUDE RTL TRANSLATE END ---'
if (-not [regex]::IsMatch($updated, $transPattern)) {
    Write-Host "TRANSLATE markers not found in patch.ps1" -ForegroundColor Red; exit 1
}
$transEvaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $transBlock }
$updated = [regex]::Replace($updated, $transPattern, $transEvaluator, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Main-process payload (UI direction switch + optional translation bridge).
$mainBlock = "// --- CLAUDE RTL MAIN PATCH START ---`n" + $mainJs.TrimEnd("`n") + "`n// --- CLAUDE RTL MAIN PATCH END ---"
$mainPattern = '(?s)// --- CLAUDE RTL MAIN PATCH START ---.*?// --- CLAUDE RTL MAIN PATCH END ---'
if (-not [regex]::IsMatch($updated, $mainPattern)) {
    Write-Host "MAIN PATCH markers not found in patch.ps1" -ForegroundColor Red; exit 1
}
$mainEvaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $mainBlock }
$updated = [regex]::Replace($updated, $mainPattern, $mainEvaluator, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# ASAR helper: embedded verbatim, so it must survive PowerShell 5.1 reading the
# BOM-less patch.ps1 as ANSI (ASCII only) and must not end the here-string early.
$helper = (Read-Lf $helperPath).TrimEnd("`n")
if ($helper -match '[^\x00-\x7F]') {
    Write-Host "src/asar-patch.cjs contains non-ASCII characters - aborting, patch.ps1 untouched." -ForegroundColor Red; exit 1
}
if ($helper -match "(?m)^'@") {
    Write-Host "src/asar-patch.cjs has a line starting with '@ (here-string terminator) - aborting." -ForegroundColor Red; exit 1
}
& node --check $helperPath
if (-not $?) { Write-Host "node --check failed on src/asar-patch.cjs - aborting, patch.ps1 untouched." -ForegroundColor Red; exit 1 }
$helperBlock = "// --- CLAUDE RTL ASAR HELPER START ---`n" + $helper + "`n// --- CLAUDE RTL ASAR HELPER END ---"
$helperPattern = '(?s)// --- CLAUDE RTL ASAR HELPER START ---.*?// --- CLAUDE RTL ASAR HELPER END ---'
if (-not [regex]::IsMatch($updated, $helperPattern)) {
    Write-Host "ASAR HELPER markers not found in patch.ps1" -ForegroundColor Red; exit 1
}
$helperEvaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $helperBlock }
$updated = [regex]::Replace($updated, $helperPattern, $helperEvaluator, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Sanity guard: never write a suspiciously small file (protects against any
# upstream failure that could otherwise truncate patch.ps1).
if ($updated.Length -lt ($patch.Length / 2)) {
    Write-Host "SANITY FAIL: assembled file too short ($($updated.Length) chars) - aborting, file untouched." -ForegroundColor Red
    exit 1
}

if ($updated -eq $patch) {
    Write-Host "Payload unchanged - patch.ps1 already up to date." -ForegroundColor Yellow
} else {
    [IO.File]::WriteAllText($patchPath, $updated, (New-Object System.Text.UTF8Encoding $false))
    $written = [IO.File]::ReadAllBytes($patchPath).Length
    Write-Host "Injected payload into patch.ps1 (block $($block.Length) chars; file now $written bytes)." -ForegroundColor Green
}

Write-Host ""
Write-Host "NEXT: re-sign and commit:" -ForegroundColor Yellow
Write-Host "  tools/sign-release.ps1"
Write-Host "  git add patch.ps1 patch.ps1.sig"
