; ==============================================================================
; notes-resize.ahk  -  drag to resize the VERIFIED INFO / CALL UPDATES box
;
; A thin bar sits between the Chat/Transcript view and the notes box. Drag it
; up to make the notes box taller, down to make it smaller. The size is
; remembered in live-captions.ini ([Window] NotesH). Default = the old size.
; ==============================================================================

notesHeightPx := 100        ; the original fixed size, used until you drag
notesSplitter := ""
NOTES_MIN_H := 70

NotesResizeInit() {
    global notesHeightPx, notesSplitter
    try {
        try notesHeightPx := Integer(IniRead(MIC_INI, "Window", "NotesH", 100))
        notesSplitter := myGui.Add("Text", "x0 y0 w10 h6 +0x100 Background2A3442", "")   ; 0x100 = receives clicks
        OnMessage(0x0201, NotesSplitterDown)       ; WM_LBUTTONDOWN
        OnMessage(0x0020, NotesSplitterCursor)     ; WM_SETCURSOR: show the up/down arrow
        RelayoutMain()
    }
}

; Height used by GuiResize for the notes area (label + box)
NotesHeight() {
    return notesHeightPx
}

; Called from GuiResize: the bar fills the gap above the notes label
NotesSplitterLayout(x, y, w) {
    if IsObject(notesSplitter)
        try notesSplitter.Move(x, y, w, 6)
}

; Called first thing on exit: while the app closes, AutoHotkey clears global
; variables but Windows keeps sending mouse messages to these handlers
NotesResizeShutdown() {
    OnMessage(0x0201, NotesSplitterDown, 0)
    OnMessage(0x0020, NotesSplitterCursor, 0)
}

NotesSplitterCursor(wParam, lParam, msg, hwnd) {
    if (!IsSet(notesSplitter) || !IsObject(notesSplitter))
        return
    if (wParam = notesSplitter.Hwnd) {
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32645, "Ptr"))  ; IDC_SIZENS
        return true
    }
}

NotesSplitterDown(wParam, lParam, msg, hwnd) {
    if (!IsSet(notesSplitter) || !IsObject(notesSplitter) || hwnd != notesSplitter.Hwnd)
        return
    SetTimer(NotesDrag, -1)
    return 0
}

NotesDrag() {
    global notesHeightPx
    try {
        CoordMode("Mouse", "Screen")
        myGui.GetClientPos(, , , &ch)
        MouseGetPos(, &startY)
        startH := notesHeightPx
        while GetKeyState("LButton", "P") {
            MouseGetPos(, &y)
            h := Max(NOTES_MIN_H, Min(startH - (y - startY), Floor(ch * 0.6)))
            if (h != notesHeightPx) {
                notesHeightPx := h
                RelayoutMain()
            }
            Sleep(15)
        }
        IniWrite(notesHeightPx, MIC_INI, "Window", "NotesH")
    }
}
