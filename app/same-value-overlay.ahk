; ==============================================================================
; same-value-overlay.ahk  -  the see-through marks over every monitor (prefix SvOv*)
;
; * One layered window per monitor: see-through, clicks pass through it, never takes the focus, always on
;   top. Drawn with GDI+ into a picture handed to Windows (UpdateLayeredWindow), so it appears at once and
;   holds no browser engine. Each window works in its monitor's real pixels (per-monitor DPI), so mixed
;   scaling is fine.
; * SvOvShow(monitors, marks, note, style, links) - draws and shows. monitors: [{index, x, y, w, h, scale}];
;   marks: [{x, y, w, h, group, near}] in screen pixels; note: a short line shown at the top of every
;   monitor ("" = none); style: {dim, fillAlpha, lineWidth, numbers, colors: [0xRRGGBB...], nearColor,
;   aloneColor, linkWidth}; links: [{x1, y1, x2, y2, group, near}] lines in screen pixels, drawn under the
;   marks - a line between monitors is drawn in both windows (each shows its own part)
; * SvOvHide() - hides every window (kept for next time).
; Needs screen-grab.ahk (GrabGdipStart, GrabDpiAware).
; ==============================================================================
svOvWins := Map()        ; monitor index -> Gui
SVOV_MARGIN := 3         ; space between a word and its outline (at 100% scaling)

SvOvShow(monitors, marks, note, style, links := []) {
    GrabGdipStart()
    SvOvSync(monitors)
    for m in monitors {
        g := svOvWins[m.index]
        SvOvDraw(g.Hwnd, m, marks, note, style, links)
    }
}

SvOvHide() {
    for idx, g in svOvWins
        try DllCall("ShowWindow", "Ptr", g.Hwnd, "Int", 0)
}

; One window per monitor; rebuilt if the monitors changed
SvOvSync(monitors) {
    same := svOvWins.Count = monitors.Length
    for m in monitors
        if !svOvWins.Has(m.index)
            same := false
    if same
        return
    for idx, g in svOvWins
        try g.Destroy()
    svOvWins.Clear()
    old := GrabDpiAware()                        ; the windows are made per-monitor DPI aware: real pixels
    try {
        for m in monitors {
            ; E0x80000 layered, E0x20 click-through, E0x80 no taskbar button, E0x08000000 never activated
            g := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale +E0x80000 +E0x20 +E0x08000000", "Same value overlay")
            svOvWins[m.index] := g
        }
    } finally {
        GrabDpiEnd(old)
    }
}

SvOvDraw(hwnd, m, marks, note, style, links) {
    w := m.w, h := m.h, s := m.scale
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)
    sdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", sdc, "Ptr")
    bits := 0
    dib := DllCall("CreateDIBSection", "Ptr", mdc, "Ptr", bi, "UInt", 0, "Ptr*", &bits, "Ptr", 0, "UInt", 0, "Ptr")
    obm := DllCall("SelectObject", "Ptr", mdc, "Ptr", dib, "Ptr")
    g := 0
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", mdc, "Ptr*", &g)
    try {
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)        ; anti-alias
        DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)    ; anti-alias (no ClearType on see-through)
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", (Round(Min(80, Max(0, style.dim)) * 2.55) << 24))
        pad := Round(SVOV_MARGIN * s)
        lw := Max(1, Round(style.lineWidth * s))
        tagH := Round(16 * s)
        ; the lines first (under everything); GDI+ clips the part that is on another monitor
        for ln in links {
            col := ln.near ? style.nearColor : style.colors[Mod(ln.group - 1, style.colors.Length) + 1]
            SvOvLine(g, ln.x1 - m.x, ln.y1 - m.y, ln.x2 - m.x, ln.y2 - m.y, 0xE0000000 | col, style.linkWidth, ln.near)
        }
        ; faint outlines first, then the matches, then the warnings on top
        for pass in [1, 2, 3] {
            for k in marks {
                if (k.x + k.w < m.x || k.x >= m.x + w || k.y + k.h < m.y || k.y >= m.y + h)
                    continue                     ; on another monitor
                x := k.x - m.x - pad, y := k.y - m.y - pad, bw := k.w + 2 * pad, bh := k.h + 2 * pad
                if (pass = 1 && !k.group && !k.near)
                    SvOvRect(g, x, y, bw, bh, 0xC0000000 | style.aloneColor, Max(1, Round(s)), false)
                else if (pass = 2 && k.group) {
                    col := style.colors[Mod(k.group - 1, style.colors.Length) + 1]
                    SvOvFill(g, x, y, bw, bh, (style.fillAlpha << 24) | col)
                    SvOvRect(g, x, y, bw, bh, 0xFF000000 | col, lw, false)
                    if style.numbers
                        SvOvTag(g, x, y - tagH, String(k.group), 0xFF000000 | col, tagH, s)
                } else if (pass = 3 && k.near) {
                    o := lw + Round(2 * s)
                    SvOvRect(g, x - o, y - o, bw + 2 * o, bh + 2 * o, 0xFF000000 | style.nearColor, lw, true)
                    SvOvTag(g, x + bw + o - Round(18 * s), y - o - tagH, "≈", 0xFF000000 | style.nearColor, tagH, s)
                }
            }
        }
        if (note != "")
            SvOvNote(g, w, note, s)
    } finally {
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    }
    pt := Buffer(8), sz := Buffer(8)
    NumPut("Int", m.x, pt, 0), NumPut("Int", m.y, pt, 4)
    NumPut("Int", w, sz, 0), NumPut("Int", h, sz, 4)
    src := Buffer(8, 0)
    old := GrabDpiAware()
    ; BLENDFUNCTION {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA} = 0x01FF0000; ULW_ALPHA = 2
    DllCall("UpdateLayeredWindow", "Ptr", hwnd, "Ptr", sdc, "Ptr", pt, "Ptr", sz, "Ptr", mdc, "Ptr", src, "UInt", 0, "UInt*", 0x01FF0000, "UInt", 2)
    ; HWND_TOPMOST, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE|SWP_SHOWWINDOW
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x1 | 0x2 | 0x10 | 0x40)
    GrabDpiEnd(old)
    DllCall("SelectObject", "Ptr", mdc, "Ptr", obm)
    DllCall("DeleteObject", "Ptr", dib)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", sdc)
}

SvOvFill(g, x, y, w, h, argb) {
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &brush)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", g, "Ptr", brush, "Int", x, "Int", y, "Int", w, "Int", h)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

SvOvLine(g, x1, y1, x2, y2, argb, width, dashed) {
    pen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", Max(1, width), "Int", 2, "Ptr*", &pen)
    if dashed
        DllCall("gdiplus\GdipSetPenDashStyle", "Ptr", pen, "Int", 1)
    DllCall("gdiplus\GdipDrawLineI", "Ptr", g, "Ptr", pen, "Int", x1, "Int", y1, "Int", x2, "Int", y2)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

SvOvRect(g, x, y, w, h, argb, width, dashed) {
    pen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", width, "Int", 2, "Ptr*", &pen)
    if dashed
        DllCall("gdiplus\GdipSetPenDashStyle", "Ptr", pen, "Int", 1)
    DllCall("gdiplus\GdipDrawRectangleI", "Ptr", g, "Ptr", pen, "Int", x, "Int", y, "Int", w, "Int", h)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

; A small coloured label (group number, or the "almost the same" sign) with white text
SvOvTag(g, x, y, text, argb, h, s) {
    w := Round((StrLen(text) * 9 + 8) * s)
    if (y < 0)
        y := 0
    SvOvFill(g, x, y, w, h, argb)
    SvOvText(g, x, y, w, h, text, 0xFFFFFFFF, 11 * s, true)
}

; A dark band with one line of text at the top centre of a monitor
SvOvNote(g, monW, text, s) {
    w := Min(monW - Round(40 * s), Round((StrLen(text) * 8 + 40) * s)), h := Round(34 * s)
    x := (monW - w) // 2, y := Round(14 * s)
    SvOvFill(g, x, y, w, h, 0xE0202630)
    SvOvRect(g, x, y, w, h, 0xFF22D3EE, Max(1, Round(s)), false)
    SvOvText(g, x, y, w, h, text, 0xFFFFFFFF, 14 * s, false)
}

SvOvText(g, x, y, w, h, text, argb, size, bold) {
    fam := 0, font := 0, fmt := 0, brush := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &fam)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", size, "Int", bold ? 1 : 0, "Int", 2, "Ptr*", &font)   ; unit 2 = pixels
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "Int", 0, "Ptr*", &fmt)                            ; no wrapping
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", 1)        ; centre
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)    ; middle
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &brush)
    rc := Buffer(16)
    NumPut("Float", x, rc, 0), NumPut("Float", y, rc, 4), NumPut("Float", w, rc, 8), NumPut("Float", h, rc, 12)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", fmt, "Ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
}
