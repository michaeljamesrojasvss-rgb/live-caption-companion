; ==============================================================================
; agent-voice.ahk  -  the agent's voice tools (app\agent\tools\voice.json): speak + listen
;
; * speak: Windows' own voice (SAPI.SpVoice), spoken in the background while this script keeps running
;   (Stop in the agent window cuts it off).
; * listen: app\agent\listen.ps1 in a hidden PowerShell = Windows' offline speech recognizer
;   (System.Speech dictation). A small window shows what it hears; Done ends it early.
; * Nothing is logged: what is said is task content.
; Needs agent.ahk (agtRun) - included from it after agent-tools.ahk.
; ==============================================================================

AgtT_Speak(args, ctx) {
    AgtVoiceSay(String(args["text"]), ctx)
    return Map("text", AgtVoiceStopped(ctx) ? "Stopped while speaking." : "Said it out loud.")
}

AgtT_Listen(args, ctx) {
    q := args.Has("question") ? Trim(String(args["question"])) : ""
    maxSec := (args.Has("maxSeconds") && IsInteger(args["maxSeconds"])) ? Integer(args["maxSeconds"]) : 30
    maxSec := Max(5, Min(120, maxSec))
    if (q != "")
        AgtVoiceSay(q, ctx)
    if AgtVoiceStopped(ctx)
        return Map("text", "Stopped before listening.")

    ps1 := A_LineFile "\..\agent\listen.ps1"
    if !FileExist(ps1)
        throw Error("listen.ps1 is missing next to agent.ahk")
    out := A_Temp "\agent-listen-" ctx.runId "-" ctx.step ".txt"
    for f in [out, out ".done", out ".err"]
        try FileDelete(f)
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps1 '" -Out "' out '" -MaxSec ' maxSec, , "Hide", &pid)

    ; the "I'm listening" window
    ; Typing in the lower box stops listening: the typed answer is sent instead (exact, for IDs and names).
    ui := {done: false, typing: false}
    g := Gui("+AlwaysOnTop -MinimizeBox +ToolWindow", "Agent is listening")
    g.SetFont("s11", "Segoe UI")
    lbl := g.Add("Text", "xm w420 h44", q != "" ? "Speak now:  " q : "Speak now - I'm listening")
    g.SetFont("s10")
    heard := g.Add("Edit", "xm w420 h70 ReadOnly -TabStop", "")
    g.Add("Text", "xm w420 h20", "Or type your answer here (stops listening, Enter sends):")
    typed := g.Add("Edit", "xm w420 h60 Multi -WantReturn", "")
    typed.OnEvent("Change", AgtVoiceTyping)
    b := g.Add("Button", "xm w100 h30 Default", "Done")
    b.OnEvent("Click", (*) => (ui.done := true))
    g.OnEvent("Close", (*) => (ui.done := true))
    g.OnEvent("Escape", (*) => (ui.done := true))
    g.Show("NoActivate")

    AgtVoiceTyping(*) {
        if ui.typing
            return
        ui.typing := true
        if ProcessExist(pid)
            try ProcessClose(pid)
        lbl.Text := "Typing - press Enter or Done to send"
    }

    t0 := A_TickCount, last := "", why := "I stopped talking", waitTyping := false
    loop {
        Sleep(150)
        if ui.typing {                            ; only Done / Stop matter now
            if ui.done
                break
            if AgtVoiceStopped(ctx) {
                AgtVoiceEnd(g, pid, out)
                return Map("text", "Stopped while I was typing.")
            }
            continue
        }
        if FileExist(out) {
            try {
                now := Trim(FileRead(out, "UTF-8"))
                if (now != last)
                    heard.Value := last := now
            }
        }
        if FileExist(out ".err") {
            err := Trim(FileRead(out ".err", "UTF-8"))
            AgtVoiceEnd(g, pid, out)
            throw Error("couldn't listen: " err)
        }
        if (!waitTyping && (FileExist(out ".done") || !ProcessExist(pid))) {
            if (last != "")
                break
            waitTyping := true                    ; heard nothing: leave the window up so I can type
            lbl.Text := "Didn't hear anything - type your answer, or press Done"
        }
        if ui.done {
            why := "I pressed Done"
            break
        }
        if AgtVoiceStopped(ctx) {
            AgtVoiceEnd(g, pid, out)
            return Map("text", "Stopped while listening.")
        }
        if (A_TickCount - t0 > (maxSec + 15) * 1000) {   ; the script didn't end by itself
            why := "time was up"
            break
        }
    }
    if ui.typing && Trim(typed.Value) != "" {
        answer := Trim(typed.Value)
        AgtVoiceEnd(g, pid, out)
        return Map("text", "I typed my answer (exact text): " answer)
    }
    try text := Trim(FileRead(out, "UTF-8"))
    catch
        text := ""
    AgtVoiceEnd(g, pid, out)
    secs := Round((A_TickCount - t0) / 1000)
    if (text = "")
        return Map("text", "You couldn't hear me say anything (listened " secs " s, ended because " why ").")
    return Map("text", "I said (speech recognition, may have small mistakes): " text)
}

; Speaks in the background and waits for it, so the window stays usable and Stop works
AgtVoiceSay(text, ctx) {
    static v := 0
    if (Trim(text) = "")
        return
    if !IsObject(v)
        v := ComObject("SAPI.SpVoice")
    v.Volume := 100
    v.Speak(text, 1 | 2)                       ; async + purge anything still speaking
    loop {
        if v.WaitUntilDone(100)
            return
        if AgtVoiceStopped(ctx) {
            v.Speak("", 1 | 2)
            return
        }
        Sleep(10)
    }
}

AgtVoiceStopped(ctx) {
    global agtRun
    return !IsObject(agtRun) || agtRun.id != ctx.runId || agtRun.status != "tool"
}

AgtVoiceEnd(g, pid, out) {
    try g.Destroy()
    if ProcessExist(pid)
        try ProcessClose(pid)
    for f in [out, out ".done", out ".err"]
        try FileDelete(f)
}
