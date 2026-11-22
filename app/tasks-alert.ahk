; ==============================================================================
; tasks-alert.ahk  -  "time's up" alerts for tasks.ahk (included by it)
;
; * One alert per task whose timer ran out. It stays until you choose:
;     Done           tick the task
;     After my call  for when it pops up while you're busy: it goes away and
;                    comes back once your call ends (or after a few minutes if
;                    you weren't on a call), so you can do the next step then
;     Open           show the task, and its linked item in its app (the
;                    Companion opens the call in review). The alert stays.
;     Hide           close the popup only: the timer stays, shown as overdue at
;                    the top of Up next, and the alert comes back every
;                    RemindHiddenMin minutes. Only Done / Stop (in Tasks) end it.
;     Snooze …       run the timer again for that long (lengths from settings)
;     🔗 Open link   only when its checklist has a link in a note (e.g. the case)
; * Same kind of window as the Companion's other toasts: always on top, never
;   takes focus, and a tool window, so it shows on every virtual desktop.
; * Several alerts stack from the chosen corner. Everything is in Tasks > ⚙
;   (data\tasks.ini [Settings]); "Save & test alert" shows a sample.
; ==============================================================================

TALERT_POSITIONS := ["Top left", "Top center", "Top right", "Bottom left", "Bottom center", "Bottom right"]
TALERT_TEST_ID := "test-alert"
talertToasts := Map()        ; task id -> Gui
talertOrder := []            ; task ids, oldest first (stacking order)
talertLastSound := 0
talertTestNode := ""         ; the sample task shown by "test alert"

TAlertShown(id) {
    return talertToasts.Has(id)
}

; quiet: don't play the sound (redrawing after a settings change)
TAlertShow(n, quiet := false) {
    global talertLastSound
    id := n["id"]
    if talertToasts.Has(id)
        return
    try {
        w := TaskSettingInt("ToastWidth", 300, 800)
        inner := "w" (w - 24)
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale +E0x08000000", "Task alert")
        g.BackColor := "2A2410"
        g.MarginX := 12
        g.MarginY := 10
        g.SetFont("s9 bold cFBBF24", "Segoe UI")
        g.Add("Text", inner, "⏰  TIME'S UP")
        g.SetFont("s11 bold cF1F5FB")
        t := g.Add("Text", inner " y+4", TaskTitle(n))
        t.OnEvent("Click", TAlertAction.Bind(id, "open"))
        sub := TAlertContext(n)
        g.SetFont("s9 norm cC9D1DC")
        if (sub != "")
            g.Add("Text", inner " y+2", sub)
        g.SetFont("s9 norm c000000")
        ; a link anywhere in its checklist (e.g. the case): one click from the alert
        links := TaskLinksAround(n)
        if links.Length {
            txt := (links.Length = 1) ? "🔗  Open link  (" links[1].title ")" : "🔗  Open a link (" links.Length ")"
            lb := g.Add("Button", "xm y+8 h26 " inner, txt)
            lb.OnEvent("Click", TAlertAction.Bind(id, "link"))
            TipSet(lb, "Open the link found in this task's checklist")
        }
        bw := (w - 24 - 3 * 6) // 4
        opt := "h26 w" bw
        for b in [["xm y+10 ", "✓ Done", "done", "Tick the task done and close this alert"]
                , ["x+6 ", "After my call", "after", "Hide it while you're busy; it comes back a little after"]
                , ["x+6 ", "Open", "open", "Show this task in the Tasks window"]
                , ["x+6 ", "Hide", "hide", "Close this alert; the timer stays overdue (Settings: whether it reminds you again)"]] {
            ab := g.Add("Button", b[1] opt, b[2])
            ab.OnEvent("Click", TAlertAction.Bind(id, b[3]))
            TipSet(ab, b[4])
        }
        snoozes := TaskDurationList(TaskSetting("SnoozeMinutes"), 6)
        if snoozes.Length {
            g.SetFont("s9 norm cC9D1DC")
            g.Add("Text", "xm y+8 w58 h24 +0x200", "Snooze")
            g.SetFont("s9 norm c000000")
            sw := Max(40, (w - 24 - 64 - (snoozes.Length - 1) * 6) // snoozes.Length)
            for i, secs in snoozes {
                sb := g.Add("Button", "x+6 yp h24 w" sw, TaskDurLabel(secs))
                sb.OnEvent("Click", TAlertSnooze.Bind(id, secs))
                TipSet(sb, "Remind me again in " TaskDurLabel(secs))
            }
        }
        g.Show("Hide AutoSize")
        talertToasts[id] := g
        talertOrder.Push(id)
        TAlertRestack()
        if !quiet {
            TAlertPlaySound()
            talertLastSound := A_TickCount
            TaskLog("alert: " TaskPath(n))
        }
    } catch as err {
        TaskLog("alert could not be shown: " err.Message)
    }
}

; "Parent task · linked item" under the title
TAlertContext(n) {
    parts := []
    p := TaskParentOf(n)
    if IsObject(p)
        parts.Push(TaskTitle(p))
    l := TaskLinkLabel(n)
    if (l != "")
        parts.Push(l)
    out := ""
    for s in parts
        out .= (out = "" ? "" : "   ·   ") s
    return out
}

TAlertRestack() {
    if !talertOrder.Length
        return
    try {
        pos := TaskSetting("Position")
        MonitorGetWorkArea(MonitorGetPrimary(), &L, &T, &R, &B)
        offset := 0
        for id in talertOrder {
            g := talertToasts[id]
            g.GetPos(, , &gw, &gh)
            if InStr(pos, "left")
                x := L + 12
            else if InStr(pos, "center")
                x := L + (R - L - gw) // 2
            else
                x := R - gw - 12
            y := InStr(pos, "Top") ? T + 12 + offset : B - 12 - gh - offset
            g.Show("NoActivate x" x " y" y)
            offset += gh + 8
        }
    } catch as err {
        TaskLog("alert placement problem: " err.Message)
    }
}

TAlertClose(id) {
    if !talertToasts.Has(id)
        return
    try talertToasts[id].Destroy()
    talertToasts.Delete(id)
    for i, x in talertOrder
        if (x = id) {
            talertOrder.RemoveAt(i)
            break
        }
    TAlertRestack()
}

TAlertCloseAll() {
    for id, g in talertToasts
        try g.Destroy()
    talertToasts.Clear()
    talertOrder.Length := 0
}

; After a settings change: redraw the open alerts with the new look and place
TAlertRefreshAll() {
    ids := talertOrder.Clone()
    TAlertCloseAll()
    for id in ids {
        n := (id = TALERT_TEST_ID) ? talertTestNode : taskById.Get(id, "")
        if IsObject(n)
            TAlertShow(n, true)
    }
}

; A sample alert (settings > Save & test alert). Its buttons just close it.
TAlertTest() {
    global talertTestNode
    TAlertClose(TALERT_TEST_ID)
    talertTestNode := TaskNewNode("Test alert - this is how a timer alert looks")
    talertTestNode["id"] := TALERT_TEST_ID
    TAlertShow(talertTestNode)
}

TAlertAction(id, action, *) {
    n := taskById.Get(id, "")
    if !IsObject(n) {
        TAlertClose(id)                      ; a test alert, or the task was deleted
        return
    }
    switch action {
        case "done":    TaskSetDone(n, true)
        case "after":   TaskSnoozeAfterCall(n)
        case "open":    TaskOpenTaskAndLink(id)
        case "hide":    TaskHideAlert(n)         ; the timer stays (overdue)
        case "link":    TaskOpenLinks(n)         ; the alert stays
    }
}

TAlertSnooze(id, seconds, *) {
    n := taskById.Get(id, "")
    if IsObject(n)
        TaskSnooze(n, seconds)
    else
        TAlertClose(id)
}

; Called every second: repeats the sound while alerts are up
TAlertSoundTick() {
    global talertLastSound
    if !talertOrder.Length
        return
    every := TaskSettingInt("RepeatSoundSec", 0, 3600)
    if (every > 0 && A_TickCount - talertLastSound >= every * 1000) {
        TAlertPlaySound()
        talertLastSound := A_TickCount
    }
}

; file: a .wav to test; "" = the one in settings (or the Windows sound)
TAlertPlaySound(file := "") {
    if (TaskSetting("Sound") != "1" && file = "")
        return
    if (file = "")
        file := Trim(TaskSetting("SoundFile"))
    try {
        if (file != "" && FileExist(file))
            SoundPlay(file)
        else
            SoundPlay("*48")
    }
}
