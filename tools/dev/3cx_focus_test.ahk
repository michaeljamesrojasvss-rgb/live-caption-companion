#Requires AutoHotkey v2.0
#SingleInstance Force

; ==============================================================================
;  3CX focus test - does bringing 3CX to the front work across virtual desktops?
;
;  1. Run it, click OK.
;  2. Within the countdown (one beep per second), switch to ANOTHER virtual
;     desktop (Ctrl+Win+Left/Right) and click into some other window there.
;  3. It then tries to bring 3CX to the front exactly like the app does
;     (CallerBring3cxToFront), and if that fails, tries a second way.
;  4. A result box appears and the same text is saved to
;     3cx-focus-test-<time>.txt next to this script.
;
;  Only activates the 3CX window. Never clicks or types into it.
; ==============================================================================

COUNTDOWN := 5        ; seconds to switch desktops
TARGET := "3CX ahk_exe 3CXSoftphone.exe ahk_class WinUIDesktopWin32WindowClass"   ; same as CALLER_3CX

if (MsgBox("After OK you have " COUNTDOWN " seconds (one beep per second) to switch to another virtual desktop.`n`nThen it will try to bring 3CX to the front.", "3CX focus test", "OKCancel") != "OK")
    ExitApp

Loop COUNTDOWN {
    SoundBeep(800, 120)
    Sleep(880)
}

out := "3CX focus test   " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n"
hwnd := WinExist(TARGET)
if !hwnd {
    ; maybe it's only found with hidden windows on (windows on other desktops are "cloaked")
    DetectHiddenWindows(true)
    hwnd := WinExist(TARGET)
    DetectHiddenWindows(false)
    out .= hwnd ? "3CX found ONLY with DetectHiddenWindows on (the app would not see it!)`n" : "3CX window NOT found at all. Is 3CX open?`n"
}
if !hwnd {
    Finish(out)
    ExitApp
}

out .= "`n--- before ---`n" Describe(hwnd)

; Method 1: what the app does today
if (WinGetMinMax(hwnd) = -1)
    WinRestore(hwnd)
try {
    WinActivate(hwnd)
} catch as err {
    out .= "WinActivate error: " err.Message "`n"
}
Sleep(500)
ok1 := WinActive(hwnd) ? true : false
out .= "`n--- after method 1 (WinRestore + WinActivate, like the app) ---`n" Describe(hwnd)
out .= "RESULT method 1: " (ok1 ? "WORKED" : "did NOT work") "`n"

; Method 2: minimize then restore (Windows tends to allow a restored window to come forward)
if !ok1 {
    Sleep(500)
    try {
        WinMinimize(hwnd)
        Sleep(200)
        WinRestore(hwnd)
        WinActivate(hwnd)
    } catch as err {
        out .= "method 2 error: " err.Message "`n"
    }
    Sleep(500)
    ok2 := WinActive(hwnd) ? true : false
    out .= "`n--- after method 2 (minimize + restore + activate) ---`n" Describe(hwnd)
    out .= "RESULT method 2: " (ok2 ? "WORKED" : "did NOT work") "`n"
}

Finish(out)
ExitApp

Describe(hwnd) {
    s := "3CX hwnd: " hwnd "   title: " WinGetTitle(hwnd) "`n"
    s .= "min/max state: " WinGetMinMax(hwnd) "   (-1 minimized, 0 normal, 1 maximized)`n"
    s .= "on current virtual desktop: " OnCurrentDesktop(hwnd) "`n"
    s .= "cloaked (hidden by Windows, e.g. other desktop): " Cloaked(hwnd) "`n"
    s .= "3CX is active window: " (WinActive(hwnd) ? "yes" : "no") "`n"
    act := WinExist("A")
    s .= "active window now: " (act ? WinGetTitle(act) " [" WinGetProcessName(act) "]" : "(none)") "`n"
    return s
}

; Uses the documented IVirtualDesktopManager COM interface (no admin needed).
OnCurrentDesktop(hwnd) {
    try {
        vdm := ComObject("{aa509086-5ca9-4c25-8f95-589d3c07b48a}", "{a5cd92ff-29be-454c-8d04-d82879fb3f1b}")
        onCur := 0
        ComCall(3, vdm, "Ptr", hwnd, "Int*", &onCur)   ; IsWindowOnCurrentVirtualDesktop
        return onCur ? "yes" : "NO (it is on another desktop)"
    } catch as err {
        return "unknown (" err.Message ")"
    }
}

Cloaked(hwnd) {
    cloaked := 0
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &cloaked, "UInt", 4)   ; DWMWA_CLOAKED
    if (hr != 0)
        return "unknown"
    return cloaked ? "yes (" cloaked ")" : "no"
}

Finish(text) {
    try FileAppend(text, A_ScriptDir "\3cx-focus-test-" FormatTime(, "yyyyMMdd-HHmmss") ".txt", "UTF-8")
    MsgBox(text, "3CX focus test result", "T60")
}
