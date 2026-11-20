#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
try TraySetIcon(A_ScriptDir "\icons\pool.ico")        ; its own icon (its windows, taskbar)
try DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", "CaptionCompanion.CopilotPool") ; own taskbar button
#Include app-paths.ahk
#Include Json.ahk
#Include debug-trace.ahk
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
; * Safety: pages load over https only; only Copilot's own pages (AllowedHosts)
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
; * Work account only: requests are refused while a personal account (gmail.com,
;   outlook.com, ... - see PersonalDomains) is signed in, unless "Allow personal
;   accounts (testing only)" is ticked.
; * Never sends a prompt twice. The log (data\copilot-pool.log) never holds
;   prompt or answer text.
; * One copy only. Arguments: /background, /show, /signin, /restart.
;
; Messages (WM_COPYDATA, tag POOL_TAG, JSON text):
;   app -> pool  {t:"ask", id, hwnd, prompt, label, conversation, newChat, stream, show}
;                {t:"cancel", id}   {t:"end", conversation}   {t:"status", hwnd}
;                {t:"show"}   {t:"signin"}   {t:"quit"}
;   pool -> app  {t:"queued", id, position}   {t:"sent", id}   {t:"chunk", id, text}
;                {t:"done", id, ok, kind, text, markdown, error, ms}
;                {t:"state", state, reason, views, ready, free, queued, account, accountKind}
;   state: off | starting | signin | account | ready
;   kind (when ok=0): unsent (never reached Copilot - safe to try another way),
;     off / starting / signin / account / busy (same: never reached Copilot),
;     lost (that conversation is gone - send the full context again),
;     replaced (a board page got a newer prompt: this one was dropped, or its answer stopped),
;     failed / timeout / cancelled (may have reached Copilot - do NOT resend)
; Board pages ("page"): the newest prompt always wins. If the page is busy, its job stops (Copilot's
; answer too), the input box is cleared and the new prompt goes right away. Only exception: a
; follow-up waits until the full prompt before it is in (a few seconds), so no context is lost.
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
POOL_SIGNOUT_URL := "https://login.microsoftonline.com/common/oauth2/v2.0/logout"   ; Microsoft's work/school sign-out
POOL_SEL_FILE := DATA_DIR "\copilot-pool-selectors.json"
POOL_WORKER := A_ScriptDir "\copilot-pool-worker.js"
POOL_CONSUMER_TENANT :="9188040d-6c67-4c5b-b112-36a304b66dad"   ; Microsoft's tenant for personal accounts
POOL_DEFAULTS := Map(
    "Address", "https://m365.cloud.microsoft/chat",
    "SingleSignOn", 1,
    "Views", 2,
    "MaxViews", 4,
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
    "AllowedHosts", "m365.cloud.microsoft, copilot.cloud.microsoft",
    "PersonalDomains", "gmail.com, googlemail.com, outlook.com, hotmail.com, live.com, msn.com, passport.com, yahoo.com, ymail.com, rocketmail.com, icloud.com, me.com, mac.com, aol.com, proton.me, protonmail.com, gmx.com, gmx.net, mail.com, yandex.com, zoho.com",
    "AllowPersonal", 0,
    "BoardColumns", 3,             ; board pages side by side up to this many, then one at a time (tabs)
    "ChatW", 900,                  ; size of a 💬 Copilot window (remembered when you close one)
    "ChatH", 760,
    "WorkConfirmed", "")           ; "unknown" = the user confirmed an account we couldn't read is the work one

DetectHiddenWindows(true)
OnError(PoolOnError)

poolArgs := ""
for a in A_Args
    poolArgs .= " " a

if InStr(poolArgs, "/restart") {
    Loop 50 {
        if !WinExist(POOL_TITLE " ahk_class AutoHotkeyGUI")
            break
        Sleep(100)
    }
}
if (other := WinExist(POOL_TITLE " ahk_class AutoHotkeyGUI")) {
    if InStr(poolArgs, "/signout")
        PoolSendTo(other, Map("t", "signout"))
    else if InStr(poolArgs, "/signin")
        PoolSendTo(other, Map("t", "signin"))
    else if !InStr(poolArgs, "/background")
        PoolSendTo(other, Map("t", "show"))
    ExitApp()
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
subs := Map()             ; app window -> true (gets "state" messages)
account := {email: "", tenant: "", how: "", known: false}
poolState := "starting"
poolReason := "starting the browser engine"
lastPublished := ""
jobSeq := 0
workerJs := ""
viewsShown := false
; The board: dedicated pages, one per name (key) an app asks for, shown together in one window
; (the Companion's Live helpers). Not part of the regular pool.
boardGui := 0
boardPages := Map()       ; key -> view
boardWanted := []         ; [{key, label}] in the order the app gave
boardTitle := "Live helpers"
boardTab := 1             ; which page is shown when there are more than BoardColumns
boardTabBtns := []

; ------------------------------------------------------------------------------
; Start
; ------------------------------------------------------------------------------
PoolTrimLog()
PoolWipeIfAsked()
PoolBuildGui()
OnMessage(0x4A, PoolOnCopyData)
OnExit(PoolOnExit)
if (InStr(poolArgs, "/show") || InStr(poolArgs, "/signin") || !InStr(poolArgs, "/background"))
    PoolShow()
PoolLog("started (" (A_PtrSize * 8) "-bit, version " APP_VERSION ")")
SetTimer(PoolStart, -50)
SetTimer(PoolHousekeep, 1000)

PoolStart() {
    global env, envError, workerJs
    try {
        if !IsSet(WebView2)
            throw Error("the WebView2 library is missing (app\lib\WebView2)")
        workerJs := FileRead(POOL_WORKER, "UTF-8")
        sso := PoolNum("SingleSignOn")
        dir := POOL_WEB "\" (sso ? "sso" : "no-sso")
        DirCreate(dir)
        env := WebView2.CreateEnvironmentAsync({ AllowSingleSignOnUsingOSPrimaryAccount: sso ? 1 : 0 }, dir).await(60000)
        ver := ""
        try ver := env.BrowserVersionString
        PoolLog("browser engine " ver ", single sign-on " (sso ? "on" : "off"))
        Loop Max(1, PoolNum("Views"))
            PoolAddView()
        PoolBoardSync()
    } catch as err {
        envError := err.Message
        PoolLog("ENGINE FAILED: " err.Message)
    }
    PoolUpdateState()
    if InStr(poolArgs, "/signout")
        SetTimer(PoolSignOut.Bind(false), -500)
    else if InStr(poolArgs, "/signin")
        PoolOpenSignIn()
}

; ==============================================================================
; Views
; ==============================================================================
PoolAddView() {
    global viewSeq
    viewSeq += 1
    v := { id: viewSeq, gui: 0, ctrl: 0, wv: 0, state: "loading", host: "", onLogin: false, dead: false,
        jobId: "", reqId: "", conv: "", lastUse: A_TickCount, createdAt: A_TickCount, failedAt: 0, held: false, needWarm: false,
        boardKey: "" }
    try {
        v.gui := Gui("+ToolWindow +Owner" pg.Hwnd, "Copilot view " v.id)
        v.gui.OnEvent("Close", PoolChatClosed.Bind(v))     ; only while it's shown as your Copilot window
        v.gui.OnEvent("Size", PoolChatSized.Bind(v))
        PoolPlaceView(v)
        PoolInitView(v)
        views.Push(v)
        PoolLog("view " v.id " opened")
    } catch as err {
        PoolLog("view " v.id " FAILED to open: " err.Message)
        try v.gui.Destroy()
    }
    PoolUpdateState()
    return v
}

; Creates the WebView in v.gui and loads Copilot (also used by the sign-in window)
PoolInitView(v, signin := false, url := "") {
    v.ctrl := env.CreateCoreWebView2ControllerAsync(v.gui.Hwnd).await(30000)
    v.ctrl.IsVisible := true             ; "visible" to the page even while its window is hidden
    v.wv := v.ctrl.CoreWebView2
    try v.wv.Settings.IsStatusBarEnabled := false
    try v.wv.Settings.AreDevToolsEnabled := false      ; no F12 tools in these windows
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
    v.wv.Navigate(url != "" ? url : PoolSetting("Address"))
}

PoolWorkerPrefix(id) {
    cfg := Map("id", id, "url", PoolSetting("Address"), "hosts", PoolHosts(),
        "sendWaitMs", PoolNum("SendWaitSec") * 1000)
    if FileExist(POOL_SEL_FILE) {
        try {
            sel := Json.Parse(FileRead(POOL_SEL_FILE, "UTF-8"))
            if (sel is Map)
                cfg["selectors"] := sel
        } catch as err {
            PoolLog("copilot-pool-selectors.json ignored: " err.Message)
        }
    }
    return "window.__lccPool=" Json.Stringify(cfg) ";`n"
}

PoolPlaceView(v) {
    if (v.held || v.boardKey != "")             ; your Copilot window / a board page: leave it where it is
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
    if (v.boardKey != "" && boardPages.Has(v.boardKey) && boardPages[v.boardKey] = v)
        boardPages.Delete(v.boardKey)
}

; Pages in the regular pool (not board pages)
PoolRegularCount() {
    n := 0
    for v in views
        if (!v.dead && v.boardKey = "")
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
    SetTimer(v.boardKey != "" ? PoolBoardSync : PoolTopUp, -2000)
}

; Keeps the number of views at the setting (plus the ones conversations need, up to MaxViews)
PoolTopUp() {
    if (env = 0 || envError != "")
        return
    want := Max(1, PoolNum("Views"))
    while (PoolRegularCount() < want)
        PoolAddView()
    PoolDispatch()
}

; Links that would open a new window: hidden pages never open anything; in your 💬 window a web link
; opens in your normal browser (not inside the pool)
PoolPopup(v, sender, args) {
    uri := ""
    try uri := args.Uri
    try args.Handled := true
    if ((v.held || v.boardKey != "") && RegExMatch(uri, "i)^https://"))
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
PoolShowChat(v, label) {
    held := 0
    for x in views
        if x.held
            held += 1
    v.held := true
    v.gui.Opt("-ToolWindow -Owner +Resize +MinSize480x400")
    v.gui.Title := "Copilot" (label != "" ? " - " label : "") " (Caption Companion)"
    w := PoolNum("ChatW"), h := PoolNum("ChatH")
    x := IniRead(POOL_INI, "ChatWindow", "X", "")
    y := IniRead(POOL_INI, "ChatWindow", "Y", "")
    pos := ""
    if (IsInteger(x) && IsInteger(y) && PoolOnScreen(x + 30 * held, y + 30 * held))
        pos := "x" (x + 30 * held) " y" (y + 30 * held) " "
    v.gui.Show(pos "w" w " h" h)
    try v.ctrl.Fill()
    PoolLog("view " v.id " shown as a Copilot window")
    PoolEnsureSpare()
}

PoolChatSized(v, g, minMax, *) {
    if (v.held && minMax != -1)
        try v.ctrl.Fill()
}

PoolChatClosed(v, *) {
    if !v.held
        return
    try {                                       ; remember the size and place for next time
        v.gui.GetPos(&x, &y)
        v.gui.GetClientPos(, , &w, &h)
        IniWrite(x, POOL_INI, "ChatWindow", "X")
        IniWrite(y, POOL_INI, "ChatWindow", "Y")
        dpi := A_ScreenDPI / 96
        PoolSet("ChatW", Round(w / dpi))
        PoolSet("ChatH", Round(h / dpi))
    }
    v.held := false
    v.lastUse := A_TickCount
    v.gui.Opt("+ToolWindow +Owner" pg.Hwnd)
    if (v.jobId = "")                           ; a fresh chat, then back to the pool
        try v.wv.PostWebMessageAsString('{"t":"newchat"}')
    PoolLog("view " v.id " window closed - back in the pool")
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
        v.gui := Gui("+Resize", "Sign in to Copilot - Caption Companion")
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
            try x.wv.Navigate(PoolSetting("Address"))
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
            if !isSignin
                v.needWarm := PoolNum("WarmUp") ? true : false    ; a freshly loaded page: warm it up once ready
            if (!isSignin && v.boardKey != "") {           ; a board page reloaded: its chat starts over
                v.fresh := true
                PoolBoardHeader(v)
            }
            if (!isSignin && v.jobId = "" && v.conv != "") {      ; the page reloaded: its chat is gone
                PoolLog("view " v.id ": conversation lost (page reloaded)")
                convs.Delete(v.conv)
                v.conv := ""
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
            }
            if (isSignin && v.state = "ready" && !v.HasOwnProp("signout"))
                SetTimer(PoolSigninReady, -1500)
            if (!isSignin && v.boardKey != "")
                PoolBoardHeader(v)
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
        case "sent":
            if (m.Get("jobId", "") != v.jobId)                ; from a job that was replaced meanwhile
                return
            if reqs.Has(v.reqId) {
                r := reqs[v.reqId]
                r.sent := true
                r.status := "sent - waiting for the answer"
                r.sentAt := A_TickCount
                DbgTrace("pool", "request " r.logName " is IN Copilot (" PoolViewName(v) "): " (A_TickCount - r.queuedAt) " ms after it arrived, "
                    (A_TickCount - r.startedAt) " ms after the page got it")
                if (v.boardKey != "" && !r.warm) {
                    if r.newChat
                        v.fresh := false                    ; the board page now has this chat's context
                    v.note := "writing..."
                    PoolBoardHeader(v)
                }
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
            if (v.boardKey != "" && !r.warm) {
                v.note := m.Get("ok", 0) ? "answered " FormatTime(, "h:mm:ss tt")
                    : m.Get("sent", 0) ? "no answer: " m.Get("error", "") : "waiting: " m.Get("error", "")
                PoolBoardHeader(v)
            }
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
                if (v.step = 1 && InStr(host, "live.com")) {      ; Microsoft account done: now the work/school sign-out
                    v.step := 2
                    SetTimer(() => v.wv.Navigate(POOL_SIGNOUT_URL), -1500)
                }
            } else {
                try v.gui.Title := "Sign in to Copilot - " (host != "" ? host : "loading...") " (Caption Companion)"
            }
        }
        if (host != "" && !PoolHostAllowed(host) && host != "about:blank") {
            if RegExMatch(host, "i)(^|\.)(login\.|account\.|signup\.)|microsoftonline|live\.com$") {
                v.onLogin := true
                v.state := "signin"
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
        show: m.Get("show", 0) ? true : false, page: m.Get("page", ""),
        queuedAt: A_TickCount, startedAt: 0, sent: false, status: "waiting", view: 0, logName: "#" jobSeq, warm: false,
        tick: IsInteger(m.Get("tick", 0)) ? m.Get("tick", 0) : 0, waitWhy: "", sentAt: 0 }
    if (r.conv = "" && r.page = "")
        r.newChat := true
    if (r.page != "")
        r.show := false
    return r
}

PoolAsk(r) {
    if (Trim(r.prompt, " `t`r`n") = "") {
        PoolFinish(r, false, "unsent", "the prompt is empty", , , , false)
        return
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
    if (r.page != "")                            ; a board page: only its newest prompt matters
        for id in queue.Clone()
            if (reqs.Has(id) && reqs[id].page = r.page && (r.newChat || !reqs[id].newChat)) {
                PoolLog("request " reqs[id].logName " replaced by " r.logName " before it started")
                PoolFinish(reqs[id], false, "replaced", "a newer prompt replaced it before it was sent")
            }
    queue.Push(r.id)
    PoolReply(r, Map("t", "queued", "id", r.id, "position", queue.Length))
    PoolLog("request " r.logName " queued" (r.conv != "" ? " (conversation" (r.newChat ? ", new" : ", follow-up") ")" : ""))
    DbgTrace("pool", "request " r.logName " = Companion ask " r.id " '" r.label "'" (r.page != "" ? " for live helper page" : "")
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
            if (r.page != "" && !PoolBoardWants(r.page)) {
                queue.RemoveAt(i)
                PoolFinish(r, false, "unsent", "there is no board page called '" r.page "'")
                continue
            }
            if (r.conv = "" && r.page = "" && PoolNoRoom()) {       ; every page is open as your window, and no more allowed
                queue.RemoveAt(i)
                PoolFinish(r, false, "busy", "every Copilot page is open in a window (" PoolRegularCount() " of " PoolNum("MaxViews") ") - close one and try again")
                continue
            }
            if (r.page != "") {
                bp := boardPages.Has(r.page) ? boardPages[r.page] : 0
                PoolWaitWhy(r, !IsObject(bp) ? "its live helper page isn't open yet"
                    : "its live helper page is " bp.state (bp.jobId != "" ? " (running " bp.jobId ")" : "")
                    (bp.jobId != "" && reqs.Has(bp.reqId) && reqs[bp.reqId].newChat && !reqs[bp.reqId].sent ? " - waiting for the full prompt to go in first" : ""))
            } else
                PoolWaitWhy(r, "no free Copilot page")
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
    return "page " v.id (v.boardKey != "" ? " (live '" v.label "')" : v.held ? " (💬 window)" : "")
}

; One line describing every page: "1 ready, 2 busy j12(#11), 3 live 'Next step' ready ..."
PoolViewsSummary() {
    s := ""
    for v in views {
        if v.dead
            continue
        d := v.id (v.boardKey != "" ? " live'" SubStr(v.label, 1, 14) "'" : "") " " v.state
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
    if (r.page != "") {                          ; a board page: only its own page, never the regular pool
        if !boardPages.Has(r.page)
            return 0                              ; not open (yet)
        v := boardPages[r.page]
        if v.dead
            return 0
        old := (v.jobId != "" && reqs.Has(v.reqId)) ? reqs[v.reqId] : 0
        if (!r.newChat && IsObject(old) && old.newChat && !old.warm && !old.sent)
            return 0                              ; a follow-up waits until the full prompt it follows is in
        if (!r.newChat && v.fresh) {              ; a follow-up, but the page's chat started over
            lost := true
            return 0
        }
        if (v.jobId != "")
            return v                              ; busy: the newest prompt wins (PoolRun stops the old job)
        return (v.state = "ready") ? v : 0
    }
    if (r.conv != "") {
        if convs.Has(r.conv) {
            v := convs[r.conv]
            if !v.dead
                return (v.state = "ready" && v.jobId = "") ? v : 0
            convs.Delete(r.conv)
        }
        if !r.newChat {
            lost := true
            return 0
        }
        v := PoolFreeView()
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
    for v in views                               ; none free: a page that is only warming up gives way
        if (!v.dead && !v.held && v.boardKey = "" && v.conv = "" && v.jobId != "" && reqs.Has(v.reqId) && reqs[v.reqId].warm)
            return v
    return 0
}

; A ready regular view with no job, no conversation, and not open as your window
PoolFreeView() {
    for v in views
        if (!v.dead && !v.held && v.boardKey = "" && v.state = "ready" && v.jobId = "" && v.conv = "")
            return v
    return 0
}

; True when every regular page is open as your window (or in a conversation) and no more may be opened
PoolNoRoom() {
    if (PoolRegularCount() < Max(PoolNum("Views"), PoolNum("MaxViews")))
        return false
    for v in views
        if (!v.dead && !v.held && v.boardKey = "" && v.conv = "")
            return false                        ; free, loading or busy: it will be free again
    return true
}

; Opens one more regular view (up to MaxViews) when none is free or on its way
PoolEnsureSpare() {
    for v in views
        if (!v.dead && !v.held && v.boardKey = "" && v.jobId = "" && v.conv = "")
            return                              ; free, or still loading
    if (PoolRegularCount() < Max(PoolNum("Views"), PoolNum("MaxViews")))
        SetTimer(PoolAddView, -1)
}

PoolRun(r, v) {
    global jobSeq
    preempt := (v.jobId != "")                   ; the page is busy: its job stops and this prompt goes now
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
    board := (r.page != "")
    job := Map("t", "job", "jobId", v.jobId, "prompt", r.prompt, "newChat", r.newChat ? 1 : 0,
        "keep", (!r.warm && (r.conv != "" || r.show || board)) ? 1 : 0, "stream", r.stream ? 1 : 0,
        "timeoutMs", PoolNum("AnswerTimeoutSec") * 1000,
        "scroll", (board && !r.warm) ? 1 : 0,          ; board pages follow the newest answer
        "preempt", preempt ? 1 : 0)
    try {
        v.wv.PostWebMessageAsString(Json.Stringify(job))
        PoolLog("request " r.logName " -> view " v.id (r.show ? " (shown as a window)" : "") (preempt ? " (replacing)" : ""))
        DbgTrace("pool", "request " r.logName " -> " PoolViewName(v) " after waiting " (A_TickCount - r.queuedAt) " ms"
            (preempt ? " (REPLACING the page's running job)" : "") (r.warm ? " (warm-up)" : "") "   | pages: " PoolViewsSummary())
        if r.show
            PoolShowChat(v, r.label)            ; you watch Copilot write the answer
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
    if (v.boardKey != "" && !v.fresh)            ; a board page already holding a call's chat: leave it
        return
    jobSeq += 1
    r := { id: "warm" jobSeq, hwnd: -1, prompt: PoolSetting("WarmUpPrompt"), label: "warm-up", conv: "",
        newChat: true, stream: false, show: false, page: "", queuedAt: A_TickCount, startedAt: 0, sent: false,
        status: "warming up", view: 0, logName: "warm-up #" jobSeq, warm: true, tick: 0, waitWhy: "", sentAt: 0 }
    reqs[r.id] := r
    PoolRun(r, v)
}

PoolEndConversation(conv) {
    if !convs.Has(conv)
        return
    v := convs[conv]
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
        wait := ((r.conv != "" && convs.Has(r.conv)) || r.page != "") ? PoolNum("AnswerTimeoutSec") + 60
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
        if (v.boardKey != "") {                   ; board pages keep their answers; only retry a failed load
            if (v.state = "load-failed" && now - v.failedAt > 30000) {
                v.failedAt := now
                try v.wv.Navigate(PoolSetting("Address"))
            }
            continue
        }
        if (v.conv != "" && now - v.lastUse > PoolNum("ConversationIdleMin") * 60000)
            PoolEndConversation(v.conv)
        else if (v.conv = "" && v.state = "ready" && now - v.lastUse > PoolNum("RefreshIdleMin") * 60000) {
            v.lastUse := now
            DbgTrace("pool", PoolViewName(v) ": idle " PoolNum("RefreshIdleMin") " min - reloading it (it will warm up again)")
            try {
                v.wv.Navigate(PoolSetting("Address"))
            }
        } else if (v.state = "load-failed" && now - v.failedAt > 30000) {
            v.failedAt := now
            try v.wv.Navigate(PoolSetting("Address"))
        }
    }
    ; extra views opened for conversations close again when idle
    want := Max(1, PoolNum("Views"))
    if (PoolRegularCount() > want)
        for v in views.Clone()
            if (PoolRegularCount() > want && !v.held && v.boardKey = "" && v.jobId = "" && v.conv = "" && now - v.lastUse > 300000) {
                PoolLog("view " v.id " closed (not needed)")
                PoolCloseView(v)
            }
    if (queue.Length && poolState = "ready")
        PoolDispatch()
    ; freshly loaded pages send one short warm-up message (one page per second), so real prompts go at once
    if (poolState = "ready" && PoolNum("WarmUp"))
        for v in views
            if (!v.dead && v.needWarm && !v.held && v.state = "ready" && v.jobId = "" && v.conv = "") {
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
            if (v.state = "ready" && v.jobId = "" && v.conv = "" && !v.held && v.boardKey = "")
                free += 1
        }
        if v.onLogin
            login := true
    }
    if IsObject(signinView) && signinView.onLogin
        login := true
    why := ""
    if (envError != "")
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
    msg := Map("t", "state", "state", s, "reason", r, "views", views.Length, "ready", ready, "free", free,
        "queued", queue.Length, "account", account.email = "" ? "" : PoolMaskEmail(account.email), "accountKind", PoolAccountKind())
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
    if (hwnd != pg.Hwnd)
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
        case "status":
            PoolPublish(Json.Parse(lastPublished != "" ? lastPublished : '{"t":"state","state":"starting"}'))
        case "show":
            PoolShow()
        case "signin":
            PoolShow()
            PoolOpenSignIn()
        case "signout":
            PoolSignOut(true)
        case "board":
            PoolBoardSet(m)
        case "boardshow":
            PoolBoardShow(m.Get("activate", 0))
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
; The board: one dedicated Copilot page per key (e.g. the Companion's auto helpers),
; shown together in one window, side by side (tabs when there are more than BoardColumns).
; Not part of the regular pool: requests reach a board page only by its key ("page").
; ==============================================================================
PoolBoardSet(m) {
    global boardWanted, boardTitle
    list := []
    pages := m.Get("pages", [])
    if (pages is Array)
        for p in pages
            if (p is Map && Trim(p.Get("key", "")) != "")
                list.Push({key: Trim(p["key"]), label: p.Get("label", p["key"])})
    boardWanted := list
    if (m.Get("title", "") != "")
        boardTitle := m["title"]
    PoolLog("board: " list.Length " page(s) wanted")
    PoolBoardSync()
}

PoolBoardWants(key) {
    for w in boardWanted
        if (w.key = key)
            return true
    return false
}

; Opens the wanted board pages, closes the unwanted ones (when idle), lays them out
PoolBoardSync(*) {
    if (env = 0 || envError != "")
        return
    try {
        PoolBoardEnsureGui()
        for key, v in boardPages.Clone()
            if (!PoolBoardWants(key) && v.jobId = "") {
                PoolLog("board page '" key "' closed")
                PoolCloseView(v)
            }
        for w in boardWanted {
            if boardPages.Has(w.key) {
                boardPages[w.key].label := w.label
                PoolBoardHeader(boardPages[w.key])
            } else {
                PoolAddBoardPage(w.key, w.label)
            }
        }
        PoolBoardLayout()
    } catch as err {
        PoolLog("board sync FAILED: " err.Message)
    }
    PoolUpdateState()
    PoolDispatch()
}

PoolAddBoardPage(key, label) {
    global viewSeq
    viewSeq += 1
    v := { id: viewSeq, gui: 0, ctrl: 0, wv: 0, state: "loading", host: "", onLogin: false, dead: false,
        jobId: "", reqId: "", conv: "", lastUse: A_TickCount, createdAt: A_TickCount, failedAt: 0, held: false, needWarm: false,
        boardKey: key, label: label, fresh: true, note: "", hdr: 0 }
    try {
        v.gui := Gui("-Caption -DPIScale +Parent" boardGui.Hwnd)     ; a panel inside the board window
        v.gui.MarginX := 0, v.gui.MarginY := 0
        v.gui.BackColor := "F3F3F3"
        v.gui.SetFont("s10 bold", "Segoe UI")
        v.hdr := v.gui.Add("Text", "x6 y3 w400 h20", label)
        v.gui.Show("NoActivate x0 y0 w600 h600")
        PoolInitView(v)
        boardPages[key] := v
        views.Push(v)
        PoolLog("board page '" key "' opened (view " v.id ")")
    } catch as err {
        PoolLog("board page '" key "' FAILED to open: " err.Message)
        try v.gui.Destroy()
    }
}

PoolBoardEnsureGui() {
    global boardGui
    if IsObject(boardGui)
        return
    boardGui := Gui("+Resize -DPIScale +MinSize560x360", boardTitle " (Caption Companion)")
    boardGui.BackColor := "D9D9D9"
    boardGui.SetFont("s9", "Segoe UI")
    boardGui.OnEvent("Size", (*) => PoolBoardLayout())
    boardGui.OnEvent("Close", PoolBoardClosed)
    w := IniRead(POOL_INI, "Board", "W", "1300")
    h := IniRead(POOL_INI, "Board", "H", "820")
    boardGui.Show("Hide w" w " h" h)
}

; Side by side when they fit (BoardColumns), otherwise one at a time with a tab button each
PoolBoardLayout() {
    global boardTab
    if !IsObject(boardGui)
        return
    try {
        keys := []
        for w in boardWanted
            if boardPages.Has(w.key)
                keys.Push(w.key)
        boardGui.GetClientPos(, , &W, &H)
        n := keys.Length
        tabbed := (n > Max(1, PoolNum("BoardColumns")))
        boardTab := Max(1, Min(boardTab, n))
        while (tabbed && boardTabBtns.Length < n) {
            b := boardGui.Add("Button", "x0 y0 w150 h26 Hidden", "")
            b.OnEvent("Click", PoolBoardTab.Bind(boardTabBtns.Length + 1))
            boardTabBtns.Push(b)
        }
        for i, b in boardTabBtns {
            if (tabbed && i <= n) {
                b.Text := (i = boardTab ? "▶ " : "") boardPages[keys[i]].label
                b.Move(6 + (i - 1) * 156, 4, 150, 26)
                b.Visible := true
            } else {
                b.Visible := false
            }
        }
        if tabbed {
            for i, key in keys {
                if (i = boardTab)
                    PoolBoardPlace(boardPages[key], 0, 34, W, H - 34)
                else
                    boardPages[key].gui.Hide()
            }
        } else if n {
            gap := 4
            colW := Floor((W - gap * (n - 1)) / n)
            for i, key in keys
                PoolBoardPlace(boardPages[key], (i - 1) * (colW + gap), 0, colW, H)
        }
    }
}

PoolBoardPlace(v, x, y, w, h) {
    v.gui.Show("NoActivate x" x " y" y " w" w " h" h)
    try v.hdr.Move(6, 3, Max(50, w - 12), 20)
    rect := Buffer(16)
    NumPut("int", 0, "int", 26, "int", w, "int", Max(27, h), rect)    ; the page sits under its header
    try v.ctrl.Bounds := rect
}

PoolBoardTab(i, *) {
    global boardTab
    boardTab := i
    PoolBoardLayout()
}

PoolBoardHeader(v) {
    if !IsObject(v.hdr)
        return
    st := v.note != "" ? v.note : v.state = "ready" ? "ready" : v.state = "signin" ? "needs sign-in" : "loading..."
    try v.hdr.Text := v.label "   ·   " st
}

; activate: 1 = bring it to the front (you asked), 0 = show it without taking focus (a call started)
PoolBoardShow(activate := 1) {
    if (env = 0 || envError != "")
        return
    PoolBoardEnsureGui()
    if DllCall("IsWindowVisible", "ptr", boardGui.Hwnd) {
        if activate
            try WinActivate("ahk_id " boardGui.Hwnd)
        return
    }
    x := IniRead(POOL_INI, "Board", "X", "")
    y := IniRead(POOL_INI, "Board", "Y", "")
    pos := (IsInteger(x) && IsInteger(y) && PoolOnScreen(x, y)) ? "x" x " y" y " " : ""
    boardGui.Show(pos (activate ? "" : "NoActivate"))
    PoolBoardLayout()
}

PoolBoardClosed(*) {
    try {
        if (DllCall("IsIconic", "ptr", boardGui.Hwnd) || DllCall("IsZoomed", "ptr", boardGui.Hwnd))
            return
        boardGui.GetPos(&x, &y)
        boardGui.GetClientPos(, , &w, &h)
        IniWrite(x, POOL_INI, "Board", "X")
        IniWrite(y, POOL_INI, "Board", "Y")
        IniWrite(w, POOL_INI, "Board", "W")
        IniWrite(h, POOL_INI, "Board", "H")
    }
    ; the window just hides; its pages keep running
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

PoolShow() {
    PoolPaintState()
    PoolRefreshList()
    pg.Show()
}

PoolPaintState() {
    try {
        names := Map("off", "Off", "starting", "Starting...", "signin", "Needs sign-in", "account", "Wrong or unknown account", "ready", "Ready")
        pg["State"].Text := "Copilot pool: " names.Get(poolState, poolState)
        pg["Reason"].Text := poolReason
        kind := PoolAccountKind()
        pg["Account"].Text := "Account: " (kind = "" ? "not known yet"
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
        pg["ViewInfo"].Text := "ready: " ready ", open as your windows: " held
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
    if (confirm && MsgBox("Sign out of Copilot and restart the pool?`n`n"
        . "A window opens on Microsoft's sign-out page, which ends this sign-in at Microsoft too. "
        . "When it says you're signed out, close that window: the pool then forgets the sign-in on this PC and restarts.`n`n"
        . "(With single sign-on on, a work PC may sign you in again with your Windows account.)"
        , "Copilot pool", "YesNo Icon? 0x40000") != "Yes")      ; 0x40000 = always on top
        return
    IniWrite(1, POOL_INI, "Pending", "WipeSignIn")
    PoolSet("WorkConfirmed", "")
    PoolLog("sign out asked")
    if (env = 0 || envError != "") {
        PoolRestart("/show")
        return
    }
    if IsObject(signinView) {                    ; a sign-in window is open: reuse nothing, close it quietly
        old := signinView
        signinView := 0
        try old.ctrl.Close()
        try old.gui.Destroy()
    }
    personal := (PoolAccountKind() = "personal")
    v := { id: 0, gui: 0, ctrl: 0, wv: 0, state: "loading", host: "", onLogin: false, dead: false,
        jobId: "", reqId: "", conv: "", lastUse: A_TickCount, signin: true, signout: true, step: personal ? 1 : 2 }
    try {
        v.gui := Gui("+Resize +AlwaysOnTop", "Signing out of Copilot (Caption Companion)")
        v.gui.OnEvent("Size", (g, mm, *) => (mm != -1 && v.ctrl ? v.ctrl.Fill() : 0))
        v.gui.OnEvent("Close", (*) => PoolCloseSignIn())
        v.gui.Show("w900 h700")
        signinView := v
        ; personal accounts: Microsoft account sign-out first, then the work/school sign-out
        PoolInitView(v, true, personal ? "https://login.live.com/logout.srf" : POOL_SIGNOUT_URL)
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

; At start: a sign-out asked for last time deletes the sign-in folder (now that nothing uses it)
PoolWipeIfAsked() {
    if DirExist(POOL_WEB_OLD) {                   ; sign-in data from an early test version: not kept in data\
        try DirDelete(POOL_WEB_OLD, true)
        PoolLog(DirExist(POOL_WEB_OLD) ? "old sign-in folder in data\ could NOT be deleted" : "old sign-in folder in data\ deleted")
    }
    if (IniRead(POOL_INI, "Pending", "WipeSignIn", "0") != "1")
        return
    Loop 30 {
        try DirDelete(POOL_WEB, true)
        if !DirExist(POOL_WEB)
            break
        Sleep(200)                                ; the old browser processes may still be closing
    }
    IniWrite(0, POOL_INI, "Pending", "WipeSignIn")
    PoolLog(DirExist(POOL_WEB) ? "sign-in folder could NOT be deleted (in use)" : "signed out (sign-in folder deleted)")
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

PoolHosts() {
    a := []
    for h in StrSplit(PoolSetting("AllowedHosts"), ",", " `t")
        if (h != "")
            a.Push(StrLower(h))
    return a
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
