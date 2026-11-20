#Requires AutoHotkey v2.0
#SingleInstance Force
try TraySetIcon(A_ScriptDir "\icons\screen-ask.ico")   ; its own icon (tray, windows)
try DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", "CaptionCompanion.ScreenAsk")
#Include app-paths.ahk
#Include Json.ahk
#Include debug-trace.ahk
#Include webview-guard.ahk
#Include *i %A_ScriptDir%\lib\WebView2\WebView2.ahk
; ==============================================================================
; screen-ask.ahk  -  Screen ask: freeze the screen, mark something, ask Copilot about it
;
; * Press the shortcut (Ctrl+Shift+Alt+A by default, Settings to change it): every monitor is
;   captured and shown "frozen" on top of everything. Draw around what you mean (free hand, box or
;   oval - as many marks as you like), type a question in the box that appears (or leave it empty:
;   "Explain what I marked") and press Enter. Esc / Cancel = nothing is sent.
; * What goes to the AI: image 1 = all monitors with your marks drawn on (the context); then a sharp
;   close-up of each marked area (marks close together share one), because with 2-3 monitors the
;   whole picture gets shrunk by the AI and small text would be unreadable. Plus a short prompt
;   (Prompt setting) that says what the images are and what you asked.
; * It's sent through the Copilot pool (copilot-pool.ahk, whichever chat site it uses), shown as the
;   pool's "Screen ask" Copilot window: you watch the answer and keep chatting there. The pool's own
;   rules apply (work account only, never sends twice). If it can't be sent, the marked screenshot
;   goes on the clipboard (paste it into Copilot yourself) and a note says why.
; * Its own app and process, generic (no call words). OFF by default for workmates: each person turns
;   it on from the Companion's tray (screen-ask-link.ahk, live-captions.ini [ScreenAsk] Enabled).
;   Started by the Companion it has no tray icon and ends with the Companion; started on its own
;   (double-click) it has its own tray icon. One copy only.
; * The frozen screen is a WebView2 page (screen-ask.html) from a folder on this PC only
;   (%LOCALAPPDATA%\CaptionCompanion\screen-ask): it never loads anything from the internet.
;   Screenshots never go to a synced folder and are deleted when done (or after KeepMin minutes).
;   Logs and the debug trace never hold the question or any image.
; * Multi-monitor and mixed scaling: the capture and the overlay work in real screen pixels
;   (per-monitor DPI on this thread); the page draws 1:1 and sizes its toolbar per monitor.
;
; Messages (WM_COPYDATA, JSON text):
;   tag SA_TAG   app -> screen ask: {t:"capture"} {t:"settings"} {t:"quit"}
;   tag POOL_TAG screen ask <-> pool: "ask" with images (see the top of copilot-pool.ahk), replies
;                queued / sent / done
; Arguments: <Companion window handle> = started by the Companion (no tray icon, ends with it);
;            /capture = capture right away; /settings = open the settings.
; ==============================================================================
SA_TITLE := "Caption Companion Screen ask"
SA_TAG := 0x3CC5
POOL_TAG := 0x3CC3
POOL_WIN := "Caption Companion Copilot pool ahk_class AutoHotkeyGUI"
SA_INI := DATA_DIR "\screen-ask.ini"
SA_LOG := DATA_DIR "\screen-ask.log"
SA_LOCAL := APP_LOCAL "\screen-ask"             ; the overlay page + the frozen screen (this PC only)
SA_WEBDATA := APP_LOCAL "\screen-ask-web"       ; the overlay's own browser folder (no sign-in, nothing shared)
SA_HOST := "screen-ask.example"                 ; the local folder's address inside the overlay
SA_COLORS := Map("Red", "#FF3B30", "Orange", "#FF9500", "Yellow", "#FFD60A", "Green", "#34C759",
    "Cyan", "#22D3EE", "Magenta", "#FF2DAA")
SA_DEFAULTS := Map(
    "Hotkey", "^+!a",              ; Ctrl+Shift+Alt+A (AutoHotkey key names: ^ Ctrl, + Shift, ! Alt, # Win)
    "DefaultQuestion", "Explain what I marked.",
    "WholeQuestion", "Explain what's on my screen.",   ; Whole screen, nothing typed
    "MarkColor", "Red",            ; a name from the list in Settings (the prompt says which colour)
    "LineWidth", 4,                ; at 100% scaling (thicker on scaled monitors)
    "CloseUps", 1,                 ; send close-ups of the marked areas too
    "MaxCloseUps", 3,              ; more groups of marks than this: one close-up around all of them
    "FullMaxSide", 4096,           ; the whole-screen image is made smaller than this (0 = never)
    "NewChat", 1,                  ; 1 = every capture starts a fresh chat; 0 = it goes on in the same chat
    "Conversation", "screen-ask",  ; the pool's name for the Screen ask window (remembers its place)
    "Tool", "pen",                 ; last used marking tool
    "KeepMin", 30,                 ; leftover image files are deleted after this long
    "MaxMB", 350,                  ; the overlay's browser over this while hidden = it's started fresh (memory guard)
    ; {{screens}} {{marked}} {{closeups}} {{focus}} {{question}} - \n = new line
    "Prompt", "Image 1 is a screenshot of my screen ({{screens}}).{{marked}}{{closeups}}{{focus}}\n\n{{question}}")

DetectHiddenWindows(true)
OnError(SaOnError)

SA_HOST_HWND := (A_Args.Length >= 1 && IsInteger(A_Args[1])) ? Integer(A_Args[1]) : 0
saArgs := ""
for a in A_Args
    saArgs .= " " a

saMain := 0          ; hidden window: receives messages (pool replies, Companion commands)
saHotkey := ""
env := 0
ov := {gui: 0, ctrl: 0, wv: 0, ready: false, failed: "", shown: false}
saShot := 0          ; the screenshot on screen: {path, vx, vy, vw, vh, monitors, t0}
saReqs := Map()      ; request id -> {prompt, files, full, at, sent, inPool}
saSeq := 0
saToastGui := 0
saProgressText := "" ; the "on its way" note now showing
saPool := 0          ; the pool's last "state" message (Map)
saShotSeq := 0       ; each capture's id (messages from the page say which capture they're about)

SaBuildMain()
OnMessage(0x4A, SaOnCopyData)
OnMessage(0x02E0, SaOnDpiChanged)     ; WM_DPICHANGED: the overlay keeps its exact size across monitors
OnExit(SaOnExit)
SaTrimLog()
SaCleanup(true)
SaSetHotkey()
if SA_HOST_HWND {
    A_IconHidden := true
    SetTimer(SaCheckHost, 2000)
} else {
    SaBuildTray()
}
SaLog("started (" (A_PtrSize * 8) "-bit, version " APP_VERSION (SA_HOST_HWND ? ", by the Companion" : ", on its own") ")")
SetTimer(SaStartOverlay, -50)
SetTimer(SaHousekeep, 30000)
SetTimer(SaKeepPool, -1500)          ; the pool runs, with Screen ask's own page reserved in it
SetTimer(SaKeepPool, 5000)
if InStr(saArgs, "/settings")
    SetTimer(SaShowSettings, -300)

SaBuildMain() {
    global saMain
    saMain := Gui("+ToolWindow", SA_TITLE)
    saMain.Show("Hide w10 h10")
}

SaBuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Capture and ask (" SaHotkeyText() ")", (*) => SaCapture())
    A_TrayMenu.Add("Settings...", (*) => SaShowSettings())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Capture and ask (" SaHotkeyText() ")"
    A_IconTip := "Screen ask - " SaHotkeyText()
}

SaCheckHost() {
    if !WinExist("ahk_id " SA_HOST_HWND)
        ExitApp()
}

; ==============================================================================
; The shortcut
; ==============================================================================
SaSetHotkey() {
    global saHotkey
    if (saHotkey != "") {
        try Hotkey(saHotkey, "Off")
        saHotkey := ""
    }
    hk := Trim(SaSetting("Hotkey"))
    if (hk = "")
        return true
    try {
        Hotkey(hk, (*) => SaCapture(), "On")
        saHotkey := hk
        return true
    } catch as err {
        SaLog("the shortcut " hk " couldn't be set: " err.Message)
        SaToast("Screen ask: the shortcut " SaHotkeyText(hk) " couldn't be set (" err.Message "). Change it in Settings.", 8000)
        return false
    }
}

; "^+!a" -> "Ctrl+Shift+Alt+A"
SaHotkeyText(hk := "") {
    if (hk = "")
        hk := Trim(SaSetting("Hotkey"))
    if (hk = "")
        return "no shortcut"
    out := ""
    mods := RegExReplace(hk, "[^#^+!<>*~$].*$")          ; the modifier symbols in front of the key
    for pair in [["#", "Win+"], ["^", "Ctrl+"], ["+", "Shift+"], ["!", "Alt+"]]
        if InStr(mods, pair[1])
            out .= pair[2]
    key := RegExReplace(hk, "^[#^+!<>*~$]+")
    return out (StrLen(key) = 1 ? StrUpper(key) : key)
}

; ==============================================================================
; The overlay: one borderless window over every monitor, with the page in it. Made once at the
; start (so the shortcut is instant), hidden until a capture.
; ==============================================================================
SaStartOverlay() {
    global env
    try {
        if !IsSet(WebView2)
            throw Error("the WebView2 library is missing (app\lib\WebView2)")
        DirCreate(SA_LOCAL)
        DirCreate(SA_WEBDATA)
        FileCopy(A_ScriptDir "\screen-ask.html", SA_LOCAL "\screen-ask.html", true)   ; always this version's page
        freed := 0                                   ; built-in browsers left behind by closed apps: end them
        if (n := WvgSweepOrphans(&freed))
            SaLog("ended " n " leftover built-in browser(s) of closed apps (" freed " MB)")
        old := SaPm()
        try {
            ; (a title that doesn't start like SA_TITLE: other apps find the message window by its title)
            ov.gui := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale", "Screen ask - mark and ask")
            ov.gui.BackColor := "000000"
            ov.gui.Show("Hide x0 y0 w320 h240")
            env := WebView2.CreateEnvironmentAsync(0, SA_WEBDATA).await(60000)
            ov.ctrl := env.CreateCoreWebView2ControllerAsync(ov.gui.Hwnd).await(30000)
            try ov.ctrl.ShouldDetectMonitorScaleChanges := false
            try ov.ctrl.RasterizationScale := 1.0        ; one page pixel = one screen pixel, on every monitor
            try ov.ctrl.DefaultBackgroundColor := 0x000000FF   ; opaque black (bytes A,R,G,B)
            ov.ctrl.IsVisible := true
            ov.wv := ov.ctrl.CoreWebView2
            s := ov.wv.Settings
            try s.IsStatusBarEnabled := false
            try s.AreDevToolsEnabled := AppIsDev()
            try s.AreDefaultContextMenusEnabled := false    ; right-click = undo
            try s.IsZoomControlEnabled := false
            try s.AreDefaultScriptDialogsEnabled := false
            try s.AreBrowserAcceleratorKeysEnabled := false   ; no F5 / Ctrl+P / ... in the overlay
            try s.IsPinchZoomEnabled := false
            ov.wv.SetVirtualHostNameToFolderMapping(SA_HOST, SA_LOCAL, 0)   ; 0 = this page's own files only
            ov.wv.add_WebMessageReceived(SaOnPageMessage)
            ov.wv.add_NavigationStarting(SaNavStarting)
            ov.wv.add_NewWindowRequested(SaNewWindow)
            ov.wv.add_ProcessFailed(SaPageFailed)
            ov.wv.Navigate("https://" SA_HOST "/screen-ask.html")
        } finally {
            SaPmEnd(old)
        }
    } catch as err {
        ov.failed := err.Message
        SaLog("OVERLAY FAILED: " err.Message)
        SaToast("Screen ask couldn't start its screen overlay: " err.Message, 10000)
    }
}

; Only the page from our own folder may load in the overlay
SaNavStarting(sender, args) {
    try {
        uri := args.Uri
        if !RegExMatch(uri, "i)^https://\Q" SA_HOST "\E/") {
            args.Cancel := true
            SetTimer(SaLog.Bind("blocked a page in the overlay: " SubStr(uri, 1, 40)), -1)
        }
    }
}

SaNewWindow(sender, args) {
    try args.Handled := true
}

SaPageFailed(sender, args) {
    kind := -1
    try kind := args.ProcessFailedKind
    SetTimer(SaRestartOverlay.Bind("the overlay page stopped (kind " kind ")"), -1)
}

SaRestartOverlay(why) {
    global env
    SaLog(why " - starting it again")
    SaHideOverlay()
    try ov.ctrl.Close()
    try ov.gui.Destroy()
    ov.gui := 0, ov.ctrl := 0, ov.wv := 0, ov.ready := false, ov.failed := ""
    env := 0
    SetTimer(SaStartOverlay, -1000)
}

; Per-monitor DPI on this thread while we work in real screen pixels (capture, overlay position).
; Returns the previous setting for SaPmEnd.
SaPm() {
    try return DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")   ; PER_MONITOR_AWARE_V2
    return 0
}
SaPmEnd(old) {
    if old
        try DllCall("SetThreadDpiAwarenessContext", "Ptr", old, "Ptr")
}

; The overlay spans monitors with different scaling: Windows would resize it when it "moves" to
; another monitor's DPI - it must keep exactly the size we gave it
SaOnDpiChanged(wParam, lParam, msg, hwnd) {
    if (IsObject(ov.gui) && hwnd = ov.gui.Hwnd)
        return 0
}

; ==============================================================================
; Capture: every monitor, as it is right now
; ==============================================================================
SaCapture(*) {
    global saShot, saShotSeq
    if IsObject(saShot)                        ; already frozen (the shortcut again): nothing to do
        return
    if (ov.failed != "") {
        SaToast("Screen ask isn't working: " ov.failed, 8000)
        return
    }
    if !ov.ready {
        SaToast("Screen ask is still starting - try again in a moment.", 3000)
        return
    }
    t0 := A_TickCount
    old := SaPm()
    try {
        mons := SaMonitors(&vx, &vy, &vw, &vh)
        DllCall("GetCursorPos", "Ptr", pt := Buffer(8, 0))
        cx := NumGet(pt, 0, "Int") - vx, cy := NumGet(pt, 4, "Int") - vy
        name := "shot-" A_TickCount ".png"
        path := SA_LOCAL "\" name
        SaGrab(vx, vy, vw, vh, path)
    } catch as err {
        SaPmEnd(old)
        SaLog("capture FAILED: " err.Message)
        SaToast("Screen ask couldn't capture the screen: " err.Message, 6000)
        return
    }
    SaPmEnd(old)
    tGrab := A_TickCount - t0
    rel := []
    for m in mons
        rel.Push(Map("x", m.x - vx, "y", m.y - vy, "w", m.w, "h", m.h, "scale", m.scale, "primary", m.primary ? 1 : 0))
    saShotSeq += 1
    saShot := {id: saShotSeq, path: path, vx: vx, vy: vy, vw: vw, vh: vh, monitors: rel, t0: t0, shown: false}
    msg := Map("t", "shot", "id", saShotSeq, "src", "https://" SA_HOST "/" name, "w", vw, "h", vh, "monitors", rel,
        "cursor", Map("x", cx, "y", cy), "color", SaColorHex(), "tool", SaSetting("Tool"),
        "lineWidth", SaNum("LineWidth"), "closeUps", SaNum("CloseUps") ? 1 : 0, "maxCloseUps", SaNum("MaxCloseUps"),
        "fullMaxSide", SaNum("FullMaxSide"))
    try ov.wv.MemoryUsageTargetLevel := 0            ; capturing: full speed
    try {
        ov.wv.PostWebMessageAsString(Json.Stringify(msg))
    } catch as err {
        SaLog("couldn't reach the overlay page: " err.Message)
        SaDropShot()
        SetTimer(SaRestartOverlay.Bind("the overlay page didn't answer"), -1)
        return
    }
    DbgTrace("screen", "captured " mons.Length " monitor(s), " vw "x" vh " px in " tGrab " ms")
    SetTimer(SaShowTimeout, -8000)
}

; The page never said it had drawn the screenshot
SaShowTimeout() {
    if (IsObject(saShot) && !saShot.shown) {
        SaLog("the overlay didn't show the screenshot in time")
        SaDropShot()
        SaToast("Screen ask: the frozen screen didn't appear - try again.", 4000)
    }
}

; Every monitor in real pixels: [{x, y, w, h, scale, primary}] and the box around them all
SaMonitors(&vx, &vy, &vw, &vh) {
    list := []
    x0 := 0x7FFFFFFF, y0 := 0x7FFFFFFF, x1 := -0x7FFFFFFF, y1 := -0x7FFFFFFF
    prim := MonitorGetPrimary()
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        scale := 1.0
        try {
            hmon := DllCall("MonitorFromPoint", "Int64", ((l + 1) & 0xFFFFFFFF) | ((t + 1) << 32), "UInt", 2, "Ptr")
            dx := 96, dy := 96
            if !DllCall("shcore\GetDpiForMonitor", "Ptr", hmon, "Int", 0, "UInt*", &dx, "UInt*", &dy)
                scale := dx / 96
        }
        list.Push({x: l, y: t, w: r - l, h: b - t, scale: scale, primary: A_Index = prim})
        x0 := Min(x0, l), y0 := Min(y0, t), x1 := Max(x1, r), y1 := Max(y1, b)
    }
    if !list.Length
        throw Error("no monitor found")
    vx := x0, vy := y0, vw := x1 - x0, vh := y1 - y0
    return list
}

; Copies the screen rectangle into a PNG file (GDI + GDI+)
SaGrab(x, y, w, h, path) {
    sdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", sdc, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", sdc, "Int", w, "Int", h, "Ptr")
    obm := DllCall("SelectObject", "Ptr", mdc, "Ptr", hbm, "Ptr")
    ok := hbm && DllCall("BitBlt", "Ptr", mdc, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", sdc, "Int", x, "Int", y, "UInt", 0x40CC0020)  ; SRCCOPY|CAPTUREBLT
    DllCall("SelectObject", "Ptr", mdc, "Ptr", obm)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", sdc)
    try {
        if !ok
            throw Error("the screen couldn't be copied")
        SaGdipStart()
        pBmp := 0
        r := DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBmp)
        if (r || !pBmp)
            throw Error("GDI+ error " r)
        try {
            r := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBmp, "WStr", path, "Ptr", SaPngClsid(), "Ptr", 0)
            if r
                throw Error("couldn't save the screenshot (GDI+ error " r ")")
        } finally {
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
        }
    } finally {
        if hbm
            DllCall("DeleteObject", "Ptr", hbm)
    }
}

SaGdipStart() {
    static token := 0
    if token
        return
    DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)
    if !token
        throw Error("GDI+ didn't start")
}

SaPngClsid() {
    static clsid := 0
    if !clsid {
        clsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    }
    return clsid
}

; ==============================================================================
; Showing / hiding the frozen screen
; ==============================================================================
SaShowOverlay() {
    if (!IsObject(saShot) || saShot.shown)
        return
    saShot.shown := true
    old := SaPm()
    try {
        h := ov.gui.Hwnd
        ; topmost, exactly over every monitor, shown (SWP_SHOWWINDOW)
        DllCall("SetWindowPos", "Ptr", h, "Ptr", -1, "Int", saShot.vx, "Int", saShot.vy, "Int", saShot.vw, "Int", saShot.vh, "UInt", 0x0040)
        try ov.ctrl.Fill()
        try ov.ctrl.NotifyParentWindowPositionChanged()
    } finally {
        SaPmEnd(old)
    }
    ov.shown := true
    try WinActivate("ahk_id " ov.gui.Hwnd)
    try ov.ctrl.MoveFocus(0)                    ; keys go to the page (Esc, typing the question)
    DbgTrace("screen", "frozen screen shown " (A_TickCount - saShot.t0) " ms after the shortcut")
}

SaHideOverlay() {
    global ov
    if (IsObject(ov.gui) && ov.shown) {
        try ov.wv.MemoryUsageTargetLevel := 1        ; hidden: little memory until the next capture
        try ov.gui.Hide()
        ov.shown := false
    }
}

; Hides the overlay and forgets the screenshot (deletes its file). resetPage: also clear the page
; (not while it is still making the images to send - it clears itself when done)
SaDropShot(resetPage := true) {
    global saShot
    SaHideOverlay()
    if IsObject(saShot) {
        p := saShot.path
        saShot := 0
        try FileDelete(p)
    }
    if resetPage
        try ov.wv.PostWebMessageAsString('{"t":"reset"}')
}

; ==============================================================================
; Messages from the page (only from our own local page)
; ==============================================================================
SaOnPageMessage(sender, args) {
    raw := ""
    try {
        if !RegExMatch(args.Source, "i)^https://\Q" SA_HOST "\E/")
            return
        raw := args.TryGetWebMessageAsString()
    }
    if (raw != "")
        SetTimer(SaHandlePage.Bind(raw), -1)
}

SaHandlePage(raw) {
    global saArgs
    try {
        m := Json.Parse(raw)
    } catch {
        return
    }
    if !(m is Map)
        return
    ; the capture this message is about: a late "send" of an earlier capture must never close a newer one
    mine := IsObject(saShot) && (m.Get("shot", 0) = saShot.id)
    try {
        switch m.Get("t", "") {
            case "ready":
                ov.ready := true
                SaLog("overlay ready")
                if (InStr(saArgs, "/capture") && !IsObject(saShot)) {
                    saArgs := StrReplace(saArgs, "/capture")   ; once (not again if the overlay restarts)
                    SetTimer(SaCapture, -200)
                }
            case "drawn":
                if mine
                    SaShowOverlay()
            case "cancel":
                if mine
                    SaDropShot()
                DbgTrace("screen", "cancelled")
            case "hide":                           ; Send / Copy: the screen comes back while the page makes the images
                if mine
                    SaDropShot(false)
            case "tool":
                t := m.Get("tool", "")
                if (t = "pen" || t = "box" || t = "oval")
                    IniWrite(t, SA_INI, "Settings", "Tool")
            case "settings":
                if mine
                    SaDropShot()
                SetTimer(SaShowSettings, -100)
            case "copy":
                if mine
                    SaDropShot(false)
                SaCopyFromPage(m.Get("b64", ""))
            case "send":
                if mine
                    SaDropShot(false)
                SaSend(m)
            case "error":
                if (mine || !m.Has("shot"))
                    SaDropShot()
                SaLog("page: " m.Get("msg", ""))
                SaToast("Screen ask: " m.Get("msg", "something went wrong"), 6000)
        }
    } catch as err {
        SaLog("ERROR handling '" m.Get("t", "") "': " err.Message)
        SaToast("Screen ask: " err.Message, 6000)
    }
}

; ==============================================================================
; Sending: the images go to the pool's image folder, the request to the pool
; ==============================================================================
SaSend(m) {
    global saSeq
    imgs := m.Get("images", [])
    if !(imgs is Array) || !imgs.Length
        throw Error("no image to send")
    saSeq += 1
    id := "s" A_TickCount "-" saSeq
    DirCreate(APP_IMAGE_INBOX)
    files := [], crops := 0, bytes := 0
    for i, im in imgs {
        path := APP_IMAGE_INBOX "\screen-ask-" id "-" i ".png"
        bytes += SaWriteB64(im.Get("b64", ""), path)
        files.Push(path)
        if (im.Get("kind", "") = "crop")
            crops += 1
    }
    marks := m.Get("marks", 0), screens := m.Get("screens", 1)
    prompt := SaBuildPrompt(Trim(m.Get("question", "")), marks, crops, screens)
    r := {id: id, prompt: prompt, files: files, full: files[1], at: A_TickCount, sent: false, inPool: false, told: false}
    saReqs[id] := r
    DbgTrace("screen", "ask " id ": " marks " mark(s), " files.Length " image(s), " Round(bytes / 1024) " KB, "
        StrLen(prompt) " chars")
    SaLog("ask " id ": " marks " mark(s), " files.Length " image(s), " Round(bytes / 1024) " KB")
    if !SaPoolWindow()
        SaStartPool()
    SaProgress()
    SaFlush()
}

; While a question is on its way: a note that stays until it's in Copilot, saying what it waits for
SaProgress() {
    global saProgressText
    for id, r in saReqs {
        if r.sent
            continue
        s := IsObject(saPool) ? saPool.Get("state", "") : ""
        why := IsObject(saPool) ? saPool.Get("reason", "") : ""
        txt := !SaPoolWindow() ? "Starting Copilot - your question goes as soon as it's ready..."
            : (s = "ready" || s = "") ? "Asking Copilot..."
            : s = "signin" ? "Copilot needs you to sign in (its sign-in window is open) - your question goes right after."
            : s = "account" ? "Copilot won't send yet: " why
            : "Copilot is getting ready (" why ") - your question goes as soon as it can..."
        if (txt != saProgressText) {
            SaToast(txt, 600000)
            saProgressText := txt                ; (after SaToast: showing a note clears it)
        }
        return
    }
}

; Screen ask keeps the Copilot pool running and its OWN page reserved there (always loaded and warm),
; so a question never waits for a free page. Every 5 s (a restarted pool forgets the reservation).
SaKeepPool() {
    hwnd := SaPoolWindow()
    if !hwnd {
        SaStartPool()
        return
    }
    SaSendTo(hwnd, POOL_TAG, Map("t", "reserve", "conversation", SaSetting("Conversation"), "hwnd", saMain.Hwnd))
}

; Hands waiting requests to the pool (starts it if needed; waits up to 90 s for it to appear)
SaFlush() {
    for id, r in saReqs.Clone() {
        if r.inPool
            continue
        if (hwnd := SaPoolWindow()) {
            m := Map("t", "ask", "id", r.id, "hwnd", saMain.Hwnd, "prompt", r.prompt, "label", "Screen ask",
                "conversation", SaSetting("Conversation"), "newChat", SaNum("NewChat") ? 1 : 0, "orNew", 1,
                "show", 1, "images", r.files, "tick", A_TickCount)
            SaSendTo(hwnd, POOL_TAG, Map("t", "reserve", "conversation", SaSetting("Conversation"), "hwnd", saMain.Hwnd))
            if SaSendTo(hwnd, POOL_TAG, m) {
                r.inPool := true
                continue
            }
        }
        if (A_TickCount - r.at > 90000)
            SaFinish(r, false, "off", "the Copilot pool didn't start")
        else {
            SaStartPool()
            SetTimer(SaFlush, -700)
        }
    }
}

SaPoolWindow() => WinExist(POOL_WIN)
SaStartPool() {
    static last := 0
    if (A_TickCount - last < 15000)
        return
    last := A_TickCount
    SaLog("the Copilot pool isn't running - starting it")
    path := A_ScriptDir "\copilot-pool.ahk"
    if FileExist(path)
        try Run(Format('"{}" "{}" /background', A_AhkPath, path), A_ScriptDir)
}

; The prompt: what the images are + your question (Prompt setting, placeholders filled in here)
SaBuildPrompt(question, marks, crops, screens) {
    color := StrLower(SaSetting("MarkColor"))
    if (question = "")
        question := marks ? SaSetting("DefaultQuestion") : SaSetting("WholeQuestion")
    scr := screens <= 1 ? "one monitor" : "all " screens " of my monitors"
    marked := marks = 0 ? "" : marks = 1 ? " I marked the part I'm asking about in " color "."
        : " I marked " marks " parts in " color ", numbered 1 to " marks "."
    close := crops = 0 ? "" : crops = 1 ? (marks > 1 ? " Image 2 is a close-up of the marked parts." : " Image 2 is a close-up of the marked part.")
        : " Images 2 to " (crops + 1) " are close-ups of the marked parts, in order."
    focus := marks ? " Focus on what I marked; use the rest of the screen only as context." : ""
    t := StrReplace(SaSetting("Prompt"), "\n", "`n")
    for k, v in Map("{{screens}}", scr, "{{marked}}", marked, "{{closeups}}", close, "{{focus}}", focus, "{{question}}", question)
        t := StrReplace(t, k, v)
    return Trim(t, " `t`r`n")
}

; A request is over: on failure the marked screenshot goes on the clipboard and a note says why
SaFinish(r, ok, kind := "", why := "") {
    if saReqs.Has(r.id)
        saReqs.Delete(r.id)
    DbgTrace("screen", "ask " r.id " " (ok ? "answered" : kind " - " why) " after " (A_TickCount - r.at) " ms")
    if !ok {
        SaLog("ask " r.id " not answered: " kind " - " why)
        copied := SaClipImage(r.full)
        neverSent := false
        for k in ["unsent", "off", "starting", "signin", "account", "busy", "lost"]
            if (kind = k)
                neverSent := true
        SaToast((neverSent ? "Not sent to Copilot: " : "Copilot didn't finish (not sent again): ") why
            . (copied ? "`nThe marked screenshot is on the clipboard - paste it into Copilot (Ctrl+V)." : ""), 10000)
    }
    for p in r.files
        try FileDelete(p)
}

; ==============================================================================
; Messages from other apps
; ==============================================================================
SaOnCopyData(wParam, lParam, msg, hwnd) {
    if (!IsObject(saMain) || hwnd != saMain.Hwnd)
        return
    try {
        tag := NumGet(lParam, 0, "UPtr")
        if (tag != SA_TAG && tag != POOL_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(SaHandleApp.Bind(tag, text), -1)
    return true
}

SaHandleApp(tag, text) {
    global saPool
    try {
        m := Json.Parse(text)
        if !(m is Map)
            return
        t := m.Get("t", "")
        if (tag = SA_TAG) {
            switch t {
                case "capture": SaCapture()
                case "settings": SaShowSettings()
                case "quit": ExitApp()
            }
            return
        }
        if (t = "state") {                       ; from the pool: its state (we're subscribed by "reserve")
            saPool := m
            SaProgress()
            return
        }
        id := m.Get("id", "")                   ; from the pool: about one of our questions
        if !saReqs.Has(id)
            return
        r := saReqs[id]
        switch t {
            case "queued":
                SaProgress()
            case "sent":
                r.sent := true
                DbgTrace("screen", "ask " r.id " is IN Copilot, " (A_TickCount - r.at) " ms after Send")
                SaToastHide()
                SaProgress()                     ; (another question still on its way)
            case "done":
                SaFinish(r, m.Get("ok", 0), m.Get("kind", ""), m.Get("error", ""))
        }
    } catch as err {
        SaLog("ERROR (message): " err.Message)
    }
}

SaSendTo(hwnd, tag, obj) {
    msg := Json.Stringify(obj)
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", tag, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(0x4A, 0, cds, , Integer(hwnd), , , , 3000)
        return true
    }
    return false
}

; Every 30 s: requests the pool never finished, leftover files
SaHousekeep() {
    ; memory guard: the hidden overlay's browser should stay small; if it grew, it's started fresh
    if (env != 0 && ov.ready && !ov.shown && !IsObject(saShot)) {
        try {
            mb := WvgEnvMB(env)
            DbgTrace("screen", "overlay memory " mb " MB")
            if (mb > SaNum("MaxMB"))
                SaRestartOverlay("the overlay used " mb " MB (limit " SaNum("MaxMB") ")")
            else
                try ov.wv.MemoryUsageTargetLevel := 1
        }
    }
    for id, r in saReqs.Clone() {
        if (A_TickCount - r.at > 12 * 60000)                    ; (a sign-in may take up to 10 min)
            SaFinish(r, false, r.sent ? "failed" : "unsent", "no answer from the Copilot pool")
        else if (r.inPool && !SaPoolWindow())
            SaFinish(r, false, r.sent ? "failed" : "unsent", "the Copilot pool closed")
    }
    SaCleanup(false)
}

; Deletes leftover screenshots / images (all of them at the start, else older than KeepMin)
SaCleanup(all) {
    keep := Max(1, SaNum("KeepMin")) * 60
    for dir in [SA_LOCAL "\shot-*.png", APP_IMAGE_INBOX "\screen-ask-*.png"] {
        Loop Files dir {
            if (!all && DateDiff(A_Now, A_LoopFileTimeModified, "Seconds") < keep)
                continue
            inUse := false
            for id, r in saReqs
                for p in r.files
                    if (p = A_LoopFileFullPath)
                        inUse := true
            if (IsObject(saShot) && saShot.path = A_LoopFileFullPath)
                inUse := true
            if !inUse
                try FileDelete(A_LoopFileFullPath)
        }
    }
}

; ==============================================================================
; Images: base64 -> file, file -> clipboard
; ==============================================================================
SaWriteB64(b64, path) {
    if (b64 = "")
        throw Error("an empty image")
    n := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", StrLen(b64), "UInt", 1, "Ptr", 0, "UInt*", &n, "Ptr", 0, "Ptr", 0)
        throw Error("a broken image")
    buf := Buffer(n)
    DllCall("crypt32\CryptStringToBinaryW", "WStr", b64, "UInt", StrLen(b64), "UInt", 1, "Ptr", buf, "UInt*", &n, "Ptr", 0, "Ptr", 0)
    f := FileOpen(path, "w")
    f.RawWrite(buf, n)
    f.Close()
    return n
}

SaCopyFromPage(b64) {
    path := APP_IMAGE_INBOX "\screen-ask-copy-" A_TickCount ".png"
    try {
        DirCreate(APP_IMAGE_INBOX)
        SaWriteB64(b64, path)
        if SaClipImage(path)
            SaToast("The marked screenshot is on the clipboard.", 3000)
        else
            SaToast("Screen ask couldn't put the image on the clipboard.", 5000)
    } catch as err {
        SaToast("Screen ask couldn't copy the image: " err.Message, 5000)
    }
    try FileDelete(path)
}

SaClipImage(path) {
    try {
        if !FileExist(path)
            return false
        SaGdipStart()
        pBmp := 0, hbm := 0
        if (DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", &pBmp) || !pBmp)
            return false
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBmp, "Ptr*", &hbm, "UInt", 0xFFFFFFFF)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
        if !hbm
            return false
        opened := false
        Loop 10 {                                     ; another program may have the clipboard open
            if (opened := DllCall("OpenClipboard", "Ptr", saMain.Hwnd))
                break
            Sleep(30)
        }
        if !opened {
            DllCall("DeleteObject", "Ptr", hbm)
            return false
        }
        DllCall("EmptyClipboard")
        ok := DllCall("SetClipboardData", "UInt", 2, "Ptr", hbm, "Ptr")    ; CF_BITMAP: the clipboard owns it now
        DllCall("CloseClipboard")
        if !ok
            DllCall("DeleteObject", "Ptr", hbm)
        return ok ? true : false
    }
    return false
}

; ==============================================================================
; A small note at the bottom right of the screen the mouse is on (never takes the focus; click = close)
; ==============================================================================
SaToast(text, ms := 4000) {
    global saToastGui
    SaToastHide()
    try {
        g := Gui("-Caption +AlwaysOnTop +ToolWindow +Border", "Screen ask")
        g.BackColor := "111827"
        g.MarginX := 14, g.MarginY := 10
        g.SetFont("s10 cF9FAFB", "Segoe UI")
        t := g.Add("Text", "w360", text)
        t.OnEvent("Click", (*) => SaToastHide())
        g.Show("Hide AutoSize")
        g.GetPos(, , &w, &h)
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        mon := 0
        Loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &l, &tp, &r, &b)
            if (mx >= l && mx < r && my >= tp && my < b)
                mon := A_Index
        }
        MonitorGetWorkArea(mon ? mon : MonitorGetPrimary(), &l, &tp, &r, &b)
        g.Show("NoActivate x" (r - w - 16) " y" (b - h - 16))
        saToastGui := g
        SetTimer(SaToastHide, -ms)
    }
}

SaToastHide() {
    global saToastGui, saProgressText
    saProgressText := ""
    if IsObject(saToastGui) {
        try saToastGui.Destroy()
        saToastGui := 0
    }
}

; ==============================================================================
; Settings window
; ==============================================================================
SaShowSettings(*) {
    static g := 0
    if IsObject(g) {
        try {
            g.Show()
            return
        }
    }
    g := Gui("+MinimizeBox", "Screen ask settings")
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 14, g.MarginY := 12
    hk := Trim(SaSetting("Hotkey"))
    win := InStr(RegExReplace(hk, "[^#^+!<>*~$].*$"), "#") ? 1 : 0
    g.Add("Text", "w440 h20", "Shortcut that freezes the screen (click the box, then press the keys):")
    hkCtl := g.Add("Hotkey", "w220 h26", StrReplace(RegExReplace(hk, "[<>*~$]"), "#"))
    winCtl := g.Add("CheckBox", "x+10 yp+4 w200 h20 Checked" win, "with the Windows key too")
    g.Add("Text", "xm w440 h20 y+16", "Question when you don't type one:")
    qCtl := g.Add("Edit", "w440 h26", SaSetting("DefaultQuestion"))
    g.Add("Text", "w440 h20 y+12", "Colour of your marks:")
    names := []
    for name in SA_COLORS
        names.Push(name)
    cur := 1
    for i, name in names
        if (name = SaSetting("MarkColor"))
            cur := i
    colCtl := g.Add("DropDownList", "w160 Choose" cur, names)
    cuCtl := g.Add("CheckBox", "xm w440 h20 y+14 Checked" (SaNum("CloseUps") ? 1 : 0), "Also send a close-up of each marked area (sharper for small text)")
    ncCtl := g.Add("CheckBox", "w440 h20 Checked" (SaNum("NewChat") ? 1 : 0), "Start a new chat with every capture (off = carry on in the same chat)")
    g.Add("Text", "w440 h40 y+12 c666666", "More options (the prompt text, image size, line width) are in the settings file.")
    g.Add("Button", "xm w100 h30 y+8 Default", "Save").OnEvent("Click", Save)
    g.Add("Button", "x+8 w100 h30", "Cancel").OnEvent("Click", (*) => g.Hide())
    g.Add("Button", "x+8 w120 h30", "Settings file").OnEvent("Click", OpenFile)
    g.Add("Button", "x+8 w90 h30", "Try it").OnEvent("Click", (*) => (g.Hide(), SetTimer(SaCapture, -400)))
    g.OnEvent("Close", (*) => g.Hide())
    g.OnEvent("Escape", (*) => g.Hide())
    g.Show()

    Save(*) {
        newHk := Trim(hkCtl.Value)
        if (newHk != "" && winCtl.Value)
            newHk := "#" newHk
        oldHk := SaSetting("Hotkey")
        IniWrite(newHk, SA_INI, "Settings", "Hotkey")
        if !SaSetHotkey() {
            IniWrite(oldHk, SA_INI, "Settings", "Hotkey")
            SaSetHotkey()
            return
        }
        IniWrite(qCtl.Value, SA_INI, "Settings", "DefaultQuestion")
        IniWrite(colCtl.Text, SA_INI, "Settings", "MarkColor")
        IniWrite(cuCtl.Value ? 1 : 0, SA_INI, "Settings", "CloseUps")
        IniWrite(ncCtl.Value ? 1 : 0, SA_INI, "Settings", "NewChat")
        if !SA_HOST_HWND
            SaBuildTray()
        g.Hide()
        SaToast("Saved. Shortcut: " SaHotkeyText(), 3000)
    }
    OpenFile(*) {
        SaWriteDefaults()
        try Run('notepad.exe "' SA_INI '"')
    }
}

; Writes every setting that isn't in the file yet (so the file shows what can be changed)
SaWriteDefaults() {
    for k, v in SA_DEFAULTS
        if (IniRead(SA_INI, "Settings", k, "`a") = "`a")
            IniWrite(v, SA_INI, "Settings", k)
}

; ==============================================================================
; Settings, log, errors
; ==============================================================================
SaSetting(key) {
    def := SA_DEFAULTS.Has(key) ? SA_DEFAULTS[key] : ""
    try return IniRead(SA_INI, "Settings", key, def)
    return def
}

SaNum(key) {
    v := SaSetting(key)
    return IsNumber(v) ? Number(v) : (SA_DEFAULTS.Has(key) && IsNumber(SA_DEFAULTS[key]) ? SA_DEFAULTS[key] : 0)
}

SaColorHex() {
    name := SaSetting("MarkColor")
    if SA_COLORS.Has(name)
        return SA_COLORS[name]
    return RegExMatch(name, "i)^#[0-9a-f]{6}$") ? name : SA_COLORS["Red"]
}

SaLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", SA_LOG, "UTF-8")
}

SaTrimLog() {
    try {
        if (FileExist(SA_LOG) && FileGetSize(SA_LOG) > 512 * 1024)
            FileMove(SA_LOG, DATA_DIR "\screen-ask.old.log", true)
    }
}

SaOnError(err, mode) {
    try SaLog("ERROR: " err.Message " (" err.What ", line " err.Line ")")
    try SaDropShot()                            ; never leave a frozen screen up
    return 1                                    ; keep running
}

SaOnExit(*) {
    try SaDropShot()
    try ov.ctrl.Close()
}
