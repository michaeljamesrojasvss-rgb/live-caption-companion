; ==============================================================================
; import-merge.ahk  -  Import & merge from another copy of the companion
;
; Pick any mix of JSON files and zipped folders. Each JSON is recognised as
; helpers (call-helpers.json), calls (call-history.json) or a full backup, and
; merged into what you already have:
;   * Helpers / contexts: an identical one (same label and prompt, or same
;     name, description and text - ignoring spaces, line breaks and case) is
;     skipped. A different one that has a name you already use is kept with
;     " (imported)" added to its name.
;   * Calls: the same call (same ID, or same start time) is skipped, or
;     replaced when the imported copy holds more (e.g. it went on longer).
;     New calls are added in date order. The live call is never touched.
;   * Backup copies inside zips (*.backup.json) are skipped, so calls you
;     deleted on purpose don't come back.
;
; Safety: a preview shows exactly what will change before anything is written;
; your current files are copied to *.before-import-<time>.json first; if
; anything goes wrong, nothing is changed.
; ==============================================================================

MERGE_MAX_BYTES := 60 * 1024 * 1024
MERGE_TEMP := DATA_DIR "\import-temp"
MERGE_SUFFIX := " (imported)"

MergeInit() {
    try {
        A_TrayMenu.Insert("1&", "Import && merge from another copy…", (*) => MergeImportStart())
    }
}

; Entry point (tray menu, Call history window)
MergeImportStart(*) {
    global helperEditorGui
    myGui.Opt("+OwnDialogs")
    if (IsSet(helperEditorGui) && IsObject(helperEditorGui)) {
        MsgBox("Close the helper editor first, then try again.", "Import & merge", "Iconi")
        return
    }
    if !historyAvailable {
        MsgBox("Your call history couldn't be loaded, so nothing can be merged into it right now.", "Import & merge", "Icon!")
        return
    }
    try {
        files := FileSelect("M3", A_MyDocuments, "Pick JSON files or zipped folders to merge in", "Companion data (*.json; *.zip)")
        if !files.Length
            return
        found := MergeCollect(files)
        plan := MergePlan(found)
        if MergeConfirm(found, plan)
            MergeApply(plan)
    } catch as err {
        MsgBox("Import & merge stopped - nothing was changed.`n`n" err.Message, "Import & merge", "Icon!")
    }
    try DirDelete(MERGE_TEMP, true)
}

; ==============================================================================
; 1) Find the data inside the picked files
; ==============================================================================
MergeCollect(files) {
    found := {helpers: [], histories: [], notes: []}
    try DirDelete(MERGE_TEMP, true)
    for i, path in files {
        SplitPath(path, &name, , &ext)
        if (ext = "zip") {
            dir := MERGE_TEMP "\" i
            try {
                PkgExtractZip(path, dir)
            } catch as err {
                found.notes.Push(name " (couldn't open the zip: " err.Message ")")
                continue
            }
            any := false
            Loop Files dir "\*.json", "R" {
                rel := name " > " SubStr(A_LoopFileFullPath, StrLen(dir) + 2)
                if RegExMatch(A_LoopFileName, "i)\.backup\.json$|before-import|^\.") {
                    found.notes.Push(rel " (backup copy - skipped)")
                    continue
                }
                any := true
                MergeClassifyFile(A_LoopFileFullPath, rel, found)
            }
            if !any
                found.notes.Push(name " (no companion data inside)")
        } else {
            MergeClassifyFile(path, name, found)
        }
    }
    return found
}

MergeClassifyFile(path, label, found) {
    if (FileGetSize(path) > MERGE_MAX_BYTES) {
        found.notes.Push(label " (larger than 60 MB - skipped)")
        return
    }
    try {
        root := Json.Parse(FileRead(path, "UTF-8"))
    } catch {
        found.notes.Push(label " (not readable JSON - skipped)")
        return
    }
    if !(root is Map) {
        found.notes.Push(label " (not companion data - skipped)")
        return
    }
    ; Full backup from the helper editor's Export
    if (root.Has("data") && root["data"] is Map && String(root.Get("format", "")) = "LiveCaptionCompanionBackup") {
        d := root["data"]
        got := false
        if (d.Has("helperConfiguration") && d["helperConfiguration"] is Map) {
            found.helpers.Push({source: label, cfg: d["helperConfiguration"]})
            got := true
        }
        if d.Has("callHistory") {
            h := MergeAsHistory(d["callHistory"])
            if IsObject(h) {
                found.histories.Push({source: label, sessions: h})
                got := true
            }
        }
        if !got
            found.notes.Push(label " (backup with nothing to merge)")
        return
    }
    h := MergeAsHistory(root)
    if IsObject(h) {
        found.histories.Push({source: label, sessions: h})
    } else if (root.Has("actions") || root.Has("context")) {
        found.helpers.Push({source: label, cfg: root})
    } else {
        found.notes.Push(label " (not companion data - skipped)")
    }
}

; The sessions array of a history document (or a bare array), else ""
MergeAsHistory(x) {
    if (x is Array)
        return x
    if (x is Map && x.Has("sessions") && x["sessions"] is Array)
        return x["sessions"]
    return ""
}

; ==============================================================================
; 2) Work out what would change (nothing is written here)
; ==============================================================================
MergePlan(found) {
    plan := {helperRoot: "", helpersChanged: false, sessions: "", historyChanged: false
        , aAdded: 0, aSame: 0, aRenamed: 0, aBad: 0
        , cAdded: 0, cSame: 0, cRenamed: 0, cBad: 0
        , sAdded: 0, sSame: 0, sUpdated: 0, sBad: 0}
    if found.helpers.Length
        MergePlanHelpers(found.helpers, plan)
    if found.histories.Length
        MergePlanHistory(found.histories, plan)
    return plan
}

MergePlanHelpers(sources, plan) {
    root := MergeReadCurrentHelpers()
    actions := []
    contexts := []
    for a in root.Get("actions", [])
        actions.Push(a)
    for c in root.Get("context", [])
        contexts.Push(c)

    aSigs := Map(), aIds := Map(), aLabels := Map()
    cSigs := Map(), cNames := Map()
    for m in [aSigs, aIds, aLabels, cSigs, cNames]
        m.CaseSense := false
    for a in actions
        MergeRemember(a, "label", aSigs, aLabels, aIds)
    for c in contexts
        MergeRemember(c, "name", cSigs, cNames)

    for src in sources {
        cfg := src.cfg
        for a in ((cfg.Has("actions") && (cfg["actions"] is Array)) ? cfg["actions"] : []) {
            if !(a is Map) || !HasText(a, "label") || !HasText(a, "prompt") {
                plan.aBad += 1
                continue
            }
            if aSigs.Has(MergeSig(a, "label")) {
                plan.aSame += 1
                continue
            }
            n := a.Clone()
            if (!HasText(n, "id") || aIds.Has(Trim(n["id"])))
                n["id"] := "helper-" NewGuid()
            if aLabels.Has(MergeBaseName(n["label"])) {
                n["label"] := MergeBaseName(n["label"], true) MERGE_SUFFIX
                plan.aRenamed += 1
            }
            actions.Push(n)
            MergeRemember(n, "label", aSigs, aLabels, aIds)
            plan.aAdded += 1
        }
        for c in ((cfg.Has("context") && (cfg["context"] is Array)) ? cfg["context"] : []) {
            if !(c is Map) || !HasText(c, "name") || !HasText(c, "description") || !HasText(c, "context") {
                plan.cBad += 1
                continue
            }
            if cSigs.Has(MergeSig(c, "name")) {
                plan.cSame += 1
                continue
            }
            n := c.Clone()
            if cNames.Has(MergeBaseName(n["name"])) {
                n["name"] := MergeBaseName(n["name"], true) MERGE_SUFFIX
                plan.cRenamed += 1
            }
            contexts.Push(n)
            MergeRemember(n, "name", cSigs, cNames)
            plan.cAdded += 1
        }
    }
    root["actions"] := actions
    root["context"] := contexts
    plan.helperRoot := root
    plan.helpersChanged := (plan.aAdded + plan.cAdded) > 0
}

; The current helper file (other top-level settings in it are kept)
MergeReadCurrentHelpers() {
    if !FileExist(USER_HELPER_PATH)
        return Map("actions", [], "context", [])
    try {
        root := Json.Parse(FileRead(USER_HELPER_PATH, "UTF-8"))
    } catch as err {
        throw Error("Your current call-helpers.json can't be read (" err.Message "). Fix it in Edit helpers first, so nothing in it is lost.")
    }
    if !(root is Map)
        throw Error("Your current call-helpers.json isn't in the expected format. Fix it in Edit helpers first.")
    return root
}

MergeRemember(item, nameKey, sigs, names, ids := "") {
    sigs[MergeSig(item, nameKey)] := true
    names[MergeBaseName(item[nameKey])] := true
    if (IsObject(ids) && HasText(item, "id"))
        ids[Trim(item["id"])] := true
}

; Everything except the ID, compared ignoring case, spacing and "(imported)"
MergeSig(item, nameKey) {
    sig := ""
    for k, v in item {
        if (k = "id")
            continue
        text := (Type(v) = "String") ? v : Json.Stringify(v)
        if (k = nameKey)
            text := MergeBaseName(text)
        sig .= k "=" MergeNorm(text) "`n"
    }
    return sig
}

MergeNorm(s) => Trim(RegExReplace(StrLower(s), "\s+", " "))

; "Summary (imported) (imported)" -> "summary" (keepCase: "Summary")
MergeBaseName(name, keepCase := false) {
    base := RegExReplace(Trim(name), "i)(\s*\(imported\))+$")
    return keepCase ? base : MergeNorm(base)
}

MergePlanHistory(sources, plan) {
    ; One slot per call: {orig: the session in your history ("" for a new call),
    ; cur: the copy that will be kept}. Calls are matched by ID, then start time.
    slots := []
    byId := Map()
    byStart := Map()
    sizes := Map()
    for s in history["sessions"]
        MergeAddSlot(slots, byId, byStart, s, s)
    for src in sources {
        for raw in src.sessions {
            s := MergeCleanSession(raw)
            if !IsObject(s) {
                plan.sBad += 1
                continue
            }
            idx := byId.Get(String(s["id"]), 0)
            if !idx
                idx := byStart.Get(String(s["startedAtUtc"]), 0)
            if !idx {
                MergeAddSlot(slots, byId, byStart, "", s)
                plan.sAdded += 1
                continue
            }
            slot := slots[idx]
            ; Same call: keep whichever copy holds more. Never touch the live call.
            if ((IsObject(slot.orig) && slot.orig == currentCall) || MergeSize(s, sizes) <= MergeSize(slot.cur, sizes)) {
                plan.sSame += 1
                continue
            }
            if (IsObject(slot.orig) && slot.cur == slot.orig)
                plan.sUpdated += 1
            s["id"] := slot.cur["id"]
            slot.cur := s
            byStart[String(s["startedAtUtc"])] := idx
        }
    }
    if (plan.sAdded + plan.sUpdated = 0)
        return

    ; New list in date order, with the live call kept last as the app expects
    list := []
    for slot in slots
        if !(IsObject(slot.orig) && slot.orig == currentCall)
            list.Push(slot.cur)
    list := MergeSortByStart(list)
    if IsObject(currentCall)
        list.Push(currentCall)

    bytes := StrPut(Json.Stringify(Map("schemaVersion", 1, "sessions", list)), "UTF-8")
    if (bytes > MAX_HISTORY_BYTES)
        throw Error("The merged call history would be " Round(bytes / 1048576) " MB, over the 50 MB limit. Delete some old calls first, or merge fewer files.")
    plan.sessions := list
    plan.historyChanged := true
}

MergeAddSlot(slots, byId, byStart, orig, cur) {
    slots.Push({orig: orig, cur: cur})
    byId[String(cur["id"])] := slots.Length
    byStart[String(cur["startedAtUtc"])] := slots.Length
}

; Imported sessions are filled out to the current format; unusable ones -> ""
MergeCleanSession(raw) {
    if !(raw is Map) || !raw.Has("startedAtUtc") || Type(raw["startedAtUtc"]) != "String"
        return ""
    s := raw.Clone()
    if (!s.Has("id") || Trim(String(s["id"])) = "")
        s["id"] := NewGuid()
    for key in ["transcriptLines", "chatBubbles", "preparedPrompts"]
        if (!s.Has(key) || !(s[key] is Array))
            s[key] := []
    if (!s.Has("agentNotes") || Type(s["agentNotes"]) != "String")
        s["agentNotes"] := ""
    if (!s.Has("endedAtUtc") || s["endedAtUtc"] is JNull)
        s["endedAtUtc"] := s["startedAtUtc"]
    if (s["transcriptLines"].Length = 0 && s["preparedPrompts"].Length = 0 && Trim(s["agentNotes"]) = "")
        return ""                                 ; an empty call: nothing worth keeping
    return s
}

MergeSize(s, cache) {
    if !cache.Has(s)
        cache[s] := StrLen(Json.Stringify(s))
    return cache[s]
}

; Sorted by startedAtUtc (ISO text sorts in time order)
MergeSortByStart(list) {
    if (list.Length < 2)
        return list
    lines := ""
    for i, s in list
        lines .= String(s["startedAtUtc"]) "`t" i "`n"
    out := []
    for line in StrSplit(Sort(RTrim(lines, "`n")), "`n") {
        p := StrSplit(line, "`t")
        out.Push(list[Integer(p[2])])
    }
    return out
}

; ==============================================================================
; 3) Preview
; ==============================================================================
MergeConfirm(found, plan) {
    src := ""
    n := 0
    for f in found.helpers
        src .= (++n <= 12) ? "   • " f.source "  (helpers)`n" : ""
    for f in found.histories
        src .= (++n <= 12) ? "   • " f.source "  (calls)`n" : ""
    if (n > 12)
        src .= "   • … and " (n - 12) " more`n"
    skipped := ""
    for i, note in found.notes
        skipped .= (i <= 8) ? "   • " note "`n" : ""
    if (found.notes.Length > 8)
        skipped .= "   • … and " (found.notes.Length - 8) " more`n"

    if !(plan.helpersChanged || plan.historyChanged) {
        msg := (n = 0) ? "No helpers or calls were found in what you picked." : "Everything in what you picked is already here - nothing to merge."
        MsgBox(msg (skipped != "" ? "`n`nSkipped:`n" skipped : ""), "Import & merge", "Iconi")
        return false
    }

    t := "Found:`n" src
    if (skipped != "")
        t .= "`nSkipped:`n" skipped
    t .= "`nWhat will change:`n"
    if found.helpers.Length {
        t .= "   Helpers:  " MergeCounts(plan.aAdded, plan.aSame, plan.aRenamed, plan.aBad) "`n"
        t .= "   Contexts:  " MergeCounts(plan.cAdded, plan.cSame, plan.cRenamed, plan.cBad) "`n"
    }
    if found.histories.Length {
        t .= "   Calls:  " plan.sAdded " new · " plan.sUpdated " replaced by a longer copy · " plan.sSame " already here"
        t .= (plan.sBad ? " · " plan.sBad " empty or unreadable (skipped)" : "") "`n"
    }
    if plan.cAdded
        t .= "`nEvery context is added to every helper prompt - check the new ones in Edit helpers.`n"
    t .= "`nYour current files are backed up first (*.before-import-*.json in the data folder).`n`nMerge now?"
    return MsgBox(t, "Import & merge - preview", "OKCancel Iconi") = "OK"
}

MergeCounts(added, same, renamed, bad) {
    t := added " new · " same " already here"
    if renamed
        t .= " · " renamed " named '…" MERGE_SUFFIX "' (same name, different content)"
    if bad
        t .= " · " bad " incomplete (skipped)"
    return t
}

; ==============================================================================
; 4) Apply
; ==============================================================================
MergeApply(plan) {
    global historyGui
    stamp := FormatTime(, "yyyyMMdd-HHmmss")
    done := []
    if plan.helpersChanged {
        if FileExist(USER_HELPER_PATH)
            FileCopy(USER_HELPER_PATH, DATA_DIR "\call-helpers.before-import-" stamp ".json", true)
        WriteTextAtomically(USER_HELPER_PATH, Json.Stringify(plan.helperRoot))
        LoadHelperActions()
        done.Push((plan.aAdded + plan.cAdded) " helper(s)/context(s)")
    }
    if plan.historyChanged {
        if IsObject(reviewCall)
            ExitReview()
        if IsObject(historyGui)
            try historyGui.Destroy()
        PersistCurrentCall()
        if FileExist(HISTORY_PATH)
            FileCopy(HISTORY_PATH, DATA_DIR "\call-history.before-import-" stamp ".json", true)
        history["sessions"] := plan.sessions
        SaveHistory()
        done.Push((plan.sAdded + plan.sUpdated) " call(s)")
    }
    statusText.Text := "Status: merged " JoinWith(done, " and ") " - backups saved as *.before-import-" stamp ".json"
}
