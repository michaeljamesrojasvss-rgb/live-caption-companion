; ==============================================================================
; copilot-assist.ahk  -  Copilot sending + auto-assist for Live Caption Companion
;
; What it does
;   * Finds the Copilot window YOU opened (it never opens or closes Copilot),
;     using copilot-targets.ini - a list you can teach with the tray menu.
;   * Sends a prompt safely: paste, read the message box back, and press Enter
;     only if the text is really there and Copilot is still the active window.
;   * Auto-assist (⚡ button): right after the customer stops talking, sends the
;     helper you chose to Copilot - but ONLY while you are not touching the
;     mouse or keyboard. It then switches straight back to your window.
;
; Safety rules - the core app must never depend on this file working:
;   * Every entry point is wrapped in try/catch; problems only show in the
;     status line and in assist-debug.log (which never contains call text).
;   * Enter is pressed only after every check passes. If you move the mouse or
;     press a key at any point, it stops right there and gives you your window
;     back.
;   * Your clipboard is restored afterwards (unless you copied something new).
;   * Auto-assist turns itself OFF after 3 real failures in a row.
;   * Settings: live-captions.ini, section [Assist].
; ==============================================================================

assistOn := false
assistBusy := false
assistBtn := ""
assistAskBtn := ""
assistTrayMenu := ""
assistCallRef := ""
assistSentLen := 0
assistNeedFull := true
assistLastSendTick := 0
assistFails := 0
assistLastPasted := ""
assistLastWaitMsg := ""
assistLearnKind := ""
assistReadMethod := ""
ASSIST_TARGETS := DATA_DIR "\copilot-targets.ini"
ASSIST_LOG := DATA_DIR "\assist-debug.log"
; Defaults (override any of them in live-captions.ini, section [Assist])
ASSIST_DEFAULTS := Map()
ASSIST_DEFAULTS["AutoOn"] := 0
ASSIST_DEFAULTS["AutoHelperId"] := ""
ASSIST_DEFAULTS["MinChars"] := 40          ; new customer text needed before a send
ASSIST_DEFAULTS["QuietMs"] := 1200         ; customer silent this long = they finished talking
ASSIST_DEFAULTS["IdleMs"] := 1200          ; you haven't touched mouse/keyboard this long
ASSIST_DEFAULTS["MinGapMs"] := 15000       ; at least this long between sends
ASSIST_DEFAULTS["RequireReadBack"] := 1    ; only press Enter after confirming the text landed
ASSIST_DEFAULTS["FollowUpPrompt"] := "The customer just said:\n{{new}}\n\nBased on the whole conversation so far, give me:\n1) one or two short things I could say next\n2) the next step I should take"

; ==============================================================================
; Hooks called from liveCaptionCompanion.ahk
; ==============================================================================
AssistInit() {
    global assistOn
    try {
        AssistEnsureTargets()
        AssistBuildUi()
        AssistBuildMenu()
        assistOn := (AssistSetting("AutoOn") = "1") && IsObject(AssistHelper())
        AssistRefreshButton()
        SetTimer(AssistTick, 250)
        AssistLog("started")
    } catch as err {
        AssistReport(err, "start")
    }
}

; Manual send (the 🤖 buttons next to your helpers). Not idle-gated: you asked.
AssistSendManual(prompt) {
    global assistBusy
    if (Trim(prompt, " `t`r`n") = "")
        return
    if assistBusy {
        statusText.Text := "Status: busy sending to Copilot - try again in a moment"
        return
    }
    assistBusy := true
    reason := ""
    try {
        for k in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
            KeyWait(k, "T2")
        reason := AssistDeliver(prompt, {gated: false, newChat: false})
    } catch as err {
        reason := "error: " err.Message
    }
    assistBusy := false
    if (reason = "") {
        statusText.Text := "Status: prompt sent to Copilot"
    } else {
        statusText.Text := "Status: not sent to Copilot (" AssistPlain(reason) ") - the prompt is still in the preview box"
        AssistLog("manual send stopped: " AssistPlain(reason))
    }
}

; ==============================================================================
; Settings
; ==============================================================================
AssistSetting(key) {
    default := ASSIST_DEFAULTS.Get(key, "")
    try return IniRead(MIC_INI, "Assist", key, default)
    return default
}

AssistNum(key) {
    try return Integer(AssistSetting(key))
    return ASSIST_DEFAULTS[key]
}

AssistHelper() {
    id := Trim(AssistSetting("AutoHelperId"))
    if (id = "")
        return ""
    for a in helperActions
        if (Trim(a["id"]) = id)
            return a
    return ""
}

; ==============================================================================
; UI: ⚡ button (click = on/off, right-click = choose helper) + tray menu
; ==============================================================================
AssistBuildUi() {
    global assistBtn, assistAskBtn
    btnPrev.GetPos(&px, &py, &pw, &ph)
    right := px + pw
    for hwnd, c in myGui {                       ; sit after the right-most toolbar button
        try {
            c.GetPos(&cx, &cy, &cw, &ch)
            if (cy = py && c.Visible && cx + cw > right)
                right := cx + cw
        }
    }
    assistBtn := myGui.Add("Button", Format("x{} y{} w56 h{}", right + 8, py, ph), "⚡ Off")
    assistBtn.OnEvent("Click", AssistSafe(AssistButtonClick))
    assistBtn.OnEvent("ContextMenu", AssistSafe(AssistPickHelper))
    ; ➤ Ask: shown while auto-assist is off - you decide when the customer is done
    assistAskBtn := myGui.Add("Button", Format("x{} y{} w52 h{}", right + 8 + 56 + 4, py, ph), "➤ Ask")
    assistAskBtn.OnEvent("Click", AssistSafe(AssistAskNow))
    assistAskBtn.OnEvent("ContextMenu", AssistSafe(AssistPickHelper))
}

; Same send as auto-assist (full context first, then only what's new), but
; right now, because you clicked - no waiting for idle or minimum length.
AssistAskNow() {
    global assistBusy, assistSentLen, assistNeedFull, assistLastSendTick, assistFails
    if assistBusy {
        statusText.Text := "Status: already sending to Copilot - one moment"
        return
    }
    helper := AssistHelper()
    if !IsObject(helper) {
        AssistPickHelper()
        return
    }
    AssistSyncCall()
    full := AssistLiveTranscript()
    if (StrLen(full) < assistSentLen)
        assistSentLen := StrLen(full)
    fresh := Trim(SubStr(full, assistSentLen + 1), " `t`r`n")
    if (Trim(full) = "") {
        statusText.Text := "Status: no customer captions in this call yet"
        return
    }
    if (!assistNeedFull && fresh = "") {
        statusText.Text := "Status: nothing new from the customer since the last send"
        return
    }
    first := assistNeedFull
    text := first ? AssistBuildFull(helper, full) : AssistBuildFollowUp(fresh)
    assistBusy := true
    reason := ""
    try {
        for k in ["Ctrl", "Shift", "Alt", "LWin", "RWin"]
            KeyWait(k, "T2")
        reason := AssistDeliver(text, {gated: false, newChat: first})
    } catch as err {
        reason := "error: " err.Message
    }
    assistBusy := false
    if (reason = "") {
        assistSentLen := StrLen(full)
        assistNeedFull := false
        assistLastSendTick := A_TickCount
        statusText.Text := "Status: sent to Copilot at " FormatTime(, "h:mm:ss tt")
        AssistLog("ask: sent " (first ? "full context" : "follow-up") " (" StrLen(text) " chars)")
    } else {
        statusText.Text := "Status: not sent to Copilot (" AssistPlain(reason) ")"
        AssistLog("ask stopped: " AssistPlain(reason))
    }
}

; Resets what has been sent when a new call record starts
AssistSyncCall() {
    global assistCallRef, assistSentLen, assistNeedFull
    if !(currentCall == assistCallRef) {
        assistCallRef := currentCall
        assistSentLen := 0
        assistNeedFull := true
    }
}

AssistBuildMenu() {
    global assistTrayMenu
    m := Menu()
    m.Add("Auto-assist on/off", AssistSafe(() => AssistSetOn(!assistOn)))
    m.Add("Choose auto-assist helper…", AssistSafe(AssistPickHelper))
    m.Add()
    m.Add("Learn: Copilot message box", AssistSafe(() => AssistStartLearn("Input")))
    m.Add("Learn: Copilot Send button", AssistSafe(() => AssistStartLearn("Send")))
    m.Add("Learn: Copilot New chat button", AssistSafe(() => AssistStartLearn("NewChat")))
    m.Add("Open copilot-targets.ini", AssistSafe(() => Run('notepad.exe "' ASSIST_TARGETS '"')))
    m.Add("Open assist log", AssistSafe(() => Run('notepad.exe "' ASSIST_LOG '"')))
    assistTrayMenu := m
    A_TrayMenu.Insert("1&", "Copilot assist", m)
}

AssistButtonClick() {
    if !IsObject(AssistHelper()) {
        AssistPickHelper()
        return
    }
    AssistSetOn(!assistOn)
}

AssistSetOn(on) {
    global assistOn, assistFails
    helper := AssistHelper()
    if (on && !IsObject(helper)) {
        statusText.Text := "Status: choose a helper for auto-assist first (right-click ⚡)"
        on := false
    }
    assistOn := on
    assistFails := 0
    try IniWrite(assistOn ? 1 : 0, MIC_INI, "Assist", "AutoOn")
    AssistRefreshButton()
    if assistOn
        statusText.Text := "Status: auto-assist ON - '" helper["label"] "' goes to Copilot after the customer speaks"
    else if IsObject(helper)
        statusText.Text := "Status: auto-assist off"
}

AssistRefreshButton() {
    if IsObject(assistBtn)
        assistBtn.Text := assistOn ? "⚡ On" : "⚡ Off"
    if IsObject(assistAskBtn)
        assistAskBtn.Visible := !assistOn          ; ➤ Ask only while auto is off
}

AssistPickHelper(*) {
    m := Menu()
    cur := Trim(AssistSetting("AutoHelperId"))
    if (helperActions.Length = 0) {
        m.Add("No helpers yet - add one in Helpers > Edit helpers", (*) => 0)
        m.Disable("1&")
    }
    for a in helperActions {
        label := StrReplace(Trim(a["label"]), "&", "&&")
        m.Add(label, AssistSafe(AssistChooseHelper.Bind(Trim(a["id"]))))
        if (Trim(a["id"]) = cur)
            m.Check(label)
    }
    m.Add()
    m.Add(assistOn ? "Turn auto-assist off" : "Turn auto-assist on", AssistSafe(() => AssistSetOn(!assistOn)))
    m.Show()
}

AssistChooseHelper(id, *) {
    try IniWrite(id, MIC_INI, "Assist", "AutoHelperId")
    AssistSetOn(true)
}

; ==============================================================================
; Auto-assist: runs every 250 ms, does nothing unless everything lines up
; ==============================================================================
AssistTick() {
    global assistCallRef, assistSentLen, assistNeedFull, assistLastSendTick, assistFails, assistBusy
    if (!assistOn || assistBusy)
        return
    try {
        AssistSyncCall()                              ; a new call record resets what was sent
        full := AssistLiveTranscript()
        if (StrLen(full) < assistSentLen)             ; a bubble was deleted
            assistSentLen := StrLen(full)
        fresh := Trim(SubStr(full, assistSentLen + 1), " `t`r`n")
        if (StrLen(fresh) < AssistNum("MinChars"))
            return
        if (lastChatTick && A_TickCount - lastChatTick < AssistNum("QuietMs"))
            return                                    ; customer is still talking
        if (A_TickCount - assistLastSendTick < AssistNum("MinGapMs"))
            return
        if (A_TimeIdlePhysical < AssistNum("IdleMs") || AssistInputHeld())
            return                                    ; you are using mouse/keyboard - wait
        if AssistDialogOpen()
            return
        helper := AssistHelper()
        if !IsObject(helper) {
            AssistSetOn(false)
            return
        }
        first := assistNeedFull
        text := first ? AssistBuildFull(helper, full) : AssistBuildFollowUp(fresh)
        assistBusy := true
        assistLastSendTick := A_TickCount
        reason := AssistDeliver(text, {gated: true, newChat: first})
        assistBusy := false
        if (reason = "") {
            assistSentLen := StrLen(full)
            assistNeedFull := false
            assistFails := 0
            statusText.Text := "Status: auto-assist sent to Copilot at " FormatTime(, "h:mm:ss tt")
            AssistLog("sent " (first ? "full context" : "follow-up") " (" StrLen(text) " chars)")
        } else {
            AssistOnFail(reason)
        }
    } catch as err {
        assistBusy := false
        AssistReport(err, "auto-assist")
    }
}

AssistOnFail(reason) {
    global assistFails, assistLastSendTick, assistLastWaitMsg
    msg := AssistPlain(reason)
    if (SubStr(reason, 1, 5) = "soft:") {
        ; not a failure - just not a good moment; try again shortly
        assistLastSendTick := A_TickCount - AssistNum("MinGapMs") + 1500
        statusText.Text := "Status: auto-assist waiting - " msg
        if (msg != assistLastWaitMsg)
            AssistLog("waiting: " msg)
        assistLastWaitMsg := msg
        return
    }
    assistLastWaitMsg := ""
    assistFails += 1
    AssistLog("FAILED (" assistFails "/3): " msg)
    statusText.Text := "Status: auto-assist not sent (" msg ")"
    if (assistFails >= 3) {
        AssistSetOn(false)
        statusText.Text := "Status: auto-assist turned itself OFF after 3 failures (" msg ") - captions unaffected"
    }
}

AssistLiveTranscript() {
    s := ""
    for line in sessionLines
        if (Trim(line.Text) != "")
            s .= (s = "" ? "" : "`n") line.Text
    return s
}

AssistBuildFull(helper, transcriptText) {
    raw := helper["prompt"]
    context := BuildContextBlock()
    notes := IsObject(currentCall) ? Trim(currentCall.Get("agentNotes", ""), " `t`r`n") : ""
    notesBlock := ""
    if (notes != "")
        notesBlock := "AGENT-VERIFIED INFORMATION AND CALL UPDATES (typed by the agent from the company's systems and the agent's own actions). "
            . "Treat this as correct: use these exact names, account names and details instead of anything in the transcript that conflicts, because captions can mishear names. "
            . "Actions listed here count as confirmed and already done, so do not suggest or draft them again.`n" notes
    transcriptValue := transcriptText
    callerText := "", callerBlock := ""
    try callerText := %"CallerPromptText"%()          ; only if caller-companion.ahk is loaded
    try callerBlock := %"CallerAutoBlock"%(raw)
    if (callerBlock != "" && InStr(raw, "{{transcript}}")) {
        transcriptValue := (transcriptValue = "" ? "" : transcriptValue "`n`n") callerBlock
        callerBlock := ""
    }
    if (notesBlock != "" && !InStr(raw, "{{verifiedInfo}}"))
        transcriptValue := (transcriptValue = "" ? "" : transcriptValue "`n`n") notesBlock
    prompt := StrReplace(raw, "{{context}}", context)
    prompt := StrReplace(prompt, "{{transcript}}", transcriptValue)
    prompt := StrReplace(prompt, "{{verifiedInfo}}", notesBlock)
    prompt := StrReplace(prompt, "{{currentCaption}}", current.Value)
    prompt := StrReplace(prompt, "{{selectedText}}", "")
    prompt := StrReplace(prompt, "{{caller}}", callerText)
    if (callerBlock != "")
        prompt .= "`n`n" callerBlock
    if (!InStr(raw, "{{context}}") && context != "")
        prompt .= "`n`nREFERENCE CONTEXT`n" context
    return NormalizeNewlines(prompt)
}

AssistBuildFollowUp(fresh) {
    tpl := StrReplace(AssistSetting("FollowUpPrompt"), "\n", "`n")
    if !InStr(tpl, "{{new}}")
        tpl := "The customer just said:`n{{new}}`n`n" tpl
    return NormalizeNewlines(StrReplace(tpl, "{{new}}", fresh))
}

; ==============================================================================
; Delivery. Returns "" on success, "soft:<why>" when it was just not a good
; moment, or "<why>" for a real failure.
; ==============================================================================
AssistDeliver(text, opts) {
    hwnd := AssistFindTarget(&sec)
    if !hwnd
        return "soft:Copilot window not found - open Copilot first"
    if AssistInputHeld()
        return "soft:a key or mouse button is held"
    t0 := A_TickCount
    prev := WinExist("A")
    saved := ClipboardAll()
    A_Clipboard := text
    if !ClipWait(1) {
        A_Clipboard := saved
        return "soft:the clipboard is busy"
    }
    reason := ""
    try {
        reason := AssistDeliverInWindow(hwnd, sec, text, opts, t0)
    } catch as err {
        reason := "error: " err.Message
    }
    if (A_Clipboard == text)                  ; leave it alone if you copied something new
        A_Clipboard := saved
    if (prev && prev != hwnd && WinExist("ahk_id " prev))
        try WinActivate("ahk_id " prev)       ; give you your window back
    return reason
}

AssistDeliverInWindow(hwnd, sec, text, opts, t0) {
    global assistLastPasted
    if (WinGetMinMax("ahk_id " hwnd) = -1)
        WinRestore("ahk_id " hwnd)
    WinActivate("ahk_id " hwnd)
    if !WinWaitActive("ahk_id " hwnd, , 1) {
        WinActivate("ahk_id " hwnd)             ; Windows sometimes ignores the first request
        if !WinWaitActive("ahk_id " hwnd, , 1)
            return "Copilot did not come to the front"
    }
    root := UIA.ElementFromHandle(hwnd)

    if opts.newChat {
        nc := AssistFindEl(root, sec, "NewChat")
        if IsObject(nc) {
            try nc.Invoke()
            Sleep(900)
            root := UIA.ElementFromHandle(hwnd)
        }
    }
    if AssistTouched(opts, t0)
        return "soft:you moved the mouse or typed"

    input := AssistFindEl(root, sec, "Input")
    if !IsObject(input)
        return "Copilot message box not found - re-learn it from the tray menu"
    existing := ""
    try existing := AssistReadInput(input)
    ex := AssistNorm(existing)
    placeholder := ""
    try placeholder := AssistNorm(input.Name)          ; e.g. "Message Copilot" shown in an empty box
    if (ex != "" && ex != placeholder && ex != AssistNorm(assistLastPasted)) {
        AssistLog("message box not empty: read " StrLen(existing) " chars, first char codes "
            . AssistCodes(existing) ", element name '" placeholder "'")
        return "soft:Copilot's message box already has your text in it - left untouched"
    }

    input.SetFocus()
    Sleep(120)
    if !WinActive("ahk_id " hwnd)
        return "Copilot lost focus"
    if AssistTouched(opts, t0)
        return "soft:you moved the mouse or typed"
    Send("^a")
    Send("^v")
    assistLastPasted := text
    Sleep(350)

    ; The editor often rebuilds itself after a paste, so look the box up again
    root := UIA.ElementFromHandle(hwnd)
    fresh := AssistFindEl(root, sec, "Input")
    if IsObject(fresh)
        input := fresh

    if (AssistSetting("RequireReadBack") = "1") {
        try {
            got := AssistReadInput(input)
        } catch as err {
            return "could not read back Copilot's message box (" err.Message ")"
        }
        if !AssistMatches(got, text)
            return "the pasted text did not show up in Copilot - not sent"
    }

    if !WinActive("ahk_id " hwnd)
        return "Copilot lost focus before Enter - not sent"
    if AssistTouched(opts, t0)
        return "soft:you moved the mouse or typed - not sent"
    if AssistInputHeld()
        return "soft:a key was held - not sent"
    Send("{Enter}")
    Sleep(500)

    ; Still in the box? Try the learned Send button once.
    root := UIA.ElementFromHandle(hwnd)
    fresh := AssistFindEl(root, sec, "Input")
    if IsObject(fresh)
        input := fresh
    after := ""
    try after := AssistReadInput(input)
    if AssistMatches(after, text) {
        sb := AssistFindEl(root, sec, "Send")
        if IsObject(sb) {
            try sb.Invoke()
            Sleep(400)
            try after := AssistReadInput(input)
        }
        if AssistMatches(after, text)
            return "soft:Copilot did not take the message yet (still answering?)"
    }
    assistLastPasted := ""
    return ""
}

AssistTouched(opts, t0) {
    return opts.gated && (A_TimeIdlePhysical + 30 < A_TickCount - t0)
}

AssistInputHeld() {
    for k in ["Ctrl", "Shift", "Alt", "LWin", "RWin", "LButton", "RButton", "MButton"]
        if GetKeyState(k, "P")
            return true
    return false
}

AssistDialogOpen() {
    if !DllCall("IsWindowEnabled", "Ptr", myGui.Hwnd)
        return true
    pid := DllCall("GetCurrentProcessId")
    return WinExist("ahk_class #32770 ahk_pid " pid) ? true : false
}

; Reads the message box. Web editors expose their text in different ways, so
; several methods are tried; the one that worked is logged once.
AssistReadInput(el) {
    global assistReadMethod
    anyWorked := false
    for method in ["TextPattern", "LegacyValue", "Value", "Children"] {
        try {
            switch method {
                case "TextPattern": t := el.TextPattern.DocumentRange.GetText(-1)
                case "LegacyValue": t := el.LegacyIAccessiblePattern.Value
                case "Value":       t := el.Value
                case "Children":    t := AssistChildText(el)
            }
        } catch {
            continue
        }
        anyWorked := true
        if (AssistNorm(t) != "") {             ; first method that actually returns text wins
            if (method != assistReadMethod) {
                assistReadMethod := method
                AssistLog("reading Copilot's message box via " method)
            }
            return t
        }
    }
    if anyWorked
        return ""                              ; readable, and genuinely empty
    throw Error("the message box can't be read")
}

; Text of a web editor = the names of the text pieces inside it
AssistChildText(el) {
    parts := []
    for d in el.FindElements({Type: 50020})          ; 50020 = text
        try parts.Push(d.Name)
    return JoinWith(parts, " ")
}

; Collapses whitespace and drops invisible characters (zero-width spaces,
; byte-order marks, object placeholders) that web editors keep in "empty" boxes.
AssistNorm(s) {
    s := RegExReplace(s, "[\x{200B}-\x{200D}\x{2060}\x{FEFF}\x{FFFC}]")
    return Trim(RegExReplace(s, "[\s\x{00A0}]+", " "))
}

; First few character codes (for the log only - never the text itself)
AssistCodes(s) {
    out := ""
    Loop Min(StrLen(s), 6)
        out .= Format("U+{:04X} ", Ord(SubStr(s, A_Index, 1)))
    return Trim(out)
}

AssistMatches(got, text) {
    g := AssistNorm(got)
    t := AssistNorm(text)
    if (g = "" || t = "")
        return false
    return InStr(g, SubStr(t, 1, 60)) && InStr(g, SubStr(t, -40))
}

AssistPlain(reason) => (SubStr(reason, 1, 5) = "soft:") ? SubStr(reason, 6) : reason

; ==============================================================================
; Copilot targets (copilot-targets.ini) and learn mode
; ==============================================================================
AssistEnsureTargets() {
    if FileExist(ASSIST_TARGETS)
        return
    content := "; copilot-targets.ini - how to find Copilot. Sections are tried top to bottom.`n"
        . "; Add or update entries with the tray menu > Copilot assist > Learn ...`n"
        . "; Type is the UI Automation control type number (50020 = text, 50000 = button).`n`n"
        . "[M365Copilot.exe]`n"
        . "Window=ahk_exe M365Copilot.exe ahk_class Microsoft 365 Copilot Host`n"
        . "InputName=Message Copilot`n"
        . "InputType=50020`n"
        . "SendName=Send`n"
        . "SendType=50000`n"
    FileAppend(content, ASSIST_TARGETS, "UTF-16")     ; UTF-16 so IniRead/IniWrite handle any text
}

AssistFindTarget(&sec) {
    sec := ""
    try {
        sections := IniRead(ASSIST_TARGETS)
    } catch {
        return 0
    }
    for s in StrSplit(sections, "`n", "`r") {
        win := IniRead(ASSIST_TARGETS, s, "Window", "")
        if (win = "")
            continue
        hwnd := WinExist(win)
        if hwnd {
            sec := s
            return hwnd
        }
    }
    return 0
}

AssistFindEl(root, sec, kind) {
    cond := {}
    aid := IniRead(ASSIST_TARGETS, sec, kind "AutomationId", "")
    nm := IniRead(ASSIST_TARGETS, sec, kind "Name", "")
    ty := IniRead(ASSIST_TARGETS, sec, kind "Type", "")
    if (aid != "")
        cond.AutomationId := aid
    if (nm != "")
        cond.Name := nm
    if (ty != "" && IsInteger(ty))
        cond.Type := Integer(ty)
    ; A learned AutomationId is stable. Without one, prefer the editor ID that
    ; M365 Copilot builds use, because a Name-based match only works while the
    ; box is empty (the Name turns into whatever text is typed in it).
    if (kind = "Input" && aid = "")
        try return root.FindElement({AutomationId: "m365-chat-editor-target-element"})
    if (ObjOwnPropCount(cond) = 0)
        return ""
    try return root.FindElement(cond)
    return ""
}

AssistStartLearn(kind) {
    global assistLearnKind
    assistLearnKind := kind
    names := Map("Input", "message box (keep it empty)", "Send", "Send button", "NewChat", "New chat button")
    ToolTip("Learn mode: hover the Copilot " names[kind] " and press F8.   Esc cancels.")
}

#HotIf assistLearnKind != ""
F8:: AssistTry(AssistLearnHere)
Esc:: AssistCancelLearn()
#HotIf

AssistCancelLearn() {
    global assistLearnKind
    assistLearnKind := ""
    ToolTip()
}

AssistLearnHere() {
    global assistLearnKind
    kind := assistLearnKind
    assistLearnKind := ""
    ToolTip()
    CoordMode("Mouse", "Screen")                  ; only affects this thread
    MouseGetPos(&mx, &my, &hwnd)
    el := UIA.ElementFromPoint(mx, my)
    exe := WinGetProcessName("ahk_id " hwnd)
    cls := WinGetClass("ahk_id " hwnd)
    if (kind = "Input")
        el := AssistEditorOf(el)            ; the text inside isn't stable - use its editor
    nm := "", aid := "", ty := ""
    try nm := el.Name
    try aid := el.AutomationId
    try ty := el.Type
    if (aid != "")
        nm := ""                            ; the ID is enough; names can change
    if (Trim(nm) = "" && Trim(aid) = "") {
        statusText.Text := "Status: that element has no name or ID - hover a little differently and try again"
        return
    }
    sec := exe
    IniWrite("ahk_exe " exe " ahk_class " cls, ASSIST_TARGETS, sec, "Window")
    IniWrite(nm, ASSIST_TARGETS, sec, kind "Name")
    IniWrite(aid, ASSIST_TARGETS, sec, kind "AutomationId")
    IniWrite(ty, ASSIST_TARGETS, sec, kind "Type")
    statusText.Text := "Status: learned Copilot " kind " in " exe " (name '" nm "')"
    AssistLog("learned " kind " in " exe ": name='" nm "' id='" aid "' type=" ty)
}

; Walks up from the hovered element to the editor that holds it: the first
; ancestor with an AutomationId, or else an Edit control. Logs the chain so the
; structure can be checked in assist-debug.log (names are cut short).
AssistEditorOf(el) {
    chain := ""
    best := el
    foundEdit := false
    cur := el
    Loop 6 {
        t := "", n := "", a := "", c := ""
        try t := cur.Type
        try n := cur.Name
        try a := cur.AutomationId
        try c := cur.ClassName
        chain .= "`n      " A_Index ": type=" t " id='" a "' class='" SubStr(c, 1, 50)
            . "' name='" SubStr(n, 1, 25) "'"
        if (a != "") {
            best := cur
            break
        }
        if (t = 50004 && !foundEdit) {      ; 50004 = edit
            best := cur
            foundEdit := true
        }
        parent := ""
        try parent := cur.Parent
        if !IsObject(parent)
            break
        cur := parent
    }
    AssistLog("learn: element and its parents:" chain)
    return best
}

; ==============================================================================
; Error handling
; ==============================================================================
AssistSafe(fn) {
    return (*) => AssistTry(fn)
}

AssistTry(fn) {
    try fn()
    catch as err
        AssistReport(err)
}

AssistReport(err, where := "") {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: Copilot assist problem (captions unaffected): " msg
    AssistLog("ERROR " where ": " msg)
}

AssistLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", ASSIST_LOG, "UTF-8")
}
