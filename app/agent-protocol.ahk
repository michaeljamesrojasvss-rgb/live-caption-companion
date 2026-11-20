; ==============================================================================
; agent-protocol.ahk  -  how the agent talks to a chat AI that has no tools of its own (prefix AgtProto*)
;
; * Messages to the AI are templates: app\agent\instructions.md, one section per message ("=== name ===",
;   lines starting with ";;" are notes). A file of the same name in data\agent\ replaces single sections.
; * The AI replies with ONE JSON object: {"tool": name, "args": {...}, "why": "..."} or {"final": "..."}.
;   AgtProtoParse finds it anywhere in the answer text: in a code block, with prose around it, with curly
;   quotes - Copilot's answers come as formatted text, Google's as the page's plain text.
; * Pure functions: no windows, no files except the templates, no state. Needs Json.ahk.
; ==============================================================================

; Section name -> text, from each folder's instructions.md in order (later folders replace sections)
AgtProtoLoadTemplates(dirs) {
    t := Map()
    t.CaseSense := false
    for dir in dirs {
        path := dir "\instructions.md"
        if !FileExist(path)
            continue
        name := "", buf := ""
        for line in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
            if RegExMatch(line, "^===\s*([\w-]+)\s*===\s*$", &m) {
                if (name != "")
                    t[name] := Trim(buf, "`r`n")
                name := m[1], buf := ""
            } else if (name != "" && SubStr(LTrim(line), 1, 2) != ";;") {
                buf .= line "`n"
            }
        }
        if (name != "")
            t[name] := Trim(buf, "`r`n")
    }
    return t
}

; A template with its {{placeholders}} filled in (vars: Map name -> text). A missing section = an error.
AgtProtoFill(templates, name, vars) {
    if !templates.Has(name)
        throw Error("the agent's instructions have no `"" name "`" section (app\agent\instructions.md)")
    s := templates[name]
    for k, v in vars
        s := StrReplace(s, "{{" k "}}", v)
    return s
}

; The TOOLS part of the first message: one block per tool (name, what it does, its argument schema)
AgtProtoToolList(tools, vars) {
    out := ""
    for name, tool in tools {
        desc := tool.description
        for k, v in vars
            desc := StrReplace(desc, "{{" k "}}", v)
        out .= "- " name (tool.approval = "ask" ? " (asks me first)" : "") ": " desc "`n"
            . "  args (JSON Schema): " AgtProtoJson(tool.schema) "`n"
    }
    return RTrim(out, "`n")
}

; ------------------------------------------------------------------------------
; Reading the AI's reply
; -> {kind: "tool", name, args (Map), why, count} | {kind: "final", text, count} | {kind: "none", error}
;    count = how many tool/final objects the reply had (only the first one is used)
; ------------------------------------------------------------------------------
AgtProtoParse(text) {
    found := AgtProtoObjects(text)
    if !found.Length {                           ; "smart" quotes from a chat page's formatting
        plain := StrReplace(StrReplace(StrReplace(StrReplace(text, Chr(0x201C), '"'), Chr(0x201D), '"'), Chr(0x2018), "'"), Chr(0x2019), "'")
        if (plain != text)
            found := AgtProtoObjects(plain)
    }
    if !found.Length
        return {kind: "none", error: 'there was no JSON object with "tool" or "final" in it'}
    o := found[1]
    if o.Has("final") {
        f := o["final"]
        return {kind: "final", text: IsObject(f) ? AgtProtoJson(f) : String(f), count: found.Length}
    }
    name := o["tool"]
    if (IsObject(name) || Trim(String(name)) = "")
        return {kind: "none", error: "`"tool`" must be a tool's name"}
    args := o.Has("args") ? o["args"] : Map()
    if (!IsObject(args) && args = "")
        args := Map()
    if !(args is Map)
        return {kind: "none", error: '"args" must be a JSON object'}
    why := (o.Has("why") && !IsObject(o["why"])) ? String(o["why"]) : ""
    return {kind: "tool", name: Trim(String(name)), args: args, why: why, count: found.Length}
}

; Every top-level {...} in the text that is valid JSON with a "tool" or "final" key, in order
AgtProtoObjects(text) {
    out := [], pos := 1
    while (pos := InStr(text, "{", true, pos)) {
        end := AgtProtoMatchBrace(text, pos)
        if end {
            try {
                o := Json.Parse(SubStr(text, pos, end - pos + 1))
                if (o is Map && (o.Has("tool") || o.Has("final"))) {
                    out.Push(o)
                    pos := end + 1
                    continue
                }
            }
        }
        pos += 1                                 ; not one of ours: look inside / further on
    }
    return out
}

; Position of the "}" that closes the "{" at pos (strings and escapes respected), 0 if it never closes
AgtProtoMatchBrace(text, pos) {
    depth := 0, quoted := false, esc := false
    Loop StrLen(text) - pos + 1 {
        i := pos + A_Index - 1
        c := SubStr(text, i, 1)
        if quoted {
            if esc
                esc := false
            else if (c = "\")
                esc := true
            else if (c = '"')
                quoted := false
            continue
        }
        if (c = '"')
            quoted := true
        else if (c = "{")
            depth += 1
        else if (c = "}") {
            depth -= 1
            if (depth = 0)
                return i
        }
    }
    return 0
}

; Compact one-line JSON (Json.Stringify writes it indented over many lines)
AgtProtoJson(v) {
    if (v is Map) {
        out := ""
        for k, val in v
            out .= (out = "" ? "" : ",") Json.Stringify(String(k)) ":" AgtProtoJson(val)
        return "{" out "}"
    }
    if (v is Array) {
        out := ""
        for val in v
            out .= (out = "" ? "" : ",") AgtProtoJson(val)
        return "[" out "]"
    }
    return Json.Stringify(v)
}

; Text cut to at most max characters, saying how much was left out
AgtProtoCut(text, max) {
    if (max <= 0 || StrLen(text) <= max)
        return text
    return SubStr(text, 1, max) "`n[... cut: " (StrLen(text) - max) " more characters not shown]"
}
