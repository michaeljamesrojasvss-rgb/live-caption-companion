; ==============================================================================
; q-alert.ahk  -  "3CX is not logged in to Q" toast for Live Caption Companion
;
;   * q-watch.ahk (its own process) checks 3CX and its Q icon on an interval (on every virtual
;     desktop) and tells us "on" / "off" / "no3cx" / "unknown". "off" and "no3cx" (3CX not running or
;     its window closed - it must always be open during work) show a toast.
;   * Settings: tray icon > 3CX Q-login alert   (or right-click a toast)
;       - alert on / off
;       - Toast position (6 screen spots, or next to the 3CX window)
;       - Toast duration, Max toasts at once (they stack), Check every N seconds
;         (each has presets and Custom...)
;     Stored in data\live-captions.ini, section [QAlert]:
;       Enabled=1  Position=Bottom right  ToastSeconds=5  MaxToasts=3  IntervalSec=10  SnoozeMinutes=5
;       ElementId= / ElementName= / MinBlue=   (see q-watch.ahk)
;   * Snooze: every toast has a "Snooze N min" button (also tray > 3CX Q-login alert > Snooze the alert now)
;     for extra after-call work: no Q toasts for SnoozeMinutes (default 5). It ends by itself, or at once with
;     "Alert back on now". A snooze isn't saved: closing the Companion ends it.
;   * Toasts never take focus; clicking one closes it.
;   * Nothing here clicks or types into 3CX.
; Hooks called from liveCaptionCompanion.ahk: QAlertInit(), QAlertShutdown()
; ==============================================================================

QA_TAG := 0x3CC1
QA_ITEM_ON := "Alert when 3CX is not open or not logged in to Q"
QA_ITEM_SNOOZE := "Snooze the alert now (extra after-call work)"
QA_ITEM_RESUME := "Alert back on now"
QA_POSITIONS := ["Top left", "Top center", "Top right", "Bottom left", "Bottom center", "Bottom right", "Near the 3CX window"]
QA_DEFAULT_POS := "Bottom right"
; key -> [menu title, preset values, unit label, default, min, max]
QA_CHOICES := Map(
    "ToastSeconds", ["Toast duration", [3, 5, 10, 15, 30], "seconds", 5, 2, 300],
    "MaxToasts",    ["Max toasts at once", [1, 2, 3, 5, 10], "", 3, 1, 10],
    "IntervalSec",  ["Check every", [5, 10, 15, 30, 60], "seconds", 10, 3, 3600],
    "SnoozeMinutes", ["Snooze length", [2, 5, 10, 15, 30], "minutes", 5, 1, 120])
qaWatchPid := 0
qaSnoozeUntil := 0              ; A_TickCount until which the alert is snoozed (0 = not snoozed)
qaToasts := []
qaMenu := ""
qaPosMenu := ""
qaChoiceMenus := Map()

QAlertSetting(key, default := "") {
    try return IniRead(MIC_INI, "QAlert", key, default)
    return default
}

; Whole-number setting kept inside its allowed range
QAInt(key) {
    c := QA_CHOICES[key]
    v := QAlertSetting(key, c[4])
    if !IsInteger(v)
        return c[4]
    return Min(c[6], Max(c[5], Integer(v)))
}

QAlertInit() {
    try {
        QABuildMenu()
        OnMessage(0x4A, QAOnCopyData)            ; WM_COPYDATA from q-watch.ahk (own tag)
        if (QAlertSetting("Enabled", 1) = "1")
            QAStartWatcher()
    } catch as err {
        QALog("start error: " err.Message)
    }
}

QAlertShutdown() {
    try QAStopWatcher()
    try QAHideAll()
}

; ------------------------------------------------------------------ menu
QABuildMenu() {
    global qaMenu, qaPosMenu
    qaPosMenu := Menu()
    for p in QA_POSITIONS
        qaPosMenu.Add(p, QAPickPosition)
    m := Menu()
    m.Add(QA_ITEM_ON, QAToggle)
    m.Add(QA_ITEM_SNOOZE, QASnooze)
    m.Add(QA_ITEM_RESUME, QAResume)
    m.Add()
    m.Add("Toast position", qaPosMenu)
    for key in ["ToastSeconds", "MaxToasts", "IntervalSec", "SnoozeMinutes"]
        QAAddChoice(m, key)
    m.Add()
    m.Add("Show a test toast", (*) => QAShowToast(true))
    m.Add("Open log", (*) => Run('notepad.exe "' CALLER_LOG '"'))
    qaMenu := m
    A_TrayMenu.Insert("1&", "3CX Q-login alert", m)
    QASyncMenu()
}

QAAddChoice(parent, key) {
    c := QA_CHOICES[key]
    sub := Menu()
    for v in c[2]
        sub.Add(QAChoiceLabel(key, v), QAPickValue.Bind(key, v))
    sub.Add()
    sub.Add("Custom…", QACustomValue.Bind(key))
    parent.Add(c[1], sub)
    qaChoiceMenus[key] := sub
}

QAChoiceLabel(key, v) {
    u := QA_CHOICES[key][3]
    return v (u != "" ? " " u : "")
}

QASyncMenu() {
    if !IsObject(qaMenu)
        return
    if (QAlertSetting("Enabled", 1) = "1")
        qaMenu.Check(QA_ITEM_ON)
    else
        qaMenu.Uncheck(QA_ITEM_ON)
    if QASnoozed()
        qaMenu.Enable(QA_ITEM_RESUME)
    else
        qaMenu.Disable(QA_ITEM_RESUME)
    cur := QAlertSetting("Position", QA_DEFAULT_POS)
    for p in QA_POSITIONS {
        if (p = cur)
            qaPosMenu.Check(p)
        else
            qaPosMenu.Uncheck(p)
    }
    for key, sub in qaChoiceMenus {
        now := QAInt(key)
        hit := false
        for v in QA_CHOICES[key][2] {
            if (v = now) {
                sub.Check(QAChoiceLabel(key, v))
                hit := true
            } else
                sub.Uncheck(QAChoiceLabel(key, v))
        }
        if hit
            sub.Uncheck("Custom…")
        else
            sub.Check("Custom…")
    }
}

; ------------------------------------------------------------------ snooze (extra after-call work)
QASnoozed() => (qaSnoozeUntil && A_TickCount < qaSnoozeUntil)

QASnooze(*) {
    global qaSnoozeUntil
    mins := QAInt("SnoozeMinutes")
    qaSnoozeUntil := A_TickCount + mins * 60000
    SetTimer(QASnoozeEnded, -mins * 60000)
    QAHideAll()
    QASyncMenu()
    try statusText.Text := "Status: 3CX Q alert snoozed for " mins " min (tray > 3CX Q-login alert > Alert back on now)"
    QALog("snoozed for " mins " min")
}

QAResume(*) {
    global qaSnoozeUntil
    qaSnoozeUntil := 0
    SetTimer(QASnoozeEnded, 0)
    QASyncMenu()
    try statusText.Text := "Status: 3CX Q alert is back on"
    QALog("snooze ended by hand")
}

QASnoozeEnded() {
    global qaSnoozeUntil
    qaSnoozeUntil := 0
    QASyncMenu()
    try statusText.Text := "Status: 3CX Q alert is back on"
    QALog("snooze ended")
}

QAToggle(*) {
    on := (QAlertSetting("Enabled", 1) != "1")
    try IniWrite(on ? 1 : 0, MIC_INI, "QAlert", "Enabled")
    QASyncMenu()
    if on
        QAStartWatcher()
    else {
        QAStopWatcher()
        QAHideAll()
    }
    try statusText.Text := "Status: 3CX Q-login alert is now " (on ? "on" : "off")
}

QAPickPosition(name, *) {
    try IniWrite(name, MIC_INI, "QAlert", "Position")
    QASyncMenu()
    QAShowToast(true)                            ; show it right away so the spot can be judged
}

QAPickValue(key, v, *) {
    QASaveValue(key, v)
}

QACustomValue(key, *) {
    c := QA_CHOICES[key]
    r := InputBox(c[1] " (" c[5] " to " c[6] (c[3] != "" ? ", " c[3] : "") "):", "3CX Q alert", "w300 h130", QAInt(key))
    if (r.Result != "OK")
        return
    if (!IsInteger(r.Value) || Integer(r.Value) < c[5] || Integer(r.Value) > c[6]) {
        MsgBox("Please type a whole number from " c[5] " to " c[6] ".", "3CX Q alert", "Iconx")
        return
    }
    QASaveValue(key, Integer(r.Value))
}

QASaveValue(key, v) {
    try IniWrite(v, MIC_INI, "QAlert", key)
    QASyncMenu()
    if (key = "MaxToasts")
        QATrim()
    if (key = "IntervalSec" && QAlertSetting("Enabled", 1) = "1")
        QAStartWatcher()                         ; new interval takes effect now
    try statusText.Text := "Status: 3CX Q-login alert - " QA_CHOICES[key][1] " is now " QAChoiceLabel(key, v)
}

; ------------------------------------------------------------------ events from q-watch.ahk
QAOnCopyData(wParam, lParam, msg, hwnd) {
    if (hwnd != myGui.Hwnd)
        return
    try {
        if (NumGet(lParam, 0, "UPtr") != QA_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(QAHandle.Bind(text), -1)            ; reply to the watcher right away
    return true
}

QAHandle(text, *) {
    try {
        p := StrSplit(text, "`t")
        if (p.Length < 2 || p[1] != "q")
            return
        if (QAlertSetting("Enabled", 1) != "1") {
            QAHideAll()
            return
        }
        if ((p[2] = "off" || p[2] = "no3cx") && QASnoozed()) {
            QAHideAll()                          ; snoozed: the next check after the snooze brings it back
            return
        }
        if (p[2] = "off")
            QAShowToast(false, "⚠ 3CX is not logged in to Q")
        else if (p[2] = "no3cx")                 ; 3CX must always be open during work
            QAShowToast(false, "⚠ " (p.Length >= 3 && p[3] != "" ? p[3] : "3CX is not open"),
                "Open 3CX - it must stay on during work.")
        else
            QAHideAll()
    } catch as err {
        QALog("event error: " err.Message)
    }
}

; ------------------------------------------------------------------ toasts (stack, newest at the screen edge)
QAShowToast(isTest, title := "", hint := "Open 3CX and log in to the queue.") {
    s := A_ScreenDPI / 96
    w := Round(410 * s)
    h := Round(64 * s)
    if (!isTest && StrLen(title) > 34)          ; a longer warning: two lines for the title
        h := Round(84 * s)
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale +E0x08000000", "3CX Q alert")
    g.BackColor := "3B1219"
    g.SetFont("s11 cFECACA", "Segoe UI")
    t := FormatTime(, "h:mm:ss tt")
    txt := g.Add("Text", Format("x{} y{} w{} h{} +0x100", Round(12 * s), Round(10 * s), w - Round(24 * s) - Round(104 * s), h - Round(20 * s))
        , isTest ? "Test toast (" t ")`nClick to close, right-click for settings."
                 : title "  (" t ")`n" hint)
    snz := g.Add("Button", Format("x{} y{} w{} h{}", w - Round(12 * s) - Round(92 * s), (h - Round(34 * s)) // 2, Round(92 * s), Round(34 * s))
        , "Snooze " QAInt("SnoozeMinutes") " min")
    snz.OnEvent("Click", (*) => QASnooze())      ; (the toast never takes focus: typing isn't disturbed)
    item := Map("gui", g, "w", w, "h", h)
    item["timer"] := QARemoveToast.Bind(item)
    txt.OnEvent("Click", item["timer"])
    g.OnEvent("ContextMenu", (*) => qaMenu.Show())
    qaToasts.Push(item)
    QATrim()
    QARestack()
    SetTimer(item["timer"], -QAInt("ToastSeconds") * 1000)
}

; Drops the oldest toasts above MaxToasts
QATrim() {
    while (qaToasts.Length > QAInt("MaxToasts"))
        QARemoveToast(qaToasts[1])
    QARestack()
}

QARemoveToast(item, *) {
    for i, it in qaToasts {
        if (it == item) {
            qaToasts.RemoveAt(i)
            break
        }
    }
    try SetTimer(item["timer"], 0)
    try item["gui"].Destroy()
    QARestack()
}

QAHideAll() {
    while (qaToasts.Length)
        QARemoveToast(qaToasts[1])
}

QARestack() {
    n := qaToasts.Length
    for i, it in qaToasts {
        k := n - i                               ; 0 = newest, sits at the anchor spot
        QAPlace(&x, &y, &down, it["w"], it["h"])
        gap := Round(8 * A_ScreenDPI / 96)
        y += (down ? 1 : -1) * k * (it["h"] + gap)
        try it["gui"].Show(Format("NA x{} y{} w{} h{}", x, y, it["w"], it["h"]))
    }
}

; Anchor spot for the newest toast; down = later toasts stack downward (else upward)
QAPlace(&x, &y, &down, w, h) {
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    m := 16
    x := r - w - m
    y := b - h - m
    down := false
    switch QAlertSetting("Position", QA_DEFAULT_POS) {
        case "Top left":      x := l + m, y := t + m, down := true
        case "Top center":    x := l + (r - l - w) // 2, y := t + m, down := true
        case "Top right":     x := r - w - m, y := t + m, down := true
        case "Bottom left":   x := l + m, y := b - h - m
        case "Bottom center": x := l + (r - l - w) // 2, y := b - h - m
        case "Near the 3CX window":
            down := true
            y := t + m
            try {
                WinGetPos(&wx, &wy, &ww, &wh, CALLER_3CX)
                x := wx - w - 8
                y := wy + 8
                if (x < l)
                    x := wx + ww + 8
                if (x + w > r)
                    x := r - w - m
            }
    }
}

; ------------------------------------------------------------------ watcher process
QAStartWatcher() {
    global qaWatchPid
    QAStopWatcher()
    path := A_ScriptDir "\q-watch.ahk"
    if !FileExist(path) {
        try statusText.Text := "Status: q-watch.ahk not found - Q alert is off (captions unaffected)"
        return
    }
    Run(Format('"{}" "{}" {} {} "{}" "{}"', A_AhkPath, path, myGui.Hwnd, QAInt("IntervalSec"), CALLER_LOG, MIC_INI)
        , A_ScriptDir, , &pid)
    qaWatchPid := pid
}

QAStopWatcher() {
    global qaWatchPid
    if (qaWatchPid && ProcessExist(qaWatchPid))
        try ProcessClose(qaWatchPid)
    qaWatchPid := 0
}

QALog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  [q-alert] " line "`n", CALLER_LOG, "UTF-8")
}
