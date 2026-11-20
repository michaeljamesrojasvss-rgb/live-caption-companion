; ==============================================================================
; same-value-settings.ahk  -  the Same value highlighter's settings window (prefix SvSet*)
;
; * Built from one list (SvSetFields): each setting = one entry {tab, key, type, label, hint, min, max,
;   choices}. A new setting = a new entry (and its default in SV_DEFAULTS in same-value.ahk).
;   Types: num, check, text, wide (a long text on its own line), choice (drop-down), combo (drop-down you
;   can also type in), color (#RRGGBB + Pick...), colors (a list + Add...).
; * Save checks every value first (numbers in range, colours, patterns that compile, a key that exists)
;   and writes data\same-value.ini. Changes apply right away (the hold key too); nothing is lost on Cancel.
; * Mouse-friendly: colour pickers, "Defaults" (fills in the shipped values - not saved until Save),
;   "Try it" (saves, then shows the overlay now), "Settings file" (the raw file, for anything else).
; Needs same-value.ahk (SvSetting, SV_DEFAULTS, SV_INI, SvSetHoldKey, SvShowNow) and same-value-read.ahk.
; ==============================================================================
SVSET_LANG_DEFAULT := "(Windows' first OCR language)"
svSetGui := 0

SvSetFields() {
    static fields := 0
    if IsObject(fields)
        return fields
    langs := [SVSET_LANG_DEFAULT]
    if IsSet(OCR) {
        try {
            for l in StrSplit(Trim(OCR.GetAvailableLanguages(), "`n"), "`n")
                if (Trim(l) != "")
                    langs.Push(Trim(l))
        }
    }
    fields := [
        {tab: 1, key: "HoldKey", type: "combo", label: "Key to hold", hint: "A short tap still does what the key does",
            choices: ["CapsLock", "ScrollLock", "NumLock", "Pause", "AppsKey", "RAlt", "RCtrl", "F13", "XButton1", "XButton2"]},
        {tab: 1, key: "HoldMs", type: "num", label: "Hold this long first (ms)", hint: "Shorter = a quick tap may start it", min: 50, max: 2000},
        {tab: 1, key: "Scale", type: "choice", label: "OCR enlargement", hint: "1 = fastest; 2 = small text read better, slower",
            choices: ["1", "1.5", "2", "3"]},
        {tab: 1, key: "OcrLang", type: "choice", label: "OCR language", hint: "Languages Windows can read on this PC", choices: langs},
        {tab: 1, key: "Reuse", type: "check", label: "Reuse the last read of a monitor that didn't change (faster)"},
        {tab: 1, key: "ShowSec", type: "num", label: "`"Show now`" stays for (seconds)", hint: "The tray's mouse way; Esc closes it sooner", min: 1, max: 120},
        {tab: 2, type: "presets", label: "Quick setup:"},
        {tab: 2, key: "MinChars", type: "num", label: "Fewest letters/digits in a value", hint: "Higher = fewer, longer values", min: 1, max: 50},
        {tab: 2, key: "NeedDigit", type: "check", label: "Only values with a digit (IDs, numbers, dates)"},
        {tab: 2, key: "CaseSense", type: "check", label: "Upper/lower case must match too"},
        {tab: 2, key: "JoinNumbers", type: "check", label: "Join number pieces split by spaces (555 123 4567)"},
        {tab: 2, key: "JoinGap", type: "num", label: "...when the gap is at most", hint: "times the text height (e.g. 0.8)", min: 0, max: 5, dec: true},
        {tab: 2, key: "IgnoreChars", type: "text", label: "Ignore these characters", hint: "e.g. - so WO-123 = WO123"},
        {tab: 2, key: "TrimChars", type: "text", label: "Take these off both ends", hint: "Punctuation around a word"},
        {tab: 2, key: "IdPattern", type: "wide", label: "A value must fit (regular expression)", hint: "Empty = no pattern", regex: true},
        {tab: 2, key: "IgnoreWords", type: "wide", label: "Never count these words (separated by commas)", hint: "Common words that would light up everywhere when words count too"},
        {tab: 3, key: "NearMiss", type: "check", label: "Red dashed outline on values that are almost the same"},
        {tab: 3, key: "NearMinChars", type: "num", label: "Only for values at least this long", hint: "Characters", min: 2, max: 50},
        {tab: 3, key: "NearMaxDiff", type: "num", label: "Most differences", hint: "Characters changed, added or missing", min: 1, max: 3},
        {tab: 3, key: "NearSkip", type: "wide", label: "Never for values like (regular expression)", hint: "Default: dates and times", regex: true},
        {tab: 4, key: "Summary", type: "check", label: "A short line at the top (how many matches)"},
        {tab: 4, key: "Numbers", type: "check", label: "Number tags on matching groups"},
        {tab: 4, key: "ShowAlone", type: "check", label: "Faint outline on values with no twin"},
        {tab: 4, key: "Links", type: "check", label: "Thin lines connecting matching values (in their colour)"},
        {tab: 4, key: "LinkNear", type: "check", label: "...and a red dashed line between values that are almost the same"},
        {tab: 4, key: "LinkWidth", type: "num", label: "Line thickness (pixels)", hint: "1 = thinnest", min: 1, max: 6},
        {tab: 4, key: "Dim", type: "num", label: "Darken the screen behind (%)", hint: "0 = not at all", min: 0, max: 80},
        {tab: 4, key: "FillAlpha", type: "num", label: "Colour fill strength", hint: "0 = outline only, 255 = solid", min: 0, max: 255},
        {tab: 4, key: "LineWidth", type: "num", label: "Outline thickness", hint: "At 100% scaling", min: 1, max: 10},
        {tab: 4, key: "NearColor", type: "color", label: "Almost-the-same colour"},
        {tab: 4, key: "AloneColor", type: "color", label: "No-twin colour"},
        {tab: 4, key: "Colors", type: "colors", label: "Group colours, in order"}]
    return fields
}

SvSetShow(*) {
    global svSetGui
    if IsObject(svSetGui) {
        svSetGui.Show()
        return
    }
    g := Gui("-MinimizeBox", "Same value highlighter - settings")
    g.SetFont("s10", "Segoe UI")
    tabNames := ["Hold && read", "Values", "Almost the same", "Look"]
    tabs := g.Add("Tab3", "x10 y10 w760 h540 vTabs", tabNames)
    rowY := Map()
    for f in SvSetFields() {
        tabs.UseTab(f.tab)
        y := rowY.Has(f.tab) ? rowY[f.tab] : 48
        SvSetAddField(g, f, y, &used)
        rowY[f.tab] := y + used
    }
    tabs.UseTab()
    g.Add("Button", "x10 y562 w100 h30 vSave Default", "Save").OnEvent("Click", (*) => SvSetSave(false))
    g.Add("Button", "x120 y562 w90 h30", "Cancel").OnEvent("Click", (*) => SvSetClose())
    g.Add("Button", "x220 y562 w100 h30", "Defaults").OnEvent("Click", (*) => SvSetFill(true))
    g.Add("Button", "x330 y562 w150 h30", "Try it (save + show)").OnEvent("Click", (*) => SvSetSave(true))
    g.Add("Button", "x650 y562 w120 h30", "Settings file").OnEvent("Click", (*) => SvOpenSettings())
    g.Add("Text", "x10 y600 w760 h40 vStatus", "")
    g.OnEvent("Close", (*) => SvSetClose())
    g.OnEvent("Escape", (*) => SvSetClose())
    svSetGui := g
    SvSetFill(false)
    g.Show("w780 h645")
}

; One setting's row(s): label, control, hint. used = how much height it took.
SvSetAddField(g, f, y, &used) {
    lx := 26, cx := 290, hintW := 760 - 20
    used := 34
    switch f.type {
        case "presets":                          ; one button per preset (SV_PRESETS): fills in, doesn't save
            g.Add("Text", "x" lx " y" (y + 6) " w110 h20", f.label)
            bx := lx + 115
            for name in SV_PRESET_ORDER {
                g.Add("Button", "x" bx " y" y " w140 h30", name).OnEvent("Click", SvSetApplyPreset.Bind(name))
                bx += 150
            }
            used := 46
            return
        case "check":
            g.Add("CheckBox", "x" lx " y" y " w720 h24 v" f.key, f.label)
            return
        case "wide", "colors":
            g.Add("Text", "x" lx " y" (y + 3) " w720 h20", f.label)
            g.Add("Edit", "x" lx " y" (y + 26) " w" (f.type = "colors" ? 600 : 720) " h26 v" f.key)
            if (f.type = "colors")
                g.Add("Button", "x" (lx + 610) " y" (y + 25) " w110 h28", "Add colour...").OnEvent("Click", SvSetAddColor.Bind(f.key))
            if (f.HasOwnProp("hint") && f.hint != "")
                g.Add("Text", "x" lx " y" (y + 56) " w720 h20 cGray", f.hint)
            used := (f.HasOwnProp("hint") && f.hint != "") ? 84 : 64
            return
    }
    g.Add("Text", "x" lx " y" (y + 3) " w" (cx - lx - 8) " h20", f.label)
    cw := f.type = "num" ? 90 : f.type = "color" ? 100 : f.type = "text" ? 160 : 230
    switch f.type {
        case "choice":
            g.Add("DropDownList", "x" cx " y" y " w" cw " v" f.key, f.choices)
        case "combo":
            g.Add("ComboBox", "x" cx " y" y " w" cw " v" f.key, f.choices)
        default:
            g.Add("Edit", "x" cx " y" y " w" cw " h26 v" f.key)
    }
    hx := cx + cw + 10
    if (f.type = "color") {
        g.Add("Button", "x" hx " y" (y - 1) " w80 h28", "Pick...").OnEvent("Click", SvSetPickColor.Bind(f.key))
        hx += 90
    }
    if (f.HasOwnProp("hint") && f.hint != "")
        g.Add("Text", "x" hx " y" (y + 3) " w" (760 - hx) " h20 cGray", f.hint)
}

; Puts the saved values (or the shipped defaults) into the window
SvSetFill(defaults) {
    for f in SvSetFields() {
        if !f.HasOwnProp("key")
            continue
        SvSetPut(f, defaults ? (SV_DEFAULTS.Has(f.key) ? SV_DEFAULTS[f.key] : "") : SvSetting(f.key))
    }
    svSetGui["Status"].Value := defaults ? "The shipped defaults are filled in - press Save to keep them." : ""
}

; A preset fills in its settings (on any tab); nothing is saved until Save
SvSetApplyPreset(name, *) {
    if !SV_PRESETS.Has(name)
        return
    p := SV_PRESETS[name]
    for f in SvSetFields()
        if (f.HasOwnProp("key") && p.Has(f.key))
            SvSetPut(f, p[f.key])
    svSetGui["Status"].Value := "`"" name "`" is filled in (" p.Count " settings, also on the other tabs) - press Save"
        . " or Try it to use it."
}

; One value into its control
SvSetPut(f, v) {
    ctl := svSetGui[f.key]
    switch f.type {
        case "check":
            ctl.Value := (v = "1") ? 1 : 0
        case "choice":
            if (f.key = "OcrLang" && Trim(v) = "")
                v := SVSET_LANG_DEFAULT
            pick := 0
            for i, c in f.choices
                if (c = String(v))
                    pick := i
            if !pick {                           ; a value that isn't in the list (typed in the file): add it
                ctl.Add([String(v)])
                f.choices.Push(String(v))
                pick := f.choices.Length
            }
            ctl.Choose(pick)
        case "combo":
            ctl.Text := v
        default:
            ctl.Value := v
    }
}

; Reads and checks every value; saves only if all are fine. thenShow = "Try it".
SvSetSave(thenShow) {
    g := svSetGui
    vals := Map(), problems := ""
    for f in SvSetFields() {
        if !f.HasOwnProp("key")
            continue
        ctl := g[f.key]
        switch f.type {
            case "check":
                v := ctl.Value ? "1" : "0"
            case "choice", "combo":
                v := Trim(ctl.Text)
            default:
                v := Trim(ctl.Value)
        }
        err := SvSetCheck(f, &v)
        if (err != "")
            problems .= (problems = "" ? "" : "`n") f.label ": " err
        vals[f.key] := v
    }
    if (problems != "") {
        g["Status"].Value := "Not saved - " problems
        return
    }
    oldKey := SvSetting("HoldKey"), oldScale := SvSetting("Scale"), oldLang := SvSetting("OcrLang")
    for k, v in vals
        IniWrite(v, SV_INI, "Settings", k)
    if (vals["Scale"] != oldScale || vals["OcrLang"] != oldLang)
        svReadCache.Clear()                      ; read again with the new OCR settings
    if (vals["HoldKey"] != oldKey)
        SvSetHoldKey()
    SvLog("settings saved")
    g["Status"].Value := "Saved - hold " vals["HoldKey"] " to use it."
    if thenShow {
        g.Hide()
        SetTimer(() => SvShowNow(), -400)
        SetTimer(() => (IsObject(svSetGui) ? svSetGui.Show() : 0), -(Max(1, SvNum("ShowSec")) * 1000 + 900))
    }
}

; "" if the value is fine (v may be tidied), else what's wrong
SvSetCheck(f, &v) {
    switch f.type {
        case "num":
            if !IsNumber(v)
                return "must be a number"
            if (!f.HasOwnProp("dec") && !IsInteger(v))
                return "must be a whole number"
            if (Number(v) < f.min || Number(v) > f.max)
                return "must be from " f.min " to " f.max
        case "choice":
            if (f.key = "OcrLang" && v = SVSET_LANG_DEFAULT)
                v := ""
        case "combo":
            if (v = "")
                return "pick a key"
            if (!GetKeyVK(v) && !GetKeySC(v))
                return "`"" v "`" isn't a key name AutoHotkey knows"
        case "color":
            if (SvColor(v) < 0)
                return "must be a colour like #FF3B30"
            v := Format("#{:06X}", SvColor(v))
        case "colors":
            n := 0
            for c in StrSplit(v, ",") {
                if (Trim(c) = "")
                    continue
                if (SvColor(c) < 0)
                    return "`"" Trim(c) "`" isn't a colour like #22C55E"
                n += 1
            }
            if !n
                return "needs at least one colour"
    }
    if (f.HasOwnProp("regex") && v != "") {
        try {
            RegExMatch("", v)
        } catch as err {
            return "the pattern doesn't work (" err.Message ")"
        }
    }
    return ""
}

SvSetClose() {
    global svSetGui
    try svSetGui.Destroy()
    svSetGui := 0
    if SV_ONCE                                   ; started only to show the settings: done
        SetTimer(() => ExitApp(), -300)
}

SvSetPickColor(key, *) {
    ctl := svSetGui[key]
    c := SvSetChooseColor(SvColor(ctl.Value))
    if (c >= 0)
        ctl.Value := Format("#{:06X}", c)
}

SvSetAddColor(key, *) {
    c := SvSetChooseColor(-1)
    if (c < 0)
        return
    ctl := svSetGui[key]
    cur := Trim(ctl.Value, " ,")
    ctl.Value := (cur = "" ? "" : cur ", ") Format("#{:06X}", c)
}

; Windows' colour dialog. rgb: 0xRRGGBB to start from (or -1). Returns 0xRRGGBB, or -1 if cancelled.
SvSetChooseColor(rgb) {
    static custom := Buffer(64, 0)               ; the dialog's 16 custom colours, kept while the app runs
    p := A_PtrSize
    cc := Buffer(p = 8 ? 72 : 36, 0)
    NumPut("UInt", cc.Size, cc, 0)
    NumPut("Ptr", svSetGui.Hwnd, cc, p)
    if (rgb >= 0)                                ; COLORREF is 0x00BBGGRR
        NumPut("UInt", ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF), cc, 3 * p)
    NumPut("Ptr", custom.Ptr, cc, 4 * p)
    NumPut("UInt", 0x1 | 0x2, cc, 5 * p)         ; CC_RGBINIT | CC_FULLOPEN
    if !DllCall("comdlg32\ChooseColorW", "Ptr", cc)
        return -1
    bgr := NumGet(cc, 3 * p, "UInt")
    return ((bgr & 0xFF) << 16) | (bgr & 0xFF00) | ((bgr >> 16) & 0xFF)
}
