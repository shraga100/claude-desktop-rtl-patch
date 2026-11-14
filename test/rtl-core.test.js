'use strict';

const test = require('node:test');
const assert = require('node:assert');
const core = require('../src/rtl-core.js');

const cp = (s) => s.codePointAt(0);

test('isRTL covers expanded ranges', () => {
    assert.ok(core.isRTL(cp('א')), 'Hebrew');
    assert.ok(core.isRTL(cp('ا')), 'Arabic');
    assert.ok(core.isRTL(cp('ܐ')), 'Syriac');
    assert.ok(core.isRTL(cp('ހ')), 'Thaana');
    assert.ok(core.isRTL(cp('ߒ')), 'NKo');
    assert.ok(core.isRTL(cp('𞤀')), 'Adlam (astral)');
    assert.ok(!core.isRTL(cp('A')), 'Latin');
    assert.ok(!core.isRTL(cp('5')), 'digit');
    assert.ok(!core.isRTL(cp('$')), 'dollar');
});

test('RTL bidi control marks are strong-RTL (native-detector parity)', () => {
    assert.ok(core.isRTL(0x200F), 'RLM');
    assert.ok(core.isRTL(0x202B), 'RLE');
    assert.ok(core.isRTL(0x202E), 'RLO');
    assert.ok(core.isRTL(0x2067), 'RLI');
    assert.ok(!core.isRTL(0x200E), 'LRM stays LTR-neutral');
    assert.ok(!core.isRTL(0x202A), 'LRE stays LTR-neutral');
    // An author who forced RTL with a leading RLM gets first-strong rtl even
    // when the visible text starts Latin.
    assert.strictEqual(core.firstStrong('‏abc'), 'rtl');
    assert.ok(core.hasRTL('abc‏'));
});

test('hasRTL walks code points (astral safe)', () => {
    assert.ok(core.hasRTL('hello שלום'));
    assert.ok(core.hasRTL('text 𞤀𞤣'));       // Adlam only
    assert.ok(!core.hasRTL('plain ascii 123'));
    assert.ok(!core.hasRTL('price $5.99'));
});

test('firstStrong picks first strong character', () => {
    assert.strictEqual(core.firstStrong('שלום world'), 'rtl');
    assert.strictEqual(core.firstStrong('world שלום'), 'ltr');
    assert.strictEqual(core.firstStrong('123 — שלום'), 'rtl');
    assert.strictEqual(core.firstStrong('123 456'), null);
});

test('rtlMajority: majority script decides ambiguous mixed text', () => {
    // English sentence quoting one Hebrew word -> Latin majority, stays LTR.
    assert.ok(!core.rtlMajority('The word שלום means hello'));
    // Hebrew sentence with an embedded English term -> RTL majority.
    assert.ok(core.rtlMajority('אני כתבתי string אחד בתוך משפט'));
    assert.ok(!core.rtlMajority('plain english only'));
    assert.ok(core.rtlMajority('עברית בלבד'));
    // Digits/punctuation are neutral -- they never vote.
    assert.ok(core.rtlMajority('123 456 !!! שלום'));
    assert.ok(!core.rtlMajority('123 456 !!! abc'));
    assert.ok(!core.rtlMajority(''));
});

test('currency $ is NOT treated as LaTeX', () => {
    assert.deepStrictEqual(core.findLatexRanges('המחיר הוא $5.99 היום'), []);
    assert.deepStrictEqual(core.findLatexRanges('עולה $5 עד $10'), []);
    assert.deepStrictEqual(core.findLatexRanges('costs $20 and $30'), []);
});

test('real LaTeX is detected', () => {
    assert.strictEqual(core.findLatexRanges('זה $x^2$ פה').length, 1);
    assert.strictEqual(core.findLatexRanges('נוסחה $$\\frac{a}{b}$$ כאן').length, 1);
    assert.strictEqual(core.findLatexRanges('inline \\(a+b\\) here').length, 1);
    assert.strictEqual(core.findLatexRanges('block \\[E=mc^2\\] done').length, 1);
});

test('$$ wins over inner single $', () => {
    const ranges = core.findLatexRanges('a $$x = 5$$ b');
    assert.strictEqual(ranges.length, 1);
    assert.strictEqual('a $$x = 5$$ b'.slice(ranges[0][0], ranges[0][1]), '$$x = 5$$');
});

test('segmentText splits text and math', () => {
    const segs = core.segmentText('עברית $x^2$ עוד');
    assert.strictEqual(segs.length, 3);
    assert.strictEqual(segs[0].type, 'text');
    assert.strictEqual(segs[1].type, 'math');
    assert.strictEqual(segs[1].value, '$x^2$');
    assert.strictEqual(segs[2].type, 'text');
});

test('segmentText with no math returns single text segment', () => {
    const segs = core.segmentText('סתם טקסט עם $5 מחיר');
    assert.strictEqual(segs.length, 1);
    assert.strictEqual(segs[0].type, 'text');
});

test('cellDir: contains-RTL beats first-strong (header starting with Latin term)', () => {
    assert.strictEqual(core.cellDir('blob מקומי (HEAD c16c988)'), 'rtl'); // Latin-first but Hebrew column
    assert.strictEqual(core.cellDir('blob מה-CDN'), 'rtl');
    assert.strictEqual(core.cellDir('קובץ'), 'rtl');
    assert.strictEqual(core.cellDir('patch.ps1'), 'ltr');
    assert.strictEqual(core.cellDir('9f954eb'), 'ltr');  // hex still has Latin letters (f,e,b)
    assert.strictEqual(core.cellDir('123.45'), null);    // truly neutral: no letters, no sway
});

test('tableDirFromCells: header majority RTL → rtl', () => {
    // The example from the discussion: עברית | English | תעתיק
    const headers = [core.firstStrong('עברית'), core.firstStrong('English'), core.firstStrong('תעתיק')];
    assert.strictEqual(core.tableDirFromCells(headers, []), 'rtl');
});

test('table with Latin-first Hebrew headers flips (regression: CDN comparison table)', () => {
    // Real case that previously failed: headers contain Hebrew but two start with "blob".
    const headers = ['קובץ', 'blob מקומי (HEAD c16c988)', 'blob מה-CDN', 'תוצאה'].map(core.cellDir);
    const firstCol = ['patch.ps1', 'patch.ps1.sig'].map(core.cellDir); // Latin first column
    assert.deepStrictEqual(headers, ['rtl', 'rtl', 'rtl', 'rtl']);
    assert.strictEqual(core.tableDirFromCells(headers, firstCol), 'rtl');
});

test('mostly-English table does NOT flip even with one Hebrew header', () => {
    const headers = ['Name', 'Value', 'שם'].map(core.cellDir);
    assert.strictEqual(core.tableDirFromCells(headers, []), null);
});

test('tableDirFromCells: header majority LTR → null (no flip)', () => {
    const headers = [core.firstStrong('Name'), core.firstStrong('Value'), core.firstStrong('שם')];
    assert.strictEqual(core.tableDirFromCells(headers, []), null);
});

test('tableDirFromCells: first column tie-breaks when headers are inconclusive', () => {
    const headers = [null, null];
    const firstCol = [core.firstStrong('שלום'), core.firstStrong('תודה'), core.firstStrong('בית')];
    assert.strictEqual(core.tableDirFromCells(headers, firstCol), 'rtl');
});

test('stripLeadingLTR drops leading filename then detects RTL', () => {
    const stripped = core.stripLeadingLTR('foo.js שלום עולם');
    assert.strictEqual(core.firstStrong(stripped), 'rtl');
});

// --- bare numeric / arithmetic isolation (findMathRanges) ---

// Helper: return the isolated substrings for a given input.
const mathSubs = (s) => core.findMathRanges(s).map(([a, b]) => s.slice(a, b));

test('findMathRanges isolates bare arithmetic inside Hebrew', () => {
    assert.deepStrictEqual(mathSubs('התוצאה היא 2 + 3 = 5 בסך הכל'), ['2 + 3 = 5']);
    assert.deepStrictEqual(mathSubs('הטווח הוא 5-3 מעלות'), ['5-3']);
    assert.deepStrictEqual(mathSubs('נשאר 1/2 מהעוגה'), ['1/2']);
    assert.deepStrictEqual(mathSubs('הצלחה של 95% מהמשתמשים'), ['95%']);
    assert.deepStrictEqual(mathSubs('אם x = 10 אז y = 20'), ['x = 10', 'y = 20']);
    assert.deepStrictEqual(mathSubs('no spaces 2+3=5 here'), ['2+3=5']);
});

test('findMathRanges keeps a trailing sentence period out of the island', () => {
    assert.deepStrictEqual(mathSubs('בסך הכל 2 + 3 = 5.'), ['2 + 3 = 5']);
    assert.deepStrictEqual(mathSubs('כך: 10 / 2 = 5, נכון'), ['10 / 2 = 5']);
});

test('findMathRanges keeps internal decimals/thousands intact', () => {
    assert.deepStrictEqual(mathSubs('הסכום 1.5 + 2.5 = 4.0 שקלים'), ['1.5 + 2.5 = 4.0']);
    assert.deepStrictEqual(mathSubs('יחס 3.14 * 2 בערך'), ['3.14 * 2']);
});

test('findMathRanges leaves lone numbers / dates / IPs / versions alone', () => {
    assert.deepStrictEqual(mathSubs('יש לי 5 כלבים'), []);          // lone number
    assert.deepStrictEqual(mathSubs('ראה עמוד 3 בספר'), []);        // lone number
    assert.deepStrictEqual(mathSubs('הגרסה היא 1.14271.0.0 כעת'), []); // dotted version, no operator
    assert.deepStrictEqual(mathSubs('כתובת 192.168.1.1 ברשת'), []); // IP, dots only
    assert.deepStrictEqual(mathSubs('בשעה 12:30 נתראה'), []);       // time, colon only
    assert.deepStrictEqual(mathSubs('1. פריט ראשון'), []);          // ordered-list marker
});

test('findMathRanges leaves currency and Hebrew-glued numbers alone', () => {
    assert.deepStrictEqual(mathSubs('המחיר $5 + $10 בלבד'), []);    // '$' breaks the run
    assert.deepStrictEqual(mathSubs('עולה $5.99 היום'), []);        // currency, no operator
    assert.deepStrictEqual(mathSubs('נפגשנו ב-15 בחודש'), []);      // Hebrew-glued, no whitespace boundary
});

test('findMathRanges does not swallow surrounding English words', () => {
    assert.deepStrictEqual(mathSubs('for 2 + 3 apples total'), ['2 + 3']);
    assert.deepStrictEqual(mathSubs('version 2 of 3 ready'), []);   // no operator between the numbers
});

test('findMathRanges supports common Unicode operators', () => {
    assert.deepStrictEqual(mathSubs('שטח 4 × 5 = 20'), ['4 × 5 = 20']); // x multiply, =
    assert.deepStrictEqual(mathSubs('טמפ\' −5 ≤ 0 מעלות'), ['−5 ≤ 0']); // minus-sign, <=
});

test('findMathRanges does not cross a newline', () => {
    assert.deepStrictEqual(mathSubs('שורה 2 + 3\nשורה 4 + 5'), ['2 + 3', '4 + 5']);
});

test('segmentText isolates bare arithmetic as a math segment', () => {
    const segs = core.segmentText('עברית 2 + 3 = 5 עוד');
    assert.strictEqual(segs.length, 3);
    assert.strictEqual(segs[0].type, 'text');
    assert.strictEqual(segs[1].type, 'math');
    assert.strictEqual(segs[1].value, '2 + 3 = 5');
    assert.strictEqual(segs[2].type, 'text');
});

test('segmentText: LaTeX wins over an overlapping numeric run', () => {
    const segs = core.segmentText('נוסחה $x^2 + 1$ סוף');
    const math = segs.filter((s) => s.type === 'math');
    assert.strictEqual(math.length, 1);
    assert.strictEqual(math[0].value, '$x^2 + 1$'); // not split by the inner "+ 1"
});

test('segmentText still returns single segment for currency-only text (regression)', () => {
    const segs = core.segmentText('סתם טקסט עם $5 מחיר');
    assert.strictEqual(segs.length, 1);
    assert.strictEqual(segs[0].type, 'text');
});

// --- List context (nested lists that mix Arabic/Hebrew with English terms) ---

test('listContextDir: items holding RTL vote rtl even when Latin-heavy', () => {
    const items = [
        'Review الـ design system وتحديث الـ colors',
        'كتابة الـ documentation للـ components',
        'Fix bug في الـ login page (Safari فقط)',
    ];
    assert.strictEqual(core.listContextDir(items), 'rtl');
});

test('listContextDir: an English list quoting one RTL word stays ltr', () => {
    const items = ['Install the package', 'Run the tests', 'Say שלום to the team'];
    assert.strictEqual(core.listContextDir(items), 'ltr');
});

test('listContextDir: neutral items abstain; empty list has no context', () => {
    assert.strictEqual(core.listContextDir(['123', '---']), null);
    assert.strictEqual(core.listContextDir([]), null);
});

test('listItemDir: Latin-heavy RTL item follows an RTL list context', () => {
    const t = 'Review الـ design system وتحديث الـ colors';
    // Standalone detection says ltr: first strong is Latin AND Latin letters outnumber RTL.
    assert.strictEqual(core.firstStrong(t), 'ltr');
    assert.strictEqual(core.rtlMajority(t), false);
    assert.strictEqual(core.listItemDir(t, null, 'rtl'), 'rtl');
});

test('listItemDir: no RTL letters, or no RTL context, keeps standalone direction', () => {
    assert.strictEqual(core.listItemDir('Fix the login page', 'ltr', 'rtl'), 'ltr');
    assert.strictEqual(core.listItemDir('Fix the login page', null, 'rtl'), null);
    assert.strictEqual(core.listItemDir('Say שלום to the team', null, 'ltr'), null);
    assert.strictEqual(core.listItemDir('Say שלום to the team', null, null), null);
    assert.strictEqual(core.listItemDir('שלום', 'rtl', 'ltr'), 'rtl');
});
