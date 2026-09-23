'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { patchArchive, encodeHeader, readArchive, integrity, verify } = require('../src/fast-asar.cjs');
const renderer = '// CLAUDE RTL PATCH START\n;globalThis.rtl = true;';
const main = '// CLAUDE RTL MAIN PATCH START\n;globalThis.mainRtl = true;';

function fixture(t, edit = () => {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtl-asar-test-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const header = { files: {} }, buffers = [];
    let offset = 0;
    for (const [name, content] of Object.entries({
        'package.json': JSON.stringify({ main: '.vite/build/entry.js' }),
        '.vite/build/entry.js': '"use strict";\nmodule.exports = 42;',
        '.vite/build/view.js': "'use strict';\nconst hebrew = 'שלום';",
        '.vite/build/index.js': 'const mainBundle = true;',
        '.vite/build/mcp/nodeHost.js': 'const host = true;',
        'other/data.bin': '\x00\x01\xff',
        'empty.txt': ''
    })) {
        const parts = name.split('/');
        let files = header.files;
        for (const part of parts.slice(0, -1)) files = (files[part] ||= { files: {} }).files;
        const bytes = Buffer.from(content);
        files[parts.at(-1)] = { size: bytes.length, offset: String(offset), integrity: integrity(bytes, 8) };
        offset += bytes.length;
        buffers.push(bytes);
    }
    header.files['native.node'] = { size: 99, unpacked: true, executable: true, integrity: integrity(Buffer.from('external')) };
    header.files.alias = { link: 'other/data.bin' };
    header.files.shared = structuredClone(header.files.other.files['data.bin']);
    edit(header);
    const source = path.join(dir, 'input.asar'), dest = path.join(dir, 'out.asar');
    fs.writeFileSync(source, Buffer.concat([encodeHeader(header), ...buffers]));
    return { source, dest, header };
}

function inspect(file) {
    const fd = fs.openSync(file, 'r');
    try {
        const archive = readArchive(fd);
        verify(fd, archive);
        const bytes = fs.readFileSync(file);
        return { ...archive, contents: new Map(archive.entries.map(f => [f.key, bytes.subarray(archive.base + f.offset, archive.base + f.offset + f.size)])) };
    } finally { fs.closeSync(fd); }
}

test('changes only selected JS; preserves strict mode, metadata, shared data and external files', t => {
    const { source, dest, header } = fixture(t);
    const before = inspect(source);
    const result = patchArchive(source, dest, renderer, main);
    assert.equal(result.changed, 2);
    const after = inspect(dest);
    assert.deepEqual(after.header.files['native.node'], header.files['native.node']);
    assert.deepEqual(after.header.files.alias, header.files.alias);
    assert.equal(after.header.files.shared.offset, after.header.files.other.files['data.bin'].offset);
    for (const [key, bytes] of before.contents) {
        if (key.endsWith('/entry.js') || key.endsWith('/view.js')) continue;
        assert.deepEqual(after.contents.get(key), bytes, key);
    }
    assert.match(after.contents.get('.vite/build/entry.js').toString(), /^"use strict";\n\/\/ CLAUDE RTL MAIN PATCH START/);
    assert.match(after.contents.get('.vite/build/view.js').toString(), /^'use strict';\n\/\/ CLAUDE RTL PATCH START/);
    const next = dest + '.again';
    assert.equal(patchArchive(dest, next, renderer, main).changed, 0);
    assert.deepEqual(fs.readFileSync(next), fs.readFileSync(dest));
});

test('refuses corrupt source before creating output', t => {
    const { source, dest } = fixture(t);
    const bytes = fs.readFileSync(source);
    bytes[bytes.length - 1] ^= 1;
    fs.writeFileSync(source, bytes);
    assert.throws(() => patchArchive(source, dest, renderer, main), /integrity mismatch/);
    assert.equal(fs.existsSync(dest), false);
});

test('refuses malformed headers, bounds, links and absent main entries', t => {
    for (const edit of [
        h => { h.files.other.files['data.bin'].offset = '99999999999'; },
        h => { h.files.alias.link = '../outside'; },
        h => { h.files['..'] = { files: {} }; },
        h => { delete h.files['.vite'].files.build.files['entry.js']; },
        h => { h.files['empty.txt'].integrity.blockSize = 0; }
    ]) {
        const { source, dest } = fixture(t, edit);
        assert.throws(() => patchArchive(source, dest, renderer, main));
        assert.equal(fs.existsSync(dest), false);
    }
});

test('refuses bad main syntax and never overwrites an existing output or source', t => {
    const { source, dest } = fixture(t);
    const original = fs.readFileSync(source);
    assert.throws(() => patchArchive(source, dest, renderer, 'invalid ( syntax'), /node --check/);
    assert.equal(fs.existsSync(dest), false);
    fs.writeFileSync(dest, 'keep me');
    assert.throws(() => patchArchive(source, dest, renderer, main), /EEXIST/);
    assert.equal(fs.readFileSync(dest, 'utf8'), 'keep me');
    assert.throws(() => patchArchive(source, source, renderer, main), /must not be overwritten/);
    assert.deepEqual(fs.readFileSync(source), original);
});

test('embedded helper exactly matches reviewed source', () => {
    const patch = fs.readFileSync(path.join(__dirname, '../patch.ps1'), 'utf8').replace(/\r\n/g, '\n');
    const embedded = patch.split("$FAST_ASAR_CODE = @'\n")[1].split("\n'@")[0];
    assert.equal(embedded, fs.readFileSync(path.join(__dirname, '../src/fast-asar.cjs'), 'utf8').replace(/\r\n/g, '\n').trimEnd());
});
