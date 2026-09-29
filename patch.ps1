<#
.SYNOPSIS
    Claude Desktop Smart RTL Patcher & Service Fixer
.DESCRIPTION
    Injects smart RTL support into Claude Desktop without breaking English/Code.
    Handles ASAR repackaging, executable hash patching, and cowork-svc binary certificate swapping.
    Strictly uses PURE BYTE-ARRAY manipulation matching the original Python script.
#>
param(
    [switch]$Auto,
    [string]$TrustedPubKey,
    [Alias('ArabicScriptFont')]
    [string]$CustomFont,
    [string]$CustomFontScope
)

# Env-var fallback for `irm | iex` invocations where param binding is not possible.
if (-not $Auto -and $env:CLAUDE_RTL_AUTO -eq '1') { $Auto = $true }
if (-not $CustomFont -and $env:CLAUDE_RTL_CUSTOM_FONT) { $CustomFont = $env:CLAUDE_RTL_CUSTOM_FONT }
if (-not $CustomFont -and $env:CLAUDE_RTL_ARABIC_FONT) { $CustomFont = $env:CLAUDE_RTL_ARABIC_FONT }
if (-not $CustomFontScope -and $env:CLAUDE_RTL_CUSTOM_FONT_SCOPE) { $CustomFontScope = $env:CLAUDE_RTL_CUSTOM_FONT_SCOPE }

# Passed as a PARAMETER, not an env var: env vars don't survive the UAC elevation
# boundary. Mirror it into the env var the rest of the script reads.
if ($TrustedPubKey) { $env:CLAUDE_RTL_TRUSTED_PUBKEY = $TrustedPubKey }

# -----------------------------------------------------------------------------
# AUTO-ELEVATION: Request Administrator Privileges Automatically
# Supports both file execution and irm|iex piped execution
# -----------------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    # -CustomFont/-CustomFontScope would be lost across the update.ps1/install.ps1
    # delegation (parameters aren't forwarded and env vars don't survive the UAC
    # boundary), so stage them in HKCU -- shared with the elevated same-user child,
    # which consumes and deletes them. HKCU is standard-user-writable, so the staged
    # values are treated as UNTRUSTED and sanitized before they touch the payload.
    if ($CustomFont -or $CustomFontScope) {
        try {
            New-Item -Path 'HKCU:\Software\ClaudeRtlPatch' -Force | Out-Null
            if ($CustomFont)      { Set-ItemProperty -Path 'HKCU:\Software\ClaudeRtlPatch' -Name 'CustomFontPending' -Value $CustomFont }
            if ($CustomFontScope) { Set-ItemProperty -Path 'HKCU:\Software\ClaudeRtlPatch' -Name 'CustomFontScopePending' -Value $CustomFontScope }
        } catch {
            Write-Host "Could not stage -CustomFont for the elevated run: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    # Prefer the local verified-update helper (written admin-only at install time):
    # it verifies patch.ps1 against the pinned pubkey before elevation. Falling back
    # to the unsigned install.ps1 is acceptable only for first-time bootstrap.
    $LocalUpdate = Join-Path $env:ProgramData "ClaudeRtlPatch\update.ps1"
    if (Test-Path $LocalUpdate) {
        if ($Auto) { $env:CLAUDE_RTL_AUTO = '1' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LocalUpdate
        Exit
    }
    # First-install bootstrap: no local pin yet. TOFU on install.ps1 (same exposure
    # as `irm install.ps1 | iex`). PS 5.1 defaults to TLS 1.0; GitHub needs 1.2+.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $InstallUrl = "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main/install.ps1"
    if ($Auto) { $env:CLAUDE_RTL_AUTO = '1' }
    Invoke-Expression (Invoke-RestMethod $InstallUrl)
    Exit
}

# -----------------------------------------------------------------------------
# GLOBAL SETTINGS & RTL JS PAYLOAD
# -----------------------------------------------------------------------------
$ErrorActionPreference = "Stop"
Import-Module Microsoft.PowerShell.Security -ErrorAction SilentlyContinue
$global:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude_rtl_patch_tmp"

# Pinned npm packages (C4 mitigation). Bump by hand after reviewing the upstream
# changelog -- never 'latest'.
$script:AsarPackage  = '@electron/asar@4.2.0'
$script:FusesPackage = '@electron/fuses@2.1.1'
# Minimum Node the pinned packages run on (both declare engines.node >=22.12.0).
# Keep in sync when bumping; drives the precise "upgrade Node" error message.
$script:MinNodeVersion = '22.12.0'

# Exact JS logic from r.js
$RTL_INJECTION_CODE = @'
// --- CLAUDE RTL PATCH START ---
;(function() {
    'use strict';
    if (typeof document === 'undefined') return;
    // Once-per-window guard. The payload is prepended to EVERY renderer chunk and a
    // window loads many; without this each would register its own observer/listener.
    if (window.__claudeRtlInit) return;
    window.__claudeRtlInit = true;
    try {
        var WRITING_SEL = '[data-testid="chat-input"]';

        // Never mutate DOM a live editor owns (issue #33): ProseMirror reverts foreign
        // mutations, re-firing our observer into an infinite loop. WRITING_SEL alone is
        // brittle (the testid can change), so we detect editors by their nature. Not a
        // bare [contenteditable]: that matches contenteditable="false" widgets too.
        var EDITOR_SEL = WRITING_SEL + ', [contenteditable="true"], [contenteditable=""], [contenteditable="plaintext-only"], .ProseMirror, [role="textbox"]';

        // --- NATIVE RTL INTEROP (claude.ai "alluvium" renderer) ---
        // claude.ai stamps dir="rtl|ltr" on markdown blocks natively (first-strong over
        // the first 80 chars incl. inline code/URLs; lists by first item, tables by first
        // header cell). Cells, list items, user messages, inputs and UI chrome get none.
        //
        // Ownership rule: every dir the patch sets carries MANAGED_FLAG. A dir WITHOUT it
        // is native and is NEVER removed or reset (React re-stamps on each re-render;
        // fighting it garbles the page). The patch overrides native dir only via the
        // code-aware confident layers, and freely fills the gaps native leaves.
        var MANAGED_FLAG = 'data-rtl-managed';
        var NATIVE_DIR_SEL = '[dir]:not([' + MANAGED_FLAG + '])';
        // Streaming markdown host: frontier blocks re-render continuously, so structural
        // work (math islands) waits for quiet.
        var STREAM_HOST_SEL = '[data-alluvium]';

        // Optional custom text font (issue #39). patch.ps1 splices a sanitized,
        // locally-installed family name over the placeholder at patch time ('' = off),
        // plus a scope: 'arabic' | 'hebrew' | 'all' (which glyphs the font covers).
        // The guards keep unreplaced placeholders from leaking into live values.
        var CUSTOM_FONT = '__RTL_CUSTOM_FONT__';
        if (CUSTOM_FONT.indexOf('__') === 0) CUSTOM_FONT = '';
        var CUSTOM_FONT_SCOPE = '__RTL_CUSTOM_FONT_SCOPE__';
        if (CUSTOM_FONT_SCOPE.indexOf('__') === 0) CUSTOM_FONT_SCOPE = 'arabic';

        function isNativeDir(el) {
            return el.hasAttribute('dir') && !el.hasAttribute(MANAGED_FLAG);
        }

        // True when el sits under a native-dir'd ancestor (or is one). <html>/<body> are
        // excluded: on a Hebrew-locale OS claude.ai stamps dir="rtl" on the ROOT (a
        // page-wide default), and treating that as native ownership no-ops every guard.
        function inNativeDirSubtree(el) {
            var host = el.closest ? el.closest(NATIVE_DIR_SEL) : null;
            return !!(host && host !== document.documentElement && host !== document.body);
        }

        function stampDir(el, dir) {
            el.setAttribute(MANAGED_FLAG, '1');
            el.dir = dir;
            el.style.direction = dir;
        }

        function unstampDir(el) {
            if (el.hasAttribute('dir')) el.removeAttribute('dir');
            el.removeAttribute(MANAGED_FLAG);
            el.style.direction = '';
        }

        // --- PURE DETECTION CORE (inlined from src/rtl-core.js by build-payload.ps1) ---
        // rtl-core.js -- pure, DOM-free RTL/LaTeX detection logic.
//
// SOURCE OF TRUTH for the detection engine. tools/build-payload.ps1 inlines this
// file into the injected IIFE inside patch.ps1 (stripping the module.exports guard
// at the bottom); test/rtl-core.test.js requires it directly. Keep it DOM-free.
'use strict';

// Strong-RTL code-point ranges, [lo, hi] inclusive. Covers living RTL scripts plus
// common historic/astral ones and the explicit RTL bidi controls (RLM/RLE/RLO/RLI),
// matching claude.ai's native detector. Tested against code points (codePointAt),
// not UTF-16 code units, so astral blocks like Adlam work.
var RTL_RANGES = [
    [0x0590, 0x05FF], // Hebrew
    [0x0600, 0x06FF], // Arabic
    [0x0700, 0x074F], // Syriac
    [0x0750, 0x077F], // Arabic Supplement
    [0x0780, 0x07BF], // Thaana
    [0x07C0, 0x07FF], // NKo
    [0x0800, 0x083F], // Samaritan
    [0x0840, 0x085F], // Mandaic
    [0x0860, 0x086F], // Syriac Supplement
    [0x0870, 0x089F], // Arabic Extended-B
    [0x08A0, 0x08FF], // Arabic Extended-A
    [0x200F, 0x200F], // Right-to-Left Mark (RLM)
    [0x202B, 0x202B], // Right-to-Left Embedding (RLE)
    [0x202E, 0x202E], // Right-to-Left Override (RLO)
    [0x2067, 0x2067], // Right-to-Left Isolate (RLI)
    [0xFB1D, 0xFB4F], // Hebrew presentation forms
    [0xFB50, 0xFDFF], // Arabic presentation forms-A
    [0xFE70, 0xFEFF], // Arabic presentation forms-B
    [0x10800, 0x1083F], // Cypriot Syllabary block (incl. early RTL scripts)
    [0x10840, 0x1085F], // Imperial Aramaic
    [0x10A00, 0x10A5F], // Kharoshthi
    [0x10E60, 0x10E7F], // Rumi Numeral Symbols
    [0x1E800, 0x1E8DF], // Mende Kikakui
    [0x1E900, 0x1E95F], // Adlam
    [0x1EE00, 0x1EEFF]  // Arabic Mathematical Alphabetic Symbols
];

function isRTL(cp) {
    for (var i = 0; i < RTL_RANGES.length; i++) {
        if (cp >= RTL_RANGES[i][0] && cp <= RTL_RANGES[i][1]) return true;
    }
    return false;
}

function hasRTL(text) {
    if (!text) return false;
    for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        if (isRTL(cp)) return true;
        i += cp > 0xFFFF ? 2 : 1;
    }
    return false;
}

// Direction of the first strong character: 'rtl', 'ltr', or null (no strong char).
function firstStrong(text) {
    if (!text) return null;
    for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        if (isRTL(cp)) return 'rtl';
        // ASCII Latin letters are strong-LTR.
        if ((cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)) return 'ltr';
        i += cp > 0xFFFF ? 2 : 1;
    }
    return null;
}

// Majority script: strong-RTL code points vs Latin letters. Last-resort tie-breaker
// when first-strong says LTR but RTL characters exist -- an English sentence quoting
// a Hebrew word stays LTR; a Hebrew paragraph opening with a Latin run flips RTL.
function rtlMajority(text) {
    if (!text) return false;
    var r = 0, l = 0;
    for (var i = 0; i < text.length;) {
        var cp = text.codePointAt(i);
        if (isRTL(cp)) r++;
        else if ((cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)) l++;
        i += cp > 0xFFFF ? 2 : 1;
    }
    return r > l;
}

// Remove leading LTR-only noise (filenames, URLs, paths, backtick-code) so a Hebrew
// sentence that starts with "foo.js" still detects as RTL.
function stripLeadingLTR(text) {
    return text
        .replace(/^[\s]*(?:[\w.\-]+\.[\w]{1,5})\s*/g, '')
        .replace(/https?:\/\/\S+/g, '')
        .replace(/[\w.\-]+[\/\\][\w.\-\/\\]+/g, '')
        .replace(/`[^`]+`/g, '');
}

// A "$...$" body is math only with a real LaTeX signal (currency guard: "$5.99" stays text).
var LATEX_SIGNAL = /[\\^_{}]|\b(?:frac|sqrt|sum|prod|int|lim|infty|cdot|times|div|leq|geq|neq|approx|partial|nabla|alpha|beta|gamma|delta|theta|lambda|mu|pi|sigma|omega|matrix|begin|end|left|right|text|mathbb|mathcal|vec|hat|bar|overline|underline)\b/;

function hasLatexSignal(body) {
    return LATEX_SIGNAL.test(body);
}

// Find math regions as [start, end) index pairs. Unambiguous delimiters
// ($$...$$, \[...\], \(...\)) always count; single $...$ only with a LaTeX signal
// and only outside already-claimed regions.
function findLatexRanges(text) {
    var ranges = [];
    if (!text) return ranges;

    function claim(re, requireSignal, bodyStart, bodyEnd) {
        var m;
        re.lastIndex = 0;
        while ((m = re.exec(text)) !== null) {
            var start = m.index;
            var end = m.index + m[0].length;
            if (overlaps(start, end)) continue;
            if (requireSignal) {
                var body = m[0].slice(bodyStart, m[0].length - bodyEnd);
                if (!hasLatexSignal(body)) continue;
            }
            ranges.push([start, end]);
        }
    }
    function overlaps(s, e) {
        for (var i = 0; i < ranges.length; i++) {
            if (s < ranges[i][1] && e > ranges[i][0]) return true;
        }
        return false;
    }

    // Claim the unambiguous, greedier delimiters first.
    claim(/\$\$[\s\S]+?\$\$/g, false, 0, 0);
    claim(/\\\[[\s\S]+?\\\]/g, false, 0, 0);
    claim(/\\\([\s\S]+?\\\)/g, false, 0, 0);
    claim(/\$[^$\n]+?\$/g, true, 1, 1); // single $...$: no newline, must carry a LaTeX signal

    ranges.sort(function (a, b) { return a[0] - b[0]; });
    return ranges;
}

// --- BARE NUMERIC / ARITHMETIC ISOLATION ---
// Claude often writes arithmetic without LaTeX delimiters ("2 + 3 = 5"); inside an
// RTL paragraph the bidi algorithm mirrors it to "5 = 3 + 2". findMathRanges marks
// such runs so the DOM can isolate them LTR.
//
// Operator characters proving a run is a genuine expression. Built with
// String.fromCharCode so the SOURCE stays pure ASCII (patch.ps1 is BOM-less and
// PowerShell 5.1 corrupts non-ASCII source bytes); '-' is escaped for the regex
// class. Codes: U+00D7 U+00F7 U+00B1 U+2212 U+2264 U+2265 U+2260 U+2248 U+2192
// U+00B7 U+2022 U+2219 U+2217 U+22C5 U+221A.
var MATH_OP_CHARS = '+\\-*/=<>%' + String.fromCharCode(
    0xD7, 0xF7, 0xB1, 0x2212, 0x2264, 0x2265, 0x2260,
    0x2248, 0x2192, 0xB7, 0x2022, 0x2219, 0x2217, 0x22C5, 0x221A);
var MATH_OP_RE  = new RegExp('[' + MATH_OP_CHARS + ']');
var MATH_DIGIT_RE = /[0-9]/;
// A token is "mathy" when built only from digits and math punctuation/operators, OR
// it is a single Latin variable letter (x, y, n). Multi-letter Latin tokens (words,
// "3D", "4K") break a run and keep prose out of the island.
var MATH_TOKEN_RE = new RegExp('^(?:[0-9.,:;()\\[\\]{}|' + MATH_OP_CHARS + ']+|[A-Za-z])$');

function isMathyToken(tok) {
    return !!tok && MATH_TOKEN_RE.test(tok);
}

// A token may BOUND a run only if it carries an operand (a digit or single Latin
// variable letter). Pure operator/punctuation tokens sit inside but never bound it.
function isOperandToken(tok) {
    return MATH_DIGIT_RE.test(tok) || /^[A-Za-z]$/.test(tok);
}

// Find bare numeric/arithmetic runs as [start, end) pairs. A run must be
// whitespace/line delimited, operand-bounded, and contain a digit AND an operator.
// Lone numbers, "$5", Hebrew-glued constructs, dates/IPs, and "1." list markers are
// left alone.
function findMathRanges(text) {
    var ranges = [];
    if (!text || !MATH_OP_RE.test(text) || !MATH_DIGIT_RE.test(text)) return ranges;

    // Scan line by line so a run never spans a newline (each line is its own bidi
    // paragraph). `base` is the absolute offset of the current line.
    var base = 0;
    var lines = text.split('\n');
    for (var li = 0; li < lines.length; li++) {
        scanLine(lines[li], base);
        base += lines[li].length + 1; // +1 for the '\n' removed by split
    }
    return ranges;

    function scanLine(line, off) {
        var toks = [];
        var re = /\S+/g;
        var m;
        while ((m = re.exec(line)) !== null) {
            toks.push({ v: m[0], start: m.index, end: m.index + m[0].length });
        }
        var i = 0;
        while (i < toks.length) {
            if (!isMathyToken(toks[i].v)) { i++; continue; }
            var j = i;
            while (j + 1 < toks.length && isMathyToken(toks[j + 1].v)) j++;
            // Trim non-operand tokens off both ends so the run is operand-bounded.
            var a = i, b = j;
            while (a <= b && !isOperandToken(toks[a].v)) a++;
            while (b >= a && !isOperandToken(toks[b].v)) b--;
            if (a <= b) {
                var s = off + toks[a].start;
                var e = off + toks[b].end;
                // Drop sentence punctuation clinging to the ends.
                while (e > s && '.,:;'.indexOf(text.charAt(e - 1)) !== -1) e--;
                while (e > s && ',:;'.indexOf(text.charAt(s)) !== -1) s++;
                var sub = text.slice(s, e);
                if (e - s >= 2 && MATH_DIGIT_RE.test(sub) && MATH_OP_RE.test(sub)) {
                    ranges.push([s, e]);
                }
            }
            i = j + 1;
        }
    }
}

// Split text into alternating {type:'text'|'math', value} segments. 'math' covers
// LaTeX islands and bare arithmetic; the DOM layer isolates both LTR. LaTeX wins
// when the two overlap.
function segmentText(text) {
    var segs = [];
    if (!text) return segs;
    var ranges = findLatexRanges(text);
    var numeric = findMathRanges(text);
    for (var n = 0; n < numeric.length; n++) {
        var ns = numeric[n][0], ne = numeric[n][1], clash = false;
        for (var c = 0; c < ranges.length; c++) {
            if (ns < ranges[c][1] && ne > ranges[c][0]) { clash = true; break; }
        }
        if (!clash) ranges.push(numeric[n]);
    }
    if (!ranges.length) {
        segs.push({ type: 'text', value: text });
        return segs;
    }
    ranges.sort(function (a, b) { return a[0] - b[0]; });
    var pos = 0;
    for (var i = 0; i < ranges.length; i++) {
        if (ranges[i][0] > pos) {
            segs.push({ type: 'text', value: text.slice(pos, ranges[i][0]) });
        }
        segs.push({ type: 'math', value: text.slice(ranges[i][0], ranges[i][1]) });
        pos = ranges[i][1];
    }
    if (pos < text.length) segs.push({ type: 'text', value: text.slice(pos) });
    return segs;
}

// Classify a table cell's direction. A cell is RTL if it *contains* any RTL char
// (header labels often start with a Latin term yet belong to a Hebrew column, so
// first-strong is too weak here). Neutral cells return null so they don't sway
// the majority.
function cellDir(text) {
    if (hasRTL(text)) return 'rtl';
    if (firstStrong(text) === 'ltr') return 'ltr';
    return null;
}

// Decide a table's column direction from header / first-column cell dirs (each an
// array of 'rtl'|'ltr'|null). Header wins; first column is the tie-breaker.
// Returns 'rtl' (flip columns) or null (leave LTR).
function tableDirFromCells(headerDirs, firstColDirs) {
    // First header is the semantic key column: if it and the first data cell are
    // both RTL, it's a Hebrew table regardless of Latin names in later headers.
    if (headerDirs && headerDirs[0] === 'rtl' &&
            firstColDirs && firstColDirs[0] === 'rtl') return 'rtl';
    var h = majorityDir(headerDirs || []);
    if (h === 'rtl') return 'rtl';
    if (h === 'ltr') return null;
    var c = majorityDir(firstColDirs || []);
    return c === 'rtl' ? 'rtl' : null;
}

function majorityDir(dirs) {
    var r = 0, l = 0;
    for (var i = 0; i < dirs.length; i++) {
        if (dirs[i] === 'rtl') r++;
        else if (dirs[i] === 'ltr') l++;
    }
    if (r > l) return 'rtl';
    if (l > r) return 'ltr';
    return null;
}
        // --- END PURE DETECTION CORE ---

        // Text of an element excluding <code>/<pre> children.
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

        // --- PER-LINE DIRECTIONAL SPLITTING ---
        // A paragraph with <br>/newline separators may carry multiple lines in different
        // scripts; forcing one dir mangles the disagreeing lines. We defer to
        // unicode-bidi:plaintext and flag data-rtl-split so later passes skip it.
        var RTL_SPLIT_FLAG = 'data-rtl-split';
        var BR_OR_NL_SPLIT = /(<br\s*\/?>|\n)/i;

        function hasMultiScriptLines(el) {
            var src = el.textContent;
            if (!src) return false;
            if (!/[a-zA-Z]{2,}/.test(src)) return false;
            if (!hasRTL(src)) return false;
            return BR_OR_NL_SPLIT.test(el.innerHTML) || src.indexOf('\n') !== -1;
        }

        function splitToDirectionalSpans(el) {
            if (el.hasAttribute(RTL_SPLIT_FLAG)) return;
            // No DOM rewriting -- assigning innerHTML broke React reconciliation. Defer to
            // unicode-bidi:plaintext: each line (a bidi paragraph) auto-picks its direction
            // from first-strong. Only a patch-owned dir may be removed; a native dir stays
            // (plaintext neutralizes it anyway).
            el.setAttribute(RTL_SPLIT_FLAG, '1');
            if (!isNativeDir(el)) unstampDir(el);
            el.style.direction = '';
            el.style.textAlign = 'start';
            el.style.unicodeBidi = 'plaintext';
        }

        // If RTL is inherited via a parent CSS class (not an explicit dir on the element),
        // removing dir alone won't free it -- pin direction=ltr. Never touches a native dir.
        function resetDirOrPinLTR(el) {
            if (isNativeDir(el)) return;
            if (window.getComputedStyle(el).direction === 'rtl') {
                stampDir(el, 'ltr');
                return;
            }
            unstampDir(el);
        }

        // --- HYBRID DIRECTION DETECTION ---

        // For DOM elements (output): 3-layer detection.
        function detectElDir(el) {
            var full = el.textContent || '';
            if (!hasRTL(full)) return null;

            // Layer 1: first-strong on text excluding <code> children.
            var noCode = textWithoutCode(el);
            var d = firstStrong(noCode);
            if (d === 'rtl') return 'rtl';

            // Layer 2: strip leading filenames/URLs, then first-strong.
            var stripped = stripLeadingLTR(noCode);
            d = firstStrong(stripped);
            if (d === 'rtl') return 'rtl';

            // Layer 3: RTL chars exist but first-strong still says LTR after stripping --
            // majority script decides.
            return rtlMajority(noCode) ? 'rtl' : null;
        }

        // Majority first-strong over a list's items: confident enough to overrule a native
        // list dir (which is judged by the FIRST item only).
        function listConfidentDir(el) {
            var dirs = [];
            for (var i = 0; i < el.children.length; i++) {
                var li = el.children[i];
                if (li.tagName !== 'LI') continue;
                var t = textWithoutCode(li);
                var d = firstStrong(t);
                if (d !== 'rtl') d = firstStrong(stripLeadingLTR(t)) || d;
                dirs.push(d || null);
            }
            return majorityDir(dirs);
        }

        // For plain text (input box, dialogs without DOM structure).
        function detectTextDir(text) {
            if (!text || !text.trim()) return null;
            var d = firstStrong(text);
            if (d === 'rtl') return 'rtl';
            if (!hasRTL(text)) return 'ltr';

            var stripped = stripLeadingLTR(text);
            d = firstStrong(stripped);
            if (d === 'rtl') return 'rtl';

            return rtlMajority(text) ? 'rtl' : 'ltr';
        }

        // --- ELEMENT PROCESSING ---

        // querySelectorAll that INCLUDES root itself if it matches.
        function qsa(root, sel) {
            var base = root.querySelectorAll ? root : document;
            var els = Array.from(base.querySelectorAll(sel));
            if (root.matches && root.matches(sel)) els.unshift(root);
            return els;
        }

        function forceCodeLTR(root) {
            // Inside editors the stylesheet already pins pre/code/katex LTR; stamping here
            // would fight ProseMirror (issue #33).
            qsa(root, 'pre, .code-block__code, .relative.group\\/copy').forEach(function(b) {
                if (b.closest(EDITOR_SEL)) return;
                stampDir(b, 'ltr'); b.style.textAlign = 'left'; b.style.unicodeBidi = 'embed';
            });
            qsa(root, 'code').forEach(function(c) {
                if (c.closest(EDITOR_SEL)) return;
                if (!c.closest('pre') && !c.closest('.code-block__code')) stampDir(c, 'ltr');
            });
            qsa(root, '.katex, .katex-display, mjx-container').forEach(function(m) {
                if (m.closest(EDITOR_SEL)) return;
                m.style.unicodeBidi = 'isolate'; m.style.direction = 'ltr';
            });
        }

        // --- RAW LaTeX + BARE-ARITHMETIC ISOLATION ---
        // Claude Desktop (Windows) shows raw "$...$" text, and inside an RTL paragraph the
        // neutral $ \ { } chars scramble formulas while bare arithmetic gets mirrored. We
        // isolate each math segment (per segmentText) in its own ltr/isolate span via
        // replaceChild -- never innerHTML -- to stay gentle on React, flagging islands so
        // we never re-wrap during streaming.
        var ISLAND_FLAG = 'data-rtl-island';

        // While a stream host is actively mutating, replaceChild is clobbered each tick.
        // Islands there wait for a quiet window; the observer schedules a catch-up pass.
        var lastStreamMut = 0;
        var STREAM_QUIET_MS = 500;

        function inActiveStream(el) {
            if (!el.closest || !el.closest(STREAM_HOST_SEL)) return false;
            return (Date.now() - lastStreamMut) < STREAM_QUIET_MS;
        }

        function isolateMath(root) {
            if (typeof document.createTreeWalker !== 'function') return;
            var host = (root && root.nodeType === 1) ? root : document.body;
            if (!host) return;
            var walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT, {
                acceptNode: function(node) {
                    var v = node.nodeValue;
                    if (!v) return NodeFilter.FILTER_REJECT;
                    // Cheap pre-filter: a LaTeX hint ($ or \) OR a numeric hint (digit AND operator).
                    var hasTex = v.indexOf('$') !== -1 || v.indexOf('\\') !== -1;
                    var hasNum = MATH_DIGIT_RE.test(v) && MATH_OP_RE.test(v);
                    if (!hasTex && !hasNum) return NodeFilter.FILTER_REJECT;
                    var p = node.parentElement;
                    if (!p) return NodeFilter.FILTER_REJECT;
                    if (p.tagName === 'SCRIPT' || p.tagName === 'STYLE') return NodeFilter.FILTER_REJECT;
                    // EDITOR_SEL (not WRITING_SEL): replaceChild on a text node the user is
                    // typing into ignited the issue #33 freeze loop.
                    if (p.closest('pre, code, .code-block__code, [' + ISLAND_FLAG + '], ' + EDITOR_SEL)) return NodeFilter.FILTER_REJECT;
                    if (inActiveStream(p)) return NodeFilter.FILTER_REJECT; // defer to settle pass
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            // Collect first -- mutating during the walk invalidates the walker.
            var targets = [];
            var n;
            while ((n = walker.nextNode())) targets.push(n);
            targets.forEach(function(textNode) {
                var segs = segmentText(textNode.nodeValue);
                var hasMath = segs.some(function(s) { return s.type === 'math'; });
                if (!hasMath) return;
                var frag = document.createDocumentFragment();
                segs.forEach(function(s) {
                    if (s.type === 'math') {
                        var span = document.createElement('span');
                        span.setAttribute(ISLAND_FLAG, '1');
                        span.style.unicodeBidi = 'isolate';
                        span.style.direction = 'ltr';
                        span.textContent = s.value;
                        frag.appendChild(span);
                    } else {
                        frag.appendChild(document.createTextNode(s.value));
                    }
                });
                if (textNode.parentNode) textNode.parentNode.replaceChild(frag, textNode);
            });
        }

        // --- TABLE COLUMN ORDERING ---
        // A Hebrew table should read RTL (first column on the right). Per-cell direction is
        // handled by processText; here we only flip column order via dir="rtl" on a stable
        // <table>, and only once confident it's a Hebrew table.
        var TABLE_FLAG = 'data-rtl-table';

        function processTables(root) {
            qsa(root, 'table').forEach(function(t) {
                if (t.getAttribute(TABLE_FLAG) === 'rtl') return;
                if (t.closest(EDITOR_SEL)) return;
                // Native flip: claude.ai stamps dir on the table's wrapper div. If columns
                // already flow RTL under a native dir, adopt it -- only per-cell work remains.
                if (inNativeDirSubtree(t) && getComputedStyle(t).direction === 'rtl') {
                    t.setAttribute(TABLE_FLAG, 'rtl');
                    return;
                }
                var headerCells = Array.from(t.querySelectorAll('thead th'));
                if (!headerCells.length) {
                    var firstRow = t.querySelector('tr');
                    if (firstRow) headerCells = Array.from(firstRow.querySelectorAll('th, td'));
                }
                var headerDirs = headerCells.map(function(c) { return cellDir(c.textContent || ''); });
                var rows = Array.from(t.querySelectorAll('tbody tr'));
                if (!rows.length) rows = Array.from(t.querySelectorAll('tr')).slice(1);
                var firstColDirs = rows.map(function(r) {
                    var cell = r.querySelector('th, td');
                    return cell ? cellDir(cell.textContent || '') : null;
                });
                if (tableDirFromCells(headerDirs, firstColDirs) === 'rtl') {
                    // Native missed this one -- flip the <table> itself (stamped, never the wrapper).
                    t.setAttribute(TABLE_FLAG, 'rtl');
                    stampDir(t, 'rtl');
                }
            });
        }

        function processText(root) {
            // Standard text elements
            qsa(root, 'p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd').forEach(function(el) {
                if (el.closest(EDITOR_SEL) || el.closest('pre') || el.closest('.code-block__code')) return;
                if (el.hasAttribute(RTL_SPLIT_FLAG)) return;
                if (isNativeDir(el)) {
                    // Native already directed this block. Add only what native cannot
                    // express; never remove or downgrade its dir. Multi-script lines first,
                    // for either native dir: native gives the whole block one dir, so a
                    // Hebrew quote whose first line is a Latin marker renders backwards.
                    if (hasRTL(el.textContent || '') && hasMultiScriptLines(el)) {
                        splitToDirectionalSpans(el);
                    } else if (el.getAttribute('dir') !== 'rtl' &&
                               detectElDir(el) === 'rtl') {
                        // Disagreement (code-prefixed or Latin-first Hebrew): override.
                        stampDir(el, 'rtl');
                    }
                    if (el.getAttribute('dir') === 'rtl' && el.tagName === 'LI') {
                        el.style.listStylePosition = 'inside';
                    }
                    return;
                }
                var dir = detectElDir(el);
                if (dir) {
                    if (dir === 'rtl' && hasMultiScriptLines(el)) {
                        splitToDirectionalSpans(el);
                        return;
                    }
                    stampDir(el, dir);
                    if (el.tagName === 'LI') {
                        el.style.listStylePosition = (dir === 'rtl') ? 'inside' : '';
                        var parentList = el.closest('ul, ol');
                        if (parentList && dir === 'rtl' && !parentList.hasAttribute('dir')) {
                            stampDir(parentList, 'rtl');
                            var pl = getComputedStyle(parentList).paddingLeft;
                            if (parseFloat(pl) > 0) { parentList.style.paddingRight = pl; parentList.style.paddingLeft = '0'; }
                        }
                    }
                } else {
                    resetDirOrPinLTR(el);
                    if (el.tagName === 'LI') el.style.listStylePosition = '';
                }
            });

            // Lists
            qsa(root, 'ul, ol').forEach(function(el) {
                if (el.closest(EDITOR_SEL) || el.closest('pre')) return;
                if (isNativeDir(el)) {
                    // Native judges a list by its FIRST item only. Overrule ltr only on a
                    // confident majority of item dirs.
                    if (el.getAttribute('dir') !== 'rtl' &&
                            listConfidentDir(el) === 'rtl') {
                        stampDir(el, 'rtl');
                        var npl = getComputedStyle(el).paddingLeft;
                        if (parseFloat(npl) > 0) { el.style.paddingRight = npl; el.style.paddingLeft = '0'; }
                    }
                    return;
                }
                var dir = detectElDir(el);
                if (dir === 'rtl') {
                    stampDir(el, 'rtl');
                    var pl = getComputedStyle(el).paddingLeft;
                    if (parseFloat(pl) > 0) { el.style.paddingRight = pl; el.style.paddingLeft = '0'; }
                } else {
                    resetDirOrPinLTR(el);
                    el.style.paddingRight = ''; el.style.paddingLeft = '';
                }
            });
        }

        // Universal: process ANY leaf text container (dialogs, tooltips, etc.)
        function processContainers(root) {
            qsa(root, 'div, span, button, a, label').forEach(function(el) {
                if (el.closest('pre') || el.closest('code') || el.closest(EDITOR_SEL)) return;
                // A subtree under native dir control is native's problem space: its inline
                // spans are React-owned and the block dir already resolves them.
                if (inNativeDirSubtree(el)) return;
                if (el.hasAttribute(RTL_SPLIT_FLAG)) return;
                if (el.hasAttribute(ISLAND_FLAG)) return;
                var parent = el.parentElement;
                if (parent && parent.hasAttribute(RTL_SPLIT_FLAG)) return;
                if (el.querySelector('p, div, ul, ol, h1, h2, h3, h4, h5, h6, pre, table')) return;
                if (/^(P|LI|H[1-6]|BLOCKQUOTE|TD|TH|UL|OL)$/.test(el.tagName)) return;
                var text = (el.textContent || '').trim();
                if (text.length < 2) return;
                if (hasRTL(text)) {
                    if (hasMultiScriptLines(el)) {
                        splitToDirectionalSpans(el);
                    } else {
                        stampDir(el, detectTextDir(text) || 'rtl');
                        el.style.textAlign = 'start';
                    }
                } else if (el.hasAttribute('dir')) {
                    unstampDir(el);
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
            isolateMath(document.body);
            processText(document);
            processContainers(document.body);
            processTables(document.body);
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
                // Raw LaTeX islands and rendered math are isolated LTR units.
                '[data-rtl-island]{unicode-bidi:isolate!important;direction:ltr!important}',
                '.katex,.katex-display,mjx-container{unicode-bidi:isolate!important;direction:ltr!important}',
                // Hebrew tables: flip column order; cells keep their own direction.
                'table[dir="rtl"]{direction:rtl!important}',
                // Scoped to patch-owned dirs: native-dir'd blocks have their own layout
                // children (word-fade spans) that a blanket plaintext rule disturbs.
                '[data-rtl-managed][dir]{text-align:start!important}[data-rtl-managed][dir="rtl"]{direction:rtl!important}[data-rtl-managed][dir="ltr"]{direction:ltr!important}',
                '[data-rtl-managed][dir]>*:not([dir]):not(pre):not(code):not(.code-block__code){unicode-bidi:plaintext;text-align:start}',
                // RTL: flip sidebar truncation gradient to fade the LEFT edge (issue #7).
                '[dir="rtl"][class*="mask-image:linear-gradient(to_right"]{-webkit-mask-image:linear-gradient(to left,hsl(var(--always-black)) 85%,transparent 99%)!important;mask-image:linear-gradient(to left,hsl(var(--always-black)) 85%,transparent 99%)!important}',
                '.group:hover [dir="rtl"][class*="mask-image:linear-gradient(to_right"],.group:focus-within [dir="rtl"][class*="mask-image:linear-gradient(to_right"],[data-menu-open="true"] [dir="rtl"][class*="mask-image:linear-gradient(to_right"]{-webkit-mask-image:linear-gradient(to left,hsl(var(--always-black)) 60%,transparent 78%)!important;mask-image:linear-gradient(to left,hsl(var(--always-black)) 60%,transparent 78%)!important}'
            ].join('');
            document.head.appendChild(s);
        }

        // Route glyphs in CUSTOM_FONT_SCOPE to CUSTOM_FONT without touching any other
        // script. @font-face + local() (+ unicode-range for the script-limited scopes)
        // defines a scoped family that silently no-ops when the font isn't installed.
        // To win over claude.ai's own stacks WITHOUT overriding its font variables
        // (fragile; the reason PR #19's approach was rejected), every same-origin
        // font-family declaration is re-declared verbatim in a shadow stylesheet with
        // the scoped family prepended -- appended last so source order settles the
        // tie. Idempotent; re-run as the SPA's split CSS chunks arrive.
        function injectCustomFont() {
            if (!CUSTOM_FONT || !document.head || !document.body) return;
            var FAM = 'claude-rtl-custom';
            var RANGES = {
                arabic: 'U+0600-06FF,U+0750-077F,U+08A0-08FF,U+FB50-FDFF,U+FE70-FEFF',
                hebrew: 'U+0590-05FF,U+FB1D-FB4F'
            };
            // 'all' (or anything unknown) -> no unicode-range: the face covers every
            // glyph the font supplies; glyphs it lacks fall through to the next family.
            var range = RANGES[CUSTOM_FONT_SCOPE] || '';
            var css = [];

            // Weight-specific faces via full + PostScript names (the static-TTF naming
            // convention Vazirmatn and most families follow). A missing name just makes
            // local() fail and the browser synthesize from the closest weight.
            [['', 'Regular', '400'], [' Medium', 'Medium', '500'],
             [' SemiBold', 'SemiBold', '600'], [' Bold', 'Bold', '700']].forEach(function(w) {
                css.push('@font-face{font-family:"' + FAM + '";src:local("' + CUSTOM_FONT + w[0] +
                    '"),local("' + CUSTOM_FONT + '-' + w[1] + '");font-weight:' + w[2] +
                    (range ? ';unicode-range:' + range : '') + '}');
            });

            // Baseline for text that gets its stack purely by inheritance from <body>.
            // Strip our own family before re-reading, or re-runs would stack it up.
            var base = '';
            try { base = getComputedStyle(document.body).fontFamily || ''; } catch (e) {}
            base = base.replace(new RegExp('^\\s*["\']?' + FAM + '["\']?\\s*,\\s*'), '');
            if (base && !/mono/i.test(base)) css.push('body{font-family:"' + FAM + '",' + base + '}');

            function scanRules(rules, prefix, suffix) {
                for (var i = 0; i < rules.length; i++) {
                    var r = rules[i];
                    if (r.type === 1 && r.selectorText && r.style) {
                        var ff = r.style.getPropertyValue('font-family');
                        if (!ff || ff.indexOf(FAM) !== -1) continue;
                        // A mono stack must stay mono even for Arabic glyphs inside
                        // code; icon/math faces map codepoints privately.
                        if (/mono|icon|katex|emoji|math/i.test(ff)) continue;
                        var bang = r.style.getPropertyPriority('font-family') ? ' !important' : '';
                        css.push(prefix + r.selectorText + '{font-family:"' + FAM + '",' + ff + bang + '}' + suffix);
                    } else if (r.cssRules && r.cssRules.length && typeof r.conditionText === 'string') {
                        var at = (r.type === 12 ? '@supports ' : '@media ') + r.conditionText;
                        scanRules(r.cssRules, prefix + at + '{', '}' + suffix);
                    }
                }
            }
            for (var si = 0; si < document.styleSheets.length; si++) {
                var sheet = document.styleSheets[si];
                if (sheet.ownerNode && sheet.ownerNode.id === 'claude-rtl-custom-font') continue;
                var rules;
                try { rules = sheet.cssRules; } catch (e) { continue; } // cross-origin
                if (rules) scanRules(rules, '', '');
            }

            var text = css.join('');
            var el = document.getElementById('claude-rtl-custom-font');
            if (!el) {
                el = document.createElement('style');
                el.id = 'claude-rtl-custom-font';
            }
            // (Re-)append so the shadow sheet stays behind late-loaded chunk CSS.
            if (el.textContent !== text || el.nextSibling) {
                el.textContent = text;
                document.head.appendChild(el);
            }
        }

        function init() {
            injectStyles();
            if (CUSTOM_FONT) {
                injectCustomFont();
                // The SPA's stylesheets stream in after DOMContentLoaded; re-scan on a
                // tapering schedule instead of observing (cheap, self-terminating).
                [1500, 4000, 10000, 25000].forEach(function(d) { setTimeout(injectCustomFont, d); });
                if (document.fonts && document.fonts.ready && document.fonts.ready.then) {
                    document.fonts.ready.then(function() { injectCustomFont(); });
                }
            }
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

            // Watch DOM changes (throttle, not debounce -- process DURING streaming)
            var pendingMuts = [];

            // Structural loop-breaker (issue #33): a freeze loop needs "editor mutation ->
            // schedule -> write into editor -> editor mutation". Dropping editor-internal
            // records at intake cuts that chain at its first link.
            function mutInsideEditor(m) {
                var t = m.target;
                var el = (t && t.nodeType === 1) ? t : (t ? t.parentElement : null);
                return !!(el && el.closest && el.closest(EDITOR_SEL));
            }

            function mutInsideStream(m) {
                var t = m.target;
                var el = (t && t.nodeType === 1) ? t : (t ? t.parentElement : null);
                return !!(el && el.closest && el.closest(STREAM_HOST_SEL));
            }

            // One-shot settle pass: after a stream host goes quiet, run the deferred math
            // isolation over it (islands skipped mid-stream).
            var settleTimer = null;
            function scheduleStreamSettle() {
                lastStreamMut = Date.now();
                if (settleTimer) clearTimeout(settleTimer);
                settleTimer = setTimeout(function() {
                    settleTimer = null;
                    document.querySelectorAll(STREAM_HOST_SEL).forEach(function(h) {
                        isolateMath(h);
                    });
                }, STREAM_QUIET_MS + 100);
            }

            var obs = new MutationObserver(function(muts) {
                var relevant = [];
                var touchedStream = false;
                for (var i = 0; i < muts.length; i++) {
                    var m = muts[i];
                    if (m.addedNodes.length === 0 && m.type !== 'characterData') continue;
                    if (mutInsideEditor(m)) continue;
                    if (!touchedStream && mutInsideStream(m)) touchedStream = true;
                    relevant.push(m);
                }
                if (touchedStream) scheduleStreamSettle();
                if (!relevant.length) return;
                for (var j = 0; j < relevant.length; j++) pendingMuts.push(relevant[j]);
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
                    var expanded = new Set(roots);
                    roots.forEach(function(r) {
                        if (!r.closest) return;
                        var txt = r.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd');
                        if (txt) expanded.add(txt);
                        var list = r.closest('ul, ol');
                        if (list) expanded.add(list);
                        var tbl = r.closest('table');
                        if (tbl) expanded.add(tbl);
                    });
                    roots = expanded;
                    if (roots.size > 0 && roots.size <= 30) {
                        roots.forEach(function(r) {
                            isolateMath(r);
                            processText(r);
                            processContainers(r);
                            processTables(r);
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

// --- CLAUDE PATCH WELCOME BANNER START ---
;(function() {
    'use strict';
    try {
        if (typeof document === 'undefined' || typeof localStorage === 'undefined') return;
        var FLAG_KEY = 'claude-rtl-patch-welcomed';
        // Tie the banner to the Claude version in the UA, so it shows once per
        // release (the saved flag stops matching) with no manual bump.
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

            function dismiss() {
                localStorage.setItem(FLAG_KEY, VERSION);
                bar.remove();
                document.removeEventListener('click', dismiss, true);
            }
            document.addEventListener('click', dismiss, true);
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', show);
        } else { show(); }
    } catch(e) { console.error('[Claude Welcome Banner]', e); }
})();
// --- CLAUDE PATCH WELCOME BANNER END ---
'@

# Main-process snippet (NOT renderer): forces Chromium's UI direction to LTR, fixing
# the native preview window jumping left and title-bar control placement on RTL OS
# locales (Chromium otherwise draws native child windows with WS_EX_LAYOUTRTL).
# Injected at the top of the main entry (index.pre.js) before app 'ready'. Kept tiny
# and DOM-free to avoid interfering with MCP startup (#14).
$MAIN_INJECTION_CODE = @'
// --- CLAUDE RTL MAIN PATCH START ---
;(function(){
    try {
        if (global.__claudeRtlMainPatched) return;
        global.__claudeRtlMainPatched = true;
        var app = require('electron').app;
        if (app && app.commandLine && typeof app.commandLine.appendSwitch === 'function') {
            app.commandLine.appendSwitch('force-ui-direction', 'ltr');
        }
    } catch (e) { try { console.error('[Claude RTL Main]', e); } catch (_) {} }
})();
// --- CLAUDE RTL MAIN PATCH END ---
'@

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------
# Persistent log -- captures every patch run (incl. silent auto-update runs).
$global:PatchLogFile = Join-Path $env:ProgramData "ClaudeRtlPatch\patch.log"

function Write-LogToFile($level, $msg) {
    try {
        $dir = Split-Path -Parent $global:PatchLogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Rotate at 1 MB to keep the file readable. One generation of history is enough.
        if ((Test-Path $global:PatchLogFile) -and (Get-Item $global:PatchLogFile).Length -gt 1MB) {
            Move-Item $global:PatchLogFile "$global:PatchLogFile.old" -Force
        }
        "$([DateTime]::Now.ToString('o'))  [$level] $msg" |
            Out-File -Append -FilePath $global:PatchLogFile -Encoding UTF8
    } catch {}
}

function Write-Log($msg)     { Write-Host "  [*] $msg" -ForegroundColor Cyan;    Write-LogToFile 'INFO' $msg }
function Write-Step($msg)    { Write-Host "`n► $msg" -ForegroundColor Magenta;   Write-LogToFile 'STEP' $msg }
function Write-Success($msg) { Write-Host "  [+] $msg" -ForegroundColor Green;   Write-LogToFile 'OK'   $msg }
function Write-Warn($msg)    { Write-Host "  [!] $msg" -ForegroundColor Yellow;  Write-LogToFile 'WARN' $msg }

# Pure Binary Search equivalent to Python's bytearray.find().
function Find-Bytes([byte[]]$Haystack, [byte[]]$Needle, [int]$StartIndex = 0) {
    # Fast path: convert both arrays to byte-preserving ISO-8859-1 strings and delegate
    # to native String.IndexOf, replacing a slow byte-by-byte PowerShell loop.
    if ($Needle -eq $null -or $Needle.Length -eq 0 -or $Haystack -eq $null -or $Haystack.Length -lt $Needle.Length) { return -1 }
    if ($StartIndex -lt 0) { $StartIndex = 0 }
    if ($StartIndex -gt ($Haystack.Length - $Needle.Length)) { return -1 }
    $enc = [System.Text.Encoding]::GetEncoding(28591)  # ISO-8859-1 / Latin-1, byte-preserving
    $hayStr = $enc.GetString($Haystack)
    $needleStr = $enc.GetString($Needle)
    return $hayStr.IndexOf($needleStr, $StartIndex, [System.StringComparison]::Ordinal)
}

# Finds EVERY occurrence of $Needle, emitting percentage progress as it sweeps. Beats
# looping Find-Bytes on two counts: it can tick "% scanned" between chunks, and it
# converts each byte to a string once instead of re-converting the whole array per
# match. Chunks overlap by ($Needle.Length - 1) so a boundary-straddling needle is
# still found; matches are counted only in their primary region, never twice.
function Find-AllBytesWithProgress {
    param(
        [byte[]]$Haystack,
        [byte[]]$Needle,
        [scriptblock]$OnProgress,
        [int]$ChunkSize = 16777216   # 16 MB
    )
    $indices = New-Object System.Collections.Generic.List[int]
    if ($null -eq $Needle -or $Needle.Length -eq 0 -or $null -eq $Haystack -or $Haystack.Length -lt $Needle.Length) {
        return $indices
    }
    $enc       = [System.Text.Encoding]::GetEncoding(28591)  # ISO-8859-1, byte-preserving
    $needleStr = $enc.GetString($Needle)
    $overlap   = $Needle.Length - 1
    $total     = $Haystack.Length
    $pos       = 0
    while ($pos -lt $total) {
        $len     = [Math]::Min($ChunkSize + $overlap, $total - $pos)
        $chunk   = $enc.GetString($Haystack, $pos, $len)
        $from    = 0
        while ($true) {
            $rel = $chunk.IndexOf($needleStr, $from, [System.StringComparison]::Ordinal)
            if ($rel -eq -1) { break }
            # Accept only matches starting in the primary region [0, ChunkSize); a match
            # in the trailing overlap is counted by the next chunk instead.
            if ($rel -ge $ChunkSize) { break }
            $indices.Add($pos + $rel)
            $from = $rel + $Needle.Length
        }
        $pos += $ChunkSize
        if ($OnProgress) {
            $pct = [Math]::Min(100, [int](100.0 * $pos / $total))
            & $OnProgress $pct
        }
    }
    return $indices
}

# -----------------------------------------------------------------------------
# AUTO-UPDATE STATE: shared with the watcher Scheduled Task
# -----------------------------------------------------------------------------
$global:RtlStateDir  = Join-Path $env:ProgramData "ClaudeRtlPatch"
$global:RtlStateFile = Join-Path $global:RtlStateDir "state.json"
$global:RtlTaskName  = "ClaudeRtlPatchWatcher"
# Bump when the watcher body or its task triggers change. The body carries a
# matching "# watcher-format: N" line; auto-mode re-registers the task when the
# on-disk watcher lacks it, since auto re-patches don't rewrite watcher.ps1.
$global:RtlWatcherFormat = 2

# -----------------------------------------------------------------------------
# OPTIONAL CUSTOM TEXT FONT (issue #39)
# -----------------------------------------------------------------------------
$script:CustomFontFile     = Join-Path $global:RtlStateDir 'custom-font.txt'
$script:CustomFontLegacy   = Join-Path $global:RtlStateDir 'arabic-font.txt'
$script:CustomFontStageKey = 'HKCU:\Software\ClaudeRtlPatch'
# Letters/digits/spaces/hyphens only, max 63 chars: admits every real family name
# while excluding quotes, backslashes and braces, so the name spliced into the JS
# payload cannot escape the string literal it lands in.
$script:CustomFontNameRe   = '^[A-Za-z0-9][A-Za-z0-9 \-]{0,62}$'
# The scope is spliced into the payload too, so it gets the same whitelisting.
$script:CustomFontScopeRe  = '^(all|arabic|hebrew)$'
$script:CustomFontScopeDesc = @{ all = 'all text'; arabic = 'Arabic/Persian text only'; hebrew = 'Hebrew text only' }

function Get-CustomFontConfig {
    # Persisted config: line 1 = family name, line 2 = scope. The v1 file
    # (arabic-font.txt, name only, implicit arabic scope) is migrated on read.
    if (-not (Test-Path $script:CustomFontFile) -and (Test-Path $script:CustomFontLegacy)) {
        try {
            $legacy = ([System.IO.File]::ReadAllText($script:CustomFontLegacy)).Trim()
            if ($legacy -match $script:CustomFontNameRe) { Save-CustomFontConfig $legacy 'arabic' }
            Remove-Item -LiteralPath $script:CustomFontLegacy -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    $cfg = @{ Name = ''; Scope = '' }
    if (Test-Path $script:CustomFontFile) {
        try {
            $lines = @([System.IO.File]::ReadAllLines($script:CustomFontFile))
            if ($lines.Count -ge 1 -and $lines[0].Trim() -match $script:CustomFontNameRe)  { $cfg.Name  = $lines[0].Trim() }
            if ($lines.Count -ge 2 -and $lines[1].Trim() -imatch $script:CustomFontScopeRe) { $cfg.Scope = $lines[1].Trim().ToLowerInvariant() }
            if (-not $cfg.Name) { Write-Warn "Persisted custom-font config is invalid; ignoring it." }
        } catch { }
    }
    return $cfg
}

function Save-CustomFontConfig([string]$name, [string]$scope) {
    if (-not (Test-Path $global:RtlStateDir)) { New-Item -ItemType Directory -Path $global:RtlStateDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($script:CustomFontFile, "$name`n$scope", [System.Text.UTF8Encoding]::new($false))
}

# Resolves the custom font for this run: explicit -CustomFont/-CustomFontScope beat
# values staged in HKCU by a pre-elevation invocation, which beat the per-machine
# config persisted in the protected state dir (what keeps the choice across auto
# re-patches after Claude updates). 'none' clears the persisted config. Returns
# @{ Name; Scope } with Name = '' when the feature is off. Every source --
# including the persisted file -- is validated before use.
function Resolve-CustomFont {
    $name  = $script:CustomFont
    $scope = $script:CustomFontScope
    $src   = '-CustomFont parameter'

    if (-not $name) {
        try {
            $name = (Get-ItemProperty -Path $script:CustomFontStageKey -Name 'CustomFontPending' -ErrorAction Stop).CustomFontPending
            $src  = 'pre-elevation staged request'
        } catch { $name = $null }
    }
    if (-not $scope) {
        try {
            $scope = (Get-ItemProperty -Path $script:CustomFontStageKey -Name 'CustomFontScopePending' -ErrorAction Stop).CustomFontScopePending
        } catch { $scope = $null }
    }
    # Consume the stage unconditionally so a stale (or hostile) HKCU value can't
    # flip a later auto re-patch run.
    Remove-ItemProperty -Path $script:CustomFontStageKey -Name 'CustomFontPending', 'CustomFontScopePending' -ErrorAction SilentlyContinue

    if ($scope) {
        if ($scope -imatch $script:CustomFontScopeRe) { $scope = $scope.ToLowerInvariant() }
        else {
            Write-Warn "Ignoring font scope '$scope': must be 'all', 'arabic' or 'hebrew'."
            $scope = $null
        }
    }

    $saved = Get-CustomFontConfig

    if ($name) {
        if ($name -ieq 'none') {
            Remove-Item -LiteralPath $script:CustomFontFile -Force -ErrorAction SilentlyContinue
            Write-Log "Custom font disabled ('none'); persisted config cleared."
            return @{ Name = ''; Scope = 'arabic' }
        }
        if ($name -notmatch $script:CustomFontNameRe) {
            Write-Warn "Ignoring custom font '$name' ($src): only letters, digits, spaces and hyphens are allowed (max 63 chars)."
            $name = $null
        }
    }

    $isNew = [bool]$name -or [bool]$scope
    if (-not $name)  { $name  = $saved.Name }
    if (-not $scope) { $scope = if ($saved.Scope) { $saved.Scope } else { 'arabic' } }
    if (-not $name)  { return @{ Name = ''; Scope = $scope } }

    if ($isNew) {
        try {
            Save-CustomFontConfig $name $scope
            Write-Log "Custom font '$name' (scope: $scope, $src) persisted for future re-patches."
        } catch {
            Write-Warn "Could not persist the custom font choice: $($_.Exception.Message)"
        }
    }
    return @{ Name = $name; Scope = $scope }
}

# Interactive menu flow for the same setting (no flag or env var needed): shows the
# current choice, validates and persists a new one, and offers to re-apply the
# patch immediately (the font only takes effect at injection time).
function Set-CustomFontMenu {
    Write-Host "`n--- Custom Text Font (optional) ---" -ForegroundColor Cyan
    $cfg = Get-CustomFontConfig
    if ($cfg.Name) {
        $curScope = if ($cfg.Scope) { $cfg.Scope } else { 'arabic' }
        Write-Host "Current: $($cfg.Name)  (applies to: $($script:CustomFontScopeDesc[$curScope]))" -ForegroundColor Green
    } else {
        Write-Host "Current: (none - system default fonts)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Renders Claude's text in a font of your choice -- all text, Hebrew only,"
    Write-Host "or Arabic/Persian only. The font must already be installed on this machine."
    Write-Host "E.g. Vazirmatn, the de-facto standard for Persian text:"
    Write-Host "  https://github.com/rastikerdar/vazirmatn/releases" -ForegroundColor Cyan
    Write-Host ""

    # Loop until the name is valid AND looks installed (or the user insists):
    # with the font absent the injected CSS local() never activates, so an
    # uninstalled name is almost always a typo. 'y' overrides for the rare
    # family GDI+ can't see, or an install-the-font-later flow.
    while ($true) {
        $answer = Read-Host "Font family name (e.g. Vazirmatn) / 'none' to disable / Enter to cancel"
        if (-not $answer) { Write-Host "No change."; return }
        $answer = $answer.Trim()

        if ($answer -ieq 'none') {
            Remove-Item -LiteralPath $script:CustomFontFile -Force -ErrorAction SilentlyContinue
            Write-Success "Custom font disabled."
            Write-Host "Re-apply the patch (menu option 1) for this to take effect." -ForegroundColor Yellow
            return
        }
        if ($answer -notmatch $script:CustomFontNameRe) {
            Write-Warn "Invalid name: only letters, digits, spaces and hyphens are allowed (max 63 chars). Try again."
            continue
        }

        # GDI+ sees per-user and machine fonts; weight-suffixed GDI families
        # ("X SemiBold") make this a prefix match. If the check itself fails,
        # give the name the benefit of the doubt.
        $installed = $true
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $fams = (New-Object System.Drawing.Text.InstalledFontCollection).Families
            $installed = [bool]($fams | Where-Object { $_.Name -ieq $answer -or $_.Name -like "$answer *" })
        } catch { }
        if (-not $installed) {
            Write-Warn "'$answer' does not appear to be installed for this user."
            $anyway = Read-Host "Use it anyway? The font won't show until you install it (y/N)"
            if ($anyway -ne 'y' -and $anyway -ne 'Y') { continue }
        }
        break
    }

    Write-Host ""
    Write-Host "Apply the font to which text?"
    Write-Host "  1. Arabic/Persian text only"
    Write-Host "  2. Hebrew text only"
    Write-Host "  3. All text"
    $defNum = switch ($cfg.Scope) { 'hebrew' { '2' } 'all' { '3' } default { '1' } }
    $scope = $null
    while (-not $scope) {
        $pick = Read-Host "Scope (1/2/3) [Enter = $defNum]"
        if (-not $pick) { $pick = $defNum }
        $scope = switch ($pick.Trim()) {
            '1' { 'arabic' } '2' { 'hebrew' } '3' { 'all' }
            default { $null }
        }
        if (-not $scope) { Write-Warn "Please answer 1, 2 or 3." }
    }

    try {
        Save-CustomFontConfig $answer $scope
        Write-Success "Saved: $answer ($($script:CustomFontScopeDesc[$scope]))"
    } catch {
        Write-Warn "Could not save the choice: $($_.Exception.Message)"
        return
    }

    Write-Host "The font takes effect the next time the patch is applied." -ForegroundColor Yellow
    $apply = Read-Host "Apply the patch now? This closes Claude Desktop (Y/n)"
    if ($apply -ne 'n' -and $apply -ne 'N') {
        try { Install-Patch } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}

# -----------------------------------------------------------------------------
# TRUST-ANCHOR DIRECTORY HARDENING
# The auto-update chain reads a pinned pubkey and EXECUTES update.ps1/watcher.ps1
# from $RtlStateDir WITH ELEVATION. Default ProgramData ACLs let standard users
# pre-plant these files (or the dir as a junction) and survive a content-only
# rewrite -- a local privilege escalation. Lock the dir to an explicit,
# non-inherited ACL (Administrators/SYSTEM full, Users read+execute) and
# delete-then-recreate each sensitive file so a planted owner/ACL can't survive.
function Protect-RtlStateDir {
    # Returns $true ONLY if the dir is a real folder owned by Administrators, with
    # inheritance disabled and no Users write. Callers MUST fail closed on $false:
    # writing an elevated-executed script or the pubkey pin into an unverified
    # directory is the exact escalation this guards against.
    $dir = $global:RtlStateDir
    try {
        # A reparse point here is always an attack (redirects the elevated writes to
        # an attacker target). Drop the link only (never touches its target).
        if (Test-Path $dir) {
            $existing = Get-Item -LiteralPath $dir -Force
            if ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-Warn "State dir '$dir' is a reparse point -- removing planted junction/symlink."
                [System.IO.Directory]::Delete($dir, $false)
            }
        }
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        # Reclaim OWNERSHIP FIRST (takeown -- Set-Acl can't, as it never enables
        # SeTakeOwnership), then icacls strips inherited/planted ACEs and installs
        # an explicit ACL by SID (correct on localized Windows). cmd /c isolates stderr.
        cmd.exe /c "takeown /F `"$dir`" /A >nul 2>&1"
        cmd.exe /c "icacls `"$dir`" /inheritance:r /grant:r `"*S-1-5-32-544:(OI)(CI)F`" `"*S-1-5-18:(OI)(CI)F`" `"*S-1-5-32-545:(OI)(CI)RX`" >nul 2>&1"

        # VERIFY and FAIL CLOSED: re-read state from disk (never trust tool exit
        # codes) and reject anything an attacker could still control.
        $chk = Get-Item -LiteralPath $dir -Force
        if ($chk.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Warn "State dir '$dir' is still a reparse point after cleanup -- refusing to trust it."
            return $false
        }
        $acl = Get-Acl -LiteralPath $dir
        $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -ne 'S-1-5-32-544' -and $ownerSid -ne 'S-1-5-18') {
            Write-Warn "State dir '$dir' owner is $ownerSid (not Administrators/SYSTEM) -- refusing to trust it."
            return $false
        }
        if (-not $acl.AreAccessRulesProtected) {
            Write-Warn "State dir '$dir' still inherits ACEs (inheritance not disabled) -- refusing to trust it."
            return $false
        }
        $usersWrite = $acl.Access | Where-Object {
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            ($_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545') -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write)
        }
        if ($usersWrite) {
            Write-Warn "State dir '$dir' still grants Users write access -- refusing to trust it."
            return $false
        }
        return $true
    } catch {
        Write-Warn "Protect-RtlStateDir failed: $($_.Exception.Message)"
        return $false
    }
}

# Deletes any existing (possibly pre-planted) file so the caller's fresh write
# inherits the locked directory ACL. Call AFTER Protect-RtlStateDir locks the dir.
function Remove-PlantedFile([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    } catch {
        Write-Warn "Could not remove existing '$([System.IO.Path]::GetFileName($Path))' before rewrite: $($_.Exception.Message)"
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
    param([Parameter(Mandatory)][string]$InstallPath)
    try {
        if (-not (Protect-RtlStateDir)) {
            Write-Warn "State dir could not be secured; not recording patch state (auto-update will stay disabled)."
            return
        }
        $ver = Get-ClaudeVersionFromPath -Path $InstallPath
        $state = [ordered]@{
            patchedVersion     = if ($ver) { $ver.ToString() } else { $null }
            patchedInstallPath = $InstallPath
            patchedAt          = (Get-Date).ToUniversalTime().ToString("o")
        }
        Remove-PlantedFile $global:RtlStateFile
        $state | ConvertTo-Json | Set-Content -Path $global:RtlStateFile -Encoding UTF8
        Write-Log "Patch state recorded at $global:RtlStateFile (version: $($state.patchedVersion))"
    } catch {
        Write-Warn "Failed to save patch state: $($_.Exception.Message)"
    }
}

function Save-TrustedPubkey {
    # Pins the maintainer's full PUBLIC KEY blob to disk. The auto-update watcher
    # verifies patch.ps1.sig directly against it and never executes install.ps1
    # (unsigned), so a compromised repo can't ship a payload around an untouched
    # pubkey. The value arrives via the CLAUDE_RTL_TRUSTED_PUBKEY env var (not a
    # fresh download) to avoid a TOCTOU race between verification and pin.
    try {
        $pubB64 = $env:CLAUDE_RTL_TRUSTED_PUBKEY
        if (-not $pubB64) {
            Write-Warn "No CLAUDE_RTL_TRUSTED_PUBKEY env var; trusted-pubkey.b64 will not be written."
            Write-Warn "(Auto-update watcher will refuse to run without it -- this is the safe default.)"
            return
        }

        # Validate the blob before pinning; a corrupt env var would break updates.
        try {
            $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pubB64))
            $pubObj  = $pubJson | ConvertFrom-Json
            $null = [Convert]::FromBase64String($pubObj.Modulus)
            $null = [Convert]::FromBase64String($pubObj.Exponent)
        } catch {
            Write-Warn "Trusted pubkey from env var failed to parse ($($_.Exception.Message)). Refusing to pin."
            return
        }

        if (-not (Protect-RtlStateDir)) {
            Write-Warn "State dir could not be secured; refusing to pin the trusted pubkey."
            return
        }
        $pinPath = Join-Path $global:RtlStateDir 'trusted-pubkey.b64'
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        Remove-PlantedFile $pinPath
        [IO.File]::WriteAllText($pinPath, $pubB64, $utf8NoBom)

        # Log a fingerprint for out-of-band cross-checking, without exposing the key blob.
        $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String($pubB64))
        $fp  = ([BitConverter]::ToString($sha)).Replace('-', '').ToLower()
        Write-Log "Trusted pubkey pinned at $pinPath (sha256=$fp)"

        # Clean up the legacy V1 fingerprint-only file (no longer read).
        $legacyFpr = Join-Path $global:RtlStateDir 'trusted-pubkey.fpr'
        if (Test-Path $legacyFpr) {
            Remove-Item $legacyFpr -Force -ErrorAction SilentlyContinue
            Write-Log "Removed legacy V1 pin file: trusted-pubkey.fpr"
        }
    } catch {
        Write-Warn "Save-TrustedPubkey failed: $($_.Exception.Message)"
    }
}

function Save-UpdateScript {
    # Local helper (ProgramData\ClaudeRtlPatch\update.ps1) for the desktop "Update
    # Claude RTL" shortcut. Mirrors the watcher's verify-then-elevate flow against
    # the pinned pubkey, so the only trusted network artifact is patch.ps1 + its sig
    # (never the unsigned install.ps1). Protect-RtlStateDir locks the dir so this
    # elevated-executed helper can't be pre-planted or rewritten by a standard user.
    try {
        if (-not (Protect-RtlStateDir)) {
            Write-Warn "State dir could not be secured; refusing to write the verified-update helper."
            return
        }
        $updatePath = Join-Path $global:RtlStateDir 'update.ps1'

        # Single-quoted here-string: $ signs are preserved literally for runtime evaluation.
        $updateBody = @'
# Claude RTL Patch -- verified local updater.
#
# Loaded by the desktop "Update Claude RTL" shortcut. Uses the pubkey pinned
# at install time to verify patch.ps1 against the maintainer's offline private
# key, then elevates via UAC. install.ps1 is intentionally NOT used here --
# a compromised GitHub repo cannot influence this path.
$ErrorActionPreference = "Continue"
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$stateDir      = Join-Path $env:ProgramData "ClaudeRtlPatch"
$pubkeyPinFile = Join-Path $stateDir "trusted-pubkey.b64"
$repoBase      = "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main"
$patchUrl      = "$repoBase/patch.ps1"
$sigUrl        = "$repoBase/patch.ps1.sig"

function Pause-ThenExit($code) {
    Write-Host ""
    Write-Host "Press Enter to close this window..." -ForegroundColor DarkGray
    $null = Read-Host
    Exit $code
}

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  Claude RTL Patch -- verified update                  " -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $pubkeyPinFile)) {
    Write-Host "No pinned pubkey at $pubkeyPinFile." -ForegroundColor Red
    Write-Host "This computer has not bootstrapped a trust anchor yet." -ForegroundColor Yellow
    Write-Host "Run the manual installer once to fix this:" -ForegroundColor Yellow
    Write-Host "  irm https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main/install.ps1 | iex" -ForegroundColor Cyan
    Pause-ThenExit 1
}

try {
    $pubB64 = (Get-Content $pubkeyPinFile -Raw).Trim()
    if (-not $pubB64) { throw "Pinned pubkey file is empty." }
    $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pubB64))
    $pubObj  = $pubJson | ConvertFrom-Json
    $params = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = [Convert]::FromBase64String($pubObj.Modulus)
    $params.Exponent = [Convert]::FromBase64String($pubObj.Exponent)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($params)
} catch {
    Write-Host "Pinned pubkey is unreadable: $($_.Exception.Message)" -ForegroundColor Red
    Pause-ThenExit 1
}

Write-Host "Downloading patch.ps1 + signature..." -ForegroundColor Gray
try {
    $wc = New-Object System.Net.WebClient
    $patchBytes = $wc.DownloadData($patchUrl)
    $sigB64     = $wc.DownloadString($sigUrl).Trim()
} catch {
    Write-Host "Network error: $($_.Exception.Message)" -ForegroundColor Red
    Pause-ThenExit 1
}

try {
    $sigBytes = [Convert]::FromBase64String($sigB64)
} catch {
    Write-Host "Downloaded signature is not valid base64. Aborting." -ForegroundColor Red
    Pause-ThenExit 1
}

$valid = $rsa.VerifyData($patchBytes, $sigBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

if (-not $valid) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "  SIGNATURE VERIFICATION FAILED -- REFUSING TO RUN patch.ps1     " -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "patch.ps1 does not match the pinned maintainer key." -ForegroundColor Yellow
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  * The GitHub repository was compromised." -ForegroundColor Yellow
    Write-Host "  * The maintainer rotated keys (requires a manual re-install)." -ForegroundColor Yellow
    Write-Host "  * A proxy is intercepting traffic." -ForegroundColor Yellow
    Pause-ThenExit 1
}

# Strip incoming BOM, re-add UTF-8 BOM on write (PS 5.1 needs it to parse patch.ps1).
$tmpFile = Join-Path $env:TEMP "claude_rtl_patch.ps1"
$content = [System.Text.Encoding]::UTF8.GetString($patchBytes)
if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
[System.IO.File]::WriteAllText($tmpFile, $content, [System.Text.UTF8Encoding]::new($true))

Write-Host "Patch verified ($($patchBytes.Length) bytes). Elevating..." -ForegroundColor Green

# Pass the pubkey as a -TrustedPubKey PARAMETER (env vars don't survive the UAC
# boundary) so the child's Save-TrustedPubkey sees the same anchor. AUTO=1 runs
# Install-Patch directly instead of the menu.
$env:CLAUDE_RTL_AUTO = '1'

# Elevate via UAC. Auto mode pauses on Read-Host at the end so the log is readable.
Start-Process -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Verb RunAs `
    -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$tmpFile,'-Auto','-TrustedPubKey',$pubB64
    )
'@

        # PS 5.1 needs UTF-8 with BOM to parse Unicode text correctly.
        Remove-PlantedFile $updatePath
        [System.IO.File]::WriteAllText($updatePath, $updateBody, [System.Text.UTF8Encoding]::new($true))
        Write-Log "Verified-update helper written to $updatePath"
    } catch {
        Write-Warn "Save-UpdateScript failed: $($_.Exception.Message)"
    }
}

function Find-ClaudeDir {
    $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*' } | Select-Object -First 1
    if (-not $pkg) {
        # UAC elevation can switch identity: elevating with a separate admin account
        # hides Claude registered to the invoking user (#34). -AllUsers (needs admin,
        # which we have) recovers it.
        Try {
            # SilentlyContinue: orphaned packages from deleted profiles emit per-entry
            # errors that would abort the pipeline under ErrorActionPreference = Stop.
            $pkg = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*' -and (Test-Path $_.InstallLocation) } |
                Sort-Object -Property { [version]$_.Version } -Descending |
                Select-Object -First 1
            if ($pkg) { Write-Log "Claude package found via -AllUsers fallback (registered to another user account)." }
            else      { Write-Log "-AllUsers fallback ran but found no Claude package either." }
        } Catch {
            Write-Log "Get-AppxPackage -AllUsers fallback failed: $($_.Exception.Message)"
        }
    }
    if ($pkg) { return $pkg.InstallLocation }

    $squirrelPath = Join-Path $env:LOCALAPPDATA "AnthropicClaude"
    if (Test-Path $squirrelPath) {
        Write-Warn "A legacy (Squirrel-based) Claude installation was detected at: $squirrelPath"
        Write-Warn "This version is not supported by the RTL patch."
        Write-Warn "Please uninstall it and install the latest version from: https://claude.ai/download"
        return $null
    }

    return $null
}

# Detects the #34 identity-mismatch: elevation with a separate admin account whose
# identity doesn't own the Claude registration. Returns the console user's DOMAIN\name
# only when BOTH hold: (a) its SID differs from ours (SID compare, since name strings
# can differ for the same account), and (b) Claude is NOT registered to our identity.
# $null otherwise (incl. RDP/service sessions).
function Get-MismatchedConsoleUser {
    Try {
        $consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        if (-not $consoleUser) { return $null }
        $consoleSid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($consoleSid -eq [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { return $null }
        $mine = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*' } | Select-Object -First 1
        if ($mine) { return $null }
        return $consoleUser
    } Catch { return $null }
}

function Stop-ClaudeServices {
    Write-Step "Halting Claude processes and services..."

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

    foreach ($procName in @("claude", "cowork-svc")) {
        $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        if ($procName -eq 'claude') {
            # claude.exe is also the Claude Code CLI. Kill only the desktop app (MSIX
            # folder) and the CLI copies it spawns under %APPDATA%\Claude; a standalone
            # CLI (e.g. ~\.local\bin) in a terminal is left running. Unknown path: kill.
            $procs = @($procs | Where-Object { -not $_.Path -or $_.Path -match '\\WindowsApps\\|\\Claude\\claude-code\\' })
        }
        if ($procs) {
            Write-Log "Killing $($procs.Count) '$procName' process(es)..."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 2
    $remaining = Get-Process -Name "cowork-svc" -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Warn "cowork-svc still running after kill! Waiting 5 more seconds..."
        Start-Sleep -Seconds 5
        Stop-Process -Name "cowork-svc" -Force -ErrorAction SilentlyContinue
    }
    
    Write-Success "Processes and services halted."
}

function Test-FileLock([string]$Path, [string]$Access = 'Write') {
    <#
    .SYNOPSIS
        Returns $true if the file can't be opened for the requested $Access, else $false.
    .PARAMETER Access
        'Read' for read-only ops (e.g. backups); 'Write' for writes (default). The probe
        must match the real op EXACTLY. It mirrors WriteAllBytes/ReadAllBytes sharing
        (FileAccess + FileShare.Read, FileMode.Open non-destructive). FileShare.Read (not
        ReadWrite) is deliberate: WriteAllBytes uses FileShare.Read, so a looser probe
        could pass while the real write fails. A stricter FileShare.None probe caused the
        issue #15 false-positive (AV read-share handle read as LOCKED).
    #>
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', $Access, 'Read')
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

function Wait-FileUnlock([string]$Path, [int]$TimeoutSeconds = 20, [string]$Access = 'Write') {
    <#
    .SYNOPSIS
        Waits until a file can be opened for the requested $Access, or throws after timeout.
    #>
    if (-not (Test-Path $Path)) { return }
    for ($w = 0; $w -lt $TimeoutSeconds; $w++) {
        if (-not (Test-FileLock $Path $Access)) {
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

# Windows Restart Manager: authoritative list of processes/services holding a file
# open (unlike Get-FileHolders, which misses services and module-less handles).
# Advisory only -- names holders in preflight errors.
$script:RmLockTypeLoaded = $false
function Initialize-RmLockType {
    if ($script:RmLockTypeLoaded) { return $true }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RmLock {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;
    enum RM_APP_TYPE { RmUnknownApp=0, RmMainWindow=1, RmOtherWindow=2, RmService=3, RmExplorer=4, RmConsole=5, RmCritical=1000 }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)] public string strServiceShortName;
        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
    public static List<string> GetLockers(string path) {
        var result = new List<string>();
        uint handle; string key = Guid.NewGuid().ToString();
        int res = RmStartSession(out handle, 0, key);
        if (res != 0) throw new Exception("RmStartSession failed: " + res);
        try {
            string[] resources = new string[] { path };
            res = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);
            if (res != 0) throw new Exception("RmRegisterResources failed: " + res);
            uint needed = 0, count = 0, reason = 0;
            res = RmGetList(handle, out needed, ref count, null, ref reason);
            if (res == 234 /*ERROR_MORE_DATA*/) {
                var info = new RM_PROCESS_INFO[needed];
                count = needed;
                res = RmGetList(handle, out needed, ref count, info, ref reason);
                if (res != 0) throw new Exception("RmGetList(2) failed: " + res);
                for (int i = 0; i < count; i++)
                    result.Add(info[i].strAppName + " (PID " + info[i].Process.dwProcessId + ", type " + info[i].ApplicationType + ")");
            } else if (res != 0) {
                throw new Exception("RmGetList(1) failed: " + res);
            }
        } finally { RmEndSession(handle); }
        return result;
    }
}
'@
        $script:RmLockTypeLoaded = $true
        return $true
    } catch {
        # A repeat Add-Type of the same type throws "already exists" -- treat as success;
        # any other failure degrades to no holder list (advisory).
        if ("$($_.Exception.Message)" -match 'already') { $script:RmLockTypeLoaded = $true; return $true }
        Write-Log "Restart Manager unavailable (holder names will be omitted): $($_.Exception.Message)"
        return $false
    }
}

function Get-FileLockers([string]$Path) {
    # Returns @("AppName (PID n, type RmService)", ...) or @(). Never throws.
    try {
        if (-not (Initialize-RmLockType)) { return @() }
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        return [RmLock]::GetLockers($Path)
    } catch {
        return @()
    }
}

function Get-FileWriteStatus([string]$Path) {
    <#
    .SYNOPSIS
        Single-shot classification of a file's writability, for preflight messaging.
        Status: MISSING (file absent) | OK (writable) | DENIED (ACL) | LOCKED (sharing).
        On DENIED/LOCKED also resolves the holding process(es) via Restart Manager.
    #>
    $name = Split-Path $Path -Leaf
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Path = $Path; Name = $name; Status = 'MISSING'; Holders = @() }
    }
    try {
        # Match WriteAllBytes exactly: FileAccess.Write + FileShare.Read, FileMode.Open
        # (non-destructive). See Test-FileLock notes.
        $fs = [System.IO.File]::Open($Path, 'Open', 'Write', 'Read')
        $fs.Close()
        return [pscustomobject]@{ Path = $Path; Name = $name; Status = 'OK'; Holders = @() }
    } catch [System.UnauthorizedAccessException] {
        return [pscustomobject]@{ Path = $Path; Name = $name; Status = 'DENIED'; Holders = (Get-FileLockers $Path) }
    } catch {
        # IOException (sharing violation) and anything else: treat as locked.
        return [pscustomobject]@{ Path = $Path; Name = $name; Status = 'LOCKED'; Holders = (Get-FileLockers $Path) }
    }
}

function Assert-PatchWritable {
    <#
    .SYNOPSIS
        PREFLIGHT: before touching ANY content, verify every write target is writable and
        abort cleanly (install untouched) rather than bricking halfway.
    .NOTES
        - Runs AFTER Stop-ClaudeServices + Take-Ownership (before that the binaries look
          falsely "locked").
        - Bounded wait per target (like Wait-FileUnlock), so it can never block a machine
          the current code would succeed on.
        - Directory checks are WARN-ONLY. Runs before any content change, so worst case is
          "refuses to run", never a corrupted file.
    #>
    param(
        [Parameter(Mandatory)][string[]]$WriteTargets,
        [string[]]$DirTargets = @(),
        [int]$TimeoutSeconds = 15
    )
    Write-Step "Preflight: verifying all patch targets are writable..."

    $blocked = @()
    foreach ($t in $WriteTargets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }   # absent target = nothing to write yet
        $unlocked = $false
        for ($w = 0; $w -lt $TimeoutSeconds; $w++) {
            if (-not (Test-FileLock $t 'Write')) { $unlocked = $true; break }
            if ($w -eq 0) { Write-Log "Preflight waiting on $(Split-Path $t -Leaf)..." }
            Start-Sleep -Seconds 1
        }
        if ($unlocked) {
            Write-Success "Writable: $(Split-Path $t -Leaf)"
        } else {
            $blocked += (Get-FileWriteStatus $t)
        }
    }

    # Directory writability (new .bak/.new files land here) -- WARN ONLY, never aborts.
    foreach ($d in $DirTargets) {
        try {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            $probe = Join-Path $d ("rtl-preflight-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Directory may not be writable (continuing anyway): $d -- $($_.Exception.Message)"
        }
    }

    if ($blocked.Count -gt 0) {
        $lines = foreach ($b in $blocked) {
            $h = if ($b.Holders -and $b.Holders.Count -gt 0) { " -- held by: " + ($b.Holders -join '; ') } else { "" }
            "    [$($b.Status)] $($b.Name)$h"
        }
        throw @"
Preflight failed -- the patch was stopped BEFORE modifying anything (your install is untouched).
These file(s) are not writable right now:
$($lines -join "`n")

How to fix:
  * Reboot and, WITHOUT opening Claude, run the patch again (a scanner/indexer can hold a file right after boot).
  * Temporarily disable real-time antivirus, then re-run.
  * If it persists, reinstall Claude:  Get-AppxPackage *Claude* | Remove-AppxPackage  then reinstall from https://claude.ai/download
"@
    }

    Write-Success "Preflight passed -- all patch targets are writable."
}

function Test-FileValid([string]$Path, [string]$Type) {
    <#
    .SYNOPSIS
        Validates a file is structurally well-formed for its type. $true/$false; never
        throws on a missing/malformed file (callers decide how to react).
    .PARAMETER Type
        'asar' -- parsable Electron ASAR header (Compute-AsarHash succeeds).
        'pe'   -- Windows PE binary: 'MZ' signature and size >= 1 MB.
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
        Atomic file copy with validation: writes "<Dest>.tmp", verifies it matches the
        source (length + optional type check), then renames to <Dest>. On any failure the
        temp is removed and <Dest> is left untouched.
    .PARAMETER ValidateAs
        Optional 'asar' or 'pe'. Test-FileValid runs on the temp before rename; omit to skip.
    .NOTES
        - Falls back to byte-level read/write if Copy-Item fails (issue #4 SCM-locked binary).
        - Source is validated too: a corrupted source must not become a corrupted backup.
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

    # Verify size matches the source -- primary defense against truncated copies.
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

function Start-ClaudeServices {
    Write-Step "Restarting Claude background service..."
    $Started = $false

    # Force-stop and re-kill any lingering process before Start-Service, so the
    # service can't pick up the old binary still mapped in memory.
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

        Stop-Process -Name "cowork-svc" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

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

    Write-Log "Launching Claude Desktop..."
    Try {
        $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' } | Select-Object -First 1
        if ($pkg) {
            $appId = "$($pkg.PackageFamilyName)!Claude"
            Start-Process "shell:AppsFolder\$appId" -ErrorAction Stop
            Write-Success "Claude Desktop launched."
        } else {
            # Elevated identity may differ from Claude's owning account (#34); app
            # activation is per-user, so launching from here isn't possible then.
            Write-Warn "Claude isn't registered to this (elevated) account -- or isn't installed."
            Write-Log "Please start Claude manually from the Start Menu."
        }
    } Catch {
        Write-Warn "Could not launch Claude Desktop: $($_.Exception.Message)"
        Write-Log "Please start Claude manually from the Start Menu."
    }
}

function Take-Ownership($Path) {
    Write-Log "Requesting permissions for: $Path"
    cmd.exe /c "takeown /F `"$Path`" /R /D Y >nul 2>&1"
    cmd.exe /c "icacls `"$Path`" /grant `"*S-1-5-32-544:(OI)(CI)F`" /T /Q >nul 2>&1"
}

function Remove-CertPrivateKey {
    <#
    .SYNOPSIS
        Destroys a certificate's private key and VERIFIES it is gone. Handles RSA *and*
        ECDSA, over CNG or legacy CSP. Matters because the patch's cert may be ECDSA
        (smaller-hole fallback), and an RSA-only wipe would leak the ECDSA key while its
        public cert stays machine-trusted in Root -- a reusable code-signing key.
    .OUTPUTS
        [bool] $true only when no private key remains (verified, or none to begin with);
        $false when a key may still exist or removal can't be confirmed.
    #>
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)

    if (-not $Cert.HasPrivateKey) { return $true }

    # Capture the CNG container name BEFORE deletion (for the fallback delete and the
    # post-delete existence check). Legacy CSP keys don't expose it this way ($null).
    $container = $null
    try {
        $probe = $null
        try { $probe = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert) } catch {}
        if (-not $probe) { try { $probe = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Cert) } catch {} }
        if ($probe -is [System.Security.Cryptography.RSACng])   { $container = $probe.Key.UniqueName }
        elseif ($probe -is [System.Security.Cryptography.ECDsaCng]) { $container = $probe.Key.UniqueName }
    } catch {}

    # Typed deletion: RSA (CNG or legacy CSP) or ECDSA (always CNG).
    $deleted = $false
    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)
        if ($rsa -is [System.Security.Cryptography.RSACng]) {
            $rsa.Key.Delete(); $deleted = $true
        } elseif ($rsa -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
            $rsa.PersistKeyInCsp = $false; $rsa.Clear(); $deleted = $true
        } else {
            $ec = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Cert)
            if ($ec -is [System.Security.Cryptography.ECDsaCng]) {
                $ec.Key.Delete(); $deleted = $true
            }
        }
    } catch {
        Write-Log "Remove-CertPrivateKey: typed delete threw ($($_.Exception.Message)); trying CngKey fallback."
    }

    # Fallback: open the container by name and delete it directly (typed path didn't
    # match a known provider type, but we hold the container name).
    if (-not $deleted -and $container) {
        try {
            $prov = [System.Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider
            $opts = [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey
            if ([System.Security.Cryptography.CngKey]::Exists($container, $prov, $opts)) {
                $ck = [System.Security.Cryptography.CngKey]::Open($container, $prov, $opts)
                $ck.Delete(); $deleted = $true
            }
        } catch {
            Write-Log "Remove-CertPrivateKey: CngKey fallback threw: $($_.Exception.Message)"
        }
    }

    # Verify: if we know the container, it MUST no longer exist -- lets the caller fail
    # loudly instead of trusting a delete that silently no-op'd.
    if ($container) {
        try {
            $prov = [System.Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider
            $opts = [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey
            if ([System.Security.Cryptography.CngKey]::Exists($container, $prov, $opts)) {
                Write-Log "Remove-CertPrivateKey: key container '$container' still exists after delete attempt."
                return $false
            }
            return $true
        } catch {
            # Exists() throwing isn't proof the key survived; fall back to the $deleted signal.
        }
    }
    return $deleted
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
# Alternative bypass path when the byte-level hash replacement can't locate the asar
# hash inside claude.exe (upstream encoding/algorithm/location changed). Split into
# probe + predicate + entry for testability. Never throws -- caller reacts to $false.
# -----------------------------------------------------------------------------

# Pattern matched against `@electron/fuses read` output to detect the disabled state.
$script:AsarFuseDisabledPattern = 'EnableEmbeddedAsarIntegrityValidation[^\r\n]*Disabled'

function Get-FuseProbeOutput {
    param([Parameter(Mandatory)][string]$ExePath)
    $raw = cmd.exe /c "npx --yes $($script:FusesPackage) read --app `"$ExePath`" 2>&1"
    return ($raw | Out-String)
}

function Test-AsarIntegrityFuseDisabled {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ProbeOutput)
    return [bool]($ProbeOutput -match $script:AsarFuseDisabledPattern)
}

function Set-AsarIntegrityFuseOff {
    param([Parameter(Mandatory)][string]$ExePath)
    $raw = cmd.exe /c "npx --yes $($script:FusesPackage) write --app `"$ExePath`" EnableEmbeddedAsarIntegrityValidation=off 2>&1"
    return [pscustomobject]@{ Output = ($raw | Out-String); ExitCode = $LASTEXITCODE }
}

function Invoke-FuseFlip {
    param([Parameter(Mandatory)][string]$ExePath)

    if (-not (Test-Path -LiteralPath $ExePath)) {
        Write-Warn "Invoke-FuseFlip: target not found at $ExePath"
        return $false
    }

    $prevWarn = $env:NODE_NO_WARNINGS
    $env:NODE_NO_WARNINGS = '1'
    try {
        Write-Log "Probing Electron fuse state on $(Split-Path $ExePath -Leaf)..."
        $before = Get-FuseProbeOutput -ExePath $ExePath
        if (Test-AsarIntegrityFuseDisabled -ProbeOutput $before) {
            Write-Success "ASAR integrity fuse already off -- nothing to do."
            return $true
        }

        Write-Log "Disabling ASAR integrity fuse (EnableEmbeddedAsarIntegrityValidation=off)..."
        $write = Set-AsarIntegrityFuseOff -ExePath $ExePath
        if ($write.ExitCode -ne 0) {
            Write-Warn "Fuse write returned non-zero exit ($($write.ExitCode))."
            foreach ($line in $write.Output.Split("`n")) {
                $trimmed = $line.TrimEnd()
                if ($trimmed) { Write-Log "    $trimmed" }
            }
            return $false
        }

        # Re-probe -- some tool builds print "Fuses written" without persisting.
        $after = Get-FuseProbeOutput -ExePath $ExePath
        if (Test-AsarIntegrityFuseDisabled -ProbeOutput $after) {
            Write-Success "Fuse disabled and confirmed via re-probe."
            return $true
        }
        Write-Warn "Fuse write reported success but re-probe still shows Enabled."
        return $false
    }
    catch {
        Write-Warn "Invoke-FuseFlip threw: $($_.Exception.Message)"
        return $false
    }
    finally {
        $env:NODE_NO_WARNINGS = $prevWarn
    }
}

function Create-UpdateShortcut {
    Write-Step "Creating Quick Update Shortcut..."
    Try {
        # Ensure the verified-update helper exists before pointing at it (idempotent).
        Save-UpdateScript

        $WshShell = New-Object -comObject WScript.Shell
        $DesktopPath = [Environment]::GetFolderPath('Desktop')
        # On identity mismatch (#34) this is the ADMIN's desktop, invisible to the user
        # of Claude -- fall back to the Public desktop (visible to all, admin-writable).
        $desktopLabel = "your Desktop"
        if ($env:PUBLIC -and (Get-MismatchedConsoleUser)) {
            $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
            if (Test-Path $publicDesktop) {
                $DesktopPath = $publicDesktop
                $desktopLabel = "the shared Public Desktop (visible to all accounts)"
            }
        }
        $ShortcutPath = Join-Path $DesktopPath "Update Claude RTL.lnk"
        $LocalUpdatePath = Join-Path $global:RtlStateDir 'update.ps1'

        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "powershell.exe"
        # Point at the LOCAL verified-update helper (verifies patch.ps1 via the pinned
        # pubkey), not remote install.ps1 which a hijacked repo could influence.
        $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$LocalUpdatePath`""
        $Shortcut.Description = "Verified update of the Claude Desktop RTL patch"

        $ClaudeDir = Find-ClaudeDir
        if ($ClaudeDir -and (Test-Path (Join-Path $ClaudeDir "app\claude.exe"))) {
            $Shortcut.IconLocation = "$(Join-Path $ClaudeDir "app\claude.exe"),0"
        } else {
            $Shortcut.IconLocation = "powershell.exe,0"
        }

        $Shortcut.Save()
        Write-Success "Shortcut created successfully on ${desktopLabel}: $ShortcutPath"
        Write-Success "It launches the local verified-update helper: $LocalUpdatePath"
    } Catch {
        Write-Warn "Failed to create shortcut: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# AUTO-UPDATE WATCHER (Scheduled Task)
# Written to ProgramData\ClaudeRtlPatch\watcher.ps1 and launched via -File (not
# -EncodedCommand -- the encoded form trips Defender's Trojan:Win32/Goptaju
# heuristic once the body downloads patch.ps1). The watcher only MONITORS for new
# claude.exe versions; when it fires it fetches patch.ps1 LIVE and runs THAT.
# Besides launches it runs a 60s idle check (#40/#42): Claude's updater stages new
# versions with deferred registration, and the outgoing instance can be left behind
# holding the single-instance lock, so no new claude.exe ever appears to react to.
# -----------------------------------------------------------------------------
function Save-WatcherScript {
    try {
        if (-not (Protect-RtlStateDir)) {
            Write-Warn "State dir could not be secured; refusing to write the auto-update watcher."
            return
        }
        $watcherPath = Join-Path $global:RtlStateDir 'watcher.ps1'

        # Single-quoted here-string: $ signs are preserved literally for runtime evaluation inside the watcher.
        $watcherBody = @'
# watcher-format: 2
$ErrorActionPreference = "Continue"
# Scheduled Task PowerShell defaults to TLS 1.0; GitHub needs 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
$stateDir       = Join-Path $env:ProgramData "ClaudeRtlPatch"
$stateFile      = Join-Path $stateDir "state.json"
$logFile        = Join-Path $stateDir "watcher.log"
$lastActionFile = Join-Path $stateDir "last-action.txt"
$pubkeyPinFile  = Join-Path $stateDir "trusted-pubkey.b64"
# ProgramData files written by the elevated installer aren't writable by a standard
# user, so an unelevated watcher (#34) can't append the log. Probe for append access
# and, only on access-denied, move the writable artifacts (log + throttle) to the
# user's LocalAppData; state.json and the pubkey pin stay in ProgramData (read-only).
try {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $probe = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
    $probe.Close()
} catch [System.UnauthorizedAccessException] {
    try {
        $userStateDir = Join-Path $env:LOCALAPPDATA "ClaudeRtlPatch"
        if (-not (Test-Path $userStateDir)) { New-Item -ItemType Directory -Path $userStateDir -Force | Out-Null }
        $logFile        = Join-Path $userStateDir "watcher.log"
        $lastActionFile = Join-Path $userStateDir "last-action.txt"
    } catch {}
} catch {}
# The watcher fetches patch.ps1 + patch.ps1.sig directly and verifies them with the
# locally-pinned pubkey. The unsigned install.ps1 is never used, so the only trusted
# network artifact is patch.ps1, validated byte-for-byte against the offline key.
$repoBase       = "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main"
$patchUrl       = "$repoBase/patch.ps1"
$sigUrl         = "$repoBase/patch.ps1.sig"

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

# Claude Desktop only runs from its MSIX folder (or WindowsApps\Deleted\ right after
# a version is replaced). The Claude Code CLI is ALSO claude.exe -- under
# %APPDATA%\Claude\claude-code\ or ~\.local\bin\ -- and must never match.
function Test-DesktopClaudePath($p) {
    return [bool]($p -and $p -match '\\WindowsApps\\(?:Deleted\\)?Claude_')
}

function Get-DesktopClaude {
    return @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { Test-DesktopClaudePath $_.Path })
}

function Write-WLogOnce($key, $msg) {
    if ($script:LoggedOnce[$key] -eq $msg) { return }
    $script:LoggedOnce[$key] = $msg
    Write-WLog $msg
}

function Get-RegisteredClaude {
    try {
        $pkgs = @(Get-AppxPackage -Name Claude -ErrorAction Stop |
            Where-Object { $_.InstallLocation -like '*\WindowsApps\*' })
        # One package is the steady state. Two means a version switch is in flight
        # (possibly a staged package surfacing before registration): skip this check
        # rather than guess which one is live and kill the running Claude.
        if ($pkgs.Count -gt 1) {
            Write-WLogOnce 'appx' "Idle check skipped: $($pkgs.Count) Claude packages listed ($(($pkgs | ForEach-Object { $_.Version }) -join ', '))."
            return $null
        }
        $script:LoggedOnce.Remove('appx')
        if ($pkgs.Count -eq 0) { return $null }
        return @{
            Version         = [Version]$pkgs[0].Version
            InstallLocation = $pkgs[0].InstallLocation.TrimEnd('\')
            Aumid           = "$($pkgs[0].PackageFamilyName)!Claude"
        }
    } catch {
        Write-WLogOnce 'appx' "Get-AppxPackage failed: $($_.Exception.Message)"
    }
    return $null
}

# Pure decision for one idle check (unit-tested by test/watcher-recovery.check.ps1).
#   Stale    -- desktop claude.exe paths outside the registered package. Once a newer
#               version is registered nothing healthy runs from the old folder, but the
#               leftover keeps Electron's single-instance lock, so every relaunch exits
#               immediately (#40, #42). No Responding heuristic: the path alone decides.
#   Patch    -- the registered version is newer than the patched one while Claude runs
#               (also covers a launch the WITHIN-1 WMI poll missed). Invoke-AutoPatch
#               ends the leftovers too, so Patch takes precedence over Stale.
#   Relaunch -- leftovers were ended and nothing from the registered version runs.
function Get-TickDecision($Registered, [string[]]$ProcPaths, $PatchedVer, [bool]$PatchAllowed) {
    $d = @{ Stale = @(); Patch = $false; Relaunch = $false }
    if (-not $Registered -or -not $Registered.InstallLocation) { return $d }
    $root    = $Registered.InstallLocation.TrimEnd('\') + '\'
    $paths   = @($ProcPaths | Where-Object { $_ })
    $current = @($paths | Where-Object { $_.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
    $stale   = @($paths | Where-Object { -not $_.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
    if ($PatchAllowed -and $PatchedVer -and $Registered.Version -gt $PatchedVer -and $paths.Count -gt 0) {
        $d.Patch = $true
    } elseif ($stale.Count -gt 0) {
        $d.Stale    = $stale
        $d.Relaunch = ($current.Count -eq 0)
    }
    return $d
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

function Get-PinnedRsa {
    # Loads the pinned pubkey and returns an RSA object plus the original base64 blob
    # (so callers can forward it via env var without re-encoding). Used directly to
    # verify patch.ps1.sig; install.ps1 is never consulted.
    try {
        if (-not (Test-Path $pubkeyPinFile)) {
            Write-WLog "No pinned pubkey at $pubkeyPinFile -- refusing to auto-update."
            return $null
        }
        $pubB64 = (Get-Content $pubkeyPinFile -Raw).Trim()
        if (-not $pubB64) {
            Write-WLog "Pinned pubkey file is empty -- refusing to auto-update."
            return $null
        }
        $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pubB64))
        $pubObj  = $pubJson | ConvertFrom-Json
        $params = New-Object System.Security.Cryptography.RSAParameters
        $params.Modulus  = [Convert]::FromBase64String($pubObj.Modulus)
        $params.Exponent = [Convert]::FromBase64String($pubObj.Exponent)
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.ImportParameters($params)
        return @{ Rsa = $rsa; PubB64 = $pubB64 }
    } catch {
        Write-WLog "Get-PinnedRsa error: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-AutoPatch($newVer, $exePath) {
    # Throttle: skip if we acted in the last 90s (avoids loops on Electron startup).
    if (Test-Path $lastActionFile) {
        try {
            $last = [DateTime]::Parse((Get-Content $lastActionFile -Raw))
            if (((Get-Date) - $last).TotalSeconds -lt 90) {
                Write-WLog "Throttled (last action $([int]((Get-Date)-$last).TotalSeconds)s ago)"
                return
            }
        } catch {}
    }
    (Get-Date).ToString('o') | Set-Content $lastActionFile -Encoding UTF8
    $script:PatchAttempted["$newVer"] = $true

    Write-WLog "Detected Claude v$newVer at $exePath -- verifying signature before patching..."

    $pinned = Get-PinnedRsa
    if (-not $pinned) {
        Show-Toast "Claude RTL: auto-update BLOCKED" "Trusted pubkey pin is missing or unreadable. Re-install the patch manually to restore auto-updates."
        return
    }

    # Fetch as raw bytes and verify those directly. The signature is over the
    # LF-normalized bytes the maintainer signed (raw.githubusercontent.com serves LF
    # via .gitattributes); decoding to string first could alter BOMs.
    try {
        $wc = New-Object System.Net.WebClient
        $patchBytes = $wc.DownloadData($patchUrl)
        $sigB64     = $wc.DownloadString($sigUrl).Trim()
    } catch {
        Write-WLog "Download failed: $($_.Exception.Message)"
        Show-Toast "Claude RTL: auto-update failed" "Network error downloading patch. Will retry next launch."
        return
    }

    try {
        $sigBytes = [Convert]::FromBase64String($sigB64)
    } catch {
        Write-WLog "Signature is not valid base64: $($_.Exception.Message)"
        Show-Toast "Claude RTL: auto-update BLOCKED" "Downloaded signature is malformed. Will not run patch."
        return
    }

    $valid = $pinned.Rsa.VerifyData(
        $patchBytes, $sigBytes,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    if (-not $valid) {
        Write-WLog "SIGNATURE MISMATCH on patch.ps1 -- refusing to auto-update."
        Show-Toast "Claude RTL: auto-update BLOCKED" "patch.ps1 does not match the pinned maintainer key. The repo may have been compromised. Re-install manually only after verifying the source out-of-band."
        return
    }

    Write-WLog "Signature verified ($($patchBytes.Length) bytes). Writing temp file and launching patch.ps1..."

    # Write with a UTF-8 BOM (PS 5.1 needs it to parse patch.ps1); strip any incoming
    # BOM first to avoid a double-BOM.
    $tmpFile = Join-Path $env:TEMP 'claude_rtl_patch.ps1'
    $content = [System.Text.Encoding]::UTF8.GetString($patchBytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
    [System.IO.File]::WriteAllText($tmpFile, $content, [System.Text.UTF8Encoding]::new($true))

    # An unelevated watcher (#34) must NOT kill Claude before elevation: the re-patch
    # pauses on a UAC prompt, which without approval leaves a kill-relaunch loop.
    # Elevated watchers keep the snappy kill-first behavior.
    $watcherIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($watcherIsAdmin) {
        Show-Toast "Claude updated to v$newVer" "Auto-patching now. A PowerShell window will open with the patch log."
        Get-DesktopClaude | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process -Name cowork-svc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    } else {
        Show-Toast "Claude updated to v$newVer" "The RTL patch needs re-applying. Please approve the admin (UAC) prompt."
    }

    try {
        # Propagate the pinned pubkey to the child so its Save-TrustedPubkey keeps the
        # SAME anchor. The watcher is elevated (RunLevel Highest), so the spawned child
        # inherits the token without a UAC prompt.
        $env:CLAUDE_RTL_TRUSTED_PUBKEY = $pinned.PubB64
        $env:CLAUDE_RTL_AUTO = '1'
        Start-Process -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $tmpFile,
                '-Auto'
            ) | Out-Null
        Write-WLog "Spawned verified patch.ps1 (file=$tmpFile)"
    } catch {
        Write-WLog "Failed to launch patch.ps1: $($_.Exception.Message)"
        Show-Toast "Auto-patch FAILED to start" "Please run patch.ps1 manually as Administrator. See watcher.log."
    } finally {
        Remove-Item Env:CLAUDE_RTL_AUTO -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_RTL_TRUSTED_PUBKEY -ErrorAction SilentlyContinue
    }
}

function Test-AndPatch($exePath) {
    if (-not $exePath) { return }
    $newVer = Get-VerFromPath $exePath
    if (-not $newVer) { return }
    $patchedVer = Get-PatchedVer
    if (-not $patchedVer) { Write-WLog "No state file; ignoring v$newVer"; return }
    if ($newVer -gt $patchedVer) { Invoke-AutoPatch -newVer $newVer -exePath $exePath }
}

function Test-PatchRunning {
    try {
        return [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*claude_rtl_patch.ps1*' })
    } catch { return $false }
}

function Invoke-IdleCheck {
    $reg = Get-RegisteredClaude
    if (-not $reg) { return }
    $procs = Get-DesktopClaude
    $paths = @($procs | ForEach-Object { $_.Path })
    $patchedVer = Get-PatchedVer
    # One idle-triggered attempt per version per watcher run: a patch that keeps
    # failing must not kill a running Claude every minute. Launches retry as before.
    $allowed = [bool]($patchedVer -and $reg.Version -gt $patchedVer -and $paths.Count -gt 0 -and
        -not $script:PatchAttempted.ContainsKey("$($reg.Version)") -and -not (Test-PatchRunning))
    $d = Get-TickDecision -Registered $reg -ProcPaths $paths -PatchedVer $patchedVer -PatchAllowed $allowed

    if ($d.Patch) {
        Write-WLog "Idle check: Claude v$($reg.Version) is registered and running, patched is v$patchedVer -- re-patching."
        Invoke-AutoPatch -newVer $reg.Version -exePath (Join-Path $reg.InstallLocation 'app\Claude.exe')
        return
    }
    if ($d.Stale.Count -eq 0) { return }

    $stale = @($procs | Where-Object { $d.Stale -contains $_.Path })
    Write-WLogOnce 'stale' "Idle check: claude.exe still running from a replaced package (registered: v$($reg.Version)) -- ending PID $($stale.Id -join ', '): $(($d.Stale | Select-Object -Unique) -join '; ')"
    $stale | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    # A survivor would swallow the relaunch again: don't launch or toast every minute.
    $left = @(Get-DesktopClaude | Where-Object { $d.Stale -contains $_.Path })
    if ($left.Count -gt 0) {
        Write-WLogOnce 'stale-left' "Could not end PID $($left.Id -join ', '); not relaunching. Signing out and back in clears it."
        return
    }
    if (-not $d.Relaunch) { return }
    try {
        Start-Process "shell:AppsFolder\$($reg.Aumid)" -ErrorAction Stop
        Write-WLog "Relaunched Claude ($($reg.Aumid))."
        Show-Toast "Claude restarted after an update" "A leftover process from the previous version was blocking Claude from reopening."
    } catch {
        Write-WLog "Relaunch failed: $($_.Exception.Message)"
    }
}

$script:PatchAttempted = @{}
$script:LoggedOnce     = @{}

Write-WLog "Watcher started (PID $PID, user $env:USERNAME)"
Write-WLog "Currently patched version: $(Get-PatchedVer)"

# Initial sweep -- Claude may already be running a newer version at watcher start.
try {
    $existing = Get-DesktopClaude | Select-Object -First 1
    if ($existing) { Test-AndPatch $existing.Path }
} catch {}

$query = "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name = 'claude.exe'"
Register-CimIndicationEvent -Query $query -SourceIdentifier "ClaudeProcessCreated" | Out-Null
Write-WLog "WMI subscription active; idle check every 60s."

$lastIdleCheck = [DateTime]::MinValue
while ($true) {
    $ev = Wait-Event -SourceIdentifier "ClaudeProcessCreated" -Timeout 60
    if ($null -ne $ev) {
        try {
            $p = $ev.SourceEventArgs.NewEvent.TargetInstance.ExecutablePath
            Test-AndPatch $p
        } catch {
            Write-WLog "Event handler error: $($_.Exception.Message)"
        } finally {
            Remove-Event -EventIdentifier $ev.EventIdentifier
        }
    }
    # A Claude launch raises one event per helper process, so gate on elapsed time.
    if (((Get-Date) - $lastIdleCheck).TotalSeconds -ge 60) {
        $lastIdleCheck = Get-Date
        try { Invoke-IdleCheck } catch { Write-WLog "Idle check error: $($_.Exception.Message)" }
    }
}
'@

        # PS 5.1 needs UTF-8 with BOM to parse Unicode text (Hebrew + toast XML) correctly.
        Remove-PlantedFile $watcherPath
        [System.IO.File]::WriteAllText($watcherPath, $watcherBody, [System.Text.UTF8Encoding]::new($true))
        Write-Log "Watcher script written to $watcherPath"
    } catch {
        Write-Warn "Save-WatcherScript failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# Registers the Scheduled Task that launches the watcher at logon via -File.
# -----------------------------------------------------------------------------
function Install-AutoUpdateTask {
    Write-Step "Installing Auto-Update Watcher (Scheduled Task)..."

    if (-not (Test-Path $global:RtlStateFile)) {
        Write-Warn "No patch state found at $global:RtlStateFile."
        Write-Warn "Run option 1 (Install Smart RTL Patch) first so the watcher knows which version is patched."
        return
    }

    # Pin the pubkey BEFORE registering the task (closes the repo-takeover vector).
    Save-TrustedPubkey

    # Write the watcher to disk; the task launches it via -File (not -EncodedCommand).
    Save-WatcherScript
    $watcherPath = Join-Path $global:RtlStateDir 'watcher.ps1'

    # Save-WatcherScript fails closed if the state dir can't be locked. Never register
    # a task that runs a watcher script from an unverified directory.
    if (-not (Test-Path $watcherPath)) {
        Write-Warn "Watcher script was not written (state dir could not be secured); skipping task registration."
        Write-Warn "The RTL patch itself is applied; only the automatic re-patch on updates is disabled."
        return
    }

    Try {
        $userName  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        # On identity mismatch (#34) GetCurrent() is the admin, who never logs on
        # interactively, so an AtLogOn task registered to it never fires. Register for
        # the console user instead (re-patch goes through the helper's UAC prompt).
        $identityMismatch = $false
        $consoleUser = Get-MismatchedConsoleUser
        if ($consoleUser) {
            $identityMismatch = $true
            $userName = $consoleUser
        }
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherPath`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $userName
        # Re-fire every 15 min for the rest of the session. IgnoreNew makes it a no-op
        # while the watcher runs; if the watcher died (seen: killed during logon with
        # 0xC000013A), it comes back without waiting for the next logon.
        $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 15)).Repetition
        $trigger.Repetition.StopAtDurationEnd = $false
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
        if ($identityMismatch) {
            Write-Success "Registered for $userName (the account that uses Claude), not the admin account running this patch."
            Write-Warn "When Claude updates, a UAC prompt for admin approval will appear before the patch is re-applied."
            Write-Warn "If ProgramData isn't writable for that account, watcher logs land in its LocalAppData\ClaudeRtlPatch instead."
        } else {
            Write-Success "It will run automatically on every logon (and is now active for this session)."
        }
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
        Remove-Item (Join-Path $global:RtlStateDir 'watcher.ps1') -Force -ErrorAction SilentlyContinue
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

    Try {
        $cmdOut = cmd.exe /c "npx --yes $($script:AsarPackage) --version 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "ASAR missing" }
    } Catch {
        # npx probe failed -- two causes: (1) npx unreachable (e.g. a Volta shim broken
        # under the elevated PATH) -- retry with system Node at ProgramFiles\nodejs;
        # (2) Node older than MinNodeVersion, so the pinned packages refuse to run --
        # surface the version and tell the user to upgrade, not "install Node" (#11).
        $sysNodeDir = Join-Path $env:ProgramFiles 'nodejs'
        $ok = $false
        if ((Test-Path (Join-Path $sysNodeDir 'node.exe')) -and `
            (Test-Path (Join-Path $sysNodeDir 'npx.cmd'))) {
            $env:PATH = "$sysNodeDir;$env:PATH"
            Write-Log "npx probe failed; retrying with system Node at $sysNodeDir"
            $cmdOut = cmd.exe /c "npx --yes $($script:AsarPackage) --version 2>&1"
            $ok = ($LASTEXITCODE -eq 0)
        }
        if (-not $ok) {
            # Record npx's real output so the failure is diagnosable from patch.log.
            if ($cmdOut) { Write-Log "npx output: $(($cmdOut | Out-String).Trim())" }

            # Detect the installed Node version to give an accurate error.
            $nodeVer = $null
            try {
                $raw = (cmd.exe /c "node --version 2>&1" | Out-String).Trim()
                if ($raw -match 'v?(\d+)\.(\d+)\.(\d+)') {
                    $nodeVer = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
                }
            } catch {}

            $minVer = [version]$script:MinNodeVersion
            if ($nodeVer -and $nodeVer -lt $minVer) {
                throw ("Node $nodeVer is too old. This patch requires Node " +
                    ">= $($script:MinNodeVersion) (Node $nodeVer is past end-of-life). " +
                    "Please upgrade Node from https://nodejs.org and re-run.")
            } elseif (-not $nodeVer) {
                throw ("Node.js (npx) is required. Please install Node.js " +
                    "(>= $($script:MinNodeVersion)) from https://nodejs.org and re-run.")
            } else {
                throw ("npx could not run $($script:AsarPackage) on Node $nodeVer. " +
                    "See the npx output in the log: $global:PatchLogFile")
            }
        }
    }

    Stop-ClaudeServices
    
    Write-Step "Taking ownership of Claude directories..."
    Take-Ownership $AppDir
    Take-Ownership $ResourcesDir

    # PREFLIGHT: verify every write target is writable before touching content (must run
    # after the ownership grant + service stop above). Aborts cleanly, install untouched.
    Assert-PatchWritable -WriteTargets @($AsarPath, $ExePath, $CoworkSvcPath) `
                         -DirTargets @($ResourcesDir, $AppDir) -TimeoutSeconds 15

    Write-Step "Creating secure backups..."
    # Clean up any orphan .bak.tmp files left by a previously interrupted run.
    foreach ($orphan in @("$AsarPath.bak.tmp", "$ExePath.bak.tmp", "$CoworkSvcPath.bak.tmp")) {
        if (Test-Path -LiteralPath $orphan) { Remove-Item -LiteralPath $orphan -Force -ErrorAction SilentlyContinue }
    }
    # Backup READS these files, so a read-access gate is what matches the operation.
    Wait-FileUnlock -Path $ExePath -TimeoutSeconds 15 -Access Read
    Wait-FileUnlock -Path $CoworkSvcPath -TimeoutSeconds 15 -Access Read
    if (-not (Test-Path "$AsarPath.bak"))      { Copy-FileSafe $AsarPath      "$AsarPath.bak"      'asar'; Write-Success "app.asar.bak created" }
    if (-not (Test-Path "$ExePath.bak") -and (Test-Path $ExePath))             { Copy-FileSafe $ExePath        "$ExePath.bak"        'pe';   Write-Success "claude.exe.bak created" }
    if (-not (Test-Path "$CoworkSvcPath.bak") -and (Test-Path $CoworkSvcPath)) { Copy-FileSafe $CoworkSvcPath  "$CoworkSvcPath.bak"  'pe';   Write-Success "cowork-svc.exe.bak created" }

    # Always restore from backup before patching, so a re-run starts from clean files
    # (first run: .bak equals the live file, so the copy is a no-op). CRITICAL: validate
    # every backup BEFORE overwriting live files -- restoring a corrupt .bak would brick
    # the install, and the rollback path also reads from .bak.
    Write-Step "Ensuring clean state before patching..."
    $RestorePairs = @(
        @{O=$AsarPath;       B="$AsarPath.bak";       T='asar'},
        @{O=$ExePath;        B="$ExePath.bak";        T='pe'},
        @{O=$CoworkSvcPath;  B="$CoworkSvcPath.bak";  T='pe'}
    )
    # Verify ALL existing backups are valid first (all-or-nothing), so a partial restore
    # can't leave claude.exe's embedded asar hash mismatching app.asar.
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

    # Atomic transaction -- any throw below drops to the Catch and triggers Restore-Patch -IsRollback.
    Try {
        Write-Step "Phase 1: ASAR Injection"
        $OldHash = Compute-AsarHash $AsarPath
        Write-Log "Original Hash: $OldHash"

        if (Test-Path $global:TmpDir) { Remove-Item $global:TmpDir -Recurse -Force }
        Write-Log "Extracting ASAR archive (this may take a moment)..."
        cmd.exe /c "npx --yes $($script:AsarPackage) extract `"$AsarPath`" `"$global:TmpDir`""
        if ($LASTEXITCODE -ne 0) {
            throw "asar extract failed with exit code $LASTEXITCODE. Aborting before pack would create an empty archive."
        }

        $BuildDir = Join-Path $global:TmpDir ".vite\build"
        if (Test-Path $BuildDir) {
            # Resolve the main-process entry from package.json "main" (fallback to the
            # known filename). The ENTRY alone gets $MAIN_INJECTION_CODE, NOT the renderer payload.
            $MainEntryFile = 'index.pre.js'
            $PkgJsonPath = Join-Path $global:TmpDir 'package.json'
            if (Test-Path $PkgJsonPath) {
                try {
                    $pkgMain = (Get-Content $PkgJsonPath -Raw | ConvertFrom-Json).main
                    if ($pkgMain) { $MainEntryFile = Split-Path $pkgMain -Leaf }
                } catch { Write-Log "Could not parse package.json 'main'; defaulting entry to '$MainEntryFile'." }
            }
            Write-Log "Main-process entry: $MainEntryFile"

            # Optional custom font (issue #39): splice the sanitized name (or '' when
            # off) and scope over the payload's placeholders. Runtime substitution on
            # the in-memory copy -- the signed patch.ps1 on disk is untouched.
            $FontCfg = Resolve-CustomFont
            if ($FontCfg.Name) {
                Write-Success "Custom font enabled: '$($FontCfg.Name)' for $($script:CustomFontScopeDesc[$FontCfg.Scope]) (must be installed on this machine; disable with -CustomFont none)"
            }
            $RendererInjection = $RTL_INJECTION_CODE.Replace('__RTL_CUSTOM_FONT__', $FontCfg.Name).Replace('__RTL_CUSTOM_FONT_SCOPE__', $FontCfg.Scope)

            # Non-renderer files that must NOT receive the renderer payload (no DOM;
            # injecting risks breaking MCP startup -- #14). index.js is the large main
            # bundle; the rest are Node MCP hosts/workers. All skipped entirely.
            $SkipEntirely = @(
                'index.js',                 # .vite/build/index.js         - large main-process bundle
                'directMcpHost.js',         # .vite/build/mcp-runtime/...  - Node MCP host
                'nodeHost.js',              # .vite/build/mcp-runtime/...  - Node host
                'shellPathWorker.js',       # .vite/build/shell-path-worker/...
                'transcriptSearchWorker.js' # .vite/build/transcript-search-worker/...
            )
            $JsFiles = Get-ChildItem -Path $BuildDir -Filter "*.js" -Recurse
            $Injected = 0
            $MainInjected = 0
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            # A leading "use strict"; must stay the FIRST statement; both branches below
            # insert AFTER it (a bare prepend would demote it to sloppy mode -- #36).
            $strictRe = '^\s*("use strict"|''use strict'')\s*;'
            foreach ($file in $JsFiles) {
                if ($SkipEntirely -contains $file.Name) {
                    Write-Log "Skipped non-renderer file (no DOM): $($file.Name)"
                    continue
                }
                $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

                if ($file.Name -eq $MainEntryFile) {
                    # Main-process entry: inject the Chromium UI-direction switch only,
                    # after "use strict"; (see $strictRe note).
                    if ($content -match "CLAUDE RTL MAIN PATCH START") { continue }
                    if ($content -match $strictRe) {
                        $prologue = $matches[0]
                        $newContent = $prologue + "`n" + $MAIN_INJECTION_CODE + "`n" + $content.Substring($prologue.Length)
                    } else {
                        $newContent = $MAIN_INJECTION_CODE + "`n" + $content
                    }
                    [System.IO.File]::WriteAllText($file.FullName, $newContent, $utf8NoBom)

                    # Fail fast: a syntax error in the ENTRY prevents Claude from starting
                    # and try/catch can't guard a parse error, so validate before repack.
                    cmd.exe /c "node --check `"$($file.FullName)`""
                    if ($LASTEXITCODE -ne 0) {
                        throw "node --check failed on patched main entry '$($file.Name)'. Refusing to repack -- the injected main-process snippet would prevent Claude from starting."
                    }
                    $MainInjected++
                    Write-Log "Injected MAIN switch (force-ui-direction=ltr) into: $($file.Name)"
                    continue
                }

                # Renderer file: inject the RTL/DOM payload after "use strict"; -- a bare
                # prepend demotes the directive to sloppy mode, which flips detached-call
                # `this` to globalThis and broke winston's logger fallback (issue #36).
                if ($content -match "CLAUDE RTL PATCH START") { continue }
                if ($content -match $strictRe) {
                    $prologue = $matches[0]
                    $newContent = $prologue + "`n" + $RendererInjection + "`n" + $content.Substring($prologue.Length)
                } else {
                    $newContent = $RendererInjection + "`n" + $content
                }
                [System.IO.File]::WriteAllText($file.FullName, $newContent, $utf8NoBom)
                $Injected++
                Write-Log "Injected RTL into: $($file.Name)"
            }
            if ($MainInjected -gt 0) { Write-Success "Injected main-process UI-direction switch into $MainInjected file(s)." }
            else { Write-Warn "Main-process entry '$MainEntryFile' not found or already patched." }
            if ($Injected -gt 0) { Write-Success "Injected RTL JS logic into $Injected file(s)." }
            else { Write-Warn "Renderer JS files already patched or not found." }
        }

        $TmpAsarPath = "$AsarPath.new"
        Write-Log "Repacking ASAR archive..."
        cmd.exe /c "npx --yes $($script:AsarPackage) pack `"$global:TmpDir`" `"$TmpAsarPath`""
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $TmpAsarPath) { Remove-Item -LiteralPath $TmpAsarPath -Force -ErrorAction SilentlyContinue }
            throw "asar pack failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-FileValid -Path $TmpAsarPath -Type 'asar')) {
            # Test-FileValid returns a bare $false, so surface WHY the repacked archive
            # is unreadable for patch.log (#26). Each probe is guarded; gather all before
            # deleting the temp.
            Write-Log "Repacked ASAR validation FAILED -- gathering diagnostics:"
            try {
                $diagLen = (Get-Item -LiteralPath $TmpAsarPath -ErrorAction Stop).Length
                Write-Log "  repacked size: $diagLen bytes"
            } catch { Write-Log "  could not stat repacked file: $($_.Exception.Message)" }
            try {
                $fs = [System.IO.File]::OpenRead($TmpAsarPath)
                try {
                    $hdr  = New-Object byte[] 16
                    $read = $fs.Read($hdr, 0, 16)
                    $hex  = (0..($read - 1) | ForEach-Object { $hdr[$_].ToString('X2') }) -join ' '
                    Write-Log "  first $read header bytes (hex): $hex"
                } finally { $fs.Close() }
            } catch { Write-Log "  could not read header bytes: $($_.Exception.Message)" }
            try {
                $null = Compute-AsarHash $TmpAsarPath
                Write-Log "  Compute-AsarHash unexpectedly succeeded on retry (transient?)."
            } catch { Write-Log "  Compute-AsarHash error: $($_.Exception.Message)" }
            try {
                $asarVer = (cmd.exe /c "npx --yes $($script:AsarPackage) --version 2>&1" | Out-String).Trim()
                Write-Log "  asar package ($($script:AsarPackage)) version: $asarVer"
            } catch { Write-Log "  could not read asar version: $($_.Exception.Message)" }

            if (Test-Path -LiteralPath $TmpAsarPath) { Remove-Item -LiteralPath $TmpAsarPath -Force -ErrorAction SilentlyContinue }
            throw "Repacked ASAR archive failed integrity check. Refusing to overwrite app.asar. See the 'Repacked ASAR validation' diagnostics above and in patch.log."
        }

        $NewHash = Compute-AsarHash $TmpAsarPath
        Write-Log "New Hash: $NewHash"
        # Move-Item -Force doesn't reliably overwrite on Windows PowerShell (#33), so
        # delete the target first. Safe: app.asar.bak was validated and rolls back on throw.
        if (Test-Path -LiteralPath $AsarPath) { Remove-Item -LiteralPath $AsarPath -Force -ErrorAction Stop }
        Move-Item -LiteralPath $TmpAsarPath -Destination $AsarPath -Force

        Write-Step "Phase 2 & 3: Executable Patching & Cert Synchronization"
        if ((Test-Path $ExePath) -and (Test-Path $CoworkSvcPath)) {

            # Read from .bak when present so the patch is idempotent on re-runs.
            $SourceSvc = if (Test-Path "$CoworkSvcPath.bak") { "$CoworkSvcPath.bak" } else { $CoworkSvcPath }
            $SourceExe = if (Test-Path "$ExePath.bak") { "$ExePath.bak" } else { $ExePath }

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

            # Log the original subject but DON'T clone it: its SERIALNUMBER + jurisdiction
            # OID fields bloat the DER cert (~1136 bytes) past the hole. Pin a compact
            # subject instead (cosmetic -- trust comes from the Root-store entry below).
            $OriginalSig = Get-AuthenticodeSignature -FilePath $SourceExe
            if ($OriginalSig -and $OriginalSig.SignerCertificate) {
                Write-Log "Original certificate subject (for reference): $($OriginalSig.SignerCertificate.Subject)"
            }
            $CertSubject = "CN=Anthropic PBC, O=Anthropic PBC, L=San Francisco, S=California, C=US"
            Write-Log "Using compact subject for binary fit: $CertSubject"

            # The replacement cert must fit the fixed hole (size detected per-binary
            # above). Cert size is driven by the key algorithm/length, so walk from
            # smallest key config up and take the first that fits: RSA-1024 (~675 bytes,
            # best Authenticode compatibility), then ECDSA P-256 (~540), then RSA-2048
            # (~936, large holes only). A weak key is fine here -- trust comes from the
            # Root-store entry, not key strength.
            $CertConfigs = @(
                @{ Label = "RSA 1024";    KeyParams = @{ KeyAlgorithm = "RSA"; KeyLength = 1024 } },
                @{ Label = "ECDSA P-256"; KeyParams = @{ KeyAlgorithm = "ECDSA_P256" } },
                @{ Label = "RSA 2048";    KeyParams = @{ KeyAlgorithm = "RSA"; KeyLength = 2048 } }
            )

            $ValidCertFound = $false
            $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
            $Store.Open("ReadWrite")

            $Cert = $null
            $NewCertBytes = $null

            foreach ($Config in $CertConfigs) {
                Write-Log "Generating self-signed certificate ($($Config.Label))..."
                $KeyParams = $Config.KeyParams
                $Cert = New-SelfSignedCertificate -Subject $CertSubject -Type CodeSigningCert -CertStoreLocation "Cert:\LocalMachine\My" -FriendlyName "Claude_RTL_SelfSigned" @KeyParams

                $NewCertBytes = $Cert.RawData

                if ($NewCertBytes.Length -le $OldCertSize) {
                    $Store.Add($Cert)
                    $ValidCertFound = $true
                    Write-Success "Generated certificate fits! ($($Config.Label), Size: $($NewCertBytes.Length) bytes, Hole: $OldCertSize bytes)"
                    break
                } else {
                    Write-Warn "Certificate too large ($($Config.Label): $($NewCertBytes.Length) bytes > $OldCertSize). Removing and trying a smaller key..."
                    Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $Cert.Thumbprint } | Remove-Item -ErrorAction SilentlyContinue
                }
            }
            $Store.Close()

            if (-not $ValidCertFound) {
                throw "Failed to generate a certificate small enough to fit the $OldCertSize-byte hole in cowork-svc.exe; even the smallest key config exceeded it."
            }

            # Byte-search hash swap mirrors the original r.js script byte-for-byte.
            Wait-FileUnlock $ExePath
            Write-Log "Reading claude.exe into memory..."
            $ExeBytes = [System.IO.File]::ReadAllBytes($SourceExe)
            $ScanMB = [math]::Round($ExeBytes.Length/1MB,1)
            Write-Log "Scanning $ScanMB MB of claude.exe for ASAR hash matches..."
            $OldHashBytes = [System.Text.Encoding]::ASCII.GetBytes($OldHash)
            $NewHashBytes = [System.Text.Encoding]::ASCII.GetBytes($NewHash)

            # Report live scan progress. Write-Progress draws the bar; the inline print
            # (throttled to 10% steps) keeps a trace in hosts where the bar isn't rendered.
            $global:RtlScanLastPct = -1
            $global:RtlScanMB      = $ScanMB
            $ScanProgress = {
                param($Pct)
                Write-Progress -Activity "Scanning claude.exe for ASAR hash matches" `
                               -Status "$Pct% of $($global:RtlScanMB) MB" -PercentComplete $Pct
                if ($Pct -ge $global:RtlScanLastPct + 10 -or $Pct -eq 100) {
                    Write-Host "  [*] Scanned $Pct%..." -ForegroundColor DarkCyan
                    $global:RtlScanLastPct = $Pct
                }
            }

            $MatchIndices = Find-AllBytesWithProgress -Haystack $ExeBytes -Needle $OldHashBytes -OnProgress $ScanProgress
            Write-Progress -Activity "Scanning claude.exe for ASAR hash matches" -Completed

            $Replacements = 0
            foreach ($Idx in $MatchIndices) {
                [Array]::Copy($NewHashBytes, 0, $ExeBytes, $Idx, $NewHashBytes.Length)
                $Replacements++
            }

            if ($Replacements -gt 0) {
                Write-Log "Writing patched claude.exe to disk..."
                [System.IO.File]::WriteAllBytes($ExePath, $ExeBytes)
                Write-Success "Replaced $Replacements ASAR hash(es) in claude.exe"
            } else {
                # Byte search empty -- the upstream hash format may have shifted. Fall
                # through to the fuse bypass; the re-sign block runs either way.
                Write-Warn "Old hash not found in claude.exe -- falling back to fuse-based bypass."
                if (-not (Invoke-FuseFlip -ExePath $ExePath)) {
                    throw "Both byte-search and fuse-based bypass failed. Aborting before re-sign."
                }
                Write-Success "ASAR integrity bypassed via Electron fuse."
            }

            Write-Log "Re-signing claude.exe with self-signed certificate (this can take several seconds)..."
            $SignResult = Set-AuthenticodeSignature -FilePath $ExePath -Certificate $Cert -HashAlgorithm SHA256
            if ($SignResult.Status -eq 'Valid') { Write-Success "Successfully re-signed claude.exe" }
            else { throw "Re-signing claude.exe failed: $($SignResult.Status)" }

            Wait-FileUnlock $CoworkSvcPath
            $Diff = $OldCertSize - $NewCertBytes.Length
            Write-Log "Swapping cowork-svc cert and padding with $Diff bytes of 0x00..."

            $PaddedCert = New-Object byte[] $OldCertSize
            [Array]::Copy($NewCertBytes, 0, $PaddedCert, 0, $NewCertBytes.Length)

            [Array]::Copy($PaddedCert, 0, $SvcBytes, $StartPos, $OldCertSize)
            [System.IO.File]::WriteAllBytes($CoworkSvcPath, $SvcBytes)
            Write-Success "Binary cert replacement completed in cowork-svc.exe"

            Write-Log "Re-signing cowork-svc.exe with self-signed certificate (this can take several seconds)..."
            $SignResult2 = Set-AuthenticodeSignature -FilePath $CoworkSvcPath -Certificate $Cert -HashAlgorithm SHA256
            if ($SignResult2.Status -eq 'Valid') { Write-Success "Successfully re-signed cowork-svc.exe" }
            else { throw "Re-signing cowork-svc.exe failed: $($SignResult2.Status)" }

            # WIPE PRIVATE KEY: the public cert stays in Root for verification, but the
            # private key would let an admin attacker sign auto-trusted binaries. Delete
            # the key material via .NET, then remove the cert via X509Store (the Cert:
            # provider's -DeleteKey doesn't bind reliably in PS 5.1).
            $myStore = $null
            $keyDestroyed = $false
            Try {
                $thumb  = $Cert.Thumbprint
                $myStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "LocalMachine")
                $myStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                $found = $myStore.Certificates | Where-Object { $_.Thumbprint -eq $thumb }
                if ($found) {
                    # Destroy the key regardless of algorithm (Remove-CertPrivateKey
                    # handles RSA and ECDSA, and verifies).
                    $keyDestroyed = Remove-CertPrivateKey -Cert $found
                    $myStore.Remove($found)
                    if ($keyDestroyed) {
                        Write-Success "Private signing key wiped and verified gone (Root cert retained)"
                    }
                } else {
                    Write-Warn "Cert with thumbprint $thumb not found in My store; cannot verify key removal."
                }
            } Catch {
                Write-Warn "Could not delete private key: $($_.Exception.Message)"
            } Finally {
                if ($myStore) { $myStore.Close() }
            }

            if (-not $keyDestroyed) {
                # BACKSTOP (rare): the key couldn't be verifiably destroyed, so a usable
                # signing key may persist alongside the trusted Root cert. Surface it loudly
                # (the RTL patch itself still works).
                Write-Warn "Signing private key could NOT be verified as deleted -- see the red banner below."
                Write-Host ""
                Write-Host "================================================================" -ForegroundColor Red
                Write-Host "  [!] SIGNING KEY NOT VERIFIABLY WIPED -- ACTION RECOMMENDED     " -ForegroundColor Red
                Write-Host "================================================================" -ForegroundColor Red
                Write-Host ""
                Write-Host "The self-signed certificate is trusted machine-wide (Root store)," -ForegroundColor Yellow
                Write-Host "and its PRIVATE KEY may still exist on this machine. An attacker" -ForegroundColor Yellow
                Write-Host "with admin rights could reuse it to sign code Windows would trust." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "To neutralize it:" -ForegroundColor Cyan
                Write-Host "  * Reboot and re-run this patch (option 1) -- the wipe usually" -ForegroundColor Cyan
                Write-Host "    succeeds once no process is holding the key store, OR" -ForegroundColor Cyan
                Write-Host "  * Run tools\claude-removal-diag.ps1 to locate and remove the" -ForegroundColor Cyan
                Write-Host "    'Claude_RTL_SelfSigned' certificate and its key container." -ForegroundColor Cyan
                Write-Host ""
            }

        } else {
            Write-Warn "claude.exe or cowork-svc.exe not found. Binary patching skipped."
        }

        Write-Step "Cleanup & Launch"
        if (Test-Path $global:TmpDir) { Remove-Item $global:TmpDir -Recurse -Force }
        Save-PatchState -InstallPath $ClaudeDir

        # Pin on EVERY install (not just with the watcher): the desktop shortcut's
        # update.ps1 reads the same pin and would otherwise fail with "no pinned pubkey".
        Save-TrustedPubkey

        # Always write the local verified-update helper, and refresh any existing
        # shortcut that still points at "irm install.ps1 | iex" to use it instead.
        Save-UpdateScript
        try {
            # Check both spots Create-UpdateShortcut uses: the current desktop and the
            # Public desktop (identity mismatch, #34).
            $shortcutName = "Update Claude RTL.lnk"
            $shortcutSpots = @( (Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName) )
            if ($env:PUBLIC) {
                $shortcutSpots += Join-Path (Join-Path $env:PUBLIC 'Desktop') $shortcutName
            }
            if ($shortcutSpots | Where-Object { Test-Path $_ }) {
                Create-UpdateShortcut
            }
        } catch {
            Write-Warn "Update-shortcut refresh failed: $($_.Exception.Message)"
        }

        Start-ClaudeServices

        Write-Host "`n=======================================================" -ForegroundColor Green
        Write-Host " PATCH INSTALLATION COMPLETED SUCCESSFULLY! ENJOY!" -ForegroundColor Green
        Write-Host "=======================================================`n" -ForegroundColor Green

        # Loud warning if the trust anchor didn't land: Save-TrustedPubkey needs the
        # CLAUDE_RTL_TRUSTED_PUBKEY env var to survive UAC, which a hostile EDR could
        # strip. Surface it NOW rather than at the next Claude update.
        $pinPath = Join-Path $global:RtlStateDir 'trusted-pubkey.b64'
        if (-not (Test-Path $pinPath)) {
            Write-Host ""
            Write-Host "================================================================" -ForegroundColor Red
            Write-Host "  [!] TRUST ANCHOR NOT PINNED -- AUTO-UPDATE WILL BE DISABLED   " -ForegroundColor Red
            Write-Host "================================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "The pinned pubkey file was not written to:" -ForegroundColor Yellow
            Write-Host "  $pinPath" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Most likely cause: this elevated session did not receive the" -ForegroundColor Yellow
            Write-Host "CLAUDE_RTL_TRUSTED_PUBKEY env var from the launching process" -ForegroundColor Yellow
            Write-Host "(usually an AV/EDR that strips the environment on UAC)." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Effect: auto-update and the 'Update Claude RTL' shortcut will" -ForegroundColor Yellow
            Write-Host "REFUSE to run until this is fixed (safe-by-default)." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Fix: re-run the installer from a clean PowerShell session:" -ForegroundColor Cyan
            Write-Host "  irm https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main/install.ps1 | iex" -ForegroundColor Cyan
            Write-Host ""
        }

        if (-not $Auto) {
            $autoPatchPrompt = Read-Host "Do you want to enable Auto Re-Patch after each Claude update? (Y/n)"
            if ($autoPatchPrompt -ne 'n' -and $autoPatchPrompt -ne 'N') {
                try { Install-AutoUpdateTask } catch { Write-Warn "Failed to install auto-patch task: $($_.Exception.Message)" }
            }
        } else {
            # Auto-mode upgrade: re-register the watcher when the installed task predates
            # the on-disk format -- catches legacy -EncodedCommand watchers (Defender's
            # Goptaju flag), installs missing the pubkey pin, and watchers older than
            # $global:RtlWatcherFormat (auto re-patches never rewrite watcher.ps1 otherwise).
            # The running watcher keeps its old body until it restarts (next logon).
            try {
                $existingTask = Get-ScheduledTask -TaskName $global:RtlTaskName -ErrorAction SilentlyContinue
                $pinPath = Join-Path $global:RtlStateDir 'trusted-pubkey.b64'
                $watcherFile = Join-Path $global:RtlStateDir 'watcher.ps1'
                $needsUpgrade = $false
                if ($existingTask) {
                    $argStr = ($existingTask.Actions | ForEach-Object { $_.Arguments }) -join ' '
                    if ($argStr -notmatch 'watcher\.ps1') { $needsUpgrade = $true }
                    if (-not (Test-Path -LiteralPath $watcherFile) -or
                        -not (Select-String -LiteralPath $watcherFile -Pattern "^# watcher-format: $global:RtlWatcherFormat\s*$" -Quiet)) {
                        $needsUpgrade = $true
                    }
                }
                if (-not (Test-Path $pinPath)) { $needsUpgrade = $true }
                if ($existingTask -and $needsUpgrade) {
                    Write-Log "Detected legacy/outdated watcher -- re-registering it silently (format $global:RtlWatcherFormat)."
                    Install-AutoUpdateTask
                }
            } catch {
                Write-Warn "Watcher upgrade check failed: $($_.Exception.Message)"
            }
        }

    } Catch {
        # Rollback path: surface the failure and restore the live files from .bak.
        $ErrorMessage = $_.Exception.Message
        Write-Host "`n[X] CRITICAL ERROR DETECTED DURING PATCHING!" -ForegroundColor Red
        Write-Host "    Reason: $ErrorMessage" -ForegroundColor Red
        Write-Host "    INITIATING AUTOMATIC ROLLBACK TO PREVENT CORRUPTION..." -ForegroundColor Yellow
        
        Restore-Patch -IsRollback

        # Don't claim a successful restore -- Restore-Patch may have aborted and prints
        # its own final status. Just surface the install failure.
        throw "Installation failed. See rollback status above."
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

    $ClaudeDir = Find-ClaudeDir
    if (-not $ClaudeDir) { 
        if ($IsRollback) { Write-Warn "Claude Dir not found during rollback." }
        else { throw "Claude installation not found on this system." }
        return
    }
    
    $AppDir = Join-Path $ClaudeDir "app"
    $ResourcesDir = Join-Path $AppDir "resources"
    
    Stop-ClaudeServices
    Take-Ownership $AppDir
    Take-Ownership $ResourcesDir

    Write-Log "Restoring original files from backup..."
    $Restored = $false
    $Aborted  = $false
    $SnapshotPaths = @()  # tracked so we can clean them up at the end

    $FilesToRestore = @(
        @{"Orig" = Join-Path $ResourcesDir "app.asar";       "Bak" = Join-Path $ResourcesDir "app.asar.bak";       "Type" = 'asar'},
        @{"Orig" = Join-Path $AppDir       "claude.exe";     "Bak" = Join-Path $AppDir       "claude.exe.bak";     "Type" = 'pe'},
        @{"Orig" = Join-Path $ResourcesDir "cowork-svc.exe"; "Bak" = Join-Path $ResourcesDir "cowork-svc.exe.bak"; "Type" = 'pe'}
    )

    # Validate every backup first: a partial restore (one good .bak, one corrupt) would
    # leave claude.exe's embedded asar hash mismatching app.asar -- worse than now.
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

        # Restore worked (past the copies without throwing) -- drop the safety snapshots.
        foreach ($snap in $SnapshotPaths) {
            if (Test-Path -LiteralPath $snap) {
                Remove-Item -LiteralPath $snap -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log "Cleaning up custom certificates..."
    Try {
        # Delete the private key material FIRST (RSA and ECDSA), THEN the certs --
        # Remove-Item on the Cert: provider drops the cert but NOT the key.
        Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'Claude_RTL_SelfSigned' } | ForEach-Object {
            $null = Remove-CertPrivateKey -Cert $_
            Remove-Item $_.PSPath -ErrorAction SilentlyContinue
        }
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.FriendlyName -eq 'Claude_RTL_SelfSigned' } | Remove-Item -ErrorAction SilentlyContinue
        Write-Success "Custom certificates removed from system store."
    } Catch {
        Write-Warn "Failed to remove some certificates."
    }

    # A user-initiated restore removes the watcher task so a broken patch can't silently
    # re-install on next logon (#14). Skip on the in-patch rollback path.
    if (-not $IsRollback) {
        Uninstall-AutoUpdateTask
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
        if ($Aborted)   { Write-Warn "Restore aborted - see messages above." }
        elseif ($Restored) { Write-Success "Restore process completed. Claude is back to original." }
        else            { Write-Warn "Restore process finished, but no backups were found." }
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
    # Color language: green = the main action, yellow = undo, white = everything
    # else, dark gray = exit. Section headers group the options by purpose.
    Write-Host ""
    Write-Host "  The patch" -ForegroundColor DarkCyan
    Write-Host "    1. Install / Re-Apply Smart RTL Patch (Full Hebrew Support)" -ForegroundColor Green
    Write-Host "    2. Restore Original State (Remove Patch)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Keep it applied after Claude updates" -ForegroundColor DarkCyan
    Write-Host "    3. Create 'Quick Update' Desktop Shortcut" -ForegroundColor White
    Write-Host "    4. Enable Auto Re-Patch (Background Watcher)" -ForegroundColor White
    Write-Host "    5. Disable Auto Re-Patch" -ForegroundColor White
    Write-Host ""
    Write-Host "  Extras" -ForegroundColor DarkCyan
    Write-Host "    6. Set a Custom Text Font (All / Hebrew / Arabic-Persian)" -ForegroundColor White
    Write-Host "    7. Exit" -ForegroundColor DarkGray

    $choice = Read-Host "`nEnter your choice (1-7)"

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
    elseif ($choice -eq '3') {
        Create-UpdateShortcut
        Write-Host "`nPress Enter to return to menu..."
        $null = Read-Host
        Show-Menu
    }
    elseif ($choice -eq '4') {
        try { Install-AutoUpdateTask } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        Write-Host "`nPress Enter to return to menu..."
        $null = Read-Host
        Show-Menu
    }
    elseif ($choice -eq '5') {
        try { Uninstall-AutoUpdateTask } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        Write-Host "`nPress Enter to return to menu..."
        $null = Read-Host
        Show-Menu
    }
    elseif ($choice -eq '6') {
        try { Set-CustomFontMenu } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        Write-Host "`nPress Enter to return to menu..."
        $null = Read-Host
        Show-Menu
    }
    elseif ($choice -eq '7') { Exit }
    else { Show-Menu }
}

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

    Write-Host "`nPress Enter to close this window..." -ForegroundColor DarkGray
    $null = Read-Host
    Exit $exitCode
} else {
    Show-Menu
}
