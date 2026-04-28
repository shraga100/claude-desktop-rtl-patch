# SECURITY NOTE: This bootstrap downloads patch.ps1 from GitHub and elevates it.
# Trust model is "trust-on-first-use" against raw.githubusercontent.com over TLS.
# Once installed, the patcher's auto-update Scheduled Task will *not* re-download:
# it caches a local copy under %ProgramData%\ClaudeRtlPatch\patch.ps1 and runs that
# from then on. Audit the local patch.ps1 before re-running install.ps1.
$f = Join-Path $env:TEMP "claude_rtl_patch.ps1"
$content = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main/patch.ps1"
# Invoke-RestMethod keeps a UTF-8 BOM as a leading U+FEFF char. Strip it so
# WriteAllText with UTF8Encoding($true) doesn't end up writing a double BOM
# (which PS 5.1 then fails to parse as a leading <# block comment).
if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
[System.IO.File]::WriteAllText($f, $content, [System.Text.UTF8Encoding]::new($true))
Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$f`""
