; ==============================================================================
; tasks-link.ahk  -  connects the Companion to the Tasks app (tasks.ahk)
;
; * Tasks is its own app and process and knows nothing about calls. To Tasks,
;   the Companion is just an app that has "an item open" (the live or reviewed
;   call) and says whether you're busy (on a call). This file only:
;     - starts Tasks with the Companion (tray > "Tasks app (timers and
;       checklists)", ON by default; per person in live-captions.ini [Tasks])
;     - the "Tasks ▸" button: opens Tasks on the call on screen, or hides it
;     - tells Tasks which call is on screen + busy, whenever that changes
;     - answers "open <call id>" from Tasks by showing that call in review
; * Tasks keeps running when the Companion closes (its timers keep counting).
; * If Tasks is missing or fails, the Companion and the captions carry on:
;   every entry point is wrapped in try/catch and only the status line says so.
; Messages: see the top of tasks.ahk (WM_COPYDATA, tag 0x3CC2).
; Hooks called from liveCaptionCompanion.ahk: TaskLinkInit(), TaskLinkOpen(),
; TaskLinkPush()
; ==============================================================================

TASKLINK_ITEM := "Tasks app (timers and checklists)"
TASKLINK_WIN := "Caption Companion Tasks ahk_class AutoHotkeyGUI"
TASKLINK_TAG := 0x3CC2
TASKLINK_APP := "Companion"          ; our name in Tasks (shown as "Open in Companion")
taskLinkLastCtx := ""
taskLinkLastHwnd := 0

TaskLinkInit() {
    try {
        A_TrayMenu.Insert("1&", TASKLINK_ITEM, (*) => TaskLinkToggle())
        OnMessage(0x4A, TaskLinkOnCopyData)          ; "open <call id>" from Tasks
        if TaskLinkEnabled() {
            A_TrayMenu.Check(TASKLINK_ITEM)
            if !TaskLinkWindow()
                TaskLinkStart("/background")
        }
        SetTimer(TaskLinkPush, 2000)
    } catch as err {
        TaskLinkReport(err)
    }
}

TaskLinkEnabled() {
    try return IniRead(MIC_INI, "Tasks", "Enabled", "1") = "1"
    return true
}

TaskLinkToggle() {
    try {
        on := !TaskLinkEnabled()
        IniWrite(on ? 1 : 0, MIC_INI, "Tasks", "Enabled")
        if on {
            A_TrayMenu.Check(TASKLINK_ITEM)
            if !TaskLinkWindow()
                TaskLinkStart("/background")
            statusText.Text := "Status: Tasks app is on (starts with the Companion)"
        } else {
            A_TrayMenu.Uncheck(TASKLINK_ITEM)
            if (hwnd := TaskLinkWindow())
                TaskLinkSend(hwnd, "quit")
            statusText.Text := "Status: Tasks app is off (the Tasks button still opens it)"
        }
    } catch as err {
        TaskLinkReport(err)
    }
}

; The Tasks window (hidden or not), or 0
TaskLinkWindow() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := WinExist(TASKLINK_WIN)
    DetectHiddenWindows(prev)
    return hwnd
}

; arg: /background (start hidden) or /linked (open on the call on screen)
TaskLinkStart(arg) {
    path := A_ScriptDir "\tasks.ahk"
    if !FileExist(path) {
        statusText.Text := "Status: tasks.ahk not found - Tasks is off (captions unaffected)"
        return false
    }
    Run(Format('"{}" "{}" {}', A_AhkPath, path, arg), A_ScriptDir)
    ; tell it about the call as soon as its window is up (a Bind per try, so
    ; these don't replace the regular every-2-seconds timer)
    for ms in [600, 1200, 2500]
        SetTimer(TaskLinkPush.Bind(true), -ms)
    return true
}

; The "Tasks ▸" button: open on the call on screen, or hide if it's showing it
TaskLinkOpen(*) {
    try {
        if (hwnd := TaskLinkWindow()) {
            TaskLinkPush(true)
            TaskLinkSend(hwnd, "togglelinked")
        } else if TaskLinkStart("/linked") {
            statusText.Text := "Status: opening Tasks..."
        }
    } catch as err {
        TaskLinkReport(err)
    }
}

; Sends the call on screen + busy when it changed (or force)
TaskLinkPush(force := false) {
    global taskLinkLastCtx, taskLinkLastHwnd
    try {
        hwnd := TaskLinkWindow()
        if !hwnd
            return
        ctx := TaskLinkContext()
        if (!force && hwnd = taskLinkLastHwnd && ctx == taskLinkLastCtx)
            return
        if TaskLinkSend(hwnd, ctx) {
            taskLinkLastCtx := ctx
            taskLinkLastHwnd := hwnd
        }
    }
}

; ctx  ourHwnd  "Companion"  callId  label  note  busy
TaskLinkContext() {
    s := IsObject(reviewCall) ? reviewCall : currentCall
    id := ""
    label := ""
    note := ""
    if IsObject(s) {
        id := s["id"]
        label := "Call · " IsoToLocal(s["startedAtUtc"], "MMM d h:mm tt") . CallerHistoryLabel(s)
        label := StrReplace(StrReplace(label, "`t", " "), "  ·  ", " · ")
        note := IsObject(reviewCall) ? "reviewing" : "live call"
    }
    busy := (callerPhase = "ringing" || callerPhase = "on call") ? 1 : 0
    return "ctx`t" myGui.Hwnd "`t" TASKLINK_APP "`t" id "`t" label "`t" note "`t" busy
}

TaskLinkSend(hwnd, msg) {
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", TASKLINK_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    ok := false
    try {
        SendMessage(0x4A, 0, cds, , "ahk_id " hwnd, , , , 1000)   ; WM_COPYDATA, 1 s max
        ok := true
    }
    DetectHiddenWindows(prev)
    return ok
}

; ---- from Tasks: "open <call id>" = show that call (Open on an alert / task) ----
TaskLinkOnCopyData(wParam, lParam, msg, hwnd) {
    if (hwnd != myGui.Hwnd)
        return
    try {
        if (NumGet(lParam, 0, "UPtr") != TASKLINK_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(TaskLinkHandle.Bind(text), -1)      ; reply to Tasks right away
    return true
}

TaskLinkHandle(text, *) {
    try {
        p := StrSplit(text, "`t")
        if (p[1] = "open" && p.Length >= 2)
            TaskLinkShowCall(p[2])
    } catch as err {
        TaskLinkReport(err)
    }
}

TaskLinkShowCall(id) {
    global guiVisible
    if !guiVisible {                              ; hidden with Ctrl+Shift+Alt+H
        myGui.Show("NoActivate")
        guiVisible := true
    }
    if (IsObject(currentCall) && currentCall["id"] = id) {
        ExitReview()
        statusText.Text := "Status: that task is for the live call"
        return
    }
    if (history is Map) {
        for s in history["sessions"] {
            if (s["id"] = id) {
                EnterReview(s)
                statusText.Text := "Status: reviewing the call of the task you opened"
                return
            }
        }
    }
    statusText.Text := "Status: the call of that task is no longer in the call history"
}

TaskLinkReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: Tasks problem (captions unaffected): " msg
}
