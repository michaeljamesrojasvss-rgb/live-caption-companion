#Requires AutoHotkey v2.0
#SingleInstance Force

; ==============================================================================
;  copilot-probe2.ahk  -  second no-focus test: send keys straight to the
;  Copilot window's web content, without activating the window.
;
;  Setup: open the big Copilot window, click INTO its message box once
;  (so the box has the cursor), then click into another window (e.g. Notepad).
;  Keep Copilot visible so you can watch it.
;
;  Ctrl+Shift+Alt+8  -> types "Reply with only the word OK. (typing test)"
;  Ctrl+Shift+Alt+9  -> pastes   "Reply with only the word OK. (paste test)"
;                       (clear the box in between if test 8 worked)
;  Ctrl+Shift+Alt+0  -> presses Enter in Copilot
;  Ctrl+Shift+Alt+-  -> opens the report (copilot-probe2.txt)
;
;  After each one, note: did the text appear / did it send? Did the window you
;  were in stay active?
; ==============================================================================

COPILOT := "ahk_exe M365Copilot.exe"
report := "Copilot probe 2  " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n"

^+!8:: Test("type",  "{Text}Reply with only the word OK. (typing test)")
^+!9:: Test("paste", "")
^+!0:: Test("enter", "{Enter}")
^+!-:: SaveReport()

Test(name, keys) {
    global report
    target := FindTarget(&info)
    report .= "---- " name " test at " FormatTime(, "HH:mm:ss") "`n   " info "`n"
    if !target {
        Tip("Copilot window or its web content was not found - see report")
        return
    }
    ; Wait until Ctrl/Shift/Alt from the hotkey are physically released - while
    ; they are held, Enter arrives as Shift+Enter and typed text gets swallowed.
    for k in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
        KeyWait(k)
    Sleep(150)
    before := WinExist("A")
    try {
        if (name = "paste") {
            saved := ClipboardAll()
            A_Clipboard := "Reply with only the word OK. (paste test)"
            ClipWait(1)
            ControlSend("^v", target)
            Sleep(300)
            A_Clipboard := saved
        } else {
            ControlSend(keys, target)
        }
        report .= "   sent with no error`n"
    } catch as err {
        report .= "   FAILED - " err.Message "`n"
    }
    Sleep(300)
    after := WinExist("A")
    report .= "   active window " (after = before ? "unchanged (focus NOT taken)" : "CHANGED to " WinDesc(after)) "`n"
    Tip(name " test done - did it work in Copilot?")
}

; The web content of a WebView2/Chromium app lives in a child window of class
; Chrome_RenderWidgetHostHWND. Returns its hwnd (0 if not found).
FindTarget(&info) {
    hwnd := WinExist(COPILOT)
    if !hwnd {
        info := "no Copilot window (M365Copilot.exe) found"
        return 0
    }
    classes := ""
    target := 0
    try {
        for ctrl in WinGetControls("ahk_id " hwnd) {
            classes .= ctrl "  "
            if (!target && InStr(ctrl, "Chrome_RenderWidgetHostHWND"))
                target := ControlGetHwnd(ctrl, "ahk_id " hwnd)
        }
    }
    info := "window '" WinGetTitle("ahk_id " hwnd) "'  controls: " (classes = "" ? "(none listed)" : classes)
        . "`n   target: " (target ? "Chrome_RenderWidgetHostHWND found" : "web content control NOT found")
    return target
}

WinDesc(hwnd) {
    if !hwnd
        return "(none)"
    try return "'" WinGetTitle("ahk_id " hwnd) "' (" WinGetProcessName("ahk_id " hwnd) ")"
    return "(unknown)"
}

SaveReport() {
    path := A_ScriptDir "\copilot-probe2.txt"
    try FileDelete(path)
    FileAppend(report, path, "UTF-8")
    Run('notepad.exe "' path '"')
}

Tip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -4000)
}
