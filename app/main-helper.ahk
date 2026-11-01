#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\salesforce.ahk
#Include %A_ScriptDir%\copy-indicator.ahk     ; Ctrl+C/X/V badge, Ctrl+Shift+Alt+I on/off
#Include %A_ScriptDir%\vdesk.ahk              ; wheel over the taskbar = switch virtual desktops, Ctrl+Shift+Alt+D on/off

; ==============================================================================
; main-helper.ahk  -  extra hotkeys, OFF by default
;
; * Started by liveCaptionCompanion.ahk as its OWN process, only when
;   tray > "Main helper (extra hotkeys)" is ticked (saved per person in
;   live-captions.ini [MainHelper] Enabled). If this script errors or is
;   closed, the companion and its captions keep running.
; * Exits by itself when the companion closes.
; * Run it on its own (double-click) to try new hotkeys.
; ==============================================================================

MH_TARGET := (A_Args.Length >= 1 && IsInteger(A_Args[1])) ? Integer(A_Args[1]) : 0
if MH_TARGET {
    A_IconHidden := true
    SetTimer(MH_CheckCompanion, 2000)
}

MH_CheckCompanion() {
    DetectHiddenWindows(true)
    if !WinExist("ahk_id " MH_TARGET)
        ExitApp()
}

; ==============================================================================
; Hotkey Configuration
; ^+` = Ctrl + Shift + Backtick
; ==============================================================================
^+`:: {
    ; Define which terminal you want to use (Uncomment ONLY ONE)
    targetTitle := "ahk_exe cmd.exe"
    launchCmd := "cmd.exe"

    ; If you prefer PowerShell, uncomment the two lines below and comment out the cmd ones:
    ; targetTitle := "ahk_exe powershell.exe"
    ; launchCmd := "powershell.exe"

    ; Check if an Admin instance of the terminal already exists
    if WinExist(targetTitle) {
        if WinActive(targetTitle) {
            WinMinimize(targetTitle)
        } else {
            WinActivate(targetTitle)
        }
    } else {
        ; Launch the terminal with Admin privileges ("RunAs")
        try {
            Run("*RunAs " . launchCmd)
        } catch as err {
            ; Handles the case where you click "No" on the UAC prompt
            ToolTip("Terminal elevation cancelled.")
            SetTimer(() => ToolTip(), -2000)
        }
    }
}

; ==============================================================================
; Ctrl + Shift + Alt + S = Salesforce global search for the clipboard text
; Ctrl + Shift + Alt + C = ServiceChannel work order for the clipboard ID
; ==============================================================================
^+!s:: {
    term := ClipboardTerm()
    if (term = "")
        return
    SF_OpenSearch(term)                 ; shared helper in salesforce.ahk
}

^+!c:: {
    id := ClipboardTerm()
    if (id = "")
        return
    if !RegExMatch(id, "^[\w-]+$") {
        Tip("Clipboard doesn't contain a valid work order ID.")
        return
    }
    Run("https://www.servicechannel.com/sc/wo/workorders/list?id=" . id)
}

; Clipboard text, trimmed; "" (with a tooltip) when it's empty or too long to be a search
ClipboardTerm() {
    t := Trim(A_Clipboard, " `t`r`n")
    if (t = "" || StrLen(t) > 120) {
        Tip("Copy an ID, number or name first.")
        return ""
    }
    return t
}

Tip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -2000)
}
