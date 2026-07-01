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
    [string]$TrustedPubKey
)

# Env-var fallback for `irm | iex` invocations where param binding is not possible.
if (-not $Auto -and $env:CLAUDE_RTL_AUTO -eq '1') { $Auto = $true }

# The trusted pubkey is passed as a PARAMETER, not an env var: environment
# variables set by install.ps1 / update.ps1 before Start-Process -Verb RunAs do
# NOT survive the UAC elevation boundary, so the elevated patch.ps1 would never
# see them and Save-TrustedPubkey would skip the pin. Mirror the param into the
# env var the rest of the script already reads.
if ($TrustedPubKey) { $env:CLAUDE_RTL_TRUSTED_PUBKEY = $TrustedPubKey }

# -----------------------------------------------------------------------------
# AUTO-ELEVATION: Request Administrator Privileges Automatically
# Supports both file execution and irm|iex piped execution
# -----------------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    # Prefer the locally-installed verified-update helper if it exists. That
    # helper (written admin-only at install time, see Save-UpdateScript) uses
    # the pinned pubkey to verify patch.ps1 before elevation -- hermetic
    # against a compromised GitHub repo. install.ps1 is unsigned, so falling
    # back to it is acceptable ONLY for first-time bootstrap where no local
    # trust anchor exists yet.
    $LocalUpdate = Join-Path $env:ProgramData "ClaudeRtlPatch\update.ps1"
    if (Test-Path $LocalUpdate) {
        if ($Auto) { $env:CLAUDE_RTL_AUTO = '1' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LocalUpdate
        Exit
    }
    # First-install bootstrap: no local pin yet. TOFU on install.ps1 -- the
    # same exposure the user already accepts when running `irm install.ps1 | iex`.
    # PS 5.1 defaults to TLS 1.0; GitHub requires 1.2+ -- enable it before the
    # IRM call below or the fallback fails with an opaque connection error.
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

# Pinned npm packages (C4 mitigation). 'asar' (unscoped) was deprecated by Electron;
# @electron/asar is the maintained drop-in replacement. Bump these by hand after
# reviewing the upstream changelog — never use 'latest', which is a moving target.
$script:AsarPackage  = '@electron/asar@4.2.0'
$script:FusesPackage = '@electron/fuses@2.1.1'
# Minimum Node these pinned packages will run on (both declare engines.node
# >=22.12.0). Keep in sync when bumping the packages above. Used to turn the old
# misleading "install Node" error into a precise "upgrade Node" message when an
# older Node (e.g. the EOL v18) is present but too old to run the toolchain.
$script:MinNodeVersion = '22.12.0'

# Exact JS logic from r.js
$RTL_INJECTION_CODE = @'
// --- CLAUDE RTL PATCH START ---
;(function() {
    'use strict';
    if (typeof document === 'undefined') return;
    try {
        var WRITING_SEL = '[data-testid="chat-input"]';

        // --- PURE DETECTION CORE (inlined from src/rtl-core.js by build-payload.ps1) ---
        // rtl-core.js -- pure, DOM-free RTL/LaTeX detection logic.
//
// SOURCE OF TRUTH for the detection engine. tools/build-payload.ps1 inlines the
// function bodies of this file into the injected IIFE inside patch.ps1 (it strips
// the module.exports guard at the bottom). test/rtl-core.test.js requires this
// file directly. Keep this file DOM-free so it stays unit-testable.
'use strict';

// Strong-RTL code-point ranges, [lo, hi] inclusive. Covers the modern living
// RTL scripts plus the common historic/astral ones. Tested against code points
// (codePointAt), NOT UTF-16 code units, so astral blocks like Adlam work.
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

// cp: a Unicode code point (from String.prototype.codePointAt).
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
        // ASCII Latin letters are strong-LTR (matches the original /[a-zA-Z]/ rule).
        if ((cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)) return 'ltr';
        i += cp > 0xFFFF ? 2 : 1;
    }
    return null;
}

// Remove leading LTR-only noise (filenames, URLs, paths, backtick-code) so a
// Hebrew sentence that starts with "foo.js" still detects as RTL.
function stripLeadingLTR(text) {
    return text
        .replace(/^[\s]*(?:[\w.\-]+\.[\w]{1,5})\s*/g, '')
        .replace(/https?:\/\/\S+/g, '')
        .replace(/[\w.\-]+[\/\\][\w.\-\/\\]+/g, '')
        .replace(/`[^`]+`/g, '');
}

// A "$...$" body is treated as math only when it carries a real LaTeX signal.
// This is the currency guard: "$5.99" or "$5 to $10" lack the signal and stay text.
var LATEX_SIGNAL = /[\\^_{}]|\b(?:frac|sqrt|sum|prod|int|lim|infty|cdot|times|div|leq|geq|neq|approx|partial|nabla|alpha|beta|gamma|delta|theta|lambda|mu|pi|sigma|omega|matrix|begin|end|left|right|text|mathbb|mathcal|vec|hat|bar|overline|underline)\b/;

function hasLatexSignal(body) {
    return LATEX_SIGNAL.test(body);
}

// Find math regions as [start, end) index pairs over `text`.
// Unambiguous delimiters ($$...$$, \[...\], \(...\)) always count; single $...$
// only counts with a LaTeX signal and only outside already-claimed regions.
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

    // Order matters: claim the unambiguous, greedier delimiters first.
    claim(/\$\$[\s\S]+?\$\$/g, false, 0, 0);
    claim(/\\\[[\s\S]+?\\\]/g, false, 0, 0);
    claim(/\\\([\s\S]+?\\\)/g, false, 0, 0);
    // Single $...$ -- no newline inside, must carry a LaTeX signal (currency guard).
    claim(/\$[^$\n]+?\$/g, true, 1, 1);

    ranges.sort(function (a, b) { return a[0] - b[0]; });
    return ranges;
}

// --- BARE NUMERIC / ARITHMETIC ISOLATION ---
//
// Claude frequently writes arithmetic WITHOUT LaTeX delimiters, e.g. a Hebrew
// sentence containing "2 + 3 = 5". Inside an RTL paragraph the Unicode bidi
// algorithm lays the number+operator tokens out right-to-left, so it renders
// mirrored as "5 = 3 + 2". findMathRanges marks such runs so the DOM can isolate
// LTR -- the same fix findLatexRanges applies to "$...$", extended to bare math.
//
// Operator characters whose PRESENCE proves a run is a genuine expression (not a
// lone number, date, IP, version, or list marker). ASCII core plus common
// Unicode math (multiply, divide, minus-sign, <=, >=, !=, ~=, arrow, dots,
// root). Built with String.fromCharCode so the SOURCE stays pure ASCII -- the
// patch.ps1 this is inlined into is a BOM-less .ps1, and PowerShell 5.1 corrupts
// non-ASCII source bytes. The '-' is escaped so the string is a safe regex class
// body. Order/codes: U+00D7 U+00F7 U+00B1 U+2212 U+2264 U+2265 U+2260 U+2248
// U+2192 U+00B7 U+2022 U+2219 U+2217 U+22C5 U+221A.
var MATH_OP_CHARS = '+\\-*/=<>%' + String.fromCharCode(
    0xD7, 0xF7, 0xB1, 0x2212, 0x2264, 0x2265, 0x2260,
    0x2248, 0x2192, 0xB7, 0x2022, 0x2219, 0x2217, 0x22C5, 0x221A);
var MATH_OP_RE  = new RegExp('[' + MATH_OP_CHARS + ']');
var MATH_DIGIT_RE = /[0-9]/;
// A whitespace-delimited token is "mathy" when built only from digits and math
// punctuation/operators, OR it is a single Latin letter used as a variable
// (x, y, n). Multi-letter Latin tokens (English words, "3D", "4K") are NOT
// mathy, so they break a run and keep prose out of the isolated island.
var MATH_TOKEN_RE = new RegExp('^(?:[0-9.,:;()\\[\\]{}|' + MATH_OP_CHARS + ']+|[A-Za-z])$');

function isMathyToken(tok) {
    return !!tok && MATH_TOKEN_RE.test(tok);
}

// A token may BOUND a run only if it carries an operand -- a digit or a single
// Latin variable letter. Pure operator/punctuation tokens ("+", "=", "(") can
// sit inside a run but never start or end it (avoids dangling "+ 3").
function isOperandToken(tok) {
    return MATH_DIGIT_RE.test(tok) || /^[A-Za-z]$/.test(tok);
}

// Find bare numeric/arithmetic runs as [start, end) index pairs over `text`.
// A run must be whitespace/line delimited, operand-bounded, and contain at least
// one digit AND one operator. Lone numbers, "$5" currency, Hebrew-glued
// constructs (a prefix letter joined to a number with no space), dates/IPs
// without operators, and "1." list markers are deliberately left alone.
function findMathRanges(text) {
    var ranges = [];
    if (!text || !MATH_OP_RE.test(text) || !MATH_DIGIT_RE.test(text)) return ranges;

    // Scan line by line so a run never spans a newline (each line is its own
    // bidi paragraph). `base` is the absolute offset of the current line.
    var base = 0;
    var lines = text.split('\n');
    for (var li = 0; li < lines.length; li++) {
        scanLine(lines[li], base);
        base += lines[li].length + 1; // +1 for the '\n' removed by split
    }
    return ranges;

    function scanLine(line, off) {
        var toks = [];
        var re = /\S+/g; // non-whitespace tokens; \s breaks them
        var m;
        while ((m = re.exec(line)) !== null) {
            toks.push({ v: m[0], start: m.index, end: m.index + m[0].length });
        }
        var i = 0;
        while (i < toks.length) {
            if (!isMathyToken(toks[i].v)) { i++; continue; }
            var j = i;
            while (j + 1 < toks.length && isMathyToken(toks[j + 1].v)) j++;
            // toks[i..j] is a maximal mathy group. Trim non-operand tokens off
            // both ends so the isolated run is operand-bounded.
            var a = i, b = j;
            while (a <= b && !isOperandToken(toks[a].v)) a++;
            while (b >= a && !isOperandToken(toks[b].v)) b--;
            if (a <= b) {
                var s = off + toks[a].start;
                var e = off + toks[b].end;
                // Drop sentence punctuation that clung to the ends (never part of
                // a real number at a boundary: a decimal never ends in '.').
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
// both LaTeX islands (findLatexRanges) and bare arithmetic (findMathRanges); the
// DOM layer isolates both LTR. LaTeX wins when the two overlap.
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

// Classify a table cell's direction from its text. A cell counts as RTL if it
// *contains* any RTL character -- not merely if its first strong char is RTL.
// Header labels often start with a Latin term ("blob ...", "ID ...") yet belong
// to a Hebrew column, so first-strong is too weak here. Neutral cells (digits,
// hashes, punctuation only) return null so they do not sway the majority.
function cellDir(text) {
    if (hasRTL(text)) return 'rtl';
    if (firstStrong(text) === 'ltr') return 'ltr';
    return null;
}

// Decide a whole table's column direction from header / first-column cell dirs.
// Each input is an array of 'rtl' | 'ltr' | null. Header wins; first column is
// the tie-breaker. Returns 'rtl' (flip columns) or null (leave LTR).
function tableDirFromCells(headerDirs, firstColDirs) {
    // First header is the semantic key column (row labels). If it's RTL and the
    // first data cell agrees, the table is a Hebrew table regardless of how many
    // product/entity names appear as LTR in subsequent headers.
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

        // --- PER-LINE DIRECTIONAL SPLITTING ---
        //
        // A paragraph rendered with <br> separators or whitespace-pre may carry
        // multiple lines, each in a different script. Forcing a single dir on the
        // host element mangles every line that disagrees. We instead defer to
        // unicode-bidi:plaintext and stamp data-rtl-split so later passes skip it.

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
            // No DOM rewriting -- assigning el.innerHTML broke React reconciliation
            // ("Failed to execute 'removeChild' on 'Node'"). Defer to
            // unicode-bidi:plaintext: <br> is a paragraph separator in the Unicode
            // BiDi algorithm, so each line auto-picks its direction from first-strong.
            el.setAttribute(RTL_SPLIT_FLAG, '1');
            if (el.hasAttribute('dir')) el.removeAttribute('dir');
            el.style.direction = '';
            el.style.textAlign = 'start';
            el.style.unicodeBidi = 'plaintext';
        }

        // If the element inherits RTL via a parent CSS class (not an explicit dir
        // attribute on itself), removing dir alone won't free it -- pin direction=ltr.
        function resetDirOrPinLTR(el) {
            if (window.getComputedStyle(el).direction === 'rtl') {
                el.dir = 'ltr';
                el.style.direction = 'ltr';
                return;
            }
            if (el.hasAttribute('dir')) el.removeAttribute('dir');
            el.style.direction = '';
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

            // Layer 3: RTL chars exist but hide behind code/filenames -> treat as RTL.
            return 'rtl';
        }

        // For plain text (input box, dialogs without DOM structure)
        function detectTextDir(text) {
            if (!text || !text.trim()) return null;
            var d = firstStrong(text);
            if (d === 'rtl') return 'rtl';
            if (!hasRTL(text)) return 'ltr';

            var stripped = stripLeadingLTR(text);
            d = firstStrong(stripped);
            if (d === 'rtl') return 'rtl';

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
            // Rendered math (KaTeX/MathJax), if present, is an LTR island too.
            qsa(root, '.katex, .katex-display, mjx-container').forEach(function(m) {
                m.style.unicodeBidi = 'isolate'; m.style.direction = 'ltr';
            });
        }

        // --- RAW LaTeX + BARE-ARITHMETIC ISOLATION ---
        //
        // Claude Desktop (Windows) does not render LaTeX -- it shows raw "$...$" text.
        // Inside an RTL paragraph the neutral $ \ { } chars scramble the formula, and
        // bare arithmetic ("2 + 3 = 5", "5-3", "x = 10") gets mirrored to "5 = 3 + 2"
        // by the bidi algorithm. We isolate each math segment (LaTeX or bare numeric,
        // per segmentText) in its own ltr/unicode-bidi:isolate span. We replace a
        // single TEXT node with a fragment (replaceChild) -- never innerHTML -- to stay
        // gentle on React reconciliation, and flag islands so we never re-wrap during
        // streaming.
        var ISLAND_FLAG = 'data-rtl-island';

        function isolateMath(root) {
            if (typeof document.createTreeWalker !== 'function') return;
            var host = (root && root.nodeType === 1) ? root : document.body;
            if (!host) return;
            var walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT, {
                acceptNode: function(node) {
                    var v = node.nodeValue;
                    if (!v) return NodeFilter.FILTER_REJECT;
                    // Cheap pre-filter: a LaTeX hint ($ or \), OR a numeric hint
                    // (a digit AND an operator). MATH_DIGIT_RE / MATH_OP_RE come from
                    // the inlined core above and are stateless (no /g flag).
                    var hasTex = v.indexOf('$') !== -1 || v.indexOf('\\') !== -1;
                    var hasNum = MATH_DIGIT_RE.test(v) && MATH_OP_RE.test(v);
                    if (!hasTex && !hasNum) return NodeFilter.FILTER_REJECT;
                    var p = node.parentElement;
                    if (!p) return NodeFilter.FILTER_REJECT;
                    if (p.tagName === 'SCRIPT' || p.tagName === 'STYLE') return NodeFilter.FILTER_REJECT;
                    if (p.closest('pre, code, .code-block__code, [' + ISLAND_FLAG + '], ' + WRITING_SEL)) return NodeFilter.FILTER_REJECT;
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
        //
        // A Hebrew table should read right-to-left: the first column on the right.
        // Per-cell direction is handled by processText; here we only flip the whole
        // table's column order via dir="rtl" on a stable <table> element (no text
        // surgery, low risk). Only flip once we are confident it is a Hebrew table;
        // leave the flag off otherwise so a table still streaming can re-evaluate.
        var TABLE_FLAG = 'data-rtl-table';

        function processTables(root) {
            qsa(root, 'table').forEach(function(t) {
                if (t.getAttribute(TABLE_FLAG) === 'rtl') return;
                if (t.closest(WRITING_SEL)) return;
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
                    t.setAttribute(TABLE_FLAG, 'rtl');
                    t.dir = 'rtl';
                    t.style.direction = 'rtl';
                }
            });
        }

        function processText(root) {
            // Standard text elements
            qsa(root, 'p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, label, dt, dd').forEach(function(el) {
                if (el.closest(WRITING_SEL) || el.closest('pre') || el.closest('.code-block__code')) return;
                if (el.hasAttribute(RTL_SPLIT_FLAG)) return;
                var dir = detectElDir(el);
                if (dir) {
                    if (dir === 'rtl' && hasMultiScriptLines(el)) {
                        splitToDirectionalSpans(el);
                        return;
                    }
                    el.dir = dir;
                    el.style.direction = dir;
                    if (el.tagName === 'LI') {
                        el.style.listStylePosition = (dir === 'rtl') ? 'inside' : '';
                        var parentList = el.closest('ul, ol');
                        if (parentList && dir === 'rtl' && !parentList.hasAttribute('dir')) {
                            parentList.dir = 'rtl';
                            parentList.style.direction = 'rtl';
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
                if (el.closest(WRITING_SEL) || el.closest('pre')) return;
                var dir = detectElDir(el);
                if (dir === 'rtl') {
                    el.dir = 'rtl';
                    el.style.direction = 'rtl';
                    var pl = getComputedStyle(el).paddingLeft;
                    if (parseFloat(pl) > 0) { el.style.paddingRight = pl; el.style.paddingLeft = '0'; }
                } else {
                    resetDirOrPinLTR(el);
                    el.style.paddingRight = ''; el.style.paddingLeft = '';
                }
            });
        }

        // Universal: process ANY leaf text container (catches dialogs, tooltips, etc.)
        function processContainers(root) {
            qsa(root, 'div, span, button, a, label').forEach(function(el) {
                if (el.closest('pre') || el.closest('code') || el.closest(WRITING_SEL)) return;
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
                        el.dir = detectTextDir(text) || 'rtl';
                        el.style.textAlign = 'start';
                    }
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
                '[dir]{text-align:start!important}[dir="rtl"]{direction:rtl!important}[dir="ltr"]{direction:ltr!important}',
                '[dir]>*:not([dir]):not(pre):not(code):not(.code-block__code){unicode-bidi:plaintext;text-align:start}',
                // RTL: flip sidebar truncation gradient to fade the LEFT edge (issue #7).
                '[dir="rtl"][class*="mask-image:linear-gradient(to_right"]{-webkit-mask-image:linear-gradient(to left,hsl(var(--always-black)) 85%,transparent 99%)!important;mask-image:linear-gradient(to left,hsl(var(--always-black)) 85%,transparent 99%)!important}',
                '.group:hover [dir="rtl"][class*="mask-image:linear-gradient(to_right"],.group:focus-within [dir="rtl"][class*="mask-image:linear-gradient(to_right"],[data-menu-open="true"] [dir="rtl"][class*="mask-image:linear-gradient(to_right"]{-webkit-mask-image:linear-gradient(to left,hsl(var(--always-black)) 60%,transparent 78%)!important;mask-image:linear-gradient(to left,hsl(var(--always-black)) 60%,transparent 78%)!important}'
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

            // Watch DOM changes (throttle, not debounce -- process DURING streaming)
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

# Main-process snippet (NOT renderer). Unlike $RTL_INJECTION_CODE, this runs in the
# Electron main process. It forces Chromium's UI direction to LTR, which fixes the
# native frame-peek/preview window jumping to the far left and the title-bar control
# placement on Hebrew/RTL OS locales. Root cause: when the OS locale is RTL, Chromium
# derives a RTL UI direction and draws native child windows with WS_EX_LAYOUTRTL
# (X-axis mirroring); the app itself sets no UI direction, so this switch is the
# override. Injected at the very top of the main entry (index.pre.js), before app
# 'ready' fires. Kept tiny and DOM-free to avoid interfering with MCP startup (#14).
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
# Persistent log -- captures every patch run (including silent ones triggered by
# the auto-update watcher) so failures can be diagnosed after the fact.
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

# Pure Binary Search equivalent to Python's bytearray.find()
function Find-Bytes([byte[]]$Haystack, [byte[]]$Needle, [int]$StartIndex = 0) {
    # Fast path: convert both arrays to ISO-8859-1 strings (1 byte ↔ 1 char, lossless
    # for all 256 byte values) and delegate to String.IndexOf, which is implemented in
    # native code. This replaces a nested PowerShell byte-by-byte loop that was the
    # dominant silent period during patching (tens of MB × needle length in pure PS
    # could take ~30–60s on claude.exe).
    if ($Needle -eq $null -or $Needle.Length -eq 0 -or $Haystack -eq $null -or $Haystack.Length -lt $Needle.Length) { return -1 }
    if ($StartIndex -lt 0) { $StartIndex = 0 }
    if ($StartIndex -gt ($Haystack.Length - $Needle.Length)) { return -1 }
    $enc = [System.Text.Encoding]::GetEncoding(28591)  # ISO-8859-1 / Latin-1, byte-preserving
    $hayStr = $enc.GetString($Haystack)
    $needleStr = $enc.GetString($Needle)
    return $hayStr.IndexOf($needleStr, $StartIndex, [System.StringComparison]::Ordinal)
}

# -----------------------------------------------------------------------------
# AUTO-UPDATE STATE: shared with the watcher Scheduled Task
# -----------------------------------------------------------------------------
$global:RtlStateDir  = Join-Path $env:ProgramData "ClaudeRtlPatch"
$global:RtlStateFile = Join-Path $global:RtlStateDir "state.json"
$global:RtlTaskName  = "ClaudeRtlPatchWatcher"

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
        if (-not (Test-Path $global:RtlStateDir)) {
            New-Item -ItemType Directory -Path $global:RtlStateDir -Force | Out-Null
        }
        $ver = Get-ClaudeVersionFromPath -Path $InstallPath
        $state = [ordered]@{
            patchedVersion     = if ($ver) { $ver.ToString() } else { $null }
            patchedInstallPath = $InstallPath
            patchedAt          = (Get-Date).ToUniversalTime().ToString("o")
        }
        $state | ConvertTo-Json | Set-Content -Path $global:RtlStateFile -Encoding UTF8
        Write-Log "Patch state recorded at $global:RtlStateFile (version: $($state.patchedVersion))"
    } catch {
        Write-Warn "Failed to save patch state: $($_.Exception.Message)"
    }
}

function Save-TrustedPubkey {
    # Pins the maintainer's PUBLIC KEY (the full RSA blob, not just a fingerprint
    # of it) to disk. The auto-update watcher loads this key directly and uses it
    # to verify patch.ps1.sig itself — install.ps1 is never fetched or executed
    # during auto-update. Storing the full key (instead of SHA-256 over the
    # blob, as the V1 design did) closes two bypasses of the V1 scheme:
    #   1. install.ps1 is unsigned. A V1 watcher fingerprint-matched only the
    #      $ExpectedPubKey variable, then ran the rest of install.ps1 as admin.
    #      A compromised repo could leave the pubkey untouched and ship a
    #      malicious payload around it. V2 never executes install.ps1.
    #   2. Regex extraction of $ExpectedPubKey is not equivalent to PowerShell's
    #      parser (commented-out lines, multiple assignments, here-strings).
    #      V2 reads the pubkey bytes from a local file, no parsing of remote
    #      script content involved.
    #
    # The pubkey value arrives via the CLAUDE_RTL_TRUSTED_PUBKEY env var set by
    # install.ps1 (first install) or by the watcher itself (subsequent
    # re-registrations). Using the env var rather than a fresh download avoids
    # a TOCTOU race where the repo could change between verification and pin.
    try {
        $pubB64 = $env:CLAUDE_RTL_TRUSTED_PUBKEY
        if (-not $pubB64) {
            Write-Warn "No CLAUDE_RTL_TRUSTED_PUBKEY env var; trusted-pubkey.b64 will not be written."
            Write-Warn "(Auto-update watcher will refuse to run without it -- this is the safe default.)"
            return
        }

        # Validate the blob is well-formed before pinning. A corrupt or
        # truncated env var would poison the pin and break legitimate updates.
        try {
            $pubJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pubB64))
            $pubObj  = $pubJson | ConvertFrom-Json
            $null = [Convert]::FromBase64String($pubObj.Modulus)
            $null = [Convert]::FromBase64String($pubObj.Exponent)
        } catch {
            Write-Warn "Trusted pubkey from env var failed to parse ($($_.Exception.Message)). Refusing to pin."
            return
        }

        if (-not (Test-Path $global:RtlStateDir)) {
            New-Item -ItemType Directory -Path $global:RtlStateDir -Force | Out-Null
        }
        $pinPath = Join-Path $global:RtlStateDir 'trusted-pubkey.b64'
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText($pinPath, $pubB64, $utf8NoBom)

        # Log a fingerprint so operators can cross-check against install.ps1 /
        # the README without exposing the full key blob in the log.
        $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String($pubB64))
        $fp  = ([BitConverter]::ToString($sha)).Replace('-', '').ToLower()
        Write-Log "Trusted pubkey pinned at $pinPath (sha256=$fp)"

        # Clean up the V1 fingerprint-only file. Harmless leftover but the V2
        # watcher no longer reads it; removing it avoids confusing future audits.
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
    # Local helper at %ProgramData%\ClaudeRtlPatch\update.ps1 for the desktop
    # "Update Claude RTL" shortcut. Mirrors the watcher's verify-then-elevate
    # flow against the pinned pubkey. Manual updates bypass install.ps1 (which
    # is unsigned and would otherwise be a code-execution path on a hijacked
    # repo) -- the only network artifact trusted is patch.ps1 + its signature.
    # Written from an already-elevated caller, so the file inherits ProgramData
    # ACLs (admin-only write).
    try {
        if (-not (Test-Path $global:RtlStateDir)) {
            New-Item -ItemType Directory -Path $global:RtlStateDir -Force | Out-Null
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

# Strip incoming BOM (we re-add UTF-8 BOM on write). PS 5.1 needs BOM to parse
# Hebrew/box-drawing characters in patch.ps1.
$tmpFile = Join-Path $env:TEMP "claude_rtl_patch.ps1"
$content = [System.Text.Encoding]::UTF8.GetString($patchBytes)
if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
[System.IO.File]::WriteAllText($tmpFile, $content, [System.Text.UTF8Encoding]::new($true))

Write-Host "Patch verified ($($patchBytes.Length) bytes). Elevating..." -ForegroundColor Green

# Pass the pinned pubkey as a -TrustedPubKey PARAMETER so the elevated child's
# Save-TrustedPubkey sees the SAME trust anchor. An env var would NOT survive the
# Start-Process -Verb RunAs UAC boundary. CLAUDE_RTL_AUTO=1 tells patch.ps1 to run
# Install-Patch directly instead of showing the menu (the "1-click update" path).
$env:CLAUDE_RTL_AUTO = '1'

# Elevate via UAC. patch.ps1's Auto mode pauses on Read-Host at the end, so
# the user gets a chance to read the patch log before the window closes.
Start-Process -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Verb RunAs `
    -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$tmpFile,'-Auto','-TrustedPubKey',$pubB64
    )
'@

        # PS 5.1 needs UTF-8 with BOM to parse Unicode text correctly.
        [System.IO.File]::WriteAllText($updatePath, $updateBody, [System.Text.UTF8Encoding]::new($true))
        Write-Log "Verified-update helper written to $updatePath"
    } catch {
        Write-Warn "Save-UpdateScript failed: $($_.Exception.Message)"
    }
}

function Find-ClaudeDir {
    $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -and $_.InstallLocation -like '*WindowsApps*' } | Select-Object -First 1
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
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
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
        Returns $true if the file can't be opened for the requested $Access, $false otherwise.
    .PARAMETER Access
        'Read' for read-only operations (e.g. creating a backup); 'Write' for writes (default).
        The probe must replicate EXACTLY what the real operation does, or it could green-light
        a step that then fails (or falsely block one that would succeed).
    .NOTES
        The probe mirrors the real operations' sharing semantics:
          * write probe (FileAccess.Write, FileShare.Read)  == [IO.File]::WriteAllBytes
          * read  probe (FileAccess.Read,  FileShare.Read)  == [IO.File]::ReadAllBytes / Copy
        FileMode.Open (never Create) keeps the probe non-destructive.

        This replaces the old (FileAccess.ReadWrite, FileShare.None) probe, which was both:
          - too strict on share: it reported LOCKED whenever ANY coexisting handle existed,
            even a benign read-share handle from an AV/indexer scanning the 200+ MB claude.exe
            right after boot — the false-positive behind issue #15; and
          - mismatched on access: it demanded ReadWrite even for read-only backup steps.
        FileShare.Read (not ReadWrite) is deliberate: WriteAllBytes itself uses FileShare.Read,
        so a permissive FileShare.ReadWrite probe could pass while WriteAllBytes then fails
        against a coexisting writer. Matching FileShare.Read keeps probe == real op.
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

# Windows Restart Manager gives the AUTHORITATIVE list of processes/services holding a
# file open — far more reliable than walking Get-Process module lists (Get-FileHolders),
# which misses services and files held without a loaded module. Ported from
# tools/claude-lock-diag.ps1. Advisory only: used to name holders in preflight errors.
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
        # A second Add-Type of the same type in one session throws "already exists" —
        # treat that as success. Any other failure: degrade to no holder list (advisory).
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
        # IOException (sharing violation) and anything else → treat as locked.
        return [pscustomobject]@{ Path = $Path; Name = $name; Status = 'LOCKED'; Holders = (Get-FileLockers $Path) }
    }
}

function Assert-PatchWritable {
    <#
    .SYNOPSIS
        PREFLIGHT: before touching ANY file content, verify every target the whole patch
        will write to is actually writable. If not, throw a single clear error so the run
        aborts cleanly with the install untouched — instead of bricking halfway through.
    .NOTES
        - Runs AFTER Stop-ClaudeServices + Take-Ownership (writability reflects the ACLs the
          patch grants itself; before stopping services the binaries are falsely "locked").
        - Uses a BOUNDED WAIT per target (mirrors the per-step Wait-FileUnlock gates) so it is
          at least as tolerant as the current code — it can never block a machine the current
          code would succeed on (e.g. cowork-svc briefly releasing after service stop).
        - Directory checks are WARN-ONLY (never abort).
        - Fail-safe: runs before any content change, so the worst case is "refuses to run",
          never a corrupted file.
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

    # Directory writability (new .bak/.new files land here) — WARN ONLY, never aborts.
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
    cmd.exe /c "icacls `"$Path`" /grant `"*S-1-5-32-544:(OI)(CI)F`" /T /Q >nul 2>&1"
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
# Alternative bypass path used when the byte-level hash replacement can't locate
# the asar hash inside claude.exe (e.g. hash encoding, algorithm or storage
# location changed upstream). Decomposed into a probe + a predicate + the main
# entry so each piece is testable in isolation. We never throw from here — the
# caller chooses what to do with a $false return.
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
            Write-Success "ASAR integrity fuse already off — nothing to do."
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

        # Re-probe — some tool builds print "Fuses written" without actually persisting.
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
        # Ensure the verified-update helper exists locally before pointing the
        # shortcut at it. Save-UpdateScript is idempotent.
        Save-UpdateScript

        $WshShell = New-Object -comObject WScript.Shell
        $DesktopPath = [Environment]::GetFolderPath('Desktop')
        $ShortcutPath = Join-Path $DesktopPath "Update Claude RTL.lnk"
        $LocalUpdatePath = Join-Path $global:RtlStateDir 'update.ps1'

        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "powershell.exe"
        # Point at the LOCAL verified-update helper, not at remote install.ps1.
        # The helper uses the pinned pubkey to verify patch.ps1 before elevating;
        # a hijacked GitHub install.ps1 cannot influence this path.
        $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$LocalUpdatePath`""
        $Shortcut.Description = "Verified update of the Claude Desktop RTL patch"

        $ClaudeDir = Find-ClaudeDir
        if ($ClaudeDir -and (Test-Path (Join-Path $ClaudeDir "app\claude.exe"))) {
            $Shortcut.IconLocation = "$(Join-Path $ClaudeDir "app\claude.exe"),0"
        } else {
            $Shortcut.IconLocation = "powershell.exe,0"
        }

        $Shortcut.Save()
        Write-Success "Shortcut created successfully on your Desktop: $ShortcutPath"
        Write-Success "It launches the local verified-update helper: $LocalUpdatePath"
    } Catch {
        Write-Warn "Failed to create shortcut: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# AUTO-UPDATE WATCHER (Scheduled Task)
# The watcher is written to %ProgramData%\ClaudeRtlPatch\watcher.ps1 and launched
# via -File (NOT -EncodedCommand). A readable on-disk script avoids the encoded-
# PowerShell heuristic that Defender flags as Trojan:Win32/Goptaju once the body
# also downloads + verifies patch.ps1 from GitHub. The watcher only MONITORS for
# new claude.exe versions; when it fires it fetches patch.ps1 LIVE from GitHub and
# runs THAT (see Invoke-AutoPatch) -- never a local copy.
# -----------------------------------------------------------------------------
function Save-WatcherScript {
    try {
        if (-not (Test-Path $global:RtlStateDir)) {
            New-Item -ItemType Directory -Path $global:RtlStateDir -Force | Out-Null
        }
        $watcherPath = Join-Path $global:RtlStateDir 'watcher.ps1'

        # Single-quoted here-string: $ signs are preserved literally for runtime evaluation inside the watcher.
        $watcherBody = @'
$ErrorActionPreference = "Continue"
# Scheduled Task PowerShell defaults to TLS 1.0, which GitHub rejects. Force 1.2
# so WebClient calls to raw.githubusercontent.com succeed.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
$stateDir       = Join-Path $env:ProgramData "ClaudeRtlPatch"
$stateFile      = Join-Path $stateDir "state.json"
$logFile        = Join-Path $stateDir "watcher.log"
$lastActionFile = Join-Path $stateDir "last-action.txt"
$pubkeyPinFile  = Join-Path $stateDir "trusted-pubkey.b64"
# The watcher fetches patch.ps1 + patch.ps1.sig DIRECTLY and verifies them with
# the locally-pinned pubkey. install.ps1 is intentionally NOT used here: it is
# unsigned, and any compromised version of install.ps1 served from a hijacked
# repo would otherwise execute as admin during auto-update. Pinning the full
# pubkey (not a fingerprint of install.ps1's $ExpectedPubKey variable) means
# the only thing we trust from the network is patch.ps1 itself, validated
# byte-for-byte against the maintainer's offline private key.
$repoBase       = "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main"
$patchUrl       = "$repoBase/patch.ps1"
$sigUrl         = "$repoBase/patch.ps1.sig"

# Tracks when the windowed claude.exe was first seen unresponsive, so Restart-IfHung
# only acts on a *sustained* hang (guards against transient "busy" blips).
$script:hungSince = $null

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

function Get-PinnedRsa {
    # Loads the pinned public key from disk and returns an RSA object configured
    # with the maintainer's pubkey, plus the original base64 blob (so callers
    # can forward it via env var to any child process without re-encoding).
    # The watcher uses this RSA object directly to verify patch.ps1.sig --
    # install.ps1 is never consulted, never executed during auto-update.
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
    # Throttle: skip if we acted within the last 90 seconds (avoids loops on multi-process Electron startup).
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

    Write-WLog "Detected Claude v$newVer at $exePath -- verifying signature before patching..."

    $pinned = Get-PinnedRsa
    if (-not $pinned) {
        Show-Toast "Claude RTL: auto-update BLOCKED" "Trusted pubkey pin is missing or unreadable. Re-install the patch manually to restore auto-updates."
        return
    }

    # Fetch patch.ps1 + signature directly as raw bytes. The signature is over
    # the exact LF-normalized bytes the maintainer signed; raw.githubusercontent.com
    # serves LF (.gitattributes eol=lf), so the on-wire bytes match. Do NOT
    # decode to string before verifying -- string round-trips can alter BOMs.
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

    # Write patch.ps1 to disk with a UTF-8 BOM (PS 5.1 needs the BOM to parse
    # Hebrew/box-drawing characters correctly). Strip any incoming BOM from the
    # bytes first to avoid double-BOM.
    $tmpFile = Join-Path $env:TEMP 'claude_rtl_patch.ps1'
    $content = [System.Text.Encoding]::UTF8.GetString($patchBytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
    [System.IO.File]::WriteAllText($tmpFile, $content, [System.Text.UTF8Encoding]::new($true))

    Show-Toast "Claude updated to v$newVer" "Auto-patching now. A PowerShell window will open with the patch log."

    # Kill running Claude processes for snappy UX (patch.ps1 will kill again via Stop-ClaudeServices).
    Get-Process -Name claude,cowork-svc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    try {
        # Propagate the pinned pubkey to the child so any re-registration that
        # happens inside patch.ps1 (Save-TrustedPubkey) sees the SAME trust
        # anchor -- never downgraded to "whatever's currently in install.ps1
        # on GitHub". The watcher is already elevated (RunLevel Highest), so
        # the spawned PowerShell inherits the elevated token without a UAC prompt.
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

function Get-ClaudeAumid {
    # Version-independent launch target. A hung process's own .Path points into
    # the OLD versioned WindowsApps folder, which may already be removed after the
    # MSIX update swap, so we relaunch via the app's AUMID instead.
    try {
        $a = Get-StartApps | Where-Object { $_.AppID -like 'Claude_*!*' } | Select-Object -First 1
        if ($a) { return $a.AppID }
    } catch {}
    try {
        $p = Get-AppxPackage -Name 'Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) { return "$($p.PackageFamilyName)!Claude" }
    } catch {}
    return $null
}

function Restart-IfHung {
    # Claude's MSIX self-update (often applied on resume from Modern Standby) can
    # leave the previously-running patched claude.exe "not responding" forever --
    # Windows logs it as Application Hang (Event 1002, MoAppHang) and the user is
    # stuck with a frozen window that never recovers on its own. Detect a SUSTAINED
    # hang (>=90s) and cleanly restart Claude. This never touches the signature-
    # verify / auto-patch path. Only the process that owns a main window is checked:
    # Responding is meaningful only for windowed processes (Electron spawns many
    # windowless helpers that always report Responding = $true).
    try {
        $win = Get-Process -Name claude -ErrorAction SilentlyContinue |
               Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $win) { $script:hungSince = $null; return }
        if ($win.Responding) { $script:hungSince = $null; return }

        if (-not $script:hungSince) {
            $script:hungSince = [DateTime]::Now
            Write-WLog "claude.exe (PID $($win.Id)) not responding -- watching for sustained hang."
            return
        }
        if (([DateTime]::Now - $script:hungSince).TotalSeconds -lt 90) { return }

        Write-WLog "claude.exe hung >90s -- killing stale processes and relaunching."
        Get-Process -Name claude,cowork-svc -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        $script:hungSince = $null
        Start-Sleep -Seconds 2
        $aumid = Get-ClaudeAumid
        if ($aumid) {
            Start-Process "explorer.exe" "shell:AppsFolder\$aumid" | Out-Null
            Write-WLog "Relaunched Claude via AUMID $aumid"
            Show-Toast "Claude was frozen" "Detected a hung Claude window (likely after an update or resume from sleep) and restarted it."
        } else {
            Write-WLog "Could not resolve Claude AUMID -- not relaunching."
        }
    } catch {
        Write-WLog "Restart-IfHung error: $($_.Exception.Message)"
    }
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
    $ev = Wait-Event -SourceIdentifier "ClaudeProcessCreated" -Timeout 60
    if ($null -eq $ev) { Restart-IfHung; continue }   # periodic hang check (~every 60s)
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

        # PS 5.1 needs UTF-8 with BOM to parse Unicode text (Hebrew + toast XML) correctly.
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

    # Pin the maintainer's pubkey BEFORE registering the task. The watcher
    # verifies patch.ps1 against this pinned pubkey -- closes the "full repo
    # takeover" vector for existing installs.
    Save-TrustedPubkey

    # Write the watcher to disk; the task launches it via -File (not -EncodedCommand).
    Save-WatcherScript
    $watcherPath = Join-Path $global:RtlStateDir 'watcher.ps1'

    Try {
        $userName  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherPath`""
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
        # The npx probe failed -- two distinct causes with different fixes:
        #  1) npx unreachable: a Node version manager shim (e.g. Volta) on PATH
        #     fails under the elevated PATH (rebuilt from the registry across
        #     UAC). Retry with system Node at %ProgramFiles%\nodejs if present.
        #  2) Node present but older than $script:MinNodeVersion -- the pinned
        #     @electron/asar/fuses refuse to run. Surface the version and tell
        #     the user to upgrade rather than printing "install Node" (issue #11).
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

    # PREFLIGHT: verify EVERY file the whole patch will write is writable, before we touch
    # any content. Aborts cleanly (install untouched) instead of bricking halfway. Runs here
    # because writability depends on the ownership just granted and on the services being
    # stopped above. See Assert-PatchWritable for the fail-safe / bounded-wait guarantees.
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

    # Always restore from backup before patching — ensures clean state
    # First run: .bak was just created from same file → copy is a no-op (safe)
    # Re-run: restores original files → fresh install on clean files
    # CRITICAL: validate every backup BEFORE overwriting the live files. If a backup
    # is corrupt (e.g., truncated leftover from older buggy versions), restoring it
    # would brick the install — and the rollback path can't recover because it
    # also reads from .bak.
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
            # Resolve the Electron main-process entry from package.json "main"
            # (currently ".vite/build/index.pre.js"); fall back to the known filename if
            # parsing fails. The ENTRY alone receives the tiny main-process switch
            # injection ($MAIN_INJECTION_CODE), NOT the renderer RTL/DOM payload.
            $MainEntryFile = 'index.pre.js'
            $PkgJsonPath = Join-Path $global:TmpDir 'package.json'
            if (Test-Path $PkgJsonPath) {
                try {
                    $pkgMain = (Get-Content $PkgJsonPath -Raw | ConvertFrom-Json).main
                    if ($pkgMain) { $MainEntryFile = Split-Path $pkgMain -Leaf }
                } catch { Write-Log "Could not parse package.json 'main'; defaulting entry to '$MainEntryFile'." }
            }
            Write-Log "Main-process entry: $MainEntryFile"

            # Files that run OUTSIDE the renderer and must NOT receive the renderer-only
            # RTL/DOM payload (no DOM; injecting risks breaking MCP startup -- issue #14).
            # index.js is the large main bundle the entry require()s; the rest are Node
            # MCP host/workers. All skipped entirely. The main ENTRY is handled separately
            # below: it gets $MAIN_INJECTION_CODE (force-ui-direction=ltr), which runs
            # before app 'ready' and fixes the native preview window jumping left and the
            # title-bar control placement on RTL OS locales.
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
            foreach ($file in $JsFiles) {
                if ($SkipEntirely -contains $file.Name) {
                    Write-Log "Skipped non-renderer file (no DOM): $($file.Name)"
                    continue
                }
                $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

                if ($file.Name -eq $MainEntryFile) {
                    # Main-process entry: inject the Chromium UI-direction switch only.
                    # Insert AFTER the leading "use strict"; directive so the bundle keeps
                    # strict mode -- a bare prepend would demote the directive (it must be
                    # the first statement) and silently disable strict mode for the whole
                    # main bundle.
                    if ($content -match "CLAUDE RTL MAIN PATCH START") { continue }
                    $strictRe = '^\s*("use strict"|''use strict'')\s*;'
                    if ($content -match $strictRe) {
                        $prologue = $matches[0]
                        $newContent = $prologue + "`n" + $MAIN_INJECTION_CODE + "`n" + $content.Substring($prologue.Length)
                    } else {
                        $newContent = $MAIN_INJECTION_CODE + "`n" + $content
                    }
                    [System.IO.File]::WriteAllText($file.FullName, $newContent, $utf8NoBom)

                    # Fail fast: a syntax error in the ENTRY would prevent Claude from
                    # starting at all, and the snippet's try/catch cannot guard a parse
                    # error. Validate the written file before committing to a repack
                    # (Test-FileValid checks asar structure, not JS syntax).
                    cmd.exe /c "node --check `"$($file.FullName)`""
                    if ($LASTEXITCODE -ne 0) {
                        throw "node --check failed on patched main entry '$($file.Name)'. Refusing to repack -- the injected main-process snippet would prevent Claude from starting."
                    }
                    $MainInjected++
                    Write-Log "Injected MAIN switch (force-ui-direction=ltr) into: $($file.Name)"
                    continue
                }

                # Renderer file: inject the RTL/DOM payload.
                if ($content -match "CLAUDE RTL PATCH START") { continue }
                $newContent = $RTL_INJECTION_CODE + "`n" + $content
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
            # Test-FileValid swallows the real exception and returns $false, leaving the
            # reporter with a generic message. Surface WHY the repacked archive is
            # unreadable so the failure is diagnosable from patch.log (issue #26).
            # Each probe is independently guarded so the diagnostics themselves can't
            # mask the original failure. Gather everything BEFORE deleting the temp.
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
        Move-Item -Path $TmpAsarPath -Destination $AsarPath -Force

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

            # Log the original cert Subject for diagnostics, but DON'T clone it into the
            # replacement: the Anthropic subject carries SERIALNUMBER + jurisdiction OID
            # fields that alone push the DER cert to ~1136 bytes. We pin a compact subject
            # instead so subject length can never blow the binary hole. The subject is
            # cosmetic anyway -- trust comes from the Root-store entry added below, not the
            # subject text.
            $OriginalSig = Get-AuthenticodeSignature -FilePath $SourceExe
            if ($OriginalSig -and $OriginalSig.SignerCertificate) {
                Write-Log "Original certificate subject (for reference): $($OriginalSig.SignerCertificate.Subject)"
            }
            $CertSubject = "CN=Anthropic PBC, O=Anthropic PBC, L=San Francisco, S=California, C=US"
            Write-Log "Using compact subject for binary fit: $CertSubject"

            # The replacement cert must fit the fixed-size hole left by the original
            # Anthropic cert (size detected per-binary above -- e.g. 856 bytes on some
            # 1.12603.x builds, ~1457 bytes on others). Cert size is deterministic, driven
            # almost entirely by the key algorithm/length -- an RSA-2048 code-signing cert
            # is ~936 bytes EVERY time, so the old "regenerate the same RSA-2048 key 10x"
            # loop could never shrink below an 856-byte hole (only serial/dates varied).
            # Instead, walk a list of progressively smaller key configs and take the first
            # that fits. RSA-1024 (~675 bytes) is preferred for maximum Authenticode
            # compatibility; ECDSA P-256 (~540 bytes) is a smaller fallback; RSA-2048
            # (~936 bytes) only fits a large hole but is kept last. (ECDSA_P256 is the
            # documented New-SelfSignedCertificate algorithm name -- portable across
            # Windows versions.) A weak key is acceptable here: trust derives from the
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
            Write-Log "Scanning $([math]::Round($ExeBytes.Length/1MB,1)) MB of claude.exe for ASAR hash matches..."
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
                Write-Log "Writing patched claude.exe to disk..."
                [System.IO.File]::WriteAllBytes($ExePath, $ExeBytes)
                Write-Success "Replaced $Replacements ASAR hash(es) in claude.exe"
            } else {
                # Byte search came up empty — the hash format upstream may have
                # shifted. Fall through to the fuse-based bypass; the subsequent
                # re-sign block restores a valid Authenticode signature either way.
                Write-Warn "Old hash not found in claude.exe — falling back to fuse-based bypass."
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

            # 7. WIPE PRIVATE KEY: public cert stays in Root for verification, but the
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
        Save-PatchState -InstallPath $ClaudeDir

        # Pin the maintainer's pubkey on EVERY install, not only when the watcher
        # is enabled. The local update.ps1 (desktop shortcut) reads the same pin,
        # so if a user installs + creates a shortcut but declines auto-update,
        # the shortcut would otherwise fail with "no pinned pubkey".
        Save-TrustedPubkey

        # Always write the local verified-update helper so the desktop shortcut
        # (current or future) can use it. If the shortcut already exists from
        # an older install pointing at "irm install.ps1 | iex", refresh it to
        # point at the local helper -- closes the manual-update bypass for
        # existing users without requiring them to recreate the shortcut.
        Save-UpdateScript
        try {
            $existingShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) "Update Claude RTL.lnk"
            if (Test-Path $existingShortcut) {
                Create-UpdateShortcut
            }
        } catch {
            Write-Warn "Update-shortcut refresh failed: $($_.Exception.Message)"
        }

        Start-ClaudeServices

        Write-Host "`n=======================================================" -ForegroundColor Green
        Write-Host " PATCH INSTALLATION COMPLETED SUCCESSFULLY! ENJOY!" -ForegroundColor Green
        Write-Host "=======================================================`n" -ForegroundColor Green

        # Loud warning if the trust anchor failed to land. Save-TrustedPubkey
        # depends on the CLAUDE_RTL_TRUSTED_PUBKEY env var propagating through
        # the UAC elevation -- this usually works, but a hostile EDR / AV that
        # intercepts the elevation could strip the environment block. In that
        # case the auto-update watcher and the desktop shortcut would both
        # silently refuse to run later. Surface the failure NOW so the user
        # can re-run rather than discovering it the next time Claude updates.
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
            # Auto-mode upgrade path: re-register the watcher whenever the
            # installed task predates the current on-disk format. This catches:
            #   - V0/V1/V2 watchers embedded as -EncodedCommand (the encoded
            #     blob that Defender flags as Trojan:Win32/Goptaju), and
            #   - any install missing the V2 pubkey pin (trusted-pubkey.b64).
            # Re-registering rewrites the task to launch watcher.ps1 via -File
            # and refreshes the pinned pubkey for local signature verification.
            try {
                $existingTask = Get-ScheduledTask -TaskName $global:RtlTaskName -ErrorAction SilentlyContinue
                $pinPath = Join-Path $global:RtlStateDir 'trusted-pubkey.b64'
                $needsUpgrade = $false
                if ($existingTask) {
                    $argStr = ($existingTask.Actions | ForEach-Object { $_.Arguments }) -join ' '
                    if ($argStr -notmatch 'watcher\.ps1') { $needsUpgrade = $true }
                }
                if (-not (Test-Path $pinPath)) { $needsUpgrade = $true }
                if ($existingTask -and $needsUpgrade) {
                    Write-Log "Detected legacy/encoded watcher -- upgrading to on-disk watcher.ps1 silently."
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

    Write-Log "Cleaning up custom certificates..."
    Try {
        Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'Claude_RTL_SelfSigned' } | Remove-Item -ErrorAction SilentlyContinue
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.FriendlyName -eq 'Claude_RTL_SelfSigned' } | Remove-Item -ErrorAction SilentlyContinue
        Write-Success "Custom certificates removed from system store."
    } Catch {
        Write-Warn "Failed to remove some certificates."
    }

    # A user-initiated restore should leave nothing behind that could re-apply the
    # patch. Remove the auto-update watcher scheduled task so a broken patch can't
    # silently re-install on the next logon (issue #14 side note). Skip this on the
    # in-patch rollback path, which must not tear down the watcher mid-patch.
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
    Write-Host "`nSelect an action:"
    Write-Host "  1. Install Smart RTL Patch (Full Hebrew Support)" -ForegroundColor White
    Write-Host "  2. Restore Original State (Remove Patch)" -ForegroundColor White
    Write-Host "  3. Create 'Quick Update' Desktop Shortcut" -ForegroundColor Green
    Write-Host "  4. Enable Auto Re-Patch After Each Claude Update (Background Service)" -ForegroundColor Green
    Write-Host "  5. Disable Auto Re-Patch Service" -ForegroundColor White
    Write-Host "  6. Exit" -ForegroundColor White

    $choice = Read-Host "`nEnter your choice (1/2/3/4/5/6)"

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
    elseif ($choice -eq '6') { Exit }
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
