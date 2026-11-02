# Live Caption Companion

AutoHotkey **v2** app for CSR calls (Windows Live Captions transcript, 3CX caller detection,
Salesforce search, M365 Copilot helpers). Runs on locked-down work PCs: no admin rights,
no installers, only the portable 32-bit AutoHotkey in `runtime\`.

## Layout
- `app\` - everything that ships. Entry point `liveCaptionCompanion.ahk`; each feature is its own
  module with its own prefix (`Caller*`, `Assist*`, `Upd*`, `Merge*`, `Pkg*`, `SF_*`).
  `app-paths.ahk` must stay the first `#Include` (sets `DATA_DIR`, `APP_VERSION`).
- `data\` - the user's history, helpers, settings, logs. Git-ignored. Never ship it, never write app files there.
- `installer\` - `Setup.bat` + `setup.ahk`. `tools\release.ahk` - builds releases.
- `app\main-helper.ahk` - extra hotkeys (Salesforce/ServiceChannel from clipboard, etc.). Ships, but OFF by
  default: each person turns it on from the tray, saved in their own `data\live-captions.ini` [MainHelper].
  Runs as its own process (started by `main-helper-host.ahk`). New personal-but-shareable hotkeys go here.
- `tools\dev\` - probes/inspectors (not shipped). `personal\` - the owner's private scripts (never shipped). `archive\` - old code.
- Details: `docs\INSTALL-AND-UPDATES.md`.
- Future plans (more apps, main helper as a hub that summons them, one bundle): `README.md` > Plans.
  Check it before changing how apps start, the main helper, or packaging.

## Rules for changes
- Captions and the live call must keep working even if a feature module fails: wrap entry points
  in try/catch, report problems in the status line and the module's log.
- Never click or type into 3CX. Never send to Copilot unless the existing safety checks pass.
- New user data goes in `DATA_DIR`; anything that ships goes in `app\`.
- AutoHotkey v2 syntax traps that have bitten this project (there is no way to run AHK in Linux, so check by reading):
  - A one-line `try X` directly before `else` (even with `}` between) makes AHK attach the `else` to the
    `try`. Use braces around the try, or restructure.
  - A string in single quotes can't contain a single quote (and double-quoted strings need `` `" ``).
  - Put fat-arrow assignments in parentheses: `() => (x := 1)`.

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
