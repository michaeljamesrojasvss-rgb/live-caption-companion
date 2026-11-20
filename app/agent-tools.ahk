; ==============================================================================
; agent-tools.ahk  -  the agent's tools: registry + built-in handlers (prefix AgtTools*, handlers AgtT_*)
;
; * A tool = a description in MCP shape (name, title, description, inputSchema = JSON Schema) in
;   <dir>\tools\*.json, plus "approval" (auto | ask) and "handler": the AHK function AgtT_<handler>.
;   A tool in data\agent\tools\ with the same name replaces the shipped one. Later, tools from real MCP
;   servers get the same shape (docs\AGENT.md > Increments).
; * Your own choice per tool overrides its approval: data\agent.ini [Approval] <tool>=auto|ask|off
;   (off = the AI never sees it).
; * A handler: AgtT_X(args (Map), ctx) -> Map("text", result text [, "images", [PNG paths]]).
;   It throws an Error with a plain-words message when it can't do it (the AI gets that message).
;   ctx = {runId, step, folders: [allowed folders], readMaxKB, shotMaxSide, imageDir}
; * Handlers never write to logs: tool results are task content.
; Needs Json.ahk, screen-grab.ahk.
; ==============================================================================

; -> {tools: Map name -> tool, problems: [text]}
;    tool = {name, title, description, schema (Map), approval, group, handler (Func)}
AgtToolsLoad(dirs, overrides) {
    tools := Map(), problems := []
    tools.CaseSense := false
    for dir in dirs {
        Loop Files dir "\tools\*.json" {
            file := A_LoopFileName
            try {
                doc := Json.Parse(FileRead(A_LoopFileFullPath, "UTF-8"))
                group := doc.Get("group", StrReplace(file, ".json"))
                for t in doc.Get("tools", []) {
                    try {
                        tool := AgtToolsMake(t, group)
                        tools[tool.name] := tool
                    } catch as err {
                        problems.Push(file ": " err.Message)
                    }
                }
            } catch as err {
                problems.Push(file ": couldn't read it (" err.Message ")")
            }
        }
    }
    for name, mode in overrides {
        if !tools.Has(name)
            continue
        if (mode = "off")
            tools.Delete(name)
        else if (mode = "auto" || mode = "ask")
            tools[name].approval := StrLower(mode)
        else
            problems.Push("[Approval] " name "=" mode ": use auto, ask or off")
    }
    return {tools: tools, problems: problems}
}

AgtToolsMake(t, group) {
    if !(t is Map)
        throw Error("a tool entry isn't a JSON object")
    name := t.Get("name", "")
    if !RegExMatch(name, "^[A-Za-z][A-Za-z0-9_-]{0,63}$")
        throw Error("tool name `"" name "`" isn't valid (letters, digits, _ and -)")
    h := t.Get("handler", "")
    fn := 0
    if RegExMatch(h, "^\w+$")
        try fn := %"AgtT_" h%
    if !(fn is Func)
        throw Error(name ": no handler AgtT_" h " in agent-tools.ahk")
    schema := t.Get("inputSchema", 0)
    if !(schema is Map) {
        schema := Map("type", "object", "properties", Map())
    }
    approval := StrLower(t.Get("approval", "ask"))
    if (approval != "auto")
        approval := "ask"                        ; anything unclear asks you first
    return {name: name, title: t.Get("title", name), description: t.Get("description", ""), schema: schema,
        approval: approval, group: group, handler: fn}
}

; "" when the arguments fit the tool's schema (required ones there, simple types right), else why not
AgtToolsCheckArgs(tool, args) {
    props := tool.schema.Get("properties", Map())
    for k in tool.schema.Get("required", [])
        if (!args.Has(k) || (!IsObject(args[k]) && Trim(String(args[k])) = ""))
            return 'the argument "' k '" is required'
    if !(props is Map)
        return ""
    for k, v in args {
        if !props.Has(k) || !(props[k] is Map)
            continue                             ; extra arguments are ignored
        p := props[k]
        want := p.Get("type", "")
        ok := want = "" ? true
            : want = "string" ? !IsObject(v)
            : want = "integer" ? (!IsObject(v) && IsInteger(v))
            : want = "number" ? (!IsObject(v) && IsNumber(v))
            : want = "boolean" ? (!IsObject(v) && RegExMatch(String(v), "i)^(0|1|true|false)$"))
            : want = "object" ? (v is Map)
            : want = "array" ? (v is Array)
            : true
        if !ok
            return 'the argument "' k '" must be a ' want
        if (p.Has("enum") && p["enum"] is Array) {
            hit := false
            for e in p["enum"]
                if (!IsObject(v) && String(e) == String(v))
                    hit := true
            if !hit
                return 'the argument "' k '" must be one of: ' AgtProtoJson(p["enum"])
        }
    }
    return ""
}

; ------------------------------------------------------------------------------
; Allowed folders: a path is used only if it is one of them or inside one ("..", "/" and
; relative-path tricks are resolved first). A relative path counts from the first allowed folder.
; ------------------------------------------------------------------------------
AgtToolsResolve(path, folders) {
    path := Trim(StrReplace(path, "/", "\"), " `t`"'")
    if !folders.Length
        throw Error("no folder is allowed (AllowedFolders in data\agent.ini)")
    if (path = "")
        path := folders[1]
    else if !RegExMatch(path, "^([A-Za-z]:\\|\\\\)")
        path := folders[1] "\" path
    full := AgtToolsFullPath(path)
    for f in folders {
        ff := AgtToolsFullPath(f)
        if (full = ff || SubStr(full, 1, StrLen(ff) + 1) = ff "\")
            return full
    }
    throw Error(full " is outside the allowed folders (" AgtToolsFolderText(folders) ")")
}

AgtToolsFullPath(p) {
    n := DllCall("GetFullPathNameW", "WStr", p, "UInt", 0, "Ptr", 0, "Ptr", 0, "UInt")
    if !n
        throw Error('"' p '" is not a valid path')
    buf := Buffer(n * 2 + 2, 0)
    DllCall("GetFullPathNameW", "WStr", p, "UInt", n, "Ptr", buf, "Ptr", 0, "UInt")
    return RTrim(StrGet(buf, "UTF-16"), "\")
}

AgtToolsFolderText(folders) {
    out := ""
    for f in folders
        out .= (out = "" ? "" : "; ") f
    return out = "" ? "(none)" : out
}

; ------------------------------------------------------------------------------
; Built-in handlers (app\agent\tools\core.json)
; ------------------------------------------------------------------------------
AgtT_GetTime(args, ctx) {
    off := DateDiff(A_Now, A_NowUTC, "Minutes")
    sign := off < 0 ? "-" : "+"
    off := Abs(off)
    return Map("text", FormatTime(, "dddd, d MMMM yyyy, HH:mm:ss") " (local time, UTC" sign
        . Format("{:02}:{:02}", off // 60, Mod(off, 60)) ")")
}

AgtT_ListFolder(args, ctx) {
    dir := AgtToolsResolve(args.Get("path", ""), ctx.folders)
    if !DirExist(dir)
        throw Error(dir " doesn't exist or isn't a folder")
    folders := "", files := "", n := 0, more := 0
    Loop Files dir "\*", "FD" {
        n += 1
        if (n > 300) {
            more += 1
            continue
        }
        when := FormatTime(A_LoopFileTimeModified, "yyyy-MM-dd HH:mm")
        if InStr(A_LoopFileAttrib, "D")
            folders .= "[folder] " A_LoopFileName "\   (changed " when ")`n"
        else
            files .= "[file]   " A_LoopFileName "   " AgtToolsSize(A_LoopFileSize) "   (changed " when ")`n"
    }
    if (folders != "")
        folders := Sort(folders)
    if (files != "")
        files := Sort(files)
    body := folders files
    if (body = "")
        body := "(the folder is empty)`n"
    return Map("text", "Folder " dir ":`n" RTrim(body, "`n") (more ? "`n(and " more " more not listed)" : ""))
}

AgtToolsSize(bytes) {
    return bytes < 1024 ? bytes " bytes" : bytes < 1048576 ? Round(bytes / 1024) " KB" : Round(bytes / 1048576, 1) " MB"
}

AgtT_ReadTextFile(args, ctx) {
    path := AgtToolsResolve(args["path"], ctx.folders)
    if (!FileExist(path) || InStr(FileExist(path), "D"))
        throw Error(path " doesn't exist or is a folder")
    kb := FileGetSize(path, "K")
    if (kb > ctx.readMaxKB)
        throw Error(path " is " kb " KB - bigger than the " ctx.readMaxKB " KB I allow")
    head := FileRead(path, "RAW m4096")          ; a text file has no zero bytes (except UTF-16)
    utf16 := head.Size >= 2 && ((NumGet(head, 0, "UChar") = 0xFF && NumGet(head, 1, "UChar") = 0xFE)
        || (NumGet(head, 0, "UChar") = 0xFE && NumGet(head, 1, "UChar") = 0xFF))
    if !utf16 {
        Loop head.Size
            if (NumGet(head, A_Index - 1, "UChar") = 0)
                throw Error(path " isn't a text file")
    }
    return Map("text", "File " path ":`n" FileRead(path, "UTF-8"))
}

AgtT_ReadClipboard(args, ctx) {
    t := A_Clipboard
    return Map("text", t = "" ? "(the clipboard has no text)" : "Clipboard text:`n" t)
}

AgtT_TakeScreenshot(args, ctx) {
    mons := GrabMonitors(&vx, &vy, &vw, &vh)
    n := args.Has("monitor") ? Integer(args["monitor"]) : 0
    if (n < 0 || n > mons.Length)
        throw Error("there is no monitor " n " (this PC has " mons.Length ")")
    if n {
        m := mons[n]
        x := m.x, y := m.y, w := m.w, h := m.h
        what := "monitor " n (m.primary ? " (the main one)" : "") " of " mons.Length
    } else {
        x := vx, y := vy, w := vw, h := vh
        what := mons.Length = 1 ? "the screen" : "all " mons.Length " monitors side by side"
    }
    DirCreate(ctx.imageDir)
    path := ctx.imageDir "\agent-" ctx.runId "-" ctx.step ".png"
    sz := GrabToPng(x, y, w, h, path, ctx.shotMaxSide)
    return Map("text", "Screenshot of " what ", " sz.w "x" sz.h " pixels - attached to this message as an image.",
        "images", [path])
}

AgtT_ShowMessage(args, ctx) {
    title := (args.Has("title") && Trim(String(args["title"])) != "") ? String(args["title"]) : "Message from the agent"
    g := Gui("+AlwaysOnTop -MinimizeBox", title)
    g.SetFont("s10", "Segoe UI")
    g.Add("Edit", "xm w460 h140 ReadOnly -TabStop", String(args["message"]))
    b := g.Add("Button", "xm w90 h28 Default", "OK")
    b.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show("NoActivate")
    return Map("text", "The message is showing on my screen.")
}
