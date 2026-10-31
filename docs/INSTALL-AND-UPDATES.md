# Install and updates

## Folder layout

| Folder | What it is | Shipped? |
|---|---|---|
| `app/` | The companion and everything it includes, plus `updater.ahk`, `version.txt`, `app.ini` | Yes - updates replace it |
| `installer/` | `Setup.bat` and `setup.ahk` | Yes (Setup.bat goes to the zip's top level) |
| `runtime/` | `AutoHotkey32.exe` (v2.0.31, the build that works on work PCs) | Yes |
| `data/` | Your call history, helpers, settings, logs (git-ignored) | Never |
| `tools/release.ahk` | Builds the zip and `version.json` | No |
| `tools/dev/` | Probes and inspectors used while building features | No |
| `personal/` | Your own private scripts | No |
| `archive/` | Old versions, the standalone whisper captions script | No |

The installed copy on a coworker's PC has the same shape:
`%LOCALAPPDATA%\CaptionCompanion\` with `runtime\`, `app\`, `app.old\` (previous version), `data\` and `install.ini`.
If Windows won't run programs from AppData, Setup falls back to `%USERPROFILE%\CaptionCompanion`.

## Running it while you develop

Run `app\liveCaptionCompanion.ahk` as before. Data goes to `data\` in the repo
(on first run it copies your old files from the repo root into `data\` - nothing is moved or deleted).
A repo copy never updates itself (no `install.ini`), but *Check for updates* works, so you can test the link.

## First release (one time)

1. Run `tools\release.ahk`, click **Starter version.json**.
2. Upload `dist\version.json` to your Drive folder, share it as **Anyone with the link**, copy the link.
3. Paste it into **Update link** in the release tool. (It's saved into `app\app.ini` when you build.)

## Every release

1. `tools\release.ahk`: check the version (defaults to today, e.g. `2026.10.28`, or `.2` for a second one the same day), write *What's new*, **Build zip**.
2. Upload `dist\CaptionCompanion-<version>.zip` to Drive, share it as **Anyone with the link**, paste its link, **Make version.json**.
3. On Drive: right-click the existing `version.json` > **File information > Manage versions > Upload new version**, pick `dist\version.json`. (Uploading it as a new file would give it a new link that nobody checks.)
4. Commit `app\version.txt` (and `app\app.ini` if the link changed).

Installed copies check about 20 seconds after every start, and every 3 hours while open (`app.ini` > `CheckHours`).
When a newer version is found, a blue **Update** button appears top-right. Tray > Updates > Check for updates checks right away.

## Every release, from the command line (or Claude Code)

```
runtime\AutoHotkey32.exe /ErrorStdOut tools\release.ahk build auto "What's new\nsecond line"
```

This builds `dist\CaptionCompanion-<version>.zip` and `dist\version.json` in one go, using the links saved in
`app\app.ini` (version.json) and `tools\release.ini` (the zip). Upload both to Drive as new versions of the
existing files. `CLAUDE.md` tells Claude Code to do exactly this when you ask it to "make a release".

## New coworker

Send them the latest zip. They extract it (right-click > Extract All), double-click `Setup.bat`, click Install.
Setup finds an older copy in Downloads/Desktop/Documents and offers to bring over its history and settings.
Running Setup again repairs or updates an install and keeps their data.

## Testing the link on one PC

Tray > Updates > **Set update link…** saves a link for that PC only (in `data\live-captions.ini`) and checks it straight away.
Releases built with the release tool already carry the link, so coworkers never need this.

## Import & merge (helpers and calls from another copy)

Tray > **Import & merge from another copy…**, or the **Import & merge…** button in Call history.
Pick JSON files or whole zipped folders (several at once is fine). A preview shows what will change before anything is written:

- Helpers and contexts that are identical (ignoring case, spacing and line breaks) are skipped. Different ones that reuse a name get " (imported)" added.
- Calls are matched by ID or start time. A copy that holds more of the same call replaces the shorter one. The live call is never touched.
- `*.backup.json` files inside zips are skipped, so calls you deleted don't come back.
- Your files are copied to `*.before-import-<time>.json` in the data folder first. To undo, close the companion and rename that copy back.

## If something goes wrong

- Tray > Updates > **Go back to the previous version** swaps back to `app.old` (run it again to go forward).
- Tray > Updates > **Open update log** shows every check, download and install.
- If Drive is blocked one day, put `version.json` and the zips on a network share and set `ManifestUrl` to a path like `\\server\share\companion\version.json` - the updater handles paths as well as links.
