; ==============================================================================
; livecaption-tools.ahk  -  helpers for fixing and testing Windows Live Captions
;
; Adds a section at the bottom of the right-click menu in the Chat view:
;   * Restart Windows Live Captions  - for when it stops captioning. Ends every
;     LiveCaptions.exe (repeating until it is really gone, like ending the task
;     twice by hand), starts it again and lets the Companion reconnect to it.
;   * Test Windows Live Captions     - speaks a short test phrase with the built-in
;     Windows voice (SAPI), so there is no recording to play. Live Captions
;     listens to the PC's sound output, so the words should show up as captions.
;     When the speech ends it tells you whether captions came through.
;
; Safety rules - same as the other modules:
;   * Every entry point is wrapped in try/catch. Problems only show in the status
;     line and in data\livecaption-tools.log. Captions and the call record keep working.
;   * Nothing here touches 3CX or sends keys anywhere.
;   * The test voice speaks out loud and its words land in the transcript like any
;     other caption, so it asks first while a call is ringing or in progress.
;   * Settings: live-captions.ini, section [LiveCaptionTest], key Text (your own sample).
; ==============================================================================

LCT_LOG := DATA_DIR "\livecaption-tools.log"
LCT_EXE := "LiveCaptions.exe"
LCT_DEFAULT_TEXT := "Testing the windows live caption"

; Auto-start: the Companion needs Live Captions, so when its window is missing (Companion start, closed,
; crashed) it is started by itself - [LiveCaptions] AutoStart in live-captions.ini (Settings > Captions &
; mic, and the tray). Never while "Restart" is closing it, never twice while it is still opening; 20 s
; between tries, once a minute after 3 failed ones. The window you were in gets the focus back.
LCT_INI := DATA_DIR "\live-captions.ini"
LCT_AUTO_TRAY := "Start Windows Live Captions by itself"
lctRestarting := false    ; Restart is closing it: auto-start waits
lctAutoLast := 0          ; when auto-start last ran it
lctAutoTries := 0         ; tries since it was last connected
lctAutoPrev := 0          ; the window that was active when it was started (gets the focus back)
lctMissing := false       ; LiveCaptions.exe isn't on this PC

lctVoice := ""            ; kept alive while speaking - releasing it cuts the speech off
lctTestStartChanges := 0  ; changeCount when the test started
lctTestStartCaption := ""
lctTestBusy := false

; Adds the section to the bottom of the right-click menu.
LctInit() {
    try {
        chatCtxMenu.Add()
        chatCtxMenu.Add("Restart Windows Live Captions", LctSafe(LctRestart))
        chatCtxMenu.Add("Test Windows Live Captions (play sample voice)", LctSafe(LctTest))
        A_TrayMenu.Insert("1&", LCT_AUTO_TRAY, LctSafe(LctAutoToggle))
        LctAutoSyncTray()
        LctLog("started (auto-start " (LctAutoOn() ? "on" : "off") ")")
    } catch as err {
        LctLog("start failed: " err.Message)
    }
}

; ------------------------------------------------------------------------------
; Restart
; ------------------------------------------------------------------------------
LctRestart() {
    global captionEl, lctRestarting
    statusText.Text := "Status: restarting Windows Live Captions..."
    captionEl := ""                      ; drop the old connection, ReadCaption reconnects

    ; Repeat until it stays gone: one kill is sometimes not enough. Auto-start must not start it again
    ; meanwhile (ReadCaption runs during these Sleeps).
    tries := 0
    lctRestarting := true
    try {
        while ProcessExist(LCT_EXE) && tries < 6 {
            tries += 1
            try ProcessClose(LCT_EXE)
            Sleep(400)
            if ProcessExist(LCT_EXE)
                try RunWait('taskkill.exe /F /IM ' LCT_EXE ' /T', , "Hide")
            Sleep(300)
        }
        if ProcessExist(LCT_EXE) {
            statusText.Text := "Status: could not close Windows Live Captions - end it in Task Manager"
            LctLog("restart: still running after " tries " tries")
            return
        }
        LctLog("restart: closed after " tries " kill round(s)")
        ok := LctStart()
    } finally {
        lctRestarting := false
    }
    if !ok {
        statusText.Text := "Status: closed Windows Live Captions - press Win+Ctrl+L to start it"
        return
    }
    statusText.Text := "Status: Windows Live Captions restarted - reconnecting..."
    try TutNote("restart")               ; the tutorial may be waiting for this
}

; Full path to LiveCaptions.exe. AutoHotkey32 is a 32-bit program, so Windows would send
; "System32" to SysWOW64, where LiveCaptions.exe does not exist - "Sysnative" gets around that.
LctExePath() {
    for dir in ["Sysnative", "System32"] {
        path := A_WinDir "\" dir "\" LCT_EXE
        if FileExist(path)
            return path
    }
    return LCT_EXE
}

; Starts Live Captions and waits (up to ~5 s) for its window. Returns true when it is up.
LctStart() {
    try {
        Run(LctExePath())
    } catch as err {
        LctLog("start: Run failed: " err.Message)
        return false
    }
    deadline := A_TickCount + 5000
    while A_TickCount < deadline {
        if WinExist("ahk_exe " LCT_EXE)
            return true
        Sleep(250)
    }
    LctLog("start: no window within 5 s")
    return false
}

; ------------------------------------------------------------------------------
; Auto-start (ReadCaption asks while there is no Live Captions window)
; ------------------------------------------------------------------------------
LctAutoOn() => IniRead(LCT_INI, "LiveCaptions", "AutoStart", "1") = "1"

LctAutoToggle() {
    IniWrite(LctAutoOn() ? "0" : "1", LCT_INI, "LiveCaptions", "AutoStart")
    LctAutoSyncTray()
    LctLog("auto-start " (LctAutoOn() ? "on" : "off"))
}

LctAutoSyncTray() {
    try LctAutoOn() ? A_TrayMenu.Check(LCT_AUTO_TRAY) : A_TrayMenu.Uncheck(LCT_AUTO_TRAY)
}

; No Live Captions window: starts it (when it may) and returns the status line to show. Never waits.
LctAutoStart() {
    global lctAutoLast, lctAutoTries, lctAutoPrev, lctMissing
    manual := "Status: looking for Windows Live Captions (Win+Ctrl+L)..."
    try {
        if (lctRestarting || !LctAutoOn())
            return manual
        if lctMissing
            return "Status: Windows Live Captions isn't on this PC (it needs Windows 11 22H2 or newer)"
        if ProcessExist(LCT_EXE)                       ; opening (no window yet): don't start a second one
            return "Status: Windows Live Captions is starting..."
        pause := lctAutoTries >= 3 ? 60000 : 20000
        if (lctAutoLast && A_TickCount - lctAutoLast < pause)
            return lctAutoTries >= 3 ? "Status: couldn't start Windows Live Captions by itself - press Win+Ctrl+L"
                : "Status: starting Windows Live Captions..."
        path := LctExePath()
        if !FileExist(path) {
            lctMissing := true
            LctLog("auto-start: " LCT_EXE " not found on this PC")
            return LctAutoStart()
        }
        lctAutoLast := A_TickCount
        lctAutoTries += 1
        lctAutoPrev := WinExist("A")
        Run(path)
        LctLog("auto-start: started it (try " lctAutoTries ")")
        try DbgTrace("captions", "Live Captions wasn't running - started it (try " lctAutoTries ")")
        return "Status: starting Windows Live Captions..."
    } catch as err {
        LctLog("auto-start failed: " err.Message)
        return manual
    }
}

; ReadCaption found the window: if we started it, the window you were in gets the focus back
LctAutoConnected(hwnd) {
    global lctAutoTries, lctAutoPrev
    try {
        if (lctAutoTries && lctAutoPrev && lctAutoPrev != hwnd && WinExist("ahk_id " lctAutoPrev) && WinActive("ahk_id " hwnd))
            WinActivate("ahk_id " lctAutoPrev)
        if lctAutoTries
            LctLog("auto-start: connected")
    }
    lctAutoTries := 0, lctAutoPrev := 0
}

; ------------------------------------------------------------------------------
; Test with a spoken sample
; ------------------------------------------------------------------------------
LctTest() {
    global lctVoice, lctTestStartChanges, lctTestStartCaption, lctTestBusy
    if lctTestBusy {
        statusText.Text := "Status: the test voice is still playing"
        return
    }
    if (callerPhase = "ringing" || callerPhase = "on call") {
        ans := MsgBox("A call looks active. The test voice will be spoken out loud and its words "
            . "will be added to this call's transcript.`n`nPlay it anyway?"
            , "Test Windows Live Captions", "YesNo Icon?")
        if (ans != "Yes")
            return
    }

    if !WinExist("ahk_exe " LCT_EXE) {
        statusText.Text := "Status: starting Windows Live Captions for the test..."
        if !LctStart() {
            statusText.Text := "Status: Windows Live Captions is not running - press Win+Ctrl+L, then test again"
            return
        }
        Sleep(1500)                       ; let it settle and the Companion connect
    }

    text := IniRead(MIC_INI, "LiveCaptionTest", "Text", LCT_DEFAULT_TEXT)
    if (Trim(text) = "")
        text := LCT_DEFAULT_TEXT

    lctVoice := ComObject("SAPI.SpVoice")
    lctVoice.Volume := 100
    lctTestStartChanges := changeCount
    lctTestStartCaption := lastCaption
    lctTestBusy := true
    lctVoice.Speak(text, 1)               ; 1 = speak in the background
    statusText.Text := "Status: playing test voice - watch the captions..."
    LctLog("test: speaking " StrLen(text) " characters")
    SetTimer(LctWatchTest, 300)
}

; Runs while the voice is speaking; when it ends, waits a moment and reports.
LctWatchTest() {
    global lctVoice, lctTestBusy
    static doneAt := 0
    try {
        if (IsObject(lctVoice) && lctVoice.Status.RunningState != 1) {   ; 1 = finished
            doneAt := 0
            return
        }
        if !doneAt {
            doneAt := A_TickCount
            return
        }
        if (A_TickCount - doneAt < 2500)                              ; captions lag the audio
            return
        SetTimer(LctWatchTest, 0)
        doneAt := 0
        lctVoice := ""
        lctTestBusy := false
        if (changeCount > lctTestStartChanges || lastCaption != lctTestStartCaption) {
            statusText.Text := "Status: test OK - Windows Live Captions picked up the voice"
            try TutNote("testok")
            LctLog("test: captions changed - OK")
        } else {
            statusText.Text := "Status: test FAILED - no captions appeared. Try right-click > Restart Windows Live Captions"
            LctLog("test: no caption change")
            try TutNote("testfail")
        }
    } catch as err {
        SetTimer(LctWatchTest, 0)
        doneAt := 0
        lctVoice := ""
        lctTestBusy := false
        statusText.Text := "Status: test voice problem: " err.Message
        LctLog("test: error " err.Message)
    }
}

; ------------------------------------------------------------------------------
LctSafe(fn) {
    return (*) => LctTry(fn)
}

LctTry(fn) {
    global lctTestBusy
    try {
        fn()
    } catch as err {
        lctTestBusy := false
        try statusText.Text := "Status: Live Captions tools problem: " err.Message
        LctLog("error: " err.Message)
    }
}

LctLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", LCT_LOG, "UTF-8")
}
