; ==============================================================================
; same-value-match.ahk  -  words read on screen -> what to mark (prefix SvMatch*)
;
; Pure logic: no windows, no OCR, no files. Design: docs\SAME-VALUE.md.
; * A "value" = one OCR word, trimmed of surrounding punctuation; number pieces OCR split on one line
;   ("555 123 4567") are joined back when close together. Only ID-like values count (opts.minChars letters/
;   digits, a digit if opts.needDigit, fitting opts.idPattern) and that aren't in opts.ignoreWords (a list
;   separated by commas/spaces/new lines - common words for when words count too).
; * Values are compared by their key: spaces and opts.ignoreChars removed, upper-cased unless opts.caseSense.
; * match = a key seen 2+ times (anywhere, same monitor too): each such key is one numbered group.
;   near  = a key that differs from another key on screen by at most opts.nearMaxDiff edits (a character
;           changed, added or missing) - the look-alike that is easy to miss.
;   alone = an ID-like value with no twin (shown faintly if opts.showAlone).
;
; SvMatch(words, opts)
;   words: [{text, x, y, w, h, line}] in reading order (x/y = screen pixels; line = any id shared by the
;          words of one OCR line)
;   opts:  {minChars, needDigit, idPattern, trimChars, ignoreChars, ignoreWords, caseSense, joinNumbers,
;           joinGap, nearMiss, nearMinChars, nearMaxDiff, nearSkip, showAlone, links, linkNear}
;   -> {marks: [{x, y, w, h, group (0 = none), near (true/false)}], links: [{x1, y1, x2, y2, group, near}],
;       values, groups, nearCount, alone}
;   links (opts.links): a line from each value of a group to the next one (reading order), centre to centre;
;   with opts.linkNear, also one between the two values of each "almost the same" pair (near = true).
; ==============================================================================

SvMatch(words, opts) {
    values := SvMatchValues(words, opts)
    byKey := Map()
    byKey.CaseSense := true                      ; keys are normalised already
    order := []
    for v in values {
        if !byKey.Has(v.key) {
            byKey[v.key] := []
            order.Push(v.key)
        }
        byKey[v.key].Push(v)
    }
    groupOf := Map()
    groupOf.CaseSense := true
    groups := 0
    for k in order
        if (byKey[k].Length >= 2)
            groupOf[k] := ++groups
    pairs := []
    nearOf := opts.nearMiss ? SvMatchNear(order, opts, pairs) : Map()
    links := []
    if (opts.HasOwnProp("links") && opts.links) {
        for k in order {
            if !groupOf.Has(k)
                continue
            items := byKey[k]
            Loop items.Length - 1
                links.Push(SvMatchLink(items[A_Index], items[A_Index + 1], groupOf[k], false))
        }
        if (opts.HasOwnProp("linkNear") && opts.linkNear)
            for p in pairs
                links.Push(SvMatchLink(byKey[p[1]][1], byKey[p[2]][1], 0, true))
    }
    marks := [], alone := 0, nearCount := 0
    for v in values {
        g := groupOf.Has(v.key) ? groupOf[v.key] : 0
        isNear := nearOf.Has(v.key)
        if isNear
            nearCount += 1
        if (!g && !isNear) {
            alone += 1
            if !opts.showAlone
                continue
        }
        marks.Push({x: v.x, y: v.y, w: v.w, h: v.h, group: g, near: isNear})
    }
    return {marks: marks, links: links, values: values.Length, groups: groups, nearCount: nearCount, alone: alone}
}

SvMatchLink(a, b, group, near) {
    return {x1: a.x + a.w // 2, y1: a.y + a.h // 2, x2: b.x + b.w // 2, y2: b.y + b.h // 2, group: group, near: near}
}

; The ID-like values among the words (number pieces on one line joined back together)
SvMatchValues(words, opts) {
    out := []
    skip := SvMatchIgnoreSet(opts)
    i := 1
    while (i <= words.Length) {
        w := words[i]
        text := SvMatchTrimmed(w.text, opts)
        x1 := w.x, y1 := w.y, x2 := w.x + w.w, y2 := w.y + w.h
        j := i
        if (opts.joinNumbers && SvMatchNumberPiece(text)) {
            while (j < words.Length) {
                nx := words[j + 1]
                if (nx.line != w.line)
                    break
                t2 := SvMatchTrimmed(nx.text, opts)
                gap := nx.x - x2
                if (!SvMatchNumberPiece(t2) || gap < -2 || gap > opts.joinGap * Max(y2 - y1, nx.h))
                    break
                text .= " " t2
                x2 := Max(x2, nx.x + nx.w), y1 := Min(y1, nx.y), y2 := Max(y2, nx.y + nx.h)
                j += 1
            }
        }
        if SvMatchIdLike(text, opts) {
            key := SvMatchKey(text, opts)
            if !skip.Has(key)
                out.Push({text: text, key: key, x: x1, y: y1, w: x2 - x1, h: y2 - y1})
        }
        i := j + 1
    }
    return out
}

; The ignore list as keys (normalised the same way as values, so case/IgnoreChars rules apply to it too)
SvMatchIgnoreSet(opts) {
    set := Map()
    set.CaseSense := true
    if (!opts.HasOwnProp("ignoreWords") || Trim(opts.ignoreWords) = "")
        return set
    for w in StrSplit(RegExReplace(opts.ignoreWords, "[,;\s]+", ","), ",") {
        w := SvMatchTrimmed(w, opts)
        if (w != "")
            set[SvMatchKey(w, opts)] := true
    }
    return set
}

SvMatchTrimmed(text, opts) => Trim(text, " `t" opts.trimChars)

SvMatchNumberPiece(t) => RegExMatch(t, "^\d[\d\-./]*$")

SvMatchIdLike(text, opts) {
    plain := StrReplace(text, " ")
    if (StrLen(RegExReplace(plain, "[^\p{L}\p{N}]")) < opts.minChars)
        return false
    if (opts.needDigit && !RegExMatch(plain, "\d"))
        return false
    if (opts.idPattern != "") {
        try {
            return RegExMatch(plain, opts.idPattern) ? true : false
        } catch {
            return true                          ; a broken pattern in the settings: don't filter on it
        }
    }
    return true
}

SvMatchKey(text, opts) {
    k := RegExReplace(text, "\s")
    Loop Parse opts.ignoreChars
        k := StrReplace(k, A_LoopField)
    return opts.caseSense ? k : StrUpper(k)
}

; Keys that are almost the same as another key: Map key -> true
; pairs: an Array that gets every [keyA, keyB] pair found
SvMatchNear(keys, opts, pairs) {
    near := Map()
    near.CaseSense := true
    maxDiff := Max(1, opts.nearMaxDiff)
    cand := []
    for k in keys {
        if (StrLen(k) < opts.nearMinChars)
            continue
        if (opts.nearSkip != "") {
            skip := false
            try skip := RegExMatch(k, opts.nearSkip)
            if skip
                continue
        }
        cand.Push(k)
    }
    n := cand.Length
    Loop n {
        a := cand[A_Index]
        la := StrLen(a)
        i := A_Index
        Loop n - i {
            b := cand[i + A_Index]
            if (Abs(StrLen(b) - la) > maxDiff)
                continue
            if SvMatchClose(a, b, maxDiff) {
                near[a] := true
                near[b] := true
                pairs.Push([a, b])
            }
        }
    }
    return near
}

; True when a and b (different) are at most maxDiff edits apart. Fast paths for one edit; a banded
; edit distance for more.
SvMatchClose(a, b, maxDiff) {
    la := StrLen(a), lb := StrLen(b)
    if (maxDiff = 1) {
        if (la = lb) {                           ; one character changed
            diff := 0
            Loop la
                if (SubStr(a, A_Index, 1) !== SubStr(b, A_Index, 1) && ++diff > 1)
                    return false
            return diff = 1
        }
        if (la > lb)                             ; one character added / missing: make a the shorter
            t := a, a := b, b := t, la := lb, lb := StrLen(b)
        i := 1
        while (i <= la && SubStr(a, i, 1) == SubStr(b, i, 1))
            i += 1
        return SubStr(a, i) == SubStr(b, i + 1)
    }
    return SvMatchDistance(a, b, maxDiff) <= maxDiff
}

; Edit distance, giving up (returns limit + 1) as soon as it must be over limit
SvMatchDistance(a, b, limit) {
    la := StrLen(a), lb := StrLen(b)
    prev := []
    Loop lb + 1
        prev.Push(A_Index - 1)
    Loop la {
        i := A_Index
        ca := SubStr(a, i, 1)
        cur := [i]
        best := i
        Loop lb {
            j := A_Index
            cost := (ca == SubStr(b, j, 1)) ? 0 : 1
            v := Min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
            cur.Push(v)
            best := Min(best, v)
        }
        if (best > limit)
            return limit + 1
        prev := cur
    }
    return prev[lb + 1]
}
