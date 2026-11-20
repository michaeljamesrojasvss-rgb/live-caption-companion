# Same value highlighter - design

Status 2026-11-21: **built, untested.** From the owner's task list: "similar values verifier, overlay - hold
button and the screen is captured fast and OCR performed and same text are colored the same for verifying".

## Why

You check that the work order (or phone number, invoice, amount...) in one window is the same one as in
another - an email on the left monitor, Salesforce on the right. Today: copy, Ctrl+F, look. Slow, and a
look-alike number with one different digit is easy to miss.

## What it does

**Hold CapsLock** (a short tap is still CapsLock). Every monitor is captured at once, read with Windows'
built-in OCR, and while you hold, a see-through overlay shows:

| Look | Meaning |
|---|---|
| **Same colour** (+ a small number tag) | These values are exactly the same (as OCR read them). Each group of equal values has its own colour. |
| **Red dashed outline** | Almost the same as another value on screen: differs by one character (`NearMaxDiff`). The case you'd miss. |
| **Faint grey outline** | An ID-like value OCR read, with no twin anywhere. So "no colour" means "no match", not "OCR missed it". |

Let go = it's gone. Matches on the same monitor count too (e.g. an email's subject and body).
Mouse way: Companion tray > Same value highlighter > "Show now" (shows for `ShowSec`, Esc closes it).

**A colour means "OCR read the same characters", not a guarantee.** OCR can misread 0/O, 1/l/I, 5/S, 8/B. A
misread on one side shows as "no match" or "almost the same" (safe: you check by hand). A misread that turns
a different digit into the same one is possible but rare; `Scale` 2 makes OCR more accurate (and slower).

## Rules (same as the other apps)

1. **Its own app and process** (`app\same-value.ahk`, prefix `Sv*`): if it fails, captions and calls carry on.
2. **OFF by default** for everyone: Companion tray > "Same value highlighter" > On (`live-captions.ini`
   [SameValue] Enabled). Ends with the Companion.
3. **Local only:** no AI, no internet. Screenshots stay in memory (never written to disk). The log
   (`data\same-value.log`) and the debug trace hold counts and times only - never text from the screen.
4. **Nothing hard-coded:** what counts as a value, how values are compared, colours, keys, timing - settings.
5. **Speed first** (owner): OCR at 1x by default; only monitors whose picture changed are read again
   (a second hold on an unchanged screen is instant).

## How it works

```
hold CapsLock (HoldMs) ─► capture every monitor (same-value-read.ahk: one picture each, real pixels)
                       ─► "Reading..." note on screen
                       ─► OCR each monitor that changed since last time (others: last result reused)
                       ─► match (same-value-match.ahk: pure logic, words in -> marks out)
                       ─► draw (same-value-overlay.ahk: one see-through, click-through window per monitor)
let go                 ─► hidden (a read still running is cancelled)
```

- **Overlay:** a layered window per monitor (no browser engine): appears instantly, little memory, clicks pass
  through it, never takes the focus. Mixed scaling: each window works in that monitor's real pixels.
- **Values** (`same-value-match.ahk`): each OCR word, trimmed of surrounding punctuation (`TrimChars`). Number
  pieces OCR split on one line (`555 123 4567`, `12 345`) are joined back when close together (`JoinNumbers`,
  `JoinGap`). A value counts if it is ID-like: at least `MinChars` letters/digits, has a digit (`NeedDigit`)
  and fits `IdPattern`. Compared after removing `IgnoreChars`, ignoring case unless `CaseSense`.
- **Almost the same:** two different values of at least `NearMinChars` characters that differ by at most
  `NearMaxDiff` edits (one character changed, added or missing).
- **Cache:** each monitor's picture gets a checksum; unchanged = the last OCR words are reused.

## Settings

Tray > Same value highlighter > **Settings...**: a window with four tabs (Hold & read, Values, Almost the
same, Look), colour pickers, **Defaults**, **Try it** (save + show now) and **Settings file** (the raw
`data\same-value.ini` [Settings]). Save checks every value first; changes apply at once (the hold key too).
The window is built from one list of fields in `same-value-settings.ahk`: a new setting = one entry there.

**Quick setup** (Values tab, owner's request 2026-11-21): one click fills in a set of settings (`SV_PRESETS`
in `same-value.ahk` - data, not code), not saved until Save / Try it:

| Preset | What counts | Almost-same | No-twin outline |
|---|---|---|---|
| **IDs only** (the default) | values with a digit, 5+ characters, ID pattern | on, 6+ characters | on |
| **Words too** | any word of 3+ letters, except the ignore list | on, 8+ characters (fewer their/there) | off (too many) |
| **Everything** | every word, even 1 letter, no ignore list | off | off |

| Key | Default | |
|---|---|---|
| `HoldKey` | `CapsLock` | The key to hold (an AutoHotkey key name). A tap still does what the key does. |
| `HoldMs` | `250` | How long to hold before it starts (shorter = a tap may trigger it) |
| `Scale` | `1` | OCR enlargement: 1 = fastest, 2 = reads small text better (about 3-4x slower) |
| `OcrLang` | (empty) | OCR language, e.g. `en-US`; empty = the first one Windows has |
| `MinChars` | `5` | Fewest letters/digits for a value to count |
| `NeedDigit` | `1` | 1 = only values with a digit (IDs, numbers, dates); 0 = words too |
| `IdPattern` | `^[A-Za-z0-9][A-Za-z0-9\-_./#:]*$` | A value must fit this (regular expression, after trimming) |
| `TrimChars` | `()[]{}<>.,;:'"` | Taken off both ends of each word |
| `IgnoreChars` | (empty) | Removed before comparing, e.g. `-` so `WO-123456` = `WO123456` |
| `IgnoreWords` | common English words + email words | Never count these (commas between); same case/IgnoreChars rules as values |
| `CaseSense` | `0` | 1 = `abc12` and `ABC12` differ |
| `JoinNumbers` | `1` | Join number pieces split by spaces |
| `JoinGap` | `0.8` | ...when the gap is at most this many times the text height |
| `NearMiss` | `1` | Show the red "almost the same" outline |
| `NearMinChars` | `6` | Fewest characters for "almost the same" |
| `NearMaxDiff` | `1` | Most differences for "almost the same" |
| `ShowAlone` | `1` | Faint outline on values with no twin |
| `Dim` | `15` | Darken the screen behind the marks (0-80 %) |
| `FillAlpha` | `80` | How strong the colour fill is (0-255) |
| `LineWidth` | `3` | Outline thickness at 100% scaling |
| `Numbers` | `1` | Number tags on matching groups |
| `Links` | `0` | Thin lines connecting the values of a group (each to the next in reading order, centre to centre, in the group's colour; drawn under the marks, across monitors too) |
| `LinkNear` | `1` | With `Links`: a red dashed line between the two values of each "almost the same" pair |
| `LinkWidth` | `1` | Line thickness in pixels |
| `Colors` | 12 colours | Group colours, in order (`#RRGGBB`, separated by commas) |
| `NearColor` / `AloneColor` | `#FF3B30` / `#9CA3AF` | |
| `ShowSec` | `8` | "Show now" (tray): how long the overlay stays |
| `Reuse` | `1` | Reuse the last OCR of a monitor whose picture didn't change |

## Files

| File | |
|---|---|
| `app\same-value.ahk` | The app: hold key, settings, tray when started on its own |
| `app\same-value-read.ahk` | Capture + change check + OCR per monitor (`SvRead*`) |
| `app\same-value-match.ahk` | Words -> marks: values, groups, almost-same, alone (`SvMatch*`) - pure |
| `app\same-value-overlay.ahk` | The see-through windows (`SvOv*`) |
| `app\same-value-settings.ahk` | The settings window, built from one list of fields (`SvSet*`) |
| `app\same-value-link.ahk` | Companion tray item, start/stop (`SvLink*`) |
| `app\screen-grab.ahk` | Shared monitor list + capture (`GrabToHBitmap`) |
| `app\lib\OCR.ahk` | Windows OCR (Descolada, unmodified) |

## Ideas for later

- Point at the differing character in an "almost the same" pair (OCR gives word boxes only, so it would be
  an estimate).
- Hover a mark to see the exact text OCR read.
- Only values near the mouse / in the active window, for very busy screens.
