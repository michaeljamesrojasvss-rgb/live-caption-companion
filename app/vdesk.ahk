; ==============================================================================
; vdesk.ahk  -  virtual desktops with the mouse, over the taskbar
; (part of the main helper)
;
; * MIDDLE-click on the taskbar = Task View (Win+Tab), to see and pick a desktop.
;   This replaces the taskbar's own middle-click (open a new window of that
;   app / close it), but only while this is on.
; * Wheel UP over the taskbar = previous virtual desktop, wheel DOWN = next.
;   Anywhere else the wheel works exactly as before.
; * It presses Windows' own Win+Ctrl+Left / Win+Ctrl+Right for you, so there is
;   no extra DLL, no admin rights, and it keeps working across Windows updates.
;   Windows doesn't wrap around: on the first/last desktop nothing happens.
; * The end of the taskbar next to the clock / tray icons is left alone
;   (VD_TRAY_ZONE), so the wheel over the volume icon still changes the volume.
; * A small "Desktop 2 of 3" tip shows after each switch. The number comes from
;   the registry (undocumented but stable); if it can't be read the tip just
;   says "Switched desktop" and switching still works.
; * Every wheel notch counts. Turn fast and you travel several desktops: the
;   notches are queued and played out one desktop every VD_STEP_MS (reversing
;   the wheel cancels queued steps). VD_MAX_QUEUE stops a long spin from
;   queueing far more steps than there are desktops.
;   Middle-click has a short cooldown so a double-click can't open and close
;   Task View straight away.
; * Ctrl+Shift+Alt+D = turn this on/off (this session only).
; * Included by main-helper.ahk, so it only runs when the main helper is on.
;   If it errors it switches itself off; the wheel keeps working normally.
; * Heads-up: a desktop is per window. To keep the Companion visible after you
;   switch, pin it to all desktops once (Win+Tab > right-click the window >
;   "Show this window on all desktops").
; ==============================================================================

VD_ON := true
VD_LAST := 0            ; last middle-click, for its cooldown
VD_PENDING := 0         ; queued steps: negative = previous desktop, positive = next
VD_DRAINING := false
VD_STEP_MS := 35        ; time between two desktop steps while the queue plays out
VD_MAX_QUEUE := 8       ; most steps that can be waiting at once
VD_TASKVIEW_COOLDOWN_MS := 500
VD_TRAY_ZONE := 260     ; px at the clock/tray end of the taskbar where the wheel is left alone
VD_KEY := "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"

#HotIf VdOverTaskbar()
WheelUp::VdStep(-1)
WheelDown::VdStep(1)
MButton::VdTaskView()
#HotIf
^+!d::VdToggle()

; True when the pointer is on the taskbar, away from the tray/clock end.
; Runs on every wheel turn, so it stays cheap and never throws.
VdOverTaskbar() {
    if !VD_ON
        return false
    try {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my, &win)
        if !win
            return false
        cls := WinGetClass("ahk_id " win)
        if (cls != "Shell_TrayWnd" && cls != "Shell_SecondaryTrayWnd")
            return false
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " win)
        if (ww >= wh)                           ; taskbar along the top or bottom: tray is at the right
            return (wx + ww - mx) > VD_TRAY_ZONE
        return (wy + wh - my) > VD_TRAY_ZONE    ; taskbar at the side: tray is at the bottom
    }
    return false
}

; One wheel notch: queue a step. The first one goes out at once; the rest are
; played out by VdDrain, so fast scrolling still lands on the right desktop.
VdStep(dir) {
    global VD_PENDING, VD_DRAINING
    VD_PENDING := Max(-VD_MAX_QUEUE, Min(VD_MAX_QUEUE, VD_PENDING + dir))
    if VD_DRAINING
        return
    VD_DRAINING := true
    VdDrain()
    if VD_DRAINING
        SetTimer(VdDrain, VD_STEP_MS)
}

VdDrain() {
    global VD_PENDING, VD_DRAINING
    if (VD_PENDING = 0) {
        SetTimer(VdDrain, 0)
        VD_DRAINING := false
        SetTimer(VdShowCurrent, -220)           ; tip once the switching has settled
        return
    }
    dir := (VD_PENDING > 0) ? 1 : -1
    VD_PENDING -= dir
    try {
        Send(dir < 0 ? "^#{Left}" : "^#{Right}")
    } catch as err {
        VD_PENDING := 0
        VdFail(err)
    }
}

VdTaskView() {
    global VD_LAST
    if (A_TickCount - VD_LAST < VD_TASKVIEW_COOLDOWN_MS)
        return
    VD_LAST := A_TickCount
    try {
        Send("#{Tab}")
    } catch as err {
        VdFail(err)
    }
}

VdShowCurrent() {
    text := "Switched desktop"
    try {
        info := VdInfo()
        if IsObject(info)
            text := "Desktop " info.index " of " info.count
    }
    VdTip(text)
}

; {index, count} of the desktop you are on, or "" when it can't be worked out.
; Ids are 16-byte GUIDs, which RegRead gives back as 32 hex characters.
VdInfo() {
    list := RegRead(VD_KEY "\VirtualDesktops", "VirtualDesktopIDs")
    sid := 0
    cur := ""
    try DllCall("ProcessIdToSessionId", "UInt", DllCall("GetCurrentProcessId", "UInt"), "UInt*", &sid)
    try cur := RegRead(VD_KEY "\SessionInfo\" sid "\VirtualDesktops", "CurrentVirtualDesktop")
    if (cur = "")
        cur := RegRead(VD_KEY "\VirtualDesktops", "CurrentVirtualDesktop")
    if (StrLen(list) < 32 || StrLen(cur) != 32)
        return ""
    count := StrLen(list) // 32
    Loop count {
        if (SubStr(list, (A_Index - 1) * 32 + 1, 32) = cur)
            return {index: A_Index, count: count}
    }
    return ""
}

VdTip(text) {
    ToolTip(text, , , 2)
    SetTimer(VdTipOff, -1200)
}

VdTipOff() {
    ToolTip(, , , 2)
}

VdToggle() {
    global VD_ON
    VD_ON := !VD_ON
    VdTip("Desktop wheel on the taskbar: " (VD_ON ? "on" : "off"))
}

VdFail(err) {
    global VD_ON, VD_PENDING
    VD_ON := false
    VD_PENDING := 0
    VdTip("Desktop wheel switched itself off: " err.Message)
}
