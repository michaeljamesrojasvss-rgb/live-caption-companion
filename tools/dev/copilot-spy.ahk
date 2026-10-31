#Requires AutoHotkey v2.0
#SingleInstance Force
#Include %A_ScriptDir%\..\..\app\UIA.ahk

; ==============================================================================
; Copilot UIA spy — run this with Copilot (Win+C) already open,
; then press Ctrl+Shift+F1 to dump the element tree to a text file
; and open it in Notepad automatically.
; ==============================================================================

^+F1:: {
    output := ""

    ; Find ANY visible Copilot-related window — mini OR full chat
    hwnd := 0
    for w in WinGetList() {
        try {
            t := WinGetTitle("ahk_id " w)
            e := WinGetProcessName("ahk_id " w)
            if (InStr(t, "Copilot") || InStr(e, "opilot")) {
                hwnd := w
                break
            }
        }
    }

    if !hwnd {
        MsgBox("No Copilot window found.`n`nOpen Copilot (Win+C) first, then press Ctrl+Shift+F1.", "Copilot spy", "Icon!")
        return
    }

    try {
        root := UIA.ElementFromHandle(hwnd)
        output := "=== Copilot UIA tree ===`n"
            . "Window HWND: " hwnd "`n"
            . "Window title: " WinGetTitle("ahk_id " hwnd) "`n`n"

        ; First: targeted search for any editable/input elements at any depth
        output .= "=== EDIT/INPUT ELEMENTS (any depth) ===`n"
        edits := []
        FindEdits(root, 0, &edits)
        if edits.Length = 0
            output .= "(none found)`n"
        for e in edits
            output .= e "`n"
        output .= "`n=== FULL TREE (depth 0-12) ===`n"
        output .= DumpElement(root, 0)
    } catch as err {
        output := "Error reading UIA tree: " err.Message
    }

    path := A_ScriptDir "\copilot-spy-output.txt"
    try FileDelete(path)
    FileAppend(output, path, "UTF-8")
    Run('notepad.exe "' path '"')
    MsgBox("Done! Check copilot-spy-output.txt`n`nLook for elements with Type=Edit (the chat input)`nand Type=Text/Document (the response area).", "Copilot spy", "Iconi")
}

DumpElement(el, depth) {
    indent := ""
    Loop depth
        indent .= "  "

    name := "", atype := "", aid := "", cls := "", value := ""
    try name  := el.Name
    try atype := el.Type
    try aid   := el.AutomationId
    try cls   := el.ClassName
    try value := el.Value

    line := indent
        . "[" atype "]"
        . (aid   != "" ? " id=" aid   : "")
        . (cls   != "" ? " cls=" cls  : "")
        . (name  != "" ? ' name="' SubStr(name, 1, 80) '"' : "")
        . (value != "" ? ' val="'  SubStr(value, 1, 60) '"' : "")
        . "`n"

    ; Don't recurse too deep — Copilot's WebView2 tree can be huge
    if (depth >= 12)
        return line . indent . "  ...(too deep)`n"

    try {
        children := el.GetChildren()
        for child in children
            line .= DumpElement(child, depth + 1)
    }

    return line
}

; Recursively find Edit / Document / RichEdit type elements at any depth
FindEdits(el, depth, &results) {
    atype := 0
    name  := ""
    aid   := ""
    cls   := ""
    try atype := el.Type
    try name  := el.Name
    try aid   := el.AutomationId
    try cls   := el.ClassName

    ; 50004=Edit, 50019=Document, 50025=Custom (contenteditable often shows as these)
    if (atype = 50004 || atype = 50019 || atype = 50025)
        results.Push("depth=" depth " type=" atype " id=" aid " cls=" cls ' name="' SubStr(name,1,80) '"')

    if (depth >= 25)
        return
    try {
        for child in el.GetChildren()
            FindEdits(child, depth + 1, results)
    }
}

MsgBox("Copilot spy loaded.`n`nSteps:`n1. Open Copilot with Win+C`n2. Press Ctrl+Shift+F1`n3. Wait a moment for the tree dump`n`nThe output opens in Notepad automatically.", "Copilot spy", "Iconi")
