// Page translation for the renderer (like the browser's "Translate this page").
// Inlined into the payload at /*__RTL_TRANSLATE__*/ by tools/build-payload.ps1; the
// CommonJS guard at the bottom is stripped there and kept only for unit tests.
//
// Design (efficiency first):
//  * Text-node values are rewritten in place. No node is ever added, removed or moved,
//    so React's reconciliation keeps working (replacing nodes is what breaks apps
//    under whole-page translators).
//  * One request unit per BLOCK (paragraph, list item, button...), not per text node:
//    inline tags keep their places via <iN> markers, so the engine sees whole
//    sentences and translates them in context.
//  * Everything is deduplicated and cached (memory + localStorage, LRU), including the
//    "already in your language" verdict, so a block is never asked twice.
//  * Only blocks near the viewport are sent (IntersectionObserver); hidden or far
//    away history costs nothing until it is scrolled to.
//  * Streaming replies are translated only after a block has been quiet for a moment.
//  * Requests are batched (many blocks per call, bounded size) with limited
//    concurrency and exponential backoff on failure.
//  * Text already in the target script, numbers, URLs, paths and code are skipped
//    before they cost a request.
//
// Transport: the page's CSP blocks third-party fetches, so requests travel over a
// console-message channel to the main process (see src/main-payload.js), which does
// the network call and answers through window.__rtlTrResult.
//
// KEEP THIS FILE ASCII-ONLY: it is embedded in patch.ps1, which PowerShell 5.1
// reads with the ANSI code page.

var TR_PREFIX = '\u0001RTLTR\u0001';
var TR_PREFS_KEY = 'claude-rtl-translate';
var TR_CACHE_KEY = 'claude-rtl-translate-cache:';

// --- PURE HELPERS (unit-tested) ---------------------------------------------------

// Letter ranges of the scripts a target language is written in. Text that is already
// mostly in that script is not sent at all. Latin-script targets have no cheap test:
// those rely on the engine's source-language verdict, which the cache remembers.
var TR_SCRIPT_RE = {
    he: /[\u0590-\u05FF\uFB1D-\uFB4F]/g, iw: /[\u0590-\u05FF\uFB1D-\uFB4F]/g, yi: /[\u0590-\u05FF\uFB1D-\uFB4F]/g,
    ar: /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/g,
    fa: /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/g,
    ur: /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/g,
    ru: /[\u0400-\u04FF]/g, uk: /[\u0400-\u04FF]/g, bg: /[\u0400-\u04FF]/g, sr: /[\u0400-\u04FF]/g,
    el: /[\u0370-\u03FF\u1F00-\u1FFF]/g,
    hi: /[\u0900-\u097F]/g, th: /[\u0E00-\u0E7F]/g, ko: /[\uAC00-\uD7AF\u1100-\u11FF]/g,
    ja: /[\u3040-\u30FF\u4E00-\u9FFF]/g, zh: /[\u4E00-\u9FFF]/g
};

function trBaseLang(lang) {
    return String(lang || '').toLowerCase().split('-')[0].replace(/^iw$/, 'he');
}

function trLetterCount(s) {
    var m = s.match(/\p{L}/gu);
    return m ? m.length : 0;
}

// True when most letters are already in the target language's script.
function trIsTargetScript(text, lang) {
    var re = TR_SCRIPT_RE[trBaseLang(lang)] || TR_SCRIPT_RE[String(lang || '').toLowerCase()];
    if (!re) return false;
    var letters = trLetterCount(text);
    if (!letters) return false;
    var m = text.match(re);
    return !!m && m.length / letters >= 0.6;
}

// Text that must not cost a request: no letters, a URL, an e-mail, a path or an
// identifier-like token.
function trLooksUntranslatable(text) {
    var t = String(text).trim();
    if (!t || !/\p{L}/u.test(t)) return true;
    if (/^(https?:\/\/|www\.)\S+$/i.test(t)) return true;
    if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(t)) return true;
    if (!/\s/.test(t) && t.length > 2 && (/[\/\\_]|::/.test(t) || /\.[A-Za-z0-9]{1,5}$/.test(t))) return true;
    return false;
}

function trShouldTranslate(text, lang) {
    return !trLooksUntranslatable(text) && !trIsTargetScript(text, lang);
}

function trEsc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function trCodePoint(n) {
    return n > 0 && n <= 0x10FFFF ? String.fromCodePoint(n) : '';
}

function trUnesc(s) {
    return String(s)
        .replace(/&#x([0-9a-f]+);/gi, function(_, h) { return trCodePoint(parseInt(h, 16)); })
        .replace(/&#(\d+);/g, function(_, d) { return trCodePoint(parseInt(d, 10)); })
        .replace(/&nbsp;/g, '\u00A0').replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
        .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

// The engine decorates some Hebrew results with vowel points; plain text reads better.
var TR_NIQQUD_RE = /[\u0591-\u05C7]/g;
function trClean(s, lang) {
    return trBaseLang(lang) === 'he' ? s.replace(TR_NIQQUD_RE, '') : s;
}

// parts: [{k:'t', v}] translatable text nodes (numbered in order), [{k:'x', v}] opaque
// inline content (code...) kept verbatim, [{k:'w'}] a whitespace gap. A lone text part
// is sent as bare text; otherwise every text part travels as <iN>..</iN> so it can be
// matched back to its own node however the engine reorders the sentence.
function trBuildSource(parts) {
    var texts = 0, i;
    for (i = 0; i < parts.length; i++) if (parts[i].k === 't') texts++;
    if (texts === 1 && parts.length === 1) return trEsc(parts[0].v);
    var out = '', n = 0;
    for (i = 0; i < parts.length; i++) {
        var p = parts[i];
        if (p.k === 't') { out += '<i' + n + '>' + trEsc(p.v) + '</i' + n + '>'; n++; }
        else if (p.k === 'x') out += '<span class="notranslate">' + trEsc(p.v) + '</span>';
        else out += ' ';
    }
    return out;
}

// -> array of translated strings indexed by text part, or null entries for parts the
// engine dropped. A bare-text source yields a one-element array.
function trParseResult(translated, textCount) {
    var res = [], i;
    for (i = 0; i < textCount; i++) res.push(null);
    if (textCount === 1 && !/<i\d+>/.test(translated)) {
        res[0] = trUnesc(translated.replace(/<[^>]+>/g, ''));
        return res;
    }
    var re = /<i(\d+)>([\s\S]*?)<\/i\1>/g, m;
    while ((m = re.exec(translated))) {
        var idx = +m[1];
        if (idx < textCount) res[idx] = trUnesc(m[2].replace(/<[^>]+>/g, ''));
    }
    return res;
}

// Keep the node's own surrounding whitespace; only the words are replaced.
function trRewrap(orig, translated) {
    var lead = (/^\s*/.exec(orig) || [''])[0];
    var trail = (/\s*$/.exec(orig) || [''])[0];
    var core = translated.trim();
    return core ? lead + core + trail : orig;
}

// Splits unique sources into request batches bounded by item count and size.
function trPlanBatches(srcs, maxItems, maxChars) {
    var batches = [], cur = [], size = 0;
    for (var i = 0; i < srcs.length; i++) {
        var len = srcs[i].length;
        if (cur.length && (cur.length >= maxItems || size + len > maxChars)) {
            batches.push(cur); cur = []; size = 0;
        }
        cur.push(srcs[i]); size += len;
    }
    if (cur.length) batches.push(cur);
    return batches;
}

// LRU over a Map (insertion order); persists through a storage-like object.
function trCreateCache(storage, lang, maxEntries, maxChars) {
    var key = TR_CACHE_KEY + lang;
    var map = new Map();
    var chars = 0;
    var timer = null;
    try {
        var raw = storage && storage.getItem(key);
        var arr = raw ? JSON.parse(raw) : [];
        for (var i = 0; i < arr.length; i++) {
            if (typeof arr[i][0] === 'string' && typeof arr[i][1] === 'string') {
                map.set(arr[i][0], arr[i][1]); chars += arr[i][0].length + arr[i][1].length;
            }
        }
    } catch (e) { map.clear(); chars = 0; }

    function trim() {
        while (map.size > maxEntries || chars > maxChars) {
            var first = map.keys().next();
            if (first.done) break;
            chars -= first.value.length + map.get(first.value).length;
            map.delete(first.value);
        }
    }
    function persist() {
        timer = null;
        try { storage.setItem(key, JSON.stringify(Array.from(map.entries()))); } catch (e) {}
    }
    return {
        get: function(src) {
            if (!map.has(src)) return undefined;
            var v = map.get(src);
            map.delete(src); map.set(src, v); // refresh recency
            return v;
        },
        set: function(src, val) {
            if (src.length > 4000) return;
            if (map.has(src)) chars -= src.length + map.get(src).length;
            map.set(src, val); chars += src.length + val.length;
            trim();
            if (storage && !timer) timer = setTimeout(persist, 3000);
        },
        size: function() { return map.size; },
        flush: persist
    };
}

// Console-message transport to the main process (see the file header).
function trCreateBridgeTransport(win, log) {
    var seq = 0, pending = {};
    win.__rtlTrResult = function(r) {
        var p = r && pending[r.id];
        if (!p) return;
        delete pending[r.id];
        clearTimeout(p.timer);
        if (r.ok && Array.isArray(r.r)) p.resolve(r.r); else p.reject(new Error(r.e || 'bad response'));
    };
    return function(lang, queries) {
        return new Promise(function(resolve, reject) {
            var id = ++seq;
            pending[id] = { resolve: resolve, reject: reject, timer: setTimeout(function() {
                delete pending[id]; reject(new Error('timeout'));
            }, 25000) };
            log(TR_PREFIX + JSON.stringify({ id: id, tl: lang, q: queries }));
        });
    };
}

// --- DOM LAYER ---------------------------------------------------------------------

var TR_INLINE_RE = /^(A|B|I|EM|STRONG|U|S|SMALL|SUB|SUP|MARK|ABBR|CITE|Q|DEL|INS|BDI|BDO|TIME|DFN|VAR|FONT)$/;
var TR_TEXTISH_RE = /^(P|LI|H[1-6]|TD|TH|BLOCKQUOTE|DD|DT|SUMMARY|FIGCAPTION|CAPTION|LABEL|LEGEND|BUTTON)$/;
// Never translated, never entered.
var TR_SKIP_TAG_RE = /^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA|INPUT|SELECT|OPTION|CODE|PRE|KBD|SAMP|SVG|MATH|MJX-CONTAINER|CANVAS|IFRAME|TEMPLATE|HEAD)$/;
var TR_SKIP_SEL = '[translate="no"], .notranslate, .katex, .katex-display, [data-rtl-island], [data-rtl-tr-ui]';
var TR_ATTRS = ['placeholder', 'title', 'aria-label'];
var TR_MAX_NODES_PER_BLOCK = 120;

// opts: { lang, scope: 'ui'|'all', transport, storage, doc, win, editorSel, contentSel }
function createTranslator(opts) {
    var doc = opts.doc || document, win = opts.win || window;
    var lang = opts.lang, scope = opts.scope === 'all' ? 'all' : 'ui';
    var EDITOR = opts.editorSel || '[contenteditable="true"], .ProseMirror, [role="textbox"]';
    var CONTENT = opts.contentSel || '[data-alluvium], .font-claude-response, .font-claude-message, [data-testid="user-message"], .font-user-message, [data-is-streaming], a[href*="/chat/"]';
    var SETTLE_UI = 60, SETTLE_CONTENT = 800, TICK = 120;

    var enabled = false;
    var cache = trCreateCache(opts.storage, lang, 3000, 700000);
    var nodeRec = new WeakMap();     // text node -> { orig, tr }
    var attrRec = new WeakMap();     // element -> { attr: { orig, tr } }
    var applied = new Set();         // strong refs for restore; pruned when detached
    var appliedAttrs = new Set();
    var dirty = new Map();           // block root -> last change time
    var visible = new WeakMap();     // block root -> bool (IntersectionObserver)
    var pendingEls = new Set();
    var queue = new Map();           // src -> [task]
    var failed = new Set();          // srcs that failed too often this session
    var inflight = 0, failures = 0, backoffUntil = 0, tickTimer = null, pruneTimer = null;
    var obs = null, io = null;

    function inEditor(el) { return !!(el.closest && el.closest(EDITOR)); }
    function inContent(el) { return !!(el.closest && el.closest(CONTENT)); }
    function allowed(el) {
        if (!el || inEditor(el)) return false;
        if (el.closest && el.closest(TR_SKIP_SEL)) return false;
        if (scope === 'ui' && inContent(el)) return false;
        return true;
    }
    function skippedEl(el) {
        return TR_SKIP_TAG_RE.test(el.tagName) || !!(el.matches && el.matches(TR_SKIP_SEL)) ||
            (el.isContentEditable === true);
    }
    function isInline(el) {
        if (!el) return false;
        if (TR_INLINE_RE.test(el.tagName)) return true;
        if (el.tagName !== 'SPAN') return false;
        var p = el.parentElement;
        return !!p && (TR_TEXTISH_RE.test(p.tagName) || isInline(p));
    }
    function blockRoot(node) {
        var el = node.parentElement;
        while (el && isInline(el)) el = el.parentElement;
        return el;
    }
    function origOf(node) {
        var r = nodeRec.get(node);
        return r && r.tr === node.nodeValue ? r.orig : node.nodeValue;
    }

    // Walks a block root in document order into parts. Nested block elements are other
    // roots' business and are not entered.
    function collectParts(root) {
        var parts = [], nodes = [];
        (function walk(el) {
            for (var c = el.firstChild; c; c = c.nextSibling) {
                if (c.nodeType === 3) {
                    var v = origOf(c);
                    if (/\S/.test(v)) { parts.push({ k: 't', v: v, node: c }); nodes.push(c); }
                    else if (parts.length) parts.push({ k: 'w' });
                } else if (c.nodeType === 1) {
                    if (skippedEl(c)) {
                        if (isInline(c) || /^(CODE|KBD|SAMP)$/.test(c.tagName)) {
                            var txt = (c.textContent || '').slice(0, 80);
                            if (txt) parts.push({ k: 'x', v: txt });
                        }
                    } else if (c.tagName === 'BR') {
                        parts.push({ k: 'w' });
                    } else if (isInline(c)) {
                        walk(c);
                    }
                }
            }
        })(root);
        return nodes.length ? parts : null;
    }

    function textParts(parts) { return parts.filter(function(p) { return p.k === 't'; }); }

    function writeNode(node, expectedCur, translated) {
        if (!node.isConnected || node.nodeValue !== expectedCur) return false;
        var orig = origOf(node);
        var next = trRewrap(orig, trClean(translated, lang));
        if (next === node.nodeValue) return true;
        nodeRec.set(node, { orig: orig, tr: next });
        applied.add(node);
        node.nodeValue = next;
        return true;
    }

    // Applies per-index translations to a task's nodes. Returns the indices still
    // missing (the engine dropped the marker).
    function applyTask(task, results) {
        var missing = [];
        for (var i = 0; i < task.texts.length; i++) {
            var t = task.texts[i];
            if (results[i] == null) { missing.push(i); continue; }
            if (results[i] === '') continue;          // verdict "already in your language"
            writeNode(t.node, t.cur, results[i]);
        }
        return missing;
    }

    function encodeEntry(results) { return results.map(function(r) { return r == null ? '' : r; }).join('\u0001'); }
    function decodeEntry(val, n) {
        var arr = val.split('\u0001');
        if (n === 1 && arr.length !== 1) arr = [val];
        return arr.length === n ? arr : null;
    }

    function buildTask(root) {
        var parts = collectParts(root);
        if (!parts) return null;
        var texts = textParts(parts);
        if (texts.length > TR_MAX_NODES_PER_BLOCK) return null;
        var any = false;
        for (var i = 0; i < texts.length; i++) if (trShouldTranslate(texts[i].v, lang)) { any = true; break; }
        if (!any) return null;
        texts.forEach(function(t) { t.cur = t.node.nodeValue; });
        return { root: root, parts: parts, texts: texts, src: trBuildSource(parts) };
    }

    // --- scheduling ---
    function markDirty(root) {
        if (!root || !root.isConnected) return;
        if (!dirty.has(root) && io) io.observe(root);
        dirty.set(root, Date.now());
        schedule();
    }
    function schedule() {
        if (tickTimer || !enabled) return;
        tickTimer = setTimeout(tick, TICK);
    }

    function scanSubtree(el) {
        if (!el.isConnected || !allowed(el.nodeType === 1 ? el : el.parentElement)) return;
        var base = el.nodeType === 1 ? el : el.parentElement;
        var walker = doc.createTreeWalker(base, NodeFilter.SHOW_TEXT, {
            acceptNode: function(n) {
                if (!/\S/.test(n.nodeValue)) return NodeFilter.FILTER_REJECT;
                var p = n.parentElement;
                if (!p || skippedEl(p) || p.closest('code, pre, ' + TR_SKIP_SEL)) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        var seen = new Set(), n, count = 0;
        while ((n = walker.nextNode())) {
            if (++count > 20000) break;
            var r = blockRoot(n);
            if (!r || seen.has(r)) continue;
            seen.add(r);
            if (allowed(r)) markDirty(r);
        }
        if (base.querySelectorAll) scanAttrs(base);
    }

    function scanAttrs(base) {
        var sel = TR_ATTRS.map(function(a) { return '[' + a + ']'; }).join(',');
        var els = Array.from(base.querySelectorAll(sel));
        if (base.matches && base.matches(sel)) els.unshift(base);
        var limit = Math.min(els.length, 300);
        for (var i = 0; i < limit; i++) {
            var el = els[i];
            if (!allowed(el) || el.tagName === 'INPUT' && el.type === 'password') continue;
            TR_ATTRS.forEach(function(a) { queueAttr(el, a); });
        }
    }

    function queueAttr(el, attr) {
        var v = el.getAttribute(attr);
        if (!v) return;
        var rec = attrRec.get(el), cur = rec && rec[attr];
        if (cur && cur.tr === v) return;               // our own write
        if (!trShouldTranslate(v, lang)) return;
        var src = trEsc(v);
        var task = { attrEl: el, attr: attr, cur: v, src: src, texts: [] };
        var hit = cache.get(src);
        if (hit !== undefined) { applyAttr(task, hit); return; }
        enqueue(task);
    }
    // tr: final (already unescaped) text; '' = nothing to change.
    function applyAttr(task, tr) {
        if (!tr) return;
        var el = task.attrEl;
        if (!el.isConnected || el.getAttribute(task.attr) !== task.cur) return;
        var next = trClean(tr, lang);
        var rec = attrRec.get(el) || {};
        rec[task.attr] = { orig: task.cur, tr: next };
        attrRec.set(el, rec);
        appliedAttrs.add(el);
        el.setAttribute(task.attr, next);
    }

    function enqueue(task) {
        if (failed.has(task.src)) return;
        var list = queue.get(task.src);
        if (list) list.push(task); else queue.set(task.src, [task]);
    }

    function tick() {
        tickTimer = null;
        if (!enabled) return;
        var now = Date.now(), waiting = false;
        dirty.forEach(function(last, root) {
            if (!root.isConnected) { dirty.delete(root); if (io) io.unobserve(root); return; }
            // Off-screen blocks cost nothing until the IntersectionObserver reports them.
            if (io && visible.get(root) !== true) return;
            var task = buildTask(root);
            if (!task) { dirty.delete(root); if (io) io.unobserve(root); return; }
            var hit = cache.get(task.src);
            if (hit !== undefined) {                  // cached: instant, no flash of the source text
                var res = decodeEntry(hit, task.texts.length);
                if (res) { applyTask(task, res); dirty.delete(root); if (io) io.unobserve(root); return; }
            }
            if (now - last < (inContent(root) ? SETTLE_CONTENT : SETTLE_UI)) { waiting = true; return; }
            enqueue(task);
            dirty.delete(root);
            if (io) io.unobserve(root);
        });
        drainPending();
        pump();
        if (waiting) schedule();
    }
    function drainPending() {
        if (!pendingEls.size) return;
        var els = Array.from(pendingEls);
        pendingEls.clear();
        els.forEach(function(el) { try { scanSubtree(el); } catch (e) {} });
        if (dirty.size) schedule();
    }

    function pump() {
        if (!enabled || inflight >= 2 || Date.now() < backoffUntil || !queue.size) return;
        var srcs = Array.from(queue.keys());
        var batch = trPlanBatches(srcs, 40, 4500)[0];
        var taken = batch.map(function(s) { var l = queue.get(s); queue.delete(s); return { src: s, tasks: l }; });
        inflight++;
        opts.transport(lang, batch).then(function(res) {
            inflight--; failures = 0;
            taken.forEach(function(item, i) {
                try { settle(item, res[i]); } catch (e) { failed.add(item.src); }
            });
            pump();
        }, function() {
            inflight--; failures++;
            backoffUntil = Date.now() + Math.min(60000, 1000 * Math.pow(2, failures));
            taken.forEach(function(item) {
                item.tasks.forEach(function(t) { t.tries = (t.tries || 0) + 1; });
                if (item.tasks[0].tries >= 3) failed.add(item.src);
                else item.tasks.forEach(enqueue);
            });
            setTimeout(function() { schedule(); pump(); }, backoffUntil - Date.now() + 10);
        });
        if (queue.size) pump();
    }
    function settle(item, pair) {
        if (!pair || typeof pair[0] !== 'string') { failed.add(item.src); return; }
        var sameLang = typeof pair[1] === 'string' && trBaseLang(pair[1]) === trBaseLang(lang);
        var first = item.tasks[0];
        var n = first.attrEl ? 1 : first.texts.length;
        var results = sameLang ? filled(n, '') : trParseResult(pair[0], n);
        var missing = results.map(function(r, i) { return r == null ? i : -1; }).filter(function(i) { return i >= 0; });
        if (!missing.length) cache.set(item.src, encodeEntry(results));
        item.tasks.forEach(function(task) {
            if (task.attrEl) { applyAttr(task, results[0]); return; }
            var miss = applyTask(task, results);
            // Marker dropped by the engine: translate those nodes on their own (once).
            if (miss.length && !task.fallback && task.texts.length > 1) {
                miss.forEach(function(i) {
                    var t = task.texts[i];
                    if (!trShouldTranslate(t.v, lang)) return;
                    enqueue({ root: task.root, parts: [t], texts: [t], src: trEsc(t.v), fallback: true });
                });
            }
        });
    }
    function filled(n, v) { var a = []; for (var i = 0; i < n; i++) a.push(v); return a; }

    // --- observation ---
    function onMutations(muts) {
        for (var i = 0; i < muts.length; i++) {
            var m = muts[i];
            if (m.type === 'attributes') {
                if (allowed(m.target)) queueAttr(m.target, m.attributeName);
                schedule();
            } else if (m.type === 'characterData') {
                var node = m.target, rec = nodeRec.get(node);
                if (rec && rec.tr === node.nodeValue) continue;   // our own write
                if (rec) nodeRec.delete(node);                    // React wrote a new original
                var r = node.parentElement && blockRoot(node);
                if (r && allowed(r)) markDirty(r);
            } else {
                for (var j = 0; j < m.addedNodes.length; j++) {
                    var a = m.addedNodes[j];
                    if (a.nodeType === 1 || a.nodeType === 3) pendingEls.add(a);
                }
            }
        }
        if (pendingEls.size) schedule();
    }

    function onIntersect(entries) {
        entries.forEach(function(e) { visible.set(e.target, e.isIntersecting); });
        schedule();
    }

    function prune() {
        applied.forEach(function(n) { if (!n.isConnected) applied.delete(n); });
        appliedAttrs.forEach(function(e) { if (!e.isConnected) appliedAttrs.delete(e); });
    }

    function restoreAll() {
        applied.forEach(function(n) {
            var r = nodeRec.get(n);
            if (r && n.nodeValue === r.tr) n.nodeValue = r.orig;
            nodeRec.delete(n);
        });
        applied.clear();
        appliedAttrs.forEach(function(el) {
            var rec = attrRec.get(el) || {};
            Object.keys(rec).forEach(function(a) {
                if (el.getAttribute(a) === rec[a].tr) el.setAttribute(a, rec[a].orig);
            });
            attrRec.delete(el);
        });
        appliedAttrs.clear();
    }

    function start() {
        if (enabled || !doc.body) return;
        enabled = true;
        if (typeof IntersectionObserver === 'function') {
            io = new IntersectionObserver(onIntersect, { rootMargin: '1200px 0px' });
        }
        obs = new MutationObserver(onMutations);
        obs.observe(doc.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: TR_ATTRS });
        pendingEls.add(doc.body);
        schedule();
        pruneTimer = setInterval(prune, 30000);
    }
    function stop() {
        enabled = false;
        if (obs) { obs.disconnect(); obs = null; }
        if (io) { io.disconnect(); io = null; }
        if (tickTimer) { clearTimeout(tickTimer); tickTimer = null; }
        if (pruneTimer) { clearInterval(pruneTimer); pruneTimer = null; }
        dirty.clear(); queue.clear(); pendingEls.clear(); failed.clear();
        restoreAll();
        cache.flush();
    }

    return {
        start: start,
        stop: stop,
        isOn: function() { return enabled; },
        getScope: function() { return scope; },
        setScope: function(s) {
            s = s === 'all' ? 'all' : 'ui';
            if (s === scope) return;
            var was = enabled;
            if (was) stop();
            scope = s;
            if (was) start();
        },
        // test hooks
        _tick: tick, _cache: cache
    };
}

// Reads/writes the runtime on/off + scope override (hotkeys); never throws.
function trLoadPrefs(storage) {
    try {
        var p = JSON.parse(storage.getItem(TR_PREFS_KEY) || 'null');
        if (p && typeof p === 'object') return { on: p.on !== false, scope: p.scope === 'all' ? 'all' : (p.scope === 'ui' ? 'ui' : null) };
    } catch (e) {}
    return { on: true, scope: null };
}
function trSavePrefs(storage, prefs) {
    try { storage.setItem(TR_PREFS_KEY, JSON.stringify(prefs)); } catch (e) {}
}

// Wires the translator into the page: patch-time defaults, runtime hotkeys
// (Ctrl+Alt+Shift+T on/off, Ctrl+Alt+Shift+Y interface-only <-> everything).
function startTranslation(cfg) {
    var storage = null;
    try { storage = window.localStorage; } catch (e) {}
    var prefs = trLoadPrefs(storage || { getItem: function() { return null; } });
    var consoleDebug = console.debug.bind(console);
    var tr = createTranslator({
        lang: cfg.lang, scope: prefs.scope || cfg.scope, storage: storage,
        editorSel: cfg.editorSel,
        transport: trCreateBridgeTransport(window, consoleDebug)
    });

    function toast(text) {
        var t = document.getElementById('claude-rtl-tr-toast');
        if (!t) {
            t = document.createElement('div');
            t.id = 'claude-rtl-tr-toast';
            t.setAttribute('data-rtl-tr-ui', '1');
            t.setAttribute('translate', 'no');
            t.style.cssText = 'position:fixed;bottom:18px;left:50%;transform:translateX(-50%);z-index:2147483647;' +
                'background:#222;color:#fff;font:13px/1.4 system-ui,sans-serif;padding:8px 14px;border-radius:8px;' +
                'box-shadow:0 2px 10px rgba(0,0,0,.35);pointer-events:none;direction:ltr';
            document.documentElement.appendChild(t);
        }
        t.textContent = text;
        clearTimeout(t._h);
        t._h = setTimeout(function() { if (t.parentNode) t.parentNode.removeChild(t); }, 1800);
    }
    function label() {
        return 'Translation ' + (tr.isOn() ? 'ON' : 'OFF') + ' (' + cfg.lang + ', ' +
            (tr.getScope() === 'all' ? 'everything' : 'interface only') + ')';
    }

    document.addEventListener('keydown', function(e) {
        if (!(e.ctrlKey && e.altKey && e.shiftKey) || e.metaKey) return;
        if (e.getModifierState && e.getModifierState('AltGraph')) return;
        if (e.code === 'KeyT') {
            if (tr.isOn()) tr.stop(); else tr.start();
            trSavePrefs(storage, { on: tr.isOn(), scope: tr.getScope() });
            toast(label()); e.preventDefault();
        } else if (e.code === 'KeyY') {
            tr.setScope(tr.getScope() === 'all' ? 'ui' : 'all');
            trSavePrefs(storage, { on: tr.isOn(), scope: tr.getScope() });
            toast(label()); e.preventDefault();
        }
    }, true);

    if (prefs.on) tr.start();
    return tr;
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        trBaseLang, trIsTargetScript, trLooksUntranslatable, trShouldTranslate, trEsc, trUnesc, trClean,
        trBuildSource, trParseResult, trRewrap, trPlanBatches, trCreateCache, trCreateBridgeTransport,
        createTranslator, trLoadPrefs, trSavePrefs, TR_PREFIX
    };
}
