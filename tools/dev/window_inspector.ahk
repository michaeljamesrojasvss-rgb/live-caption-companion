#Requires AutoHotkey v2.0
#SingleInstance Force
; ==========================================================================
;  Window Inspector (like Ctrl+Shift+C in a browser, but for any window)
;
;  Ctrl+Shift+C  -> start inspecting (hover to highlight elements)
;  Left click    -> copy the element's text (phone number only, if one is found)
;  Esc           -> cancel
;
;  Uses Windows UI Automation directly - no extra libraries needed.
; ==========================================================================
CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

global UIA := ComObject("{ff48dba4-60ef-4201-aa87-54103eef594e}"   ; CUIAutomation
                     , "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")   ; IUIAutomation
global Inspecting := false
global LastInfo := ""
global Frame := []

; Four thin click-through windows that form the red highlight box
Loop 4 {
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x80020")  ; layered + click-through
    g.BackColor := "FF3B30"
    Frame.Push(g)
}

^+c:: ToggleInspect()

#HotIf Inspecting
LButton:: CopyAndStop()
Esc:: StopInspect()
#HotIf

; --------------------------------------------------------------------------
ToggleInspect() {
    global Inspecting
    if Inspecting {
        StopInspect()
        return
    }
    Inspecting := true
    SetTimer InspectTick, 60
}

StopInspect() {
    global Inspecting := false
    SetTimer InspectTick, 0
    for g in Frame
        g.Hide()
    ToolTip
}

InspectTick() {
    global LastInfo
    MouseGetPos &mx, &my
    info := ElementInfoAt(mx, my)
    if !info
        return
    LastInfo := info
    ShowFrame(info.x, info.y, info.w, info.h)
    ToolTip Format("Name:  {}`nValue:  {}`nType:  {}`nAutomationId:  {}`nClass:  {}`n`n[Click] copy    [Esc] cancel"
        , Short(info.name), Short(info.value), info.type, info.id, info.cls), mx + 20, my + 20
}

CopyAndStop() {
    global LastInfo
    StopInspect()
    if !LastInfo
        return
    txt := LastInfo.value != "" ? LastInfo.value : LastInfo.name
    ; If the text contains something that looks like a phone number, copy just that
    if RegExMatch(txt, "\+?\d[\d\s\-().]{5,}\d", &m)
        txt := RegExReplace(m[0], "[^\d+]")
    A_Clipboard := txt
    ToolTip "Copied: " txt
    SetTimer () => ToolTip(), -2000
}

; --------------------------------------------------------------------------
;  UI Automation helpers
; --------------------------------------------------------------------------
ElementInfoAt(x, y) {
    el := 0
    try ComCall(7, UIA, "int64", (x & 0xFFFFFFFF) | (y << 32), "ptr*", &el)  ; ElementFromPoint
    if !el
        return ""
    info := {}
    info.name  := GetBstr(el, 23)   ; CurrentName
    info.type  := GetBstr(el, 22)   ; CurrentLocalizedControlType
    info.id    := GetBstr(el, 29)   ; CurrentAutomationId
    info.cls   := GetBstr(el, 30)   ; CurrentClassName
    info.value := GetValue(el)
    rc := Buffer(16, 0)
    try ComCall(43, el, "ptr", rc)  ; CurrentBoundingRectangle
    info.x := NumGet(rc, 0, "int"), info.y := NumGet(rc, 4, "int")
    info.w := NumGet(rc, 8, "int") - info.x
    info.h := NumGet(rc, 12, "int") - info.y
    ObjRelease(el)
    return info
}

GetBstr(el, vtIndex) {
    bstr := 0
    try ComCall(vtIndex, el, "ptr*", &bstr)
    if !bstr
        return ""
    s := StrGet(bstr, "UTF-16")
    DllCall("OleAut32\SysFreeString", "ptr", bstr)
    return s
}

GetValue(el) {   ; ValuePattern.Value (text boxes, some labels)
    v := Buffer(24, 0)
    try ComCall(10, el, "int", 30045, "ptr", v)  ; GetCurrentPropertyValue(UIA_ValueValuePropertyId)
    catch
        return ""
    s := ""
    if NumGet(v, 0, "ushort") = 8 {             ; VT_BSTR
        p := NumGet(v, 8, "ptr")
        if p
            s := StrGet(p, "UTF-16")
    }
    DllCall("OleAut32\VariantClear", "ptr", v)
    return s
}

ShowFrame(x, y, w, h) {
    t := 3
    if (w < 1 || h < 1)
        return
    Frame[1].Show(Format("NA x{} y{} w{} h{}", x, y, w, t))
    Frame[2].Show(Format("NA x{} y{} w{} h{}", x, y + h - t, w, t))
    Frame[3].Show(Format("NA x{} y{} w{} h{}", x, y, t, h))
    Frame[4].Show(Format("NA x{} y{} w{} h{}", x + w - t, y, t, h))
}

Short(s) => StrLen(s) > 60 ? SubStr(s, 1, 60) "…" : s
