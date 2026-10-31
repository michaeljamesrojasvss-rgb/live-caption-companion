#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\..\..\app\UIA.ahk

; ==============================================================================
;  3CX capture tool - saves everything Windows exposes about the 3CX window(s)
;
;  Ctrl+Shift+Alt+3  -> capture while the call is RINGING (before answering)
;  Ctrl+Shift+Alt+4  -> capture while ON the call (after answering)
;  Ctrl+Shift+Alt+5  -> capture while IDLE (no call) - useful for comparison
;
;  TIP: keep the mouse over the 3CX ringing popup when you press the hotkey.
;       The window under the mouse is always captured, even if it is not
;       recognised as 3CX (e.g. a Windows notification).
;
;  Output: 3cx-capture-<STATE>-<time>.txt next to this script.
; ==============================================================================

MASK_DIGITS := false      ; true = replace every digit with # in the saved file

^+!3:: Capture("RINGING")
^+!4:: Capture("ON-CALL")
^+!5:: Capture("IDLE")

Capture(label) {
    ToolTip "Capturing 3CX (" label ")..."
    MouseGetPos(, , &hoverHwnd)
    hoverRoot := hoverHwnd ? DllCall("GetAncestor", "Ptr", hoverHwnd, "UInt", 2, "Ptr") : 0  ; GA_ROOT

    out := "3CX capture: " label "   " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n"
    out .= "Windows " A_OSVersion "   AutoHotkey " A_AhkVersion "   admin: " (A_IsAdmin ? "yes" : "no") "`n`n"

    ; ---- every window whose title, program or class mentions 3cx (hidden ones too)
    targets := Map()
    out .= "== Windows matching '3cx' (title / program / class) ==`n"
    found := 0
    DetectHiddenWindows true
    for hwnd in WinGetList() {
        try {
            t := WinGetTitle(hwnd)
            exe := WinGetProcessName(hwnd)
            cls := WinGetClass(hwnd)
            WinGetPos(&x, &y, &w, &h, hwnd)
        } catch {
            continue
        }
        if !RegExMatch(t " " exe " " cls, "i)3cx")
            continue
        found += 1
        vis := DllCall("IsWindowVisible", "Ptr", hwnd) ? "visible" : "HIDDEN"
        out .= Format("{}. hwnd={}  title='{}'  program={}  class={}  {}  pos={},{}  size={}x{}`n"
            , found, hwnd, t, exe, cls, vis, x, y, w, h)
        if (vis = "visible" && w > 0 && h > 0)
            targets[hwnd] := "matched 3cx"
    }
    DetectHiddenWindows false
    if (found = 0)
        out .= "(none)`n"

    if (hoverRoot && !targets.Has(hoverRoot))
        targets[hoverRoot] := "window under the mouse"

    ; ---- full UI Automation tree of each target window
    for hwnd, why in targets {
        t := "", exe := "", cls := ""
        try {
            t := WinGetTitle(hwnd)
            exe := WinGetProcessName(hwnd)
            cls := WinGetClass(hwnd)
        }
        out .= "`n`n==================================================================`n"
        out .= "WINDOW '" t "'  program=" exe "  class=" cls "  [" why "]`n"
        out .= "==================================================================`n"

        start := A_TickCount
        tree := ""
        try {
            root := UIA.ElementFromHandle(hwnd)
            tree := root.DumpAll()
            ; Chromium-based apps sometimes build their accessibility tree only
            ; after the first request - wait a moment and try again if it's thin
            if (StrSplit(tree, "`n").Length < 15) {
                Sleep 700
                root := UIA.ElementFromHandle(hwnd)
                tree := root.DumpAll()
            }
        } catch as err {
            tree := "UIA dump failed: " err.Message "`n"
        }
        took := A_TickCount - start

        ; Quick summary: lines that look like call controls
        hits := ""
        for ln in StrSplit(tree, "`n", "`r")
            if RegExMatch(ln, "i)answer|decline|accept|reject|incoming|ringing|calling")
                hits .= "   " SubStr(Trim(ln), 1, 200) "`n"
        out .= "-- lines mentioning answer/decline/incoming/ringing:`n" (hits = "" ? "   (none)`n" : hits)
        out .= "-- dump took " took " ms`n`n"
        out .= tree "`n"
    }

    if MASK_DIGITS
        out := RegExReplace(out, "\d", "#")

    path := A_ScriptDir "\3cx-capture-" label "-" FormatTime(, "HHmmss") ".txt"
    FileAppend(out, path, "UTF-8")
    ToolTip "Saved " path
    SetTimer () => ToolTip(), -4000
}
