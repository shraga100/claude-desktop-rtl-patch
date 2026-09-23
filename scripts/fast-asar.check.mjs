import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const result = spawnSync(process.execPath, ['--test', fileURLToPath(new URL('../test/fast-asar.test.js', import.meta.url))], { stdio: 'inherit' });
assert.equal(result.status, 0, 'ASAR security / integrity regression checks failed');
if (process.platform === 'win32') {
    const transaction = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        fileURLToPath(new URL('../test/patch-transaction.check.ps1', import.meta.url))], { stdio: 'inherit' });
    assert.equal(transaction.status, 0, 'Patch rollback checks failed');
}
