# Live Caption Companion

AutoHotkey **v2** app for CSR calls (Windows Live Captions transcript, 3CX caller detection,
Salesforce search, M365 Copilot helpers). Runs on locked-down work PCs: no admin rights,
no installers, only the portable 32-bit AutoHotkey in `runtime\`.

## Layout
- `app\` - everything that ships. Entry point `liveCaptionCompanion.ahk`; each feature is its own
  module with its own prefix (`Caller*`, `Assist*`, `Upd*`, `Merge*`, `Pkg*`, `SF_*`, `Lct*` = Windows Live Captions restart/test tools, `Tut*` = guided tutorial).
  `app-paths.ahk` must stay the first `#Include` (sets `DATA_DIR`, `APP_VERSION`).
- `data\` - the user's history, helpers, settings, logs. Git-ignored. Never ship it, never write app files there.
- `installer\` - `Setup.bat` + `setup.ahk`. `tools\release.ahk` - builds releases.
- `app\main-helper.ahk` - extra hotkeys (Salesforce/ServiceChannel from clipboard, etc.). Ships, but OFF by
  default: each person turns it on from the tray, saved in their own `data\live-captions.ini` [MainHelper].
  Runs as its own process (started by `main-helper-host.ahk`). New personal-but-shareable hotkeys go here.
- `app\tasks.ahk` (+ `tasks-alert.ahk`, prefix `Task*` / `TAlert*`) - the Tasks app: nested tasks, timers,
  planned timers, alerts on every virtual desktop, templates, read aloud. Its OWN app and process, and it
  must stay **call-agnostic**: no call/3CX/caption words or fields in it. Other apps give it generic
  links {app, id, label} and a "busy" flag; the protocol is at the top of `tasks.ahk`. Data:
  `data\tasks.json`, `data\task-templates.json` (new templates in `app\task-templates.default.json` are
  added once, by id), `data\tasks.ini`. The Companion side is `app\tasks-link.ahk` (`TaskLink*`): starts
  it (on by default, tray toggle), the Tasks button, sends the call on screen + busy, answers "open".
  Tasks never reads call-history.json.
- `app\copilot-pool.ahk` (+ `copilot-pool-worker.js`, prefix `Pool*`) - the Copilot pool: hidden Copilot pages
  in WebView2 (`app\lib\`, see its README) that answer prompts. Its OWN app and process, **generic** (no
  call words, like Tasks): text in, text out, one-off or kept "conversations". Work account only (personal
  domains refused unless the testing switch is on). Never sends a prompt twice; its log never holds prompt
  or answer text. Protocol at the top of `copilot-pool.ahk`. Companion side: `app\copilot-pool-link.ahk`
  (`PoolLink*`): starts it (tray > Copilot assist, ON by default), and the **💬 and ^ buttons** beside the
  helpers (only while the pool is on): 💬 opens that helper's OWN Copilot window (a pool page, conversation
  `helper-<id>`) with the full prompt; 💬 again sends into the same window/chat. ^ = follow-up into it with
  only what the customer said since (like auto-assist, but on click). Both are orange while the window is
  open (the pool lists open windows in its "state"). Each window remembers its own place/size; closing it
  frees the page. One sign-in for all pages; "Sign out" switches to a new empty sign-in folder
  (`profile-<n>`), single sign-on is OFF by default; one pool page kept ready by default. 🤖, ➤ Ask and ⚡
  auto-assist do NOT use the pool (they paste as before; their overhaul comes later).
  **Auto helpers** (`app\auto-helpers.ahk`, `Auto*`): helpers ticked "Auto-run during calls" (right-click,
  saved in `live-captions.ini` [AutoHelpers]) work only in their own 💬 window, only while it is open
  (no hidden pages, no combined window - removed 2026-11-20 at the owner's request). At a new call (New
  call / 3CX ring) each opens its window by itself (remembered place, no focus: ask `quiet`) - or reuses
  the open one - with a fresh chat + the full prompt; closed during the call = stays closed until the next
  call. Then a follow-up with the new customer words when the customer pauses (like ^). 💬, ^ and auto share what the
  window has seen (`poolLinkHelperSeen`, tied to the call). Auto prompts never replace text you typed in
  the window (`respectDraft`). Design and plans: `docs\COPILOT-POOL.md`.
- **Caption capture** (`ProcessSnapshot` + `Cap*` in `liveCaptionCompanion.ahk`): Live Captions rewrites
  lines it already showed (punctuation, numbers "twenty three" -> "23", "road" -> "Rd.", sometimes many
  seconds later). Only words added at the end are new speech (`CaptionNewAt`); a rewrite updates the
  bubble in place, never adds it again. The debug trace logs `[caption]` events (line numbers, word
  counts, how a line changed) - never the words.
  **Chat sites are plug-in data**: `app\chat-sites\<id>.json` (README there) holds everything site-specific
  (address, hosts, sign-in/out, account rule, selectors, `newChat` link|navigate, `answer` copy-button|settle).
  The pool and `copilot-pool-worker.js` must stay site-agnostic - a new site (Claude, Gemini...) is a new
  file, plus worker code only for a genuinely new newChat/answer kind. `devOnly` sites (Google AI Mode, for
  testing without Copilot) load only in **dev mode** = `AppIsDev()` in `app-paths.ahk` (git working copy,
  not installed; `[Dev] On=0` in live-captions.ini turns it off); picked in the pool window's "Chat site" list.
- `app\debug-trace.ahk` (`Dbg*`) - one shared timing trace, `data\debug-trace.log`, written by the Companion,
  the pool and each pool page (ms timestamps; every button click, helper prompts, pool queue/dispatch,
  page steps with a snapshot of what the page shows). Never prompt/answer/caption text. Off by default (data\debug.ini [Trace] On=1 turns it on); tray toggle.
- `app\icons\*.ico` - each app's own icon (companion, tasks, pool, updater), drawn by
  `tools\dev\make-icons.ps1`. Every app script starts with `TraySetIcon(...)` and its own
  `SetCurrentProcessExplicitAppUserModelID` (own taskbar button; they all run on the same AutoHotkey32.exe).
  A new app gets a new icon + app ID the same way. Every icon carries the owner's signature: a cyan
  (#22D3EE) rounded-square ring around the app's coloured tile - keep it on any new icon.
- `tools\dev\` - probes/inspectors (not shipped). `personal\` - the owner's private scripts (never shipped). `archive\` - old code.
- Details: `docs\INSTALL-AND-UPDATES.md`.
- Future plans (more apps, main helper as a hub that summons them, one bundle): `README.md` > Plans.
  Check it before changing how apps start, the main helper, or packaging.

## Rules for changes
- Captions and the live call must keep working even if a feature module fails: wrap entry points
  in try/catch, report problems in the status line and the module's log.
- Never click or type into 3CX. Never send to Copilot unless the existing safety checks pass (paste path:
  the checks in `copilot-assist.ahk`; pool path: ready state + work account, and one send per prompt).
- New user data goes in `DATA_DIR`; anything that ships goes in `app\`.
- AutoHotkey v2 syntax traps that have bitten this project (there is no way to run AHK in Linux, so check by reading):
  - A one-line `try X` directly before `else` (even with `}` between) makes AHK attach the `else` to the
    `try`. Use braces around the try, or restructure.
  - A string in single quotes can't contain a single quote (and double-quoted strings need `` `" ``).
  - Put fat-arrow assignments in parentheses: `() => (x := 1)`.
- GUI rendering traps (they caused black blocks over list headers and ghost pixels):
  - A Text control added without `h` gets the height its text needs at the given width - a long
    label becomes 2 lines tall and later paints over the control below it. Labels in resizable
    windows always get an explicit `h` (e.g. `h20`).
  - Never let controls overlap. After a layout pass, repaint the whole window once
    (`RepaintWindow` in the Companion, `TaskRepaint` in Tasks), on a short timer.

## Releases
Releases are automatic: every push to `main` that changes `app\`, `installer\`, `runtime\` or
`tools\release.ahk` is built and published by GitHub Actions (`.github\workflows\release.yml`). Put a line
`Release-note: <what changed, for workmates, plain language>` in the commit message for the "What's new" text.
Nothing to build or upload by hand.

## Making a release by hand (only if Actions is down; "make a release" / "build a new version")
1. Make sure the changes are done and committed.
2. Run (from the repo root, on Windows):
   ```
   runtime\AutoHotkey32.exe /ErrorStdOut tools\release.ahk build auto "What's new line 1\nline 2"
   ```
   `auto` = today's date as the version (or `.2`, `.3` for more the same day); a version like
   `2026.10.30` can be given instead. It prints `OK: ...` or `FAILED: ...` (also saved in
   `dist\release-result.txt`) and exits 0/1. Write the notes for the workmates who use the app:
   short, plain language, what changed for them.
3. Output in `dist\`: `CaptionCompanion-<version>.zip` and `version.json`.
4. Tell the user to upload both to Google Drive **as new versions of the existing files**
   (right-click > File information > Manage versions > Upload new version) - never as new files,
   or the links that installed copies and workmates use would stop pointing at the latest version.
5. Commit `app\version.txt`.
