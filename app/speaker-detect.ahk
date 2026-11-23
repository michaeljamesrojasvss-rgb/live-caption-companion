; ==============================================================================
; speaker-detect.ahk  -  who is talking: the agent (mic) or the customer (PC sound)
;
; Windows Live Captions with "Include microphone audio" mixes both voices into one
; caption stream and does not say who spoke. This module watches two sound LEVELS
; (never the sound itself, nothing is recorded):
;   * the mic                         -> the agent is talking
;   * the sound output (3CX's device) -> the customer is talking
; and, when new caption words arrive, says whose voice they most likely were.
;
; How a judgement works (SpkJudge):
;   1. Every SampleMs both meters are read (Windows' own peak meter of the device,
;      IAudioMeterInformation) and kept for BufferSec in a ring buffer.
;   2. Each source learns its own noise floor (the steady background: room noise,
;      fan, line hiss). It drops quickly to quieter moments and creeps up only
;      slowly (NoiseRiseDbPerSec), so speech - which always has tiny gaps - does
;      not lift it. "Talking" = louder than floor + MicAboveNoiseDb / OutAboveNoiseDb
;      (never below MicMinDb / OutMinDb) for at least StartMs, and it stays on for
;      HangMs after the last loud moment, so breaths and short gaps don't flip it.
;      Threshold=fixed uses MicOnDb / OutOnDb instead (no floor).
;      While the customer is talking, the mic must be BleedExtraDb louder to count -
;      their voice leaking from the earpiece into the mic stays the customer's.
;      Calibrate (quiet, then speak) suggests MicAboveNoiseDb: SpkSuggestAbove.
;   3. Captions lag the voice. Words that show up at time t were spoken around t - lag:
;      the judgement looks at [t - lag - MinWindowMs, t - lag + LeadMs], the newest part
;      counting most (OldestWeight). Each side has its own lag (the PC sound is captioned
;      much sooner than the mic). The lag is learned by itself: when someone
;      starts talking after a silence, the time until the next words show up is one
;      lag sample (median of the last LagSamples; starts at LagStartMs).
;   4. Whoever talked clearly more in that window (Margin times) gets the words;
;      close = "unsure", nobody = "none" (the caller keeps the current speaker).
;      If only one side talked at all, even briefly (SoloMinMs), it gets them.
;   5. Is Live Captions hearing the mic at all? ("Include microphone audio" is easy to
;      forget, and Windows keeps it nowhere we can read.) When the agent talks alone
;      for MicCheckSoloMs, caption words must follow. MicCheckMisses times in a row
;      without = "no": every word is then the customer's (Live Captions can only be
;      hearing the PC sound) and SpkMicHeard() says so, for a hint. Any words after
;      the agent talking alone = "yes" again.
;
; Public:
;   SpkStart(ini, section := "Speaker")  -> true when at least one meter works
;   SpkStop()
;   SpkJudge(tick := A_TickCount)        -> {who, micMs, outMs, lagMs, windowMs}
;                                           who: agent | customer | unsure | none
;   SpkLevels()                          -> {micDb, outDb, micTalk, outTalk, micOk, outOk,
;                                            micFloor, outFloor, micOnDb, outOnDb, lagMs, lagSamples}
;   SpkSuggestAbove(quietDbs, speechDbs, floor) -> {ok, above, noise, speech, gap, note}
;   SpkDevices(flow)                     -> [{id, name}]  flow: SPK_MIC | SPK_OUT
;   SpkCfg(key) / SpkSetCfg(key, value)  -> settings (defaults in SPK_DEFAULTS)
;   SpkMicHeard()                        -> yes | no | unknown  (does Live Captions hear the mic?)
;   SpkReason                            -> why it is not working ("" when fine)
;
; Safety: every entry point catches its own errors. A meter that fails (headset
; unplugged) is reopened every few seconds; meanwhile it reads as silent, and
; SpkJudge answers "none" - so captions simply carry on without speakers.
; Logs (data\speaker-detect.log) hold levels, times and decisions - never words.
; ==============================================================================

SPK_OUT := 0                ; eRender
SPK_MIC := 1                ; eCapture
SPK_ROLE := 2               ; eCommunications - the devices calls use
SPK_SILENT_DB := -100.0

; Every setting with its default. A new setting = one entry here.
SPK_DEFAULTS := Map(
    "Enabled",      "0",
    "MicDevice",    "",      ; device id; "" = Windows' communications mic
    "OutDevice",    "",      ; device id; "" = Windows' communications speaker
    "SampleMs",     "50",
    "BufferSec",    "20",
    "Threshold",    "auto",  ; auto = above the learned noise floor | fixed = MicOnDb / OutOnDb
    "MicAboveNoiseDb", "10", ; auto: the mic this much above its noise floor = agent talking
    "OutAboveNoiseDb", "10", ; auto: the output this much above its noise floor = customer talking
    "MicMinDb",     "-60",   ; auto: never count anything quieter than this
    "OutMinDb",     "-60",
    "NoiseRiseDbPerSec", "1.0", ; how fast the noise floor may creep up
    "MicOnDb",      "-38",   ; fixed: mic louder than this = agent talking
    "OutOnDb",      "-45",   ; fixed: output louder than this = customer talking
    "BleedExtraDb", "10",    ; while the customer talks the mic needs this much more
    "StartMs",      "100",   ; must stay loud this long to start "talking" (clicks don't count)
    "HangMs",       "350",   ; stays "talking" this long after the last loud moment
    "QuietMs",      "700",   ; silence before a new start counts for lag learning
    "LagMode",      "auto",  ; auto = learned while people talk | fixed = MicLagMs / OutLagMs
    "MicLagMs",     "1200",  ; fixed: how long your (mic) words take to show up in the captions
    "OutLagMs",     "700",   ; fixed: how long the customer's (PC sound) words take
    "LagStartMs",   "1200",  ; auto: the lag used until one is learned
    "LagMinMs",     "250",
    "LagMaxMs",     "4000",
    "LagSamples",   "15",
    "MinWindowMs",  "900",   ; a judgement looks this far back from when the words were spoken...
    "LeadMs",       "300",   ; ...and this far after it
    "OldestWeight", "0.25",  ; how much the oldest moment of the window counts (the newest = 1): new
                             ; words are mostly the newest sound, the oldest is often the last speaker's tail
    "MinTalkMs",    "150",   ; less talking than this does not count...
    "SoloMinMs",    "40",    ; ...unless only one side talked at all (a customer's first words)
    "MicCheckSoloMs", "3000", ; the agent talking alone this long must bring caption words...
    "MicCheckMisses", "3",   ; ...this many times in a row without = Live Captions is not hearing the mic
                             ; (long + several: typing or a bumped desk also moves the mic meter)
    "Margin",       "1.6",   ; the winner must have talked this many times more
    "Unsure",       "faded"  ; faded = show the words faded with "?" | previous = give them to the last speaker
)

spkSettings := Map()        ; (not spkCfg: AHK names ignore case, that would clash with SpkCfg())
spkIni := ""
spkSection := "Speaker"
spkRunning := false
SpkReason := ""

spkMeters := Map()          ; SPK_MIC / SPK_OUT -> SpkMeter
spkVad := Map()             ; SPK_MIC / SPK_OUT -> {talk, lastLoud, loudSince, floor, onDb}
spkRing := ""               ; SpkSampleRing
spkLags := Map()            ; SPK_MIC / SPK_OUT -> learned lag samples (ms): each side has its own
spkPrevChunk := 0
spkPendingOnset := ""       ; {t, who} - a start after silence, waiting for its first words
spkBothQuietSince := 0
spkLastReopen := 0
spkLog := ""
spkMicEp := ""              ; the agent talking alone right now: {start, last, heard}
spkMicEps := []             ; finished ones waiting for their caption words
spkMicHeardState := "unknown"
spkMicMisses := 0
SpkLogAll := false          ; true = every judgement in the log (the probe); else only with the debug trace on

; ------------------------------------------------------------------------------
; Start / stop
; ------------------------------------------------------------------------------
; Where the settings live (and the log, next to it) - without starting anything, so a
; settings window can read and save them while detection is off. SpkStart calls it too.
SpkUseIni(ini, section := "Speaker") {
    global spkIni, spkSection, spkLog
    spkIni := ini
    spkSection := section
    SplitPath(ini, , &dir)
    spkLog := dir "\speaker-detect.log"
    SpkLoadCfg()
}

SpkStart(ini, section := "Speaker") {
    global spkRunning, SpkReason, spkRing, spkLags
    global spkPrevChunk, spkPendingOnset, spkBothQuietSince
    try {
        SpkStop()
        SpkUseIni(ini, section)
        size := Max(20, Ceil(SpkNum("BufferSec") * 1000 / Max(10, SpkNum("SampleMs"))))
        spkRing := SpkSampleRing(size)
        spkLags := Map(SPK_MIC, [], SPK_OUT, [])
        spkPrevChunk := 0
        spkPendingOnset := ""
        spkBothQuietSince := A_TickCount
        SpkMicCheckReset()
        for src in [SPK_MIC, SPK_OUT]
            spkVad[src] := {talk: false, lastLoud: 0, loudSince: 0, floor: "", onDb: 0, lastT: 0}
        SpkOpenMeters()
        if (!spkMeters[SPK_MIC].ok && !spkMeters[SPK_OUT].ok) {
            SpkReason := "no sound device could be read (mic: " spkMeters[SPK_MIC].err
                . " / output: " spkMeters[SPK_OUT].err ")"
            SpkLogLine("start failed: " SpkReason)
            ; keep the timer: a headset plugged in later is picked up
        } else {
            SpkReason := ""
            SpkLogLine("started - mic " (spkMeters[SPK_MIC].ok ? "ok" : "FAILED") ", output "
                . (spkMeters[SPK_OUT].ok ? "ok" : "FAILED"))
        }
        spkRunning := true
        SetTimer(SpkTick, SpkNum("SampleMs"))
        return spkMeters[SPK_MIC].ok || spkMeters[SPK_OUT].ok
    } catch as err {
        SpkReason := "start problem: " err.Message
        SpkLogLine("start error: " err.Message)
        return false
    }
}

SpkStop() {
    global spkRunning
    try SetTimer(SpkTick, 0)
    for src, m in spkMeters
        try m.Close()
    spkMeters.Clear()
    spkRunning := false
}

SpkOpenMeters() {
    for src, key in Map(SPK_MIC, "MicDevice", SPK_OUT, "OutDevice") {
        if spkMeters.Has(src)
            try spkMeters[src].Close()
        spkMeters[src] := SpkMeter(src, SpkCfg(key))
    }
}

; ------------------------------------------------------------------------------
; Sampling (timer)
; ------------------------------------------------------------------------------
SpkTick() {
    global spkLastReopen, spkBothQuietSince, spkPendingOnset
    static lastErr := 0
    try {
        now := A_TickCount
        ; A failed meter, or "Windows default" whose device changed: reopen now and then
        if (now - spkLastReopen > 3000) {
            spkLastReopen := now
            for src, m in spkMeters {
                if m.NeedsReopen() {
                    wasOk := m.ok
                    spkMeters[src] := SpkMeter(src, m.wantId)
                    try m.Close()
                    if (spkMeters[src].ok != wasOk || spkMeters[src].ok)
                        SpkLogLine((src = SPK_MIC ? "mic" : "output") " reopened: " (spkMeters[src].ok ? "ok" : spkMeters[src].err))
                }
            }
        }

        outDb := spkMeters[SPK_OUT].Db()
        micDb := spkMeters[SPK_MIC].Db()
        bothQuietBefore := !spkVad[SPK_MIC].talk && !spkVad[SPK_OUT].talk

        SpkVadStep(SPK_OUT, outDb, now, 0)
        SpkVadStep(SPK_MIC, micDb, now, spkVad[SPK_OUT].talk ? SpkNum("BleedExtraDb") : 0)

        micTalk := spkVad[SPK_MIC].talk
        outTalk := spkVad[SPK_OUT].talk
        if (!micTalk && !outTalk) {
            if !bothQuietBefore
                spkBothQuietSince := now
        } else if (bothQuietBefore && now - spkBothQuietSince >= SpkNum("QuietMs")) {
            ; Someone started after a real silence: their first words will tell us the lag
            spkPendingOnset := {t: now, who: micTalk && !outTalk ? "agent" : outTalk && !micTalk ? "customer" : "both"}
        }
        spkRing.Push(now, micDb, outDb, micTalk, outTalk)
        SpkMicCheckStep(now, micTalk, outTalk)
    } catch as err {
        if (A_TickCount - lastErr > 60000) {      ; don't flood the log
            lastErr := A_TickCount
            SpkLogLine("sample error: " err.Message)
        }
    }
}

; One sample of one source: update its noise floor, its threshold and its talking state
SpkVadStep(src, db, now, extraDb) {
    st := spkVad[src]
    dt := st.lastT ? Min(now - st.lastT, 1000) : 0
    st.lastT := now
    SpkFloorStep(st, db, dt, src = SPK_OUT)
    st.onDb := SpkOnDb(src, st.floor) + extraDb

    if (db >= st.onDb) {
        if !st.loudSince
            st.loudSince := now
        st.lastLoud := now
        if (!st.talk && now - st.loudSince >= SpkNum("StartMs"))
            st.talk := true
    } else {
        st.loudSince := 0
        if (st.talk && now - st.lastLoud > SpkNum("HangMs"))
            st.talk := false
    }
}

; Noise floor: falls fast to quieter moments, creeps up slowly.
; Digital silence (SPK_SILENT_DB):
;   * output (silenceIsFloor): it IS its floor - nothing playing = perfect silence, so any sound
;     counts (never below OutMinDb). Ignoring it made the first sound (a customer's soft "Hello")
;     the floor, and their first words then did not count as talking.
;   * mic: ignored - an open mic always hears some room; a moment of silence there is the stream
;     restarting, and must not make the room noise count as the agent talking.
SpkFloorStep(st, db, dt, silenceIsFloor := false) {
    if (db <= SPK_SILENT_DB + 1 && !silenceIsFloor)
        return
    if (st.floor = "") {
        st.floor := db
        return
    }
    if (db < st.floor)
        st.floor += (db - st.floor) * 0.5
    else
        st.floor := Min(db, st.floor + SpkNum("NoiseRiseDbPerSec") * dt / 1000)
}

; The level that counts as talking for one source (before any bleed extra)
SpkOnDb(src, floor) {
    isMic := src = SPK_MIC
    if (SpkCfg("Threshold") = "fixed" || floor = "")
        return SpkNum(isMic ? "MicOnDb" : "OutOnDb")
    return Max(SpkNum(isMic ? "MicMinDb" : "OutMinDb"), floor + SpkNum(isMic ? "MicAboveNoiseDb" : "OutAboveNoiseDb"))
}

; Pure. Calibration: levels (dB) while quiet, then while speaking, and the noise floor
; at that time -> a suggested "above noise" value halfway between room noise and voice.
SpkSuggestAbove(quietDbs, speechDbs, floor) {
    res := {ok: false, above: 0, noise: 0, speech: 0, gap: 0, note: ""}
    q := SpkSorted(quietDbs), s := SpkSorted(speechDbs)
    if (q.Length < 10 || s.Length < 10) {
        res.note := "not enough sound was read - is Live Captions listening to the mic?"
        return res
    }
    res.noise := q[Max(1, Round(q.Length * 0.9))]          ; the loud end of the room noise
    res.speech := s[Max(1, Round(s.Length * 0.5))]         ; a typical speaking moment
    res.gap := res.speech - res.noise
    if (floor = "")
        floor := q[Max(1, Round(q.Length * 0.1))]
    if (res.gap < 6) {
        res.note := "your voice is only " Round(res.gap) " dB louder than the room - a headset mic close to the mouth works much better"
        return res
    }
    res.above := Max(3, Min(30, Round((res.noise + res.speech) / 2 - floor)))
    res.ok := true
    return res
}

; Sorted copy (numbers only, unreadable samples left out)
SpkSorted(arr) {
    s := []
    for v in arr {
        if (IsNumber(v) && v > SPK_SILENT_DB + 1)
            s.Push(v + 0)
    }
    Loop s.Length - 1 {
        i := A_Index + 1, v := s[i], j := i - 1
        while (j >= 1 && s[j] > v) {
            s[j + 1] := s[j]
            j -= 1
        }
        s[j + 1] := v
    }
    return s
}

; ------------------------------------------------------------------------------
; Judging new caption words
; ------------------------------------------------------------------------------
; Call it when new words show up in the captions. Returns {who, micMs, outMs, lagMs, windowMs}.
SpkJudge(tick := A_TickCount) {
    global spkPrevChunk, spkPendingOnset
    res := {who: "none", micMs: 0, outMs: 0, lagMs: 0, windowMs: 0}
    try {
        if (!spkRunning || !IsObject(spkRing))
            return res

        ; Lag learning: the first words after a start-after-silence
        if IsObject(spkPendingOnset) {
            d := tick - spkPendingOnset.t
            if (d >= SpkNum("LagMinMs") && d <= SpkNum("LagMaxMs") && spkPendingOnset.who != "both")
                SpkAddLag(spkPendingOnset.who = "agent" ? SPK_MIC : SPK_OUT, d)
            if (d >= SpkNum("LagMinMs"))              ; sooner = words from before that start
                spkPendingOnset := ""
        }

        ; A short window around when these words were spoken (tick - lag), whatever the time since the
        ; last words: Live Captions can go quiet for seconds and then add words - looking back to the
        ; previous words then mostly measured the speaker before (a late split).
        ; Each side is looked at with ITS OWN lag: the customer's (PC sound) words show up much
        ; sooner than the agent's (mic), so one shared lag looked before a customer had started.
        gap := SpkNum("SampleMs") * 2, oldestW := Max(0, Min(1, SpkNum("OldestWeight")))
        micLag := SpkLag(SPK_MIC), outLag := SpkLag(SPK_OUT)
        spkRing.TalkMs(tick - micLag - SpkNum("MinWindowMs"), tick - micLag + SpkNum("LeadMs"), &micMs, &unused1, gap, oldestW)
        spkRing.TalkMs(tick - outLag - SpkNum("MinWindowMs"), tick - outLag + SpkNum("LeadMs"), &unused2, &outMs, gap, oldestW)
        lag := micLag " / " outLag                    ; for the trace: "mic / output"
        toT := SpkNum("LeadMs"), fromT := -SpkNum("MinWindowMs")
        spkPrevChunk := tick

        SpkMicCheckWords(tick)
        who := SpkDecide(micMs, outMs)
        if (spkMicHeardState = "no")
            who := "customer"                        ; Live Captions can only be hearing the PC sound
        res := {who: who, micMs: micMs, outMs: outMs, lagMs: lag, windowMs: toT - fromT}
        if SpkVerbose(res)
            SpkLogLine("judge " res.who " mic " micMs "ms out " outMs "ms lag " lag "ms window " res.windowMs "ms"
                . SpkLevelsNote() (spkMicHeardState = "no" ? " (mic not captioned)" : ""))
    } catch as err {
        SpkLogLine("judge error: " err.Message)
    }
    return res
}

; Each judgement is a log line only when wanted (several a second while people talk):
; SpkLogAll := true (the probe), or the shared debug trace is on (DbgTrace, in the Companion).
SpkVerbose(res) {
    if SpkLogAll
        return true
    try {                                            ; debug-trace.ahk may not be loaded (the probe)
        if %"DbgOn"%()
            %"DbgTrace"%("speaker", res.who " mic " res.micMs "ms out " res.outMs "ms lag " res.lagMs "ms" SpkLevelsNote())
    }
    return false
}

; " | mic -31 (noise -42, talk -31) out -100 (noise -60, talk -50) heard yes" - levels right now, for the trace
SpkLevelsNote() {
    L := SpkLevels()
    f(db, floor, onDb) => Round(db) " (noise " (floor = "" ? "?" : Round(floor)) ", talk " Round(onDb) ")"
    return " | mic " f(L.micDb, L.micFloor, L.micOnDb) " out " f(L.outDb, L.outFloor, L.outOnDb)
        . " heard " SpkMicHeard() (L.micOk ? "" : " MIC UNREADABLE") (L.outOk ? "" : " OUTPUT UNREADABLE")
}

; Pure: talk time of each side -> agent | customer | unsure | none
SpkDecide(micMs, outMs) {
    minTalk := SpkNum("MinTalkMs")
    margin := SpkNum("Margin")
    if (micMs < minTalk && outMs < minTalk) {
        solo := SpkNum("SoloMinMs")                  ; only one side made any sound at all
        if (micMs >= solo && outMs = 0)
            return "agent"
        if (outMs >= solo && micMs = 0)
            return "customer"
        return "none"
    }
    if (micMs >= minTalk && micMs >= outMs * margin)
        return "agent"
    if (outMs >= minTalk && outMs >= micMs * margin)
        return "customer"
    return "unsure"
}

; ------------------------------------------------------------------------------
; Is Live Captions hearing the mic? (see 5. at the top)
; ------------------------------------------------------------------------------
SpkMicHeard() => spkMicHeardState

SpkMicCheckReset() {
    global spkMicEp, spkMicEps, spkMicHeardState, spkMicMisses
    spkMicEp := ""
    spkMicEps := []
    spkMicHeardState := "unknown"
    spkMicMisses := 0
}

; Every sample: follow "the agent talking alone" and settle the finished ones
SpkMicCheckStep(now, micTalk, outTalk) {
    global spkMicEp
    if (micTalk && !outTalk) {
        if !IsObject(spkMicEp)
            spkMicEp := {start: now, last: now, heard: false}
        else
            spkMicEp.last := now
    } else if IsObject(spkMicEp) {
        ep := spkMicEp
        spkMicEp := ""
        if (!outTalk && ep.last - ep.start >= SpkNum("MicCheckSoloMs")) {  ; the customer cutting in = not alone
            if ep.heard
                SpkMicCheckResult(true)
            else
                spkMicEps.Push(ep)
        }
    }
    while (spkMicEps.Length && now > spkMicEps[1].last + SpkNum("LagMaxMs") + 500) {
        ep := spkMicEps.RemoveAt(1)
        SpkMicCheckResult(ep.heard)
    }
}

; Caption words showed up at tick: they belong to the agent's talking-alone stretches around then.
; While the state is "no", such words prove the opposite right away - flipped back to "yes" BEFORE
; the judgement, so the agent's own first words aren't forced to the customer.
SpkMicCheckWords(tick) {
    lagMin := SpkNum("LagMinMs"), lagMax := SpkNum("LagMaxMs")
    heard := false
    if (IsObject(spkMicEp) && tick >= spkMicEp.start + lagMin)
        spkMicEp.heard := heard := true
    for ep in spkMicEps {
        if (tick >= ep.start + lagMin && tick <= ep.last + lagMax)
            ep.heard := heard := true
    }
    if (heard && spkMicHeardState = "no")
        SpkMicCheckResult(true)
}

SpkMicCheckResult(heard) {
    global spkMicHeardState, spkMicMisses
    before := spkMicHeardState
    if heard {
        spkMicMisses := 0
        spkMicHeardState := "yes"
    } else {
        spkMicMisses += 1
        if (spkMicMisses >= SpkNum("MicCheckMisses"))
            spkMicHeardState := "no"
    }
    if (spkMicHeardState != before)
        SpkLogLine("Live Captions hears the mic: " spkMicHeardState (heard ? "" : " (" spkMicMisses " times the agent talked alone with no captions)"))
}

SpkLagCount(src) => spkLags.Has(src) ? spkLags[src].Length : 0

SpkAddLag(src, ms) {
    if !spkLags.Has(src)
        return
    list := spkLags[src]
    list.Push(ms)
    while (list.Length > SpkNum("LagSamples"))
        list.RemoveAt(1)
}

; The lag a judgement uses for one side: LagMode=fixed -> MicLagMs / OutLagMs, else the learned one.
; No side given = both sides together (for display).
SpkLag(src := "") {
    if (SpkCfg("LagMode") = "fixed") {
        if (src = "")
            return Round((SpkNum("MicLagMs") + SpkNum("OutLagMs")) / 2)
        return SpkNum(src = SPK_MIC ? "MicLagMs" : "OutLagMs")
    }
    return SpkLearnedLag(src)
}

; Median learned lag of one side (SPK_MIC / SPK_OUT); a side with nothing learned yet uses the
; other side's, then LagStartMs. No side given = both sides together. Learned in either mode,
; so Settings can show it (and you can copy it into the fixed values).
SpkLearnedLag(src := "") {
    all := []
    if (src = "") {
        for k, list in spkLags
            for v in list
                all.Push(v)
    } else if (spkLags.Has(src) && spkLags[src].Length) {
        all := spkLags[src]
    } else {
        for k, list in spkLags
            for v in list
                all.Push(v)
    }
    if (all.Length = 0)
        return SpkNum("LagStartMs")
    s := SpkSorted(all)
    n := s.Length
    return Round(Mod(n, 2) ? s[(n + 1) // 2] : (s[n // 2] + s[n // 2 + 1]) / 2)
}

SpkLevels() {
    res := {micDb: SPK_SILENT_DB, outDb: SPK_SILENT_DB, micTalk: false, outTalk: false
        , micOk: false, outOk: false, micFloor: "", outFloor: "", micOnDb: 0, outOnDb: 0
        , lagMs: SpkLag(), micLagMs: SpkLag(SPK_MIC), outLagMs: SpkLag(SPK_OUT)
        , lagSamples: SpkLagCount(SPK_MIC) + SpkLagCount(SPK_OUT)
        , micLagSamples: SpkLagCount(SPK_MIC), outLagSamples: SpkLagCount(SPK_OUT)}
    if (spkMeters.Has(SPK_MIC) && spkVad.Has(SPK_MIC)) {
        res.micDb := spkMeters[SPK_MIC].lastDb
        res.micOk := spkMeters[SPK_MIC].ok
        res.micTalk := spkVad[SPK_MIC].talk
        res.micFloor := spkVad[SPK_MIC].floor
        res.micOnDb := spkVad[SPK_MIC].onDb
    }
    if (spkMeters.Has(SPK_OUT) && spkVad.Has(SPK_OUT)) {
        res.outDb := spkMeters[SPK_OUT].lastDb
        res.outOk := spkMeters[SPK_OUT].ok
        res.outTalk := spkVad[SPK_OUT].talk
        res.outFloor := spkVad[SPK_OUT].floor
        res.outOnDb := spkVad[SPK_OUT].onDb
    }
    return res
}

; ------------------------------------------------------------------------------
; Settings
; ------------------------------------------------------------------------------
SpkLoadCfg() {
    spkSettings.Clear()
    for key, dflt in SPK_DEFAULTS {
        val := dflt
        if (spkIni != "")
            try val := IniRead(spkIni, spkSection, key, dflt)
        spkSettings[key] := val
    }
}

SpkCfg(key) {
    if spkSettings.Has(key)
        return spkSettings[key]
    return SPK_DEFAULTS.Has(key) ? SPK_DEFAULTS[key] : ""
}

SpkNum(key) {
    v := SpkCfg(key)
    if IsNumber(v)
        return v + 0
    d := SPK_DEFAULTS.Has(key) ? SPK_DEFAULTS[key] : 0
    return IsNumber(d) ? d + 0 : 0
}

; Changes a setting now and saves it. Device changes reopen that meter.
SpkSetCfg(key, value) {
    spkSettings[key] := value
    if (spkIni != "")
        try IniWrite(value, spkIni, spkSection, key)
    if (spkRunning && (key = "MicDevice" || key = "OutDevice")) {
        src := key = "MicDevice" ? SPK_MIC : SPK_OUT
        if spkMeters.Has(src)
            try spkMeters[src].Close()
        spkMeters[src] := SpkMeter(src, value)
    }
}

SpkLogLine(line) {
    if (spkLog = "")
        return
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", spkLog, "UTF-8")
}

; ------------------------------------------------------------------------------
; Sound devices (Windows Core Audio through COM)
; ------------------------------------------------------------------------------
SpkEnumerator() {
    static e := ""
    if !IsObject(e)
        e := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}", "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
    return e
}

SpkGuid(str) {
    b := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", str, "Ptr", b, "HRESULT")
    return b
}

; Every active device of one kind: [{id, name}]
SpkDevices(flow) {
    out := []
    coll := 0
    try {
        ComCall(3, SpkEnumerator(), "Int", flow, "UInt", 1, "Ptr*", &coll)     ; EnumAudioEndpoints, ACTIVE
        ComCall(3, coll, "UInt*", &n := 0)                                    ; GetCount
        Loop n {
            dev := 0
            try {
                ComCall(4, coll, "UInt", A_Index - 1, "Ptr*", &dev)           ; Item
                out.Push({id: SpkDeviceId(dev), name: SpkDeviceName(dev)})
            }
            if dev
                ObjRelease(dev)
        }
    } catch as err {
        SpkLogLine("device list error: " err.Message)
    }
    if coll
        ObjRelease(coll)
    return out
}

SpkDeviceId(dev) {
    p := 0
    ComCall(5, dev, "Ptr*", &p)                                               ; GetId
    id := StrGet(p, "UTF-16")
    DllCall("ole32\CoTaskMemFree", "Ptr", p)
    return id
}

SpkDeviceName(dev) {
    store := 0
    name := ""
    try {
        ComCall(4, dev, "UInt", 0, "Ptr*", &store)                            ; OpenPropertyStore, STGM_READ
        key := Buffer(20, 0)                                                  ; PKEY_Device_FriendlyName
        DllCall("ole32\CLSIDFromString", "WStr", "{a45c254e-df1c-4efd-8020-67d146a850e0}", "Ptr", key, "HRESULT")
        NumPut("UInt", 14, key, 16)
        pv := Buffer(24, 0)                                                   ; PROPVARIANT (16 on 32-bit, 24 on 64-bit)
        ComCall(5, store, "Ptr", key, "Ptr", pv)                              ; GetValue
        if (NumGet(pv, 0, "UShort") = 31)                                     ; VT_LPWSTR
            name := StrGet(NumGet(pv, 8, "Ptr"), "UTF-16")
        DllCall("ole32\PropVariantClear", "Ptr", pv)
    }
    if store
        ObjRelease(store)
    return name
}

; The Windows default communications device of one kind -> its id ("" when none)
SpkDefaultId(flow) {
    dev := 0
    id := ""
    try {
        ComCall(4, SpkEnumerator(), "Int", flow, "Int", SPK_ROLE, "Ptr*", &dev)  ; GetDefaultAudioEndpoint
        id := SpkDeviceId(dev)
    }
    if dev
        ObjRelease(dev)
    return id
}

; One device's peak meter. wantId "" = follow Windows' communications default.
class SpkMeter {
    __New(flow, wantId) {
        this.flow := flow
        this.wantId := wantId
        this.id := ""
        this.dev := 0
        this.meter := 0
        this.ok := false
        this.err := ""
        this.lastDb := SPK_SILENT_DB
        this.failedAt := 0
        try {
            e := SpkEnumerator()
            dev := 0
            if (wantId = "")
                ComCall(4, e, "Int", flow, "Int", SPK_ROLE, "Ptr*", &dev)       ; GetDefaultAudioEndpoint
            else
                ComCall(5, e, "WStr", wantId, "Ptr*", &dev)                     ; GetDevice
            this.dev := dev
            this.id := SpkDeviceId(dev)
            m := 0
            ComCall(3, dev, "Ptr", SpkGuid("{C02216F6-8C67-4B5B-9D00-D008E73E0064}")   ; Activate IAudioMeterInformation
                , "UInt", 23, "Ptr", 0, "Ptr*", &m)
            this.meter := m
            this.ok := true
        } catch as err {
            this.err := err.Message
            this.failedAt := A_TickCount
        }
    }

    ; Current peak in dB (SPK_SILENT_DB when unreadable). A capture device reads 0 unless
    ; some program has it open - Live Captions does, when it listens to the mic.
    Db() {
        if !this.ok
            return this.lastDb := SPK_SILENT_DB
        try {
            ComCall(3, this.meter, "Float*", &peak := 0.0)                       ; GetPeakValue
            return this.lastDb := peak > 0.000001 ? 20 * Log(peak) : SPK_SILENT_DB
        } catch as err {
            this.ok := false
            this.err := err.Message
            this.failedAt := A_TickCount
            return this.lastDb := SPK_SILENT_DB
        }
    }

    NeedsReopen() {
        if !this.ok
            return true
        return this.wantId = "" && SpkDefaultId(this.flow) != this.id      ; Windows default changed
    }

    Close() {
        if this.meter
            try ObjRelease(this.meter)
        if this.dev
            try ObjRelease(this.dev)
        this.meter := 0
        this.dev := 0
        this.ok := false
    }

    __Delete() => this.Close()
}

; Fixed-size ring buffer of samples: tick, levels and talking flags of both sides
class SpkSampleRing {
    __New(size) {
        this.size := size
        this.head := 0          ; index of the newest sample (1-based), 0 = empty
        this.count := 0
        this.t := [], this.mic := [], this.out := [], this.micTalk := [], this.outTalk := []
        for arr in [this.t, this.mic, this.out, this.micTalk, this.outTalk]
            arr.Length := size
    }

    Push(t, micDb, outDb, micTalk, outTalk) {
        this.head := Mod(this.head, this.size) + 1
        this.t[this.head] := t
        this.mic[this.head] := micDb
        this.out[this.head] := outDb
        this.micTalk[this.head] := micTalk
        this.outTalk[this.head] := outTalk
        this.count := Min(this.count + 1, this.size)
    }

    ; Milliseconds each side was talking between fromT and toT. A sample stands for the
    ; time until the next one (capped at maxGap, in case the timer was held up). Weighted:
    ; a moment at fromT counts oldestW, one at toT counts 1, in between on a straight line.
    TalkMs(fromT, toT, &micMs, &outMs, maxGap, oldestW := 1) {
        micMs := 0, outMs := 0
        if (this.count = 0)
            return
        idx := Mod(this.head - this.count + this.size, this.size) + 1     ; oldest
        Loop this.count {
            nextIdx := Mod(idx, this.size) + 1
            t0 := this.t[idx]
            t1 := (A_Index < this.count) ? this.t[nextIdx] : t0 + maxGap / 2
            t1 := Min(t1, t0 + maxGap)
            a := Max(t0, fromT), b := Min(t1, toT)
            if (b > a) {
                mid := (a + b) / 2
                w := toT > fromT ? oldestW + (1 - oldestW) * (mid - fromT) / (toT - fromT) : 1
                if this.micTalk[idx]
                    micMs += (b - a) * w
                if this.outTalk[idx]
                    outMs += (b - a) * w
            }
            idx := nextIdx
        }
        micMs := Round(micMs), outMs := Round(outMs)
    }
}
