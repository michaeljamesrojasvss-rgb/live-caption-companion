#Requires AutoHotkey v2.0

class JNull {
}

class Json {
    static Null := JNull()

    static Parse(text) {
        pos := 1
        v := this._Value(text, &pos)
        this._Ws(text, &pos)
        if (pos <= StrLen(text))
            throw Error("Unexpected data after JSON value at position " pos)
        return v
    }

    static Stringify(v, indent := "") {
        t := Type(v)
        if (t = "String")
            return '"' this._Esc(v) '"'
        if (t = "Integer" || t = "Float")
            return String(v)
        if (v is JNull)
            return "null"
        inner := indent "  "
        if (t = "Map") {
            if (v.Count = 0)
                return "{}"
            out := ""
            for k, val in v
                out .= (out = "" ? "" : ",`n") inner '"' this._Esc(String(k)) '": ' this.Stringify(val, inner)
            return "{`n" out "`n" indent "}"
        }
        if (t = "Array") {
            if (v.Length = 0)
                return "[]"
            out := ""
            for val in v
                out .= (out = "" ? "" : ",`n") inner this.Stringify(val, inner)
            return "[`n" out "`n" indent "]"
        }
        throw Error("Cannot serialize value of type " t)
    }

    static _Esc(s) {
        if !RegExMatch(s, '[\\"\x01-\x1F]')              ; nothing to escape (most strings): skip the 31 passes below
            return s
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        s := StrReplace(s, "`n", "\n")
        s := StrReplace(s, "`r", "\r")
        s := StrReplace(s, "`t", "\t")
        Loop 31 {
            c := A_Index
            if (c = 9 || c = 10 || c = 13)
                continue
            s := StrReplace(s, Chr(c), Format("\u{:04x}", c))
        }
        return s
    }

    static _Ws(text, &pos) {
        len := StrLen(text)
        while (pos <= len && InStr(" `t`r`n", SubStr(text, pos, 1)))
            pos += 1
    }

    static _Value(text, &pos) {
        this._Ws(text, &pos)
        ch := SubStr(text, pos, 1)

        if (ch = "{") {
            obj := Map()
            obj.CaseSense := false
            pos += 1
            this._Ws(text, &pos)
            if (SubStr(text, pos, 1) = "}") {
                pos += 1
                return obj
            }
            Loop {
                this._Ws(text, &pos)
                if (SubStr(text, pos, 1) != '"')
                    throw Error("Expected a string key at position " pos)
                k := this._Str(text, &pos)
                this._Ws(text, &pos)
                if (SubStr(text, pos, 1) != ":")
                    throw Error("Expected ':' at position " pos)
                pos += 1
                obj[k] := this._Value(text, &pos)
                this._Ws(text, &pos)
                c := SubStr(text, pos, 1)
                pos += 1
                if (c = "}")
                    return obj
                if (c != ",")
                    throw Error("Expected ',' or '}' at position " (pos - 1))
            }
        }

        if (ch = "[") {
            arr := []
            pos += 1
            this._Ws(text, &pos)
            if (SubStr(text, pos, 1) = "]") {
                pos += 1
                return arr
            }
            Loop {
                arr.Push(this._Value(text, &pos))
                this._Ws(text, &pos)
                c := SubStr(text, pos, 1)
                pos += 1
                if (c = "]")
                    return arr
                if (c != ",")
                    throw Error("Expected ',' or ']' at position " (pos - 1))
            }
        }

        if (ch = '"')
            return this._Str(text, &pos)

        if (SubStr(text, pos, 4) == "true") {
            pos += 4
            return 1
        }
        if (SubStr(text, pos, 5) == "false") {
            pos += 5
            return 0
        }
        if (SubStr(text, pos, 4) == "null") {
            pos += 4
            return Json.Null
        }
        if RegExMatch(text, "A)-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", &nm, pos) {
            pos += nm.Len[0]
            return Number(nm[0])
        }
        throw Error("Unexpected character at position " pos)
    }

    static _Str(text, &pos) {
        pos += 1                                   ; skip opening quote
        out := ""
        Loop {
            if !RegExMatch(text, '["\\]', &m, pos)
                throw Error("Unterminated string")
            out .= SubStr(text, pos, m.Pos - pos)
            pos := m.Pos + 1
            if (m[0] = '"')
                return out
            e := SubStr(text, pos, 1)
            pos += 1
            if (e == "n")
                out .= "`n"
            else if (e == "r")
                out .= "`r"
            else if (e == "t")
                out .= "`t"
            else if (e == "b")
                out .= "`b"
            else if (e == "f")
                out .= "`f"
            else if (e == "u") {
                out .= Chr(Integer("0x" SubStr(text, pos, 4)))
                pos += 4
            } else
                out .= e                           ; \"  \\  \/
        }
    }
}