; ==============================================================================
; screen-ask-link.ahk  -  starts Screen ask (screen-ask.ahk) from the Companion when it's turned on
;
; * OFF by default for everyone. Each person turns it on from the tray ("Screen ask" > "On");
;   saved in their own live-captions.ini [ScreenAsk] Enabled, so it never ships and updates keep it.
; * Screen ask is its own app and process (freeze the screen, mark something, ask Copilot through
;   the Copilot pool): if it fails, captions and the call carry on. It ends with the Companion.
; * The tray menu also has a mouse way to every keyboard action: "Capture and ask now", "Settings...".
; Hooks: SaLinkInit() (after MainHelperInit), SaLinkShutdown()
; ==============================================================================

SALINK_MENU := "Screen ask (mark the screen, ask Copilot)"
SALINK_ON := "On (starts with the Companion)"
SALINK_NOW := "Capture and ask now"
SALINK_SETTINGS := "Settings (shortcut, colour)..."
SALINK_TAG := 0x3CC5
SALINK_WIN := "Caption Companion Screen ask ahk_class AutoHotkeyGUI"
saLinkPid := 0
saLinkMenu := 0

SaLinkInit() {
    global saLinkMenu
    try {
        saLinkMenu := Menu()
        saLinkMenu.Add(SALINK_ON, (*) => SaLinkToggle())
        saLinkMenu.Add()
        saLinkMenu.Add(SALINK_NOW, (*) => SaLinkCommand("capture"))
        saLinkMenu.Add(SALINK_SETTINGS, (*) => SaLinkCommand("settings"))
        A_TrayMenu.Insert("2&", SALINK_MENU, saLinkMenu)
        if SaLinkEnabled() {
            saLinkMenu.Check(SALINK_ON)
            SaLinkStart()
        }
    } catch as err {
        SaLinkReport(err)
    }
}

SaLinkShutdown() {
    try SaLinkStop()
}

SaLinkEnabled() {
    try return IniRead(MIC_INI, "ScreenAsk", "Enabled", "0") = "1"
    return false
}

SaLinkToggle() {
    try {
        on := !SaLinkEnabled()
        IniWrite(on ? 1 : 0, MIC_INI, "ScreenAsk", "Enabled")
        if on {
            saLinkMenu.Check(SALINK_ON)
            SaLinkStart()
        } else {
            saLinkMenu.Uncheck(SALINK_ON)
            SaLinkStop()
        }
        statusText.Text := "Status: Screen ask is now " (on ? "on - press Ctrl+Shift+Alt+A (or tray > Screen ask) to mark your screen and ask" : "off")
    } catch as err {
        SaLinkReport(err)
    }
}

SaLinkStart(arg := "") {
    global saLinkPid
    SaLinkStop()
    path := A_ScriptDir "\screen-ask.ahk"
    if !FileExist(path) {
        statusText.Text := "Status: screen-ask.ahk not found - Screen ask is off (captions unaffected)"
        return false
    }
    Run(Format('"{}" "{}" {} {}', A_AhkPath, path, myGui.Hwnd, arg), A_ScriptDir, , &pid)
    saLinkPid := pid
    return true
}

SaLinkStop() {
    global saLinkPid
    if (hwnd := SaLinkWindow())
        SaLinkSend(hwnd, "quit")
    if (saLinkPid && ProcessExist(saLinkPid)) {
        try ProcessWaitClose(saLinkPid, 2)
        if ProcessExist(saLinkPid)
            try ProcessClose(saLinkPid)
    }
    saLinkPid := 0
}

; "capture" / "settings" from the tray: works even while Screen ask is off (it starts just for that)
SaLinkCommand(what) {
    try {
        if (hwnd := SaLinkWindow()) {
            SaLinkSend(hwnd, what)
            return
        }
        if !SaLinkEnabled() && (what = "capture") {
            if (MsgBox("Screen ask is off.`n`nTurn it on? (Then Ctrl+Shift+Alt+A freezes your screen so you can mark something and ask Copilot about it.)"
                , "Screen ask", "YesNo Icon?") != "Yes")
                return
            IniWrite(1, MIC_INI, "ScreenAsk", "Enabled")
            saLinkMenu.Check(SALINK_ON)
        }
        SaLinkStart("/" what)
    } catch as err {
        SaLinkReport(err)
    }
}

SaLinkWindow() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := WinExist(SALINK_WIN)
    DetectHiddenWindows(prev)
    return hwnd
}

SaLinkSend(hwnd, what) {
    msg := '{"t":"' what '"}'
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", SALINK_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(0x4A, 0, cds, , Integer(hwnd), , , , 2000)
        return true
    }
    return false
}

SaLinkReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: Screen ask problem (captions unaffected): " msg
}
