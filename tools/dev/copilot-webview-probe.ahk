#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\..\..\app\lib\WebView2\WebView2.ahk
#Include %A_ScriptDir%\..\..\app\Json.ahk

; ==============================================================================
;  copilot-webview-probe.ahk  -  can AHK host its own hidden Copilot "tabs"?
;
;  Tests the idea behind an AHK Copilot pool (like the extension's, but with no
;  browser): Copilot pages hosted in WebView2 inside AutoHotkey.
;
;  1. Run it. It runs in 32-bit (what workmates have). If you started it in
;     64-bit it offers to restart in 32-bit.
;  2. "1. Open Copilot and sign in": a window opens on Copilot. Sign in with
;     your WORK account if asked. Wait until the probe says "ready".
;  3. "2. Test hidden views": opens hidden Copilot views (they share your
;     sign-in) and sends a short test prompt to all of them at once.
;     If something fails, the views log "WHAT IT SEES" (buttons, focus, page
;     state). "What do views see?" asks for that at any time.
;  4. "Copy report" puts the log on the clipboard (also saved as
;     copilot-webview-probe.txt next to this file). Paste it to Claude.
;
;  Try both "Keep them" choices, and "single sign-on" on and off (that one needs
;  a restart of the probe; the two modes keep separate sign-ins).
;
;  The only thing it ever sends to Copilot is the test prompt in the box.
;  Sign-in data stays in %LOCALAPPDATA%\CaptionCompanion\webview-probe\. Delete
;  that folder to sign out.
;
;  Dev self-check (no Copilot, no window): AutoHotkey32.exe copilot-webview-probe.ahk /selftest
;  -> writes copilot-webview-selftest.txt and exits 0 (ok) or 1 (failed).
; ==============================================================================

P_ROOT := FullPath(A_ScriptDir "\..\..")
P_DATA := EnvGet("LOCALAPPDATA") "\CaptionCompanion\webview-probe"   ; sign-in data: never in a OneDrive-synced folder
P_EXE32 := P_ROOT "\runtime\AutoHotkey32.exe"
P_WORKER := A_ScriptDir "\copilot-webview-worker.js"
P_REPORT := A_ScriptDir "\copilot-webview-probe.txt"

if HasArg("/selftest") {
    ExitApp(SelfTest() ? 0 : 1)
}

if (A_PtrSize = 8 && !HasArg("/allow64") && FileExist(P_EXE32)) {
    r := MsgBox("This was started with 64-bit AutoHotkey.`n`nWorkmates use the 32-bit one in runtime\, so that is what should be tested.`n`nRestart the probe in 32-bit?", "Copilot WebView probe", "YesNo Icon?")
    if (r = "Yes") {
        Run('"' P_EXE32 '" "' A_ScriptFullPath '"')
        ExitApp()
    }
}

env := 0                ; the WebView2 environment (browser engine + sign-in folder), shared by all views
mainView := 0           ; the visible Copilot window
pool := []              ; the hidden views
logLines := []
jobSeq := 0
pendingTest := false    ; waiting for every hidden view to be ready before sending
testStart := 0
testRunning := false
poolShown := false
workerJs := ""

; ---------------------------------------------------------------- window
G := Gui(, "Copilot WebView probe")
G.SetFont("s9", "Segoe UI")
G.Add("Text", "xm w540 vInfo", "AutoHotkey " A_AhkVersion "  |  " (A_PtrSize * 8) "-bit  |  Windows " A_OSVersion)
G.Add("Text", "xm y+10", "Copilot address:")
G.Add("Edit", "xm w540 vUrl", "https://m365.cloud.microsoft/chat")
G.Add("CheckBox", "xm vSso Checked", "Sign in with my Windows account (single sign-on). Fixed once Copilot is opened.")
G.Add("Button", "xm w260 h30", "1. Open Copilot and sign in").OnEvent("Click", OpenMain)
G.Add("Text", "x+10 yp+8 w270 vMainState", "Not opened yet")
G.Add("Text", "xm y+18", "Hidden views:")
G.Add("Edit", "x+6 yp-3 w45 Number vCount", "2")
G.Add("UpDown", "Range1-6", 2)
G.Add("Text", "x+14 yp+3", "Keep them:")
G.Add("DropDownList", "x+6 yp-3 w220 vHideHow Choose1", ["in a hidden window", "in a window moved off-screen"])
G.Add("CheckBox", "xm y+8 vFocusEmu Checked", "Hidden views act as if they have focus (focus emulation)")
G.Add("Text", "xm y+12", "Test prompt  ({n} becomes the view number):")
G.Add("Edit", "xm w540 vPrompt", "Reply with only the number {n}, nothing else. (automation test)")
G.Add("Button", "xm w175 h30", "2. Test hidden views").OnEvent("Click", TestPool)
G.Add("Button", "x+8 w175 h30", "Test the visible window").OnEvent("Click", TestMain)
G.Add("Button", "x+8 w174 h30 vBtnShow", "Show hidden views").OnEvent("Click", ToggleShow)
G.Add("Text", "xm y+8 w540 vPoolState", "Hidden views: none")
G.Add("Edit", "xm w540 h240 ReadOnly -Wrap +HScroll vLog")
G.Add("Button", "xm w130 h28", "Copy report").OnEvent("Click", CopyReport)
G.Add("Button", "x+7 w130 h28", "What do views see?").OnEvent("Click", AskDiag)
G.Add("Button", "x+7 w130 h28", "Developer tools").OnEvent("Click", DevTools)
G.Add("Button", "x+7 w129 h28", "Close hidden views").OnEvent("Click", (*) => ClosePool(true))
G.OnEvent("Close", (*) => ExitApp())
G.Show()
OnExit(CleanUp)
SetTimer(Watchdog, 1000)

try {
    workerJs := FileRead(P_WORKER, "UTF-8")
    Log("Probe started (" (A_PtrSize * 8) "-bit). Worker script loaded.")
} catch as err {
    Log("PROBLEM: can't read " P_WORKER " - " err.Message)
}

; ==============================================================================
; Engine + views
; ==============================================================================
EnsureEnv() {
    global env
    if env
        return env
    sso := G["Sso"].Value
    dir := P_DATA "\" (sso ? "sso" : "no-sso")
    DirCreate(dir)
    Log("Starting the browser engine (single sign-on " (sso ? "ON" : "OFF") ")...")
    t := A_TickCount
    env := WebView2.CreateEnvironmentAsync({ AllowSingleSignOnUsingOSPrimaryAccount: sso ? 1 : 0 }, dir).await(30000)
    G["Sso"].Enabled := false
    ver := ""
    try ver := env.BrowserVersionString
    Log("Browser engine started in " Secs(A_TickCount - t) " - WebView2 runtime " ver)
    G["Info"].Text .= "  |  WebView2 " ver
    return env
}

NewView(kind, id) {
    v := { id: id, kind: kind, state: "", vis: "", created: A_TickCount, readyAt: 0,
        jobId: "", sentAt: 0, lastHost: "", gui: 0, ctrl: 0, wv: 0 }
    if (kind = "main") {
        v.gui := Gui("+Resize", "Copilot (probe) - sign in here")
        v.gui.OnEvent("Size", MainResized)
        v.gui.Show("w1000 h760")
    } else {
        v.gui := Gui("+ToolWindow +Owner" G.Hwnd, "Hidden Copilot view " id)
        PlacePoolWindow(v)
    }
    v.ctrl := env.CreateCoreWebView2ControllerAsync(v.gui.Hwnd).await(30000)
    v.ctrl.IsVisible := true          ; "visible" to the engine even when its window is hidden
    v.wv := v.ctrl.CoreWebView2
    try v.wv.Settings.IsStatusBarEnabled := false
    if (kind = "pool") {
        try v.wv.Settings.AreDefaultScriptDialogsEnabled := false   ; a hidden view must never wait on a dialog
        v.wv.add_NewWindowRequested(PoolNewWindow.Bind(v))
        v.focusEmu := G["FocusEmu"].Value
        if v.focusEmu {
            try {
                v.wv.CallDevToolsProtocolMethodAsync("Emulation.setFocusEmulationEnabled", '{"enabled":true}').await(5000)
            } catch as err {
                Log(Name(v) " focus emulation FAILED: " err.Message)
            }
        }
    }
    v.wv.add_WebMessageReceived(ViewMessage.Bind(v))
    v.wv.add_NavigationCompleted(ViewNavDone.Bind(v))
    v.wv.add_ProcessFailed(ViewProcessFailed.Bind(v))
    cfg := Map("id", id, "url", G["Url"].Value)
    v.wv.AddScriptToExecuteOnDocumentCreatedAsync("window.__lccPool=" Json.Stringify(cfg) ";`n" workerJs).await(10000)
    v.wv.Navigate(G["Url"].Value)
    return v
}

PlacePoolWindow(v) {
    if poolShown
        v.gui.Show("NoActivate x" (60 + 40 * v.id) " y" (60 + 40 * v.id) " w1100 h800")
    else if (G["HideHow"].Value = 2)
        v.gui.Show("NoActivate x-20000 y-20000 w1100 h800")
    else
        v.gui.Show("Hide w1100 h800")
}

MainResized(g, minMax, w, h) {
    try {
        if (minMax != -1 && IsObject(mainView) && mainView.ctrl)
            mainView.ctrl.Fill()
    }
}

OpenMain(*) {
    global mainView
    if (workerJs = "") {
        MsgBox("The worker script is missing:`n" P_WORKER)
        return
    }
    if IsObject(mainView) {
        mainView.gui.Show()
        return
    }
    try {
        EnsureEnv()
        mainView := NewView("main", 0)
        Log("Visible window opened. Sign in if asked; wait for 'ready'.")
    } catch as err {
        Log("PROBLEM opening Copilot: " err.Message " (" err.What ", line " err.Line ")")
        mainView := 0
    }
    UpdateStates()
}

TestPool(*) {
    global pendingTest, testStart, testRunning
    if !(IsObject(mainView) && mainView.readyAt) {
        MsgBox("First do step 1: open Copilot and sign in, and wait until it says 'ready'.", "Copilot WebView probe")
        return
    }
    if (testRunning || pendingTest) {
        Log("A test is already running.")
        return
    }
    n := Integer(G["Count"].Value || 2)
    if (pool.Length != n || (pool.Length && (pool[1].hideHow != G["HideHow"].Value || pool[1].focusEmu != G["FocusEmu"].Value)))
        ClosePool(false)
    try {
        while (pool.Length < n) {
            v := NewView("pool", pool.Length + 1)
            v.hideHow := G["HideHow"].Value
            pool.Push(v)
            Log("Hidden view " v.id " created (" G["HideHow"].Text ", focus emulation " (v.focusEmu ? "on" : "off") ")")
        }
    } catch as err {
        Log("PROBLEM creating hidden views: " err.Message " (" err.What ", line " err.Line ")")
        return
    }
    pendingTest := true
    testStart := A_TickCount
    Log("Test: waiting for " n " hidden view(s) to be ready...")
    TryDispatch()
}

TryDispatch() {
    global pendingTest, testRunning
    if !pendingTest
        return
    for v in pool
        if (v.state != "ready")
            return
    pendingTest := false
    testRunning := true
    for v in pool
        SendJob(v)
    Log("Sent the test to all " pool.Length " hidden view(s) at the same time. Waiting for answers...")
}

TestMain(*) {
    if !(IsObject(mainView) && mainView.state = "ready") {
        MsgBox("The visible window isn't ready yet (see the state next to button 1).", "Copilot WebView probe")
        return
    }
    SendJob(mainView)
    Log("Sent the test to the visible window.")
}

SendJob(v) {
    global jobSeq
    jobSeq += 1
    v.jobId := "j" jobSeq
    v.sentAt := A_TickCount
    prompt := StrReplace(G["Prompt"].Value, "{n}", v.id = 0 ? 1 : v.id)
    v.wv.PostWebMessageAsString(Json.Stringify(Map("t", "job", "jobId", v.jobId, "prompt", prompt)))
}

ToggleShow(*) {
    global poolShown
    poolShown := !poolShown
    G["BtnShow"].Text := poolShown ? "Hide hidden views" : "Show hidden views"
    for v in pool
        try PlacePoolWindow(v)
}

ClosePool(say) {
    global pendingTest, testRunning
    for v in pool {
        try v.ctrl.Close()
        try v.gui.Destroy()
    }
    if (say && pool.Length)
        Log("Closed " pool.Length " hidden view(s).")
    pool.Length := 0
    pendingTest := false
    testRunning := false
    UpdateStates()
}

DevTools(*) {
    if IsObject(mainView)
        try mainView.wv.OpenDevToolsWindow()
}

AskDiag(*) {
    views := []
    if IsObject(mainView)
        views.Push(mainView)
    for v in pool
        views.Push(v)
    if !views.Length {
        Log("No views open yet.")
        return
    }
    for v in views
        try v.wv.PostWebMessageAsString('{"t":"diag"}')
}

; The worker asks for "real" input (trusted events through the DevTools protocol, no window focus needed).
DoTrusted(v, m) {
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
        }
        Log(Name(v) " trusted " op ": done")
    } catch as err {
        Log(Name(v) " trusted " op " FAILED: " err.Message)
    }
    try v.wv.PostWebMessageAsString('{"t":"trusted-done","reqId":' m.Get("reqId", 0) ',"ok":' ok '}')
}

CleanUp(*) {
    for v in pool
        try v.ctrl.Close()
    if IsObject(mainView)
        try mainView.ctrl.Close()
}

; ==============================================================================
; Events from the views (keep these short: they run inside a COM callback)
; ==============================================================================
ViewMessage(v, sender, args) {
    raw := ""
    try raw := args.TryGetWebMessageAsString()
    if (raw != "")
        SetTimer(HandleMessage.Bind(v, raw), -1)
}

HandleMessage(v, raw) {
    try {
        m := Json.Parse(raw)
    } catch {
        return
    }
    t := m.Get("t", "")
    if m.Has("vis")
        v.vis := m["vis"]
    switch t {
        case "hello":
            Log(Name(v) " Copilot page loaded: " m.Get("path", "") " (page is " v.vis ")")
        case "vis":
            Log(Name(v) " page visibility changed: " v.vis)
        case "state":
            s := m.Get("state", "")
            if (s != v.state) {
                v.state := s
                if (s = "ready" && !v.readyAt) {
                    v.readyAt := A_TickCount
                    Log(Name(v) " READY - Copilot's input box found, " Secs(v.readyAt - v.created) " after opening (page is " v.vis ")")
                } else if (s = "waiting-for-input-box") {
                    Log(Name(v) " waiting for Copilot's input box" (v.kind = "main" ? " - sign in if asked" : ""))
                }
            }
            UpdateStates()
            TryDispatch()
        case "trusted":
            DoTrusted(v, m)
        case "diag":
            info := m.Get("info", Map())
            s := ""
            if (info is Map)
                for k, val in info
                    s .= "`r`n            " k ": " (IsObject(val) ? "?" : val)
            Log(Name(v) " WHAT IT SEES (" m.Get("where", "") "):" s)
        case "log":
            d := m.Get("d", "")
            Log(Name(v) " " m.Get("m", "") (d is String && d != "" ? " | " d : ""))
        case "result":
            if (m.Get("jobId", "") != v.jobId)
                return
            total := A_TickCount - v.sentAt
            v.jobId := ""
            if m.Get("ok", 0)
                Log(Name(v) " ANSWER after " Secs(total) " (typed by " m.Get("how", "?") ", page " m.Get("vis", "?") "): " Short(m.Get("text", "")))
            else
                Log(Name(v) " FAILED after " Secs(total) ": " m.Get("error", "?"))
            v.lastMs := total
            v.lastOk := m.Get("ok", 0)
            CheckAllDone()
    }
}

CheckAllDone() {
    global testRunning
    if !testRunning
        return
    for v in pool
        if (v.jobId != "")
            return
    testRunning := false
    ok := 0, slowest := 0, sum := 0
    for v in pool {
        if v.HasOwnProp("lastOk") && v.lastOk
            ok += 1
        slowest := Max(slowest, v.HasOwnProp("lastMs") ? v.lastMs : 0)
        sum += v.HasOwnProp("lastMs") ? v.lastMs : 0
    }
    line := "RESULT: " ok " of " pool.Length " hidden view(s) answered. Slowest " Secs(slowest)
    if (pool.Length > 1)
        line .= ", one after another would have been about " Secs(sum) " -> " (slowest < sum * 0.8 ? "they ran in parallel." : "they did NOT run in parallel.")
    Log(line)
}

ViewNavDone(v, sender, args) {
    try {
        src := sender.Source
        host := RegExMatch(src, "i)^\w+://([^/?#]+)", &mm) ? mm[1] : SubStr(src, 1, 40)
        ok := args.IsSuccess
        status := args.WebErrorStatus
        if !ok {
            if (status != 14)          ; 14 = cancelled (normal during sign-in redirects)
                SetTimer(Log.Bind(Name(v) " page FAILED to load: " host " (" WebErrorName(status) ")"), -1)
        } else if (host != v.lastHost) {
            v.lastHost := host
            SetTimer(Log.Bind(Name(v) " now on: " host), -1)
        }
    }
}

ViewProcessFailed(v, sender, args) {
    kind := ""
    try kind := args.ProcessFailedKind
    SetTimer(Log.Bind(Name(v) " BROWSER PROCESS FAILED (kind " kind ")"), -1)
}

PoolNewWindow(v, sender, args) {
    try args.Handled := true           ; hidden views never open pop-ups
    SetTimer(Log.Bind(Name(v) " blocked a pop-up"), -1)
}

Watchdog() {
    global pendingTest, testRunning
    if (pendingTest && A_TickCount - testStart > 90000) {
        pendingTest := false
        list := ""
        for v in pool
            if (v.state != "ready")
                list .= (list = "" ? "" : ", ") v.id " (" (v.state = "" ? "page not loaded" : v.state) ")"
        Log("TIMEOUT: hidden view(s) not ready after 90 s: " list ". Try 'Show hidden views' to see them.")
    }
    for v in pool {
        if (v.jobId != "" && A_TickCount - v.sentAt > 120000) {
            try v.wv.PostWebMessageAsString(Json.Stringify(Map("t", "abort", "jobId", v.jobId)))
            v.jobId := ""
            v.lastOk := 0
            v.lastMs := 120000
            Log(Name(v) " TIMEOUT: no answer after 120 s")
            CheckAllDone()
        }
    }
}

; ==============================================================================
; Status, log, report
; ==============================================================================
UpdateStates() {
    if IsObject(mainView)
        G["MainState"].Text := "Visible window: " (mainView.state = "" ? "loading" : mainView.state) (mainView.vis ? " (" mainView.vis ")" : "")
    if !pool.Length {
        G["PoolState"].Text := "Hidden views: none"
        return
    }
    s := ""
    for v in pool
        s .= (s = "" ? "" : "   ") v.id ": " (v.state = "" ? "loading" : v.state)
    G["PoolState"].Text := "Hidden views - " s
}

Log(msg) {
    logLines.Push(FormatTime(, "HH:mm:ss") "  " msg)
    if (logLines.Length > 500)
        logLines.RemoveAt(1)
    try {
        text := ""
        for l in logLines
            text .= l "`r`n"
        G["Log"].Value := text
        SendMessage(0x0115, 7, 0, G["Log"])     ; WM_VSCROLL, SB_BOTTOM
    }
}

CopyReport(*) {
    head := "Copilot WebView probe report - " FormatTime(, "yyyy-MM-dd HH:mm") "`r`n"
        . "AutoHotkey " A_AhkVersion " " (A_PtrSize * 8) "-bit, Windows " A_OSVersion "`r`n"
        . "Single sign-on: " (G["Sso"].Value ? "ON" : "OFF") ", hidden views kept " G["HideHow"].Text
        . ", focus emulation " (G["FocusEmu"].Value ? "ON" : "OFF") "`r`n"
        . "Address: " G["Url"].Value "`r`n" G["Info"].Text "`r`n`r`n"
    body := ""
    for l in logLines
        body .= l "`r`n"
    A_Clipboard := head body
    try {
        f := FileOpen(P_REPORT, "w", "UTF-8")
        f.Write(head body)
        f.Close()
    }
    Log("Report copied to the clipboard (also saved as " P_REPORT ")")
}

; ==============================================================================
; Self-check for development: engine + one hidden view + a message round trip
; ==============================================================================
SelfTest() {
    out := A_ScriptDir "\copilot-webview-selftest.txt"
    lines := "AutoHotkey " A_AhkVersion " " (A_PtrSize * 8) "-bit`r`n"
    ok := false
    try {
        e := WebView2.CreateEnvironmentAsync({ AllowSingleSignOnUsingOSPrimaryAccount: 0 }, A_Temp "\lcc-webview-selftest").await(30000)
        lines .= "engine: " e.BrowserVersionString "`r`n"
        g := Gui("+ToolWindow")
        g.Show("Hide w800 h600")
        c := e.CreateCoreWebView2ControllerAsync(g.Hwnd).await(30000)
        c.IsVisible := true
        w := c.CoreWebView2
        res := { got: "" }
        w.add_WebMessageReceived((s, a) => (res.got := a.TryGetWebMessageAsString()))
        w.AddScriptToExecuteOnDocumentCreatedAsync("window.__lccSelf = 1;").await(10000)
        w.NavigateToString("<html><body><script>chrome.webview.postMessage(JSON.stringify({injected: window.__lccSelf === 1, vis: document.visibilityState}))</script></body></html>")
        t := A_TickCount
        while (res.got = "" && A_TickCount - t < 20000)
            Sleep(50)
        lines .= "message from page: " (res.got = "" ? "(none - timed out)" : res.got) "`r`n"
        ok := InStr(res.got, '"injected":true') > 0
        try c.Close()
    } catch as err {
        lines .= "ERROR: " err.Message " (" err.What ", line " err.Line ")`r`n"
    }
    lines .= ok ? "OK`r`n" : "FAILED`r`n"
    try {
        f := FileOpen(out, "w", "UTF-8")
        f.Write(lines)
        f.Close()
    }
    return ok
}

; ==============================================================================
; Small helpers
; ==============================================================================
Name(v) => v.kind = "main" ? "[visible]" : "[hidden " v.id "]"
Secs(ms) => Format("{:.1f} s", ms / 1000)
Short(s) => (s := RegExReplace(s, "\s+", " "), StrLen(s) > 160 ? SubStr(s, 1, 160) "..." : s)

HasArg(a) {
    for x in A_Args
        if (x = a)
            return true
    return false
}

FullPath(p) {
    buf := Buffer(2048, 0)
    DllCall("GetFullPathNameW", "str", p, "uint", 1024, "ptr", buf, "ptr", 0)
    return StrGet(buf)
}

WebErrorName(code) {
    static names := Map(0, "unknown", 1, "certificate name wrong", 2, "certificate expired", 5, "certificate invalid",
        6, "server unreachable", 7, "timed out", 9, "connection aborted", 10, "connection reset", 11, "disconnected",
        12, "cannot connect", 13, "address not found", 14, "cancelled", 15, "redirect failed", 16, "unexpected error",
        17, "sign-in required", 18, "proxy sign-in required")
    return names.Has(code) ? names[code] " (" code ")" : "error " code
}
