# Faster patch installation

The patcher now edits ASAR files directly instead of extracting the entire archive
and repacking it through `npx`. The helper uses Node's built-in modules, so the
normal archive path needs no npm downloads or extra dependencies.

It reads the archive index, updates the selected JavaScript files, and copies the
remaining packed data into a new archive. It preserves external native modules,
shared file ranges, links, executable flags, and strict-mode directives. The RTL
payload and the list of excluded Node/MCP files are unchanged.

Input and output SHA-256 records are checked, including block hashes. The patched
main entry must pass `node --check` before the live archive can be replaced.
Unsupported layouts fail without replacing the source archive. The existing
backups, signing checks, private-key cleanup and rollback are retained.

Two other changes remove unnecessary work:

- Grant permissions only on the directories and files used by the patch, instead
  of recursively changing the whole installation twice.
- Read the original signer name from the embedded certificate. This name is only
  logged; it does not need an online trust-chain check. Verification after signing
  remains unchanged.

## Measurements

Measured on one Windows machine with Claude Desktop 2.7032.0.0:

| Step | Previous run | Updated run |
| --- | --- | --- |
| Complete patch | About 21 min 26 sec | 30.29 sec |
| ASAR extraction, injection and repacking | 566 sec | 1.28 sec |

The updated run was a full re-patch of the installed application, starting from
its original backups. It included stopping Claude, patching and signing the
binaries, cleaning up the signing key, and restarting the service and application.
UAC approval and the separate before/after backup checksum checks are excluded
from the timing. The process returned exit code 0; all three backup hashes stayed
unchanged. Claude reopened and its window responded, the Cowork service was
running, and the executable's embedded ASAR hash matched the patched archive.

The original archive was 40,453,269 bytes. A separate read with the official
`@electron/asar` 4.2.0 library confirmed the expected contents of all 348 packed
files and preserved metadata for all six external files.

These are two observed runs, not a controlled cold-cache benchmark. Disk caching,
network timeouts and antivirus activity may affect the difference. The new archive
path removes npm and extraction from the process regardless of those conditions.

## Development

The editable helper is `src/fast-asar.cjs`. `npm run build` embeds it in `patch.ps1`
alongside the renderer payload, keeping the installer self-contained. Run:

```sh
npm run build
npm test
npm run check:security
npm audit --omit=dev
```

The Windows security check exercises rollback after temporary-file cleanup fails,
and checks that a failed install releases its mutex. Archive tests cover content
preservation, strict mode, shared ranges, external files, repeat runs, corrupt
inputs, malformed metadata, invalid main-entry syntax and existing output files.

As with any edit to `patch.ps1`, the maintainer must regenerate `patch.ps1.sig`
using the release key before publishing. This change does not modify the public
key, update verification, or the signing policy.
