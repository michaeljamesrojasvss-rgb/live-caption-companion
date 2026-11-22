#Requires AutoHotkey v2.0
#SingleInstance Off
#Include %A_ScriptDir%\..\..\..\..\app\Json.ahk

; ==============================================================================
; host.ahk - the native messaging host of the Edge bridge probe (dev only, never shipped)
;
; Edge starts this (through host.bat) when you click the probe extension's icon. The browser
; talks to it over stdin/stdout: each message = 4-byte length (little endian) + UTF-8 JSON.
; stdin is read without blocking (PeekNamedPipe on a timer) so this window stays usable.
;
; Tests: round-trip time (ping), Copilot in a BACKGROUND tab and in a VISIBLE tab (does the
; page load, is it signed in, is there a message box, does the browser slow a hidden tab).
; It never types, clicks or sends anything to Copilot. Report: ..\probe-report.txt (+ Copy report).
; ==============================================================================

COPILOT_URL := "https://m365.cloud.microsoft/chat"
REPORT := A_ScriptDir "\..\probe-report.txt"
hIn := DllCall("GetStdHandle", "Int", -10, "Ptr")
hOut := DllCall("GetStdHandle", "Int", -11, "Ptr")
acc := Buffer(0), accLen := 0
connected := true
seq := 0
pings := Map()                       ; id -> tick sent
pingTimes := []

OnError(HostOnError)
g := Gui("+AlwaysOnTop", "Caption Companion - Edge bridge probe")
g.SetFont("s10", "Segoe UI")
g.Add("Text", "w640 h20 vState", "Connected to the browser - waiting for its hello...")
logBox := g.Add("Edit", "w640 h330 ReadOnly Multi VScroll")
g.Add("Button", "w120 h30", "Ping x5").OnEvent("Click", (*) => PingMany(5))
g.Add("Button", "x+8 w190 h30", "Copilot: background tab").OnEvent("Click", (*) => OpenTest(false))
g.Add("Button", "x+8 w170 h30", "Copilot: visible tab").OnEvent("Click", (*) => OpenTest(true))
g.Add("Button", "x+8 w130 h30", "Copy report").OnEvent("Click", (*) => (A_Clipboard := logBox.Value, Log("(report copied)")))
g.OnEvent("Close", (*) => ExitApp())
g.Show()

Log("Probe host started " FormatTime(, "yyyy-MM-dd HH:mm:ss") ", AutoHotkey " A_AhkVersion " " (A_PtrSize * 8) "-bit")
Log("Started by: " (A_Args.Length ? JoinArgs() : "(no arguments - not started by a browser?)"))
SetTimer(ReadPipe, 30)

; ------------------------------------------------------------------ pipe
ReadPipe() {
    global acc, accLen, connected
    if !connected
        return
    avail := 0
    if !DllCall("PeekNamedPipe", "Ptr", hIn, "Ptr", 0, "UInt", 0, "Ptr", 0, "UInt*", &avail, "Ptr", 0) {
        connected := false
        g["State"].Value := "The browser closed the connection (you can still copy the report)."
        Log("browser closed the connection (pipe error " A_LastError ")")
        return
    }
    if !avail
        return
    chunk := Buffer(avail)
    got := 0
    DllCall("ReadFile", "Ptr", hIn, "Ptr", chunk, "UInt", avail, "UInt*", &got, "Ptr", 0)
    nb := Buffer(accLen + got)
    if accLen
        DllCall("RtlMoveMemory", "Ptr", nb, "Ptr", acc, "UPtr", accLen)
    DllCall("RtlMoveMemory", "Ptr", nb.Ptr + accLen, "Ptr", chunk, "UPtr", got)
    acc := nb, accLen += got
    while (accLen >= 4) {
        n := NumGet(acc, 0, "UInt")
        if (accLen < 4 + n)
            break
        text := StrGet(acc.Ptr + 4, n, "UTF-8")
        rest := accLen - 4 - n
        nb := Buffer(rest)
        if rest
            DllCall("RtlMoveMemory", "Ptr", nb, "Ptr", acc.Ptr + 4 + n, "UPtr", rest)
        acc := nb, accLen := rest
        try {
            OnBrowser(Json.Parse(text))
        } catch as err {
            Log("could not read a message: " err.Message)
        }
    }
}

HostSend(m) {
    if !connected {
        Log("not connected - click the extension's icon in Edge again")
        return false
    }
    s := Json.Stringify(m)
    n := StrPut(s, "UTF-8") - 1
    b := Buffer(4 + n + 1, 0)
    NumPut("UInt", n, b, 0)
    StrPut(s, b.Ptr + 4, "UTF-8")
    w := 0
    return DllCall("WriteFile", "Ptr", hOut, "Ptr", b, "UInt", 4 + n, "UInt*", &w, "Ptr", 0) && w = 4 + n
}

; ------------------------------------------------------------------ messages from the browser
OnBrowser(m) {
    switch m.Get("t", "") {
        case "hello":
            ua := m.Get("ua", "")
            browser := InStr(ua, "Edg/") ? "Edge " RegExReplace(ua, ".*Edg/([\d.]+).*", "$1")
                : InStr(ua, "Chrome/") ? "Chrome " RegExReplace(ua, ".*Chrome/([\d.]+).*", "$1") : ua
            g["State"].Value := "Connected: " browser " - use the buttons below"
            Log("OK hello from the extension (" m.Get("reason", "") "): " browser ", extension " m.Get("ext", ""))
            PingMany(5)
        case "pong":
            id := m.Get("id", 0)
            if pings.Has(id) {
                ms := A_TickCount - pings[id]
                pings.Delete(id)
                pingTimes.Push(ms)
                if !pings.Count {
                    total := 0, mx := 0
                    for t in pingTimes
                        total += t, mx := Max(mx, t)
                    Log("OK round trip AHK -> browser -> AHK: average " Round(total / pingTimes.Length) " ms, slowest " mx " ms (" pingTimes.Length " pings)")
                }
            }
        case "opened":
            ReportOpened(m)
        case "error":
            Log("browser error: " m.Get("error", ""))
        default:
            Log("unknown message: " Json.Stringify(m))
    }
}

ReportOpened(m) {
    kind := m.Get("active", 0) ? "VISIBLE tab" : "BACKGROUND tab"
    Log("Copilot in a " kind ": page " (m.Get("loaded", 0) ? "loaded" : "did NOT finish loading") ", test took " Round(m.Get("ms", 0) / 1000, 1) " s")
    last := ""
    for s in m.Get("samples", []) {
        at := Round(s.Get("atMs", 0) / 1000, 1)
        if s.Has("error") {
            Log("   at " at " s: could not read the page: " s["error"])
            continue
        }
        Log("   at " at " s: " s.Get("host", "?") ", title `"" s.Get("title", "") "`", message box: " (s.Get("hasMessageBox", 0) ? "yes" : "no")
            . ", page visible to itself: " s.Get("visibility", "?") (s.Get("signInPage", 0) ? ", SIGN-IN PAGE" : ""))
        last := s
    }
    if !IsObject(last)
        Log("   => could not read the page at all")
    else if last.Get("signInPage", 0)
        Log("   => asks you to sign in: your Edge isn't signed in to Copilot there (or SSO didn't happen)")
    else if last.Get("hasMessageBox", 0)
        Log("   => signed in and ready (message box found) - your own Edge session works")
    else
        Log("   => loaded, but no message box found yet (slow, a different page, or throttled in the background)")
}

; ------------------------------------------------------------------ tests
PingMany(n) {
    global seq, pingTimes
    pingTimes := []
    Loop n {
        seq += 1
        pings[seq] := A_TickCount
        HostSend(Map("t", "ping", "id", seq))
        Sleep(20)
    }
}

OpenTest(active) {
    global seq
    seq += 1
    Log("opening Copilot in a " (active ? "visible" : "background") " tab (it closes by itself after ~15 s)...")
    HostSend(Map("t", "open", "id", seq, "url", COPILOT_URL, "active", active ? 1 : 0, "closeAfter", 1
        , "readAtMs", [3000, 8000, 15000]))
}

; ------------------------------------------------------------------ helpers
Log(line) {
    try {
        logBox.Value .= line "`r`n"
        SendMessage(0x0115, 7, 0, logBox.Hwnd)          ; WM_VSCROLL SB_BOTTOM
    }
    try FileAppend(line "`n", REPORT, "UTF-8")
}

JoinArgs() {
    s := ""
    for a in A_Args
        s .= (s = "" ? "" : "  ") a
    return s
}

HostOnError(err, mode) {
    Log("ERROR: " err.Message " (line " err.Line ")")
    return 1                                            ; carry on
}
