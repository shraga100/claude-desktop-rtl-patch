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

        // Optional page translation (src/translate.js). patch.ps1 splices the target
        // language ('' = off) and scope ('ui' = interface only, 'all' = interface and
        // conversation); when it is off the translation code is not injected at all.
        var TRANSLATE_TO = '__RTL_TRANSLATE_TO__';
        if (TRANSLATE_TO.indexOf('__') === 0) TRANSLATE_TO = '';
        var TRANSLATE_SCOPE = '__RTL_TRANSLATE_SCOPE__';
        if (TRANSLATE_SCOPE.indexOf('__') === 0) TRANSLATE_SCOPE = 'ui';

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
        /*__RTL_CORE__*/
        // --- END PURE DETECTION CORE ---

        // --- OPTIONAL TRANSLATION LAYER (spliced in by patch.ps1 only when enabled) ---
        /*__RTL_TRANSLATE_CODE__*/

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
                        var bang = r.style.getPropertyPriority('font-family') ? ' !important' : '';
                        // A mono stack must stay mono even for Arabic glyphs inside
                        // code; icon/math faces map codepoints privately; CSS-wide
                        // keywords can't take a prefix. These are still re-declared
                        // VERBATIM, in place: every font-family rule is copied in its
                        // original order, so a prefixed copy of an earlier rule can't
                        // overtake a later mono rule it used to lose to
                        // (e.g. class="font-claude-response font-mono").
                        var keep = /mono|icon|katex|emoji|math/i.test(ff) ||
                            /^\s*(inherit|initial|unset|revert|revert-layer)\s*$/i.test(ff);
                        css.push(prefix + r.selectorText + '{font-family:' + (keep ? '' : '"' + FAM + '",') + ff + bang + '}' + suffix);
                    } else if (r.cssRules && r.cssRules.length) {
                        // claude.ai (Tailwind v4) keeps nearly every font-family inside
                        // @layer base/components/utilities. Re-entering the same named
                        // layer keeps each copy in its original cascade layer; anonymous
                        // layers can't be re-entered and are skipped.
                        var at = '';
                        if (typeof CSSLayerBlockRule !== 'undefined' && r instanceof CSSLayerBlockRule) {
                            if (r.name) at = '@layer ' + r.name;
                        } else if (typeof CSSScopeRule !== 'undefined' && r instanceof CSSScopeRule) {
                            // A prelude-less @scope is bound to its <style>'s parent;
                            // a copy in our sheet would widen it to the whole page.
                            if (r.start) at = '@scope (' + r.start + ')' + (r.end ? ' to (' + r.end + ')' : '');
                        } else if (typeof CSSContainerRule !== 'undefined' && r instanceof CSSContainerRule) {
                            at = '@container ' + r.conditionText;
                        } else if (r.type === 12) {
                            at = '@supports ' + r.conditionText;
                        } else if (r.type === 4) {
                            at = '@media ' + r.conditionText;
                        }
                        if (at) scanRules(r.cssRules, prefix + at + '{', '}' + suffix);
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
            // (Re-)append so the shadow sheet stays behind late-loaded chunk CSS. It goes
            // after <body>, not into <head>: claude.ai loads its CSS via <link>s inside
            // <body>, which would otherwise follow us in document order and win ties.
            var root = document.documentElement;
            if (el.textContent !== text || el.parentNode !== root || el.nextSibling) {
                el.textContent = text;
                root.appendChild(el);
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

            if (TRANSLATE_TO && typeof startTranslation === 'function') {
                try { startTranslation({ lang: TRANSLATE_TO, scope: TRANSLATE_SCOPE, editorSel: EDITOR_SEL }); }
                catch (e) { console.error('[Claude RTL] translation', e); }
            }

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
