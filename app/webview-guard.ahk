; ==============================================================================
; webview-guard.ahk  -  keeps the apps' built-in browsers (WebView2) in check (prefix Wvg*)
;
; Used by the Companion, the Copilot pool and Screen ask. Each built-in browser is a family of
; msedgewebview2.exe processes (browser, GPU, one renderer per page, ...) started for one of our
; folders in APP_LOCAL. They must never outlive the app that started them, and never grow without limit.
;
; * WvgEnvMB(env)      - memory of one browser engine (all its processes), in MB (private memory)
; * WvgSweepOrphans()  - ends OUR browser engines whose app is gone (their parent isn't a running
;                        AutoHotkey). Only engines started for a folder in APP_LOCAL: Edge, Teams,
;                        Windows Search and other programs' WebView2 are never touched.
; * WvgReport()        - "who uses how much": our engines by app + leftovers, as text
; Needs app-paths.ahk (APP_LOCAL). No text from any page is ever read here.
; ==============================================================================

; Private memory of one process in MB (what it really costs; 0 if it's gone)
WvgProcMB(pid) {
    h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")   ; QUERY_LIMITED_INFORMATION
    if !h
        return 0
    size := 8 + 9 * A_PtrSize                    ; PROCESS_MEMORY_COUNTERS_EX
    pmc := Buffer(size, 0)
    NumPut("UInt", size, pmc)
    mb := 0
    if DllCall("psapi\GetProcessMemoryInfo", "Ptr", h, "Ptr", pmc, "UInt", size)
        mb := NumGet(pmc, 8 + 8 * A_PtrSize, "UPtr") / 1048576   ; PrivateUsage
    DllCall("CloseHandle", "Ptr", h)
    return mb
}

; All processes of one browser engine (browser, GPU, renderers, utilities)
WvgEnvPids(env) {
    pids := []
    try {
        for info in env.GetProcessInfos()
            pids.Push(info.ProcessId)
    }
    return pids
}

WvgEnvMB(env) {
    total := 0
    for pid in WvgEnvPids(env)
        total += WvgProcMB(pid)
    return Round(total)
}

; Every msedgewebview2.exe started for one of our folders: [{pid, ppid, browser, dir}]
WvgOurProcesses() {
    list := []
    root := StrLower(APP_LOCAL "\")
    try {
        wmi := ComObjGet("winmgmts:\\.\root\cimv2")
        for p in wmi.ExecQuery("SELECT ProcessId, ParentProcessId, CommandLine FROM Win32_Process WHERE Name='msedgewebview2.exe'") {
            cl := ""
            try cl := p.CommandLine
            if (cl = "" || !InStr(StrLower(cl), root))
                continue
            dir := RegExMatch(cl, 'i)--user-data-dir="?([^"]+?)"?(?:\s--|\s*$)', &m) ? m[1] : ""
            list.Push({pid: p.ProcessId, ppid: p.ParentProcessId, browser: !InStr(cl, "--type="), dir: dir})
        }
    }
    return list
}

; Which of our apps a browser folder belongs to
WvgAppOf(dir) {
    d := StrLower(dir)
    if InStr(d, "\copilot-pool-web\")
        return "Copilot pool"
    if InStr(d, "\screen-ask-web")
        return "Screen ask"
    if InStr(d, "\webview-probe") || InStr(d, "probe")
        return "test probe"
    return "other (" dir ")"
}

; A browser engine is a leftover when the app that started it (its parent) is gone. Then it's ended
; (its other processes end with it). Returns how many were ended, and their memory.
WvgSweepOrphans(&freedMB := 0) {
    freedMB := 0, n := 0
    all := WvgOurProcesses()
    for p in all {
        if !p.browser
            continue
        parent := ""
        try parent := ProcessGetName(p.ppid)
        if (parent != "" && InStr(parent, "AutoHotkey"))
            continue                             ; its app is still running
        mb := 0
        for q in all                             ; the whole family's memory (for the log)
            if (q.dir = p.dir)
                mb += WvgProcMB(q.pid)
        try {
            ProcessClose(p.pid)
            n += 1, freedMB += Round(mb)
        }
    }
    return n
}

; Text for "who uses how much" (Companion tray, pool window)
WvgReport() {
    groups := Map()
    for p in WvgOurProcesses() {
        app := WvgAppOf(p.dir)
        if !groups.Has(app)
            groups[app] := {mb: 0, procs: 0, orphan: false}
        g := groups[app]
        g.mb += WvgProcMB(p.pid), g.procs += 1
        if p.browser {
            parent := ""
            try parent := ProcessGetName(p.ppid)
            if !(parent != "" && InStr(parent, "AutoHotkey"))
                g.orphan := true
        }
    }
    if !groups.Count
        return "No built-in browser of these apps is running."
    out := "", total := 0
    for app, g in groups {
        out .= app ": " Round(g.mb) " MB (" g.procs " processes)" (g.orphan ? " - LEFTOVER, its app is closed" : "") "`n"
        total += g.mb
    }
    return out "Total: " Round(total) " MB"
}
