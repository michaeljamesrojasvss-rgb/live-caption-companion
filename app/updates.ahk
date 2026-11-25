; ==============================================================================
; updates.ahk  -  "an update is available" for Live Caption Companion
;
; What the agent sees
;   * Nothing, until a newer version is published. It is then downloaded in the
;     background (still nothing on screen). When it's ready and it's a quiet moment
;     (no call, no captions for a minute) a small "Update ready" box asks:
;     Restart now / Ask me later (RemindMinutes, default 10). Later = it asks again
;     after that long. The "⬆ Update" pill top-right stays and opens the full dialog.
;   * The update can't be skipped: when the app is opened and a newer version is
;     there (or found in the first minutes), it installs by itself, no question.
;   * Tray menu > Updates: version, Check for updates, Set update link, Go
;     back to the previous version, Open data folder, Open update log.
;
; Safety rules - the core app must never depend on this file working:
;   * All network and file work runs in updater.ahk, a separate process. A slow
;     or blocked network can't freeze captions.
;   * Nothing installs while 3CX shows a ringing or live call, or captions came in
;     during the last minute. Installing by itself (AutoUpdate=1, the default) only
;     happens when the app is opened; while it's open the person chooses (Restart now).
;     A failed install is never retried by itself within 30 minutes (no restart loops).
;   * The call is saved before the companion closes; the previous version is
;     kept in app.old for "Go back".
;   * Only a copy installed by Setup updates itself, so your repo is never
;     overwritten. In the repo you can still check, to test the link.
;   * Settings: app.ini [Update] (shipped), or live-captions.ini [Update] to
;     override on one PC (handy for testing a different link).
; ==============================================================================

UPD_DIR := DATA_DIR "\update"
UPD_LOG := UPD_DIR "\update.log"
UPD_DEFAULTS := Map("ManifestUrl", "", "CheckHours", 3, "AutoUpdate", 1, "RemindMinutes", 10)
UPD_AUTO_INI := UPD_DIR "\auto.ini"      ; [Auto] LastTry = when the app last installed an update by itself
UPD_PILL_W := 84

updPill := ""
updStatusW := 0             ; the status line's own width, restored when the pill hides
updTrayMenu := ""
updProc := {pid: 0, kind: "", manual: false, started: 0}
updLatest := ""             ; Map from status.json when a newer version exists
updDlg := ""                ; {gui, status, btnUpdate} while the dialog is open
updPrompt := ""             ; {gui, note} while the "Update ready" box is open
updAutoDl := false          ; the running download was started by the app itself (background)
updDlFailAt := 0            ; a background download failed: try again after a while
updStartup := true          ; the first minutes after opening: a newer version installs without asking
updForce := false           ; an update is to be installed by itself, waiting for a quiet moment
updRemindAt := 0            ; "Ask me later": don't show the box before this A_TickCount

; ==============================================================================
; Hooks called from liveCaptionCompanion.ahk
; ==============================================================================
UpdInit() {
    try {
        DirCreate(UPD_DIR)
        A_IconTip := "Live Caption Companion " APP_VERSION
        UpdBuildUi()
        UpdBuildMenu()
        UpdReportLastResult()
        UpdApplyStatus(PkgReadJson(UPD_DIR "\status.json"))    ; result of the last check
        SetTimer(() => UpdStartCheck(false), -1)               ; every start: check right away, once startup is done (non-blocking: runs in updater.ahk)
        SetTimer(UpdAutoCheck, -30 * 60 * 1000)                ; then every CheckHours while it stays open
        SetTimer(UpdStartupApply, -3000)                       ; an update already downloaded: installs now, no question
        SetTimer(UpdEndStartup, -5 * 60 * 1000)
        SetTimer(UpdTick, -30000)                              ; background download + the "Update ready" box
    } catch as err {
        UpdReport(err, "start")
    }
}

; Called from GuiResize
UpdLayout(width, height) {
    if !IsObject(updPill)
        return
    try {
        statusText.GetPos(&sx, &sy, , &sh)
        if updPill.Visible {
            px := width - 10 - UPD_PILL_W
            updPill.Move(px, sy - 2, UPD_PILL_W, 24)
            statusText.Move(, , Max(80, px - sx - 8))
        } else {
            statusText.Move(, , Max(80, width - 10 - sx))
        }
    }
}

; ==============================================================================
; Settings
; ==============================================================================
UpdSetting(key) {
    default := UPD_DEFAULTS.Get(key, "")
    try default := IniRead(APP_DIR "\app.ini", "Update", key, default)
    try return IniRead(MIC_INI, "Update", key, default)
    return default
}

; Saves a link for this PC only (live-captions.ini [Update]), then checks it.
; Releases bake the link into app.ini, so coworkers never need this.
UpdSetLink() {
    myGui.Opt("+OwnDialogs")
    r := InputBox("Paste the Google Drive share link of version.json`n(leave empty to use the link the app shipped with)"
        , "Update link", "w560 h150", UpdSetting("ManifestUrl"))
    if (r.Result != "OK")
        return
    UpdSaveLink(Trim(r.Value))
    UpdStartCheck(true)
}

; "" removes this PC's link, so the one the app shipped with is used again
UpdSaveLink(link) {
    if (link != "")
        IniWrite(link, MIC_INI, "Update", "ManifestUrl")
    if (link = "" && FileExist(MIC_INI))
        IniDelete(MIC_INI, "Update", "ManifestUrl")
}

; ==============================================================================
; UI: pill + tray menu
; ==============================================================================
UpdBuildUi() {
    global updPill, updStatusW
    statusText.GetPos(, , &w)
    updStatusW := w
    updPill := myGui.Add("Text", Format("x0 y0 w{} h24 +0x100 +0x200 Center Hidden Background1D4ED8 cFFFFFF", UPD_PILL_W), "⬆ Update")
    updPill.OnEvent("Click", UpdSafe(UpdShowDialog))
    TipSet(updPill, "A new version is ready: click to see what's new and update")
}

UpdBuildMenu() {
    global updTrayMenu
    m := Menu()
    m.Add("Version " APP_VERSION, (*) => 0)
    m.Disable("Version " APP_VERSION)
    m.Add()
    m.Add("Check for updates", UpdSafe(() => UpdStartCheck(true)))
    m.Add("Set update link…", UpdSafe(UpdSetLink))
    m.Add("Go back to the previous version…", UpdSafe(UpdRollback))
    m.Add()
    m.Add("Open data folder", UpdSafe(() => Run('explorer.exe "' DATA_DIR '"')))
    m.Add("Open update log", UpdSafe(() => Run('notepad.exe "' UPD_LOG '"')))
    m.Add()
    m.Add("Uninstall…", UpdSafe(UninstRun))
    updTrayMenu := m
    A_TrayMenu.Insert("1&")
    A_TrayMenu.Insert("1&", "Updates", m)
    UpdSyncMenu()
}

UpdSyncMenu() {
    if !IsObject(updTrayMenu)
        return
    item := "Go back to the previous version…"
    if (AppIsInstalled() && FileExist(APP_ROOT "\app.old\" PKG_MAIN_SCRIPT))
        updTrayMenu.Enable(item)
    else
        updTrayMenu.Disable(item)
}

UpdShowPill(show) {
    if !IsObject(updPill) || (updPill.Visible = show)
        return
    updPill.Visible := show
    RelayoutMain()
}

; ==============================================================================
; Checking (in updater.ahk)
; ==============================================================================
UpdAutoCheck() {
    try {
        st := PkgReadJson(UPD_DIR "\status.json")
        last := (st is Map) ? st.Get("checkedAt", "") : ""
        hours := 0
        try hours := Integer(UpdSetting("CheckHours"))
        due := (last = "") || !IsInteger(last) || (DateDiff(A_Now, last, "Hours") >= Max(1, hours))
        if due
            UpdStartCheck(false)
    }
    SetTimer(UpdAutoCheck, -30 * 60 * 1000)      ; look again in 30 minutes
}

UpdStartCheck(manual) {
    url := Trim(UpdSetting("ManifestUrl"))
    if (url = "") {
        if manual
            statusText.Text := "Status: no update link set yet (tray > Updates > Set update link)"
        return
    }
    if UpdRunUpdater("check", [url, APP_VERSION, UPD_DIR], manual) && manual
        statusText.Text := "Status: checking for updates..."
}

; Starts updater.ahk. Returns false when it is already busy.
UpdRunUpdater(kind, args, manual := false) {
    global updProc
    if updProc.pid {
        if manual
            statusText.Text := "Status: the updater is already working - one moment"
        return false
    }
    cmd := Format('"{}" "{}" {}', A_AhkPath, APP_DIR "\updater.ahk", kind)
    for a in args
        cmd .= ' "' RTrim(a, "\") '"'
    Run(cmd, UPD_DIR, , &pid)
    updProc := {pid: pid, kind: kind, manual: manual, started: A_TickCount}
    SetTimer(UpdPoll, 400)
    return true
}

UpdPoll() {
    global updProc
    p := updProc
    if ProcessExist(p.pid) {
        if (A_TickCount - p.started < 120000)
            return
        try ProcessClose(p.pid)                  ; stuck: give up quietly
        UpdLog(p.kind " timed out")
    }
    SetTimer(UpdPoll, 0)
    updProc := {pid: 0, kind: "", manual: false, started: 0}
    try {
        if (p.kind = "check")
            UpdAfterCheck(p.manual)
        else if (p.kind = "download")
            UpdAfterDownload()
    } catch as err {
        UpdReport(err, p.kind)
    }
}

UpdAfterCheck(manual) {
    st := PkgReadJson(UPD_DIR "\status.json")
    if !(st is Map) || !st.Get("ok", 0) {
        if manual
            statusText.Text := "Status: couldn't check for updates (" ((st is Map) ? st["error"] : "no answer") ")"
        return
    }
    UpdApplyStatus(st)
    if (!manual && IsObject(updLatest))
        UpdAutoDownload()
    if !manual
        return
    if IsObject(updLatest)
        UpdShowDialog()
    else
        statusText.Text := "Status: you have the latest version (" APP_VERSION ")"
}

; Shows or hides the pill for a status.json result
UpdApplyStatus(st) {
    global updLatest
    newer := (st is Map) && st.Get("ok", 0) && PkgCompareVersions(st["latest"], APP_VERSION) > 0
    updLatest := newer ? st : ""
    UpdShowPill(newer)
}

; ==============================================================================
; Automatic update: download in the background, ask to restart, install on open
; ==============================================================================
UpdAutoOn() => (UpdSetting("AutoUpdate") != "0")

UpdRemindMins() {
    n := 10
    try n := Integer(UpdSetting("RemindMinutes"))
    return Max(1, n)
}

; A quiet moment: no ringing / live call and no captions in the last minute
UpdIdle() => !UpdCallInProgress() && !(lastChatTick && A_TickCount - lastChatTick < 60000)

; Is a downloaded update waiting? With a version: that one. Without: any newer than this copy.
UpdPendingFor(ver := "") {
    dl := PkgReadJson(UPD_DIR "\download.json")
    if !(dl is Map) || !dl.Get("ok", 0) || !FileExist(dl.Get("appDir", "") "\" PKG_MAIN_SCRIPT)
        return false
    return (ver = "") ? (PkgCompareVersions(dl["version"], APP_VERSION) > 0) : (dl["version"] = ver)
}

UpdRecentAutoTry() {
    t := ""
    try t := IniRead(UPD_AUTO_INI, "Auto", "LastTry", "")
    return IsInteger(t) && DateDiff(A_Now, t, "Minutes") < 30
}

UpdEndStartup() {
    global updStartup
    updStartup := false
}

; Newer version known: fetch it quietly (the updater runs in its own process, captions never wait)
UpdAutoDownload() {
    global updAutoDl
    if !UpdAutoOn() || !AppIsInstalled() || !IsObject(updLatest)
        return
    if UpdPendingFor(updLatest["latest"]) {
        UpdOnReady()
        return
    }
    if (updDlFailAt && A_TickCount - updDlFailAt < 30 * 60 * 1000)
        return
    if UpdRunUpdater("download", [UPD_DIR]) {
        updAutoDl := true
        UpdLog("downloading version " updLatest["latest"] " in the background")
    }
}

; The update is downloaded. Just opened = install it now; otherwise ask when it's a quiet moment.
UpdOnReady() {
    global updForce
    if updStartup {
        updForce := true
        UpdLog("update ready right after opening - it installs by itself")
    }
    UpdTick()
}

; Every 30 s: retry a download, install-by-itself, or show the "Update ready" box
UpdTick() {
    global updForce
    try {
        if (updForce && !UpdPendingFor(""))
            updForce := false                     ; nothing downloaded after all: back to the normal way
        if (updForce && AppIsInstalled() && UpdIdle()) {
            UpdForceApply()
        } else if (!updForce && AppIsInstalled() && UpdAutoOn() && IsObject(updLatest) && !IsObject(updPrompt)) {
            if !UpdPendingFor(updLatest["latest"])
                UpdAutoDownload()
            else if (A_TickCount >= updRemindAt && UpdIdle())
                UpdShowPrompt()
        }
    } catch as err {
        UpdReport(err, "auto")
    }
    SetTimer(UpdTick, -30000)
}

; At every start: a downloaded newer version is installed now (the app is only just open: nothing to lose).
UpdStartupApply() {
    global updForce
    if !UpdAutoOn() || !AppIsInstalled() || !UpdPendingFor("")
        return
    if UpdRecentAutoTry() {
        UpdLog("an update is waiting but one was tried in the last 30 minutes - not installing it by itself again yet")
        return
    }
    updForce := true
    UpdTick()
}

UpdForceApply() {
    global updForce
    updForce := false
    UpdClosePrompt()
    UpdCloseDialog()
    ver := ""
    try ver := PkgReadJson(UPD_DIR "\download.json")["version"]
    try IniWrite(A_Now, UPD_AUTO_INI, "Auto", "LastTry")
    UpdLog("installing version " ver " by itself (the app was just opened)")
    try TrayTip("Installing the update (version " ver ") - reopening in a few seconds...", "Live Caption Companion", "Iconi Mute")
    UpdInstallAndRestart("apply")
}

; "Update ready": Restart now / Ask me later. Never takes the keyboard focus and has no default button,
; so typing during a call can't press it by accident.
UpdShowPrompt() {
    global updPrompt
    if IsObject(updPrompt) || !IsObject(updLatest)
        return
    mins := UpdRemindMins()
    g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Update ready")
    g.BackColor := "11151D"
    g.SetFont("s12 bold cF1F5FB", "Segoe UI")
    g.Add("Text", "w380", "Update ready: version " updLatest["latest"])
    g.SetFont("s10 norm c9BA8BA")
    g.Add("Text", "w380", "Restart to finish updating. Your call, helpers and settings are saved and kept. "
        . "If you wait, it installs by itself the next time you open the app.")
    note := g.Add("Text", "w380 h20 cFBBF24", "")
    btnNow := g.Add("Button", "w150", "Restart now")
    btnLater := g.Add("Button", "x+10 w190", "Ask me later (" mins " min)")
    TipSetAll([[btnNow, "Close the Companion and reopen it with the new version (a few seconds; your calls, helpers and settings are kept)"],
        [btnLater, "Not now: this box comes back in " mins " minutes. Opening the app later installs the update anyway"]])
    btnNow.OnEvent("Click", UpdSafe(UpdPromptRestart))
    btnLater.OnEvent("Click", UpdSafe(UpdPromptLater))
    g.OnEvent("Close", UpdSafe(UpdPromptLater))
    g.OnEvent("Escape", UpdSafe(UpdPromptLater))
    updPrompt := {gui: g, note: note}
    g.Show("Hide AutoSize")
    g.GetPos(, , &w, &h)
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    g.Show("NoActivate x" (r - w - 16) " y" (b - h - 16))
    UpdLog("showed the Update ready box (version " updLatest["latest"] ")")
}

UpdClosePrompt() {
    global updPrompt
    if IsObject(updPrompt)
        try updPrompt.gui.Destroy()
    updPrompt := ""
}

UpdPromptRestart() {
    if UpdCallInProgress() {
        if IsObject(updPrompt)
            updPrompt.note.Text := "3CX shows a call - finish it first."
        return
    }
    if !UpdPendingFor(IsObject(updLatest) ? updLatest["latest"] : "") {   ; the download went missing: fetch it again
        UpdClosePrompt()
        UpdAutoDownload()
        return
    }
    UpdClosePrompt()
    UpdLog("Restart now clicked")
    UpdInstallAndRestart("apply")
}

UpdPromptLater() {
    global updRemindAt
    mins := UpdRemindMins()
    updRemindAt := A_TickCount + mins * 60000
    UpdClosePrompt()
    statusText.Text := "Status: update ready - I'll ask again in " mins " min (it also installs when you reopen the app)"
    UpdLog("Ask me later: asking again in " mins " min")
}

; ==============================================================================
; The update dialog
; ==============================================================================
UpdShowDialog() {
    global updDlg
    if !IsObject(updLatest) {
        UpdStartCheck(true)
        return
    }
    if IsObject(updDlg) {
        try WinActivate("ahk_id " updDlg.gui.Hwnd)
        return
    }
    g := Gui("+Owner" myGui.Hwnd " -MinimizeBox", "Update")
    g.BackColor := "11151D"
    g.SetFont("s12 bold cF1F5FB", "Segoe UI")
    g.Add("Text", "w440", "Version " updLatest["latest"] " is available")
    g.SetFont("s10 norm c9BA8BA")
    g.Add("Text", "w440", "You have version " APP_VERSION ". Your calls, helpers and settings are kept.")
    g.Add("Text", "w440 y+12", "What's new")
    g.SetFont("cF1F5FB")
    notes := Trim(updLatest["notes"]) = "" ? "(no notes)" : updLatest["notes"]
    g.Add("Edit", "w440 r7 ReadOnly +0x100 Background1B2431", StrReplace(notes, "`n", "`r`n"))
    st := g.Add("Text", "w440 c9BA8BA", "")
    btnUpdate := g.Add("Button", "w130 Default", "Update now")
    btnLater := g.Add("Button", "x+10 w90", "Later")

    if !AppIsInstalled() {
        btnUpdate.Enabled := false
        st.Text := "This copy wasn't installed with Setup.bat (it's your repo), so it won't update itself."
    } else {
        st.Text := "The companion closes and reopens in a few seconds."
    }
    updDlg := {gui: g, status: st, btnUpdate: btnUpdate}
    btnUpdate.OnEvent("Click", UpdSafe(UpdBeginUpdate))
    btnLater.OnEvent("Click", (*) => UpdCloseDialog())
    TipSetAll([[btnUpdate, "Download and install it now: the Companion closes and reopens by itself (your calls, helpers and settings are kept)"],
        [btnLater, "Not now: the blue Update button stays, so you can update when you're free"]])
    g.OnEvent("Close", (*) => UpdCloseDialog())
    g.OnEvent("Escape", (*) => UpdCloseDialog())
    g.Show()
}

UpdCloseDialog() {
    global updDlg
    if IsObject(updDlg)
        try updDlg.gui.Destroy()
    updDlg := ""
}

UpdDialogStatus(text, canClick) {
    if !IsObject(updDlg)
        return
    updDlg.status.Text := text
    updDlg.btnUpdate.Enabled := canClick
}

UpdBeginUpdate() {
    if UpdCallInProgress() {
        UpdDialogStatus("3CX shows a call right now. Finish the call first - updating restarts the companion.", true)
        return
    }
    if (lastChatTick && A_TickCount - lastChatTick < 60000) {
        updDlg.gui.Opt("+OwnDialogs")
        if (MsgBox("Captions came in during the last minute.`n`nUpdate anyway? The companion closes for a few seconds and the call so far is saved."
            , "Update", "YesNo Icon? Default2") != "Yes")
            return
    }
    ; Already downloaded this version? Go straight to installing.
    dl := PkgReadJson(UPD_DIR "\download.json")
    if ((dl is Map) && dl.Get("ok", 0) && dl["version"] = updLatest["latest"]) {
        UpdInstallAndRestart("apply")
        return
    }
    UpdDialogStatus("Downloading version " updLatest["latest"] "...", false)
    if !UpdRunUpdater("download", [UPD_DIR])
        UpdDialogStatus("The updater is busy - try again in a moment.", true)
}

UpdAfterDownload() {
    global updAutoDl, updDlFailAt
    auto := updAutoDl
    updAutoDl := false
    dl := PkgReadJson(UPD_DIR "\download.json")
    if (auto && !IsObject(updDlg)) {              ; started by the app itself, nobody clicked anything
        if (dl is Map) && dl.Get("ok", 0) {
            UpdLog("downloaded in the background: version " dl["version"])
            UpdOnReady()
        } else {
            updDlFailAt := A_TickCount
            UpdLog("background download FAILED: " ((dl is Map) ? dl["error"] : "no answer from the updater"))
        }
        return
    }
    if !(dl is Map) || !dl.Get("ok", 0) {
        why := (dl is Map) ? dl["error"] : "no answer from the updater"
        UpdDialogStatus("Download failed: " why, true)
        statusText.Text := "Status: update download failed (" why ")"
        return
    }
    if !IsObject(updDlg) {                        ; dialog was closed meanwhile: don't restart by surprise
        statusText.Text := "Status: update downloaded - click ⬆ Update to install it"
        return
    }
    if UpdCallInProgress() {
        UpdDialogStatus("Downloaded. 3CX shows a call, so it will install when you click Update now after the call.", true)
        return
    }
    UpdInstallAndRestart("apply")
}

; Hands over to updater.ahk and closes. HandleExit saves the call on the way out.
UpdInstallAndRestart(mode) {
    UpdDialogStatus(mode = "apply" ? "Installing - the companion will reopen in a few seconds..." : "Going back...", false)
    pid := DllCall("GetCurrentProcessId")
    if UpdRunUpdater(mode, [APP_ROOT, UPD_DIR, pid]) {
        UpdLog(mode " started from " APP_VERSION)
        SetTimer(() => ExitApp(), -300)
    }
}

UpdRollback() {
    if !AppIsInstalled() {
        statusText.Text := "Status: going back only works on a copy installed with Setup.bat"
        return
    }
    prev := PkgReadVersion(APP_ROOT "\app.old")
    if !FileExist(APP_ROOT "\app.old\" PKG_MAIN_SCRIPT) {
        statusText.Text := "Status: there is no previous version to go back to"
        return
    }
    if UpdCallInProgress() {
        statusText.Text := "Status: finish the call first - going back restarts the companion"
        return
    }
    myGui.Opt("+OwnDialogs")
    if (MsgBox("Go back from version " APP_VERSION " to version " prev "?`n`nThe companion closes and reopens. Your calls and settings are kept."
        , "Go back to the previous version", "YesNo Icon? Default2") != "Yes")
        return
    UpdInstallAndRestart("rollback")
}

; After an update or going back, say how it went (once)
UpdReportLastResult() {
    path := UPD_DIR "\last-result.json"
    r := PkgReadJson(path)
    try FileDelete(path)
    if !(r is Map)
        return
    if r["ok"]
        msg := (r["action"] = "rollback" ? "Went back to version " : "Updated to version ") APP_VERSION
    else
        msg := "The update didn't finish (" r["error"] ") - still on version " APP_VERSION
    TrayTip(msg, "Live Caption Companion", r["ok"] ? "Iconi Mute" : "Icon! Mute")
    SetTimer(() => (statusText.Text := "Status: " msg), -3000)   ; after the captions status settles
}

UpdCallInProgress() {
    try return (callerPhase = "ringing" || callerPhase = "on call")
    return false
}

; ==============================================================================
; Error handling
; ==============================================================================
UpdSafe(fn) {
    return (*) => UpdTry(fn)
}

UpdTry(fn) {
    try fn()
    catch as err
        UpdReport(err)
}

UpdReport(err, where := "") {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: update problem (captions unaffected): " msg
    UpdLog("ERROR " where ": " msg)
}

UpdLog(line) {
    PkgLog(UPD_LOG, "[companion] " line)
}
