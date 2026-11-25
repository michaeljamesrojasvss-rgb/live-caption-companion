; ==============================================================================
; auto-helpers.ahk  -  auto helpers: chosen helpers that follow the call by themselves
;                      in their own 💬 Copilot window (prefix Auto*).
;
; * Right-click a helper button > "Auto-run during calls". The choice is yours
;   (live-captions.ini [AutoHelpers] Ids=...), not stored in the helpers file.
;   Auto helpers show "⟳" in front of their name.
; * An auto helper only works in its own 💬 window (the one 💬 opens, see
;   copilot-pool-link.ahk), and only while that window is open (💬 is orange).
; * New call (New call or a 3CX ring): each auto helper opens its window by
;   itself - at its remembered place, without taking the focus - with a fresh
;   chat and the helper's full prompt (built like 🤖 builds it). A window that
;   is already open gets the same fresh chat + full prompt. Close a window
;   during the call and it stays closed until the next call (💬 opens it again).
; * Then, each time the customer pauses: a follow-up with what's new - any NEW
;   words in the captions (even a short "thank you"), and the verified info
;   once you stop typing it. Like pressing ^ yourself. When Live Captions only
;   polishes what was already sent (punctuation, a corrected word) nothing is
;   sent; the polished text goes along with the next real follow-up.
;   Timing: [AutoHelpers] MinChars / QuietMs / MinGapMs (defaults below).
; * One prompt at a time per window: the next waits until the previous one is
;   in Copilot (Copilot then answers them in order). 💬, ^ and auto share what
;   the window has seen (poolLinkHelperSeen), so nothing is sent twice.
; * Only while the Copilot pool is ready, and only for the live call. Nothing
;   goes to logs.
; Hooks: AutoInit() (after PoolLinkInit), AutoHelpersNewCall() (a new call),
; AutoIsOn(id), AutoHelperMenu(action) (right-click)
; ==============================================================================

AUTO_DEFAULTS := Map(
    "MinChars", 1,                  ; new customer text needed before a follow-up (1 = any change)
    "QuietMs", 1200,                ; customer silent this long = they finished talking
    "MinGapMs", 0,                  ; at least this long between follow-ups to one helper
    "FollowUpPrompt", "UPDATE FROM THE LIVE CALL\n{{new}}\n\nKeep following your instructions above, and give your updated answer for the whole conversation so far.")
autoState := Map()                  ; helper id -> see AutoFreshState()
autoOpenCall := ""                  ; the call started with New call / a ring: auto helpers open their windows for it

AutoInit() {
    try {
        SetTimer(AutoTick, 300)
    } catch as err {
        AutoReport(err)
    }
}

; ---- which helpers are auto ----
AutoIds() {
    ids := []
    try {
        for id in StrSplit(IniRead(MIC_INI, "AutoHelpers", "Ids", ""), ",", " `t")
            if (id != "")
                ids.Push(id)
    }
    return ids
}

AutoIsOn(id) {
    for x in AutoIds()
        if (x = Trim(id))
            return true
    return false
}

; The auto helpers that exist in the helpers file now, in its order
AutoHelpers() {
    list := []
    for a in helperActions
        if AutoIsOn(a["id"])
            list.Push(a)
    return list
}

AutoSetting(key) {
    def := AUTO_DEFAULTS.Get(key, "")
    try return IniRead(MIC_INI, "AutoHelpers", key, def)
    return def
}

AutoNum(key) {
    try return Integer(AutoSetting(key))
    return AUTO_DEFAULTS[key]
}

; ---- right-click menu on a helper's buttons ----
AutoHelperMenu(action) {
    try {
        id := Trim(action["id"])
        m := Menu()
        item := "Auto-run during calls (opens its 💬 window at each new call)"
        m.Add(item, (*) => AutoToggle(id))
        if AutoIsOn(id)
            m.Check(item)
        if !PoolLinkEnabled() {
            m.Add()
            m.Add("(needs the Copilot pool: tray > Copilot assist > Use the Copilot pool)", (*) => 0)
            m.Disable("(needs the Copilot pool: tray > Copilot assist > Use the Copilot pool)")
        }
        m.Show()
    } catch as err {
        AutoReport(err)
    }
}

AutoToggle(id) {
    try {
        ids := AutoIds()
        on := !AutoIsOn(id)
        out := ""
        for x in ids
            if (x != id)
                out .= (out = "" ? "" : ",") x
        if on
            out .= (out = "" ? "" : ",") id
        IniWrite(out, MIC_INI, "AutoHelpers", "Ids")
        RebuildHelperButtons()                       ; the ⟳ mark
        if autoState.Has(id)
            autoState.Delete(id)
        statusText.Text := on ? "Status: auto helper on - at each new call it opens its 💬 window and follows up by itself when the customer pauses"
            : "Status: auto helper off"
    } catch as err {
        AutoReport(err)
    }
}

; ---- a call ----
; sending state per helper: why (trace), retryAt (a failed try waits), lastSend, notesSeen / notesTick
; (the verified info and when you last changed it). What its window has seen is poolLinkHelperSeen.
AutoFreshState() {
    return {why: "", retryAt: 0, lastSend: 0, notesSeen: "", notesTick: 0, openedFor: ""}
}

AutoSt(id) {
    if !autoState.Has(id)
        autoState[id] := AutoFreshState()
    return autoState[id]
}

; Words in the captions, ignoring punctuation and symbols (so "ok" -> "Ok." is not a new word)
AutoWordCount(s) {
    RegExReplace(RegExReplace(s, "[\p{P}\p{S}]+", " "), "\S+", "", &n)
    return n
}

; Trace: why a helper is (not) sending right now - written only when the reason changes
AutoWhy(st, label, why) {
    if (st.why == why)
        return
    st.why := why
    if (why != "")
        DbgTrace("auto", "'" label "' " why)
}

; A new call started (New call button, or a 3CX ring). On the next ticks: auto helpers whose window is
; closed open it (without taking the focus) with the full prompt; open windows notice they hold an
; older call's chat and start a fresh one with the full prompt. A window you close during the call
; stays closed until the next call.
AutoHelpersNewCall() {
    global autoState, autoOpenCall
    try {
        autoState := Map()
        autoOpenCall := currentCall
        open := "", closed := ""
        for a in AutoHelpers() {
            if PoolLinkHelperOpen(a["id"])
                open .= (open = "" ? "" : ", ") "'" Trim(a["label"]) "'"
            else
                closed .= (closed = "" ? "" : ", ") "'" Trim(a["label"]) "'"
        }
        DbgTrace("auto", "NEW CALL - fresh chat in the open windows: " (open = "" ? "none" : open)
            "; opening: " (closed = "" ? "none" : closed))
    } catch as err {
        AutoReport(err)
    }
}

; This helper's window is closed and it should open it: a new call it hasn't opened for yet
AutoShouldOpen(a) {
    id := Trim(a["id"])
    st := AutoSt(id)
    return IsObject(autoOpenCall) && autoOpenCall == currentCall && !(st.openedFor == currentCall)
        && A_TickCount >= st.retryAt && !PoolLinkHelperBusy(id)
}

; Opens the helper's 💬 window (at its remembered place, without taking the focus) with its full prompt
AutoOpenWindow(a, full, notes) {
    id := Trim(a["id"]), label := Trim(a["label"])
    st := AutoSt(id)
    st.openedFor := currentCall                      ; once per call: if you close it, it stays closed
    st.lastSend := A_TickCount
    text := AssistBuildFull(a, full)
    snap := {text: full, notes: notes, call: currentCall}
    DbgTrace("auto", "'" label "' NEW CALL - opening its 💬 window with the full prompt (" StrLen(text) " chars)")
    h := {sent: PoolLinkHelperSent.Bind(id, snap), done: AutoDone.Bind(st, id, label, snap, true)}
    if (PoolLinkAsk(text, label, PoolLinkHelperConv(id), true, h, true, Map("orNew", 1, "quiet", 1)) = "") {
        st.openedFor := ""
        st.retryAt := A_TickCount + 3000
    } else {
        try PoolLinkPaintHelpers()
    }
}

; Every 300 ms: send what each auto helper's window needs, when it's a good moment
AutoTick() {
    static poolWait := false
    try {
        if !IsObject(currentCall)
            return
        list := [], toOpen := []
        for a in AutoHelpers() {
            if PoolLinkHelperOpen(a["id"])
                list.Push(a)
            else if AutoShouldOpen(a)
                toOpen.Push(a)
        }
        if (!list.Length && !toOpen.Length)
            return
        if !PoolLinkUsable() {                       ; starting / needs sign-in: wait
            if !poolWait
                DbgTrace("auto", "waiting: the Copilot pool isn't ready ("
                    (IsObject(poolLinkState) ? poolLinkState.Get("state", "?") " - " poolLinkState.Get("reason", "") : "no state yet") ")")
            poolWait := true
            return
        }
        if poolWait
            DbgTrace("auto", "the Copilot pool is ready again")
        poolWait := false
        full := AssistLiveTranscript()
        notes := Trim(currentCall.Get("agentNotes", ""), " `t`r`n")
        quiet := !(lastChatTick && A_TickCount - lastChatTick < AutoNum("QuietMs"))
        for a in toOpen
            AutoOpenWindow(a, full, notes)
        for a in list
            AutoTickHelper(a, full, notes, quiet)
    } catch as err {
        AutoReport(err)
    }
}

AutoTickHelper(a, full, notes, quiet) {
    id := Trim(a["id"])
    label := Trim(a["label"])
    if !autoState.Has(id)
        autoState[id] := AutoFreshState()
    st := autoState[id]
    if (notes !== st.notesSeen) {                    ; you're typing the verified info: wait until you pause
        st.notesSeen := notes
        st.notesTick := A_TickCount
    }
    if PoolLinkHelperBusy(id) {
        AutoWhy(st, label, "waiting: a prompt is on its way into its window")
        return
    }
    if (A_TickCount < st.retryAt) {
        AutoWhy(st, label, "waiting to retry (its last try didn't reach Copilot)")
        return
    }
    seen := poolLinkHelperSeen.Has(id) ? poolLinkHelperSeen[id] : ""
    if (!IsObject(seen) || !seen.HasOwnProp("call") || !(seen.call == currentCall)) {
        ; its window holds an older call's chat, or nothing yet: a fresh chat with the full prompt
        t := A_TickCount
        text := AssistBuildFull(a, full)
        AutoWhy(st, label, "")
        DbgTrace("auto", "'" label "' FULL prompt (fresh chat for this call) built in " (A_TickCount - t) " ms ("
            StrLen(text) " chars, captions " StrLen(full) " chars) - sending")
        AutoSend(a, st, text, true, {text: full, notes: notes, call: currentCall})
        return
    }
    notesChanged := (notes !== seen.notes) && (A_TickCount - st.notesTick >= AutoNum("QuietMs"))
    if (full !== seen.text && !notesChanged && AutoWordCount(full) <= AutoWordCount(seen.text)) {
        ; Live Captions only polished what Copilot already has (punctuation, a corrected word):
        ; it goes along with the next real follow-up
        seen.text := full
        AutoWhy(st, label, "idle: captions only corrected (no new words) - not sent")
        return
    }
    if (full == seen.text && !notesChanged) {
        AutoWhy(st, label, "idle: nothing new in the captions")
        return
    }
    fresh := Trim(AutoNewText(seen.text, full), " `t`r`n")
    if (StrLen(fresh) < AutoNum("MinChars") && !notesChanged) {
        AutoWhy(st, label, "waiting: fewer new chars than MinChars (" AutoNum("MinChars") ")")
        return
    }
    if !quiet {
        AutoWhy(st, label, "waiting: the customer is still talking")
        return
    }
    if (A_TickCount - st.lastSend < AutoNum("MinGapMs")) {
        AutoWhy(st, label, "waiting: MinGapMs since the last send")
        return
    }
    AutoWhy(st, label, "")
    DbgTrace("auto", "'" label "' FOLLOW-UP: " StrLen(fresh) " new chars" (notesChanged ? " + verified info changed" : "")
        ", customer quiet for " (lastChatTick ? A_TickCount - lastChatTick : -1) " ms - sending")
    AutoSend(a, st, AutoFollowUp(fresh, notes, notesChanged), false, {text: full, notes: notes, call: currentCall})
}

; What changed in the captions since Copilot last saw them: the new text at the end, or - when Live
; Captions corrected earlier words - everything from the start of the corrected line
AutoNewText(old, now) {
    if (old == "")
        return now
    if (SubStr(now, 1, StrLen(old)) == old)
        return SubStr(now, StrLen(old) + 1)
    n := Min(StrLen(old), StrLen(now)), p := 0
    while (p < n && SubStr(old, p + 1, 1) == SubStr(now, p + 1, 1))
        p += 1
    if (p = 0)
        return now
    lineStart := InStr(SubStr(now, 1, p), "`n", , -1)    ; the last line break before the change (0 = none)
    return SubStr(now, lineStart + 1)
}

AutoFollowUp(fresh, notes, notesChanged) {
    part := fresh != "" ? SpkChatNewLead() "`n" fresh : "(Nothing new from the customer.)"
    if (notesChanged && notes != "")
        part .= "`n`nUPDATED AGENT-VERIFIED INFORMATION (treat as correct; actions listed are already done):`n" notes
    tpl := StrReplace(AutoSetting("FollowUpPrompt"), "\n", "`n")
    if !InStr(tpl, "{{new}}")
        tpl := "{{new}}`n`n" tpl
    return NormalizeNewlines(StrReplace(tpl, "{{new}}", part))
}

; Into the helper's open 💬 window, without bringing it to the front. snap = what the window will
; have seen once this prompt is in (stored when the pool says it's in - shared with 💬 and ^).
AutoSend(a, st, text, newChat, snap) {
    id := Trim(a["id"]), label := Trim(a["label"])
    st.lastSend := A_TickCount
    h := {sent: PoolLinkHelperSent.Bind(id, snap), done: AutoDone.Bind(st, id, label, snap, false)}
    if (PoolLinkAsk(text, label, PoolLinkHelperConv(id), newChat, h, false, Map("respectDraft", 1)) = "")   ; never over your own typing
        st.retryAt := A_TickCount + 3000
}

AutoDone(st, id, label, snap, opening, m) {
    DbgTrace("auto", "'" label "' prompt finished: " (m.Get("ok", 0) ? "answered" : m.Get("kind", "") " - " m.Get("error", ""))
        ", " (A_TickCount - st.lastSend) " ms after sending")
    if m.Get("ok", 0)
        return
    kind := m.Get("kind", "")
    if (kind = "lost") {                             ; its chat started over (page reloaded): the full prompt again
        if poolLinkHelperSeen.Has(id)
            poolLinkHelperSeen.Delete(id)
        return
    }
    if PoolLinkNeverSent(kind) {                     ; never reached Copilot: try again in a moment
        st.retryAt := A_TickCount + 3000
        if (opening && kind != "busy")               ; its window didn't open: open it again ("busy" = no room: give up)
            st.openedFor := ""
        return
    }
    poolLinkHelperSeen[id] := snap                   ; it may have reached Copilot: never send it again
    AssistLog("auto helper '" label "': " kind)
}

AutoReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: auto helpers problem (captions unaffected): " msg
    try AssistLog("auto helpers ERROR: " msg)
}
