<#
.SYNOPSIS
    Checks for the patch.ps1 helpers behind #48 (signature-aware cowork-svc search),
    #45 (package selection, stale-cert sweep) and the Stop-ClaudeServices CLI filter.
.DESCRIPTION
    Loads the functions straight from patch.ps1's AST (nothing else in patch.ps1 runs)
    and exercises them with synthetic data and mocked cmdlets. Read-only: it never
    touches certificate stores, processes or Claude's files. When an installed Claude
    has a cowork-svc.exe.bak, it is also checked read-only.
    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File test\patch-helpers.check.ps1
#>
$ErrorActionPreference = 'Stop'
$repoRoot  = Split-Path -Parent $PSScriptRoot
$patchPath = Join-Path $repoRoot 'patch.ps1'

$failures = 0
function Assert($cond, [string]$msg) {
    if ($cond) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
    else       { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:failures++ }
}

$tokens = $null; $errs = $null
# ParseFile reads the BOM-less file the way `powershell -File patch.ps1` does (system
# ANSI code page), so this also proves a direct run from the repo parses.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($patchPath, [ref]$tokens, [ref]$errs)
Write-Host "patch.ps1 parse"
Assert ($errs.Count -eq 0) "patch.ps1 parses without errors ($($errs.Count))"

function Import-PatchFunction([string]$name) {
    $fn = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Function $name not found in patch.ps1" }
    . ([ScriptBlock]::Create($fn.Extent.Text))
    Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
}

foreach ($n in 'Get-PeSecurityDirOffset', 'Find-Bytes', 'Select-ClaudePackage', 'Stop-ClaudeServices', 'Remove-StaleRtlCerts') {
    Import-PatchFunction $n
}

$script:Logged = @()
function Write-Log($m)     { $script:Logged += $m }
function Write-Step($m)    { }
function Write-Success($m) { }
function Write-Warn($m)    { }

# --- Get-PeSecurityDirOffset ------------------------------------------------------
Write-Host "`nGet-PeSecurityDirOffset"
function New-FakePe([int]$magic, [uint32]$secOff, [uint32]$secSize, [int]$len) {
    $b = New-Object byte[] $len
    $b[0] = 0x4D; $b[1] = 0x5A
    $pe = 0x80
    [BitConverter]::GetBytes([int]$pe).CopyTo($b, 0x3C)
    $b[$pe] = 0x50; $b[$pe+1] = 0x45
    [BitConverter]::GetBytes([uint16]$magic).CopyTo($b, $pe + 24)
    $dd = if ($magic -eq 0x20b) { $pe + 24 + 112 } else { $pe + 24 + 96 }
    [BitConverter]::GetBytes($secOff).CopyTo($b, $dd + 32)
    [BitConverter]::GetBytes($secSize).CopyTo($b, $dd + 36)
    return ,$b
}
Assert ((Get-PeSecurityDirOffset (New-FakePe 0x20b 0x300 0x100 0x400)) -eq 0x300) 'PE32+: returns the security directory offset'
Assert ((Get-PeSecurityDirOffset (New-FakePe 0x10b 0x300 0x100 0x400)) -eq 0x300) 'PE32: returns the security directory offset'
Assert ((Get-PeSecurityDirOffset (New-FakePe 0x20b 0 0 0x400)) -eq 0x400) 'unsigned PE: returns the file length'
Assert ((Get-PeSecurityDirOffset (New-FakePe 0x20b 0x300 0x200 0x400)) -eq 0x400) 'directory past EOF: returns the file length'
Assert ((Get-PeSecurityDirOffset (New-FakePe 0x999 0x300 0x100 0x400)) -eq 0x400) 'unknown optional-header magic: returns the file length'
$notPe = New-Object byte[] 0x200
Assert ((Get-PeSecurityDirOffset $notPe) -eq 0x200) 'non-PE bytes: returns the file length'
Assert ((Get-PeSecurityDirOffset ([byte[]](1, 2, 3))) -eq 3) 'tiny input: returns the file length'

# Anchor inside the signature must be ignored; one before it must still be found.
$fake = New-FakePe 0x20b 0x300 0x100 0x400
$anchor = [Text.Encoding]::ASCII.GetBytes('Anthropic, PBC')
$anchor.CopyTo($fake, 0x350)
$sig = Get-PeSecurityDirOffset $fake
$pos = Find-Bytes -Haystack $fake -Needle $anchor
Assert ($pos -ge $sig) 'anchor only inside the signature is at/after the signature start (search stops)'
$anchor.CopyTo($fake, 0x200)
$pos = Find-Bytes -Haystack $fake -Needle $anchor
Assert ($pos -eq 0x200 -and $pos -lt $sig) 'anchor in the image body is still found before the signature'

# Installed Claude, read-only (skipped when absent).
# WindowsApps can't be listed without admin, so resolve the folder via Appx.
$bak = $null
$pkgDir = (Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1).InstallLocation
if ($pkgDir) {
    $p = Join-Path $pkgDir 'app\resources\cowork-svc.exe.bak'
    if (Test-Path -LiteralPath $p) { $bak = Get-Item -LiteralPath $p }
}
if ($bak) {
    $bytes = [IO.File]::ReadAllBytes($bak.FullName)
    $sig = Get-PeSecurityDirOffset $bytes
    $first = Find-Bytes -Haystack $bytes -Needle $anchor
    Write-Host "  [INFO] $($bak.FullName): signature at $([Convert]::ToString($sig,16)), first anchor at $([Convert]::ToString($first,16))"
    Assert ($sig -lt $bytes.Length) 'installed cowork-svc.exe.bak: signature directory detected'
    $where = if ($first -lt 0 -or $first -ge $sig) { 'only inside the signature -> patch will re-sign without a byte swap' } else { 'in the image body -> patch will swap the embedded cert' }
    Write-Host "  [INFO] 'Anthropic, PBC' found $where"
} else {
    Write-Host "  [SKIP] no installed cowork-svc.exe.bak to check"
}

# --- Select-ClaudePackage --------------------------------------------------------
Write-Host "`nSelect-ClaudePackage"
$store  = [pscustomobject]@{ Name = 'AnthropicPBC.Claude'; Version = '2.26454.2.0' }
$direct = [pscustomobject]@{ Name = 'Claude'; Version = '2.31226.0.0' }
$other  = [pscustomobject]@{ Name = 'SomethingClaude'; Version = '1.0.0.0' }
$script:Logged = @()
Assert ((Select-ClaudePackage @($store, $direct)).Name -eq 'Claude') 'prefers the package named exactly Claude'
Assert (@($script:Logged | Where-Object { $_ -like 'Multiple Claude packages found*' }).Count -eq 1) 'logs when several packages match'
$script:Logged = @()
Assert ((Select-ClaudePackage @($direct)).Name -eq 'Claude') 'single package returned as-is'
Assert ($script:Logged.Count -eq 0) 'no log line for a single package'
Assert ((Select-ClaudePackage @($store)).Name -eq 'AnthropicPBC.Claude') 'only another match: still returned (unchanged behaviour)'
Assert ((Select-ClaudePackage @($other, $store)).Name -eq 'SomethingClaude') 'no exact Claude: first candidate (unchanged behaviour)'
Assert ($null -eq (Select-ClaudePackage @())) 'empty input: $null'
Assert ($null -eq (Select-ClaudePackage $null)) '$null input: $null'

# --- Stop-ClaudeServices CLI filter ---------------------------------------------
Write-Host "`nStop-ClaudeServices"
$desktop = 'C:\Program Files\WindowsApps\Claude_5.11492.5.0_x64__pzs8sxrjxfjjc\app\claude.exe'
$appCli  = 'C:\Users\u\AppData\Local\Claude-Data\claude_pzs8sxrjxfjjc\claude-code\2.1.325\abc\claude.exe'
$roamCli = 'C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.0\claude.exe'
$local   = 'C:\Users\u\.local\bin\claude.exe'
$script:FakeProcs = @(
    [pscustomobject]@{ Path = $desktop }, [pscustomobject]@{ Path = $appCli },
    [pscustomobject]@{ Path = $roamCli }, [pscustomobject]@{ Path = $local },
    [pscustomobject]@{ Path = $null })
$script:Stopped = @()
function Get-WmiObject { param($Class) }
function Start-Sleep { param($Seconds) }
function Get-Process {
    [CmdletBinding()] param($Name)
    if ($Name -eq 'claude') { return $script:FakeProcs }
    return @()
}
function Stop-Process {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force, $Name)
    process { if ($InputObject) { $script:Stopped += , $InputObject.Path } }
}
$script:Logged = @()
Stop-ClaudeServices
Assert ($script:Stopped -contains $desktop) 'stops the desktop app'
Assert ($script:Stopped -contains $appCli)  'stops the CLI copies the desktop app runs (Claude-Data\...\claude-code)'
Assert ($script:Stopped -contains $roamCli) 'stops CLI copies under Roaming\Claude\claude-code'
Assert ($script:Stopped -notcontains $local) 'leaves a standalone ~\.local\bin CLI running'
Assert (@($script:Stopped | Where-Object { -not $_ }).Count -eq 1) 'stops a claude.exe whose path is unreadable'
Assert (@($script:Logged | Where-Object { $_ -like 'Leaving 1 standalone*' }).Count -eq 1) 'logs the standalone CLI left running'

# --- Remove-StaleRtlCerts (shape only; never run against real stores here) -------
Write-Host "`nRemove-StaleRtlCerts"
$fnText = ($ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-StaleRtlCerts' }, $true)).Extent.Text
Assert ($fnText -match "Thumbprint -ne \`$KeepThumbprint") 'keeps the current thumbprint'
Assert ($fnText -match "FriendlyName -eq 'Claude_RTL_SelfSigned'") 'only touches Claude_RTL_SelfSigned certificates'
$patchText = [IO.File]::ReadAllText($patchPath)
$callIdx = $patchText.IndexOf('Remove-StaleRtlCerts -KeepThumbprint $Cert.Thumbprint')
$signIdx = $patchText.IndexOf('Successfully re-signed cowork-svc.exe')
Assert ($callIdx -gt $signIdx -and $signIdx -gt 0) 'the sweep is called only after cowork-svc.exe is re-signed'

if ($failures -gt 0) { Write-Host "`n$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll patch helper checks passed." -ForegroundColor Green
