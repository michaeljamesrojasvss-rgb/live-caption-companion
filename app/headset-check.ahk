; ==============================================================================
; headset-check.ahk  -  "is your headset on?" check for the 3CX Q-login alert (prefix Hs*)
;
; * The moment you most likely took the headset off is when you logged out of Q (water, CR...).
;   So: when Q goes from off (or 3CX closed) back to on, after you were away at least MinAwaySec,
;   it checks at once (StartDelaySec, default 0): plays a short sound in the headset and listens
;   ListenSec seconds. You answer with a sound (say "yep", tap the mic...). Heard = nothing pops up.
;   Not heard = a reminder toast that stays until it hears you:
;     Check again        beeps and listens again; closes by itself when it hears you
;     I'm wearing them   shown only after a SECOND miss (or a mic problem): something may be wrong
;                        with the mic, so you can close it yourself (owner's choice 2026-11-23)
; * Listening starts only AFTER the sound has finished (+ HS_GAP_MS), so the beep leaking from a
;   headset lying on the desk is never taken for your answer.
; * Two modes (owner's design 2026-11-23):
;     strict  not sure you wear it: logged out of Q (no beeps while away), back in Q = check at once;
;             a miss = reminder + re-check every StrictEverySec (2 min) until it hears you.
;     light   sure you wear it: after a sign (heard answer, "I'm wearing them", or a call - ringing /
;             on a call counts as wearing it) the next check comes LightEveryMin (10 min) after the
;             LAST sign, so calls keep pushing it back. A light miss = strict again.
;   Never a beep during a ringing / live call, nor while you're logged out of Q.
; * Calibrate... (Settings > Calls & 3CX, tray > 3CX Q-login alert > Headset check): pick the sound
;   and the mic, record the quiet room, your answer after the beep (3 times, the softest counts)
;   and, optional, the same answer with the headset on the desk. It suggests the trigger level in
;   the gap and says whether the gap is clear. A slider lets you move it.
; * Off by default ([HeadsetCheck] Enabled=0 in data\live-captions.ini). It uses the Q alert's
;   watcher (q-watch.ahk), which runs while EITHER is on: with the Q alert off you get no Q toasts,
;   only this. Turning it on before calibrating opens Calibrate first.
; * The moment it hears you it stops listening and plays the sound again (AckOn, default on), so
;   you know you can stop answering.
; * The mic is read with Windows' own wave-in API, in memory only: nothing is recorded to a file,
;   the log (CALLER_LOG, "[headset]") holds only levels, times and outcomes.
; * If the mic can't be used, the reminder shows anyway (with the reason): it fails towards
;   reminding you. Every entry point is in try/catch: captions and the call are never affected.
; * Settings ([HeadsetCheck]): Enabled Sound Mic ThresholdDb ListenSec MinAwaySec StartDelaySec
;   MinSoundMs LightEveryMin StrictEverySec ReminderSec  +  calibration results NoiseDb ReplyDb DeskDb CalibratedAt
; Hooks: HsInit() (after QAlertInit), HsOnQState(state) (from QAHandle), HsShutdown()
; ==============================================================================

HS_FRAME_MS := 50                  ; one level reading per 50 ms
HS_RATE := 16000                   ; 16 kHz mono 16-bit is plenty for a loudness check
HS_GAP_MS := 300                   ; pause after the sound before listening
HS_DEFAULT_DB := -35               ; trigger level until you calibrate
HS_ITEM_ON := "Check my headset when I log back in to Q"
HS_ITEM_ACK := "Play the sound again when it hears me"
HS_DEFAULT_POS := "Bottom right"      ; its own spot (one of QA_POSITIONS); same spot as the Q alert = they stack
HS_MIC_DEFAULT := "Windows default microphone"
; key -> [label, default, min, max, tip]
HS_NUMS := Map(
    "ListenSec",     ["Listen after the beep (seconds)", 3, 1, 15, "How long it listens for your answer after the sound"],
    "MinAwaySec",    ["Logged out of Q at least (seconds)", 15, 0, 3600, "A shorter log-out (or a Q detection blip) doesn't trigger a check"],
    "StartDelaySec", ["Wait before the beep (seconds)", 0, 0, 60, "Time between seeing you back in Q and the beep (0 = at once)"],
    "MinSoundMs",    ["Answer must last at least (ms)", 50, 50, 2000, "50 = the loudest moment counts (a spike is enough). Raise it if bumps or clicks count as an answer."],
    "ThresholdDb",   ["Trigger level (dB, Calibrate sets it)", HS_DEFAULT_DB, -90, -1, "Louder than this after the beep = you answered. Calibrate sets it for your headset and room."],
    "LightEveryMin",  ["Light: check after (min, 0 = off)", 10, 0, 240, "When it's sure you wear the headset: the next check comes this long after the last sign (an answer, 'I'm wearing them' or a call). Calls keep pushing it back. Only while you're in Q and not on a call."],
    "StrictEverySec", ["Strict: re-check every (s, 0 = off)", 120, 0, 3600, "When it didn't hear you: beep and listen again this often while the reminder is up, until it hears you (10 seconds at least)"],
    "ReminderSec",   ["Reminder closes after (s, 0 = stays)", 0, 0, 3600, "0 = the reminder stays until you click it"])
hsMenu := ""
hsPosMenu := ""
hsQState := ""                     ; last known Q state: on / off / no3cx ("" = not seen yet)
hsAwaySince := 0                   ; A_TickCount when Q went off
hsLastOk := 0                      ; A_TickCount of the last sign you wear it (answer, button, call)
hsLastCheck := 0
hsGen := 0                         ; bumped to cancel a check on its way
hsBusy := false
hsRec := ""                        ; Map while the mic is open
hsToast := ""
hsToastText := ""
hsToastOk := ""                    ; the reminder's "I'm wearing them" (hidden until a second miss)
hsToastAgain := ""
hsToastBottomY := 0
hsToastH := 0                      ; the reminder's height while it shows (Q toasts stack past it)
hsRunFrames := 0                   ; loud frames in a row while a check listens
hsCal := ""                     ; Map while the Calibrate window is open

HsSetting(key, default := "") {
    try return IniRead(MIC_INI, "HeadsetCheck", key, default)
    return default
}

HsNum(key) {
    c := HS_NUMS[key]
    v := HsSetting(key, c[2])
    if !IsInteger(v)
        return c[2]
    return Min(c[4], Max(c[3], Integer(v)))
}

HsSetNum(key, v) {
    try IniWrite(Integer(v), MIC_INI, "HeadsetCheck", key)
    if (key = "StrictEverySec" && IsObject(hsToast))
        HsArmRecheck()
}

HsEnabled() => HsSetting("Enabled", 0) = "1"
HsCalibrated() => HsSetting("ThresholdDb", "") != ""
HsAckOn() => HsSetting("AckOn", 1) = "1"

HsAckToggle() {
    try IniWrite(HsAckOn() ? 0 : 1, MIC_INI, "HeadsetCheck", "AckOn")
    HsSyncMenu()
}

HsLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  [headset] " line "`n", CALLER_LOG, "UTF-8")
}

HsStatus(text) {
    try statusText.Text := "Status: headset check - " text
}

; ------------------------------------------------------------------ start / stop
HsInit() {
    global hsMenu, hsPosMenu
    try {
        m := Menu()
        m.Add(HS_ITEM_ON, (*) => HsToggle())
        m.Add(HS_ITEM_ACK, (*) => HsAckToggle())
        pm := Menu()
        for p in QA_POSITIONS
            pm.Add(p, (name, *) => HsSetPosition(name))
        hsPosMenu := pm
        m.Add("Where the reminder shows", pm)
        m.Add("Calibrate...", (*) => HsSafe(() => HsCalOpen(false)))
        m.Add("Check now (beep and listen)", (*) => HsSafe(() => HsRunCheck("now")))
        m.Add("More settings...", (*) => CSetShow())
        hsMenu := m
        if IsObject(qaMenu) {
            qaMenu.Add()
            qaMenu.Add("Headset check", m)
        }
        HsSyncMenu()
        SetTimer(HsTick, 30000)
    } catch as err {
        HsLog("start error: " err.Message)
    }
}

HsShutdown() {
    global hsGen
    hsGen += 1
    try HsRecAbort()
    try HsCloseToast()
    try HsCalClose()
}

HsSafe(fn) {
    try fn()
    catch as err {
        HsLog("error: " err.Message)
        HsStatus("problem: " err.Message " (captions unaffected)")
    }
}

HsSyncMenu() {
    try {
        if HsEnabled()
            hsMenu.Check(HS_ITEM_ON)
        else
            hsMenu.Uncheck(HS_ITEM_ON)
        if HsAckOn()
            hsMenu.Check(HS_ITEM_ACK)
        else
            hsMenu.Uncheck(HS_ITEM_ACK)
        cur := HsPosition()
        for p in QA_POSITIONS {
            if (p = cur)
                hsPosMenu.Check(p)
            else
                hsPosMenu.Uncheck(p)
        }
    }
}

; Tray and Settings both use this. Turning on before calibrating opens Calibrate (its Save turns it on).
HsToggle() {
    try {
        on := !HsEnabled()
        if (on && !HsCalibrated()) {
            HsStatus("calibrate first: the check turns on when you Save there")
            HsCalOpen(true)
            return
        }
        IniWrite(on ? 1 : 0, MIC_INI, "HeadsetCheck", "Enabled")
        HsSyncMenu()
        try QAWatcherSync()                      ; Q watcher runs while the alert or this is on
        if !on
            HsCancel()
        HsStatus(on ? "on (beeps and listens when you log back in to Q)" : "off")
    } catch as err {
        HsLog("toggle error: " err.Message)
    }
}

; ------------------------------------------------------------------ Q events (from QAHandle)
HsOnQState(state) {
    global hsQState, hsAwaySince
    try {
        if (state != "on" && state != "off" && state != "no3cx")
            return                                   ; unknown: keep what we had
        prev := hsQState
        hsQState := state
        if (state != "on") {
            if (prev = "on" || prev = "") {
                hsAwaySince := A_TickCount
                HsCancel()                           ; you left again: the next log-in checks
                HsCloseToast()
            }
            return
        }
        if ((prev = "off" || prev = "no3cx") && hsAwaySince && HsEnabled()) {
            away := (A_TickCount - hsAwaySince) // 1000
            hsAwaySince := 0
            if (away < HsNum("MinAwaySec")) {
                HsLog("back in Q after " away " s - shorter than " HsNum("MinAwaySec") " s, no check")
                return
            }
            g := hsGen
            SetTimer(() => (g = hsGen ? HsSafe(() => HsRunCheck("Q log-in after " away " s")) : 0), -Max(1, HsNum("StartDelaySec") * 1000))
        }
        hsAwaySince := 0
    } catch as err {
        HsLog("Q event error: " err.Message)
    }
}

HsOnCall() {
    try return (callerPhase = "ringing" || callerPhase = "on call")
    return false
}

; Every 30 s: a call counts as wearing the headset; the light check (strict re-checks run from the reminder)
HsTick() {
    global hsLastOk
    try {
        if HsOnCall() {
            hsLastOk := A_TickCount
            if IsObject(hsToast)
                HsCloseToast()                   ; on a call = wearing it
            return
        }
        every := HsNum("LightEveryMin")
        if (!HsEnabled() || every <= 0 || hsQState != "on" || hsBusy || IsObject(hsToast) || IsObject(hsCal))
            return
        since := A_TickCount - Max(hsLastOk, hsLastCheck)
        if (since >= every * 60000)
            HsRunCheck("light check, " every " min")
    } catch as err {
        HsLog("tick error: " err.Message)
    }
}

; ------------------------------------------------------------------ the check
HsCancel() {
    global hsGen, hsBusy
    hsGen += 1
    if hsBusy
        try HsRecAbort()
    hsBusy := false
}

HsRunCheck(reason) {
    global hsBusy, hsGen, hsLastCheck
    if (hsBusy || IsObject(hsCal))
        return
    if HsOnCall() {
        HsLog("check skipped (" reason "): a call is ringing or on")
        return
    }
    hsBusy := true
    hsGen += 1
    g := hsGen
    hsLastCheck := A_TickCount
    try {
        if IsObject(hsToast)
            HsToastSay("🔊 Listening... say something after the beep")
        dur := HsPlay(HsSoundPath())
        SetTimer(HsListen.Bind(g, reason), -(dur + HS_GAP_MS))
    } catch as err {
        hsBusy := false
        throw err
    }
}

HsListen(g, reason) {
    global hsRunFrames
    if (g != hsGen)
        return
    hsRunFrames := 0
    try {
        if !HsRecStart(HsSetting("Mic", ""), HsNum("ListenSec") * 1000, HsCheckFrame.Bind(g), HsHeard.Bind(g, reason))
            HsHeard(g, reason, "", "the microphone is busy")
    } catch as err {
        HsHeard(g, reason, "", err.Message)
    }
}

; Each 50 ms while a check listens: true = it heard you (loud for MinSoundMs) -> stop listening now
HsCheckFrame(g, db) {
    global hsRunFrames
    if (g != hsGen)
        return false
    hsRunFrames := db >= HsNum("ThresholdDb") ? hsRunFrames + 1 : 0
    return hsRunFrames >= Max(1, Ceil(HsNum("MinSoundMs") / HS_FRAME_MS))
}

HsHeard(g, reason, frames, why) {
    global hsBusy, hsLastOk
    if (g != hsGen)
        return
    hsBusy := false
    try {
        if !IsObject(frames) {
            HsLog("mic problem (" reason "): " why)
            HsShowReminder("I couldn't use the microphone (" why ").", true)
            return
        }
        lvl := HsSustained(frames, HsNum("MinSoundMs"))
        thr := HsNum("ThresholdDb")
        if (lvl >= thr) {
            hsLastOk := A_TickCount
            HsLog("heard you (" reason "): " lvl " dB, trigger " thr " dB, after " frames.Length * HS_FRAME_MS " ms")
            if HsAckOn()
                try HsPlay(HsSoundPath())            ; "got it" - you can stop answering
            HsCloseToast()
            HsStatus("heard you after the beep - headset on ✓")
        } else {
            HsLog("not heard (" reason "): " lvl " dB, trigger " thr " dB - reminder")
            HsShowReminder("I didn't hear you after the beep.")
        }
    } catch as err {
        HsLog("result error: " err.Message)
    }
}

; ------------------------------------------------------------------ the reminder toast
; First miss: only "Check again". A further miss (or a mic problem, showOk) adds "I'm wearing them".
HsShowReminder(detail, showOk := false) {
    global hsToast, hsToastText, hsToastOk, hsToastAgain, hsToastBottomY, hsToastH
    if IsObject(hsToast) {
        HsToastSay("🎧 Put your headset on  (" FormatTime(, "h:mm tt") ")`n"
            . (hsToastOk.Visible || showOk ? detail : "Still didn't hear you - is the mic OK?"))
        HsToastShowOk()
        return
    }
    s := A_ScreenDPI / 96
    w := Round(440 * s)
    h := Round(84 * s)
    pad := Round(12 * s)
    bw := Round(124 * s)
    bh := Round(30 * s)
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale +E0x08000000", "Headset reminder")
    g.BackColor := "3A2A06"
    g.SetFont("s11 cFDE68A", "Segoe UI")
    hsToastText := g.Add("Text", Format("x{} y{} w{} h{} +0x100", pad, Round(10 * s), w - 3 * pad - bw, h - Round(20 * s))
        , "🎧 Put your headset on  (" FormatTime(, "h:mm tt") ")`n" detail)
    g.SetFont("s9 c000000")
    ok := g.Add("Button", Format("x{} y{} w{} h{} Hidden", w - pad - bw, Round(9 * s), bw, bh), "I'm wearing them")
    again := g.Add("Button", Format("x{} y{} w{} h{}", w - pad - bw, (h - bh) // 2, bw, bh), "Check again")
    ok.OnEvent("Click", (*) => HsWearing())
    again.OnEvent("Click", (*) => HsSafe(() => HsRunCheck("check again")))
    TipSet(ok, "Close this reminder yourself - for when it can't hear you even with the headset on")
    TipSet(again, "Put your headset on, click, and answer after the beep: this closes by itself when it hears you")
    g.OnEvent("ContextMenu", (*) => hsMenu.Show())
    hsToast := g
    hsToastOk := ok
    hsToastAgain := again
    hsToastBottomY := h - Round(9 * s) - bh
    if showOk
        HsToastShowOk()
    hsToastH := h
    QAPlaceAt(HsPosition(), &x, &y, &down, w, h) ; its own spot; Q toasts stack past it when they share the spot
    g.Show(Format("NA x{} y{} w{} h{}", x, y, w, h))
    try QARestack()
    if (HsNum("ReminderSec") > 0)
        SetTimer(HsCloseToast, -HsNum("ReminderSec") * 1000)
    HsArmRecheck()
    HsStatus("reminder shown - put your headset on")
}

HsToastSay(text) {
    try hsToastText.Value := text
}

; Second miss: "Check again" moves down, "I'm wearing them" appears above it
HsToastShowOk() {
    try {
        if hsToastOk.Visible
            return
        hsToastAgain.GetPos(&ax)
        hsToastAgain.Move(ax, hsToastBottomY)
        hsToastOk.Visible := true
    }
}

HsWearing() {
    global hsLastOk
    hsLastOk := A_TickCount
    HsLog("'I'm wearing them' clicked")
    HsCancel()
    HsCloseToast()
}

HsArmRecheck() {
    sec := HsNum("StrictEverySec")
    SetTimer(HsRecheck, (sec > 0 && IsObject(hsToast)) ? Max(10, sec) * 1000 : 0)
}

HsRecheck() {
    if !IsObject(hsToast) {
        SetTimer(HsRecheck, 0)
        return
    }
    HsSafe(() => HsRunCheck("re-check while the reminder shows"))
}

HsCloseToast(*) {
    global hsToast, hsToastText, hsToastH
    SetTimer(HsRecheck, 0)
    SetTimer(HsCloseToast, 0)
    had := IsObject(hsToast)
    if had
        try hsToast.Destroy()
    hsToast := ""
    hsToastText := ""
    hsToastH := 0
    if had
        try QARestack()                          ; Q toasts slide back to the anchor spot
}

; Called by the Q alert's QARestack: puts the reminder at its own spot and returns its height when it
; shares the spot with the Q alert (their toasts then stack past it), else 0
HsToastHeight() {
    if !IsObject(hsToast)
        return 0
    try {
        hsToast.GetPos(, , &w)
        QAPlaceAt(HsPosition(), &x, &y, &down, w, hsToastH)
        hsToast.Move(x, y)
    }
    return HsPosition() = QAlertSetting("Position", QA_DEFAULT_POS) ? hsToastH : 0
}

HsPosition() {
    p := HsSetting("Position", HS_DEFAULT_POS)
    for x in QA_POSITIONS
        if (x = p)
            return x
    return HS_DEFAULT_POS
}

; Tray and Settings: the reminder's own spot (moves it now if it shows)
HsSetPosition(name) {
    try IniWrite(name, MIC_INI, "HeadsetCheck", "Position")
    HsSyncMenu()
    try QARestack()
    HsStatus("the reminder now shows at: " name)
}

; ------------------------------------------------------------------ sound
HsWindowsSounds() {
    list := []
    try {
        Loop Files, A_WinDir "\Media\*.wav"
            list.Push(A_LoopFileFullPath)
    }
    return list
}

HsDefaultSound() {
    for name in ["Windows Notify System Generic.wav", "Windows Notify.wav", "ding.wav", "chimes.wav"]
        if FileExist(A_WinDir "\Media\" name)
            return A_WinDir "\Media\" name
    return ""
}

HsSoundPath() {
    p := HsSetting("Sound", "")
    return (p != "" && FileExist(p)) ? p : HsDefaultSound()
}

; Plays the sound without waiting; returns how long it lasts (ms)
HsPlay(path) {
    if (path != "") {
        try {
            SoundPlay(path)
            return HsWavMs(path)
        }
    }
    SoundBeep(880, 200)                          ; no usable sound file: a plain short beep
    return 0
}

; Length of a .wav from its header (1 s if it can't be read)
HsWavMs(path) {
    try {
        b := FileRead(path, "RAW")
        if (b.Size < 44 || StrGet(b.Ptr, 4, "CP0") != "RIFF" || StrGet(b.Ptr + 8, 4, "CP0") != "WAVE")
            return 1000
        off := 12, rate := 0
        while (off + 8 <= b.Size) {
            id := StrGet(b.Ptr + off, 4, "CP0")
            size := NumGet(b, off + 4, "UInt")
            if (id = "fmt " && off + 16 <= b.Size)
                rate := NumGet(b, off + 16, "UInt")  ; byte rate
            else if (id = "data" && rate > 0)
                return Min(10000, Round(Min(size, b.Size - off - 8) * 1000 / rate))
            off += 8 + size + (size & 1)
        }
    }
    return 1000
}

; ------------------------------------------------------------------ mic (wave-in, memory only)
HsMicNames() {
    names := []
    try {
        caps := Buffer(80, 0)                    ; WAVEINCAPSW
        loop DllCall("winmm\waveInGetNumDevs", "UInt") {
            if !DllCall("winmm\waveInGetDevCapsW", "UPtr", A_Index - 1, "Ptr", caps, "UInt", 80, "UInt")
                names.Push(StrGet(caps.Ptr + 8, 32, "UTF-16"))
        }
    }
    return names
}

HsMicId(name) {
    if (name = "")
        return 0xFFFFFFFF                        ; WAVE_MAPPER = the Windows default
    for i, n in HsMicNames()
        if (n = name)
            return i - 1
    HsLog("mic '" name "' not found - using the Windows default")
    return 0xFFFFFFFF
}

; Opens the mic for ms milliseconds. onFrame(db) for each 50 ms (or ""), onDone(frames, why):
; frames = Array of levels (dBFS), or "" with the reason. Returns false if the mic is already in use here.
HsRecStart(micName, ms, onFrame, onDone) {
    global hsRec
    if IsObject(hsRec)
        return false
    fmt := Buffer(18, 0)                         ; WAVEFORMATEX: PCM, mono, 16 kHz, 16-bit
    NumPut("UShort", 1, "UShort", 1, "UInt", HS_RATE, "UInt", HS_RATE * 2, "UShort", 2, "UShort", 16, "UShort", 0, fmt)
    h := 0
    r := DllCall("winmm\waveInOpen", "Ptr*", &h, "UInt", HsMicId(micName), "Ptr", fmt, "UPtr", 0, "UPtr", 0, "UInt", 0, "UInt")
    if r
        throw Error("the microphone could not be opened (code " r ")")
    n := Ceil(ms / HS_FRAME_MS)
    bytes := HS_RATE * 2 * HS_FRAME_MS // 1000
    hsz := 4 * A_PtrSize + 16                    ; WAVEHDR
    data := Buffer(bytes * n, 0)
    hdrs := Buffer(hsz * n, 0)
    loop n {
        p := hdrs.Ptr + (A_Index - 1) * hsz
        NumPut("Ptr", data.Ptr + (A_Index - 1) * bytes, p, 0)
        NumPut("UInt", bytes, p, A_PtrSize)
        DllCall("winmm\waveInPrepareHeader", "Ptr", h, "Ptr", p, "UInt", hsz)
        DllCall("winmm\waveInAddBuffer", "Ptr", h, "Ptr", p, "UInt", hsz)
    }
    hsRec := Map("h", h, "data", data, "hdrs", hdrs, "n", n, "hsz", hsz, "next", 1, "frames", []
        , "onFrame", onFrame, "onDone", onDone, "started", A_TickCount)
    DllCall("winmm\waveInStart", "Ptr", h)
    SetTimer(HsRecPoll, 30)
    return true
}

HsRecPoll() {
    r := hsRec
    if !IsObject(r) {
        SetTimer(HsRecPoll, 0)
        return
    }
    try {
        while (r["next"] <= r["n"]) {
            p := r["hdrs"].Ptr + (r["next"] - 1) * r["hsz"]
            if !(NumGet(p, 2 * A_PtrSize + 8, "UInt") & 1)   ; WHDR_DONE
                break
            db := HsLevelDb(NumGet(p, 0, "Ptr"), NumGet(p, A_PtrSize + 4, "UInt"))
            r["frames"].Push(db)
            r["next"] += 1
            if IsObject(r["onFrame"]) {
                stop := false
                try stop := r["onFrame"](db)
                if (stop = true) {                   ; the listener has what it needs: stop early
                    HsRecFinish(true)
                    return
                }
            }
        }
        if (r["next"] > r["n"])
            HsRecFinish(true)
        else if (A_TickCount - r["started"] > r["n"] * HS_FRAME_MS + 3000)
            HsRecFinish(false, "the microphone stopped sending sound")
    } catch as err {
        HsRecFinish(false, err.Message)
    }
}

HsRecFinish(ok, why := "") {
    global hsRec
    r := hsRec
    if !IsObject(r)
        return
    hsRec := ""
    SetTimer(HsRecPoll, 0)
    try DllCall("winmm\waveInReset", "Ptr", r["h"])
    loop r["n"]
        try DllCall("winmm\waveInUnprepareHeader", "Ptr", r["h"], "Ptr", r["hdrs"].Ptr + (A_Index - 1) * r["hsz"], "UInt", r["hsz"])
    try DllCall("winmm\waveInClose", "Ptr", r["h"])
    cb := r["onDone"]
    if IsObject(cb) {
        try cb(ok ? r["frames"] : "", why)
        catch as err
            HsLog("after listening: " err.Message)
    }
}

HsRecAbort() {
    if IsObject(hsRec) {
        hsRec["onDone"] := ""
        HsRecFinish(false, "stopped")
    }
}

; Loudness of 16-bit samples, in dB below full scale (-100 = silence)
HsLevelDb(ptr, bytes) {
    n := bytes // 2
    if (n < 1)
        return -100.0
    sum := 0.0
    loop n {
        v := NumGet(ptr, (A_Index - 1) * 2, "Short")
        sum += v * v
    }
    rms := Sqrt(sum / n)
    return rms < 1 ? -100.0 : 20 * Log(rms / 32768)
}

; The loudest level that lasted at least minMs (50 ms = the single loudest moment, the default)
HsSustained(frames, minMs) {
    k := Max(1, Ceil(minMs / HS_FRAME_MS))
    best := -100.0
    if (frames.Length < k)
        k := Max(1, frames.Length)
    loop frames.Length - k + 1 {
        i := A_Index
        lo := 0.0
        loop k {
            v := frames[i + A_Index - 1]
            lo := (A_Index = 1 || v < lo) ? v : lo
        }
        best := Max(best, lo)
    }
    return Round(best, 1)
}

; ------------------------------------------------------------------ Calibrate window
HsCalOpen(enableOnSave) {
    global hsCal
    if IsObject(hsCal) {
        if enableOnSave
            hsCal["enable"] := true
        try WinActivate("ahk_id " hsCal["gui"].Hwnd)
        return
    }
    HsCancel()
    c := Map("enable", enableOnSave, "noise", "", "replies", [], "desk", "", "running", false)
    g := Gui("+AlwaysOnTop", "Headset check - calibrate")
    g.SetFont("s10", "Segoe UI")
    g.OnEvent("Close", (*) => HsCalClose())
    g.OnEvent("Escape", (*) => HsCalClose())
    c["gui"] := g
    W := 600
    g.Add("Text", "xm w" W " h40", "This teaches the check how loud your room is and how loud your answer is. "
        . "Use the headset you take calls with, sitting where you work.")

    ; sound
    c["soundPaths"] := HsWindowsSounds()
    cur := HsSoundPath()
    if (cur != "" && !HsHasPath(c["soundPaths"], cur))
        c["soundPaths"].InsertAt(1, cur)
    labels := []
    pick := 1
    for i, p in c["soundPaths"] {
        SplitPath(p, , , , &nm)
        labels.Push(nm)
        if (p = cur)
            pick := i
    }
    g.Add("Text", "xm y+10 w100 h26 +0x200", "Sound:")
    c["sound"] := g.Add("DropDownList", "x+6 yp+1 w330" (labels.Length ? " Choose" pick : ""), labels)
    TipAdd(g.Add("Button", "x+6 yp-1 w80 h27", "Browse..."), "Pick another .wav file for the beep").OnEvent("Click", (*) => HsCalBrowse())
    TipAdd(g.Add("Button", "x+6 yp w70 h27", "▶ Play"), "Hear the sound now (in your headset, if it is Windows' sound device)").OnEvent("Click", (*) => HsCalPlay())

    ; mic
    mics := [HS_MIC_DEFAULT]
    curMic := HsSetting("Mic", "")
    mpick := 1
    for n in HsMicNames() {
        mics.Push(n)
        if (n = curMic)
            mpick := mics.Length
    }
    g.Add("Text", "xm y+10 w100 h26 +0x200", "Microphone:")
    c["mic"] := g.Add("DropDownList", "x+6 yp+1 w492 Choose" mpick, mics)

    ; level meter
    g.Add("Text", "xm y+12 w100 h22 +0x200", "Level now:")
    c["meter"] := g.Add("Progress", "x+6 yp+3 w420 h16 Range0-100 c22D3EE", 0)
    c["meterTxt"] := g.Add("Text", "x+8 yp-3 w66 h22 +0x200", "")

    ; steps
    sec := HsNum("ListenSec")
    c["b1"] := TipAdd(g.Add("Button", "xm y+16 w180 h34", "1. Quiet room"), "Listens " sec " s while you stay quiet")
    g.Add("Text", "x+10 yp w410 h34 +0x200", "Stay quiet for " sec " seconds (the room's normal noise).")
    c["r1"] := g.Add("Text", "xm+190 y+2 w410 h20 c1D4ED8", "")
    c["b2"] := TipAdd(g.Add("Button", "xm y+10 w180 h34", "2. Your answer (x3)"), "Three beeps; answer after each one")
    g.Add("Text", "x+10 yp w410 h34", "Headset ON. After each beep, answer the way you will every time (say `"yep`", tap the mic...).")
    c["r2"] := g.Add("Text", "xm+190 y+2 w410 h20 c1D4ED8", "")
    c["b3"] := TipAdd(g.Add("Button", "xm y+10 w180 h34", "3. Headset on the desk"), "Optional: shows whether the mic can tell on-your-head from on-the-desk")
    g.Add("Text", "x+10 yp w410 h34", "Optional, recommended: put the headset on the desk and answer the same way from your seat.")
    c["r3"] := g.Add("Text", "xm+190 y+2 w410 h20 c1D4ED8", "")
    c["b1"].OnEvent("Click", (*) => HsCalStep(1))
    c["b2"].OnEvent("Click", (*) => HsCalStep(2))
    c["b3"].OnEvent("Click", (*) => HsCalStep(3))

    ; result + trigger level
    c["verdict"] := g.Add("Text", "xm y+16 w" W " h40", "Do steps 1 and 2 (3 if you can). The trigger level is then set in the gap.")
    g.Add("Text", "xm y+6 w100 h26 +0x200", "Trigger level:")
    thr := HsNum("ThresholdDb")
    c["slider"] := g.Add("Slider", "x+6 yp w420 h26 Range10-99 TickInterval10 AltSubmit", thr + 100)
    c["slider"].OnEvent("Change", (*) => HsCalSliderText())
    c["thrTxt"] := g.Add("Text", "x+8 yp w66 h26 +0x200", thr " dB")
    TipSet(c["slider"], "An answer louder than this (and at least the minimum length) counts as `"headset on`". Right = needs a louder answer.")

    save := g.Add("Button", "xm+" (W - 190) " y+16 w90 h30 Default", "Save")
    save.OnEvent("Click", (*) => HsCalSave())
    g.Add("Button", "x+10 yp w90 h30", "Cancel").OnEvent("Click", (*) => HsCalClose())
    hsCal := c
    g.Show()
}

HsHasPath(list, p) {
    for x in list
        if (x = p)
            return true
    return false
}

HsCalSound() {
    c := hsCal
    i := c["sound"].Value
    return (i >= 1 && i <= c["soundPaths"].Length) ? c["soundPaths"][i] : HsDefaultSound()
}

HsCalMic() {
    v := hsCal["mic"].Text
    return v = HS_MIC_DEFAULT ? "" : v
}

HsCalBrowse() {
    c := hsCal
    c["gui"].Opt("+OwnDialogs")
    f := FileSelect(1, A_WinDir "\Media", "Pick a sound", "Sounds (*.wav)")
    if (f = "")
        return
    if !HsHasPath(c["soundPaths"], f) {
        c["soundPaths"].Push(f)
        SplitPath(f, , , , &nm)
        c["sound"].Add([nm])
    }
    for i, p in c["soundPaths"]
        if (p = f)
            c["sound"].Choose(i)
}

HsCalPlay() {
    try HsPlay(HsCalSound())
}

HsCalMeter(db) {
    try {
        hsCal["meter"].Value := Max(0, Min(100, Round((db + 80) * 100 / 80)))
        hsCal["meterTxt"].Value := Round(db) " dB"
    }
}

HsCalButtons(on) {
    for k in ["b1", "b2", "b3"]
        try hsCal[k].Enabled := on
}

HsCalStep(step) {
    c := hsCal
    if (!IsObject(c) || c["running"])
        return
    if hsBusy {
        c["verdict"].Value := "A headset check is running - try again in a few seconds."
        return
    }
    c["running"] := true
    HsCalButtons(false)
    if (step = 1) {
        c["r1"].Value := "Listening... stay quiet"
        HsCalListen(0, (lvl) => HsCalGot(1, lvl))
    } else if (step = 2) {
        c["replies"] := []
        HsCalReplyRound(1)
    } else {
        c["r3"].Value := "Wait for the beep, then answer from your seat"
        HsCalListen(HsCalPlayMs(), (lvl) => HsCalGot(3, lvl))
    }
}

HsCalPlayMs() {
    return HsPlay(HsCalSound()) + HS_GAP_MS
}

HsCalReplyRound(n) {
    if !IsObject(hsCal)
        return
    hsCal["r2"].Value := "Beep " n " of 3: answer after the beep"
    HsCalListen(HsCalPlayMs(), (lvl) => HsCalGotReply(n, lvl))
}

; Waits delayMs, then listens ListenSec; done(level) gets the sustained level, or "" on a problem
HsCalListen(delayMs, done) {
    SetTimer(() => HsCalListenNow(done), -Max(1, delayMs))
}

HsCalListenNow(done) {
    if !IsObject(hsCal)
        return
    try {
        if !HsRecStart(HsCalMic(), HsNum("ListenSec") * 1000, HsCalMeter, (frames, why) => HsCalHeard(done, frames, why))
            HsCalHeard(done, "", "the microphone is busy")
    } catch as err {
        HsCalHeard(done, "", err.Message)
    }
}

HsCalHeard(done, frames, why) {
    if !IsObject(hsCal)
        return
    HsCalMeter(-100)
    if !IsObject(frames) {
        hsCal["running"] := false
        HsCalButtons(true)
        hsCal["verdict"].Value := "⚠ The microphone couldn't be used: " why ". Pick another microphone above and try again."
        return
    }
    done(HsSustained(frames, HsNum("MinSoundMs")))
}

HsCalGot(step, lvl) {
    c := hsCal
    if (step = 1) {
        c["noise"] := lvl
        c["r1"].Value := "Room, loudest moment: " lvl " dB"
    } else {
        c["desk"] := lvl
        c["r3"].Value := "On the desk, loudest moment: " lvl " dB"
    }
    HsCalDone()
}

HsCalGotReply(n, lvl) {
    c := hsCal
    c["replies"].Push(lvl)
    txt := ""
    for v in c["replies"]
        txt .= (txt = "" ? "" : ",  ") v
    c["r2"].Value := "Loudest moment of each answer: " txt " dB"
    if (n < 3) {
        SetTimer(() => HsCalReplyRound(n + 1), -700)
        return
    }
    c["r2"].Value .= "   (softest " HsMinOf(c["replies"]) " dB counts)"
    HsCalDone()
}

HsMinOf(arr) {
    m := ""
    for v in arr
        m := (m = "" || v < m) ? v : m
    return m
}

HsCalDone() {
    c := hsCal
    c["running"] := false
    HsCalButtons(true)
    if (c["noise"] = "" || c["replies"].Length < 3) {
        c["verdict"].Value := c["noise"] = "" ? "Now step 1 (quiet room)." : "Now step 2 (your answer)."
        return
    }
    soft := HsMinOf(c["replies"])
    floor := c["noise"]
    if (c["desk"] != "" && c["desk"] > floor)
        floor := c["desk"]
    gap := Round(soft - floor, 1)
    thr := Round((soft + floor) / 2)
    thr := Max(-90, Min(-1, thr))
    c["slider"].Value := thr + 100
    HsCalSliderText()
    against := c["desk"] != "" ? "the headset on the desk" : "the quiet room"
    if (gap >= 10)
        c["verdict"].Value := "✓ Good: your softest answer is " gap " dB louder than " against ". Trigger level set in the middle - Save to keep it."
    else if (gap >= 5)
        c["verdict"].Value := "⚠ It may work: only " gap " dB between your softest answer and " against ". A louder answer (or a mic tap) makes it surer."
    else
        c["verdict"].Value := "✗ Too close (" gap " dB): it can't tell your answer from " against ". Try a louder answer, a mic tap, or another microphone."
}

HsCalSliderText() {
    try hsCal["thrTxt"].Value := (hsCal["slider"].Value - 100) " dB"
}

HsCalSave() {
    c := hsCal
    try {
        IniWrite(HsCalSound(), MIC_INI, "HeadsetCheck", "Sound")
        IniWrite(HsCalMic(), MIC_INI, "HeadsetCheck", "Mic")
        IniWrite(c["slider"].Value - 100, MIC_INI, "HeadsetCheck", "ThresholdDb")
        if (c["noise"] != "")
            IniWrite(c["noise"], MIC_INI, "HeadsetCheck", "NoiseDb")
        if c["replies"].Length
            IniWrite(HsMinOf(c["replies"]), MIC_INI, "HeadsetCheck", "ReplyDb")
        if (c["desk"] != "")
            IniWrite(c["desk"], MIC_INI, "HeadsetCheck", "DeskDb")
        IniWrite(FormatTime(, "yyyy-MM-dd HH:mm"), MIC_INI, "HeadsetCheck", "CalibratedAt")
        HsLog("calibrated: room " c["noise"] " dB, softest answer " HsMinOf(c["replies"]) " dB, desk " c["desk"] " dB, trigger " (c["slider"].Value - 100) " dB")
        if c["enable"] {
            IniWrite(1, MIC_INI, "HeadsetCheck", "Enabled")
            HsSyncMenu()
            try QAWatcherSync()
            HsStatus("on (beeps and listens when you log back in to Q)")
        } else
            HsStatus("calibration saved")
    } catch as err {
        HsLog("calibration save error: " err.Message)
        HsStatus("calibration could not be saved: " err.Message)
    }
    HsCalClose()
}

HsCalClose() {
    global hsCal
    if !IsObject(hsCal)
        return
    c := hsCal
    hsCal := ""
    try HsRecAbort()
    try c["gui"].Destroy()
}
