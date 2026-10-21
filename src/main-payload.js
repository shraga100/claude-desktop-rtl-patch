// Main-process payload, injected at the top of the main entry (index.pre.js) before
// app 'ready'. Spliced into patch.ps1's $MAIN_INJECTION_CODE by
// tools/build-payload.ps1; the CommonJS guard at the bottom is stripped there and kept
// only for unit tests. Kept tiny and DOM-free to avoid interfering with MCP startup
// (#14); every step is wrapped so a failure can never keep Claude from starting.
//
// 1. Forces Chromium's UI direction to LTR, fixing the native preview window jumping
//    left and title-bar control placement on RTL OS locales (Chromium otherwise draws
//    native child windows with WS_EX_LAYOUTRTL).
// 2. Optional translation bridge (only when a target language was configured). The
//    renderer cannot reach translate.googleapis.com itself (page CSP), and a preload
//    bridge would mean patching Claude's preload. Instead the renderer logs a tagged
//    console message; this side performs the request with Chromium's network stack
//    (proxy/certificate aware) and answers through window.__rtlTrResult.
//
// KEEP THIS FILE ASCII-ONLY: it is embedded in patch.ps1, which PowerShell 5.1
// reads with the ANSI code page.

function claudeRtlMainInstall(electron, translateTo) {
    var app = electron.app;
    if (app && app.commandLine && typeof app.commandLine.appendSwitch === 'function') {
        app.commandLine.appendSwitch('force-ui-direction', 'ltr');
    }
    if (translateTo) claudeRtlTranslateBridge(electron, translateTo);
}

function claudeRtlTranslateBridge(electron, defaultLang) {
    var PREFIX = String.fromCharCode(1) + 'RTLTR' + String.fromCharCode(1);
    var ENDPOINT = 'https://translate.googleapis.com/translate_a/t?client=gtx&sl=auto&dt=t&format=html&tl=';
    var LANG_RE = /^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$/;
    var MAX_ITEMS = 80, MAX_CHARS = 40000, MAX_INFLIGHT = 4;
    var inflight = 0;

    function reply(wc, payload) {
        try {
            if (wc.isDestroyed()) return;
            var p = wc.executeJavaScript('window.__rtlTrResult&&window.__rtlTrResult(' + JSON.stringify(payload) + ')');
            if (p && typeof p.catch === 'function') p.catch(function () {});
        } catch (e) { /* window gone */ }
    }

    function handle(wc, json) {
        var req;
        try { req = JSON.parse(json); } catch (e) { return; }
        if (!req || typeof req.id !== 'number' || typeof req.tl !== 'string' || !LANG_RE.test(req.tl) ||
            !Array.isArray(req.q) || req.q.length < 1 || req.q.length > MAX_ITEMS) return;
        var total = 0;
        for (var i = 0; i < req.q.length; i++) {
            if (typeof req.q[i] !== 'string') return;
            total += req.q[i].length;
        }
        if (total > MAX_CHARS) return;
        if (inflight >= MAX_INFLIGHT) { reply(wc, { id: req.id, ok: false, e: 'busy' }); return; }
        inflight++;
        var body = req.q.map(function (q) { return 'q=' + encodeURIComponent(q); }).join('&');
        var doFetch = (electron.net && typeof electron.net.fetch === 'function') ? electron.net.fetch.bind(electron.net) : fetch;
        var done = function (payload) { inflight--; reply(wc, payload); };
        try {
            doFetch(ENDPOINT + encodeURIComponent(req.tl), {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
                body: body
            }).then(function (r) {
                if (!r.ok) throw new Error('http ' + r.status);
                return r.json();
            }).then(function (data) {
                done({ id: req.id, ok: true, r: data });
            }, function (err) {
                done({ id: req.id, ok: false, e: String(err && err.message || err) });
            });
        } catch (e) { done({ id: req.id, ok: false, e: String(e && e.message || e) }); }
    }

    function attach(wc) {
        try {
            wc.on('console-message', function (a, level, message) {
                // Electron >= 35 passes one event object; older versions pass positional args.
                var msg = (a && typeof a.message === 'string') ? a.message : message;
                if (typeof msg !== 'string' || msg.indexOf(PREFIX) !== 0) return;
                handle(wc, msg.slice(PREFIX.length));
            });
        } catch (e) { /* not a real WebContents */ }
    }

    electron.app.on('web-contents-created', function (_event, wc) { attach(wc); });
    try {
        if (electron.webContents && typeof electron.webContents.getAllWebContents === 'function') {
            electron.webContents.getAllWebContents().forEach(attach);
        }
    } catch (e) { /* none yet */ }
}

;(function () {
    try {
        if (global.__claudeRtlMainPatched || global.__claudeRtlMainTest) return;
        global.__claudeRtlMainPatched = true;
        var lang = '__RTL_TRANSLATE_TO__';
        if (lang.indexOf('__') === 0) lang = '';
        claudeRtlMainInstall(require('electron'), lang);
    } catch (e) { try { console.error('[Claude RTL Main]', e); } catch (_) {} }
})();

if (typeof module !== 'undefined' && module.exports) {
    module.exports = { claudeRtlMainInstall: claudeRtlMainInstall };
}
