<div align="center">

# Claude Desktop RTL Patch

**Proper Hebrew & Arabic (right-to-left) support for Claude Desktop on Windows.**

Auto-detects RTL text and aligns direction where it should, without breaking English or code blocks.

[English](README.md) · [עברית](README.he.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6.svg)](#-requirements)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#-requirements)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#-contributing)
[![GitHub stars](https://img.shields.io/github/stars/shraga100/claude-desktop-rtl-patch?style=social)](https://github.com/shraga100/claude-desktop-rtl-patch/stargazers)

</div>

---

> [!IMPORTANT]
> **Update (July 2026): Claude now ships official RTL support — and the patch has been redesigned to build on top of it.**
>
> Anthropic added native RTL rendering to the **Code tab**, and the code for the regular **Chat tab** is already present (currently disabled, likely rolling out soon). This is genuinely good news, and hopefully this patch will become unnecessary altogether before long.
>
> For now, though, the native logic still has real gaps: no per-cell table direction, no handling of mixed-language lines, mixed lists judged by their first item only, no math/LaTeX isolation, and nothing at all for user messages, the input box, or the rest of the UI. The broken window UI on RTL systems is also still not fixed natively — including the preview window it pushes off to the far left.
>
> The patch has therefore been comprehensively reworked to **merge with Claude's native RTL instead of fighting it**: wherever native support exists it is left untouched, and the patch's detection engine fills in everything native still misses. When Anthropic enables native RTL in the Chat tab, the patch will step back there automatically — no update needed.

---

## ✨ What it does

- **Auto-detects RTL text** in Claude's responses and the input box, and aligns the direction in real time, even while a reply is still streaming.
- **Handles code, math formulas, and tables** — code blocks and LaTeX (`$x^2$`, `$$…$$`) stay left-to-right inside Hebrew, and Hebrew tables read right-to-left.
- **Fixes the broken window UI on RTL systems** (see the note below).
- **Backs up every file it touches**, with one-click restore and automatic rollback if anything goes wrong.
- **Stays applied across updates** (optional), via a desktop shortcut or a background auto-updater.

> [!NOTE]
> On a Windows system whose display language is set to Hebrew/Arabic, Claude Desktop's entire window UI flips to RTL on its own. This is a pre-existing bug, not caused by the patch. It pushes the title-bar window controls (minimize / maximize / close) on top of Claude's own settings and navigation buttons, hiding them, and sends the preview window to the far left. The patch fixes this by forcing the window chrome back to LTR, without affecting the direction of the chat text itself.

---

## 🚀 Quick install

Open **Windows PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main/install.ps1 | iex
```

A UAC prompt will appear. Click **Yes** to grant administrator privileges, then choose **1. Install** from the menu.

> [!TIP]
> Prefer not to pipe to `iex`? Download `patch.ps1` from the repo, right-click it, and choose **Run with PowerShell**.

---

## 📋 Requirements

| Requirement | Notes |
| :--- | :--- |
| **Windows 10 / 11** | With Claude Desktop installed ([download](https://downloads.claude.ai/releases/win32/ClaudeSetup.exe)) |
| **Node.js** | Node 22.12 or newer ([nodejs.org](https://nodejs.org/)), used to patch the app archive locally. `npx` is used only by a rare fallback |
| **Administrator** | The installer elevates automatically via UAC |

> [!IMPORTANT]
> **Windows only.** On macOS, use [soguy's Mac patch](https://github.com/soguy/claude-desktop-rtl-mac) instead. *(I haven't personally tested the Mac version, use at your own risk.)*

---

## 🎛️ Menu options

When you run the script, you get an interactive menu:

| # | Option | What it does |
| :---: | :--- | :--- |
| **1** | Install Smart RTL Patch | Backs up the originals and injects RTL support |
| **2** | Restore Original State | Reverts every change the patch made |
| **3** | Create 'Quick Update' Shortcut | Adds a desktop shortcut for one-click re-patching |
| **4** | Enable Auto Re-Patch | Installs a background watcher that re-patches after each Claude update |
| **5** | Disable Auto Re-Patch | Removes that background watcher |
| **6** | Set a Custom Text Font | Renders all text — or only Hebrew, or only Arabic/Persian — in an installed font of your choice |
| **7** | Translate Claude | Translates the interface (or the whole conversation too) like the browser's "Translate this page" |
| **8** | Exit | Close the patcher |

---

## 🔄 Keeping the patch applied

Claude Desktop updates often, and each update overwrites the patch. Two optional features keep it effortless:

- **Quick Update shortcut (option 3):** a desktop shortcut named **"Update Claude RTL"**. Double-click it to silently fetch and re-apply the latest patch.
- **Auto-updater (option 4):** a lightweight Windows scheduled task that detects when a new `claude.exe` version launches, re-applies the patch automatically, and shows a notification when it's done.

---

## 🔤 Optional: custom text font

Prefer reading in a different typeface? The patch can render Claude's text in any font that is **already installed on your machine**, and you choose which text it applies to:

| Scope | What changes | Example fonts |
| :--- | :--- | :--- |
| **All text** | Every non-code glyph the font covers | Rubik, Open Sans |
| **Hebrew only** | Hebrew letters; Latin/Arabic untouched | Heebo, Rubik, Assistant |
| **Arabic/Persian only** (default) | Arabic-script letters; Latin/Hebrew untouched | [Vazirmatn](https://github.com/rastikerdar/vazirmatn), Noto Naskh Arabic |

### How to enable it, step by step

1. **Install the font** (one time, no admin needed): download it, extract, select **all** the `.ttf` files, right-click → **Install**.
   - Persian/Arabic — **Vazirmatn**: the latest `vazirmatn-vXX.XXX.zip` from the [official releases page](https://github.com/rastikerdar/vazirmatn/releases) (the `.ttf` files are under `fonts/ttf`).
   - Hebrew — **Heebo** / **Rubik** / **Assistant**: download from [Google Fonts](https://fonts.google.com/).
2. **Run the patcher** (see [Quick install](#-quick-install) above) and choose **6. Set a Custom Text Font** from the menu.
3. Type the font's family name — e.g. `Vazirmatn` or `Heebo` — and press Enter. If the name doesn't look installed, the patcher asks you to re-type it (or confirm using it anyway).
4. Pick the scope: **1** Arabic/Persian only, **2** Hebrew only, or **3** all text.
5. Answer **Y** when asked *"Apply the patch now?"* (this closes Claude Desktop and re-applies the patch with the font enabled).
6. Open Claude Desktop again. The chosen text now renders in your font; everything else is unchanged.

**For scripting/automation**, the same setting is available as parameters:

```powershell
.\patch.ps1 -CustomFont "Vazirmatn" -CustomFontScope arabic
```

`-CustomFontScope` accepts `all`, `hebrew` or `arabic` (default: `arabic`). The pre-scope alias `-ArabicScriptFont` still works.

### Good to know

- The patch never bundles or downloads fonts — it only references an installed one via CSS `local()`. If the font isn't installed, nothing changes.
- **Scoped by `unicode-range`:** with the Hebrew or Arabic scope, no other script is touched. Code blocks, math and monospace stacks are never overridden in any scope — even in "all text" mode.
- Glyphs the font doesn't include automatically fall back to Claude's regular fonts, so a Hebrew-only font in "all text" mode is harmless.
- **Persistent:** the choice is saved (in `ProgramData\ClaudeRtlPatch`) and survives auto re-patches after Claude updates — set it once and forget it.
- **Disable:** menu option 6 → type `none` (or `.\patch.ps1 -CustomFont none`), then re-apply the patch.
- Any family name of letters/digits/spaces/hyphens works, e.g. `"Noto Naskh Arabic"`.

---

## 🌐 Optional: translate Claude

Want Claude Desktop in a language it doesn't speak natively, or every reply translated for you? The patch can translate the page the way the browser's **Translate this page** does, and you choose how far it goes:

| Scope | What gets translated |
| :--- | :--- |
| **Interface only** (default) | Menus, buttons, settings, tooltips, placeholders. The conversation stays exactly as written. |
| **Interface and conversation** | Everything above, plus your messages and Claude's replies. |

### Turn it on

Run the patcher and choose **7. Translate Claude**, type a target language code (`he`, `ar`, `ru`, `fr`, `pt-BR`, `zh-CN`, ...), pick the scope, and answer **Y** to apply the patch. For scripting:

```powershell
.\patch.ps1 -TranslateTo he -TranslateScope ui     # ui | all
.\patch.ps1 -TranslateTo none                      # turn it off
```

The choice is saved (in `ProgramData\ClaudeRtlPatch`) and survives auto re-patches after Claude updates. Inside Claude, **Ctrl+Alt+Shift+T** switches translation on/off (the original text comes back instantly) and **Ctrl+Alt+Shift+Y** flips between *interface only* and *everything*; the choice is remembered.

> [!WARNING]
> **Privacy:** the text is sent to Google Translate. With the *interface and conversation* scope that includes your messages and Claude's replies. Leave translation off (the default) if that is not acceptable.

### Built to be cheap

- **Text is edited in place.** No element is added, moved or removed, so Claude's React UI keeps working. Whole-page translators that rewrite the DOM are what usually break web apps.
- **One request unit per paragraph/button, not per fragment.** Inline formatting (bold, links) travels as numbered markers, so the engine sees whole sentences and each piece is written back to its own text node. Inline code is sent as "do not translate".
- **Only what you can see (plus a screenful around it)** is sent. Long histories and hidden panels cost nothing until you scroll to them.
- **Batched and cached.** Many blocks per request, identical strings sent once, results (including "already in your language") cached in memory and `localStorage` with LRU eviction, so a known string never costs a second request and reopening Claude is instant.
- **Streaming-aware.** A reply is translated paragraph by paragraph once a paragraph stops changing, not on every token.
- **Skips what needs no translation:** text already in the target script (e.g. Hebrew when translating to Hebrew), numbers, URLs, e-mails, file paths, code blocks, math, and the message box you type in.
- **Failure-friendly:** limited concurrency, exponential backoff, and a per-string retry cap.
- **Zero cost when off:** the translation code is only injected when a language is configured.

### How it works

Claude's page security policy blocks calls to third-party hosts, so the renderer cannot reach the translation service itself. Rather than relaxing the policy or patching Claude's preload script, the renderer logs a tagged message to the console. A small hook in the main-process payload ([`src/main-payload.js`](src/main-payload.js)) picks it up, performs the request with Chromium's network stack (proxy- and certificate-aware), and answers through `window.__rtlTrResult`. The hook only talks to one fixed endpoint, validates the language code and request size, and is not installed at all when translation is off. The renderer side lives in [`src/translate.js`](src/translate.js).

---

## 🗑️ Uninstall

Run the script and choose **2. Restore Original State**. This restores all original files from backup and removes the self-signed certificate from your Windows certificate store. If you enabled the auto-updater, choose **5. Disable Auto Re-Patch** as well.

---

## 🛠️ Troubleshooting

**"Node.js is required" / "Node … is too old":** Install or upgrade Node.js (22.12 or newer) from [nodejs.org](https://nodejs.org/) and reopen PowerShell.

**Claude won't start after patching:** Run the script again, choose **2 (Restore)**, then **1 (Install)**.

**Claude updated and the patch broke:** Run the "Update Claude RTL" shortcut, or use the auto-updater. To fix it manually, delete any `.bak` files in the Claude app directory and run the installer again.

**`Import-Module … The member AuditToString is already present`:** You ran the command in **PowerShell 7 (`pwsh`)**, which has a known bug that breaks the patch. Use the built-in **Windows PowerShell** instead:

1. Press **Win + R**, type `powershell`, and press **Enter**. This opens the classic **blue** Windows PowerShell window (not the black `pwsh` one).
2. Paste the install command and run it.

---

<details>
<summary><b>🔍 How it works (technical)</b></summary>

Claude Desktop is a **digitally signed** Electron app, so editing its UI code breaks the integrity checks. The patch works around this in three phases, all atomic, with automatic rollback on failure:

**Phase 1, ASAR injection.** Claude's UI lives inside `app.asar`. A small Node helper embedded in the script ([`src/asar-patch.cjs`](src/asar-patch.cjs)) edits the archive in place of an extract/repack round trip: it prepends the RTL-detection payload to the renderer files (and forces the window UI to LTR in the main process), copies every other file across unchanged, keeps native modules in `app.asar.unpacked` external, and verifies the per-file SHA-256 integrity records before and after. The script then computes the new header hash. The payload's detection logic lives in [`src/rtl-core.js`](src/rtl-core.js) (pure, unit-tested) plus [`src/rtl-payload.js`](src/rtl-payload.js) (DOM layer); `tools/build-payload.ps1` assembles them, together with the helper, into `patch.ps1`.

**Phase 2, hash replacement in `claude.exe`.** The original ASAR hash is stored as an ASCII string inside `claude.exe`. The script does a byte-level search-and-replace to update it. If the format ever changes, it falls back to disabling the Electron integrity fuse.

**Phase 3, certificate swap in `cowork-svc.exe`.** This service verifies `claude.exe` against Anthropic's embedded certificate. The script locates that certificate (by pattern-matching around the `"Anthropic, PBC"` string), replaces it in-place with a self-signed one (padded with `0x00` to keep the file size), re-signs both binaries, adds the new certificate to the Windows trusted root store, and then wipes the private key.

All original files are backed up as `.bak` next to the originals before anything changes.

</details>

<details>
<summary><b>🔐 Security & verification</b></summary>

`install.ps1` verifies an **RSA-4096 signature** over `patch.ps1` before running it. A compromised GitHub repo alone is **not** enough to ship malicious code; the attacker would also need the maintainer's offline private key.

**Public-key fingerprint (SHA-256):**

```
6e:f4:c2:a6:c2:42:34:a1:5f:e5:cd:e5:5d:a5:b0:3c:94:64:b4:56:7f:81:04:7c:83:9a:50:1c:7c:6f:07:c9
```

To double-check, recompute the fingerprint of the key embedded in `install.ps1` and confirm it matches:

```powershell
$content = Invoke-RestMethod "https://raw.githubusercontent.com/shraga100/claude-desktop-rtl-patch/main/install.ps1"
if ($content -match "ExpectedPubKey\s*=\s*'([A-Za-z0-9+/=]+)'") {
    $bytes = [Convert]::FromBase64String($matches[1])
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    ([BitConverter]::ToString($hash)).Replace('-', ':').ToLower()
}
```

A mismatch means the embedded key was swapped. **Do not proceed**, and report it as a security issue.

To audit a release without installing:

```powershell
git clone https://github.com/shraga100/claude-desktop-rtl-patch
cd claude-desktop-rtl-patch
powershell -ExecutionPolicy Bypass -File tools\verify-signature.ps1
```

</details>

---

## ⚠️ Disclaimer

> [!CAUTION]
> This patch modifies Claude Desktop's binaries. It replaces Anthropic's code-signing certificate inside `cowork-svc.exe` with a self-signed one, adds that certificate to your Windows **trusted root store**, and bypasses the app's integrity verification.

By installing, you accept that:

1. **You use it at your own risk.** The authors take no responsibility for system damage, data loss, or instability.
2. **Modifying the app may not align with Anthropic's Terms of Service.** It's worth reviewing them and using your own judgment.
3. **You trust this repository.** Running `irm | iex` as Administrator executes code with full privileges, so always verify the source.
4. **It's temporary.** Claude updates overwrite the patched files, so re-run the installer (or use the auto-updater) after each update.
5. **It's a stopgap** until Anthropic adds native RTL support. Please request that feature through official channels.

---

## 🤝 Contributing

This project is open source under the **MIT** license. Contributions that improve RTL accuracy are very welcome, and PRs are open. 🙏

The math-formula isolation approach is credited to [Claude-UniMath](https://github.com/DavidiBellaire/Claude-UniMath) by Davidi Bellaire.

## License

[MIT](LICENSE)
