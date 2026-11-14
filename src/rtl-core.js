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

// --- LIST CONTEXT ---
// A list item is judged in the context of its list. Hebrew/Arabic writers mix in
// English terms freely ("Review [Hebrew/Arabic: the] design system [and update the]
// colors"): such an item can open with a Latin word AND hold more Latin letters than
// RTL ones, so first-strong and rtlMajority both call it LTR. Inside an RTL list it
// is still an RTL sentence. Like cellDir for tables, an item that CONTAINS RTL inside
// an RTL list context is RTL; items with no RTL letters keep their own direction.

// Context direction of a list from its items' own texts (nested sub-lists excluded).
// Votes like cellDir: an item containing RTL votes 'rtl', a Latin-first item without
// RTL votes 'ltr', neutral items abstain.
function listContextDir(itemTexts) {
    var dirs = [];
    for (var i = 0; i < (itemTexts || []).length; i++) dirs.push(cellDir(itemTexts[i]));
    return majorityDir(dirs);
}

// Direction for one list item. `ownDir` is the item's standalone detection ('rtl',
// 'ltr' or null); `contextDir` is the list's context ('rtl' from an RTL parent item
// or an RTL-majority list). Returns 'rtl' or the standalone result unchanged.
function listItemDir(text, ownDir, contextDir) {
    if (ownDir === 'rtl') return 'rtl';
    if (contextDir === 'rtl' && hasRTL(text)) return 'rtl';
    return ownDir;
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        RTL_RANGES: RTL_RANGES,
        isRTL: isRTL,
        hasRTL: hasRTL,
        firstStrong: firstStrong,
        rtlMajority: rtlMajority,
        stripLeadingLTR: stripLeadingLTR,
        LATEX_SIGNAL: LATEX_SIGNAL,
        hasLatexSignal: hasLatexSignal,
        findLatexRanges: findLatexRanges,
        findMathRanges: findMathRanges,
        segmentText: segmentText,
        cellDir: cellDir,
        tableDirFromCells: tableDirFromCells,
        majorityDir: majorityDir,
        listContextDir: listContextDir,
        listItemDir: listItemDir
    };
}
