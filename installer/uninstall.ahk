#Requires AutoHotkey v2.0
#SingleInstance Force
try DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", "CaptionCompanion.Uninstall")

; ==============================================================================
; uninstall.ahk  -  removes Live Caption Companion for the current Windows user.
; Started by Uninstall.bat, which first copies this script and AutoHotkey32.exe to
; a temp folder, so the install folder can be deleted while this runs.
; Self-contained on purpose (no #Include): the .bat + this file can be copied alone
; to any PC that has the app installed.
;
;   Uninstall.bat                 asks first, then removes everything
;   Uninstall.bat /silent         no windows; removes everything INCLUDING the data folder
;   Uninstall.bat /silent /keepdata   no windows; keeps data\ (call history, helpers, settings)
;
; What it removes (nothing outside the user's own folders, no admin rights needed):
;   * the install folder (%LOCALAPPDATA%\CaptionCompanion or %USERPROFILE%\CaptionCompanion,
;     or the folder the Desktop / Start menu shortcut points to)
;   * the Desktop, Start menu and Startup shortcuts that point into it
;   * the built-in browser sign-in and screenshot folders in %LOCALAPPDATA%\CaptionCompanion
;   * temp files the app left in %TEMP%
; Result (also for /silent) is logged in %TEMP%\CaptionCompanion-uninstall.log.
; Exit code: 0 = done, 1 = something couldn't be removed.
; ==============================================================================

TITLE := "Uninstall Live Caption Companion"
SHORTCUT_NAME := "Live Caption Companion"
DEFAULT_ROOT := EnvGet("LOCALAPPDATA") "\CaptionCompanion"
FALLBACK_ROOT := EnvGet("USERPROFILE") "\CaptionCompanion"
LOG_FILE := A_Temp "\CaptionCompanion-uninstall.log"

silent := false
keepData := false
for arg in A_Args {
    switch StrLower(arg) {
        case "/silent": silent := true
        case "/keepdata": keepData := true
    }
}

ExitApp(UnMain())

UnMain() {
    mode := silent ? "silent" : "window"
    if keepData
        mode .= ", keep data"
    UnLog("Uninstall started (" mode ")")

    roots := UnFindRoots()
    if (roots.Length = 0 && !silent) {
        if (MsgBox("Live Caption Companion doesn't seem to be installed for this Windows user.`n`n"
            . "If you put it in a folder of your own, click Yes and pick that folder.", TITLE, "YesNo Icon!") = "Yes") {
            sel := RTrim(DirSelect("*" EnvGet("LOCALAPPDATA"), 0, "Pick the Live Caption Companion folder (the one with install.ini in it)"), "\")
            if (sel != "") {
                if UnIsInstall(sel) {
                    roots.Push(sel)
                } else {
                    MsgBox("That folder isn't a Live Caption Companion install (no install.ini in it), so nothing was removed.`n`n" sel, TITLE, "Icon!")
                    return 1
                }
            }
        }
    }

    deleteData := !keepData
    if (!silent && roots.Length) {
        ans := UnAsk(roots)
        if !ans.go {
            UnLog("Cancelled")
            return 0
        }
        deleteData := ans.del
    }

    problems := []
    UnStopEverything(roots)
    UnRemoveShortcuts(roots)
    for root in roots {
        left := UnRemoveRoot(root, deleteData)
        if (left != "")
            problems.Push(left)
    }
    UnRemoveLocalLeftovers(roots)
    UnRemoveTemp()

    if (roots.Length = 0) {
        msg := "Nothing was installed here. Any leftover shortcuts and temp files were cleaned up."
    } else {
        msg := "Live Caption Companion was removed from this PC."
        if !deleteData {
            msg .= "`n`nYour call history, helpers and settings were kept in:"
            for root in roots
                msg .= "`n" root "\data"
        }
    }
    if problems.Length {
        msg .= "`n`nSome things couldn't be removed (something in that folder may still be open - close it and run this again):"
        for p in problems
            msg .= "`n- " p
    }
    UnLog(StrReplace(msg, "`n", " | "))
    if !silent
        MsgBox(msg, TITLE, problems.Length ? "Icon!" : "Iconi")
    return problems.Length ? 1 : 0
}

; ==============================================================================
; Window
; ==============================================================================
UnAsk(roots) {
    st := {go: false, del: false, done: false}
    g := Gui("-MinimizeBox", TITLE)
    g.SetFont("s13 bold", "Segoe UI")
    g.Add("Text", "w470 h28", "Live Caption Companion")
    g.SetFont("s10 norm")
    txt := "This closes the companion and removes it from this PC:"
    for r in roots
        txt .= "`n" r
    g.Add("Text", "w470 y+8", txt)
    ck := g.Add("Checkbox", "xm y+16 w470", "Also delete my call history, helpers and settings (can't be undone)")
    g.Add("Text", "xm y+4 w470 h36 c666666", "Leave it unticked to keep them: they stay in the data folder, and a later install picks them up again.")
    btnGo := g.Add("Button", "xm y+14 w130 Default", "Uninstall")
    btnNo := g.Add("Button", "x+10 w90", "Cancel")

    Go(*) {
        st.go := true
        st.del := ck.Value ? true : false
        st.done := true
    }
    Stop(*) {
        st.done := true
    }
    btnGo.OnEvent("Click", Go)
    btnNo.OnEvent("Click", Stop)
    g.OnEvent("Close", Stop)
    g.Show()
    while !st.done
        Sleep(50)
    g.Destroy()
    return st
}

; ==============================================================================
; Finding the install
; ==============================================================================
UnIsInstall(dir) {
    return (FileExist(dir "\install.ini") != "" && !DirExist(dir "\.git")) ? true : false
}

UnAddRoot(roots, r) {
    r := RTrim(r, "\")
    if !UnIsInstall(r)
        return
    for x in roots {
        if (StrLower(x) = StrLower(r))
            return
    }
    roots.Push(r)
}

; The default folders, plus wherever the shortcuts point (a folder picked in Setup)
UnFindRoots() {
    roots := []
    for r in [DEFAULT_ROOT, FALLBACK_ROOT]
        UnAddRoot(roots, r)
    for lnk in UnShortcutFiles() {
        target := ""
        try FileGetShortcut(lnk, &target)
        if RegExMatch(target, "i)^(.+)\\runtime\\AutoHotkey32\.exe$", &m)
            UnAddRoot(roots, m[1])
    }
    return roots
}

UnShortcutFiles() {
    list := []
    for dir in [A_Desktop, A_Programs, A_Startup] {
        Loop Files dir "\*.lnk"
            list.Push(A_LoopFileFullPath)
    }
    return list
}

; ==============================================================================
; Closing the app
; ==============================================================================
; Asks every script of the app to close (the companion saves the call as it exits),
; then ends whatever is still running from the install: AutoHotkey, its built-in
; browsers (msedgewebview2) and the speech helper (powershell) - only ones whose
; command line or program lives in our folders.
UnStopEverything(roots) {
    paths := []
    for r in roots
        paths.Push(r)
    paths.Push(DEFAULT_ROOT)

    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    wins := []
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        if (hwnd = A_ScriptHwnd)
            continue
        title := ""
        try title := WinGetTitle(hwnd)
        for p in paths {
            if (InStr(title, p "\") = 1) {
                wins.Push(hwnd)
                try WinClose(hwnd)
                break
            }
        }
    }
    deadline := A_TickCount + 10000
    for hwnd in wins {
        while (WinExist("ahk_id " hwnd) && A_TickCount < deadline)
            Sleep(100)
    }
    DetectHiddenWindows(prev)

    ended := 0
    try {
        wmi := ComObjGet("winmgmts:\\.\root\cimv2")
        me := ProcessExist()
        for proc in wmi.ExecQuery("SELECT ProcessId, Name, CommandLine, ExecutablePath FROM Win32_Process") {
            if (proc.ProcessId = me)
                continue
            name := ""
            cl := ""
            ep := ""
            try name := StrLower(proc.Name)
            try cl := proc.CommandLine
            try ep := proc.ExecutablePath
            if (name = "cmd.exe" || name = "conhost.exe" || name = "explorer.exe")
                continue                         ; never the window that started us
            hay := StrLower(cl " " ep)
            for p in paths {
                if InStr(hay, StrLower(p "\")) {
                    try {
                        ProcessClose(proc.ProcessId)
                        ended += 1
                    }
                    break
                }
            }
        }
    }
    if ended
        UnLog("Ended " ended " process(es) that were still running")
    Sleep(1500)                                  ; let Windows let go of the files
}

; ==============================================================================
; Removing
; ==============================================================================
UnRemoveShortcuts(roots) {
    doomed := []
    for lnk in UnShortcutFiles() {
        target := ""
        try FileGetShortcut(lnk, &target)
        if (target = "")
            continue
        SplitPath(lnk, &file)
        hit := false
        for r in roots {
            if (InStr(target, r "\") = 1)
                hit := true
        }
        ; our own shortcut whose app is already gone (folder deleted by hand)
        if (!hit && StrLower(file) = StrLower(SHORTCUT_NAME ".lnk") && !FileExist(target))
            hit := true
        if hit
            doomed.Push(lnk)
    }
    for lnk in doomed {
        try FileDelete(lnk)
        UnLog("Removed shortcut " lnk)
    }
}

; Returns "" when done, or a plain-language note about what is left
UnRemoveRoot(root, deleteData) {
    if (StrLen(root) < 6 || DirExist(root "\.git"))
        return "Skipped, it doesn't look like an install: " root
    if deleteData {
        if !UnDeletePath(root, true)
            return root
        UnLog("Removed " root)
        return ""
    }
    ; keep data\ : remove everything else (install.ini goes too, so it's no longer "installed")
    items := []
    Loop Files root "\*", "FD" {
        isDir := InStr(A_LoopFileAttrib, "D") ? true : false
        if (isDir && StrLower(A_LoopFileName) = "data")
            continue
        items.Push({path: A_LoopFileFullPath, dir: isDir})
    }
    left := ""
    for it in items {
        if !UnDeletePath(it.path, it.dir)
            left .= (left = "" ? "" : ", ") it.path
    }
    UnLog("Removed " root " (data kept)")
    return left
}

UnDeletePath(path, isDir) {
    Loop 12 {
        try {
            if isDir {
                FileSetAttrib("-R", path "\*.*", "FDR")
                DirDelete(path, true)
            } else {
                FileSetAttrib("-R", path)
                FileDelete(path)
            }
        }
        if !(isDir ? DirExist(path) : FileExist(path))
            return true
        Sleep(500)
    }
    return false
}

; When the app lived in %USERPROFILE%\CaptionCompanion (or a folder of the user's choice), its
; built-in browser sign-in and screenshots were still kept in %LOCALAPPDATA%\CaptionCompanion.
; Only those folders go - never anything else that might be there (e.g. a kept data\).
UnRemoveLocalLeftovers(roots) {
    for r in roots {
        if (StrLower(r) = StrLower(DEFAULT_ROOT))
            return                               ; that folder was handled as the install itself
    }
    if !DirExist(DEFAULT_ROOT)
        return
    for pat in ["copilot-pool-web*", "screen-ask*", "pool-images", "webview-probe*"] {
        dirs := []
        Loop Files DEFAULT_ROOT "\" pat, "D"
            dirs.Push(A_LoopFileFullPath)
        for d in dirs
            UnDeletePath(d, true)
    }
    try DirDelete(DEFAULT_ROOT)                  ; only works if it is now empty
}

UnRemoveTemp() {
    try DirDelete(A_Temp "\live-captions-companion", true)
    try FileDelete(A_Temp "\caption-companion-setup-probe.ahk")
    try FileDelete(A_Temp "\wheel-debug.log")
    files := []
    Loop Files A_Temp "\agent-listen-*.txt"
        files.Push(A_LoopFileFullPath)
    for f in files
        try FileDelete(f)
}

UnLog(line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", LOG_FILE, "UTF-8")
}
