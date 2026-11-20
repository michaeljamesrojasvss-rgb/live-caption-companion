// copilot-pool-worker.js - runs inside each Copilot page of the Copilot pool (copilot-pool.ahk).
// Grown from automation-extension/bridge/worker.js and tools/dev/copilot-webview-worker.js.
//
// AHK puts   window.__lccPool = { id, url, hosts: [...], selectors: {...}, sendWaitMs }   in front of this script.
// To AHK (JSON strings):  hello | state | account | log | trusted | sent | chunk | result
// From AHK (JSON strings): job {jobId, prompt, newChat, keep, stream, preempt} | abort {jobId} | trusted-done | ping
//
// Rules: click Send ONCE and wait - Copilot takes 5-7 s to register it on a freshly loaded page. Only try
// another way if the prompt is still in the box. Never send a prompt twice.
// A job with "preempt" doesn't wait: the running job stops (Copilot's answer is stopped too), whatever
// is in the input box is cleared, and the new prompt goes right away. A Send already clicked is never
// interrupted: it is allowed to register first, so nothing is lost or sent twice.
(() => {
  if (window.top !== window || window.__lccWorker) return;
  const cfg = window.__lccPool || {};
  const hosts = cfg.hosts && cfg.hosts.length ? cfg.hosts : ["m365.cloud.microsoft", "copilot.cloud.microsoft"];
  if (!hosts.some(h => location.hostname === h || location.hostname.endsWith("." + h))) return;
  const wv = window.chrome && window.chrome.webview;
  if (!wv) return;
  window.__lccWorker = true;

  let state = "init", current = null, nextJob = null;
  const copilotUrl = location.origin + "/chat";
  const SEND_WAIT_MS = cfg.sendWaitMs || 15000;

  // ---------- selectors: defaults, overridable from data\copilot-pool-selectors.json ----------
  const DEFAULT_SEL = {
    editor: ['[data-lexical-editor="true"][contenteditable="true"]', 'span[role="textbox"][contenteditable="true"]'],
    question: ['[data-testid="chatQuestion"]'],
    message: ['[data-testid="copilot-message-div"]'],
    messageBusy: [".fai-CopilotMessage"],
    copyButton: ['[data-testid="CopyButtonTestId"]'],
    reply: ['[data-testid="markdown-reply"]'],
    inputBox: [".fai-BebopLiteChatInput"],
    attachments: [".fai-BebopLiteChatInput__attachments"],
    newChat: ['a[aria-label="New chat"]']
  };
  const SEL = Object.assign({}, DEFAULT_SEL);
  for (const [k, v] of Object.entries(cfg.selectors || {}))
    if (DEFAULT_SEL[k]) SEL[k] = Array.isArray(v) ? v : [String(v)];
  const q = (key, root = document) => { for (const s of SEL[key]) { try { const e = root.querySelector(s); if (e) return e; } catch {} } return null; };
  const qa = (key, root = document) => { for (const s of SEL[key]) { try { const l = root.querySelectorAll(s); if (l.length) return [...l]; } catch {} } return []; };

  const norm = s => (s || "").replace(/\s+/g, " ").trim();
  const send = m => { try { wv.postMessage(JSON.stringify(m)); } catch {} };
  const log = (m, d) => send({ t: "log", m, d: d === undefined ? undefined : String(d).slice(0, 300) });
  const setState = s => { state = s; send({ t: "state", state: s, path: location.hostname + location.pathname }); };

  // Resolves as soon as pred() is truthy; re-checks on every DOM mutation.
  function waitUntil(pred, timeout = 5000) {
    return new Promise(resolve => {
      let done = false, queued = false, tm = 0, iv = 0, mo = null;
      const fin = v => { if (done) return; done = true; mo.disconnect(); clearTimeout(tm); clearInterval(iv); resolve(v); };
      const check = () => { queued = false; if (done) return; let v = null; try { v = pred(); } catch {} if (v) fin(v); };
      mo = new MutationObserver(() => { if (!queued) { queued = true; queueMicrotask(check); } });
      mo.observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: true });
      tm = setTimeout(() => fin(null), timeout);
      iv = setInterval(check, 300);
      check();
    });
  }

  // ---------- trusted input from AHK (DevTools protocol, no focus needed) ----------
  let reqSeq = 0;
  const pending = new Map();
  function trusted(op, text) {
    return new Promise(resolve => {
      const reqId = ++reqSeq;
      const tm = setTimeout(() => { pending.delete(reqId); resolve(false); }, 4000);
      pending.set(reqId, ok => { clearTimeout(tm); resolve(ok); });
      send({ t: "trusted", reqId, op, text });
    });
  }

  // ---------- the page ----------
  const getEditor = () => q("editor");
  const editorText = () => { const e = getEditor(); return e ? norm(e.innerText) : ""; };
  const questionCount = () => qa("question").length;
  const isClean = () => !!getEditor() && questionCount() === 0 && editorText() === "";
  const btnLabel = b => (b.getAttribute("aria-label") || "") + " " + (b.getAttribute("data-testid") || "") + " " + (b.title || "");

  function inputButtons() {
    const known = q("inputBox");
    if (known) return [...known.querySelectorAll("button")];
    let n = getEditor();
    for (let i = 0; n && i < 8; i++, n = n.parentElement) {
      const bs = n.querySelectorAll("button");
      if (bs.length) return [...bs];
    }
    return [];
  }
  function findSendButton() {
    const isSend = b => /send|submit/i.test(btnLabel(b)) && !/dictat|stop|feedback/i.test(btnLabel(b));
    return inputButtons().find(isSend) || [...document.querySelectorAll("button")].find(isSend) || null;
  }
  // ---------- debug trace: step timings + what the page shows (counts and states only, never text) ----------
  let traceJob = "", traceT0 = 0;
  function snap() {
    try {
      const b = findSendButton(), a = answerState(), att = q("attachments");
      return "questions=" + questionCount() + " messages=" + qa("message").length + " box=" + editorText().length + "ch"
        + " send=" + (b ? (b.disabled ? "disabled" : "enabled") : "none") + " stop=" + (stopButton() ? "yes" : "no")
        + " answer=" + (a ? (a.busy ? "writing" : a.hasCopy ? "done" : "no-copy-btn") : "none")
        + (att && att.children.length ? " attachments=" + att.children.length : "")
        + " visible=" + document.visibilityState + " focus=" + (document.hasFocus() ? "yes" : "no")
        + " path=" + location.pathname + " state=" + state;
    } catch (e) { return "snapshot failed: " + e.message; }
  }
  // job steps: ms since the job arrived; page events: ms since the page loaded
  const tr = step => {
    const now = performance.now();
    send({ t: "trace", jobId: traceJob, ms: Math.round(traceJob ? now - traceT0 : now), step: traceJob ? step : "(page) " + step, snap: snap() });
  };

  const stopButton = () => [...document.querySelectorAll("button")].find(b => /\bstop\b/i.test(btnLabel(b)) && !/dictat/i.test(btnLabel(b))) || null;
  // Stops the answer Copilot is writing (if any)
  async function stopAnswer() {
    const b = stopButton();
    if (!b) return;
    tr("Copilot is still writing - clicking Stop");
    const t = performance.now();
    b.click();
    if (!(await waitUntil(() => !stopButton(), 5000))) { log("Stop didn't end Copilot's answer in 5 s"); tr("Stop did NOT end the answer in 5 s"); }
    else tr("answer stopped after " + Math.round(performance.now() - t) + " ms");
  }
  function pressEnter(el) {
    const init = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
    el.dispatchEvent(new KeyboardEvent("keydown", init));
    el.dispatchEvent(new KeyboardEvent("keypress", init));
    el.dispatchEvent(new KeyboardEvent("keyup", init));
  }

  // ---------- who is signed in ----------
  const EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;
  function findAccount() {
    for (const st of [localStorage, sessionStorage]) {
      try {
        for (let i = 0; i < st.length; i++) {
          const v = st.getItem(st.key(i));
          if (!v || v[0] !== "{" || v.length > 50000 || !/"(username|preferred_username)"\s*:/.test(v)) continue;
          let o; try { o = JSON.parse(v); } catch { continue; }
          const u = String(o.username || o.preferred_username || "");
          const m = u.match(EMAIL);
          if (m) return { email: m[0], tenant: String(o.realm || o.tenantId || o.tid || ""), how: "sign-in data" };
        }
      } catch {}
    }
    for (const e of document.querySelectorAll("[aria-label],[title]")) {
      const m = (e.getAttribute("aria-label") || e.getAttribute("title") || "").match(EMAIL);
      if (m) return { email: m[0], tenant: "", how: "page" };
    }
    return { email: "", tenant: "", how: "" };
  }
  let lastAccount = "";
  function reportAccount() {
    const a = findAccount();
    const key = a.email + "|" + a.tenant;
    if (key !== lastAccount) { lastAccount = key; send(Object.assign({ t: "account" }, a)); }
  }

  // ---------- reset to a fresh chat ----------
  async function resetChat() {
    if (isClean()) return true;
    const link = q("newChat") ||
      [...document.querySelectorAll("a,button")].find(a => /new chat/i.test(a.getAttribute("aria-label") || ""));
    tr(link ? "clicking New chat" : "no New chat link found");
    const t = performance.now();
    if (link) link.click();
    if (await waitUntil(isClean, link ? 4000 : 200)) { tr("new chat is clean after " + Math.round(performance.now() - t) + " ms"); return true; }
    log("New chat didn't clear the page - reloading", link ? "link clicked" : "no link");
    tr("New chat didn't clear the page - RELOADING the page");
    location.href = copilotUrl;
    return false; // the page reloads and this script starts over
  }
  async function resetAndReady() {
    setState("resetting");
    if (await resetChat()) { setState("ready"); reportAccount(); }
  }

  // ---------- type the prompt ----------
  const hasPrompt = text => {
    const have = editorText().length, want = norm(text).length;
    if (have >= Math.min(want, Math.max(1, want * 0.9))) return true;
    const att = q("attachments");
    return !!(att && att.children.length); // very long pastes can turn into an attachment chip
  };
  // Empties the input box, whatever is in it (your own typing, a prompt that was never sent)
  async function clearEditor(editor) {
    if (editorText() === "") return;
    tr("the input box has " + editorText().length + " chars in it - clearing");
    editor.focus(); document.execCommand("selectAll"); document.execCommand("delete");
    if (await waitUntil(() => editorText() === "", 1000)) { tr("box cleared"); return; }
    tr("script delete didn't clear it - trying trusted Backspace");
    editor.focus(); document.execCommand("selectAll");
    if (await trusted("backspace") && await waitUntil(() => editorText() === "", 1500)) { tr("box cleared (Backspace)"); return; }
    throw new Error("Couldn't clear Copilot's input box");
  }
  async function insertText(editor, text) {
    await clearEditor(editor);
    editor.focus();
    const sel = getSelection(); sel.removeAllRanges();
    const r = document.createRange(); r.selectNodeContents(editor); sel.addRange(r);
    const dt = new DataTransfer(); dt.setData("text/plain", text);
    editor.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
    if (await waitUntil(() => hasPrompt(text), 1500)) return "paste";
    log("paste didn't take - using insertText");
    editor.focus(); document.execCommand("selectAll"); document.execCommand("insertText", false, text);
    if (await waitUntil(() => hasPrompt(text), 1500)) return "insertText";
    log("insertText didn't take - using trusted typing");
    editor.focus(); document.execCommand("selectAll");
    if (await trusted("insert", text) && await waitUntil(() => hasPrompt(text), 3000)) return "trusted";
    throw new Error("Couldn't type the prompt into Copilot");
  }

  // ---------- send (once) ----------
  async function submit(editor, before, prompt) {
    const path0 = location.pathname;
    const sent = () => questionCount() > before || editorText() === "" || location.pathname !== path0 || !!stopButton();
    const tries = [
      ["button", async () => {
        const w = performance.now();
        const b = await waitUntil(() => { const x = findSendButton(); return x && !x.disabled ? x : null; }, 2000);
        if (!b) { tr("Send button not found / not enabled after " + Math.round(performance.now() - w) + " ms"); return false; }
        tr("Send button enabled (waited " + Math.round(performance.now() - w) + " ms) - clicking it");
        b.click(); return true;
      }],
      ["trusted-enter", async () => { tr("pressing Enter (trusted)"); editor.focus(); return trusted("enter"); }],
      ["enter", async () => { tr("pressing Enter (script)"); editor.focus(); pressEnter(editor); return true; }]
    ];
    for (const [how, run] of tries) {
      if (sent()) return how + " (late)";
      if (!hasPrompt(prompt)) throw new Error("The prompt left the box without being sent");
      if (!(await run())) continue;
      const t = performance.now();
      const iv = setInterval(() => tr("still waiting for Copilot to take the message (" + how + ", " + Math.round(performance.now() - t) + " ms)"), 2000);
      const ok = await waitUntil(sent, SEND_WAIT_MS);
      clearInterval(iv);
      if (ok) { log("sent by " + how + " after " + Math.round(performance.now() - t) + " ms"); tr("Copilot took the message (" + how + ") after " + Math.round(performance.now() - t) + " ms"); return how; }
      log("send: " + how + " didn't register in " + SEND_WAIT_MS / 1000 + " s");
      tr("send by " + how + " did NOT register in " + SEND_WAIT_MS / 1000 + " s");
    }
    throw new Error("Couldn't send the message");
  }

  // ---------- read the answer ----------
  function answerState() {
    const msgs = qa("message");
    const last = msgs[msgs.length - 1];
    if (!last) return null;
    const art = q("messageBusy", last);
    return { last, busy: art ? art.getAttribute("aria-busy") === "true" : true, hasCopy: !!q("copyButton", last) };
  }
  const answerNodes = last => qa("reply", last);
  const answerText = last => answerNodes(last).map(n => n.innerText.trim()).filter(Boolean).join("\n\n");

  function toMd(root) {
    const walk = n => {
      if (n.nodeType === 3) return n.nodeValue.replace(/\s+/g, " ");
      if (n.nodeType !== 1) return "";
      const tag = n.tagName.toLowerCase();
      const kids = () => [...n.childNodes].map(walk).join("");
      if ((tag === "input" && (n.getAttribute("type") || "").toLowerCase() === "checkbox") || n.getAttribute("role") === "checkbox")
        return n.checked || n.getAttribute("aria-checked") === "true" ? "[x] " : "[ ] ";
      switch (tag) {
        case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "\n\n" + "#".repeat(+tag[1]) + " " + kids().trim() + "\n\n";
        case "p": return "\n\n" + kids().trim() + "\n\n";
        case "br": return "\n";
        case "strong": case "b": return "**" + kids().trim() + "**";
        case "em": case "i": return "*" + kids().trim() + "*";
        case "code": return n.parentElement && n.parentElement.tagName === "PRE" ? n.textContent : "`" + n.textContent + "`";
        case "pre": return "\n\n```\n" + n.textContent.replace(/\n$/, "") + "\n```\n\n";
        case "a": { const t = kids().trim(), h = n.getAttribute("href"); return h && /^https?:/i.test(h) ? `[${t}](${h})` : t; }
        case "ul": case "ol": {
          let i = 0;
          const items = [...n.children].filter(c => c.tagName === "LI").map(li => {
            i++; const body = walk(li).trim().replace(/\n/g, "\n  ");
            return (tag === "ol" ? i + ". " : "- ") + body;
          });
          return "\n\n" + items.join("\n") + "\n\n";
        }
        case "table": {
          const rows = [...n.querySelectorAll("tr")].map(tr => [...tr.children].map(c => c.textContent.trim().replace(/\s+/g, " ").replace(/\|/g, "\\|")));
          if (!rows.length) return "";
          const head = rows[0];
          return "\n\n" + ["| " + head.join(" | ") + " |", "| " + head.map(() => "---").join(" | ") + " |", ...rows.slice(1).map(r => "| " + r.join(" | ") + " |")].join("\n") + "\n\n";
        }
        case "blockquote": return "\n\n" + kids().trim().split("\n").map(l => "> " + l).join("\n") + "\n\n";
        case "hr": return "\n\n---\n\n";
        case "style": case "script": case "button": case "svg": return "";
        default: return kids();
      }
    };
    return walk(root).replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  // Keeps the newest answer in view (board pages)
  let lastScroll = 0;
  function scrollToNewest(force) {
    const now = performance.now();
    if (!force && now - lastScroll < 700) return;
    lastScroll = now;
    const msgs = qa("message"), last = msgs[msgs.length - 1];
    try { if (last) last.scrollIntoView({ block: "end" }); } catch {}
  }

  async function waitForAnswer(job, msgsBefore) {
    let lastSent = "", lastAt = 0, started = false, words = false;
    const t = performance.now();
    const iv = setInterval(() => tr("waiting for the answer (" + Math.round(performance.now() - t) + " ms so far)"), 5000);
    const check = () => {
      if (job.aborted) return "ABORT";
      if (qa("message").length <= msgsBefore) return null;     // the new answer hasn't started yet
      if (!started) { started = true; tr("answer bubble appeared " + Math.round(performance.now() - t) + " ms after sending"); }
      if (job.scroll) scrollToNewest(false);
      const a = answerState();
      if (!a) return null;
      if (!words && answerText(a.last)) { words = true; tr("first words of the answer " + Math.round(performance.now() - t) + " ms after sending"); }
      if (job.stream && a.busy) {
        const now = performance.now();
        if (now - lastAt > 400) {
          const t = answerText(a.last);
          if (t && t !== lastSent) { lastSent = t; lastAt = now; send({ t: "chunk", jobId: job.id, text: t }); }
        }
      }
      return !a.busy && a.hasCopy && answerText(a.last) ? a : null;
    };
    const a = await waitUntil(check, job.timeoutMs);
    clearInterval(iv);
    if (job.aborted || a === "ABORT") throw new Error("aborted");
    if (!a) throw new Error("No answer from Copilot in time");
    tr("answer finished " + Math.round(performance.now() - t) + " ms after sending (" + answerText(a.last).length + " chars)");
    if (job.scroll) { scrollToNewest(true); setTimeout(() => scrollToNewest(true), 600); }
    const nodes = answerNodes(a.last);
    return { text: answerText(a.last), markdown: nodes.map(toMd).filter(Boolean).join("\n\n") };
  }

  // ---------- one job ----------
  async function runJob(m) {
    const job = { id: m.jobId, stream: !!m.stream, scroll: !!m.scroll, aborted: false, sent: false, timeoutMs: m.timeoutMs || 180000 };
    const stopIfAborted = () => { if (job.aborted) throw new Error("aborted"); };
    const t0 = performance.now();
    traceJob = job.id; traceT0 = t0;
    tr("job received: " + (m.prompt || "").length + " chars" + (m.newChat ? ", new chat" : ", follow-up")
      + (m.keep ? ", keep chat" : "") + (m.preempt ? ", replacing the previous job" : ""));
    current = job;
    setState("busy");
    let sentBy = "";
    try {
      await stopAnswer();                     // still writing an earlier answer: stop it, this prompt goes now
      stopIfAborted();
      if (m.newChat && !isClean()) { if (!(await resetChat())) { send({ t: "result", jobId: job.id, ok: false, sent: false, error: "the page had to reload" }); return; } }
      const we = performance.now();
      const editor = await waitUntil(getEditor, 8000);
      if (!editor) throw new Error("Copilot's input box wasn't found (signed out?)");
      tr("input box found (waited " + Math.round(performance.now() - we) + " ms)");
      stopIfAborted();
      const before = questionCount(), msgsBefore = qa("message").length;
      const ti = performance.now();
      const how = await insertText(editor, m.prompt);
      tr("prompt is in the box (by " + how + ", " + Math.round(performance.now() - ti) + " ms)");
      stopIfAborted();                        // replaced before Send: the newer prompt overwrites the box
      sentBy = await submit(editor, before, m.prompt);   // never interrupted once Send is clicked
      job.sent = true;
      send({ t: "sent", jobId: job.id });
      const res = await waitForAnswer(job, msgsBefore);
      send({ t: "result", jobId: job.id, ok: true, sent: true, text: res.text, markdown: res.markdown,
        how: how + ", sent by " + sentBy, ms: Math.round(performance.now() - t0) });
    } catch (e) {
      tr((job.aborted ? "job stopped: a newer prompt replaced it / it was cancelled" : "job FAILED: " + ((e && e.message) || String(e)))
        + (job.sent ? " (it had been sent)" : " (it was never sent)"));
      if (job.aborted) { if (job.sent) await stopAnswer(); }
      else send({ t: "result", jobId: job.id, ok: false, sent: !!sentBy, error: (e && e.message) || String(e), ms: Math.round(performance.now() - t0) });
    } finally {
      current = null;
      tr("job over after " + Math.round(performance.now() - t0) + " ms" + (nextJob ? " - the newer prompt starts now" : m.keep ? " - chat kept" : " - resetting to a new chat"));
      traceJob = "";
      if (nextJob) { const n = nextJob; nextJob = null; runJob(n); }   // a newer prompt is waiting: no reset in between
      else if (m.keep) setState("ready");     // a kept conversation stays as it is
      else await resetAndReady();
    }
  }

  // ---------- messages from AHK ----------
  wv.addEventListener("message", e => {
    let m = e.data;
    if (typeof m === "string") { try { m = JSON.parse(m); } catch { return; } }
    if (!m) return;
    if (m.t === "job") {
      if (!current) runJob(m);
      else if (m.preempt) {                   // the newest prompt wins: the running job stops, this one goes next
        tr("a NEWER prompt (" + m.jobId + ") arrived - stopping this job" + (current.sent ? " (already sent: its answer gets stopped)" : " (not sent yet)"));
        if (nextJob) send({ t: "result", jobId: nextJob.jobId, ok: false, sent: false, error: "replaced by a newer prompt" });
        nextJob = m;
        current.aborted = true;
      }
      else send({ t: "result", jobId: m.jobId, ok: false, sent: false, error: "view busy" });
    }
    else if (m.t === "abort") {
      if (current && current.id === m.jobId) current.aborted = true;
      else if (nextJob && nextJob.jobId === m.jobId) nextJob = null;
    }
    else if (m.t === "trusted-done") { const f = pending.get(m.reqId); if (f) { pending.delete(m.reqId); f(!!m.ok); } }
    else if (m.t === "newchat") { if (!current) resetAndReady(); }
    else if (m.t === "ping") { send({ t: "state", state, path: location.hostname + location.pathname }); reportAccount(); }
  });

  async function start() {
    send({ t: "hello", path: location.hostname + location.pathname });
    tr("page script started (" + document.readyState + ")");
    setState("waiting-for-input-box");
    if (!(await waitUntil(getEditor, 10 * 60 * 1000))) {
      tr("no input box after 10 minutes (signed out?)");
      setState("no-input-box");
      return;
    }
    tr("input box appeared");
    // The input box shows up before the page has finished loading: wait for "complete", then let it settle.
    setState("page-finishing");
    if (document.readyState !== "complete")
      await new Promise(r => window.addEventListener("load", r, { once: true }));
    tr("page load complete - settling 1.5 s");
    await new Promise(r => setTimeout(r, 1500));
    await resetAndReady();
    tr("page ready for prompts");
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
