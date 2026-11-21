# Agent - design

Status 2026-11-21: **increment 1 released** (owner's choice: shipped for everyone, OFF by default in
installed copies, ON in dev mode; first real tests still to come).
From the owner's task list: "start with pool can request action" (this) and "AI agent doing the work,
start with its own separate browser" (increment 3).

## What it is

The chat AIs we drive (M365 Copilot, Google AI Mode) can only write text: they have no tools. The agent
gives them tools the way Claude Code does, with a **loop around the Copilot pool**:

```
  you: a goal ─► Agent (own app)  ──prompt──►  Copilot pool (kept conversation "agent")
                   ▲                                   │ answer text
                   │                                   ▼
             tool result  ◄── run the tool ◄── read ONE JSON object from the answer:
             (+ images)       (after your OK         {"tool": ..., "args": {...}, "why": ...}
                   │           if it asks)           {"final": "..."}
                   └── repeat until "final", the step limit, the time limit, or you press Stop
```

The pool is **not changed**: the agent is one more app that sends text and gets text back (like Screen ask).

## Where this is heading (owner, 2026-11-21)

Later the agent will drive **Salesforce / ServiceChannel** and the **PC itself** (screenshots, clicks,
typing). That shapes increment 1:
- Tool results can carry **images** (the pool already attaches images): `take_screenshot` proves it.
- Every tool says if it **asks first**: acting on real systems will always need your OK.
- Text from tools is treated as **data, not instructions** (a web page or an email could try to steer the
  AI - "prompt injection"). The instructions tell the AI so, and approvals are the real safety net.
- The rules in `COPILOT-POOL.md` > "Rules for any site we host or automate" apply to the agent's own
  browser (increment 3): ask IT first for Salesforce, own profile, narrow message channel.

## Rules (same spirit as Tasks, the pool and Screen ask)

1. **Its own app and process** (`app\agent.ahk`, prefix `Agt*`). Generic: no call, caption or customer words.
2. **Off by default** for workmates: tray > Agent > On (`live-captions.ini` [Agent] Enabled, per person;
   on by default in dev mode). "Open the agent" works while it's off too. Nothing runs while it's off.
3. **Tools are data + a handler.** A tool is described in **MCP shape** (`name`, `title`, `description`,
   `inputSchema` = JSON Schema) in `app\agent\tools\*.json`; the AHK code is a function `AgtT_<handler>`.
   Real MCP servers (JSON-RPC over stdio) can later supply tools of the same shape (increment 4).
4. **Approvals on** (window checkbox "Allow everything (dangerous)" skips them all: off at every start, never saved, confirmed when turned on). Each tool has `approval`: `auto` (runs by itself, read-only and harmless) or `ask`
   (you click Allow / Allow for this task / Deny). Your own choice per tool overrides it:
   `data\agent.ini` [Approval] `<tool>=auto|ask|off` (`off` = the AI can't use it).
5. **One tool per reply**, a step limit (`MaxSteps`), a time limit (`RunMaxMin`), and **Stop** at any time.
6. **Never sent twice:** a step that may have reached the AI (`failed` / `timeout` / `cancelled`) ends the
   task; only steps that never got in (`unsent`, pool starting, sign-in, you typing in its box) are retried.
7. **Logs hold no content:** `data\agent.log` and the debug trace have states, tool names, counts and
   times - never the goal, answers or tool results. The transcript lives only in the window
   (**Copy transcript** puts it on the clipboard).
8. **Nothing hard-coded:** the messages to the AI are templates in `app\agent\instructions.md`
   (a `data\agent\instructions.md` overrides sections of it), tools are JSON, limits are settings.
9. **Memory:** the agent has no browser of its own yet. It talks to the pool through a small hidden
   window that it closes ~2 min after a task ends, so the pool can still close itself when nothing uses it.

## The protocol (`agent-protocol.ahk`, `AgtProto*`)

- The first message (`=== start ===`) explains the reply format, lists the tools (name, description,
  argument schema, "asks first") and gives your goal.
- The AI must reply with **one JSON object**. The parser finds it anywhere in the answer (a code block,
  prose around it, curly quotes), because Copilot's answer comes as formatted text and Google's as plain
  page text. If there are several, the first one counts (the AI is told).
- No valid object = a `format-error` message with the rule again, at most `MaxFormatRetries` times in a row.
- After a tool: `result` (or `tool-error`, `denied`) with the result text (cut to `ResultMaxChars`) and its
  images attached.
- The AI's chat is the pool's **"agent" window** (`ShowChat`, opens without taking the focus): you can
  watch it. Closing it during a task ends the task (the AI's memory of it is gone).

### When Copilot won't play along (2026-11-21)
- **Refusals**: M365 Copilot's safety filter sometimes answers a tool result (seen with web-page text) with a
  canned "I can't help with that." and then repeats the same canned text in that chat. A reply with no JSON
  that looks like a refusal (or the same bad reply twice) = `AgtRecover`: a **fresh chat** with the task +
  `resume` (one line per step so far, results cut to 300 chars), at most 2 times per task.
- **Plain sentences** (no JSON, e.g. while talking by voice): one `format-error` reminder; plain text again
  = taken as the final answer.
- Results are wrapped in `----- start of data ----- / ----- end of data -----`; the browser tools send a
  short on-screen-only snapshot after each action (full list only from `browser_snapshot`).

## Increment 1 tools (`app\agent\tools\core.json`)

| Tool | Approval | What it does |
|---|---|---|
| `get_time` | auto | Local date, time and UTC offset |
| `list_folder` | auto | Files and folders in an allowed folder (`AllowedFolders`) |
| `read_text_file` | auto | A text file in an allowed folder (up to `ReadMaxKB`) |
| `read_clipboard` | ask | The text on the clipboard |
| `take_screenshot` | ask | All monitors or one, as an image for the AI |
| `show_message` | ask | Shows you a message (proves the approval flow for actions) |

Allowed folders default to `data\agent-workspace` (created at start). Add more in `data\agent.ini`
`AllowedFolders` (separate with `|`, `%USERPROFILE%`-style variables work). Paths outside them are refused,
`..` tricks included.

## Voice tools (`app\agent\tools\voice.json`, handlers in `app\agent-voice.ahk`) - prototype

| Tool | Approval | What it does |
|---|---|---|
| `speak` | auto | Says `text` out loud (Windows voice, SAPI). Stop cuts it off. |
| `listen` | ask | Says `question` first (optional), then listens on the default mic and returns what you said as text |

`listen` runs `app\agent\listen.ps1` in a hidden PowerShell: Windows' own offline speech recognizer
(System.Speech dictation, English), so nothing leaves the PC. It ends after ~2.5 s of silence once you've
spoken (8 s if you never start), when you press **Done** in the small "Agent is listening" window, at
`maxSeconds` (default 30, max 120), or on Stop. The words are only in a temp file while it listens, deleted after.
Typing in the window's lower box stops listening and sends the typed (exact) answer instead; if it hears
nothing, the window stays up for typing. Accuracy is that of old Windows dictation: fine for short answers, not names/IDs. A better engine (Live
Captions with mic audio, or Windows.Media speech) can replace listen.ps1 later without changing the tool.

## Browser tools (`app\agent\tools\browser.json`, `app\agent-browser.ahk`, pool side `app\copilot-pool-browser.ahk`) - prototype

The agent "summons" its own **tab in the Copilot pool** (owner's choice 2026-11-21: a pool tab, so it shares
the pool's browser engine and **sign-in** - work sites with single sign-on open signed in). It is NOT a
Copilot page: never in the pool's page list, no worker script, can't message the pool. It shows as its own
window ("Agent browser - <title>") so you watch it work and can use it yourself; it remembers its place.
https only; links that open a new window open in the same tab; script dialogs off.

| Tool | Approval | What it does |
|---|---|---|
| `browser_open` | auto | Opens/brings up the tab, optionally at `url` |
| `browser_navigate` | auto | Loads `url` |
| `browser_snapshot` | auto | Title, address, scroll, numbered list of usable elements (`[ref] kind "label"` + value/checked/disabled/off-screen), page text |
| `browser_screenshot` | auto | Image of the visible part; 1 image px = 1 page px, so x/y can be clicked |
| `browser_click` | ask | `ref` or `x,y`; `button` left/right/middle; `double` |
| `browser_drag` | ask | Left-button drag from `from` (ref) or `fromX,fromY` to `to` or `toX,toY`: real mouse drag in steps; items marked `draggable` get HTML5 drag-and-drop events instead (protocol mouse input does not start those) |
| `browser_hover` | auto | Mouse over `ref` or `x,y` |
| `browser_type` | ask | Clicks `ref` (optional), replaces (or `clear:false` adds) `text`, `submit` = Enter |
| `browser_key` | ask | Enter, Tab, Escape, arrows, Ctrl+A, ... |
| `browser_select` | ask | Picks an option of a `select` by text/value |
| `browser_scroll` | auto | down/up/left/right by `amount` px, the page or inside `ref` |
| `browser_back` | auto | Back (or `direction: forward`) |
| `browser_close` | auto | Closes the tab |

Every action returns a fresh snapshot, so the AI sees what changed without an extra step. Refs are
`data-agt-ref` attributes set by the latest snapshot. Input is real (DevTools protocol `Input.*`, in-process,
no debugging port), so right-click menus, hover menus and React/Lightning fields react as for a person.
Limits now: elements inside frames aren't listed (screenshot + x/y works), shadow DOM isn't searched, one
tab. Browsing uses many steps: raise `MaxSteps` in `data\agent.ini` for longer jobs.
Pool message: `{t:"tab", id, hwnd, owner, tab, op, args}` -> `{t:"tab-done", id, ok, text, image, error}`;
the tab closes when its owner window (the agent) is gone.

## Settings (`data\agent.ini` [Settings], "Settings file" button)

| Key | Default | |
|---|---|---|
| `Hotkey` | `^+!g` | Ctrl+Shift+Alt+G opens the agent window |
| `Conversation` | `agent` | The pool's name for the agent's chat (its window remembers its place) |
| `ShowChat` | `1` | Show the AI's chat window while it works |
| `MaxSteps` | `15` | Most tool calls per task |
| `MaxFormatRetries` | `2` | Badly formatted replies in a row before the task stops |
| `ResultMaxChars` | `6000` | A tool result is cut to this before it goes to the AI |
| `RunMaxMin` | `20` | A task stops after this long |
| `SendRetrySec` | `120` | How long a step that couldn't reach the AI yet is retried |
| `AllowedFolders` | `<data>\agent-workspace` | Folders the file tools may read |
| `ReadMaxKB` | `256` | Biggest file `read_text_file` reads |
| `ScreenshotMaxSide` | `2560` | Screenshots are made smaller than this (0 = never) |

## Files

| File | Ships? | |
|---|---|---|
| `app\agent.ahk` | yes | The app: window, loop, approvals |
| `app\agent-protocol.ahk` | yes | Templates, tool list text, reply parser |
| `app\agent-tools.ahk` | yes | Tool registry (loads JSON, checks arguments) + built-in handlers |
| `app\agent-voice.ahk`, `app\agent\listen.ps1` | yes | Voice tools (speak, listen) |
| `app\agent-browser.ahk` | yes | Browser tools: sends each step to the pool's tab and waits |
| `app\copilot-pool-browser.ahk` | yes | Pool side: the tab window, snapshot, real input, screenshot |
| `app\agent\instructions.md` | yes | The messages to the AI (sections `=== name ===`) |
| `app\agent\tools\*.json` | yes | Tool descriptions, one file per group |
| `app\screen-grab.ahk` | yes | Screen capture to PNG (GDI+), for `take_screenshot` |
| `app\agent-link.ahk` | yes | Companion side: tray item (off by default, on in dev mode), starts/stops the agent |
| `data\agent.ini`, `data\agent.log` | never | Settings, log (no content) |

## Increments

1. **Loop + protocol + 6 harmless tools + approvals** (this). Proves the AIs follow the protocol.
2. Real tools: writing files in the workspace, running saved actions, Tasks link; tool picker in the window.
3. **The agent's own browser** - prototype done as a pool tab sharing the pool's sign-in (owner's choice,
   2026-11-21; see Browser tools). Next: frames, several tabs, the tab in the memory audit.
4. **Real MCP servers** (stdio JSON-RPC client), their tools listed next to the built-in ones.
5. PC control (click/type in apps) and Salesforce / ServiceChannel - after IT says yes.

Later clean-up: Screen ask has its own copy of the capture code (`SaGrab`); it can move to `screen-grab.ahk`.
