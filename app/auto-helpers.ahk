; ==============================================================================
; auto-helpers.ahk  -  auto helpers: chosen helpers that run by themselves during a call
;                      (prefix Auto*). Design: docs\COPILOT-POOL.md > "Auto helpers".
;
; * Right-click a helper button > "Auto-run during calls". The choice is yours
;   (live-captions.ini [AutoHelpers] Ids=...), not stored in the helpers file.
;   Auto helpers show "⟳" in front of their name.
; * Each auto helper has its own dedicated Copilot page in the Copilot pool (a
;   "board page", separate from the 💬 pages), opened ahead of time. They are
;   shown together in the pool's "Live helpers" window, side by side, each
;   following its newest answer. You can type into them too.
; * When a new call starts (New call, or a 3CX ring): every auto helper's page
;   gets a fresh chat and the helper's full prompt (built like 🤖 builds it).
;   Then, each time the customer pauses, what's new is sent - any change in the
;   captions, even a short "thank you" or a corrected word, and the verified
;   info if you changed it - as one follow-up.
;   Timing: [AutoHelpers] MinChars / QuietMs / MinGapMs (defaults below).
; * Aggressive: the newest prompt always wins. If Copilot is still writing an
;   answer, it is stopped and the new follow-up goes at once; whatever is in
;   the helper page's input box is replaced. Only a follow-up waits until the
;   call's first (full) prompt is in, so Copilot never misses the context.
; * Only while the Copilot pool is on and ready, and only for the live call
;   (not while reviewing an old one). Never sends a prompt twice. Nothing goes
;   to logs.
; * ⚡ auto-assist and ➤ Ask are retired (their buttons are gone); auto helpers replace them.
; Hooks: AutoInit() (after PoolLinkInit), AutoHelpersNewCall() (a new call),
; AutoIsOn(id), AutoHelperMenu(action) (right-click), AutoOnPoolState(state)
; ==============================================================================

AUTO_DEFAULTS := Map(
    "MinChars", 1,                  ; new customer text needed before a follow-up (1 = any change)
    "QuietMs", 1200,                ; customer silent this long = they finished talking
    "MinGapMs", 0,                  ; at least this long between follow-ups to one helper
    "FollowUpPrompt", "UPDATE FROM THE LIVE CALL\n{{new}}\n\nKeep following your instructions above, and give your updated answer for the whole conversation so far.")
AUTO_TITLE := "Live helpers"
AUTO_ITEM_WINDOW := "Live helpers window (auto helpers)..."
autoCallRef := ""                   ; the live call the auto helpers are working on ("" = none)
autoState := Map()                  ; helper id -> see AutoFreshState()
autoBoardSig := ""                  ; the board pages last sent to the pool

AutoInit() {
    try {
        if IsObject(assistTrayMenu)
            assistTrayMenu.Add(AUTO_ITEM_WINDOW, (*) => AutoShowBoard(true))
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
        item := "Auto-run during calls (Live helpers)"
        m.Add(item, (*) => AutoToggle(id))
        if AutoIsOn(id)
            m.Check(item)
        m.Add("Open the Live helpers window", (*) => AutoShowBoard(true))
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
        AutoSyncBoard(true)                          ; the pool opens / closes its page
        if (on && IsObject(autoCallRef))             ; turned on during a call: it joins this call
            autoState[id] := AutoFreshState()
        statusText.Text := on ? "Status: auto helper on - it runs by itself during calls (Live helpers window)"
            : "Status: auto helper off"
    } catch as err {
        AutoReport(err)
    }
}

; ---- the pool's board pages = the auto helpers ----
AutoOnPoolState(state) {
    global autoBoardSig
    autoBoardSig := ""                               ; a (re)started pool needs the list again
    AutoSyncBoard(true)
}

AutoSyncBoard(force := false) {
    global autoBoardSig
    try {
        if !PoolLinkEnabled()
            return
        hwnd := PoolLinkWindow()
        if !hwnd
            return
        pages := []
        for a in AutoHelpers()
            pages.Push(Map("key", Trim(a["id"]), "label", Trim(a["label"])))
        msg := Map("t", "board", "hwnd", myGui.Hwnd, "title", AUTO_TITLE, "pages", pages)
        sig := Json.Stringify(pages)
        if (!force && sig == autoBoardSig)
            return
        if PoolLinkSend(hwnd, msg)
            autoBoardSig := sig
    } catch as err {
        AutoReport(err)
    }
}

AutoShowBoard(activate) {
    try {
        if !PoolLinkEnabled() {
            PoolLinkShowWindow()                     ; offers to turn the pool on
            return
        }
        if activate
            DllCall("AllowSetForegroundWindow", "UInt", 0xFFFFFFFF)
        if (hwnd := PoolLinkWindow())
            PoolLinkSend(hwnd, Map("t", "boardshow", "activate", activate ? 1 : 0))
        else if activate
            statusText.Text := "Status: the Copilot pool is starting - try again in a moment"
    } catch as err {
        AutoReport(err)
    }
}

; ---- a call ----
; needFull: the call's full prompt still has to go.  sentText / notesSent: what Copilot has seen.
; sending: a prompt is on its way and not in Copilot yet.  seq: the newest prompt (older replies are ignored).
AutoFreshState() {
    return {needFull: true, sentText: "", notesSent: "", sending: false, seq: 0, lastSend: 0, retryAt: 0, why: ""}
}

; Trace: why a helper is (not) sending right now - written only when the reason changes
AutoWhy(st, label, why) {
    if (st.why == why)
        return
    st.why := why
    if (why != "")
        DbgTrace("auto", "'" label "' " why)
}

; A new call started (New call button, or a 3CX ring): every auto helper starts over on it
AutoHelpersNewCall() {
    global autoCallRef, autoState
    try {
        if (!IsObject(currentCall) || !AutoHelpers().Length || !PoolLinkEnabled()) {
            DbgTrace("auto", "new call signal - ignored (" (!IsObject(currentCall) ? "no call record"
                : !AutoHelpers().Length ? "no auto helpers ticked" : "the Copilot pool is off") ")")
            return
        }
        if (currentCall == autoCallRef) {            ; already working on this call
            DbgTrace("auto", "new call signal - already on this call, nothing to do")
            return
        }
        autoCallRef := currentCall
        autoState := Map()
        names := ""
        for a in AutoHelpers() {
            autoState[Trim(a["id"])] := AutoFreshState()
            names .= (names = "" ? "" : ", ") "'" Trim(a["label"]) "'"
        }
        DbgTrace("auto", "NEW CALL - auto helpers start: " names " (pool " (PoolLinkUsable() ? "ready" : "NOT ready") ")")
        AutoShowBoard(false)                         ; show the Live helpers without taking focus
    } catch as err {
        AutoReport(err)
    }
}

; Every 300 ms: send what each auto helper needs, when it's a good moment
AutoTick() {
    global autoCallRef
    static n := 0
    try {
        n += 1
        if (Mod(n, 7) = 0)                           ; ~2 s: helper names / auto list changed? (sends only changes)
            AutoSyncBoard()
        if !IsObject(autoCallRef)
            return
        static poolWait := false
        if !(currentCall == autoCallRef) {           ; that call was finished or thrown away
            DbgTrace("auto", "the call changed (finished / discarded) - auto helpers stop")
            autoCallRef := ""
            return
        }
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
        for a in AutoHelpers() {
            id := Trim(a["id"])
            label := Trim(a["label"])
            if !autoState.Has(id)
                autoState[id] := AutoFreshState()
            st := autoState[id]
            if (st.sending && A_TickCount - st.lastSend > 60000) {  ; never heard back: don't stay stuck
                DbgTrace("auto", "'" label "' no word from the pool for 60 s - not waiting any longer")
                st.sending := false
            }
            if st.sending {
                AutoWhy(st, label, "waiting: its prompt is on the way into Copilot")
                continue
            }
            if (A_TickCount < st.retryAt) {
                AutoWhy(st, label, "waiting to retry (its last try didn't reach Copilot)")
                continue
            }
            if st.needFull {                             ; the call's first prompt: right away, no waiting
                t := A_TickCount
                text := AssistBuildFull(a, full)
                AutoWhy(st, label, "")
                DbgTrace("auto", "'" label "' FULL prompt built in " (A_TickCount - t) " ms (" StrLen(text) " chars, captions "
                    StrLen(full) " chars) - sending")
                AutoSend(a, st, text, true, full, notes)
                continue
            }
            notesChanged := (notes !== st.notesSent)
            if (full == st.sentText && !notesChanged) {
                AutoWhy(st, label, "idle: nothing new in the captions")
                continue
            }
            fresh := Trim(AutoNewText(st.sentText, full), " `t`r`n")
            if (StrLen(fresh) < AutoNum("MinChars") && !notesChanged) {
                AutoWhy(st, label, "waiting: fewer new chars than MinChars (" AutoNum("MinChars") ")")
                continue
            }
            if !quiet {
                AutoWhy(st, label, "waiting: the customer is still talking")
                continue
            }
            if (A_TickCount - st.lastSend < AutoNum("MinGapMs")) {
                AutoWhy(st, label, "waiting: MinGapMs since the last send")
                continue
            }
            ; Copilot may still be writing the previous answer: the pool stops it and sends this at once
            AutoWhy(st, label, "")
            DbgTrace("auto", "'" label "' FOLLOW-UP: " StrLen(fresh) " new chars" (notesChanged ? " + verified info changed" : "")
                ", customer quiet for " (lastChatTick ? A_TickCount - lastChatTick : -1) " ms - sending")
            AutoSend(a, st, AutoFollowUp(fresh, notes, notesChanged), false, full, notes)
        }
    } catch as err {
        AutoReport(err)
    }
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
    part := fresh != "" ? "The customer just said:`n" fresh : "(Nothing new from the customer.)"
    if (notesChanged && notes != "")
        part .= "`n`nUPDATED AGENT-VERIFIED INFORMATION (treat as correct; actions listed are already done):`n" notes
    tpl := StrReplace(AutoSetting("FollowUpPrompt"), "\n", "`n")
    if !InStr(tpl, "{{new}}")
        tpl := "{{new}}`n`n" tpl
    return NormalizeNewlines(StrReplace(tpl, "{{new}}", part))
}

AutoSend(a, st, text, full, transcript, notes) {
    st.seq += 1
    st.sending := true
    st.lastSend := A_TickCount
    call := autoCallRef
    h := {sent: AutoSent.Bind(st, st.seq, call, transcript, notes), done: AutoDone.Bind(st, st.seq, call, Trim(a["label"]))}
    id := PoolLinkAsk(text, Trim(a["label"]), "", full, h, false, Map("page", Trim(a["id"])))
    if (id = "") {
        st.sending := false
        st.retryAt := A_TickCount + 3000
    }
}

; The prompt is in Copilot (its answer may still be coming): from now on a newer follow-up may replace it
AutoSent(st, seq, call, transcript, notes, m) {
    if (seq != st.seq || !(call == autoCallRef))     ; an older prompt / a newer call already started
        return
    DbgTrace("auto", "prompt #" seq " is in Copilot, " (A_TickCount - st.lastSend) " ms after sending")
    st.sending := false
    st.needFull := false
    st.sentText := transcript
    st.notesSent := notes
}

AutoDone(st, seq, call, label, m) {
    DbgTrace("auto", "'" label "' prompt #" seq " finished: " (m.Get("ok", 0) ? "answered" : m.Get("kind", "") " - " m.Get("error", ""))
        ", " (A_TickCount - st.lastSend) " ms" (seq != st.seq ? " (an older prompt - ignored)" : ""))
    if (seq != st.seq)                               ; an older prompt (replaced by a newer one)
        return
    st.sending := false
    if m.Get("ok", 0)
        return
    kind := m.Get("kind", "")
    if (kind = "replaced")
        return
    if (kind = "lost" && call == autoCallRef) {      ; its page started over: send everything again
        st.needFull := true
        st.retryAt := 0
        return
    }
    if PoolLinkNeverSent(kind)                       ; never reached Copilot: try again in a moment
        st.retryAt := A_TickCount + 3000
    else
        AssistLog("auto helper '" label "': " kind)
}

AutoReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: auto helpers problem (captions unaffected): " msg
    try AssistLog("auto helpers ERROR: " msg)
}
