# Screen ask - design

Status 2026-11-20: **built, untested.** Like Android's circle to search, except you mark the screen before
it's sent, so the AI knows what you mean.

## What it does

1. Press **Ctrl+Shift+Alt+A** (Settings to change it), or tray > Screen ask > Capture and ask now.
2. **Every monitor freezes** (a screenshot shown on top of everything, with a cyan frame per monitor).
3. **Mark** what you mean: free hand (default), box or oval, as many marks as you like (2+ are numbered).
   Right-click or Ctrl+Z = undo, Esc / Cancel = nothing is sent. **Whole screen** = ask without marking.
4. A **question box** appears next to your mark: type a question, or leave it empty ("Explain what I
   marked."). **Enter / Send** sends it. **Copy image** puts the marked screenshot on the clipboard instead.
   **Copy text** (box, toolbar or T) = quick OCR instead: the text of the marked areas (or the whole
   screen if nothing is marked) goes on the clipboard. Read on this PC by Windows' built-in OCR
   (`lib\OCR.ahk`, Descolada/OCR, MIT) from the clean screenshot - never the marks; small areas are
   enlarged 2-3x first. Nothing is sent. Language: `OcrLang` (empty = Windows' first OCR language).
   Tested 2026-11-21 on a 1080p screen: ~160 ms, good on normal UI text; icons can come out as stray
   characters and I/l can mix (e.g. "AI" -> "Al"). For tables/tiny text a "Copy exact text (Copilot)"
   option could come later.
5. The screen comes back at once, and the pool's **Screen ask Copilot window** opens with the answer.
   Follow-up questions go in that window. The window remembers its place.

## What goes to the AI

- **Image 1:** all monitors with the marks drawn on (context), made smaller if it's over `FullMaxSide` px.
- **Images 2+:** a sharp **close-up of each marked area**, with some margin around it. Marks close together
  share one close-up; with more than `MaxCloseUps` groups there is one close-up around all of them. These
  are needed because with 2-3 monitors the AI shrinks the whole picture and small text gets unreadable.
- **The prompt** (`Prompt` setting, placeholders filled in by the app), e.g.
  *"Image 1 is a screenshot of my screen (all 3 of my monitors). I marked the part I'm asking about in red.
  Image 2 is a close-up of the marked part. Focus on what I marked; use the rest of the screen only as
  context. <your question>"*

## How it's built

```
screen-ask.ahk (own process)                        copilot-pool.ahk (own process)
  shortcut -> GDI capture of every monitor (PNG)       ask {prompt, images:[paths], show, conversation
  overlay window over all monitors                          "screen-ask", newChat}
    WebView2 page screen-ask.html (local folder only)  -> reads the files (inbox folder only, size checked)
    marks, question, makes the images (canvas)         -> page job: "images-get" -> attach -> type -> Send once
  images -> %LOCALAPPDATA%\CaptionCompanion\pool-images  -> shown as the Screen ask Copilot window
  failure -> marked screenshot on the clipboard + note  <- queued / sent / done
```

- **Own app and process** (`app\screen-ask.ahk`, prefix `Sa*`), generic (no call words). **Off by default**:
  Companion tray > "Screen ask" > On (`live-captions.ini` [ScreenAsk] Enabled, per person). Started by the
  Companion: no tray icon, ends with it. Double-clicked on its own: its own tray icon. Companion side:
  `app\screen-ask-link.ahk` (`SaLink*`), with mouse ways to everything (Capture and ask now, Settings).
- **Multi-monitor, mixed scaling:** the capture and the overlay use real screen pixels (per-monitor DPI on
  the thread while capturing and placing the overlay; the overlay ignores WM_DPICHANGED). The WebView's
  RasterizationScale is 1, so the page shows the screenshot 1:1 and sizes its toolbar per monitor.
- **Fast:** the overlay and its WebView are made once at the start and kept hidden. The shortcut only
  captures, saves the PNG and tells the page; the window appears once the page has drawn it.
- **Instant Send (prepared ahead, 2026-11-23):** the trace showed 2.2-8 s between Send and the question
  being in Copilot (new chat ~0.4 s, two image pastes ~1-1.7 s, upload ~0.5 s, and a failed paste try =
  6 s). Now the moment a mark is done the page makes the images (`stage`) and Screen ask sends a **held**
  ask (`hold: 1`): the pool's page opens the new chat and attaches the images while you type, then waits.
  Send only brings the prompt (`release`) - typed and clicked in ~50 ms. A changed mark = the held ask is
  cancelled (`restore: 0`) and a new one made; Esc / Copy / a new capture = cancelled, nothing sent, and the
  window shows the chat it had before again. If the held ask failed meanwhile, Send asks the normal way.
  The page also tries the attach way that worked last time first. A new ask never waits for the previous
  answer: it's sent with `preempt`, so an answer still being written is stopped (owner's choice 2026-11-23;
  it stays in Copilot's history; a question not yet IN Copilot is never dropped). Trace: `PREPARED ahead`, `RELEASED`,
  page `prepared - waiting for the prompt` / `prompt arrived ... typing and sending`.
- **Pool images** (generic, any app can use them): `images` in an ask = file paths, which must be in
  `APP_IMAGE_INBOX` (PNG/JPEG, up to `ImageMaxMB`). The pool reads them when the request arrives and gives
  them to the page only when it asks for them (never stored in the page or logs). The page attaches them
  before typing, trying the site's `images.how` ways (paste / drop / file input / trusted file input via
  the DevTools protocol), and checks that the box shows each one. All or nothing: a failure before Send is
  `unsent`. Chat sites without `images` refuse such requests (`chat-sites\README.md`).
- **Always available (owner, 2026-11-20: "non-negotiable"):** Screen ask keeps the pool running (starts it
  if it isn't, even if the Companion's "Use the Copilot pool" is off) and has its **own reserved page** in
  it (`reserve screen-ask`, re-sent every 5 s), loaded and warm before you ask, never lent to helpers. A
  question waits for Copilot (sign-in included) instead of failing, with a note saying what it waits for
  until it's in Copilot.
- **Falls back** only when it really can't: pool not up in 90 s, not a work account, attach failed... = the
  marked screenshot goes on the clipboard and a note says why ("paste it into Copilot").
- Every message from the page carries its capture's id: a late Send of one capture never closes a newer one.

## Privacy and safety

- The pool's rules apply: **work account only**, never sends twice. Google AI Mode is dev-only - never use
  it for screens with customer data.
- Screenshots stay on this PC (`%LOCALAPPDATA%\CaptionCompanion\screen-ask` and `pool-images`, never
  OneDrive), are deleted when the request ends, at the start, and after `KeepMin` minutes at most.
- The overlay page loads only from its own local folder (`https://screen-ask.example/`, virtual host
  mapping); any other address is blocked, no popups, no context menu, no browser keys, dev tools only in
  dev mode. Messages are accepted from that page only.
- Logs (`data\screen-ask.log`) and the debug trace hold counts, sizes and timings - never the question,
  the prompt or images.

## Settings (`data\screen-ask.ini` [Settings]; the Settings window has the common ones)

| Key | Default | |
|---|---|---|
| `Hotkey` | `^+!a` | AutoHotkey key name (`^` Ctrl, `+` Shift, `!` Alt, `#` Win). Empty = no shortcut. |
| `DefaultQuestion` / `WholeQuestion` | Explain what I marked. / Explain what's on my screen. | When nothing is typed. |
| `MarkColor` | `Red` | Red, Orange, Yellow, Green, Cyan, Magenta (the prompt names it). |
| `LineWidth` | `4` | At 100% scaling. |
| `CloseUps` / `MaxCloseUps` | `1` / `3` | |
| `FullMaxSide` | `4096` | 0 = never shrink image 1. |
| `NewChat` | `1` | 0 = each capture goes on in the same chat. |
| `Conversation` | `screen-ask` | The pool's name for the window (place/size remembered in copilot-pool.ini). |
| `KeepMin` | `30` | |
| `Prompt` | see the file | `{{screens}} {{marked}} {{closeups}} {{focus}} {{question}}`, `\n` = new line. |

## To check in the first tests (debug trace on: `[screen]` lines + the pool page's `image n attached by ...`)

1. Freeze speed (`frozen screen shown N ms after the shortcut`) with all monitors, and that the
   overlay lines up exactly on each monitor (mixed scaling too).
2. Which attach way works on Copilot (`paste` is expected); if none, the page trace shows what was tried.
   Tune `images` / selectors in `chat-sites\copilot.json` (or `data\chat-sites\copilot.json` on one PC).
3. That Send waits for the upload (`attachBusy` is a guess).

## Ideas for later

- Hold Shift with the shortcut = add to the current Screen ask chat instead of a new one.
- Arrow and text-label tools; blur a part before sending (customer details).
- The main helper as the hub that summons it (README > Plans).
