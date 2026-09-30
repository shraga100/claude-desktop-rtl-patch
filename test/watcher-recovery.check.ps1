# Checks the watcher's idle-check recovery (#40, #42) without touching real processes:
# extracts the watcher body from patch.ps1, parses it, and runs its decision logic
# against mocked Get-AppxPackage / Get-Process / Stop-Process / Start-Process.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File test\watcher-recovery.check.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$failures = 0
function Assert($condition, $message) {
    if ($condition) { Write-Host "  ok   $message" -ForegroundColor Green }
    else { Write-Host "  FAIL $message" -ForegroundColor Red; $script:failures++ }
}

# patch.ps1 has no BOM, so ParseFile would decode it as ANSI under PS 5.1.
$errors = $null
$source = [IO.File]::ReadAllText((Join-Path $repo 'patch.ps1'), [Text.Encoding]::UTF8)
$patchAst = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
Assert ($errors.Count -eq 0) 'patch.ps1 parses without errors'

$bodyAst = $patchAst.Find({ param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$watcherBody' }, $true)
$body = $bodyAst.Right.Expression.Value
Assert ($body -and $body.Length -gt 1000) 'watcher body extracted from Save-WatcherScript'

$errors = $null
$watcherAst = [Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$errors)
Assert ($errors.Count -eq 0) 'watcher body parses without errors'

$formatAst = $patchAst.Find({ param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$global:RtlWatcherFormat' }, $true)
$format = $formatAst.Right.Expression.Value
Assert (($body -split "`n")[0].Trim() -eq "# watcher-format: $format") "watcher body starts with '# watcher-format: $format'"

# The Claude Code CLI is claude.exe too: only Get-DesktopClaude may list claude processes.
$byName = ([regex]::Matches($body, 'Get-Process -Name claude\b')).Count
Assert ($byName -eq 1) 'watcher lists claude.exe processes in exactly one place (Get-DesktopClaude)'

# --- load the functions under test (mocks below shadow everything else they call) ---
foreach ($name in 'Test-DesktopClaudePath', 'Get-DesktopClaude', 'Write-WLogOnce', 'Get-RegisteredClaude', 'Get-TickDecision', 'Invoke-IdleCheck') {
    $fn = $watcherAst.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Function $name not found in the watcher body." }
    . ([ScriptBlock]::Create($fn.Extent.Text))
}

$apps  = 'C:\Program Files\WindowsApps'
$old   = "$apps\Claude_2.9939.4.0_x64__pzs8sxrjxfjjc"
$new   = "$apps\Claude_2.16120.0.0_x64__pzs8sxrjxfjjc"
$cli   = 'C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.284\claude.exe'
$local = 'C:\Users\u\.local\bin\claude.exe'

Write-Host "Test-DesktopClaudePath"
Assert (Test-DesktopClaudePath "$new\app\Claude.exe") 'MSIX package path is the desktop app'
Assert (Test-DesktopClaudePath "$apps\Deleted\Claude_2.9939.4.0_x64__pzs8sxrjxfjjcfa584140\app\Claude.exe") 'WindowsApps\Deleted path is the desktop app'
Assert (-not (Test-DesktopClaudePath $cli)) 'desktop-bundled Claude Code CLI is not'
Assert (-not (Test-DesktopClaudePath $local)) 'standalone Claude Code CLI is not'
Assert (-not (Test-DesktopClaudePath $null)) '$null path is not'

Write-Host "Get-TickDecision"
$regNew = @{ Version = [Version]'2.16120.0.0'; InstallLocation = $new; Aumid = 'Claude_pzs8sxrjxfjjc!Claude' }
$regOld = @{ Version = [Version]'2.9939.4.0';  InstallLocation = $old; Aumid = 'Claude_pzs8sxrjxfjjc!Claude' }
$patched = [Version]'2.9939.4.0'

$d = Get-TickDecision $regOld @("$old\app\Claude.exe", "$old\app\Claude.exe") $patched $true
Assert (-not $d.Patch -and $d.Stale.Count -eq 0) 'update staged but not registered yet: the running old version is left alone'

$d = Get-TickDecision $regNew @("$old\app\Claude.exe") $patched $true
Assert ($d.Patch -and $d.Stale.Count -eq 0) 'new version registered, old leftover running: re-patch (which ends it)'

$d = Get-TickDecision $regNew @("$old\app\Claude.exe") $patched $false
Assert (-not $d.Patch -and $d.Stale.Count -eq 1 -and $d.Relaunch) 'patch not allowed: end the leftover and relaunch'

$d = Get-TickDecision $regNew @("$new\app\Claude.exe") $patched $true
Assert ($d.Patch) 'new version running unpatched (launch missed by WMI): re-patch'

$d = Get-TickDecision $regNew @() $patched $true
Assert (-not $d.Patch -and -not $d.Relaunch) 'nothing running: wait for the next launch, never start Claude unasked'

$d = Get-TickDecision $regNew @("$old\app\Claude.exe", "$new\app\Claude.exe") $regNew.Version $true
Assert (-not $d.Patch -and $d.Stale.Count -eq 1 -and -not $d.Relaunch) 'already patched: end the leftover, no relaunch while the new version runs'

$d = Get-TickDecision $regNew @("$($new.ToUpper())\APP\CLAUDE.EXE") $regNew.Version $true
Assert ($d.Stale.Count -eq 0) 'path comparison ignores case'

$d = Get-TickDecision $regNew @("${new}fa584140\app\Claude.exe") $regNew.Version $true
Assert ($d.Stale.Count -eq 1) 'a sibling folder sharing the registered prefix is not the registered package'

$d = Get-TickDecision $null @("$old\app\Claude.exe") $patched $true
Assert (-not $d.Patch -and $d.Stale.Count -eq 0) 'no registered package: do nothing'

# --- Invoke-IdleCheck end to end, with every side effect mocked ---
function Get-AppxPackage { param($Name, $ErrorAction) $script:MockPkgs }
function Get-Process { param($Name, $ErrorAction) $script:MockProcs | Where-Object { $_.Name -in $Name } }
function Stop-Process {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force, $Name)
    process {
        if (-not $InputObject) { return }
        $script:Stopped += @($InputObject.Path)
        if (-not $script:KillFails) { $id = $InputObject.Id; $script:MockProcs = @($script:MockProcs | Where-Object { $_.Id -ne $id }) }
    }
}
function Start-Process { param($FilePath, $ErrorAction) $script:Started += @($FilePath) }
function Start-Sleep { param($Seconds) }
function Get-PatchedVer { $script:MockPatched }
function Test-PatchRunning { $script:MockPatchRunning }
function Invoke-AutoPatch($newVer, $exePath) { $script:AutoPatched += @("$newVer"); $script:PatchAttempted["$newVer"] = $true }
function Write-WLog($msg) { $script:Logged += @($msg) }
function Show-Toast($title, $body) { $script:Toasts += @($title) }

function Reset-Scenario($pkgLocation, $pkgVersion, [string[]]$procPaths, $patchedVer) {
    $script:MockPkgs = @([pscustomobject]@{ Version = $pkgVersion; InstallLocation = $pkgLocation; PackageFamilyName = 'Claude_pzs8sxrjxfjjc' })
    $i = 100
    $script:MockProcs = @($procPaths | ForEach-Object { [pscustomobject]@{ Name = 'claude'; Id = ($i++); Path = $_ } })
    $script:MockPatched = [Version]$patchedVer
    $script:MockPatchRunning = $false
    $script:KillFails = $false
    $script:Stopped = @(); $script:Started = @(); $script:AutoPatched = @(); $script:Logged = @(); $script:Toasts = @()
    $script:PatchAttempted = @{}
    $script:LoggedOnce = @{}
}

Write-Host "Invoke-IdleCheck"
Reset-Scenario $old '2.9939.4.0' @("$old\app\Claude.exe", $cli, $local) '2.9939.4.0'
Invoke-IdleCheck
Assert ($script:Stopped.Count -eq 0 -and $script:Started.Count -eq 0 -and $script:AutoPatched.Count -eq 0) 'deferred-registration window: no kill, no launch, no patch'

Reset-Scenario $new '2.16120.0.0' @("$old\app\Claude.exe", $cli) '2.9939.4.0'
Invoke-IdleCheck
Assert ($script:AutoPatched -contains '2.16120.0.0' -and $script:Stopped.Count -eq 0) 'leftover after update: hands off to Invoke-AutoPatch'
Invoke-IdleCheck
Assert ($script:AutoPatched.Count -eq 1) 'a second idle check does not re-patch the same version'
Assert ($script:Stopped -contains "$old\app\Claude.exe" -and $script:Stopped -notcontains $cli) '...but still ends the leftover, and never the CLI'
Assert ($script:Started -contains 'shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude') '...and relaunches Claude through its AUMID'

Reset-Scenario $new '2.16120.0.0' @("$old\app\Claude.exe") '2.9939.4.0'
$script:MockPatchRunning = $true
Invoke-IdleCheck
Assert ($script:AutoPatched.Count -eq 0 -and $script:Stopped.Count -eq 1) 'a patch already running: no second patch, leftover still ended'

Reset-Scenario $new '2.16120.0.0' @($cli, $local) '2.9939.4.0'
Invoke-IdleCheck
Assert ($script:AutoPatched.Count -eq 0 -and $script:Stopped.Count -eq 0) 'only CLI processes running: Claude Desktop counts as not running'

Reset-Scenario $new '2.16120.0.0' @("$old\app\Claude.exe") '2.16120.0.0'
$script:KillFails = $true
Invoke-IdleCheck; Invoke-IdleCheck; Invoke-IdleCheck
Assert ($script:Started.Count -eq 0 -and $script:Toasts.Count -eq 0) 'leftover survives the kill: no relaunch, no toast'
Assert ($script:Logged.Count -eq 2) '...and it is logged once, not every minute'

# A staged package might surface next to the registered one mid-switch; the running
# old version must not be mistaken for a leftover then.
Reset-Scenario $old '2.9939.4.0' @("$old\app\Claude.exe") '2.9939.4.0'
$script:MockPkgs += [pscustomobject]@{ Version = '2.16120.0.0'; InstallLocation = $new; PackageFamilyName = 'Claude_pzs8sxrjxfjjc' }
Invoke-IdleCheck; Invoke-IdleCheck
Assert ($script:Stopped.Count -eq 0 -and $script:Started.Count -eq 0 -and $script:AutoPatched.Count -eq 0) 'two Claude packages listed: skip the check entirely'
Assert ($script:Logged.Count -eq 1) '...logging that once'

# --- patch.ps1's own Stop-ClaudeServices: same CLI exclusion ---
Write-Host "Stop-ClaudeServices (patch.ps1)"
$stopFn = $patchAst.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-ClaudeServices' }, $true)
. ([ScriptBlock]::Create($stopFn.Extent.Text))
function Get-WmiObject { param($Class) }
function Write-Step($m) { }; function Write-Log($m) { }; function Write-Success($m) { }; function Write-Warn($m) { }
Reset-Scenario $new '2.16120.0.0' @("$new\app\Claude.exe", $cli, $local, $null) '2.9939.4.0'
Stop-ClaudeServices
Assert ($script:Stopped -contains "$new\app\Claude.exe" -and $script:Stopped -contains $cli) 'kills the desktop app and the CLI copies it spawned'
Assert ($script:Stopped -notcontains $local) 'leaves a standalone Claude Code CLI running'
Assert (@($script:Stopped | Where-Object { -not $_ }).Count -eq 1) 'still kills a claude.exe whose path is unreadable'

if ($failures -gt 0) { Write-Host "`n$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll watcher recovery checks passed." -ForegroundColor Green
