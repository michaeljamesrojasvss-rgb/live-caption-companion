// copilot-pool-worker.js - runs inside each chat page of the Copilot pool (copilot-pool.ahk).
// Grown from automation-extension/bridge/worker.js and tools/dev/copilot-webview-worker.js.
//
// Site-agnostic: everything that differs between chat sites (Copilot, Google AI Mode, ...) comes from the
// site's file in app\chat-sites (see its README) - selectors, how a new chat starts (site.newChat) and how
// an answer is known to be finished (site.answer). A new site = a new file, not new code here.
//
// AHK puts   window.__lccPool = { id, url, hosts: [...], site: {...}, account, sendWaitMs }   in front of this.
// To AHK (JSON strings):  hello {resume} | state | account | log | trusted | sent | chunk | result
// From AHK (JSON strings): job {jobId, prompt, newChat, keep, stream, preempt, hold} | go {jobId, prompt} | abort {jobId} | trusted-done | ping
// A job with "hold" is prepared ahead (new chat, images attached) and then WAITS: "go" brings its prompt,
// which is typed and sent at once (Screen ask: the slow steps happen while you mark and type).
//
// Rules: click Send ONCE and wait - Copilot takes 5-7 s to register a Send on a freshly loaded page. Only try
// another way if the prompt is still in the box. Never send a prompt twice.
// A job with "preempt" doesn't wait: the running job stops (the answer being written is stopped too), whatever
// is in the input box is cleared, and the new prompt goes right away. A Send already clicked is never
// interrupted: it is allowed to register first, so nothing is lost or sent twice.
// A job survives a page load it causes itself (a "navigate" new chat, or a site that loads a new page when it
// sends): it is kept in sessionStorage and carried on by the new page - typing is never repeated after Send.
(() => {
  if (window.top !== window || window.__lccWorker) return;
  const cfg = window.__lccPool || {};
  const site = cfg.site || {};
  const hosts = cfg.hosts && cfg.hosts.length ? cfg.hosts : [];
  if (!hosts.some(h => location.hostname === h || location.hostname.endsWith("." + h))) return;
  const wv = window.chrome && window.chrome.webview;
  if (!wv) return;
  window.__lccWorker = true;

  let state = "init", current = null, nextJob = null;
  const homeUrl = cfg.url || location.origin;
  const SEND_WAIT_MS = cfg.sendWaitMs || 15000;
  const NAVIGATE_NEW_CHAT = site.newChat === "navigate";
  const SETTLE = site.answer === "settle";
  const SETTLE_MS = site.settleMs || 2500;
  const RESUME_KEY = "__lccPoolResume";
  const KEEP_CHAT_KEY = "__lccPoolKeepChat";   // a page loaded on purpose to show a chat again: don't reset it
  const HOLD_MAX_MS = 4 * 60000;               // a held job waits this long for its prompt, then gives up (unsent)
  const goFor = new Map();                     // jobId -> prompt: "go" may arrive before the job reaches its wait

  // ---------- selectors: from the site file ----------
  const SEL_KEYS = ["editor", "question", "message", "messageBusy", "copyButton", "reply", "inputBox", "attachments", "newChat", "answerArea", "stop",
    "fileInput", "attachmentItem", "attachBusy", "dropTarget"];
  const SEL = {};
  for (const k of SEL_KEYS) {
    const v = (site.selectors || {})[k];
    SEL[k] = Array.isArray(v) ? v : v ? [String(v)] : [];
  }
  const q = (key, root = document) => { for (const s of SEL[key]) { try { const e = root.querySelector(s); if (e) return e; } catch {} } return null; };
  const qa = (key, root = document) => { for (const s of SEL[key]) { try { const l = root.querySelectorAll(s); if (l.length) return [...l]; } catch {} } return []; };

  const norm = s => (s || "").replace(/\s+/g, " ").trim();
  const send = m => { try { wv.postMessage(JSON.stringify(m)); } catch {} };
  const log = (m, d) => send({ t: "log", m, d: d === undefined ? undefined : String(d).slice(0, 300) });
  const setState = s => { state = s; send({ t: "state", state: s, path: location.hostname + location.pathname }); };
  const sleep = ms => new Promise(r => setTimeout(r, ms));

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

  // ---------- a job carried over a page load (sessionStorage: this tab only) ----------
  const resumeSave = (m, phase, extra) => { try { sessionStorage.setItem(RESUME_KEY, JSON.stringify(Object.assign({ m, phase, at: Date.now() }, extra || {}))); } catch {} };
  const resumeClear = () => { try { sessionStorage.removeItem(RESUME_KEY); } catch {} };
  function resumeTake() {
    try {
      const r = JSON.parse(sessionStorage.getItem(RESUME_KEY) || "null");
      sessionStorage.removeItem(RESUME_KEY);
      return r && r.m && Date.now() - r.at < 60000 ? r : null;
    } catch { return null; }
  }
  const resumed = resumeTake();

  // ---------- trusted input from AHK (DevTools protocol, no focus needed) ----------
  let reqSeq = 0;
  const pending = new Map();
  function trusted(op, text, timeoutMs = 4000) {
    return new Promise(resolve => {
      const reqId = ++reqSeq;
      const tm = setTimeout(() => { pending.delete(reqId); resolve(false); }, timeoutMs);
      pending.set(reqId, ok => { clearTimeout(tm); resolve(ok); });
      send({ t: "trusted", reqId, op, text });
    });
  }

  // ---------- the page ----------
  // The input box: the one you can see. Right after "New chat" Copilot briefly keeps the old (hidden or
  // detached) box next to the new one - typing into that one never shows up.
  const shown = e => e && e.isConnected && e.getClientRects().length > 0;
  const getEditor = () => {
    for (const s of SEL.editor) {
      try { const l = [...document.querySelectorAll(s)].filter(shown); if (l.length) return l[l.length - 1]; } catch {}
    }
    return null;
  };
  const isField = e => e && (e.tagName === "TEXTAREA" || e.tagName === "INPUT");   // a plain text box (not contenteditable)
  const editorText = () => { const e = getEditor(); return e ? norm(isField(e) ? e.value : e.innerText) : ""; };
  const questionCount = () => qa("question").length;
  let pageUsed = false;            // "navigate" sites: a prompt was sent on this page load (so it's not a fresh chat)
  // clean = empty box, no chat yet, and no file chips left in the box (e.g. images of a job that failed before Send)
  const isClean = () => !!getEditor() && editorText() === "" && (NAVIGATE_NEW_CHAT ? !pageUsed : questionCount() === 0)
    && !attachPending                         // images put in the box but never sent: only a reload is sure to clear them
    && (!imagesUsed || chipCount() === 0);   // (only checked on a page we attached images on: text-only use is unchanged)
  const btnLabel = b => (b.getAttribute("aria-label") || "") + " " + (b.getAttribute("data-testid") || "") + " " + (b.title || "");

  function inputButtons() {
    const known = q("inputBox");
    if (known) return [...known.querySelectorAll("button")];
    let n = getEditor();
    for (let i = 0; n && i < 8; i++, n = n.parentElement) {
      const bs = n.querySelectorAll("button,[role=button]");
      if (bs.length) return [...bs];
    }
    return [];
  }
  function findSendButton() {
    const isSend = b => /send|submit/i.test(btnLabel(b)) && !/dictat|stop|feedback/i.test(btnLabel(b));
    return inputButtons().find(isSend) || [...document.querySelectorAll("button")].find(isSend) || null;
  }
  const btnDisabled = b => b.disabled || b.getAttribute("aria-disabled") === "true";
  // ---------- debug trace: step timings + what the page shows (counts and states only, never text) ----------
  let traceJob = "", traceT0 = 0;
  function snap() {
    try {
      const b = findSendButton(), a = SETTLE ? null : answerState(), att = q("attachments");
      return "questions=" + questionCount() + " messages=" + qa("message").length + " box=" + editorText().length + "ch"
        + " send=" + (b ? (btnDisabled(b) ? "disabled" : "enabled") : "none") + " stop=" + (stopButton() ? "yes" : "no")
        + (SETTLE ? " area=" + areaText().length + "ch" : " answer=" + (a ? (a.busy ? "writing" : a.hasCopy ? "done" : "no-copy-btn") : "none"))
        + (att && att.children.length ? " attachments=" + att.children.length : "")
        + (IMG ? " chips=" + chipCount() + " imgsignal=" + attachSignal() + " filepics=" + madePictures() + " imgs=" + document.images.length : "")
        + " visible=" + document.visibilityState + " focus=" + (document.hasFocus() ? "yes" : "no")
        + " path=" + location.pathname + " state=" + state;
    } catch (e) { return "snapshot failed: " + e.message; }
  }
  // job steps: ms since the job arrived; page events: ms since the page loaded
  const tr = step => {
    const now = performance.now();
    send({ t: "trace", jobId: traceJob, ms: Math.round(traceJob ? now - traceT0 : now), step: traceJob ? step : "(page) " + step, snap: snap() });
  };

  // The site's "stop writing" button: selectors.stop if the site file gives it, else any visible button
  // labelled Stop - unless the site says "stopByLabel": false (its page has other buttons called "stop")
  const stopButton = () => {
    if (SEL.stop.length) return qa("stop").find(shown) || null;
    if (site.stopByLabel === 0 || site.stopByLabel === false) return null;
    return [...document.querySelectorAll("button")].find(b => shown(b) && /\bstop\b/i.test(btnLabel(b)) && !/dictat/i.test(btnLabel(b))) || null;
  };
  // Stops the answer being written (if any)
  async function stopAnswer() {
    const b = stopButton();
    if (!b) return;
    tr("the site is still writing - clicking Stop");
    const t = performance.now();
    b.click();
    if (!(await waitUntil(() => !stopButton(), 5000))) { log("Stop didn't end the answer in 5 s"); tr("Stop did NOT end the answer in 5 s"); }
    else tr("answer stopped after " + Math.round(performance.now() - t) + " ms");
  }
  function pressEnter(el) {
    const init = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
    el.dispatchEvent(new KeyboardEvent("keydown", init));
    el.dispatchEvent(new KeyboardEvent("keypress", init));
    el.dispatchEvent(new KeyboardEvent("keyup", init));
  }

  // ---------- who is signed in (sites with a work-account check only) ----------
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
    if (cfg.account === "none") return;
    const a = findAccount();
    const key = a.email + "|" + a.tenant;
    if (key !== lastAccount) { lastAccount = key; send(Object.assign({ t: "account" }, a)); }
  }

  // ---------- reset to a fresh chat ----------
  // Returns true when the page is a fresh chat now; false when the page is being loaded again (this script
  // starts over on the new page - with m given, it carries that job on there).
  async function resetChat(m) {
    if (isClean()) return true;
    if (NAVIGATE_NEW_CHAT) {
      tr("new chat = loading the site's page again");
      if (m) resumeSave(m, "new");
      location.href = homeUrl;
      return false;
    }
    const link = q("newChat") ||
      [...document.querySelectorAll("a,button")].find(a => /new chat/i.test(a.getAttribute("aria-label") || ""));
    tr(link ? "clicking New chat" : "no New chat link found");
    const t = performance.now(), path0 = location.pathname, inConv = /\/conversation\//.test(path0);
    if (link) link.click();
    // clean, and (if a conversation was open) the site has moved off it - else the box is about to be replaced
    if (await waitUntil(() => isClean() && (!inConv || location.pathname !== path0), link ? 4000 : 200)) {
      await sleep(300);   // let the new box settle
      if (isClean()) { tr("new chat is clean after " + Math.round(performance.now() - t) + " ms"); return true; }
    }
    if (link && isClean()) { tr("new chat is clean (its address didn't change) after " + Math.round(performance.now() - t) + " ms"); return true; }
    log("New chat didn't clear the page - reloading", link ? "link clicked" : "no link");
    tr("New chat didn't clear the page - RELOADING the page");
    if (m) resumeSave(m, "new");
    location.href = homeUrl;
    return false;
  }
  async function resetAndReady() {
    setState("resetting");
    if (await resetChat(null)) { setState("ready"); reportAccount(); }
  }

  // ---------- type the prompt ----------
  const hasPrompt = text => {
    const have = editorText().length, want = norm(text).length;
    if (have >= Math.min(want, Math.max(1, want * 0.9))) return true;
    return chipCount() > attachBase;      // very long pastes can turn into an attachment chip (images we attached don't count)
  };
  // A plain text box (textarea/input): set its value the way the page's own code notices (React & co.)
  function setFieldValue(el, text) {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    el.focus();
    setter.call(el, text);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }
  // Empties the input box, whatever is in it (your own typing, a prompt that was never sent)
  async function clearEditor(editor) {
    if (editorText() === "") return;
    tr("the input box has " + editorText().length + " chars in it - clearing");
    if (isField(editor)) setFieldValue(editor, "");
    else { editor.focus(); document.execCommand("selectAll"); document.execCommand("delete"); }
    if (await waitUntil(() => editorText() === "", 1000)) { tr("box cleared"); return; }
    tr("script delete didn't clear it - trying trusted Backspace");
    editor.focus(); if (isField(editor)) editor.select(); else document.execCommand("selectAll");
    if (await trusted("backspace") && await waitUntil(() => editorText() === "", 1500)) { tr("box cleared (Backspace)"); return; }
    throw new Error("Couldn't clear the input box");
  }
  async function insertText(editor, text) {
    editor = getEditor() || editor;
    await clearEditor(editor);
    editor = getEditor() || editor;
    if (isField(editor)) {
      setFieldValue(editor, text);
      if (await waitUntil(() => hasPrompt(text), 1500)) return "value";
      log("setting the value didn't take - using insertText");
    } else {
      editor.focus();
      const sel = getSelection(); sel.removeAllRanges();
      const r = document.createRange(); r.selectNodeContents(editor); sel.addRange(r);
      const dt = new DataTransfer(); dt.setData("text/plain", text);
      editor.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
      if (await waitUntil(() => hasPrompt(text), 1500)) return "paste";
      log("paste didn't take - using insertText");
    }
    editor = getEditor() || editor;
    editor.focus(); if (isField(editor)) editor.select(); else document.execCommand("selectAll");
    document.execCommand("insertText", false, text);
    if (await waitUntil(() => hasPrompt(text), 1500)) return "insertText";
    log("insertText didn't take - using trusted typing");
    editor = getEditor() || editor;
    editor.focus(); if (isField(editor)) editor.select(); else document.execCommand("selectAll");
    if (await trusted("insert", text) && await waitUntil(() => hasPrompt(text), 3000)) return "trusted";
    throw new Error("Couldn't type the prompt into the input box");
  }

  // ---------- images (site.images in the site file) ----------
  // A job with "images": n asks AHK for them ("images-get" -> "images" {list:[{name, mime, b64}]}) - never
  // through sessionStorage or logs - and attaches them BEFORE the prompt is typed. Each way in site.images.how
  // is tried in order for the first image; the way that worked is used for the rest:
  //   paste         = a paste event with the file on the input box (what Ctrl+V of an image does)
  //   drop          = drag-and-drop events with the file on selectors.dropTarget / inputBox / the box
  //   input         = the page's own <input type=file> (selectors.fileInput), set by script
  //   trusted-input = the same input, filled by AHK through the DevTools protocol (DOM.setFileInputFiles)
  // An image counts as attached when the box shows one more attachment. All or nothing: if one can't be
  // attached the job fails before Send (unsent). Never clicks an "attach" button (it would open a file dialog).
  const IMG = site.images || null;
  let attachBase = 0;                     // chips in the box that are ours (images), not a long paste
  let imagesUsed = false;                 // this page has had images attached (then a "clean" page has no chips left)
  let attachPending = false;              // we may have put images in the box that weren't sent (a site may show no chips)
  let imgWait = null;
  let lastWay = "";                       // the attach way that worked last on this page
  const composer = () => q("inputBox") || (getEditor() && getEditor().closest("form")) || null;
  // file chips in the input box
  function chipCount() {
    let n = 0;
    const box = q("attachments");
    if (box) n = box.children.length;
    return Math.max(n, qa("attachmentItem").filter(shown).length);
  }
  // anything that shows an attachment appeared: chips, pictures in the input box area, or anywhere on the
  // page a picture made from a file (blob:/data: address = a pasted image's thumbnail). Compared before/after.
  // (2026-11-20, Google AI Mode: the pasted images showed, but with no chips or box area known to us, only
  // the "made from a file" pictures and the Send button give it away - see attachedNow)
  function madePictures() {
    let n = 0;
    for (const im of document.images) { const s = im.currentSrc || im.src || ""; if (/^(blob|data):/i.test(s) && shown(im)) n++; }
    return n;
  }
  function attachSignal() {
    let n = chipCount();
    const c = composer();
    if (c) n = Math.max(n, c.querySelectorAll("img,canvas").length);
    return n + madePictures();
  }
  const sendEnabled = () => { const b = findSendButton(); return !!b && !btnDisabled(b); };
  // attached since "before" ({sig, sendOff}): more attachment signs, or Send came on with an empty box
  // (a site enables Send only when there is something to send)
  const attachedNow = before => attachSignal() > before.sig || (before.sendOff && editorText() === "" && sendEnabled());
  function imagesFromAhk(jobId) {
    return new Promise(resolve => {
      const tm = setTimeout(() => { imgWait = null; resolve(null); }, 15000);
      imgWait = { jobId, done: list => { clearTimeout(tm); imgWait = null; resolve(list); } };
      send({ t: "images-get", jobId });
    });
  }
  function toFile(it, i) {
    const bin = atob(it.b64 || ""), a = new Uint8Array(bin.length);
    for (let k = 0; k < bin.length; k++) a[k] = bin.charCodeAt(k);
    return new File([a], it.name || "image-" + (i + 1) + ".png", { type: it.mime || "image/png", lastModified: Date.now() });
  }
  function fileInput() {
    const sels = SEL.fileInput.length ? SEL.fileInput : ['input[type="file"]'];
    for (const s of sels) {
      try {
        const l = [...document.querySelectorAll(s)].filter(e => !e.disabled && (!e.accept || /image|\*/i.test(e.accept)));
        if (l.length) return l[l.length - 1];
      } catch {}
    }
    return null;
  }
  async function attachOne(how, file, idx, editor) {
    const dt = new DataTransfer();
    dt.items.add(file);
    if (how === "paste") {
      const e = getEditor() || editor;
      e.focus();
      e.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
      return true;
    }
    if (how === "drop") {
      const t = q("dropTarget") || q("inputBox") || getEditor() || editor, r = t.getBoundingClientRect();
      const o = { dataTransfer: dt, bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      document.body.dispatchEvent(new DragEvent("dragenter", o));
      for (const type of ["dragenter", "dragover", "drop"]) t.dispatchEvent(new DragEvent(type, o));
      return true;
    }
    if (how === "input" || how === "trusted-input") {
      const inp = fileInput();
      if (!inp) return false;
      if (how === "input") {
        inp.files = dt.files;
        inp.dispatchEvent(new Event("input", { bubbles: true }));
        inp.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      }
      document.querySelectorAll("[data-lcc-files]").forEach(x => x.removeAttribute("data-lcc-files"));
      inp.setAttribute("data-lcc-files", "1");
      const ok = await trusted("files", String(idx), 12000);
      inp.removeAttribute("data-lcc-files");
      return ok;
    }
    return false;
  }
  async function attachImages(job, count, editor) {
    if (!IMG) throw new Error("this chat site can't take images (no \"images\" in its site file)");
    const list = await imagesFromAhk(job.id);
    if (!list || list.length !== count) throw new Error("the images didn't arrive from the pool");
    const files = list.map(toFile);
    imagesUsed = true;
    attachPending = true;                 // until Send takes them (a failure leaves the page "not clean": reloaded)
    let ways = Array.isArray(IMG.how) && IMG.how.length ? IMG.how : ["paste", "drop", "input", "trusted-input"];
    // the way that worked last time goes first (a way that fails costs attachWaitMs, 6 s on Copilot)
    if (lastWay && ways.includes(lastWay)) ways = [lastWay].concat(ways.filter(w => w !== lastWay));
    const waitMs = IMG.attachWaitMs || 6000;
    let worked = null;
    for (let i = 0; i < files.length; i++) {
      let ok = false;
      for (const how of worked ? [worked] : ways) {
        const b0 = { sig: attachSignal(), sendOff: !sendEnabled() }, t = performance.now();
        if (!(await attachOne(how, files[i], i, editor))) { tr("image " + (i + 1) + ": no way to " + how + " here"); continue; }
        if (await waitUntil(() => attachedNow(b0), waitMs)) {
          ok = true; worked = how;
          tr("image " + (i + 1) + " of " + files.length + " attached by " + how + " (" + Math.round(performance.now() - t) + " ms)");
          break;
        }
        tr("image " + (i + 1) + ": " + how + " showed no attachment in " + waitMs + " ms");
        if (attachedNow(b0)) { ok = true; worked = how; break; }   // just in time: never attach it twice
      }
      if (!ok) throw new Error("couldn't attach image " + (i + 1) + " of " + files.length + " to the chat box");
      job.attached = true;
    }
    // uploads: done when the site shows no upload in progress (selectors.attachBusy), if it tells us
    if (SEL.attachBusy.length) {
      const t = performance.now(), upMs = IMG.uploadWaitMs || 60000;
      await sleep(400);
      if (!(await waitUntil(() => !qa("attachBusy").some(shown), upMs))) throw new Error("the images were still uploading after " + upMs / 1000 + " s");
      tr("uploads finished (" + Math.round(performance.now() - t) + " ms)");
    }
    lastWay = worked || lastWay;
    log("attached " + files.length + " image(s) by " + worked);
  }

  // ---------- send (once) ----------
  async function submit(editor, before, prompt, buttonWaitMs = 2000) {
    const href0 = location.href, stopBefore = stopButton();
    // in: the box emptied, a new question, the page moved, or a Stop button APPEARED (one that was already
    // there before sending proves nothing)
    const sent = () => questionCount() > before || editorText() === "" || location.href !== href0
      || (!!stopButton() && stopButton() !== stopBefore);
    const tries = [
      ["button", async () => {
        const w = performance.now();
        const b = await waitUntil(() => { const x = findSendButton(); return x && !btnDisabled(x) ? x : null; }, buttonWaitMs);
        if (!b) { tr("Send button not found / not enabled after " + Math.round(performance.now() - w) + " ms"); return false; }
        tr("Send button enabled (waited " + Math.round(performance.now() - w) + " ms) - clicking it");
        b.click(); return true;
      }],
      ["trusted-enter", async () => { tr("pressing Enter (trusted)"); (getEditor() || editor).focus(); return trusted("enter"); }],
      ["enter", async () => { tr("pressing Enter (script)"); const e = getEditor() || editor; e.focus(); pressEnter(e); return true; }]
    ];
    for (const [how, run] of tries) {
      if (sent()) return how + " (late)";
      if (!hasPrompt(prompt)) throw new Error("The prompt left the box without being sent");
      if (!(await run())) continue;
      const t = performance.now();
      const iv = setInterval(() => tr("still waiting for the site to take the message (" + how + ", " + Math.round(performance.now() - t) + " ms)"), 2000);
      const ok = await waitUntil(sent, SEND_WAIT_MS);
      clearInterval(iv);
      if (ok) { log("sent by " + how + " after " + Math.round(performance.now() - t) + " ms"); tr("the site took the message (" + how + ") after " + Math.round(performance.now() - t) + " ms"); return how; }
      log("send: " + how + " didn't register in " + SEND_WAIT_MS / 1000 + " s");
      tr("send by " + how + " did NOT register in " + SEND_WAIT_MS / 1000 + " s");
    }
    throw new Error("Couldn't send the message");
  }

  // ---------- read the answer: "copy-button" sites (Copilot) ----------
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
    try { if (last) last.scrollIntoView({ block: "end" }); else window.scrollTo(0, document.body.scrollHeight); } catch {}
  }

  async function waitForAnswerCopyButton(job, msgsBefore) {
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
          const x = answerText(a.last);
          if (x && x !== lastSent) { lastSent = x; lastAt = now; send({ t: "chunk", jobId: job.id, text: x }); }
        }
      }
      return !a.busy && a.hasCopy && answerText(a.last) ? a : null;
    };
    const a = await waitUntil(check, job.timeoutMs);
    clearInterval(iv);
    if (job.aborted || a === "ABORT") throw new Error("aborted");
    if (!a) throw new Error("No answer in time");
    tr("answer finished " + Math.round(performance.now() - t) + " ms after sending (" + answerText(a.last).length + " chars)");
    if (job.scroll) { scrollToNewest(true); setTimeout(() => scrollToNewest(true), 600); }
    const nodes = answerNodes(a.last);
    return { text: answerText(a.last), markdown: nodes.map(toMd).filter(Boolean).join("\n\n") };
  }

  // ---------- read the answer: "settle" sites (no reliable answer markers, e.g. Google AI Mode) ----------
  // The answer = the text of the answer area after the prompt (as the page shows it); finished when it
  // hasn't changed for settleMs, nothing is busy and there's no Stop button.
  function areaEl() { for (const s of SEL.answerArea.length ? SEL.answerArea : ["body"]) { try { const e = document.querySelector(s); if (e) return e; } catch {} } return document.body; }
  function areaText() { try { return norm(areaEl().innerText); } catch { return ""; } }
  function settleAnswer(prompt, baseline) {
    const all = areaText(), p = norm(prompt);
    const tail = p.slice(-40), head = p.slice(0, 40);
    let i = tail ? all.lastIndexOf(tail) : -1;
    if (i >= 0) return all.slice(i + tail.length).trim();
    i = head ? all.lastIndexOf(head) : -1;          // the page shows only the start of a long prompt
    if (i >= 0) return all.slice(i + head.length).trim();
    if (!baseline) return all;
    let n = 0;                                      // else: whatever differs from the page just before Send
    const max = Math.min(all.length, baseline.length);
    while (n < max && all[n] === baseline[n]) n++;
    return all.slice(n).trim();
  }
  async function waitForAnswerSettle(job, prompt, baseline) {
    const t = performance.now();
    let last = "", since = performance.now(), words = false, lastChunk = "";
    for (;;) {
      if (job.aborted) throw new Error("aborted");
      if (performance.now() - t > job.timeoutMs) throw new Error("No answer in time");
      const now = performance.now();
      const ans = settleAnswer(prompt, baseline);
      if (ans !== last) { last = ans; since = now; }
      if (ans && !words) { words = true; tr("first words of the answer " + Math.round(now - t) + " ms after sending"); }
      if (job.stream && ans && ans !== lastChunk) { lastChunk = ans; send({ t: "chunk", jobId: job.id, text: ans }); }
      if (job.scroll) scrollToNewest(false);
      const busy = !!stopButton() || !!areaEl().querySelector('[aria-busy="true"]');
      // done: unchanged for settleMs and nothing busy - or unchanged 3x as long (a "busy" marker that never clears)
      if (ans && now - t >= (site.minAnswerMs || 0) && now - since >= (busy ? 3 * SETTLE_MS : SETTLE_MS)) break;
      if (Math.round(now - t) % 5000 < 300) tr("waiting for the answer to settle (" + Math.round(now - t) + " ms so far)");
      await sleep(300);
    }
    tr("answer settled " + Math.round(performance.now() - t) + " ms after sending (" + last.length + " chars)");
    if (job.scroll) scrollToNewest(true);
    return { text: last, markdown: last };
  }

  // A held job was cancelled before Send after it had left a chat: load that chat again, as it was
  function backToChat(url) {
    try { sessionStorage.setItem(KEEP_CHAT_KEY, "1"); } catch {}
    tr("cancelled before Send - showing the previous chat again");
    attachPending = false;
    location.href = url;
    return true;
  }

  // ---------- one job ----------
  // r = a job carried over from the previous page load: {phase: "new" (not typed yet) | "sent" (in the site), ...}
  async function runJob(m, r) {
    const job = { id: m.jobId, stream: !!m.stream, scroll: !!m.scroll, aborted: false, sent: false, timeoutMs: m.timeoutMs || 180000,
      wake: null, backTo: "" };
    const stopIfAborted = () => { if (job.aborted) throw new Error("aborted"); };
    const t0 = performance.now();
    traceJob = job.id; traceT0 = t0;
    tr((r ? "job carried over the page load (" + r.phase + "): " : "job received: ") + (m.prompt || "").length + " chars"
      + (m.newChat ? ", new chat" : ", follow-up") + (m.keep ? ", keep chat" : "") + (m.preempt ? ", replacing the previous job" : "")
      + (m.hold ? ", HELD (prepared now, its prompt comes later)" : ""));
    current = job;
    setState("busy");
    let sentBy = "", how = "", leaving = false;
    try {
      if (r && r.phase === "sent") {          // it went in before the page changed: only the answer is left
        job.sent = true; sentBy = "before the page load";
        pageUsed = true;
        send({ t: "sent", jobId: job.id });
        const res = SETTLE ? await waitForAnswerSettle(job, m.prompt, "") : await waitForAnswerCopyButton(job, 0);
        send({ t: "result", jobId: job.id, ok: true, sent: true, text: res.text, markdown: res.markdown, how: "carried over", ms: Math.round(performance.now() - t0) });
        return;
      }
      // something typed into the box by hand (a person's draft): an automatic prompt never replaces it -
      // it comes back unsent and the app tries again later
      if (m.respectDraft && editorText() !== "") throw new Error("someone is typing in the input box - not replacing their text");
      await stopAnswer();                     // still writing an earlier answer: stop it, this prompt goes now
      stopIfAborted();
      // held: if it's cancelled before Send, the chat it had is loaded again as it was (its images gone) - you
      // may still be reading it. A new chat on a hidden page needn't: nobody sees it.
      if (m.hold && !r && questionCount() > 0 && (!m.newChat || document.visibilityState === "visible")) job.backTo = location.href;
      if (m.newChat && !isClean()) {
        if (!(await resetChat(m))) { leaving = true; return; }   // the page loads again and carries this job on
      }
      const we = performance.now();
      const editor = await waitUntil(getEditor, 8000);
      if (!editor) throw new Error("the input box wasn't found (signed out?)");
      tr("input box found (waited " + Math.round(performance.now() - we) + " ms)");
      stopIfAborted();
      const nImg = m.images || 0;
      if (nImg) {                             // images first: the prompt is typed after them
        await attachImages(job, nImg, editor);
        stopIfAborted();
      }
      attachBase = chipCount();
      if (m.hold) {                           // prepared: now wait for the prompt ("go")
        const th = performance.now();
        if (!goFor.has(job.id) && !job.aborted) {
          tr("prepared - waiting for the prompt");
          setState("held");
          await new Promise(res => { job.wake = res; setTimeout(res, HOLD_MAX_MS); });
          job.wake = null;
          setState("busy");
        }
        stopIfAborted();
        if (!goFor.has(job.id)) throw new Error("the prompt never came (held " + Math.round(HOLD_MAX_MS / 60000) + " min)");
        m = Object.assign({}, m, { prompt: goFor.get(job.id), hold: 0 });
        tr("prompt arrived (" + m.prompt.length + " chars) after holding " + Math.round(performance.now() - th) + " ms - typing and sending");
        if (nImg && chipCount() < attachBase) throw new Error("the images left the chat box while it waited");
      }
      const before = questionCount(), msgsBefore = qa("message").length;
      const ti = performance.now();
      try { how = await insertText(editor, m.prompt); }
      catch (e) { if (/Couldn't type/.test(e.message)) job.reload = true; throw e; }
      tr("prompt is in the box (by " + how + ", " + Math.round(performance.now() - ti) + " ms)");
      stopIfAborted();                        // replaced before Send: the newer prompt overwrites the box
      const baseline = SETTLE ? areaText() : "";   // the page as it is right before Send (typing can change it)
      resumeSave(m, "sent");                  // if Send loads a new page, that page waits for the answer (never types again)
      if (nImg && chipCount() < attachBase) throw new Error("the images left the chat box before Send");
      // with images, Send may stay disabled while they upload: wait for it longer
      sentBy = await submit(getEditor() || editor, before, m.prompt, nImg ? (IMG.uploadWaitMs || 60000) : 2000);   // never interrupted once Send is clicked
      job.sent = true; pageUsed = true; attachPending = false;
      send({ t: "sent", jobId: job.id });
      const res = SETTLE ? await waitForAnswerSettle(job, m.prompt, baseline) : await waitForAnswerCopyButton(job, msgsBefore);
      send({ t: "result", jobId: job.id, ok: true, sent: true, text: res.text, markdown: res.markdown,
        how: how + ", sent by " + sentBy, ms: Math.round(performance.now() - t0) });
    } catch (e) {
      tr((job.aborted ? "job stopped: a newer prompt replaced it / it was cancelled" : "job FAILED: " + ((e && e.message) || String(e)))
        + (job.sent ? " (it had been sent)" : " (it was never sent)"));
      if (job.aborted) {
        if (job.sent) await stopAnswer();
        else if (job.backTo && !nextJob) leaving = backToChat(job.backTo);   // the page loads that chat again
      }
      else send({ t: "result", jobId: job.id, ok: false, sent: !!sentBy, error: (e && e.message) || String(e), ms: Math.round(performance.now() - t0) });
    } finally {
      if (leaving) { tr(job.aborted ? "page loading the previous chat again" : "page loading again - the job carries on there"); return; }
      resumeClear();
      goFor.delete(job.id);
      current = null;
      tr("job over after " + Math.round(performance.now() - t0) + " ms" + (nextJob ? " - the newer prompt starts now" : m.keep ? " - chat kept" : " - resetting to a new chat"));
      traceJob = "";
      if (job.reload && !nextJob) {           // the box won't take text: the page is stuck - load it again
        log("the input box won't take text - reloading the page");
        tr("RELOADING the page (the input box won't take text)");
        location.href = homeUrl;
      }
      else if (nextJob) { const n = nextJob; nextJob = null; runJob(n); }   // a newer prompt is waiting: no reset in between
      else if (m.keep && !(job.aborted && !job.sent && attachPending)) setState("ready");     // a kept conversation stays as it is
      else if (m.keep) await resetAndReady();  // stopped before Send with images in the box: they're cleared
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
    else if (m.t === "go") {                  // the prompt of a held job (taken once only)
      if (!m.jobId || typeof m.prompt !== "string" || goFor.has(m.jobId)) return;
      goFor.set(m.jobId, m.prompt);
      if (current && current.id === m.jobId && current.wake) current.wake();
    }
    else if (m.t === "abort") {
      if (current && current.id === m.jobId) {
        current.aborted = true;
        if (m.restore === 0) current.backTo = "";            // replaced by a new prepared one: no need to show the old chat
        if (current.wake) current.wake();
        if (imgWait && imgWait.jobId === m.jobId) imgWait.done(null);   // don't sit waiting for images that won't come
      }
      else if (nextJob && nextJob.jobId === m.jobId) nextJob = null;
    }
    else if (m.t === "trusted-done") { const f = pending.get(m.reqId); if (f) { pending.delete(m.reqId); f(!!m.ok); } }
    else if (m.t === "images") { if (imgWait && imgWait.jobId === m.jobId) imgWait.done(m.list || []); }
    else if (m.t === "mem") {                 // memory audit: this page's own size (numbers only)
      let heapMB = 0;
      try { heapMB = Math.round(((performance.memory && performance.memory.usedJSHeapSize) || 0) / 1048576); } catch {}
      send({ t: "mem", heapMB, nodes: document.getElementsByTagName("*").length });
    }
    else if (m.t === "newchat") { if (!current) resetAndReady(); }
    else if (m.t === "ping") { send({ t: "state", state, path: location.hostname + location.pathname }); reportAccount(); }
  });

  async function start() {
    send({ t: "hello", path: location.hostname + location.pathname, resume: resumed ? resumed.m.jobId : "" });
    tr("page script started (" + document.readyState + ")" + (resumed ? " - carrying on job " + resumed.m.jobId : ""));
    if (resumed && resumed.phase === "sent") {   // already in the site: don't wait for a clean page, just read the answer
      runJob(resumed.m, resumed);
      return;
    }
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
    await sleep(1500);
    let keepChat = false;
    try { keepChat = sessionStorage.getItem(KEEP_CHAT_KEY) === "1"; sessionStorage.removeItem(KEEP_CHAT_KEY); } catch {}
    if (keepChat && !resumed) {             // loaded to show a chat again (a cancelled held job): leave it as it is
      tr("page ready - the previous chat is shown again");
      setState("ready"); reportAccount();
      return;
    }
    if (resumed) {                          // a new chat it asked for: this fresh page is it
      reportAccount();
      runJob(Object.assign({}, resumed.m, { newChat: 0, preempt: 0 }), resumed);
      return;
    }
    await resetAndReady();
    tr("page ready for prompts");
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
