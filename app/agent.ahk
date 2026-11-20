#Requires AutoHotkey v2.0
#SingleInstance Force
try TraySetIcon(A_ScriptDir "\icons\agent.ico")     ; its own icon (tray, windows)
try DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", "CaptionCompanion.Agent")
#Include app-paths.ahk
#Include Json.ahk
#Include debug-trace.ahk
#Include screen-grab.ahk
#Include agent-protocol.ahk
#Include agent-tools.ahk
; ==============================================================================
; agent.ahk  -  the Agent: a chat AI (through the Copilot pool) that can use tools, with your OK
;
; * You type a task. The agent sends it to the AI with the list of tools it may use (agent-protocol.ahk:
;   templates in app\agent\instructions.md). The AI replies with ONE JSON object: a tool call or "final".
;   The agent runs the tool (agent-tools.ahk) - after asking you, for tools that ask first - and sends
;   the result back (images too). Until "final", Stop, MaxSteps or RunMaxMin. Design: docs\AGENT.md.
; * The AI's chat is a kept pool conversation (Conversation setting) shown as the pool's Copilot window
;   (ShowChat; without taking the focus). Closing that window during a task ends the task.
; * Never sends a step twice: one that may have reached the AI (failed / timeout / cancelled) ends the
;   task; only steps that never got in (unsent, pool starting, sign-in, you typing in its box) are retried.
; * Its own app and process, generic (no call words). Started from the Companion's tray (agent-link.ahk):
;   OFF by default in installed copies, ON in dev mode. Started by the Companion it has no tray icon and ends with it; started on
;   its own (double-click) it has its own tray icon. One copy only.
; * The log (data\agent.log) and the debug trace never hold the task, the AI's replies or tool results.
; * Memory: it talks to the pool through a small hidden window made for a task and closed ~2 min after it,
;   so the pool can still close itself when nothing uses it.
;
; Messages (WM_COPYDATA, JSON text):
;   tag AGT_TAG  app -> agent: {t:"show"} {t:"quit"}
;   tag POOL_TAG agent <-> pool: "ask" (see the top of copilot-pool.ahk), "cancel"; replies queued / sent /
;                done, and "state"
; Arguments: <Companion window handle> = started by the Companion; /show = open the window right away.
; ==============================================================================
AGT_TITLE := "Caption Companion Agent"            ; the hidden message window (agent-link.ahk finds it by this)
AGT_WIN_TITLE := "Agent - Caption Companion"
AGT_CONTACT_TITLE := "Agent pool contact (Caption Companion)"
AGT_TAG := 0x3CC6
POOL_TAG := 0x3CC3
POOL_WIN := "Caption Companion Copilot pool ahk_class AutoHotkeyGUI"
AGT_INI := DATA_DIR "\agent.ini"
AGT_LOG := DATA_DIR "\agent.log"
AGT_DIRS := [A_ScriptDir "\agent", DATA_DIR "\agent"]   ; data\ replaces sections / tools of app\
AGT_WORKSPACE := DATA_DIR "\agent-workspace"
AGT_NEVER_SENT := ["unsent", "off", "starting", "signin", "busy"]   ; pool "done" kinds that never reached the AI
AGT_ACTIVE := ["thinking", "approval", "tool"]
AGT_DEFAULTS := Map(
    "Hotkey", "^+!g",              ; Ctrl+Shift+Alt+G (AutoHotkey key names: ^ Ctrl, + Shift, ! Alt, # Win)
    "Conversation", "agent",       ; the pool's name for the agent's chat (its window remembers its place)
    "ShowChat", 1,                 ; 1 = the AI's chat shows as a window while it works (no focus taken)
    "MaxSteps", 15,                ; most tool calls per task
    "MaxFormatRetries", 2,         ; replies in a row the agent couldn't read before it gives up
    "ResultMaxChars", 6000,        ; a tool result is cut to this before it goes to the AI
    "RunMaxMin", 20,               ; a task stops after this long
    "SendRetrySec", 120,           ; a step that couldn't reach the AI yet is tried again for this long
    "AllowedFolders", AGT_WORKSPACE,   ; folders the file tools may read: separate with |, %VARIABLES% work
    "ReadMaxKB", 256,              ; biggest file read_text_file reads
    "ScreenshotMaxSide", 2560,     ; screenshots are made smaller than this (0 = never)
    "ContactKeepSec", 120)         ; the hidden pool-contact window stays this long after a task

DetectHiddenWindows(true)
OnError(AgtOnError)

AGT_HOST_HWND := (A_Args.Length >= 1 && IsInteger(A_Args[1])) ? Integer(A_Args[1]) : 0
agtArgs := ""
for a in A_Args
    agtArgs .= " " a

agtMain := 0          ; hidden window: commands from the Companion
agtContact := 0       ; hidden window the pool talks to (made for a task, closed ContactKeepSec after)
agtContactIdleAt := 0
agtGui := 0
agtRun := 0           ; the task: see AgtRunStart
agtPool := 0          ; the pool's last "state" message (Map)
agtSeq := 0
agtEntries := []      ; the transcript: {at, who, what, detail}
agtTemplates := Map()
agtTools := Map()
agtToolProblems := []
agtHotkey := ""

AgtBuildMain()
OnMessage(0x4A, AgtOnCopyData)
OnExit(AgtOnExit)
AgtTrimLog()
try DirCreate(AGT_WORKSPACE)
AgtCleanImages()
AgtLoadConfig()
AgtBuildGui()
AgtSetHotkey()
if AGT_HOST_HWND {
    A_IconHidden := true
    SetTimer(AgtCheckHost, 2000)
} else {
    AgtBuildTray()
}
AgtLog("started (" (A_PtrSize * 8) "-bit, version " APP_VERSION (AGT_HOST_HWND ? ", by the Companion" : ", on its own")
    . ", " agtTools.Count " tool(s)" (agtToolProblems.Length ? ", " agtToolProblems.Length " tool problem(s)" : "") ")")
SetTimer(AgtWatch, 1000)
if (!AGT_HOST_HWND || InStr(agtArgs, "/show"))
    SetTimer(() => AgtShow(), -100)

AgtBuildMain() {
    global agtMain
    agtMain := Gui("+ToolWindow", AGT_TITLE)
    agtMain.Show("Hide w10 h10")
}

AgtBuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Open the agent (" AgtHotkeyText() ")", (*) => AgtShow())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Open the agent (" AgtHotkeyText() ")"
    A_IconTip := "Agent - " AgtHotkeyText()
}

AgtCheckHost() {
    if !WinExist("ahk_id " AGT_HOST_HWND)
        ExitApp()
}

AgtSetHotkey() {
    global agtHotkey
    key := Trim(AgtSetting("Hotkey"))
    if (key = "")
        return
    try {
        Hotkey(key, (*) => AgtShow())
        agtHotkey := key
    } catch as err {
        AgtLog("the shortcut `"" key "`" couldn't be set: " err.Message)
    }
}

AgtHotkeyText() {
    k := agtHotkey != "" ? agtHotkey : AgtSetting("Hotkey")
    out := ""
    for pair in [["^", "Ctrl+"], ["+", "Shift+"], ["!", "Alt+"], ["#", "Win+"]]
        if InStr(k, pair[1])
            out .= pair[2]
    return out StrUpper(RegExReplace(k, "[\^+!#<>*~$]"))
}

; Tools and the messages to the AI: read again at every task, so edits apply without a restart
AgtLoadConfig() {
    global agtTemplates, agtTools, agtToolProblems
    try {
        agtTemplates := AgtProtoLoadTemplates(AGT_DIRS)
    } catch as err {
        agtTemplates := Map()
        AgtLog("couldn't read the instructions: " err.Message)
    }
    res := AgtToolsLoad(AGT_DIRS, AgtIniSection("Approval"))
    agtTools := res.tools
    agtToolProblems := res.problems
}

; ==============================================================================
; The window
; ==============================================================================
AgtBuildGui() {
    global agtGui
    g := Gui("+Resize +MinSize600x520", AGT_WIN_TITLE)
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "x10 y8 w600 h20 vGoalLabel", "What should the agent do?  (Run = Ctrl+Enter)")
    g.Add("Edit", "x10 y30 w600 h64 vGoal Multi WantReturn")
    g.Add("Button", "x10 y102 w100 h30 vRun Default", "▶ Run").OnEvent("Click", (*) => AgtRunStart())
    g.Add("Button", "x120 y102 w90 h30 vStop Disabled", "■ Stop").OnEvent("Click", (*) => AgtStop())
    g.Add("Button", "x220 y102 w110 h30 vNew", "New task").OnEvent("Click", (*) => AgtNewTask())
    g.Add("Text", "x10 y140 w600 h20 vStatus", "")
    g.SetFont("s10 bold")
    g.Add("Text", "x10 y166 w600 h40 vAsk Disabled", "No action is waiting for your OK.")
    g.SetFont("s10 norm")
    g.Add("Button", "x10 y208 w100 h28 vAllow Disabled", "Allow").OnEvent("Click", (*) => AgtApprove("once"))
    g.Add("Button", "x120 y208 w160 h28 vAllowRun Disabled", "Allow for this task").OnEvent("Click", (*) => AgtApprove("task"))
    g.Add("Button", "x290 y208 w90 h28 vDeny Disabled", "Deny").OnEvent("Click", (*) => AgtApprove("deny"))
    lv := g.Add("ListView", "x10 y246 w600 h200 vSteps -Multi Grid", ["#", "Who", "What"])
    lv.OnEvent("ItemSelect", (ctl, row, sel) => (sel ? AgtShowEntry(row) : 0))
    g.Add("Edit", "x10 y454 w600 h120 vDetail ReadOnly Multi")
    g.Add("Button", "x10 y582 w100 h30 vTools", "Tools...").OnEvent("Click", (*) => AgtShowTools())
    g.Add("Button", "x120 y582 w120 h30 vSettings", "Settings file").OnEvent("Click", (*) => AgtOpenSettings())
    g.Add("Button", "x250 y582 w140 h30 vCopy", "Copy transcript").OnEvent("Click", (*) => AgtCopyTranscript())
    g.OnEvent("Size", AgtOnSize)
    g.OnEvent("Close", (*) => AgtHide())
    g.OnEvent("Escape", (*) => AgtHide())
    agtGui := g
    HotIfWinActive("ahk_id " g.Hwnd)
    Hotkey("^Enter", (*) => AgtRunStart())
    HotIf()
    AgtRefresh()
}

AgtOnSize(g, minMax, w, h) {
    if (minMax = -1)
        return
    cw := w - 20
    bottomY := h - 40
    detailH := Max(80, Min(200, (h - 246) // 3))
    detailY := bottomY - 8 - detailH
    lvH := Max(60, detailY - 8 - 246)
    g["GoalLabel"].Move(10, 8, cw, 20)
    g["Goal"].Move(10, 30, cw, 64)
    g["Status"].Move(10, 140, cw, 20)
    g["Ask"].Move(10, 166, cw, 40)
    g["Steps"].Move(10, 246, cw, lvH)
    g["Detail"].Move(10, detailY, cw, detailH)
    for name in ["Tools", "Settings", "Copy"] {
        g[name].GetPos(&bx)
        g[name].Move(bx, bottomY)
    }
    lv := g["Steps"]
    lv.ModifyCol(1, 40)
    lv.ModifyCol(2, 70)
    lv.ModifyCol(3, Max(100, cw - 40 - 70 - 30))
    SetTimer(AgtRepaint, -60)
}

AgtRepaint() {
    try DllCall("RedrawWindow", "Ptr", agtGui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x1 | 0x4 | 0x80 | 0x100 | 0x400)
}

AgtShow(activate := true) {
    if !AgtWindowShown() {
        x := AgtIni("Window", "X"), y := AgtIni("Window", "Y"), w := AgtIni("Window", "W"), h := AgtIni("Window", "H")
        opts := (IsInteger(w) && IsInteger(h)) ? "w" w " h" h : "w760 h680"
        if (IsInteger(x) && IsInteger(y) && AgtPointOnScreen(x + 40, y + 20))
            opts .= " x" x " y" y
        agtGui.Show(opts (activate ? "" : " NoActivate"))
    } else {
        agtGui.Show(activate ? "" : "NoActivate")
    }
    if activate {
        try WinActivate("ahk_id " agtGui.Hwnd)
        if !AgtActive()
            try agtGui["Goal"].Focus()
    }
}

AgtWindowShown() {
    try return DllCall("IsWindowVisible", "Ptr", agtGui.Hwnd) && WinGetMinMax("ahk_id " agtGui.Hwnd) != -1
    return false
}

AgtHide() {
    try {
        if (DllCall("IsWindowVisible", "Ptr", agtGui.Hwnd) && WinGetMinMax("ahk_id " agtGui.Hwnd) = 0) {
            agtGui.GetPos(&x, &y)
            agtGui.GetClientPos(, , &w, &h)
            IniWrite(x, AGT_INI, "Window", "X")
            IniWrite(y, AGT_INI, "Window", "Y")
            IniWrite(w, AGT_INI, "Window", "W")
            IniWrite(h, AGT_INI, "Window", "H")
        }
    }
    agtGui.Hide()                                ; a task carries on; a question for you shows it again
}

AgtPointOnScreen(x, y) {
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return true
    }
    return false
}

; Buttons, the approval box and the status line, from the task's state
AgtRefresh() {
    if !IsObject(agtGui)
        return
    active := AgtActive()
    r := agtRun
    agtGui["Run"].Enabled := !active
    agtGui["Stop"].Enabled := active
    agtGui["New"].Enabled := !active
    asking := active && r.status = "approval"
    for name in ["Allow", "AllowRun", "Deny", "Ask"]
        agtGui[name].Enabled := asking
    if !asking
        agtGui["Ask"].Value := "No action is waiting for your OK."
    agtGui["Status"].Value := AgtStatusText()
}

AgtStatusText() {
    r := agtRun
    ps := IsObject(agtPool) ? agtPool.Get("state", "") : ""
    pr := IsObject(agtPool) ? agtPool.Get("reason", "") : ""
    if !IsObject(r)
        return "Ready. Type a task and press Run." (ps != "" && ps != "ready" ? "  (Copilot: " pr ")" : "")
    secs := Round(((r.endedAt ? r.endedAt : A_TickCount) - r.startedAt) / 1000)
    steps := r.step " tool call" (r.step = 1 ? "" : "s")
    switch r.status {
        case "thinking":
            o := r.out
            if !IsObject(o) || !o.inPool
                return !WinExist(POOL_WIN) ? "Starting Copilot - the task goes as soon as it's ready... (" secs " s)"
                    : (ps = "signin") ? "Copilot needs you to sign in (its window is open) - the task goes right after."
                    : (ps != "" && ps != "ready") ? "Copilot isn't ready (" pr ") - waiting... (" secs " s)"
                    : "Sending to the AI... (" secs " s)"
            return (o.sent ? "The AI is working on it" : "Sending to the AI") "... (" steps " so far, " secs " s)"
        case "approval":
            return "Waiting for your OK below (" steps " so far, " secs " s)"
        case "tool":
            return "Running " (IsObject(r.pending) ? r.pending.name : "a tool") "... (" secs " s)"
        case "done":
            return "Done - " steps ", " secs " s."
        case "stopped":
            return "Stopped: " r.endWhy " (" steps ", " secs " s)"
        case "failed":
            return "Failed: " r.endWhy " (" steps ", " secs " s)"
    }
    return ""
}

; ------------------------------------------------------------------------------
; The transcript: what you asked, every message to and from the AI, every tool run. Only in this window.
; ------------------------------------------------------------------------------
AgtEntry(who, what, detail := "") {
    agtEntries.Push({at: FormatTime(, "HH:mm:ss"), who: who, what: what, detail: detail})
    try {
        lv := agtGui["Steps"]
        one := RegExReplace(what, "\s*[\r\n]+\s*", "  ")
        row := lv.Add("", agtEntries.Length, who, StrLen(one) > 220 ? SubStr(one, 1, 220) "..." : one)
        lv.Modify(row, "Select Focus Vis")
        AgtShowEntry(row)
    }
}

AgtShowEntry(row) {
    if (row < 1 || row > agtEntries.Length)
        return
    e := agtEntries[row]
    d := e.detail != "" ? e.detail : e.what
    try agtGui["Detail"].Value := e.at "  " e.who "`r`n`r`n" StrReplace(StrReplace(d, "`r`n", "`n"), "`n", "`r`n")
}

AgtCopyTranscript() {
    out := ""
    for i, e in agtEntries
        out .= "#" i "  " e.at "  " e.who ": " e.what (e.detail != "" && e.detail != e.what ? "`n" e.detail : "") "`n`n"
    if (out = "") {
        agtGui["Status"].Value := "Nothing to copy yet."
        return
    }
    A_Clipboard := RTrim(out, "`n")
    agtGui["Status"].Value := "Transcript copied (" agtEntries.Length " entries)."
}

AgtNewTask() {
    global agtRun, agtEntries
    if AgtActive()
        return
    agtRun := 0
    agtEntries := []
    agtGui["Steps"].Delete()
    agtGui["Detail"].Value := ""
    agtGui["Goal"].Value := ""
    try agtGui["Goal"].Focus()
    AgtRefresh()
}

AgtShowTools() {
    AgtLoadConfig()
    out := ""
    for name, t in agtTools
        out .= (t.approval = "ask" ? "[asks first]  " : "[runs by itself]  ") name " - " t.title "`n"
    if (out = "")
        out := "(no tools)`n"
    if agtToolProblems.Length {
        out .= "`nProblems:`n"
        for p in agtToolProblems
            out .= "- " p "`n"
    }
    out .= "`nAllowed folders: " AgtToolsFolderText(AgtFolders())
        . "`n`nChange a tool: data\agent.ini, section [Approval], a line <tool>=auto, ask or off."
        . "`nTool files: app\agent\tools\ (and data\agent\tools\ to add or replace one)."
    MsgBox(out, "Agent tools", "Owner" agtGui.Hwnd)
}

AgtOpenSettings() {
    for k, v in AGT_DEFAULTS
        if (IniRead(AGT_INI, "Settings", k, "`a") = "`a")
            IniWrite(v, AGT_INI, "Settings", k)
    try Run('notepad.exe "' AGT_INI '"')
}

; ==============================================================================
; A task
; run = {id, goal, status (thinking | approval | tool | done | stopped | failed), step (tool calls so far),
;        badFormat, startedAt, endedAt, endWhy, out (the message on its way to the AI), pending (the tool
;        call waiting for your OK / running), allow (tools allowed for this task), files (images to delete),
;        note (said once with the next message), sawWindow (its chat window was open)}
; ==============================================================================
AgtActive() {
    if !IsObject(agtRun)
        return false
    for s in AGT_ACTIVE
        if (agtRun.status = s)
            return true
    return false
}

AgtRunStart() {
    global agtRun, agtSeq, agtEntries
    if AgtActive()
        return
    goal := Trim(agtGui["Goal"].Value, " `t`r`n")
    if (goal = "") {
        agtGui["Status"].Value := "Type what the agent should do first."
        try agtGui["Goal"].Focus()
        return
    }
    AgtLoadConfig()
    agtSeq += 1
    agtRun := {id: "a" A_TickCount "-" agtSeq, goal: goal, status: "thinking", step: 0, badFormat: 0,
        startedAt: A_TickCount, endedAt: 0, endWhy: "", out: 0, pending: 0, allow: Map(), files: [], note: "",
        sawWindow: false}
    agtEntries := []
    agtGui["Steps"].Delete()
    AgtEntry("You", goal)
    for p in agtToolProblems
        AgtEntry("Agent", "Tool problem: " p)
    try {
        prompt := AgtProtoFill(agtTemplates, "start", Map("tools", AgtProtoToolList(agtTools, AgtToolVars()),
            "goal", goal, "maxSteps", AgtNum("MaxSteps"), "today", FormatTime(, "dddd d MMMM yyyy")))
    } catch as err {
        AgtEnd("failed", err.Message)
        return
    }
    AgtLog("task " agtRun.id " started: " StrLen(goal) " chars, " agtTools.Count " tool(s)")
    DbgTrace("agent", "task " agtRun.id " started: " StrLen(goal) " chars, " agtTools.Count " tool(s)")
    AgtAsk(prompt, [], true, "Task + " agtTools.Count " tools")
}

AgtToolVars() => Map("allowedFolders", AgtToolsFolderText(AgtFolders()), "readMaxKB", AgtNum("ReadMaxKB"))

; A message to the AI (the first one starts a fresh chat)
AgtAsk(prompt, images, newChat, what) {
    r := agtRun
    if (r.note != "") {
        prompt .= "`n`n" r.note
        r.note := ""
    }
    r.status := "thinking"
    r.pending := 0
    r.out := {id: "", prompt: prompt, images: images, newChat: newChat, at: A_TickCount, inPool: false, sent: false, tries: 0}
    AgtEntry("Agent", "To the AI: " what (images.Length ? " + " images.Length " image(s)" : ""), prompt)
    DbgTrace("agent", "task " r.id " message to the AI: " StrLen(prompt) " chars, " images.Length " image(s)" (newChat ? ", new chat" : ""))
    AgtRefresh()
    AgtFlush()
}

; Hands the waiting message to the pool (starts the pool if it isn't running; retried for SendRetrySec)
AgtFlush() {
    global agtSeq
    r := agtRun
    if (!IsObject(r) || r.status != "thinking" || !IsObject(r.out) || r.out.inPool)
        return
    o := r.out
    if (hwnd := WinExist(POOL_WIN)) {
        agtSeq += 1
        o.id := r.id "-" agtSeq
        o.tries += 1
        m := Map("t", "ask", "id", o.id, "hwnd", AgtPoolContact(), "prompt", o.prompt, "label", "Agent",
            "conversation", AgtSetting("Conversation"), "newChat", o.newChat ? 1 : 0,
            "show", AgtNum("ShowChat") ? 1 : 0, "quiet", 1, "respectDraft", 1, "tick", A_TickCount)
        if o.images.Length
            m["images"] := o.images
        if AgtSendTo(hwnd, POOL_TAG, m) {
            o.inPool := true
            AgtRefresh()
            return
        }
    }
    if (A_TickCount - o.at > AgtNum("SendRetrySec") * 1000) {
        AgtEnd("failed", "the Copilot pool didn't take the message (nothing was sent)")
        return
    }
    AgtStartPool()
    AgtRefresh()
    SetTimer(AgtFlush, -1000)
}

; The pool finished our message
AgtOnDone(m) {
    r := agtRun
    o := r.out
    if m.Get("ok", 0) {
        r.out := 0
        text := m.Get("text", "")
        if (Trim(text) = "")
            text := m.Get("markdown", "")
        DbgTrace("agent", "task " r.id " answer: " StrLen(text) " chars after " (A_TickCount - o.at) " ms")
        AgtOnAnswer(text)
        return
    }
    kind := m.Get("kind", ""), why := m.Get("error", "")
    neverSent := false
    for k in AGT_NEVER_SENT
        if (kind = k)
            neverSent := true
    AgtLog("task " r.id " message not answered: " kind)
    if (neverSent && A_TickCount - o.at < AgtNum("SendRetrySec") * 1000) {
        o.inPool := false                        ; never reached the AI: safe to try again in a moment
        o.sent := false
        SetTimer(AgtFlush, -3000)
        AgtRefresh()
        return
    }
    r.out := 0
    AgtEnd("failed", neverSent ? "the AI couldn't be reached (" why ") - nothing was sent"
        : kind = "account" ? "Copilot won't take it: " why
        : kind = "lost" ? "the AI's chat was closed, so it no longer knows this task"
        : "the AI didn't answer (" kind (why != "" ? ": " why : "") ") - not sent again")
}

; The AI answered: a tool call, the final answer, or something we can't read
AgtOnAnswer(text) {
    r := agtRun
    p := AgtProtoParse(text)
    if (p.kind = "none") {
        AgtEntry("AI", "(reply not in the agent's format)", text)
        r.badFormat += 1
        if (r.badFormat > AgtNum("MaxFormatRetries")) {
            AgtEnd("failed", "the AI didn't reply in the agent's format " r.badFormat " times in a row")
            return
        }
        AgtAsk(AgtProtoFill(agtTemplates, "format-error", Map("error", p.error)), [], false, "Please use the format")
        return
    }
    r.badFormat := 0
    if (p.count > 1)
        r.note := AgtProtoFill(agtTemplates, "several", Map("count", p.count))
    if (p.kind = "final") {
        AgtEntry("AI", "Finished: " p.text, p.text)
        AgtEnd("done", "")
        return
    }
    call := {name: p.name, args: p.args, why: p.why, step: r.step + 1}
    AgtEntry("AI", "Wants " p.name " " AgtProtoJson(p.args) (p.why != "" ? " - " p.why : ""), text)
    r.step += 1
    if (r.step > AgtNum("MaxSteps")) {
        AgtEnd("stopped", "the step limit (" AgtNum("MaxSteps") " tool calls, MaxSteps) was reached")
        return
    }
    if !agtTools.Has(p.name) {
        names := ""
        for n in agtTools
            names .= (names = "" ? "" : ", ") n
        AgtToolError(call, 'there is no tool called "' p.name '". The tools are: ' names)
        return
    }
    tool := agtTools[p.name]
    call.name := tool.name
    if ((err := AgtToolsCheckArgs(tool, p.args)) != "") {
        AgtToolError(call, err)
        return
    }
    if (tool.approval = "ask" && !r.allow.Has(tool.name))
        AgtAskApproval(call, tool)
    else
        AgtRunTool(call)
}

AgtAskApproval(call, tool) {
    r := agtRun
    r.status := "approval"
    r.pending := call
    args := AgtProtoJson(call.args)
    AgtShow(false)                               ; your OK is needed: the window comes up (without the focus)
    agtGui["Ask"].Value := "The AI wants to: " tool.title " (" call.name ")" (args != "{}" ? "  " (StrLen(args) > 160 ? SubStr(args, 1, 160) "..." : args) : "")
        . (call.why != "" ? "`nWhy: " call.why : "")
    AgtRefresh()
    try agtGui.Flash()
    try agtGui["Allow"].Focus()
    DbgTrace("agent", "task " r.id " asks your OK for " call.name)
}

AgtApprove(how) {
    r := agtRun
    if (!AgtActive() || r.status != "approval" || !IsObject(r.pending))
        return
    call := r.pending
    if (how = "deny") {
        AgtEntry("You", "Denied " call.name)
        AgtLog("task " r.id ": " call.name " denied")
        AgtAsk(AgtProtoFill(agtTemplates, "denied", Map("tool", call.name, "step", call.step, "maxSteps", AgtNum("MaxSteps"))),
            [], false, "Denied " call.name)
        return
    }
    if (how = "task")
        r.allow[call.name] := true
    AgtEntry("You", "Allowed " call.name (how = "task" ? " (for this task)" : ""))
    AgtRunTool(call)
}

AgtRunTool(call) {
    r := agtRun
    r.status := "tool"
    r.pending := call
    AgtRefresh()
    tool := agtTools[call.name]
    ctx := {runId: r.id, step: call.step, folders: AgtFolders(), readMaxKB: AgtNum("ReadMaxKB"),
        shotMaxSide: AgtNum("ScreenshotMaxSide"), imageDir: APP_IMAGE_INBOX}
    t0 := A_TickCount
    try {
        res := tool.handler.Call(call.args, ctx)
    } catch as err {
        AgtLog("task " r.id ": " call.name " failed after " (A_TickCount - t0) " ms")
        if (agtRun = r && r.status = "tool")
            AgtToolError(call, err.Message)
        return
    }
    ms := A_TickCount - t0
    text := (res is Map) ? res.Get("text", "") : String(res)
    imgs := (res is Map && res.Get("images", 0) is Array) ? res["images"] : []
    for f in imgs
        r.files.Push(f)
    if (agtRun != r || r.status != "tool")       ; stopped while it ran
        return
    cut := AgtProtoCut(text, AgtNum("ResultMaxChars"))
    AgtEntry("Tool", call.name " done in " ms " ms" (imgs.Length ? " + " imgs.Length " image(s)" : "")
        . (StrLen(cut) < StrLen(text) ? " (cut to " StrLen(cut) " chars)" : ""), cut)
    AgtLog("task " r.id ": " call.name " ran in " ms " ms (" StrLen(text) " chars, " imgs.Length " image(s))")
    DbgTrace("agent", "task " r.id " tool " call.name " ran in " ms " ms: " StrLen(text) " chars, " imgs.Length " image(s)")
    imgNote := imgs.Length ? " " imgs.Length " image(s) attached." : ""
    AgtAsk(AgtProtoFill(agtTemplates, "result", Map("tool", call.name, "step", call.step, "maxSteps", AgtNum("MaxSteps"),
        "result", cut, "images", imgNote)), imgs, false, "Result of " call.name)
}

AgtToolError(call, err) {
    AgtEntry("Tool", call.name " couldn't run: " err, err)
    AgtAsk(AgtProtoFill(agtTemplates, "tool-error", Map("tool", call.name, "step", call.step,
        "maxSteps", AgtNum("MaxSteps"), "error", err)), [], false, "Error from " call.name)
}

AgtStop(why := "you stopped it") {
    r := agtRun
    if !AgtActive()
        return
    o := r.out
    if (IsObject(o) && o.inPool && o.id != "" && (hwnd := WinExist(POOL_WIN)))
        AgtSendTo(hwnd, POOL_TAG, Map("t", "cancel", "id", o.id))
    r.out := 0
    AgtEnd("stopped", why)
}

AgtEnd(status, why) {
    global agtContactIdleAt
    r := agtRun
    if !IsObject(r)
        return
    r.status := status
    r.endWhy := why
    r.endedAt := A_TickCount
    r.out := 0
    r.pending := 0
    if (status != "done")
        AgtEntry("Agent", (status = "failed" ? "Failed: " : "Stopped: ") why)
    secs := Round((r.endedAt - r.startedAt) / 1000)
    AgtLog("task " r.id " " status " after " r.step " tool call(s), " secs " s" (why != "" ? " - " why : ""))
    DbgTrace("agent", "task " r.id " " status " after " r.step " tool call(s), " secs " s")
    for f in r.files
        try FileDelete(f)
    r.files := []
    agtContactIdleAt := A_TickCount
    AgtRefresh()
}

; Every second: the time limit, the status line, the pool-contact window's end
AgtWatch() {
    global agtContact
    if AgtActive() {
        if (A_TickCount - agtRun.startedAt > AgtNum("RunMaxMin") * 60000)
            AgtStop("the time limit (" AgtNum("RunMaxMin") " min, RunMaxMin) was reached")
        else
            try agtGui["Status"].Value := AgtStatusText()
    } else if (IsObject(agtContact) && A_TickCount - agtContactIdleAt > AgtNum("ContactKeepSec") * 1000) {
        try agtContact.Destroy()
        agtContact := 0
    }
}

; ==============================================================================
; The Copilot pool
; ==============================================================================
; The hidden window the pool talks to: only while there's a task (and ContactKeepSec after), so the pool
; isn't kept running by an agent that sits idle
AgtPoolContact() {
    global agtContact, agtContactIdleAt
    if !IsObject(agtContact) {
        agtContact := Gui("+ToolWindow", AGT_CONTACT_TITLE)
        agtContact.Show("Hide w10 h10")
    }
    agtContactIdleAt := A_TickCount
    return agtContact.Hwnd
}

AgtStartPool() {
    static last := 0
    if (A_TickCount - last < 15000)
        return
    last := A_TickCount
    AgtLog("the Copilot pool isn't running - starting it")
    path := A_ScriptDir "\copilot-pool.ahk"
    if FileExist(path)
        try Run(Format('"{}" "{}" /background', A_AhkPath, path), A_ScriptDir)
}

AgtOnCopyData(wParam, lParam, msg, hwnd) {
    if !((IsObject(agtMain) && hwnd = agtMain.Hwnd) || (IsObject(agtContact) && hwnd = agtContact.Hwnd))
        return
    try {
        tag := NumGet(lParam, 0, "UPtr")
        if (tag != AGT_TAG && tag != POOL_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(AgtHandle.Bind(tag, text), -1)
    return true
}

AgtHandle(tag, text) {
    global agtPool
    try {
        m := Json.Parse(text)
        if !(m is Map)
            return
        t := m.Get("t", "")
        if (tag = AGT_TAG) {
            switch t {
                case "show": AgtShow()
                case "quit": ExitApp()
            }
            return
        }
        if (t = "state") {
            agtPool := m
            AgtCheckChatWindow(m)
            AgtRefresh()
            return
        }
        r := agtRun
        if (!AgtActive() || !IsObject(r.out) || m.Get("id", "") != r.out.id)
            return                               ; about an older message (e.g. one you stopped)
        switch t {
            case "sent":
                r.out.sent := true
                AgtRefresh()
            case "done":
                AgtOnDone(m)
        }
    } catch as err {
        AgtLog("ERROR (message): " err.Message)
    }
}

; Closing the AI's chat window during a task = the AI forgot it: the task ends
AgtCheckChatWindow(m) {
    if (!AgtActive() || !AgtNum("ShowChat"))
        return
    open := false
    wins := m.Get("windows", [])
    if (wins is Array)
        for c in wins
            if (c = AgtSetting("Conversation"))
                open := true
    if open
        agtRun.sawWindow := true
    else if agtRun.sawWindow
        AgtStop("you closed the AI's chat window, so it no longer knows this task")
}

AgtSendTo(hwnd, tag, obj) {
    msg := Json.Stringify(obj)
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", tag, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(0x4A, 0, cds, , Integer(hwnd), , , , 3000)
        return true
    }
    return false
}

; ==============================================================================
; Settings, log, errors
; ==============================================================================
AgtSetting(key) {
    def := AGT_DEFAULTS.Has(key) ? AGT_DEFAULTS[key] : ""
    try return IniRead(AGT_INI, "Settings", key, def)
    return def
}

AgtNum(key) {
    v := AgtSetting(key)
    return IsNumber(v) ? Number(v) : (AGT_DEFAULTS.Has(key) && IsNumber(AGT_DEFAULTS[key]) ? AGT_DEFAULTS[key] : 0)
}

AgtIni(section, key, def := "") {
    try return IniRead(AGT_INI, section, key, def)
    return def
}

AgtIniSection(section) {
    m := Map()
    m.CaseSense := false
    try {
        for line in StrSplit(IniRead(AGT_INI, section), "`n", "`r")
            if RegExMatch(line, "^\s*([^=;]+?)\s*=\s*(.*?)\s*$", &x)
                m[x[1]] := x[2]
    }
    return m
}

; AllowedFolders: separated by |, %VARIABLES% expanded, no trailing backslash
AgtFolders() {
    out := []
    for f in StrSplit(AgtSetting("AllowedFolders"), "|") {
        f := Trim(f, " `t`"")
        if (f = "")
            continue
        n := DllCall("ExpandEnvironmentStringsW", "WStr", f, "Ptr", 0, "UInt", 0, "UInt")
        if n {
            buf := Buffer(n * 2 + 2, 0)
            DllCall("ExpandEnvironmentStringsW", "WStr", f, "Ptr", buf, "UInt", n, "UInt")
            f := StrGet(buf, "UTF-16")
        }
        out.Push(RTrim(f, "\"))
    }
    return out
}

; Screenshots left from an earlier run (the agent deletes its own at the end of each task)
AgtCleanImages() {
    try {
        Loop Files APP_IMAGE_INBOX "\agent-*.png"
            try FileDelete(A_LoopFileFullPath)
    }
}

AgtLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", AGT_LOG, "UTF-8")
}

AgtTrimLog() {
    try {
        if (FileExist(AGT_LOG) && FileGetSize(AGT_LOG) > 512 * 1024)
            FileMove(AGT_LOG, DATA_DIR "\agent.old.log", true)
    }
}

AgtOnError(err, mode) {
    static inside := false
    try AgtLog("ERROR: " err.Message " (" err.What ", line " err.Line ")")
    if (!inside && AgtActive()) {                ; never leave a task hanging half-way
        inside := true
        try AgtStop("something went wrong in the agent (" err.Message ")")
        inside := false
    }
    return 1                                     ; keep running
}

AgtOnExit(*) {
    try AgtStop("the agent closed")
}
