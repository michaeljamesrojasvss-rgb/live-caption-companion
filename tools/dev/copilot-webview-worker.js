// copilot-webview-worker.js - runs inside a Copilot page hosted in an AHK WebView2.
// Port of automation-extension/bridge/worker.js: same Copilot page logic, but it talks to AHK
// through window.chrome.webview instead of chrome.runtime.
//
// AHK puts   window.__lccPool = { id: <view number>, url: "<copilot address>" }   in front of this script.
// Messages TO AHK (JSON strings):   hello | state | log | result
// Messages FROM AHK (JSON strings): {t:"job", jobId, prompt} | {t:"abort", jobId} | {t:"ping"}
(() => {
  if (window.top !== window || window.__lccWorker) return;
  if (!/(^|\.)(copilot\.cloud\.microsoft|m365\.cloud\.microsoft)$/i.test(location.hostname)) return;
  const wv = window.chrome && window.chrome.webview;
  if (!wv) return;
  window.__lccWorker = true;

  const cfg = window.__lccPool || {};
  let state = "init", current = null;
  const copilotUrl = location.origin + "/chat";   // reload where we ARE (work: m365..., personal: copilot.cloud...)

  const norm = s => (s || "").replace(/\s+/g, " ").trim();
  const send = m => { try { wv.postMessage(JSON.stringify(m)); } catch {} };

  // Ask AHK to do a "real" (trusted) input through the DevTools protocol: works without window focus.
  // op: "insert" (type text into the focused element) | "enter" (press Enter)
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
  const log = (m, d) => send({ t: "log", m, d: d === undefined ? undefined : String(d).slice(0, 300) });
  const setState = s => { state = s; send({ t: "state", state: s, vis: document.visibilityState }); };

  // Resolves as soon as pred() is truthy; re-checks on every DOM mutation (works when timers are throttled).
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

  // ---------- selectors (same as the extension) ----------
  const getEditor = () =>
    document.querySelector('[data-lexical-editor="true"][contenteditable="true"]') ||
    document.querySelector('span[role="textbox"][contenteditable="true"]');
  const editorText = () => { const e = getEditor(); return e ? norm(e.innerText) : ""; };
  const questionCount = () => document.querySelectorAll('[data-testid="chatQuestion"]').length;
  const isClean = () => !!getEditor() && questionCount() === 0 && editorText() === "";

  const btnLabel = b => (b.getAttribute("aria-label") || "") + " " + (b.getAttribute("data-testid") || "") + " " + (b.title || "");
  // The buttons that belong to the input box: the ones in the nearest ancestor of the editor that has buttons.
  function inputButtons() {
    const known = document.querySelector(".fai-BebopLiteChatInput");
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
  // Does the page draw frames? (A hidden window may not, which stalls updates that wait for the next frame.)
  const frameCheck = () => new Promise(resolve => {
    const t = performance.now();
    const tm = setTimeout(() => resolve("NO frame in 1 s"), 1000);
    requestAnimationFrame(() => { clearTimeout(tm); resolve("yes (" + Math.round(performance.now() - t) + " ms)"); });
  });
  // What the page looks like right now (only UI labels - the only text typed is the test prompt).
  async function diag(where) {
    const bs = inputButtons().slice(0, 12).map(b => (norm(btnLabel(b)) || "(no label)") + (b.disabled ? " [disabled]" : ""));
    const yn = b => (b ? "yes" : "no");
    const frames = await frameCheck();
    // Who is signed in? Labels/titles that look like an account (to learn how to tell work from personal).
    const account = [...document.querySelectorAll("[aria-label],[title]")]
      .map(e => norm(e.getAttribute("aria-label") || e.getAttribute("title")))
      .filter(l => /@|account manager|signed in|profile/i.test(l) && l.length < 160)
      .filter((l, i, a) => a.indexOf(l) === i).slice(0, 4).join(" ; ") || "(not found)";
    send({ t: "diag", where, info: {
      account,
      drawsFrames: frames,
      readyState: document.readyState, hasFocus: yn(document.hasFocus()), vis: document.visibilityState,
      editor: yn(getEditor()), editorFocused: yn(getEditor() && document.activeElement === getEditor()),
      editorChars: editorText().length, knownInputBox: yn(document.querySelector(".fai-BebopLiteChatInput")),
      questions: questionCount(), answers: document.querySelectorAll('[data-testid="copilot-message-div"]').length,
      sendButton: findSendButton() ? norm(btnLabel(findSendButton())) : "(not found)",
      inputButtons: bs.join(" ; "), url: location.hostname + location.pathname
    } });
  }
  function pressEnter(el) {
    const init = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
    el.dispatchEvent(new KeyboardEvent("keydown", init));
    el.dispatchEvent(new KeyboardEvent("keypress", init));
    el.dispatchEvent(new KeyboardEvent("keyup", init));
  }

  // ---------- reset to a fresh chat ----------
  async function resetChat() {
    if (isClean()) return true;
    const link = document.querySelector('a[aria-label="New chat"]') ||
      [...document.querySelectorAll("a")].find(a => /new chat/i.test(a.getAttribute("aria-label") || ""));
    if (link) link.click();
    if (await waitUntil(isClean, link ? 4000 : 200)) return true;
    log("New chat didn't clear the page - reloading", link ? "link clicked" : "no link");
    location.href = copilotUrl;
    return false; // the page reloads and this script starts over
  }
  async function resetAndReady() {
    setState("resetting");
    if (await resetChat()) {
      setState("ready");
      send({ t: "log", m: "draws frames: " + (await frameCheck()) });
    }
  }

  // ---------- put the prompt in the box ----------
  const hasPrompt = text => {
    const have = editorText().length, want = norm(text).length;
    if (have >= Math.min(want, Math.max(1, want * 0.9))) return true;
    const att = document.querySelector(".fai-BebopLiteChatInput__attachments");
    return !!(att && att.children.length); // very long pastes can turn into an attachment chip
  };
  async function insertText(editor, text) {
    editor.focus();
    const sel = getSelection(); sel.removeAllRanges();
    const r = document.createRange(); r.selectNodeContents(editor); sel.addRange(r);
    const dt = new DataTransfer(); dt.setData("text/plain", text);
    editor.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
    if (await waitUntil(() => hasPrompt(text), 800)) return "paste";
    log("paste didn't take - using insertText");
    editor.focus(); document.execCommand("selectAll"); document.execCommand("insertText", false, text);
    if (await waitUntil(() => hasPrompt(text), 800)) return "insertText";
    log("insertText didn't take - using trusted typing from AHK");
    editor.focus(); document.execCommand("selectAll");
    if (await trusted("insert", text) && await waitUntil(() => hasPrompt(text), 1500)) return "trusted";
    diag("typing failed");
    throw new Error("Couldn't type the prompt into Copilot");
  }
  // Tries, in order: the Send button, a trusted Enter from AHK, a plain (synthetic) Enter. Returns what worked.
  // Copilot can take several seconds to show the question (longer in a hidden view), so each try waits
  // patiently, and the next one only runs if the prompt is STILL in the box - never send twice.
  const SEND_WAIT_MS = 15000;
  async function submit(editor, before, prompt) {
    const path0 = location.pathname;
    const isStop = () => [...document.querySelectorAll("button")].some(b => /\bstop\b/i.test(btnLabel(b)));
    const sent = () => questionCount() > before || editorText() === "" || location.pathname !== path0 || isStop();
    const tries = [
      ["button", async () => { const b = await waitUntil(() => { const x = findSendButton(); return x && !x.disabled ? x : null; }, 1500); if (!b) return false; b.click(); return true; }],
      ["trusted-enter", async () => { editor.focus(); return trusted("enter"); }],
      ["enter", async () => { editor.focus(); pressEnter(editor); return true; }]
    ];
    for (const [how, run] of tries) {
      if (sent()) return how + " (late)";
      if (!hasPrompt(prompt)) { diag("prompt left the box but nothing was sent"); throw new Error("The prompt disappeared without being sent"); }
      if (!(await run())) { log("send: " + how + " not available"); continue; }
      const t = performance.now();
      if (await waitUntil(sent, SEND_WAIT_MS)) { log("send: " + how + " registered after " + Math.round(performance.now() - t) + " ms"); return how; }
      log("send: " + how + " didn't register in " + SEND_WAIT_MS / 1000 + " s");
    }
    diag("send failed");
    throw new Error("Couldn't send the message");
  }

  // ---------- read the answer ----------
  function answerState() {
    const msgs = document.querySelectorAll('[data-testid="copilot-message-div"]');
    const last = msgs[msgs.length - 1];
    if (!last) return null;
    const art = last.querySelector(".fai-CopilotMessage");
    return {
      last,
      busy: art ? art.getAttribute("aria-busy") === "true" : true,
      hasCopy: !!last.querySelector('[data-testid="CopyButtonTestId"]')
    };
  }
  const answerNodes = last => [...last.querySelectorAll('[data-testid="markdown-reply"]')];
  const answerText = last => answerNodes(last).map(n => n.innerText.trim()).filter(Boolean).join("\n\n");

  async function waitForAnswer(job) {
    const check = () => {
      if (job.aborted) return "ABORT";
      const a = answerState();
      if (!a) return null;
      return !a.busy && a.hasCopy && answerText(a.last) ? a : null; // done = "busy" cleared and the toolbar showed up
    };
    const a = await waitUntil(check, 10 * 60 * 1000);
    if (job.aborted || a === "ABORT") throw new Error("aborted");
    if (!a) throw new Error("No answer from Copilot");
    return { text: answerText(a.last) };
  }

  // ---------- one job ----------
  async function runJob(m) {
    const job = { id: m.jobId, aborted: false };
    current = job;
    setState("busy");
    const t0 = performance.now();
    try {
      if (!isClean()) { if (!(await resetChat())) return; }
      const editor = await waitUntil(getEditor, 8000);
      if (!editor) throw new Error("Copilot's input box wasn't found (signed out?)");
      const before = questionCount();
      const how = await insertText(editor, m.prompt);
      const sentBy = await submit(editor, before, m.prompt);
      const res = await waitForAnswer(job);
      send({ t: "result", jobId: job.id, ok: true, text: res.text, how: how + ", sent by " + sentBy, ms: Math.round(performance.now() - t0), vis: document.visibilityState });
    } catch (e) {
      if (!job.aborted) send({ t: "result", jobId: job.id, ok: false, error: (e && e.message) || String(e), ms: Math.round(performance.now() - t0) });
    } finally {
      current = null;
      await resetAndReady();
    }
  }

  // ---------- connection to AHK ----------
  wv.addEventListener("message", e => {
    let m = e.data;
    if (typeof m === "string") { try { m = JSON.parse(m); } catch { return; } }
    if (!m) return;
    if (m.t === "job") { if (current) send({ t: "result", jobId: m.jobId, ok: false, error: "view busy" }); else runJob(m); }
    else if (m.t === "abort") { if (current && current.id === m.jobId) current.aborted = true; }
    else if (m.t === "ping") send({ t: "state", state, vis: document.visibilityState });
    else if (m.t === "trusted-done") { const f = pending.get(m.reqId); if (f) { pending.delete(m.reqId); f(!!m.ok); } }
    else if (m.t === "diag") diag("asked by AHK");
  });
  document.addEventListener("visibilitychange", () => send({ t: "vis", vis: document.visibilityState }));

  async function start() {
    send({ t: "hello", vis: document.visibilityState, path: location.hostname + location.pathname });
    setState("waiting-for-input-box");
    if (!(await waitUntil(getEditor, 10 * 60 * 1000))) {
      log("no input box after 10 minutes (signed out or a different page?)", location.hostname + location.pathname);
      return;
    }
    // The input box shows up before the page has finished loading: wait for "complete", then let it settle.
    setState("page-finishing");
    if (document.readyState !== "complete")
      await new Promise(r => window.addEventListener("load", r, { once: true }));
    await new Promise(r => setTimeout(r, 1500));
    await resetAndReady();
  }
  // This script is added "on document created", before the page exists: wait for the DOM first.
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
