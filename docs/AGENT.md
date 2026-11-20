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
4. **Approvals on.** Each tool has `approval`: `auto` (runs by itself, read-only and harmless) or `ask`
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
| `app\agent\instructions.md` | yes | The messages to the AI (sections `=== name ===`) |
| `app\agent\tools\*.json` | yes | Tool descriptions, one file per group |
| `app\screen-grab.ahk` | yes | Screen capture to PNG (GDI+), for `take_screenshot` |
| `app\agent-link.ahk` | yes | Companion side: tray item (off by default, on in dev mode), starts/stops the agent |
| `data\agent.ini`, `data\agent.log` | never | Settings, log (no content) |

## Increments

1. **Loop + protocol + 6 harmless tools + approvals** (this). Proves the AIs follow the protocol.
2. Real tools: writing files in the workspace, running saved actions, Tasks link; tool picker in the window.
3. **The agent's own browser**: its own WebView2 window and profile (never Copilot's sign-in), tools
   `browser_open / read / click / type`, memory guard (`webview-guard.ahk`).
4. **Real MCP servers** (stdio JSON-RPC client), their tools listed next to the built-in ones.
5. PC control (click/type in apps) and Salesforce / ServiceChannel - after IT says yes.

Later clean-up: Screen ask has its own copy of the capture code (`SaGrab`); it can move to `screen-grab.ahk`.
