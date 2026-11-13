# Live Caption Companion

AutoHotkey v2 app for CSR calls: keeps a transcript from Windows Live Captions, detects
the caller from 3CX, searches Salesforce, and has M365 Copilot helpers. Built for locked-down
work PCs (no admin rights, no installers): it runs on the portable AutoHotkey in `runtime\`.

- Installing, updating and releasing: [docs/INSTALL-AND-UPDATES.md](docs/INSTALL-AND-UPDATES.md)
- Code layout and rules for changes: [CLAUDE.md](CLAUDE.md)

## Plans

Ideas that are agreed in principle but not built yet. Read this before changing how apps
are started, how the main helper works, or how things are packaged.

### More apps, with the main helper as the hub

The Companion is meant to be the first of several apps. The main helper
(`app\main-helper.ahk`) started out as the owner's own hotkey script that also *summoned*
the Companion (Ctrl+Shift+Alt+L). The idea is for it to become the hub again:

```
main helper (hub, starts at login, always running)
 ├─ Ctrl+Shift+Alt+L  → Companion
 ├─ Ctrl+Shift+Alt+?  → app 2
 ├─ Ctrl+Shift+Alt+?  → app 3
 └─ shared hotkeys (Salesforce search, ServiceChannel, ...)
```

- **Apps don't depend on the hub, and the hub doesn't depend on any app.** If one fails,
  the others keep working.
- **A hotkey "summons" its app:** it starts the app if it isn't running, or brings its
  window to the front if it is. It must never start a second copy: the Companion uses
  `#SingleInstance Force`, so a second start would restart it and cut the live call record.
- **Off by default for coworkers, per person:** turning it on (e.g. a tray item
  "Start main helper at login") would put a shortcut in that person's own Startup folder
  (no admin needed) and start the hub; turning it off removes the shortcut. The choice is
  stored in the user's data, never shipped.
- **Apps are listed in a small config** (name, hotkey, where the app lives), so adding an
  app is a new line, not new code.
- **Packaging, leaning towards one bundle:** one install folder, one portable AutoHotkey,
  one Setup and one update link, containing the hub, shared code (like `salesforce.ahk`)
  and one folder per app. Simplest for coworkers on locked-down PCs.

**When:** once the second app actually exists. Until then the main helper stays as it is
now (see below).

### Where things stand today (2026.10.30)

- The main helper ships inside the Companion and is **started by the Companion**, only when
  tray > "Main helper (extra hotkeys)" is ticked (`data\live-captions.ini` [MainHelper]
  Enabled, off by default). It closes when the Companion closes.
- Ctrl+Shift+Alt+L (summon the Companion) was **removed** in this setup, because the helper
  only runs while the Companion runs. It comes back as a "summon" hotkey in the hub design.
- New hotkeys meant to be shareable go in `app\main-helper.ahk`.


Credit...
