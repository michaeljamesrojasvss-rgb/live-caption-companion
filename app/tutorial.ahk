; ==============================================================================
; tutorial.ahk  -  guided tutorial for Live Caption Companion
;
; A small floating guide window ("Tutorial") that sits next to the Companion and
; walks a new user through the app, one step at a time. A step either waits for
; the user to click Next, or notices by itself that the user did the thing (the
; app tells this module through TutNote("name")) and then turns Next on. The user
; always clicks Next, so there is time to read.
;
; Where it starts:
;   * right after the first start (install), and after an update, as a question
;     "Want a short tutorial?" - asked once per version, only until the tutorial
;     has been completed
;   * any time from the tray icon menu > "Tutorial (how to use the app)"
;
; What it teaches (in order):
;   1. Name, checklist (Chrome, Salesforce, Copilot), what the app is, restart and
;      test of Windows Live Captions
;   2. A practice call: a computer voice (Windows SAPI) plays the caller, so real
;      captions appear. Greeting, caller name, company, site, Search in Salesforce
;      on highlighted caption text, verified info notes
;   3. Helpers: draft teammate message (copied to the clipboard), New call, Prev
;      call, the call log helper, Back to live call, Call history
;   4. Making it your own: the Edit helpers window (helper buttons, reusable
;      context, import / export)
;   The practice call stays in the user's call history on purpose, so they can
;   practise deleting calls later.
;
; Safety rules - same as the other modules:
;   * Every entry point is wrapped in try/catch. Problems only show in the status
;     line and in data\tutorial.log. Captions and the live call keep working.
;   * Nothing here touches 3CX, and nothing is sent anywhere.
;   * The guide window never takes focus (it is shown with NoActivate), so it can
;     not disturb the Companion or a call. Its text areas scroll when a text is
;     longer than the space.
;   * Settings: live-captions.ini, section [Tutorial]:
;       DoneRev, AskedVersion   - bookkeeping
;       W, H                    - size of the guide window (saved when you close it)
;       CallerName              - what the practice caller says as their name
;       Company                 - ... as their company
;       SiteLine                - ... when asked for the site
;     (the defaults are Damone Simpson / Immaculate Clearing Service, LLC / Lowes
;      #2995 1400 Taylor Avenue, Parkville MD; change them to match your Salesforce)
; ==============================================================================

TUT_REV := 1               ; raise when the tutorial gets steps people should see again
TUT_FULL := true           ; finishing the tutorial counts as done
TUT_LOG := DATA_DIR "\tutorial.log"
TUT_W := 400               ; default size of the guide window (the user can resize it)
TUT_H := 460
tutW := TUT_W              ; current size (inner), remembered between runs
tutH := TUT_H

tutGui := ""
tutTitle := ""
tutBody := ""
tutNoteBox := ""
tutBtnAction := ""
tutBtnNext := ""
tutBtnSkip := ""
tutBtnExit := ""
tutSteps := []             ; array of step Maps (see TutBuildSteps)
tutIdx := 0
tutName := ""              ; the name the user typed, used in the practice call too
tutActive := false
tutReady := false          ; the current step is satisfied (Next is enabled)
tutEvents := Map()         ; events reported by TutNote since the step started
tutLastMainPos := ""

; The computer voice that plays the caller
tutVoice := ""
tutSpeakBusy := false
tutSpeakStartChanges := 0
tutSpeakStartCaption := ""

; ==============================================================================
; Hooks called from liveCaptionCompanion.ahk and the other modules
; ==============================================================================
TutInit() {
    try {
        A_TrayMenu.Insert("1&")
        A_TrayMenu.Insert("1&", "Tutorial (how to use the app)", TutSafe(TutStart))
        SetTimer(TutOfferAtStart, -6000)
        TutLog("started")
    } catch as err {
        TutLog("start failed: " err.Message)
    }
}

; Other modules call this when the user did something the tutorial may be waiting
; for. Always safe: does nothing when no tutorial is running.
; Names used: restart, testok, testfail, newcall, sfsearch, helper, helper:<id>,
; editor, history
TutNote(name) {
    if tutActive
        tutEvents[name] := A_TickCount
}

; ==============================================================================
; Offer at start (first start after install, and after an update)
; ==============================================================================
TutOfferAtStart() {
    try {
        if tutActive
            return
        if (Integer(IniRead(MIC_INI, "Tutorial", "DoneRev", "0")) >= TUT_REV)
            return
        if (IniRead(MIC_INI, "Tutorial", "AskedVersion", "") = APP_VERSION)
            return
        if (callerPhase = "ringing" || callerPhase = "on call")
            return                       ; not during a call: it asks again next start
        IniWrite(APP_VERSION, MIC_INI, "Tutorial", "AskedVersion")
        myGui.Opt("+OwnDialogs")
        ans := MsgBox("Welcome to Live Caption Companion!`n`n"
            . "Would you like a short guided tutorial? It takes about 10 minutes and "
            . "uses a practice call.`n`n"
            . "You can also start it any time from the tray icon menu > Tutorial."
            , "Live Caption Companion", "YesNo Iconi")
        if (ans = "Yes")
            TutStart()
    } catch as err {
        TutLog("offer failed: " err.Message)
    }
}

; ==============================================================================
; Start / stop
; ==============================================================================
TutStart() {
    global tutName, tutActive, tutSteps, tutIdx, guiVisible
    if tutActive {
        try {
            tutGui.Show("NA")
        }
        return
    }
    if (callerPhase = "ringing" || callerPhase = "on call") {
        MsgBox("A call looks active. Start the tutorial when you are between calls."
            , "Tutorial", "Iconi")
        return
    }

    ; Make sure the Companion window is visible
    try {
        if (WinGetMinMax("ahk_id " myGui.Hwnd) = -1)
            WinRestore("ahk_id " myGui.Hwnd)
        myGui.Show()
        guiVisible := true
    }

    myGui.Opt("+OwnDialogs")
    r := InputBox("What is your name?`n(Only used to personalise the tutorial.)"
        , "Tutorial", "w340 h150")
    if (r.Result != "OK")
        return
    name := SubStr(Trim(r.Value), 1, 30)
    if (name = "")
        name := "there"
    tutName := name

    try SetView(true)                    ; the tutorial uses the Chat view
    tutSteps := TutBuildSteps(name)
    TutBuildGui()
    tutActive := true
    tutIdx := 0
    TutLog("started for " name)
    TutGo(1)
    SetTimer(TutPoll, 300)
}

; finished = true when the user clicked Finish on the last step
TutClose(finished := false) {
    global tutActive, tutGui, tutVoice, tutSpeakBusy
    SetTimer(TutPoll, 0)
    SetTimer(TutWatchSpeech, 0)
    tutSpeakBusy := false
    tutVoice := ""
    tutActive := false
    if (finished && TUT_FULL) {
        try IniWrite(TUT_REV, MIC_INI, "Tutorial", "DoneRev")
    }
    try {
        IniWrite(tutW, MIC_INI, "Tutorial", "W")
        IniWrite(tutH, MIC_INI, "Tutorial", "H")
    }
    try tutGui.Destroy()
    tutGui := ""
    try statusText.Text := "Status: tutorial closed - start it again from the tray icon menu > Tutorial"
    TutLog(finished ? "finished" : "closed early")
}

TutAskExit() {
    try tutGui.Opt("+OwnDialogs")
    ans := MsgBox("Exit the tutorial?`n`nYou can start it again any time from the tray icon menu > Tutorial."
        , "Tutorial", "YesNo Icon?")
    if (ans = "Yes")
        TutClose(false)
}

; ==============================================================================
; The guide window
; ==============================================================================
TutBuildGui() {
    global tutGui, tutTitle, tutBody, tutNoteBox, tutBtnAction, tutBtnNext, tutBtnSkip, tutBtnExit
    global tutW, tutH
    tutW := TutCfgInt("W", TUT_W, 380, 1000)
    tutH := TutCfgInt("H", TUT_H, 380, Max(380, A_ScreenHeight - 80))
    g := Gui("+AlwaysOnTop +ToolWindow +Resize +MinSize380x380 +E0x08000000", "Tutorial")
    g.BackColor := "11151D"
    g.SetFont("s10 cF1F5FB", "Segoe UI")
    tutTitle := g.Add("Text", "x14 y10 w372 h26", "")
    tutTitle.SetFont("s12 Bold cF1F5FB")
    ; Read-only edit boxes instead of plain text: a long text gets a scroll bar
    ; (and the mouse wheel works) instead of being cut off. TutLayout sizes them.
    tutBody := g.Add("Edit", "x14 y42 w372 h150 Multi ReadOnly VScroll -Tabstop Background1B2431 cF1F5FB", "")
    tutNoteBox := g.Add("Edit", "x14 y198 w372 h70 Multi ReadOnly VScroll -Tabstop Background1B2431 c4ADE80", "")
    tutBtnAction := g.Add("Button", "x14 y264 w372 h30 Hidden", "")
    tutBtnNext := g.Add("Button", "x14 y302 w110 h30", "Next")
    tutBtnSkip := g.Add("Button", "x+8 w120 h30", "Skip this step")
    tutBtnExit := g.Add("Button", "x+8 w120 h30", "Exit tutorial")
    tutBtnAction.OnEvent("Click", TutSafe(TutDoAction))
    tutBtnNext.OnEvent("Click", TutSafe(() => TutAdvanceFrom(tutIdx)))
    tutBtnSkip.OnEvent("Click", TutSafe(() => TutAdvanceFrom(tutIdx)))
    tutBtnExit.OnEvent("Click", TutSafe(TutAskExit))
    g.OnEvent("Close", TutSafe(TutAskExit))
    g.OnEvent("Size", TutOnSize)
    tutGui := g
    TutLayout(tutW, tutH)
}

; The window was resized: remember the size and re-lay out the controls
TutOnSize(g, minMax, w, h) {
    global tutW, tutH
    if (minMax = -1)
        return
    tutW := w
    tutH := h
    TutLayout(w, h)
}

; The text gets all the extra height; the note, the action button and the buttons
; stay at the bottom
TutLayout(w, h) {
    try {
        m := 14
        cw := Max(100, w - 2 * m)
        btnH := 30
        noteH := 70
        btnY := h - 8 - btnH
        actY := btnY - 6 - btnH
        noteY := actY - 6 - noteH
        bodyY := 42
        bodyH := Max(40, noteY - 6 - bodyY)
        tutTitle.Move(m, 10, cw, 26)
        tutBody.Move(m, bodyY, cw, bodyH)
        tutNoteBox.Move(m, noteY, cw, noteH)
        tutBtnAction.Move(m, actY, cw, btnH)
        tutBtnNext.Move(m, btnY, 110, btnH)
        tutBtnSkip.Move(m + 118, btnY, 120, btnH)
        tutBtnExit.Move(m + 246, btnY, 120, btnH)
    }
}

; Puts the guide to the right of the Companion (or to the left when there is no room).
; It is placed once at the start; after that it only follows when the Companion moves,
; so a place the user dragged it to is kept from step to step.
TutPlaceGui(force := false) {
    global tutLastMainPos
    try {
        hwnd := myGui.Hwnd
        if (WinGetMinMax("ahk_id " hwnd) = -1)
            return
        WinGetPos(&mx, &my, &mw, &mh, "ahk_id " hwnd)
        key := mx "," my "," mw "," mh
        if (!force && key = tutLastMainPos)
            return
        tutLastMainPos := key
        x := mx + mw + 8
        if (x + tutW > A_ScreenWidth)
            x := mx - tutW - 8
        if (x < 0)
            x := Max(0, A_ScreenWidth - tutW)
        y := Max(0, my + 40)
        tutGui.Show("NA x" x " y" y " w" tutW " h" tutH)
    }
}

; The note under the text: green for good news, amber for a problem
TutSetNote(text, ok := true) {
    try {
        tutNoteBox.Opt(ok ? "c4ADE80" : "cFBBF24")
        tutNoteBox.Value := text
        tutNoteBox.Redraw()
    }
}

; ==============================================================================
; Step engine
; ==============================================================================
; A step is a Map:
;   title, body    the text shown
;   ready          function returning true when the step is satisfied (Next enables)
;   okText         shown in green once ready (optional)
;   enter          function run when the step starts (optional)
;   actionText     label of a button that runs `action` (optional)
;   action         function
;   failEvent      a TutNote name that means "that did not work" (optional)
;   failText       shown in amber when failEvent arrives
TutGo(n) {
    global tutIdx, tutReady, tutEvents
    if (n > tutSteps.Length) {
        TutClose(true)
        return
    }
    tutIdx := n
    tutReady := false
    tutEvents := Map()
    step := tutSteps[n]
    tutGui.Title := "Tutorial  -  step " n " of " tutSteps.Length
    tutTitle.Text := step["title"]
    tutBody.Value := step["body"]
    TutSetNote("", true)
    if step.Has("actionText") {
        tutBtnAction.Text := step["actionText"]
        tutBtnAction.Visible := true
    } else {
        tutBtnAction.Visible := false
    }
    tutBtnNext.Text := (n = tutSteps.Length) ? "Finish" : "Next"
    tutBtnNext.Enabled := false
    if step.Has("enter") {
        enter := step["enter"]
        enter()
    }
    TutPlaceGui(n = 1)
    TutCheckReady()
}

; Moves on from step idx - ignored when the step already changed (double click)
TutAdvanceFrom(idx) {
    if (!tutActive || idx != tutIdx)
        return
    TutGo(tutIdx + 1)
}

TutDoAction() {
    step := tutSteps[tutIdx]
    action := step["action"]
    action()
}

TutPoll() {
    if !tutActive {
        SetTimer(TutPoll, 0)
        return
    }
    try {
        TutPlaceGui()
        step := tutSteps[tutIdx]
        if (step.Has("failEvent") && tutEvents.Has(step["failEvent"])) {
            tutEvents.Delete(step["failEvent"])
            TutSetNote(step["failText"], false)
        }
        TutCheckReady()
    } catch as err {
        TutLog("poll error: " err.Message)
    }
}

; Turns Next on (and shows the green text) once the step is satisfied.
; It never moves on by itself: the user clicks Next when they have read it.
TutCheckReady() {
    global tutReady
    if tutReady
        return
    step := tutSteps[tutIdx]
    isReady := step["ready"]
    if !isReady()
        return
    tutReady := true
    tutBtnNext.Enabled := true
    if (step.Has("okText") && step["okText"] != "")
        TutSetNote(step["okText"] "`nClick Next when you are ready.", true)
}

; ==============================================================================
; The steps
; ==============================================================================
TutBuildSteps(name) {
    steps := []
    callerName := TutCfg("CallerName", "Damone Simpson")
    company := TutCfg("Company", "Immaculate Clearing Service, LLC")
    siteLine := TutCfg("SiteLine", "The site that I worked on last time was: Lowes #2995 1400 Taylor Avenue, Parkville MD")
    teammateId := "draft-teammate-message"
    callLogId := "draft-salesforce-call-log"
    teammateLabel := TutHelperLabel(teammateId, "Draft teammate message")
    callLogLabel := TutHelperLabel(callLogId, "Draft Salesforce call log")

    ; ---- Part 1: checklist, what the app is, fixing captions ----
    steps.Push(Map(
        "title", "Hi " name "!",
        "body", "Welcome! In this tutorial you will learn how to use Live Caption Companion, "
            . "step by step, with a practice call.`n`n"
            . "First, a quick checklist to make sure your PC is ready.`n`n"
            . "Tip: you can drag this window by its title bar if it covers something.`n`n"
            . "Click Next to begin.",
        "ready", () => true))

    steps.Push(Map(
        "title", "Checklist 1: Chrome",
        "body", "Your default browser must be Google Chrome, because the app opens Salesforce "
            . "searches in your default browser.`n`n"
            . "If it is not, click the button below, find Google Chrome in the list and click "
            . "'Set default'. Next turns on once Chrome is your default browser.",
        "actionText", "Open the default apps settings",
        "action", () => Run("ms-settings:defaultapps"),
        "ready", TutChromeIsDefault,
        "okText", "Google Chrome is your default browser."))

    steps.Push(Map(
        "title", "Checklist 2: Salesforce",
        "body", "Make sure you are logged in to Salesforce.`n`n"
            . "Click the button below. A Salesforce search opens in Chrome. If you see a login page, "
            . "log in. When the search page shows (it does not matter what it finds), come back "
            . "here and click Next.",
        "actionText", "Open a Salesforce test search",
        "action", () => SF_OpenSearch("test"),
        "ready", () => true))

    steps.Push(Map(
        "title", "Checklist 3: Copilot",
        "body", "Have your Copilot ready.`n`n"
            . "Open the Copilot you use for work and make sure you are signed in and can start a chat. "
            . "Some helpers in this app prepare a message for you to paste into Copilot, so it should "
            . "be ready before your calls.`n`n"
            . "When it is ready, click Next.",
        "ready", () => true))

    steps.Push(Map(
        "title", "About this app",
        "body", "The Companion works together with Windows Live Captions. You still need the normal "
            . "Windows Live Captions running: the Companion only reads those captions, shows them as "
            . "a chat and adds helpers on top.`n`n"
            . "It is safe. If the Companion ever fails, crashes or lags (this rarely happens), it just "
            . "closes on its own and Windows Live Captions is not touched.",
        "ready", () => true))

    steps.Push(Map(
        "title", "If captions stop showing",
        "body", "If Windows Live Captions itself stops showing captions, that is not the Companion's "
            . "fault. Instead of ending it in Task Manager, use the restart option.`n`n"
            . "Try it now: right-click inside the big chat box and click 'Restart Windows Live "
            . "Captions'.",
        "enter", () => TutShowChat(),
        "ready", () => tutEvents.Has("restart"),
        "okText", "Done! Windows Live Captions restarted. Give it a second to reconnect."))

    steps.Push(Map(
        "title", "Make sure it really works",
        "body", "After a restart, check that captions really come through.`n`n"
            . "Right-click inside the chat box again and click 'Test Windows Live Captions (play "
            . "sample voice)'. A voice says a short sentence and you should see it appear in the chat. "
            . "Wait until the status line at the top says the test is OK.",
        "enter", () => TutShowChat(),
        "ready", () => tutEvents.Has("testok"),
        "okText", "The test passed: Windows Live Captions picked up the voice.",
        "failEvent", "testfail",
        "failText", "No captions appeared. Right-click > Restart Windows Live Captions, then test again."))

    ; ---- Part 2: the practice call ----
    steps.Push(Map(
        "title", "Start with a clean call",
        "body", "Every call starts with a clean chat. Click the 'New call' button at the bottom "
            . "of the window now. It saves the previous call to your history and clears the chat. "
            . "(If it asks to save the current call, click Yes.)`n`n"
            . "In real life you do not need to click it: when a call rings in 3CX, the app starts "
            . "a new call by itself.",
        "enter", () => TutShowChat(),
        "ready", () => tutEvents.Has("newcall"),
        "okText", "New call started: the chat is clean."))

    steps.Push(Map(
        "title", "The practice call",
        "body", "Now a practice call. You are the agent, and the app plays the caller with a "
            . "computer voice, so you will see real captions in the chat.`n`n"
            . "Say your lines out loud like in a real call (the app does not need to hear you). "
            . "For the caller's answers you click a button and the computer voice talks.`n`n"
            . "Turn your PC volume up and do not mute it.",
        "ready", () => true))

    steps.Push(TutSpeakStep("Greet the caller",
        "Say it out loud: 'Hi, thank you for calling, this is " name ". How can I help you today?'`n`n"
            . "Then click the button below. The caller answers with a computer voice, and the "
            . "captions appear in the chat.",
        "Hi " name ", I'm looking for a missing payment for the site that I worked on."))

    steps.Push(TutSpeakStep("Ask for the caller's name",
        "Pretend you ask for the caller's name. Say: 'May I have your full name please?'`n`n"
            . "Then click the button below.",
        callerName))

    steps.Push(TutSpeakStep("Ask for the company",
        "Pretend you ask for the caller's company. Say: 'And which company are you with?'`n`n"
            . "Then click the button below.",
        company))

    steps.Push(Map(
        "title", "Search in Salesforce",
        "body", "You can search Salesforce straight from the captions.`n`n"
            . "In the chat, drag-highlight the company name the caller just gave, with the mouse. "
            . "Then right-click the highlighted text and click 'Search in Salesforce'. The search "
            . "opens in Chrome.",
        "enter", () => TutShowChat(),
        "ready", () => tutEvents.Has("sfsearch"),
        "okText", "The Salesforce search opened in Chrome."))

    steps.Push(Map(
        "title", "Check what Salesforce shows",
        "body", "In Salesforce, check that the account really exists, and look at the point of "
            . "contact (POC).`n`n"
            . "Compare the spelling with the captions. Captions can be inaccurate, especially with "
            . "names: the caller's name may be spelled a little differently in the chat than in "
            . "Salesforce.`n`n"
            . "No problem: there is a way to correct that, and you will do it in a moment.",
        "ready", () => true))

    steps.Push(TutSpeakStep("Ask for the site",
        "Pretend you ask which site the missing payment is for. Say: 'Which site is the missing "
            . "payment for?'`n`n"
            . "Then click the button below.",
        siteLine))

    steps.Push(Map(
        "title", "Search the site",
        "body", "Search again the same way: drag-highlight the site in the chat (for example the "
            . "store number or the address), right-click it and click 'Search in Salesforce'.",
        "enter", () => TutShowChat(),
        "ready", () => tutEvents.Has("sfsearch"),
        "okText", "The Salesforce search opened in Chrome."))

    steps.Push(Map(
        "title", "Write down the verified info",
        "body", "Look at the account manager (AM) shown on the Salesforce page. Also copy the real "
            . "account name and the caller's real name from Salesforce.`n`n"
            . "Now click the VERIFIED INFO box under the chat and type, for example:`n"
            . "Account manager: <the AM's name>`n"
            . "need to reach out to AM`n"
            . "You can paste the real names there too.",
        "ready", () => StrLen(Trim(RegExReplace(notesBox.Value, "\s+", " "))) >= 25,
        "okText", "Good. From now on every helper treats this box as correct, even when the captions "
            . "heard something different. That is how you fix inaccurate captions."))

    ; ---- Part 3: helpers, new call, previous calls, history ----
    steps.Push(Map(
        "title", "Open the helpers",
        "body", "Now let the helpers do the writing for you. Click the 'Helpers' button at the "
            . "bottom of the window to open the helper buttons.",
        "ready", () => helpersVisible,
        "okText", "Each helper button builds a ready-made prompt from the call so far, your verified "
            . "info and your reference contexts."))

    steps.Push(Map(
        "title", "Teammate message",
        "body", "You need to reach out to the account manager, so click the helper '" teammateLabel "'. "
            . "Use the main button (the wide one), not the small robot icon.`n`n"
            . "(If your helpers are named differently, pick the one that drafts a teammate message.)",
        "enter", () => TutOpenHelpers(),
        "ready", () => TutHelperReady(teammateId),
        "okText", "The prompt is copied to your clipboard automatically. You can also see it in the "
            . "preview box."))

    steps.Push(Map(
        "title", "Paste it into Copilot",
        "body", "Open Copilot and paste (Ctrl+V). It writes a message for the teammate who can help.`n`n"
            . "Read it. If you are satisfied, copy the message. If not, change it first. Then send it "
            . "to your teammate, like you would in a real call.`n`n"
            . "Tip: the small robot button next to a helper sends the prompt to Copilot for you.",
        "ready", () => true))

    steps.Push(Map(
        "title", "End the call",
        "body", "That is the end of the call. Click 'New call' to save it to your history and start "
            . "a fresh one. If it asks, click Yes.",
        "ready", () => tutEvents.Has("newcall"),
        "okText", "The call is saved and a new one started."))

    steps.Push(Map(
        "title", "Go back to an earlier call",
        "body", "To look at an earlier call again, click the 'Prev call' button at the top of the "
            . "window. It shows the call you just finished.",
        "enter", () => TutShowChat(),
        "ready", () => IsObject(reviewCall),
        "okText", "You are reviewing the practice call (see the yellow banner). The helpers work on "
            . "this call now."))

    steps.Push(Map(
        "title", "Log the call",
        "body", "After a call you log it in Salesforce. While you review the call, click the helper "
            . "'" callLogLabel "'. It copies a prompt that writes the call log for you.`n`n"
            . "(If your helpers are named differently, pick the one that drafts the call log.)",
        "enter", () => TutOpenHelpers(),
        "ready", () => TutHelperReady(callLogId),
        "okText", "Copied! Paste it into Copilot to get the call log, check it, then paste it into "
            . "Salesforce."))

    steps.Push(Map(
        "title", "Back to the live call",
        "body", "Click 'Back to live call' in the yellow banner to leave the review.",
        "ready", () => !IsObject(reviewCall),
        "okText", "Back to the live call."))

    steps.Push(Map(
        "title", "Call history",
        "body", "All your calls are saved. Click 'Call history' to see them.`n`n"
            . "There you can read a call, copy its details and select calls to delete them with "
            . "'Delete selected...' (this is permanent). Your practice calls stay in the list, so you "
            . "can try deleting them later.",
        "ready", () => tutEvents.Has("history"),
        "okText", "This is your call history. Close that window when you are done."))

    ; ---- Part 4: make it your own ----
    steps.Push(Map(
        "title", "Make the helpers yours",
        "body", "You can add and change helpers and contexts yourself.`n`n"
            . "Open the helper buttons if they are closed, then click 'Edit helpers' at the bottom of "
            . "the helpers panel.",
        "enter", () => TutOpenHelpers(),
        "ready", () => tutEvents.Has("editor"),
        "okText", "The editor is open. Drag this guide away if it covers something."))

    steps.Push(Map(
        "title", "Editor: helper buttons",
        "body", "On the 'Helper buttons' tab, the list on the left is your helper buttons. Add makes "
            . "a new one, Remove deletes one, and the arrows change the order they appear in.`n`n"
            . "Pick a button to change its label and its PROMPT TEMPLATE on the right. The template is "
            . "the instruction sent to the AI. Placeholders such as {{transcript}} (the call so far), "
            . "{{verifiedInfo}} (your notes), {{selectedText}} and {{caller}} are filled in for you "
            . "each time you click the button.",
        "ready", () => true))

    steps.Push(Map(
        "title", "Editor: reusable context",
        "body", "Click the 'Reusable context' tab. A context is background knowledge that is added "
            . "to every helper prompt, like your call flow, company guides, sample Teams messages or "
            . "sample call logs. This is how the AI learns how things work in your team.`n`n"
            . "Add a context with a name, a short description and the full text.`n`n"
            . "Import and Export (top right) let you share helpers and contexts with your workmates.",
        "ready", () => true))

    steps.Push(Map(
        "title", "Close the editor",
        "body", "Click 'Save changes' to keep what you changed. Your helper buttons update right "
            . "away. Click 'Cancel' to leave everything as it was.`n`n"
            . "For now, just click Cancel and then Next here.`n`n"
            . "If you ever edit call-helpers.json by hand, the 'Reload' button in the helpers panel "
            . "reads it again.",
        "ready", () => true))

    steps.Push(Map(
        "title", "A few more things",
        "body", "Chat / Transcript: two ways to look at the same call.`n"
            . "A- / A+: make the text smaller or bigger.`n"
            . "The pin button (top left): keep the Companion on top of other windows.`n"
            . "Copy transcript: copies the whole call text.`n"
            . "Discard call: throws a call away instead of saving it (use it for tests).`n"
            . "Right-click in the chat: delete a bubble, undo, and the Live Captions tools.",
        "ready", () => true))

    steps.Push(Map(
        "title", "You did it, " name "!",
        "body", "That is everything: you can fix the captions, handle a call, correct names with "
            . "verified info, use the helpers, review and log calls, and make the helpers your own.`n`n"
            . "You can run this tutorial again any time from the tray icon menu > Tutorial.`n`n"
            . "Click Finish to close.",
        "ready", () => true))

    return steps
}

; A step where the practice caller answers: the button speaks `reply` with the Windows
; voice, Live Captions turns it into captions, and the step is done when they show up.
TutSpeakStep(title, body, reply) {
    return Map(
        "title", title,
        "body", body,
        "actionText", "Play the caller's reply",
        "action", () => TutSpeak(reply),
        "enter", () => TutShowChat(),
        "ready", () => tutEvents.Has("spoken"),
        "okText", "The caller's words appeared in the chat as captions.",
        "failEvent", "spokenfail",
        "failText", "No captions appeared. Check your PC volume, then right-click in the chat > "
            . "Restart Windows Live Captions, and click the button again.")
}

; ------------------------------------------------------------------------------
; The practice caller (Windows voice, like the Live Captions test)
; ------------------------------------------------------------------------------
TutSpeak(text) {
    global tutVoice, tutSpeakBusy, tutSpeakStartChanges, tutSpeakStartCaption
    if tutSpeakBusy {
        TutSetNote("The caller is still speaking...", true)
        return
    }
    if !WinExist("ahk_exe " LCT_EXE) {
        TutSetNote("Windows Live Captions is not running. Press Win+Ctrl+L, or right-click in the chat "
            . "> Restart Windows Live Captions, then click the button again.", false)
        return
    }
    text := TutSpokenText(text)
    tutVoice := ComObject("SAPI.SpVoice")
    tutVoice.Volume := 100
    tutSpeakStartChanges := changeCount
    tutSpeakStartCaption := lastCaption
    tutSpeakBusy := true
    tutVoice.Speak(text, 1)               ; 1 = speak in the background
    TutSetNote("The caller is speaking... watch the chat.", true)
    TutLog("speaking " StrLen(text) " characters")
    SetTimer(TutWatchSpeech, 300)
}

; What the voice should say: numbers are read digit by digit ("123" becomes "1 2 3",
; so it says one two three, not one hundred twenty three) and "#" is read as "number"
TutSpokenText(text) {
    text := StrReplace(text, "#", " number ")
    out := ""
    pos := 1
    while RegExMatch(text, "\d+", &m, pos) {
        out .= SubStr(text, pos, m.Pos - pos)
        spaced := ""
        Loop Parse m[0]
            spaced .= (A_Index > 1 ? " " : "") A_LoopField
        out .= spaced
        pos := m.Pos + m.Len
    }
    out .= SubStr(text, pos)
    return RegExReplace(out, "\s+", " ")
}

; Runs while the voice is speaking; when it ends, waits a moment (captions lag the
; audio) and reports whether captions came through
TutWatchSpeech() {
    global tutVoice, tutSpeakBusy
    static doneAt := 0
    try {
        if (IsObject(tutVoice) && tutVoice.Status.RunningState != 1) {   ; 1 = finished
            doneAt := 0
            return
        }
        if !doneAt {
            doneAt := A_TickCount
            return
        }
        if (A_TickCount - doneAt < 3000)
            return
        SetTimer(TutWatchSpeech, 0)
        doneAt := 0
        tutVoice := ""
        tutSpeakBusy := false
        if (changeCount > tutSpeakStartChanges || lastCaption != tutSpeakStartCaption)
            TutNote("spoken")
        else
            TutNote("spokenfail")
    } catch as err {
        SetTimer(TutWatchSpeech, 0)
        doneAt := 0
        tutVoice := ""
        tutSpeakBusy := false
        TutSetNote("The practice voice had a problem: " err.Message, false)
        TutLog("speech error: " err.Message)
    }
}

; ------------------------------------------------------------------------------
; Small helpers
; ------------------------------------------------------------------------------
; A whole-number setting kept between lo and hi
TutCfgInt(key, default, lo, hi) {
    try {
        v := Integer(TutCfg(key, default))
        return Max(lo, Min(hi, v))
    }
    return default
}

TutCfg(key, default) {
    try {
        return IniRead(MIC_INI, "Tutorial", key, default)
    }
    return default
}

; True when Chrome is the default for https links (read-only registry check, no admin needed)
TutChromeIsDefault() {
    try {
        prog := RegRead("HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "ProgId")
        return InStr(prog, "Chrome") ? true : false
    }
    return false
}

TutShowChat() {
    try SetView(true)
}

; Opens the helpers panel when it is closed
TutOpenHelpers() {
    try {
        if !helpersVisible {
            ToggleHelpers()
        }
    }
}

TutHelperExists(id) {
    try {
        for a in helperActions {
            if (Trim(a["id"]) = id)
                return true
        }
    }
    return false
}

TutHelperLabel(id, fallback) {
    try {
        for a in helperActions {
            if (Trim(a["id"]) = id)
                return Trim(a["label"])
        }
    }
    return fallback
}

; The helper was clicked - or, when this PC has no helper with that id, any helper was
TutHelperReady(id) {
    if tutEvents.Has("helper:" id)
        return true
    return (!TutHelperExists(id) && tutEvents.Has("helper"))
}

; ------------------------------------------------------------------------------
TutSafe(fn) {
    return (*) => TutTry(fn)
}

TutTry(fn) {
    try {
        fn()
    } catch as err {
        try statusText.Text := "Status: tutorial problem: " err.Message
        TutLog("error: " err.Message)
    }
}

TutLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", TUT_LOG, "UTF-8")
}
