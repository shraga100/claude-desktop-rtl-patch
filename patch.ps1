<#
.SYNOPSIS
    Claude Desktop Smart RTL Patcher & Service Fixer
.DESCRIPTION
    Injects smart RTL support into Claude Desktop without breaking English/Code.
    Handles ASAR repackaging, executable hash patching, and cowork-svc binary certificate swapping.
    Strictly uses PURE BYTE-ARRAY manipulation matching the original Python script.
#>

# -----------------------------------------------------------------------------
# AUTO-ELEVATION: Request Administrator Privileges Automatically
# Supports both file execution and irm|iex piped execution
# -----------------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    $ScriptPath = $MyInvocation.MyCommand.Path
    if ($ScriptPath) {
        # Running as a .ps1 file — re-launch that file as admin
        Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    } else {
        # Running via irm|iex — download to temp file, then re-launch as admin
        $TmpScript = Join-Path $env:TEMP "claude_rtl_patch.ps1"
        $RepoUrl = "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main/patch.ps1"
        Write-Host "Downloading script to temp file for elevation..." -ForegroundColor Cyan
        Invoke-RestMethod -Uri $RepoUrl -OutFile $TmpScript
        Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$TmpScript`""
    }
    Exit
}

# -----------------------------------------------------------------------------
# GLOBAL SETTINGS & RTL JS PAYLOAD
# -----------------------------------------------------------------------------
$ErrorActionPreference = "Stop"
$global:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude_rtl_patch_tmp"

# Exact JS logic from r.js
$RTL_INJECTION_CODE = @'
// --- CLAUDE RTL PATCH START ---
;(function() {
    'use strict';
    if (typeof document === 'undefined') return;
    try {
        var WRITING_SEL = '[data-testid="chat-input"]';

        function isRTL(c) {
            var code = c.charCodeAt(0);
            return (code >= 0x0590 && code <= 0x05FF) ||
                   (code >= 0x0600 && code <= 0x06FF) ||
                   (code >= 0x0750 && code <= 0x077F) ||
                   (code >= 0x08A0 && code <= 0x08FF);
        }

        function hasRTL(text) {
            if (!text) return false;
            for (var i = 0; i < text.length; i++) { if (isRTL(text[i])) return true; }
            return false;
        }

        // First strong character direction in a string
        function firstStrong(text) {
            if (!text) return null;
            for (var i = 0; i < text.length; i++) {
                if (isRTL(text[i])) return 'rtl';
                if (/[a-zA-Z]/.test(text[i])) return 'ltr';
            }
            return null;
        }

        // Get text from element excluding <code> children (DOM-aware)
        function textWithoutCode(el) {
            var out = '';
            var nodes = el.childNodes;
            for (var i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                if (n.nodeType === 3) { out += n.textContent; }
                else if (n.nodeType === 1 && n.tagName !== 'CODE' && n.tagName !== 'PRE') {
                    out += textWithoutCode(n);
                }
            }
            return out;
        }

        // Strip leading LTR-only patterns from plain text
        // Removes: filenames (x.js), URLs, paths (a/b/c), backtick-code
        function stripLeadingLTR(text) {
            return text
                .replace(/^[\s]*(?:[\w.\-]+\.[\w]{1,5})\s*/g, '')
                .replace(/https?:\/\/\S+/g, '')
                .replace(/[\w.\-]+[\/\\][\w.\-\/\\]+/g, '')
                .replace(/`[^`]+`/g, '');
        }

        // --- HYBRID DIRECTION DETECTION ---

        // For DOM elements (output): 3-layer detection
        function detectElDir(el) {
            var full = el.textContent || '';
            if (!hasRTL(full)) return null;

            // Layer 1: first-strong on text excluding <code> children
            var noCode = textWithoutCode(el);
            var d = firstStrong(noCode);
            if (d === 'rtl') return 'rtl';

            // Layer 2: strip leading filenames/URLs, then first-strong
            var stripped = stripLeadingLTR(noCode);
            d = firstStrong(stripped);
            if (d === 'rtl') return 'rtl';

            // Layer 3: there ARE RTL chars (we checked above) but they hide
            // behind code/filenames. Since RTL exists, treat as RTL.
            return 'rtl';
        }

        // For plain text (input box, dialogs without DOM structure)
        function detectTextDir(text) {
            if (!text || !text.trim()) return null;
            var d = firstStrong(text);
            if (d === 'rtl') return 'rtl';
            if (!hasRTL(text)) return 'ltr';

            // Has RTL but first-strong is LTR — strip patterns and retry
            var stripped = stripLeadingLTR(text);
            d = firstStrong(stripped);
            if (d === 'rtl') return 'rtl';

            // RTL chars exist somewhere → RTL
            return 'rtl';
        }

        // --- ELEMENT PROCESSING ---

        // querySelectorAll that INCLUDES root itself if it matches
        function qsa(root, sel) {
            var base = root.querySelectorAll ? root : document;
            var els = Array.from(base.querySelectorAll(sel));
            if (root.matches && root.matches(sel)) els.unshift(root);
            return els;
        }

        function forceCodeLTR(root) {
            qsa(root, 'pre, .code-block__code, .relative.group\\/copy').forEach(function(b) {
                b.dir = 'ltr'; b.style.textAlign = 'left'; b.style.unicodeBidi = 'embed';
            });
            qsa(root, 'code').forEach(function(c) {
                if (!c.closest('pre') && !c.closest('.code-block__code')) c.dir = 'ltr';
            });
        }

        function processText(root) {
            // Standard text elements
            qsa(root, 'p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd').forEach(function(el) {
                if (el.closest(WRITING_SEL) || el.closest('pre') || el.closest('.code-block__code')) return;
                var dir = detectElDir(el);
                if (dir) {
                    el.dir = dir;
                    el.style.direction = dir;
                    if (el.tagName === 'LI') {
                        el.style.listStylePosition = (dir === 'rtl') ? 'inside' : '';
                        // Propagate RTL to parent list immediately to fix bullet position
                        var parentList = el.closest('ul, ol');
                        if (parentList && dir === 'rtl' && !parentList.hasAttribute('dir')) {
                            parentList.dir = 'rtl';
                            parentList.style.direction = 'rtl';
                            var pl = getComputedStyle(parentList).paddingLeft;
                            if (parseFloat(pl) > 0) { parentList.style.paddingRight = pl; parentList.style.paddingLeft = '0'; }
                        }
                    }
                } else {
                    if (el.hasAttribute('dir')) el.removeAttribute('dir');
                    el.style.direction = '';
                    if (el.tagName === 'LI') el.style.listStylePosition = '';
                }
            });

            // Lists
            qsa(root, 'ul, ol').forEach(function(el) {
                if (el.closest(WRITING_SEL) || el.closest('pre')) return;
                var dir = detectElDir(el);
                if (dir === 'rtl') {
                    el.dir = 'rtl';
                    el.style.direction = 'rtl';
                    var pl = getComputedStyle(el).paddingLeft;
                    if (parseFloat(pl) > 0) { el.style.paddingRight = pl; el.style.paddingLeft = '0'; }
                } else {
                    if (el.hasAttribute('dir')) el.removeAttribute('dir');
                    el.style.direction = '';
                    el.style.paddingRight = ''; el.style.paddingLeft = '';
                }
            });
        }

        // Universal: process ANY leaf text container (catches dialogs, tooltips, etc.)
        function processContainers(root) {
            qsa(root, 'div, span, button, a, label').forEach(function(el) {
                if (el.closest('pre') || el.closest('code') || el.closest(WRITING_SEL)) return;
                // Skip if has block children (not a leaf)
                if (el.querySelector('p, div, ul, ol, h1, h2, h3, h4, h5, h6, pre, table')) return;
                // Skip elements already handled by processText
                if (/^(P|LI|H[1-6]|BLOCKQUOTE|TD|TH|UL|OL)$/.test(el.tagName)) return;
                var text = (el.textContent || '').trim();
                if (text.length < 2) return;
                if (hasRTL(text)) {
                    el.dir = detectTextDir(text) || 'rtl';
                    el.style.textAlign = 'start';
                } else if (el.hasAttribute('dir')) {
                    el.removeAttribute('dir');
                    el.style.textAlign = '';
                }
            });
        }

        function processInput() {
            document.querySelectorAll(WRITING_SEL).forEach(function(input) {
                var text = input.textContent || input.innerText || '';
                var dir = detectTextDir(text);
                if (dir === 'rtl') {
                    input.style.direction = 'rtl'; input.style.textAlign = 'right'; input.style.paddingRight = '25px';
                } else {
                    input.style.direction = 'ltr'; input.style.textAlign = 'left'; input.style.paddingRight = '';
                }
            });
        }

        function processAll() {
            processText(document);
            processContainers(document.body);
            processInput();
            forceCodeLTR(document.body);
        }

        function injectStyles() {
            if (document.getElementById('claude-rtl-styles')) return;
            var s = document.createElement('style');
            s.id = 'claude-rtl-styles';
            s.textContent = [
                'p:not([dir]),li:not([dir]),h1:not([dir]),h2:not([dir]),h3:not([dir]),h4:not([dir]),h5:not([dir]),h6:not([dir]),blockquote:not([dir]),td:not([dir]),th:not([dir]),summary:not([dir]),label:not([dir]),legend:not([dir]),dt:not([dir]),dd:not([dir]),figcaption:not([dir]),caption:not([dir]){unicode-bidi:plaintext!important;text-align:start!important}',
                'pre,.code-block__code,.relative.group\\/copy{unicode-bidi:embed!important;direction:ltr!important;text-align:left!important}',
                'code{unicode-bidi:isolate!important;direction:ltr!important}',
                '[dir]{text-align:start!important}[dir="rtl"]{direction:rtl!important}[dir="ltr"]{direction:ltr!important}',
                '[dir]>*:not([dir]):not(pre):not(code):not(.code-block__code){unicode-bidi:plaintext;text-align:start}'
            ].join('');
            document.head.appendChild(s);
        }

        function init() {
            injectStyles();
            processAll();

            // Input box live direction switching
            document.addEventListener('input', function(e) {
                var t = e.target;
                if (!t || !(t.tagName === 'TEXTAREA' || t.tagName === 'INPUT' || t.isContentEditable)) return;
                var text = t.textContent || t.innerText || t.value || '';
                var dir = detectTextDir(text);
                if (dir === 'rtl') {
                    t.style.direction = 'rtl'; t.style.textAlign = 'right'; t.style.paddingRight = '25px';
                } else {
                    t.style.direction = 'ltr'; t.style.textAlign = 'left'; t.style.paddingRight = '';
                }
            }, true);

            // Watch DOM changes (throttle, not debounce — process DURING streaming)
            var pendingMuts = [];
            var obs = new MutationObserver(function(muts) {
                var dominated = false;
                for (var i = 0; i < muts.length; i++) {
                    if (muts[i].addedNodes.length > 0 || muts[i].type === 'characterData') { dominated = true; break; }
                }
                if (!dominated) return;
                for (var j = 0; j < muts.length; j++) pendingMuts.push(muts[j]);
                if (window._rtlT) return; // throttle: already scheduled
                window._rtlT = setTimeout(function() {
                    window._rtlT = null;
                    var toProcess = pendingMuts;
                    pendingMuts = [];
                    var roots = new Set();
                    toProcess.forEach(function(m) {
                        m.addedNodes.forEach(function(n) { if (n.nodeType === 1) roots.add(n); });
                        if (m.type === 'characterData' && m.target.parentElement) roots.add(m.target.parentElement);
                    });
                    // Expand roots to include ancestor text/list elements
                    var expanded = new Set(roots);
                    roots.forEach(function(r) {
                        if (!r.closest) return;
                        var txt = r.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd');
                        if (txt) expanded.add(txt);
                        var list = r.closest('ul, ol');
                        if (list) expanded.add(list);
                    });
                    roots = expanded;
                    if (roots.size > 0 && roots.size <= 30) {
                        roots.forEach(function(r) {
                            processText(r);
                            processContainers(r);
                            forceCodeLTR(r);
                        });
                        processInput();
                    } else {
                        processAll();
                    }
                }, 50);
            });
            obs.observe(document.body, { childList: true, subtree: true, characterData: true });
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else { init(); }
    } catch(e) { console.error('[Claude RTL]', e); }
})();
// --- CLAUDE RTL PATCH END ---
'@

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------
function Write-Log($msg)     { Write-Host "  [*] $msg" -ForegroundColor Cyan }
function Write-Step($msg)    { Write-Host "`n► $msg" -ForegroundColor Magenta }
function Write-Success($msg) { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn($msg)    { Write-Host "  [!] $msg" -ForegroundColor Yellow }

# Pure Binary Search equivalent to Python's bytearray.find()
function Find-Bytes([byte[]]$Haystack, [byte[]]$Needle, [int]$StartIndex = 0) {
    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) { return -1 }
    for ($i = $StartIndex; $i -le ($Haystack.Length - $Needle.Length); $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $match = $false
                break
            }
        }
        if ($match) { return $i }
    }
    return -1
}

function Find-ClaudeDir {
    $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*' } | Select-Object -First 1
    if ($pkg) { return $pkg.InstallLocation }
    return $null
}

function Find-ClaudeApp {
	# Try at WindowsApps
	$pkg = Find-ClaudeDir
    if ($pkg) {
		$AppDir = Join-Path $pkg "app"
		if ($AppDir) { return $AppDir }
	}
	# Try at installed softwares
	$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $pkg = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue | 
                 Where-Object { $_.DisplayName -match "Claude" -and $_.InstallLocation } | 
                 Select-Object -First 1
	if ($pkg) {
		$activeVersion = $pkg.DisplayVersion
		# Get the directory with current version .exe file
		$claudeExe = Get-ChildItem -Path $pkg.InstallLocation -Filter "claude.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue | 
					 Where-Object { 
						(Test-Path (Join-Path $_.DirectoryName "resources\app.asar")) -and 
						($_.VersionInfo.FileVersion -like "*$activeVersion*" -or $_.VersionInfo.ProductVersion -like "*$activeVersion*")
					 } | Select-Object -First 1
		if ($claudeExe) { return $claudeExe.DirectoryName }
	}
    return $null
}


function Stop-ClaudeServices {
    Write-Step "Halting Claude processes and services..."
    
    # 1. Stop the Windows service via WMI
    $wmiSvc = Get-WmiObject Win32_Service | Where-Object { $_.PathName -match "cowork-svc" }
    if ($wmiSvc) {
        Write-Log "Stopping service: $($wmiSvc.Name) (State: $($wmiSvc.State))"
        Stop-Service -Name $wmiSvc.Name -Force -ErrorAction SilentlyContinue
        
        # Wait for service to actually stop
        $timeout = 10
        for ($w = 0; $w -lt $timeout; $w++) {
            $state = (Get-Service -Name $wmiSvc.Name -ErrorAction SilentlyContinue).Status
            if ($state -eq 'Stopped' -or -not $state) { break }
            Start-Sleep -Seconds 1
        }
        Write-Log "Service state after stop: $((Get-Service -Name $wmiSvc.Name -ErrorAction SilentlyContinue).Status)"
    } else {
        Write-Log "No cowork-svc Windows service found."
    }
    
    # 2. Kill any remaining processes
    foreach ($procName in @("claude", "cowork-svc")) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log "Killing $($procs.Count) '$procName' process(es)..."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    
    # 3. Wait and verify processes are gone
    Start-Sleep -Seconds 2
    $remaining = Get-Process -Name "cowork-svc" -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Warn "cowork-svc still running after kill! Waiting 5 more seconds..."
        Start-Sleep -Seconds 5
        Stop-Process -Name "cowork-svc" -Force -ErrorAction SilentlyContinue
    }
    
    Write-Success "Processes and services halted."
}

function Test-FileLock([string]$Path) {
    <#
    .SYNOPSIS
        Returns $true if the file is locked by another process, $false if writable.
    #>
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

function Wait-FileUnlock([string]$Path, [int]$TimeoutSeconds = 20) {
    <#
    .SYNOPSIS
        Waits until a file is no longer locked, or throws after timeout.
    #>
    if (-not (Test-Path $Path)) { return }
    for ($w = 0; $w -lt $TimeoutSeconds; $w++) {
        if (-not (Test-FileLock $Path)) {
            Write-Log "File unlocked: $(Split-Path $Path -Leaf)"
            return
        }
        if ($w -eq 0) { Write-Log "Waiting for file lock release: $(Split-Path $Path -Leaf)..." }
        Start-Sleep -Seconds 1
    }
    throw "File '$(Split-Path $Path -Leaf)' is still locked after ${TimeoutSeconds}s. A process may still be using it. Try rebooting and running again."
}

function Start-ClaudeServices {
    Write-Step "Restarting Claude background service..."
    $Started = $false
    
    # 1. Make absolutely sure the service is stopped before starting
    #    (prevents it from running with old binary still in memory)
    $wmiSvc = Get-WmiObject Win32_Service | Where-Object { $_.PathName -match "cowork-svc" }
    if ($wmiSvc) {
        $svcName = $wmiSvc.Name
        $currentState = (Get-Service -Name $svcName -ErrorAction SilentlyContinue).Status
        
        if ($currentState -ne 'Stopped') {
            Write-Log "Service is '$currentState' - forcing stop before restart..."
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            $stopTimeout = 10
            for ($w = 0; $w -lt $stopTimeout; $w++) {
                if ((Get-Service -Name $svcName -ErrorAction SilentlyContinue).Status -eq 'Stopped') { break }
                Start-Sleep -Seconds 1
            }
        }
        
        # Also kill any lingering process to guarantee the new binary loads fresh
        Stop-Process -Name "cowork-svc" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        # Now start
        Write-Log "Starting service: $svcName"
        Try {
            Start-Service -Name $svcName -ErrorAction Stop
            
            # Wait up to 15 seconds for Running state
            $timeout = 15
            for ($w = 0; $w -lt $timeout; $w++) {
                $status = (Get-Service -Name $svcName).Status
                if ($status -eq 'Running') {
                    $Started = $true
                    break
                }
                Start-Sleep -Seconds 1
            }
            if ($Started) {
                Write-Success "Service '$svcName' is running (fresh binary loaded)."
            } else {
                Write-Warn "Service '$svcName' state: $status after ${timeout}s."
            }
        } Catch {
            Write-Warn "Could not start service: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "cowork-svc service not found via WMI."
    }

    # 2. Launch Claude Desktop UI
    Write-Log "Launching Claude Desktop..."
    Try {
        $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' } | Select-Object -First 1
        if ($pkg) {
            $appId = "$($pkg.PackageFamilyName)!Claude"
            Start-Process "shell:AppsFolder\$appId" -ErrorAction Stop
            Write-Success "Claude Desktop launched."
        } else {
            Write-Warn "Claude AppxPackage not found for launch."
        }
    } Catch {
        Write-Warn "Could not launch Claude Desktop: $($_.Exception.Message)"
        Write-Log "Please start Claude manually from the Start Menu."
    }
}

function Take-Ownership($Path) {
    Write-Log "Requesting permissions for: $Path"
    cmd.exe /c "takeown /F `"$Path`" /R /D Y >nul 2>&1"
    cmd.exe /c "icacls `"$Path`" /grant Administrators:F /T /Q >nul 2>&1"
}

function Compute-AsarHash($AsarPath) {
    $fs = [System.IO.File]::OpenRead($AsarPath)
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Seek(12, [System.IO.SeekOrigin]::Begin) | Out-Null
    $jsonSize = $br.ReadUInt32()
    if ($jsonSize -le 0 -or $jsonSize -gt 10485760) {
        $fs.Close()
        throw "Abnormal ASAR header size: $jsonSize"
    }
    $jsonBytes = $br.ReadBytes($jsonSize)
    $fs.Close()

    $jsonStr = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($jsonStr))
    $hashStr = [BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
    return $hashStr
}

# -----------------------------------------------------------------------------
# CORE PATCHING LOGIC (WITH ATOMIC FALLBACK)
# -----------------------------------------------------------------------------
function Install-Patch {
    Write-Host "`n=======================================================" -ForegroundColor Cyan
    Write-Host "     INSTALLING CLAUDE SMART RTL PATCH" -ForegroundColor Cyan
    Write-Host "=======================================================`n" -ForegroundColor Cyan

	$AppDir = Find-ClaudeApp
	if (-not $AppDir) { throw "Claude installation not found on this system." }
    Write-Success "Found Claude app at: $AppDir"
	
    $ResourcesDir = Join-Path $AppDir "resources"
    $AsarPath = Join-Path $ResourcesDir "app.asar"
    $ExePath = Join-Path $AppDir "claude.exe"
    $CoworkSvcPath = Join-Path $ResourcesDir "cowork-svc.exe"

    if (-not (Test-Path $AsarPath)) { throw "app.asar not found!" }

    Try {
        $cmdOut = cmd.exe /c "npx --yes asar --version 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "ASAR missing" }
    } Catch {
        throw "Node.js (npx) is required. Please install Node.js."
    }

    Stop-ClaudeServices
    
    Write-Step "Taking ownership of Claude directories..."
    Take-Ownership $AppDir
    Take-Ownership $ResourcesDir

    Write-Step "Creating secure backups..."
    if (-not (Test-Path "$AsarPath.bak")) { Copy-Item $AsarPath "$AsarPath.bak" -Force; Write-Success "app.asar.bak created" }
    if (-not (Test-Path "$ExePath.bak") -and (Test-Path $ExePath)) { Copy-Item $ExePath "$ExePath.bak" -Force; Write-Success "claude.exe.bak created" }
    if (-not (Test-Path "$CoworkSvcPath.bak") -and (Test-Path $CoworkSvcPath)) { Copy-Item $CoworkSvcPath "$CoworkSvcPath.bak" -Force; Write-Success "cowork-svc.exe.bak created" }

    # Always restore from backup before patching — ensures clean state
    # First run: .bak was just created from same file → copy is a no-op (safe)
    # Re-run: restores original files → fresh install on clean files
    Write-Step "Ensuring clean state before patching..."
    foreach ($pair in @(
        @{O=$AsarPath;       B="$AsarPath.bak"},
        @{O=$ExePath;        B="$ExePath.bak"},
        @{O=$CoworkSvcPath;  B="$CoworkSvcPath.bak"}
    )) {
        if (Test-Path $pair.B) {
            Copy-Item $pair.B $pair.O -Force
            Write-Log "Restored $(Split-Path $pair.O -Leaf) from backup"
        }
    }

    # ==========================================
    # START ATOMIC TRANSACTION (TRY/CATCH)
    # ==========================================
    Try {
        Write-Step "Phase 1: ASAR Injection"
        $OldHash = Compute-AsarHash $AsarPath
        Write-Log "Original Hash: $OldHash"

        if (Test-Path $global:TmpDir) { Remove-Item $global:TmpDir -Recurse -Force }
        Write-Log "Extracting ASAR archive (this may take a moment)..."
        cmd.exe /c "npx --yes asar extract `"$AsarPath`" `"$global:TmpDir`""
        
        $BuildDir = Join-Path $global:TmpDir ".vite\build"
        if (Test-Path $BuildDir) {
            $JsFiles = Get-ChildItem -Path $BuildDir -Filter "*.js" -Recurse
            $Injected = 0
            foreach ($file in $JsFiles) {
                $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
                if ($content -match "CLAUDE RTL PATCH START") { continue }

                $newContent = $RTL_INJECTION_CODE + "`n" + $content
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($file.FullName, $newContent, $utf8NoBom)
                $Injected++
                Write-Log "Injected RTL into: $($file.Name)"
            }
            if ($Injected -gt 0) { Write-Success "Injected RTL JS logic into $Injected file(s)." }
            else { Write-Warn "JS files already patched or not found." }
        }

        $TmpAsarPath = "$AsarPath.new"
        Write-Log "Repacking ASAR archive..."
        cmd.exe /c "npx --yes asar pack `"$global:TmpDir`" `"$TmpAsarPath`""
        
        $NewHash = Compute-AsarHash $TmpAsarPath
        Write-Log "New Hash: $NewHash"
        Move-Item -Path $TmpAsarPath -Destination $AsarPath -Force

        Write-Step "Phase 2 & 3: Executable Patching & Cert Synchronization"
        if ((Test-Path $ExePath) -and (Test-Path $CoworkSvcPath)) {
            
            # 1. READ FROM BAK FILES FOR IDEMPOTENCY
            $SourceSvc = if (Test-Path "$CoworkSvcPath.bak") { "$CoworkSvcPath.bak" } else { $CoworkSvcPath }
            $SourceExe = if (Test-Path "$ExePath.bak") { "$ExePath.bak" } else { $ExePath }

            # EXACT PYTHON LOGIC: PURE BYTE ARRAY SEARCH
            $SvcBytes = [System.IO.File]::ReadAllBytes($SourceSvc)
            $AnchorBytes = [System.Text.Encoding]::ASCII.GetBytes("Anthropic, PBC")
            
            $StartPos = -1
            $OldCertSize = 0
            $Offset = 0

            while ($true) {
                $AnchorPos = Find-Bytes -Haystack $SvcBytes -Needle $AnchorBytes -StartIndex $Offset
                if ($AnchorPos -eq -1) { break }

                $Limit = [Math]::Max(0, $AnchorPos - 2000)
                for ($i = $AnchorPos; $i -ge $Limit; $i--) {
                    if ($SvcBytes[$i] -eq 0x30 -and $SvcBytes[$i+1] -eq 0x82) {
                        $TotalSize = 4 + (([int]$SvcBytes[$i+2] -shl 8) -bor [int]$SvcBytes[$i+3])
                        if ($TotalSize -gt 500 -and $TotalSize -lt 4000 -and $i -lt $AnchorPos -and ($i + $TotalSize) -gt $AnchorPos) {
                            $StartPos = $i
                            $OldCertSize = $TotalSize
                            break
                        }
                    }
                }
                if ($StartPos -ne -1) { break }
                $Offset = $AnchorPos + 1
            }

            if ($StartPos -eq -1) {
                throw "Anthropic certificate pattern not found in cowork-svc.exe. Binary patch aborted."
            }

            Write-Log "Target cowork-svc hole found at $([Convert]::ToString($StartPos, 16)) (Size: $OldCertSize bytes)."

            # 2. EXTRACT ORIGINAL SUBJECT FOR STEALTH
            $OriginalSig = Get-AuthenticodeSignature -FilePath $SourceExe
            $CertSubject = "CN=Claude-RTL-Patcher"
            if ($OriginalSig -and $OriginalSig.SignerCertificate) {
                $CertSubject = $OriginalSig.SignerCertificate.Subject
                Write-Log "Cloning original certificate subject: $CertSubject"
            }

            # 3. DYNAMIC CERTIFICATE GENERATION LOOP
            $ValidCertFound = $false
            $Attempts = 1
            $MaxAttempts = 10
            $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
            $Store.Open("ReadWrite")
            
            $Cert = $null
            $NewCertBytes = $null

            while (-not $ValidCertFound -and $Attempts -le $MaxAttempts) {
                Write-Log "Generating self-signed certificate (Attempt $Attempts)..."
                $Cert = New-SelfSignedCertificate -Subject $CertSubject -Type CodeSigningCert -CertStoreLocation "Cert:\LocalMachine\My" -FriendlyName "Claude_RTL_SelfSigned" -KeyAlgorithm RSA -KeyLength 2048
                
                $NewCertBytes = $Cert.RawData
                
                if ($NewCertBytes.Length -le $OldCertSize) {
                    $Store.Add($Cert)
                    $ValidCertFound = $true
                    Write-Success "Generated certificate fits! (Size: $($NewCertBytes.Length) bytes, Hole: $OldCertSize bytes)"
                } else {
                    Write-Warn "Certificate too large ($($NewCertBytes.Length) bytes). Removing and retrying..."
                    Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $Cert.Thumbprint } | Remove-Item -ErrorAction SilentlyContinue
                    $Attempts++
                }
            }
            $Store.Close()

            if (-not $ValidCertFound) {
                throw "Failed to generate a suitably sized certificate after $MaxAttempts attempts."
            }

            # 4. SWAP ALL HASHES IN CLAUDE.EXE (PURE BYTE SEARCH LIKE r.js)
            Wait-FileUnlock $ExePath
            $ExeBytes = [System.IO.File]::ReadAllBytes($SourceExe)
            $OldHashBytes = [System.Text.Encoding]::ASCII.GetBytes($OldHash)
            $NewHashBytes = [System.Text.Encoding]::ASCII.GetBytes($NewHash)
            
            $OffsetExe = 0
            $Replacements = 0

            while ($true) {
                $Idx = Find-Bytes -Haystack $ExeBytes -Needle $OldHashBytes -StartIndex $OffsetExe
                if ($Idx -eq -1) { break }
                
                [Array]::Copy($NewHashBytes, 0, $ExeBytes, $Idx, $NewHashBytes.Length)
                $OffsetExe = $Idx + $OldHashBytes.Length
                $Replacements++
            }

            if ($Replacements -gt 0) {
                [System.IO.File]::WriteAllBytes($ExePath, $ExeBytes)
                Write-Success "Replaced $Replacements ASAR hash(es) in claude.exe"
            } else {
                Write-Warn "Old hash not found in claude.exe. Skipping hash replacement."
            }

            $SignResult = Set-AuthenticodeSignature -FilePath $ExePath -Certificate $Cert -HashAlgorithm SHA256
            if ($SignResult.Status -eq 'Valid') { Write-Success "Successfully re-signed claude.exe" }
            else { throw "Re-signing claude.exe failed: $($SignResult.Status)" }

            # 5. EXACT PADDING AND BINARY SWAP IN COWORK-SVC.EXE
            Wait-FileUnlock $CoworkSvcPath
            $Diff = $OldCertSize - $NewCertBytes.Length
            Write-Log "Swapping cowork-svc cert and padding with $Diff bytes of 0x00..."
            
            $PaddedCert = New-Object byte[] $OldCertSize
            [Array]::Copy($NewCertBytes, 0, $PaddedCert, 0, $NewCertBytes.Length)
            
            [Array]::Copy($PaddedCert, 0, $SvcBytes, $StartPos, $OldCertSize)
            [System.IO.File]::WriteAllBytes($CoworkSvcPath, $SvcBytes)
            Write-Success "Binary cert replacement completed in cowork-svc.exe"

            # 6. SIGN COWORK-SVC.EXE
            $SignResult2 = Set-AuthenticodeSignature -FilePath $CoworkSvcPath -Certificate $Cert -HashAlgorithm SHA256
            if ($SignResult2.Status -eq 'Valid') { Write-Success "Successfully re-signed cowork-svc.exe" }
            else { throw "Re-signing cowork-svc.exe failed: $($SignResult2.Status)" }

        } else {
            Write-Warn "claude.exe or cowork-svc.exe not found. Binary patching skipped."
        }

        Write-Step "Cleanup & Launch"
        if (Test-Path $global:TmpDir) { Remove-Item $global:TmpDir -Recurse -Force }
        Start-ClaudeServices
        
        Write-Host "`n=======================================================" -ForegroundColor Green
        Write-Host " PATCH INSTALLATION COMPLETED SUCCESSFULLY! ENJOY!" -ForegroundColor Green
        Write-Host "=======================================================`n" -ForegroundColor Green

    } Catch {
        # ==========================================
        # FALLBACK / ROLLBACK MECHANISM
        # ==========================================
        $ErrorMessage = $_.Exception.Message
        Write-Host "`n[X] CRITICAL ERROR DETECTED DURING PATCHING!" -ForegroundColor Red
        Write-Host "    Reason: $ErrorMessage" -ForegroundColor Red
        Write-Host "    INITIATING AUTOMATIC ROLLBACK TO PREVENT CORRUPTION..." -ForegroundColor Yellow
        
        Restore-Patch -IsRollback
        
        throw "Installation failed, but your system was safely restored to its original state."
    }
}

function Restore-Patch {
    param([switch]$IsRollback)

    if (-not $IsRollback) {
        Write-Host "`n=======================================================" -ForegroundColor Cyan
        Write-Host "     RESTORING CLAUDE TO ORIGINAL STATE" -ForegroundColor Cyan
        Write-Host "=======================================================`n" -ForegroundColor Cyan
    } else {
        Write-Step "Executing Fallback Rollback..."
    }

    $AppDir = Find-ClaudeApp
	if (-not $AppDir) { 
        if ($IsRollback) { Write-Warn "Claude App Dir not found during rollback." }
        else { throw "Claude installation not found on this system." }
        return
    }
    $ResourcesDir = Join-Path $AppDir "resources"
    
    Stop-ClaudeServices
    Take-Ownership $AppDir
    Take-Ownership $ResourcesDir

    Write-Log "Restoring original files from backup..."
    $Restored = $false
    
    $FilesToRestore = @(
        @{"Orig" = Join-Path $ResourcesDir "app.asar"; "Bak" = Join-Path $ResourcesDir "app.asar.bak"},
        @{"Orig" = Join-Path $AppDir "claude.exe"; "Bak" = Join-Path $AppDir "claude.exe.bak"},
        @{"Orig" = Join-Path $ResourcesDir "cowork-svc.exe"; "Bak" = Join-Path $ResourcesDir "cowork-svc.exe.bak"}
    )

    foreach ($Item in $FilesToRestore) {
        if (Test-Path $Item["Bak"]) {
            Try {
                Copy-Item $Item["Bak"] $Item["Orig"] -Force -ErrorAction Stop
                Write-Success "Restored $(Split-Path $Item['Orig'] -Leaf)"
                $Restored = $true
            } Catch {
                Write-Warn "Failed to copy $(Split-Path $Item['Orig'] -Leaf) back: $($_.Exception.Message)"
            }
        } else {
            Write-Warn "Backup for $(Split-Path $Item['Orig'] -Leaf) not found."
        }
    }

    Write-Log "Cleaning up custom certificates..."
    Try {
        Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'Claude_RTL_SelfSigned' } | Remove-Item -ErrorAction SilentlyContinue
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.FriendlyName -eq 'Claude_RTL_SelfSigned' } | Remove-Item -ErrorAction SilentlyContinue
        Write-Success "Custom certificates removed from system store."
    } Catch {
        Write-Warn "Failed to remove some certificates."
    }

    Start-ClaudeServices

    if ($IsRollback) {
        Write-Host "`n[V] ROLLBACK COMPLETED SUCCESSFULLY." -ForegroundColor Green
    } else {
        if ($Restored) { Write-Success "Restore process completed. Claude is back to original." }
        else { Write-Warn "Restore process finished, but no backups were found." }
    }
}

# -----------------------------------------------------------------------------
# MAIN MENU LOOP
# -----------------------------------------------------------------------------
function Show-Menu {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║    Claude Desktop Smart RTL & Service Patcher    ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "`nSelect an action:"
    Write-Host "  1. Install Smart RTL Patch (Full Hebrew Support)" -ForegroundColor White
    Write-Host "  2. Restore Original State (Remove Patch)" -ForegroundColor White
    Write-Host "  3. Exit" -ForegroundColor White

    $choice = Read-Host "`nEnter your choice (1/2/3)"
    
    if ($choice -eq '1' -or $choice -eq '2') {
        Write-Host "`nWARNING: This will automatically close Claude Desktop and its background services." -ForegroundColor Yellow
        $confirm = Read-Host "Do you want to continue? (Y/n)"
        if ($confirm -eq 'n' -or $confirm -eq 'N') {
            Write-Host "Operation cancelled."
            Start-Sleep -Seconds 2
            Show-Menu
            return
        }

        try {
            if ($choice -eq '1') { Install-Patch }
            else { Restore-Patch }
        } catch {
            Write-Host "`n[!] Final Script Status:" -ForegroundColor DarkGray
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        Write-Host "`nPress Enter to exit..."
        $null = Read-Host
    }
    elseif ($choice -eq '3') { Exit }
    else { Show-Menu }
}

# Start the application
Show-Menu
