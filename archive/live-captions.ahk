#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; =====================================================================
;  Live Mic Captions — Whisper edition (whisper.cpp, offline, CPU only)
;  Nothing to install. Put things in one folder like this:
;
;     live-captions.ahk
;     whisper\whisper-stream.exe   <- plus all the .dll files from the same zip
;     whisper\ggml-small.en.bin    <- the speech model
;
;  Right-click the caption bar (or the tray icon) for the menu
;  F8  = choose microphone
;  F9  = pause / resume listening
;  F10 = clear captions
;  Ctrl+Alt+Q = quit
;  Drag the caption bar with the left mouse button to move it.
; =====================================================================

; ---------- Settings (defaults, then overridden by INI) ----------
IniFile := A_ScriptDir "\live-captions.ini"
MaxCPU  := Min(8, Integer(EnvGet("NUMBER_OF_PROCESSORS") || 4))

ModelFile := IniRead(IniFile, "Settings", "Model",   "ggml-base.en.bin")
Language  := "en"
StepMs    := Integer(IniRead(IniFile, "Settings", "StepMs",   2000))
LengthMs  := Integer(IniRead(IniFile, "Settings", "LengthMs", 10000))
Threads   := Integer(IniRead(IniFile, "Settings", "Threads",  MaxCPU))
MaxLines  := 2
FontSize  := 18
BoxWidth  := 900
Opacity   := 220

; ---------- Files ----------
DataDir := A_Temp "\live-captions"
OutFile := DataDir "\captions.txt"
LogFile := DataDir "\engine.log"
DirCreate(DataDir)

WhisperDir := ""
for dir in [A_ScriptDir "\whisper", A_ScriptDir "\Release", A_ScriptDir]
    if FileExist(dir "\whisper-stream.exe") {
        WhisperDir := dir
        break
    }
if (WhisperDir = "") {
    MsgBox("Couldn't find whisper-stream.exe.`n`nUnzip whisper-bin-x64.zip and put all of its files in:`n"
        . A_ScriptDir "\whisper", "Live Captions", "Iconx")
    ExitApp
}
StreamExe := WhisperDir "\whisper-stream.exe"

ModelPath := ""
for dir in [WhisperDir, A_ScriptDir, WhisperDir "\models", A_ScriptDir "\models"]
    if FileExist(dir "\" ModelFile) {
        ModelPath := dir "\" ModelFile
        break
    }
if (ModelPath = "") {
    MsgBox("Couldn't find the model file " ModelFile ".`n`nDownload it and put it in:`n"
        . WhisperDir, "Live Captions", "Iconx")
    ExitApp
}

; ---------- Caption window ----------
cap := Gui("+AlwaysOnTop -Caption +ToolWindow")
cap.BackColor := "101010"
cap.MarginX := 16, cap.MarginY := 10
cap.SetFont("s" FontSize " cWhite", "Segoe UI")
finalTxt := cap.AddText("w" BoxWidth " r" (MaxLines * 2), "")
cap.SetFont("s" FontSize " c9A9A9A italic", "Segoe UI")
hypTxt := cap.AddText("w" BoxWidth " r2", "")

cap.Show("NoActivate Hide AutoSize")
cap.GetPos(, , &w, &h)
cap.Show("NoActivate x" (A_ScreenWidth - w) // 2 " y" (A_ScreenHeight - h - 80))
WinSetTransparent(Opacity, cap)

; Drag window by clicking anywhere on it
OnMessage(0x201, DragCaption)   ; WM_LBUTTONDOWN
DragCaption(wParam, lParam, msg, hwnd) {
    global cap
    if (hwnd = cap.Hwnd || DllCall("GetParent", "Ptr", hwnd, "Ptr") = cap.Hwnd)
        PostMessage(0xA1, 2, , , cap)   ; WM_NCLBUTTONDOWN, HTCAPTION
}

; ---------- Microphones ----------
micIds := [], micNames := []
hypTxt.Value := "Finding microphones…"
LoadDevices()

; whisper-stream prints its capture devices before loading a model,
; so running it with a dummy model path lists them and exits.
LoadDevices() {
    global micIds, micNames
    devFile := DataDir "\devices.txt"
    try FileDelete(devFile)
    RunWait(A_ComSpec ' /c ""' StreamExe '" -m "__list_devices__" 2> "' devFile '""', WhisperDir, "Hide")
    if !FileExist(devFile)
        return
    for line in StrSplit(StrReplace(FileRead(devFile, "UTF-8"), "`r"), "`n")
        if RegExMatch(line, "Capture device #(\d+): '(.*)'", &m) {
            micIds.Push(m[1])
            micNames.Push(m[2])
        }
}

MicLabel(index) {
    global micNames
    return index = 0 ? "Windows default microphone" : micNames[index]
}

savedMic := IniRead(IniFile, "Settings", "Mic", "")
currentMic := 0
for i, name in micNames
    if (name = savedMic)
        currentMic := i

SetMic(index, *) {
    global currentMic
    micMenu.Uncheck(MicLabel(currentMic))
    currentMic := index
    micMenu.Check(MicLabel(currentMic))
    IniWrite(index = 0 ? "" : MicLabel(index), IniFile, "Settings", "Mic")
    if listening
        StartEngine()
}

; ---------- Speech engine (whisper-stream.exe) ----------
listening := true
enginePid := 0
engineReady := false
engineDead := false
lagWarned := false
readPos := 0
committed := []
clearedCount := 0
partialText := ""
lastLogCheck := 0

StartEngine() {
    global enginePid, engineReady, engineDead, readPos, partialText
    StopEngine()
    try FileDelete(OutFile)
    try FileDelete(LogFile)
    readPos := 0, partialText := "", engineReady := false, engineDead := false
    args := Format('-m "{}" -t {} --step {} --length {} -l {}', ModelPath, Threads, StepMs, LengthMs, Language)
    if (currentMic > 0)
        args .= " -c " micIds[currentMic]
    Run(A_ComSpec ' /c ""' StreamExe '" ' args ' > "' OutFile '" 2> "' LogFile '""', WhisperDir, "Hide", &enginePid)
    Render()
}

StopEngine() {
    global enginePid
    if (enginePid && ProcessExist(enginePid))
        RunWait(A_ComSpec ' /c taskkill /F /T /PID ' enginePid ' >nul 2>&1', , "Hide")
    enginePid := 0
}

; whisper-stream rewrites the current line with `r while you talk and
; ends it with a newline once it's final. We keep only the latest version.
CleanLine(s) {
    s := RTrim(s, "`r")
    if (p := InStr(s, "`r", , -1))
        s := SubStr(s, p + 1)
    s := RegExReplace(s, "\x1B\[[0-9;]*[A-Za-z]")                 ; terminal codes
    s := RegExReplace(s, "\[[^\]]*\]|\([^)]*\)|\*[^*]*\*")        ; [BLANK_AUDIO], (music), *sigh*
    return Trim(RegExReplace(s, "\s+", " "))
}

Poll() {
    global readPos, committed, clearedCount, partialText, engineReady
    if !listening
        return
    CheckEngine()
    if !FileExist(OutFile)
        return
    try {
        f := FileOpen(OutFile, "r", "UTF-8-RAW")
        f.Pos := readPos
        chunk := f.Read()
        f.Close()
    } catch
        return
    if (chunk = "")
        return
    if InStr(chunk, "Start speaking")
        engineReady := true

    if (lastNL := InStr(chunk, "`n", , -1)) {
        done := SubStr(chunk, 1, lastNL)
        readPos += StrPut(done, "UTF-8") - 1
        for line in StrSplit(done, "`n")
            if ((t := CleanLine(line)) != "")
                committed.Push(t)
        while (committed.Length > 50) {
            committed.RemoveAt(1)
            clearedCount := Max(0, clearedCount - 1)
        }
        partialText := CleanLine(SubStr(chunk, lastNL + 1))
    } else
        partialText := CleanLine(chunk)
    Render()
}

CheckEngine() {
    global engineDead, lagWarned, lastLogCheck
    if (!engineDead && enginePid && !ProcessExist(enginePid)) {
        engineDead := true
        Render()
    }
    if (!lagWarned && A_TickCount - lastLogCheck > 5000) {
        lastLogCheck := A_TickCount
        try {
            if InStr(FileRead(LogFile), "cannot process audio fast enough") {
                lagWarned := true
                TrayTip("Your PC can't keep up with this model, so some speech gets skipped.`n"
                    . "Try ggml-base.en.bin, or set StepMs to 3000.", "Live Captions", "Iconi")
            }
        }
    }
}

LastError() {
    try for line in StrSplit(FileRead(LogFile), "`n", "`r")
        if InStr(line, "error") || InStr(line, "failed") || InStr(line, "couldn't")
            msg := line
    return IsSet(msg) ? msg : "see the engine log in the tray menu."
}

Render() {
    out := "", n := committed.Length - clearedCount
    start := Max(1, n - MaxLines + 1)
    Loop n - start + 1
        out .= (A_Index > 1 ? "`n" : "") committed[clearedCount + start + A_Index - 1]
    finalTxt.Value := out

    if !listening
        hypTxt.Value := "[paused — F9 to resume]"
    else if engineDead
        hypTxt.Value := "Speech engine stopped: " LastError()
    else if !engineReady
        hypTxt.Value := "Loading speech model…"
    else if (partialText = "" && n = 0)
        hypTxt.Value := "Listening… start speaking."
    else
        hypTxt.Value := partialText
}

; ---------- Menus ----------
micMenu := Menu()
micMenu.Add(MicLabel(0), SetMic.Bind(0))
if micNames.Length
    micMenu.Add()
for i, name in micNames
    micMenu.Add(name, SetMic.Bind(i))
micMenu.Check(MicLabel(currentMic))

OpenLog(*) {
    if FileExist(LogFile)
        Run('notepad.exe "' LogFile '"')
}

ctxMenu := Menu()
ctxMenu.Add("Microphone", micMenu)
ctxMenu.Add("Pause / resume`tF9", (*) => TogglePause())
ctxMenu.Add("Clear captions`tF10", (*) => ClearCaptions())
ctxMenu.Add("Open engine log", OpenLog)
ctxMenu.Add("Settings", ShowSettings)
ctxMenu.Add()
ctxMenu.Add("Exit`tCtrl+Alt+Q", (*) => ExitApp())
cap.OnEvent("ContextMenu", (*) => ctxMenu.Show())

A_TrayMenu.Insert("1&", "Microphone", micMenu)
A_TrayMenu.Insert("2&", "Open engine log", OpenLog)
A_TrayMenu.Insert("3&", "Settings", ShowSettings)
A_TrayMenu.Insert("4&")

; ---------- Actions ----------
TogglePause() {
    global listening
    listening := !listening
    if listening
        StartEngine()
    else
        StopEngine()
    Render()
}

ClearCaptions() {
    global clearedCount, partialText
    clearedCount := committed.Length
    partialText := ""
    Render()
}

ExitCleanup(*) {
    StopEngine()
}

ShowSettings(*) {
    global StepMs, LengthMs, Threads, ModelFile, ModelPath
    sg := Gui("+AlwaysOnTop", "Live Captions — Settings")
    sg.SetFont("s10", "Segoe UI")

    sg.Add("Text", , "Model:")
    models := ["ggml-base.en.bin", "ggml-small.en.bin"]
    modelDDL := sg.Add("DropDownList", "w260 vModel", models)
    modelDDL.Text := ModelFile

    sg.Add("Text", , "Step ms (caption refresh — lower = faster, more CPU):")
    stepEdit := sg.Add("Edit", "w260 vStepMs Number")
    stepEdit.Value := StepMs

    sg.Add("Text", , "Length ms (audio window before line is finalized):")
    lenEdit := sg.Add("Edit", "w260 vLengthMs Number")
    lenEdit.Value := LengthMs

    sg.Add("Text", , "Threads (max " MaxCPU "):")
    thrEdit := sg.Add("Edit", "w260 vThreads Number")
    thrEdit.Value := Threads

    sg.Add("Text", "w260 c888888", "Tip: try Step 1000–1500 for faster captions.`nLower = snappier but uses more CPU.")

    btnApply := sg.Add("Button", "w120 Default", "Apply && restart")
    btnCancel := sg.Add("Button", "x+16 w120", "Cancel")

    btnApply.OnEvent("Click", ApplySettings.Bind(sg))
    btnCancel.OnEvent("Click", (*) => sg.Destroy())
    sg.OnEvent("Close", (*) => sg.Destroy())
    sg.Show()
}

ApplySettings(sg, *) {
    global StepMs, LengthMs, Threads, ModelFile, ModelPath
    saved := sg.Submit()
    newModel := saved.Model
    newStep  := Max(500, Integer(saved.StepMs))
    newLen   := Max(2000, Integer(saved.LengthMs))
    newThr   := Clamp(Integer(saved.Threads), 1, MaxCPU)

    ; find model path for the chosen model
    newModelPath := ""
    for dir in [WhisperDir, A_ScriptDir, WhisperDir "\models", A_ScriptDir "\models"]
        if FileExist(dir "\" newModel) {
            newModelPath := dir "\" newModel
            break
        }
    if (newModelPath = "") {
        MsgBox("Could not find " newModel " in the whisper folder.", "Settings", "Iconx")
        return
    }

    ModelFile := newModel, StepMs := newStep, LengthMs := newLen, Threads := newThr
    ModelPath := newModelPath

    IniWrite(ModelFile, IniFile, "Settings", "Model")
    IniWrite(StepMs,    IniFile, "Settings", "StepMs")
    IniWrite(LengthMs,  IniFile, "Settings", "LengthMs")
    IniWrite(Threads,   IniFile, "Settings", "Threads")

    if listening
        StartEngine()
}

Clamp(val, lo, hi) => Min(hi, Max(lo, val))

; ---------- Start ----------
OnExit(ExitCleanup)
StartEngine()
SetTimer(Poll, 150)

; ---------- Hotkeys ----------
F8::micMenu.Show()
F9::TogglePause()
F10::ClearCaptions()
^!q::ExitApp
