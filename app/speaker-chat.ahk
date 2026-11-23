; ==============================================================================
; speaker-chat.ahk  -  agent / customer bubbles in the Chat view (prefix SpkChat*)
;
; The Companion side of speaker-detect.ahk. OFF by default for everyone: tray >
; "Speaker detection" or Settings > Captions & mic, saved in live-captions.ini
; [Speaker] Enabled (the detector's own settings are in the same section).
;
; Needs Windows Live Captions to hear the mic too: Live Captions > Settings (gear) >
; Preferences > "Include microphone audio". If that is off, the detector notices
; (you talk, no captions come) and this shows a hint; meanwhile every word is the
; customer's, as before.
;
; What it does while on:
;   * New caption words -> SpkJudge says who. Someone else talking = a new bubble,
;     the same way a pause starts one (ProcessSnapshot asks SpkChatSwitch).
;   * Each live bubble carries .Speaker: agent | customer | unsure. "unsure" turns
;     into the first clear answer for that bubble. [Speaker] Unsure=previous gives
;     unsure words to the last speaker instead.
;   * Chat view: the agent's bubbles sit on the right (indented for now), unsure ones
;     are marked "?". Right-click a bubble > "This is me" / "This is the customer"
;     fixes it (works on saved calls too, and even with detection off).
;   * Prompts: the whole conversation, one line per bubble, "Agent: ..." /
;     "Customer: ..." (SpkChatPromptTranscript). Without any speaker = as before.
;   * Saved calls: "chatSpeakers", parallel to "chatBubbles" (older calls have none
;     and show as before). Deleted bubbles keep their speaker for Undo.
;
; Turning it on turns off the experimental whisper mic captions (they would caption
; your words twice), and the other way round.
; Safety: every entry point catches its own errors; with a problem it behaves as off.
; ==============================================================================

SPKCHAT_TRAY := "Speaker detection (agent / customer bubbles)"
SPKCHAT_LABELS := Map("agent", "Agent", "customer", "Customer", "unsure", "Not sure who")
SPKCHAT_THRESHOLDS := ["Auto - above the room noise", "Fixed level"]
SPKCHAT_UNSURE := ["Mark it with ?", "Give it to the last speaker"]
SPKCHAT_DEFAULT_DEV := "(Windows communications device)"
SPKCHAT_LAGMODES := ["Auto - learned while you talk", "Fixed - the values below"]
; Fine-tuning fields: [key, label, min, max, tip, scale]. A new tuning value = one row here (+ its
; default in SPK_DEFAULTS). scale 100 = shown as a percent.
SPKCHAT_TUNING := [
    ["MinWindowMs", "Looks back from the words, ms", 200, 3000, "How much sound before each new word is checked. Longer = steadier, but slower to notice a new speaker"],
    ["LeadMs", "Looks ahead of the words, ms", 0, 1500, "A little sound after, because the delay varies from word to word"],
    ["OldestWeight", "Oldest sound counts, %", 0, 100, "100 = all of the window counts the same. Lower = the newest sound decides more (catches a new speaker sooner)", 100],
    ["Margin", "Winner must lead by, %", 100, 400, "160 = the winner talked at least 1.6 times as much; closer than that = not sure", 100],
    ["MinTalkMs", "Least talking that counts, ms", 0, 1000, "Less than this from both sides = nobody heard yet"],
    ["SoloMinMs", "...unless only one side made sound, ms", 0, 500, "If only one side made any sound at all, this little is enough"],
    ["StartMs", "Loud this long to start talking, ms", 0, 1000, "Clicks and bumps shorter than this don't count"],
    ["HangMs", "Still talking after a sound, ms", 0, 2000, "Short gaps between words stay 'talking'"],
    ["BleedExtraDb", "Mic extra while customer talks, dB", 0, 30, "The customer leaking into your mic stays the customer's. Higher = you must be louder to count while they talk"],
    ["NoiseRiseDbPerSec", "Room noise may rise, dB per second", 0, 10, "How fast the learned room noise follows a noisier room"],
    ["MicMinDb", "Mic: never count quieter than, dB", -100, 0, "Auto mode: nothing below this counts as you"],
    ["OutMinDb", "Output: never count quieter than, dB", -100, 0, "Auto mode: nothing below this counts as the customer"],
    ["LagMinMs", "Delay learning: shortest, ms", 0, 2000, "Learned delays shorter than this are ignored"],
    ["LagMaxMs", "Delay learning: longest, ms", 500, 10000, "Learned delays longer than this are ignored"],
    ["LagStartMs", "Delay before anything is learned, ms", 100, 5000, "Used until the first delay is learned"],
    ["QuietMs", "Silence that teaches the delay, ms", 200, 5000, "Someone starting after this much silence = a delay to learn from"],
    ["MicCheckSoloMs", "Mic check: you talking alone, ms", 500, 10000, "You talking alone this long must bring captions..."],
    ["MicCheckMisses", "Mic check: misses before the hint", 1, 10, "...this many times without = Live Captions isn't hearing your mic"]
]

spkChatOn := false
spkChatVerdict := ""        ; {count, who}: the answer for the caption change being processed
spkChatLastWho := ""        ; agent | customer: who had the last clear bubble
spkChatHinted := ""         ; the mic hint already shown ("no" = shown for this "not heard")
spkChatCal := ""            ; the running calibration

SpkChatInit() {
    try {
        SpkUseIni(MIC_INI)
        A_TrayMenu.Insert("1&", SPKCHAT_TRAY, (*) => SpkChatSafe(SpkChatToggle))
        if (SpkCfg("Enabled") = "1")
            SpkChatSetOn(true, false)
        SpkChatSyncTray()
        chatCtxMenu.Insert("Delete bubble", "This is me (agent)", (*) => SpkChatSafe(() => SpkChatFix("agent")))
        chatCtxMenu.Insert("Delete bubble", "This is the customer", (*) => SpkChatSafe(() => SpkChatFix("customer")))
        chatCtxMenu.Insert("Delete bubble")
    } catch as err {
        SpkChatReport(err)
    }
}

SpkChatShutdown() {
    try SpkStop()
}

SpkChatToggle() => SpkChatSetOn(!spkChatOn, true)

SpkChatSetOn(on, save) {
    global spkChatOn, spkChatHinted
    if (on && micEnabled) {
        ToggleMicCaptions()                      ; whisper mic captions would caption your words twice
        statusText.Text := "Status: experimental mic captions turned off - speaker detection replaces them"
    }
    if on {
        ok := SpkStart(MIC_INI)
        spkChatOn := true
        spkChatHinted := ""
        SetTimer(SpkChatWatch, 2000)
        statusText.Text := ok ? "Status: speaker detection on - your bubbles go on the right"
            : "Status: speaker detection on, but no sound device can be read yet (" SpkReason ")"
    } else {
        SpkStop()
        spkChatOn := false
        SetTimer(SpkChatWatch, 0)
        if save
            statusText.Text := "Status: speaker detection off"
    }
    if save
        SpkSetCfg("Enabled", on ? "1" : "0")
    SpkChatSyncTray()
    RenderTranscript()
}

SpkChatSyncTray() {
    try {
        if spkChatOn
            A_TrayMenu.Check(SPKCHAT_TRAY)
        else
            A_TrayMenu.Uncheck(SPKCHAT_TRAY)
    }
}

; New call: who spoke last belongs to the old call
SpkChatReset() {
    global spkChatLastWho, spkChatVerdict
    spkChatLastWho := ""
    spkChatVerdict := ""
}

; ------------------------------------------------------------------------------
; Capture hooks (called from ProcessSnapshot only where new words arrive)
; ------------------------------------------------------------------------------
; Who said the new words of this caption change: agent | customer | unsure | none ("" = off).
; Asked once per change (cached on changeCount), so the lag/window logic sees each chunk once.
SpkChatWho() {
    global spkChatVerdict
    if !spkChatOn
        return ""
    try {
        if (IsObject(spkChatVerdict) && spkChatVerdict.count = changeCount)
            return spkChatVerdict.who
        who := SpkJudge().who
        spkChatVerdict := {count: changeCount, who: who}
        return who
    } catch as err {
        SpkChatReport(err)
        return ""
    }
}

; ProcessSnapshot calls this wherever new words arrive - BEFORE deciding about a new bubble, so
; every chunk is judged right when it shows up (a pause alone used to skip it: the first words
; of a turn then went to the previous speaker, and the lag was learned one chunk late).
SpkChatNoteWords() {
    if spkChatOn
        SpkChatWho()
}

; True when the new words are clearly someone else's than bubble's -> start a new bubble
SpkChatSwitch(bubble) {
    if (!spkChatOn || !IsObject(bubble))
        return false
    who := SpkChatWho()
    if (who != "agent" && who != "customer")
        return false
    sp := SpkChatSpeaker(bubble)
    return (sp = "agent" || sp = "customer") && sp != who && !bubble.HasOwnProp("SpeakerFixed")
}

; Gives bubble its speaker (new bubble) or settles an unsure one. Only call it when new
; words went into bubble during this caption change.
SpkChatTag(bubble) {
    global spkChatLastWho
    if (!spkChatOn || !IsObject(bubble) || bubble.HasOwnProp("SpeakerFixed"))
        return
    who := SpkChatWho()
    sp := SpkChatSpeaker(bubble)
    if (who = "agent" || who = "customer") {
        if (sp = "" || sp = "unsure")              ; a new bubble, or the first clear answer for an unsure one
            bubble.Speaker := who
    } else if (who = "unsure" && sp = "") {
        if (SpkCfg("Unsure") != "previous")
            bubble.Speaker := "unsure"
        else if (spkChatLastWho != "")
            bubble.Speaker := spkChatLastWho
    }
    ; who = none (nobody heard yet, e.g. the first words of a turn): wait for a clear answer.
    ; Until then the bubble shows plain, as before (also when the meters can't be read at all).
    sp := SpkChatSpeaker(bubble)
    if (sp = "agent" || sp = "customer")
        spkChatLastWho := sp
}

; After a caption change: the bubble that got new words gets its speaker settled
SpkChatAfterSnapshot(bubble) {
    if (spkChatOn && IsObject(spkChatVerdict) && spkChatVerdict.count = changeCount)
        SpkChatTag(bubble)
}

SpkChatSpeaker(bubble) => (IsObject(bubble) && bubble.HasOwnProp("Speaker")) ? bubble.Speaker : ""

; Speakers of the live bubbles, in the same order as BubbleTexts() (empty bubbles skipped)
BubbleSpeakers() {
    out := []
    for bubble in bubbles {
        if (BubbleText(bubble) != "")
            out.Push(SpkChatSpeaker(bubble))
    }
    return out
}

; A saved call's speakers, or [] when it has none / they don't line up with its bubbles
SpkChatSavedSpeakers(s) {
    try {
        if (s.Has("chatSpeakers") && s["chatSpeakers"] is Array && s["chatSpeakers"].Length = s["chatBubbles"].Length)
            return s["chatSpeakers"]
    }
    return []
}

; The speakers of the call on screen (reviewed or live)
SpkChatViewedSpeakers() => IsObject(reviewCall) ? SpkChatSavedSpeakers(reviewCall) : BubbleSpeakers()

SpkChatAnyKnown(speakers) {
    for sp in speakers {
        if (sp != "")
            return true
    }
    return false
}

; For PersistCurrentCall: saved only once some bubble has a speaker (older format otherwise)
SpkChatPersist(call) {
    sp := BubbleSpeakers()
    if SpkChatAnyKnown(sp)
        call["chatSpeakers"] := sp
    else if call.Has("chatSpeakers")
        call.Delete("chatSpeakers")
}

; ------------------------------------------------------------------------------
; Chat view and prompts
; ------------------------------------------------------------------------------
; How bubble i looks in the Chat view: {side: left | right, faded}. The agent's on the right,
; "not sure who" faded; no speaker (detection off, older calls) = on the left, as before.
SpkChatLook(speakers, i) {
    sp := i <= speakers.Length ? speakers[i] : ""
    return {side: sp = "agent" ? "right" : "left", faded: sp = "unsure"}
}

; "Customer: ...`nAgent: ..." - one line per bubble; "" when no bubble has a speaker
SpkChatLabeled(texts, speakers, nl := "`n") {
    if !SpkChatAnyKnown(speakers)
        return ""
    out := ""
    for i, text in texts {
        sp := i <= speakers.Length ? speakers[i] : ""
        label := SPKCHAT_LABELS.Has(sp) ? SPKCHAT_LABELS[sp] : "Customer"
        out .= (out = "" ? "" : nl) label ": " text
    }
    return out
}

; The transcript for prompts: labelled when speakers are known, else the plain lines (as before)
SpkChatPromptTranscript(nl := "`r`n") {
    texts := IsObject(reviewCall) ? reviewCall["chatBubbles"] : BubbleTexts()
    return SpkChatLabeled(texts, SpkChatViewedSpeakers(), nl)
}

; How follow-ups introduce the new text: with speakers it holds both sides
SpkChatNewLead() => SpkChatAnyKnown(BubbleSpeakers()) ? "New in the conversation since my last message:" : "The customer just said:"

; ------------------------------------------------------------------------------
; Fixing a bubble by hand (right-click > This is me / This is the customer)
; ------------------------------------------------------------------------------
SpkChatFix(who) {
    global spkChatLastWho
    p := pickedBubble
    if (!IsObject(p) || !p.HasProp("type") || p.type != "customer") {
        statusText.Text := "Status: right-click the bubble you want to change first (Chat view)"
        return
    }
    if IsObject(reviewCall) {
        if !(p.session == reviewCall)
            return
        cb := reviewCall["chatBubbles"]
        sp := SpkChatSavedSpeakers(reviewCall)
        if (sp.Length = 0) {                       ; a call saved without speakers: start a list
            sp := []
            Loop cb.Length
                sp.Push("")
            reviewCall["chatSpeakers"] := sp
        }
        if (p.index < 1 || p.index > sp.Length)
            return
        sp[p.index] := who
        SaveHistory()
    } else {
        if !BubbleIsLive(p.bubble) {
            statusText.Text := "Status: that bubble is no longer there; click a bubble again"
            return
        }
        p.bubble.Speaker := who
        p.bubble.SpeakerFixed := true              ; detection leaves it alone from now on
        if (p.bubble == activeBubble)
            spkChatLastWho := who
        PersistCurrentCall()
    }
    RenderTranscript()
    statusText.Text := "Status: bubble marked as " (who = "agent" ? "you (agent)" : "the customer")
}

; Deleting / restoring bubbles keeps the speaker with them
SpkChatNoteRemoved(rec, speaker) {
    if (speaker != "")
        rec["speaker"] := speaker
}

SpkChatSavedRemoveAt(session, index) {
    sp := SpkChatSavedSpeakers(session)
    if (sp.Length && index <= sp.Length)
        return sp.RemoveAt(index)
    return ""
}

SpkChatSavedInsertAt(session, index, rec) {
    if !session.Has("chatSpeakers")
        return
    sp := session["chatSpeakers"]
    if (sp is Array && sp.Length + 1 = session["chatBubbles"].Length)     ; the bubble is already back in
        sp.InsertAt(Min(index, sp.Length + 1), rec.Get("speaker", ""))
}

SpkChatRestoreLive(bubble, rec) {
    sp := rec.Get("speaker", "")
    if (sp != "")
        bubble.Speaker := sp
}

; ------------------------------------------------------------------------------
; "Live Captions is not hearing your mic" hint
; ------------------------------------------------------------------------------
SpkChatWatch() {
    global spkChatHinted
    try {
        heard := SpkMicHeard()
        if (heard = "no" && spkChatHinted != "no") {
            spkChatHinted := "no"
            statusText.Text := "Status: Live Captions isn't captioning your mic - turn on Live Captions > Settings > Preferences > Include microphone audio"
            TrayTip("Your words are not being captioned. In Live Captions: Settings (gear) > Preferences > "
                . "Include microphone audio. Until then every bubble counts as the customer's.", "Speaker detection", "Iconi")
        } else if (heard = "yes" && spkChatHinted = "no") {
            spkChatHinted := "yes"
            statusText.Text := "Status: Live Captions is captioning your mic again"
        }
    }
}

; Two lines for Settings (live rows): the levels, then lag + whether Live Captions hears the mic
SpkChatLevelsText() {
    if !spkChatOn
        return "Off."
    L := SpkLevels()
    return "Mic: " SpkChatSide(L.micOk, L.micDb, L.micFloor, L.micTalk) "   ·   Output: " SpkChatSide(L.outOk, L.outDb, L.outFloor, L.outTalk)
}

SpkChatSide(ok, db, floor, talk) {
    if !ok
        return "can't read"
    s := db <= SPK_SILENT_DB + 1 ? "silent" : Round(db) " dB"
    if (floor != "")
        s .= " (noise " Round(floor) ")"
    return s (talk ? "  TALKING" : "")
}

SpkChatHeardText() {
    if !spkChatOn
        return ""
    if (SpkReason != "")
        return SpkReason
    heard := Map("yes", "yes", "no", "NO - turn on Include microphone audio", "unknown", "not checked yet (talk a little)")[SpkMicHeard()]
    return "Learned delay: you " SpkLearnedLag(SPK_MIC) " ms, customer " SpkLearnedLag(SPK_OUT) " ms"
        . (SpkCfg("LagMode") = "fixed" ? " (using Fixed)" : "") "   ·   Live Captions hears your mic: " heard
}

; ------------------------------------------------------------------------------
; Settings window fields (Captions & mic section)
; ------------------------------------------------------------------------------
SpkChatFields(sec) {
    f := []
    f.Push({sec: sec, type: "head", label: "Speaker detection (who is talking: you or the customer)"})
    f.Push({sec: sec, type: "note", label: "Your bubbles go on the right and prompts say `"Agent:`" / `"Customer:`". "
        . "Needs Live Captions to hear your mic: Live Captions > Settings (gear) > Preferences > Include microphone audio."})
    f.Push({sec: sec, type: "check", key: "Spk.On", label: "Speaker detection", def: 0
        , tip: "Off by default. Tells your voice (mic) from the customer's (headset sound) by their sound levels - nothing is recorded"
        , get: () => spkChatOn, flip: () => SpkChatSafe(SpkChatToggle)})
    f.Push({sec: sec, type: "live", get: SpkChatLevelsText})
    f.Push({sec: sec, type: "live", get: SpkChatHeardText})
    f.Push({sec: sec, type: "choice", key: "Spk.Mic", label: "Microphone (you)", choices: SpkChatDevNames(SPK_MIC), def: SPKCHAT_DEFAULT_DEV
        , tip: "The mic 3CX uses - your headset", get: () => SpkChatDevGet(SPK_MIC), set: (v) => SpkChatDevSet(SPK_MIC, v)})
    f.Push({sec: sec, type: "choice", key: "Spk.Out", label: "Sound output (the customer)", choices: SpkChatDevNames(SPK_OUT), def: SPKCHAT_DEFAULT_DEV
        , tip: "Where 3CX plays the customer - your headset", get: () => SpkChatDevGet(SPK_OUT), set: (v) => SpkChatDevSet(SPK_OUT, v)})
    f.Push({sec: sec, type: "choice", key: "Spk.Threshold", label: "Talking level", choices: SPKCHAT_THRESHOLDS, def: SPKCHAT_THRESHOLDS[1]
        , tip: "Auto learns your room's noise and counts as talking what is louder than it. Fixed = the levels below in dB."
        , get: () => SPKCHAT_THRESHOLDS[SpkCfg("Threshold") = "fixed" ? 2 : 1]
        , set: (v) => SpkSetCfg("Threshold", v = SPKCHAT_THRESHOLDS[2] ? "fixed" : "auto")})
    f.Push(SpkChatNum(sec, "MicAboveNoiseDb", "Mic: dB above noise (Auto)", 0, 40, "Calibrate sets this. Higher = needs a louder voice to count as you"))
    f.Push(SpkChatNum(sec, "OutAboveNoiseDb", "Output: dB above noise (Auto)", 0, 40, "Higher = the customer's sound must be louder to count"))
    f.Push(SpkChatNum(sec, "MicOnDb", "Mic level (Fixed), dB", -80, 0, "Only used with Talking level = Fixed"))
    f.Push(SpkChatNum(sec, "OutOnDb", "Output level (Fixed), dB", -80, 0, "Only used with Talking level = Fixed"))
    f.Push({sec: sec, type: "choice", key: "Spk.Unsure", label: "When it can't tell who spoke", choices: SPKCHAT_UNSURE, def: SPKCHAT_UNSURE[1]
        , tip: "Both talked at once, or too little to tell. Either way you can right-click a bubble to fix it."
        , get: () => SPKCHAT_UNSURE[SpkCfg("Unsure") = "previous" ? 2 : 1]
        , set: (v) => SpkSetCfg("Unsure", v = SPKCHAT_UNSURE[2] ? "previous" : "faded")})
    f.Push({sec: sec, type: "buttons", items: [["Calibrate mic...", () => SpkChatSafe(SpkChatCalStart)
        , "Stay quiet 4 seconds, then read aloud 6 seconds: it works out how loud you are compared to the room"]]})

    ; Caption delay: learned, or fixed values (e.g. copied from the learned ones shown above)
    f.Push({sec: sec, type: "choice", key: "Spk.LagMode", label: "Caption delay", choices: SPKCHAT_LAGMODES, def: SPKCHAT_LAGMODES[1]
        , tip: "How long words take to show up in Live Captions after they're said. Auto learns it for you and for the customer; "
            . "the line above shows what it learned."
        , get: () => SPKCHAT_LAGMODES[SpkCfg("LagMode") = "fixed" ? 2 : 1]
        , set: (v) => SpkSetCfg("LagMode", v = SPKCHAT_LAGMODES[2] ? "fixed" : "auto")})
    f.Push(SpkChatNum(sec, "MicLagMs", "Your words' delay (Fixed), ms", 100, 5000, "Only used with Caption delay = Fixed"))
    f.Push(SpkChatNum(sec, "OutLagMs", "Customer's words' delay (Fixed), ms", 100, 5000, "Only used with Caption delay = Fixed"))

    f.Push({sec: sec, type: "head", label: "Speaker detection - fine-tuning (advanced)"})
    f.Push({sec: sec, type: "note", label: "Changes apply right away. With the debug trace on (tray), every decision is logged "
        . "with its numbers in data\debug-trace.log (times and levels only, never words)."})
    for n in SPKCHAT_TUNING
        f.Push(SpkChatNum(sec, n[1], n[2], n[3], n[4], n[5], n.Length >= 6 ? n[6] : 1))
    return f
}

; A number field. scale: the setting is stored divided by it (100 = shown as a percent, e.g. 1.6 -> 160)
SpkChatNum(sec, key, label, lo, hi, tip, scale := 1) {
    return {sec: sec, type: "num", key: "Spk." key, label: label, hint: lo " to " hi, tip: tip, min: lo, max: hi
        , def: Round(SPK_DEFAULTS[key] * scale), get: () => Round(SpkNum(key) * scale)
        , set: (v) => SpkSetCfg(key, scale = 1 ? v : Round(v / scale, 3))}
}

SpkChatDevNames(flow) {
    names := [SPKCHAT_DEFAULT_DEV]
    for d in SpkDevices(flow)
        names.Push(d.name)
    return names
}

SpkChatDevGet(flow) {
    want := SpkCfg(flow = SPK_MIC ? "MicDevice" : "OutDevice")
    if (want != "") {
        for d in SpkDevices(flow) {
            if (d.id = want)
                return d.name
        }
    }
    return SPKCHAT_DEFAULT_DEV
}

SpkChatDevSet(flow, name) {
    id := ""
    if (name != SPKCHAT_DEFAULT_DEV) {
        for d in SpkDevices(flow) {
            if (d.name = name) {
                id := d.id
                break
            }
        }
    }
    SpkSetCfg(flow = SPK_MIC ? "MicDevice" : "OutDevice", id)
}

; ------------------------------------------------------------------------------
; Calibrate the mic: 4 s quiet, then 6 s reading aloud -> MicAboveNoiseDb
; ------------------------------------------------------------------------------
SpkChatCalStart() {
    global spkChatCal
    if IsObject(spkChatCal)
        return
    if !spkChatOn {
        MsgBox("Turn speaker detection on first, then calibrate.", "Calibrate mic", "Iconi")
        return
    }
    if (MsgBox("Calibrate the mic:`n`n1. Stay quiet for 4 seconds (the room as it normally is).`n"
        . "2. After the beep, read something aloud for 6 seconds in your normal call voice.`n`n"
        . "Live Captions must be listening to the mic (Include microphone audio). Start?", "Calibrate mic", "OKCancel Iconi") != "OK")
        return
    spkChatCal := {phase: "quiet", until: A_TickCount + 4000, quiet: [], speech: [], floor: ""}
    SetTimer(SpkChatCalTick, 50)
}

SpkChatCalTick() {
    global spkChatCal
    try {
        c := spkChatCal
        L := SpkLevels()
        left := Ceil((c.until - A_TickCount) / 1000)
        if (c.phase = "quiet") {
            c.quiet.Push(L.micDb)
            statusText.Text := "Status: calibrating - stay QUIET... " left " s"
            if (A_TickCount >= c.until) {
                c.floor := L.micFloor
                c.phase := "speak"
                c.until := A_TickCount + 6000
                SoundBeep(880, 120)
            }
            return
        }
        c.speech.Push(L.micDb)
        statusText.Text := "Status: calibrating - now READ ALOUD... " left " s"
        if (A_TickCount < c.until)
            return
        SetTimer(SpkChatCalTick, 0)
        spkChatCal := ""
        r := SpkSuggestAbove(c.quiet, c.speech, c.floor)
        if !r.ok {
            statusText.Text := "Status: calibration didn't work - " r.note
            MsgBox("Calibration didn't work: " r.note, "Calibrate mic", "Icon!")
            return
        }
        msg := Format("Room noise: about {} dB`nYour voice: about {} dB (gap {} dB)`n`nSuggested: you count as talking at {} dB above the room noise.`n`nUse it?"
            , Round(r.noise), Round(r.speech), Round(r.gap), r.above)
        if (MsgBox(msg, "Calibrate mic", "YesNo Iconi") = "Yes") {
            SpkSetCfg("MicAboveNoiseDb", r.above)
            SpkSetCfg("Threshold", "auto")
            statusText.Text := "Status: calibration saved - you count as talking at " r.above " dB above the room noise"
        } else {
            statusText.Text := "Status: calibration not saved"
        }
    } catch as err {
        SetTimer(SpkChatCalTick, 0)
        spkChatCal := ""
        SpkChatReport(err)
    }
}

; ------------------------------------------------------------------------------
SpkChatSafe(fn) {
    try {
        fn()
    } catch as err {
        SpkChatReport(err)
    }
}

SpkChatReport(err) {
    try statusText.Text := "Status: speaker detection problem: " err.Message
    try SpkLogLine("companion error: " err.Message " (" err.What ")")
}
