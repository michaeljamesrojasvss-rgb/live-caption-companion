#Requires AutoHotkey v2.0
#SingleInstance Force
; ==============================================================================
; speaker-probe.ahk  -  dev probe (not shipped) for speaker detection
;
; Run it during a real 3CX call (or a test call) with Windows Live Captions open and
; its "Include microphone audio" setting ON. It shows:
;   * both sound meters live: your mic (agent) and the sound output (customer),
;     with the level that counts as "talking" for each - change them right here;
;   * every time new caption words show up: how long each side talked just before
;     (shifted by the caption lag), and who the detector thinks it was;
;   * the caption lag it has learned.
; The new words are shown in the list (on screen only) so you can see whether the
; guess was right. Nothing in the files holds words:
;   data\speaker-detect.log    decisions + times (the real module's log)
;   data\speaker-probe.csv     levels every 50 ms, while "Record levels" is ticked
;   data\speaker-probe-info.txt  "Dump Live Captions info": its window structure
;                               (no caption text) + its registry settings, to find
;                               out whether it exposes a speaker or the mic setting
; Thresholds and devices are saved in data\live-captions.ini [Speaker], the same
; place the Companion will read them from.
; ==============================================================================
#Include ..\..\app\UIA.ahk
#Include ..\..\app\speaker-detect.ahk

PROBE_DATA := A_ScriptDir "\..\..\data"
try DirCreate(PROBE_DATA)
PROBE_INI := PROBE_DATA "\live-captions.ini"
PROBE_CSV := PROBE_DATA "\speaker-probe.csv"
PROBE_INFO := PROBE_DATA "\speaker-probe-info.txt"

capEl := ""
capLast := ""
csvBuf := ""
micList := [], outList := []
showingMode := false        ; true while ShowMode fills the boxes (their Change events are ignored)
cal := ""                   ; the running calibration, or ""

SpkLogAll := true           ; the probe logs every judgement (times + decisions, never words)
SpkStart(PROBE_INI)

; ------------------------------------------------------------------------------
; Window
; ------------------------------------------------------------------------------
g := Gui("+Resize +MinSize700x460", "Speaker detection probe")
g.SetFont("s10", "Segoe UI")

g.Add("Text", "x12 y12 w150 h22", "Mic (you):")
ddMic := g.Add("DropDownList", "x165 y9 w420")
g.Add("Text", "x12 y44 w150 h22", "Sound output (customer):")
ddOut := g.Add("DropDownList", "x165 y41 w420")
g.Add("Button", "x595 y9 w95 h26", "Refresh").OnEvent("Click", (*) => FillDevices())

g.Add("Text", "x12 y76 w150 h22", "Talking level:")
ddMode := g.Add("DropDownList", "x165 y73 w260", ["Auto - above the room noise", "Fixed level"])
g.Add("Button", "x435 y72 w150 h26", "Calibrate mic...").OnEvent("Click", (*) => CalStart())

g.Add("Text", "x12 y110 w60 h22", "Mic")
barMic := g.Add("Progress", "x75 y110 w250 h20 Range0-100 c22D3EE BackgroundE5E7EB")
txtMic := g.Add("Text", "x332 y110 w250 h22", "")
lblMic := g.Add("Text", "x585 y110 w55 h22 Right", "")
edMic := g.Add("Edit", "x645 y107 w45 h24")
udMic := g.Add("UpDown", "Range-80-40")

g.Add("Text", "x12 y140 w60 h22", "Output")
barOut := g.Add("Progress", "x75 y140 w250 h20 Range0-100 cF59E0B BackgroundE5E7EB")
txtOut := g.Add("Text", "x332 y140 w250 h22", "")
lblOut := g.Add("Text", "x585 y140 w55 h22 Right", "")
edOut := g.Add("Edit", "x645 y137 w45 h24")
udOut := g.Add("UpDown", "Range-80-40")

txtLag := g.Add("Text", "x12 y172 w676 h22", "")
chkCsv := g.Add("CheckBox", "x12 y200 w300 h22", "Record levels (data\speaker-probe.csv)")
g.Add("Button", "x330 y197 w200 h26", "Dump Live Captions info").OnEvent("Click", (*) => DumpInfo())
g.Add("Button", "x540 y197 w80 h26", "Clear").OnEvent("Click", (*) => lv.Delete())

lv := g.Add("ListView", "x12 y232 w676 h194 -Multi", ["Time", "Who", "Mic ms", "Out ms", "Lag", "Window", "New words (screen only)"])
txtStatus := g.Add("Text", "x12 y432 w676 h22", "")

ddMic.OnEvent("Change", (*) => PickDevice(ddMic, micList, "MicDevice"))
ddOut.OnEvent("Change", (*) => PickDevice(ddOut, outList, "OutDevice"))
ddMode.OnEvent("Change", (*) => (SpkSetCfg("Threshold", ddMode.Value = 2 ? "fixed" : "auto"), ShowMode()))
edMic.OnEvent("Change", (*) => SetDb(edMic, ModeKey("Mic")))
edOut.OnEvent("Change", (*) => SetDb(edOut, ModeKey("Out")))
g.OnEvent("Size", GuiSize)
g.OnEvent("Close", (*) => Quit())

FillDevices()
ShowMode()
g.Show("w700 h460")
SetTimer(UiTick, 100)
SetTimer(CaptionTick, 100)
SetTimer(CsvTick, 50)
SetTimer(CsvFlush, 1000)
return

GuiSize(gui, minMax, w, h) {
    if (minMax = -1)
        return
    lv.Move(, , w - 24, h - 232 - 34)
    txtStatus.Move(, h - 28, w - 24)
    lv.ModifyCol(7, "AutoHdr")
}

Quit() {
    CsvFlush()
    SpkStop()
    ExitApp()
}

; ------------------------------------------------------------------------------
; Devices and thresholds
; ------------------------------------------------------------------------------
FillDevices() {
    global micList, outList
    micList := SpkDevices(SPK_MIC)
    outList := SpkDevices(SPK_OUT)
    for pair in [[ddMic, micList, "MicDevice"], [ddOut, outList, "OutDevice"]] {
        dd := pair[1], list := pair[2], want := SpkCfg(pair[3])
        names := ["(Windows communications device)"]
        pick := 1
        for d in list {
            names.Push(d.name)
            if (d.id = want)
                pick := A_Index + 1
        }
        dd.Delete()
        dd.Add(names)
        dd.Choose(pick)
    }
}

PickDevice(dd, list, key) {
    i := dd.Value
    SpkSetCfg(key, i <= 1 ? "" : list[i - 1].id)
}

SetDb(ed, key) {
    global showingMode
    if showingMode                       ; ShowMode is filling the boxes, not the user
        return
    v := Trim(ed.Value)
    if IsNumber(v)
        SpkSetCfg(key, v)
}

; The setting the mic/output box edits in the current mode
ModeKey(side) => SpkCfg("Threshold") = "fixed" ? side "OnDb" : side "AboveNoiseDb"

ShowMode() {
    global showingMode
    showingMode := true
    fixed := SpkCfg("Threshold") = "fixed"
    ddMode.Choose(fixed ? 2 : 1)
    for row in [[lblMic, udMic, "Mic"], [lblOut, udOut, "Out"]] {
        row[1].Text := fixed ? "talk at" : "+ dB"
        row[2].Opt(fixed ? "Range-80-0" : "Range0-40")
        row[2].Value := Round(SpkNum(ModeKey(row[3])))
    }
    showingMode := false
}

; ------------------------------------------------------------------------------
; Calibrate the mic: 4 s quiet, then 6 s reading aloud -> suggested "+ dB"
; ------------------------------------------------------------------------------
CalStart() {
    global cal
    if IsObject(cal)
        return
    if (MsgBox("Calibrate the mic:`n`n1. Stay quiet for 4 seconds (the room as it normally is).`n"
        . "2. When it says so, read something aloud for 6 seconds, at your normal call voice.`n`n"
        . "Live Captions must be listening to the mic. Start?", "Calibrate mic", "OKCancel Iconi") != "OK")
        return
    cal := {phase: "quiet", until: A_TickCount + 4000, quiet: [], speech: [], floor: ""}
    SetTimer(CalTick, 50)
}

CalTick() {
    global cal
    L := SpkLevels()
    if (cal.phase = "quiet") {
        cal.quiet.Push(L.micDb)
        txtStatus.Text := "Calibrating: stay QUIET... " Ceil((cal.until - A_TickCount) / 1000) " s"
        if (A_TickCount >= cal.until) {
            cal.floor := L.micFloor
            cal.phase := "speak"
            cal.until := A_TickCount + 6000
            SoundBeep(880, 120)
        }
        return
    }
    cal.speech.Push(L.micDb)
    txtStatus.Text := "Calibrating: now READ ALOUD... " Ceil((cal.until - A_TickCount) / 1000) " s"
    if (A_TickCount < cal.until)
        return
    SetTimer(CalTick, 0)
    r := SpkSuggestAbove(cal.quiet, cal.speech, cal.floor)
    cal := ""
    if !r.ok {
        txtStatus.Text := "Calibration: " r.note
        MsgBox("Calibration didn't work: " r.note, "Calibrate mic", "Icon!")
        return
    }
    msg := Format("Room noise: about {} dB`nYour voice: about {} dB (gap {} dB)`n`nSuggested: talking = {} dB above the room noise.`n`nUse it?"
        , Round(r.noise), Round(r.speech), Round(r.gap), r.above)
    if (MsgBox(msg, "Calibrate mic", "YesNo Iconi") = "Yes") {
        SpkSetCfg("MicAboveNoiseDb", r.above)
        SpkSetCfg("Threshold", "auto")
        ShowMode()
        txtStatus.Text := "Calibration saved: mic talking = " r.above " dB above the room noise"
    }
}

; ------------------------------------------------------------------------------
; Live display
; ------------------------------------------------------------------------------
DbToBar(db) => Max(0, Min(100, Round((db + 80) * 100 / 80)))   ; -80 dB .. 0 dB

; "-30 dB · noise -36 · talk -26  TALKING"
LevelText(ok, db, floor, onDb, talk) {
    if !ok
        return "can't read"
    s := (db <= SPK_SILENT_DB + 1 ? "silent" : Round(db) " dB")
    if (floor != "")
        s .= " · noise " Round(floor)
    s .= " · talk " Round(onDb)
    return s (talk ? "  TALKING" : "")
}

UiTick() {
    try {
        L := SpkLevels()
        barMic.Value := DbToBar(L.micDb)
        barOut.Value := DbToBar(L.outDb)
        txtMic.Text := LevelText(L.micOk, L.micDb, L.micFloor, L.micOnDb, L.micTalk)
        txtOut.Text := LevelText(L.outOk, L.outDb, L.outFloor, L.outOnDb, L.outTalk)
        txtLag.Text := "Caption lag: mic " L.micLagMs " ms (" L.micLagSamples " learned), output " L.outLagMs " ms (" L.outLagSamples " learned)"
            . (SpkReason != "" ? "   ·   " SpkReason : "")
    }
}

; ------------------------------------------------------------------------------
; Caption watching (a simple version of the Companion's: only "words added at the end")
; ------------------------------------------------------------------------------
CaptionTick() {
    global capEl, capLast
    try {
        if !IsObject(capEl) {
            hwnd := WinExist("ahk_exe LiveCaptions.exe")
            if !hwnd {
                txtStatus.Text := "Live Captions is not running (Win+Ctrl+L)"
                return
            }
            capEl := UIA.ElementFromHandle(hwnd).FindElement({AutomationId: "CaptionsTextBlock"})
            txtStatus.Text := "Connected to Live Captions - talk, and let the customer talk"
        }
        cap := Trim(capEl.Name, " `t`r`n")
    } catch {
        capEl := ""
        txtStatus.Text := "Reconnecting to Live Captions..."
        return
    }
    cap := RegExReplace(cap, "\s+", " ")
    if (cap == capLast || cap = "")
        return
    added := NewWords(capLast, cap)
    capLast := cap
    if (added = "")
        return                                       ; only a rewrite of words already shown
    r := SpkJudge()
    who := r.who
    if (who = "unsure" && SpkCfg("Unsure") = "previous")
        who := "unsure (-> previous)"
    row := lv.Add(, FormatTime(, "HH:mm:ss"), who, r.micMs, r.outMs, r.lagMs, r.windowMs, added)
    lv.Modify(row, "Vis")
    CsvAdd("EV," A_TickCount "," r.who "," r.micMs "," r.outMs "," r.lagMs "," StrLen(added))
}

; Words at the end of cur that were not at the end of prev ("" = nothing new).
; Finds where prev's last few words are in cur; everything after them is new.
NewWords(prev, cur) {
    if (prev = "")
        return cur
    pw := Words(prev), cw := Words(cur)
    n := Min(6, pw.Length)                             ; try prev's last 6 words, then fewer
    while (n >= 1) {
        ; last place in cur where prev's last n words appear
        pos := cw.Length - n + 1
        while (pos >= 1) {
            same := true
            Loop n {
                if (cw[pos + A_Index - 1].norm != pw[pw.Length - n + A_Index].norm) {
                    same := false
                    break
                }
            }
            if same {
                out := ""
                Loop cw.Length - (pos + n - 1)
                    out .= (A_Index = 1 ? "" : " ") cw[pos + n - 1 + A_Index].raw
                return out
            }
            pos -= 1
        }
        n -= 1
    }
    return "(rewritten) " SubStr(cur, -60)
}

; Words of a caption: [{raw, norm}], punctuation-only bits left out
Words(s) {
    out := []
    for w in StrSplit(s, " ") {
        n := StrLower(RegExReplace(w, "[^\w']"))
        if (n != "")
            out.Push({raw: w, norm: n})
    }
    return out
}

; ------------------------------------------------------------------------------
; Level recording (levels only)
; ------------------------------------------------------------------------------
CsvTick() {
    if !chkCsv.Value
        return
    L := SpkLevels()
    CsvAdd(A_TickCount "," Round(L.micDb, 1) "," Round(L.outDb, 1) "," (L.micTalk ? 1 : 0) "," (L.outTalk ? 1 : 0))
}

CsvAdd(line) {
    global csvBuf
    if chkCsv.Value
        csvBuf .= line "`n"
}

CsvFlush() {
    global csvBuf
    if (csvBuf = "")
        return
    if !FileExist(PROBE_CSV)
        csvBuf := "tick,micDb,outDb,micTalk,outTalk   (EV lines: EV,tick,who,micMs,outMs,lagMs,chars)`n" csvBuf
    try FileAppend(csvBuf, PROBE_CSV, "UTF-8")
    csvBuf := ""
}

; ------------------------------------------------------------------------------
; Live Captions structure + registry (does it expose a speaker / the mic setting?)
; ------------------------------------------------------------------------------
DumpInfo() {
    out := "Speaker probe - Live Captions info, " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n"
    out .= "Caption text is left out on purpose.`n`n== Window structure ==`n"
    try {
        hwnd := WinExist("ahk_exe LiveCaptions.exe")
        if hwnd
            out .= DumpEl(UIA.ElementFromHandle(hwnd), 0)
        else
            out .= "(Live Captions is not running)`n"
    } catch as err {
        out .= "(error: " err.Message ")`n"
    }
    out .= "`n== Registry ==`n"
    for key in ["HKCU\Software\Microsoft\LiveCaptions"
            , "HKCU\Software\Microsoft\Windows\CurrentVersion\Accessibility\LiveCaptions"
            , "HKCU\Software\Microsoft\Accessibility\LiveCaptions"] {
        out .= "[" key "]`n"
        found := false
        try {
            Loop Reg, key, "KVR" {
                found := true
                if (A_LoopRegType = "KEY") {
                    out .= "  key " A_LoopRegKey "\" A_LoopRegName "`n"
                    continue
                }
                val := ""
                try val := RegRead()
                if (StrLen(val) > 120)
                    val := SubStr(val, 1, 120) "..."
                out .= "  " A_LoopRegKey " : " A_LoopRegName " (" A_LoopRegType ") = " val "`n"
            }
        }
        if !found
            out .= "  (nothing)`n"
    }
    try FileDelete(PROBE_INFO)
    FileAppend(out, PROBE_INFO, "UTF-8")
    txtStatus.Text := "Saved " PROBE_INFO
    try Run('notepad.exe "' PROBE_INFO '"')
}

DumpEl(el, depth) {
    if (depth > 14)
        return ""
    line := ""
    try {
        id := el.AutomationId
        name := id = "CaptionsTextBlock" ? "(caption text)" : el.Name
        if (StrLen(name) > 60)
            name := SubStr(name, 1, 60) "..."
        line := Format("{}{} | id={} | class={} | name={}`n", StrRepeat("  ", depth), el.LocalizedType, id, el.ClassName, name)
    } catch as err {
        line := StrRepeat("  ", depth) "(unreadable: " err.Message ")`n"
    }
    try {
        for child in el.Children
            line .= DumpEl(child, depth + 1)
    }
    return line
}

StrRepeat(s, n) {
    out := ""
    Loop n
        out .= s
    return out
}
