# Copilot pool - design

Status 2026-11-20: proven by `tools\dev\copilot-webview-probe.ahk` at home with a personal Copilot
account (32-bit AutoHotkey, 2 hidden pages answering in parallel, ~10 s each). **Built:** the pool
app and the **💬 buttons**. ON by default for everyone (switch it off: tray > Copilot assist > "Use the Copilot pool"), being
tested at home with a personal account ("Allow personal accounts (testing only)"). Still to prove:
the work account on the work PC.

## What it is

The extension's Copilot pool (`automation-extension\bridge\`), rebuilt inside AutoHotkey: a few
hidden Copilot pages hosted in WebView2, kept ready. Any app sends text and gets text back.

```
Companion (its own process)                 Copilot pool (its own process)
  💬 beside each helper ── ask, show ──────►  ┌─ hidden Copilot page 1 ─┐
                                              │  hidden Copilot page 2  ├─ worker.js in each page
                         ◄── sent / done ───  └─ (more, up to MaxViews) ┘
                                              the page that took it appears as a Copilot window
                                              (yours until you close it, then back to the pool)
  🤖 / ➤ Ask / ⚡ auto-assist: unchanged, paste into the Copilot app as before
```

## In the Companion: the 💬 buttons

- Each helper gets a **💬** next to its 🤖, **only while the pool is on** (workmates who don't
  use it see no change).
- 💬 builds the prompt exactly like 🤖 (also copied to the clipboard), sends it to the pool, and
  that Copilot page **appears as a normal Copilot window right away**. You watch the answer being
  written, with Copilot's own formatting and buttons, and **can keep chatting** in it.
- **The page is yours until you close that window.** The pool never types into it. When you
  close it, it gets a fresh chat and goes back to the pool. Meanwhile the pool opens another page
  (up to `MaxViews`) so the next 💬 doesn't wait.
- If every page is open as a window and no more may open, 💬 says "close one and try again".
- **💬 just works:** if the pool isn't running it is started, and the request goes as soon as
  it's up; if Copilot needs a sign-in, the **sign-in window opens** and the request runs by itself
  right after you sign in (it waits up to `SignInWaitSec`, 10 min). If the signed-in account isn't
  allowed, the pool window opens with the reason. 🤖 is still there to paste instead.
- 🤖, ➤ Ask and ⚡ auto-assist **don't use the pool yet**. Their overhaul comes later.

## Rules (same spirit as Tasks)

1. **Its own app and process** (`app\copilot-pool.ahk`, prefix `Pool*`). If it crashes or hangs,
   captions and the call carry on.
2. **Generic.** It knows nothing about calls, captions, helpers or customers. Requests are
   `{prompt, label, conversation, show}`. The Companion side is `app\copilot-pool-link.ahk`
   (`PoolLink*`), like `tasks-link.ahk`.
3. **Never send twice.** The worker clicks Send once and waits (Copilot takes 5-7 s to register
   it). It only tries another way if the prompt is still in the box. A prompt that may have
   reached Copilot is never resent (`PoolLinkNeverSent` lists the failures that are safe to retry).
4. **No call text in logs.** `data\copilot-pool.log` holds states, timings and errors only.
5. **Work account only.** Requests are refused while a personal account is signed in, so customer
   details never go to a personal Copilot. Personal = an email at one of `PersonalDomains`
   (gmail.com, outlook.com, hotmail.com, live.com, yahoo.com, icloud.com, ...) or Microsoft's
   personal-account tenant; anything else is work. The pool reads the email from Copilot's own
   sign-in data in the page, or the page's labels. If it can't read it, the pool window asks
   ("It's my work account"). **Testing switch:** "Allow personal accounts (testing only)" accepts
   any signed-in account.
6. **On by default** for everyone (decided 2026-11-20). Anyone can
   turn it off. The choice is in their own `live-captions.ini` [CopilotPool].
7. **Nothing hard-coded:** address, page counts, waits, personal domains and page selectors are
   settings.

## Safety of the built-in browser

WebView2 is Microsoft Edge's own engine (the "Evergreen" runtime that updates with Edge/Windows,
same version as Edge), so it has the same security fixes, sandboxing and site isolation as Edge.
What differs, and how the pool handles it:

- **No address bar:** the sign-in window's title shows the site you're on (check for
  `login.microsoftonline.com` or your company's sign-in page).
- **Our script in the page:** it runs only on Copilot's own addresses (`AllowedHosts`), and the
  pool only accepts messages from those pages, so another site can't feed it a fake account or
  answer.
- **Only https** pages load; links in a 💬 window open in your normal browser, not in the pool.
- **No debugging port** is opened (the DevTools protocol is used in-process for typing without
  focus; no other program can connect). Developer tools are switched off.
- **Sign-in data** sits in `%LOCALAPPDATA%` like Edge's own profile, encrypted for your Windows
  account, never in a synced folder. Sign out deletes it.
- **Company control:** WebView2 follows the Edge policies IT sets for WebView2, and sign-in goes
  through Microsoft's normal sign-in, so company sign-in rules still apply.

## Rules for any site we host or automate (Salesforce and others, later)

The engine is no weaker than Edge. The extra risk is in **our app around it**. Before any other
site (e.g. Salesforce, which holds customer records) runs in an AHK WebView:

1. **Ask IT first.** Some company protections only work inside Edge itself, e.g. Microsoft Purview
   **Endpoint DLP** (blocks copying/uploading customer data) and some Defender / Conditional Access
   policies. A WebView2 app may not be covered, so using customer systems in it could bypass
   monitoring the company relies on. That is a compliance question, not only a technical one.
2. **Narrow message channel.** Any page in a view can send messages to AHK. Accept only a short list
   of message types, **check the sending site** on every message (`args.Source`), and never let a
   message make AHK run programs, read files or type into other windows.
3. **Never expose AHK objects to pages** (WebView2 "host objects", `AddHostObjectToScript`).
4. **Never bypass certificate errors** (no `ServerCertificateErrorDetected` handler that continues).
5. **Never open a remote-debugging port** (`--remote-debugging-port`, the "drive Chrome from AHK"
   approach): while it's open, any program on the PC can take over every signed-in session. Use the
   in-process DevTools protocol only.
6. **One profile per purpose:** a separate user-data folder (or WebView2 profile) per site family,
   e.g. Copilot and Salesforce never share cookies.
7. **Lock it down per site:** load only that site's own addresses (https only, plus its sign-in
   pages), links elsewhere open in the normal browser, saved passwords off, camera / microphone /
   location requests denied, downloads decided on purpose, developer tools off.
8. **Our injected script reads only what the feature needs**, and nothing it reads goes to logs or
   disk. Whoever can change our scripts can read the site, so:
9. **Protect the update channel:** the Companion updates from GitHub releases and Google Drive, so
   whoever controls those accounts can put code into every workmate's sessions. Two-factor sign-in
   on GitHub and Google, and nobody else can push to `main`.
10. **Sign-in data** lives in `%LOCALAPPDATA%` (never a synced folder), and there is a Sign out.

## Conversations (built into the pool, not used by the Companion yet)

| Kind | What the pool does |
|---|---|
| **One-off** (`conversation` empty) | Any free page. New chat before; clean chat after. |
| **Shown** (`show`) | One-off, but the page appears as your window and is yours until you close it (💬). |
| **Kept** (`conversation` = a name) | The first request claims a page and the chat is kept; follow-ups go to the same page, so only the new part is sent. Ends on `end` or after `ConversationIdleMin`. If the page is lost, the next reply says `lost` and the app sends the full context again. |

Kept conversations are for the ➤ Ask / ⚡ overhaul and the live helpers board (below).

## Messages (WM_COPYDATA, tag `0x3CC3`, JSON text)

The full list is at the top of `app\copilot-pool.ahk`. In short:
- **app → pool:** `ask {id, hwnd, prompt, label, conversation, newChat, stream, show}`,
  `cancel {id}`, `end {conversation}`, `status {hwnd}`, `show`, `signin`, `quit`.
- **pool → app:** `queued`, `sent` (the prompt is in Copilot: never resend after this), `chunk`
  (live text, if `stream`), `done {ok, kind, text, markdown, error, ms}`, `state`.
- **`kind` when not ok:** `unsent` / `off` / `starting` / `signin` / `account` / `busy` (never
  reached Copilot), `lost` (kept conversation gone), `failed` / `timeout` / `cancelled` (may have
  reached Copilot: don't resend).

## The pool window

State in plain words, the account, **Sign in...**, **It's my work account** (only when the
account can't be read), **Sign out**, the testing switch, how many pages to keep ready, the list of
requests in progress (label and time only) with **Cancel selected**, a **Test** box, **Copy log**,
**Settings file**, **Show the pages** (troubleshooting) and **Restart pool**. Closing it only hides
it; the pool keeps running.

**Restarts:** the pool restarts every time the Companion starts (so it always runs the current
files), and by hand from tray > Copilot assist > "Restart the Copilot pool" or the pool window's
**Restart pool**. The sign-in is kept; open 💬 windows close.

**Sign out and restart** (pool window, or tray > Copilot assist > "Sign out of Copilot and restart
the pool"): opens Microsoft's own sign-out page in a window (Microsoft-account sign-out first for a
personal account, then work/school), which **ends the sign-in at Microsoft**, not only on this PC.
When it says you're signed out, close that window: the pool deletes the local sign-in data and
restarts, ready to sign in again. (With single sign-on on, a work PC may sign in again by itself
with the Windows account.)

## Settings (`data\copilot-pool.ini` [Settings], "Settings file" button)

| Key | Default | |
|---|---|---|
| `Address` | `https://m365.cloud.microsoft/chat` | Where the pages open. |
| `SingleSignOn` | `1` | Sign in with the Windows account. Each mode keeps its own sign-in folder. |
| `Views` / `MaxViews` | `2` / `4` | Pages kept ready / most pages at once (each ~150-300 MB). |
| `SendWaitSec` | `15` | How long to wait for Copilot to register Send. |
| `AnswerTimeoutSec` | `180` | |
| `QueueWaitSec` | `45` | A request that can't start this soon is handed back (`busy`). |
| `SignInWaitSec` | `600` | How long a 💬 request waits for you to sign in. |
| `ConversationIdleMin` | `30` | A kept conversation is released after this long unused. |
| `RefreshIdleMin` | `30` | Idle pages reload now and then so the sign-in stays fresh. |
| `AllowedHosts` | `m365.cloud.microsoft, copilot.cloud.microsoft` | The worker only runs on these. |
| `PersonalDomains` | gmail.com, outlook.com, ... | Email domains counted as personal. |
| `AllowPersonal` | `0` | Testing switch (pool window checkbox). |
| `ChatW` / `ChatH` | `900` / `760` | Size of a 💬 window (remembered when you close one). |

**Page selectors:** defaults in the worker script; an optional `data\copilot-pool-selectors.json`
(e.g. `{"editor": ["..."], "message": ["..."]}`) overrides them, so a Copilot page change can be
fixed with a small data file instead of a release.

## Files

| File | Ships? | |
|---|---|---|
| `app\copilot-pool.ahk` | yes | The pool app. |
| `app\copilot-pool-worker.js` | yes | Runs in each Copilot page. |
| `app\copilot-pool-link.ahk` | yes | Companion side: start/stop, 💬, state. |
| `app\lib\` | yes | WebView2 library + Microsoft loader DLLs (see its README). |
| `%LOCALAPPDATA%\CaptionCompanion\copilot-pool-web\` | never | Sign-in data (Sign out deletes it). Never in a synced folder like OneDrive. |
| `data\copilot-pool.ini`, `data\copilot-pool.log` | never | Settings, log (no call text). |

## Next

1. **Work PC:** sign in with the work account (Conditional Access), check the account is read as work.
2. **➤ Ask / ⚡ auto-assist overhaul** (later, owner's call): likely kept conversations per call.
3. **Live helpers board** (below).
4. The extension's other features (Outlook buttons, WO checker), then retiring the extension.

## Auto helpers (built 2026-11-20, being tested - `app\auto-helpers.ahk`, prefix `Auto*`)

From the owner. Some helpers are marked **auto**. During a live call each one runs by itself, in
its own Copilot page, and you just watch the answers.

- **Choosing them:** right-click a helper button (or its 🤖 / 💬) > "Auto-run during calls" (a
  tick). Saved per person in `live-captions.ini` [AutoHelpers] `Ids=` (not in the shared helpers
  file). Auto helpers show **⟳** before their name.
- **Started by:** a new call record - the New call button or a 3CX ring (owner's choice), not
  when the Companion starts.
- **Shown in:** one **Live helpers** window (the pool's "board"), side by side up to
  `BoardColumns` (3), then one at a time with a tab button each. Each page has a header with the
  helper's name and its status (writing / answered at ...). Tray > Copilot assist > "Live helpers
  window", or right-click a helper > "Open the Live helpers window". It appears by itself (without
  taking focus) when a call starts.
- **Settings:** `[AutoHelpers]` `MinChars` (40), `QuietMs` (1200), `MinGapMs` (8000),
  `FollowUpPrompt` (`{{new}}` = the new customer text and changed verified info).
- **Their own pages:** auto helpers get **dedicated pages**, separate from the 💬 pages (4 regular
  + 2 auto helpers = 6 pages). They are opened ahead of time when the Companion starts (warm), so
  a call starts instantly.
- **Call starts** (a new live call record): each auto helper's page gets a fresh chat and its full
  prompt (helper instructions + reference context + caller info + transcript so far + verified
  info), like 🤖 builds today.
- **As the customer talks:** when the customer pauses, only the **new** customer text (and changed
  verified info / notes) is sent as a follow-up into the same chat. Same timing rules as ⚡ today
  (`MinChars`, `QuietMs`, `MinGapMs`), as settings. If Copilot is still writing, the new text waits
  and goes as **one** combined follow-up when it finishes (never a pile-up).
- **Watching:** the auto pages are shown in **one "Live helpers" window**, side by side (tabs
  when there are many), each page **auto-scrolling** to the newest answer. You can still type into
  any of them.
- **Call ends / next call:** the conversations end; the pages keep showing the last answers until
  the next call starts, then get a fresh chat.
- **Safety:** same as the pool: work account only, never sends twice, nothing in logs. Only while
  the pool is on, and only for **live** calls (not when reviewing an old call).
- **In the pool (generic):** `board {title, pages:[{key,label}]}` opens one dedicated page per key
  (closing the ones no longer wanted), `boardshow {activate}` shows the window, and an `ask` with
  `page: <key>` goes only to that page (`newChat` 1 = fresh chat + full prompt, 0 = follow-up in
  the same chat). If the page reloaded, a follow-up gets `lost` and the Companion sends everything
  again. Board pages auto-scroll (`scroll`), and a follow-up never overwrites what you're typing
  there (`respectDraft`: it comes back unsent and is tried again later).
- **Watch for:** memory (each page ~150-300 MB), Copilot's own usage limits with many helpers,
  very long calls outgrowing a chat (re-send a summary).
- ⚡ auto-assist and ➤ Ask stay as they are until this is proven; then they can be retired or folded in.

## Decisions (owner, 2026-11-20)

1. A dedicated **💬** button beside 🤖 for the pool; 🤖 stays exactly as before (paste).
2. **No answers window:** the Copilot page itself is shown as a window with the answer, and you
   can keep chatting. It returns to the pool when you close it.
3. ➤ Ask / ⚡ auto-assist: **not touched** for now.
4. **Work account only**; personal = gmail.com-style domains; a testing switch for home.
5. Workmates: **on by default** once proven.
