; ==============================================================================
; chat-view.ahk  -  the Chat view's text box (prefix ChatView*)
;
; A RichEdit control (msftedit.dll, part of Windows), so bubbles can sit on either
; side: the customer's on the left, the agent's on the right (speaker detection),
; "not sure who" ones faded. Long text wraps inside its own side.
; If RichEdit can't be loaded, it is the plain Edit box from before (agent bubbles
; pushed right with spaces) - the rest of the app doesn't notice the difference.
;
; The app hands it a list of items and asks it questions back:
;   ChatViewCreate(gui, opts)          -> the control (opts: Gui position options)
;   ChatViewRender(ctrl, items)        items: [{text, side: "left"|"right", faded, ref}]
;                                      keeps the highlight and the scroll position; follows
;                                      new text when scrolled to the bottom
;   ChatViewItemAt(pos)                -> the item at a character position ("" = none)
;   ChatViewCharFromPos(ctrl, x, y)    -> character position under a client point
;   ChatViewGetSel(ctrl, &s, &e)       -> the highlight (character positions)
;   ChatViewSelText(ctrl)              -> the highlighted text, bubble markers removed
;   ChatViewSetFontSize(ctrl, pt)      -> A- / A+ (the next render uses it)
; Colours: CHATVIEW_COLORS. Spacing: CHATVIEW_SIDE_TWIPS (how far the other side's
; text stays away), CHATVIEW_GAP_TWIPS (space between bubbles).
; ==============================================================================

CHATVIEW_COLORS := Map("bg", "1B2431", "left", "F1F5FB", "right", "67E8F9", "faded", "94A3B8")
CHATVIEW_FONT := "Segoe UI"
CHATVIEW_SIDE_TWIPS := 1200        ; ~0.8 inch kept free on the other side of each bubble
CHATVIEW_GAP_TWIPS := 160          ; space after each bubble
CHATVIEW_PLAIN_INDENT := "                                        "   ; plain mode: 40 spaces push agent bubbles right

chatViewRich := false              ; true = RichEdit, false = plain Edit fallback
chatViewItems := []                ; the items on screen, each with .start / .end (character positions)
chatViewLast := ""                 ; what was last put in (RTF or plain text): unchanged = nothing to do
chatViewFontPt := 10

ChatViewCreate(gui, opts) {
    global chatViewRich
    try {
        if DllCall("LoadLibrary", "Str", "msftedit.dll", "Ptr") {
            ; ES_MULTILINE | ES_AUTOVSCROLL | ES_NOHIDESEL | ES_READONLY | WS_VSCROLL, sunken edge like the Edit boxes
            ctrl := gui.Add("Custom", "ClassRICHEDIT50W " opts " +0x200944 +E0x200")
            bg := CHATVIEW_COLORS["bg"]
            SendMessage(0x0443, 0, ChatViewBgr(bg), ctrl.Hwnd)          ; EM_SETBKGNDCOLOR
            SendMessage(0x0435, 0, 0x7FFFFFFF, ctrl.Hwnd)               ; EM_EXLIMITTEXT: no 32K cap
            chatViewRich := true
            return ctrl
        }
    }
    chatViewRich := false
    return gui.Add("Edit", opts " ReadOnly +0x100 Background" CHATVIEW_COLORS["bg"] " c" CHATVIEW_COLORS["left"])
}

ChatViewIsRich() => chatViewRich

ChatViewSetFontSize(ctrl, pt) {
    global chatViewFontPt, chatViewLast
    chatViewFontPt := pt
    chatViewLast := ""                                 ; force the next render
    if !chatViewRich
        ctrl.SetFont("s" pt)
}

; ------------------------------------------------------------------------------
; Rendering
; ------------------------------------------------------------------------------
ChatViewRender(ctrl, items) {
    if chatViewRich
        ChatViewRenderRich(ctrl, items)
    else
        ChatViewRenderPlain(ctrl, items)
}

; What a bubble looks like as plain text (both modes: the character positions follow it)
ChatViewPlainPara(it) {
    if chatViewRich
        return it.side = "right" ? it.text " ▐" : (it.faded ? "? " : "▌ ") it.text
    if (it.side = "right")
        return CHATVIEW_PLAIN_INDENT (it.faded ? "░ " : "▐ ") it.text
    return (it.faded ? "▌? " : "▌ ") it.text
}

ChatViewRenderPlain(ctrl, items) {
    global chatViewItems, chatViewLast
    text := "", pos := 0
    for it in items {
        para := ChatViewPlainPara(it)
        if (A_Index > 1) {
            text .= "`r`n`r`n"
            pos += 4
        }
        it.start := pos, it.end := pos + StrLen(para)
        text .= para
        pos := it.end
    }
    chatViewItems := items
    if (text == chatViewLast)
        return
    chatViewLast := text
    SetEditText(ctrl, text)
}

ChatViewRenderRich(ctrl, items) {
    global chatViewItems, chatViewLast
    c := CHATVIEW_COLORS
    rtf := "{\rtf1\ansi\deff0{\fonttbl{\f0 " CHATVIEW_FONT ";}}{\colortbl;" ChatViewRtfColor(c["left"])
        . ChatViewRtfColor(c["right"]) ChatViewRtfColor(c["faded"]) "}\uc1\f0\fs" (chatViewFontPt * 2) " "
    pos := 0
    for it in items {
        para := ChatViewPlainPara(it)
        it.start := pos, it.end := pos + StrLen(para)
        pos := it.end + 1                              ; RichEdit ends a paragraph with one CR
        if (it.side = "right")
            fmt := "\pard\qr\li" CHATVIEW_SIDE_TWIPS "\ri0\sa" CHATVIEW_GAP_TWIPS "\cf" (it.faded ? 3 : 2) (it.faded ? "\i " : " ")
        else
            fmt := "\pard\ql\li0\ri" CHATVIEW_SIDE_TWIPS "\sa" CHATVIEW_GAP_TWIPS "\cf" (it.faded ? 3 : 1) (it.faded ? "\i " : " ")
        rtf .= fmt ChatViewRtfEsc(para) (it.faded ? "\i0" : "") "\par "
    }
    rtf .= "}"
    chatViewItems := items
    if (rtf == chatViewLast)
        return
    chatViewLast := rtf

    hwnd := ctrl.Hwnd
    cr := Buffer(8, 0)
    SendMessage(0x0434, 0, cr, hwnd)                   ; EM_EXGETSEL: keep the highlight
    s := NumGet(cr, 0, "Int"), e := NumGet(cr, 4, "Int")
    firstLine := SendMessage(0x00CE, 0, 0, hwnd)       ; EM_GETFIRSTVISIBLELINE
    atBottom := IsScrolledToBottom(hwnd)

    SendMessage(0x000B, 0, 0, hwnd)                    ; WM_SETREDRAW off: no flicker while replacing
    st := Buffer(8, 0)                                 ; SETTEXTEX {flags = ST_DEFAULT, codepage = ACP}
    bytes := Buffer(StrPut(rtf, "CP0"))
    StrPut(rtf, bytes, "CP0")                          ; pure ASCII: everything else is \uN escaped
    SendMessage(0x0461, st, bytes, hwnd)               ; EM_SETTEXTEX
    if (e > s)
        SendMessage(0x0437, 0, cr, hwnd)               ; EM_EXSETSEL
    SendMessage(0x000B, 1, 0, hwnd)                    ; WM_SETREDRAW on

    if atBottom
        SendMessage(0x0115, 7, 0, hwnd)                ; at the bottom: follow new text
    else
        RestoreFirstLine(hwnd, firstLine)              ; scrolled up: stay where you are
    DllCall("RedrawWindow", "Ptr", hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
}

; Text -> RTF: \ { } escaped, anything past ASCII as \uN? (UTF-16 units, signed)
ChatViewRtfEsc(s) {
    s := StrReplace(StrReplace(StrReplace(s, "\", "\\"), "{", "\{"), "}", "\}")
    if !RegExMatch(s, "[^\x00-\x7F]")
        return s
    out := ""
    Loop Parse s {
        c := Ord(A_LoopField)
        if (c < 128)
            out .= A_LoopField
        else if (c > 0xFFFF)                           ; emoji etc.: two UTF-16 units, as RichEdit counts them
            out .= ChatViewRtfU(0xD800 + ((c - 0x10000) >> 10)) ChatViewRtfU(0xDC00 + ((c - 0x10000) & 0x3FF))
        else
            out .= ChatViewRtfU(c)
    }
    return out
}

ChatViewRtfU(u) => "\u" (u > 32767 ? u - 65536 : u) "?"

ChatViewRtfColor(hex) {
    return "\red" Integer("0x" SubStr(hex, 1, 2)) "\green" Integer("0x" SubStr(hex, 3, 2)) "\blue" Integer("0x" SubStr(hex, 5, 2)) ";"
}

ChatViewBgr(hex) => Integer("0x" SubStr(hex, 5, 2) SubStr(hex, 3, 2) SubStr(hex, 1, 2))

; ------------------------------------------------------------------------------
; Questions back: what is where, what is highlighted
; ------------------------------------------------------------------------------
ChatViewItemAt(pos) {
    for it in chatViewItems {
        nextStart := A_Index < chatViewItems.Length ? chatViewItems[A_Index + 1].start : 0x7FFFFFFF
        if (pos >= it.start && pos < nextStart)       ; the gap after a bubble belongs to it
            return it
    }
    return ""
}

ChatViewCharFromPos(ctrl, x, y) {
    pt := Buffer(8, 0)
    NumPut("Int", x, pt, 0)
    NumPut("Int", y, pt, 4)
    r := SendMessage(0x00D7, 0, pt, ctrl.Hwnd)        ; EM_CHARFROMPOS
    return chatViewRich ? r : r & 0xFFFF              ; RichEdit: the index; Edit: low word
}

ChatViewGetSel(ctrl, &s, &e) {
    if chatViewRich {
        cr := Buffer(8, 0)
        SendMessage(0x0434, 0, cr, ctrl.Hwnd)          ; EM_EXGETSEL
        s := NumGet(cr, 0, "Int"), e := NumGet(cr, 4, "Int")
        return
    }
    sb := Buffer(4, 0), eb := Buffer(4, 0)
    SendMessage(0x00B0, sb, eb, ctrl.Hwnd)             ; EM_GETSEL
    s := NumGet(sb, 0, "UInt"), e := NumGet(eb, 0, "UInt")
}

; The highlighted text without the bubble markers ("" = nothing highlighted)
ChatViewSelText(ctrl) {
    ChatViewGetSel(ctrl, &s, &e)
    if (e <= s)
        return ""
    if chatViewRich {
        buf := Buffer((e - s + 1) * 2, 0)
        SendMessage(0x043E, 0, buf, ctrl.Hwnd)         ; EM_GETSELTEXT
        text := StrGet(buf, "UTF-16")
    } else {
        len := SendMessage(0x000E, 0, 0, ctrl.Hwnd)    ; the raw text: .Value turns CRLF into LF
        raw := Buffer((len + 1) * 2, 0)
        SendMessage(0x000D, len + 1, raw, ctrl.Hwnd)
        text := SubStr(StrGet(raw, "UTF-16"), s + 1, e - s)
    }
    text := RegExReplace(text, "[▌▐░]|(?<=^|\r|\n)\? ", " ")
    return Trim(RegExReplace(text, "[ \t]+", " "), " `t`r`n")
}
