; ==============================================================================
; salesforce.ahk  -  shared Salesforce search helpers
; #Include this from any script (main-helper.ahk, liveCaptionCompanion.ahk).
; It only defines functions, so including it changes nothing on its own.
; ==============================================================================

global SF_SEARCH_PREFIX := "https://case-snow.lightning.force.com/one/one.app#"

; Opens one Salesforce global-search tab. Returns false when the term is empty.
SF_OpenSearch(term) {
    term := Trim(term, " `t`r`n")
    if (term = "")
        return false
    Run(SF_SearchUrl(term))
    return true
}

; Opens a tab for every term, with a short pause so the browser keeps the order.
SF_OpenSearches(terms) {
    opened := 0
    for t in terms {
        if (opened > 0)
            Sleep(350)
        if SF_OpenSearch(t)
            opened += 1
    }
    return opened
}

SF_SearchUrl(term) {
    t := SF_JsonEscape(term)
    payload := '{"componentDef":"forceSearch:searchPageDesktop","attributes":{"term":"' . t
        . '","scopeMap":{"type":"TOP_RESULTS","namespace":"","label":"Top Results","labelPlural":"Top Results","resultsCmp":"forceSearch:predictedResults"},'
        . '"context":{"FILTERS":{},"searchSource":"ASSISTANT_DIALOG","disableIntentQuery":false,"disableSpellCorrection":false,'
        . '"debugInfo":{"appName":"National_Operations","appType":"Standard","appNamespace":"c","location":"force:relatedListDesktop","sobjectType":"Work_Orders__r"}},'
        . '"groupId":"DEFAULT"},"state":{}}'
    return SF_SEARCH_PREFIX . SF_Base64(payload)
}

SF_JsonEscape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := RegExReplace(s, "[\r\n\t]", " ")
    return s
}

; Base64 (UTF-8), no line breaks. Padding is KEPT and URL-encoded as %3D -
; stripping it is what made some searches show "page not found".
SF_Base64(str) {
    size := StrPut(str, "UTF-8") - 1
    buf := Buffer(size + 1)
    StrPut(str, buf, "UTF-8")
    DllCall("Crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", size
        , "UInt", 0x40000001, "Ptr", 0, "UInt*", &len := 0)
    out := Buffer(len * 2)
    DllCall("Crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", size
        , "UInt", 0x40000001, "Ptr", out, "UInt*", &len)
    return StrReplace(StrGet(out, "UTF-16"), "=", "%3D")
}

; ------------------------------------------------------------------------------
; Classify any text (caller field, highlighted caption, clipboard...).
; Returns Map: kind ("phone" | "text"), display, digits, terms (Array of
; search terms). phoneFormats: comma list of dashed, raw, paren.
; ------------------------------------------------------------------------------
SF_Classify(text, phoneFormats := "dashed") {
    text := Trim(RegExReplace(text, "\s+", " "))
    r := Map("kind", "text", "display", text, "digits", "", "terms", [])
    if (text = "")
        return r

    if RegExMatch(text, "^[\d\s+\-().]+$") {
        digits := RegExReplace(text, "\D")
        if (StrLen(digits) = 11 && SubStr(digits, 1, 1) = "1")
            digits := SubStr(digits, 2)
        if (StrLen(digits) >= 7) {
            r["kind"] := "phone"
            r["digits"] := digits
            if (StrLen(digits) = 10) {
                dashed := SubStr(digits, 1, 3) "-" SubStr(digits, 4, 3) "-" SubStr(digits, 7)
                paren := "(" SubStr(digits, 1, 3) ") " SubStr(digits, 4, 3) "-" SubStr(digits, 7)
                r["display"] := dashed
                for f in StrSplit(phoneFormats, ",", " ") {
                    if (f = "dashed")
                        t := dashed
                    else if (f = "raw")
                        t := digits
                    else if (f = "paren")
                        t := paren
                    else
                        continue
                    if !SF_ArrayHas(r["terms"], t)
                        r["terms"].Push(t)
                }
            }
            if (r["terms"].Length = 0)
                r["terms"].Push(digits)     ; not a 10-digit US number: search the digits
            return r
        }
    }
    r["terms"].Push(text)
    return r
}

; "Rojas, Michael" -> "Michael Rojas" (unchanged when there is no comma)
SF_FlipName(name) {
    if RegExMatch(name, "^\s*([^,]+?)\s*,\s*(.+?)\s*$", &m)
        return m[2] " " m[1]
    return name
}

SF_ArrayHas(arr, value) {
    for v in arr
        if (v == value)
            return true
    return false
}
