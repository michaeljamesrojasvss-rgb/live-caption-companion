#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\..\app\Json.ahk
#Include %A_ScriptDir%\..\app\package-lib.ahk

; ==============================================================================
; setup.ahk  -  installs Live Caption Companion for the current Windows user.
; Started by Setup.bat (which uses the AutoHotkey32.exe inside the package).
;
;   <root>\runtime\AutoHotkey32.exe
;   <root>\app\          the program (replaced by updates; app.old = previous)
;   <root>\data\         the agent's calls, helpers and settings (never touched)
;   <root>\install.ini   marks an installed copy, so it may update itself
;
; Running it again over an existing install updates/repairs it and keeps data.
; No admin rights needed; nothing outside the user's own folders is changed.
; ==============================================================================

SplitPath(A_ScriptDir, , &PKG_ROOT)
SETUP_VERSION := PkgReadVersion(PKG_ROOT "\app")
DEFAULT_ROOT := EnvGet("LOCALAPPDATA") "\CaptionCompanion"
FALLBACK_ROOT := EnvGet("USERPROFILE") "\CaptionCompanion"   ; if Windows blocks programs in AppData
SHORTCUT_NAME := "Live Caption Companion"

ui := {}                    ; controls, filled by SetupBuildUi
state := {root: "", rootChosen: false, fellBack: false}

SetupMain()

SetupMain() {
    if !FileExist(PKG_ROOT "\app\" PKG_MAIN_SCRIPT) || !FileExist(PKG_ROOT "\runtime\AutoHotkey32.exe") {
        MsgBox("Setup can't find the app files next to it.`n`nExtract the whole zip first (right-click > Extract All), then run Setup.bat from the extracted folder."
            , "Live Caption Companion setup", "Iconx")
        ExitApp()
    }
    existing := SetupFindInstall()
    state.root := existing != "" ? existing : DEFAULT_ROOT
    SetupBuildUi()
}

; ==============================================================================
; Window
; ==============================================================================
SetupBuildUi() {
    g := Gui("-MinimizeBox", "Install Live Caption Companion")
    g.SetFont("s13 bold", "Segoe UI")
    g.Add("Text", "w470", "Live Caption Companion")
    g.SetFont("s10 norm")
    g.Add("Text", "w470 y+2 c666666", "Version " SETUP_VERSION)

    g.Add("Text", "w470 y+16", "Install to")
    ui.root := g.Add("Edit", "w380 ReadOnly")
    ui.change := g.Add("Button", "x+8 w82 hp", "Change…")
    ui.existing := g.Add("Text", "xm w470 c666666", "")

    ui.import := g.Add("Checkbox", "xm y+14 w470", "Bring over call history, helpers and settings from an older copy")
    ui.old := g.Add("Edit", "xm+18 w362")
    ui.browse := g.Add("Button", "x+8 w82 hp", "Browse…")

    ui.desktop := g.Add("Checkbox", "xm y+14 Checked", "Put a shortcut on the desktop")
    ui.start := g.Add("Checkbox", "xm Checked", "Add it to the Start menu")

    ui.status := g.Add("Text", "xm y+14 w470 r2 c666666", "")
    ui.install := g.Add("Button", "xm w120 Default", "Install")
    ui.cancel := g.Add("Button", "x+10 w90", "Cancel")

    ui.change.OnEvent("Click", (*) => SetupChangeRoot())
    ui.browse.OnEvent("Click", (*) => SetupBrowseOld())
    ui.import.OnEvent("Click", (*) => SetupSyncImport())
    ui.install.OnEvent("Click", (*) => SetupInstallClicked())
    ui.cancel.OnEvent("Click", (*) => ExitApp())
    g.OnEvent("Close", (*) => ExitApp())
    ui.gui := g

    old := SetupFindOldCopy()
    ui.old.Value := old
    ui.import.Value := (old != "")
    SetupShowRoot()
    g.Show()
}

SetupShowRoot() {
    ui.root.Value := state.root
    ver := ""
    try ver := IniRead(state.root "\install.ini", "Install", "Version", "")
    ui.existing.Text := (ver = "") ? ""
        : "Version " ver " is installed here. It will be replaced; calls, helpers and settings are kept."
    if (FileExist(state.root "\data\call-history.json") && ui.old.Value = "")
        ui.import.Value := false
    SetupSyncImport()
}

SetupSyncImport() {
    ui.old.Enabled := ui.import.Value
    ui.browse.Enabled := ui.import.Value
}

SetupChangeRoot() {
    ui.gui.Opt("+OwnDialogs")
    sel := DirSelect("*" state.root, 3, "Choose where to install Live Caption Companion")
    if (sel = "")
        return
    sel := RTrim(sel, "\")
    SplitPath(sel, &name)
    if (!FileExist(sel "\install.ini") && name != "CaptionCompanion")
        sel .= "\CaptionCompanion"               ; keep everything in its own folder
    state.root := sel
    state.rootChosen := true
    SetupShowRoot()
}

SetupBrowseOld() {
    ui.gui.Opt("+OwnDialogs")
    sel := DirSelect("*" EnvGet("USERPROFILE") "\Downloads", 0, "Pick the folder of the older copy (the one with liveCaptionCompanion.ahk)")
    if (sel != "")
        ui.old.Value := RTrim(sel, "\")
}

SetupStatus(text) {
    ui.status.Text := text
}

SetupBusy(busy) {
    for c in [ui.change, ui.browse, ui.import, ui.desktop, ui.start, ui.install, ui.cancel]
        c.Enabled := !busy
    if !busy
        SetupSyncImport()
}

; ==============================================================================
; Install
; ==============================================================================
SetupInstallClicked() {
    ui.gui.Opt("+OwnDialogs")
    old := ui.import.Value ? Trim(ui.old.Value) : ""
    if (old != "" && !SetupIsOldCopy(old, false)) {
        MsgBox("That folder doesn't have an older copy's call history or settings in it:`n`n" old, "Install", "Icon!")
        return
    }
    SetupBusy(true)
    try {
        summary := SetupInstall(old)
    } catch as err {
        SetupBusy(false)
        SetupStatus("")
        MsgBox("Setup didn't finish:`n`n" err.Message, "Install", "Iconx")
        return
    }
    SetupStatus("Done.")
    if (MsgBox("Live Caption Companion " SETUP_VERSION " is installed." summary "`n`nOpen it now?"
        , "Install", "YesNo Iconi") = "Yes")
        SetupLaunch(state.root)
    ExitApp()
}

; Returns extra lines for the final message
SetupInstall(old) {
    root := SetupPlaceRuntime(state.root)
    state.root := root

    SetupStatus("Copying the app...")
    newApp := root "\app.new"
    try DirDelete(newApp, true)
    DirCopy(PKG_ROOT "\app", newApp, true)
    reason := PkgSwapApp(root, newApp)
    if (reason != "")
        throw Error(reason)

    DirCreate(root "\data")
    summary := ""
    if (old != "") {
        SetupStatus("Bringing over your calls and settings...")
        PkgCloseScriptsIn(old, [PKG_MAIN_SCRIPT, "caller-watch.ahk", "main-helper.ahk"])   ; it saves its call as it closes
        r := SetupImport(old, root "\data")
        summary .= "`n`nBrought over " r.copied " file(s) from your older copy."
        if r.skipped
            summary .= " " r.skipped " were already in the installed copy, so those were kept."
        summary .= "`nYou can delete the old folder once you're happy:`n" old
    }

    IniWrite(SETUP_VERSION, root "\install.ini", "Install", "Version")
    IniWrite(FormatTime(, "yyyy-MM-dd HH:mm"), root "\install.ini", "Install", "InstalledAt")

    SetupStatus("Creating shortcuts...")
    if ui.desktop.Value
        SetupShortcut(root, A_Desktop "\" SHORTCUT_NAME ".lnk")
    if ui.start.Value
        SetupShortcut(root, A_Programs "\" SHORTCUT_NAME ".lnk")
    if state.fellBack
        summary .= "`n`nWindows didn't allow programs in AppData, so it went to:`n" root
    return summary
}

; Copies AutoHotkey32.exe and checks Windows lets it run there. If AppData is
; blocked (and the agent didn't pick the folder), falls back to the user folder.
; Returns the root actually used.
SetupPlaceRuntime(root) {
    SetupStatus("Closing the companion if it's open...")
    DirCreate(root)
    if (DirExist(root "\app") && !PkgCloseScriptsIn(root "\app"))
        throw Error("Live Caption Companion is still open. Close it (tray icon > Exit), then click Install again.")

    SetupStatus("Copying AutoHotkey...")
    DirCreate(root "\runtime")
    Loop Files PKG_ROOT "\runtime\*"
        FileCopy(A_LoopFileFullPath, root "\runtime\" A_LoopFileName, true)
    exe := root "\runtime\AutoHotkey32.exe"
    try FileDelete(exe ":Zone.Identifier")       ; downloaded-file mark: avoids a prompt on every start

    if SetupCanRun(exe)
        return root
    if (!state.rootChosen && root = DEFAULT_ROOT) {
        try DirDelete(root "\runtime", true)     ; leave nothing behind in the blocked folder
        try DirDelete(root)                      ; only removed if it's now empty
        SetupStatus("Windows blocked that folder - trying " FALLBACK_ROOT "...")
        state.rootChosen := true                 ; only fall back once
        state.fellBack := true
        return SetupPlaceRuntime(FALLBACK_ROOT)
    }
    throw Error("Windows didn't let AutoHotkey run from:`n" root "`n`nClick Change… and pick a folder where it works today, for example inside Downloads.")
}

SetupCanRun(exe) {
    probe := A_Temp "\caption-companion-setup-probe.ahk"
    try {
        PkgWriteText(probe, "ExitApp(42)")
        code := RunWait(Format('"{}" "{}"', exe, probe), , "Hide")
        FileDelete(probe)
        return code = 42
    }
    return false
}

SetupImport(oldDir, dataDir) {
    r := {copied: 0, skipped: 0}
    for name in PKG_DATA_FILES {
        if !FileExist(oldDir "\" name)
            continue
        if FileExist(dataDir "\" name) {
            r.skipped += 1
            continue
        }
        FileCopy(oldDir "\" name, dataDir "\" name)
        r.copied += 1
    }
    return r
}

SetupShortcut(root, lnk) {
    exe := root "\runtime\AutoHotkey32.exe"
    script := root "\app\" PKG_MAIN_SCRIPT
    try FileCreateShortcut(exe, lnk, root "\app", '"' script '"', "Live Caption Companion", exe)
}

SetupLaunch(root) {
    try Run(Format('"{}" "{}"', root "\runtime\AutoHotkey32.exe", root "\app\" PKG_MAIN_SCRIPT), root "\app")
}

; ==============================================================================
; Finding things
; ==============================================================================
SetupFindInstall() {
    for r in [DEFAULT_ROOT, FALLBACK_ROOT]
        if FileExist(r "\install.ini")
            return r
    return ""
}

; Looks (two folders deep) in Downloads, Desktop and Documents for a copy run the
; old way: liveCaptionCompanion.ahk with its call history next to it
SetupFindOldCopy() {
    for dir in [EnvGet("USERPROFILE") "\Downloads", A_Desktop, A_MyDocuments] {
        found := SetupSearch(dir, 2)
        if (found != "")
            return found
    }
    return ""
}

SetupSearch(dir, depth) {
    if SetupIsOldCopy(dir, true)
        return dir
    if (depth = 0)
        return ""
    try {
        Loop Files dir "\*", "D" {
            if InStr(A_LoopFileAttrib, "H") || InStr(A_LoopFileAttrib, "S")
                continue
            found := SetupSearch(A_LoopFileFullPath, depth - 1)
            if (found != "")
                return found
        }
    }
    return ""
}

; needScript: also require liveCaptionCompanion.ahk (used by the automatic search)
SetupIsOldCopy(dir, needScript) {
    for r in [DEFAULT_ROOT, FALLBACK_ROOT]
        if (InStr(dir, r) = 1)
            return false                         ; that's an install, not an old copy
    if (needScript && !FileExist(dir "\" PKG_MAIN_SCRIPT))
        return false
    for name in PKG_DATA_FILES
        if FileExist(dir "\" name)
            return true
    return false
}
