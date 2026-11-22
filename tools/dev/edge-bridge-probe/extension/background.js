// Caption Companion bridge probe - the browser side.
// Click the extension's icon: it starts the native host (host\host.bat -> host.ahk) through
// native messaging and does what the host asks: open a tab, read what the page shows, close it.
// It never types or clicks anything on a page; it only reads (title, address, is there a message box).

const HOST = "com.captioncompanion.bridge";
let port = null;

chrome.action.onClicked.addListener(() => connect("icon click"));

function badge(text, color) {
  chrome.action.setBadgeText({ text });
  if (color) chrome.action.setBadgeBackgroundColor({ color });
}

function connect(reason) {
  if (port) { send({ t: "hello", reason: "already connected - " + reason }); return; }
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    badge("ERR", "#DC2626");
    chrome.storage.local.set({ lastError: String(e) });
    return;
  }
  badge("ON", "#16A34A");
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => {
    const err = (chrome.runtime.lastError && chrome.runtime.lastError.message) || "";
    port = null;
    badge(err ? "ERR" : "", "#DC2626");
    // the reason shows on the extension's "service worker" console and in storage
    console.log("native host disconnected", err);
    chrome.storage.local.set({ lastError: err, at: new Date().toISOString() });
  });
  send({
    t: "hello", reason, ua: navigator.userAgent, ext: chrome.runtime.id,
    ver: chrome.runtime.getManifest().version
  });
}

function send(m) {
  try { if (port) port.postMessage(m); } catch (e) { console.log("send failed", e); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function waitComplete(tabId, timeoutMs) {
  return new Promise((resolve) => {
    const done = (ok) => { chrome.tabs.onUpdated.removeListener(on); clearTimeout(timer); resolve(ok); };
    const on = (id, info) => { if (id === tabId && info.status === "complete") done(true); };
    const timer = setTimeout(() => done(false), timeoutMs);
    chrome.tabs.onUpdated.addListener(on);
    chrome.tabs.get(tabId, (t) => { if (t && t.status === "complete") done(true); });
  });
}

// Runs IN the page: only reads
function inspectPage() {
  const box = document.querySelector('textarea, [contenteditable="true"], [role="textbox"]');
  return {
    title: document.title,
    url: location.href,
    host: location.host,
    hasMessageBox: !!box,
    visibility: document.visibilityState,
    signInPage: /login\.microsoftonline\.com|login\.live\.com|accounts\.google\.com/.test(location.host)
  };
}

async function onMessage(m) {
  try {
    if (m.t === "ping") {
      send({ t: "pong", id: m.id });
    } else if (m.t === "open") {
      const t0 = Date.now();
      const tab = await chrome.tabs.create({ url: m.url, active: !!m.active });
      const loaded = await waitComplete(tab.id, m.timeoutMs || 45000);
      const samples = [];
      // read the page a few times: a background tab may be slowed down by the browser
      for (const at of m.readAtMs || [3000, 8000, 15000]) {
        await sleep(Math.max(0, at - (Date.now() - t0)));
        try {
          const [r] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: inspectPage });
          samples.push({ atMs: Date.now() - t0, ...(r && r.result) });
        } catch (e) {
          samples.push({ atMs: Date.now() - t0, error: String(e && e.message || e) });
        }
      }
      send({ t: "opened", id: m.id, active: !!m.active, loaded, ms: Date.now() - t0, samples });
      if (m.closeAfter) chrome.tabs.remove(tab.id);
    } else if (m.t === "bye") {
      port.disconnect();
      port = null;
      badge("", null);
    }
  } catch (e) {
    send({ t: "error", id: m.id, error: String(e && e.message || e) });
  }
}
