#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\salesforce.ahk
#Include %A_ScriptDir%\copy-indicator.ahk     ; Ctrl+C/X/V badge, Ctrl+Shift+Alt+I on/off
#Include %A_ScriptDir%\vdesk.ahk              ; wheel over the taskbar = switch virtual desktops, Ctrl+Shift+Alt+D on/off

; ==============================================================================
; main-helper.ahk  -  extra hotkeys, OFF by default
;
; * Started by liveCaptionCompanion.ahk as its OWN process, only when
;   tray > "Main helper (extra hotkeys)" is ticked (saved per person in
;   live-captions.ini [MainHelper] Enabled). If this script errors or is
;   closed, the companion and its captions keep running.
; * Exits by itself when the companion closes.
; * Run it on its own (double-click) to try new hotkeys.
; ==============================================================================

MH_TARGET := (A_Args.Length >= 1 && IsInteger(A_Args[1])) ? Integer(A_Args[1]) : 0
if MH_TARGET {
    A_IconHidden := true
    SetTimer(MH_CheckCompanion, 2000)
}

MH_CheckCompanion() {
    DetectHiddenWindows(true)
    if !WinExist("ahk_id " MH_TARGET)
        ExitApp()
}

; Radial wheel settings (the wheel itself is further down, Ctrl+Shift+Alt+Z)
WHEEL_AUTO_COPY := true     ; true = press Ctrl+C for you; false = use the clipboard as-is

WHEEL_OPTIONS := [
    Map("name", "ServiceChannel", "angle", 180, "fn", OpenServiceChannel),
    Map("name", "Salesforce",     "angle", 0,   "fn", OpenSalesforce)
]

WHEEL_SCALE  := A_ScreenDPI / 96
WHEEL_RADIUS := Round(105 * WHEEL_SCALE)     ; centre of wheel -> centre of an option
WHEEL_BTN_W  := Round(130 * WHEEL_SCALE)
WHEEL_BTN_H  := Round(46 * WHEEL_SCALE)
WHEEL_DEAD   := Round(28 * WHEEL_SCALE)      ; "cancel" zone in the middle
WHEEL_PI     := 4 * ATan(1)
WHEEL_BASE_BG  := "2B2B2B"
WHEEL_HOVER_BG := "0078D4"
WHEEL_KEY_BG   := "010203"                   ; becomes see-through

wheelGui := ""
wheelBtns := []
wheelActive := false

; ==============================================================================
; Hotkey Configuration
; ^+` = Ctrl + Shift + Backtick
; ==============================================================================
^+`:: {
    ; Define which terminal you want to use (Uncomment ONLY ONE)
    targetTitle := "ahk_exe cmd.exe"
    launchCmd := "cmd.exe"

    ; If you prefer PowerShell, uncomment the two lines below and comment out the cmd ones:
    ; targetTitle := "ahk_exe powershell.exe"
    ; launchCmd := "powershell.exe"

    ; Check if an Admin instance of the terminal already exists
    if WinExist(targetTitle) {
        if WinActive(targetTitle) {
            WinMinimize(targetTitle)
        } else {
            WinActivate(targetTitle)
        }
    } else {
        ; Launch the terminal with Admin privileges ("RunAs")
        try {
            Run("*RunAs " . launchCmd)
        } catch as err {
            ; Handles the case where you click "No" on the UAC prompt
            ToolTip("Terminal elevation cancelled.")
            SetTimer(() => ToolTip(), -2000)
        }
    }
}

; ==============================================================================
; Ctrl + Shift + Alt + S = Salesforce global search for the clipboard text
; Ctrl + Shift + Alt + C = ServiceChannel work order for the clipboard ID
; Ctrl + Shift + Alt + Z = radial wheel (hold, flick toward an option, release)
; ==============================================================================
^+!s:: OpenSalesforce()
^+!c:: OpenServiceChannel()

OpenSalesforce() {
    term := ClipboardTerm()
    if (term = "")
        return
    SF_OpenSearch(term)                 ; shared helper in salesforce.ahk
}

OpenServiceChannel() {
    id := ClipboardTerm()
    if (id = "")
        return
    if !RegExMatch(id, "^[\w-]+$") {
        Tip("Clipboard doesn't contain a valid work order ID.")
        return
    }
    Run("https://www.servicechannel.com/sc/wo/workorders/list?id=" . id)
}

; ==============================================================================
; Radial wheel  -  Ctrl + Shift + Alt + Z
;
;   1. HOLD Ctrl+Shift+Alt+Z: a wheel appears around the mouse.
;   2. Move the mouse toward an option (it lights up). Esc, or releasing with the
;      mouse still in the middle, cancels.
;   3. RELEASE Z: that option runs on the highlighted text (or, if nothing could be
;      copied, on whatever is already in the clipboard).
;
; To add an option: add a line to WHEEL_OPTIONS (name, angle in degrees where
; 0 = right, 90 = down, 180 = left, 270 = up, and the function to run), and a
; function that does the work (see OpenSalesforce above). Keep it to ~6 or fewer.
; ==============================================================================
^+!z:: WheelRun()

WheelBuild() {
    global wheelGui, wheelBtns
    size := 2 * (WHEEL_RADIUS + WHEEL_BTN_W // 2)
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale")   ; E0x08000000 = never steal focus
    g.BackColor := WHEEL_KEY_BG
    g.MarginX := 0, g.MarginY := 0
    g.SetFont("s10 bold", "Segoe UI")

    btns := []
    for opt in WHEEL_OPTIONS {
        a := opt["angle"] * WHEEL_PI / 180
        bx := size // 2 + Round(Cos(a) * WHEEL_RADIUS) - WHEEL_BTN_W // 2
        by := size // 2 + Round(Sin(a) * WHEEL_RADIUS) - WHEEL_BTN_H // 2
        c := g.Add("Text", Format("x{} y{} w{} h{} Center +0x200 Background{}", bx, by, WHEEL_BTN_W, WHEEL_BTN_H, WHEEL_BASE_BG), opt["name"])
        c.SetFont("cD0D0D0")
        rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", WHEEL_BTN_W + 1, "Int", WHEEL_BTN_H + 1
            , "Int", WHEEL_BTN_H, "Int", WHEEL_BTN_H, "Ptr")
        DllCall("SetWindowRgn", "Ptr", c.Hwnd, "Ptr", rgn, "Int", true)
        btns.Push(c)
    }

    ; little dot in the middle = the cancel zone
    d := Round(26 * WHEEL_SCALE)
    dot := g.Add("Text", Format("x{} y{} w{} h{} Background{}", size // 2 - d // 2, size // 2 - d // 2, d, d, WHEEL_BASE_BG))
    rgn := DllCall("CreateEllipticRgn", "Int", 0, "Int", 0, "Int", d + 1, "Int", d + 1, "Ptr")
    DllCall("SetWindowRgn", "Ptr", dot.Hwnd, "Ptr", rgn, "Int", true)

    g.Show(Format("Hide NA w{} h{}", size, size))
    WinSetTransColor(WHEEL_KEY_BG, "ahk_id " g.Hwnd)
    wheelGui := g
    wheelBtns := btns
}

WheelRun() {
    global wheelActive, wheelGui
    if wheelActive
        return
    wheelActive := true
    chosen := 0
    try {
        CoordMode("Mouse", "Screen")
        if !IsObject(wheelGui)
            WheelBuild()
        MouseGetPos(&mx, &my)
        wheelGui.GetPos(, , &w, &h)

        ; keep the whole wheel on the monitor the mouse is on
        WheelMonitorBounds(mx, my, &ml, &mt, &mr, &mb)
        wx := Max(ml, Min(mx - w // 2, mr - w))
        wy := Max(mt, Min(my - h // 2, mb - h))
        cx := wx + w // 2
        cy := wy + h // 2
        if (cx != mx || cy != my)
            MouseMove(cx, cy, 0)          ; centre the mouse in the wheel so the middle stays "cancel"

        wheelGui.Show(Format("NA x{} y{}", wx, wy))

        hover := 0
        while GetKeyState("z", "P") {
            if GetKeyState("Escape", "P") {
                hover := 0
                chosen := 0
                KeyWait("z")
                return
            }
            MouseGetPos(&mx, &my)
            now := WheelPick(mx - cx, my - cy)
            if (now != hover) {
                if hover
                    WheelPaint(hover, false)
                if now
                    WheelPaint(now, true)
                hover := now
            }
            Sleep(15)
        }
        chosen := hover
    } finally {
        try wheelGui.Hide()
        wheelActive := false
    }
    if chosen
        WheelDo(WHEEL_OPTIONS[chosen])
}

; Which option is the mouse pointing at? 0 = none (middle, or between options)
WheelPick(dx, dy) {
    dist := Sqrt(dx * dx + dy * dy)
    if (dist < WHEEL_DEAD)
        return 0
    best := 0
    bestDot := 0.35                        ; must point reasonably close to an option
    for i, opt in WHEEL_OPTIONS {
        a := opt["angle"] * WHEEL_PI / 180
        dot := (dx * Cos(a) + dy * Sin(a)) / dist
        if (dot > bestDot) {
            bestDot := dot
            best := i
        }
    }
    return best
}

WheelPaint(i, on) {
    c := wheelBtns[i]
    c.Opt("Background" (on ? WHEEL_HOVER_BG : WHEEL_BASE_BG))
    c.SetFont(on ? "cWhite" : "cD0D0D0")
    c.Redraw()
}

WheelMonitorBounds(x, y, &l, &t, &r, &b) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (x >= ml && x < mr && y >= mt && y < mb) {
            l := ml, t := mt, r := mr, b := mb
            return
        }
    }
    MonitorGet(MonitorGetPrimary(), &l, &t, &r, &b)
}

WheelDo(opt) {
    if WHEEL_AUTO_COPY
        WheelCopySelection()
    opt["fn"].Call()
}

; Ctrl+C the highlighted text into the clipboard. If nothing gets copied the
; previous clipboard is put back, so "copy first, then use the wheel" still works.
WheelCopySelection() {
    ; let go of the chord first, or the app would see Ctrl+Shift+Alt+C
    for k in ["Ctrl", "Shift", "Alt"]
        KeyWait(k, "T1")
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    if !ClipWait(0.5)
        A_Clipboard := saved
}

; Clipboard text, trimmed; "" (with a tooltip) when it's empty or too long to be a search
ClipboardTerm() {
    t := Trim(A_Clipboard, " `t`r`n")
    if (t = "" || StrLen(t) > 120) {
        Tip("Copy an ID, number or name first.")
        return ""
    }
    return t
}

Tip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -2000)
}
