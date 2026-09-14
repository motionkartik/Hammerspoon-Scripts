# Project Progress & Session Log

Working document for tracking development across sessions. Update this file at the end of every session so the next session can pick up where we left off.

---

## Project Overview

**Spoonfeeder** — A Hammerspoon configuration loader that auto-discovers and loads every `.lua` file in the `Spoons/` directory (recursively), auto-reloads when config changes, and ships with two utility spoons:

| Spoon | Purpose | State |
|-------|---------|-------|
| **aural** | macOS audio device switcher (menubar icon, scroll volume, SF Symbol icons, floating HUD, verified device switching) | Mature / actively polished |
| **auto_dlp** | Automatic clipboard media downloader via yt-dlp (3-state mode, parallel downloads, cookie support, history) | Feature-complete |
| **Spoonfeeder** | The auto-loader itself (lives in `init.lua`) | Stable |

**Repo:** https://github.com/motionkartik/Hammerspoon-Scripts
**License:** MIT (2026 Kartik Gupta)
**Branch:** `main`
**Dependencies (runtime):** Hammerspoon, macOS 12+; yt-dlp, ffmpeg, node (auto_dlp); `swiftc` for on-demand icon compilation (aural).

---

## Current File Map

```text
./
├── init.lua                      # Spoonfeeder loader + auto-reload watcher
├── README.md                     # Public project README (paths are somewhat outdated — see backlog)
├── LICENSE
├── PROGRESS.md                   # This file
└── Spoons/
    ├── aural/
    │   ├── aural.lua             # 590 lines — the audio switcher
    │   ├── README.md
    │   ├── sfsymbol_export.swift # Swift SF Symbol → PNG exporter source
    │   ├── sfsymbol-export       # Committed ARM64 binary (see backlog item #4)
    │   └── aural-icons/          # Cached PNG icons (bluetooth, default, speakers)
    └── auto_dlp/
        ├── auto-dlp.lua          # 511 lines — the clipboard downloader
        └── README.md
```

---

## Issue Tracker

### Critical

- **[FIXED 2026-09-14] Spoonfeeder recursive self-loading** — `Spoons/Spoonfeeder/spoonfeeder.lua` was byte-identical to `init.lua` and lived inside the directory the loader scans, causing infinite recursion (stack overflow) and hundreds of duplicate menubar items/timers/watchers. **Fix:** deleted the duplicate file; loader now lives only in `init.lua`.

- **[FIXED 2026-09-14] `aural` table not globally accessible** — `aural.lua` declared `local aural = {}` and only `return`ed it, but `init.lua` loads via `pcall(dofile, ...)` which discards the return value. Documented console commands like `aural.debug = true` / `aural.hudEnabled = false` failed with `attempt to index a nil value`. **Fix:** added `_G.aural = aural`.

### Moderate

- **[OPEN] HUD canvas element index assumption** — `aural.showHUD()` conditionally inserts the icon image element only if icon render succeeds, but `aural.updateHUD()` assumes fixed positions (`hud[2]`=image, `hud[3]`=name, `hud[4]`=volume). If icon render fails, updateHUD writes to wrong elements → corrupted HUD. Likely path for the icon failures the 2026-09-14 commit was chasing.

- **[OPEN] Committed ARM64 binary** — `Spoons/aural/sfsymbol-export` is a 70KB ARM64 Mach-O in git. Breaks Intel Macs (mtime check passes → never auto-recompiles → exec fails) and contradicts the README's "auto-compiles on first launch". Fix options: gitignore + rely on auto-compile, or build a universal fat binary.

- **[OPEN] README path/filename mismatches** — Docs use `Aural/`/`Auto_DLP/`/`Aural.lua`/`Auto_DLP.lua`; actual files are lowercase `aural/`, `auto_dlp/`, `aural.lua`, `auto-dlp.lua`. Structure diagram omits `Spoons/Spoonfeeder/`. Auto-DLP README describes a "Monitoring" toggle that the 3-state Idle/Video/Audio UI replaced. Works on case-insensitive APFS but is confusing/wrong on case-sensitive filesystems.

### Minor / Code Smells

- **[OPEN] No `.gitignore`** — Three `.DS_Store` files are tracked and churn on every `git status`. Add `.gitignore` and `git rm --cached` them.
- **[FIXED 2026-09-14] Duplicate loader reference** — `Spoons/Spoonfeeder/spoonfeeder.lua` (byte-identical to `init.lua`) was deleted along with its now-empty directory. The loader lives only in `init.lua`.
- **[OPEN] Global `watcher` pollution** — `init.lua` declares `watcher = hs.pathwatcher.new(...)` without `local`. Collision risk if other scripts use the same name.
- **[OPEN] `hs.shutdownCallback` single-slot** — `auto-dlp.lua` sets `hs.shutdownCallback = hs.auto_dlp_unload`, silently overwriting any other handler.
- **[OPEN] Shell string interpolation** — `auto-dlp.lua` uses `hs.execute('open "' .. DOWNLOAD_DIR .. '"')`; prefer `hs.task`/`hs.osascript` for safety.

---

## Session Log

### Session 1 — 2026-09-14

**Work done:**
- Full repository analysis (all spoons, git history, dependencies, code smells).
- Created this `PROGRESS.md` for cross-session tracking.
- Fixed **CRITICAL** — Spoonfeeder recursive self-loading:
  - Deleted `Spoons/Spoonfeeder/spoonfeeder.lua` (duplicate of `init.lua` that caused infinite recursion + duplicate widget loads).
  - Loader now lives only in `init.lua`.
- Fixed **CRITICAL** — `aural` not globally accessible:
  - Added `_G.aural = aural` in `Spoons/aural/aural.lua` so documented console commands (`aural.debug`, `aural.hudEnabled`) actually work.

**Verified:**
- `diff init.lua Spoons/Spoonfeeder/spoonfeeder.lua` confirmed byte-identical before deletion.
- `git status` shows the duplicate staged for removal; `Spoons/Spoonfeeder/` directory is gone.
- All three Lua files pass syntax check under Lua 5.4: `luac -p init.lua Spoons/aural/aural.lua Spoons/auto_dlp/auto-dlp.lua`.
- `_G.aural = aural` placed immediately before the final `return aural` (note: there is an early `return aural` at line ~84 in the `ensureExporter()` guard — the final return is the correct hook point).
- Observed a Lua 5.5-only compile error in `auto-dlp.lua` (for-loop variable assignment); confirmed it is **not** an issue under Lua 5.4, which is what Hammerspoon uses. Logged as backlog item #7.

**Notes:**
- Auto-DLP's `hs.auto_dlp_unload()` name is referenced by `init.lua`'s reload hook — keep that name stable.
- The empty `Spoons/Spoonfeeder/` directory was removed along with its file (was never tracked separately by git).
- Nothing committed this session; changes left staged/unstaged for review.

### Session 2 — 2026-09-14

**Work done — Auto-DLP overhaul (`Spoons/auto_dlp/auto-dlp.lua`, full rewrite):**
- Replaced **all** `hs.notify` and `hs.alert` usage with a custom, Aural-style canvas notification system. Notifications appear under the menubar icon and are queued one-at-a-time.
- Added **clickable buttons** to notifications using `hs.canvas:mouseCallback` + per-element `trackMouseUp`/`trackMouseEnterExit` (with hover highlight). Verified this API pattern against the official `hs.canvas.examples` wiki.
  - `Media Detected` → **Start Now**, **Cancel**, **Cancel All**
  - `Download Complete` → **Open** (reveal in Finder), **Open File** (default player)
  - `Download Started` → **Cancel** (stops that specific task)
  - `Download Failed` → **Retry** (re-queues the URL)
- Added **live countdown** text on the Media Detected notification (`dynamicText` ticker, deadline-based so it stays correct even if queued).
- Added **mode-switch notification** every time the mode changes, via a new `setMode()` used by both the left-click cycle and the right-click menu.
- Added **"Download URL…"** menu item; bypasses the domain allow-list and downloads using a chosen mode (defaults to the current mode; idle falls back to Video). Initially implemented with `hs.dialog.textPrompt`; replaced in Session 3 with a custom webview dialog (see below).
- Introduced a `terminating` slot map so cancel/timeout no longer triggers a spurious "Download Failed" (previously a timeout could double-notify).
- **Follow-up fix:** same-tag notifications now replace the current panel instantly instead of queuing. Mode-switch notifications are tagged `"mode"`, so rapid back-to-back clicks update the panel immediately (`dismissNotification(true)` deletes the old canvas without the fade-wait). Other notifications still queue one-at-a-time.

**Verified:**
- `luac -p Spoons/auto_dlp/auto-dlp.lua` passes under Lua 5.4.
- `rg`/grep confirms zero `hs.notify` / `hs.alert` calls remain (only one explanatory comment mentions `hs.notify`).
- `hs.dialog.textPrompt` signature confirmed: `(message, informativeText, defaultText, buttonOne, buttonTwo) -> button, text`.

**Notes / decisions (for review before assuming final):**
- Notification durations: button notifications 8s; mode-switch 2s; other info 3s.
- "Cancel All" clears the pending batch, the queue, and terminates all active tasks, then shows a single confirmation.
- `Cancel` on Media Detected only cancels that pending batch.
- "Open" reveals in Finder; "Open File" opens in the default player (per user's requested labels).
- **Not yet tested in a live Hammerspoon session** — needs a reload to validate button hit-boxes, queue behavior, and countdown.
- README for auto_dlp still documents the old behavior (system notifications, "Monitoring" toggle) — needs updating.

### Session 3 — 2026-09-14

**Work done — replace the manual-URL prompt with a custom webview dialog (`Spoons/auto_dlp/auto-dlp.lua`):**
- Root cause: `hs.dialog.textPrompt` uses a single-line `NSTextField` that scrolls to the caret on paste, so a long URL only showed its tail (looked like the paste failed).
- Replaced it with a custom `hs.webview` dialog (`downloadFromURL`): a wrapping `<textarea>` keeps the **whole URL visible** (multi-line, `word-break: break-all`), plus **Video/Audio** segmented buttons, an inline validation error, and Download/Cancel buttons.
- JS↔Lua bridge: `hs.webview.usercontent.new("autoDlp")` + `setCallback(fn)`; the page posts `{ action, url, mode }` via `webkit.messageHandlers.autoDlp.postMessage(...)`. Confirmed the callback receives a single Lua table and that `injectScript` can seed `window.__initialMode`.
- Initial mode is injected at `documentStart` from the current `mode` (idle → Video). Download enqueues `{ url, audioOnly }` and calls `processQueue()`; both actions close the window.
- Window: `hs.webview.newBrowser` (standard titled/closable), `deleteOnClose(true)`, `closeOnEscape(false)` (Escape is handled in JS so it routes through the cancel path), dark mode, centered on the main screen.
- Added module state `dialogWebview` and `closeURLDialog()`; message handling is deferred one tick via `hs.timer.doAfter(0, ...)` so the webview is never torn down from inside its own message pump.

**Verified:**
- `luac -p Spoons/auto_dlp/auto-dlp.lua` passes under **both** Lua 5.4 and 5.5.
- `hs.webview.usercontent` API confirmed from official docs: `new(name)`, `injectScript(scriptTable)`, `setCallback(fn)` (one message arg).
- No `hs.dialog.textPrompt` reference remains in the file.

**Follow-up fix (buttons were dead):**
- The `setCallback` handler receives a `WKScriptMessage` wrapper — the posted table is at **`scriptMessage.body`** (confirmed against heptal's working `hs.webview.usercontent` example). Previous code read `message.action` directly (nil), so Download/Cancel silently no-opped. Now reads `message.body` -> `{ action, url, mode }`.
- `dialogController` (the `hs.webview.usercontent` object) is now held at module scope for the dialog's lifetime — GC collecting the local would drop the callback even though the webview kept working.
- JS `post()` no longer swallows errors: if the bridge is missing it shows "Hammerspoon bridge unavailable" in the error line instead of failing silently.

**Notes / decisions:**
- The webview dialog, like the earlier prompt, bypasses the domain allow-list.
- Still **not live-tested in Hammerspoon** — needs a reload to validate typing/paste visibility, the Video/Audio toggle, the message bridge, and Escape/⌘↵.

---

## Backlog / Next Steps

Prioritized items for upcoming sessions:

1. **Fix HUD canvas element indexing** (moderate) — make `updateHUD()` index-agnostic (store element references, or always insert all elements as placeholders). *Note: the new Auto-DLP notification code deliberately avoids this trap by using string element `id`s.*
2. **Handle the committed ARM64 binary** (moderate) — decide: gitignore binary and rely on auto-compile, or commit universal binary.
3. **Update READMEs** (moderate) — fix all path/filename case mismatches, update structure diagram. Auto-DLP README additionally needs a rewrite of the notification/menu sections (now: custom canvas notifications with buttons, "Download URL…", no "Monitoring" toggle).
4. **Add `.gitignore`** (minor) — ignore `.DS_Store`, untrack existing ones.
5. **Make `watcher` local** in `init.lua` (minor).
6. **Evaluate `hs.shutdownCallback` overwrite** in auto-dlp (minor).
7. **[FIXED Session 2] Lua 5.5 forward-compat** — the clipboard-watcher loop now uses `local clean = url:gsub(...)` instead of reassigning the for-loop variable, so the file is 5.5-clean too.
8. **Test on a fresh clone** — confirm no duplicate widgets on startup and that console `aural.debug = true` works.
9. **Live-test the Auto-DLP notification system** (high priority next session) — reload Hammerspoon and verify: buttons are clickable, "Cancel All" clears everything, countdown updates live, mode-switch notification fires, and the webview "Download URL…" dialog works (paste visibility, Video/Audio toggle, Escape/⌘↵).

---

## Dev Environment Notes

- **Lua for syntax checks:** `luac` is not shipped with macOS. Installed via Homebrew:
  - `/opt/homebrew/opt/lua@5.4/bin/luac` — matches Hammerspoon's Lua 5.4; **use this one**.
  - `/opt/homebrew/opt/lua/bin/luac` — Lua 5.5; useful for catching forward-compat issues but errors on some valid 5.4 idioms.
- Quick check command:
  ```bash
  luac -p init.lua Spoons/aural/aural.lua Spoons/auto_dlp/auto-dlp.lua
  ```

---

## Session Handoff Template

Copy this to begin a new session log entry:

```markdown
### Session N — YYYY-MM-DD

**Work done:**
- (what was implemented, fixed, or investigated)

**Verified:**
- (how it was tested / checked)

**Notes:**
- (things the next session must know)
```