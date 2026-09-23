$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$source = [IO.File]::ReadAllText((Join-Path $repo 'patch.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Patch syntax errors.' }
$core = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-PatchCore' }, $true)
$transaction = $core.FindAll({ param($n) $n -is [Management.Automation.Language.TryStatementAst] }, $true) |
    Where-Object { $_.CatchClauses.Extent.Text -match 'INITIATING AUTOMATIC ROLLBACK' } | Select-Object -First 1
if (-not $transaction) { throw 'Transaction catch not found.' }
$catchBody = $transaction.CatchClauses[0].Body.Extent.Text
$script:restored = $false
function Remove-FastWorkspace { throw 'Simulated locked workspace' }
function Restore-Patch { param([switch]$IsRollback) $script:restored = [bool]$IsRollback }
function Write-Warn { param($message) }
function Write-Host { param($message, $ForegroundColor) }
$TmpAsarPath = $null
try { & ([ScriptBlock]::Create($catchBody.Substring(1, $catchBody.Length - 2))) } catch { }
if (-not $script:restored) { throw 'Cleanup failure prevented live-file rollback.' }
$wrapper = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-Patch' }, $true)
. ([ScriptBlock]::Create($wrapper.Extent.Text))
$script:entered = 0
function Install-PatchCore { $script:entered++; throw 'Simulated transaction failure' }
try { Install-Patch } catch { }
try { Install-Patch } catch { }
if ($script:entered -ne 2) { throw 'Failed install did not release the mutex.' }
[Console]::WriteLine('PASS: cleanup failure still rolls back; failed install releases its mutex.')
