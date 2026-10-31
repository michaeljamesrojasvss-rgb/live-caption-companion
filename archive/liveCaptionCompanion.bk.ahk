#Requires AutoHotkey v2.0
#SingleInstance Force
#Include UIA.ahk
#Include Json.ahk

; ==============================================================================
; State
; ==============================================================================
class CaptionLine {
    __New(text) {
        this.Text := text
    }
}

captionEl := ""
lastCaption := ""
snapshotLines := []
snapshotMap := []          ; parallel array of [CaptionLine, prefixLength]
sessionLines := []
bubbles := []              ; each bubble is an array of CaptionLine
activeBubble := ""
baseline := Map()
lastChatTick := 0
changeCount := 0
NEW_TURN_MS := 2000

; Everything lives next to the script
HISTORY_DIR := A_ScriptDir
HISTORY_PATH := HISTORY_DIR "\call-history.json"
USER_HELPER_PATH := A_ScriptDir "\call-helpers.json"
MAX_HISTORY_BYTES := 50 * 1024 * 1024
history := ""              ; Map: the whole call-history document
currentCall := ""          ; Map: the session being recorded
historyAvailable := true
historyGui := ""
chatView := true
fontSize := 10
HELPER_H := 260            ; fixed height of the helpers accordion panel

; Review mode: look at a saved call in the main view while the live call keeps recording
reviewCall := ""           ; the saved session being reviewed ("" = normal live view)
viewLeft := 0              ; where the chat/transcript view starts (set once the GUI is built)
viewTop := 0
NOTES_LABEL := "VERIFIED INFO / CALL UPDATES  -  e.g. the real name and account, or who you already contacted"

; Call helpers
helperActions := []        ; valid action Maps from call-helpers.json
helperContexts := []       ; valid context Maps
helperConfigPath := ""
helpersVisible := false    ; accordion open/closed
helperPanelBuilt := false  ; controls created on myGui yet?
helperButtons := []
helperMiniButtons := []    ; small icon buttons beside each helper (Copilot submit)
hStatusLine := ""
hNone := ""
hPreviewStatus := ""
hPreview := ""
hBtnCopy := ""
hBtnReload := ""
hBtnOpen := ""
lastCopiedPrompt := ""
activePrompt := ""         ; the prepared-prompt record for the prompt being shown
selectedText := ""         ; most recent text highlighted in Chat/Transcript

; Bubble deletion
pickedBubble := ""         ; the bubble the agent last clicked in the Chat view
removedWin := ""           ; the "Deleted bubbles" window

; Experimental: agent mic captions (whisper-stream)
micEnabled := false
micPid := 0
micReady := false
micDead := false
micReadPos := 0
micPartial := ""
micPartialAfterBubble := 0 ; where the shadow sits in the interleave
micCommitted := []         ; [{text, afterBubble}] finalized agent lines
micUndoStack := []         ; deleted agent bubbles for undo
MIC_INDENT := "                                        "  ; 40 spaces
micDataDir := A_Temp "\live-captions-companion"
micOutFile := micDataDir "\captions.txt"
micLogFile := micDataDir "\engine.log"
MIC_INI := A_ScriptDir "\live-captions.ini"

; Look for whisper-stream (needed only when mic captions are enabled)
micStreamExe := ""
micModelPath := ""
micWhisperDir := ""
for dir in [A_ScriptDir "\whisper", A_ScriptDir]
    if FileExist(dir "\whisper-stream.exe") {
        micWhisperDir := dir
        micStreamExe := dir "\whisper-stream.exe"
        break
    }
if (micStreamExe != "") {
    micModelFile := IniRead(MIC_INI, "Settings", "Model", "ggml-base.en.bin")
    for dir in [micWhisperDir, A_ScriptDir, micWhisperDir "\models"]
        if FileExist(dir "\" micModelFile) {
            micModelPath := dir "\" micModelFile
            break
        }
}
micAvailable := (micStreamExe != "" && micModelPath != "")

; Discover mic devices via whisper-stream (runs once at startup)
micDeviceIds := []
micDeviceNames := []
micCurrentDevice := 0      ; 0 = system default
if micAvailable {
    micDevFile := micDataDir "\devices.txt"
    DirCreate(micDataDir)
    try FileDelete(micDevFile)
    RunWait(A_ComSpec ' /c ""' micStreamExe '" -m "__list_devices__" 2> "' micDevFile '""', micWhisperDir, "Hide")
    if FileExist(micDevFile)
        for line in StrSplit(StrReplace(FileRead(micDevFile, "UTF-8"), "`r"), "`n")
            if RegExMatch(line, "Capture device #(\d+): '(.*)'", &m) {
                micDeviceIds.Push(m[1])
                micDeviceNames.Push(m[2])
            }
    ; Restore saved mic
    savedMicName := IniRead(MIC_INI, "Companion", "Mic", "")
    if (savedMicName != "")
        for i, name in micDeviceNames
            if (name = savedMicName) {
                micCurrentDevice := i
                break
            }
}

MicDeviceLabel(index) {
    return index = 0 ? "Windows default microphone" : micDeviceNames[index]
}

; ==============================================================================
; GUI
; ==============================================================================
myGui := Gui("+Resize +MinSize600x480", "Live Caption Companion")
myGui.BackColor := "11151D"
myGui.SetFont("s10 cF1F5FB", "Segoe UI")
pinned := false
btnPin := myGui.Add("Button", "w30 h22", "📍")
statusText := myGui.Add("Text", "x+8 w570", "Status: starting...")
myGui.Add("Text", "xm w640 c9BA8BA", "Current caption")
current := myGui.Add("Edit", "w640 r4 ReadOnly +0x100 Background1B2431 cF1F5FB")
btnChat    := myGui.Add("Button", "w90",      "Chat")
btnTrans   := myGui.Add("Button", "x+8 w100", "Transcript")
btnFontDec := myGui.Add("Button", "x+16 w30", "A−")
btnFontInc := myGui.Add("Button", "x+4  w30", "A+")
btnPrev    := myGui.Add("Button", "x+16 w95", "◀ Prev call")
transcript := myGui.Add("Edit", "xm w640 r14 ReadOnly +0x100 Background1B2431 cF1F5FB")
chatBox := myGui.Add("Edit", "xp yp wp hp ReadOnly +0x100 Background1B2431 cF1F5FB")
reviewBanner := myGui.Add("Text", "xm w640 h28 +0x200 Background3B3215 cFBBF24 Hidden", "")
btnLive := myGui.Add("Button", "x+6 w140 h28 Hidden", "Back to live call")
notesLabel := myGui.Add("Text", "xm w640 c9BA8BA", NOTES_LABEL)
notesBox := myGui.Add("Edit", "xm w640 r3 Multi VScroll WantReturn +0x100 Background1B2431 cF1F5FB")
debugText := myGui.Add("Text", "xm w640 c9BA8BA", "")
btnNew := myGui.Add("Button", "w100", "New call")
btnHist := myGui.Add("Button", "x+10 w110", "Call history")
btnHelp := myGui.Add("Button", "x+10 w110", "Helpers ▼")
btnCopy := myGui.Add("Button", "x+10 w140", "Copy transcript")
transcript.GetPos(&viewLeft, &viewTop)

btnNew.OnEvent("Click", NewCall)
btnHist.OnEvent("Click", ShowHistoryWindow)
btnHelp.OnEvent("Click", ToggleHelpers)
btnCopy.OnEvent("Click", CopyTranscript)
notesBox.OnEvent("Change", NotesChanged)
btnChat.OnEvent("Click",    (*) => SetView(true))
btnTrans.OnEvent("Click",   (*) => SetView(false))
btnFontDec.OnEvent("Click", (*) => ChangeFontSize(-1))
btnFontInc.OnEvent("Click", (*) => ChangeFontSize(1))
btnPrev.OnEvent("Click", ReviewPrevious)
btnPin.OnEvent("Click", TogglePin)

; Right-click context menu on the chat/transcript view
chatCtxMenu := Menu()
chatCtxMenu.Add("Delete bubble", (*) => DeleteSelectedBubble())
chatCtxMenu.Add("Undo delete`tCtrl+Z", (*) => UndoLastDelete())
chatCtxMenu.Add("Deleted bubbles…", ShowRemovedWindow)

; Intercept right-click on chatBox: pick bubble, show custom menu, suppress
; the Edit control's default context menu by blocking WM_RBUTTONDOWN entirely.
OnMessage(0x0204, ChatRButtonDown)     ; WM_RBUTTONDOWN

ChatRButtonDown(wParam, lParam, msg, hwnd) {
    if (hwnd != chatBox.Hwnd || !chatView)
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    pt := Buffer(8, 0)
    NumPut("Int", x, pt, 0)
    NumPut("Int", y, pt, 4)
    charPos := SendMessage(0x00D7, 0, pt, chatBox.Hwnd) & 0xFFFF   ; EM_CHARFROMPOS
    PickBubbleAt(charPos)
    chatCtxMenu.Show()
    return 0    ; suppress — prevents WM_RBUTTONUP and default Edit menu from firing
}

TogglePin(*) {
    global pinned
    pinned := !pinned
    myGui.Opt((pinned ? "+" : "-") "AlwaysOnTop")
    btnPin.Text := pinned ? "📌" : "📍"
}
OnMessage(0x0202, ChatLButtonUp)       ; WM_LBUTTONUP: remember which bubble was clicked
btnLive.OnEvent("Click", ExitReview)
myGui.OnEvent("Close", (*) => ExitApp())
myGui.OnEvent("Size", GuiResize)
ShowAtMinWidthMaxHeight()
SetView(true)

; Ctrl+Shift+Alt+H — toggle the companion window on/off without closing it
guiVisible := true
^+!h:: {
    global guiVisible
    if guiVisible {
        myGui.Hide()
        guiVisible := false
    } else {
        myGui.Show()
        guiVisible := true
    }
}

OnExit(HandleExit)
LoadHelperActions()
LoadHistory()
StartNewCallRecord()
SetTimer(ReadCaption, 200)
SetTimer(TrackSelection, 250)

; Mic captions tray toggle (only shown if whisper-stream is available)
if micAvailable {
    ; Build mic device submenu
    micDevMenu := Menu()
    micDevMenu.Add(MicDeviceLabel(0), SetMicDevice.Bind(0))
    if micDeviceNames.Length
        micDevMenu.Add()
    for i, name in micDeviceNames
        micDevMenu.Add(name, SetMicDevice.Bind(i))
    micDevMenu.Check(MicDeviceLabel(micCurrentDevice))

    A_TrayMenu.Insert("1&")
    A_TrayMenu.Insert("1&", "Mic device", micDevMenu)
    A_TrayMenu.Insert("1&", "Experimental: Mic captions", ToggleMicCaptions)
    micEnabled := IniRead(MIC_INI, "Companion", "MicCaptions", "0") = "1"
    if micEnabled {
        A_TrayMenu.Check("Experimental: Mic captions")
        StartMicEngine()
        SetTimer(PollMic, 200)
    }
}

HandleExit(*) {
    StopMicEngine()
    SaveNotes()
    FinishCurrentCall()
}

; ==============================================================================
; Font size
; ==============================================================================
ChangeFontSize(delta) {
    global fontSize
    fontSize := Max(8, Min(20, fontSize + delta))
    ApplyFontSize()
}

ApplyFontSize() {
    current.SetFont("s" fontSize)
    transcript.SetFont("s" fontSize)
    chatBox.SetFont("s" fontSize)
    notesBox.SetFont("s" fontSize)
}

; ==============================================================================
; Polling
; ==============================================================================
ReadCaption() {
    global captionEl, lastCaption, changeCount

    try {
        if !IsObject(captionEl) {
            hwnd := WinExist("ahk_exe LiveCaptions.exe")
            if !hwnd {
                statusText.Text := "Status: looking for Windows Live Captions (Win+Ctrl+L)..."
                return
            }
            root := UIA.ElementFromHandle(hwnd)
            captionEl := root.FindElement({AutomationId: "CaptionsTextBlock"})
            statusText.Text := "Status: connected to Windows Live Captions"
        }
        caption := Trim(captionEl.Name, " `t`r`n")
    } catch {
        captionEl := ""
        statusText.Text := "Status: reconnecting..."
        return
    }

    if (caption = "")
        return

    lines := SplitLines(caption)
    SetEditText(current, JoinWith(lines, "`r`n"))

    if (caption == lastCaption) {
        RefreshDebug()
        return
    }

    changeCount += 1
    ProcessSnapshot(lines)
    RenderTranscript()
    PersistCurrentCall()
    lastCaption := caption
    RefreshDebug()
}

SplitLines(text) {
    out := []
    for part in StrSplit(text, ["`r`n", "`n", "`r"], " `t") {
        if (part != "")
            out.Push(part)
    }
    return out
}

JoinWith(arr, sep) {
    s := ""
    for item in arr
        s .= (A_Index = 1 ? "" : sep) . item
    return s
}

; Opens the window at its minimum width (600, from +MinSize600x480) and the full
; working height of the screen it opens on (the area above the taskbar).
ShowAtMinWidthMaxHeight() {
    minW := 600                                   ; keep in sync with +MinSize600x480
    myGui.Show("w" minW " h480")
    hwnd := myGui.Hwnd
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)

    ; Use the monitor the window opened on
    cx := x + w // 2
    cy := y + h // 2
    mon := MonitorGetPrimary()
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (cx >= l && cx < r && cy >= t && cy < b) {
            mon := A_Index
            break
        }
    }
    MonitorGetWorkArea(mon, &left, &top, &right, &bottom)

    ; Windows 10/11 windows have an invisible border; add its height so the
    ; visible bottom edge meets the taskbar instead of stopping short
    extra := 0
    try {
        rect := Buffer(16, 0)
        if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "Int", 9, "Ptr", rect, "Int", 16) = 0)
            extra := Max(0, (y + h) - NumGet(rect, 12, "Int"))
    }
    WinMove(x, top, w, (bottom - top) + extra, "ahk_id " hwnd)
}

; Saved with the call a moment after you stop typing
NotesChanged(*) {
    SetTimer(SaveNotes, -800)
}

SaveNotes() {
    ; The box belongs to the reviewed call while reviewing, otherwise to the live call
    target := IsObject(reviewCall) ? reviewCall : currentCall
    if !IsObject(target)
        return
    if (target.Get("agentNotes", "") == notesBox.Value)
        return
    target["agentNotes"] := notesBox.Value
    SaveHistory()
}

; ==============================================================================
; Snapshot diffing
; ==============================================================================
ProcessSnapshot(lines) {
    global snapshotLines, snapshotMap, sessionLines, bubbles, activeBubble
    global baseline, lastChatTick, NEW_TURN_MS

    if (lines.Length = 0)
        return

    now := A_TickCount

    if (snapshotLines.Length = 0) {
        bubble := []
        bubbles.Push(bubble)
        for text in lines {
            line := CaptionLine(text)
            sessionLines.Push(line)
            bubble.Push(line)
            snapshotMap.Push([line, 0])
            snapshotLines.Push(text)
        }
        activeBubble := bubble
        lastChatTick := now
        return
    }

    isNewTurn := (now - lastChatTick) >= NEW_TURN_MS

    overlap := FindSuffixPrefixOverlap(snapshotLines, lines)
    hasRollingWindow := overlap > 0
        && overlap < Min(snapshotLines.Length, lines.Length)
        && lines.Length <= snapshotLines.Length

    currentMap := []
    sharedCount := hasRollingWindow ? overlap : Min(lines.Length, snapshotLines.Length)
    oldStart := hasRollingWindow ? snapshotLines.Length - overlap : 0

    Loop sharedCount {
        index := A_Index - 1
        oldIndex := oldStart + index
        previousLine := snapshotLines[oldIndex + 1]
        pair := snapshotMap[oldIndex + 1]
        entry := pair[1]
        prefixLength := pair[2]
        currentMap.Push([entry, prefixLength])
        cur := lines[index + 1]

        if (cur == previousLine)
            continue

        if baseline.Has(entry) {
            commonPrefix := CommonPrefixLength(previousLine, cur)
            newTail := Trim(SubStr(cur, commonPrefix + 1))
            if (newTail != "") {
                if (!IsObject(activeBubble) || isNewTurn) {
                    activeBubble := []
                    bubbles.Push(activeBubble)
                }
                tailEntry := CaptionLine(newTail)
                sessionLines.Push(tailEntry)
                activeBubble.Push(tailEntry)
                baseline.Delete(entry)
                currentMap[index + 1] := [tailEntry, commonPrefix]
            } else {
                currentMap[index + 1] := [entry, StrLen(cur)]
            }
            continue
        }

        if (isNewTurn && lines.Length <= snapshotLines.Length && index = sharedCount - 1) {
            commonPrefix := CommonPrefixLength(previousLine, cur)
            newTail := Trim(SubStr(cur, commonPrefix + 1))
            if (newTail != "") {
                bubble := []
                bubbles.Push(bubble)
                tailEntry := CaptionLine(newTail)
                sessionLines.Push(tailEntry)
                bubble.Push(tailEntry)
                currentMap[index + 1] := [tailEntry, commonPrefix]
                activeBubble := bubble
            } else {
                entry.Text := Trim(SubStr(cur, prefixLength + 1))
            }
        } else {
            entry.Text := Trim(SubStr(cur, prefixLength + 1))
        }
    }

    firstNewIndex := sharedCount
    Loop lines.Length - firstNewIndex {
        index := firstNewIndex + A_Index - 1
        if (!IsObject(activeBubble) || (isNewTurn && index = firstNewIndex)) {
            activeBubble := []
            bubbles.Push(activeBubble)
        }
        entry := CaptionLine(lines[index + 1])
        sessionLines.Push(entry)
        activeBubble.Push(entry)
        currentMap.Push([entry, 0])
    }

    snapshotLines := lines.Clone()
    snapshotMap := currentMap
    lastChatTick := now
}

FindSuffixPrefixOverlap(previous, cur) {
    count := Min(previous.Length, cur.Length)
    while (count > 0) {
        matches := true
        Loop count {
            if (previous[previous.Length - count + A_Index] !== cur[A_Index]) {
                matches := false
                break
            }
        }
        if matches
            return count
        count -= 1
    }
    return 0
}

CommonPrefixLength(a, b) {
    n := Min(StrLen(a), StrLen(b))
    i := 0
    while (i < n && SubStr(a, i + 1, 1) == SubStr(b, i + 1, 1))
        i += 1
    return i
}

; ==============================================================================
; Call sessions + history persistence
; ==============================================================================
NowIso() {
    return FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss") "." Format("{:03}", A_MSec) "Z"
}

NewHistoryDoc() {
    doc := Map()
    doc.CaseSense := false
    doc["schemaVersion"] := 1
    doc["sessions"] := []
    return doc
}

NewGuid() {
    s := ""
    Loop 32
        s .= Format("{:x}", Random(0, 15))
    return s
}

ValidateHistory(doc) {
    if (Type(doc) != "Map")
        throw Error("The history root must be an object.")
    if (!doc.Has("schemaVersion") || doc["schemaVersion"] != 1)
        throw Error("Call history schema version is not supported.")
    if (!doc.Has("sessions") || Type(doc["sessions"]) != "Array")
        throw Error("Call history is missing its sessions list.")
    ids := Map()
    for s in doc["sessions"] {
        if (Type(s) != "Map" || !s.Has("id") || Trim(String(s["id"])) = "" || ids.Has(s["id"]))
            throw Error("Call history contains an empty or duplicate session ID.")
        ids[s["id"]] := true
        for key in ["transcriptLines", "chatBubbles", "preparedPrompts"] {
            if (!s.Has(key) || Type(s[key]) != "Array")
                throw Error("Session '" s["id"] "' is missing its " key " list.")
        }
        if (!s.Has("startedAtUtc"))
            throw Error("Session '" s["id"] "' has no start time.")
    }
}

LoadHistory() {
    global history, historyAvailable

    if !FileExist(HISTORY_PATH) {
        history := NewHistoryDoc()
        return
    }

    try {
        if (FileGetSize(HISTORY_PATH) > MAX_HISTORY_BYTES)
            throw Error("Call history file exceeds the 50 MB safety limit.")
        history := Json.Parse(FileRead(HISTORY_PATH, "UTF-8"))
        ValidateHistory(history)
    } catch as err {
        ; Same safety rule as the C# app: never overwrite a file we could not read.
        historyAvailable := false
        history := NewHistoryDoc()
        statusText.Text := "Status: call history could not be loaded; new calls will not be saved: " err.Message
        return
    }

    recovered := false
    sessions := history["sessions"]
    i := sessions.Length
    while (i >= 1) {
        s := sessions[i]
        if (s["transcriptLines"].Length = 0 && s["preparedPrompts"].Length = 0 && RemovedCount(s) = 0) {
            sessions.RemoveAt(i)
            recovered := true
        } else if (!s.Has("endedAtUtc") || s["endedAtUtc"] is JNull) {
            s["endedAtUtc"] := NowIso()
            recovered := true
        }
        i -= 1
    }
    if recovered
        SaveHistory()
}

SaveHistory() {
    if (!historyAvailable)
        return
    try {
        jsonText := Json.Stringify(history)
        DirCreate(HISTORY_DIR)
        tmp := HISTORY_DIR "\.call-history." A_TickCount ".tmp"
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        f.Write(jsonText)
        f.Close()
        FileMove(tmp, HISTORY_PATH, true)
    } catch as err {
        statusText.Text := "Status: call is active, but the latest changes could not be saved: " err.Message
    }
}

StartNewCallRecord() {
    global currentCall
    s := Map()
    s.CaseSense := false
    s["id"] := NewGuid()
    s["startedAtUtc"] := NowIso()
    s["endedAtUtc"] := Json.Null
    s["transcriptLines"] := []
    s["chatBubbles"] := []
    s["preparedPrompts"] := []
    s["agentNotes"] := ""
    currentCall := s
    history["sessions"].Push(s)
    SeedCaptionBaseline(lastCaption)
    PersistCurrentCall()
}

PersistCurrentCall() {
    if !IsObject(currentCall)
        return
    tl := []
    for line in sessionLines {
        if (Trim(line.Text) != "")
            tl.Push(line.Text)
    }
    currentCall["transcriptLines"] := tl
    currentCall["chatBubbles"] := BubbleTexts()
    SaveHistory()
}

FinishCurrentCall() {
    global currentCall
    if !IsObject(currentCall)
        return

    if (sessionLines.Length = 0 && currentCall["preparedPrompts"].Length = 0 && RemovedCount(currentCall) = 0) {
        sessions := history["sessions"]
        Loop sessions.Length {
            if (sessions[A_Index] == currentCall) {
                sessions.RemoveAt(A_Index)
                break
            }
        }
        SaveHistory()
    } else {
        currentCall["endedAtUtc"] := NowIso()
        PersistCurrentCall()
    }
    currentCall := ""
}

ResetCallView() {
    global sessionLines, snapshotLines, snapshotMap, baseline, bubbles
    global activeBubble, changeCount, lastChatTick
    global micCommitted, micPartial, micPartialAfterBubble, micUndoStack
    sessionLines := []
    snapshotLines := []
    snapshotMap := []
    baseline := Map()
    bubbles := []
    activeBubble := ""
    changeCount := 0
    lastChatTick := 0
    micCommitted := []
    micPartial := ""
    micPartialAfterBubble := 0
    micUndoStack := []
    ClearPromptState()
    notesBox.Value := ""
    RenderTranscript()
    SeedCaptionBaseline(lastCaption)
    RefreshDebug()
}

; Treat the caption text already on screen as a baseline so the previous call's
; visible text is never copied into the new call's transcript.
SeedCaptionBaseline(caption) {
    global snapshotLines, snapshotMap, baseline, lastChatTick
    snapshotLines := []
    snapshotMap := []
    for line in SplitLines(caption) {
        snapshotLines.Push(line)
        bl := CaptionLine("")
        baseline[bl] := true
        snapshotMap.Push([bl, StrLen(line)])
    }
    if (snapshotLines.Length > 0)
        lastChatTick := A_TickCount
}

NewCall(*) {
    ExitReview()                       ; back to the live call first if reviewing
    myGui.Opt("+OwnDialogs")
    hasData := sessionLines.Length > 0
        || (IsObject(currentCall) && currentCall["preparedPrompts"].Length > 0)
    if (hasData && MsgBox("Save this call to history and start a new call?`n`nThe current transcript and prepared prompts will be kept.", "Start a new call", "YesNo Icon?") != "Yes")
        return
    SaveNotes()
    FinishCurrentCall()
    ResetCallView()
    StartNewCallRecord()
    statusText.Text := "Status: new call started"
}

; ==============================================================================
; Call history window
; ==============================================================================
IsoToLocal(iso, fmt) {
    if !RegExMatch(iso, "^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)", &m)
        return iso
    stamp := m[1] m[2] m[3] m[4] m[5] m[6]
    offsetMinutes := Round(DateDiff(A_Now, A_NowUTC, "Seconds") / 60)
    return FormatTime(DateAdd(stamp, offsetMinutes, "Minutes"), fmt)
}

SessionTitle(s) {
    ended := s.Get("endedAtUtc", Json.Null)
    if (ended is JNull)
        return "Current call"
    return IsoToLocal(s["startedAtUtc"], "MMM d, yyyy h:mm tt")
}

SessionSummary(s) {
    ended := s.Get("endedAtUtc", Json.Null)
    endText := (ended is JNull) ? "In progress" : "Ended " IsoToLocal(ended, "h:mm tt")
    removedText := RemovedCount(s) > 0 ? "  ·  " . RemovedCount(s) . " deleted bubble(s)" : ""
    return endText "  ·  " s["transcriptLines"].Length " transcript line(s)  ·  " s["preparedPrompts"].Length " prompt(s)" removedText
}

BuildDetails(s) {
    sections := ["TRANSCRIPT"]
    tl := s["transcriptLines"]
    sections.Push(tl.Length = 0 ? "No caption text was captured." : JoinWith(tl, "`r`n"))
    
    notes := s.Get("agentNotes", "")
    if (Trim(notes) != "") {
        sections.Push("VERIFIED INFO / CALL UPDATES")
        sections.Push(notes)
    }

    cb := s["chatBubbles"]
    if (cb.Length > 0) {
        sections.Push("CHAT GROUPS")
        sections.Push(JoinWith(cb, "`r`n`r`n"))
    }

    pp := s["preparedPrompts"]
    if (pp.Length > 0) {
        sections.Push("PREPARED PROMPTS")
        for p in pp {
            sections.Push("[" IsoToLocal(p.Get("createdAtUtc", ""), "h:mm:ss tt") "] " p.Get("helperLabel", ""))
            sections.Push(p.Get("prompt", ""))
        }
    }
    return JoinWith(sections, "`r`n`r`n")
}

ShowHistoryWindow(*) {
    global historyGui
    PersistCurrentCall()

    if IsObject(historyGui) {
        try historyGui.Destroy()
    }

    ; newest first
    src := history["sessions"]
    sessions := []
    Loop src.Length
        sessions.Push(src[src.Length - A_Index + 1])

    items := []
    for s in sessions
        items.Push(SessionTitle(s) "  ·  " SessionSummary(s))

    hg := Gui("+Owner" myGui.Hwnd, "Call history")
    hg.BackColor := "11151D"
    hg.SetFont("s10 cF1F5FB", "Segoe UI")
    lb := hg.Add("ListBox", "w360 r18 Background1B2431 cF1F5FB", items)
    details := hg.Add("Edit", "x+10 w560 r18 ReadOnly +0x100 Background1B2431 cF1F5FB")
    hStatus := hg.Add("Text", "xm w920 c9BA8BA", sessions.Length " saved call(s)")
    btnCopyDetails := hg.Add("Button", "w120", "Copy details")
    btnViewMain := hg.Add("Button", "x+10 w180", "View in main window")
    btnCloseHist := hg.Add("Button", "x+10 w100", "Close")

    state := {text: ""}

    ShowSelected() {
        idx := lb.Value
        if (!idx) {
            details.Value := ""
            state.text := ""
            return
        }
        state.text := BuildDetails(sessions[idx])
        details.Value := state.text
    }

    CopyDetails() {
        if (Trim(state.text) = "") {
            hStatus.Text := "Select a call to copy its details"
            return
        }
        A_Clipboard := state.text
        hStatus.Text := "Call details copied"
    }

    ViewInMain() {
        idx := lb.Value
        if (!idx) {
            hStatus.Text := "Select a call first"
            return
        }
        picked := sessions[idx]
        hg.Destroy()
        EnterReview(picked)
        WinActivate("ahk_id " myGui.Hwnd)
    }

    lb.OnEvent("Change", (*) => ShowSelected())
    lb.OnEvent("DoubleClick", (*) => ViewInMain())
    btnViewMain.OnEvent("Click", (*) => ViewInMain())
    btnCopyDetails.OnEvent("Click", (*) => CopyDetails())
    btnCloseHist.OnEvent("Click", (*) => hg.Destroy())
    hg.OnEvent("Close", (*) => hg.Destroy())

    historyGui := hg
    hg.Show()
    if (sessions.Length > 0) {
        lb.Choose(1)
        ShowSelected()
    }
}

; ==============================================================================
; Call helpers (port of LoadHelperActions / HelperAction_Click)
; ==============================================================================
HasText(m, key) {
    return m.Has(key) && Type(m[key]) = "String" && Trim(m[key]) != ""
}

NormalizeNewlines(s) {
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "`r`n")
}

LoadHelperActions() {
    global helperActions, helperContexts, helperConfigPath, lastCopiedPrompt, activePrompt

    helperActions := []
    helperContexts := []
    lastCopiedPrompt := ""
    activePrompt := ""
    ClearPreview()

    path := FileExist(USER_HELPER_PATH) ? USER_HELPER_PATH : ""
    helperConfigPath := path

    info := ""
    if (path = "") {
        statusText.Text := "Status: no call helpers loaded (call-helpers.json was not found)"
        info := "call-helpers.json was not found. Put it next to the script: " A_ScriptDir
    } else {
        try {
            config := Json.Parse(FileRead(path, "UTF-8"))
            if (Type(config) != "Map")
                throw Error("The JSON root must be an object.")

            skipped := 0
            if (config.Has("context") && Type(config["context"]) = "Array") {
                for c in config["context"] {
                    if (Type(c) != "Map" || !HasText(c, "name") || !HasText(c, "description") || !HasText(c, "context")) {
                        skipped += 1
                        continue
                    }
                    helperContexts.Push(c)
                }
            }

            seen := Map()
            seen.CaseSense := false
            if (config.Has("actions") && Type(config["actions"]) = "Array") {
                for a in config["actions"] {
                    if (Type(a) != "Map" || !HasText(a, "id") || !HasText(a, "label") || !HasText(a, "prompt")
                        || seen.Has(Trim(a["id"]))) {
                        skipped += 1
                        continue
                    }
                    seen[Trim(a["id"])] := true
                    helperActions.Push(a)
                }
            }

            info := "Loaded " helperActions.Length " helper(s) and " helperContexts.Length " context(s)"
            if (skipped > 0)
                info .= "; skipped " skipped " invalid or duplicate item(s)"
            statusText.Text := "Status: " info
            info .= "  ·  " path
        } catch as err {
            helperActions := []
            helperContexts := []
            statusText.Text := "Status: could not load call-helpers.json: " err.Message
            info := "Could not load call-helpers.json: " err.Message
        }
    }

    RebuildHelperButtons(info)
}

; Build helper panel controls on myGui the first time they're needed.
; Controls are added Hidden; ToggleHelpers shows/hides them.
EnsureHelperPanel() {
    global helperPanelBuilt, hStatusLine, hNone, hPreviewStatus, hPreview
    global hBtnCopy, hBtnReload, hBtnOpen

    if helperPanelBuilt
        return

    hStatusLine   := myGui.Add("Text",   "x10 y0 w400 c9BA8BA Hidden", "")
    hNone         := myGui.Add("Text",   "x10 y0 w400 c9BA8BA Hidden",
                        "No helper buttons yet. Add actions to call-helpers.json, then click Reload.")
    hPreviewStatus := myGui.Add("Text",  "x10 y0 w400 c9BA8BA Hidden", "")
    hPreview      := myGui.Add("Edit",   "x10 y0 w400 r4 +0x100 Background1B2431 cF1F5FB Hidden")
    hBtnCopy      := myGui.Add("Button", "x10 y0 w120 Hidden", "Copy again")
    hBtnReload    := myGui.Add("Button", "x10 y0 w100 Hidden",  "Reload")
    hBtnOpen      := myGui.Add("Button", "x10 y0 w150 Hidden",  "Edit helpers")

    hPreview.OnEvent("Change", PreviewChanged)
    hBtnCopy.OnEvent("Click",  (*) => CopyPromptToClipboard(hPreview.Value))
    hBtnReload.OnEvent("Click", (*) => LoadHelperActions())
    hBtnOpen.OnEvent("Click",  OpenHelperEditor)
    helperPanelBuilt := true
}

ToggleHelpers(*) {
    global helpersVisible
    helpersVisible := !helpersVisible
    btnHelp.Text := helpersVisible ? "Helpers ▲" : "Helpers ▼"
    EnsureHelperPanel()
    ShowHideHelperControls(helpersVisible)
    myGui.GetClientPos(, , &w, &h)
    GuiResize(myGui, 0, w, h)
}

ShowHideHelperControls(vis) {
    hStatusLine.Visible    := vis
    hNone.Visible          := (vis && helperActions.Length = 0)
    hPreviewStatus.Visible := vis
    hPreview.Visible       := vis
    hBtnCopy.Visible       := vis
    hBtnReload.Visible     := vis
    hBtnOpen.Visible       := vis
    Loop Min(helperActions.Length, helperButtons.Length)
        helperButtons[A_Index].Visible := vis
    Loop Min(helperActions.Length, helperMiniButtons.Length)
        helperMiniButtons[A_Index].Visible := vis
}

RebuildHelperButtons(info := "") {
    global helperButtons, helperMiniButtons

    EnsureHelperPanel()

    ; A single control cannot be destroyed in AutoHotkey v2, so keep a pool of
    ; buttons: reuse them for the current helpers and hide any extras.
    n := helperActions.Length
    for i, action in helperActions {
        label := Trim(action["label"])
        shown := StrReplace(label, "&", "&&")
        w := Max(110, StrLen(label) * 8 + 30)
        ; Main button — clipboard only
        if (i <= helperButtons.Length) {
            btn := helperButtons[i]
            btn.Text := shown
            btn.Move(, , w)
        } else {
            btn := myGui.Add("Button", "x0 y0 w" w " h30 Hidden", shown)
            btn.OnEvent("Click", HelperClickedAt.Bind(i))
            helperButtons.Push(btn)
        }
        btn.Visible := helpersVisible
        ; Mini icon button — Copilot submit
        if (i <= helperMiniButtons.Length) {
            helperMiniButtons[i].Visible := helpersVisible
        } else {
            mini := myGui.Add("Button", "x0 y0 w30 h30 Hidden", "🤖")
            mini.OnEvent("Click", HelperCopilotAt.Bind(i))
            helperMiniButtons.Push(mini)
        }
        helperMiniButtons[i].Visible := helpersVisible
    }
    Loop helperButtons.Length - n
        helperButtons[n + A_Index].Visible := false
    Loop helperMiniButtons.Length - n
        helperMiniButtons[n + A_Index].Visible := false

    hNone.Visible := (helpersVisible && n = 0)
    if (info != "")
        hStatusLine.Text := info
    if (helpersVisible) {
        myGui.GetClientPos(, , &w, &h)
        LayoutHelperPanel(w, h)
    }
}

; Each pooled button runs whichever helper currently sits at its position
HelperClickedAt(i, *) {
    if (i <= helperActions.Length)
        HelperClicked(helperActions[i])
}

; Mini icon button: prepare prompt, copy, then submit to Copilot
HelperCopilotAt(i, *) {
    if (i <= helperActions.Length) {
        HelperClicked(helperActions[i])
        SubmitToCopilot()
    }
}

LayoutHelperPanel(width, height) {
    if !helperPanelBuilt
        return

    margin  := 10
    ; Panel occupies the HELPER_H band directly above the debug/button row (80px)
    panelY  := height - 80 - HELPER_H
    y       := panelY

    hStatusLine.Move(margin, y, width - 2 * margin)
    y += 24

    n := Min(helperActions.Length, helperButtons.Length)
    nm := Min(helperActions.Length, helperMiniButtons.Length)
    if (n = 0) {
        hNone.Move(margin, y, width - 2 * margin)
        y += 30
    } else {
        x    := margin
        rowH := 36
        miniW := 30
        Loop n {
            btn := helperButtons[A_Index]
            btn.GetPos(, , &bw)
            pairW := bw + 2 + miniW  ; main + gap + mini icon
            if (x > margin && x + pairW > width - margin) {
                x := margin
                y += rowH
            }
            btn.Move(x, y)
            if (A_Index <= nm)
                helperMiniButtons[A_Index].Move(x + bw + 2, y, miniW)
            x += pairW + 7
        }
        y += rowH + 6
    }

    hPreviewStatus.Move(margin, y, width - 2 * margin)
    y += 22

    ; Action buttons sit 38 px above the bottom of the panel
    by := height - 80 - 38
    previewH := Max(30, by - y - 4)
    hPreview.Move(margin, y, width - 2 * margin, previewH)

    hBtnCopy.Move(margin,       by)
    hBtnReload.Move(margin + 130, by)
    hBtnOpen.Move(margin + 240, by)
}

BuildContextBlock() {
    parts := []
    for c in helperContexts
        parts.Push("Context: " c["name"] "`nDescription: " c["description"] "`nGuidance:`n" c["context"])
    return JoinWith(parts, "`n`n")
}

HelperClicked(action, *) {
    global lastCopiedPrompt, activePrompt

    TrackSelection()                                   ; capture the latest highlight first

    context := BuildContextBlock()
    raw := action["prompt"]
    hasContextPlaceholder := InStr(raw, "{{context}}")
    hasNotesPlaceholder := InStr(raw, "{{verifiedInfo}}")

    ; Agent-verified info / call updates typed in the box under the transcript
    notes := Trim(notesBox.Value, " `t`r`n")
    notesBlock := ""
    if (notes != "")
        notesBlock := "AGENT-VERIFIED INFORMATION AND CALL UPDATES (typed by the agent from the company's systems and the agent's own actions). "
            . "Treat this as correct: use these exact names, account names and details instead of anything in the transcript that conflicts, because captions can mishear names. "
            . "Actions listed here count as confirmed and already done, so do not suggest or draft them again.`n" notes

    transcriptValue := TranscriptText()
    if (notesBlock != "" && !hasNotesPlaceholder)
        transcriptValue := (transcriptValue = "" ? "" : transcriptValue "`n`n") notesBlock

    prompt := StrReplace(raw, "{{context}}", context)
    prompt := StrReplace(prompt, "{{transcript}}", transcriptValue)
    prompt := StrReplace(prompt, "{{verifiedInfo}}", notesBlock)
    prompt := StrReplace(prompt, "{{currentCaption}}", IsObject(reviewCall) ? "" : current.Value)
    prompt := StrReplace(prompt, "{{selectedText}}", selectedText)
    if (!hasContextPlaceholder && context != "")
        prompt .= "`n`nREFERENCE CONTEXT`n" context
    prompt := NormalizeNewlines(prompt)

    lastCopiedPrompt := prompt
    hPreview.Value := prompt

    rec := Map()
    rec.CaseSense := false
    rec["createdAtUtc"] := NowIso()
    rec["helperId"] := action["id"]
    rec["helperLabel"] := action["label"]
    rec["prompt"] := prompt
    activePrompt := rec
    if IsObject(reviewCall) {
        reviewCall["preparedPrompts"].Push(rec)        ; belongs to the call being reviewed
        SaveHistory()
    } else if IsObject(currentCall) {
        currentCall["preparedPrompts"].Push(rec)
        PersistCurrentCall()
    }

    CopyPromptToClipboard(prompt)   ; copies prompt to clipboard (main button stops here)
    SendMessage(0x00B1, 0, 0, hPreview.Hwnd)           ; caret to the start
    SendMessage(0x00B7, 0, 0, hPreview.Hwnd)           ; scroll caret into view
}

CopyPromptToClipboard(prompt) {
    global lastCopiedPrompt
    if (Trim(prompt) = "") {
        statusText.Text := "Status: there is no prompt to copy"
        return
    }
    A_Clipboard := prompt
    if (IsObject(activePrompt) && activePrompt["prompt"] !== prompt) {
        activePrompt["prompt"] := prompt
        PersistCurrentCall()
    }
    lastCopiedPrompt := prompt
    hPreviewStatus.Text := "PROMPT · COPIED" ReviewSuffix()
    statusText.Text := "Status: prompt copied to clipboard"
}

; ==============================================================================
; Copilot automation
; ==============================================================================

; Called from HelperClicked. Runs on a timer so the caption loop is never blocked.
SubmitToCopilot() {
    SetTimer(CopilotWorker, -50)
}

; Step-by-step log next to the script (window info only, never transcript text).
; Change "true" to "false" to switch it off.
CopilotLog(msg) {
    static enabled := true
    if !enabled
        return
    try FileAppend(FormatTime(, "HH:mm:ss") "." Format("{:03}", A_MSec) "  " msg "`n", A_ScriptDir "\copilot-debug.log", "UTF-8")
}

; Finds visible Copilot app windows. Returns Map("mini", hwnd or 0, "full", hwnd or 0).
; Titles seen so far:
;   work PC : mini "Copilot Quick View" (class "Microsoft Copilot (Undocked) Host")
;             full "Copilot" (class Chrome_WidgetWin_1)
;   home PC : mini "M365 Copilot quick view", full "Microsoft 365 Copilot"
FindCopilotWindows() {
    result := Map("mini", 0, "full", 0)
    for hwnd in WinGetList() {
        if (hwnd = myGui.Hwnd)
            continue
        try {
            title := Trim(WinGetTitle(hwnd))
            cls := WinGetClass(hwnd)
        } catch {
            continue
        }
        if (title = "")
            continue
        kind := ""
        if RegExMatch(title, "i)copilot.*quick\s*view")
            kind := "mini"
        else if RegExMatch(title, "i)^(microsoft 365|m365) copilot")
            kind := "full"
        else if (title = "Copilot" && cls = "Chrome_WidgetWin_1")
            kind := "full"
        if (kind = "")
            continue
        CopilotLog("candidate: '" title "'  class=" cls "  -> " kind)
        if (!result[kind])
            result[kind] := hwnd
    }
    return result
}
ActivateAndVerify(hwnd) {
    WinActivate("ahk_id " hwnd)
    if !WinWaitActive("ahk_id " hwnd, , 2) {
        CopilotLog("could not make the Copilot window active")
        return false
    }
    return true
}

; Pastes the clipboard and presses Enter, but only while Copilot is the active window.
PasteAndSend(hwnd) {
    if !WinActive("ahk_id " hwnd) {
        CopilotLog("refusing to paste: Copilot is not the active window")
        return false
    }
    Send("^a")
    Sleep(80)
    Send("^v")
    Sleep(250)
    if !WinActive("ahk_id " hwnd) {
        CopilotLog("Copilot lost focus before Enter; not pressing Enter")
        return false
    }
    Send("{Enter}")
    return true
}

SubmitViaUia(hwnd) {
    inputEl := ""
    try {
        root := UIA.ElementFromHandle(hwnd)
    } catch as err {
        CopilotLog("UIA: could not open the window: " err.Message)
        return false
    }

    ; Mini view = PromptInput, full window = m365-chat-editor-target-element.
    ; The full window is a web page, so its controls can take a moment to appear.
    Loop 8 {
        for id in ["PromptInput", "m365-chat-editor-target-element"] {
            try inputEl := root.FindElement({AutomationId: id})
            if IsObject(inputEl) {
                CopilotLog("UIA: found input box '" id "'")
                break
            }
        }
        if IsObject(inputEl)
            break
        Sleep(250)
    }

    if !IsObject(inputEl) {
        CopilotLog("UIA: known input boxes not found")
        return false
    }

    if !ActivateAndVerify(hwnd)
        return false
    try inputEl.SetFocus()
    Sleep(200)
    return PasteAndSend(hwnd)
}

SubmitViaClick(hwnd) {
    if !ActivateAndVerify(hwnd)
        return false
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    MouseClick("Left", wx + ww // 2, wy + wh - 55)
    Sleep(150)
    return PasteAndSend(hwnd)
}

CopilotWorker() {
    prevHwnd := WinExist("A")
    CopilotLog("---- submit started (previous window program: " (prevHwnd ? WinGetProcessName("ahk_id " prevHwnd) : "none") ")")
    statusText.Text := "Status: sending prompt to Copilot..."

    wins := FindCopilotWindows()

    ; Only the full window is open: close it so Win+C can bring up the mini view
    if (!wins["mini"] && wins["full"]) {
        CopilotLog("only the full window is open; closing it first")
        old := wins["full"]
        WinClose("ahk_id " old)
        Loop 15 {
            Sleep(100)
            if !WinExist("ahk_id " old)
                break
        }
        wins := FindCopilotWindows()
    }

    if (!wins["mini"]) {
        CopilotLog("sending Win+C")
        SendInput("{LWin Down}c{LWin Up}")
        Loop 25 {
            Sleep(150)
            wins := FindCopilotWindows()
            if (wins["mini"] || wins["full"])
                break
        }
    }
    CopilotLog("after waiting: mini=" wins["mini"] "  full=" wins["full"])

    ok := false
    if (wins["mini"]) {
        ok := SubmitViaUia(wins["mini"])
    } else if (wins["full"]) {
        ok := SubmitViaUia(wins["full"])
        if (!ok) {
            CopilotLog("UIA failed on the full window; trying the click fallback")
            ok := SubmitViaClick(wins["full"])
        }
    } else {
        CopilotLog("no Copilot window found")
    }

    if (prevHwnd && WinExist("ahk_id " prevHwnd))
        WinActivate("ahk_id " prevHwnd)

    if ok
        statusText.Text := "Status: prompt sent to Copilot"
    else if (wins["mini"] || wins["full"])
        statusText.Text := "Status: could not send to Copilot - the prompt is on the clipboard (see copilot-debug.log)"
    else
        statusText.Text := "Status: no Copilot window found - the prompt is on the clipboard. Press Ctrl+Shift+Alt+W with Copilot open to save diagnostics"
}

; Saves what Windows exposes about Copilot to copilot-diagnostics.txt (next to the script).
DumpCopilotDiagnostics() {
    out := "Copilot diagnostics  " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n"
    out .= "Windows: " A_OSVersion "   AutoHotkey: " A_AhkVersion "   running as admin: " (A_IsAdmin ? "yes" : "no") "`n`n"

    out .= "== Windows whose title, class or program mentions copilot / m365 / quick view (hidden ones included) ==`n"
    oldHidden := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    n := 0
    for hwnd in WinGetList() {
        try {
            title := WinGetTitle(hwnd)
            exe := WinGetProcessName(hwnd)
            cls := WinGetClass(hwnd)
            WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        } catch {
            continue
        }
        if !RegExMatch(title " " exe " " cls, "i)copilot|m365|microsoft 365|quick\s*view")
            continue
        visible := DllCall("IsWindowVisible", "Ptr", hwnd) ? "visible" : "HIDDEN"
        cloaked := 0
        DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "Int", 13, "Int*", &cloaked, "Int", 4)
        n += 1
        out .= n ". title='" title "'  program=" exe "  class=" cls "  " visible (cloaked ? " CLOAKED" : "")
            . "  pos=" x "," y "  size=" w "x" h "`n"
    }
    DetectHiddenWindows(oldHidden)
    if (n = 0)
        out .= "(none found)`n"

    out .= "`n== Active window when you pressed the hotkey ==`n"
    active := WinExist("A")
    if (active) {
        title := WinGetTitle("ahk_id " active)
        exe := WinGetProcessName("ahk_id " active)
        cls := WinGetClass("ahk_id " active)
        out .= "title='" title "'  program=" exe "  class=" cls "`n"
        if RegExMatch(title " " exe " " cls, "i)copilot|m365|microsoft 365|quick\s*view") {
            out .= "`n== UI Automation tree of that window ==`n"
            try {
                tree := UIA.ElementFromHandle(active).DumpAll()
                lines := StrSplit(tree, "`n", "`r")
                shown := 0
                for ln in lines {
                    if (shown >= 300)
                        break
                    out .= SubStr(ln, 1, 150) "`n"
                    shown += 1
                }
                out .= "(" lines.Length " elements in total; first " shown " shown, long lines cut at 150 characters)`n"
            } catch as err {
                out .= "UIA dump failed: " err.Message "`n"
            }
        } else {
            out .= "(not a Copilot window, so its contents were not dumped. Open the Copilot window, click inside it, then press the hotkey again.)`n"
        }
    }

    path := A_ScriptDir "\copilot-diagnostics.txt"
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ToolTip("Saved " path)
    SetTimer(() => ToolTip(), -4000)
}
PreviewChanged(*) {
    if (!IsObject(hPreviewStatus))
        return
    hPreviewStatus.Text := ((hPreview.Value == lastCopiedPrompt)
        ? "PROMPT · COPIED"
        : "PROMPT EDITED · COPY AGAIN TO UPDATE CLIPBOARD") ReviewSuffix()
}

ClearPreview() {
    if IsObject(hPreview)
        hPreview.Value := ""
    if IsObject(hPreviewStatus)
        hPreviewStatus.Text := ""
}

ClearPromptState() {
    global lastCopiedPrompt, activePrompt, selectedText, pickedBubble
    lastCopiedPrompt := ""
    activePrompt := ""
    selectedText := ""
    pickedBubble := ""
    ClearPreview()
}

OpenHelperJson(*) {
    myGui.Opt("+OwnDialogs")
    if !FileExist(USER_HELPER_PATH) {
        MsgBox("There is no call-helpers.json yet. Put your call-helpers.json in this folder, click Reload, then try again:`n`n" A_ScriptDir, "Open JSON file", "Icon!")
        return
    }
    try {
        Run('notepad.exe "' USER_HELPER_PATH '"')
        statusText.Text := "Status: edit and save the file, then click Reload in the helpers window"
    } catch as err {
        statusText.Text := "Status: could not open call-helpers.json: " err.Message
    }
}

; ==============================================================================
; Helper editor (port of HelperEditorWindow)
; ==============================================================================
WriteTextAtomically(path, text) {
    SplitPath(path, , &dir)
    DirCreate(dir)
    tmp := dir "\.helpers." A_TickCount ".tmp"
    f := FileOpen(tmp, "w", "UTF-8-RAW")
    f.Write(text)
    f.Close()
    try {
        FileMove(tmp, path, true)
    } catch as err {
        try FileDelete(tmp)
        throw err
    }
}

; Reads a plain helper configuration or a backup bundle. Returns
; Map("actions", [...], "contexts", [...], "isBundle", bool) in editor format, or throws.
ParseHelperImport(text) {
    root := Json.Parse(text)
    if (Type(root) != "Map")
        throw Error("The JSON root must be an object.")

    isBundle := false
    if root.Has("format") {
        isBundle := true
        if (String(root["format"]) !== "LiveCaptionCompanionBackup")
            throw Error("This file is not a Live Caption Companion backup.")
        if (!root.Has("schemaVersion") || root["schemaVersion"] != 1)
            throw Error("This backup's schema version is not supported by this editor (supported: 1).")
        if (!root.Has("data") || Type(root["data"]) != "Map")
            throw Error("The backup is missing its data section.")
        data := root["data"]
        for key, val in data {
            if !(key = "helperConfiguration" || key = "preferences" || key = "callHistory")
                throw Error("The backup contains data sections this app does not support. Update the app before importing so those sections are preserved.")
        }
        if (!data.Has("helperConfiguration") || Type(data["helperConfiguration"]) != "Map")
            throw Error("The backup does not include helper configuration.")
        cfg := data["helperConfiguration"]
    } else {
        if (!root.Has("actions") && !root.Has("context"))
            throw Error("The JSON is neither a backup bundle nor a helper configuration.")
        cfg := root
    }

    rawActions := cfg.Has("actions") ? cfg["actions"] : []
    rawContexts := cfg.Has("context") ? cfg["context"] : []
    if (Type(rawActions) != "Array" || Type(rawContexts) != "Array")
        throw Error("The file must contain actions and context arrays.")

    actions := []
    ids := Map()
    ids.CaseSense := false
    for a in rawActions {
        if (Type(a) != "Map" || !HasText(a, "id") || !HasText(a, "label") || !HasText(a, "prompt"))
            throw Error("Every helper needs an ID, button label, and prompt.")
        id := Trim(a["id"])
        if ids.Has(id)
            throw Error("Helper ID '" id "' is duplicated.")
        ids[id] := true
        actions.Push(Map("id", id, "label", a["label"], "prompt", NormalizeNewlines(a["prompt"])))
    }

    contexts := []
    for c in rawContexts {
        if (Type(c) != "Map" || !HasText(c, "name") || !HasText(c, "description") || !HasText(c, "context"))
            throw Error("Every context needs a name, description, and full context text.")
        contexts.Push(Map("name", c["name"], "description", c["description"], "context", NormalizeNewlines(c["context"])))
    }
    return Map("actions", actions, "contexts", contexts, "isBundle", isBundle)
}

OpenHelperEditor(*) {
    global helperEditorGui
    if (IsSet(helperEditorGui) && IsObject(helperEditorGui)) {
        try {
            helperEditorGui.Show()
            return
        }
    }

    ; Saving replaces the file, so warn first if it exists but cannot be read
    if FileExist(USER_HELPER_PATH) {
        try {
            Json.Parse(FileRead(USER_HELPER_PATH, "UTF-8"))
        } catch as err {
            myGui.Opt("+OwnDialogs")
            answer := MsgBox("call-helpers.json could not be read:`n`n" err.Message
                . "`n`nIf you save in the editor, the file will be replaced with what you see there "
                . "(the old file is kept as call-helpers.backup.json).`n`nOpen the editor anyway?",
                "Edit helpers", "YesNo Icon!")
            if (answer != "Yes")
                return
        }
    }

    ; Working copies: nothing touches the file until Save
    st := {tab: "A", loading: false, selA: 0, selC: 0, actions: [], contexts: []}
    for a in helperActions
        st.actions.Push(Map("id", a["id"], "label", a["label"], "prompt", NormalizeNewlines(a["prompt"])))
    for c in helperContexts
        st.contexts.Push(Map("name", c["name"], "description", c["description"], "context", NormalizeNewlines(c["context"])))

    ed := Gui("+Owner" myGui.Hwnd, "Edit Call Helpers and Contexts")
    ed.BackColor := "11151D"
    ed.SetFont("s16 Bold cF1F5FB", "Segoe UI")
    ed.Add("Text", "x16 y10 w620 h32", "Call helper setup")
    ed.SetFont("s9 Norm c9BA8BA", "Segoe UI")
    ed.Add("Text", "x16 y44 w640 h20", "Edit the buttons and reusable context included in every helper prompt.")
    ed.SetFont("s10 Norm cF1F5FB", "Segoe UI")

    btnImport := ed.Add("Button", "x700 y14 w76 h28", "Import")
    btnExport := ed.Add("Button", "x782 y14 w76 h28", "Export")
    btnTabA := ed.Add("Button", "x16 y78 w160 h30", "● Helper buttons")
    btnTabC := ed.Add("Button", "x182 y78 w170 h30", "Reusable context")

    ; --- helper buttons group ---
    capA := ed.Add("Text", "x16 y120 w260 c83AEFF", "HELPER BUTTONS")
    lvA := ed.Add("ListView", "x16 y140 w260 h370 -Hdr -Multi +0x8 Background1B2431 cF1F5FB", ["Helper"])
    btnAddA := ed.Add("Button", "x16 y516 w60 h28", "Add")
    btnRemA := ed.Add("Button", "x82 y516 w76 h28", "Remove")
    btnUpA := ed.Add("Button", "x164 y516 w50 h28", "▲")
    btnDnA := ed.Add("Button", "x220 y516 w50 h28", "▼")
    lblA1 := ed.Add("Text", "x296 y120 w300 c9BA8BA", "BUTTON LABEL")
    edLabel := ed.Add("Edit", "x296 y140 w568 h26 Background1B2431 cF1F5FB")
    lblA2 := ed.Add("Text", "x296 y178 w300 c9BA8BA", "PROMPT TEMPLATE")
    hintA := ed.Add("Text", "x296 y198 w568 h34 c9BA8BA", "Placeholders: {{transcript}}  {{verifiedInfo}}  {{currentCaption}}  {{selectedText}}  {{context}}. Verified info follows {{transcript}} unless you place {{verifiedInfo}} yourself.")
    edPrompt := ed.Add("Edit", "x296 y236 w568 h274 Multi VScroll WantReturn Background1B2431 cF1F5FB")

    ; --- reusable context group ---
    capC := ed.Add("Text", "x16 y120 w260 c83AEFF Hidden", "REUSABLE CONTEXT")
    lvC := ed.Add("ListView", "x16 y140 w260 h370 -Hdr -Multi +0x8 Background1B2431 cF1F5FB Hidden", ["Context"])
    btnAddC := ed.Add("Button", "x16 y516 w60 h28 Hidden", "Add")
    btnRemC := ed.Add("Button", "x82 y516 w76 h28 Hidden", "Remove")
    btnUpC := ed.Add("Button", "x164 y516 w50 h28 Hidden", "▲")
    btnDnC := ed.Add("Button", "x220 y516 w50 h28 Hidden", "▼")
    lblC1 := ed.Add("Text", "x296 y120 w300 c9BA8BA Hidden", "CONTEXT NAME")
    edName := ed.Add("Edit", "x296 y140 w568 h26 Background1B2431 cF1F5FB Hidden")
    lblC2 := ed.Add("Text", "x296 y178 w300 c9BA8BA Hidden", "DESCRIPTION")
    edDesc := ed.Add("Edit", "x296 y198 w568 h26 Background1B2431 cF1F5FB Hidden")
    lblC3 := ed.Add("Text", "x296 y236 w300 c9BA8BA Hidden", "FULL CONTEXT / GUIDE")
    edCtx := ed.Add("Edit", "x296 y256 w568 h254 Multi VScroll WantReturn Background1B2431 cF1F5FB Hidden")

    noteText := ed.Add("Text", "x16 y550 w840 h20 c9BA8BA", "Buttons appear in the Helpers panel in the order listed here.")
    valText := ed.Add("Text", "x16 y580 w640 h24 cF0A5A5", "")
    btnCancel := ed.Add("Button", "x676 y572 w84 h32", "Cancel")
    btnSave := ed.Add("Button", "x766 y572 w100 h32", "Save changes")

    DisplayA(a) {
        return (Trim(a["label"]) = "") ? "(no label)" : a["label"]
    }

    DisplayC(c) {
        return (Trim(c["name"]) = "") ? "(no name)" : c["name"]
    }

    LoadFields(kind, idx) {
        st.loading := true
        if (kind = "A") {
            has := (idx >= 1 && idx <= st.actions.Length)
            st.selA := has ? idx : 0
            edLabel.Value := has ? st.actions[idx]["label"] : ""
            edPrompt.Value := has ? st.actions[idx]["prompt"] : ""
            edLabel.Enabled := has
            edPrompt.Enabled := has
        } else {
            has := (idx >= 1 && idx <= st.contexts.Length)
            st.selC := has ? idx : 0
            edName.Value := has ? st.contexts[idx]["name"] : ""
            edDesc.Value := has ? st.contexts[idx]["description"] : ""
            edCtx.Value := has ? st.contexts[idx]["context"] : ""
            edName.Enabled := has
            edDesc.Enabled := has
            edCtx.Enabled := has
        }
        st.loading := false
    }

    RefreshList(kind, selectIdx := 0) {
        st.loading := true
        lv := (kind = "A") ? lvA : lvC
        items := (kind = "A") ? st.actions : st.contexts
        lv.Delete()
        for item in items
            lv.Add(, (kind = "A") ? DisplayA(item) : DisplayC(item))
        lv.ModifyCol(1, 236)
        st.loading := false
        if (selectIdx >= 1 && selectIdx <= items.Length)
            lv.Modify(selectIdx, "Select Focus Vis")
        LoadFields(kind, selectIdx)
    }

    OnPick(kind, item, selected) {
        if (st.loading || !selected)
            return
        LoadFields(kind, item)
    }

    OnFieldChange(kind, *) {
        if st.loading
            return
        if (kind = "A") {
            i := st.selA
            if (i < 1 || i > st.actions.Length)
                return
            st.actions[i]["label"] := edLabel.Value
            st.actions[i]["prompt"] := edPrompt.Value
            lvA.Modify(i, , DisplayA(st.actions[i]))
        } else {
            i := st.selC
            if (i < 1 || i > st.contexts.Length)
                return
            st.contexts[i]["name"] := edName.Value
            st.contexts[i]["description"] := edDesc.Value
            st.contexts[i]["context"] := edCtx.Value
            lvC.Modify(i, , DisplayC(st.contexts[i]))
        }
        valText.Text := ""
    }

    AddItem(kind, *) {
        if (kind = "A") {
            st.actions.Push(Map("id", "helper-" NewGuid(), "label", "New helper",
                "prompt", "Write the instructions for this helper. Use {{transcript}} to include the call transcript and {{context}} to place shared guidance here. Shared contexts are added automatically if the token is omitted."))
            RefreshList("A", st.actions.Length)
        } else {
            st.contexts.Push(Map("name", "New context", "description", "Describe when this guidance applies.",
                "context", "Paste or write the full guidance here."))
            RefreshList("C", st.contexts.Length)
        }
        valText.Text := ""
    }

    RemoveItem(kind, *) {
        items := (kind = "A") ? st.actions : st.contexts
        idx := (kind = "A") ? st.selA : st.selC
        if (idx < 1 || idx > items.Length)
            return
        items.RemoveAt(idx)
        RefreshList(kind, Min(idx, items.Length))
        valText.Text := ""
    }

    MoveItem(kind, dir, *) {
        items := (kind = "A") ? st.actions : st.contexts
        idx := (kind = "A") ? st.selA : st.selC
        other := idx + dir
        if (idx < 1 || other < 1 || other > items.Length)
            return
        tmp := items[idx]
        items[idx] := items[other]
        items[other] := tmp
        RefreshList(kind, other)
    }

    SwitchTab(kind, *) {
        st.tab := kind
        isA := (kind = "A")
        for c in [capA, lvA, btnAddA, btnRemA, btnUpA, btnDnA, lblA1, edLabel, lblA2, hintA, edPrompt]
            c.Visible := isA
        for c in [capC, lvC, btnAddC, btnRemC, btnUpC, btnDnC, lblC1, edName, lblC2, edDesc, lblC3, edCtx]
            c.Visible := !isA
        btnTabA.Text := isA ? "● Helper buttons" : "Helper buttons"
        btnTabC.Text := isA ? "Reusable context" : "● Reusable context"
        noteText.Text := isA ? "Buttons appear in the Helpers panel in the order listed here."
                             : "Every context is added to every helper prompt."
    }

    ; Returns "" when everything is valid, otherwise {msg, kind, idx}
    Validate() {
        ids := Map()
        ids.CaseSense := false
        for i, a in st.actions {
            id := Trim(a["id"])
            if (id = "" || Trim(a["label"]) = "" || Trim(a["prompt"]) = "")
                return {msg: "Each helper needs a button label and a prompt.", kind: "A", idx: i}
            if ids.Has(id)
                return {msg: "Helper ID '" id "' is duplicated.", kind: "A", idx: i}
            ids[id] := true
        }
        for i, c in st.contexts {
            if (Trim(c["name"]) = "" || Trim(c["description"]) = "" || Trim(c["context"]) = "")
                return {msg: "Each context needs a name, description, and full context text.", kind: "C", idx: i}
        }
        return ""
    }

    ShowProblem(p) {
        SwitchTab(p.kind)
        lv := (p.kind = "A") ? lvA : lvC
        lv.Modify(p.idx, "Select Focus Vis")
        LoadFields(p.kind, p.idx)
        valText.Text := p.msg
    }

    BuildConfig() {
        acts := []
        for a in st.actions
            acts.Push(Map("id", Trim(a["id"]), "label", a["label"], "prompt", StrReplace(a["prompt"], "`r`n", "`n")))
        ctxs := []
        for c in st.contexts
            ctxs.Push(Map("name", c["name"], "description", c["description"], "context", StrReplace(c["context"], "`r`n", "`n")))
        return Map("actions", acts, "context", ctxs)
    }

    CloseEditor(*) {
        global helperEditorGui
        myGui.Opt("-Disabled")
        helperEditorGui := ""
        ed.Destroy()
    }

    SaveChanges(*) {
        problem := Validate()
        if IsObject(problem) {
            ShowProblem(problem)
            return
        }
        try {
            if FileExist(USER_HELPER_PATH)
                FileCopy(USER_HELPER_PATH, A_ScriptDir "\call-helpers.backup.json", true)
            WriteTextAtomically(USER_HELPER_PATH, Json.Stringify(BuildConfig()))
        } catch as err {
            valText.Text := "Could not save call-helpers.json: " err.Message
            return
        }
        CloseEditor()
        LoadHelperActions()
        statusText.Text := "Status: call helpers and contexts saved"
    }

    ImportFile(*) {
        ed.Opt("+OwnDialogs")
        path := FileSelect(1, A_ScriptDir, "Import helper backup or configuration", "JSON files (*.json)")
        if (path = "")
            return
        try {
            if (FileGetSize(path) > 60 * 1024 * 1024)
                throw Error("The selected file is larger than the 60 MB import limit.")
            imported := ParseHelperImport(FileRead(path, "UTF-8"))
            summary := "This will replace the current editor contents with:`n`n"
                . "• " imported["actions"].Length " helper(s)`n"
                . "• " imported["contexts"].Length " context(s)`n`n"
            if imported["isBundle"]
                summary .= "(Call history and font size in the backup are not imported by this editor.)`n`n"
            summary .= "The import is applied to this editor only. Choose Save changes to apply it to the app."
            if (MsgBox(summary, "Review import", "OKCancel Icon?") != "OK")
                return
            st.actions := imported["actions"]
            st.contexts := imported["contexts"]
            RefreshList("A", st.actions.Length ? 1 : 0)
            RefreshList("C", st.contexts.Length ? 1 : 0)
            valText.Text := "Imported into the editor. Save changes to apply."
        } catch as err {
            MsgBox("Import failed. The current editor contents were left unchanged.`n`n" err.Message,
                "Could not import file", "Icon!")
        }
    }

    ExportFile(*) {
        ed.Opt("+OwnDialogs")
        problem := Validate()
        if IsObject(problem) {
            MsgBox("Fix the configuration before exporting.`n`n" problem.msg, "Could not export", "Icon!")
            ShowProblem(problem)
            return
        }
        path := FileSelect("S16", A_ScriptDir "\call-helpers-export.json", "Export call helpers", "JSON files (*.json)")
        if (path = "")
            return
        if !RegExMatch(path, "i)\.json$")
            path .= ".json"
        try {
            WriteTextAtomically(path, Json.Stringify(BuildConfig()))
            valText.Text := "Exported"
        } catch as err {
            MsgBox("Export failed.`n`n" err.Message, "Could not export", "Icon!")
        }
    }

    ; --- wiring ---
    btnTabA.OnEvent("Click", SwitchTab.Bind("A"))
    btnTabC.OnEvent("Click", SwitchTab.Bind("C"))
    lvA.OnEvent("ItemSelect", (lv, item, selected) => OnPick("A", item, selected))
    lvC.OnEvent("ItemSelect", (lv, item, selected) => OnPick("C", item, selected))
    edLabel.OnEvent("Change", OnFieldChange.Bind("A"))
    edPrompt.OnEvent("Change", OnFieldChange.Bind("A"))
    edName.OnEvent("Change", OnFieldChange.Bind("C"))
    edDesc.OnEvent("Change", OnFieldChange.Bind("C"))
    edCtx.OnEvent("Change", OnFieldChange.Bind("C"))
    btnAddA.OnEvent("Click", AddItem.Bind("A"))
    btnAddC.OnEvent("Click", AddItem.Bind("C"))
    btnRemA.OnEvent("Click", RemoveItem.Bind("A"))
    btnRemC.OnEvent("Click", RemoveItem.Bind("C"))
    btnUpA.OnEvent("Click", MoveItem.Bind("A", -1))
    btnDnA.OnEvent("Click", MoveItem.Bind("A", 1))
    btnUpC.OnEvent("Click", MoveItem.Bind("C", -1))
    btnDnC.OnEvent("Click", MoveItem.Bind("C", 1))
    btnImport.OnEvent("Click", ImportFile)
    btnExport.OnEvent("Click", ExportFile)
    btnSave.OnEvent("Click", SaveChanges)
    btnCancel.OnEvent("Click", CloseEditor)
    ed.OnEvent("Close", CloseEditor)
    ed.OnEvent("Escape", CloseEditor)

    helperEditorGui := ed
    myGui.Opt("+Disabled")                 ; modal, like ShowDialog in the C# app
    ed.Show("w882 h620")
    RefreshList("A", st.actions.Length ? 1 : 0)
    RefreshList("C", st.contexts.Length ? 1 : 0)
}

; Remember the most recently highlighted text in the visible Chat/Transcript box
; (the Edit control keeps its selection when it loses focus because of +0x100).
TrackSelection() {
    global selectedText
    ctrl := chatView ? chatBox : transcript
    sel := Buffer(4, 0)
    sel2 := Buffer(4, 0)
    SendMessage(0x00B0, sel, sel2, ctrl.Hwnd)          ; EM_GETSEL
    s := NumGet(sel, 0, "UInt")
    e := NumGet(sel2, 0, "UInt")
    if (e <= s)
        return
    text := SubStr(ctrl.Value, s + 1, e - s)
    text := Trim(StrReplace(text, "▌ ", ""), " `t`r`n")
    if (text != "")
        selectedText := text
}

; ==============================================================================
; Rendering / actions
; ==============================================================================
TranscriptText() {
    if IsObject(reviewCall)
        return JoinWith(reviewCall["transcriptLines"], "`r`n")
    s := ""
    for line in sessionLines {
        if (line.Text = "")
            continue
        s .= (s = "" ? "" : "`r`n") . line.Text
    }
    return s
}

RenderTranscript() {
    SetEditText(transcript, TranscriptText())
    SetEditText(chatBox, ChatText())
}

; Updates an Edit control without wiping the user's highlight or scroll position.
; Does nothing if the text did not change. Follows new text whenever the user is
; at the bottom; stays put when they have scrolled up.
SetEditText(ctrl, newText) {
    if (ctrl.Value == newText)
        return
    hwnd := ctrl.Hwnd

    selStart := Buffer(4, 0)
    selEnd := Buffer(4, 0)
    SendMessage(0x00B0, selStart, selEnd, hwnd)          ; EM_GETSEL
    s := NumGet(selStart, 0, "UInt")
    e := NumGet(selEnd, 0, "UInt")
    hasSelection := (e > s)

    firstLine := SendMessage(0x00CE, 0, 0, hwnd)         ; EM_GETFIRSTVISIBLELINE
    atBottom := IsScrolledToBottom(hwnd)

    ctrl.Value := newText
    if (hasSelection)
        SendMessage(0x00B1, s, e, hwnd)                  ; EM_SETSEL: keep the highlight

    if (atBottom)
        SendMessage(0x0115, 7, 0, hwnd)                  ; at the bottom: follow new text
    else
        RestoreFirstLine(hwnd, firstLine)                ; scrolled up: stay where you are

    ; One full, immediate repaint: INVALIDATE | ERASE | ALLCHILDREN | UPDATENOW
    DllCall("RedrawWindow", "Ptr", hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
}

RestoreFirstLine(hwnd, wanted) {
    nowFirst := SendMessage(0x00CE, 0, 0, hwnd)          ; EM_GETFIRSTVISIBLELINE
    delta := wanted - nowFirst
    if (delta != 0)
        SendMessage(0x00B6, 0, delta, hwnd)              ; EM_LINESCROLL (relative)
}

IsScrolledToBottom(hwnd) {
    si := Buffer(28, 0)
    NumPut("UInt", 28, si, 0)                            ; cbSize
    NumPut("UInt", 0x17, si, 4)                          ; SIF_ALL
    if !DllCall("GetScrollInfo", "Ptr", hwnd, "Int", 1, "Ptr", si)   ; SB_VERT
        return true
    nMax := NumGet(si, 12, "Int")
    nPage := NumGet(si, 16, "UInt")
    nPos := NumGet(si, 20, "Int")
    if (nPage = 0)
        return true
    return (nPos + nPage >= nMax - 1)                    ; 1 line of tolerance
}

ScrollToEnd(ctrl) {
    SendMessage(0x0115, 7, 0, ctrl.Hwnd)   ; WM_VSCROLL / SB_BOTTOM
}

; One entry per bubble: that bubble's lines joined with spaces (same as the C# app)
BubbleTexts() {
    out := []
    for bubble in bubbles {
        text := BubbleText(bubble)
        if (text != "")
            out.Push(text)
    }
    return out
}

ChatText() {
    out := ""
    texts := IsObject(reviewCall) ? reviewCall["chatBubbles"] : BubbleTexts()
    hasMic := micEnabled && !IsObject(reviewCall) && (micCommitted.Length > 0 || micPartial != "")

    if !hasMic {
        for text in texts
            out .= (out = "" ? "" : "`r`n`r`n") "▌ " text
        return out
    }

    ; Build a combined timeline of customer + agent + shadow entries
    ; Shadow is placed at its interleaved position (micPartialAfterBubble)
    shadowPos := micPartial != "" ? micPartialAfterBubble : -1
    agentIdx := 1

    ; Agent/shadow entries before any customer bubble
    while (agentIdx <= micCommitted.Length && micCommitted[agentIdx].afterBubble < 1) {
        out .= (out = "" ? "" : "`r`n`r`n") MIC_INDENT "▐ " micCommitted[agentIdx].text
        agentIdx += 1
    }
    if (shadowPos = 0)
        out .= (out = "" ? "" : "`r`n`r`n") MIC_INDENT "░ " micPartial

    for i, text in texts {
        out .= (out = "" ? "" : "`r`n`r`n") "▌ " text
        ; Agent bubbles after this customer bubble
        while (agentIdx <= micCommitted.Length && micCommitted[agentIdx].afterBubble <= i) {
            out .= "`r`n`r`n" MIC_INDENT "▐ " micCommitted[agentIdx].text
            agentIdx += 1
        }
        if (shadowPos = i)
            out .= "`r`n`r`n" MIC_INDENT "░ " micPartial
    }
    ; Remaining agent bubbles after all customer bubbles
    while (agentIdx <= micCommitted.Length) {
        out .= (out = "" ? "" : "`r`n`r`n") MIC_INDENT "▐ " micCommitted[agentIdx].text
        agentIdx += 1
    }
    if (shadowPos > texts.Length)
        out .= (out = "" ? "" : "`r`n`r`n") MIC_INDENT "░ " micPartial

    return out
}

SetView(chat) {
    global chatView
    chatView := chat
    chatBox.Visible := chat
    transcript.Visible := !chat
    btnChat.Text := chat ? "● Chat" : "Chat"
    btnTrans.Text := chat ? "Transcript" : "● Transcript"
    ScrollToEnd(chat ? chatBox : transcript)
}

CopyTranscript(*) {
    text := Trim(TranscriptText(), " `t`r`n")
    if (text = "") {
        statusText.Text := "Status: there is no transcript to copy yet"
        return
    }
    A_Clipboard := text
    statusText.Text := "Status: transcript copied to clipboard"
}

RefreshDebug() {
    quiet := lastChatTick = 0 ? "-" : Round((A_TickCount - lastChatTick) / 1000, 1) . "s"
    debugText.Text := "changes " changeCount " · lines " sessionLines.Length
        . " · quiet " quiet " · bubbles " bubbles.Length
    if IsObject(reviewCall)
        UpdateReviewBanner()
}

GuiResize(thisGui, minMax, width, height) {
    if (minMax = -1)
        return
    bannerH := IsObject(reviewCall) ? 34 : 0     ; room for the "reviewing" banner
    notesH := 100                                ; label + box + gaps under the view
    current.Move(, , width - 20)
    panelSpace := helpersVisible ? HELPER_H : 0
    newH := Max(60, height - viewTop - 80 - panelSpace - notesH - bannerH)
    viewY := viewTop + bannerH
    if (bannerH) {
        reviewBanner.Move(viewLeft, viewTop, width - 20 - 146, 28)
        btnLive.Move(viewLeft + width - 20 - 140, viewTop, 140, 28)
    }
    transcript.Move(viewLeft, viewY, width - 20, newH)
    chatBox.Move(viewLeft, viewY, width - 20, newH)
    notesTop := viewY + newH + 6
    notesLabel.Move(viewLeft, notesTop, width - 20)
    notesBox.Move(viewLeft, notesTop + 22, width - 20, notesH - 34)
    debugText.Move(, height - 70, width - 20)
    btnNew.Move(, height - 40)
    btnHist.Move(, height - 40)
    btnHelp.Move(, height - 40)
    btnCopy.Move(, height - 40)
    if (helpersVisible)
        LayoutHelperPanel(width, height)
}

RelayoutMain() {
    myGui.GetClientPos(, , &w, &h)
    GuiResize(myGui, 0, w, h)
}

; ==============================================================================
; Review mode: look at a saved call in the main view while the live call keeps
; recording in the background
; ==============================================================================
EnterReview(session) {
    global reviewCall
    if (session == currentCall) {          ; that is the live call: just go back to it
        ExitReview()
        return
    }
    SaveNotes()                            ; keep what is in the box with the call it belongs to
    reviewCall := session
    ClearPromptState()                     ; clears the preview and the remembered highlight
    notesBox.Value := reviewCall.Get("agentNotes", "")
    notesLabel.Text := "VERIFIED INFO / CALL UPDATES  -  notes of the REVIEWED call (the live call's notes are kept)"
    myGui.Title := "Live Caption Companion  -  REVIEWING A PAST CALL"
    reviewBanner.Visible := true
    btnLive.Visible := true
    UpdateReviewBanner()
    RelayoutMain()
    RenderTranscript()
    SendMessage(0x0115, 6, 0, chatBox.Hwnd)      ; SB_TOP: start reading from the beginning
    SendMessage(0x0115, 6, 0, transcript.Hwnd)
}

ExitReview(*) {
    global reviewCall
    if !IsObject(reviewCall)
        return
    SaveNotes()                            ; saves edits made to the reviewed call's notes
    reviewCall := ""
    ClearPromptState()
    notesBox.Value := IsObject(currentCall) ? currentCall.Get("agentNotes", "") : ""
    notesLabel.Text := NOTES_LABEL
    myGui.Title := "Live Caption Companion"
    reviewBanner.Visible := false
    btnLive.Visible := false
    RelayoutMain()
    RenderTranscript()
    ScrollToEnd(chatBox)
    ScrollToEnd(transcript)
    statusText.Text := "Status: back to the live call"
}

; From the live view: the most recent earlier call. While reviewing: one call further back.
ReviewPrevious(*) {
    sessions := history["sessions"]
    i := sessions.Length
    if IsObject(reviewCall) {
        Loop sessions.Length {
            if (sessions[A_Index] == reviewCall) {
                i := A_Index - 1
                break
            }
        }
    }
    while (i >= 1) {
        s := sessions[i]
        if (!(s == currentCall) && (s["transcriptLines"].Length > 0 || s["preparedPrompts"].Length > 0 || RemovedCount(s) > 0)) {
            EnterReview(s)
            return
        }
        i -= 1
    }
    statusText.Text := "Status: there is no earlier call to show"
}

UpdateReviewBanner() {
    if !IsObject(reviewCall)
        return
    reviewBanner.Text := "  REVIEWING  " SessionTitle(reviewCall) "  ·  live call: " sessionLines.Length " lines"
}

; Appended to the prompt status so you can see which call a prompt was built from
ReviewSuffix() {
    if !IsObject(reviewCall)
        return ""
    return "  ·  CALL FROM " IsoToLocal(reviewCall["startedAtUtc"], "h:mm tt")
}

^+!w::DumpCopilotDiagnostics()

; ==============================================================================
; Experimental: agent mic captions via whisper-stream
; ==============================================================================
MicCleanLine(s) {
    s := RTrim(s, "`r")
    if (p := InStr(s, "`r", , -1))
        s := SubStr(s, p + 1)
    s := RegExReplace(s, "\x1B\[[0-9;]*[A-Za-z]")
    s := RegExReplace(s, "\[[^\]]*\]|\([^)]*\)|\*[^*]*\*")
    return Trim(RegExReplace(s, "\s+", " "))
}

StartMicEngine() {
    global micPid, micReady, micDead, micReadPos, micPartial
    StopMicEngine()
    DirCreate(micDataDir)
    try FileDelete(micOutFile)
    try FileDelete(micLogFile)
    micReadPos := 0
    micPartial := ""
    micReady := false
    micDead := false
    threads := Min(8, Integer(EnvGet("NUMBER_OF_PROCESSORS") || 4))
    stepMs := Integer(IniRead(MIC_INI, "Settings", "StepMs", 2000))
    lengthMs := Integer(IniRead(MIC_INI, "Settings", "LengthMs", 10000))
    args := Format('-m "{}" -t {} --step {} --length {} -l en', micModelPath, threads, stepMs, lengthMs)
    if (micCurrentDevice > 0)
        args .= " -c " micDeviceIds[micCurrentDevice]
    Run(A_ComSpec ' /c ""' micStreamExe '" ' args ' > "' micOutFile '" 2> "' micLogFile '""', micWhisperDir, "Hide", &micPid)
}

StopMicEngine() {
    global micPid
    if (micPid && ProcessExist(micPid))
        RunWait(A_ComSpec ' /c taskkill /F /T /PID ' micPid ' >nul 2>&1', , "Hide")
    micPid := 0
}

PollMic() {
    global micReadPos, micCommitted, micPartial, micReady, micPartialAfterBubble
    if !micEnabled
        return
    if !FileExist(micOutFile)
        return
    try {
        f := FileOpen(micOutFile, "r", "UTF-8-RAW")
        f.Pos := micReadPos
        chunk := f.Read()
        f.Close()
    } catch
        return
    if (chunk = "")
        return
    if InStr(chunk, "Start speaking")
        micReady := true
    prevPartial := micPartial
    if (lastNL := InStr(chunk, "`n", , -1)) {
        done := SubStr(chunk, 1, lastNL)
        micReadPos += StrPut(done, "UTF-8") - 1
        ; Use the shadow's position if we had a partial, otherwise current bubble count
        pos := prevPartial != "" ? micPartialAfterBubble : BubbleTexts().Length
        for line in StrSplit(done, "`n") {
            t := MicCleanLine(line)
            if (t != "") {
                ; Merge consecutive agent lines into one bubble (same position = same turn)
                if (micCommitted.Length > 0 && micCommitted[micCommitted.Length].afterBubble = pos)
                    micCommitted[micCommitted.Length].text .= " " t
                else
                    micCommitted.Push({text: t, afterBubble: pos})
            }
        }
        micPartial := MicCleanLine(SubStr(chunk, lastNL + 1))
    } else
        micPartial := MicCleanLine(chunk)
    ; Track shadow position: set when partial text first appears
    if (prevPartial = "" && micPartial != "")
        micPartialAfterBubble := BubbleTexts().Length
    RenderTranscript()
}

SetMicDevice(index, *) {
    global micCurrentDevice
    micDevMenu.Uncheck(MicDeviceLabel(micCurrentDevice))
    micCurrentDevice := index
    micDevMenu.Check(MicDeviceLabel(micCurrentDevice))
    IniWrite(index = 0 ? "" : MicDeviceLabel(index), MIC_INI, "Companion", "Mic")
    if micEnabled
        StartMicEngine()
}

ToggleMicCaptions(*) {
    global micEnabled
    micEnabled := !micEnabled
    if micEnabled {
        A_TrayMenu.Check("Experimental: Mic captions")
        StartMicEngine()
        SetTimer(PollMic, 200)
    } else {
        A_TrayMenu.Uncheck("Experimental: Mic captions")
        StopMicEngine()
        SetTimer(PollMic, 0)
        micPartial := ""
    }
    IniWrite(micEnabled ? 1 : 0, MIC_INI, "Companion", "MicCaptions")
    RenderTranscript()
}

; ==============================================================================
; Bubble deletion
;   - Click inside a bubble in the Chat view, then press "Delete bubble" (or the
;     Delete key) and confirm.
;   - The bubble disappears from the Chat, the Transcript and every prompt built
;     afterwards. Works on the live call and on a call opened with "Prev call".
;   - A copy is kept inside that call's record in call-history.json under
;     "removedBubbles" (never used for prompts) so it can be brought back with
;     "Undo…" or Ctrl+Z, or erased for good from the same window.
; ==============================================================================

; Text of one live bubble, built the same way the chat view shows it
BubbleText(bubble) {
    text := ""
    for line in bubble
        text .= (A_Index = 1 ? "" : " ") line.Text
    return Trim(text)
}

; Non-empty live bubbles, in the order the Chat view shows them
VisibleBubbles() {
    out := []
    for bubble in bubbles {
        if (BubbleText(bubble) != "")
            out.Push(bubble)
    }
    return out
}

; Every line of every live bubble, in order (this is what sessionLines always holds)
FlattenBubbles() {
    out := []
    for bubble in bubbles {
        for line in bubble
            out.Push(line)
    }
    return out
}

LiveBubbleLines(bubble) {
    out := []
    for line in bubble {
        if (Trim(line.Text) != "")
            out.Push(line.Text)
    }
    return out
}

; The call on screen: the reviewed one, or the live one
ViewedCall() {
    return IsObject(reviewCall) ? reviewCall : currentCall
}

RemovedCount(s) {
    return (s.Has("removedBubbles") && Type(s["removedBubbles"]) = "Array") ? s["removedBubbles"].Length : 0
}

NormalizeSpaces(text) {
    return Trim(RegExReplace(text, "\s+", " "))
}

; Remember which bubble the agent clicked in (WM_LBUTTONUP on the Chat box)
ChatLButtonUp(wParam, lParam, msg, hwnd) {
    if (hwnd != chatBox.Hwnd || !chatView)
        return
    sel := Buffer(4, 0)
    sel2 := Buffer(4, 0)
    SendMessage(0x00B0, sel, sel2, chatBox.Hwnd)         ; EM_GETSEL
    PickBubbleAt(NumGet(sel, 0, "UInt"))
}

PickBubbleAt(pos) {
    global pickedBubble
    hasMic := micEnabled && !IsObject(reviewCall) && (micCommitted.Length > 0 || micPartial != "")

    if !hasMic {
        ; Original fast path: only customer bubbles on screen
        texts := IsObject(reviewCall) ? reviewCall["chatBubbles"] : BubbleTexts()
        start := 0
        found := 0
        Loop texts.Length {
            if (pos < start)
                break
            found := A_Index
            start += StrLen("▌ " . texts[A_Index]) + 4   ; "▌ " + text + blank line
        }
        if (found = 0) {
            pickedBubble := ""
            return
        }
        if IsObject(reviewCall)
            pickedBubble := {type: "customer", session: reviewCall, index: found, bubble: ""}
        else
            pickedBubble := {type: "customer", session: currentCall, index: found, bubble: VisibleBubbles()[found]}
        return
    }

    ; Walk the interleaved chat text to identify what was clicked
    segments := StrSplit(ChatText(), "`r`n`r`n")
    offset := 0
    customerCount := 0
    agentCount := 0
    pickedBubble := ""
    for seg in segments {
        segEnd := offset + StrLen(seg)
        if (pos >= offset && pos < segEnd) {
            trimmed := LTrim(seg)
            if (SubStr(trimmed, 1, 2) = "▌ ") {
                pickedBubble := {type: "customer", session: currentCall, index: customerCount + 1, bubble: VisibleBubbles()[customerCount + 1]}
            } else if (SubStr(trimmed, 1, 2) = "▐ ") {
                pickedBubble := {type: "agent", micIndex: agentCount + 1}
            }
            return
        }
        trimmed := LTrim(seg)
        if (SubStr(trimmed, 1, 2) = "▌ ")
            customerCount += 1
        else if (SubStr(trimmed, 1, 2) = "▐ ")
            agentCount += 1
        offset := segEnd + 4
    }
}

; Which transcript lines belong to bubble number bubbleIdx of a saved call.
; Returns [firstLine, lineCount] (1-based) or 0 if the saved text does not line up,
; in which case nothing is touched.
FindBubbleLineSpan(session, bubbleIdx) {
    tl := session["transcriptLines"]
    cb := session["chatBubbles"]
    p := 1
    Loop cb.Length {
        target := NormalizeSpaces(cb[A_Index])
        acc := ""
        cnt := 0
        matched := false
        while (p + cnt <= tl.Length) {
            acc .= (cnt = 0 ? "" : " ") . tl[p + cnt]
            cnt += 1
            cmp := NormalizeSpaces(acc)
            if (cmp == target) {
                matched := true
                break
            }
            if (StrLen(cmp) > StrLen(target))
                break
        }
        if (!matched)
            return 0
        if (A_Index = bubbleIdx)
            return [p, cnt]
        p += cnt
    }
    return 0
}

NewRemovedRecord(text, lines, chatIdx, lineIdx) {
    r := Map()
    r.CaseSense := false
    r["id"] := NewGuid()
    r["deletedAtUtc"] := NowIso()
    r["text"] := text
    r["lines"] := lines
    r["chatIndex"] := chatIdx
    r["lineIndex"] := lineIdx
    return r
}

AddRemovedRecord(session, rec) {
    if (!session.Has("removedBubbles") || Type(session["removedBubbles"]) != "Array")
        session["removedBubbles"] := []
    session["removedBubbles"].Push(rec)
}

RemoveRemovedRecord(session, rec) {
    list := session["removedBubbles"]
    Loop list.Length {
        if (list[A_Index] == rec) {
            list.RemoveAt(A_Index)
            return
        }
    }
}

DeleteSelectedBubble() {
    global pickedBubble, micCommitted, micUndoStack
    p := pickedBubble
    myGui.Opt("+OwnDialogs")

    ; Agent (mic) bubble deletion
    if (IsObject(p) && p.HasProp("type") && p.type = "agent") {
        idx := p.micIndex
        if (idx < 1 || idx > micCommitted.Length) {
            statusText.Text := "Status: that agent bubble is no longer there"
            return
        }
        text := micCommitted[idx].text
        preview := StrLen(text) > 400 ? SubStr(text, 1, 400) . "…" : text
        if (MsgBox("Delete this agent bubble?`n`n" preview, "Delete bubble", "YesNo Icon! Default2") != "Yes")
            return
        micUndoStack.Push(micCommitted[idx])
        micCommitted.RemoveAt(idx)
        pickedBubble := ""
        RenderTranscript()
        statusText.Text := "Status: agent bubble deleted (Ctrl+Z brings it back)"
        return
    }

    viewed := ViewedCall()
    if (!IsObject(p) || !IsObject(viewed) || !(p.session == viewed)) {
        statusText.Text := "Status: right-click the bubble you want to delete first (Chat view)"
        return
    }

    live := !IsObject(reviewCall)
    lineTexts := []
    if (live) {
        if (!BubbleIsLive(p.bubble)) {
            pickedBubble := ""
            statusText.Text := "Status: that bubble is no longer there; click a bubble again"
            return
        }
        text := BubbleText(p.bubble)
        lineTexts := LiveBubbleLines(p.bubble)
    } else {
        cb := reviewCall["chatBubbles"]
        span := FindBubbleLineSpan(reviewCall, p.index)
        if (!IsObject(span) || p.index > cb.Length) {
            MsgBox("This saved call's bubbles do not line up with its transcript lines, so a bubble cannot be removed safely. Nothing was changed.", "Delete bubble", "Icon!")
            return
        }
        text := cb[p.index]
        Loop span[2]
            lineTexts.Push(reviewCall["transcriptLines"][span[1] + A_Index - 1])
    }

    preview := StrLen(text) > 400 ? SubStr(text, 1, 400) . "…" : text
    msg := "Delete this bubble" . (live ? "" : " from the reviewed call") . "?`n`n" . preview
        . "`n`nIt is removed from the Chat and Transcript and will not be used in any prompt. "
        . "You can bring it back with Undo… (or Ctrl+Z)."
    if (MsgBox(msg, "Delete bubble", "YesNo Icon! Default2") != "Yes")
        return

    if (live) {
        if (!IsObject(RemoveLiveBubble(p.bubble))) {
            statusText.Text := "Status: that bubble is no longer there; nothing was deleted"
            return
        }
    } else {
        ; the saved text cannot change while the dialog is open, but recheck the span anyway
        span := FindBubbleLineSpan(reviewCall, p.index)
        if (!IsObject(span)) {
            statusText.Text := "Status: the saved call no longer lines up; nothing was deleted"
            return
        }
        Loop span[2]
            reviewCall["transcriptLines"].RemoveAt(span[1])
        reviewCall["chatBubbles"].RemoveAt(p.index)
        AddRemovedRecord(reviewCall, NewRemovedRecord(text, lineTexts, p.index - 1, span[1] - 1))
        SaveHistory()
    }

    ClearPromptState()                  ; forget the highlight and any prompt preview that still holds the old text
    RenderTranscript()
    RefreshDebug()
    statusText.Text := "Status: bubble deleted (Ctrl+Z or Undo… brings it back)"
}

BubbleIsLive(bubble) {
    if !IsObject(bubble)
        return false
    for b in bubbles {
        if (b == bubble)
            return true
    }
    return false
}

; Takes a bubble out of the live call. Returns the removed-record, or "" if the bubble is gone.
RemoveLiveBubble(bubble) {
    global bubbles, sessionLines, activeBubble, baseline
    Critical "On"                       ; the 200 ms caption timer must not run halfway through
    visIdx := 0
    lineIdx := 0
    found := false
    for b in bubbles {
        if (b == bubble) {
            found := true
            break
        }
        if (BubbleText(b) != "") {
            visIdx += 1
            for line in b {
                if (Trim(line.Text) != "")
                    lineIdx += 1
            }
        }
    }
    if (!found) {
        Critical "Off"
        return ""
    }

    rec := NewRemovedRecord(BubbleText(bubble), LiveBubbleLines(bubble), visIdx, lineIdx)

    ; If the same words are still on the Live Captions window, treat them like the
    ; text that was there before the call: only words that come after them count.
    for line in bubble
        baseline[line] := true
    if (IsObject(activeBubble) && activeBubble == bubble)
        activeBubble := ""

    Loop bubbles.Length {
        if (bubbles[A_Index] == bubble) {
            bubbles.RemoveAt(A_Index)
            break
        }
    }
    sessionLines := FlattenBubbles()
    AddRemovedRecord(currentCall, rec)
    PersistCurrentCall()
    Critical "Off"
    return rec
}

; Puts a deleted bubble back. Returns true on success.
RestoreRemoved(session, rec) {
    global bubbles, sessionLines
    text := rec.Get("text", "")
    lines := []
    if (rec.Has("lines") && Type(rec["lines"]) = "Array") {
        for t in rec["lines"]
            lines.Push(t)
    }
    if (lines.Length = 0 && Trim(text) != "")
        lines.Push(text)
    if (lines.Length = 0)
        return false
    chatIdx := 0
    try chatIdx := Max(0, Integer(rec.Get("chatIndex", 0)))

    if (session == currentCall && !IsObject(reviewCall)) {
        Critical "On"
        nb := []
        for t in lines
            nb.Push(CaptionLine(t))
        placed := false
        count := 0
        Loop bubbles.Length {
            if (BubbleText(bubbles[A_Index]) = "")
                continue
            if (count = chatIdx) {
                bubbles.InsertAt(A_Index, nb)
                placed := true
                break
            }
            count += 1
        }
        if (!placed)
            bubbles.Push(nb)
        sessionLines := FlattenBubbles()
        RemoveRemovedRecord(session, rec)
        PersistCurrentCall()
        Critical "Off"
    } else {
        cb := session["chatBubbles"]
        tl := session["transcriptLines"]
        ci := Min(chatIdx, cb.Length)
        if (ci < cb.Length) {
            span := FindBubbleLineSpan(session, ci + 1)
            if (IsObject(span))
                li := span[1] - 1
            else {
                ci := cb.Length                 ; cannot place it exactly: put it at the end
                li := tl.Length
            }
        } else
            li := tl.Length
        cb.InsertAt(ci + 1, text)
        tl.InsertAt(li + 1, lines*)
        RemoveRemovedRecord(session, rec)
        SaveHistory()
    }
    RenderTranscript()
    RefreshDebug()
    return true
}

UndoLastDelete() {
    global micUndoStack, micCommitted
    ; Try agent undo first (if last action was an agent bubble delete)
    if (micUndoStack.Length > 0) {
        micCommitted.Push(micUndoStack.Pop())
        RenderTranscript()
        statusText.Text := "Status: agent bubble restored"
        return
    }
    sess := ViewedCall()
    if (!IsObject(sess) || RemovedCount(sess) = 0) {
        statusText.Text := "Status: there is no deleted bubble to bring back"
        return
    }
    list := sess["removedBubbles"]
    if RestoreRemoved(sess, list[list.Length])
        statusText.Text := "Status: bubble restored"
    else
        statusText.Text := "Status: that deleted bubble could not be restored"
}

ShowRemovedWindow(*) {
    global removedWin
    sess := ViewedCall()
    if !IsObject(sess)
        return
    if IsObject(removedWin) {
        try removedWin.Destroy()
    }

    rg := Gui("+Owner" myGui.Hwnd, "Deleted bubbles")
    rg.BackColor := "11151D"
    rg.SetFont("s10 cF1F5FB", "Segoe UI")
    lb := rg.Add("ListBox", "w360 r12 Background1B2431 cF1F5FB")
    pv := rg.Add("Edit", "x+10 w440 r12 ReadOnly +0x100 Background1B2431 cF1F5FB")
    st := rg.Add("Text", "xm w810 c9BA8BA", "")
    btnRestore := rg.Add("Button", "w110", "Restore")
    btnErase := rg.Add("Button", "x+10 w150", "Erase permanently")
    btnClose := rg.Add("Button", "x+10 w100", "Close")
    order := []

    Refill() {
        order.Length := 0
        lb.Delete()
        pv.Value := ""
        removed := sess.Has("removedBubbles") ? sess["removedBubbles"] : []
        Loop removed.Length {
            rec := removed[removed.Length - A_Index + 1]        ; newest first
            order.Push(rec)
            label := rec.Get("text", "")
            if (StrLen(label) > 70)
                label := SubStr(label, 1, 70) . "…"
            lb.Add([IsoToLocal(rec.Get("deletedAtUtc", ""), "h:mm:ss tt") . "  ·  " . label])
        }
        st.Text := order.Length . " deleted bubble(s) for " . (IsObject(reviewCall) ? "the reviewed call" : "the live call")
        if (order.Length > 0) {
            lb.Choose(1)
            ShowPicked()
        }
    }

    ShowPicked() {
        idx := lb.Value
        pv.Value := idx ? order[idx].Get("text", "") : ""
    }

    DoRestore() {
        idx := lb.Value
        if (!idx) {
            st.Text := "Select a deleted bubble first"
            return
        }
        ok := RestoreRemoved(sess, order[idx])
        Refill()
        st.Text := (ok ? "Bubble restored. " : "That bubble could not be restored. ") . st.Text
    }

    DoErase() {
        idx := lb.Value
        if (!idx) {
            st.Text := "Select a deleted bubble first"
            return
        }
        rg.Opt("+OwnDialogs")
        if (MsgBox("Erase this deleted bubble permanently?`n`nIt will be removed from call-history.json and cannot be brought back.", "Erase permanently", "YesNo Icon! Default2") != "Yes")
            return
        RemoveRemovedRecord(sess, order[idx])
        SaveHistory()
        Refill()
        RefreshDebug()
    }

    lb.OnEvent("Change", (*) => ShowPicked())
    lb.OnEvent("DoubleClick", (*) => DoRestore())
    btnRestore.OnEvent("Click", (*) => DoRestore())
    btnErase.OnEvent("Click", (*) => DoErase())
    btnClose.OnEvent("Click", (*) => rg.Destroy())
    rg.OnEvent("Close", (*) => rg.Destroy())

    removedWin := rg
    rg.Show()
    Refill()
}

ChatBoxFocused() {
    try
        return WinActive("ahk_id " myGui.Hwnd) && chatView && (ControlGetFocus("ahk_id " myGui.Hwnd) = chatBox.Hwnd)
    return false
}

#HotIf ChatBoxFocused()
Delete::DeleteSelectedBubble()
^z::UndoLastDelete()
#HotIf


