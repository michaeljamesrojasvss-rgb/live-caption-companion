; ==============================================================================
; same-value-read.ahk  -  capture every monitor and read it with Windows OCR (prefix SvRead*)
;
; * SvReadCapture() - every monitor captured NOW, before anything is drawn: [{index, x, y, w, h, primary,
;   scale, hbm, crc}]. Pictures stay in memory (never on disk).
; * SvReadWords(shots, opts, cancelled) - the words on every monitor, in reading order:
;   [{text, x, y, w, h, line}] in screen pixels. A monitor whose picture is unchanged since its last read
;   (same checksum, opts.reuse) gets its last words back without OCR. cancelled: a Func checked between
;   monitors; true = stop and return 0. opts = {scale, lang, reuse}. Frees every picture.
; * SvReadFree(shots) - frees the pictures (SvReadWords does it itself).
; Needs screen-grab.ahk and lib\OCR.ahk. Never logs text.
; ==============================================================================
svReadCache := Map()     ; "x,y,w,h" of a monitor -> {crc, words}

SvReadCapture() {
    shots := []
    try {
        for m in GrabMonitors(&vx, &vy, &vw, &vh) {
            m.hbm := GrabToHBitmap(m.x, m.y, m.w, m.h)
            shots.Push(m)
        }
    } catch as err {
        SvReadFree(shots)
        throw err
    }
    return shots
}

SvReadFree(shots) {
    for m in shots {
        if (m.HasOwnProp("hbm") && m.hbm) {
            DllCall("DeleteObject", "Ptr", m.hbm)
            m.hbm := 0
        }
    }
}

; How many monitors need OCR (their picture changed since their last read); sets each shot's crc
SvReadChanged(shots, opts) {
    n := 0
    for m in shots {
        m.crc := opts.reuse ? SvReadCrc(m.hbm, m.w, m.h) : 0
        key := m.x "," m.y "," m.w "," m.h
        if !(opts.reuse && m.crc && svReadCache.Has(key) && svReadCache[key].crc = m.crc)
            n += 1
    }
    return n
}

SvReadWords(shots, opts, cancelled) {
    words := []
    try {
        for m in shots {
            if cancelled.Call()
                return 0
            key := m.x "," m.y "," m.w "," m.h
            if !m.HasOwnProp("crc")
                m.crc := opts.reuse ? SvReadCrc(m.hbm, m.w, m.h) : 0
            if (opts.reuse && m.crc && svReadCache.Has(key) && svReadCache[key].crc = m.crc) {
                mw := svReadCache[key].words
            } else {
                mw := SvReadOcr(m, opts)
                svReadCache[key] := {crc: m.crc, words: mw}
            }
            for w in mw
                words.Push(w)
            DllCall("DeleteObject", "Ptr", m.hbm)     ; done with this picture
            m.hbm := 0
        }
    } finally {
        SvReadFree(shots)
    }
    return words
}

; One monitor's picture -> its words in screen pixels, line by line
SvReadOcr(m, opts) {
    scale := Max(1, opts.scale)
    while (scale > 1 && Max(m.w, m.h) * scale > OCR.MaxImageDimension)
        scale -= 0.5
    if (Max(m.w, m.h) > OCR.MaxImageDimension)
        throw Error("monitor " m.index " is bigger than Windows OCR can read (" OCR.MaxImageDimension " px)")
    o := {scale: scale}
    if (opts.lang != "")
        o.lang := opts.lang
    res := OCR.FromBitmap(m.hbm, o)
    out := []
    for li, line in res.Lines {
        for w in line.Words
            out.Push({text: w.Text, x: w.x + m.x, y: w.y + m.y, w: w.w, h: w.h, line: m.index "-" li})
    }
    return out
}

; Checksum of a picture's pixels (unchanged screen = same number)
SvReadCrc(hbm, w, h) {
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)
    size := w * h * 4
    px := Buffer(size)
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    lines := DllCall("GetDIBits", "Ptr", hdc, "Ptr", hbm, "UInt", 0, "UInt", h, "Ptr", px, "Ptr", bi, "UInt", 0, "Int")
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    if (lines != h)
        return 0                                  ; can't tell: read it again
    return DllCall("ntdll\RtlComputeCrc32", "UInt", 0, "Ptr", px, "UInt", size, "UInt")
}
