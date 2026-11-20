; ==============================================================================
; copilot-pool-link.ahk  -  connects the Companion to the Copilot pool (copilot-pool.ahk)
;
; * The pool is its own app and process, and knows nothing about calls. This
;   file only:
;     - starts it with the Companion (tray > Copilot assist > "Use the Copilot
;       pool", per person in live-captions.ini [CopilotPool]; ON by default
;       for everyone; anyone can switch it off there - see docs\COPILOT-POOL.md)
;     - the 💬 and ^ buttons beside the helpers (shown only while the pool is on):
;       💬 (PoolLinkAskInWindow) opens the helper's own Copilot window with
;       the answer - you can keep chatting; 💬 again goes to the same window.
;       ^ (PoolLinkFollowUp) sends only what's new since. Orange = that
;       helper's window is open. The page is yours until you close it.
;       Auto helpers (auto-helpers.ahk) send into the same open windows.
;     - sends prompts (PoolLinkAsk) and hands the replies to whoever asked
;     - keeps the pool's last state (PoolLinkUsable)
; * 🤖, ➤ Ask and ⚡ auto-assist don't use the pool (yet): they paste into
;   Copilot exactly as before. If the pool isn't ready, 💬 says why - use 🤖.
; * A prompt that may have reached Copilot is never sent again
;   (PoolLinkNeverSent tells which failures are safe to retry).
; * Every entry point is wrapped in try/catch: captions are never affected.
; Messages: see the top of copilot-pool.ahk (WM_COPYDATA, tag 0x3CC3, JSON).
; Hooks: PoolLinkInit() (after AssistInit), PoolLinkEnabled(),
; PoolLinkAskInWindow(), PoolLinkUsable(), PoolLinkAsk(), PoolLinkEnd()
; ==============================================================================

POOLLINK_TAG := 0x3CC3
POOLLINK_WIN := "Caption Companion Copilot pool ahk_class AutoHotkeyGUI"
POOLLINK_USE := "Use the Copilot pool (answers inside the Companion)"
POOLLINK_WINDOW := "Copilot pool window (sign in, status)..."
poolLinkState := ""            ; last "state" Map from the pool ("" = nothing heard yet)
poolLinkReqs := Map()          ; request id -> {h: handlers, at, sent}
poolLinkSeq := 0
poolLinkLastStart := 0
poolLinkPending := []          ; 💬 requests waiting for the pool to start
poolLinkHelperSeen := Map()    ; helper id -> {text, notes, call}: the live call as its Copilot window last saw it
                               ; (for ^ and auto helpers; call = which call that chat is about)
POOLLINK_RESTART := "Restart the Copilot pool"
POOLLINK_SIGNOUT := "Sign out of Copilot and restart the pool"

PoolLinkInit() {
    try {
        OnMessage(0x4A, PoolLinkOnCopyData)
        if IsObject(assistTrayMenu) {
            assistTrayMenu.Add()
            assistTrayMenu.Add(POOLLINK_USE, (*) => PoolLinkToggle())
            assistTrayMenu.Add(POOLLINK_WINDOW, (*) => PoolLinkShowWindow())
            assistTrayMenu.Add(POOLLINK_RESTART, (*) => PoolLinkRestart())
            assistTrayMenu.Add(POOLLINK_SIGNOUT, (*) => PoolLinkSignOut())
            if PoolLinkEnabled()
                assistTrayMenu.Check(POOLLINK_USE)
        }
        ; the pool restarts with the Companion (a fresh start, with the Companion's current files);
        ; your Copilot sign-in is kept
        if PoolLinkEnabled()
            PoolLinkRestart(false)
        SetTimer(PoolLinkWatch, 3000)
    } catch as err {
        PoolLinkReport(err)
    }
}

PoolLinkEnabled() {
    try return IniRead(MIC_INI, "CopilotPool", "Enabled", "1") = "1"
    return false
}

PoolLinkToggle() {
    global poolLinkState
    try {
        on := !PoolLinkEnabled()
        IniWrite(on ? 1 : 0, MIC_INI, "CopilotPool", "Enabled")
        if on {
            assistTrayMenu.Check(POOLLINK_USE)
            if !PoolLinkWindow()
                PoolLinkStart("/show")
            statusText.Text := "Status: Copilot pool on - starting (sign in if it asks). The 💬 buttons are in Helpers."
        } else {
            assistTrayMenu.Uncheck(POOLLINK_USE)
            if (hwnd := PoolLinkWindow())
                PoolLinkSend(hwnd, Map("t", "quit"))
            poolLinkState := "", PoolLinkPaintHelpers()
            statusText.Text := "Status: Copilot pool off"
        }
        RebuildHelperButtons()                       ; show / hide the 💬 buttons
    } catch as err {
        PoolLinkReport(err)
    }
}

PoolLinkShowWindow() {
    try {
        if !PoolLinkEnabled() {
            if (MsgBox("The Copilot pool is off.`n`nTurn it on? (Copilot answers then show inside the Companion.)"
                , "Copilot pool", "YesNo Icon?") = "Yes")
                PoolLinkToggle()
            return
        }
        if (hwnd := PoolLinkWindow())
            PoolLinkSend(hwnd, Map("t", "show"))
        else
            PoolLinkStart("/show")
    } catch as err {
        PoolLinkReport(err)
    }
}

; Closes the pool if it's running and starts it again (tray item, and every Companion start).
; Its open Copilot windows close; the sign-in is kept.
PoolLinkRestart(say := true) {
    global poolLinkState
    try {
        if !PoolLinkEnabled() {
            if say
                statusText.Text := "Status: the Copilot pool is off (tray > Copilot assist > Use the Copilot pool)"
            return
        }
        poolLinkState := "", PoolLinkPaintHelpers()
        if PoolLinkWindow() {
            PoolLinkSend(PoolLinkWindow(), Map("t", "quit"))
            PoolLinkStart("/restart /background")     ; waits for the old one to close first
        } else {
            PoolLinkStart("/background")
        }
        if say
            statusText.Text := "Status: restarting the Copilot pool..."
    } catch as err {
        PoolLinkReport(err)
    }
}

; Signs out at Microsoft (ends the sign-in there), then the pool forgets it here and restarts.
; The pool asks first and shows Microsoft's sign-out page.
PoolLinkSignOut() {
    try {
        if !PoolLinkEnabled() {
            statusText.Text := "Status: the Copilot pool is off (tray > Copilot assist > Use the Copilot pool)"
            return
        }
        DllCall("AllowSetForegroundWindow", "UInt", 0xFFFFFFFF)   ; the pool's question can come to the front
        if (hwnd := PoolLinkWindow())
            PoolLinkSend(hwnd, Map("t", "signout"))
        else
            PoolLinkStart("/signout")
    } catch as err {
        PoolLinkReport(err)
    }
}

; The pool's window (hidden or not), or 0
PoolLinkWindow() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := WinExist(POOLLINK_WIN)
    DetectHiddenWindows(prev)
    return hwnd
}

PoolLinkStart(arg) {
    global poolLinkLastStart
    poolLinkLastStart := A_TickCount
    path := A_ScriptDir "\copilot-pool.ahk"
    if !FileExist(path) {
        statusText.Text := "Status: copilot-pool.ahk not found - Copilot buttons paste as before"
        return false
    }
    Run(Format('"{}" "{}" {}', A_AhkPath, path, arg), A_ScriptDir)
    for ms in [1500, 3000, 6000, 12000]
        SetTimer(PoolLinkSubscribe, -ms)
    return true
}

; Ask the pool for its state now and whenever it changes
PoolLinkSubscribe() {
    try {
        if (hwnd := PoolLinkWindow())
            PoolLinkSend(hwnd, Map("t", "status", "hwnd", myGui.Hwnd))
    }
}

; True when a prompt can go to the pool right now
PoolLinkUsable() {
    try {
        return PoolLinkEnabled() && IsObject(poolLinkState) && poolLinkState.Get("state", "") = "ready" && PoolLinkWindow()
    }
    return false
}

; ---- each helper has its own Copilot window ----
; 💬 opens the helper's own Copilot window (a pool page) with its full prompt. While that window is
; open the 💬 and ^ buttons are orange, and 💬 again sends the full prompt into the same window and chat.
; ^ = follow-up: only what the customer said since that helper last sent (and the verified info if it
; changed) goes into its window - like auto-assist, but when you click. You place and size each window
; yourself; it comes back there next time. Closing the window frees its page.
PoolLinkHelperConv(helperId) => (SubStr(Trim(helperId), 1, 7) = "helper-" ? "" : "helper-") Trim(helperId)   ; ids already start with "helper-"

; Is this helper's Copilot window open? (the pool lists the open ones in its state)
PoolLinkHelperOpen(helperId) {
    try {
        if !IsObject(poolLinkState)
            return false
        w := poolLinkState.Get("windows", [])
        if !(w is Array)
            return false
        conv := PoolLinkHelperConv(helperId)
        for x in w
            if (x = conv)
                return true
    }
    return false
}

; A prompt for this helper's window is on its way and not in Copilot yet
PoolLinkHelperBusy(helperId) {
    conv := PoolLinkHelperConv(helperId)
    for id, r in poolLinkReqs
        if (r.conv = conv && !r.sent)
            return true
    return false
}

; Does this helper's window hold a chat about the live call? (no = nothing yet, or an older call)
PoolLinkHelperOnThisCall(helperId) {
    if !poolLinkHelperSeen.Has(helperId)
        return false
    s := poolLinkHelperSeen[helperId]
    return s.HasOwnProp("call") && IsObject(currentCall) && s.call == currentCall
}

; 💬: send the prompt; the pool shows the helper's Copilot window with the answer.
; It just works: if you need to sign in, the sign-in window opens and the request runs right after;
; if the pool isn't running, it's started and the request goes as soon as it's up.
PoolLinkAskInWindow(prompt, label, helperId := "") {
    try {
        if (Trim(prompt, " `t`r`n") = "")
            return
        DllCall("AllowSetForegroundWindow", "UInt", 0xFFFFFFFF)   ; you clicked: the pool may bring its windows to the front
        snap := PoolLinkSnapshot()
        if !PoolLinkWindow() {
            DbgTrace("link", "💬 '" label "': the pool isn't running - held until it starts")
            poolLinkPending.Push({prompt: prompt, label: label, helperId: helperId, snap: snap, at: A_TickCount})
            if (A_TickCount - poolLinkLastStart > 5000)
                PoolLinkStart("/background")
            SetTimer(PoolLinkFlushPending, 300)
            statusText.Text := "Status: starting Copilot - your request goes as soon as it's ready"
            return
        }
        PoolLinkSendShown(prompt, label, helperId, snap)
    } catch as err {
        PoolLinkReport(err)
    }
}

; What the live call looks like now (what Copilot will have seen once this prompt is in)
PoolLinkSnapshot() {
    t := "", n := ""
    try t := AssistLiveTranscript()
    try n := IsObject(currentCall) ? Trim(currentCall.Get("agentNotes", ""), " `t`r`n") : ""
    return {text: t, notes: n, call: currentCall}
}

; ^ beside a helper: a follow-up into that helper's window with what's new since it last sent.
; If its window isn't open, it does what 💬 does (the full prompt); if the window holds an older
; call's chat, a fresh chat with the full prompt.
PoolLinkFollowUp(action) {
    try {
        helperId := Trim(action["id"]), label := Trim(action["label"])
        if !PoolLinkHelperOpen(helperId) {
            DbgTrace("link", "^ '" label "': its window isn't open - sending the full prompt (like 💬)")
            HelperClicked(action)
            PoolLinkAskInWindow(lastCopiedPrompt, label, helperId)
            return
        }
        if PoolLinkHelperBusy(helperId) {
            statusText.Text := "Status: '" label "': its last prompt is still on its way into Copilot - try ^ again in a moment"
            return
        }
        if !PoolLinkHelperOnThisCall(helperId) {
            DbgTrace("link", "^ '" label "': its window holds an older call's chat - fresh chat with the full prompt")
            DllCall("AllowSetForegroundWindow", "UInt", 0xFFFFFFFF)
            HelperClicked(action)
            snap := PoolLinkSnapshot()
            id := PoolLinkAsk(lastCopiedPrompt, label, PoolLinkHelperConv(helperId), true,
                {sent: PoolLinkHelperSent.Bind(helperId, snap), done: PoolLinkWindowDone}, true)
            statusText.Text := id = "" ? "Status: couldn't reach the Copilot pool"
                : "Status: '" label "': new chat for this call (its Copilot window)"
            return
        }
        snap := PoolLinkSnapshot()
        last := poolLinkHelperSeen.Has(helperId) ? poolLinkHelperSeen[helperId] : {text: "", notes: ""}
        notesChanged := (snap.notes !== last.notes)
        fresh := Trim(AutoNewText(last.text, snap.text), " `t`r`n")
        if (fresh = "" && !notesChanged) {
            statusText.Text := "Status: '" label "': nothing new from the customer since its last send"
            return
        }
        DllCall("AllowSetForegroundWindow", "UInt", 0xFFFFFFFF)
        text := AutoFollowUp(fresh, snap.notes, notesChanged)
        DbgTrace("link", "^ '" label "': follow-up, " StrLen(fresh) " new chars" (notesChanged ? " + verified info changed" : ""))
        id := PoolLinkAsk(text, label, PoolLinkHelperConv(helperId), false,
            {sent: PoolLinkHelperSent.Bind(helperId, snap), done: PoolLinkWindowDone}, true)
        statusText.Text := id = "" ? "Status: couldn't reach the Copilot pool"
            : "Status: follow-up sent to '" label "' (its Copilot window)"
    } catch as err {
        PoolLinkReport(err)
    }
}

; The prompt is in Copilot: remember what that helper's window has seen (for the next ^)
PoolLinkHelperSent(helperId, snap, m) {
    poolLinkHelperSeen[helperId] := snap
}

; Orange 💬 / ^ while that helper's Copilot window is open
PoolLinkPaintHelpers() {
    try {
        for i, action in helperActions {
            open := PoolLinkHelperOpen(action["id"])
            for list in [helperPoolButtons, helperFollowButtons]
                if (i <= list.Length)
                    PoolLinkPaintButton(list[i], open)
        }
    }
}

PoolLinkPaintButton(ctrl, open) {
    want := open ? "FDBA74" : "E5E7EB"
    if (ctrl.HasOwnProp("paintedAs") && ctrl.paintedAs = want)
        return
    ctrl.paintedAs := want
    ctrl.Opt("+Background" want)
    ctrl.SetFont(open ? "c1F1300 bold" : "c111827 norm")
    ctrl.Redraw()
}

PoolLinkSendShown(prompt, label, helperId := "", snap := "") {
    if (helperId != "") {                            ; the helper's own window (the same one again if it's open)
        open := PoolLinkHelperOpen(helperId)
        h := {done: PoolLinkWindowDone}
        if IsObject(snap)
            h.sent := PoolLinkHelperSent.Bind(helperId, snap)
        id := PoolLinkAsk(prompt, label, PoolLinkHelperConv(helperId), !open, h, true, Map("orNew", 1))
    } else {
        id := PoolLinkAsk(prompt, label, "", true, {done: PoolLinkWindowDone}, true)
    }
    if (id = "") {
        statusText.Text := "Status: couldn't reach the Copilot pool - 🤖 pastes into Copilot instead"
        return
    }
    st := IsObject(poolLinkState) ? poolLinkState.Get("state", "") : ""
    statusText.Text := st = "ready" ? "Status: sent to Copilot - its window shows the answer"
        : st = "signin" ? "Status: sign in to Copilot - your request runs right after"
        : st = "account" ? "Status: Copilot pool: " poolLinkState.Get("reason", "check the account")
        : "Status: Copilot is starting - your request runs when it's ready"
}

; 💬 requests made while the pool was starting: send them once it's up (or give up after 30 s)
PoolLinkFlushPending() {
    try {
        if !poolLinkPending.Length {
            SetTimer(PoolLinkFlushPending, 0)
            return
        }
        if PoolLinkWindow() {
            Sleep(300)                                ; let it finish setting up its message handler
            items := poolLinkPending.Clone()
            poolLinkPending.Length := 0
            SetTimer(PoolLinkFlushPending, 0)
            DllCall("AllowSetForegroundWindow", "UInt", 0xFFFFFFFF)
            for p in items
                PoolLinkSendShown(p.prompt, p.label, p.helperId, p.snap)
            return
        }
        if (A_TickCount - poolLinkPending[1].at > 30000) {
            poolLinkPending.Length := 0
            SetTimer(PoolLinkFlushPending, 0)
            statusText.Text := "Status: the Copilot pool didn't start - 🤖 pastes into Copilot instead"
        }
    } catch as err {
        PoolLinkReport(err)
    }
}

PoolLinkWindowDone(m) {
    if m.Get("ok", 0) {
        statusText.Text := "Status: Copilot answered (in its window - you can keep chatting there)"
        return
    }
    why := m.Get("error", "")
    kind := m.Get("kind", "")
    if (kind = "busy" && InStr(why, "window"))
        why := "every Copilot page is open in a window - close one and try again"
    else if (kind = "signin" || kind = "account" || kind = "starting")
        why := "not signed in in time (" why ") - click 💬 again"
    else if (kind = "lost")
        why := "that helper's Copilot chat is gone (window closed or page reloaded) - click 💬 to start it again"
    statusText.Text := "Status: Copilot pool: " why
}

; Sends a prompt. conv "" = a one-off (fresh chat); a name = keep that chat for follow-ups.
; show = the pool shows that Copilot page as a window and leaves it to you until you close it.
; h: {sent: fn(m), chunk: fn(m), done: fn(m)} - any can be left out. Returns the request id, or "" if the
; pool couldn't be reached (then nothing was sent).
PoolLinkAsk(prompt, label, conv, newChat, h, show := false, extra := "") {
    global poolLinkSeq
    hwnd := PoolLinkWindow()
    if !hwnd
        return ""
    poolLinkSeq += 1
    id := "c" A_TickCount "-" poolLinkSeq
    m := Map("t", "ask", "id", id, "hwnd", myGui.Hwnd, "prompt", prompt, "label", label,
        "conversation", conv, "newChat", newChat ? 1 : 0, "show", show ? 1 : 0, "tick", A_TickCount)
    if (extra is Map)                                ; e.g. "orNew"
        for k, val in extra
            m[k] := val
    poolLinkReqs[id] := {h: h, at: A_TickCount, sent: false, label: label, conv: conv}
    t := A_TickCount
    ok := PoolLinkSend(hwnd, m)
    DbgTrace("link", "ask " id " '" label "' -> pool" (show ? " (💬 window)" : conv != "" ? " (" conv ")" : "")
        (newChat ? " new chat" : " follow-up") ", " StrLen(prompt) " chars, handed over in " (A_TickCount - t) " ms"
        (ok ? "" : " - FAILED to reach the pool"))
    if !ok {
        poolLinkReqs.Delete(id)
        return ""
    }
    return id
}

; A conversation is over (e.g. the call ended): the pool frees its Copilot page
PoolLinkEnd(conv) {
    try {
        if (conv != "" && (hwnd := PoolLinkWindow()))
            PoolLinkSend(hwnd, Map("t", "end", "conversation", conv))
    }
}

; Failures where the prompt never reached Copilot: trying another way is safe
PoolLinkNeverSent(kind) {
    for k in ["unsent", "off", "starting", "signin", "account", "busy"]
        if (kind = k)
            return true
    return false
}

; ---- messages from the pool ----
PoolLinkOnCopyData(wParam, lParam, msg, hwnd) {
    if (!IsSet(myGui) || hwnd != myGui.Hwnd)         ; (a message can arrive before the main window exists)
        return
    try {
        if (NumGet(lParam, 0, "UPtr") != POOLLINK_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(PoolLinkHandle.Bind(text), -1)      ; reply to the pool right away
    return true
}

PoolLinkHandle(text, *) {
    try {
        m := Json.Parse(text)
        if !(m is Map)
            return
        id := m.Get("id", "")
        switch m.Get("t", "") {
            case "state":
                PoolLinkOnState(m)
            case "queued":
                if poolLinkReqs.Has(id)
                    DbgTrace("link", "ask " id " queued in the pool (position " m.Get("position", "?") ") after "
                        (A_TickCount - poolLinkReqs[id].at) " ms")
            case "sent":
                if poolLinkReqs.Has(id) {
                    r := poolLinkReqs[id]
                    r.sent := true
                    DbgTrace("link", "ask " id " '" r.label "' is IN Copilot, " (A_TickCount - r.at) " ms after asking")
                    PoolLinkCall(r.h, "sent", m)
                }
            case "chunk":
                if poolLinkReqs.Has(id)
                    PoolLinkCall(poolLinkReqs[id].h, "chunk", m)
            case "done":
                if poolLinkReqs.Has(id) {
                    r := poolLinkReqs[id]
                    poolLinkReqs.Delete(id)
                    DbgTrace("link", "ask " id " '" r.label "' done: " (m.Get("ok", 0) ? "answered (" StrLen(m.Get("text", "")) " chars)"
                        : m.Get("kind", "") " - " m.Get("error", "")) ", " (A_TickCount - r.at) " ms after asking")
                    PoolLinkCall(r.h, "done", m)
                }
        }
    } catch as err {
        PoolLinkReport(err)
    }
}

PoolLinkCall(h, name, m) {
    if !(IsObject(h) && h.HasOwnProp(name))
        return
    fn := h.%name%
    try {
        fn(m)
    } catch as err {
        PoolLinkReport(err)
    }
}

PoolLinkOnState(m) {
    global poolLinkState
    prev := IsObject(poolLinkState) ? poolLinkState.Get("state", "") : ""
    poolLinkState := m
    PoolLinkPaintHelpers()                           ; which helpers' Copilot windows are open
    s := m.Get("state", "")
    if (s = prev)
        return
    AssistLog("Copilot pool: " s)
    reason := m.Get("reason", "")
    switch s {
        case "ready":
            statusText.Text := "Status: Copilot pool ready - 💬 beside a helper opens the answer in a Copilot window"
        case "signin":
            statusText.Text := "Status: Copilot pool needs you to sign in (its window is open; or tray > Copilot assist)"
        case "account":
            statusText.Text := "Status: Copilot pool won't send - " reason
        case "off":
            if (prev != "")
                statusText.Text := "Status: Copilot pool stopped (" reason ") - 🤖 still pastes into Copilot"
    }
}

; Every 3 s: pool gone? requests that never got an answer?
PoolLinkWatch() {
    global poolLinkState
    try {
        if !PoolLinkEnabled()
            return
        if !PoolLinkWindow() {
            if (IsObject(poolLinkState) && poolLinkState.Get("state", "") != "off")
                poolLinkState := Map("state", "off", "reason", "not running"), PoolLinkPaintHelpers()
            PoolLinkFailAll("the Copilot pool closed")
            if (A_TickCount - poolLinkLastStart > 60000)          ; restart it, at most once a minute
                PoolLinkStart("/background")
            return
        }
        if !IsObject(poolLinkState)
            PoolLinkSubscribe()
        for id, r in poolLinkReqs.Clone()
            if (A_TickCount - r.at > 6 * 60000) {
                poolLinkReqs.Delete(id)
                PoolLinkCall(r.h, "done", Map("ok", 0, "kind", "timeout", "error", "no reply from the Copilot pool"))
            }
    } catch as err {
        PoolLinkReport(err)
    }
}

; The pool vanished with requests open: we can't know if they reached Copilot, so never resend them
PoolLinkFailAll(why) {
    for id, r in poolLinkReqs.Clone() {
        poolLinkReqs.Delete(id)
        PoolLinkCall(r.h, "done", Map("ok", 0, "kind", "failed", "error", why))
    }
}

PoolLinkSend(hwnd, obj) {
    msg := Json.Stringify(obj)
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", POOLLINK_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        ; a plain window handle (not "ahk_id ..."): the pool's window is usually hidden, and a
        ; title match would skip hidden windows here
        SendMessage(0x4A, 0, cds, , Integer(hwnd), , , , 3000)
        return true
    }
    return false
}

PoolLinkReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: Copilot pool problem (captions unaffected): " msg
    try AssistLog("pool link ERROR: " msg)
}
