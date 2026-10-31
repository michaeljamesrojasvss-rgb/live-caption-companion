; ==============================================================================
; error-log.ahk  -  catch-all for errors no try/catch handled
;
; * An error that would pop up AutoHotkey's error box is written to
;   data\errors.log instead, with a short note in the status line. Only the
;   action that failed stops; the app and the captions keep running. (That box
;   has an Exit button, so before this one error could close the whole app.)
; * The same error repeating (e.g. from a timer) is logged once, then counted.
; * If the last session didn't close normally (crashed, ended from Task
;   Manager, PC lost power), that is noted in the log at the next start, so
;   hard crashes leave a trace too.
; * Include right after app-paths.ahk (needs DATA_DIR and APP_VERSION).
; ==============================================================================

ERR_LOG := DATA_DIR "\errors.log"
ERR_FLAG := DATA_DIR "\running.flag"     ; exists while the app runs

ErrLogInit()

ErrLogInit() {
    OnError(ErrOnError)
    try {
        if FileExist(ERR_FLAG) {
            since := ""
            try since := Trim(FileRead(ERR_FLAG), " `t`r`n")
            ErrWrite("The last session didn't close normally (it crashed, was ended from Task Manager, "
                . "or the PC shut down). That session started " since)
        }
        f := FileOpen(ERR_FLAG, "w", "UTF-8")
        f.Write(FormatTime(, "yyyy-MM-dd HH:mm:ss") " (version " APP_VERSION ")")
        f.Close()
    }
}

; Last thing on a normal exit
ErrLogShutdown() {
    try FileDelete(ERR_FLAG)
}

; Runs fn(args*); an error is logged and doesn't stop the caller
ErrRun(fn, args*) {
    try {
        return fn(args*)
    } catch as err {
        ErrWrite(ErrDescribe(err))
    }
}

ErrOnError(thrown, mode) {
    static busy := false, lastKey := "", lastTick := 0, repeats := 0
    if busy
        return 1
    busy := true
    try {
        key := ErrShort(thrown)
        try key .= "|" thrown.File ":" thrown.Line
        if (key = lastKey && A_TickCount - lastTick < 60000) {
            repeats += 1                    ; same error again soon: count, don't flood the log
        } else {
            if (repeats > 0)
                ErrWrite("(the error above happened " repeats " more time(s))")
            repeats := 0
            ErrWrite(ErrDescribe(thrown) (mode = "ExitApp" ? "`n  AutoHotkey had to close the app after this error." : ""))
        }
        lastKey := key, lastTick := A_TickCount
        try statusText.Text := "Status: something went wrong (saved in errors.log, captions keep running): " ErrShort(thrown)
    }
    busy := false
    ; ExitApp = AutoHotkey closes the app anyway: let its box say why
    return (mode = "ExitApp") ? 0 : 1
}

ErrShort(e) {
    if (e is Error)
        return e.Message (e.Extra != "" ? " (" e.Extra ")" : "")
    try return "thrown value: " String(e)
    return "thrown " Type(e)
}

ErrDescribe(e) {
    if !(e is Error)
        return ErrShort(e)
    s := e.Message
    if (e.Extra != "")
        s .= "`n  Specifically: " e.Extra
    s .= "`n  At: " e.What "  (" e.File ":" e.Line ")"
    s .= "`n  Stack:`n" RTrim(e.Stack, "`r`n")
    return s
}

ErrWrite(text) {
    try {
        if (FileExist(ERR_LOG) && FileGetSize(ERR_LOG) > 1024 * 1024)
            FileMove(ERR_LOG, DATA_DIR "\errors.old.log", true)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  v" APP_VERSION "  " text "`n`n", ERR_LOG, "UTF-8")
    }
}
