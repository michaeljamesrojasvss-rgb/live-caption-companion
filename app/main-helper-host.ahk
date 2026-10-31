; ==============================================================================
; main-helper-host.ahk  -  starts main-helper.ahk (extra hotkeys) when enabled
;
; * OFF by default for everyone. Turned on per person from the tray
;   ("Main helper (extra hotkeys)"); saved in live-captions.ini [MainHelper]
;   Enabled, which lives in the user's data folder, so it never ships and
;   updates keep it.
; * The helper runs as its own process: if it fails, captions keep working.
; ==============================================================================

MAINHELPER_ITEM := "Main helper (extra hotkeys)"
mainHelperPid := 0

MainHelperInit() {
    try {
        A_TrayMenu.Insert("1&", MAINHELPER_ITEM, (*) => MainHelperToggle())
        if MainHelperEnabled() {
            A_TrayMenu.Check(MAINHELPER_ITEM)
            MainHelperStart()
        }
    } catch as err {
        MainHelperReport(err)
    }
}

MainHelperShutdown() {
    try MainHelperStop()
}

MainHelperEnabled() {
    try return IniRead(MIC_INI, "MainHelper", "Enabled", "0") = "1"
    return false
}

MainHelperToggle() {
    try {
        on := !MainHelperEnabled()
        IniWrite(on ? 1 : 0, MIC_INI, "MainHelper", "Enabled")
        if on {
            A_TrayMenu.Check(MAINHELPER_ITEM)
            MainHelperStart()
        } else {
            A_TrayMenu.Uncheck(MAINHELPER_ITEM)
            MainHelperStop()
        }
        statusText.Text := "Status: main helper (extra hotkeys) is now " (on ? "on" : "off")
    } catch as err {
        MainHelperReport(err)
    }
}

MainHelperStart() {
    global mainHelperPid
    MainHelperStop()
    path := A_ScriptDir "\main-helper.ahk"
    if !FileExist(path) {
        statusText.Text := "Status: main-helper.ahk not found - extra hotkeys are off (captions unaffected)"
        return
    }
    Run(Format('"{}" "{}" {}', A_AhkPath, path, myGui.Hwnd), A_ScriptDir, , &pid)
    mainHelperPid := pid
}

MainHelperStop() {
    global mainHelperPid
    if (mainHelperPid && ProcessExist(mainHelperPid))
        try ProcessClose(mainHelperPid)
    mainHelperPid := 0
}

MainHelperReport(err) {
    msg := (IsObject(err) && err.HasProp("Message")) ? err.Message : String(err)
    try statusText.Text := "Status: main helper problem (captions unaffected): " msg
}
