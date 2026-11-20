; ==============================================================================
; screen-grab.ahk  -  screen capture to a PNG file (prefix Grab*), GDI + GDI+
;
; * GrabMonitors(&vx, &vy, &vw, &vh) - the monitors [{x, y, w, h, primary}] and the virtual screen around them
; * GrabToPng(x, y, w, h, path, maxSide := 0) - copies that screen rectangle into a PNG; maxSide > 0 makes
;   the image smaller so its longest side is at most maxSide (the AI shrinks big images anyway)
; Works in real screen pixels: the capture runs per-monitor DPI aware (mixed scaling, several monitors).
; Used by the agent (take_screenshot). Screen ask still has its own copy (SaGrab) - can move here later.
; ==============================================================================

GrabMonitors(&vx, &vy, &vw, &vh) {
    old := GrabDpiAware()
    try {
        list := []
        x0 := 0x7FFFFFFF, y0 := 0x7FFFFFFF, x1 := -0x7FFFFFFF, y1 := -0x7FFFFFFF
        prim := MonitorGetPrimary()
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &l, &t, &r, &b)
            list.Push({x: l, y: t, w: r - l, h: b - t, primary: A_Index = prim})
            x0 := Min(x0, l), y0 := Min(y0, t), x1 := Max(x1, r), y1 := Max(y1, b)
        }
    } finally {
        GrabDpiEnd(old)
    }
    if !list.Length
        throw Error("no monitor found")
    vx := x0, vy := y0, vw := x1 - x0, vh := y1 - y0
    return list
}

GrabToPng(x, y, w, h, path, maxSide := 0) {
    old := GrabDpiAware()
    sdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", sdc, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", sdc, "Int", w, "Int", h, "Ptr")
    obm := DllCall("SelectObject", "Ptr", mdc, "Ptr", hbm, "Ptr")
    ok := hbm && DllCall("BitBlt", "Ptr", mdc, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", sdc, "Int", x, "Int", y, "UInt", 0x40CC0020)  ; SRCCOPY|CAPTUREBLT
    DllCall("SelectObject", "Ptr", mdc, "Ptr", obm)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", sdc)
    GrabDpiEnd(old)
    pBmp := 0, dst := 0
    try {
        if !ok
            throw Error("the screen couldn't be copied")
        GrabGdipStart()
        r := DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBmp)
        if (r || !pBmp)
            throw Error("GDI+ error " r)
        out := pBmp, ow := w, oh := h
        if (maxSide > 0 && Max(w, h) > maxSide) {
            f := maxSide / Max(w, h)
            ow := Max(1, Round(w * f)), oh := Max(1, Round(h * f))
            dst := GrabScaled(pBmp, w, h, ow, oh)
            out := dst
        }
        r := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", out, "WStr", path, "Ptr", GrabPngClsid(), "Ptr", 0)
        if r
            throw Error("couldn't save the screenshot (GDI+ error " r ")")
        return {w: ow, h: oh}
    } finally {
        if dst
            DllCall("gdiplus\GdipDisposeImage", "Ptr", dst)
        if pBmp
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
        if hbm
            DllCall("DeleteObject", "Ptr", hbm)
    }
}

; A smaller copy of a GDI+ bitmap (high-quality scaling); the caller disposes it
GrabScaled(src, w, h, dw, dh) {
    dst := 0, g := 0
    if (DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", dw, "Int", dh, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &dst) || !dst)
        throw Error("couldn't make the smaller image (" dw "x" dh ")")
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", dst, "Ptr*", &g)
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", g, "Int", 7)    ; HighQualityBicubic
    DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", g, "Int", 4)      ; HighQuality
    r := DllCall("gdiplus\GdipDrawImageRectRectI", "Ptr", g, "Ptr", src, "Int", 0, "Int", 0, "Int", dw, "Int", dh
        , "Int", 0, "Int", 0, "Int", w, "Int", h, "Int", 2, "Ptr", 0, "Ptr", 0, "Ptr", 0)   ; 2 = UnitPixel
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    if r {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", dst)
        throw Error("couldn't make the image smaller (GDI+ error " r ")")
    }
    return dst
}

GrabGdipStart() {
    static token := 0
    if token
        return
    DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)
    if !token
        throw Error("GDI+ didn't start")
}

GrabPngClsid() {
    static clsid := 0
    if !clsid {
        clsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    }
    return clsid
}

GrabDpiAware() {
    try return DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")   ; PER_MONITOR_AWARE_V2
    return 0
}

GrabDpiEnd(old) {
    if old
        try DllCall("SetThreadDpiAwarenessContext", "Ptr", old, "Ptr")
}
