'use strict';

// patch.ps1 and install.ps1 are served without a BOM, and Windows PowerShell 5.1
// reads a BOM-less script in the system ANSI code page. Any non-ASCII byte can
// then decode as a "smart quote" and break parsing (e.g. on Hebrew locales), so
// both files must stay pure ASCII. Build non-ASCII text from [char] code points.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

for (const name of ['patch.ps1', 'install.ps1']) {
    test(`${name} is pure ASCII`, () => {
        const buf = fs.readFileSync(path.join(__dirname, '..', name));
        const bad = [];
        let line = 1;
        for (let i = 0; i < buf.length; i++) {
            if (buf[i] === 0x0a) line++;
            else if (buf[i] > 0x7f && (bad.length === 0 || bad[bad.length - 1] !== line)) bad.push(line);
        }
        assert.deepStrictEqual(bad, [], `${name} has non-ASCII bytes on line(s) ${bad.join(', ')}`);
    });
}
