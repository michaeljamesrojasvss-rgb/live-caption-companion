; ==============================================================================
; same-value-link.ahk  -  starts the Same value highlighter (same-value.ahk) from the Companion (SvLink*)
;
; * OFF by default for everyone. Tray > "Same value highlighter" > "On" (live-captions.ini [SameValue]
;   Enabled, per person). While on, holding CapsLock shows equal values on screen in the same colour.
; * Mouse way: "Show now" (works while it's off too: starts it just for that) and "Settings..." (a window; its "Settings file" button opens the raw file).
; * Its own app and process: if it fails, captions and the call carry on. It ends with the Companion.
;   Design: docs\SAME-VALUE.md.
; Hooks: SvLinkInit() (after AgtLinkInit), SvLinkShutdown()
; ==============================================================================

SVLINK_MENU := "Same value highlighter (hold CapsLock)"
SVLINK_ON := "On (starts with the Companion)"
SVLINK_SHOW := "Show now"
SVLINK_SETTINGS := "Settings..."
SVLINK_TAG := 0x3CC7
SVLINK_WIN := "Caption Companion Same value ahk_class AutoHotkeyGUI"
svLinkPid := 0
svLinkMenu := 0

SvLinkInit() {
    global svLinkMenu
    try {
        svLinkMenu := Menu()
        svLinkMenu.Add(SVLINK_ON, (*) => SvLinkToggle())
        svLinkMenu.Add()
        svLinkMenu.Add(SVLINK_SHOW, (*) => SvLinkCommand("show"))
        svLinkMenu.Add(SVLINK_SETTINGS, (*) => SvLinkCommand("settings"))
        A_TrayMenu.Insert("2&", SVLINK_MENU, svLinkMenu)
        if SvLinkEnabled() {
            svLinkMenu.Check(SVLINK_ON)
            SvLinkStart()
        }
    } catch as err {
        SvLinkReport(err)
    }
}

SvLinkShutdown() {
    try SvLinkStop()
}

SvLinkEnabled() {
    try return IniRead(MIC_INI, "SameValue", "Enabled", "0") = "1"
    return false
}

SvLinkToggle() {
    try {
        on := !SvLinkEnabled()
        IniWrite(on ? 1 : 0, MIC_INI, "SameValue", "Enabled")
        if on {
            svLinkMenu.Check(SVLINK_ON)
            SvLinkStart()
        } else {
            svLinkMenu.Uncheck(SVLINK_ON)
            SvLinkStop()
        }
        statusText.Text := "Status: Same value highlighter is now " (on ? "on - hold CapsLock to see equal values in the same colour" : "off")
    } catch as err {
        SvLinkReport(err)
    }
}

; "show" / "settings" from the tray: works while it's off too (it starts just for that)
SvLinkCommand(what) {
    try {
        if (hwnd := SvLinkWindow()) {
            SvLinkSend(hwnd, what)
            return
        }
        SvLinkStart("/" what (SvLinkEnabled() ? "" : " /once"))   ; off: no hold key, it quits when done
    } catch as err {
        SvLinkReport(err)
    }
}

SvLinkStart(arg := "") {
    global svLinkPid
    SvLinkStop()
    path := A_ScriptDir "\same-value.ahk"
    if !FileExist(path) {
        statusText.Text := "Status: same-value.ahk not found - the Same value highlighter is off (captions unaffected)"
        return false
    }
    Run(Format('"{}" "{}" {} {}', A_AhkPath, path, myGui.Hwnd, arg), A_ScriptDir, , &pid)
    svLinkPid := pid
    return true
}

SvLinkStop() {
    global svLinkPid
    if (hwnd := SvLinkWindow())
        SvLinkSend(hwnd, "quit")
    if (svLinkPid && ProcessExist(svLinkPid)) {
        try ProcessWaitClose(svLinkPid, 2)
        if ProcessExist(svLinkPid)
            try ProcessClose(svLinkPid)
    }
    svLinkPid := 0
}

SvLinkWindow() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := WinExist(SVLINK_WIN)
    DetectHiddenWindows(prev)
    return hwnd
}

SvLinkSend(hwnd, what) {
    msg := '{"t":"' what '"}'
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", SVLINK_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(0x4A, 0, cds, , Integer(hwnd), , , , 2000)
        return true
    }
    return false
}

SvLinkReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: Same value highlighter problem (captions unaffected): " msg
}
