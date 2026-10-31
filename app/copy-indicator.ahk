; ==============================================================================
; copy-indicator.ahk  -  copy / cut / paste indicator (part of the main helper)
;
; * A small badge by the mouse pointer after Ctrl+C / Ctrl+X / Ctrl+V:
;     green  "COPIED" / "CUT"  the clipboard really changed
;     blue   "PASTED"          there was something to paste and a text cursor
;     grey   "? PASTED"        something to paste, but no text cursor was seen
;     red    + shake           copy didn't take / nothing to paste
; * Spam-friendly: one badge, one timer. Repeat presses within 1.5 s count up
;   a combo (COPIED x4) and the badge pops a bit bigger each time.
; * Only watches (~ hotkeys): the keys still reach the app untouched. Never
;   reads the copied text. Never takes focus; clicks pass through the badge.
;   Ctrl+C sent by other AutoHotkey scripts (SendLevel 0) doesn't trigger it.
; * Ctrl+Shift+Alt+I = indicator on/off (this session only).
; * Included by main-helper.ahk, so it only runs when the main helper is on.
;   If it errors it switches itself off; copy/paste keep working.
; ==============================================================================

IND_ON := true
IND_GUI := 0, IND_ICON := 0, IND_LABEL := 0
IND_KIND := "", IND_COUNT := 0, IND_LAST := 0   ; combo
IND_PEND := ""                                  ; copy/cut waiting for the clipboard
IND_ANIM := ""                                  ; badge being animated

IND_COMBO_MS := 1500    ; presses closer than this keep the combo going
IND_WAIT_MS  := 500     ; how long a copy may take before it counts as failed
IND_HOLD_MS  := 900     ; badge fully visible
IND_FADE_MS  := 250     ; then fades out

~^c::IndCopyPressed("COPY")
~^x::IndCopyPressed("CUT")
~^v::IndPastePressed()
^+!i::IndToggle()

IndCopyPressed(kind) {
    global IND_PEND
    if !IND_ON
        return
    try {
        ; a newer press replaces a check still waiting
        IND_PEND := {kind: kind, seq: IndClipSeq(), t: A_TickCount}
        SetTimer(IndCheckCopy, 30)
    } catch as err {
        IndFail(err)
    }
}

IndCheckCopy() {
    global IND_PEND
    try {
        p := IND_PEND
        if !IsObject(p) {
            SetTimer(IndCheckCopy, 0)
            return
        }
        if (IndClipSeq() != p.seq) {
            IND_PEND := ""
            SetTimer(IndCheckCopy, 0)
            IndShow(p.kind, "ok")
        } else if (A_TickCount - p.t > IND_WAIT_MS) {
            IND_PEND := ""
            SetTimer(IndCheckCopy, 0)
            IndShow(p.kind, "fail")
        }
    } catch as err {
        SetTimer(IndCheckCopy, 0)
        IndFail(err)
    }
}

IndPastePressed() {
    if !IND_ON
        return
    try {
        if !DllCall("CountClipboardFormats")
            IndShow("PASTE", "fail")
        else
            IndShow("PASTE", IndHasCaret() ? "ok" : "maybe")
    } catch as err {
        IndFail(err)
    }
}

IndToggle() {
    global IND_ON, IND_ANIM, IND_PEND
    IND_ON := !IND_ON
    if !IND_ON {
        IND_ANIM := "", IND_PEND := ""
        try IND_GUI.Hide()
    }
    IndTip("Copy/paste indicator " (IND_ON ? "on" : "off"))
}

; Changes every time anything is put on the clipboard (even the same text again)
IndClipSeq() => DllCall("GetClipboardSequenceNumber", "UInt")

IndHasCaret() {
    try {
        CoordMode("Caret", "Screen")
        return CaretGetPos(&x, &y) ? true : false
    }
    return false
}

; ------------------------------------------------------------------------------
; Badge
; ------------------------------------------------------------------------------
IndShow(kind, result) {
    global IND_KIND, IND_COUNT, IND_LAST, IND_ANIM
    Critical
    DetectHiddenWindows(true)   ; the badge window is hidden between shows
    now := A_TickCount
    if (result = "fail") {
        IND_KIND := "", IND_COUNT := 0
    } else {
        IND_COUNT := (kind = IND_KIND && now - IND_LAST < IND_COMBO_MS) ? IND_COUNT + 1 : 1
        IND_KIND := kind
        IND_LAST := now
    }

    if (result = "fail") {
        icon := Chr(0x2716), color := "D33A3A"
        label := (kind = "PASTE") ? "NOTHING TO PASTE" : kind " FAILED"
    } else {
        icon := (result = "maybe") ? "?" : Chr(0x2714)
        label := (kind = "COPY") ? "COPIED" : (kind = "CUT") ? "CUT" : "PASTED"
        color := (result = "maybe") ? "6B7280" : (kind = "PASTE") ? "2F6FD6" : "2E9E4F"
        if (IND_COUNT > 1)
            label .= "  " Chr(0xD7) IND_COUNT
    }

    g := IndGui()
    g.BackColor := color
    IND_ICON.Text := icon
    IND_LABEL.Text := label

    a := {t: now, pt: 12 + Min(Max(IND_COUNT, 1) - 1, 6), fail: result = "fail", shownPt: 0, pos: ""}
    IndLayout(a, a.pt)

    ; just below-right of the pointer, flipped/clamped to stay on its monitor
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    IndWorkArea(mx, my, &l, &t, &r, &b)
    x := mx + 16, y := my + 22
    if (x + a.w > r)
        x := mx - 16 - a.w
    if (y + a.h > b)
        y := my - 16 - a.h
    x := Max(l, Min(x, r - a.w)), y := Max(t, Min(y, b - a.h))
    a.cx := x + a.w // 2, a.cy := y + a.h // 2

    IND_ANIM := a
    WinSetTransparent(235, g.Hwnd)
    IndTick()
    SetTimer(IndTick, 15)
}

IndTick() {
    global IND_ANIM
    Critical
    DetectHiddenWindows(true)
    try {
        a := IND_ANIM
        if !IsObject(a) {
            SetTimer(IndTick, 0)
            return
        }
        e := A_TickCount - a.t
        if (e >= IND_HOLD_MS + IND_FADE_MS) {
            SetTimer(IndTick, 0)
            IND_ANIM := ""
            IND_GUI.Hide()
            return
        }

        dx := 0, pt := a.pt
        if a.fail {
            if (e < 360)
                dx := Round(9 * Sin(e / 20) * (1 - e / 360))
        } else if (e < 40) {
            pt := a.pt + 5
        } else if (e < 80) {
            pt := a.pt + 3
        } else if (e < 120) {
            pt := a.pt + 1
        }
        if (pt != a.shownPt)
            IndLayout(a, pt)
        if (e > IND_HOLD_MS)
            WinSetTransparent(Round(235 * (IND_HOLD_MS + IND_FADE_MS - e) / IND_FADE_MS), IND_GUI.Hwnd)

        pos := Format("NA x{} y{} w{} h{}", a.cx - a.w // 2 + dx, a.cy - a.h // 2, a.w, a.h)
        if (pos != a.pos) {
            a.pos := pos
            IND_GUI.Show(pos)
        }
    } catch as err {
        SetTimer(IndTick, 0)
        IndFail(err)
    }
}

; Sizes the controls and the pill-shaped window for font size pt (pixels)
IndLayout(a, pt) {
    IND_ICON.SetFont("s" pt)
    IND_LABEL.SetFont("s" pt)
    iw := IndTextSize(IND_ICON.Text, "Segoe UI Symbol", pt)
    lw := IndTextSize(IND_LABEL.Text, "Segoe UI", pt)
    padX := Round(pt * 0.9), padY := Round(pt * 0.45), gap := Round(pt * 0.4)
    h := Max(iw.h, lw.h)
    IND_ICON.Move(padX, padY, iw.w + 2, h)
    IND_LABEL.Move(padX + iw.w + 2 + gap, padY, lw.w + 2, h)
    a.w := padX * 2 + iw.w + 2 + gap + lw.w + 2
    a.h := padY * 2 + h
    a.shownPt := pt
    a.pos := ""
    WinSetRegion("0-0 W" a.w " H" a.h " R" a.h "-" a.h, IND_GUI.Hwnd)
}

IndGui() {
    global IND_GUI, IND_ICON, IND_LABEL
    if !IND_GUI {
        ; E0x20 = clicks pass through, E0x08000000 = never activates
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20 +E0x08000000")
        g.MarginX := 0, g.MarginY := 0
        g.SetFont("s12 bold cFFFFFF", "Segoe UI Symbol")
        IND_ICON := g.AddText("x0 y0 w10 h10 Center")
        g.SetFont("s12 bold cFFFFFF", "Segoe UI")
        IND_LABEL := g.AddText("x0 y0 w10 h10")
        IND_GUI := g
    }
    return IND_GUI
}

; Pixel size of text in a bold font of pt points
IndTextSize(text, fontName, pt) {
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    height := -DllCall("MulDiv", "Int", pt, "Int", DllCall("GetDeviceCaps", "Ptr", hdc, "Int", 90), "Int", 72)
    hFont := DllCall("CreateFont", "Int", height, "Int", 0, "Int", 0, "Int", 0, "Int", 700
        , "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5, "UInt", 0
        , "Str", fontName, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    size := Buffer(8, 0)
    DllCall("GetTextExtentPoint32", "Ptr", hdc, "Str", text, "Int", StrLen(text), "Ptr", size)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", hFont)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return {w: NumGet(size, 0, "Int"), h: NumGet(size, 4, "Int")}
}

IndWorkArea(x, y, &l, &t, &r, &b) {
    n := MonitorGetPrimary()
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (x >= ml && x < mr && y >= mt && y < mb) {
            n := A_Index
            break
        }
    }
    MonitorGetWorkArea(n, &l, &t, &r, &b)
}

IndTip(text, ms := 1500) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -ms)
}

; Any error: switch the indicator off for this session and say so once
IndFail(err) {
    global IND_ON, IND_ANIM, IND_PEND
    IND_ON := false, IND_ANIM := "", IND_PEND := ""
    try IND_GUI.Hide()
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    IndTip("Copy/paste indicator stopped (copy/paste still work): " msg, 4000)
}
