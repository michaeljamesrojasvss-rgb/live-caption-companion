; ==============================================================================
; uninstall-link.ahk  -  lets an installed copy uninstall itself
;
; The uninstaller (Uninstall.bat + uninstall.ahk) ships INSIDE app\uninstall\, because
; updates replace app\ as a whole, so that is the only place an update can deliver it.
; On every start of an installed copy it is copied to where Uninstall.bat expects it:
;     <root>\Uninstall.bat
;     <root>\installer\uninstall.ahk
; Tray > Updates > "Uninstall..." runs it. Nothing happens in a git working copy.
; ==============================================================================
UNINST_SRC := APP_DIR "\uninstall"

UninstInit() {
    try UninstSync()
}

; Copies the shipped uninstaller next to the install. Quiet: never blocks startup.
UninstSync() {
    if (!AppIsInstalled() || !DirExist(UNINST_SRC))
        return false
    try DirCreate(APP_ROOT "\installer")
    try FileCopy(UNINST_SRC "\Uninstall.bat", APP_ROOT "\Uninstall.bat", true)
    try FileCopy(UNINST_SRC "\uninstall.ahk", APP_ROOT "\installer\uninstall.ahk", true)
    return FileExist(APP_ROOT "\Uninstall.bat") && FileExist(APP_ROOT "\installer\uninstall.ahk")
}

; Tray > Updates > Uninstall...
UninstRun(*) {
    if !AppIsInstalled() {
        MsgBox("This is a development copy (not installed by Setup), so there is nothing to uninstall.", "Live Caption Companion", "Iconi")
        return
    }
    if !UninstSync() {
        MsgBox("The uninstaller isn't in this version.`n`nInstall the newest version (tray > Updates > Check for updates), then try again.", "Live Caption Companion", "Icon!")
        return
    }
    if (MsgBox("Uninstall Live Caption Companion from this PC?`n`nThe uninstaller will ask whether to keep your call history and settings.", "Live Caption Companion", "YesNo Icon?") != "Yes")
        return
    try Run('"' APP_ROOT '\Uninstall.bat"', APP_ROOT, "Min")
    catch as e
        MsgBox("Couldn't start the uninstaller:`n" e.Message, "Live Caption Companion", "Icon!")
}
