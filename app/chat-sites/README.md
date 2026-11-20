# Chat sites for the Copilot pool

Each `.json` file here is one chat site the pool can drive (`copilot-pool.ahk` + `copilot-pool-worker.js`).
To add a site (Claude, Gemini, ...), add a file - no code changes, unless it needs a new kind of
`newChat` / `answer` behaviour. The pool uses `[Settings] Site=<id>` from `data\copilot-pool.ini`
(default `copilot`); in dev mode the pool window has a "Chat site" list.

A file with the same `id` in `data\chat-sites\` overrides fields of the one here (its `selectors`
are merged key by key) - handy to fix a selector on one PC without an update.

| Field | Meaning |
|---|---|
| `id`, `name`, `about` | id (= file name), name shown in windows, one-line description |
| `devOnly` | `true` = only in dev mode (a git working copy, not installed by Setup). Never loads in an installed copy. |
| `address` | the page the pool loads (https only) |
| `hosts` | sites the pages may talk to the pool from (a host or any sub-domain of it) |
| `signInHosts` | regex: a page on one of these hosts = needs sign-in |
| `signOutUrl`, `personalSignOutUrl` | shown by "Sign out" before the pool forgets the sign-in ("" = just forget it) |
| `account` | `work` = Microsoft work account only (personal refused, see PersonalDomains); `none` = no account check (dev-only sites only) |
| `warmUp` | send a short message once per freshly loaded page (Copilot is slow on a page's first message) |
| `newChat` | `link` = click the New chat link (`selectors.newChat`); `navigate` = load `address` again |
| `answer` | `copy-button` = done when the last `message` is not busy and has a `copyButton`; `settle` = done when the text after the prompt stops changing for `settleMs` |
| `settleMs`, `minAnswerMs` | settle: how long the answer must stay unchanged; the soonest an answer may count as done (skips "thinking..." placeholders) |
| `stopByLabel` | `false` = the page has other buttons labelled "stop", so only `selectors.stop` counts as the Stop-writing button |
| `selectors` | CSS selector lists, first match wins: `editor` (input box), `question`, `message`, `messageBusy`, `copyButton`, `reply`, `inputBox`, `attachments`, `newChat`, `answerArea` (settle: where the answer appears), `stop` (the Stop-writing button) |
