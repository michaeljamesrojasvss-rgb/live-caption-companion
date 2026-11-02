#Requires AutoHotkey v2.0
#SingleInstance Off
#Include %A_ScriptDir%\..\app\Json.ahk
#Include %A_ScriptDir%\..\app\package-lib.ahk

; ==============================================================================
; release.ahk  -  builds the zip you share and the version.json that tells
; installed copies a new version exists. Run it on your own PC.
;
; Two ways to run it:
;   * Double-click: a small window (Build zip, then Make version.json).
;   * Command line (for scripts and Claude Code) - builds both in one go:
;       runtime\AutoHotkey32.exe /ErrorStdOut tools\release.ahk build [version] ["notes"]
;     version: e.g. 2026.10.30, or leave out / "auto" for today's date
;     notes:   What's new; write \n for a new line
;     Prints the result, and exits with 0 on success, 1 on failure.
;
; Output (dist\):
;   CaptionCompanion-<version>.zip  -> on Drive, upload as a NEW VERSION of the
;                                      existing zip file (Manage versions)
;   version.json                    -> same, onto the existing version.json
; Replacing the files on Drive keeps both links the same, so installed copies
; and the link you give workmates never change.
;
; Links live in:
;   app\app.ini       [Update]  ManifestUrl = link of version.json (shipped)
;   tools\release.ini [Release] ZipUrl      = link of the zip (only for releases built by hand)
; Building also writes app\version.txt - commit it (not needed for GitHub releases).
;
; Normally you don't run this at all: every push to main that changes the app is built
; and published by GitHub Actions (.github\workflows\release.yml), which calls the
; command line below with RELEASE_CI=1. "notes" can also be "@path" to read a file.
; ==============================================================================

SplitPath(A_ScriptDir, , &REPO)
APP := REPO "\app"
DIST := REPO "\dist"
APP_INI := APP "\app.ini"
RELEASE_INI := A_ScriptDir "\release.ini"

rel := {}                   ; window controls

if (A_Args.Length && A_Args[1] = "build")
    ExitApp(ReleaseCli())
ReleaseBuildUi()

; ==============================================================================
; Shared steps (used by the window and the command line)
; ==============================================================================

; Builds dist\CaptionCompanion-<ver>.zip. Returns {zip, files, note}.
ReleaseBuildZip(ver, includeHelpers) {
    if !PkgIsValidVersion(ver)
        throw Error("'" ver "' isn't a version like 2026.10.30 (add .2 for a second release the same day)")
    for f in [REPO "\runtime\AutoHotkey32.exe", REPO "\installer\Setup.bat", REPO "\installer\setup.ahk", APP "\" PKG_MAIN_SCRIPT]
        if !FileExist(f)
            throw Error("missing " f)

    PkgWriteText(APP "\version.txt", ver)
    name := "CaptionCompanion-" ver
    build := DIST "\_build"
    pkg := build "\" name
    PkgResetDir(build)
    DirCreate(pkg "\installer")
    DirCreate(pkg "\runtime")
    FileCopy(REPO "\installer\Setup.bat", pkg "\Setup.bat")
    FileCopy(REPO "\installer\setup.ahk", pkg "\installer\setup.ahk")
    FileCopy(REPO "\runtime\AutoHotkey32.exe", pkg "\runtime\AutoHotkey32.exe")
    try FileCopy(REPO "\runtime\license.txt", pkg "\runtime\license.txt")
    files := ReleaseCopyApp(APP, pkg "\app")

    note := ""
    if includeHelpers {
        src := REPO "\data\call-helpers.json"
        if FileExist(src) {
            DirCreate(pkg "\app\defaults")
            FileCopy(src, pkg "\app\defaults\call-helpers.json")
            note := "with your helpers as the starting set"
        } else {
            note := "no data\call-helpers.json found, so no helpers included"
        }
    }

    zip := DIST "\" name ".zip"
    PkgCreateZip(pkg, zip)
    try DirDelete(build, true)
    return {zip: zip, files: files, note: note}
}

; Copies app\ minus logs, backups and anything personal. Returns the file count.
ReleaseCopyApp(src, dest) {
    n := 0
    Loop Files src "\*", "FR" {
        relPath := SubStr(A_LoopFileFullPath, StrLen(src) + 2)
        if ReleaseExcluded(relPath, A_LoopFileName)
            continue
        target := dest "\" relPath
        SplitPath(target, , &dir)
        DirCreate(dir)
        FileCopy(A_LoopFileFullPath, target)
        n += 1
    }
    return n
}

ReleaseExcluded(relPath, name) {
    if RegExMatch(relPath, "i)^(whisper|defaults)\\")
        return true
    if RegExMatch(name, "i)\.(log|bak|tmp|old)$|\.bk\.ahk$|\.backup\.json$")
        return true
    if (RegExMatch(name, "i)\.txt$") && name != "version.txt")
        return true
    for f in PKG_DATA_FILES
        if (name = f)
            return true
    return false
}

; Writes dist\version.json. zipLink: the zip's Drive share link.
ReleaseWriteVersionJson(ver, zipLink, notes) {
    direct := PkgDirectUrl(zipLink)
    if (direct = zipLink && InStr(zipLink, "drive.google.com"))
        throw Error("that zip link isn't a Drive file link (Drive: right-click the zip > Share > Copy link)")
    DirCreate(DIST)
    path := DIST "\version.json"
    PkgWriteJson(path, Map("version", ver, "zip", direct, "notes", notes, "released", FormatTime(, "yyyy-MM-dd")))
    return path
}

; Today's date, or today.2 / .3 ... when today's version already exists
ReleaseSuggestVersion(current) {
    today := FormatTime(, "yyyy.MM.dd")
    if (PkgCompareVersions(today, current) > 0)
        return today
    n := 2
    if RegExMatch(current, "^\Q" today "\E\.(\d+)$", &m)
        n := Integer(m[1]) + 1
    return today "." n
}

ReleaseManifestLink() => IniRead(APP_INI, "Update", "ManifestUrl", "")
ReleaseZipLink() => IniRead(RELEASE_INI, "Release", "ZipUrl", "")

; ==============================================================================
; Command line
; ==============================================================================
ReleaseCli() {
    try {
        ; GitHub Actions sets RELEASE_CI=1 and RELEASE_ZIP_URL, and picks the version itself
        ; (see .github\workflows\release.yml). On your own PC neither is set.
        ci := (EnvGet("RELEASE_CI") = "1")
        current := PkgReadVersion(APP)
        ver := (A_Args.Length >= 2 && A_Args[2] != "auto") ? Trim(A_Args[2]) : ReleaseSuggestVersion(current)
        notes := ""
        if (A_Args.Length >= 3) {
            if (SubStr(A_Args[3], 1, 1) = "@") {            ; "@path" = read the notes from a file
                notes := Trim(FileRead(SubStr(A_Args[3], 2), "UTF-8"), " `t`r`n")
            } else {
                notes := StrReplace(A_Args[3], "\n", "`n")
            }
        }
        if (!ci && PkgCompareVersions(ver, current) <= 0)
            throw Error(ver " isn't newer than the current version " current ", so installed copies wouldn't be offered it")
        if (ReleaseManifestLink() = "")
            throw Error("no update link in app\app.ini [Update] ManifestUrl")
        zipLink := EnvGet("RELEASE_ZIP_URL")
        if (zipLink = "")
            zipLink := ReleaseZipLink()
        if (zipLink = "")
            throw Error("no zip link in tools\release.ini [Release] ZipUrl")

        r := ReleaseBuildZip(ver, false)
        json := ReleaseWriteVersionJson(ver, zipLink, notes)
        msg := "OK: built version " ver " (" r.files " app files)`n"
            . "  zip:          " r.zip "`n"
            . "  version.json: " json
        if !ci {
            msg .= "`nNext: upload the zip and version.json where the update link points (see docs\INSTALL-AND-UPDATES.md)."
                . "`nCommit app\version.txt."
        }
        ReleaseOut(msg)
        return 0
    } catch as err {
        ReleaseOut("FAILED: " err.Message)
        return 1
    }
}

; Prints to the console when there is one, and always to dist\release-result.txt
ReleaseOut(text) {
    try DirCreate(DIST)
    try FileDelete(DIST "\release-result.txt")
    try FileAppend(text "`n", DIST "\release-result.txt", "UTF-8")
    try FileAppend(text "`n", "*")
}

; ==============================================================================
; Window
; ==============================================================================
ReleaseBuildUi() {
    current := PkgReadVersion(APP)
    g := Gui(, "Release Live Caption Companion")
    g.SetFont("s12 bold", "Segoe UI")
    g.Add("Text", "w540", "Release a new version")
    g.SetFont("s10 norm")

    g.Add("Text", "w540 y+14", "Update link - the Drive share link of version.json")
    rel.manifest := g.Add("Edit", "w400", ReleaseManifestLink())
    rel.starter := g.Add("Button", "x+8 w132 hp", "Starter version.json")
    g.Add("Text", "xm w540 c666666", "Every installed copy checks this link. Set it once, then keep it the same by using Manage versions on Drive.")

    g.Add("Text", "xm w540 y+16", "Version (current: " current ")")
    rel.version := g.Add("Edit", "w160", ReleaseSuggestVersion(current))
    g.Add("Text", "xm w540", "What's new - workmates see this in the update window")
    rel.notes := g.Add("Edit", "w540 r5 Multi WantReturn")
    rel.helpers := g.Add("Checkbox", "w540", "Include my call helpers (data\call-helpers.json) as the starting set for new installs")
    rel.build := g.Add("Button", "w160 Default", "1. Build zip")

    g.Add("Text", "xm w540 y+16", "The zip's Drive share link")
    rel.zip := g.Add("Edit", "w400", ReleaseZipLink())
    rel.makeJson := g.Add("Button", "x+8 w132 hp", "2. Make version.json")

    rel.status := g.Add("Text", "xm w540 r4 y+14 c1D4ED8", "")

    rel.starter.OnEvent("Click", (*) => ReleaseTry(ReleaseStarterJson))
    rel.build.OnEvent("Click", (*) => ReleaseTry(ReleaseBuildClicked))
    rel.makeJson.OnEvent("Click", (*) => ReleaseTry(ReleaseMakeJsonClicked))
    g.OnEvent("Close", (*) => ExitApp())
    rel.gui := g
    g.Show()
}

ReleaseBuildClicked() {
    rel.gui.Opt("+OwnDialogs")
    ver := Trim(rel.version.Value)
    manifest := Trim(rel.manifest.Value)
    current := PkgReadVersion(APP)
    if (PkgIsValidVersion(ver) && PkgCompareVersions(ver, current) <= 0) {
        if (MsgBox(ver " isn't newer than " current ", so installed copies won't be offered it.`n`nBuild anyway?", "Version", "YesNo Icon? Default2") != "Yes")
            return
    }
    if (manifest = "") {
        if (MsgBox("There's no update link yet, so copies installed from this zip can't check for updates.`n`nFirst time? Click Starter version.json, upload it, and paste its link.`n`nBuild anyway?", "Update link", "YesNo Icon? Default2") != "Yes")
            return
    }
    ReleaseStatus("Building " ver "...")
    IniWrite(manifest, APP_INI, "Update", "ManifestUrl")
    r := ReleaseBuildZip(ver, rel.helpers.Value)
    SplitPath(r.zip, &zipName)
    ReleaseStatus("Built dist\" zipName " - " r.files " app files" (r.note != "" ? " (" r.note ")" : "") ".`n"
        . "Next: on Drive, upload it as a new version of your existing zip (Manage versions), "
        . "then click Make version.json.")
    Run('explorer.exe /select,"' r.zip '"')
}

ReleaseMakeJsonClicked() {
    link := Trim(rel.zip.Value)
    if (link = "") {
        ReleaseStatus("Paste the zip's Drive share link first.")
        return
    }
    ver := PkgReadVersion(APP)                   ; the version the last build wrote
    path := ReleaseWriteVersionJson(ver, link, Trim(rel.notes.Value, " `t`r`n"))
    IniWrite(link, RELEASE_INI, "Release", "ZipUrl")
    ReleaseStatus("dist\version.json is ready for " ver ".`n"
        . "On Drive: upload it as a new version of your existing version.json (Manage versions). "
        . "Installed copies will offer the update within a few hours (or tray > Updates > Check).")
    Run('explorer.exe /select,"' path '"')
}

; First time only: a placeholder that offers nothing, just to get a link
ReleaseStarterJson() {
    DirCreate(DIST)
    path := DIST "\version.json"
    PkgWriteJson(path, Map("version", "0", "zip", "", "notes", ""))
    ReleaseStatus("dist\version.json (placeholder) is ready.`n"
        . "Upload it to your Drive folder, share it as 'Anyone with the link', copy its link "
        . "into the Update link box above, then build.")
    Run('explorer.exe /select,"' path '"')
}

ReleaseStatus(text) {
    rel.status.Text := text
}

ReleaseTry(fn) {
    try {
        fn()
    } catch as err {
        ReleaseStatus("")
        rel.gui.Opt("+OwnDialogs")
        MsgBox("That didn't work:`n`n" err.Message, "Release", "Iconx")
    }
}
