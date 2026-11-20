; ==============================================================================
; debug-trace.ahk  -  one shared timing trace (prefix Dbg*), for hunting delays and hiccups
;
; * Used by the Companion AND the Copilot pool (two processes, one file):
;   data\debug-trace.log, one line per event:  HH:mm:ss.mmm  [who]  what happened
;   Times are to the millisecond and comparable across both processes.
; * NEVER prompt, answer, caption or customer text: only button names, helper names,
;   lengths, counts, states and milliseconds.
; * OFF by default (on only where data\debug.ini [Trace] On=1). Companion tray > "Debug trace (timings)"
;   switches it (data\debug.ini [Trace] On=0/1). Over 5 MB, the file is moved to
;   debug-trace.old.log at the Companion's start.
; ==============================================================================
DBG_FILE := DATA_DIR "\debug-trace.log"
DBG_INI := DATA_DIR "\debug.ini"
DBG_ITEM := "Debug trace (timings, data\debug-trace.log)"
DBG_ITEM_OPEN := "Open the debug trace"

DbgOn() {
    static on := false, at := 0
    if (at = 0 || A_TickCount - at > 2000) {          ; re-read now and then: the other process may switch it
        try {
            on := IniRead(DBG_INI, "Trace", "On", "0") = "1"
        } catch {
            on := false
        }
        at := A_TickCount
    }
    return on
}

DbgTrace(who, msg) {
    if !DbgOn()
        return
    line := FormatTime(, "HH:mm:ss") "." Format("{:03}", A_MSec) "  [" who "]  " msg "`n"
    Loop 3 {                                          ; the other process may be writing this moment
        try {
            FileAppend(line, DBG_FILE, "UTF-8")
            return
        }
        Sleep(3)
    }
}

; Companion only: tray items, and a fresh file when it grew big
DbgInitCompanion() {
    try {
        if (FileExist(DBG_FILE) && FileGetSize(DBG_FILE) > 5 * 1024 * 1024)
            FileMove(DBG_FILE, DATA_DIR "\debug-trace.old.log", true)
    }
    try {
        A_TrayMenu.Add()
        A_TrayMenu.Add(DBG_ITEM, DbgToggle)
        A_TrayMenu.Add(DBG_ITEM_OPEN, (*) => Run('notepad.exe "' DBG_FILE '"'))
        if DbgOn()
            A_TrayMenu.Check(DBG_ITEM)
        OnMessage(0x111, DbgOnCommand)                ; every button click in the Companion's windows
    }
    DbgTrace("app", "Companion started (" (A_PtrSize * 8) "-bit, version " APP_VERSION ")")
}

DbgToggle(*) {
    on := !DbgOn()
    try IniWrite(on ? 1 : 0, DBG_INI, "Trace", "On")
    try {
        if on
            A_TrayMenu.Check(DBG_ITEM)
        else
            A_TrayMenu.Uncheck(DBG_ITEM)
    }
    if on
        DbgTrace("app", "trace switched on")
}

; WM_COMMAND: a button / checkbox / clickable text was clicked (BN_CLICKED = STN_CLICKED = 0).
; Logs the window and the button's caption; changes nothing.
DbgOnCommand(wParam, lParam, msg, hwnd) {
    if (!lParam || ((wParam >> 16) & 0xFFFF) != 0 || !DbgOn())
        return
    try {
        ctrl := GuiCtrlFromHwnd(lParam)
        if !IsObject(ctrl)
            return
        type := ctrl.Type
        if !(type = "Button" || type = "Checkbox" || type = "Radio" || type = "Text")
            return
        cap := Trim(RegExReplace(ctrl.Text, "\s+", " "))
        if (StrLen(cap) > 40)                         ; a long text is content, not a button name
            cap := SubStr(cap, 1, 40) "..."
        val := (type = "Checkbox" || type = "Radio") ? " = " ctrl.Value : ""
        DbgTrace("click", "'" cap "'" val "  (" type (ctrl.Name != "" ? " " ctrl.Name : "") ", window '" ctrl.Gui.Title "')")
    }
}
