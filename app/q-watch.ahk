#Requires AutoHotkey v2.0
#SingleInstance Force
#Include UIA.ahk

; ==============================================================================
; q-watch.ahk  -  read-only check: is 3CX logged in to the Queue (the "Q" icon)?
;
; * Started by liveCaptionCompanion.ahk (q-alert.ahk) as its OWN process, so if it
;   errors or hangs the companion and its captions keep running.
; * Only READS 3CX (UI Automation + the colour of the Q icon). Never clicks or types.
; * Every interval (default 10 s) it sends the companion one message:
;       q <TAB> on        Q icon is blue      (logged in)
;       q <TAB> off       Q icon is not blue  (logged out)
;       q <TAB> unknown   can't tell (3CX closed / minimised / on another desktop /
;                         covered by another window / Q icon not found)
;   The companion shows the toast only for "off".
; * Settings (data\live-captions.ini, section [QAlert]), all optional:
;       ElementId=    AutomationId of the Q icon (find it with tools\dev\window_inspector.ahk)
;       ElementName=  part of the Q icon's Name (used if ElementId is empty)
;       MinBlue=2     how many blue pixels (of 64 sampled) count as "blue"
; * Run it on its own (double-click) to test: the state shows as a tooltip.
; ==============================================================================

Q_TARGET := (A_Args.Length >= 1 && IsInteger(A_Args[1])) ? Integer(A_Args[1]) : 0
Q_INTERVAL := (A_Args.Length >= 2 && IsInteger(A_Args[2])) ? Max(3, Integer(A_Args[2])) * 1000 : 10000
Q_LOG := (A_Args.Length >= 3 && A_Args[3] != "") ? A_Args[3] : A_ScriptDir "\caller-debug.log"
Q_INI := (A_Args.Length >= 4) ? A_Args[4] : ""
Q_TAG := 0x3CC1
Q_3CX := "3CX ahk_exe 3CXSoftphone.exe ahk_class WinUIDesktopWin32WindowClass"

q_lastKey := ""
q_missCount := 0

if Q_TARGET {
    A_IconHidden := true
} else {
    ToolTip("Q watcher (test mode): checking every " (Q_INTERVAL // 1000) " s. Exit from the tray icon.")
    SetTimer(() => ToolTip(), -3000)
}
QW_Log("started" (Q_TARGET ? "" : " (test mode)"))
SetTimer(QW_Tick, Q_INTERVAL)
QW_Tick()

QW_Tick() {
    global q_lastKey
    if (Q_TARGET && !QW_CompanionAlive()) {
        QW_Log("companion closed - exiting")
        ExitApp()
    }
    state := "unknown"
    why := ""
    try {
        r := QW_ReadState()
        state := r[1]
        why := r[2]
    } catch as err {
        why := "read error: " err.Message
    }
    key := state " " why
    if (key != q_lastKey) {
        q_lastKey := key
        QW_Log("Q = " state (why != "" ? "  (" why ")" : ""))
    }
    QW_Notify(state)
}

; Returns [state, detail]
QW_ReadState() {
    global q_missCount
    hwnd := QW_Find3cx()
    if !hwnd
        return ["unknown", "3CX window not open"]
    if (WinGetMinMax("ahk_id " hwnd) = -1)
        return ["unknown", "3CX is minimised"]
    if QW_IsCloaked(hwnd)
        return ["unknown", "3CX is on another virtual desktop"]

    root := UIA.ElementFromHandle(hwnd)
    el := QW_FindQ(root)
    if !IsObject(el) {
        q_missCount += 1
        if (q_missCount = 1 || Mod(q_missCount, 30) = 0) {
            QW_Log("Q icon element not found (is the dialpad view showing? set ElementId / ElementName in [QAlert])")
            QW_DumpTop(root, hwnd)
        }
        return ["unknown", "Q icon element not found"]
    }
    q_missCount := 0

    br := el.BoundingRectangle
    w := br.r - br.l
    h := br.b - br.t
    if (w < 4 || h < 4)
        return ["unknown", "Q icon has no size on screen"]

    ; make sure 3CX is really what is showing at that spot (not covered by another window)
    cx := br.l + w // 2
    cy := br.t + h // 2
    top := DllCall("WindowFromPoint", "Int64", (cx & 0xFFFFFFFF) | (cy << 32), "Ptr")
    if (!top || DllCall("GetAncestor", "Ptr", top, "UInt", 2, "Ptr") != hwnd)
        return ["unknown", "3CX is covered by another window"]

    n := QW_CountBlue(br)
    need := Integer(QW_Ini("MinBlue", 2))
    return [(n >= need) ? "on" : "off", n " blue pixels of 64"]
}

; Finds the Q icon element. ElementId / ElementName from the ini win; otherwise a guess by name.
QW_FindQ(root) {
    id := QW_Ini("ElementId", "")
    nm := QW_Ini("ElementName", "")
    if (id != "") {
        try return root.FindElement({AutomationId: id})
        return ""
    }
    if (nm != "") {
        try return root.FindElement({Name: nm, MatchMode: "Substring"})
        return ""
    }
    for pat in ["i)^Q$", "i)queue"] {
        for prop in ["Name", "AutomationId"] {
            cond := {}
            cond.%prop% := pat
            cond.MatchMode := "RegEx"
            try {
                for el in root.FindElements(cond) {
                    br := el.BoundingRectangle
                    if (br.r - br.l >= 6 && br.b - br.t >= 6)
                        return el
                }
            }
        }
    }
    return ""
}

; Counts "blue" pixels on an 8x8 grid inside the icon's rectangle
QW_CountBlue(br) {
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    if !hdc
        return 0
    n := 0
    steps := 8
    w := br.r - br.l
    h := br.b - br.t
    Loop steps {
        y := br.t + (A_Index * h) // (steps + 1)
        Loop steps {
            x := br.l + (A_Index * w) // (steps + 1)
            c := DllCall("GetPixel", "Ptr", hdc, "Int", x, "Int", y, "UInt")
            if (c = 0xFFFFFFFF)
                continue
            red := c & 0xFF
            grn := (c >> 8) & 0xFF
            blu := (c >> 16) & 0xFF
            if (blu >= 140 && blu - red >= 70 && blu - grn >= 20)
                n += 1
        }
    }
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return n
}

; Diagnostics: logs what is in the top part of the 3CX window, so the Q icon can be identified
QW_DumpTop(root, hwnd) {
    try {
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
        QW_Log("--- elements in the top 300 px of the 3CX window (type | name | id | rect) ---")
        n := 0
        for el in root.FindAll(UIA.TrueCondition, 4) {
            try {
                br := el.BoundingRectangle
                if (br.r - br.l < 2 || br.t - wy > 300 || br.t < wy - 5)
                    continue
                QW_Log("   " el.LocalizedType " | " el.Name " | " el.AutomationId " | " br.l "," br.t "," br.r "," br.b)
                n += 1
                if (n >= 80)
                    break
            }
        }
        QW_Log("--- end of list ---")
    }
}

QW_Ini(key, default) {
    if (Q_INI = "")
        return default
    try return IniRead(Q_INI, "QAlert", key, default)
    return default
}

QW_IsCloaked(hwnd) {
    c := 0
    try DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &c, "UInt", 4)
    return c != 0
}

QW_Find3cx() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    found := 0
    for hwnd in WinGetList(Q_3CX) {
        if (WinGetStyle(hwnd) & 0x10000000) {      ; WS_VISIBLE (not just closed to the tray)
            found := hwnd
            break
        }
    }
    DetectHiddenWindows(prev)
    return found
}

QW_CompanionAlive() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    ok := WinExist("ahk_id " Q_TARGET)
    DetectHiddenWindows(prev)
    return ok
}

QW_Notify(state) {
    if !Q_TARGET {
        ToolTip("3CX Q: " state)
        SetTimer(() => ToolTip(), -4000)
        return
    }
    msg := "q`t" state
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", Q_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    try SendMessage(0x4A, 0, cds, , "ahk_id " Q_TARGET, , , , 2000)
    catch as err
        QW_Log("could not reach the companion: " err.Message)
    DetectHiddenWindows(prev)
}

QW_Log(line) {
    try {
        if (FileExist(Q_LOG) && FileGetSize(Q_LOG) > 1000000)
            FileMove(Q_LOG, Q_LOG ".old", true)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  [q-watch] " line "`n", Q_LOG, "UTF-8")
    }
}
