#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\..\..\app\UIA.ahk
CoordMode "Mouse", "Screen"

; ==============================================================================
;  copilot-probe.ahk  -  can we send to Copilot WITHOUT taking focus?
;
;  1. Open your Copilot window (the big one) as you normally would.
;  2. Hover the Copilot INPUT box          -> Ctrl+Shift+Alt+6
;  3. Hover the Copilot SEND button        -> Ctrl+Shift+Alt+7
;     (type one letter in the box first if Send only appears with text)
;  4. Click into a DIFFERENT window (e.g. Notepad), then -> Ctrl+Shift+Alt+8
;     The probe tries to put a short test message into Copilot and press Send
;     using UI Automation only - no clicking, no typing, no window switching.
;     Watch Copilot: did the text appear? Did it send?
;  5. Ctrl+Shift+Alt+9 opens the report (copilot-probe.txt). Send it to Claude,
;     plus what you saw in step 4.
;
;  The only thing it ever sends is: "Reply with only the word OK. (automation test)"
; ==============================================================================

report := "Copilot probe  " FormatTime(, "yyyy-MM-dd HH:mm:ss")
    . "   Windows " A_OSVersion "   AutoHotkey " A_AhkVersion "`n"
inputEl := ""
sendEl := ""

^+!6:: Remember("input")
^+!7:: Remember("send")
^+!8:: RunTest()
^+!9:: SaveReport(true)

Remember(kind) {
    global inputEl, sendEl
    MouseGetPos(&mx, &my, &hwnd)
    try {
        el := UIA.ElementFromPoint(mx, my)
    } catch as err {
        Add("[" kind "] could not read the element under the mouse: " err.Message)
        Tip("Could not read that element - try again, or see the report")
        return
    }
    info := Describe(el, hwnd)
    Add("[" kind "] " info)
    if (kind = "input")
        inputEl := el
    else
        sendEl := el
    Tip("Saved " kind ":`n" info)
}

RunTest() {
    if !IsObject(inputEl) {
        Tip("First hover the Copilot input box and press Ctrl+Shift+Alt+6")
        return
    }
    before := WinExist("A")
    msg := "Reply with only the word OK. (automation test " FormatTime(, "HH:mm:ss") ")"
    Add("---- test at " FormatTime(, "HH:mm:ss") "   active window before: " WinDesc(before))

    ; 1) put the text in, trying three different ways
    for method in ["Value property", "ValuePattern.SetValue", "LegacyIAccessible.SetValue"] {
        try {
            switch method {
                case "Value property":             inputEl.Value := msg
                case "ValuePattern.SetValue":      inputEl.ValuePattern.SetValue(msg)
                case "LegacyIAccessible.SetValue": inputEl.LegacyIAccessiblePattern.SetValue(msg)
            }
            Sleep(400)
            back := ""
            try back := inputEl.Value
            Add("   set text via " method ": no error, value read back = '" Short(back) "'")
            if InStr(back, "automation test")
                break
        } catch as err {
            Add("   set text via " method ": FAILED - " err.Message)
        }
    }

    ; 2) press Send without clicking
    if IsObject(sendEl) {
        Sleep(600)
        enabled := "?"
        try enabled := sendEl.IsEnabled ? "yes" : "no"
        Add("   send button enabled: " enabled)
        for method in ["Invoke()", "InvokePattern.Invoke"] {
            try {
                if (method = "Invoke()")
                    sendEl.Invoke()
                else
                    sendEl.InvokePattern.Invoke()
                Add("   send via " method ": no error")
                break
            } catch as err {
                Add("   send via " method ": FAILED - " err.Message)
            }
        }
    } else {
        Add("   (no send button saved - skipped sending)")
    }

    after := WinExist("A")
    Add("   active window after: " WinDesc(after)
        . (after = before ? "   -> unchanged, focus was NOT taken" : "   -> CHANGED"))
    SaveReport(false)
    Tip("Test done. Note what you saw in Copilot:`n- did the text appear?`n- did it send?`nThen Ctrl+Shift+Alt+9")
}

Describe(el, hwnd) {
    t := ""
    try t .= "window='" WinGetTitle(hwnd) "'  program=" WinGetProcessName(hwnd) "  class=" WinGetClass(hwnd) "`n      "
    for prop in ["Name", "LocalizedType", "AutomationId", "ClassName"] {
        v := ""
        try v := el.%prop%
        t .= prop "='" Short(v) "'  "
    }
    t .= "`n      patterns: " Patterns(el)
    return t
}

Patterns(el) {
    out := ""
    for p in ["Value", "Text", "Invoke", "LegacyIAccessible"] {
        state := "no"
        try {
            pat := el.%p "Pattern"%
            if IsObject(pat)
                state := "yes"
        }
        out .= p "=" state "  "
    }
    return out
}

WinDesc(hwnd) {
    if !hwnd
        return "(none)"
    try return "'" WinGetTitle("ahk_id " hwnd) "' (" WinGetProcessName("ahk_id " hwnd) ")"
    return "(unknown)"
}

Add(line) {
    global report
    report .= line "`n"
}

SaveReport(open) {
    path := A_ScriptDir "\copilot-probe.txt"
    try FileDelete(path)
    FileAppend(report, path, "UTF-8")
    if open
        Run('notepad.exe "' path '"')
}

Tip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -5000)
}

Short(s) => StrLen(s) > 80 ? SubStr(s, 1, 80) "…" : s
