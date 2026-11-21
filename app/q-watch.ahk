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
;       q <TAB> on      <TAB> detail   Q icon is blue      (logged in)
;       q <TAB> off     <TAB> detail   Q icon is not blue  (logged out)
;       q <TAB> no3cx   <TAB> detail   3CX isn't running, or its window is closed (tray only) -
;                                      3CX must always be open during work
;       q <TAB> unknown <TAB> detail   can't tell (3CX minimised / Q icon not found / picture unreadable)
;   The companion shows a toast for "off" and "no3cx".
; * Works on every virtual desktop. 3CX is found wherever it is. On 3CX's own desktop the Q icon's
;   colour is read from 3CX's picture of its window (PrintWindow - fine when covered), else the screen.
;   On another desktop Windows doesn't redraw 3CX (its picture is old), so Q is read from 3CX's
;   accessibility info instead, as learned on 3CX's desktop: each time the colour is read there, the
;   UIA "look" of the Q icon is saved with on/off in live-captions.ini [QAlertLearned]. Once it has
;   seen Q on and Q off on 3CX's desktop, other desktops work too ("both" = UIA looks the same either
;   way: then Q can only be read on 3CX's desktop - the log says so).
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
QW_Described := false        ; the Q icon element was described in the log
try DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")   ; real pixels: UIA, window and picture coordinates agree
; 3CX on another virtual desktop is "cloaked", which AutoHotkey treats as a hidden window. Without this every
; Win* call on it (WinGetMinMax, ...) fails with "Target window not found" and the other-desktop reading below is never reached.
DetectHiddenWindows(true)
QW_LastVia := ""             ; which child window gave the Q icon on another desktop (logged when it changes)

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
    QW_Notify(state, why)
}

; Returns [state, detail]. 3CX is checked first: it must always be open during work.
; While 3CX is on THIS desktop the Q icon's colour is read from 3CX's own picture of its window
; (PrintWindow - fine when covered), or the screen. On ANOTHER virtual desktop Windows doesn't redraw
; 3CX, so its picture is old: there Q is read from 3CX's accessibility info (UI Automation), using what
; was learned on this desktop - which info goes with Q on, and which with Q off (QW_Learn).
QW_ReadState() {
    global q_missCount, QW_LastVia
    hwnd := QW_Find3cx()
    if !hwnd
        return ProcessExist("3CXSoftphone.exe") ? ["no3cx", "3CX is running but its window is closed (only in the tray)"]
            : ["no3cx", "3CX is not running"]
    if (WinGetMinMax("ahk_id " hwnd) = -1)
        return ["unknown", "3CX is minimised - the Q icon can't be seen"]
    away := QW_IsCloaked(hwnd)

    root := UIA.ElementFromHandle(hwnd)
    el := QW_FindQ(root)
    via := ""
    if (!IsObject(el) && away)                   ; Windows may leave only the title bar in the top window's tree
        el := QW_FindQAway(hwnd, &via)
    if !IsObject(el) {
        q_missCount += 1
        if (q_missCount = 1 || Mod(q_missCount, 30) = 0) {
            QW_Log("Q icon element not found" (away ? " (3CX is on another virtual desktop)" : "")
                " (is the dialpad view showing? set ElementId / ElementName in [QAlert])")
            if away
                QW_DiagAway(hwnd, root)
            else
                QW_DumpTop(root, hwnd)
        }
        msg := away ? "3CX is on another virtual desktop and Windows hides its Q icon from accessibility tools"
            : "Q icon element not found"
        return ["unknown", msg]
    }
    if (via != QW_LastVia) {
        QW_LastVia := via
        if (via != "")
            QW_Log("on another virtual desktop the Q icon was found through the " via)
    }
    if (q_missCount != 0 || !QW_Described)
        QW_Describe(el)
    q_missCount := 0
    fp := QW_Fingerprint(el)
    key := QW_Crc(fp)

    if away {                                    ; another virtual desktop: what UIA says, as learned
        l := QW_LearnedState(key)
        if (l = "on" || l = "off")
            return [l, "3CX is on another virtual desktop - read from its accessibility info (learned " key ")"]
        return ["unknown", "3CX is on another virtual desktop and " (l = "both"
            ? "its accessibility info is the same with Q on and off - Q can only be read on 3CX's desktop"
            : "this Q look isn't learned yet (" key "): switch to 3CX's desktop once with Q on and once with Q off")]
    }

    br := el.BoundingRectangle
    w := br.r - br.l
    h := br.b - br.t
    if (w < 4 || h < 4)
        return ["unknown", "Q icon has no size"]
    need := Integer(QW_Ini("MinBlue", 2))
    n := QW_CountBlueInWindow(hwnd, br)          ; 3CX's own picture: covered is fine
    how := "window picture"
    if (n < 0) {                                 ; fallback: the screen - only if 3CX is what is showing there
        cx := br.l + w // 2
        cy := br.t + h // 2
        top := DllCall("WindowFromPoint", "Int64", (cx & 0xFFFFFFFF) | (cy << 32), "Ptr")
        if (!top || DllCall("GetAncestor", "Ptr", top, "UInt", 2, "Ptr") != hwnd)
            return ["unknown", "3CX's window picture couldn't be read and 3CX is covered by another window"]
        hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
        if !hdc
            return ["unknown", "the screen couldn't be read"]
        n := QW_CountBlueDC(hdc, br.l, br.t, w, h, &blank)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
        how := "screen"
    }
    state := (n >= need) ? "on" : "off"
    QW_Learn(key, state, fp)
    return [state, n " blue pixels of 64 (" how ")"]
}

; What UIA says about the Q icon and around it (its own text colours, its 3 parents, its neighbours) -
; no positions (they move), digits blanked (a timer nearby would change it every second)
QW_Fingerprint(el) {
    static props := ["ClassName", "Name", "HelpText", "ItemStatus", "FullDescription", "IsEnabled",
        "LegacyIAccessibleState", "LegacyIAccessibleDescription", "LegacyIAccessibleValue",
        "ToggleToggleState", "SelectionItemIsSelected", "Value"]
    fp := ""
    try {
        r := el.TextPattern.DocumentRange
        for a in [40008, 40001, 40007]                       ; foreground, background colour, weight
            try fp .= "t" a "=" String(r.GetAttributeValue(a)) ";"
    }
    cur := el
    Loop 4 {                                                 ; the icon, then its parents
        fp .= "|" A_Index ":"
        for p in props
            fp .= p "=" QW_Prop(cur, p) ";"
        if (A_Index = 2) {                                   ; the icon's neighbours (its parent's children)
            try {
                for c in cur.GetChildren() {
                    fp .= "{"
                    for p in ["ClassName", "Name", "IsEnabled", "ItemStatus", "LegacyIAccessibleState"]
                        fp .= p "=" QW_Prop(c, p) ";"
                    fp .= "}"
                    if (A_Index >= 12)
                        break
                }
            }
        }
        try cur := cur.Parent
        catch
            break
    }
    return RegExReplace(fp, "\d", "#")
}

QW_Crc(s) {
    buf := Buffer(StrPut(s, "UTF-8"))
    StrPut(s, buf, "UTF-8")
    return Format("{:08X}", DllCall("ntdll\RtlComputeCrc32", "UInt", 0, "Ptr", buf, "UInt", buf.Size, "UInt"))
}

; Remembers (in live-captions.ini [QAlertLearned]) which UIA look went with Q on / off.
; Seen with both = UIA can't tell them apart ("both").
QW_Learn(key, state, fp) {
    if (Q_INI = "")
        return
    prev := QW_LearnedState(key)
    if (prev = state || prev = "both")
        return
    now := (prev = "") ? state : "both"
    try IniWrite(now, Q_INI, "QAlertLearned", key)
    if (now = "both")
        QW_Log("learned: Q looks the same to UIA when on and off (" key ") - on another desktop Q can't be read. UIA: " SubStr(fp, 1, 600))
    else
        QW_Log("learned: UIA look " key " = Q " state " (now readable on another desktop too). UIA: " SubStr(fp, 1, 600))
}

QW_LearnedState(key) {
    if (Q_INI = "")
        return ""
    try return IniRead(Q_INI, "QAlertLearned", key, "")
    return ""
}

; Logs what the Q icon element is (once, and again after it was lost) - to learn how 3CX shows Q
QW_Describe(el) {
    global QW_Described
    QW_Described := true
    d := ""
    for prop in ["Name", "AutomationId", "ClassName", "HelpText", "LocalizedType"]
        try d .= prop "=" el.%prop% "  "
    try d .= "ToggleState=" el.ToggleState
    QW_Log("Q icon element: " d)
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

; Counts "blue" pixels in the Q icon, read from 3CX's own picture of its window (PrintWindow with
; PW_RENDERFULLCONTENT). -1 = the picture couldn't be made (or came out empty).
QW_CountBlueInWindow(hwnd, br) {
    rect := Buffer(16, 0)
    if !DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rect)
        return -1
    wl := NumGet(rect, 0, "Int"), wt := NumGet(rect, 4, "Int")
    ww := NumGet(rect, 8, "Int") - wl, wh := NumGet(rect, 12, "Int") - wt
    if (ww < 10 || wh < 10 || br.l < wl || br.t < wt || br.r > wl + ww || br.b > wt + wh)
        return -1
    sdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", sdc, "Ptr")
    bmp := DllCall("CreateCompatibleBitmap", "Ptr", sdc, "Int", ww, "Int", wh, "Ptr")
    old := DllCall("SelectObject", "Ptr", mdc, "Ptr", bmp, "Ptr")
    n := -1
    if DllCall("PrintWindow", "Ptr", hwnd, "Ptr", mdc, "UInt", 2) {
        n := QW_CountBlueDC(mdc, br.l - wl, br.t - wt, br.r - br.l, br.b - br.t, &blank)
        if blank                                 ; all black: the picture is empty
            n := -1
    }
    DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", bmp)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", sdc)
    return n
}

; Counts "blue" pixels on an 8x8 grid inside a rectangle of a device context. blank = every sample black.
QW_CountBlueDC(hdc, x0, y0, w, h, &blank) {
    n := 0, black := 0, seen := 0
    steps := 8
    Loop steps {
        y := y0 + (A_Index * h) // (steps + 1)
        Loop steps {
            x := x0 + (A_Index * w) // (steps + 1)
            c := DllCall("GetPixel", "Ptr", hdc, "Int", x, "Int", y, "UInt")
            if (c = 0xFFFFFFFF)
                continue
            seen += 1
            if (c = 0)
                black += 1
            red := c & 0xFF
            grn := (c >> 8) & 0xFF
            blu := (c >> 16) & 0xFF
            if (blu >= 140 && blu - red >= 70 && blu - grn >= 20)
                n += 1
        }
    }
    blank := (seen = 0 || black = seen)
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

; On another virtual desktop Windows usually leaves only the title bar in the top window's accessibility
; tree. The content of a WinUI window lives in child windows, so try each one as its own UIA root.
; Returns the Q icon element or "";  via = which child window it was found in.
QW_FindQAway(hwnd, &via) {
    via := ""
    kids := []
    try kids := WinGetControlsHwnd("ahk_id " hwnd)
    n := 0
    for kid in kids {
        n += 1
        if (n > 8)
            break
        try {
            el := QW_FindQ(UIA.ElementFromHandle(kid))
            if IsObject(el) {
                via := "child window " QW_ClassOf(kid)
                return el
            }
        }
    }
    return ""
}

QW_ClassOf(h) {
    try return WinGetClass("ahk_id " h)
    return ""
}

; Diagnostics for 3CX on another virtual desktop (logged at the first miss, then every ~5 min):
; which windows 3CX has and what UI Automation still shows in each. No names/text are logged except
; elements that look like the Q / queue / status icon - customer names must not end up in the log.
QW_DiagAway(hwnd, root) {
    c := 0
    try DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &c, "UInt", 4)
    QW_Log("--- 3CX on another virtual desktop: what Windows still shows of it (cloaked=" c ") ---")
    roots := [["top window", root]]
    kids := []
    try kids := WinGetControlsHwnd("ahk_id " hwnd)
    n := 0
    for kid in kids {
        n += 1
        if (n > 12)
            break
        vis := 0
        try vis := (WinGetStyle("ahk_id " kid) & 0x10000000) ? 1 : 0
        QW_Log("   child window " QW_ClassOf(kid) "  visible=" vis)
        if (n <= 8) {
            try roots.Push(["child window " QW_ClassOf(kid), UIA.ElementFromHandle(kid)])
        }
    }
    for item in roots {
        try {
            found := item[2].FindAll(UIA.TrueCondition, 4)
            QW_Log("   " item[1] ": " found.Length " accessible elements")
            shown := 0
            for el in found {
                line := ""
                try line := el.LocalizedType " | " el.AutomationId " | " el.ClassName
                nm := ""
                try nm := el.Name
                if RegExMatch(nm, "i)^(q|queue|queues|agent|status|available|log ?in|logged.*)$")
                    line .= " | name=" nm
                QW_Log("      " line)
                shown += 1
                if (shown >= 40)
                    break
            }
        } catch as err {
            QW_Log("   " item[1] ": could not be read (" err.Message ")")
        }
    }
    QW_Log("--- end of list ---")
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

QW_Notify(state, why := "") {
    if !Q_TARGET {
        ToolTip("3CX Q: " state (why != "" ? " - " why : ""))
        SetTimer(() => ToolTip(), -4000)
        return
    }
    msg := "q`t" state "`t" why
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

; One UIA property as text ("" if it can't be read). The window being on another desktop must not
; change the look, so the "offscreen / invisible / focused" bits of the old-style state are left out.
QW_Prop(el, p) {
    try {
        v := el.GetPropertyValue(UIA.Property.%p%)
        if (p = "LegacyIAccessibleState" && IsInteger(v))
            v := v & ~0x18004
        return String(v)
    }
    return ""
}
