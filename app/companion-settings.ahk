; ==============================================================================
; companion-settings.ahk  -  the Companion's Settings window (prefix CSet*)
;
; * Opened by the ⚙ button (top left, next to 📍) and tray > "Settings...". Sections on the
;   left, that section's settings on the right, Save / Close / Defaults at the bottom.
; * The tray menu keeps ALL its items too (owner's choice 2026-11-22: people used to the tray
;   keep it). Both places use the same functions (CallerToggle, QASaveValue, PoolLinkToggle...),
;   so they never disagree: the tray's ticks follow a Save here, and this window reads the
;   current state every time it opens.
; * Ticks, numbers, lists and texts apply on Save - only the ones you changed here, so a tray
;   change made while this window was open is kept. Buttons act right away.
; * Built from one list (CSetFields): a new setting = one entry. Types:
;     head    {label}                          a heading
;     note    {label}                          grey text
;     check   {key, label, get, flip, def}     get() -> true/false; flip() switches it (the tray's own toggle)
;     num     {key, label, hint, min, max, get, set, def}
;     choice  {key, label, hint, choices, get, set, def}     get/set use the shown text
;     text    {key, label, hint, rows, need, get, set, def}  multi-line; need = text it must contain
;     buttons {items: [[label, fn], ...]}      a row of buttons (act right away)
;     app     {key, label, get, flip, def, items}   an On tick + that app's buttons on one row
;   Every field has sec (its section number, see CSET_SECTIONS).
; * The other apps (Tasks, Screen ask, Same value, Agent, the pool) keep their own settings
;   windows: Apps only switches them on/off and opens them.
; * Every entry point is wrapped in try/catch: captions and the call are never affected.
; Hooks: CSetInit() (after TutInit: its tray item goes on top), CSetShow()
; ==============================================================================

CSET_SECTIONS := ["Calls && 3CX", "Copilot", "Apps", "Captions && mic", "Updates && help", "Troubleshooting"]
CSET_TRAY := "Settings..."
CSET_PX := 214                     ; where the page starts (right of the section list)
CSET_PW := 640                     ; page width
cSetGui := 0
cSetFieldList := []
cSetSec := 1

CSetInit() {
    try {
        A_TrayMenu.Insert("1&")
        A_TrayMenu.Insert("1&", CSET_TRAY, (*) => CSetShow())
    } catch as err {
        CSetReport(err)
    }
}

; ------------------------------------------------------------------ the list
CSetFields() {
    f := []
    ; ---- 1  Calls & 3CX
    f.Push({sec: 1, type: "head", label: "3CX caller"})
    f.Push(CSetCallerFlag("Enabled", "Detect calls from 3CX"))
    f.Push(CSetCallerFlag("AutoNewCall", "Start a new call record when a call rings"))
    f.Push(CSetCallerFlag("Popup", "Show the caller card near 3CX"))
    f.Push(CSetCallerFlag("FocusOnRing", "Switch to the Companion when a call rings"))
    f.Push({sec: 1, type: "head", label: "Q-login alert"})
    f.Push({sec: 1, type: "check", key: "QA.Enabled", label: QA_ITEM_ON, def: 1
        , get: () => QAlertSetting("Enabled", 1) = "1", flip: () => QAToggle()})
    f.Push({sec: 1, type: "choice", key: "QA.Position", label: "Where the alert shows", choices: QA_POSITIONS
        , def: QA_DEFAULT_POS, get: () => QAlertSetting("Position", QA_DEFAULT_POS), set: CSetQaPosition})
    for k in ["ToastSeconds", "MaxToasts", "IntervalSec"]
        f.Push(CSetQaNum(k))
    f.Push({sec: 1, type: "buttons", items: [["Show a test alert", () => QAShowToast(true)]]})

    ; ---- 2  Copilot
    f.Push({sec: 2, type: "head", label: "Copilot pool (the 💬 and ^ buttons beside the helpers)"})
    f.Push({sec: 2, type: "check", key: "Pool.Enabled", label: POOLLINK_USE, def: 1
        , get: PoolLinkEnabled, flip: PoolLinkToggle})
    f.Push({sec: 2, type: "buttons", items: [["Open the pool window", PoolLinkShowWindow]
        , ["Restart the pool", PoolLinkRestart], ["Sign out of Copilot...", PoolLinkSignOut]]})
    f.Push({sec: 2, type: "head", label: "Auto helpers"})
    f.Push({sec: 2, type: "note", label: "To pick which helpers follow the call by themselves: right-click a helper button > Auto-run during calls."})
    f.Push(CSetAutoNum("MinChars", "New customer letters before a follow-up", "1 = any new words", 1, 5000))
    f.Push(CSetAutoNum("QuietMs", "Customer quiet this long = finished (ms)", "1000 ms = 1 second", 100, 30000))
    f.Push(CSetAutoNum("MinGapMs", "At least this long between follow-ups (ms)", "0 = no wait", 0, 600000))
    f.Push({sec: 2, type: "text", key: "Auto.FollowUpPrompt", rows: 4, need: "{{new}}"
        , label: "Follow-up message  ({{new}} = what the customer just said)"
        , def: StrReplace(AUTO_DEFAULTS["FollowUpPrompt"], "\n", "`n")
        , get: () => StrReplace(AutoSetting("FollowUpPrompt"), "\n", "`n")
        , set: (v) => IniWrite(StrReplace(v, "`n", "\n"), MIC_INI, "AutoHelpers", "FollowUpPrompt")})
    f.Push({sec: 2, type: "head", label: "Paste into Copilot (the 🤖 buttons)"})
    f.Push({sec: 2, type: "buttons", items: [["Learn: message box", () => AssistStartLearn("Input")]
        , ["Learn: Send button", () => AssistStartLearn("Send")], ["Learn: New chat button", () => AssistStartLearn("NewChat")]]})

    ; ---- 3  Apps
    f.Push({sec: 3, type: "note", label: "Each app runs on its own: if one has a problem, captions and the call carry on. "
        . "On = it starts with the Companion. The buttons work while an app is off too."})
    f.Push({sec: 3, type: "app", key: "App.Tasks", label: TASKLINK_ITEM, def: 1, get: TaskLinkEnabled, flip: TaskLinkToggle
        , items: [["Open", () => TaskLinkShowApp("show")], ["Settings...", () => TaskLinkShowApp("settings")]]})
    f.Push({sec: 3, type: "app", key: "App.MainHelper", label: MAINHELPER_ITEM, def: 0, get: MainHelperEnabled
        , flip: MainHelperToggle, items: []})
    f.Push({sec: 3, type: "app", key: "App.ScreenAsk", label: SALINK_MENU, def: 0, get: SaLinkEnabled, flip: SaLinkToggle
        , items: [["Capture now", CSetScreenAskNow], ["Settings...", () => SaLinkCommand("settings")]]})
    f.Push({sec: 3, type: "app", key: "App.SameValue", label: SVLINK_MENU, def: 0, get: SvLinkEnabled, flip: SvLinkToggle
        , items: [["Show now", () => SvLinkCommand("show")], ["Settings...", () => SvLinkCommand("settings")]]})
    f.Push({sec: 3, type: "app", key: "App.Agent", label: AGTLINK_MENU, def: AppIsDev() ? 1 : 0, get: AgtLinkEnabled
        , flip: AgtLinkToggle, items: [["Open", AgtLinkOpen]]})
    f.Push({sec: 3, type: "note", label: "The Copilot pool is under Copilot."})

    ; ---- 4  Captions & mic
    f.Push({sec: 4, type: "head", label: "Windows Live Captions"})
    f.Push({sec: 4, type: "note", label: "Also in the right-click menu of the chat view."})
    f.Push({sec: 4, type: "buttons", items: [["Restart Live Captions", LctSafe(LctRestart)]
        , ["Test Live Captions (plays a sample voice)", LctSafe(LctTest)]]})
    f.Push({sec: 4, type: "head", label: "Mic captions (experimental: your own voice)"})
    if micAvailable {
        devs := [MicDeviceLabel(0)]
        for name in micDeviceNames
            devs.Push(name)
        f.Push({sec: 4, type: "check", key: "Mic.On", label: "Experimental: Mic captions", def: 0
            , get: () => micEnabled, flip: () => ToggleMicCaptions()})
        f.Push({sec: 4, type: "choice", key: "Mic.Device", label: "Microphone", choices: devs, def: MicDeviceLabel(0)
            , get: () => MicDeviceLabel(micCurrentDevice), set: CSetMicDevice})
    } else {
        f.Push({sec: 4, type: "note", label: "Not available on this PC (the speech files for mic captions aren't installed)."})
    }

    ; ---- 5  Updates & help
    f.Push({sec: 5, type: "head", label: "Updates  (this copy: version " APP_VERSION ")"})
    f.Push({sec: 5, type: "buttons", items: [["Check for updates", UpdSafe(() => UpdStartCheck(true))]
        , ["Set update link...", UpdSafe(UpdSetLink)], ["Go back to the previous version...", UpdSafe(UpdRollback)]]})
    f.Push({sec: 5, type: "head", label: "Help and your data"})
    f.Push({sec: 5, type: "buttons", items: [["Tutorial (how to use the app)", CSetTutorial]
        , ["Open data folder", () => Run('explorer.exe "' DATA_DIR '"')]]})
    f.Push({sec: 5, type: "buttons", items: [["Import && merge from another copy...", () => MergeImportStart()]]})

    ; ---- 6  Troubleshooting
    f.Push({sec: 6, type: "head", label: "Debug trace"})
    f.Push({sec: 6, type: "check", key: "Dbg.On", label: DBG_ITEM, def: 0
        , get: () => IniRead(DBG_INI, "Trace", "On", "0") = "1", flip: () => DbgToggle()})
    f.Push({sec: 6, type: "head", label: "Logs"})
    f.Push({sec: 6, type: "buttons", items: [["Debug trace", () => CSetOpenFile(DBG_FILE)]
        , ["Errors", () => CSetOpenFile(ERR_LOG)], ["3CX caller / Q alert", () => CSetOpenFile(CALLER_LOG)]]})
    f.Push({sec: 6, type: "buttons", items: [["Updates", () => CSetOpenFile(UPD_LOG)]
        , ["Paste into Copilot", () => CSetOpenFile(ASSIST_LOG)], ["Copilot targets file", () => CSetOpenFile(ASSIST_TARGETS)]]})
    f.Push({sec: 6, type: "head", label: "Try without a real call"})
    f.Push({sec: 6, type: "buttons", items: [["Simulate incoming call...", CallerSafe(CallerSimulateRing)]
        , ["Simulate call ended", CallerSafe(CallerOnIdle)]]})
    f.Push({sec: 6, type: "head", label: "Memory"})
    f.Push({sec: 6, type: "buttons", items: [["Built-in browser memory (Copilot pool, Screen ask)...", PoolLinkMemoryReport]]})
    return f
}

; Entry makers: each call gets its own variables (closures made in a loop would all share one)
CSetCallerFlag(key, label) {
    return {sec: 1, type: "check", key: "Caller." key, label: label, def: CALLER_DEFAULTS.Get(key, 0)
        , get: () => CallerFlag(key), flip: () => CallerToggle(key)}
}

CSetQaNum(key) {
    c := QA_CHOICES[key]
    return {sec: 1, type: "num", key: "QA." key, label: c[1] (c[3] != "" ? " (" c[3] ")" : ""), hint: c[5] " to " c[6]
        , min: c[5], max: c[6], def: c[4], get: () => QAInt(key), set: (v) => QASaveValue(key, Integer(v))}
}

CSetAutoNum(key, label, hint, lo, hi) {
    return {sec: 2, type: "num", key: "Auto." key, label: label, hint: hint, min: lo, max: hi, def: AUTO_DEFAULTS[key]
        , get: () => AutoNum(key), set: (v) => IniWrite(Integer(v), MIC_INI, "AutoHelpers", key)}
}

CSetQaPosition(v) {
    IniWrite(v, MIC_INI, "QAlert", "Position")
    QASyncMenu()
}

CSetMicDevice(v) {
    if (v = MicDeviceLabel(0)) {
        SetMicDevice(0)
        return
    }
    for i, name in micDeviceNames
        if (name = v)
            return SetMicDevice(i)
}

; Screen ask freezes the whole screen: this window steps aside first
CSetScreenAskNow() {
    try cSetGui.Hide()
    SetTimer(() => SaLinkCommand("capture"), -250)
}

; The tutorial points at the main window: this window closes first (asks about unsaved changes)
CSetTutorial() {
    if CSetClose()
        SetTimer(TutSafe(TutStart), -200)
}

CSetOpenFile(path) {
    if !FileExist(path) {
        CSetStatus("Nothing written there yet (" path ")")
        return
    }
    Run('notepad.exe "' path '"')
}

; ------------------------------------------------------------------ the window
CSetShow(*) {
    global cSetGui, cSetFieldList, cSetSec
    try {
        if IsObject(cSetGui) {
            if !CSetDirty()
                CSetFill(false)                  ; pick up changes made from the tray meanwhile
            cSetGui.Show()
            return
        }
        try cSetSec := Integer(IniRead(MIC_INI, "Settings", "LastSection", 1))
        if (cSetSec < 1 || cSetSec > CSET_SECTIONS.Length)
            cSetSec := 1
        g := Gui("-MinimizeBox +Owner" myGui.Hwnd, "Live Caption Companion - Settings")
        g.SetFont("s10", "Segoe UI")
        names := []
        for s in CSET_SECTIONS
            names.Push(StrReplace(s, "&&", "&"))
        list := g.Add("ListBox", "x12 y12 w186 h520 vSections Choose" cSetSec, names)
        list.OnEvent("Change", (ctl, *) => CSetShowSection(ctl.Value))
        cSetFieldList := CSetFields()
        rowY := Map()
        for f in cSetFieldList {
            y := rowY.Has(f.sec) ? rowY[f.sec] : 12
            if (f.type = "head" && y > 12)
                y += 8                           ; a little air above each heading but the first
            f.ctls := []
            CSetAddField(g, f, y, &used)
            rowY[f.sec] := y + used
        }
        g.Add("Text", "x12 y544 w836 h1 0x10")       ; a thin line above the buttons (SS_ETCHEDHORZ)
        g.Add("Button", "x12 y556 w100 h30 Default", "Save").OnEvent("Click", (*) => CSetSave())
        g.Add("Button", "x120 y556 w90 h30", "Close").OnEvent("Click", (*) => CSetClose())
        g.Add("Button", "x218 y556 w190 h30", "Defaults (this section)").OnEvent("Click", (*) => CSetDefaults())
        g.Add("Text", "x420 y552 w428 h40 cGray vStatus", "Ticks and values apply when you press Save. Buttons act right away.")
        g.OnEvent("Close", (*) => !CSetClose())  ; true = keep the window (Cancel on the question)
        g.OnEvent("Escape", (*) => CSetClose())
        cSetGui := g
        CSetFill(false)
        CSetShowSection(cSetSec)
        g.Show("w860 h600")
    } catch as err {
        CSetReport(err)
    }
}

; One setting's controls at height y (page coordinates). used = height it took.
CSetAddField(g, f, y, &used) {
    px := CSET_PX, pw := CSET_PW, lw := 300
    switch f.type {
        case "head":
            g.SetFont("s10 bold")
            f.ctls.Push(g.Add("Text", "x" px " y" y " w" pw " h22", f.label))
            g.SetFont("s10 norm")
            used := 28
        case "note":
            lines := Ceil(StrLen(f.label) / 92)
            f.ctls.Push(g.Add("Text", "x" px " y" y " w" pw " h" (20 * lines) " cGray", f.label))
            used := 20 * lines + 8
        case "check":
            f.ctl := g.Add("CheckBox", "x" px " y" y " w" pw " h24", f.label)
            f.ctls.Push(f.ctl)
            used := 30
        case "num", "choice":
            f.ctls.Push(g.Add("Text", "x" px " y" (y + 3) " w" (lw - 8) " h20", f.label))
            cw := f.type = "num" ? 90 : 250
            if (f.type = "choice")
                f.choices := f.choices.Clone()   ; our own copy (CSetPut may add to it; QA_POSITIONS feeds the tray)
            if (f.type = "num")
                f.ctl := g.Add("Edit", "x" (px + lw) " y" y " w" cw " h26")
            else
                f.ctl := g.Add("DropDownList", "x" (px + lw) " y" y " w" cw, f.choices)
            f.ctls.Push(f.ctl)
            if (f.HasOwnProp("hint") && f.hint != "") {
                hx := px + lw + cw + 10
                f.ctls.Push(g.Add("Text", "x" hx " y" (y + 3) " w" (px + pw - hx) " h20 cGray", f.hint))
            }
            used := 34
        case "text":
            f.ctls.Push(g.Add("Text", "x" px " y" y " w" pw " h20", f.label))
            h := f.rows * 20 + 8
            f.ctl := g.Add("Edit", "x" px " y" (y + 24) " w" pw " h" h " Multi WantReturn VScroll")
            f.ctls.Push(f.ctl)
            used := 24 + h + 8
        case "buttons":
            bx := px
            for it in f.items {
                w := CSetButtonW(it[1])
                b := g.Add("Button", "x" bx " y" y " w" w " h28", it[1])
                b.OnEvent("Click", CSetRun.Bind(it[2]))
                f.ctls.Push(b)
                bx += w + 8
            }
            used := 36
        case "app":
            f.ctl := g.Add("CheckBox", "x" px " y" (y + 2) " w380 h24", f.label)
            f.ctls.Push(f.ctl)
            bx := px + 390
            for it in f.items {
                w := Max(100, CSetButtonW(it[1]))
                b := g.Add("Button", "x" bx " y" y " w" w " h28", it[1])
                b.OnEvent("Click", CSetRun.Bind(it[2]))
                f.ctls.Push(b)
                bx += w + 8
            }
            used := 38
        default:
            used := 0
    }
}

CSetButtonW(label) => Max(90, StrLen(StrReplace(label, "&&", "&")) * 8 + 24)

CSetShowSection(i) {
    global cSetSec
    try {
        cSetSec := i
        for f in cSetFieldList
            for c in f.ctls
                c.Visible := (f.sec = i)
        try IniWrite(i, MIC_INI, "Settings", "LastSection")
        SetTimer(() => (IsObject(cSetGui) ? RepaintWindow(cSetGui.Hwnd) : 0), -60)
    } catch as err {
        CSetReport(err)
    }
}

; A button: runs now; the status line then shows what the main window's status line says
CSetRun(fn, *) {
    try {
        fn()
        SetTimer(CSetMirrorStatus, -400)
    } catch as err {
        CSetReport(err)
    }
}

CSetMirrorStatus() {
    try {
        t := statusText.Text
        if (SubStr(t, 1, 8) = "Status: ")
            t := SubStr(t, 9)
        CSetStatus(t)
    }
}

CSetStatus(text) {
    try cSetGui["Status"].Value := text
}

; ------------------------------------------------------------------ values
CSetHasValue(f) => (f.type = "check" || f.type = "app" || f.type = "num" || f.type = "choice" || f.type = "text")

; What the control shows now, in the same form as f.orig
CSetRead(f) {
    switch f.type {
        case "check", "app": return f.ctl.Value ? 1 : 0
        case "choice":       return f.ctl.Text
        case "text":         return StrReplace(f.ctl.Value, "`r")
        default:             return Trim(f.ctl.Value)
    }
}

CSetPut(f, v) {
    switch f.type {
        case "check", "app":
            f.ctl.Value := v ? 1 : 0
        case "choice":
            pick := 0
            for i, c in f.choices
                if (c = String(v))
                    pick := i
            if !pick {                           ; a value not in the list (typed in the file): add it
                f.ctl.Add([String(v)])
                f.choices.Push(String(v))
                pick := f.choices.Length
            }
            f.ctl.Choose(pick)
        case "text":
            f.ctl.Value := StrReplace(v, "`n", "`r`n")
        default:
            f.ctl.Value := v
    }
}

; Fills in the current state (defaults = only this section's shipped values; they're saved on Save)
CSetFill(defaults) {
    for f in cSetFieldList {
        if !CSetHasValue(f)
            continue
        try {
            if defaults {
                if (f.sec = cSetSec)
                    CSetPut(f, f.def)
                continue
            }
            getFn := f.get                       ; (f.get() would pass f as a first parameter)
            v := getFn()
            if (f.type = "check" || f.type = "app")
                v := v ? 1 : 0
            CSetPut(f, v)
            f.orig := CSetRead(f)                ; what Save compares with
        } catch as err {
            CSetReport(err, f.key)
        }
    }
}

CSetDefaults() {
    CSetFill(true)
    CSetStatus("The shipped defaults of " StrReplace(CSET_SECTIONS[cSetSec], "&&", "&") " are filled in - press Save to keep them.")
}

CSetDirty() {
    if !IsObject(cSetGui)
        return false
    for f in cSetFieldList
        if (CSetHasValue(f) && f.HasOwnProp("orig") && !(CSetRead(f) == f.orig))
            return true
    return false
}

; "" = fine, else what's wrong
CSetCheck(f, v) {
    switch f.type {
        case "num":
            if !IsInteger(v)
                return "must be a whole number"
            if (Integer(v) < f.min || Integer(v) > f.max)
                return "must be from " f.min " to " f.max
        case "text":
            if (Trim(v, " `t`n") = "")
                return "can't be empty"
            if (f.HasOwnProp("need") && !InStr(v, f.need))
                return "must contain " f.need
    }
    return ""
}

; Checks everything first; then applies only what changed here. True if saved.
CSetSave() {
    try {
        problems := "", firstBad := 0
        for f in cSetFieldList {
            if !CSetHasValue(f)
                continue
            err := CSetCheck(f, CSetRead(f))
            if (err != "") {
                problems .= (problems = "" ? "" : "   ·   ") f.label ": " err
                if !firstBad
                    firstBad := f
            }
        }
        if (problems != "") {
            if (firstBad.sec != cSetSec) {
                cSetGui["Sections"].Choose(firstBad.sec)
                CSetShowSection(firstBad.sec)
            }
            CSetStatus("Not saved - " problems)
            return false
        }
        n := 0
        for f in cSetFieldList {
            if !CSetHasValue(f) || !f.HasOwnProp("orig")
                continue
            v := CSetRead(f)
            if (v == f.orig)
                continue
            try {
                if (f.type = "check" || f.type = "app") {
                    getFn := f.get, flipFn := f.flip  ; (f.get() would pass f as a first parameter)
                    if ((getFn() ? 1 : 0) != v)       ; the tray's own toggle: menus, starting/stopping follow
                        flipFn()
                } else {
                    setFn := f.set
                    setFn(v)
                }
                f.orig := v
                n += 1
            } catch as err {
                CSetReport(err, f.key)
            }
        }
        CSetStatus(n ? "Saved (" n " change" (n = 1 ? "" : "s") ")." : "Nothing changed.")
        if n
            statusText.Text := "Status: settings saved (" n " change" (n = 1 ? "" : "s") ")"
        return true
    } catch as err {
        CSetReport(err)
        return false
    }
}

; Closes the window; asks first if something isn't saved. False = stay open (Cancel).
CSetClose() {
    global cSetGui
    try {
        if !IsObject(cSetGui)
            return true
        if CSetDirty() {
            cSetGui.Opt("+OwnDialogs")
            r := MsgBox("Save your changes first?", "Settings", "YesNoCancel Icon?")
            if (r = "Cancel")
                return false
            if (r = "Yes" && !CSetSave())
                return false                     ; a value is wrong: the status line says which
        }
        cSetGui.Destroy()
    } catch as err {
        CSetReport(err)
    }
    cSetGui := 0
    return true
}

CSetReport(err, where := "") {
    msg := "Settings" (where != "" ? " (" where ")" : "") ": " err.Message
    try statusText.Text := "Status: " msg " (captions keep running)"
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "  [" err.What " line " err.Line "]`n", ERR_LOG, "UTF-8")
}
