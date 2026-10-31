; ==============================================================================
; caller-companion.ahk  -  3CX caller detection for Live Caption Companion
;
; Safety rules - the core app must never depend on this file working:
;   * Detection runs in a separate process (caller-watch.ahk). If it fails,
;     hangs or is closed, captions, history and helpers keep working.
;   * Nothing here ever clicks, types into or activates 3CX - it only reads.
;     When a call rings it switches you to the Companion's own window instead
;     (setting "Switch to the Companion when a call rings", on by default).
;   * Every entry point is wrapped in try/catch. Problems only show in the
;     status line and in caller-debug.log.
;   * Auto "new call" never throws anything away: the previous call is saved
;     first, and it is skipped during an active call or while a dialog is open.
;   * Manual paths always work, with or without 3CX:
;       📞 button (set the caller by hand), right-click "Search in Salesforce",
;       tray > 3CX caller > Simulate incoming call, and the normal New call button.
;   * Settings: live-captions.ini, section [Caller] (also in the tray menu).
; ==============================================================================

callerInfo := ""          ; Map with number, numberTerms, name, nameTerms, source, key, waiting
callerPhase := ""         ; "" | "ringing" | "on call" | "ended" | "manual"
callerUiBuilt := false
callerStripShown := false
callerWatchPid := 0
callerTrayMenu := ""
callerBtnToolbar := ""
callerStripText := ""
callerBtnSfNum := ""
callerBtnSfName := ""
callerBtnCopy := ""
callerBtnEdit := ""
callerBtnClose := ""
callerCard := ""
callerCardText := ""
callerCardSfNum := ""
callerCardSfName := ""
CALLER_LOG := DATA_DIR "\caller-debug.log"
CALLER_TAG := 0x3CC0
CALLER_3CX := "3CX ahk_exe 3CXSoftphone.exe ahk_class WinUIDesktopWin32WindowClass"
CALLER_DEFAULTS := Map("Enabled", 1, "AutoNewCall", 1, "Popup", 1, "FocusOnRing", 1, "LogRaw", 1)

; ==============================================================================
; Hooks called from liveCaptionCompanion.ahk (each one is safe to call anytime)
; ==============================================================================
CallerInit() {
    try {
        CallerBuildUi()
        CallerBuildMenus()
        OnMessage(0x4A, CallerOnCopyData)        ; WM_COPYDATA from caller-watch.ahk
        if CallerFlag("Enabled")
            CallerStartWatcher()
        CallerLog("companion side started")
    } catch as err {
        CallerReportError(err, "start")
    }
}

CallerShutdown() {
    try CallerStopWatcher()
    try CallerHideCard()
}

CallerOnNewCall() {
    global callerInfo, callerPhase
    try {
        callerInfo := ""
        callerPhase := ""
        CallerHideCard()
        CallerRefresh()
    } catch as err {
        CallerReportError(err)
    }
}

CallerStripHeight() {
    return callerStripShown ? 34 : 0
}

; Places the caller strip; called from GuiResize
CallerLayout(x, y, w) {
    if !callerUiBuilt
        return
    try {
        for c in [callerStripText, callerBtnSfNum, callerBtnSfName, callerBtnCopy, callerBtnEdit, callerBtnClose]
            c.Visible := callerStripShown
        if !callerStripShown
            return
        right := x + w
        btns := [callerBtnClose, callerBtnEdit, callerBtnCopy, callerBtnSfName, callerBtnSfNum]
        widths := [30, 30, 56, 78, 60]
        for i, b in btns {
            right -= widths[i]
            b.Move(right, y, widths[i], 28)
            right -= 4
        }
        callerStripText.Move(x, y, Max(60, right - x), 28)
    }
}

; {{caller}} placeholder for helper prompts
CallerPromptText() {
    try {
        s := IsObject(reviewCall) ? reviewCall : currentCall
        c := IsObject(s) ? s.Get("caller", "") : ""
        if (c is Map) {
            parts := []
            if (c.Get("number", "") != "")
                parts.Push("Caller number: " c["number"])
            if (c.Get("name", "") != "")
                parts.Push("Caller ID name: " c["name"])
            return JoinWith(parts, "`n")
        }
    }
    return ""
}

; Caller added automatically when a helper prompt doesn't place {{caller}} itself:
; it follows {{transcript}} (before the verified info), or goes at the end.
; "" when the prompt has {{caller}} or no caller is known.
CallerAutoBlock(raw) {
    if InStr(raw, "{{caller}}")
        return ""
    t := CallerPromptText()
    return (t = "") ? "" : "CALLER (from the phone system's caller ID, not from the captions)`n" t
}

; Extra text for the Call history list
CallerHistoryLabel(s) {
    try {
        c := s.Get("caller", "")
        if (c is Map) {
            t := Trim(c.Get("number", "") "  " c.Get("name", ""))
            if (t != "")
                return "  ·  📞 " t
        }
    }
    return ""
}

; ==============================================================================
; Settings
; ==============================================================================
CallerSetting(key, default := "") {
    try return IniRead(MIC_INI, "Caller", key, default)
    return default
}

CallerFlag(key) {
    return CallerSetting(key, CALLER_DEFAULTS.Get(key, 0)) = "1"
}

CallerSetFlag(key, on) {
    try IniWrite(on ? 1 : 0, MIC_INI, "Caller", key)
}

CallerToggle(key) {
    on := !CallerFlag(key)
    CallerSetFlag(key, on)
    CallerSyncMenu()
    if (key = "Enabled") {
        if on
            CallerStartWatcher()
        else
            CallerStopWatcher()
    }
    if (key = "Popup" && !on)
        CallerHideCard()
    statusText.Text := "Status: 3CX caller - " key " is now " (on ? "on" : "off")
}

; ==============================================================================
; UI: 📞 toolbar button, caller strip, right-click entry, tray menu
; ==============================================================================
CallerBuildUi() {
    global callerUiBuilt, callerBtnToolbar, callerStripText, callerBtnSfNum
    global callerBtnSfName, callerBtnCopy, callerBtnEdit, callerBtnClose

    btnPrev.GetPos(&px, &py, &pw, &ph)
    callerBtnToolbar := myGui.Add("Button", Format("x{} y{} w40 h{}", px + pw + 8, py, ph), "📞")
    callerBtnToolbar.OnEvent("Click", CallerSafe(CallerManualEntry))

    callerStripText := myGui.Add("Text", "x0 y0 w100 h28 +0x200 Background16352A cA7F3D0 Hidden", "")
    callerBtnSfNum  := myGui.Add("Button", "x0 y0 w60 h28 Hidden", "SF #")
    callerBtnSfName := myGui.Add("Button", "x0 y0 w78 h28 Hidden", "SF name")
    callerBtnCopy   := myGui.Add("Button", "x0 y0 w56 h28 Hidden", "Copy")
    callerBtnEdit   := myGui.Add("Button", "x0 y0 w30 h28 Hidden", "✎")
    callerBtnClose  := myGui.Add("Button", "x0 y0 w30 h28 Hidden", "×")

    callerBtnSfNum.OnEvent("Click", CallerSafe(CallerSearchNumber))
    callerBtnSfName.OnEvent("Click", CallerSafe(CallerSearchName))
    callerBtnCopy.OnEvent("Click", CallerSafe(CallerCopy))
    callerBtnEdit.OnEvent("Click", CallerSafe(CallerManualEntry))
    callerBtnClose.OnEvent("Click", CallerSafe(CallerClose))
    callerUiBuilt := true
}

CallerBuildMenus() {
    global callerTrayMenu
    chatCtxMenu.Insert("1&", "Search in Salesforce", CallerSafe(CallerSearchSelection))
    chatCtxMenu.Insert("2&")

    m := Menu()
    m.Add("Detect calls from 3CX", CallerSafe(() => CallerToggle("Enabled")))
    m.Add("New call record when a call rings", CallerSafe(() => CallerToggle("AutoNewCall")))
    m.Add("Caller card near 3CX", CallerSafe(() => CallerToggle("Popup")))
    m.Add("Switch to the Companion when a call rings", CallerSafe(() => CallerToggle("FocusOnRing")))
    m.Add()
    m.Add("Simulate incoming call…", CallerSafe(CallerSimulateRing))
    m.Add("Simulate call ended", CallerSafe(CallerOnIdle))
    m.Add("Open caller log", CallerSafe(() => Run('notepad.exe "' CALLER_LOG '"')))
    callerTrayMenu := m
    A_TrayMenu.Insert("1&")
    A_TrayMenu.Insert("1&", "3CX caller", m)
    CallerSyncMenu()
}

CallerSyncMenu() {
    if !IsObject(callerTrayMenu)
        return
    items := Map("Detect calls from 3CX", "Enabled"
        , "New call record when a call rings", "AutoNewCall"
        , "Caller card near 3CX", "Popup"
        , "Switch to the Companion when a call rings", "FocusOnRing")
    for item, key in items {
        if CallerFlag(key)
            callerTrayMenu.Check(item)
        else
            callerTrayMenu.Uncheck(item)
    }
}

CallerRefresh() {
    global callerStripShown
    if !callerUiBuilt
        return
    callerStripShown := IsObject(callerInfo)
    if callerStripShown {
        callerStripText.Text := "  " CallerLabel()
        callerBtnSfNum.Enabled := callerInfo["numberTerms"].Length > 0
        callerBtnSfName.Enabled := callerInfo["nameTerms"].Length > 0
    }
    RelayoutMain()
    CallerRefreshCard()
}

CallerLabel() {
    parts := []
    if (callerInfo["number"] != "")
        parts.Push("📞 " callerInfo["number"])
    if (callerInfo["name"] != "")
        parts.Push("👤 " callerInfo["name"])
    if !parts.Length
        parts.Push("📞 unknown caller")
    phase := (callerPhase = "ringing" || callerPhase = "on call" || callerPhase = "ended")
        ? callerPhase : callerInfo["source"]
    if callerInfo["waiting"]
        phase := "call waiting"
    return JoinWith(parts, "   ") "   ·  " phase
}

; ==============================================================================
; Events from caller-watch.ahk
; ==============================================================================
CallerOnCopyData(wParam, lParam, msg, hwnd) {
    if (hwnd != myGui.Hwnd)
        return
    try {
        if (NumGet(lParam, 0, "UPtr") != CALLER_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(CallerHandleEvent.Bind(text), -1)   ; reply to the watcher right away
    return true
}

CallerHandleEvent(text, *) {
    try {
        p := StrSplit(text, "`t")
        while (p.Length < 3)
            p.Push("")
        switch p[1] {
            case "ringing": CallerOnRing(p[2], p[3], "3CX")
            case "oncall":  CallerOnAnswered(p[3])
            case "idle":    CallerOnIdle()
        }
    } catch as err {
        CallerReportError(err, "event")
    }
}

CallerOnRing(numberField, nameField, source) {
    global callerInfo, callerPhase
    info := CallerBuildInfo(numberField, nameField, source)
    if (callerPhase = "ringing" && IsObject(callerInfo) && callerInfo["key"] == info["key"])
        return                                          ; same ring reported again
    waiting := (callerPhase = "on call")                ; a second call while talking
    info["waiting"] := waiting
    if (!waiting && CallerFlag("AutoNewCall"))
        CallerAutoNewCall()
    callerInfo := info
    callerPhase := "ringing"
    if !waiting
        CallerSaveToRecord()
    CallerRefresh()
    if CallerFlag("Popup")
        CallerShowCard()
    if (!waiting && CallerFlag("FocusOnRing"))      ; also on simulated rings, to test it
        CallerSwitchToCompanion()
    statusText.Text := "Status: incoming call  " CallerLabel()
}

; Makes the Companion's main window active where it is. If it is on another virtual
; desktop, Windows switches you to that desktop - the window itself is never moved.
; Runs on a timer so the watcher's message isn't held up while we wait and check.
CallerSwitchToCompanion() {
    SetTimer(CallerSwitchToCompanionNow, -10)
}

CallerSwitchToCompanionNow() {
    try {
        hwnd := myGui.Hwnd
        where := CallerOnCurrentDesktop(hwnd)
        if !DllCall("IsWindowVisible", "Ptr", hwnd)
            myGui.Show()
        if (WinGetMinMax(hwnd) = -1)
            WinRestore(hwnd)
        WinActivate(hwnd)
        Sleep(300)
        if WinActive(hwnd) {
            ; across desktops Windows can report it active but only flash the taskbar
            CallerLog((CallerOnCurrentDesktop(hwnd) = "on this desktop" ? "switched to the Companion" : "Windows flashed the Companion in the taskbar instead of switching")
                . " (it was " where ")")
            return
        }
        ; Windows can refuse when the app hasn't been used for a while; a window that
        ; is restored from minimized is more often allowed to come forward
        WinMinimize(hwnd)
        Sleep(200)
        WinRestore(hwnd)
        WinActivate(hwnd)
        Sleep(300)
        act := WinExist("A")
        CallerLog((WinActive(hwnd) ? "switched to the Companion on 2nd try" : "Windows refused to switch to the Companion")
            . " (it was " where ", active now: " (act ? WinGetProcessName(act) : "none") ")")
    } catch as err {
        CallerReportError(err, "switch to Companion")
    }
}

; "this desktop" / "another desktop" via the documented IVirtualDesktopManager (no admin needed)
CallerOnCurrentDesktop(hwnd) {
    try {
        vdm := ComObject("{aa509086-5ca9-4c25-8f95-589d3c07b48a}", "{a5cd92ff-29be-454c-8d04-d82879fb3f1b}")
        onCur := 0
        ComCall(3, vdm, "Ptr", hwnd, "Int*", &onCur)   ; IsWindowOnCurrentVirtualDesktop
        return onCur ? "on this desktop" : "on another desktop"
    } catch {
        return "on an unknown desktop"
    }
}

CallerOnAnswered(contact) {
    global callerPhase
    callerPhase := "on call"
    if IsObject(callerInfo) {
        callerInfo["waiting"] := false
        CallerRefresh()
    }
}

CallerOnIdle(*) {
    global callerPhase
    if !(callerPhase = "ringing" || callerPhase = "on call")
        return
    callerPhase := "ended"
    CallerHideCard()
    if IsObject(callerInfo)
        CallerRefresh()
}

CallerBuildInfo(numberField, nameField, source) {
    phoneFmt := CallerSetting("PhoneFormats", "dashed")
    num := SF_Classify(numberField, phoneFmt)
    nm := SF_Classify(nameField, phoneFmt)
    ; 3CX may show the number in the name field (unknown caller)
    if (num["display"] = "" && nm["kind"] = "phone") {
        num := nm
        nm := SF_Classify("")
    }
    ; same number shown twice
    if (nm["kind"] = "phone" && nm["digits"] = num["digits"])
        nm := SF_Classify("")

    nameTerms := []
    if (nm["display"] != "") {
        for f in StrSplit(CallerSetting("NameFormats", "asis"), ",", " ") {
            t := (f = "flipped") ? SF_FlipName(nm["display"]) : nm["display"]
            if (t != "" && !SF_ArrayHas(nameTerms, t))
                nameTerms.Push(t)
        }
    }
    info := Map()
    info["number"] := num["display"]
    info["numberTerms"] := num["terms"]
    info["name"] := nm["display"]
    info["nameTerms"] := nameTerms
    info["source"] := source
    info["key"] := Trim(numberField) "|" Trim(nameField)
    info["waiting"] := false
    return info
}

; Starts a fresh call record the same way the New call button does, but only
; when it is safe, and always saving the previous call first.
CallerAutoNewCall() {
    if CallerDialogOpen() {
        CallerLog("auto new call skipped: a dialog is open")
        return
    }
    if IsObject(reviewCall)
        ExitReview()
    hasData := sessionLines.Length > 0
        || (IsObject(currentCall) && currentCall["preparedPrompts"].Length > 0)
        || Trim(notesBox.Value) != ""
    if !hasData
        return                          ; current record is still empty: just reuse it
    SaveNotes()
    FinishCurrentCall()
    ResetCallView()
    StartNewCallRecord()
    CallerLog("auto new call started")
}

CallerDialogOpen() {
    if !DllCall("IsWindowEnabled", "Ptr", myGui.Hwnd)
        return true                     ; e.g. the helper editor is open
    pid := DllCall("GetCurrentProcessId")
    return WinExist("ahk_class #32770 ahk_pid " pid) ? true : false
}

CallerSaveToRecord() {
    if (!IsObject(currentCall) || !IsObject(callerInfo))
        return
    c := Map()
    c["number"] := callerInfo["number"]
    c["name"] := callerInfo["name"]
    c["source"] := callerInfo["source"]
    c["detectedAtUtc"] := NowIso()
    currentCall["caller"] := c
    SaveHistory()
}

; ==============================================================================
; Actions
; ==============================================================================
CallerSearchNumber() {
    if (!IsObject(callerInfo) || !callerInfo["numberTerms"].Length) {
        statusText.Text := "Status: no caller number to search"
        return
    }
    n := SF_OpenSearches(callerInfo["numberTerms"])
    statusText.Text := "Status: opened " n " Salesforce search(es) for " callerInfo["number"]
}

CallerSearchName() {
    if (!IsObject(callerInfo) || !callerInfo["nameTerms"].Length) {
        statusText.Text := "Status: no caller name to search"
        return
    }
    n := SF_OpenSearches(callerInfo["nameTerms"])
    statusText.Text := "Status: opened " n " Salesforce search(es) for " callerInfo["name"]
}

CallerCopy() {
    if !IsObject(callerInfo)
        return
    t := callerInfo["number"] != "" ? callerInfo["number"] : callerInfo["name"]
    if (t = "")
        return
    A_Clipboard := t
    statusText.Text := "Status: copied " t
}

CallerClose() {
    global callerInfo, callerPhase
    callerInfo := ""
    callerPhase := ""
    CallerHideCard()
    CallerRefresh()
}

CallerManualEntry() {
    def := ""
    if IsObject(callerInfo)
        def := Trim(callerInfo["number"] " | " callerInfo["name"], " |")
    myGui.Opt("+OwnDialogs")
    r := InputBox("Caller number and/or name.`nUse | to give both, e.g.  7892344567 | Maria Santos"
        , "Set caller", "w440 h150", def)
    if (r.Result != "OK")
        return
    CallerSetManual(r.Value)
}

CallerSetManual(text) {
    global callerInfo, callerPhase
    p := StrSplit(text, "|", " `t")
    a := p.Length >= 1 ? p[1] : ""
    b := p.Length >= 2 ? p[2] : ""
    if (p.Length < 2 && SF_Classify(a)["kind"] != "phone" && !RegExMatch(a, "^\d+$")) {
        b := a                              ; a single value that is not a number is a name
        a := ""
    }
    if (Trim(a) = "" && Trim(b) = "") {
        CallerClose()
        return
    }
    callerInfo := CallerBuildInfo(a, b, "manual")
    callerPhase := "manual"
    CallerSaveToRecord()
    CallerRefresh()
}

CallerSimulateRing() {
    myGui.Opt("+OwnDialogs")
    r := InputBox("Fake caller (nothing is sent to 3CX):  number | name`n"
        . "Behaves like a real ring, including 'New call record when a call rings'."
        , "Simulate incoming call", "w460 h160", "7892344567 | Rojas, michael 2")
    if (r.Result != "OK")
        return
    p := StrSplit(r.Value, "|", " `t")
    CallerOnRing(p.Length >= 1 ? p[1] : "", p.Length >= 2 ? p[2] : "", "simulated")
}

; Right-click > Search in Salesforce: searches the text highlighted in Chat
CallerSearchSelection() {
    ctrl := chatView ? chatBox : transcript
    s := Buffer(4, 0)
    e := Buffer(4, 0)
    SendMessage(0x00B0, s, e, ctrl.Hwnd)              ; EM_GETSEL
    a := NumGet(s, 0, "UInt")
    b := NumGet(e, 0, "UInt")
    if (b <= a) {
        statusText.Text := "Status: highlight some text first, then right-click > Search in Salesforce"
        return
    }
    ; Use the control's raw text: .Value turns every CRLF into LF, which shifts
    ; the selection offsets by one character per line break above it.
    text := SubStr(CallerEditText(ctrl.Hwnd), a + 1, b - a)
    text := Trim(RegExReplace(RegExReplace(text, "[▌▐░]", " "), "\s+", " "))
    if (text = "")
        return
    if (StrLen(text) > 120) {
        statusText.Text := "Status: highlight a shorter piece of text (a number, name or ID) to search"
        return
    }
    r := SF_Classify(text, CallerSetting("PhoneFormats", "dashed"))
    n := SF_OpenSearches(r["terms"])
    statusText.Text := "Status: opened " n " Salesforce search(es) for " r["display"]
}

; Text of an Edit control exactly as the control holds it (CRLF kept), so the
; character offsets from EM_GETSEL line up.
CallerEditText(hwnd) {
    len := SendMessage(0x000E, 0, 0, hwnd)              ; WM_GETTEXTLENGTH
    buf := Buffer((len + 1) * 2, 0)
    SendMessage(0x000D, len + 1, buf, hwnd)             ; WM_GETTEXT
    return StrGet(buf, "UTF-16")
}

; ==============================================================================
; Floating card next to 3CX (never takes focus, so it can't disturb answering)
; ==============================================================================
CallerShowCard() {
    global callerCard, callerCardText, callerCardSfNum, callerCardSfName
    if !IsObject(callerCard) {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border +E0x08000000", "3CX caller")
        g.BackColor := "11151D"
        g.SetFont("s10 cF1F5FB", "Segoe UI")
        callerCardText := g.Add("Text", "x10 y8 w250 h40", "")
        callerCardSfNum := g.Add("Button", "x10 y52 w70 h26", "SF #")
        callerCardSfName := g.Add("Button", "x+6 w84 h26", "SF name")
        closeBtn := g.Add("Button", "x+6 w30 h26", "×")
        callerCardSfNum.OnEvent("Click", CallerSafe(CallerSearchNumber))
        callerCardSfName.OnEvent("Click", CallerSafe(CallerSearchName))
        closeBtn.OnEvent("Click", CallerSafe(CallerHideCard))
        callerCard := g
    }
    CallerRefreshCard()
    w := 270
    h := 86
    x := A_ScreenWidth - w - 20
    y := 80
    try {
        WinGetPos(&wx, &wy, &ww, &wh, CALLER_3CX)
        x := wx - w - 8                           ; left of the 3CX window
        y := wy + 40
        if (x < SysGet(76))                       ; off the left edge: put it on the right
            x := wx + ww + 8
    }
    callerCard.Show(Format("NA x{} y{} w{} h{}", x, y, w, h))
}

CallerRefreshCard() {
    if !IsObject(callerCard)
        return
    if !IsObject(callerInfo) {
        callerCard.Hide()
        return
    }
    lines := []
    if (callerInfo["number"] != "")
        lines.Push("📞 " callerInfo["number"])
    if (callerInfo["name"] != "")
        lines.Push("👤 " callerInfo["name"])
    if !lines.Length
        lines.Push("📞 unknown caller")
    callerCardText.Text := JoinWith(lines, "`n")
    callerCardSfNum.Enabled := callerInfo["numberTerms"].Length > 0
    callerCardSfName.Enabled := callerInfo["nameTerms"].Length > 0
}

CallerHideCard(*) {
    if IsObject(callerCard)
        callerCard.Hide()
}

; ==============================================================================
; Watcher process
; ==============================================================================
CallerStartWatcher() {
    global callerWatchPid
    CallerStopWatcher()
    path := A_ScriptDir "\caller-watch.ahk"
    if !FileExist(path) {
        statusText.Text := "Status: caller-watch.ahk not found - caller detection is off (captions unaffected)"
        return
    }
    Run(Format('"{}" "{}" {} {} "{}"', A_AhkPath, path, myGui.Hwnd, CallerFlag("LogRaw") ? 1 : 0, CALLER_LOG)
        , A_ScriptDir, , &pid)
    callerWatchPid := pid
}

CallerStopWatcher() {
    global callerWatchPid
    if (callerWatchPid && ProcessExist(callerWatchPid))
        try ProcessClose(callerWatchPid)
    callerWatchPid := 0
}

; ==============================================================================
; Error handling
; ==============================================================================
CallerSafe(fn) {
    return (*) => CallerTry(fn)
}

CallerTry(fn) {
    try fn()
    catch as err
        CallerReportError(err)
}

CallerReportError(err, where := "") {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: caller feature problem (captions unaffected): " msg
    CallerLog("ERROR " where ": " msg)
}

CallerLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  [companion] " line "`n", CALLER_LOG, "UTF-8")
}
