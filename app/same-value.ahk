#Requires AutoHotkey v2.0
#SingleInstance Force
try TraySetIcon(A_ScriptDir "\icons\same-value.ico")    ; its own icon (tray)
try DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", "CaptionCompanion.SameValue")
#Include app-paths.ahk
#Include Json.ahk                                     ; package-lib.ahk (via app-paths) uses it
#Include debug-trace.ahk
#Include tooltips.ahk               ; hover tips on buttons (shared)
#Include screen-grab.ahk
#Include *i %A_ScriptDir%\lib\OCR.ahk                 ; Windows' built-in OCR
#Include same-value-read.ahk
#Include same-value-match.ahk
#Include same-value-overlay.ahk
#Include same-value-settings.ahk
; ==============================================================================
; same-value.ahk  -  Same value highlighter: hold a key, equal values on screen light up in the same colour
;
; * Hold CapsLock (HoldKey; a short tap still does what the key does): every monitor is captured, read with
;   Windows' built-in OCR, and while you hold, a see-through overlay marks the ID-like values: the same
;   colour (+ a number) = the same value; a red dashed outline = almost the same as another value (one
;   character different); a faint outline = no twin. Let go = gone. Design: docs\SAME-VALUE.md.
; * Pieces: same-value-read.ahk (capture + OCR, reuses a monitor's last read if its picture didn't change),
;   same-value-match.ahk (pure: words -> marks), same-value-overlay.ahk (the see-through windows),
;   same-value-settings.ahk (the settings window).
; * Local only: no AI, no internet; pictures stay in memory. The log and the debug trace never hold text
;   from the screen - only counts and times.
; * Its own app and process, generic. OFF by default: Companion tray > Same value highlighter > On
;   (same-value-link.ahk, live-captions.ini [SameValue] Enabled). Started by the Companion it has no tray
;   icon and ends with it; started on its own (double-click) it has a tray icon. One copy only.
;
; Messages (WM_COPYDATA, tag SV_TAG, JSON-ish text): {"t":"show"} (show for ShowSec, the mouse way),
;   {"t":"settings"}, {"t":"quit"}
; Arguments: <Companion window handle> = started by the Companion; /show; /settings;
;   /once = only that (while the feature is off): no hold key, quits when done
; ==============================================================================
SV_TITLE := "Caption Companion Same value"
SV_TAG := 0x3CC7
SV_INI := DATA_DIR "\same-value.ini"
SV_LOG := DATA_DIR "\same-value.log"
; Common words that would light up everywhere once words count too (the default ignore list)
SV_COMMON_WORDS := "the, and, for, you, your, with, this, that, these, those, from, have, has, had, are, was, were, "
    . "not, but, all, any, can, our, will, would, should, could, his, her, they, them, then, than, there, their, "
    . "what, when, where, which, who, how, its, into, out, about, just, also, more, some, only, other, been, being, "
    . "please, thank, thanks, hello, regards, subject, sent, reply, forward, date, page, view, edit, new, open, close"
; One-click setups in the settings window (Values tab): each fills in these settings (not saved until Save)
SV_PRESETS := Map(
    "IDs only", Map("NeedDigit", 1, "MinChars", 5, "IdPattern", "^[A-Za-z0-9][A-Za-z0-9\-_./#:]*$",
        "NearMiss", 1, "NearMinChars", 6, "ShowAlone", 1),
    "Words too", Map("NeedDigit", 0, "MinChars", 3, "IdPattern", "", "IgnoreWords", SV_COMMON_WORDS,
        "NearMiss", 1, "NearMinChars", 8, "ShowAlone", 0),
    "Everything", Map("NeedDigit", 0, "MinChars", 1, "IdPattern", "", "IgnoreWords", "",
        "NearMiss", 0, "ShowAlone", 0))
SV_PRESET_ORDER := ["IDs only", "Words too", "Everything"]
SV_DEFAULTS := Map(
    "HoldKey", "CapsLock",         ; the key to hold (AutoHotkey key name); a tap still does what it does
    "HoldMs", 250,                 ; hold this long before it starts
    "Scale", 1,                    ; OCR enlargement: 1 = fastest, 2 = reads small text better (slower)
    "OcrLang", "",                 ; e.g. en-US; empty = the first OCR language Windows has
    "MinChars", 5,                 ; fewest letters/digits for a value to count
    "NeedDigit", 1,                ; 1 = only values with a digit; 0 = words too
    "IdPattern", "^[A-Za-z0-9][A-Za-z0-9\-_./#:]*$",   ; a value must fit this (regular expression)
    "TrimChars", "()[]{}<>.,;:'`"",   ; taken off both ends of each word
    "IgnoreChars", "",             ; removed before comparing, e.g. - so WO-123456 = WO123456
    ; never count these (separated by commas) - matters when words count too (NeedDigit 0)
    "IgnoreWords", SV_COMMON_WORDS,
    "CaseSense", 0,
    "JoinNumbers", 1,              ; join number pieces split by spaces (555 123 4567)
    "JoinGap", 0.8,                ; ...when the gap is at most this many times the text height
    "NearMiss", 1,                 ; red dashed outline: almost the same as another value
    "NearMinChars", 6,
    "NearMaxDiff", 1,
    ; dates and times differ by one digit all the time: never "almost the same"
    "NearSkip", "^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}$|^\d{1,2}:\d{2}",
    "ShowAlone", 1,                ; faint outline on values with no twin
    "Dim", 15,                     ; darken the screen behind the marks (0-80 %)
    "FillAlpha", 80,               ; colour fill strength (0-255)
    "LineWidth", 3,                ; outline thickness at 100% scaling
    "Numbers", 1,                  ; number tags on matching groups
    "Links", 0,                    ; thin lines between matching values (each to the next, reading order)
    "LinkNear", 1,                 ; ...and a red dashed line between "almost the same" values
    "LinkWidth", 1,                ; line thickness in pixels
    "Colors", "#22C55E, #3B82F6, #F59E0B, #EC4899, #14B8A6, #A855F7, #EAB308, #06B6D4, #F97316, #84CC16, #6366F1, #E11D48",
    "NearColor", "#FF3B30",
    "AloneColor", "#9CA3AF",
    "ShowSec", 8,                  ; "Show now" (tray): how long the overlay stays
    "Summary", 1,                  ; a short line at the top: how many matches / almost the same
    "Reuse", 1)                    ; reuse a monitor's last read if its picture didn't change

DetectHiddenWindows(true)
OnError(SvOnError)

SV_HOST_HWND := (A_Args.Length >= 1 && IsInteger(A_Args[1])) ? Integer(A_Args[1]) : 0
svArgs := ""
for a in A_Args
    svArgs .= " " a
SV_ONCE := InStr(svArgs, "/once") ? true : false

svMain := 0          ; hidden window: commands from the Companion
svKey := ""          ; the hold key in use
svHeld := false      ; the hold key is down
svStarted := false   ; this hold started a read (so letting go hides it instead of being a tap)
svBusy := false      ; a read is running
svCancel := false    ; let go / Esc while reading: don't show the result
svShown := false     ; the overlay is up

SvBuildMain()
OnMessage(0x4A, SvOnCopyData)
OnMessage(0x02E0, SvOnDpiChanged)
OnExit((*) => SvOvHide())
SvTrimLog()
if !IsSet(OCR)
    SvLog("the OCR library (app\lib\OCR.ahk) is missing - nothing can be read")
if !SV_ONCE
    SvSetHoldKey()
if SV_HOST_HWND {
    A_IconHidden := true
    SetTimer(SvCheckHost, 2000)
} else {
    SvBuildTray()
}
SvLog("started (" (A_PtrSize * 8) "-bit, version " APP_VERSION (SV_HOST_HWND ? ", by the Companion" : ", on its own") ", hold " svKey ")")
if InStr(svArgs, "/settings")
    SetTimer(SvSetShow, -300)
if InStr(svArgs, "/show")
    SetTimer(() => SvShowNow(), -400)

SvBuildMain() {
    global svMain
    svMain := Gui("+ToolWindow", SV_TITLE)
    svMain.Show("Hide w10 h10")
}

SvBuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Show now (" SvSetting("ShowSec") " s)", (*) => SetTimer(() => SvShowNow(), -400))
    A_TrayMenu.Add("Settings...", (*) => SvSetShow())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_IconTip := "Same value highlighter - hold " svKey
}

SvCheckHost() {
    if !WinExist("ahk_id " SV_HOST_HWND)
        ExitApp()
}

; ==============================================================================
; Holding the key
; ==============================================================================
SvSetHoldKey() {
    global svKey
    key := Trim(SvSetting("HoldKey"))
    if (svKey != "" && svKey != key) {           ; changed in the settings: the old key is free again
        try Hotkey("$*" svKey, "Off")
        try Hotkey("$*" svKey " up", "Off")
        svKey := ""
    }
    if (key = "")
        return
    try {
        Hotkey("$*" key, SvKeyDown, "On")
        Hotkey("$*" key " up", SvKeyUp, "On")
        svKey := key
    } catch as err {
        SvLog("the hold key couldn't be set (" key "): " err.Message)
    }
}

SvKeyDown(*) {
    global svHeld, svStarted, svCancel
    if svHeld                                    ; the keyboard repeats while a key is held: once is enough
        return
    svHeld := true
    svStarted := false
    if svBusy                                    ; pressed again while the last read is still running: show it
        svCancel := false
    SetTimer(SvHoldStart, -Max(50, SvNum("HoldMs")))
}

SvKeyUp(*) {
    global svHeld, svCancel
    svHeld := false
    SetTimer(SvHoldStart, 0)
    if !svStarted {
        SvTap()
        return
    }
    svCancel := true
    SvHide()
}

SvHoldStart() {
    global svStarted, svCancel
    if !svHeld
        return
    svStarted := true
    svCancel := false                            ; a new hold: the last let-go's cancel no longer applies
    SvRun(false)
}

; A short tap: the key does what it normally does
SvTap() {
    k := StrLower(svKey)
    if (k = "capslock")
        SetCapsLockState(GetKeyState("CapsLock", "T") ? "Off" : "On")
    else if (k = "numlock")
        SetNumLockState(GetKeyState("NumLock", "T") ? "Off" : "On")
    else if (k = "scrolllock")
        SetScrollLockState(GetKeyState("ScrollLock", "T") ? "Off" : "On")
    else
        Send("{Blind}{" svKey "}")
}

; The mouse way (tray "Show now"): shows for ShowSec; Esc closes it sooner
SvShowNow() {
    global svCancel
    svCancel := false
    SvRun(true)
}

SvHide() {
    global svShown
    SetTimer(SvHide, 0)
    try Hotkey("Esc", "Off")
    SvOvHide()
    svShown := false
    if (SV_ONCE && !IsObject(svSetGui))          ; started only for this: done (unless its settings are open)
        SetTimer(() => ExitApp(), -300)
}

; ==============================================================================
; One read: capture -> OCR -> match -> draw
; ==============================================================================
SvRun(timed) {
    global svBusy, svShown
    if svBusy
        return
    if !IsSet(OCR) {
        SvLog("can't read the screen: the OCR library is missing")
        if SV_ONCE
            ExitApp()
        return
    }
    svBusy := true
    t0 := A_TickCount
    shots := []
    try {
        shots := SvReadCapture()                 ; first, before anything is drawn on screen
        tCap := A_TickCount - t0
        style := SvStyle()
        ropts := {scale: SvNum("Scale"), lang: Trim(SvSetting("OcrLang")), reuse: SvNum("Reuse") ? 1 : 0}
        toRead := SvReadChanged(shots, ropts)
        if (toRead && !svCancel) {
            SvOvShow(shots, [], "Reading " toRead " monitor" (toRead = 1 ? "" : "s") "...", style)
            svShown := true
        }
        words := SvReadWords(shots, ropts, () => svCancel)
        if (!IsObject(words) || svCancel) {
            DbgTrace("same", "read cancelled after " (A_TickCount - t0) " ms")
            return
        }
        tRead := A_TickCount - t0
        res := SvMatch(words, SvMatchOpts())
        SvOvShow(shots, res.marks, SvNum("Summary") ? SvSummary(res) : "", style, res.links)
        svShown := true
        if timed {
            try Hotkey("Esc", (*) => SvHide(), "On")
            SetTimer(SvHide, -Max(1, SvNum("ShowSec")) * 1000)
        }
        line := shots.Length " monitor(s), " toRead " read, " words.Length " words, " res.values " values, "
            . res.groups " group(s), " res.nearCount " almost-same, " res.alone " alone; capture " tCap " ms, total "
            . (A_TickCount - t0) " ms (read " tRead " ms)"
        DbgTrace("same", line)
        SvLog(line)
    } catch as err {
        SvLog("FAILED: " err.Message " (" err.What ", line " err.Line ")")
        try {
            if shots.Length {
                SvOvShow(shots, [], "Same value highlighter: " err.Message, SvStyle())
                svShown := true
                SetTimer(SvHide, -4000)
            } else if SV_ONCE {
                SetTimer(() => ExitApp(), -300)
            }
        }
    } finally {
        SvReadFree(shots)
        svBusy := false
    }
    if (!timed && !svHeld)                       ; let go while it was finishing
        SvHide()
}

SvSummary(res) {
    if !res.values
        return "No ID-like values found on screen"
    if (!res.groups && !res.nearCount)
        return "No matching values (" res.values " read)"
    t := res.groups " matching value" (res.groups = 1 ? "" : "s")
    if res.nearCount
        t .= "  ·  " res.nearCount " ALMOST the same (red)"
    return t
}

SvMatchOpts() {
    return {minChars: SvNum("MinChars"), needDigit: SvNum("NeedDigit"), idPattern: SvSetting("IdPattern"),
        trimChars: SvSetting("TrimChars"), ignoreChars: SvSetting("IgnoreChars"), ignoreWords: SvSetting("IgnoreWords"),
        caseSense: SvNum("CaseSense"),
        joinNumbers: SvNum("JoinNumbers"), joinGap: SvNum("JoinGap"), nearMiss: SvNum("NearMiss"),
        nearMinChars: SvNum("NearMinChars"), nearMaxDiff: SvNum("NearMaxDiff"), nearSkip: SvSetting("NearSkip"),
        showAlone: SvNum("ShowAlone"), links: SvNum("Links"), linkNear: SvNum("LinkNear")}
}

SvStyle() {
    cols := []
    for c in StrSplit(SvSetting("Colors"), ",")
        if ((v := SvColor(c)) >= 0)
            cols.Push(v)
    if !cols.Length
        cols := [0x22C55E, 0x3B82F6, 0xF59E0B, 0xEC4899]
    near := SvColor(SvSetting("NearColor")), alone := SvColor(SvSetting("AloneColor"))
    return {dim: SvNum("Dim"), fillAlpha: Min(255, Max(0, Round(SvNum("FillAlpha")))), lineWidth: SvNum("LineWidth"),
        numbers: SvNum("Numbers"), linkWidth: Max(1, Round(SvNum("LinkWidth"))), colors: cols, nearColor: near >= 0 ? near : 0xFF3B30, aloneColor: alone >= 0 ? alone : 0x9CA3AF}
}

; "#RRGGBB" -> 0xRRGGBB, or -1 if it isn't a colour
SvColor(text) {
    text := Trim(text)
    return RegExMatch(text, "^#?([0-9A-Fa-f]{6})$", &m) ? Integer("0x" m[1]) : -1
}

; ==============================================================================
; Messages, settings, log
; ==============================================================================
SvOnCopyData(wParam, lParam, msg, hwnd) {
    if (!IsObject(svMain) || hwnd != svMain.Hwnd)
        return
    try {
        if (NumGet(lParam, 0, "UPtr") != SV_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    if InStr(text, '"show"')
        SetTimer(() => SvShowNow(), -400)        ; after the tray menu has closed
    else if InStr(text, '"settings"')
        SetTimer(SvSetShow, -1)
    else if InStr(text, '"quit"')
        SetTimer(() => ExitApp(), -1)
    return true
}

; The overlay windows keep their exact size when Windows says their monitor's scaling changed
SvOnDpiChanged(wParam, lParam, msg, hwnd) {
    for idx, g in svOvWins
        if (hwnd = g.Hwnd)
            return 0
}

SvOpenSettings(*) {
    for k, v in SV_DEFAULTS
        if (IniRead(SV_INI, "Settings", k, "`a") = "`a")
            IniWrite(v, SV_INI, "Settings", k)
    try Run('notepad.exe "' SV_INI '"')
}

SvSetting(key) {
    def := SV_DEFAULTS.Has(key) ? SV_DEFAULTS[key] : ""
    try return IniRead(SV_INI, "Settings", key, def)
    return def
}

SvNum(key) {
    v := SvSetting(key)
    return IsNumber(v) ? Number(v) : (SV_DEFAULTS.Has(key) && IsNumber(SV_DEFAULTS[key]) ? SV_DEFAULTS[key] : 0)
}

SvLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", SV_LOG, "UTF-8")
}

SvTrimLog() {
    try {
        if (FileExist(SV_LOG) && FileGetSize(SV_LOG) > 512 * 1024)
            FileMove(SV_LOG, DATA_DIR "\same-value.old.log", true)
    }
}

SvOnError(err, mode) {
    try SvLog("ERROR: " err.Message " (" err.What ", line " err.Line ")")
    try SvOvHide()                               ; never leave the overlay up
    return 1
}
