; ==============================================================================
; package-lib.ahk  -  shared by the companion, updater.ahk, installer\setup.ahk
; and tools\release.ahk: versions, download links, zips, swapping app folders.
;
; Only defines functions and constants, so including it changes nothing on its
; own. The script that includes it must also include Json.ahk.
; ==============================================================================

PKG_MAIN_SCRIPT := "liveCaptionCompanion.ahk"

; Files that belong to the agent (data\), never to the app (app\)
PKG_DATA_FILES := ["call-history.json", "call-history.backup.json", "call-helpers.json"
    , "call-helpers.backup.json", "live-captions.ini", "copilot-targets.ini"]

; ------------------------------------------------------------------------------
; Versions: dates like 2026.10.28, with an optional .2 / .3 for same-day fixes
; ------------------------------------------------------------------------------
PkgReadVersion(appDir) {
    try return Trim(FileRead(appDir "\version.txt", "UTF-8"), " `t`r`n")
    return "dev"
}

; 1 if a is newer than b, -1 if older, 0 if the same
PkgCompareVersions(a, b) {
    pa := StrSplit(Trim(a), ".")
    pb := StrSplit(Trim(b), ".")
    Loop Max(pa.Length, pb.Length) {
        x := (A_Index <= pa.Length && IsInteger(pa[A_Index])) ? Integer(pa[A_Index]) : 0
        y := (A_Index <= pb.Length && IsInteger(pb[A_Index])) ? Integer(pb[A_Index]) : 0
        if (x != y)
            return x > y ? 1 : -1
    }
    return 0
}

PkgIsValidVersion(v) {
    return RegExMatch(v, "^\d{4}\.\d{1,2}\.\d{1,2}(\.\d+)?$") ? true : false
}

; ------------------------------------------------------------------------------
; Fetching: Google Drive share links, any http(s) link, or a file/network path
; ------------------------------------------------------------------------------

; "https://drive.google.com/file/d/<id>/view?usp=sharing" -> direct download link.
; Anything else (another site, \\server\share\...) is returned unchanged.
PkgDirectUrl(link) {
    link := Trim(link)
    if RegExMatch(link, "i)drive\.google\.com/.*?(?:/d/|[?&]id=)([\w-]{20,})", &m)
        return "https://drive.google.com/uc?export=download&id=" m[1]
    return link
}

PkgFetch(src, dest) {
    try FileDelete(dest)
    if RegExMatch(src, "i)^https?://") {
        ; never answer from Windows' download cache - we want the latest file
        try DllCall("wininet\DeleteUrlCacheEntryW", "Str", src)
        Download(src, dest)
    } else {
        FileCopy(src, dest, true)
    }
    if !FileExist(dest)
        throw Error("nothing was downloaded")
}

PkgLooksLikeZip(path) {
    try {
        f := FileOpen(path, "r")
        sig := f.ReadUShort()
        f.Close()
        return sig = 0x4B50                      ; "PK"
    }
    return false
}

; ------------------------------------------------------------------------------
; Zips. tar.exe ships with Windows 10/11; Explorer's zip support is the fallback.
; ------------------------------------------------------------------------------
PkgExtractZip(zip, dest) {
    PkgResetDir(dest)
    tar := PkgSystemTool("tar.exe")
    if (tar != "") {
        try {
            if (RunWait(Format('"{}" -x -f "{}" -C "{}"', tar, zip, dest), , "Hide") = 0)
                return
        }
        PkgResetDir(dest)
    }
    sh := ComObject("Shell.Application")
    src := sh.NameSpace(zip)
    if !IsObject(src)
        throw Error("the zip could not be opened")
    sh.NameSpace(dest).CopyHere(src.Items(), 4 | 16 | 512 | 1024)   ; silent, yes to all
    PkgWaitUntilStill(dest)                                        ; it can return early
}

; Waits until a folder has files and its file count stops changing (max 60 s)
PkgWaitUntilStill(dir) {
    last := -1
    still := 0
    deadline := A_TickCount + 60000
    while (A_TickCount < deadline) {
        n := 0
        Loop Files dir "\*", "FR"
            n += 1
        still := (n > 0 && n = last) ? still + 1 : 0
        if (still >= 3)
            return
        last := n
        Sleep(500)
    }
}

PkgCreateZip(folder, zip) {
    try FileDelete(zip)
    SplitPath(folder, &name, &parent)
    tar := PkgSystemTool("tar.exe")
    if (tar != "")
        try RunWait(Format('"{}" -a -c -f "{}" -C "{}" "{}"', tar, zip, parent, name), , "Hide")
    if !PkgLooksLikeZip(zip) {
        ps := PkgSystemTool("WindowsPowerShell\v1.0\powershell.exe")
        if (ps != "")
            try RunWait(Format('"{}" -NoProfile -Command "Compress-Archive -LiteralPath {} -DestinationPath {} -Force"'
                , ps, PkgPsQuote(folder), PkgPsQuote(zip)), , "Hide")
    }
    if !PkgLooksLikeZip(zip)
        throw Error("could not create the zip")
}

; A path as a PowerShell literal: 'C:\it''s here'
PkgPsQuote(s) => "'" StrReplace(s, "'", "''") "'"

; A 32-bit AutoHotkey sees System32 redirected; Sysnative is the real one
PkgSystemTool(relPath) {
    for dir in [A_WinDir "\Sysnative", A_WinDir "\System32"]
        if FileExist(dir "\" relPath)
            return dir "\" relPath
    return ""
}

; The folder that holds app\liveCaptionCompanion.ahk: dir itself or one level down
PkgFindPackageRoot(dir) {
    if FileExist(dir "\app\" PKG_MAIN_SCRIPT)
        return dir
    Loop Files dir "\*", "D"
        if FileExist(A_LoopFileFullPath "\app\" PKG_MAIN_SCRIPT)
            return A_LoopFileFullPath
    return ""
}

; ------------------------------------------------------------------------------
; Swapping app folders. <root>\app.old always holds the version before.
; Each returns "" on success, or a plain-language reason.
; ------------------------------------------------------------------------------
PkgSwapApp(root, newApp) {
    app := root "\app"
    old := root "\app.old"
    if DirExist(old) {
        try DirDelete(old, true)
        if DirExist(old)
            return "the previous-version folder (app.old) is in use"
    }
    if (DirExist(app) && !PkgRetry(() => DirMove(app, old)))
        return "the app folder is in use - close the companion and any Explorer window showing that folder"
    if !PkgRetry(() => DirMove(newApp, app)) {
        if DirExist(old)
            PkgRetry(() => DirMove(old, app))    ; put the working version back
        return "the new version could not be put in place"
    }
    return ""
}

; Swaps app and app.old, so running it twice goes back to where you started
PkgRollbackApp(root) {
    app := root "\app"
    old := root "\app.old"
    tmp := root "\app.swap"
    if !FileExist(old "\" PKG_MAIN_SCRIPT)
        return "there is no previous version to go back to"
    try DirDelete(tmp, true)
    if !PkgRetry(() => DirMove(app, tmp))
        return "the app folder is in use - close the companion and any Explorer window showing that folder"
    if !PkgRetry(() => DirMove(old, app)) {
        PkgRetry(() => DirMove(tmp, app))
        return "the previous version could not be put in place"
    }
    PkgRetry(() => DirMove(tmp, old))
    return ""
}

; Antivirus or a closing process can hold a folder for a moment
PkgRetry(fn, tries := 20, waitMs := 500) {
    Loop tries {
        try {
            fn()
            return true
        }
        Sleep(waitMs)
    }
    return false
}

PkgResetDir(dir) {
    try DirDelete(dir, true)
    DirCreate(dir)
}

; ------------------------------------------------------------------------------
; Running copies. Every AutoHotkey script has a hidden window titled with its
; full path, so this finds the companion and caller-watch run from a folder.
; names: only these script files (default: every script in the folder).
; Returns true when none are left running.
; ------------------------------------------------------------------------------
PkgCloseScriptsIn(dir, names := "", timeoutMs := 15000) {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    prefix := RTrim(dir, "\") "\"
    found := []
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        if (hwnd = A_ScriptHwnd)
            continue
        title := ""
        try title := WinGetTitle(hwnd)
        if PkgTitleMatches(title, prefix, names) {
            found.Push(hwnd)
            try WinClose(hwnd)                   ; the companion saves the call as it exits
        }
    }
    deadline := A_TickCount + timeoutMs
    left := 0
    for hwnd in found {
        while (WinExist(hwnd) && A_TickCount < deadline)
            Sleep(100)
        if WinExist(hwnd)
            left += 1
    }
    DetectHiddenWindows(prev)
    return left = 0
}

; Script window titles look like "C:\path\script.ahk - AutoHotkey v2.0.31"
PkgTitleMatches(title, prefix, names) {
    if (InStr(title, prefix) != 1)
        return false
    if !IsObject(names)
        return true
    for name in names
        if (InStr(title, prefix name " - ") = 1)
            return true
    return false
}

; ------------------------------------------------------------------------------
; Small files
; ------------------------------------------------------------------------------
PkgReadJson(path) {
    try return Json.Parse(FileRead(path, "UTF-8"))
    return ""
}

PkgWriteJson(path, obj) {
    tmp := path ".tmp"
    try FileDelete(tmp)
    FileAppend(Json.Stringify(obj), tmp, "UTF-8")
    FileMove(tmp, path, true)
}

PkgWriteText(path, text) {
    f := FileOpen(path, "w", "UTF-8-RAW")
    f.Write(text)
    f.Close()
}

PkgLog(path, line) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", path, "UTF-8")
}
