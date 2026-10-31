#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include Json.ahk
#Include package-lib.ahk

; ==============================================================================
; updater.ahk  -  started by the companion (updates.ahk), always as its own
; process, so a slow or blocked network can never freeze captions.
;
;   check    <manifestUrl> <currentVersion> <updateDir>   -> status.json
;   download <updateDir>                                  -> download.json
;   apply    <root> <updateDir> <companionPid>            -> last-result.json
;   rollback <root> <updateDir> <companionPid>            -> last-result.json
;
; apply/rollback wait for the companion to close, swap <root>\app with the new
; (or previous) version, and start the companion again. If the swap fails, the
; working version is put back and started instead.
; ==============================================================================

UpdaterMain()
ExitApp()

UpdaterMain() {
    switch UpdaterArg(1) {
        case "check":    UpdaterCheck(UpdaterArg(2), UpdaterArg(3), UpdaterArg(4))
        case "download": UpdaterDownload(UpdaterArg(2))
        case "apply":    UpdaterSwap("apply", UpdaterArg(2), UpdaterArg(3), UpdaterArg(4))
        case "rollback": UpdaterSwap("rollback", UpdaterArg(2), UpdaterArg(3), UpdaterArg(4))
        default:
            MsgBox("This is Live Caption Companion's updater.`nThe companion starts it when needed - there's no need to run it yourself."
                , "Updater", "Iconi")
    }
}

UpdaterArg(i) => (A_Args.Length >= i) ? A_Args[i] : ""

; ------------------------------------------------------------------------------
UpdaterCheck(manifestUrl, current, updDir) {
    DirCreate(updDir)
    st := Map("checkedAt", A_Now, "current", current, "ok", 0
        , "latest", "", "zip", "", "notes", "", "error", "")
    try {
        tmp := updDir "\manifest.download"
        PkgFetch(PkgDirectUrl(manifestUrl), tmp)
        try {
            m := Json.Parse(FileRead(tmp, "UTF-8"))
        } catch {
            throw Error("the update link didn't return version info - check that version.json is shared as 'Anyone with the link'")
        }
        if !(m is Map) || Trim(m.Get("version", "")) = ""
            throw Error("version.json has no version in it")
        notes := m.Get("notes", "")
        st["latest"] := Trim(m["version"])
        st["zip"] := Trim(m.Get("zip", ""))
        st["notes"] := (Type(notes) = "String") ? notes : ""
        st["ok"] := 1
        try FileDelete(tmp)
    } catch as err {
        st["error"] := err.Message
    }
    PkgWriteJson(updDir "\status.json", st)
    PkgLog(updDir "\update.log", "check: " (st["ok"] ? "latest " st["latest"] ", have " current : "FAILED " st["error"]))
}

; ------------------------------------------------------------------------------
UpdaterDownload(updDir) {
    res := Map("ok", 0, "version", "", "appDir", "", "error", "")
    try {
        st := PkgReadJson(updDir "\status.json")
        if !(st is Map) || !st.Get("ok", 0)
            throw Error("check for updates first")
        ver := st["latest"]
        res["version"] := ver
        if (st["zip"] = "")
            throw Error("version.json has no zip link")

        zip := updDir "\package.zip"
        staging := updDir "\staging"
        PkgFetch(PkgDirectUrl(st["zip"]), zip)
        if !PkgLooksLikeZip(zip)
            throw Error("the zip link didn't return a zip file - check that the zip is shared as 'Anyone with the link'")
        PkgExtractZip(zip, staging)

        pkg := PkgFindPackageRoot(staging)
        if (pkg = "")
            throw Error("the zip doesn't contain app\" PKG_MAIN_SCRIPT)
        got := PkgReadVersion(pkg "\app")
        if (got != ver)
            throw Error("the zip holds version " got ", but version.json says " ver)
        res["appDir"] := pkg "\app"
        res["ok"] := 1
        try FileDelete(zip)
    } catch as err {
        res["error"] := err.Message
    }
    PkgWriteJson(updDir "\download.json", res)
    PkgLog(updDir "\update.log", "download: " (res["ok"] ? "ready " res["version"] : "FAILED " res["error"]))
}

; ------------------------------------------------------------------------------
UpdaterSwap(mode, root, updDir, pid) {
    logPath := updDir "\update.log"
    appDir := root "\app"
    from := PkgReadVersion(appDir)
    res := Map("action", mode, "ok", 0, "from", from, "to", "", "error", "", "at", A_Now)

    ; 1) wait for the companion to finish saving and close
    if IsInteger(pid)
        ProcessWaitClose(Integer(pid), 30)
    PkgCloseScriptsIn(appDir)                     ; e.g. caller-watch.ahk

    ; 2) swap folders
    if (mode = "apply") {
        dl := PkgReadJson(updDir "\download.json")
        if !(dl is Map) || !dl.Get("ok", 0) || !FileExist(dl["appDir"] "\" PKG_MAIN_SCRIPT)
            reason := "the downloaded update is missing - download it again"
        else
            reason := PkgSwapApp(root, dl["appDir"])
    } else {
        reason := PkgRollbackApp(root)
    }
    res["to"] := PkgReadVersion(appDir)
    res["ok"] := (reason = "") ? 1 : 0
    res["error"] := reason
    PkgWriteJson(updDir "\last-result.json", res)
    PkgLog(logPath, mode ": " (reason = "" ? from " -> " res["to"] : "FAILED " reason))

    ; 3) tidy up, then start whichever version is in place now
    if (mode = "apply") {
        try DirDelete(updDir "\staging", true)
        try FileDelete(updDir "\download.json")
    }
    try Run(Format('"{}" "{}"', A_AhkPath, appDir "\" PKG_MAIN_SCRIPT), appDir)
    catch as err
        PkgLog(logPath, "could not restart the companion: " err.Message)
}
