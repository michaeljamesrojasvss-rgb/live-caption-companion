#Requires AutoHotkey v2.0
#SingleInstance Force

; ==============================================================================
; edge-bridge-probe.ahk - can the Caption Companion use YOUR Edge (your sign-ins) instead of its
; built-in browser? Dev probe, never shipped. Run it with runtime\AutoHotkey32.exe.
;
;  0. It first shows the company policies that could block this (extensions you load yourself,
;     developer mode, native messaging for your user). Nothing needs admin rights.
;  1. "Open edge://extensions": turn on Developer mode, Load unpacked > pick the folder
;     (the button copies its path), then copy the extension's ID.
;  2. "Register the bridge": paste the ID. Writes host\com.captioncompanion.bridge.json and
;     HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.captioncompanion.bridge (and the
;     same for Chrome) - your user only.
;  3. Click the extension's icon in Edge (pin it from the puzzle-piece menu): the probe window
;     opens and runs the tests. "Copy report" -> paste it to Claude. Also saved in probe-report.txt.
;  "Remove" deletes the registry keys again. The probe never types or sends anything to Copilot.
; ==============================================================================

HOST_NAME := "com.captioncompanion.bridge"
EXT_DIR := A_ScriptDir "\extension"
HOST_JSON := A_ScriptDir "\host\" HOST_NAME ".json"
REG_KEYS := ["HKCU\Software\Microsoft\Edge\NativeMessagingHosts\" HOST_NAME
    , "HKCU\Software\Google\Chrome\NativeMessagingHosts\" HOST_NAME]

g := Gui(, "Edge bridge probe - setup")
g.SetFont("s10", "Segoe UI")
g.Add("Text", "w660 h20", "Company policies that matter (from the registry; edge://policy shows the same):")
pol := g.Add("Edit", "w660 h210 ReadOnly Multi VScroll", PolicyReport())
g.Add("Text", "w660 h20 y+12", "Then, in order:")
g.Add("Button", "w210 h30", "1a. Open edge://extensions").OnEvent("Click", (*) => OpenExtensionsPage())
g.Add("Button", "x+8 w220 h30", "1b. Copy the extension folder").OnEvent("Click", (*) => (A_Clipboard := EXT_DIR, Say("Folder path copied - paste it in Load unpacked")))
g.Add("Button", "xm w210 h30", "2. Register the bridge...").OnEvent("Click", (*) => Register())
g.Add("Button", "x+8 w220 h30", "Remove the registration").OnEvent("Click", (*) => Unregister())
g.Add("Text", "xm w660 h40 y+10", "3. In Edge, click the extension's icon (Caption Companion bridge probe). "
    . "The probe window opens and runs the tests - copy its report to Claude.")
st := g.Add("Text", "xm w660 h40 cGray", RegStatus())
g.Add("Button", "xm w160 h30", "Copy policy report").OnEvent("Click", (*) => (A_Clipboard := pol.Value, Say("Policy report copied")))
g.OnEvent("Close", (*) => ExitApp())
g.Show()

Say(t) => st.Value := t

OpenExtensionsPage() {
    try {
        Run('msedge.exe "edge://extensions"')
        Say("In edge://extensions: switch on Developer mode (bottom left or top right), Load unpacked > the extension folder (1b copies it).")
    } catch as err {
        Say("Could not start Edge: " err.Message)
    }
}

Register() {
    r := InputBox("Paste the extension's ID (32 letters, shown under its name in edge://extensions):", "Register the bridge", "w440 h140")
    if (r.Result != "OK")
        return
    id := Trim(r.Value)
    if !RegExMatch(id, "^[a-p]{32}$") {
        MsgBox("That doesn't look like an extension ID (32 letters a-p).", "Register", "Iconx")
        return
    }
    m := '{`n  "name": "' HOST_NAME '",`n  "description": "Caption Companion bridge (probe)",`n  "path": "host.bat",`n'
        . '  "type": "stdio",`n  "allowed_origins": ["chrome-extension://' id '/"]`n}`n'
    try FileDelete(HOST_JSON)
    FileAppend(m, HOST_JSON, "UTF-8-RAW")
    for k in REG_KEYS
        RegWrite(HOST_JSON, "REG_SZ", k)
    Say("Registered for extension " id ". Now click the extension's icon in Edge.`n" RegStatus())
}

Unregister() {
    for k in REG_KEYS
        try RegDeleteKey(k)
    Say("Registration removed. " RegStatus())
}

RegStatus() {
    s := ""
    for k in REG_KEYS {
        v := ""
        try v := RegRead(k)
        s .= (InStr(k, "Edge") ? "Edge: " : "Chrome: ") (v = "" ? "not registered" : "registered") "   "
    }
    return s
}

; ------------------------------------------------------------------ policies
PolicyReport() {
    out := ""
    for root in ["HKLM", "HKCU"] {
        for b in [["Edge", root "\SOFTWARE\Policies\Microsoft\Edge"], ["Chrome", root "\SOFTWARE\Policies\Google\Chrome"]] {
            found := PolicyLines(b[2])
            out .= b[1] " (" root "): " (found = "" ? "none of the policies below are set`r`n" : "`r`n" found)
        }
    }
    out .= "`r`nWhat they mean:`r`n"
        . "- NativeMessagingUserLevelHosts = 0: a bridge registered for your user is BLOCKED (would need IT).`r`n"
        . "- NativeMessagingBlocklist containing * (and our name not in the Allowlist): bridge BLOCKED.`r`n"
        . "- ExtensionInstallBlocklist containing * (and no Allowlist for it): loading the extension is BLOCKED.`r`n"
        . "- ExtensionDeveloperModeSettings = 1, or DeveloperToolsAvailability = 2: no Developer mode = no Load unpacked.`r`n"
        . "- ExtensionAllowedTypes without `"extension`": BLOCKED.`r`n"
        . "Nothing listed = probably allowed (the test in step 3 is the real answer)."
    return out
}

PolicyLines(key) {
    s := ""
    for name in ["NativeMessagingUserLevelHosts", "DeveloperToolsAvailability", "ExtensionDeveloperModeSettings", "BlockExternalExtensions"] {
        try {
            v := RegRead(key, name)
            s .= "   " name " = " v "`r`n"
        }
    }
    for name in ["NativeMessagingBlocklist", "NativeMessagingAllowlist", "ExtensionInstallBlocklist", "ExtensionInstallAllowlist"
            , "ExtensionAllowedTypes", "ExtensionInstallForcelist"] {
        vals := ""
        try {
            Loop Reg, key "\" name, "V"
                vals .= (vals = "" ? "" : ", ") RegRead()
        }
        if (vals != "")
            s .= "   " name ": " vals "`r`n"
    }
    try {
        v := RegRead(key, "ExtensionSettings")
        s .= "   ExtensionSettings (JSON): " SubStr(v, 1, 300) (StrLen(v) > 300 ? "..." : "") "`r`n"
    }
    return s
}
