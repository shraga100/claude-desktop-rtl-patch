'use strict';

// No npm or extraction: preserve ASAR metadata, edit selected packed files,
// recalculate their Electron integrity records, and verify the completed archive.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const MAX_HEADER = 10 * 1024 * 1024;
const MAX_EDIT = 128 * 1024 * 1024;
const BLOCK = 4 * 1024 * 1024;
const SKIP = new Set(['index.js', 'directMcpHost.js', 'nodeHost.js',
    'shellPathWorker.js', 'transcriptSearchWorker.js']);
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function readExact(fd, size, position) {
    const bytes = Buffer.alloc(size);
    let read = 0;
    while (read < size) {
        const n = fs.readSync(fd, bytes, read, size - read, position + read);
        if (!n) throw new Error('Truncated ASAR');
        read += n;
    }
    return bytes;
}

function writeAll(fd, bytes) {
    let written = 0;
    while (written < bytes.length) {
        const n = fs.writeSync(fd, bytes, written, bytes.length - written);
        if (!n) throw new Error('Short ASAR write');
        written += n;
    }
}

function readArchive(fd) {
    const size = fs.fstatSync(fd).size;
    const prefix = readExact(fd, 16, 0);
    const headerSize = prefix.readUInt32LE(4);
    const jsonSize = prefix.readUInt32LE(12);
    if (prefix.readUInt32LE(0) !== 4 || !jsonSize || jsonSize > MAX_HEADER ||
        headerSize !== 8 + Math.ceil(jsonSize / 4) * 4 ||
        prefix.readUInt32LE(8) !== headerSize - 4 || 8 + headerSize > size) {
        throw new Error('Invalid ASAR header');
    }
    const header = JSON.parse(readExact(fd, jsonSize, 16).toString('utf8'));
    const base = 8 + headerSize;
    const entries = [];
    function walk(dir, parent, depth) {
        if (depth > 64 || !dir.files || typeof dir.files !== 'object' || Array.isArray(dir.files)) {
            throw new Error('Invalid ASAR directory');
        }
        for (const [name, entry] of Object.entries(dir.files)) {
            if (!name || name === '.' || name === '..' || /[\\/:\x00]/.test(name) ||
                !entry || typeof entry !== 'object') throw new Error('Invalid ASAR entry');
            const key = parent + name;
            if (entry.files) { walk(entry, key + '/', depth + 1); continue; }
            if (entry.link !== undefined) {
                if (typeof entry.link !== 'string' || path.posix.isAbsolute(entry.link) ||
                    /[\\:\x00]/.test(entry.link) || entry.link.split('/').includes('..')) {
                    throw new Error('Unsafe ASAR link');
                }
                continue; // Never follow or extract links.
            }
            if (!Number.isSafeInteger(entry.size) || entry.size < 0) throw new Error('Invalid ASAR size');
            if (entry.unpacked) continue; // Keep external native modules external, byte-for-byte.
            if (typeof entry.offset !== 'string' || !/^\d+$/.test(entry.offset)) throw new Error('Invalid ASAR offset');
            const offset = Number(entry.offset);
            if (!Number.isSafeInteger(offset) || offset + entry.size > size - base) throw new Error('ASAR entry out of bounds');
            if (entry.integrity && (entry.integrity.algorithm !== 'SHA256' ||
                !Number.isSafeInteger(entry.integrity.blockSize) || entry.integrity.blockSize < 1 ||
                entry.integrity.blockSize > 64 * 1024 * 1024)) throw new Error('Unsupported ASAR integrity');
            entries.push({ key, entry, offset, size: entry.size });
        }
    }
    walk(header, '', 0);
    entries.sort((a, b) => a.offset - b.offset || a.size - b.size);
    let end = 0;
    let previous;
    for (const file of entries) {
        // Electron ASAR deduplicates identical files at an identical range.
        if (file.offset < end && !(previous && file.offset === previous.offset && file.size === previous.size)) throw new Error('Overlapping ASAR entries');
        end = file.offset + file.size;
        previous = file;
    }
    return { header, entries, base };
}

function integrity(bytes, blockSize = BLOCK) {
    const blocks = [];
    for (let i = 0; i < bytes.length; i += blockSize) blocks.push(sha(bytes.subarray(i, i + blockSize)));
    if (!bytes.length) blocks.push(sha(bytes));
    return { algorithm: 'SHA256', hash: sha(bytes), blockSize, blocks };
}

function verify(fd, archive) {
    for (const file of archive.entries) {
        const expected = file.entry.integrity;
        if (!expected) continue;
        const hash = crypto.createHash('sha256');
        const blocks = [];
        for (let i = 0; i < file.size; i += expected.blockSize) {
            const bytes = readExact(fd, Math.min(expected.blockSize, file.size - i), archive.base + file.offset + i);
            hash.update(bytes);
            blocks.push(sha(bytes));
        }
        if (!file.size) blocks.push(sha(Buffer.alloc(0)));
        if (hash.digest('hex') !== expected.hash || JSON.stringify(blocks) !== JSON.stringify(expected.blocks)) {
            throw new Error('ASAR integrity mismatch: ' + file.key);
        }
    }
}

function encodeHeader(header) {
    const json = Buffer.from(JSON.stringify(header));
    if (json.length > MAX_HEADER) throw new Error('ASAR header too large');
    const buffer = Buffer.alloc(16 + Math.ceil(json.length / 4) * 4);
    buffer.writeUInt32LE(4, 0);
    buffer.writeUInt32LE(buffer.length - 8, 4);
    buffer.writeUInt32LE(buffer.length - 12, 8);
    buffer.writeUInt32LE(json.length, 12);
    json.copy(buffer, 16);
    return buffer;
}

function inject(content, payload, marker) {
    if (content.includes(marker)) return null;
    const prologue = /^\s*("use strict"|'use strict')\s*;/.exec(content);
    return prologue ? prologue[0] + '\n' + payload + '\n' + content.slice(prologue[0].length) : payload + '\n' + content;
}

function patchArchive(source, destination, renderer, main) {
    const started = performance.now();
    if (path.resolve(source) === path.resolve(destination)) throw new Error('Source must not be overwritten');
    const input = fs.openSync(source, 'r');
    let output;
    let created = false;
    try {
        const archive = readArchive(input);
        verify(input, archive);
        const pkg = archive.entries.find(f => f.key === 'package.json');
        if (!pkg || pkg.size > MAX_EDIT) throw new Error('Missing or oversized package.json');
        const metadata = JSON.parse(readExact(input, pkg.size, archive.base + pkg.offset).toString('utf8'));
        const mainPath = typeof metadata.main === 'string' ? metadata.main.replace(/^\.\//, '') : '.vite/build/index.pre.js';
        if (!mainPath.startsWith('.vite/build/') || mainPath.split('/').includes('..')) throw new Error('Unsupported main entry');
        const changes = new Map();
        let mainFound = false;
        let renderers = 0;
        for (const file of archive.entries) {
            const isMain = file.key === mainPath;
            if (!isMain && (!file.key.startsWith('.vite/build/') || !file.key.endsWith('.js') || SKIP.has(path.posix.basename(file.key)))) continue;
            if (file.size > MAX_EDIT) throw new Error('JavaScript entry too large');
            const content = readExact(input, file.size, archive.base + file.offset).toString('utf8');
            const patched = inject(content, isMain ? main : renderer, isMain ? 'CLAUDE RTL MAIN PATCH START' : 'CLAUDE RTL PATCH START');
            if (isMain) {
                mainFound = true;
                const check = spawnSync(process.execPath, ['--check', '--input-type=commonjs'], {
                    input: patched === null ? content : patched, encoding: 'utf8', windowsHide: true, timeout: 60000
                });
                if (check.error || check.status !== 0) throw new Error('Patched main entry failed node --check');
            } else { renderers++; }
            if (patched !== null) {
                const bytes = Buffer.from(patched);
                changes.set(file.key, bytes);
                file.entry.size = bytes.length;
                file.entry.integrity = integrity(bytes, file.entry.integrity?.blockSize || BLOCK);
            }
        }
        if (!mainFound || !renderers) throw new Error('Expected main/renderer entries missing; refusing to patch');
        let offset = 0;
        const shared = new Map();
        const writes = [];
        for (const file of archive.entries) {
            const range = file.offset + ':' + file.size;
            if (!changes.has(file.key) && shared.has(range)) {
                file.entry.offset = shared.get(range);
                continue;
            }
            file.entry.offset = String(offset);
            if (!changes.has(file.key)) shared.set(range, file.entry.offset);
            writes.push(file);
            offset += file.entry.size;
        }
        // Exclusive creation refuses existing files, hardlinks and symlinks.
        output = fs.openSync(destination, 'wx');
        created = true;
        writeAll(output, encodeHeader(archive.header));
        for (const file of writes) {
            if (changes.has(file.key)) writeAll(output, changes.get(file.key));
            else for (let i = 0; i < file.size; i += BLOCK) {
                writeAll(output, readExact(input, Math.min(BLOCK, file.size - i), archive.base + file.offset + i));
            }
        }
        fs.fsyncSync(output);
        fs.closeSync(output);
        output = undefined;
        const checked = fs.openSync(destination, 'r');
        try { verify(checked, readArchive(checked)); } finally { fs.closeSync(checked); }
        return { changed: changes.size, renderers, seconds: Number(((performance.now() - started) / 1000).toFixed(3)) };
    } catch (error) {
        if (output !== undefined) { fs.closeSync(output); output = undefined; }
        if (created) fs.unlinkSync(destination);
        throw error;
    } finally { fs.closeSync(input); }
}

module.exports = { patchArchive, readArchive, encodeHeader, integrity, verify, inject };
if (require.main === module) {
    try {
        const [source, destination, rendererPath, mainPath] = process.argv.slice(2);
        const result = patchArchive(source, destination, fs.readFileSync(rendererPath, 'utf8'), fs.readFileSync(mainPath, 'utf8'));
        console.log(`Verified ASAR: ${result.changed} files changed, ${result.renderers} renderer files, ${result.seconds}s`);
    } catch (error) { console.error('ASAR patch failed: ' + error.message); process.exitCode = 1; }
}
