'use strict';

// Page translation: pure helpers (src/translate.js), the main-process bridge
// (src/main-payload.js), and the contract with patch.ps1 / the renderer payload.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');

const root = path.join(__dirname, '..');
const read = f => fs.readFileSync(path.join(root, f), 'utf8').replace(/\r\n/g, '\n');
const T = require('../src/translate.js');

global.__claudeRtlMainTest = true; // keep the injected IIFE inert under test
const { claudeRtlMainInstall } = require('../src/main-payload.js');

// ---------- pure helpers ----------

test('escape / unescape round-trips markup characters and entities', () => {
    assert.strictEqual(T.trEsc('a & b <c> "d"'), 'a &amp; b &lt;c&gt; "d"');
    assert.strictEqual(T.trUnesc('a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39; &#x41;&#66;'), 'a & b <c> "d" \'e\' AB');
    assert.strictEqual(T.trUnesc('&#99999999;'), '', 'invalid code points are dropped, not thrown');
    const s = 'x < y && z > "w"';
    assert.strictEqual(T.trUnesc(T.trEsc(s)), s);
});

test('target-script detection skips text already in the target language', () => {
    assert.ok(T.trIsTargetScript('שלום עולם', 'he'));
    assert.ok(T.trIsTargetScript('שלום', 'iw'), 'iw is an alias of he');
    assert.ok(!T.trIsTargetScript('Hello world', 'he'));
    assert.ok(!T.trIsTargetScript('Hello ש', 'he'), 'mostly Latin stays translatable');
    assert.ok(T.trIsTargetScript('привет', 'ru'));
    assert.ok(T.trIsTargetScript('مرحبا', 'ar'));
    assert.ok(!T.trIsTargetScript('Bonjour', 'fr'), 'Latin targets have no script shortcut');
});

test('untranslatable text never costs a request', () => {
    for (const s of ['', '   ', '12345', '3.14 %', '\u{1F600}', 'https://example.com/a?b=1', 'www.example.com',
        'me@example.com', 'src/main.js', 'node_modules', 'foo::bar', 'index.html']) {
        assert.ok(T.trLooksUntranslatable(s), JSON.stringify(s));
    }
    for (const s of ['Settings', 'Hello world', 'New chat', 'Yes. No!']) {
        assert.ok(!T.trLooksUntranslatable(s), JSON.stringify(s));
    }
    assert.ok(T.trShouldTranslate('Settings', 'he'));
    assert.ok(!T.trShouldTranslate('הגדרות', 'he'));
});

test('niqqud is stripped for Hebrew only', () => {
    const withPoints = 'לִפְתוֹחַ';
    assert.strictEqual(T.trClean(withPoints, 'he'), 'לפתוח');
    assert.strictEqual(T.trClean(withPoints, 'iw'), 'לפתוח');
    assert.strictEqual(T.trClean(withPoints, 'ar'), withPoints);
});

test('source building: lone text is bare, mixed blocks carry numbered tags', () => {
    assert.strictEqual(T.trBuildSource([{ k: 't', v: 'Save & exit' }]), 'Save &amp; exit');
    const src = T.trBuildSource([
        { k: 't', v: 'Run ' }, { k: 'x', v: 'npm i' }, { k: 't', v: ' now' }, { k: 'w' }, { k: 't', v: 'Done' }
    ]);
    assert.strictEqual(src, '<i0>Run </i0><span class="notranslate">npm i</span><i1> now</i1> <i2>Done</i2>');
});

test('result parsing maps tags back to their own node, in any order', () => {
    const out = T.trParseResult('<i2>c &amp; d</i2> <i0>a</i0><b>x</b><i1><u>b</u></i1>', 3);
    assert.deepStrictEqual(out, ['a', 'b', 'c & d']);
    assert.deepStrictEqual(T.trParseResult('<i0>only</i0>', 2), ['only', null], 'dropped marker -> null');
    assert.deepStrictEqual(T.trParseResult('plain &lt;text&gt;', 1), ['plain <text>']);
    assert.deepStrictEqual(T.trParseResult('<i9>stray</i9>', 2), [null, null], 'out-of-range index ignored');
});

test('rewrap keeps the node\'s own surrounding whitespace', () => {
    assert.strictEqual(T.trRewrap('  Hello ', ' world\n'), '  world ');
    assert.strictEqual(T.trRewrap('Hello', ''), 'Hello', 'empty translation leaves the original');
});

test('batch planning respects item and size limits and keeps order', () => {
    const srcs = Array.from({ length: 7 }, (_, i) => 'x'.repeat(10) + i);
    assert.deepStrictEqual(T.trPlanBatches(srcs, 3, 10000).map(b => b.length), [3, 3, 1]);
    assert.deepStrictEqual(T.trPlanBatches(srcs, 100, 25).map(b => b.length), [2, 2, 2, 1]);
    assert.deepStrictEqual(T.trPlanBatches(srcs, 3, 10000).flat(), srcs);
    assert.deepStrictEqual(T.trPlanBatches(['y'.repeat(50)], 5, 20), [['y'.repeat(50)]], 'an oversized item travels alone');
    assert.deepStrictEqual(T.trPlanBatches([], 5, 20), []);
});

test('cache: LRU eviction, recency refresh and persistence', () => {
    const store = {};
    const storage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = v; } };
    const c = T.trCreateCache(storage, 'he', 3, 1e6);
    c.set('a', '1'); c.set('b', '2'); c.set('c', '3');
    assert.strictEqual(c.get('a'), '1');           // a becomes most recent
    c.set('d', '4');                               // evicts b
    assert.strictEqual(c.get('b'), undefined);
    assert.strictEqual(c.get('a'), '1');
    assert.strictEqual(c.size(), 3);
    c.flush();
    const c2 = T.trCreateCache(storage, 'he', 3, 1e6);
    assert.strictEqual(c2.get('d'), '4');
    const other = T.trCreateCache(storage, 'fr', 3, 1e6);
    assert.strictEqual(other.size(), 0, 'each language has its own cache');
    storage.setItem('claude-rtl-translate-cache:xx', '{not json');
    assert.strictEqual(T.trCreateCache(storage, 'xx', 3, 1e6).size(), 0, 'corrupt storage is ignored');
    const big = T.trCreateCache(null, 'he', 10, 1e6);
    big.set('z'.repeat(4001), 'v');
    assert.strictEqual(big.size(), 0, 'oversized sources are not cached');
});

test('bridge transport: correlates replies by id and times out cleanly', async () => {
    const win = {};
    const sent = [];
    const send = T.trCreateBridgeTransport(win, m => sent.push(m));
    const p = send('he', ['a', 'b']);
    assert.ok(sent[0].startsWith(T.TR_PREFIX));
    const req = JSON.parse(sent[0].slice(T.TR_PREFIX.length));
    assert.deepStrictEqual([req.tl, req.q], ['he', ['a', 'b']]);
    win.__rtlTrResult({ id: req.id, ok: true, r: [['x', 'en'], ['y', 'en']] });
    assert.deepStrictEqual(await p, [['x', 'en'], ['y', 'en']]);
    const p2 = send('he', ['c']);
    win.__rtlTrResult({ id: JSON.parse(sent[1].slice(T.TR_PREFIX.length)).id, ok: false, e: 'http 429' });
    await assert.rejects(p2, /http 429/);
    win.__rtlTrResult({ id: 999, ok: true, r: [] });  // unknown id: ignored
});

// ---------- main-process bridge ----------

function fakeElectron(fetchImpl) {
    const app = new EventEmitter();
    const switches = [];
    app.commandLine = { appendSwitch: (...a) => switches.push(a) };
    const wc = new EventEmitter();
    wc.executed = [];
    wc.isDestroyed = () => false;
    wc.executeJavaScript = js => { wc.executed.push(js); return Promise.resolve(); };
    return { app, wc, switches, net: { fetch: fetchImpl }, webContents: { getAllWebContents: () => [] } };
}
const tick = () => new Promise(r => setImmediate(r));
const MSG = obj => T.TR_PREFIX + JSON.stringify(obj);

test('main: always forces LTR UI, bridge only when a language is set', () => {
    const off = fakeElectron(() => { throw new Error('unused'); });
    claudeRtlMainInstall(off, '');
    assert.deepStrictEqual(off.switches, [['force-ui-direction', 'ltr']]);
    assert.strictEqual(off.app.listenerCount('web-contents-created'), 0);
    const on = fakeElectron(() => { throw new Error('unused'); });
    claudeRtlMainInstall(on, 'he');
    assert.strictEqual(on.app.listenerCount('web-contents-created'), 1);
});

test('main: relays a request to the fixed endpoint and answers the sender', async () => {
    const calls = [];
    const el = fakeElectron(async (url, init) => {
        calls.push({ url, init });
        return { ok: true, json: async () => [['shalom', 'en'], ['olam', 'en']] };
    });
    claudeRtlMainInstall(el, 'he');
    el.app.emit('web-contents-created', {}, el.wc);
    // Electron >= 35 style (one event object)
    el.wc.emit('console-message', { message: MSG({ id: 7, tl: 'pt-BR', q: ['Hi & bye', 'World'] }) });
    await tick(); await tick();
    assert.strictEqual(calls.length, 1);
    assert.ok(calls[0].url.startsWith('https://translate.googleapis.com/translate_a/t?'));
    assert.ok(calls[0].url.endsWith('&tl=pt-BR'));
    assert.strictEqual(calls[0].init.method, 'POST');
    assert.strictEqual(calls[0].init.body, 'q=Hi%20%26%20bye&q=World');
    assert.strictEqual(el.wc.executed.length, 1);
    const reply = JSON.parse(el.wc.executed[0].match(/__rtlTrResult\((.*)\)$/)[1]);
    assert.deepStrictEqual(reply, { id: 7, ok: true, r: [['shalom', 'en'], ['olam', 'en']] });
    // legacy positional signature
    el.wc.emit('console-message', {}, 0, MSG({ id: 8, tl: 'he', q: ['x'] }), 1, 'src');
    await tick(); await tick();
    assert.strictEqual(calls.length, 2);
});

test('main: reports failures to the renderer instead of dropping them', async () => {
    const el = fakeElectron(async () => ({ ok: false, status: 429 }));
    claudeRtlMainInstall(el, 'he');
    el.app.emit('web-contents-created', {}, el.wc);
    el.wc.emit('console-message', { message: MSG({ id: 1, tl: 'he', q: ['x'] }) });
    await tick(); await tick();
    const reply = JSON.parse(el.wc.executed[0].match(/__rtlTrResult\((.*)\)$/)[1]);
    assert.strictEqual(reply.ok, false);
    assert.match(reply.e, /429/);
});

test('main: rejects malformed, oversized or unrelated messages', async () => {
    let n = 0;
    const el = fakeElectron(async () => { n++; return { ok: true, json: async () => [] }; });
    claudeRtlMainInstall(el, 'he');
    el.app.emit('web-contents-created', {}, el.wc);
    const bad = [
        'plain log line',
        T.TR_PREFIX + '{not json',
        MSG({ id: 'x', tl: 'he', q: ['a'] }),
        MSG({ id: 1, tl: 'he&evil=1', q: ['a'] }),
        MSG({ id: 1, tl: 'he/../x', q: ['a'] }),
        MSG({ id: 1, tl: 'he', q: [] }),
        MSG({ id: 1, tl: 'he', q: [1] }),
        MSG({ id: 1, tl: 'he', q: new Array(81).fill('a') }),
        MSG({ id: 1, tl: 'he', q: ['a'.repeat(40001)] })
    ];
    for (const m of bad) el.wc.emit('console-message', { message: m });
    await tick();
    assert.strictEqual(n, 0);
    assert.strictEqual(el.wc.executed.length, 0);
});

// ---------- contract with patch.ps1 and the renderer payload ----------

const payload = read('src/rtl-payload.js');
const patch = read('patch.ps1');

test('payload carries each translation placeholder once and they cannot overlap', () => {
    const TO = '__RTL_TRANSLATE_TO__', SC = '__RTL_TRANSLATE_SCOPE__', CODE = '/*__RTL_TRANSLATE_CODE__*/';
    assert.ok(!SC.includes(TO) && !TO.includes(SC));
    for (const ph of [TO, SC, CODE]) assert.strictEqual(payload.split(ph).length - 1, 1, ph);
    assert.strictEqual(read('src/main-payload.js').split(TO).length - 1, 1);
});

test('assembled payload parses with translation on and off', () => {
    let core = read('src/rtl-core.js');
    core = core.slice(0, core.indexOf('if (typeof module !==')).trimEnd();
    let trans = read('src/translate.js');
    trans = trans.slice(0, trans.indexOf('if (typeof module !==')).trimEnd();
    for (const code of [trans, '']) {
        for (const [to, scope] of [['he', 'ui'], ['pt-BR', 'all'], ['', 'ui']]) {
            const src = payload.replace('/*__RTL_CORE__*/', () => core)
                .replace('/*__RTL_TRANSLATE_CODE__*/', () => code)
                .replace('__RTL_TRANSLATE_SCOPE__', scope).replace('__RTL_TRANSLATE_TO__', to);
            assert.doesNotThrow(() => new vm.Script(src), `to='${to}' scope=${scope} code=${!!code}`);
        }
    }
});

test('embedded sources are ASCII-only (patch.ps1 is read as ANSI by PS 5.1)', () => {
    for (const f of ['src/translate.js', 'src/main-payload.js']) {
        assert.ok(!/[^\x00-\x7F]/.test(read(f)), f);
    }
});

test('patch.ps1 embeds the current translate.js and main-payload.js (run npm run build)', () => {
    const strip = t => t.slice(0, t.indexOf('if (typeof module !==')).trimEnd();
    const between = (a, b) => {
        const i = patch.indexOf(a), j = patch.indexOf(b);
        assert.ok(i >= 0 && j > i, `markers ${a}`);
        return patch.slice(i + a.length, j).trim();
    };
    assert.strictEqual(between('// --- CLAUDE RTL TRANSLATE START ---', '// --- CLAUDE RTL TRANSLATE END ---'),
        strip(read('src/translate.js')));
    assert.strictEqual(between('// --- CLAUDE RTL MAIN PATCH START ---', '// --- CLAUDE RTL MAIN PATCH END ---'),
        strip(read('src/main-payload.js')));
});

test('patch.ps1 language/scope whitelists match the JS side', () => {
    const lang = /\$script:TranslateLangRe\s*=\s*'([^']+)'/.exec(patch)[1];
    const scope = /\$script:TranslateScopeRe\s*=\s*'([^']+)'/.exec(patch)[1];
    const L = new RegExp(lang), S = new RegExp(scope, 'i');
    for (const ok of ['he', 'ar', 'fr', 'pt-BR', 'zh-CN', 'fil']) assert.ok(L.test(ok), ok);
    for (const bad of ['', 'h', "he'; alert(1); '", 'he/x', 'hebrew1', 'he-', 'a b', 'he\n']) assert.ok(!L.test(bad), JSON.stringify(bad));
    assert.ok(S.test('ui') && S.test('all') && !S.test('everything'));
    // The main-process side validates with the same shape.
    const mainLang = /var LANG_RE = (\/.+\/);/.exec(read('src/main-payload.js'))[1];
    assert.strictEqual(mainLang, '/' + lang + '/');
});
