<#
.SYNOPSIS
    Claude Desktop Smart RTL Patcher & Service Fixer
.DESCRIPTION
    Injects smart RTL support into Claude Desktop without breaking English/Code.
    Handles ASAR repackaging, executable hash patching, and cowork-svc binary certificate swapping.
    Strictly uses PURE BYTE-ARRAY manipulation matching the original Python script.
#>
param(
    [switch]$Auto
)

# Env-var fallback for `irm | iex` invocations where param binding is not possible.
if (-not $Auto -and $env:CLAUDE_RTL_AUTO -eq '1') { $Auto = $true }

# -----------------------------------------------------------------------------
# AUTO-ELEVATION: Request Administrator Privileges Automatically
# Supports both file execution and irm|iex piped execution
# -----------------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    $autoArg = if ($Auto) { ' -Auto' } else { '' }
    # SECURITY: When the user is running a real local file (the audited copy on
    # disk), re-launch THAT file under elevation. Do NOT re-download from GitHub
    # post-UAC — that would silently swap the audited script for a fresh remote
    # copy and turn elevation into an unattended remote-code-execution path.
    # The download fallback is reserved for the `irm | iex` flow, where there
    # is no $PSCommandPath to relaunch.
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        Write-Host "Elevating local script: $PSCommandPath" -ForegroundColor Cyan
        Write-Host "  source: local file" -ForegroundColor DarkGray
        Start-Process -FilePath PowerShell.exe -Verb RunAs `
            -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`"$autoArg"
    } else {
        # $PSCommandPath is null — script was piped (irm|iex) rather than run from a file.
        # This patcher no longer supports unattended remote-code-execution via irm|iex.
        # All flows must originate from a saved local file so the user can audit what
        # runs under elevated privileges.
        Write-Host ""
        Write-Host "ERROR: Cannot elevate — patch.ps1 must be run from a saved local file." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Download a release archive from:" -ForegroundColor Yellow
        Write-Host "    https://github.com/shraga100/claude-desktop-rtl-patch/releases" -ForegroundColor Cyan
        Write-Host "  Extract it, then run: .\install.ps1" -ForegroundColor Yellow
        Write-Host "  Or run patch.ps1 directly from the extracted folder." -ForegroundColor Yellow
        Write-Host ""
        Exit 1
    }
    Exit
}

# -----------------------------------------------------------------------------
# GLOBAL SETTINGS & RTL JS PAYLOAD
# -----------------------------------------------------------------------------
$ErrorActionPreference = "Stop"
Import-Module Microsoft.PowerShell.Security -ErrorAction SilentlyContinue
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
// --- CLAUDE WCO FIX START ---
;(function() {
    'use strict';
    try {
        if (typeof navigator === 'undefined' || typeof document === 'undefined') return;
        // Feature-detect + locale fallback. If the WCO API isn't available and the
        // OS locale is LTR, this whole block becomes a silent no-op.
        var wco = ('windowControlsOverlay' in navigator) ? navigator.windowControlsOverlay : null;
        var locale = ((navigator.language || '') + ',' + (navigator.languages || []).join(',')).toLowerCase();
        var LOCALE_IS_RTL = /\b(he|iw|ar|fa|ur|yi|ps|sd)\b/.test(locale);
        var FALLBACK_PAD_PX = 140; // Default Windows titleBarOverlay width at 100% DPI
        if (!wco && !LOCALE_IS_RTL) {
            window.__claudeWCOState = { source: 'none', reason: 'no-api-and-ltr-locale', locale: locale };
            return;
        }

        var STYLE_ID = 'claude-wco-fix';
        var TARGET_ATTR = 'data-claude-wco-target';
        var retryCount = 0;
        var MAX_RETRIES = 20; // ~10 seconds total at 500ms interval

        function removeAll() {
            var style = document.getElementById(STYLE_ID);
            if (style) style.remove();
            var marked = document.querySelectorAll('[' + TARGET_ATTR + ']');
            for (var i = 0; i < marked.length; i++) {
                marked[i].removeAttribute(TARGET_ATTR);
            }
        }

        // The title bar is the element Electron marks as the OS drag region.
        // In Claude Desktop it's always the element with class `draggable` (as
        // opposed to `draggable-none`, which marks non-drag subregions).
        // Padding on this overlay moves only the title-bar buttons, not the
        // app body — which is exactly what we want.
        function findTopBar() {
            return document.querySelector('.draggable:not(.draggable-none)');
        }

        function applyFix() {
            try {
                var rect = (wco && typeof wco.getTitlebarAreaRect === 'function')
                    ? wco.getTitlebarAreaRect() : null;

                var padStart = 0;
                var source = 'none';
                var height = 0;

                if (wco && wco.visible && rect && rect.width !== 0 && rect.x > 0) {
                    padStart = Math.round(rect.x);
                    height = Math.round(rect.height) || 40;
                    source = 'wco-api';
                } else if (LOCALE_IS_RTL) {
                    // Fallback: WCO API unavailable or not reporting left-side controls,
                    // but the OS locale is RTL — apply a conservative default padding.
                    padStart = FALLBACK_PAD_PX;
                    height = 40;
                    source = 'locale-fallback';
                } else {
                    // True no-op case: LTR locale and either no API or overlay on right.
                    window.__claudeWCOState = { source: 'none', reason: 'ltr-or-right-controls', rect: rect, locale: locale };
                    removeAll();
                    return true;
                }

                window.__claudeWCOState = { source: source, padStart: padStart, rect: rect, locale: locale, visible: wco ? wco.visible : null };

                var topBar = findTopBar();
                if (!topBar) return false; // Signal caller to retry later

                // Clear stale markers (previous target may have unmounted), mark fresh one.
                var prevMarked = document.querySelectorAll('[' + TARGET_ATTR + ']');
                for (var i = 0; i < prevMarked.length; i++) {
                    if (prevMarked[i] !== topBar) prevMarked[i].removeAttribute(TARGET_ATTR);
                }
                topBar.setAttribute(TARGET_ATTR, 'true');

                var style = document.getElementById(STYLE_ID);
                if (!style) {
                    style = document.createElement('style');
                    style.id = STYLE_ID;
                    document.head.appendChild(style);
                }
                // Single rule bound to our private attribute — zero collision risk
                // with any selector claude.ai might define.
                style.textContent =
                    '[' + TARGET_ATTR + ']{padding-inline-start:' + padStart +
                    'px!important;box-sizing:border-box!important}';
                return true;
            } catch(e) {
                console.error('[Claude WCO Fix]', e);
                return true; // Error → don't spam retries
            }
        }

        function scheduleAttempt() {
            var ok = applyFix();
            if (ok === false && retryCount++ < MAX_RETRIES) {
                setTimeout(scheduleAttempt, 500);
            }
        }

        function attach() {
            scheduleAttempt();

            // Chromium fires geometrychange on maximize/restore/DPI change.
            if (wco && typeof wco.addEventListener === 'function') {
                wco.addEventListener('geometrychange', function() {
                    retryCount = 0;
                    applyFix();
                });
            }
            // In locale-fallback mode we have no geometrychange event — listen
            // for window resize as a proxy. Cheap, fires rarely.
            if (!wco && LOCALE_IS_RTL) {
                window.addEventListener('resize', function() {
                    retryCount = 0;
                    applyFix();
                });
            }

            // React/SPA re-renders can unmount the top bar. Re-apply when that
            // happens. Debounced to 200ms; only actually re-runs if the marked
            // target is no longer in the DOM.
            var debounceTimer = null;
            var obs = new MutationObserver(function() {
                if (debounceTimer) return;
                debounceTimer = setTimeout(function() {
                    debounceTimer = null;
                    var marked = document.querySelector('[' + TARGET_ATTR + ']');
                    if (!marked || !document.body.contains(marked)) {
                        retryCount = 0;
                        applyFix();
                    }
                }, 200);
            });
            obs.observe(document.body, { childList: true, subtree: true });
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', attach);
        } else {
            attach();
        }
    } catch(e) { console.error('[Claude WCO Fix]', e); }
})();
// --- CLAUDE WCO FIX END ---

// --- CLAUDE PATCH WELCOME BANNER START ---
;(function() {
    'use strict';
    try {
        if (typeof document === 'undefined' || typeof localStorage === 'undefined') return;
        var FLAG_KEY = 'claude-rtl-patch-welcomed';
        // Tie the welcome banner to the Claude Desktop version reported in the UA
        // (e.g. "...Claude/1.3036.0 Chrome/..."). On every Claude release the
        // version changes, the saved flag stops matching, and the banner shows
        // once for the new version — no manual bump needed.
        var versionMatch = (navigator.userAgent || '').match(/Claude\/([\d.]+)/);
        var VERSION = versionMatch ? versionMatch[1] : '0';
        if (localStorage.getItem(FLAG_KEY) === VERSION) return;

        function show() {
            if (!document.body || document.getElementById('claude-rtl-welcome-banner')) return;
            var bar = document.createElement('div');
            bar.id = 'claude-rtl-welcome-banner';
            bar.dir = 'rtl';
            bar.style.cssText = [
                'position:fixed', 'top:12px', 'left:50%',
                'transform:translateX(-50%)',
                'z-index:2147483647',
                'background:#1f1f1f', 'color:#fff',
                'border:1px solid #3a3a3a', 'border-radius:10px',
                'padding:10px 14px', 'font:14px/1.4 system-ui,sans-serif',
                'box-shadow:0 6px 20px rgba(0,0,0,.4)',
                'display:flex', 'gap:12px', 'align-items:center',
                'max-width:560px'
            ].join(';');
            bar.innerHTML =
                '<span style="font-size:18px">\u2713</span>' +
                '<span style="flex:1">\u05d4\u05e4\u05d0\u05d8\u05e5\' \u05d4\u05d5\u05d7\u05dc \u05d1\u05d4\u05e6\u05dc\u05d7\u05d4 \u2014 \u05ea\u05de\u05d9\u05db\u05ea RTL \u05d5\u05ea\u05d9\u05e7\u05d5\u05df \u05db\u05e4\u05ea\u05d5\u05e8\u05d9 \u05d4\u05d7\u05dc\u05d5\u05df \u05e4\u05e2\u05d9\u05dc\u05d9\u05dd.</span>' +
                '<button id="claude-rtl-banner-close" style="background:transparent;color:#aaa;border:0;font-size:20px;cursor:pointer;padding:0 4px" aria-label="close">\u00d7</button>';
            document.body.appendChild(bar);

            document.getElementById('claude-rtl-banner-close').onclick = function() {
                localStorage.setItem(FLAG_KEY, VERSION);
                bar.remove();
            };
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', show);
        } else { show(); }
    } catch(e) { console.error('[Claude Welcome Banner]', e); }
})();
// --- CLAUDE PATCH WELCOME BANNER END ---
'@

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------
function Write-Log($msg)     { Write-Host "  [*] $msg" -ForegroundColor Cyan }
function Write-Step($msg)    { Write-Host "`n► $msg" -ForegroundColor Magenta }
function Write-Success($msg) { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn($msg)    { Write-Host "  [!] $msg" -ForegroundColor Yellow }

# Pure Binary Search equivalent to Python's bytearray.find()
# $PrecomputedHaystack: optional ISO-8859-1 string pre-computed from $Haystack by the
# caller. Pass this when calling Find-Bytes in a tight loop over the SAME byte array
# to avoid re-encoding the haystack on every iteration (significant for claude.exe ~100 MB).
function Find-Bytes([byte[]]$Haystack, [byte[]]$Needle, [int]$StartIndex = 0, [string]$PrecomputedHaystack = $null) {
    # Fast path: convert both arrays to ISO-8859-1 strings (1 byte <=> 1 char, lossless
    # for all 256 byte values) and delegate to String.IndexOf, which is implemented in
    # native code. This replaces a nested PowerShell byte-by-byte loop that was the
    # dominant silent period during patching (tens of MB x needle length in pure PS
    # could take ~30-60s on claude.exe).
    if ($Needle -eq $null -or $Needle.Length -eq 0 -or $Haystack -eq $null -or $Haystack.Length -lt $Needle.Length) { return -1 }
    if ($StartIndex -lt 0) { $StartIndex = 0 }
    if ($StartIndex -gt ($Haystack.Length - $Needle.Length)) { return -1 }
    $enc      = [System.Text.Encoding]::GetEncoding(28591)  # ISO-8859-1 / Latin-1, byte-preserving
    $hayStr   = if ($PrecomputedHaystack) { $PrecomputedHaystack } else { $enc.GetString($Haystack) }
    $needleStr = $enc.GetString($Needle)
    return $hayStr.IndexOf($needleStr, $StartIndex, [System.StringComparison]::Ordinal)
}

# -----------------------------------------------------------------------------
# AUTO-UPDATE STATE: shared with the watcher Scheduled Task
# -----------------------------------------------------------------------------
$global:RtlStateDir         = Join-Path $env:ProgramData "ClaudeRtlPatch"
$global:RtlStateFile        = Join-Path $global:RtlStateDir "state.json"
$global:RtlTaskName         = "ClaudeRtlPatchWatcher"
$global:RtlPatchScriptCache = Join-Path $global:RtlStateDir "patch.ps1"
$global:RtlAclBackup        = Join-Path $global:RtlStateDir "appdir-acl.txt"
$global:RtlCertSubject      = 'CN=Claude-RTL-Patcher (self-signed), O=Local'
$global:RtlCertFriendly     = 'Claude_RTL_SelfSigned'
# Pinned ASAR tool — avoids running an arbitrary "latest" npm package as Administrator.
# Bump deliberately and re-test if upstream behaviour changes.
$global:RtlAsarPkg          = '@electron/asar@3.2.10'
# URL of the npm tarball for the pinned ASAR package (fallback when not bundled).
$global:RtlAsarTarballUrl   = 'https://registry.npmjs.org/@electron/asar/-/asar-3.2.10.tgz'
# Deterministic filename for the tarball; shipped in release archives and checked
# by manifest.json so update-local-patcher.ps1 verifies it as part of every update.
$global:RtlAsarTarFileName  = 'asar-3.2.10.tgz'
# SHA-512 integrity of @electron/asar@3.2.10 in npm dist.integrity format ('sha512-<base64>').
# Verified against npm registry (npm view @electron/asar@3.2.10 dist.integrity) and
# independently by downloading the tarball and computing SHA-512 locally.
# Update this constant whenever $global:RtlAsarPkg is bumped.
$global:RtlAsarIntegrity    = 'sha512-mvBSwIBUeiRscrCeJE1LwctAriBj65eUDm0Pc11iE5gRwzkmsdbS7FnZ1XUWjpSeQWL1L5g12Fc/SchPM9DUOw=='

# Named constants for magic values used in binary-patching loops.
# Changing these values changes patch behaviour — review the cert-search
# and hash-replacement sections of Install-Patch before bumping.
$global:RtlCertSearchRadius = 2000  # bytes to scan backwards from anchor searching for 0x30 0x82
$global:RtlCertMinSize      = 500   # minimum valid DER certificate size (bytes)
$global:RtlCertMaxSize      = 4000  # maximum valid DER certificate size (bytes)
$global:RtlCertMaxAttempts  = 10    # maximum self-signed cert generation retries
$global:RtlWatcherThrottle  = 90    # minimum seconds between watcher-triggered patches

function Initialize-RtlStateDir {
    <#
    .SYNOPSIS
        Creates %ProgramData%\ClaudeRtlPatch with a hardened ACL: Admins/SYSTEM full,
        Users read-only. Default ProgramData ACL grants CREATOR_OWNER write to
        authenticated users — a non-admin local user could otherwise tamper with
        state.json and trick the elevated watcher into invoking a re-patch.
    #>
    if (-not (Test-Path $global:RtlStateDir)) {
        New-Item -ItemType Directory -Path $global:RtlStateDir -Force | Out-Null
    }
    # SECURITY: ACL hardening is mandatory. Default ProgramData ACL grants
    # CREATOR_OWNER write to authenticated users — a non-admin local user could
    # otherwise tamper with state.json and trick the elevated watcher.
    # Failure here is not a warning; it is a hard abort.
    $aclOk = $false
    Try {
        & icacls.exe $global:RtlStateDir '/inheritance:r' `
            '/grant' 'BUILTIN\Administrators:(OI)(CI)F' `
            '/grant' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' `
            '/grant' 'BUILTIN\Users:(OI)(CI)R' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $aclOk = $true }
    } Catch {}
    if (-not $aclOk) {
        throw "SECURITY ABORT: Failed to harden ACL on '$global:RtlStateDir' (icacls exit $LASTEXITCODE). " +
              "The watcher and state directory cannot be protected without this ACL. " +
              "Ensure you are running as Administrator with full access to $env:ProgramData and retry."
    }
}

function Get-FileSha256Hex([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function New-IntegrityBackup([string]$Source, [string]$Backup) {
    <#
    .SYNOPSIS
        Creates a .bak from $Source plus a sibling .sha256 sidecar. If both
        already exist, validates the existing backup against its sha256 and is
        a no-op on match. Refuses to silently overwrite an existing backup —
        that .bak may be the only surviving copy of the original signed binary.
        Aborts if the backup hash matches the *currently installed* file AND
        that file is patched (signed by our self-signed cert), because the
        backup has already been overwritten with a patched binary.
    #>
    $hashFile = "$Backup.sha256"
    if (Test-Path -LiteralPath $Backup) {
        if (-not (Test-Path -LiteralPath $hashFile)) {
            throw "Backup '$Backup' exists without its '.sha256' sidecar. Refusing to use a backup of unknown provenance. Reinstall Claude Desktop, then re-run the patch."
        }
        $expected = (Get-Content -LiteralPath $hashFile -Raw).Trim().ToLower()
        $actual   = Get-FileSha256Hex $Backup
        if ($expected -ne $actual) {
            throw "Backup '$Backup' SHA-256 mismatch (expected $expected, got $actual). Backup may be corrupted or tampered with. Reinstall Claude Desktop, then re-run the patch."
        }
        # Detect a previously-corrupted state: backup hash matches the currently
        # installed file, AND that file is signed by our patcher. If both hold,
        # the .bak was already overwritten with a patched binary on a prior run.
        if (Test-Path -LiteralPath $Source) {
            $sourceHash = Get-FileSha256Hex $Source
            if ($sourceHash -eq $expected) {
                $sig = $null
                try { $sig = Get-AuthenticodeSignature -FilePath $Source } catch {}
                if ($sig -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -like '*Claude-RTL-Patcher*') {
                    throw "Backup '$Backup' appears to be a patched binary, not an original. Reinstall Claude Desktop from claude.ai/download, then re-run this patch."
                }
            }
        }
        Write-Log "Backup verified: $(Split-Path $Backup -Leaf) (SHA-256 OK)"
        return
    }
    Copy-FileWithFallback $Source $Backup
    $h = Get-FileSha256Hex $Backup
    Set-Content -LiteralPath $hashFile -Value $h -Encoding ASCII
    Write-Success "$(Split-Path $Backup -Leaf) created (SHA-256 recorded)"
}

function Test-BackupUsable([string]$Backup) {
    # Used by Restore-Patch to refuse to copy a tampered or hash-less backup
    # over a working file. Warns and returns $false on any check failure.
    if (-not (Test-Path -LiteralPath $Backup)) { return $false }
    $hashFile = "$Backup.sha256"
    if (-not (Test-Path -LiteralPath $hashFile)) {
        Write-Warn "Backup '$Backup' has no .sha256 sidecar — refusing to restore from it."
        return $false
    }
    $expected = (Get-Content -LiteralPath $hashFile -Raw).Trim().ToLower()
    $actual   = Get-FileSha256Hex $Backup
    if ($expected -ne $actual) {
        Write-Warn "Backup '$Backup' SHA-256 mismatch — refusing to restore from it."
        return $false
    }
    return $true
}

function Test-ClaudePathSafe([string]$Path) {
    <#
    .SYNOPSIS
        Whitelist guard for Take-Ownership / ACL operations. Refuses anything
        outside the known Claude install roots so an attacker-controlled or
        misdetected $Path cannot be used to widen permissions on arbitrary
        directories.
    #>
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $allowedRoots = @(
        (Join-Path $env:ProgramFiles 'WindowsApps'),
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')
    )
    foreach ($root in $allowedRoots) {
        if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Backup-AppDirAcl([string]$Path) {
    if (-not (Test-ClaudePathSafe $Path)) { return }
    Initialize-RtlStateDir
    if (Test-Path -LiteralPath $global:RtlAclBackup) {
        Write-Log "ACL backup already present: $global:RtlAclBackup (kept)"
        return
    }
    Try {
        $parent = Split-Path -Parent $Path
        $leaf   = Split-Path -Leaf   $Path
        $tmp    = Join-Path $env:TEMP ("claude-acl-" + [Guid]::NewGuid().ToString('N') + ".txt")
        Push-Location -LiteralPath $parent
        Try {
            & icacls.exe $leaf '/save' $tmp '/t' '/q' 2>&1 | Out-Null
        } Finally {
            Pop-Location
        }
        if (Test-Path -LiteralPath $tmp) {
            Move-Item -LiteralPath $tmp -Destination $global:RtlAclBackup -Force
            Write-Log "ACL backup saved: $global:RtlAclBackup"
        } else {
            Write-Warn "ACL backup file was not produced by icacls (exit $LASTEXITCODE)."
        }
    } Catch {
        Write-Warn "ACL backup failed: $($_.Exception.Message)"
    }
}

function Restore-AppDirAcl([string]$Path) {
    if (-not (Test-ClaudePathSafe $Path)) { return }

    if (-not (Test-Path -LiteralPath $global:RtlAclBackup)) {
        Write-Warn "No ACL backup found at: $global:RtlAclBackup"
        Write-Warn "WindowsApps ACLs could NOT be restored. The directory retains Administrators ownership."
        Write-Warn "If Claude behaves unexpectedly, reinstall it from https://claude.ai/download"
        return
    }

    # Stage 1: restore ACL entries from saved backup
    Write-Log "Restoring WindowsApps ACL from: $global:RtlAclBackup"
    $aclRestored = $false
    Try {
        $parent = Split-Path -Parent $Path
        Push-Location -LiteralPath $parent
        Try {
            & icacls.exe '.' '/restore' $global:RtlAclBackup '/q' 2>&1 | Out-Null
        } Finally {
            Pop-Location
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Success "ACL entries restored from backup (icacls exit 0)."
            $aclRestored = $true
        } else {
            Write-Warn "icacls /restore exited $LASTEXITCODE — ACL entries may not be fully restored."
        }
    } Catch {
        Write-Warn "ACL restore threw: $($_.Exception.Message)"
    }

    # Stage 2: restore TrustedInstaller ownership so the MSIX security model is reinstated.
    # Failure is visible but non-fatal — Windows functions without this, but the MSIX
    # integrity guarantee is weakened until Claude is reinstalled.
    Write-Log "Attempting to restore TrustedInstaller ownership on: $Path"
    $ownerRestored = $false
    Try {
        $proc = Start-Process -FilePath icacls.exe `
            -ArgumentList @($Path, '/setowner', 'NT SERVICE\TrustedInstaller', '/t', '/q') `
            -Wait -PassThru -NoNewWindow -WindowStyle Hidden
        if ($proc -and $proc.ExitCode -eq 0) {
            Write-Success "TrustedInstaller ownership restored."
            $ownerRestored = $true
        } else {
            Write-Warn "icacls /setowner exited $($proc.ExitCode) — ownership may still be 'Administrators'."
        }
    } Catch {
        Write-Warn "Could not restore TrustedInstaller ownership: $($_.Exception.Message)"
    }

    # Stage 3: surface a clear reboot/reinstall advisory if either stage failed.
    if (-not $aclRestored -or -not $ownerRestored) {
        Write-Host ""
        Write-Host "  [!] WindowsApps ACL/ownership restore was INCOMPLETE." -ForegroundColor Yellow
        Write-Host "      ACL restored : $aclRestored" -ForegroundColor Yellow
        Write-Host "      Owner restored: $ownerRestored" -ForegroundColor Yellow
        Write-Host "      The Claude install directory may retain non-standard permissions." -ForegroundColor Yellow
        Write-Host "      If Claude behaves unexpectedly after restore:" -ForegroundColor Yellow
        Write-Host "        1. Reboot (releases file locks that block permission changes)." -ForegroundColor Yellow
        Write-Host "        2. Reinstall Claude from https://claude.ai/download" -ForegroundColor Yellow
        Write-Host "           (MSIX reinstall resets WindowsApps permissions fully)." -ForegroundColor Yellow
        Write-Host ""
    }
}

function Get-ClaudeVersionFromPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $leaf = Split-Path -Leaf $Path
    if ($leaf -match '^Claude_(\d+(?:\.\d+){1,3})_') {
        try { return [Version]$matches[1] } catch { return $null }
    }
    # Path may also be the inner app dir; walk up one level.
    $parent = Split-Path -Parent $Path
    if ($parent) {
        $leaf2 = Split-Path -Leaf $parent
        if ($leaf2 -match '^Claude_(\d+(?:\.\d+){1,3})_') {
            try { return [Version]$matches[1] } catch { return $null }
        }
    }
    return $null
}

function Save-PatchState {
    param(
        [Parameter(Mandatory)][string]$InstallPath,
        [string]$CertThumbprint,
        [hashtable]$BackupHashes = @{}
    )
    try {
        Initialize-RtlStateDir
        $ver = Get-ClaudeVersionFromPath -Path $InstallPath
        # Record the SHA-256 of the cached patcher script so the watcher can
        # verify it has not been tampered with before launching an elevated re-patch.
        $cachedHash = if (Test-Path -LiteralPath $global:RtlPatchScriptCache) {
            Get-FileSha256Hex $global:RtlPatchScriptCache
        } else { $null }
        $state = [ordered]@{
            patchedVersion     = if ($ver) { $ver.ToString() } else { $null }
            patchedInstallPath = $InstallPath
            patchedAt          = (Get-Date).ToUniversalTime().ToString("o")
            certThumbprint     = $CertThumbprint
            certSubject        = $global:RtlCertSubject
            cachedScriptSha256 = $cachedHash
            backupHashes       = $BackupHashes
        }
        $state | ConvertTo-Json | Set-Content -Path $global:RtlStateFile -Encoding UTF8
        Write-Log "Patch state recorded at $global:RtlStateFile (version: $($state.patchedVersion))"
    } catch {
        Write-Warn "Failed to save patch state: $($_.Exception.Message)"
    }
}

function Get-PatchStateField([string]$Name) {
    if (-not (Test-Path -LiteralPath $global:RtlStateFile)) { return $null }
    try {
        $s = Get-Content -LiteralPath $global:RtlStateFile -Raw | ConvertFrom-Json
        return $s.$Name
    } catch { return $null }
}

function Find-ClaudeDir {
    # Strict filter: AnthropicPBC* package name OR publisher cert subject contains
    # "CN=Anthropic". Refuses to silently pick a sideloaded "*Claude*" package
    # from an unknown publisher — that would let a malicious package hijack the
    # patcher's elevated path operations.
    $candidates = @(Get-AppxPackage | Where-Object {
        ($_.Name -like 'AnthropicPBC*' -or $_.Publisher -match 'CN=Anthropic') `
        -and $_.InstallLocation -like '*WindowsApps*'
    })

    if ($candidates.Count -gt 1) {
        Write-Warn "Multiple Anthropic Claude packages detected:"
        foreach ($c in $candidates) {
            Write-Warn "  $($c.PackageFullName) -> $($c.InstallLocation)"
        }
        throw "Ambiguous Claude installation. Uninstall older packages and re-run."
    }
    if ($candidates.Count -eq 1) { return $candidates[0].InstallLocation }

    $squirrelPath = Join-Path $env:LOCALAPPDATA "AnthropicClaude"
    if (Test-Path $squirrelPath) {
        Write-Warn "A legacy (Squirrel-based) Claude installation was detected at: $squirrelPath"
        Write-Warn "This version is not supported by the RTL patch."
        Write-Warn "Please uninstall it and install the latest version from: https://claude.ai/download"
        return $null
    }

    return $null
}

function Get-CoworkSvc {
    # Replaces Get-WmiObject (deprecated, removed in PowerShell 7) with
    # Get-CimInstance, which works on both Windows PowerShell 5.1 and 7+.
    try {
        return Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.PathName -match "cowork-svc" } |
            Select-Object -First 1
    } catch {
        Write-Warn "CIM query for Win32_Service failed: $($_.Exception.Message)"
        return $null
    }
}

function Stop-ClaudeServices {
    Write-Step "Halting Claude processes and services..."

    # 1. Stop the Windows service via CIM
    $svc = Get-CoworkSvc
    if ($svc) {
        Write-Log "Stopping service: $($svc.Name) (State: $($svc.State))"
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
        } catch {
            Write-Warn "Stop-Service failed for $($svc.Name): $($_.Exception.Message)"
        }

        $timeout = 10
        for ($w = 0; $w -lt $timeout; $w++) {
            $state = (Get-Service -Name $svc.Name -ErrorAction SilentlyContinue).Status
            if ($state -eq 'Stopped' -or -not $state) { break }
            Start-Sleep -Seconds 1
        }
        Write-Log "Service state after stop: $((Get-Service -Name $svc.Name -ErrorAction SilentlyContinue).Status)"
    } else {
        Write-Log "No cowork-svc Windows service found."
    }

    # 2. Kill any remaining processes
    foreach ($procName in @("claude", "cowork-svc")) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log "Killing $($procs.Count) '$procName' process(es)..."
            foreach ($p in $procs) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
                catch { Write-Warn "Stop-Process failed for $procName($($p.Id)): $($_.Exception.Message)" }
            }
        }
    }

    # 3. Verify processes are gone
    Start-Sleep -Seconds 2
    $remaining = Get-Process -Name "cowork-svc" -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Warn "cowork-svc still running after kill! Waiting 5 more seconds..."
        Start-Sleep -Seconds 5
        try { Stop-Process -Name "cowork-svc" -Force -ErrorAction Stop }
        catch { Write-Warn "Final cowork-svc kill failed: $($_.Exception.Message)" }
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

function Get-FileHolders([string]$Path) {
    # Best-effort: list processes whose loaded modules include the given file.
    # Used only for diagnostic output on backup failure.
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue
        $holders = @()
        foreach ($p in $procs) {
            try {
                if ($p.Modules | Where-Object { $_.FileName -ieq $Path }) {
                    $holders += "$($p.Name)($($p.Id))"
                }
            } catch { }
        }
        return ($holders | Select-Object -Unique)
    } catch { return @() }
}

function Test-FileValid([string]$Path, [string]$Type) {
    <#
    .SYNOPSIS
        Validates that a file is structurally well-formed for its declared type.
        Returns $true if valid, $false otherwise. Never throws on a missing or
        malformed file — callers decide how to react.
    .PARAMETER Type
        'asar' — verifies a parsable Electron ASAR header (Compute-AsarHash succeeds).
        'pe'   — verifies a Windows PE binary: 'MZ' signature and size >= 1 MB.
    #>
    if (-not (Test-Path $Path)) { return $false }
    try {
        $size = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($size -lt 16) { return $false }

        switch ($Type) {
            'asar' {
                # Compute-AsarHash reads the 4-byte JSON-size at offset 12 and the JSON blob.
                # If the file is truncated or not an ASAR, ReadUInt32/ReadBytes throws.
                $null = Compute-AsarHash $Path
                return $true
            }
            'pe' {
                if ($size -lt 1048576) { return $false }
                $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
                try {
                    $b0 = $fs.ReadByte()
                    $b1 = $fs.ReadByte()
                    return ($b0 -eq 0x4D -and $b1 -eq 0x5A)  # 'M','Z'
                } finally { $fs.Close() }
            }
            default { return ($size -gt 0) }
        }
    } catch {
        return $false
    }
}

function Copy-FileSafe([string]$Source, [string]$Dest, [string]$ValidateAs) {
    <#
    .SYNOPSIS
        Atomic file copy with content validation. Writes to "<Dest>.tmp" first,
        verifies the temp file matches the source byte-for-byte (length + optional
        type-specific structural check), then renames to <Dest>. If anything fails,
        the temp is removed and the original <Dest> (if any) is left untouched.
    .PARAMETER ValidateAs
        Optional. 'asar' or 'pe'. If supplied, Test-FileValid is also called on the
        temp file before the rename. Pass empty string or omit to skip type check.
    .NOTES
        - Falls back to byte-level read/write if Copy-Item fails (preserves the
          SCM-locked-binary handling from issue #4).
        - Source is also validated against ValidateAs before copy: a corrupted
          source must not become a corrupted backup.
    #>
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Copy-FileSafe: source '$Source' does not exist."
    }

    if ($ValidateAs) {
        if (-not (Test-FileValid -Path $Source -Type $ValidateAs)) {
            throw "Source file '$(Split-Path $Source -Leaf)' failed integrity check ($ValidateAs). Refusing to create a corrupted backup. Reinstall Claude with: Get-AppxPackage *Claude* | Remove-AppxPackage; then reinstall."
        }
    }

    $tmpDest = "$Dest.tmp"
    if (Test-Path -LiteralPath $tmpDest) {
        Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue
    }

    $copied = $false
    try {
        Copy-Item -LiteralPath $Source -Destination $tmpDest -Force -ErrorAction Stop
        $copied = $true
    } catch {
        Write-Log "Copy-Item failed for $(Split-Path $Dest -Leaf): $($_.Exception.Message). Trying byte-level fallback..."
    }

    if (-not $copied) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($Source)
            [System.IO.File]::WriteAllBytes($tmpDest, $bytes)
            Write-Log "Byte-level copy succeeded for $(Split-Path $Dest -Leaf)"
        } catch {
            if (Test-Path -LiteralPath $tmpDest) { Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue }
            $holders = Get-FileHolders -Path $Source
            if ($holders -and $holders.Count -gt 0) {
                Write-Warn "Processes holding $(Split-Path $Source -Leaf): $($holders -join ', ')"
            }
            throw "Failed to back up '$(Split-Path $Source -Leaf)' to '$(Split-Path $Dest -Leaf)': $($_.Exception.Message)"
        }
    }

    # Verify size matches the source — primary defense against truncated copies
    # (MSIX bindflt sparse reads, EDR interference, mid-copy interruption).
    try {
        $srcLen = (Get-Item -LiteralPath $Source -ErrorAction Stop).Length
        $tmpLen = (Get-Item -LiteralPath $tmpDest -ErrorAction Stop).Length
    } catch {
        if (Test-Path -LiteralPath $tmpDest) { Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue }
        throw "Copy-FileSafe: failed to stat copy target: $($_.Exception.Message)"
    }
    if ($srcLen -ne $tmpLen) {
        Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue
        throw "Copy-FileSafe: size mismatch for '$(Split-Path $Dest -Leaf)' (source=$srcLen, copy=$tmpLen). Aborting."
    }

    if ($ValidateAs) {
        if (-not (Test-FileValid -Path $tmpDest -Type $ValidateAs)) {
            Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue
            throw "Copy-FileSafe: copy of '$(Split-Path $Dest -Leaf)' failed integrity check ($ValidateAs). Aborting."
        }
    }

    Move-Item -LiteralPath $tmpDest -Destination $Dest -Force
}

# -----------------------------------------------------------------------------
# ASAR TOOL HELPERS
# Strategy: download the pinned tarball, verify SHA-512 (hard abort on mismatch),
# extract with the Windows-builtin tar.exe, then invoke node.exe directly.
# No cmd.exe, no shell string parsing, no npx, no network after first run.
# -----------------------------------------------------------------------------
function Get-NodePath {
    <#
    .SYNOPSIS Returns the full path to node.exe. Throws if not installed.
    #>
    $found = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if (-not $found) { $found = Get-Command 'node' -ErrorAction SilentlyContinue }
    if (-not $found) {
        throw "node.exe not found on PATH. Install Node.js from https://nodejs.org and retry."
    }
    return $found.Source
}

function Get-AsarTarPath {
    # Cache path for the verified ASAR tarball inside the hardened state dir.
    return Join-Path $global:RtlStateDir $global:RtlAsarTarFileName
}

function Get-AsarVendorDir {
    return Join-Path $global:RtlStateDir "asar-vendor"
}

function Test-AsarIntegrity {
    <#
    .SYNOPSIS
        Downloads the pinned ASAR tarball and verifies its SHA-512 integrity
        against $global:RtlAsarIntegrity (npm dist.integrity 'sha512-<base64>' format).
        Hard-aborts if the hash does not match — no degraded/warn-only mode.
        Safe to call multiple times: skips download if a matching cache exists.
    #>
    if ($global:RtlAsarIntegrity -notmatch '^sha512-(.+)$') {
        throw "SECURITY ABORT: RtlAsarIntegrity constant is missing or malformed. " +
              "Expected 'sha512-<base64>' (run: npm view $global:RtlAsarPkg dist.integrity). " +
              "Cannot proceed without a known-good hash for the ASAR tool."
    }
    $expectedB64 = $matches[1]
    try { $expectedBytes = [Convert]::FromBase64String($expectedB64) }
    catch { throw "Could not decode RtlAsarIntegrity base64: $($_.Exception.Message)" }

    $cachedTar = Get-AsarTarPath

    if (-not (Test-Path -LiteralPath $cachedTar)) {
        # Check if the tarball was bundled in the release package next to patch.ps1.
        # Release archives ship asar-3.2.10.tgz alongside the scripts so that the
        # install flow is fully offline. Only fall back to network if the bundle is absent.
        $bundledTar = $null
        if ($PSCommandPath) {
            $bundledTar = Join-Path (Split-Path -Parent $PSCommandPath) $global:RtlAsarTarFileName
        }
        if ($bundledTar -and (Test-Path -LiteralPath $bundledTar)) {
            Write-Log "Using bundled ASAR tarball from release package: $bundledTar"
            Copy-Item -LiteralPath $bundledTar -Destination $cachedTar -Force
        } else {
            Write-Log "Bundled tarball not found — downloading $global:RtlAsarPkg from npm registry..."
            Write-Warn "Network access: downloading ASAR tool from $global:RtlAsarTarballUrl"
            Write-Warn "To avoid this, ship $global:RtlAsarTarFileName alongside patch.ps1 in your release archive."
            try {
                Invoke-WebRequest -Uri $global:RtlAsarTarballUrl -OutFile $cachedTar -UseBasicParsing -ErrorAction Stop
                Write-Log "Tarball downloaded: $cachedTar"
            } catch {
                throw "Failed to download ASAR tarball from $global:RtlAsarTarballUrl : $($_.Exception.Message)"
            }
        }
    } else {
        Write-Log "Using cached ASAR tarball: $(Split-Path $cachedTar -Leaf)"
    }

    $sha    = [System.Security.Cryptography.SHA512]::Create()
    $stream = [System.IO.File]::OpenRead($cachedTar)
    try     { $actualBytes = $sha.ComputeHash($stream) }
    finally { $stream.Close(); $sha.Dispose() }

    if (-not [System.Linq.Enumerable]::SequenceEqual($expectedBytes, $actualBytes)) {
        Remove-Item -LiteralPath $cachedTar -Force -ErrorAction SilentlyContinue
        throw "SECURITY ABORT: ASAR tarball SHA-512 mismatch!`n" +
              "  Expected : $global:RtlAsarIntegrity`n" +
              "  The downloaded package does not match the pinned hash. " +
              "Possible npm registry tamper or CDN corruption. Aborting."
    }
    Write-Success "ASAR tarball SHA-512 verified: $global:RtlAsarPkg"
}

function Install-AsarVendor {
    <#
    .SYNOPSIS
        Extracts the verified ASAR tarball into $RtlStateDir\asar-vendor using
        the Windows-builtin tar.exe (available since Windows 10 v1803).
        Idempotent: skips extraction if asar.js is already present.
    #>
    $vendorDir = Get-AsarVendorDir
    $asarJs    = Join-Path $vendorDir "package\bin\asar.js"

    if (Test-Path -LiteralPath $asarJs) {
        Write-Log "ASAR vendor already extracted: $asarJs"
        return
    }

    $cachedTar = Get-AsarTarPath
    if (-not (Test-Path -LiteralPath $cachedTar)) {
        throw "ASAR tarball not found at $cachedTar. Call Test-AsarIntegrity first."
    }

    $tarExe = "$env:SystemRoot\System32\tar.exe"
    if (-not (Test-Path -LiteralPath $tarExe)) {
        throw "tar.exe not found at $tarExe. Windows 10 v1803+ is required."
    }

    if (Test-Path -LiteralPath $vendorDir) { Remove-Item -LiteralPath $vendorDir -Recurse -Force }
    New-Item -ItemType Directory -Path $vendorDir -Force | Out-Null

    Write-Log "Extracting ASAR vendor package with tar.exe..."
    $proc = Start-Process -FilePath $tarExe `
        -ArgumentList @('-xzf', $cachedTar, '-C', $vendorDir) `
        -Wait -PassThru -NoNewWindow
    if ($proc -and $proc.ExitCode -ne 0) {
        throw "tar.exe extraction failed (exit $($proc.ExitCode)). Tarball may be corrupt."
    }

    if (-not (Test-Path -LiteralPath $asarJs)) {
        throw "asar.js not found at expected path $asarJs after extraction."
    }
    Write-Success "ASAR vendor extracted: $vendorDir"
}

function Get-AsarJsPath {
    <#
    .SYNOPSIS
        Returns the path to the asar CLI entry point from the vendored package.
        Reads bin entry from package.json for forward compatibility.
    #>
    $vendorDir = Get-AsarVendorDir
    $pkgJson   = Join-Path $vendorDir "package\package.json"
    if (-not (Test-Path -LiteralPath $pkgJson)) {
        throw "Vendored asar package.json not found at $pkgJson. Run Test-AsarIntegrity and Install-AsarVendor."
    }
    $pkg = Get-Content -LiteralPath $pkgJson -Raw | ConvertFrom-Json
    $binEntry = if ($pkg.bin -is [string]) { $pkg.bin }
                elseif ($pkg.bin.asar)     { $pkg.bin.asar }
                else { $null }
    if (-not $binEntry) { throw "Cannot determine asar bin entry from $pkgJson" }

    $normEntry = $binEntry -replace '/', '\'
    $fullPath  = Join-Path $vendorDir "package\$normEntry"
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "asar CLI entry point not found at $fullPath"
    }
    return $fullPath
}

function Invoke-AsarCommand {
    <#
    .SYNOPSIS
        Invokes the vendored asar CLI via node.exe directly.
        No cmd.exe, no shell string parsing, no network after first setup.
    .PARAMETER Verb
        asar sub-command: '--version', 'extract', or 'pack'.
    .PARAMETER Arg1
        First positional argument (source path).
    .PARAMETER Arg2
        Second positional argument (destination path).
    #>
    param(
        [Parameter(Mandatory)][string]$Verb,
        [string]$Arg1,
        [string]$Arg2
    )
    $nodeExe = Get-NodePath
    $asarJs  = Get-AsarJsPath

    # Argument array — no shell interpolation, no injection surface.
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.Add($asarJs)
    $argList.Add($Verb)
    if ($Arg1) { $argList.Add($Arg1) }
    if ($Arg2) { $argList.Add($Arg2) }

    $proc = Start-Process -FilePath $nodeExe -ArgumentList $argList.ToArray() -Wait -PassThru -NoNewWindow
    if ($proc -and $proc.ExitCode -ne 0) {
        throw "asar $Verb failed (node exit code $($proc.ExitCode)). Check node.exe and ASAR vendor installation."
    }
}

function Start-ClaudeServices {
    Write-Step "Restarting Claude background service..."
    $Started = $false
    
    # 1. Make absolutely sure the service is stopped before starting
    #    (prevents it from running with old binary still in memory)
    $cimSvc = Get-CoworkSvc
    if ($cimSvc) {
        $svcName = $cimSvc.Name
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
        Write-Warn "cowork-svc service not found via CIM."
    }

    # 2. Launch Claude Desktop UI
    Write-Log "Launching Claude Desktop..."
    Try {
        $pkg = Get-AppxPackage | Where-Object {
            ($_.Name -like 'AnthropicPBC*' -or $_.Publisher -match 'CN=Anthropic') `
            -and $_.InstallLocation -like '*WindowsApps*'
        } | Select-Object -First 1
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
    # Whitelist guard: refuse to operate on anything outside Claude install roots.
    # Argument arrays via Start-Process avoid shell parsing — no command injection
    # window if $Path ever picks up an unexpected character.
    if (-not (Test-ClaudePathSafe $Path)) {
        throw "Refusing to take ownership of non-Claude path: '$Path'"
    }
    Write-Log "Requesting permissions for: $Path"
    Try {
        Start-Process -FilePath takeown.exe `
            -ArgumentList @('/F', $Path, '/R', '/D', 'Y') `
            -Wait -NoNewWindow -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } Catch {
        Write-Warn "takeown failed on '$Path': $($_.Exception.Message)"
    }
    Try {
        Start-Process -FilePath icacls.exe `
            -ArgumentList @($Path, '/grant', 'Administrators:F', '/T', '/Q') `
            -Wait -NoNewWindow -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } Catch {
        Write-Warn "icacls grant failed on '$Path': $($_.Exception.Message)"
    }
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

function Create-UpdateShortcut {
    Write-Step "Creating Quick Update Shortcut..."
    Try {
        $WshShell    = New-Object -comObject WScript.Shell
        $DesktopPath = [Environment]::GetFolderPath('Desktop')
        $ShortcutPath = Join-Path $DesktopPath "Update Claude RTL.lnk"

        # Resolve path to update-local-patcher.ps1 next to this script.
        # This shortcut runs the explicit local updater — the only script in
        # this package that contacts GitHub — rather than an irm|iex bootstrap.
        $updaterScript = if ($PSCommandPath) {
            Join-Path (Split-Path -Parent $PSCommandPath) "update-local-patcher.ps1"
        } else {
            Join-Path $global:RtlStateDir "update-local-patcher.ps1"
        }

        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "powershell.exe"
        $Shortcut.Arguments  = "-NoProfile -ExecutionPolicy Bypass -File `"$updaterScript`""
        $Shortcut.Description = "Run update-local-patcher.ps1 to download and verify the latest Claude RTL patch release"

        # Use Claude icon if available, otherwise fall back to PowerShell default.
        $ClaudeDir = Find-ClaudeDir
        if ($ClaudeDir -and (Test-Path (Join-Path $ClaudeDir "app\claude.exe"))) {
            $Shortcut.IconLocation = "$(Join-Path $ClaudeDir "app\claude.exe"),0"
        } else {
            $Shortcut.IconLocation = "powershell.exe,0"
        }

        $Shortcut.Save()
        Write-Success "Shortcut created on Desktop: $ShortcutPath"
        Write-Log "The shortcut runs update-local-patcher.ps1 (verified network updater, not irm|iex)."
    } Catch {
        Write-Warn "Failed to create shortcut: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# AUTO-UPDATE WATCHER (Scheduled Task)
# Watches for new claude.exe processes from a higher version path and triggers
# the patch automatically. The watcher script is embedded as a base64-encoded
# command in the Scheduled Task XML — no extra files on disk.
# -----------------------------------------------------------------------------
function Install-AutoUpdateTask {
    Write-Step "Installing Auto-Update Watcher (Scheduled Task)..."

    if (-not (Test-Path $global:RtlStateFile)) {
        Write-Warn "No patch state found at $global:RtlStateFile."
        Write-Warn "Run option 1 (Install Smart RTL Patch) first so the watcher knows which version is patched."
        return
    }

    # Cache the *currently running* patch.ps1 into the hardened ProgramData dir.
    # The watcher will invoke this cached copy at update time instead of
    # downloading a fresh script — eliminates the persistent unattended
    # remote-code-execution surface that the previous `irm | iex` watcher had.
    Initialize-RtlStateDir
    if (-not $PSCommandPath -or -not (Test-Path -LiteralPath $PSCommandPath)) {
        throw "Auto-Update requires running patch.ps1 from a saved file (so it can be cached). The current invocation has no \$PSCommandPath. Save patch.ps1 to disk and re-run."
    }
    Try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $global:RtlPatchScriptCache -Force
        Write-Log "Cached patch.ps1 to $global:RtlPatchScriptCache (watcher will use this)"
    } Catch {
        throw "Failed to cache patch.ps1 to $global:RtlPatchScriptCache : $($_.Exception.Message)"
    }

    # Record the hash of the freshly cached script in state.json so the watcher
    # can verify integrity before launching an elevated re-patch.
    $cachedHash = Get-FileSha256Hex $global:RtlPatchScriptCache
    Write-Log "Cached script SHA-256: $cachedHash"
    if (Test-Path -LiteralPath $global:RtlStateFile) {
        try {
            $s = Get-Content -LiteralPath $global:RtlStateFile -Raw | ConvertFrom-Json
            $s | Add-Member -MemberType NoteProperty -Name 'cachedScriptSha256' -Value $cachedHash -Force
            $s | ConvertTo-Json | Set-Content -LiteralPath $global:RtlStateFile -Encoding UTF8
            Write-Log "cachedScriptSha256 updated in state.json"
        } catch {
            Write-Warn "Could not update cachedScriptSha256 in state.json: $($_.Exception.Message)"
        }
    }

    # SECURITY: Watcher runs at logon with RunLevel Highest. Previous versions
    # invoked `irm <url> | iex` here — that meant every Claude update fetched
    # and ran an unverified script as Administrator. New behaviour: install
    # caches the *current* patch.ps1 to %ProgramData%\ClaudeRtlPatch\patch.ps1
    # (in a directory whose ACL only Admins/SYSTEM can write) and the watcher
    # invokes that local file. No network call from the elevated path.
    # Single-quoted here-string: $ signs are preserved literally for runtime evaluation inside the watcher.
    $watcher = @'
$ErrorActionPreference = "Continue"
$stateDir       = Join-Path $env:ProgramData "ClaudeRtlPatch"
$stateFile      = Join-Path $stateDir "state.json"
$logFile        = Join-Path $stateDir "watcher.log"
$lastActionFile = Join-Path $stateDir "last-action.txt"
$cachedScript   = Join-Path $stateDir "patch.ps1"

function Write-WLog($msg) {
    try {
        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
            Move-Item $logFile "$logFile.old" -Force
        }
        "$([DateTime]::Now.ToString('o'))  $msg" | Out-File -Append -FilePath $logFile -Encoding UTF8
    } catch {}
}

function Get-VerFromPath($p) {
    if (-not $p) { return $null }
    $cur = $p
    for ($i = 0; $i -lt 4 -and $cur; $i++) {
        $leaf = Split-Path -Leaf $cur
        if ($leaf -match '^Claude_(\d+(?:\.\d+){1,3})_') {
            try { return [Version]$matches[1] } catch { return $null }
        }
        $cur = Split-Path -Parent $cur
    }
    return $null
}

function Show-Toast($title, $body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
        $safeTitle = [System.Security.SecurityElement]::Escape($title)
        $safeBody  = [System.Security.SecurityElement]::Escape($body)
        $xmlStr = "<toast><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeBody</text></binding></visual></toast>"
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlStr)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Claude RTL Patch").Show($toast)
    } catch {
        Write-WLog "Toast failed: $($_.Exception.Message)"
    }
}

function Get-PatchedVer {
    if (-not (Test-Path $stateFile)) { return $null }
    try {
        $s = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($s.patchedVersion) { return [Version]$s.patchedVersion }
    } catch { Write-WLog "State read error: $($_.Exception.Message)" }
    return $null
}

function Invoke-AutoPatch($newVer, $exePath) {
    # Throttle: skip if we acted within the last N seconds (avoids loops on
    # multi-process Electron startup). Threshold stored in state but defaults to 90.
    $throttleSec = 90
    if (Test-Path $lastActionFile) {
        try {
            $last = [DateTime]::Parse((Get-Content $lastActionFile -Raw))
            if (((Get-Date) - $last).TotalSeconds -lt $throttleSec) {
                Write-WLog "Throttled (last action $([int]((Get-Date)-$last).TotalSeconds)s ago, threshold ${throttleSec}s)"
                return
            }
        } catch {}
    }
    (Get-Date).ToString('o') | Set-Content $lastActionFile -Encoding UTF8

    if (-not (Test-Path $cachedScript)) {
        Write-WLog "Cached patch.ps1 missing at $cachedScript -- auto-patch aborted."
        Show-Toast "Auto-patch unavailable" "Cached patch.ps1 missing. Re-run the installer to refresh the watcher."
        return
    }

    # SECURITY: Verify SHA-256 of the cached patcher before launching it with
    # elevated privileges. If the cached file was tampered with (e.g. by a
    # non-admin user before ACL hardening, or by another process), this check
    # catches the drift and aborts rather than running unexpected code as Admin.
    $expectedHash = $null
    if (Test-Path $stateFile) {
        try {
            $s = Get-Content $stateFile -Raw | ConvertFrom-Json
            $expectedHash = $s.cachedScriptSha256
        } catch { Write-WLog "Could not read cachedScriptSha256 from state: $($_.Exception.Message)" }
    }
    if ($expectedHash) {
        $actualHash = (Get-FileHash -LiteralPath $cachedScript -Algorithm SHA256).Hash.ToLower()
        if ($actualHash -ne $expectedHash.ToLower()) {
            Write-WLog "SECURITY: Cached patch.ps1 SHA-256 MISMATCH."
            Write-WLog "  Expected : $expectedHash"
            Write-WLog "  Actual   : $actualHash"
            Write-WLog "Auto-patch aborted. Re-run the installer to refresh and re-verify the cached script."
            Show-Toast "Auto-patch security check failed" "Cached patcher checksum mismatch. Re-run installer to fix. See watcher.log."
            return
        }
        Write-WLog "Cached patch.ps1 integrity OK (SHA-256 match)"
    } else {
        Write-WLog "WARNING: No expected SHA-256 in state.json -- skipping integrity check. Re-run installer to populate hash."
    }

    Write-WLog "Detected Claude v$newVer at $exePath -- launching cached patcher (Auto mode)"
    Show-Toast "Claude updated to v$newVer" "Auto-patching now. A PowerShell window will open with the patch log."

    # Kill running Claude processes for snappy UX (patch.ps1 kills again properly via Stop-ClaudeServices).
    Get-Process -Name claude,cowork-svc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    try {
        # Local elevated launch of the verified cached script. No network call.
        Start-Process -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $cachedScript,
                '-Auto'
            ) | Out-Null
        Write-WLog "Spawned cached patch.ps1 -Auto from $cachedScript"
    } catch {
        Write-WLog "Failed to launch cached patcher: $($_.Exception.Message)"
        Show-Toast "Auto-patch FAILED to start" "Please run patch.ps1 manually as Administrator. See watcher.log."
    }
}

function Test-AndPatch($exePath) {
    if (-not $exePath) { return }
    $newVer = Get-VerFromPath $exePath
    if (-not $newVer) { return }

    # SECURITY: Authenticode check before triggering any elevated patch action.
    # Refuses to act on a fake Claude_99.99.99_* folder or an unsigned binary.
    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-WLog "Refusing auto-patch: detected path does not exist: $exePath"
        return
    }
    try {
        $sig = Get-AuthenticodeSignature -FilePath $exePath -ErrorAction Stop
        if ($sig.Status -ne 'Valid') {
            Write-WLog "Refusing auto-patch: claude.exe signature status '$($sig.Status)' at $exePath"
            return
        }
        if ($sig.SignerCertificate.Subject -notmatch 'Anthropic') {
            Write-WLog "Refusing auto-patch: claude.exe signer '$($sig.SignerCertificate.Subject)' does not contain 'Anthropic' -- possible spoofed package."
            return
        }
        Write-WLog "Authenticode OK: claude.exe signed by $($sig.SignerCertificate.Subject)"
    } catch {
        Write-WLog "Refusing auto-patch: Authenticode check failed for $exePath : $($_.Exception.Message)"
        return
    }

    $patchedVer = Get-PatchedVer
    if (-not $patchedVer) { Write-WLog "No state file; ignoring v$newVer"; return }
    if ($newVer -gt $patchedVer) { Invoke-AutoPatch -newVer $newVer -exePath $exePath }
}

Write-WLog "Watcher started (PID $PID, user $env:USERNAME)"
Write-WLog "Currently patched version: $(Get-PatchedVer)"

# Initial sweep — Claude might already be running from a newer version when the watcher starts.
try {
    $existing = Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($existing) { Test-AndPatch $existing.Path }
} catch {}

$query = "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name = 'claude.exe'"
Register-CimIndicationEvent -Query $query -SourceIdentifier "ClaudeProcessCreated" | Out-Null
Write-WLog "WMI subscription active. Idling..."

while ($true) {
    $ev = Wait-Event -SourceIdentifier "ClaudeProcessCreated" -Timeout 3600
    if ($null -eq $ev) { continue }
    try {
        $p = $ev.SourceEventArgs.NewEvent.TargetInstance.ExecutablePath
        Test-AndPatch $p
    } catch {
        Write-WLog "Event handler error: $($_.Exception.Message)"
    } finally {
        Remove-Event -EventIdentifier $ev.EventIdentifier
    }
}
'@

    Try {
        $bytes   = [System.Text.Encoding]::Unicode.GetBytes($watcher)
        $encoded = [Convert]::ToBase64String($bytes)

        $userName  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $userName
        $settings  = New-ScheduledTaskSettingsSet `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -MultipleInstances IgnoreNew -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $principal = New-ScheduledTaskPrincipal -UserId $userName `
            -RunLevel Highest -LogonType Interactive

        Register-ScheduledTask -TaskName $global:RtlTaskName `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "Detects Claude Desktop updates and re-applies the RTL patch automatically." `
            -Force | Out-Null

        Start-ScheduledTask -TaskName $global:RtlTaskName -ErrorAction SilentlyContinue
        Write-Success "Scheduled Task '$global:RtlTaskName' installed and started."
        Write-Success "Watcher logs: $(Join-Path $global:RtlStateDir 'watcher.log')"
        Write-Success "It will run automatically on every logon (and is now active for this session)."
    } Catch {
        Write-Warn "Failed to install scheduled task: $($_.Exception.Message)"
    }
}

function Uninstall-AutoUpdateTask {
    Write-Step "Removing Auto-Update Watcher..."
    Try {
        $existing = Get-ScheduledTask -TaskName $global:RtlTaskName -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Warn "Scheduled Task '$global:RtlTaskName' is not installed."
            return
        }
        Stop-ScheduledTask -TaskName $global:RtlTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $global:RtlTaskName -Confirm:$false -ErrorAction Stop
        Write-Success "Scheduled Task '$global:RtlTaskName' removed."
        Write-Log "State file at $global:RtlStateFile was kept. Use option 2 (Restore) to remove all state."
    } Catch {
        Write-Warn "Failed to remove scheduled task: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# CORE PATCHING LOGIC (WITH ATOMIC FALLBACK)
# -----------------------------------------------------------------------------
function Install-Patch {
    Write-Host "`n=======================================================" -ForegroundColor Cyan
    Write-Host "     INSTALLING CLAUDE SMART RTL PATCH" -ForegroundColor Cyan
    Write-Host "=======================================================`n" -ForegroundColor Cyan

    $ClaudeDir = Find-ClaudeDir
    if (-not $ClaudeDir) { throw "Claude installation not found on this system." }
    Write-Success "Found Claude at: $ClaudeDir"

    $AppDir = Join-Path $ClaudeDir "app"
    $ResourcesDir = Join-Path $AppDir "resources"
    $AsarPath = Join-Path $ResourcesDir "app.asar"
    $ExePath = Join-Path $AppDir "claude.exe"
    $CoworkSvcPath = Join-Path $ResourcesDir "cowork-svc.exe"

    if (-not (Test-Path $AsarPath)) { throw "app.asar not found!" }

    # Verify ASAR tool integrity before first use.
    # Downloads the pinned tarball (if not already cached), verifies SHA-512 —
    # hard abort on mismatch. Extracts into the hardened state dir with tar.exe.
    # From this point forward, node.exe calls the vendored asar.js directly —
    # no npx, no cmd.exe, no network after the first run.
    Initialize-RtlStateDir
    Write-Log "Verifying and setting up ASAR vendor tool..."
    Test-AsarIntegrity
    Install-AsarVendor
    Try {
        # Smoke-test: confirm node.exe can run the vendored asar binary.
        $null = Get-NodePath
        Invoke-AsarCommand -Verb '--version'
    } Catch {
        throw "ASAR tool smoke-test failed: $($_.Exception.Message). Install Node.js from https://nodejs.org"
    }

    Stop-ClaudeServices

    Write-Step "Saving WindowsApps ACL snapshot before modification..."
    Initialize-RtlStateDir
    Backup-AppDirAcl $ClaudeDir

    Write-Step "Taking ownership of Claude directories..."
    Take-Ownership $AppDir
    Take-Ownership $ResourcesDir

    Write-Step "Creating integrity-checked backups..."
    Wait-FileUnlock -Path $ExePath -TimeoutSeconds 15
    Wait-FileUnlock -Path $CoworkSvcPath -TimeoutSeconds 15
    # New-IntegrityBackup creates .bak + .bak.sha256, validates an existing
    # backup against its sidecar, and refuses to silently overwrite a backup
    # whose hash is missing or whose hash matches an already-patched current
    # file (would mean the original is gone).
    New-IntegrityBackup $AsarPath        "$AsarPath.bak"
    if (Test-Path $ExePath)       { New-IntegrityBackup $ExePath       "$ExePath.bak" }
    if (Test-Path $CoworkSvcPath) { New-IntegrityBackup $CoworkSvcPath "$CoworkSvcPath.bak" }

    # Always restore from backup before patching — ensures clean state
    # First run: .bak was just created from same file → copy is a no-op (safe)
    # Re-run: backup is validated by hash above → fresh install on clean files
    Write-Step "Ensuring clean state before patching..."
    $RestorePairs = @(
        @{O=$AsarPath;       B="$AsarPath.bak";       T='asar'},
        @{O=$ExePath;        B="$ExePath.bak";        T='pe'},
        @{O=$CoworkSvcPath;  B="$CoworkSvcPath.bak";  T='pe'}
    )
    # Pre-flight: verify ALL existing backups are valid before touching anything.
    # An all-or-nothing check prevents a partial restore that could leave
    # claude.exe's embedded asar hash mismatching app.asar.
    foreach ($pair in $RestorePairs) {
        if ((Test-Path $pair.B) -and -not (Test-FileValid -Path $pair.B -Type $pair.T)) {
            $bakName = Split-Path $pair.B -Leaf
            $bakSize = if (Test-Path $pair.B) { (Get-Item -LiteralPath $pair.B).Length } else { 0 }
            throw "Backup '$bakName' appears corrupted ($bakSize bytes, expected valid $($pair.T)).`n    Path: $($pair.B)`n    Delete the corrupted backup file and re-run, or reinstall Claude:`n      Get-AppxPackage *Claude* | Remove-AppxPackage`n    Aborting before touching any live files."
        }
    }
    foreach ($pair in $RestorePairs) {
        if (Test-Path $pair.B) {
            Wait-FileUnlock -Path $pair.O -TimeoutSeconds 15
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
        Invoke-AsarCommand -Verb 'extract' -Arg1 $AsarPath -Arg2 $global:TmpDir

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

        # ATOMIC: stage all three modified files as `.new`. Originals stay
        # untouched until every step (asar repack, hash replacement, cert swap,
        # re-signing) has succeeded. On failure, the .new files are deleted in
        # the catch block below — originals never need to be restored from .bak
        # because they were never modified.
        $TmpAsarPath = "$AsarPath.new"
        $TmpExePath  = "$ExePath.new"
        $TmpSvcPath  = "$CoworkSvcPath.new"
        Write-Log "Repacking ASAR archive..."
        Invoke-AsarCommand -Verb 'pack' -Arg1 $global:TmpDir -Arg2 $TmpAsarPath

        $NewHash = Compute-AsarHash $TmpAsarPath
        Write-Log "New Hash: $NewHash"

        Write-Step "Phase 2 & 3: Executable Patching & Cert Synchronization"
        if ((Test-Path $ExePath) -and (Test-Path $CoworkSvcPath)) {
            
            # 1. READ FROM BAK FILES FOR IDEMPOTENCY
            $SourceSvc = if (Test-Path "$CoworkSvcPath.bak") { "$CoworkSvcPath.bak" } else { $CoworkSvcPath }
            $SourceExe = if (Test-Path "$ExePath.bak") { "$ExePath.bak" } else { $ExePath }

            # EXACT PYTHON LOGIC: PURE BYTE ARRAY SEARCH
            $SvcBytes    = [System.IO.File]::ReadAllBytes($SourceSvc)
            $AnchorBytes = [System.Text.Encoding]::ASCII.GetBytes("Anthropic, PBC")
            # Pre-compute ISO-8859-1 string for the SVC byte array once; reused
            # across iterations to avoid repeated full-array encoding in the loop.
            $encLatin1   = [System.Text.Encoding]::GetEncoding(28591)
            $SvcHayStr   = $encLatin1.GetString($SvcBytes)

            $StartPos = -1
            $OldCertSize = 0
            $Offset = 0

            while ($true) {
                $AnchorPos = Find-Bytes -Haystack $SvcBytes -Needle $AnchorBytes -StartIndex $Offset -PrecomputedHaystack $SvcHayStr
                if ($AnchorPos -eq -1) { break }

                $Limit = [Math]::Max(0, $AnchorPos - $global:RtlCertSearchRadius)
                for ($i = $AnchorPos; $i -ge $Limit; $i--) {
                    if ($SvcBytes[$i] -eq 0x30 -and $SvcBytes[$i+1] -eq 0x82) {
                        $TotalSize = 4 + (([int]$SvcBytes[$i+2] -shl 8) -bor [int]$SvcBytes[$i+3])
                        if ($TotalSize -gt $global:RtlCertMinSize -and $TotalSize -lt $global:RtlCertMaxSize -and $i -lt $AnchorPos -and ($i + $TotalSize) -gt $AnchorPos) {
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

            # 2. CERT SUBJECT — clearly local, never impersonates Anthropic.
            # The previous build cloned the original Anthropic Subject DN into our
            # self-signed Root cert: any binary signed by anyone with admin on this
            # box would then display "Anthropic, PBC" in Windows UI. New behaviour
            # uses a distinguishing local subject. We still install into the Root
            # store because cowork-svc's PE cert table is checked against Root for
            # service trust on some Windows configurations; if a future test shows
            # TrustedPublisher is sufficient, switch the StoreName below.
            $CertSubject = $global:RtlCertSubject
            Write-Log "Using local self-signed cert subject: $CertSubject"

            # 3. DYNAMIC CERTIFICATE GENERATION LOOP
            # WHY LocalMachine\Root IS REQUIRED (not TrustedPublisher):
            # Authenticode verification traces the signing cert's chain up to a
            # trusted root CA. For a self-signed cert, the cert IS the root —
            # it must therefore be in the Root store for Windows to call the chain
            # "Valid". TrustedPublisher is an additional layer that controls UAC /
            # SmartScreen prompts for already-trusted chains; it cannot substitute
            # for a trusted root. Placing the cert only in TrustedPublisher produces
            # a status of "UnknownError" from Get-AuthenticodeSignature because the
            # chain has no trusted anchor. Root is the minimal necessary store.
            #
            # Mitigations:
            #   * Subject is "CN=Claude-RTL-Patcher (self-signed), O=Local" — clearly
            #     local, never impersonates Anthropic.
            #   * Thumbprint is stored in state.json; Restore removes it precisely.
            #   * The private key is deleted from My store immediately after signing
            #     (step 8 below) — only the public cert remains in Root.
            Write-Warn "Installing self-signed code-signing certificate into LocalMachine\Root."
            Write-Warn "  Subject  : $CertSubject"
            Write-Warn "  Root store is required: self-signed certs need to be their own CA"
            Write-Warn "  for Authenticode chain validation (TrustedPublisher alone is not sufficient)."
            Write-Warn "  Private key will be deleted immediately after signing."
            Write-Warn "  Use Restore (option 2) to remove this cert when reverting the patch."
            $ValidCertFound = $false
            $Attempts = 1
            $MaxAttempts = $global:RtlCertMaxAttempts
            $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
            $Store.Open("ReadWrite")

            $Cert = $null
            $NewCertBytes = $null

            while (-not $ValidCertFound -and $Attempts -le $MaxAttempts) {
                Write-Log "Generating self-signed certificate (Attempt $Attempts)..."
                $Cert = New-SelfSignedCertificate -Subject $CertSubject -Type CodeSigningCert -CertStoreLocation "Cert:\LocalMachine\My" -FriendlyName $global:RtlCertFriendly -KeyAlgorithm RSA -KeyLength 2048

                $NewCertBytes = $Cert.RawData

                if ($NewCertBytes.Length -le $OldCertSize) {
                    $Store.Add($Cert)
                    $ValidCertFound = $true
                    Write-Success "Generated certificate fits! (Size: $($NewCertBytes.Length) bytes, Hole: $OldCertSize bytes)"
                } else {
                    Write-Warn "Certificate too large ($($NewCertBytes.Length) bytes). Removing and retrying..."
                    Try {
                        Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $Cert.Thumbprint } | Remove-Item -ErrorAction Stop
                    } Catch {
                        Write-Warn "Could not remove oversized cert $($Cert.Thumbprint): $($_.Exception.Message)"
                    }
                    $Attempts++
                }
            }
            $Store.Close()

            if (-not $ValidCertFound) {
                throw "Failed to generate a suitably sized certificate after $MaxAttempts attempts."
            }
            # Track the freshly issued cert for state.json + clean rollback.
            $script:LastCertThumbprint = $Cert.Thumbprint

            # 4. SWAP ALL HASHES IN CLAUDE.EXE (PURE BYTE SEARCH LIKE r.js)
            Wait-FileUnlock $ExePath
            Write-Log "Reading claude.exe into memory..."
            $ExeBytes = [System.IO.File]::ReadAllBytes($SourceExe)
            Write-Log "Scanning $([math]::Round($ExeBytes.Length/1MB,1)) MB of claude.exe for ASAR hash matches..."
            $OldHashBytes = [System.Text.Encoding]::ASCII.GetBytes($OldHash)
            $NewHashBytes = [System.Text.Encoding]::ASCII.GetBytes($NewHash)
            # Pre-compute ISO-8859-1 string for EXE bytes once; avoids re-encoding the
            # entire ~100 MB array on every Find-Bytes iteration in the replacement loop.
            $ExeHayStr = $encLatin1.GetString($ExeBytes)

            $OffsetExe = 0
            $Replacements = 0

            while ($true) {
                $Idx = Find-Bytes -Haystack $ExeBytes -Needle $OldHashBytes -StartIndex $OffsetExe -PrecomputedHaystack $ExeHayStr
                if ($Idx -eq -1) { break }

                [Array]::Copy($NewHashBytes, 0, $ExeBytes, $Idx, $NewHashBytes.Length)
                $OffsetExe = $Idx + $OldHashBytes.Length
                $Replacements++
            }

            if ($Replacements -gt 0) {
                Write-Log "Writing patched claude.exe to staging file ($TmpExePath)..."
                [System.IO.File]::WriteAllBytes($TmpExePath, $ExeBytes)
                Write-Success "Replaced $Replacements ASAR hash(es) in claude.exe.new"
            } else {
                Write-Warn "Old hash not found in claude.exe. Writing unmodified copy to staging."
                [System.IO.File]::WriteAllBytes($TmpExePath, $ExeBytes)
            }

            Write-Log "Re-signing claude.exe.new (this can take several seconds)..."
            $SignResult = Set-AuthenticodeSignature -FilePath $TmpExePath -Certificate $Cert -HashAlgorithm SHA256
            if ($SignResult.Status -eq 'Valid') { Write-Success "Successfully re-signed claude.exe.new" }
            else { throw "Re-signing claude.exe.new failed: $($SignResult.Status)" }

            # 5. EXACT PADDING AND BINARY SWAP IN COWORK-SVC.EXE (staged)
            $Diff = $OldCertSize - $NewCertBytes.Length
            Write-Log "Swapping cowork-svc cert and padding with $Diff bytes of 0x00..."

            $PaddedCert = New-Object byte[] $OldCertSize
            [Array]::Copy($NewCertBytes, 0, $PaddedCert, 0, $NewCertBytes.Length)

            [Array]::Copy($PaddedCert, 0, $SvcBytes, $StartPos, $OldCertSize)
            [System.IO.File]::WriteAllBytes($TmpSvcPath, $SvcBytes)
            Write-Success "Binary cert replacement written to cowork-svc.exe.new"

            # 6. SIGN COWORK-SVC.EXE.NEW
            Write-Log "Re-signing cowork-svc.exe.new (this can take several seconds)..."
            $SignResult2 = Set-AuthenticodeSignature -FilePath $TmpSvcPath -Certificate $Cert -HashAlgorithm SHA256
            if ($SignResult2.Status -eq 'Valid') { Write-Success "Successfully re-signed cowork-svc.exe.new" }
            else { throw "Re-signing cowork-svc.exe.new failed: $($SignResult2.Status)" }

            # 7. ATOMIC COMMIT — every staging file is signed and validated.
            # Replace originals now. If any Move-Item fails mid-commit (rare —
            # would require a new lock between Wait-FileUnlock and Move-Item),
            # the catch block restores from .bak.
            Wait-FileUnlock $AsarPath
            Wait-FileUnlock $ExePath
            Wait-FileUnlock $CoworkSvcPath
            Move-Item -Path $TmpAsarPath -Destination $AsarPath       -Force
            Move-Item -Path $TmpExePath  -Destination $ExePath        -Force
            Move-Item -Path $TmpSvcPath  -Destination $CoworkSvcPath  -Force
            Write-Success "Atomic commit: app.asar / claude.exe / cowork-svc.exe replaced."

            # 8. WIPE PRIVATE KEY: public cert stays in Root for verification, but the
            # private key is no longer needed and would let an admin-level attacker
            # sign additional binaries that Windows would auto-trust.
            #
            # Note: 'Remove-Item -DeleteKey' is a dynamic parameter of the Cert:
            # provider that doesn't always bind through a pipeline in PS 5.1, so
            # we delete the CSP/CNG key material via .NET, then remove the cert
            # via X509Store — this works on PS 5.1 and PS 7+ uniformly.
            $myStore = $null
            Try {
                $thumb  = $Cert.Thumbprint
                $myStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "LocalMachine")
                $myStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                $found = $myStore.Certificates | Where-Object { $_.Thumbprint -eq $thumb }
                if ($found) {
                    if ($found.HasPrivateKey) {
                        Try {
                            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($found)
                            if ($rsa -is [System.Security.Cryptography.RSACng]) {
                                $rsa.Key.Delete()
                            } elseif ($rsa -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
                                $rsa.PersistKeyInCsp = $false
                                $rsa.Clear()
                            }
                        } Catch {
                            Write-Warn "Could not delete CSP/CNG key material: $($_.Exception.Message)"
                        }
                    }
                    $myStore.Remove($found)
                    Write-Success "Private signing key wiped from My store (Root cert retained)"
                } else {
                    Write-Warn "Cert with thumbprint $thumb not found in My store; nothing to wipe."
                }
            } Catch {
                Write-Warn "Could not delete private key: $($_.Exception.Message)"
            } Finally {
                if ($myStore) { $myStore.Close() }
            }

        } else {
            Write-Warn "claude.exe or cowork-svc.exe not found. Binary patching skipped."
        }

        Write-Step "Cleanup & Launch"
        if (Test-Path $global:TmpDir) { Remove-Item $global:TmpDir -Recurse -Force }
        Save-PatchState -InstallPath $ClaudeDir -CertThumbprint $script:LastCertThumbprint
        Start-ClaudeServices

        Write-Host "`n=======================================================" -ForegroundColor Green
        Write-Host " PATCH INSTALLATION COMPLETED SUCCESSFULLY! ENJOY!" -ForegroundColor Green
        Write-Host "=======================================================`n" -ForegroundColor Green

        if (-not $Auto) {
            $autoPatchPrompt = Read-Host "Do you want to enable Auto Re-Patch after each Claude update? (Y/n)"
            if ($autoPatchPrompt -ne 'n' -and $autoPatchPrompt -ne 'N') {
                try { Install-AutoUpdateTask } catch { Write-Warn "Failed to install auto-patch task: $($_.Exception.Message)" }
            }
        }

    } Catch {
        # ==========================================
        # FALLBACK / ROLLBACK MECHANISM
        # ==========================================
        $ErrorMessage = $_.Exception.Message
        Write-Host "`n[X] CRITICAL ERROR DETECTED DURING PATCHING!" -ForegroundColor Red
        Write-Host "    Reason: $ErrorMessage" -ForegroundColor Red
        Write-Host "    INITIATING AUTOMATIC ROLLBACK TO PREVENT CORRUPTION..." -ForegroundColor Yellow

        # Delete any leftover staging files. Originals were never replaced if
        # the failure happened pre-commit; if it happened during commit (after
        # one Move-Item but before another), Restore-Patch below recovers from
        # validated .bak files.
        foreach ($staging in @("$AsarPath.new", "$ExePath.new", "$CoworkSvcPath.new")) {
            if (Test-Path -LiteralPath $staging) {
                Try { Remove-Item -LiteralPath $staging -Force -ErrorAction Stop }
                Catch { Write-Warn "Could not delete staging file $staging : $($_.Exception.Message)" }
            }
        }

        Restore-Patch -IsRollback

        # Don't claim a successful restore here — Restore-Patch may have aborted
        # (e.g., if all backups were corrupt). The rollback path prints its own
        # final status line, so we just surface the install failure itself.
        throw "Installation failed. See rollback status above."
    }
}

function Restore-Patch {
    param([switch]$IsRollback)

    if (-not $IsRollback) {
        Write-Host "`n=======================================================" -ForegroundColor Cyan
        Write-Host "     RESTORING CLAUDE & REMOVING PATCHER PERSISTENCE" -ForegroundColor Cyan
        Write-Host "=======================================================`n" -ForegroundColor Cyan
    } else {
        Write-Step "Executing Fallback Rollback..."
    }

    $ClaudeDir = Find-ClaudeDir
    if (-not $ClaudeDir) {
        if ($IsRollback) { Write-Warn "Claude Dir not found during rollback." }
        else { Write-Warn "Claude install not found — file restore will be skipped, persistence cleanup will continue." }
    }

    $AppDir       = if ($ClaudeDir) { Join-Path $ClaudeDir "app" }       else { $null }
    $ResourcesDir = if ($AppDir)    { Join-Path $AppDir "resources" }    else { $null }

    Stop-ClaudeServices

    # 1) Restore patched files from .bak (validated against .sha256).
    $Restored = $false
    $Aborted  = $false
    $SnapshotPaths = @()  # tracked so we can clean them up at the end

    $FilesToRestore = @(
        @{"Orig" = Join-Path $ResourcesDir "app.asar";       "Bak" = Join-Path $ResourcesDir "app.asar.bak";       "Type" = 'asar'},
        @{"Orig" = Join-Path $AppDir       "claude.exe";     "Bak" = Join-Path $AppDir       "claude.exe.bak";     "Type" = 'pe'},
        @{"Orig" = Join-Path $ResourcesDir "cowork-svc.exe"; "Bak" = Join-Path $ResourcesDir "cowork-svc.exe.bak"; "Type" = 'pe'}
    )

    # Pre-flight: validate every backup we plan to use. A partial restore where
    # one file is restored from a good .bak but another fails on a corrupt .bak
    # would leave claude.exe's embedded asar hash mismatching app.asar — worse
    # than the patched-but-working state we started from.
    $InvalidBaks = @()
    foreach ($Item in $FilesToRestore) {
        if (Test-Path -LiteralPath $Item["Bak"]) {
            if (-not (Test-FileValid -Path $Item["Bak"] -Type $Item["Type"])) {
                $InvalidBaks += (Split-Path $Item["Bak"] -Leaf)
            }
        }
    }

    if ($InvalidBaks.Count -gt 0) {
        Write-Warn "The following backup file(s) appear corrupted and CANNOT be used to restore: $($InvalidBaks -join ', ')"
        Write-Warn "ROLLBACK ABORTED: leaving the system in its current state to avoid making it worse."
        Write-Warn "To recover Claude, reinstall the application:"
        Write-Warn "  Get-AppxPackage *Claude* | Remove-AppxPackage"
        Write-Warn "Then download and install Claude Desktop again."
        $Aborted = $true
    } else {
        # Snapshot current state so a botched restore can be reversed manually.
        # Best-effort only: if a snapshot fails, log and proceed.
        foreach ($Item in $FilesToRestore) {
            if (Test-Path -LiteralPath $Item["Orig"]) {
                $snap = "$($Item['Orig']).pre-rollback"
                Try {
                    Copy-Item -LiteralPath $Item["Orig"] -Destination $snap -Force -ErrorAction Stop
                    $SnapshotPaths += $snap
                } Catch {
                    Write-Warn "Could not snapshot $(Split-Path $Item['Orig'] -Leaf) before rollback: $($_.Exception.Message)"
                }
            }
        }

        foreach ($Item in $FilesToRestore) {
            if (Test-Path -LiteralPath $Item["Bak"]) {
                Try {
                    Wait-FileUnlock -Path $Item["Orig"] -TimeoutSeconds 15
                    Copy-Item -LiteralPath $Item["Bak"] -Destination $Item["Orig"] -Force -ErrorAction Stop
                    Write-Success "Restored $(Split-Path $Item['Orig'] -Leaf)"
                    $Restored = $true
                } Catch {
                    Write-Warn "Failed to copy $(Split-Path $Item['Orig'] -Leaf) back: $($_.Exception.Message)"
                }
            } else {
                Write-Warn "Backup for $(Split-Path $Item['Orig'] -Leaf) not found."
            }
        }

        # Clean up the pre-rollback snapshots — the restore worked (we're past the
        # copies above without throwing), so we no longer need the safety copies.
        foreach ($snap in $SnapshotPaths) {
            if (Test-Path -LiteralPath $snap) {
                Remove-Item -LiteralPath $snap -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 2) Remove the auto-update Scheduled Task. Restore now means *full* revert
    #    — no leftover persistence from this patcher after this completes.
    Write-Log "Removing auto-update Scheduled Task (if present)..."
    Try {
        $existing = Get-ScheduledTask -TaskName $global:RtlTaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-ScheduledTask  -TaskName $global:RtlTaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $global:RtlTaskName -Confirm:$false -ErrorAction Stop
            Write-Success "Scheduled Task '$global:RtlTaskName' removed."
        } else {
            Write-Log "Scheduled Task '$global:RtlTaskName' was not registered."
        }
    } Catch {
        Write-Warn "Failed to remove scheduled task: $($_.Exception.Message)"
    }

    # 3) Remove our self-signed cert. Match by stored thumbprint first, fall
    #    back to FriendlyName + Subject. Refuse to wildcard-match Anthropic.
    Write-Log "Cleaning up patcher-issued certificates..."
    $thumb = Get-PatchStateField -Name 'certThumbprint'
    foreach ($storeName in @('My','Root','TrustedPublisher')) {
        Try {
            $matched = @()
            if ($thumb) {
                $matched += Get-ChildItem "Cert:\LocalMachine\$storeName" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Thumbprint -eq $thumb }
            }
            $matched += Get-ChildItem "Cert:\LocalMachine\$storeName" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FriendlyName -eq $global:RtlCertFriendly -and
                    $_.Subject -eq $global:RtlCertSubject
                }
            $matched = $matched | Sort-Object -Property Thumbprint -Unique
            foreach ($c in $matched) {
                Try {
                    Remove-Item -LiteralPath $c.PSPath -Force -ErrorAction Stop
                    Write-Success "Removed cert $($c.Thumbprint) from $storeName"
                } Catch {
                    Write-Warn "Failed to remove cert $($c.Thumbprint) from $storeName : $($_.Exception.Message)"
                }
            }
        } Catch {
            Write-Warn "Cert enumeration in $storeName failed: $($_.Exception.Message)"
        }
    }
    # Defensive scan: warn (do NOT remove) on stray self-signed Anthropic-subject roots.
    Try {
        $strays = Get-ChildItem 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -match 'Anthropic, PBC' -and $_.Subject -eq $_.Issuer }
        foreach ($s in $strays) {
            Write-Warn "Suspicious self-signed cert with Anthropic subject left in Root: $($s.Thumbprint). Inspect manually with certlm.msc — not removed automatically."
        }
    } Catch {}

    # 4) Restore WindowsApps ACL snapshot.
    if ($ClaudeDir) { Restore-AppDirAcl $ClaudeDir }

    # 5) Clean patcher-owned files in ProgramData. Keep watcher.log in case the
    #    user wants to read it; remove the cached patch.ps1, ACL backup, state,
    #    and last-action throttle file. Leave the directory itself in place.
    foreach ($f in @($global:RtlPatchScriptCache, $global:RtlAclBackup, $global:RtlStateFile,
                     (Join-Path $global:RtlStateDir 'last-action.txt'))) {
        if (Test-Path -LiteralPath $f) {
            Try {
                Remove-Item -LiteralPath $f -Force -ErrorAction Stop
                Write-Log "Removed $(Split-Path $f -Leaf)"
            } Catch {
                Write-Warn "Could not remove $(Split-Path $f -Leaf): $($_.Exception.Message)"
            }
        }
    }

    Start-ClaudeServices

    if ($IsRollback) {
        if ($Aborted) {
            Write-Host "`n[X] ROLLBACK ABORTED: backup integrity check failed. System left in its current state - see messages above." -ForegroundColor Red
        } elseif ($Restored) {
            Write-Host "`n[V] ROLLBACK COMPLETED SUCCESSFULLY." -ForegroundColor Green
        } else {
            Write-Host "`n[!] ROLLBACK FINISHED WITH NO RESTORES (no backups available)." -ForegroundColor Yellow
        }
    } else {
        if ($Aborted)      { Write-Warn "Restore aborted - see messages above." }
        elseif ($Restored) { Write-Success "Restore process completed. Claude is back to original." }
        else               { Write-Warn "Restore process finished, but no backups were found." }
    }
}

# -----------------------------------------------------------------------------
# MAIN MENU LOOP
# -----------------------------------------------------------------------------
function Show-Menu {
    # Iterative loop instead of recursive self-call. Behaviour identical to
    # users (Clear-Host on each redraw, same prompts), but no stack growth on
    # long sessions and a single, predictable exit point.
    while ($true) {
        Clear-Host
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║    Claude Desktop Smart RTL & Service Patcher    ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host "`nSelect an action:"
        Write-Host "  1. Install Smart RTL Patch (Full Hebrew Support)" -ForegroundColor White
        Write-Host "  2. Restore Original State (full revert: files + cert + Scheduled Task + state)" -ForegroundColor White
        Write-Host "  3. Create 'Quick Update' Desktop Shortcut" -ForegroundColor Green
        Write-Host "  4. Enable Auto Re-Patch After Each Claude Update (Background Service)" -ForegroundColor Green
        Write-Host "  5. Disable Auto Re-Patch Service (only removes Scheduled Task; use 2 for full cleanup)" -ForegroundColor White
        Write-Host "  6. Exit" -ForegroundColor White

        $choice = Read-Host "`nEnter your choice (1/2/3/4/5/6)"

        if ($choice -eq '1' -or $choice -eq '2') {
            Write-Host "`nWARNING: This will automatically close Claude Desktop and its background services." -ForegroundColor Yellow
            if ($choice -eq '2') {
                Write-Host "Restore will: revert app.asar / claude.exe / cowork-svc.exe from validated .bak files," -ForegroundColor Yellow
                Write-Host "             remove the auto-update Scheduled Task," -ForegroundColor Yellow
                Write-Host "             remove the patcher's self-signed certificate from My/Root/TrustedPublisher," -ForegroundColor Yellow
                Write-Host "             restore WindowsApps ACLs, and clean state files in ProgramData." -ForegroundColor Yellow
            }
            $confirm = Read-Host "Do you want to continue? (Y/n)"
            if ($confirm -eq 'n' -or $confirm -eq 'N') {
                Write-Host "Operation cancelled."
                Start-Sleep -Seconds 2
                continue
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
            return
        }
        elseif ($choice -eq '3') {
            Create-UpdateShortcut
            Write-Host "`nPress Enter to return to menu..."
            $null = Read-Host
        }
        elseif ($choice -eq '4') {
            try { Install-AutoUpdateTask } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
            Write-Host "`nPress Enter to return to menu..."
            $null = Read-Host
        }
        elseif ($choice -eq '5') {
            try { Uninstall-AutoUpdateTask } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
            Write-Host "`nPress Enter to return to menu..."
            $null = Read-Host
        }
        elseif ($choice -eq '6') { return }
        # else: invalid input — fall through and redraw the menu.
    }
}

# Start the application
if ($Auto) {
    Write-Host "`n=======================================================" -ForegroundColor Cyan
    Write-Host "  AUTO RE-PATCH MODE (triggered by Claude update)" -ForegroundColor Cyan
    Write-Host "=======================================================`n" -ForegroundColor Cyan
    $exitCode = 0
    try {
        Install-Patch
    } catch {
        Write-Host "`n[!] Auto patch failed: $($_.Exception.Message)" -ForegroundColor Red
        $exitCode = 1
    }

    # Auto mode is invoked by the Scheduled Task on logon — the user is not
    # interactively watching this window. Read-Host would block the spawned
    # PowerShell forever (the task uses -NoExit-style behaviour via -File).
    # Sleep briefly so any toast/log output is visible, then exit cleanly.
    Write-Host "`nClosing in 8 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 8
    Exit $exitCode
} else {
    Show-Menu
}
