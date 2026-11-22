; ==============================================================================
; tooltips.ahk  -  hover tips on buttons, shared by every app (prefix Tip*)
;
; * TipSet(ctl, text): when the mouse rests on ctl (~half a second), a small tip shows `text`.
;   Call it again to change the text (e.g. a state: "on now"); "" removes the tip. Works on
;   buttons, ticks, boxes and clickable Text controls (anything with an OnEvent "Click").
; * Uses Windows' own tooltip control (tooltips_class32, TTF_SUBCLASS): no timers while idle,
;   nothing polls the mouse. One tip window per app window.
; * One switch for all apps: data\tips.ini [Tips] On (1 by default). The Companion's Settings
;   (Updates & help) and its tray switch it; every app notices within a few seconds.
; * Needs app-paths.ahk (DATA_DIR). Never fails loudly: a tip that can't be made is just missing.
; ==============================================================================

TIPS_INI := DATA_DIR "\tips.ini"
tipWins := Map()                   ; app window hwnd -> its tip window hwnd
tipTools := Map()                  ; control hwnd -> [tip window, app window]
tipOnNow := -1                     ; last state given to the tip windows (-1 = not yet)

TipsEnabled() {
    try return IniRead(TIPS_INI, "Tips", "On", "1") = "1"
    return true
}

TipsSetEnabled(on) {
    try IniWrite(on ? 1 : 0, TIPS_INI, "Tips", "On")
    TipsWatch()
}

TipSet(ctl, text) {
    try {
        h := ctl.Hwnd
        top := DllCall("GetAncestor", "Ptr", h, "UInt", 2, "Ptr")      ; GA_ROOT: the app window
        if !top
            return
        tt := TipWindow(top)
        if !tt
            return
        ti := TipInfo(top, h, text)
        ; a closed window's control handle can be reused by a new control: only a tip in THIS tip window counts
        if (tipTools.Has(h) && tipTools[h][1] != tt)
            tipTools.Delete(h)
        if tipTools.Has(h) {
            if (text = "") {
                TipMsg(tt, 0x0433, 0, ti.Ptr)           ; TTM_DELTOOLW
                tipTools.Delete(h)
            } else
                TipMsg(tt, 0x0439, 0, ti.Ptr)           ; TTM_UPDATETIPTEXTW
        } else if (text != "") {
            TipMsg(tt, 0x0432, 0, ti.Ptr)               ; TTM_ADDTOOLW
            tipTools[h] := [tt, top]
        }
    }
}

; The tip window of one app window (made the first time)
TipWindow(top) {
    global tipOnNow
    if tipWins.Has(top) {
        if DllCall("IsWindow", "Ptr", tipWins[top])
            return tipWins[top]
        tipWins.Delete(top)
    }
    ; WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, topmost (shows over always-on-top windows too)
    tt := DllCall("CreateWindowEx", "UInt", 0x8, "Str", "tooltips_class32", "Ptr", 0
        , "UInt", 0x80000000 | 0x1 | 0x2, "Int", 0x80000000, "Int", 0x80000000, "Int", 0x80000000, "Int", 0x80000000
        , "Ptr", top, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    if !tt
        return 0
    TipMsg(tt, 0x0418, 0, 420)                          ; TTM_SETMAXTIPWIDTH: long tips wrap
    TipMsg(tt, 0x0403, 2, 30000)                        ; TTM_SETDELAYTIME autopop: 30 s to read
    TipMsg(tt, 0x0403, 3, 450)                          ; ... initial: 450 ms
    if !TipsEnabled()
        TipMsg(tt, 0x0401, 0, 0)                        ; TTM_ACTIVATE off
    tipWins[top] := tt
    if (tipOnNow = -1) {
        tipOnNow := TipsEnabled() ? 1 : 0
        SetTimer(TipsWatch, 3000)                                        ; the switch may change in another app
    }
    return tt
}

; TOOLINFOW: cbSize, uFlags, hwnd, uId, rect, hinst, lpszText, lParam, lpReserved
TipInfo(top, h, text) {
    p := A_PtrSize
    static bufs := Map()               ; the text buffer must live while the message is sent; kept per control
    ti := Buffer(24 + 6 * p, 0)
    NumPut("UInt", ti.Size, ti, 0)
    NumPut("UInt", 0x1 | 0x10, ti, 4)                                    ; TTF_IDISHWND | TTF_SUBCLASS
    NumPut("Ptr", top, ti, 8)
    NumPut("Ptr", h, ti, 8 + p)
    s := Buffer(StrPut(text, "UTF-16"))
    StrPut(text, s, "UTF-16")
    bufs[h] := s
    NumPut("Ptr", s.Ptr, ti, 24 + 3 * p)
    return ti
}

; Follows data\tips.ini: turns every tip window of this app on or off
TipsWatch() {
    global tipOnNow
    on := TipsEnabled() ? 1 : 0
    if (on = tipOnNow)
        return
    tipOnNow := on
    for top, tt in tipWins
        try TipMsg(tt, 0x0401, on, 0)                   ; TTM_ACTIVATE
}

; Gives ctl a tip and returns ctl, for one-liners: TipAdd(g.Add("Button", ...), "tip").OnEvent("Click", Fn)
TipAdd(ctl, text) {
    TipSet(ctl, text)
    return ctl
}

; Several tips at once: TipSetAll([[ctl, text], ...])
TipSetAll(list) {
    for pair in list
        TipSet(pair[1], pair[2])
}

; SendMessage straight to the tip window (AutoHotkey's own SendMessage can't see hidden windows)
TipMsg(tt, msg, w, l) => DllCall("SendMessage", "Ptr", tt, "UInt", msg, "Ptr", w, "Ptr", l, "Ptr")
