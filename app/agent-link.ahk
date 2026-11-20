; ==============================================================================
; agent-link.ahk  -  starts the Agent (agent.ahk) from the Companion (prefix AgtLink*)
;
; * Ships to everyone, OFF by default in installed copies (nothing runs, no memory used); ON by default in
;   dev mode (AppIsDev: your git working copy). Each person's choice: live-captions.ini [Agent] Enabled.
;   Design: docs\AGENT.md.
; * Tray > "Agent": "On (starts with the Companion)" and "Open the agent" (works while it's off too:
;   starts it just for that).
; * The Agent is its own app and process: if it fails, captions and the call carry on. It ends with the
;   Companion. Its shortcut (Ctrl+Shift+Alt+G by default) belongs to the Agent itself.
; Hooks: AgtLinkInit() (after SaLinkInit), AgtLinkShutdown()
; ==============================================================================

AGTLINK_MENU := "Agent (AI that uses tools - early test)"
AGTLINK_ON := "On (starts with the Companion)"
AGTLINK_OPEN := "Open the agent"
AGTLINK_TAG := 0x3CC6
AGTLINK_WIN := "Caption Companion Agent ahk_class AutoHotkeyGUI"
agtLinkPid := 0
agtLinkMenu := 0

AgtLinkInit() {
    global agtLinkMenu
    try {
        agtLinkMenu := Menu()
        agtLinkMenu.Add(AGTLINK_ON, (*) => AgtLinkToggle())
        agtLinkMenu.Add()
        agtLinkMenu.Add(AGTLINK_OPEN, (*) => AgtLinkOpen())
        A_TrayMenu.Insert("2&", AGTLINK_MENU, agtLinkMenu)
        if AgtLinkEnabled() {
            agtLinkMenu.Check(AGTLINK_ON)
            AgtLinkStart()
        }
    } catch as err {
        AgtLinkReport(err)
    }
}

AgtLinkShutdown() {
    try AgtLinkStop()
}

AgtLinkEnabled() {
    try return IniRead(MIC_INI, "Agent", "Enabled", AppIsDev() ? "1" : "0") = "1"
    return false
}

AgtLinkToggle() {
    try {
        on := !AgtLinkEnabled()
        IniWrite(on ? 1 : 0, MIC_INI, "Agent", "Enabled")
        if on {
            agtLinkMenu.Check(AGTLINK_ON)
            AgtLinkStart()
        } else {
            agtLinkMenu.Uncheck(AGTLINK_ON)
            AgtLinkStop()
        }
        statusText.Text := "Status: the Agent is now " (on ? "on - Ctrl+Shift+Alt+G (or tray > Agent) opens it" : "off")
    } catch as err {
        AgtLinkReport(err)
    }
}

AgtLinkOpen() {
    try {
        if (hwnd := AgtLinkWindow()) {
            AgtLinkSend(hwnd, "show")
            return
        }
        AgtLinkStart("/show")
    } catch as err {
        AgtLinkReport(err)
    }
}

AgtLinkStart(arg := "") {
    global agtLinkPid
    AgtLinkStop()
    path := A_ScriptDir "\agent.ahk"
    if !FileExist(path) {
        statusText.Text := "Status: agent.ahk not found - the Agent is off (captions unaffected)"
        return false
    }
    Run(Format('"{}" "{}" {} {}', A_AhkPath, path, myGui.Hwnd, arg), A_ScriptDir, , &pid)
    agtLinkPid := pid
    return true
}

AgtLinkStop() {
    global agtLinkPid
    if (hwnd := AgtLinkWindow())
        AgtLinkSend(hwnd, "quit")
    if (agtLinkPid && ProcessExist(agtLinkPid)) {
        try ProcessWaitClose(agtLinkPid, 2)
        if ProcessExist(agtLinkPid)
            try ProcessClose(agtLinkPid)
    }
    agtLinkPid := 0
}

AgtLinkWindow() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := WinExist(AGTLINK_WIN)
    DetectHiddenWindows(prev)
    return hwnd
}

AgtLinkSend(hwnd, what) {
    msg := '{"t":"' what '"}'
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", AGTLINK_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(0x4A, 0, cds, , Integer(hwnd), , , , 2000)
        return true
    }
    return false
}

AgtLinkReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: Agent problem (captions unaffected): " msg
}
