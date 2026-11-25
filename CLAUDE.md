# Live Caption Companion

AutoHotkey **v2** app for CSR calls (Windows Live Captions transcript, 3CX caller detection,
Salesforce search, M365 Copilot helpers). Runs on locked-down work PCs: no admin rights,
no installers, only the portable 32-bit AutoHotkey in `runtime\`.

## Layout
- `app\` - everything that ships. Entry point `liveCaptionCompanion.ahk`; each feature is its own
  module with its own prefix (`Caller*`, `Assist*`, `Upd*`, `Merge*`, `Pkg*`, `SF_*`, `Lct*` = Windows Live Captions restart/test tools, `Tut*` = guided tutorial).
  `app-paths.ahk` must stay the first `#Include` (sets `DATA_DIR`, `APP_VERSION`).
- `data\` - the user's history, helpers, settings, logs. Git-ignored. Never ship it, never write app files there.
- `installer\` - `Setup.bat` + `setup.ahk`, and `Uninstall.bat` + `uninstall.ahk` (self-contained, no #Include; runs from a temp copy so it can delete the install folder; `/silent` and `/keepdata` for many PCs). A new thing the app puts outside `app\`/`data\` (shortcut, startup entry, registry, new folder in %LOCALAPPDATA%) must also be removed by `uninstall.ahk`. `tools\release.ahk` - builds releases.
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
- `app\screen-ask.ahk` (+ `screen-ask.html`, prefix `Sa*`) - Screen ask: a shortcut (Ctrl+Shift+Alt+A) freezes
  every monitor, you mark something (free hand / box / oval), type a question (optional), and it goes to the
  Copilot pool as images (all screens with the marks + close-ups of the marked areas) + a prompt, shown in the
  pool's "screen-ask" Copilot window, a page **reserved** for it in the pool (`reserve`, always loaded and warm;
  Screen ask keeps the pool running - availability is the owner's must). Its OWN app and process, generic. **OFF by default**: Companion tray >
  Screen ask > On ([ScreenAsk] in live-captions.ini), side `app\screen-ask-link.ahk` (`SaLink*`). Failure =
  marked screenshot on the clipboard + a note. Pool side: `images` in an ask (files in `APP_IMAGE_INBOX`
  only), attached by the worker per the site's `images` block. Design: `docs\SCREEN-ASK.md`.
- `app\agent.ahk` (+ `agent-protocol.ahk` `AgtProto*`, `agent-tools.ahk` `AgtTools*`/`AgtT_*`, prefix `Agt*`) - the
  Agent: a chat AI (through the pool, kept conversation `agent`) that uses tools like Claude Code. It replies
  with ONE JSON object (`{"tool","args","why"}` or `{"final"}`), the agent runs the tool (after your OK for
  `approval: ask` tools) and sends the result back (images too), until final / Stop / MaxSteps / RunMaxMin.
  Tools are MCP-shaped JSON in `app\agent\tools\*.json` + an AHK handler `AgtT_<handler>`; the messages to
  the AI are templates in `app\agent\instructions.md` (`.md`, not `.txt`: releases drop .txt files). Its OWN
  app and process, generic. **OFF by default** for workmates (tray > Agent > On, `live-captions.ini` [Agent]
  Enabled; ON by default in dev mode); Companion side `app\agent-link.ahk` (`AgtLink*`). Logs never hold the task, replies or results. Screen capture: `app\screen-grab.ahk`
  (`Grab*`). Voice tools: `agent-voice.ahk` (+ `agent\listen.ps1`). Browser tools: `agent-browser.ahk` drives a
  browser TAB in the pool (`copilot-pool-browser.ahk`, `PoolTab*`, pool message `tab`): its own window, the
  pool's sign-in, never one of the Copilot pages. Design + increments (own browser, real MCP servers, Salesforce/PC later): `docs\AGENT.md`.
- `app\same-value.ahk` (`Sv*`) - Same value highlighter: hold CapsLock (a tap stays CapsLock) -> every monitor
  captured + Windows OCR -> a see-through, click-through layered window per monitor marks ID-like values:
  same colour + number = equal, red dashed = almost the same (one edit apart), faint = no twin. Pieces:
  `same-value-read.ahk` (`SvRead*`, capture in memory + checksum so unchanged monitors reuse their last OCR),
  `same-value-match.ahk` (`SvMatch*`, PURE words -> marks), `same-value-overlay.ahk` (`SvOv*`, GDI+ +
  UpdateLayeredWindow, no WebView2). Local only, logs hold counts/times only. Own app and process, OFF by default:
  Companion tray > Same value highlighter (`same-value-link.ahk`, `SvLink*`, [SameValue] Enabled; "Show now"
  while off starts it with `/once`). Settings window `same-value-settings.ahk` (`SvSet*`, built from one field
  list - a new setting = one entry + its default in `SV_DEFAULTS`), saved in `data\same-value.ini`. Design: `docs\SAME-VALUE.md`.
- `app\companion-settings.ahk` (`CSet*`) - the Companion's **Settings window**: ⚙ next to 📍, and tray > Settings...
  Sections on the left, built from one field list (`CSetFields`: a new setting = one entry; types at the top of the
  file). The tray menu keeps all its items too (owner's choice), so both MUST use the same functions: a tick calls the
  module's own toggle (`CallerToggle`, `PoolLinkToggle`, ...) so tray ticks follow; values use the module's setter.
  Save applies only fields changed in the window (a tray change made meanwhile is kept). A new Companion setting goes
  in both places: its module's tray item + one `CSetFields` entry. Other apps keep their own settings windows.
- `app\tooltips.ahk` (`Tip*`) - **hover tips**, shared by every app (include it after `app-paths.ahk`): `TipSet(ctl, text)`
  ("" removes; call again to change, e.g. a state), `TipAdd(ctl, text)` returns ctl for one-liners
  (`TipAdd(g.Add(...), "tip").OnEvent(...)` - keep it on ONE line, a line starting with `.OnEvent` is not chaining).
  Windows' own tooltip control, no polling. One switch for all apps: `data\tips.ini` [Tips] On (Companion Settings >
  Updates & help, and tray). **Rule: every new button gets a tip** (what it does, in plain words); skip only
  self-explaining ones (Close, Cancel, OK, Next). Not on big text boxes (they'd pop up while typing). Helpers can carry
  their own `tip` (Edit helpers > Tooltip), shown above the generic text. Screen ask's page uses HTML `title=`.
- `app\webview-guard.ahk` (`Wvg*`) - **memory guard** for every built-in browser (WebView2), used by the Companion,
  the pool and Screen ask. Rule: a WebView2 app must never outlive its users or grow without limit. The pool
  closes itself when no app/window uses it (`NoAppQuitSec`) and the Companion quits it on exit; the pool audits
  its engine every `MemAuditSec` (idle hidden pages -> WebView2 low-memory level, a page over `PageMaxMB` or the
  engine over `TotalMaxMB` -> reloads/closes idle pages); Screen ask's hidden overlay goes low-memory and is
  rebuilt over `MaxMB`. Leftover engines of OUR folders (parent not AutoHotkey) are ended at each start and every
  5 min by the Companion; tray > Copilot assist > "Built-in browser memory" shows who uses what. Any new
  WebView2 app must do the same (include it, sweep at start, audit, end with its users).
- `app\debug-trace.ahk` (`Dbg*`) - one shared timing trace, `data\debug-trace.log`, written by the Companion,
  the pool and each pool page (ms timestamps; every button click, helper prompts, pool queue/dispatch,
  page steps with a snapshot of what the page shows). Never prompt/answer/caption text. Off by default (data\debug.ini [Trace] On=1 turns it on); tray toggle.
- `app\icons\*.ico` - each app's own icon (companion, tasks, pool, screen-ask, updater), drawn by
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
