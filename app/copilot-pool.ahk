#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
try TraySetIcon(A_ScriptDir "\icons\pool.ico")        ; its own icon (its windows, taskbar)
try DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", "CaptionCompanion.CopilotPool") ; own taskbar button
#Include app-paths.ahk
#Include Json.ahk
#Include debug-trace.ahk
#Include webview-guard.ahk
#Include *i %A_ScriptDir%\lib\WebView2\WebView2.ahk
; ==============================================================================
; copilot-pool.ahk  -  Copilot pool: hidden Copilot pages that answer requests
;
; * Its own app and its own process. It knows nothing about calls, captions or
;   helpers: an app sends text, it gets text back. The Companion is one such app
;   (copilot-pool-link.ahk). If this crashes, the Companion carries on and falls
;   back to pasting into Copilot. Design: docs\COPILOT-POOL.md.
; * A few Copilot pages hosted in WebView2 (app\lib), each running
;   copilot-pool-worker.js. One sign-in, shared by all of them, kept in
;   %LOCALAPPDATA%\CaptionCompanion\copilot-pool-web (never a synced folder).
;   "Sign out" in the window forgets it.
; * Chat sites: Copilot by default. What differs per site (address, hosts, sign-in, selectors, how a new
;   chat starts, how an answer is known to be done) is in app\chat-sites\<id>.json - see its README.
;   Dev-only sites (Google AI Mode, for testing without Copilot) load only in dev mode (AppIsDev:
;   a git working copy); the pool window then has a "Chat site" list. Each site has its own sign-in.
; * Safety: pages load over https only; only the site's own pages (its "hosts")
;   can send messages to the pool; links open in your normal browser; no
;   developer tools; no debugging port is opened (the DevTools protocol is used
;   in-process only, for typing without focus).
; * One-off requests get a fresh chat. A request with a "conversation" name
;   keeps its page and chat, so follow-ups only need the new part.
; * A request with "show" (the Companion's 💬 buttons): its page appears as a
;   normal Copilot window right away - you watch the answer and can keep
;   chatting. That page is yours until you close the window; then it gets a
;   fresh chat and goes back to the pool. Another page opens meanwhile (up to
;   MaxViews) so the next request doesn't wait.
;   With a "conversation" name too (the Companion: one per helper), later
;   requests with that name go to the same window and chat, and the window
;   remembers its own place and size. Closing it ends the conversation. The
;   open ones are listed in every "state" message (windows).
; * One sign-in for all pages: a page that lands on the sign-in page (you
;   signed out in a Copilot window) reloads every page; signing in on one
;   reloads the pages still waiting for it. "Sign out" switches to a new,
;   empty sign-in folder, so nothing from the old sign-in is reused.
; * Work account only: requests are refused while a personal account (gmail.com,
;   outlook.com, ... - see PersonalDomains) is signed in, unless "Allow personal
;   accounts (testing only)" is ticked.
; * Never sends a prompt twice. The log (data\copilot-pool.log) never holds
;   prompt or answer text.
; * One copy only. Arguments: /background, /show, /signin, /restart.
;
; Messages (WM_COPYDATA, tag POOL_TAG, JSON text):
;   app -> pool  {t:"ask", id, hwnd, prompt, label, conversation, newChat, stream, show, orNew, respectDraft, quiet}
;                (quiet: with show - the window opens without taking the focus)
;                (orNew: a follow-up that may start the conversation again if it's gone - it carries the full prompt)
;                (respectDraft: an automatic prompt - if text was typed by hand into the page's box, it comes back unsent)
;                (images: [file paths] - PNG/JPEG files in APP_IMAGE_INBOX only (app-paths.ahk), attached to the
;                 message before the prompt; all or nothing - if one can't be attached it comes back unsent.
;                 Read when the request arrives: the app may delete the files once it has "done".
;                 Sites without "images" in their chat-sites file refuse them (unsent).)
;                {t:"cancel", id}   {t:"end", conversation}   {t:"status", hwnd}
;                {t:"reserve", conversation, hwnd}: that conversation gets its OWN page, always loaded and
;                  warm, never lent out (Screen ask). Closing its window / "end" = only a fresh chat. Not kept
;                  across pool restarts: the app sends it again now and then (it also subscribes to "state").
; Never stuck: pages that fail to open are retried (2, 4, 8... up to 30 s apart); 3 failures in a row or a
; failed engine start = a new browser engine (PoolMakeEngine, retried every 15 s).
;                {t:"show"}   {t:"signin"}   {t:"quit"}
;   pool -> app  {t:"queued", id, position}   {t:"sent", id}   {t:"chunk", id, text}
;                {t:"done", id, ok, kind, text, markdown, error, ms}
;                {t:"state", state, reason, views, ready, free, queued, account, accountKind, windows:[conversation names]}
;   state: off | starting | signin | account | ready
;   kind (when ok=0): unsent (never reached Copilot - safe to try another way),
;     off / starting / signin / account / busy (same: never reached Copilot),
;     lost (that conversation is gone - send the full context again),
;     replaced (a warm-up message was dropped for a real request),
;     failed / timeout / cancelled (may have reached Copilot - do NOT resend)
; Warm-up: each freshly loaded page sends WarmUpPrompt once (Copilot is slow on a page's first
; message only); any real request replaces a warm-up at once.
; ==============================================================================
POOL_TITLE := "Caption Companion Copilot pool"
POOL_TAG := 0x3CC3
POOL_INI := DATA_DIR "\copilot-pool.ini"
POOL_LOG := DATA_DIR "\copilot-pool.log"
; Browser sign-in data lives in the local app-data folder (like Edge's own profile): never in a folder
; that OneDrive could sync. Encrypted by WebView2 for this Windows account.
POOL_WEB := EnvGet("LOCALAPPDATA") "\CaptionCompanion\copilot-pool-web"
POOL_WEB_OLD := DATA_DIR "\copilot-pool"           ; where early test versions kept it (removed at start)
POOL_WORKER := A_ScriptDir "\copilot-pool-worker.js"
; The chat sites the pool can drive: one JSON file each (see chat-sites\README.md). Copilot is the real
; one; dev-only sites (e.g. Google AI Mode, for testing without Copilot) load only in dev mode.
POOL_SITES_DIRS := [A_ScriptDir "\chat-sites", DATA_DIR "\chat-sites"]   ; data\ overrides app\ (same id)
POOL_DEV := AppIsDev()
POOL_CONSUMER_TENANT :="9188040d-6c67-4c5b-b112-36a304b66dad"   ; Microsoft's tenant for personal accounts
POOL_DEFAULTS := Map(
    "Site", "copilot",             ; which chat site (a file in chat-sites\)
    ; 0 = never signs in by itself with the Windows account: you sign in once in the pool's own window,
    ; and after "Sign out" nothing is reused (a brand-new, empty sign-in folder)
    "SingleSignOn", 0,
    "Views", 1,                    ; pages kept ready (a spare); each helper's 💬 window takes one
    "MaxViews", 8,                 ; most pages at once (helper windows + the spare)
    "SendWaitSec", 15,             ; Copilot takes 5-7 s to register Send
    "AnswerTimeoutSec", 180,
    "QueueWaitSec", 45,            ; a request that can't start this soon is handed back (unsent)
    "SignInWaitSec", 600,          ; a 💬 request waits this long for you to sign in
    "ConversationIdleMin", 30,
    "RefreshIdleMin", 120,         ; an idle page reloads this often (each reload is followed by a warm-up)
    ; Copilot takes 4-13 s to accept the FIRST message on a freshly loaded page (later ones: instantly).
    ; So each page sends this short message by itself once it has loaded, then starts a new chat.
    "WarmUp", 1,
    "WarmUpPrompt", "Connection check - please reply with just: OK",
    "PersonalDomains", "gmail.com, googlemail.com, outlook.com, hotmail.com, live.com, msn.com, passport.com, yahoo.com, ymail.com, rocketmail.com, icloud.com, me.com, mac.com, aol.com, proton.me, protonmail.com, gmx.com, gmx.net, mail.com, yandex.com, zoho.com",
    "AllowPersonal", 0,
    "ImageMaxMB", 20,              ; biggest image file a request may attach
    ; Memory guard (PoolMemAudit): the pool's whole browser engine is measured every MemAuditSec.
    "MemAuditSec", 30,
    "IdleLowMemSec", 60,           ; a hidden page idle this long is told to use little memory (WebView2 "low" level)
    "PageMaxMB", 400,              ; a page's own script memory over this (idle, not your window) = it's reloaded fresh
    "TotalMaxMB", 1500,            ; the whole engine over this = biggest idle page reloaded, idle spare pages closed
    "NoAppQuitSec", 60,            ; no app (Companion, Screen ask...) and no open window for this long = the pool closes
    "ChatW", 900,                  ; size of a 💬 Copilot window (remembered when you close one)
    "ChatH", 760,
    "WorkConfirmed", "")           ; "unknown" = the user confirmed an account we couldn't read is the work one

DetectHiddenWindows(true)
OnError(PoolOnError)

poolArgs := ""
for a in A_Args
    poolArgs .= " " a

; One copy only - a named mutex, so two copies started at the same moment can't both run (they did:
; two pools on one sign-in folder, every page twice, and a sign-out that couldn't delete the folder).
; /restart waits for the old copy to end (and ends it if it hangs).
poolMutex := PoolTakeMutex()
if (!poolMutex && InStr(poolArgs, "/restart")) {
    Loop 150 {                                  ; up to ~15 s
        Sleep(100)
        if (poolMutex := PoolTakeMutex())
            break
        if (A_Index = 80) {                     ; 8 s and the old copy is still there: end it
            try ProcessClose(WinGetPID(POOL_TITLE " ahk_class AutoHotkeyGUI"))
        }
    }
}
if !poolMutex {
    other := 0
    Loop 30 {                                   ; the other copy may still be building its window
        if (other := WinExist(POOL_TITLE " ahk_class AutoHotkeyGUI"))
            break
        Sleep(100)
    }
    if other {
        if InStr(poolArgs, "/signout")
            PoolSendTo(other, Map("t", "signout"))
        else if InStr(poolArgs, "/signin")
            PoolSendTo(other, Map("t", "signin"))
        else if !InStr(poolArgs, "/background")
            PoolSendTo(other, Map("t", "show"))
    }
    ExitApp()
}

PoolTakeMutex() {
    h := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", "Local\CaptionCompanion.CopilotPool", "Ptr")
    if (h && A_LastError = 183) {               ; ERROR_ALREADY_EXISTS: another copy holds it
        DllCall("CloseHandle", "Ptr", h)
        return 0
    }
    return h                                    ; held until this process ends
}

; ------------------------------------------------------------------------------
; State
; ------------------------------------------------------------------------------
env := 0                  ; WebView2 environment (browser engine + sign-in folder)
envError := ""
views := []               ; hidden Copilot views
viewSeq := 0
signinView := 0           ; the visible sign-in window, while open
reqs := Map()             ; request id -> request
queue := []               ; ids waiting for a view
convs := Map()            ; conversation name -> view
reserved := Map()         ; conversation name -> true: an app's OWN page, always kept loaded and ready ("reserve")
addFails := 0             ; pages that failed to open in a row (retried with a growing pause; 3 = new browser engine)
lastAddTry := 0
envFailedAt := 0
envRetry := false         ; the engine failed but trying again may help
poolMemMB := 0            ; the browser engine's memory at the last audit (all its processes)
poolStartedAt := A_TickCount
subs := Map()             ; app window -> true (gets "state" messages)
account := {email: "", tenant: "", how: "", known: false}
poolState := "starting"
poolReason := "starting the browser engine"
lastPublished := ""
jobSeq := 0
workerJs := ""
viewsShown := false

; ------------------------------------------------------------------------------
; Start
; ------------------------------------------------------------------------------
PoolTrimLog()
poolSites := PoolLoadSites()      ; id -> site (Map), only the ones allowed here
site := PoolPickSite()            ; the site in use (Map)
PoolWipeIfAsked()
PoolBuildGui()
OnMessage(0x4A, PoolOnCopyData)
OnExit(PoolOnExit)
if (InStr(poolArgs, "/show") || InStr(poolArgs, "/signin") || !InStr(poolArgs, "/background"))
    PoolShow()
PoolLog("started (" (A_PtrSize * 8) "-bit, version " APP_VERSION (POOL_DEV ? ", DEV MODE" : "") "), site: " PoolSiteName())
; after a restart the old copy's browser engine may still be closing on the same sign-in folder (a page
; opened on it at that moment gets "Operation aborted"): give it a moment
SetTimer(PoolStart, InStr(poolArgs, "/restart") ? -2000 : -50)
SetTimer(PoolHousekeep, 1000)
SetTimer(PoolMemAudit, Max(10, PoolNum("MemAuditSec")) * 1000)
SetTimer(PoolOwnerCheck, 5000)

PoolStart() {
    global workerJs
    if !IsSet(WebView2) {
        PoolEngineFailed("the WebView2 library is missing (app\lib\WebView2)", false)
        return
    }
    if !IsObject(site) {
        PoolEngineFailed("no chat site files found (app\chat-sites)", false)
        return
    }
    try {
        workerJs := FileRead(POOL_WORKER, "UTF-8")
    } catch as err {
        PoolEngineFailed("couldn't read " POOL_WORKER ": " err.Message, false)
        return
    }
    ; a browser engine left behind by an earlier pool (or Screen ask) that's gone: end it first - it
    ; holds memory, and one still closing on our sign-in folder makes new pages fail ("Operation aborted")
    freed := 0
    if (n := WvgSweepOrphans(&freed))
        PoolLog("ended " n " leftover built-in browser(s) of closed apps (" freed " MB)")
    if PoolMakeEngine()
        PoolTopUp()
    PoolUpdateState()
    if InStr(poolArgs, "/signout")
        SetTimer(PoolSignOut.Bind(false), -500)
    else if InStr(poolArgs, "/signin")
        PoolOpenSignIn()
}

; Starts the browser engine (on the current sign-in folder). False = failed (retried by PoolHousekeep).
PoolMakeEngine() {
    global env, envError, addFails
    try {
        sso := PoolNum("SingleSignOn")
        dir := PoolProfileDir()
        DirCreate(dir)
        env := WebView2.CreateEnvironmentAsync({ AllowSingleSignOnUsingOSPrimaryAccount: sso ? 1 : 0 }, dir).await(60000)
        envError := "", addFails := 0
        ver := ""
        try ver := env.BrowserVersionString
        PoolLog("browser engine " ver ", single sign-on " (sso ? "on" : "off"))
        return true
    } catch as err {
        PoolEngineFailed(err.Message, true)
        return false
    }
}

; retry: try again by itself in a moment (always, unless something is missing that a retry can't fix)
PoolEngineFailed(why, retry) {
    global env, envError, envFailedAt, envRetry
    env := 0
    envError := why
    envFailedAt := A_TickCount
    envRetry := retry
    PoolLog("ENGINE FAILED: " why (retry ? " - trying again in 15 s" : ""))
    PoolUpdateState()
}

; The pages should be: the "Views" setting + one page per reserved conversation (up to MaxViews)
PoolWantViews() => Min(Max(PoolNum("Views"), PoolNum("MaxViews")), Max(1, PoolNum("Views")) + reserved.Count)

; A page that failed to open is tried again after 2, 4, 8, 16, then every 30 s
PoolAddPause() => addFails ? Min(30000, 2000 * (2 ** (addFails - 1))) : 0

; ==============================================================================
; Views
; ==============================================================================
PoolAddView() {
    global viewSeq, addFails, lastAddTry
    lastAddTry := A_TickCount
    viewSeq += 1
    v := { id: viewSeq, gui: 0, ctrl: 0, wv: 0, state: "loading", host: "", onLogin: false, dead: false,
        jobId: "", reqId: "", conv: "", lastUse: A_TickCount, createdAt: A_TickCount, failedAt: 0, held: false, needWarm: false,
        reserved: false }
    if (env = 0)
        return 0
    try {
        v.gui := Gui("+ToolWindow +Owner" pg.Hwnd, PoolSiteName() " view " v.id)
        v.gui.OnEvent("Close", PoolChatClosed.Bind(v))     ; only while it's shown as your Copilot window
        v.gui.OnEvent("Size", PoolChatSized.Bind(v))
        PoolPlaceView(v)
        PoolInitView(v)
        views.Push(v)
        addFails := 0
        PoolLog("view " v.id " opened")
    } catch as err {
        ; (it was never shown: nothing to tidy but the window) - tried again after a pause (PoolHousekeep);
        ; 3 in a row = the browser engine itself is broken (e.g. it was closing): a new one is started
        addFails += 1
        PoolLog("view " v.id " FAILED to open: " err.Message " (" addFails " in a row - trying again in "
            Round(PoolAddPause() / 1000) " s)")
        try v.ctrl.Close()
        try v.gui.Destroy()
        if (addFails >= 3 && Mod(addFails, 3) = 0) {
            PoolLog("pages keep failing to open - starting a new browser engine")
            PoolMakeEngine()
        }
        PoolUpdateState()
        return 0
    }
    PoolEnsureReserved()
    PoolUpdateState()
    return v
}

; Creates the WebView in v.gui and loads Copilot (also used by the sign-in window)
PoolInitView(v, signin := false, url := "") {
    v.ctrl := env.CreateCoreWebView2ControllerAsync(v.gui.Hwnd).await(30000)
    v.ctrl.IsVisible := true             ; "visible" to the page even while its window is hidden
    v.wv := v.ctrl.CoreWebView2
    try v.wv.Settings.IsStatusBarEnabled := false
    try v.wv.Settings.AreDevToolsEnabled := POOL_DEV   ; F12 tools only in dev mode (to inspect a site's page)
    if !signin {
        try v.wv.Settings.AreDefaultScriptDialogsEnabled := false
        try v.wv.CallDevToolsProtocolMethodAsync("Emulation.setFocusEmulationEnabled", '{"enabled":true}').await(5000)
        v.wv.add_NewWindowRequested(PoolPopup.Bind(v))
    }
    v.wv.add_NavigationStarting(PoolNavStarting)
    v.wv.add_WebMessageReceived(PoolViewMessage.Bind(v))
    v.wv.add_NavigationCompleted(PoolViewNavDone.Bind(v))
    v.wv.add_ProcessFailed(PoolViewFailed.Bind(v))
    v.wv.AddScriptToExecuteOnDocumentCreatedAsync(PoolWorkerPrefix(v.id) workerJs).await(10000)
    v.wv.Navigate(url != "" ? url : PoolAddress())
}

PoolWorkerPrefix(id) {
    ; the page script gets the whole site description (selectors, how answers and new chats work)
    cfg := Map("id", id, "url", PoolAddress(), "hosts", PoolHosts(), "site", site,
        "account", PoolNoAccountCheck() ? "none" : "work", "sendWaitMs", PoolNum("SendWaitSec") * 1000)
    return "window.__lccPool=" Json.Stringify(cfg) ";`n"
}

PoolPlaceView(v) {
    if v.held                                   ; your Copilot window: leave it where it is
        return
    if viewsShown
        v.gui.Show("NoActivate x" (40 + 40 * v.id) " y" (40 + 40 * v.id) " w1100 h800")
    else
        v.gui.Show("Hide w1100 h800")
}

PoolCloseView(v) {
    v.dead := true
    try v.ctrl.Close()
    try v.gui.Destroy()
    for i, x in views
        if (x = v) {
            views.RemoveAt(i)
            break
        }
}

; Pages in the pool
PoolRegularCount() {
    n := 0
    for v in views
        if !v.dead
            n += 1
    return n
}

; A view whose page crashed or hung: its request fails, its conversation is lost, a new view replaces it
PoolReplaceView(v, why) {
    PoolLog("view " v.id " replaced: " why)
    if (v.reqId != "" && reqs.Has(v.reqId)) {
        r := reqs[v.reqId]
        PoolFinish(r, false, r.sent ? "failed" : "unsent", "the Copilot page stopped (" why ")")
    }
    if (v.conv != "")
        convs.Delete(v.conv)
    PoolCloseView(v)
    SetTimer(PoolTopUp, -2000)
}

; Keeps the number of views at the setting (plus the ones conversations need, up to MaxViews)
PoolTopUp() {
    if (env = 0 || envError != "")
        return
    Loop Max(0, PoolWantViews() - PoolRegularCount()) {   ; (stops at the first failure: retried after a pause)
        if !PoolAddView()
            break
    }
    PoolEnsureReserved()
    PoolDispatch()
}

; ==============================================================================
; Reserved conversations: an app's OWN page (e.g. Screen ask), always loaded and ready, never lent out.
; The app says {t:"reserve", conversation} (again now and then: a restarted pool forgets). Closing its
; window or "end" only starts a fresh chat on it; if its page dies, a new one takes its place.
; ==============================================================================
PoolReserve(conv) {
    if (conv = "")
        return
    if !reserved.Has(conv) {
        if (reserved.Count >= 4)                 ; a few apps at most: never let a bad caller eat every page
            return
        reserved[conv] := true
        PoolLog("conversation " conv " reserved (its own page, kept ready)")
    }
    PoolEnsureReserved()
}

; Gives every reserved conversation a page: a free one, else a new one (PoolTopUp / PoolHousekeep retry)
PoolEnsureReserved() {
    for conv in reserved {
        if (convs.Has(conv) && !convs[conv].dead) {
            convs[conv].reserved := true
            continue
        }
        if convs.Has(conv)
            convs.Delete(conv)
        v := PoolFreeView()
        if !IsObject(v) {                        ; a page still loading, not taken by anything
            for x in views
                if (!x.dead && !x.held && x.conv = "" && x.jobId = "" && x.state != "load-failed") {
                    v := x
                    break
                }
        }
        if !IsObject(v)
            continue                             ; PoolTopUp adds a page for it (PoolWantViews counts it)
        v.conv := conv, v.reserved := true
        convs[conv] := v
        PoolLog("view " v.id " is " conv "'s own page")
        DbgTrace("pool", PoolViewName(v) " reserved for " conv "   | pages: " PoolViewsSummary())
    }
}

; Links that would open a new window: hidden pages never open anything; in your 💬 window a web link
; opens in your normal browser (not inside the pool)
PoolPopup(v, sender, args) {
    uri := ""
    try uri := args.Uri
    try args.Handled := true
    if (v.held && RegExMatch(uri, "i)^https://"))
        SetTimer(() => Run(uri), -1)
}

; Pages only ever load over https (sign-in pages included); anything else is stopped
PoolNavStarting(sender, args) {
    try {
        uri := args.Uri
        if !RegExMatch(uri, "i)^(https://|about:blank)") {
            args.Cancel := true
            SetTimer(PoolLog.Bind("blocked a non-https page: " SubStr(uri, 1, 40)), -1)
        }
    }
}

; ==============================================================================
; A page shown as your own Copilot window (💬). Yours until you close it.
; ==============================================================================
; A window with a "conversation" name (e.g. one per helper) remembers its own place and size
; ([Window <name>] in copilot-pool.ini); others use the last place any window had ([ChatWindow]).
PoolShowChat(v, label, quiet := false) {     ; quiet: an app opened it by itself - never take the focus
    PoolMemLevel(v, 0)
    v.gui.Title := PoolSiteName() (label != "" ? " - " label : "") " (Caption Companion)"
    if v.held {                                  ; already open (the same helper again): bring it up, leave it where it is
        if quiet
            return
        try {
            if (WinGetMinMax("ahk_id " v.gui.Hwnd) = -1)
                WinRestore("ahk_id " v.gui.Hwnd)
        }
        v.gui.Show()
        try v.ctrl.Fill()
        return
    }
    held := 0
    for x in views
        if x.held
            held += 1
    v.held := true
    v.gui.Opt("-ToolWindow -Owner +Resize +MinSize360x300")
    sec := PoolChatSection(v)
    x := IniRead(POOL_INI, sec, "X", ""), y := IniRead(POOL_INI, sec, "Y", "")
    w := IniRead(POOL_INI, sec, "W", ""), h := IniRead(POOL_INI, sec, "H", "")
    off := 0
    if !(IsInteger(x) && IsInteger(y)) {         ; a window never placed before: near the last one, a bit offset
        x := IniRead(POOL_INI, "ChatWindow", "X", ""), y := IniRead(POOL_INI, "ChatWindow", "Y", "")
        off := 30 * held
    }
    if !(IsInteger(w) && IsInteger(h))
        w := PoolNum("ChatW"), h := PoolNum("ChatH")
    pos := ""
    if (IsInteger(x) && IsInteger(y) && PoolOnScreen(x + off, y + off))
        pos := "x" (x + off) " y" (y + off) " "
    v.gui.Show(pos "w" w " h" h (quiet ? " NoActivate" : ""))
    if quiet {                                   ; in front of the other windows, but your typing stays where it is:
        for after in [-1, -2]                    ; always-on-top for a moment, then not (SWP_NOMOVE|NOSIZE|NOACTIVATE)
            DllCall("SetWindowPos", "Ptr", v.gui.Hwnd, "Ptr", after, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
    }
    try v.ctrl.Fill()
    PoolLog("view " v.id " shown as a Copilot window" (v.conv != "" ? " (" v.conv ")" : ""))
    PoolEnsureSpare()
    PoolUpdateState()                            ; apps see which windows are open
}

PoolChatSection(v) => (v.conv != "" ? "Window " v.conv : "ChatWindow")

PoolChatSized(v, g, minMax, *) {
    if (v.held && minMax != -1)
        try v.ctrl.Fill()
}

PoolChatClosed(v, *) {
    if !v.held
        return
    try {                                       ; remember the size and place for next time
        if (WinGetMinMax("ahk_id " v.gui.Hwnd) = 0) {
            v.gui.GetPos(&x, &y)
            v.gui.GetClientPos(, , &w, &h)
            dpi := A_ScreenDPI / 96
            w := Round(w / dpi), h := Round(h / dpi)
            for sec in (v.conv != "" ? ["ChatWindow", PoolChatSection(v)] : ["ChatWindow"]) {
                IniWrite(x, POOL_INI, sec, "X")
                IniWrite(y, POOL_INI, sec, "Y")
                IniWrite(w, POOL_INI, sec, "W")
                IniWrite(h, POOL_INI, sec, "H")
            }
            PoolSet("ChatW", w)
            PoolSet("ChatH", h)
        }
    }
    v.held := false
    v.lastUse := A_TickCount
    v.gui.Opt("+ToolWindow +Owner" pg.Hwnd)
    if (v.conv != "" && v.reserved) {           ; an app's own page: it stays that app's, with a fresh chat
        PoolLog("view " v.id " window closed - stays " v.conv "'s own page")
    } else if (v.conv != "") {                  ; that window's conversation (its helper) ends with it
        PoolLog("view " v.id " window closed - conversation " v.conv " ended")
        convs.Delete(v.conv)
        v.conv := ""
    }
    v.convFresh := false
    if (v.jobId = "")                           ; a fresh chat, then back to the pool
        try v.wv.PostWebMessageAsString('{"t":"newchat"}')
    PoolLog("view " v.id " window closed - back in the pool")
    PoolUpdateState()                           ; apps see the window is gone
    SetTimer(PoolDispatch, -1)
    ; the window hides itself (default for Close)
}

PoolOnScreen(x, y) {
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        if (x + 100 >= l && x + 100 < r && y + 15 >= t && y + 15 < b)
            return true
    }
    return false
}

; ==============================================================================
; The sign-in window (visible Copilot page)
; ==============================================================================
PoolOpenSignIn(*) {
    global signinView
    if (env = 0) {
        PoolShow()
        return
    }
    if IsObject(signinView) {
        try signinView.gui.Show()
        return
    }
    v := { id: 0, gui: 0, ctrl: 0, wv: 0, state: "loading", host: "", onLogin: false, dead: false,
        jobId: "", reqId: "", conv: "", lastUse: A_TickCount, signin: true }
    try {
        v.gui := Gui("+Resize", "Sign in to " PoolSiteName() " - Caption Companion")
        v.gui.OnEvent("Size", (g, mm, *) => (mm != -1 && v.ctrl ? v.ctrl.Fill() : 0))
        v.gui.OnEvent("Close", (*) => PoolCloseSignIn())
        v.gui.Show("w1000 h760")
        signinView := v
        PoolInitView(v, true)
        PoolLog("sign-in window opened")
    } catch as err {
        PoolLog("sign-in window FAILED: " err.Message)
        PoolCloseSignIn()
    }
}

PoolCloseSignIn() {
    global signinView
    if !IsObject(signinView)
        return
    v := signinView
    signinView := 0
    try v.ctrl.Close()
    try v.gui.Destroy()
    if v.HasOwnProp("signout") {                 ; signed out at Microsoft: now forget it here too
        PoolLog("sign-out window closed - deleting the sign-in and restarting")
        PoolRestart("/show")
        return
    }
    ; pages that were waiting on the sign-in page load Copilot again
    for x in views
        if (x.state != "ready" && x.jobId = "")
            try x.wv.Navigate(PoolAddress())
}

; ==============================================================================
; Events from the pages (short: they run inside a COM callback)
; ==============================================================================
PoolViewMessage(v, sender, args) {
    raw := ""
    try {
        ; only Copilot's own pages may talk to the pool (a page elsewhere can't fake an account or a result)
        src := args.Source
        host := RegExMatch(src, "i)^https://([^/?#:]+)", &mm) ? StrLower(mm[1]) : ""
        if (host = "" || !PoolHostAllowed(host))
            return
        raw := args.TryGetWebMessageAsString()
    }
    if (raw != "")
        SetTimer(PoolOnViewMessage.Bind(v, raw), -1)
}

PoolOnViewMessage(v, raw) {
    try {
        m := Json.Parse(raw)
    } catch {
        return
    }
    if v.dead
        return
    isSignin := v.HasOwnProp("signin")
    switch m.Get("t", "") {
        case "hello":
            v.onLogin := false
            ; the page reloaded on purpose in the middle of a job (a site whose "new chat" is a page load, or
            ; that loads a new page when it sends): its script carries the job on - nothing is lost
            if (!isSignin && v.jobId != "" && m.Get("resume", "") = v.jobId) {
                DbgTrace("pool", PoolViewName(v) ": page reloaded during job " v.jobId " - the job carries on")
                return
            }
            if !isSignin
                v.needWarm := PoolWarmUpOn()                       ; a freshly loaded page: warm it up once ready
            if (!isSignin && v.jobId = "" && v.conv != "") {      ; the page reloaded: its chat is gone
                if (v.held || v.reserved) {               ; still your open window (e.g. a helper's) / an app's own page: it stays
                    v.convFresh := true                   ; that helper's, but the next prompt must be a full one
                    PoolLog("view " v.id ": " v.conv " window reloaded - its chat starts over")
                } else {
                    PoolLog("view " v.id ": conversation lost (page reloaded)")
                    convs.Delete(v.conv)
                    v.conv := ""
                }
            }
            if (!isSignin && v.reqId != "" && reqs.Has(v.reqId)) {
                r := reqs[v.reqId]
                PoolFinish(r, false, r.sent ? "failed" : "unsent", "the Copilot page reloaded")
                v.jobId := "", v.reqId := ""
            }
        case "state":
            prevState := v.state
            v.state := m.Get("state", "")
            if (v.state != prevState)
                DbgTrace("pool", PoolViewName(v) ": " prevState " -> " v.state "   | pages now: " PoolViewsSummary())
            if (v.state = "ready") {
                v.onLogin := false
                if (v.jobId != "" && !reqs.Has(v.reqId))     ; a cancelled job has finished
                    v.jobId := "", v.reqId := ""
                if (!isSignin && v.HasOwnProp("sawLogin") && v.sawLogin) {   ; signed in on this page: the others follow
                    v.sawLogin := false
                    SetTimer(PoolSignedInSomewhere.Bind(v), -1)
                }
            }
            if (isSignin && v.state = "ready" && !v.HasOwnProp("signout"))
                SetTimer(PoolSigninReady, -1500)
            PoolUpdateState()
            PoolDispatch()
        case "account":
            PoolSetAccount(m)
        case "log":
            d := m.Get("d", "")
            PoolLog("view " v.id ": " m.Get("m", "") ((d is String && d != "") ? " | " d : ""))
        case "trace":                                     ; the page's own step-by-step timings (no text)
            jid := m.Get("jobId", "")
            rq := (jid != "" && jid = v.jobId && reqs.Has(v.reqId)) ? " " reqs[v.reqId].logName : ""
            DbgTrace("page " v.id, (jid != "" ? "job " jid rq " " : "") "+" m.Get("ms", 0) " ms  " m.Get("step", "")
                "   [" m.Get("snap", "") "]")
        case "trusted":
            PoolDoTrusted(v, m)
        case "mem":                                       ; the page's own size (memory audit)
            v.heapMB := m.Get("heapMB", 0), v.nodes := m.Get("nodes", 0)
        case "images-get":                                ; the page is about to attach its job's images
            if (m.Get("jobId", "") != v.jobId || !reqs.Has(v.reqId))
                return
            list := [], rq := reqs[v.reqId]
            for im in (rq.HasOwnProp("images") ? rq.images : [])
                list.Push(Map("name", im.name, "mime", im.mime, "b64", im.b64))
            try v.wv.PostWebMessageAsString(Json.Stringify(Map("t", "images", "jobId", v.jobId, "list", list)))
        case "sent":
            if (m.Get("jobId", "") != v.jobId)                ; from a job that was replaced meanwhile
                return
            if reqs.Has(v.reqId) {
                r := reqs[v.reqId]
                r.sent := true
                r.status := "sent - waiting for the answer"
                r.sentAt := A_TickCount
                if (r.newChat && v.HasOwnProp("convFresh"))
                    v.convFresh := false                    ; the window's chat has its full prompt again
                DbgTrace("pool", "request " r.logName " is IN Copilot (" PoolViewName(v) "): " (A_TickCount - r.queuedAt) " ms after it arrived, "
                    (A_TickCount - r.startedAt) " ms after the page got it")
                PoolReply(r, Map("t", "sent", "id", r.id))
                PoolRefreshList()
            }
        case "chunk":
            if (m.Get("jobId", "") != v.jobId)
                return
            if reqs.Has(v.reqId) {
                r := reqs[v.reqId]
                if r.stream
                    PoolReply(r, Map("t", "chunk", "id", r.id, "text", m.Get("text", "")))
            }
        case "result":
            if (m.Get("jobId", "") != v.jobId)
                return
            rid := v.reqId
            v.jobId := "", v.reqId := ""
            v.lastUse := A_TickCount
            if !reqs.Has(rid)
                return
            r := reqs[rid]
            if ((r.conv != "" && v.conv = "") || (r.show && !v.held))   ; ended / window closed while it ran: clean the chat
                try v.wv.PostWebMessageAsString('{"t":"newchat"}')
            if m.Get("ok", 0) {
                PoolFinish(r, true, "", "", m.Get("text", ""), m.Get("markdown", ""), m.Get("ms", 0))
                PoolLog("request " r.logName " answered in " Round(m.Get("ms", 0) / 1000, 1) " s (" m.Get("how", "") ")")
            } else {
                err := m.Get("error", "")
                kind := m.Get("sent", 0) ? (InStr(err, "in time") ? "timeout" : "failed") : "unsent"
                PoolLog("request " r.logName " " kind ": " err)
                PoolFinish(r, false, kind, err)
            }
            PoolDispatch()
    }
}

PoolSigninReady() {
    if !IsObject(signinView)
        return
    why := ""
    if PoolAccountOk(&why) {
        PoolLog("signed in" (account.email != "" ? " (" PoolAccountKind() ")" : ""))
        PoolCloseSignIn()
    }
    PoolUpdateState()
}

PoolViewNavDone(v, sender, args) {
    try {
        src := sender.Source
        host := RegExMatch(src, "i)^\w+://([^/?#]+)", &mm) ? StrLower(mm[1]) : ""
        v.host := host
        if v.HasOwnProp("signin")                ; no address bar: the title shows which site you're on
        {
            if v.HasOwnProp("signout") {
                try v.gui.Title := "Signing out - " (host != "" ? host : "loading...") " - close this window when it says you're signed out"
                if (v.step = 1 && host != "") {      ; personal-account sign-out done: now the site's own sign-out
                    v.step := 2
                    SetTimer(() => v.wv.Navigate(PoolSiteGet("signOutUrl")), -1500)
                }
            } else {
                try v.gui.Title := "Sign in to " PoolSiteName() " - " (host != "" ? host : "loading...") " (Caption Companion)"
            }
        }
        if (host != "" && !PoolHostAllowed(host) && host != "about:blank") {
            if PoolIsSignInHost(host) {
                wasWorking := (v.state = "ready" || v.state = "busy" || v.state = "resetting")
                v.onLogin := true
                v.state := "signin"
                if !v.HasOwnProp("signin") {
                    v.sawLogin := true
                    ; a working page fell to the sign-in page (e.g. you signed out in a Copilot window):
                    ; the sign-in is shared, so every page follows
                    ; (only if it STAYS there: a page load can pass through the sign-in page for a moment)
                    if (wasWorking || poolState = "ready")
                        SetTimer(PoolSignedOutSomewhere.Bind(v), -5000)
                }
            }
        }
        if !args.IsSuccess {
            status := args.WebErrorStatus
            if (status != 14) {                          ; 14 = cancelled (normal during redirects)
                v.state := "load-failed"
                v.failedAt := A_TickCount
                SetTimer(PoolLog.Bind("view " v.id ": page failed to load (" host ", error " status ")"), -1)
            }
        }
        SetTimer(PoolUpdateState, -1)
    }
}

PoolViewFailed(v, sender, args) {
    kind := -1
    try kind := args.ProcessFailedKind
    ; 0 = the whole browser engine, 1 = this page's process exited, 2 = it hung
    if (v.HasOwnProp("signin") && kind != 0)
        SetTimer(PoolCloseSignIn, -1)
    else if (kind = 0)
        SetTimer(PoolEngineDied, -1)
    else if (kind = 1 || kind = 2)
        SetTimer(PoolReplaceView.Bind(v, kind = 1 ? "page process exited" : "page stopped responding"), -1)
    else
        SetTimer(PoolLog.Bind("view " v.id ": a helper process failed (kind " kind ")"), -1)
}

; ==============================================================================
; One sign-in for every page: signed out on one page = signed out on all; signed in on one = all
; (they share the sign-in folder, but a page that is already open keeps what it loaded until it reloads)
; ==============================================================================
PoolSignedOutSomewhere(src) {
    global account
    static last := 0
    if (src.dead || !src.onLogin)                ; it went back to Copilot by itself: not a sign-out
        return
    if (A_TickCount - last < 20000)              ; the other pages reloading land here too: once is enough
        return
    last := A_TickCount
    PoolLog(PoolViewName(src) " is on the sign-in page - signed out: every Copilot page reloads")
    account := {email: "", tenant: "", how: "", known: false}
    for x in views.Clone()
        if (!x.dead && x != src)
            try x.wv.Navigate(PoolAddress())     ; a running job fails cleanly when its page reloads
    PoolUpdateState()
}

PoolSignedInSomewhere(src) {
    PoolLog(PoolViewName(src) " signed in - pages still on the sign-in page reload")
    for x in views
        if (!x.dead && x != src && x.jobId = "" && x.state != "ready" && x.state != "busy" && x.state != "resetting")
            try x.wv.Navigate(PoolAddress())
    PoolUpdateState()
}

PoolEngineDied() {
    PoolLog("BROWSER ENGINE STOPPED - restarting the pool")
    PoolRestart()
}

; Trusted input (DevTools protocol): typing or Enter that works without window focus
PoolDoTrusted(v, m) {
    ok := 0
    op := m.Get("op", "")
    try {
        if (op = "insert") {
            v.wv.CallDevToolsProtocolMethodAsync("Input.insertText", Json.Stringify(Map("text", m.Get("text", "")))).await(4000)
            ok := 1
        } else if (op = "enter") {
            for p in ['{"type":"rawKeyDown","key":"Enter","code":"Enter","windowsVirtualKeyCode":13,"nativeVirtualKeyCode":13}'
                    , '{"type":"char","key":"Enter","code":"Enter","text":"\r","unmodifiedText":"\r","windowsVirtualKeyCode":13,"nativeVirtualKeyCode":13}'
                    , '{"type":"keyUp","key":"Enter","code":"Enter","windowsVirtualKeyCode":13,"nativeVirtualKeyCode":13}']
                v.wv.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", p).await(4000)
            ok := 1
        } else if (op = "backspace") {                  ; clears the selected text (the page selects all first)
            for p in ['{"type":"rawKeyDown","key":"Backspace","code":"Backspace","windowsVirtualKeyCode":8,"nativeVirtualKeyCode":8}'
                    , '{"type":"keyUp","key":"Backspace","code":"Backspace","windowsVirtualKeyCode":8,"nativeVirtualKeyCode":8}']
                v.wv.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", p).await(4000)
            ok := 1
        } else if (op = "files") {                      ; puts image n of the job into the file input the page marked
            idx := IsInteger(m.Get("text", "")) ? Integer(m.Get("text")) + 1 : 0
            r := reqs.Has(v.reqId) ? reqs[v.reqId] : 0
            if (IsObject(r) && r.HasOwnProp("images") && idx >= 1 && idx <= r.images.Length && FileExist(r.images[idx].path)) {
                doc := Json.Parse(v.wv.CallDevToolsProtocolMethodAsync("DOM.getDocument", '{"depth":0}').await(4000))
                found := Json.Parse(v.wv.CallDevToolsProtocolMethodAsync("DOM.querySelector",
                    Json.Stringify(Map("nodeId", doc["root"]["nodeId"], "selector", "input[data-lcc-files]"))).await(4000))
                if found.Get("nodeId", 0) {
                    v.wv.CallDevToolsProtocolMethodAsync("DOM.setFileInputFiles",
                        Json.Stringify(Map("files", [r.images[idx].path], "nodeId", found["nodeId"]))).await(8000)
                    ok := 1
                }
            }
        }
    } catch as err {
        PoolLog("view " v.id ": trusted " op " failed: " err.Message)
    }
    try v.wv.PostWebMessageAsString('{"t":"trusted-done","reqId":' m.Get("reqId", 0) ',"ok":' ok '}')
}

; ==============================================================================
; Account: work only (unless personal is allowed for testing)
; ==============================================================================
PoolSetAccount(m) {
    global account
    email := Trim(m.Get("email", ""))
    tenant := Trim(m.Get("tenant", ""))
    ; an empty report never overwrites a known account (another page may just not show it)
    if (email = "" && account.email != "")
        return
    changed := (email != account.email || tenant != account.tenant || !account.known)
    account := {email: email, tenant: tenant, how: m.Get("how", ""), known: true}
    if changed {
        PoolLog("account: " (email = "" ? "could not be read" : PoolAccountKind() " (" PoolMaskEmail(email) ", found in " account.how ")"))
        PoolUpdateState()
        if IsObject(signinView)
            SetTimer(PoolSigninReady, -1500)
    }
}

; "work" | "personal" | "unknown" (signed in, but no email found) | "" (not known yet)
PoolAccountKind() {
    if !account.known
        return ""
    if (account.tenant = POOL_CONSUMER_TENANT)
        return "personal"
    e := account.email
    if (e = "")
        return "unknown"
    domain := StrLower(SubStr(e, InStr(e, "@") + 1))
    for d in StrSplit(PoolSetting("PersonalDomains"), ",", " `t")
        if (d != "" && domain = StrLower(d))
            return "personal"
    return "work"
}

PoolAccountOk(&why) {
    why := ""
    if PoolNoAccountCheck()                       ; a dev-only test site with no accounts (dev mode only)
        return true
    kind := PoolAccountKind()
    if (kind != "" && PoolNum("AllowPersonal"))  ; testing switch: any signed-in account
        return true
    switch kind {
        case "work":
            return true
        case "personal":
            why := "signed in with a personal account (" account.email "). Sign out, then sign in with your work account."
            return false
        case "unknown":
            if (PoolSetting("WorkConfirmed") = "unknown")
                return true
            why := "couldn't tell which account is signed in. If it's your work account, click 'It's my work account'."
            return false
        default:
            why := "checking which account is signed in..."
            return false
    }
}

PoolMaskEmail(e) => RegExReplace(e, "^(.).*?(@.*)$", "$1***$2")

; ==============================================================================
; Requests
; ==============================================================================
PoolNewRequest(m, hwnd) {
    global jobSeq
    jobSeq += 1
    r := { id: m.Get("id", "r" jobSeq), hwnd: hwnd, prompt: m.Get("prompt", ""), label: m.Get("label", ""),
        conv: m.Get("conversation", ""), newChat: m.Get("newChat", 0) ? true : false, stream: m.Get("stream", 0) ? true : false,
        show: m.Get("show", 0) ? true : false,
        orNew: m.Get("orNew", 0) ? true : false,     ; a follow-up whose conversation is gone may start a new one (it carries the full prompt)
        respectDraft: m.Get("respectDraft", 0) ? true : false,   ; an automatic prompt: never replaces text you typed in the box
        quiet: m.Get("quiet", 0) ? true : false,   ; show: the window opens without taking the focus (an app opened it by itself)
        queuedAt: A_TickCount, startedAt: 0, sent: false, status: "waiting", view: 0, logName: "#" jobSeq, warm: false,
        tick: IsInteger(m.Get("tick", 0)) ? m.Get("tick", 0) : 0, waitWhy: "", sentAt: 0,
        imgPaths: (m.Get("images", "") is Array) ? m.Get("images") : [], images: [], imgBytes: 0 }
    if (r.conv = "")
        r.newChat := true
    return r
}

; Reads a request's images (from APP_IMAGE_INBOX only - no other file can be sent this way) into memory.
; Only sizes ever go to the log.
PoolLoadImages(r, &why) {
    spec := PoolSiteGet("images", "")
    if !(spec is Map) {
        why := PoolSiteName() " can't take images"
        return false
    }
    maxN := spec.Get("max", 4)
    if (r.imgPaths.Length > maxN) {
        why := "too many images (" r.imgPaths.Length " - " PoolSiteName() " takes " maxN ")"
        return false
    }
    inbox := StrLower(RTrim(PoolFullPath(APP_IMAGE_INBOX), "\")) "\"
    for p in r.imgPaths {
        full := (p is String) ? PoolFullPath(p) : ""
        if (full = "" || SubStr(StrLower(full), 1, StrLen(inbox)) != inbox || InStr(SubStr(full, StrLen(inbox) + 1), "\")) {
            why := "an image that isn't in the pool's image folder was refused"
            return false
        }
        SplitPath(full, &name, , &ext)
        if !RegExMatch(ext, "i)^(png|jpe?g)$") {
            why := "only PNG and JPEG images can be sent"
            return false
        }
        if !FileExist(full) {
            why := "an image file is missing"
            return false
        }
        size := FileGetSize(full)
        if (size = 0 || size > PoolNum("ImageMaxMB") * 1048576) {
            why := "an image is empty or bigger than " PoolNum("ImageMaxMB") " MB"
            return false
        }
        r.images.Push({path: full, name: name, mime: (StrLower(ext) = "png" ? "image/png" : "image/jpeg"),
            b64: PoolB64(FileRead(full, "RAW"))})
        r.imgBytes += size
    }
    return true
}

PoolFullPath(p) {
    n := DllCall("GetFullPathNameW", "WStr", p, "UInt", 0, "Ptr", 0, "Ptr", 0, "UInt")
    if !n
        return ""
    buf := Buffer(n * 2 + 2, 0)
    DllCall("GetFullPathNameW", "WStr", p, "UInt", n + 1, "Ptr", buf, "Ptr", 0, "UInt")
    return StrGet(buf, "UTF-16")
}

PoolB64(buf) {
    n := 0
    DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", 0, "UInt*", &n)   ; BASE64 | NOCRLF
    out := Buffer(n * 2, 0)
    DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", out, "UInt*", &n)
    return StrGet(out, n, "UTF-16")
}

PoolAsk(r) {
    if (Trim(r.prompt, " `t`r`n") = "") {
        PoolFinish(r, false, "unsent", "the prompt is empty", , , , false)
        return
    }
    if r.imgPaths.Length {
        why := ""
        if !PoolLoadImages(r, &why) {
            PoolLog("request " r.logName " refused: " why)
            PoolFinish(r, false, "unsent", why, , , , false)
            return
        }
        PoolLog("request " r.logName ": " r.images.Length " image(s), " Round(r.imgBytes / 1024) " KB")
    }
    reqs[r.id] := r
    if (poolState = "off" || (!r.show && (poolState = "signin" || poolState = "account"))) {
        PoolFinish(r, false, poolState, poolReason)
        return
    }
    ; a 💬 request waits for you: sign in (or fix the account), then it runs by itself
    if (r.show && poolState = "signin")
        SetTimer(PoolOpenSignIn, -1)
    else if (r.show && poolState = "account")
        PoolShow()
    queue.Push(r.id)
    PoolReply(r, Map("t", "queued", "id", r.id, "position", queue.Length))
    PoolLog("request " r.logName " queued" (r.conv != "" ? " (conversation" (r.newChat ? ", new" : ", follow-up") ")" : ""))
    DbgTrace("pool", "request " r.logName " = Companion ask " r.id " '" r.label "'"
        (r.show ? " (💬 window)" : "") (r.newChat ? ", new chat" : ", follow-up") ", " StrLen(r.prompt) " chars, arrived "
        (r.tick ? A_TickCount - r.tick : "?") " ms after the Companion sent it; pool " poolState
        ", queue " queue.Length "   | pages: " PoolViewsSummary())
    PoolRefreshList()
    PoolDispatch()
}

PoolDispatch() {
    if (poolState != "ready") {
        for id in queue                          ; trace: why these requests wait (once per reason)
            if reqs.Has(id)
                PoolWaitWhy(reqs[id], "the pool is " poolState " (" poolReason ")")
        return
    }
    i := 1
    while (i <= queue.Length) {
        id := queue[i]
        if !reqs.Has(id) {
            queue.RemoveAt(i)
            continue
        }
        r := reqs[id]
        lost := false
        v := PoolPickView(r, &lost)
        if lost {
            queue.RemoveAt(i)
            PoolFinish(r, false, "lost", "that conversation is no longer open - send the full context again")
            continue
        }
        if !IsObject(v) {
            if ((r.conv = "" || !convs.Has(r.conv)) && PoolNoRoom()) {   ; every page is open as your window, and no more allowed
                queue.RemoveAt(i)
                PoolFinish(r, false, "busy", "every Copilot page is open in a window (" PoolRegularCount() " of " PoolNum("MaxViews") ") - close one and try again")
                continue
            }
            PoolWaitWhy(r, (r.conv != "" && convs.Has(r.conv)) ? "its Copilot window is still busy (" convs[r.conv].state
                (convs[r.conv].jobId != "" ? ", running " convs[r.conv].jobId : "") ")" : "no free Copilot page")
            i += 1
            continue
        }
        queue.RemoveAt(i)
        PoolRun(r, v)
    }
    PoolRefreshList()
}

; Trace: why a request is still waiting (written when the reason changes) - with every page's state
PoolWaitWhy(r, why) {
    if (r.waitWhy == why)
        return
    r.waitWhy := why
    DbgTrace("pool", "request " r.logName " waits " (A_TickCount - r.queuedAt) " ms so far: " why "   | pages: " PoolViewsSummary())
}

PoolViewName(v) {
    if v.HasOwnProp("signin")                    ; the sign-in / sign-out window (no pool fields)
        return "sign-in window"
    return "page " v.id (v.held ? " (💬 window" (v.conv != "" ? " " v.conv : "") ")" : "")
        . (v.reserved ? " [" v.conv "'s own]" : "")
}

; One line describing every page: "1 ready, 2 busy j12(#11) 💬window ..."
PoolViewsSummary() {
    s := ""
    for v in views {
        if v.dead
            continue
        d := v.id " " v.state
        if (v.jobId != "")
            d .= " " v.jobId (reqs.Has(v.reqId) ? "(" reqs[v.reqId].logName (reqs[v.reqId].sent ? " sent" : "") ")" : "")
        if v.held
            d .= " 💬window"
        if v.needWarm
            d .= " cold"
        s .= (s = "" ? "" : ", ") d
    }
    return s = "" ? "(none)" : s
}

PoolPickView(r, &lost) {
    lost := false
    if (r.conv != "") {
        if convs.Has(r.conv) {
            v := convs[r.conv]
            if !v.dead {
                if (!r.newChat && v.HasOwnProp("convFresh") && v.convFresh) {   ; its chat started over (page reloaded)
                    if r.orNew
                        r.newChat := true                 ; a full prompt: fine, it starts the chat again
                    else {
                        lost := true                      ; a follow-up alone would lack the context
                        return 0
                    }
                }
                if (v.state = "ready" && v.jobId = "")
                    return v
                ; only warming up (e.g. an app's own page): the real prompt replaces the warm-up (PoolRun)
                if (v.jobId != "" && reqs.Has(v.reqId) && reqs[v.reqId].warm)
                    return v
                return 0
            }
            convs.Delete(r.conv)
        }
        if (!r.newChat && r.orNew)                ; its window was closed meanwhile: start it again
            r.newChat := true
        if !r.newChat {
            lost := true
            return 0
        }
        v := PoolFreeView()
        if !IsObject(v)
            v := PoolWarmingView()
        if IsObject(v) {
            convs[r.conv] := v
            v.conv := r.conv
            PoolEnsureSpare()
            return v
        }
        PoolEnsureSpare()
        return 0
    }
    v := PoolFreeView()
    if IsObject(v)
        return v
    PoolEnsureSpare()
    return PoolWarmingView()
}

; None free: a page that is only warming up gives way (PoolRun replaces its warm-up)
PoolWarmingView() {
    for v in views
        if (!v.dead && !v.held && v.conv = "" && v.jobId != "" && reqs.Has(v.reqId) && reqs[v.reqId].warm)
            return v
    return 0
}

; A ready regular view with no job, no conversation, and not open as your window
PoolFreeView() {
    for v in views
        if (!v.dead && !v.held && v.state = "ready" && v.jobId = "" && v.conv = "")
            return v
    return 0
}

; True when every regular page is open as your window (or in a conversation) and no more may be opened
PoolNoRoom() {
    if (PoolRegularCount() < Max(PoolNum("Views"), PoolNum("MaxViews")))
        return false
    for v in views
        if (!v.dead && !v.held && v.conv = "")
            return false                        ; free, loading or busy: it will be free again
    return true
}

; Opens one more regular view (up to MaxViews) when none is free or on its way
PoolEnsureSpare() {
    for v in views
        if (!v.dead && !v.held && v.jobId = "" && v.conv = "")
            return                              ; free, or still loading
    if (PoolRegularCount() < Max(PoolNum("Views"), PoolNum("MaxViews")))
        SetTimer(PoolAddView, -1)
}

PoolRun(r, v) {
    global jobSeq
    preempt := (v.jobId != "")                   ; the page is only warming up: that stops and this prompt goes now
    if (preempt && reqs.Has(v.reqId)) {
        old := reqs[v.reqId]
        PoolLog("request " old.logName " replaced by " r.logName " on view " v.id (old.sent ? " (its answer was stopped)" : ""))
        PoolFinish(old, false, "replaced", old.sent ? "a newer prompt replaced it (its answer was stopped)"
            : "a newer prompt replaced it before it was sent")
    }
    jobSeq += 1
    v.jobId := "j" jobSeq
    v.reqId := r.id
    v.lastUse := A_TickCount
    r.view := v
    r.startedAt := A_TickCount
    r.status := "typing"
    job := Map("t", "job", "jobId", v.jobId, "prompt", r.prompt, "newChat", r.newChat ? 1 : 0,
        "keep", (!r.warm && (r.conv != "" || r.show)) ? 1 : 0, "stream", r.stream ? 1 : 0,
        "timeoutMs", PoolNum("AnswerTimeoutSec") * 1000,
        "scroll", (v.held && !r.warm) ? 1 : 0,          ; your 💬 window follows the newest answer
        "respectDraft", (r.HasOwnProp("respectDraft") && r.respectDraft) ? 1 : 0,
        "images", r.HasOwnProp("images") ? r.images.Length : 0,   ; the page asks for them ("images-get")
        "preempt", preempt ? 1 : 0)
    PoolMemLevel(v, 0)                           ; working: full speed
    try {
        v.wv.PostWebMessageAsString(Json.Stringify(job))
        PoolLog("request " r.logName " -> view " v.id (r.show ? " (shown as a window)" : "") (preempt ? " (replacing)" : ""))
        DbgTrace("pool", "request " r.logName " -> " PoolViewName(v) " after waiting " (A_TickCount - r.queuedAt) " ms"
            (preempt ? " (REPLACING the page's running job)" : "") (r.warm ? " (warm-up)" : "") "   | pages: " PoolViewsSummary())
        if r.show
            PoolShowChat(v, r.label, r.HasOwnProp("quiet") && r.quiet)   ; you watch Copilot write the answer
    } catch as err {
        v.jobId := "", v.reqId := ""
        PoolFinish(r, false, "unsent", "couldn't reach the Copilot page: " err.Message)
    }
}

; Ends a request: tells the app (or the Test box) and forgets it
PoolFinish(r, ok, kind := "", why := "", text := "", markdown := "", ms := 0, known := true) {
    DbgTrace("pool", "request " r.logName " '" r.label "' FINISHED: " (ok ? "answered, " StrLen(text) " chars" : kind " - " why)
        ", total " (A_TickCount - r.queuedAt) " ms" (r.sentAt ? ", answer took " (A_TickCount - r.sentAt) " ms after it went in" : ", never went in"))
    if known && reqs.Has(r.id)
        reqs.Delete(r.id)
    for i, id in queue
        if (id = r.id) {
            queue.RemoveAt(i)
            break
        }
    if (r.hwnd = 0) {                            ; the Test box in this window
        try {
            pg["TestAnswer"].Value := ok ? text : "(not answered: " kind " - " why ")"
        }
    } else {
        PoolReply(r, Map("t", "done", "id", r.id, "ok", ok ? 1 : 0, "kind", kind, "text", text,
            "markdown", markdown, "error", why, "ms", ms ? ms : A_TickCount - r.queuedAt))
    }
    PoolRefreshList()
}

; Copilot is slow (4-13 s) to accept the first message on a freshly loaded page and instant after that,
; so a new page sends a short message of its own first. Any real prompt replaces it right away.
PoolWarm(v) {
    global jobSeq
    v.needWarm := false
    jobSeq += 1
    r := { id: "warm" jobSeq, hwnd: -1, prompt: PoolSetting("WarmUpPrompt"), label: "warm-up", conv: "",
        newChat: true, stream: false, show: false, queuedAt: A_TickCount, startedAt: 0, sent: false,
        status: "warming up", view: 0, logName: "warm-up #" jobSeq, warm: true, tick: 0, waitWhy: "", sentAt: 0 }
    reqs[r.id] := r
    PoolRun(r, v)
}

PoolEndConversation(conv) {
    if !convs.Has(conv)
        return
    v := convs[conv]
    if v.reserved {                              ; an app's own page: only a fresh chat, it stays theirs
        if (v.jobId = "" && !v.held)
            try v.wv.PostWebMessageAsString('{"t":"newchat"}')
        return
    }
    convs.Delete(conv)
    v.conv := ""
    if (v.jobId = "")
        try v.wv.PostWebMessageAsString('{"t":"newchat"}')
    PoolLog("conversation ended, view " v.id " is free again")
    PoolDispatch()
}

; Every second: timeouts, idle conversations, refreshes, the list
PoolHousekeep() {
    now := A_TickCount
    ; requests that waited too long for a view never reached Copilot
    for id in queue.Clone() {
        if !reqs.Has(id)
            continue
        r := reqs[id]
        ; a follow-up waits for its own conversation's previous answer; a 💬 request waits while you
        ; sign in; others only briefly
        wait := (r.conv != "" && convs.Has(r.conv)) ? PoolNum("AnswerTimeoutSec") + 60
            : (r.show && poolState != "ready") ? PoolNum("SignInWaitSec")
            : PoolNum("QueueWaitSec")
        if (now - r.queuedAt > wait * 1000)
            PoolFinish(r, false, poolState = "ready" ? "busy" : poolState, "no Copilot page was free in time")
    }
    ; safety net for a page that never answers
    limit := (PoolNum("AnswerTimeoutSec") + 3 * PoolNum("SendWaitSec") + 60) * 1000
    for v in views.Clone()
        if (v.jobId != "" && reqs.Has(v.reqId) && now - reqs[v.reqId].startedAt > limit)
            PoolReplaceView(v, "no reply from the page")
    ; idle conversations are released, idle views refreshed, pages that failed to load retried
    for v in views {
        if v.dead || v.jobId != "" || v.held      ; your open Copilot windows are never touched
            continue
        if (v.conv != "" && !v.reserved && now - v.lastUse > PoolNum("ConversationIdleMin") * 60000)
            PoolEndConversation(v.conv)
        else if ((v.conv = "" || v.reserved) && v.state = "ready" && now - v.lastUse > PoolNum("RefreshIdleMin") * 60000) {
            v.lastUse := now
            DbgTrace("pool", PoolViewName(v) ": idle " PoolNum("RefreshIdleMin") " min - reloading it (it will warm up again)")
            try {
                v.wv.Navigate(PoolAddress())
            }
        } else if (v.state = "load-failed" && now - v.failedAt > 30000) {
            v.failedAt := now
            try v.wv.Navigate(PoolAddress())
        }
    }
    ; extra views opened for conversations close again when idle
    want := PoolWantViews()
    if (PoolRegularCount() > want)
        for v in views.Clone()
            if (PoolRegularCount() > want && !v.held && v.jobId = "" && v.conv = "" && now - v.lastUse > 300000) {
                PoolLog("view " v.id " closed (not needed)")
                PoolCloseView(v)
            }
    ; never stuck without pages: a broken browser engine is started again, missing pages (the "Views"
    ; setting + reserved ones) are opened again, after a pause that grows while they keep failing
    if (env = 0 && envError != "" && envRetry && now - envFailedAt > 15000) {
        PoolLog("starting the browser engine again")
        if PoolMakeEngine()
            PoolTopUp()
        PoolUpdateState()
    } else if (env != 0 && PoolRegularCount() < PoolWantViews() && now - lastAddTry > Max(1500, PoolAddPause())) {
        PoolTopUp()
    } else if reserved.Count {
        PoolEnsureReserved()
    }
    if (queue.Length && poolState = "ready")
        PoolDispatch()
    ; freshly loaded pages send one short warm-up message (one page per second), so real prompts go at once
    ; (an app's own reserved page too, while it isn't open as a window)
    if (poolState = "ready" && PoolWarmUpOn())
        for v in views
            if (!v.dead && v.needWarm && !v.held && v.state = "ready" && v.jobId = "" && (v.conv = "" || v.reserved)) {
                PoolWarm(v)
                break
            }
    if WinActive("ahk_id " pg.Hwnd)
        PoolRefreshList()
}

; ==============================================================================
; Overall state, sent to the apps whenever it changes
; ==============================================================================
PoolUpdateState(*) {
    global poolState, poolReason
    ready := 0, free := 0, login := false
    for v in views {
        if v.dead
            continue
        if (v.state = "ready" || v.state = "busy" || v.state = "resetting") {   ; loaded and working
            ready += 1
            if (v.state = "ready" && v.jobId = "" && v.conv = "" && !v.held)
                free += 1
        }
        if v.onLogin
            login := true
    }
    if IsObject(signinView) && signinView.onLogin
        login := true
    why := ""
    if (envError != "" && envRetry)
        s := "starting", r := "the browser engine failed (" envError ") - trying again"
    else if (envError != "")
        s := "off", r := "Copilot pool couldn't start: " envError
    else if (env = 0)
        s := "starting", r := "starting the browser engine"
    else if (ready = 0 && login)
        s := "signin", r := "Copilot needs you to sign in (Copilot pool window > Sign in)"
    else if (ready = 0)
        s := "starting", r := "loading Copilot"
    else if !PoolAccountOk(&why)
        s := (PoolAccountKind() = "" ? "starting" : "account"), r := why
    else
        s := "ready", r := ready " Copilot page(s) open"
    poolState := s
    poolReason := r
    windows := []                                ; conversations open as windows (e.g. a helper's 💬 window)
    for v in views
        if (!v.dead && v.held && v.conv != "")
            windows.Push(v.conv)
    msg := Map("t", "state", "state", s, "reason", r, "views", views.Length, "ready", ready, "free", free,
        "queued", queue.Length, "account", account.email = "" ? "" : PoolMaskEmail(account.email), "accountKind", PoolAccountKind(),
        "windows", windows)
    sig := Json.Stringify(msg)
    if (sig != lastPublished) {
        PoolPublish(msg)
        PoolPaintState()
        if (s = "signin" && PoolShowWaiting())       ; a 💬 request is waiting: show the sign-in
            SetTimer(PoolOpenSignIn, -1)
        else if (s = "account" && PoolShowWaiting())
            PoolShow()
        if (s != "starting")
            PoolLog("state: " s " - " r)
    }
    return s
}

; Is a 💬 (shown) request waiting for a page?
PoolShowWaiting() {
    for id in queue
        if (reqs.Has(id) && reqs[id].show)
            return true
    return false
}

PoolPublish(msg) {
    global lastPublished
    lastPublished := Json.Stringify(msg)
    for hwnd in subs.Clone()
        if !PoolSendTo(hwnd, msg)
            subs.Delete(hwnd)
}

PoolReply(r, msg) {
    if (r.hwnd > 0)                              ; 0 = the Test box, -1 = a warm-up (nobody to tell)
        PoolSendTo(r.hwnd, msg)
}

; ==============================================================================
; Messages from apps
; ==============================================================================
PoolOnCopyData(wParam, lParam, msg, hwnd) {
    if (!IsSet(pg) || !IsObject(pg) || hwnd != pg.Hwnd)    ; (a message during start-up or exit)
        return
    try {
        if (NumGet(lParam, 0, "UPtr") != POOL_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(PoolHandle.Bind(text), -1)          ; answer the sender right away
    return true
}

PoolHandle(text) {
    try {
        m := Json.Parse(text)
    } catch {
        return
    }
    if !(m is Map)
        return
    hwnd := m.Get("hwnd", 0)
    if (IsInteger(hwnd) && hwnd)
        subs[hwnd] := true
    switch m.Get("t", "") {
        case "ask":
            PoolAsk(PoolNewRequest(m, IsInteger(hwnd) ? hwnd : 0))
        case "cancel":
            PoolCancel(m.Get("id", ""))
        case "end":
            PoolEndConversation(m.Get("conversation", ""))
        case "reserve":                              ; {conversation}: keep a page of its own, always ready
            PoolReserve(Trim(m.Get("conversation", "")))
        case "status":
            PoolPublish(Json.Parse(lastPublished != "" ? lastPublished : '{"t":"state","state":"starting"}'))
        case "show":
            PoolShow()
        case "signin":
            PoolShow()
            PoolOpenSignIn()
        case "signout":
            PoolSignOut(true)
        case "quit":
            ExitApp()
    }
}

PoolCancel(id) {
    if !reqs.Has(id)
        return
    r := reqs[id]
    if (IsObject(r.view) && r.view.jobId != "" && r.view.reqId = id)
        try r.view.wv.PostWebMessageAsString(Json.Stringify(Map("t", "abort", "jobId", r.view.jobId)))
    PoolLog("request " r.logName " cancelled")
    PoolFinish(r, false, r.sent || IsObject(r.view) ? "cancelled" : "unsent", "cancelled")
}

PoolSendTo(hwnd, obj) {
    msg := Json.Stringify(obj)
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", POOL_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(0x4A, 0, cds, , Integer(hwnd), , , , 2000)    ; a plain handle: works for hidden windows too
        return true
    }
    return false
}

; ==============================================================================
; The pool window
; ==============================================================================
PoolBuildGui() {
    global pg
    pg := Gui("+MinimizeBox", POOL_TITLE)
    pg.SetFont("s10", "Segoe UI")
    pg.Add("Text", "xm w470 vState", "Copilot pool: starting...")
    pg.SetFont("s9")
    if (poolSites.Count > 1) {                    ; a choice only exists in dev mode (dev-only test sites)
        names := [], pick := 1
        for id, s in poolSites {
            names.Push(s.Get("name", id))
            if (IsObject(site) && id = site["id"])
                pick := names.Length
        }
        pg.Add("Text", "xm y+6 h20 +0x200", "Chat site" (POOL_DEV ? " (dev mode)" : "") ":")
        pg.Add("DropDownList", "x+6 yp w300 vSite Choose" pick, names).OnEvent("Change", PoolSiteChanged)
    }
    pg.Add("Text", "xm w470 h32 vReason", "")
    pg.Add("Text", "xm w470 vAccount", "Account: not known yet")
    pg.Add("Button", "xm w120 h30", "Sign in...").OnEvent("Click", PoolOpenSignIn)
    pg.Add("Button", "x+8 w170 h30 vBtnConfirm Hidden", "It's my work account").OnEvent("Click", PoolConfirmWork)
    pg.Add("Button", "x+8 w150 h30", "Sign out and restart").OnEvent("Click", (*) => PoolSignOut(true))
    pg.Add("CheckBox", "xm y+10 vAllowPersonal" (PoolNum("AllowPersonal") ? " Checked" : ""),
        "Allow personal accounts (testing only - never for customer calls)").OnEvent("Click", PoolAllowPersonalClicked)
    pg.Add("Text", "xm y+10", "Copilot pages kept ready:")
    pg.Add("Edit", "x+6 yp-3 w45 Number vViews", PoolNum("Views"))
    pg.Add("UpDown", "Range1-6", PoolNum("Views")).OnEvent("Change", PoolViewsChanged)
    pg.Add("Text", "x+12 yp+3 w220 vViewInfo", "")
    pg.Add("ListView", "xm y+10 w470 h110 -Multi vList", ["Request", "Status", "Time"])
    pg["List"].ModifyCol(1, 200), pg["List"].ModifyCol(2, 200), pg["List"].ModifyCol(3, 50)
    pg.Add("Button", "xm w150 h28", "Cancel selected").OnEvent("Click", PoolCancelSelected)
    pg.Add("Text", "xm y+12", "Test - sends this to Copilot and shows the answer:")
    pg.Add("Edit", "xm w380 h28 vTestPrompt", "Reply with only the word OK.")
    pg.Add("Button", "x+8 w82 h28", "Send").OnEvent("Click", PoolTestSend)
    pg.Add("Edit", "xm w470 h70 ReadOnly vTestAnswer", "")
    pg.Add("Button", "xm w110 h28", "Copy log").OnEvent("Click", PoolCopyLog)
    pg.Add("Button", "x+8 w110 h28", "Settings file").OnEvent("Click", PoolOpenSettings)
    pg.Add("Button", "x+8 w120 h28 vBtnViews", "Show the pages").OnEvent("Click", PoolToggleViews)
    pg.Add("Button", "x+8 w106 h28", "Restart pool").OnEvent("Click", (*) => PoolRestart())
    pg.OnEvent("Close", (*) => pg.Hide())         ; keeps running; the Companion's tray opens it again
    pg.OnEvent("Escape", (*) => pg.Hide())
}

; Another chat site: saved, then the pool restarts on it (each site keeps its own sign-in folder)
PoolSiteChanged(ctrl, *) {
    i := 0
    for id, s in poolSites {
        i += 1
        if (i != ctrl.Value)
            continue
        if (IsObject(site) && id = site["id"])
            return
        PoolSet("Site", id)
        PoolLog("chat site changed to '" id "' - restarting")
        PoolRestart("/show")
        return
    }
}

PoolShow() {
    PoolPaintState()
    PoolRefreshList()
    pg.Show()
}

PoolPaintState() {
    try {
        names := Map("off", "Off", "starting", "Starting...", "signin", "Needs sign-in", "account", "Wrong or unknown account", "ready", "Ready")
        pg["State"].Text := "Copilot pool: " names.Get(poolState, poolState) (PoolSiteGet("id", "copilot") != "copilot" ? "  -  using " PoolSiteName() : "")
        pg["Reason"].Text := poolReason
        kind := PoolAccountKind()
        pg["Account"].Text := "Account: " (PoolNoAccountCheck() ? "not needed (" PoolSiteName() ")"
            : kind = "" ? "not known yet"
            : kind = "unknown" ? "signed in, but the email couldn't be read" (PoolSetting("WorkConfirmed") = "unknown" ? " (you confirmed it's your work account)" : "")
            : account.email " (" kind ")")
        pg["BtnConfirm"].Visible := (kind = "unknown" && PoolSetting("WorkConfirmed") != "unknown")
        ready := 0, held := 0
        for v in views {
            if (!v.dead && v.state = "ready" && !v.held)
                ready += 1
            if v.held
                held += 1
        }
        pg["ViewInfo"].Text := "ready: " ready ", open as your windows: " held (poolMemMB ? ", memory: " poolMemMB " MB" : "")
    }
}

PoolRefreshList() {
    try {
        lv := pg["List"]
        lv.Opt("-Redraw")
        lv.Delete()
        for id, r in reqs
            lv.Add(, (r.label != "" ? r.label : "(no label)") (r.conv != "" ? "  · conversation" : ""),
                r.view ? r.status : "waiting for a free page", Round((A_TickCount - r.queuedAt) / 1000) " s")
        lv.Opt("+Redraw")
        PoolPaintState()
    }
}

PoolCancelSelected(*) {
    row := pg["List"].GetNext()
    if !row
        return
    i := 0
    for id, r in reqs {
        i += 1
        if (i = row) {
            PoolCancel(id)
            return
        }
    }
}

PoolTestSend(*) {
    m := Map("prompt", pg["TestPrompt"].Value, "label", "Test (pool window)")
    pg["TestAnswer"].Value := "Waiting for Copilot..."
    PoolAsk(PoolNewRequest(m, 0))
}

PoolConfirmWork(*) {
    if (MsgBox("Copilot is signed in, but the pool couldn't read which account.`n`nIs it your WORK account?"
        , "Copilot pool", "YesNo Icon?") != "Yes")
        return
    PoolSet("WorkConfirmed", "unknown")
    PoolLog("user confirmed the unreadable account is the work account")
    PoolUpdateState()
    PoolDispatch()
    SetTimer(PoolSigninReady, -100)
}

PoolAllowPersonalClicked(ctrl, *) {
    PoolSet("AllowPersonal", ctrl.Value ? 1 : 0)
    PoolLog("personal accounts " (ctrl.Value ? "ALLOWED (testing)" : "not allowed"))
    PoolUpdateState()
    PoolDispatch()
    SetTimer(PoolSigninReady, -100)
}

PoolViewsChanged(*) {
    n := Integer(pg["Views"].Value || 1)
    PoolSet("Views", n)
    PoolTopUp()
    PoolPaintState()
}

PoolToggleViews(*) {
    global viewsShown
    viewsShown := !viewsShown
    pg["BtnViews"].Text := viewsShown ? "Hide the pages" : "Show the pages"
    for v in views
        try PoolPlaceView(v)
}

; Signs out at Microsoft first (ends the session there, not only on this PC), then - when you close
; that window - deletes the sign-in here and restarts the pool, ready to sign in again.
PoolSignOut(confirm := true) {
    global signinView
    outUrl := PoolSiteGet("signOutUrl", "")
    if (confirm && MsgBox("Sign out of " PoolSiteName() " and restart the pool?`n`n"
        . (outUrl != "" ? "A window opens on the sign-out page, which ends this sign-in at the site too. "
        . "When it says you're signed out, close that window: the pool then forgets the sign-in on this PC and restarts.`n`n"
        . "(With single sign-on on, a work PC may sign you in again with your Windows account.)"
        : "The pool forgets everything this site stored on this PC (a new, empty sign-in folder) and restarts.")
        , "Copilot pool", "YesNo Icon? 0x40000") != "Yes")      ; 0x40000 = always on top
        return
    PoolNewProfile()                             ; the next start uses a new, empty sign-in folder
    IniWrite(0, POOL_INI, "Pending", "WipeSignIn")
    PoolSet("WorkConfirmed", "")
    PoolLog("sign out asked")
    if (env = 0 || envError != "" || outUrl = "") {
        PoolRestart("/show")
        return
    }
    if IsObject(signinView) {                    ; a sign-in window is open: reuse nothing, close it quietly
        old := signinView
        signinView := 0
        try old.ctrl.Close()
        try old.gui.Destroy()
    }
    personalUrl := PoolSiteGet("personalSignOutUrl", "")
    personal := (PoolAccountKind() = "personal" && personalUrl != "")
    v := { id: 0, gui: 0, ctrl: 0, wv: 0, state: "loading", host: "", onLogin: false, dead: false,
        jobId: "", reqId: "", conv: "", lastUse: A_TickCount, signin: true, signout: true, step: personal ? 1 : 2 }
    try {
        v.gui := Gui("+Resize +AlwaysOnTop", "Signing out of " PoolSiteName() " (Caption Companion)")
        v.gui.OnEvent("Size", (g, mm, *) => (mm != -1 && v.ctrl ? v.ctrl.Fill() : 0))
        v.gui.OnEvent("Close", (*) => PoolCloseSignIn())
        v.gui.Show("w900 h700")
        signinView := v
        ; personal accounts: Microsoft account sign-out first, then the work/school sign-out
        PoolInitView(v, true, personal ? personalUrl : outUrl)
        PoolLog("sign-out window opened")
    } catch as err {
        PoolLog("sign-out window FAILED: " err.Message " - restarting anyway")
        PoolRestart("/show")
    }
}

PoolRestart(arg := "/background") {
    Run(Format('"{}" "{}" /restart {}', A_AhkPath, A_ScriptFullPath, arg), A_ScriptDir)
    ExitApp()
}

; The sign-in folder in use: POOL_WEB\profile-<n>. A sign-out moves to the next number - a brand-new,
; empty folder - so nothing from the old sign-in can ever be reused, even if the old folder is still
; locked by a closing browser process. Old folders are deleted at start (retried every start).
; Each chat site has its own folder (copilot: profile-<n>, others: <site>-profile-<n>), so switching
; sites never touches another site's sign-in.
PoolProfileDir(siteId := "") {
    siteId := siteId != "" ? siteId : PoolSiteGet("id", "copilot")
    return POOL_WEB "\" (siteId = "copilot" ? "" : siteId "-") "profile-" PoolProfileGen(siteId) (PoolNum("SingleSignOn") ? "-sso" : "")
}

PoolProfileKey(siteId) => siteId = "copilot" ? "Gen" : "Gen " siteId

PoolProfileGen(siteId) {
    gen := IniRead(POOL_INI, "Profile", PoolProfileKey(siteId), "1")
    return IsInteger(gen) ? Integer(gen) : 1
}

PoolNewProfile() {
    id := PoolSiteGet("id", "copilot")
    IniWrite(PoolProfileGen(id) + 1, POOL_INI, "Profile", PoolProfileKey(id))
}

; At start: an older sign-out still pending moves to a new folder; every other folder is deleted
PoolWipeIfAsked() {
    if DirExist(POOL_WEB_OLD) {                   ; sign-in data from an early test version: not kept in data\
        try DirDelete(POOL_WEB_OLD, true)
        PoolLog(DirExist(POOL_WEB_OLD) ? "old sign-in folder in data\ could NOT be deleted" : "old sign-in folder in data\ deleted")
    }
    if (IniRead(POOL_INI, "Pending", "WipeSignIn", "0") = "1") {
        PoolNewProfile()
        IniWrite(0, POOL_INI, "Pending", "WipeSignIn")
        PoolLog("signed out - starting with a new, empty sign-in folder")
    }
    keep := Map()                                 ; every usable site's current folder stays
    keep.CaseSense := false
    for id in poolSites
        keep[PoolProfileDir(id)] := true
    left := 0
    Loop Files, POOL_WEB "\*", "D" {
        if keep.Has(A_LoopFileFullPath)
            continue
        Loop 10 {
            try DirDelete(A_LoopFileFullPath, true)
            if !DirExist(A_LoopFileFullPath)
                break
            Sleep(200)                            ; the old browser processes may still be closing
        }
        if DirExist(A_LoopFileFullPath)
            left += 1
    }
    if left
        PoolLog(left " old sign-in folder(s) still in use - not used any more, deleted at a later start")
}

PoolOpenSettings(*) {
    if !FileExist(POOL_INI) {
        txt := "; Copilot pool settings. Remove a line to go back to its default.`n[Settings]`n"
        for k, v in POOL_DEFAULTS
            txt .= k "=" v "`n"
        FileAppend(txt, POOL_INI, "UTF-16")
    }
    Run('notepad.exe "' POOL_INI '"')
}

PoolCopyLog(*) {
    text := ""
    try text := FileRead(POOL_LOG, "UTF-8")
    lines := StrSplit(RTrim(text, "`n"), "`n")
    out := "Copilot pool log (last lines) - " FormatTime(, "yyyy-MM-dd HH:mm") "`r`n" (A_PtrSize * 8) "-bit, version " APP_VERSION
        . ", state: " poolState " - " poolReason "`r`n`r`n"
    start := Max(1, lines.Length - 150)
    Loop lines.Length - start + 1
        out .= lines[start + A_Index - 1] "`r`n"
    A_Clipboard := out
    pg["TestAnswer"].Value := "The log is on the clipboard."
}

; ==============================================================================
; Memory guard: the pool never grows without limit, and never outlives the apps that use it
; ==============================================================================
; WebView2's memory level for one page: 0 normal, 1 low (a hidden idle page: it may drop caches;
; its script keeps running, so it still takes prompts - set back to normal the moment it gets one)
PoolMemLevel(v, level) {
    if (v.dead || (v.HasOwnProp("memLevel") && v.memLevel = level))
        return
    try {
        v.wv.MemoryUsageTargetLevel := level
        v.memLevel := level
    }
}

; Every MemAuditSec: measure, calm idle pages down, reload a page that grew too big, and if the whole
; engine is over TotalMaxMB: reload the biggest idle page and close idle spare pages. Numbers only in logs.
PoolMemAudit() {
    global poolMemMB
    static lastLogged := 0
    if (env = 0)
        return
    now := A_TickCount
    try {
        total := WvgEnvMB(env)
        poolMemMB := total
        for v in views {
            if v.dead
                continue
            idle := !v.held && v.jobId = "" && now - v.lastUse > PoolNum("IdleLowMemSec") * 1000
            PoolMemLevel(v, idle ? 1 : 0)
            try v.wv.PostWebMessageAsString('{"t":"mem"}')       ; the page answers with its size (next audit uses it)
        }
        ; one page grown too big (a long chat, a leaking site): a fresh copy of it, if nobody is using it
        for v in views {
            if (v.dead || v.held || v.jobId != "" || !v.HasOwnProp("heapMB") || v.heapMB <= PoolNum("PageMaxMB"))
                continue
            PoolMemReload(v, "its page uses " v.heapMB " MB (limit " PoolNum("PageMaxMB") ")")
        }
        over := total > PoolNum("TotalMaxMB")
        if over {
            big := 0
            for v in views
                if (!v.dead && !v.held && v.jobId = "" && v.HasOwnProp("heapMB")
                    && (!IsObject(big) || v.heapMB > big.heapMB))
                    big := v
            if IsObject(big)
                PoolMemReload(big, "the pool uses " total " MB (limit " PoolNum("TotalMaxMB") ")")
            want := PoolWantViews()
            for v in views.Clone()                  ; spare pages above the setting go now (not after 5 min)
                if (PoolRegularCount() > want && !v.dead && !v.held && v.jobId = "" && v.conv = "") {
                    PoolLog("view " v.id " closed (memory)")
                    PoolCloseView(v)
                }
        }
        DbgTrace("pool", "memory " total " MB in " WvgEnvPids(env).Length " processes, " PoolRegularCount() " page(s)"
            (over ? " - OVER " PoolNum("TotalMaxMB") " MB" : ""))
        if (over || Abs(total - lastLogged) >= 150) {
            lastLogged := total
            PoolLog("memory: " total " MB (" PoolRegularCount() " pages)" (over ? " - over the limit, trimmed" : ""))
        }
        PoolPaintState()
    } catch as err {
        PoolLog("memory audit failed: " err.Message)
    }
}

PoolMemReload(v, why) {
    PoolLog("view " v.id " reloaded to free memory: " why)
    DbgTrace("pool", PoolViewName(v) " reloaded to free memory: " why)
    v.heapMB := 0
    v.lastUse := A_TickCount
    try v.wv.Navigate(PoolAddress())             ; a reserved page stays reserved (it only reloads)
}

; The pool closes itself when nothing uses it: no app window that talks to it (Companion, Screen ask - they
; subscribe) and none of its Copilot windows open, for NoAppQuitSec. Its window open on screen keeps it too.
PoolOwnerCheck() {
    static noneSince := 0
    if (noneSince = 0)
        noneSince := poolStartedAt               ; a grace period at the start for the apps to say hello
    used := false
    try used := DllCall("IsWindowVisible", "Ptr", pg.Hwnd)
    for v in views
        if (!v.dead && v.held)
            used := true                         ; one of its Copilot windows is open: you're using it
    for hwnd in subs.Clone() {
        if WinExist("ahk_id " hwnd)
            used := true
        else
            subs.Delete(hwnd)
    }
    if used {
        noneSince := A_TickCount
        return
    }
    if (A_TickCount - noneSince > Max(15, PoolNum("NoAppQuitSec")) * 1000) {
        PoolLog("no app is using the pool any more - closing it (frees " poolMemMB " MB)")
        ExitApp()
    }
}

PoolOnExit(*) {
    for id, r in reqs.Clone()
        PoolFinish(r, false, r.sent || IsObject(r.view) ? "failed" : "unsent", "the Copilot pool closed")
    for v in views
        try v.ctrl.Close()
    if IsObject(signinView)
        try signinView.ctrl.Close()
    PoolPublish(Map("t", "state", "state", "off", "reason", "the Copilot pool closed"))
}

; ==============================================================================
; Settings, log, errors
; ==============================================================================
PoolSetting(key) {
    def := POOL_DEFAULTS.Has(key) ? POOL_DEFAULTS[key] : ""
    try return IniRead(POOL_INI, "Settings", key, def)
    return def
}

PoolNum(key) {
    try return Integer(PoolSetting(key))
    return POOL_DEFAULTS.Get(key, 0)
}

PoolSet(key, value) {
    try IniWrite(value, POOL_INI, "Settings", key)
}

; ==============================================================================
; Chat sites (chat-sites\*.json, see its README): everything that differs between Copilot, Google AI
; Mode, ... lives in those files; this file and the page script only read them.
; ==============================================================================
PoolLoadSites() {
    sites := Map()
    for dir in POOL_SITES_DIRS {
        Loop Files dir "\*.json" {
            try {
                s := Json.Parse(FileRead(A_LoopFileFullPath, "UTF-8"))
                id := (s is Map) ? Trim(s.Get("id", "")) : ""
                if (id = "")
                    throw Error("no id")
                if !sites.Has(id) {
                    sites[id] := s
                    continue
                }
                base := sites[id]                 ; data\chat-sites\ overrides app\chat-sites\ field by field
                for k, val in s {
                    if (k = "selectors" && val is Map && base.Get("selectors", "") is Map) {
                        for sk, sv in val
                            base["selectors"][sk] := sv
                    } else
                        base[k] := val
                }
            } catch as err {
                PoolLog("chat site file " A_LoopFileName " ignored: " err.Message)
            }
        }
    }
    for id, s in sites.Clone() {
        why := ""
        if (s.Get("devOnly", 0) && !POOL_DEV)
            why := "dev only"
        else if !RegExMatch(s.Get("address", ""), "i)^https://")
            why := "its address isn't https"
        else if !(s.Get("hosts", "") is Array && s["hosts"].Length)
            why := "no hosts"
        else if (s.Get("account", "work") != "work" && !s.Get("devOnly", 0))
            why := "only dev-only sites may skip the work-account check"
        if (why != "") {
            sites.Delete(id)
            if (why != "dev only")
                PoolLog("chat site '" id "' not used: " why)
        }
    }
    return sites
}

PoolPickSite() {
    id := PoolSetting("Site")
    if poolSites.Has(id)
        return poolSites[id]
    PoolLog("chat site '" id "' isn't available here" (POOL_DEV ? "" : " (dev-only sites need dev mode)") " - using Copilot")
    if poolSites.Has("copilot")
        return poolSites["copilot"]
    for id, s in poolSites
        return s
    return 0                                      ; no site files at all: PoolStart reports it
}

PoolSiteGet(key, def := "") => IsObject(site) ? site.Get(key, def) : def
PoolSiteName() => PoolSiteGet("name", PoolSiteGet("id", "(no chat site)"))
PoolWarmUpOn() => (PoolNum("WarmUp") && PoolSiteGet("warmUp", 0)) ? true : false
PoolAddress() => PoolSiteGet("address", "about:blank")
PoolNoAccountCheck() => (POOL_DEV && PoolSiteGet("devOnly", 0) && PoolSiteGet("account", "work") = "none")

PoolHosts() {
    a := []
    hs := PoolSiteGet("hosts", [])
    if (hs is Array)
        for h in hs
            if (Trim(h) != "")
                a.Push(StrLower(Trim(h)))
    return a
}

PoolIsSignInHost(host) {
    re := PoolSiteGet("signInHosts", "")
    try return (re != "" && RegExMatch(host, "i)" re))
    return false
}

PoolHostAllowed(host) {
    for h in PoolHosts()
        if (host = h || SubStr(host, -(StrLen(h) + 1)) = "." h)
            return true
    return false
}

PoolLog(line) {
    DbgTrace("pool", line)
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", POOL_LOG, "UTF-8")
}

PoolTrimLog() {
    try {
        if (FileGetSize(POOL_LOG) > 1024 * 1024)
            FileMove(POOL_LOG, DATA_DIR "\copilot-pool.old.log", true)
    }
}

PoolOnError(err, mode) {
    PoolLog("ERROR: " err.Message " (" err.What ", line " err.Line ")")
    return true                                   ; no error dialogs for workmates; it's in the log
}
