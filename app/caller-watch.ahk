#Requires AutoHotkey v2.0
#SingleInstance Force
#Include UIA.ahk

; ==============================================================================
; caller-watch.ahk  -  read-only watcher for the 3CX desktop app
;
; * Started by liveCaptionCompanion.ahk as its OWN process. If this script
;   errors, hangs or is closed, the companion and its captions keep running.
; * It only READS 3CX. It never clicks, types or changes anything in 3CX.
; * It reports state changes to the companion (WM_COPYDATA):
;       ringing <TAB> FromCallerExtensionText <TAB> FromCallerNameText
;       oncall  <TAB>                         <TAB> ContactName
;       idle    /  nowindow  /  hidden (on another desktop, state unknown)
; * Every change is written to caller-debug.log (path given by the companion,
;   otherwise next to the script).
; * Run it on its own (double-click) to test: changes show as tooltips.
; ==============================================================================

W_TARGET := (A_Args.Length >= 1 && IsInteger(A_Args[1])) ? Integer(A_Args[1]) : 0
W_LOG_RAW := (A_Args.Length >= 2) ? (A_Args[2] = "1") : true
W_POLL_MS := 300
W_SLOW_MS := 2000
W_LOG_PATH := (A_Args.Length >= 3 && A_Args[3] != "") ? A_Args[3] : A_ScriptDir "\caller-debug.log"
W_TAG := 0x3CC0
W_3CX := "3CX ahk_exe 3CXSoftphone.exe ahk_class WinUIDesktopWin32WindowClass"

w_lastKey := ""
w_failCount := 0
w_slowMode := false

if W_TARGET {
    A_IconHidden := true
} else {
    ToolTip("Watching 3CX (test mode). Exit from the tray icon.")
    SetTimer(() => ToolTip(), -3000)
}
W_Log("watcher started" (W_TARGET ? "" : " (test mode)"))
SetTimer(W_Tick, W_POLL_MS)

W_Tick() {
    global w_lastKey, w_failCount, w_slowMode
    if (W_TARGET && !W_CompanionAlive()) {
        W_Log("companion closed - watcher exiting")
        ExitApp()
    }
    try {
        s := W_Read3cx()
    } catch as err {
        w_failCount += 1
        if (w_failCount = 1 || Mod(w_failCount, 100) = 0)
            W_Log("read error #" w_failCount ": " err.Message)
        if (w_failCount >= 5 && !w_slowMode) {
            w_slowMode := true
            SetTimer(W_Tick, W_SLOW_MS)       ; keep trying, but gently
        }
        return
    }
    w_failCount := 0
    if w_slowMode {
        w_slowMode := false
        SetTimer(W_Tick, W_POLL_MS)
    }
    key := s[1] "`t" s[2] "`t" s[3]
    if (key == w_lastKey)
        return
    w_lastKey := key
    W_Log(W_LOG_RAW ? StrReplace(key, "`t", " | ") : s[1])
    W_Notify(key)
}

; When 3CX is on another virtual desktop, Windows only exposes its title bar, so the
; ring is read from 3CX's "INCOMING CALL" notification instead. If neither can be read
; the state is "hidden", which the companion ignores (it keeps the last known state).
W_Read3cx() {
    hwnd := W_Find3cx()
    cloaked := hwnd && W_IsCloaked(hwnd)
    if (hwnd && !cloaked) {
        root := UIA.ElementFromHandle(hwnd)
        if IsObject(W_FindId(root, "AnswerCallButton"))
            return ["ringing", W_NameOf(root, "FromCallerExtensionText"), W_NameOf(root, "FromCallerNameText")]
        if IsObject(W_FindId(root, "EndCallButton"))
            return ["oncall", "", W_NameOf(root, "ContactName")]
    }
    toast := W_ReadToast()
    if IsObject(toast)
        return toast
    if !hwnd
        return ["nowindow", "", ""]
    return cloaked ? ["hidden", "", ""] : ["idle", "", ""]
}

W_IsCloaked(hwnd) {
    c := 0
    try DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &c, "UInt", 4)   ; DWMWA_CLOAKED
    return c != 0
}

; Reads a Windows notification from 3CX whose title is "<name>`n INCOMING CALL - <number>".
; Returns ["ringing", number, name], or "" when there is none. Only reads, never clicks.
W_ReadToast() {
    for hwnd in W_NotificationWindows() {
        try {
            root := UIA.ElementFromHandle(hwnd)
            for el in root.FindElements({AutomationId: "Title"}) {
                title := el.Name
                if !RegExMatch(title, "i)INCOMING CALL\s*-?\s*(.*)", &m)
                    continue
                sender := ""
                try sender := el.Parent.FindElement({AutomationId: "SenderName"}).Name
                if (sender != "3CX")
                    continue
                name := Trim(RegExReplace(SubStr(title, 1, m.Pos - 1), "\s+", " "))
                return ["ringing", Trim(StrReplace(m[1], "`t", " ")), StrReplace(name, "`t", " ")]
            }
        }
    }
    return ""
}

; The notification host window always exists, but WinGetList with ahk_exe misses it
; (Windows won't tell AHK that protected process's name), so walk the windows of its
; class with FindWindowEx and check the process via its PID instead.
W_NotificationWindows() {
    wins := []
    h := 0
    Loop {
        h := DllCall("FindWindowEx", "Ptr", 0, "Ptr", h, "Str", "Windows.UI.Core.CoreWindow", "Ptr", 0, "Ptr")
        if !h
            break
        pid := 0
        DllCall("GetWindowThreadProcessId", "Ptr", h, "UInt*", &pid)
        try {
            if (ProcessGetName(pid) = "ShellExperienceHost.exe")
                wins.Push(h)
        }
    }
    return wins
}

; On another virtual desktop 3CX is "cloaked", which AHK treats as hidden, so a plain
; WinExist misses it. Search hidden windows too, but only take one that is really open
; (WS_VISIBLE), not a truly hidden one such as 3CX closed to the tray.
W_Find3cx() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    found := 0
    for hwnd in WinGetList(W_3CX) {
        if (WinGetStyle(hwnd) & 0x10000000) {      ; WS_VISIBLE
            found := hwnd
            break
        }
    }
    DetectHiddenWindows(prev)
    return found
}

W_FindId(root, id) {
    try return root.FindElement({AutomationId: id})
    return ""
}

W_NameOf(root, id) {
    el := W_FindId(root, id)
    if !IsObject(el)
        return ""
    try return Trim(StrReplace(el.Name, "`t", " "))
    return ""
}

W_CompanionAlive() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    ok := WinExist("ahk_id " W_TARGET)
    DetectHiddenWindows(prev)
    return ok
}

W_Notify(msg) {
    if !W_TARGET {
        ToolTip("3CX: " StrReplace(msg, "`t", " | "))
        SetTimer(() => ToolTip(), -4000)
        return
    }
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", W_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    try SendMessage(0x4A, 0, cds, , "ahk_id " W_TARGET, , , , 2000)   ; WM_COPYDATA, 2 s max
    catch as err
        W_Log("could not reach the companion: " err.Message)
    DetectHiddenWindows(prev)
}

W_Log(line) {
    try {
        if (FileExist(W_LOG_PATH) && FileGetSize(W_LOG_PATH) > 1000000)
            FileMove(W_LOG_PATH, W_LOG_PATH ".old", true)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  [watcher] " line "`n", W_LOG_PATH, "UTF-8")
    }
}
