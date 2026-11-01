; ==============================================================================
; history-window.ahk  -  Call history window, with "Delete selected…" and
; "Import & merge…" (calls and helpers from another copy - import-merge.ahk)
;
; Several calls can be picked at once (Ctrl+click, Shift+click, "Select all",
; "Select today") and deleted together.
;
; Replaces ShowHistoryWindow from liveCaptionCompanion.ahk: delete (or comment
; out) the old ShowHistoryWindow function there, then #Include this file.
;
; Deleting is careful:
;   * asks first, with the number of calls and their dates shown
;   * the live call is never deleted (Discard call in the main window does that)
;   * if you are reviewing a deleted call, the main window goes back to the live call
;   * call-history.backup.json keeps the history from just before the delete,
;     so a mistaken delete can be undone by restoring that file
;   * if the history file couldn't be loaded, nothing can be deleted
; ==============================================================================

ShowHistoryWindow(*) {
    global historyGui
    if !(history is Map) {
        statusText.Text := "Status: call history is still loading - try again in a moment"
        return
    }
    PersistCurrentCall()

    if IsObject(historyGui) {
        try historyGui.Destroy()
    }

    sessions := []                      ; newest first, rebuilt by Refill()

    hg := Gui("+Owner" myGui.Hwnd, "Call history")
    hg.BackColor := "11151D"
    hg.SetFont("s10 cF1F5FB", "Segoe UI")
    lb := hg.Add("ListBox", "w360 r18 Multi Background1B2431 cF1F5FB")
    details := hg.Add("Edit", "x+10 w560 r18 ReadOnly +0x100 Background1B2431 cF1F5FB")
    hStatus := hg.Add("Text", "xm w920 c9BA8BA", "")
    btnCopyDetails := hg.Add("Button", "w110", "Copy details")
    btnViewMain := hg.Add("Button", "x+10 w160", "View in main window")
    btnSelAll := hg.Add("Button", "x+10 w90", "Select all")
    btnSelToday := hg.Add("Button", "x+10 w100", "Select today")
    btnDelete := hg.Add("Button", "x+10 w130", "Delete selected…")
    btnImport := hg.Add("Button", "x+10 w150", "Import && merge…")
    btnCloseHist := hg.Add("Button", "x+10 w80", "Close")

    state := {text: ""}

    Refill(selectIdx := 1) {
        src := history["sessions"]
        sessions.Length := 0
        Loop src.Length
            sessions.Push(src[src.Length - A_Index + 1])
        items := []
        for s in sessions
            items.Push(SessionTitle(s) "  ·  " SessionSummary(s))
        lb.Delete()
        if items.Length
            lb.Add(items)
        hStatus.Text := sessions.Length " saved call(s)"
        if (sessions.Length > 0)
            SetSel(Min(Max(selectIdx, 1), sessions.Length), true)
        ShowSelected()
    }

    ; LB_SETSEL: idx 0 = every item
    SetSel(idx, on) {
        SendMessage(0x0185, on, idx - 1, lb)
    }

    Picked() {
        v := lb.Value
        return (v is Array) ? v : (v ? [v] : [])
    }

    ; The one picked call, or "" (with a hint) when none or several are picked
    PickedOne(what) {
        p := Picked()
        if (p.Length = 1)
            return sessions[p[1]]
        hStatus.Text := (p.Length = 0) ? "Select a call first" : "Select just one call to " what
        return ""
    }

    ShowSelected() {
        p := Picked()
        state.text := ""
        if (p.Length = 0) {
            details.Value := ""
            return
        }
        if (p.Length = 1) {
            state.text := BuildDetails(sessions[p[1]])
            details.Value := state.text
            return
        }
        lines := 0, prompts := 0
        for i in p {
            lines += sessions[i]["transcriptLines"].Length
            prompts += sessions[i]["preparedPrompts"].Length
        }
        details.Value := p.Length " calls selected  (" DateRangeText(p) ")`r`n`r`n"
            . lines " transcript line(s), " prompts " prompt(s) in total.`r`n`r`n"
            . "Delete selected… removes them all at once. Pick just one call to see or copy its details."
    }

    ; "Oct 27 – Oct 30" (or one date) for the picked calls; sessions are newest first
    DateRangeText(p) {
        first := IsoToLocal(sessions[p[p.Length]]["startedAtUtc"], "MMM d")
        last := IsoToLocal(sessions[p[1]]["startedAtUtc"], "MMM d")
        return (first = last) ? first : first " – " last
    }

    SelectAll() {
        if (sessions.Length = 0)
            return
        SetSel(0, true)
        ShowSelected()
        hStatus.Text := sessions.Length " call(s) selected"
    }

    SelectToday() {
        today := FormatTime(, "yyyyMMdd")
        SetSel(0, false)
        n := 0
        for i, s in sessions {
            if (IsoToLocal(s["startedAtUtc"], "yyyyMMdd") = today) {
                SetSel(i, true)
                n += 1
            }
        }
        ShowSelected()
        hStatus.Text := n ? n " call(s) from today selected" : "No calls from today"
    }

    CopyDetails() {
        if !IsObject(PickedOne("copy its details"))
            return
        if (Trim(state.text) = "") {
            hStatus.Text := "Select a call to copy its details"
            return
        }
        A_Clipboard := state.text
        hStatus.Text := "Call details copied"
    }

    ViewInMain() {
        one := PickedOne("view it")
        if !IsObject(one)
            return
        hg.Destroy()
        EnterReview(one)
        WinActivate("ahk_id " myGui.Hwnd)
    }

    DeleteSelected() {
        p := Picked()
        if (p.Length = 0) {
            hStatus.Text := "Select the call(s) to delete"
            return
        }
        if !historyAvailable {
            hStatus.Text := "Call history couldn't be loaded (" historyLoadError "), so nothing can be deleted right now"
            return
        }
        doomed := [], skippedLive := false
        for i in p {
            if (sessions[i] == currentCall)
                skippedLive := true
            else
                doomed.Push(sessions[i])
        }
        if (doomed.Length = 0) {
            hStatus.Text := "That's the live call - use Discard call in the main window to throw it away"
            return
        }
        hg.Opt("+OwnDialogs")
        what := (doomed.Length = 1)
            ? "Delete this call permanently?`n`n" SessionTitle(doomed[1]) "`n" SessionSummary(doomed[1])
            : "Delete " doomed.Length " calls permanently?`n`n" DateRangeText(p)
        if skippedLive
            what .= "`n`n(The live call is skipped - use Discard call in the main window for that.)"
        answer := MsgBox(what
            . "`n`nA copy of the history from just before this delete is kept in call-history.backup.json."
            , "Delete calls", "YesNo Icon! Default2")
        if (answer != "Yes")
            return
        try FileCopy(HISTORY_PATH, HISTORY_DIR "\call-history.backup.json", true)
        gone := Map()
        for s in doomed {
            gone[s] := true
            if (IsObject(reviewCall) && s == reviewCall)
                ExitReview()
        }
        src := history["sessions"]
        i := src.Length
        while (i >= 1) {
            if gone.Has(src[i])
                src.RemoveAt(i)
            i -= 1
        }
        SaveHistory()
        Refill(p[1])
        hStatus.Text := doomed.Length " call(s) deleted  ·  " hStatus.Text
    }

    lb.OnEvent("Change", (*) => ShowSelected())
    lb.OnEvent("DoubleClick", (*) => ViewInMain())
    btnViewMain.OnEvent("Click", (*) => ViewInMain())
    btnCopyDetails.OnEvent("Click", (*) => CopyDetails())
    btnSelAll.OnEvent("Click", (*) => SelectAll())
    btnSelToday.OnEvent("Click", (*) => SelectToday())
    btnDelete.OnEvent("Click", (*) => DeleteSelected())
    btnImport.OnEvent("Click", (*) => (hg.Destroy(), MergeImportStart()))
    btnCloseHist.OnEvent("Click", (*) => hg.Destroy())
    hg.OnEvent("Close", (*) => hg.Destroy())

    historyGui := hg
    hg.Show()
    Refill(1)
}
