; ==============================================================================
; app-paths.ahk  -  where the app's files and the agent's own data live
;
;   <root>\app\     this folder: the program. Updates replace it as a whole.
;   <root>\data\    call history, helpers, settings and logs. Never touched by
;                   setup or updates.
;
; <root> is the install folder on a coworker's PC, or your git repo while you
; develop - the layout is the same, so nothing behaves differently in dev.
;
; Include this FIRST in liveCaptionCompanion.ahk: other modules use DATA_DIR
; while they load.
; ==============================================================================
#Include package-lib.ahk

APP_DIR := A_ScriptDir
APP_ROOT := AppParentDir(A_ScriptDir)
DATA_DIR := APP_ROOT "\data"
APP_VERSION := PkgReadVersion(APP_DIR)

AppPathsInit()

AppPathsInit() {
    try DirCreate(DATA_DIR)
    if !DirExist(DATA_DIR)
        throw Error("Could not create the data folder:`n" DATA_DIR)

    ; Older copies kept the data next to the script (or in the repo root), so
    ; it is brought over once - copied, never moved
    for dir in [APP_DIR, APP_ROOT]
        AppCopyMissing(dir, DATA_DIR, PKG_DATA_FILES)

    ; Starting helpers shipped with the package, for a brand-new install
    AppCopyMissing(APP_DIR "\defaults", DATA_DIR, ["call-helpers.json"])
}

; Copies each named file from src to dest, only when dest doesn't have it yet
AppCopyMissing(src, dest, names) {
    for name in names {
        if (FileExist(src "\" name) && !FileExist(dest "\" name))
            try FileCopy(src "\" name, dest "\" name)
    }
}

AppParentDir(path) {
    SplitPath(path, , &parent)
    return parent
}

; True on a copy installed by Setup (it writes install.ini). False in your repo,
; so an update can never overwrite your working copy.
AppIsInstalled() {
    return FileExist(APP_ROOT "\install.ini") ? true : false
}
