#Requires AutoHotkey v2.0
#SingleInstance Off
try TraySetIcon(A_ScriptDir "\icons\tasks.ico")       ; its own icon (tray, windows, taskbar)
try DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", "CaptionCompanion.Tasks")       ; own taskbar button
#Include app-paths.ahk
#Include Json.ahk
#Include tooltips.ahk               ; hover tips on buttons (shared; data\tips.ini switches them)
#Include tasks-alert.ahk

; ==============================================================================
; tasks.ahk  -  Tasks: nested to-do lists with timers
;
; * Its own app and its own process. It knows nothing about calls, captions or
;   3CX. Other apps can talk to it (see "Messages" below); the Companion is one
;   of them. Tasks keeps running when they close, and they don't notice if it fails.
; * Tasks nest without limit (like Workflowy). Mouse: drag and drop, the
;   toolbar buttons and right-click. Keyboard: see the ? button.
; * Links: a top-level task can be linked to "something open in another app"
;   (for the Companion: a call). A link is just {app, id, label} - the app gives
;   the id and the label, Tasks only stores them. "Linked to current" shows the
;   tasks of whatever that app has open now. Open on a linked task asks the app
;   to show that item (the Companion opens the call in review).
; * Busy: an app can say "the user is busy" (the Companion: on a call). Alerts
;   can wait until you're free, and "After my call" brings one back then.
; * Timers: start one now, or plan one on a task (fixed length, or ask how long
;   when it starts), started by you or when the task above it is ticked.
;   Alerts stay on screen (every virtual desktop, never steal focus) until you
;   choose: Done / Snooze / After my call / Open / Hide. Hide keeps the timer
;   (overdue, reminds again); only Done or Stop ends one. Each task keeps a
;   read-only timer history; Up next can also list today's finished timers.
; * Templates: data\task-templates.json (editable). New templates shipped in
;   app\task-templates.default.json are added to it once, by id.
; * Your data: data\tasks.json, data\task-templates.json, data\tasks.ini
;   (settings, window, sizes), data\tasks.log (problems).
; * One copy only: starting it again hands over to the running one.
;   Arguments: /background, /linked (open on "Linked to current"), /settings (its settings window), /restart.
;
; Messages (WM_COPYDATA, tag TASK_TAG, text split by TAB):
;   app -> Tasks   ctx  appHwnd  appName  itemId  itemLabel  note  busy(0/1)
;                  newitem   appHwnd  appName  itemId  itemLabel   (something new started:
;                            add the settings' checklist for it, maybe show Tasks)
;                  dropitem  appHwnd  appName  itemId   (thrown away: remove its
;                            automatic checklist if untouched)
;                  show | showlinked | togglelinked | hide | settings | quit
;   Tasks -> app   open  itemId          (show that item, e.g. review the call)
;                  itemstatus  itemId  open  total   (tasks still open for its
;                            open item; sent when it changes)
; ==============================================================================

TASK_WIN_TITLE := "Caption Companion Tasks"
TASK_TAG := 0x3CC2
TASK_PATH := DATA_DIR "\tasks.json"
TASK_GOOD_PATH := DATA_DIR "\tasks.good.json"
TASK_TPL_PATH := DATA_DIR "\task-templates.json"
TASK_TPL_DEFAULT := A_ScriptDir "\task-templates.default.json"
TASK_INI := DATA_DIR "\tasks.ini"
TASK_LOG := DATA_DIR "\tasks.log"
TASK_VIEWS := ["All tasks", "Linked to current", "Not linked"]
TASK_VIEW_ALL := 1
TASK_VIEW_LINKED := 2
TASK_VIEW_UNLINKED := 3
TASK_STARTS := ["afterPrevious", "manual", "now"]   ; when a planned timer starts
TASK_MAX_QUICK := 6                  ; most timer buttons under the list
TASK_HISTORY_MAX := 50               ; timer history entries kept per task
TASK_TREE_TOP := 108
TASK_MIN_TREE_H := 60
TASK_SETTING_DEFAULTS := Map(
    "Position", "Bottom left",       ; where alerts appear (see TALERT_POSITIONS)
    "Sound", 1,
    "SoundFile", "",                 ; empty = the Windows exclamation sound
    "RepeatSoundSec", 60,            ; 0 = play once
    "SnoozeMinutes", "1,2,5,10",     ; durations: plain numbers are minutes, or 30s / 1h
    "DuringCall", "wait",            ; "wait" = hold new alerts while busy | "show"
    "AfterCallDelaySec", 15,         ; held / "After my call" alerts come back this long after
    "AfterCallFallbackMin", 3,       ; "After my call" when not busy: back after this long
    "RemindHiddenMin", 3,            ; a hidden (overdue) alert comes back after this; 0 = never
    "QuickTimers", "2,5,10,15,30",   ; durations, like SnoozeMinutes
    "Hotkey", "^+!t",
    "ToastWidth", 400,
    "ReadVoice", "",                 ; Windows voice name; empty = the default voice
    "ReadRate", 0,                   ; -10 (slow) .. 10 (fast)
    "NewItemTemplate", "default-call", ; template id added when an app starts a new item; "" = none
    "NewItemShow", 0)                ; 1 = also show Tasks (without taking focus)

DetectHiddenWindows(true)            ; other apps and the other copy may be hidden
OnError(TaskOnError)

taskArg := A_Args.Length ? A_Args[1] : ""

; A copy that is restarting after an update: let the old one close first
if (taskArg = "/restart") {
    Loop 40 {
        if !WinExist(TASK_WIN_TITLE " ahk_class AutoHotkeyGUI")
            break
        Sleep(100)
    }
}

; Only one copy: hand the request to the one that is running and leave
if (other := WinExist(TASK_WIN_TITLE " ahk_class AutoHotkeyGUI")) {
    if (taskArg != "/background" && taskArg != "/restart")
        TaskSendTo(other, taskArg = "/linked" ? "showlinked" : taskArg = "/settings" ? "settings" : "show")
    ExitApp()
}

; ------------------------------------------------------------------------------
; State
; ------------------------------------------------------------------------------
taskDoc := ""                ; Map: {schemaVersion, tasks: [node, ...]}
taskById := Map()            ; id -> node
taskParent := Map()          ; id -> parent node, or "" for a top-level task
tvToTask := Map()            ; TreeView item -> task id
taskToTv := Map()            ; task id -> TreeView item
taskView := TASK_VIEW_ALL
taskShowDone := true
taskShowFinished := false    ; Up next also lists today's finished timers
taskTemplates := []
taskNotesId := ""            ; the task whose notes are in the notes box
taskNewEditId := ""          ; a task just added and being named (removed if left empty)
taskLastDeleted := ""        ; {node, parentId, index} for Ctrl+Z
taskUpNextIds := []
taskUpNextSig := ""
taskQuick := []              ; seconds on the timer buttons
taskHotkey := ""
taskTickCount := 0
taskLoadedVersion := APP_VERSION
taskSeenIds := Map()
taskListH := 110             ; Up next height (drag the bars to change)
taskNotesH := 64             ; notes height
taskDragId := ""             ; task being dragged with the mouse
taskVoice := ""              ; Windows speech (read aloud)

; What the other apps last told us
ctxApp := ""                 ; app that sent the current item, e.g. "Companion"
ctxId := ""                  ; its item id ("" = nothing open)
ctxLabel := ""               ; its label, e.g. "Call · Nov 19 2:14 PM · 📞 555"
ctxNote := ""                ; e.g. "live call" / "reviewing"
ctxApps := Map()             ; app name -> its window
busyApps := Map()            ; app name -> true while that app says you're busy
lastBusyEndUtc := ""
pendingShowLinked := false   ; open on "Linked to current" as soon as an app reports
taskPendingFocus := ""       ; task opened from Up next / an alert, waiting for its app
taskLastStatus := ""         ; last "itemstatus" sent (only changes are sent)

; ------------------------------------------------------------------------------
; Start
; ------------------------------------------------------------------------------
TaskLoad()
TaskReindex()
TaskLoadTemplates()
TaskBuildGui()
TaskBuildTray()
TaskApplyHotkey()
OnMessage(0x4A, TaskOnCopyData)          ; WM_COPYDATA from other apps / another copy
OnMessage(0x0201, TaskSplitterDown)      ; WM_LBUTTONDOWN on the resize bars
OnMessage(0x0020, TaskSplitterCursor)    ; WM_SETCURSOR: up/down arrow over them
OnExit(TaskOnExit)
TaskRebuildTree()
TaskRefreshUpNext()
SetTimer(TaskTick, 1000)
if (taskArg = "/settings")
    TaskOpenSettings()
else if (taskArg != "/background" && taskArg != "/restart")
    TaskShowWindow(taskArg = "/linked" ? TASK_VIEW_LINKED : 0)
TaskTick()                               ; timers that ran out while closed alert now
Persistent()

; ------------------------------------------------------------------------------
; Keys inside the task list (only while the list itself has the focus, so they
; never get in the way while you type a name or notes)
; ------------------------------------------------------------------------------
; While typing a task's name: Enter saves it, and if it's a task you just
; added, starts the next one below (keep typing a list, Workflowy-style).
; Enter on an empty new task stops. Esc cancels. Tab saves and indents.
#HotIf TaskLabelEditing()
Enter::TaskFinishEdit("save")
NumpadEnter::TaskFinishEdit("save")
Escape::TaskFinishEdit("cancel")
Tab::TaskFinishEdit("indent")
+Tab::TaskFinishEdit("outdent")
#HotIf

#HotIf TaskTreeFocused()
Enter::TaskAddSibling()
NumpadEnter::TaskAddSibling()
^Enter::TaskAddChild()
Insert::TaskAddChild()
Tab::TaskIndent()
+Tab::TaskOutdent()
Delete::TaskDeleteSelected()
^z::TaskUndoDelete()
^Up::TaskMove(-1)
^Down::TaskMove(1)
#HotIf

TaskLabelEditing() {
    try return WinActive("ahk_id " tkGui.Hwnd) && TaskEditing()
    return false
}

; Ends the name box. how: save | cancel | indent | outdent
TaskFinishEdit(how) {
    global taskNewEditId
    newId := taskNewEditId                    ; TaskOnEndEdit clears it
    id := TaskSelectedId()
    if (how = "indent" || how = "outdent")
        taskNewEditId := ""                   ; an empty new task may be indented, not dropped
    SendMessage(0x1116, how = "cancel" ? 1 : 0, 0, tkTree)   ; TVM_ENDEDITLABELNOW (1 = cancel)
    if (how = "cancel" || id = "")
        return
    SetTimer(TaskAfterEdit.Bind(id, how, newId = id), -40)  ; after the name is saved / relabelled
}

TaskAfterEdit(id, how, wasNew, *) {
    global taskNewEditId
    n := taskById.Get(id, "")
    if !IsObject(n)
        return                                ; an empty new task was dropped
    if taskToTv.Has(id)
        tkTree.Modify(taskToTv[id], "Select")
    switch how {
        case "indent":  TaskIndent()
        case "outdent": TaskOutdent()
    }
    if (how = "save" && wasNew && Trim(n["title"]) != "") {
        TaskAddSibling()                      ; keep going: the next task, ready to type
        return
    }
    if (how != "save") {                      ; indent/outdent: keep typing its name
        if wasNew
            taskNewEditId := id               ; still "new": Enter goes on to the next one
        SetTimer(TaskBeginEdit.Bind(id), -30)
    }
}

TaskTreeFocused() {
    try {
        if !WinActive("ahk_id " tkGui.Hwnd)
            return false
        return ControlGetFocus("ahk_id " tkGui.Hwnd) = tkTree.Hwnd
    }
    return false
}

; ==============================================================================
; Data: nodes, load, save, index
; ==============================================================================
TaskNewMap(pairs*) {
    m := Map()
    m.CaseSense := false
    i := 1
    while (i < pairs.Length) {
        m[pairs[i]] := pairs[i + 1]
        i += 2
    }
    return m
}

TaskNewId() {
    s := ""
    Loop 16
        s .= Format("{:x}", Random(0, 15))
    return s
}

; Every key a task has, with its empty value (fresh objects each call)
;   link       {app, id, label} on a top-level task, or null
;   timer      running timer {dueAtUtc, seconds, state, afterSinceUtc, sawBusy}, or null
;   autoTimer  planned timer {seconds, ask, question, start}, or null
;   askOnDone  ask something before it can be ticked {question, label, required}, or null;
;              the answer goes into the notes as "label: answer"
;   history    what happened to its timers [{at, kind, what}] - read-only in the app;
;              kind: start | rang | after | hide | remind | end (newest last, capped)
TaskDefaults() {
    return TaskNewMap("id", "", "title", "", "notes", "", "done", 0
        , "createdAtUtc", "", "doneAtUtc", "", "link", Json.Null
        , "collapsed", 0, "timer", Json.Null, "autoTimer", Json.Null, "askOnDone", Json.Null
        , "history", [], "auto", 0
        , "children", [])
}

TaskNewNode(title := "") {
    n := TaskDefaults()
    n["id"] := TaskNewId()
    n["title"] := title
    n["createdAtUtc"] := TaskNowIso()
    return n
}

TaskLoad() {
    global taskDoc
    taskDoc := TaskNewMap("schemaVersion", 2, "tasks", [])
    for path in [TASK_PATH, TASK_GOOD_PATH] {
        if !FileExist(path)
            continue
        try {
            d := Json.Parse(FileRead(path, "UTF-8"))
            if !((d is Map) && d.Has("tasks") && (d["tasks"] is Array))
                throw Error("there is no task list in it")
            taskSeenIds.Clear()
            TaskRepair(d["tasks"])
            d["schemaVersion"] := 2
            taskDoc := d
            if (path != TASK_PATH)
                TaskLog("tasks.json could not be read; loaded tasks.good.json instead")
            if (path = TASK_PATH)
                try FileCopy(TASK_PATH, TASK_GOOD_PATH, true)   ; last copy that loaded fine
            return
        } catch as err {
            if (path = TASK_PATH) {
                bad := DATA_DIR "\tasks.broken-" FormatTime(, "yyyyMMdd-HHmmss") ".json"
                try FileCopy(TASK_PATH, bad, true)
                TaskLog("could not read tasks.json (" err.Message "); kept a copy as " bad)
            }
        }
    }
}

; Fills in missing keys, converts older files, drops anything that isn't a
; task - so a hand-edited or older file still loads
TaskRepair(list) {
    i := list.Length
    while (i >= 1) {
        n := list[i]
        if !(n is Map) {
            list.RemoveAt(i)
        } else {
            ; version 1 stored calls directly: callId / callLabel -> a Companion link
            if (n.Has("callId") && Trim(n["callId"]) != "" && !(n.Get("link", "") is Map))
                n["link"] := TaskNewLink("Companion", n["callId"], n.Get("callLabel", ""))
            for key in ["callId", "callLabel"]
                if n.Has(key)
                    n.Delete(key)
            for key, def in TaskDefaults()
                if !n.Has(key)
                    n[key] := def
            n["id"] := String(n["id"])
            if (n["id"] = "" || taskSeenIds.Has(n["id"]))
                n["id"] := TaskNewId()
            taskSeenIds[n["id"]] := true
            if !(n["children"] is Array)
                n["children"] := []
            if !(n["link"] is Map) || Trim(n["link"].Get("id", "")) = ""
                n["link"] := Json.Null
            if !(n["timer"] is Map) || !n["timer"].Has("dueAtUtc")
                n["timer"] := Json.Null
            n["autoTimer"] := TaskNormAuto(n["autoTimer"])
            n["askOnDone"] := TaskNormAsk(n["askOnDone"])
            if !(n["history"] is Array)
                n["history"] := []
            TaskRepair(n["children"])
        }
        i -= 1
    }
}

TaskNewLink(app, id, label) {
    return TaskNewMap("app", String(app), "id", String(id), "label", String(label))
}

; A planned timer in any shape (older files, templates) -> {seconds, ask, question, start}
TaskNormAuto(at) {
    if !(at is Map)
        return Json.Null
    secs := 0
    if (at.Has("seconds") && IsNumber(at["seconds"]))
        secs := at["seconds"]
    else if at.Has("duration")
        secs := Max(0, TaskParseDuration(String(at["duration"]), false))
    else if (at.Has("minutes") && IsNumber(at["minutes"]))
        secs := at["minutes"] * 60
    question := String(at.Get("question", ""))
    ask := at.Get("ask", 0)
    if !IsNumber(ask) {                      ; version 1: "ask" held the question itself
        if (Trim(ask) != "" && question = "")
            question := ask
        ask := (Trim(ask) != "") ? 1 : 0
    }
    ask := ask ? 1 : 0
    start := at.Get("start", "afterPrevious")
    ok := false
    for s in TASK_STARTS
        if (s = start)
            ok := true
    if !ok
        start := "afterPrevious"
    if (!ask && secs <= 0)
        return Json.Null
    return TaskNewMap("seconds", Round(secs), "ask", ask, "question", question, "start", start)
}

; "Ask before done" in any shape -> {question, label, required}, or null
TaskNormAsk(a) {
    if !(a is Map) || Trim(a.Get("question", "")) = ""
        return Json.Null
    req := a.Get("required", 1)
    return TaskNewMap("question", Trim(a["question"]), "label", Trim(a.Get("label", ""))
        , "required", (IsNumber(req) ? req : 1) ? 1 : 0)
}

TaskSaveSoon() {
    SetTimer(TaskSaveNow, -400)
}

TaskSaveNow() {
    try {
        text := Json.Stringify(taskDoc)
        tmp := DATA_DIR "\.tasks." A_TickCount ".tmp"
        f := FileOpen(tmp, "w", "UTF-8")
        f.Write(text)
        f.Close()
        FileMove(tmp, TASK_PATH, true)
    } catch as err {
        TaskStatus("Could not save the tasks: " err.Message)
        TaskLog("save failed: " err.Message)
    }
}

TaskReindex() {
    global taskById, taskParent
    taskById := Map()
    taskParent := Map()
    TaskIndexList(taskDoc["tasks"], "")
}

TaskIndexList(list, parent) {
    for n in list {
        taskById[n["id"]] := n
        taskParent[n["id"]] := parent
        TaskIndexList(n["children"], n)
    }
}

TaskParentOf(n) {
    return taskParent.Get(n["id"], "")
}

TaskIsRoot(n) {
    return !IsObject(TaskParentOf(n))
}

TaskRoot(n) {
    while IsObject(p := TaskParentOf(n))
        n := p
    return n
}

TaskSiblings(n) {
    p := TaskParentOf(n)
    return IsObject(p) ? p["children"] : taskDoc["tasks"]
}

TaskIndexIn(list, n) {
    for i, x in list
        if (x["id"] = n["id"])
            return i
    return 0
}

; True if a is b or somewhere under b
TaskIsInside(a, b) {
    while IsObject(a) {
        if (a["id"] = b["id"])
            return true
        a := TaskParentOf(a)
    }
    return false
}

; How many tasks are under n (all levels)
TaskCountUnder(n) {
    c := 0
    for x in n["children"]
        c += 1 + TaskCountUnder(x)
    return c
}

; Calls fn(node) for n and everything under it
TaskEachIn(n, fn) {
    fn(n)
    for c in n["children"]
        TaskEachIn(c, fn)
}

; "Parent › Task" - enough to tell similar steps apart
TaskPath(n) {
    p := TaskParentOf(n)
    t := TaskTitle(n)
    return IsObject(p) ? TaskTitle(p) " › " t : t
}

TaskTitle(n) {
    return Trim(n["title"]) = "" ? "(untitled)" : n["title"]
}

; The link of a task's top-level task, or ""
TaskLinkOf(n) {
    l := TaskRoot(n)["link"]
    return (l is Map) ? l : ""
}

TaskLinkLabel(n) {
    l := TaskLinkOf(n)
    return IsObject(l) ? l.Get("label", "") : ""
}

; Is this link the item an app has open right now?
TaskLinkIsCurrent(l) {
    return (l is Map) && ctxId != "" && l["id"] = ctxId && l["app"] = ctxApp
}

; ==============================================================================
; Time and durations
; ==============================================================================
TaskNowIso() {
    return FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss") "Z"
}

TaskIsoIn(seconds) {
    return FormatTime(DateAdd(A_NowUTC, seconds, "Seconds"), "yyyy-MM-dd'T'HH:mm:ss") "Z"
}

TaskIsoStamp(iso) {
    if RegExMatch(iso, "^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)", &m)
        return m[1] m[2] m[3] m[4] m[5] m[6]
    return ""
}

; Seconds from now until iso (negative = in the past)
TaskSecsUntil(iso) {
    st := TaskIsoStamp(iso)
    return (st = "") ? 0 : DateDiff(st, A_NowUTC, "Seconds")
}

TaskFmtLeft(sec) {
    sec := Max(0, sec)
    h := sec // 3600
    m := Mod(sec, 3600) // 60
    s := Mod(sec, 60)
    return h ? Format("{}:{:02}:{:02}", h, m, s) : Format("{}:{:02}", m, s)
}

; 30 -> "30s", 300 -> "5m", 5400 -> "1h30m"
TaskDurLabel(sec) {
    sec := Round(sec)
    if (sec < 60)
        return sec "s"
    h := sec // 3600
    m := Mod(sec, 3600) // 60
    s := Mod(sec, 60)
    return (h ? h "h" : "") (m ? m "m" : "") (s ? s "s" : "")
}

; Reads a length of time. Returns seconds, or -1 if it can't be read.
;   plain number = minutes ("5", "1.5") · "30s" · "2m" · "1h" · "1h 30" · "1m 30s"
;   allowClock: also a clock time ("3:30 pm", "15:30", "3pm") = time until then
TaskParseDuration(text, allowClock := true) {
    t := Trim(StrLower(text))
    if (t = "")
        return -1
    if RegExMatch(t, "^\d+(?:\.\d+)?$")
        return Round(t * 60)
    if RegExMatch(t, "^(\d+)\s*h(?:ours?|rs?)?\s*(\d+)$", &m)          ; "1h 30"
        return m[1] * 3600 + m[2] * 60
    if RegExMatch(t, "^(?:(\d+(?:\.\d+)?)\s*h(?:ours?|rs?)?)?\s*(?:(\d+(?:\.\d+)?)\s*m(?:in(?:ute)?s?)?)?\s*(?:(\d+)\s*s(?:ec(?:ond)?s?)?)?$", &m) {
        if (m[1] != "" || m[2] != "" || m[3] != "") {
            secs := (m[1] = "" ? 0 : m[1] * 3600) + (m[2] = "" ? 0 : m[2] * 60) + (m[3] = "" ? 0 : m[3] + 0)
            return Round(secs)
        }
    }
    if (allowClock && RegExMatch(t, "^(\d{1,2})(?::(\d\d))?\s*(am|pm|a|p)?$", &m) && (m[2] != "" || m[3] != "")) {
        h := Integer(m[1])
        mi := (m[2] = "") ? 0 : Integer(m[2])
        if (h > 23 || mi > 59)
            return -1
        if (m[3] != "")
            h := Mod(h, 12) + (SubStr(m[3], 1, 1) = "p" ? 12 : 0)
        target := FormatTime(A_Now, "yyyyMMdd") Format("{:02}{:02}00", h, mi)
        diff := DateDiff(target, A_Now, "Seconds")
        if (m[3] = "") {                     ; no am/pm: the next time the clock shows it
            while (diff <= 0)
                diff += 12 * 3600
        } else if (diff <= 0) {
            diff += 24 * 3600
        }
        return diff
    }
    return -1
}

; "30s, 2, 5m" -> [30, 120, 300] (at most maxCount)
TaskDurationList(text, maxCount) {
    out := []
    for part in StrSplit(text, [",", ";"]) {
        s := TaskParseDuration(part, false)
        if (s > 0 && out.Length < maxCount)
            out.Push(s)
    }
    return out
}

; ==============================================================================
; Window
; ==============================================================================
TaskBuildGui() {
    global tkGui, tkView, tkShowDone, tkBtnTpl, tkBtnSettings, tkBtnHelp, tkBanner
    global tkTree, tkUpLbl, tkList, tkNotesLbl, tkNotes, tkTimerLbl, tkTimerBtns
    global tkBtnCustom, tkBtnPlan, tkBtnStop, tkStatus, tkSplitA, tkSplitB, tkToolbar, tkShowFinished
    global taskView, taskShowDone, taskListH, taskNotesH, taskShowFinished

    taskView := TaskIniInt("Window", "View", TASK_VIEW_ALL, 1, TASK_VIEWS.Length)
    taskShowDone := TaskIniInt("Window", "ShowDone", 1, 0, 1)
    taskListH := TaskIniInt("Window", "ListH", 110, 40, 2000)
    taskNotesH := TaskIniInt("Window", "NotesH", 64, 40, 2000)
    taskShowFinished := TaskIniInt("Window", "ShowFinished", 0, 0, 1)

    tkGui := Gui("+Resize +MinSize600x560", TASK_WIN_TITLE)
    tkGui.BackColor := "11151D"
    tkGui.SetFont("s10 cF1F5FB", "Segoe UI")
    tkGui.Add("Text", "x10 y14 w38 c9BA8BA", "View")
    tkView := tkGui.Add("DropDownList", "x48 y10 w180 Choose" taskView, TASK_VIEWS)
    tkShowDone := tkGui.Add("Checkbox", "x240 y14 w100 Checked" taskShowDone, "Show done")
    tkBtnTpl := tkGui.Add("Button", "x346 y9 w112 h26", "Templates ▼")
    tkBtnSettings := tkGui.Add("Button", "x+6 yp w34 h26", "⚙")
    tkBtnHelp := tkGui.Add("Button", "x+6 yp w30 h26", "?")
    ; yellow while showing the tasks linked to what's open (like the Companion's review banner)
    tkBanner := tkGui.Add("Text", "x10 y42 w600 h26 +0x200 c9BA8BA", "")
    ; mouse-friendly buttons for everything the keyboard can do
    tkToolbar := []
    for b in [["+ Task", TaskAddSibling, 70, "New task below the selected one (Enter)"]
            , ["+ Subtask", TaskAddChild, 84, "New task inside the selected one (Ctrl+Enter)"]
            , ["◀ Out", TaskOutdent, 62, "Move the selected task one level out"]
            , ["In ▶", TaskIndent, 56, "Move the selected task one level in (under the task above it)"]
            , ["▲", TaskMove.Bind(-1), 34, "Move the selected task up"], ["▼", TaskMove.Bind(1), 34, "Move the selected task down"]
            , ["✓ Done", TaskToggleDoneSelected, 70, "Tick the selected task done (or not done again)"]
            , ["🗑", TaskDeleteSelected, 36, "Delete the selected task (Del)"]
            , ["🔗 Links", (*) => TaskOpenLinks(TaskSelectedNode()), 76, "Open a link from the selected task's checklist or notes"]] {
        c := tkGui.Add("Button", "y74 h26 w" b[3] (A_Index = 1 ? " x10" : " x+4"), b[1])
        c.OnEvent("Click", TaskToolbarClick.Bind(b[2]))
        TipSet(c, b[4])
        tkToolbar.Push(c)
    }
    tkTree := tkGui.Add("TreeView", "x10 y" TASK_TREE_TOP " w600 h300 Checked -ReadOnly Background1B2431 cF1F5FB")
    tkSplitA := tkGui.Add("Text", "x10 w600 h6 +0x100 Background2A3442", "")    ; 0x100 = gets clicks
    tkUpLbl := tkGui.Add("Text", "x10 w400 h20 c9BA8BA", "UP NEXT  -  overdue first, then soonest (click to open the task and its call)")
    tkShowFinished := tkGui.Add("Checkbox", "w180 Checked" taskShowFinished, "Show finished today")
    tkShowFinished.OnEvent("Click", TaskOnShowFinished)
    tkList := tkGui.Add("ListView", "x10 w600 h110 -Multi NoSortHdr Background1B2431 cF1F5FB", ["When", "Task", "Linked to"])
    tkSplitB := tkGui.Add("Text", "x10 w600 h6 +0x100 Background2A3442", "")
    tkNotesLbl := tkGui.Add("Text", "x10 w600 h20 c9BA8BA", "NOTES")
    tkNotes := tkGui.Add("Edit", "x10 w600 h64 Multi WantReturn VScroll Background1B2431 cF1F5FB Disabled")
    tkTimerLbl := tkGui.Add("Text", "x10 w44 c9BA8BA", "Timer")
    tkTimerBtns := []
    Loop TASK_MAX_QUICK {
        b := tkGui.Add("Button", "w52 h26 Hidden", "")
        b.OnEvent("Click", TaskQuickTimer.Bind(A_Index))
        TipSet(b, "Start a timer this long on the selected task (the lengths are in Settings)")
        tkTimerBtns.Push(b)
    }
    tkBtnCustom := tkGui.Add("Button", "w76 h26", "Custom…")
    tkBtnStop := tkGui.Add("Button", "w56 h26", "Stop")
    tkBtnPlan := tkGui.Add("Button", "w70 h26", "Plan…")
    tkStatus := tkGui.Add("Text", "x10 w600 h20 c9BA8BA", "Drag tasks to move them · right-click for more · ? for keys")

    tkView.OnEvent("Change", TaskOnViewChange)
    tkShowDone.OnEvent("Click", TaskOnShowDone)
    tkBtnTpl.OnEvent("Click", TaskShowTemplateMenu)
    tkBtnSettings.OnEvent("Click", (*) => TaskOpenSettings())
    tkBtnHelp.OnEvent("Click", (*) => TaskShowHelp())
    tkTree.OnEvent("ItemCheck", TaskOnCheck)
    tkTree.OnEvent("ItemSelect", (*) => TaskShowSelected())
    tkTree.OnEvent("ItemExpand", TaskOnExpand)
    tkTree.OnEvent("ContextMenu", TaskOnContextMenu)
    tkTree.OnNotify(-459, TaskOnBeginEdit)        ; TVN_BEGINLABELEDITW
    tkTree.OnNotify(-460, TaskOnEndEdit)          ; TVN_ENDLABELEDITW
    tkTree.OnNotify(-456, TaskOnBeginDrag)        ; TVN_BEGINDRAGW
    tkList.OnEvent("Click", TaskOnUpNextOpen)          ; one click opens it
    tkNotes.OnEvent("Change", TaskOnNotesChange)
    tkBtnCustom.OnEvent("Click", (*) => TaskCustomTimer(TaskSelectedNode()))
    tkBtnStop.OnEvent("Click", (*) => TaskStopTimer(TaskSelectedNode()))
    tkBtnPlan.OnEvent("Click", (*) => TaskPlanDialog(TaskSelectedNode()))
    TipSetAll([
        [tkShowDone, "Also show tasks that are ticked done"],
        [tkBtnTpl, "Add a ready-made checklist (a template), or save the selected task as one"],
        [tkBtnSettings, "Tasks settings: alerts, sounds, timer buttons, read aloud"],
        [tkBtnHelp, "The keys and mouse actions in Tasks"],
        [tkShowFinished, "Also list the timers that finished today"],
        [tkSplitA, "Drag up or down to resize"], [tkSplitB, "Drag up or down to resize"],
        [tkBtnCustom, "Start a timer of any length on the selected task"],
        [tkBtnStop, "Stop the selected task's timer"],
        [tkBtnPlan, "Plan a timer that starts later by itself (e.g. when the task above is ticked done)"]])
    tkGui.OnEvent("Size", TaskOnSize)
    tkGui.OnEvent("Close", (*) => TaskHide())
    TaskSetupTimerButtons()
}

TaskToolbarClick(fn, *) {
    fn()
}

TaskBuildTray() {
    A_IconTip := "Caption Companion Tasks"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Open Tasks", (*) => TaskShowWindow())
    tray.Add("Settings…", (*) => TaskOpenSettings())
    tray.Add("Edit templates file", (*) => TaskEditTemplates())
    tray.Add("Reload templates", (*) => TaskReloadTemplates())
    tray.Add()
    tray.Add("Exit Tasks", (*) => ExitApp())
    tray.Default := "Open Tasks"
}

TaskOnSize(g, minMax, w, h) {
    if (minMax = -1)
        return
    cw := w - 20
    statusY := h - 24
    timerY := statusY - 34
    ; the bars' sizes, shrunk for now (not saved) if the window is too short
    room := timerY - 6 - TASK_TREE_TOP - TASK_MIN_TREE_H - 8 - 20 - 10 - 20 - 6
    listH := taskListH
    notesH := taskNotesH
    if (listH + notesH > room) {
        notesH := Max(30, Min(notesH, room // 2))
        listH := Max(30, room - notesH)
    }
    notesY := timerY - 6 - notesH
    notesLblY := notesY - 20
    listY := notesLblY - 10 - listH
    upLblY := listY - 20
    splitAY := upLblY - 8
    tkBanner.Move(10, 42, cw)
    tkTree.Move(10, TASK_TREE_TOP, cw, Max(TASK_MIN_TREE_H, splitAY - 2 - TASK_TREE_TOP))
    tkSplitA.Move(10, splitAY, cw, 6)
    tkUpLbl.Move(10, upLblY, cw - 190)
    tkShowFinished.Move(10 + cw - 180, upLblY - 2, 180)
    tkList.Move(10, listY, cw, listH)
    tkSplitB.Move(10, listY + listH + 2, cw, 6)
    tkNotesLbl.Move(10, notesLblY, cw)
    tkNotes.Move(10, notesY, cw, notesH)
    tkTimerLbl.Move(10, timerY + 4)
    x := 56
    for i, b in tkTimerBtns {
        if (i > taskQuick.Length)
            continue
        b.Move(x, timerY)
        x += 56
    }
    tkBtnCustom.Move(x, timerY)
    tkBtnStop.Move(x + 80, timerY)
    tkBtnPlan.Move(x + 80 + 60, timerY)
    tkStatus.Move(10, statusY, cw)
    tkList.ModifyCol(1, 120)
    tkList.ModifyCol(2, Max(120, Round((cw - 150) * 0.6)))
    tkList.ModifyCol(3, Max(100, cw - 150 - Round((cw - 150) * 0.6)))
    SetTimer(TaskRepaint, -60)                       ; once the moving is over: no leftover pixels
}

; Moving a control doesn't repaint the spot it left, so old pixels could stay on screen: after every
; layout the whole window and all its controls are repainted once
TaskRepaint() {
    try DllCall("RedrawWindow", "Ptr", tkGui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x1 | 0x4 | 0x80 | 0x100 | 0x400)
}

TaskRelayout() {
    try {
        tkGui.GetClientPos(, , &w, &h)
        TaskOnSize(tkGui, 0, w, h)
    }
}

; ---- the two drag bars: above Up next, and between Up next and the notes ----
TaskSplitterCursor(wParam, lParam, msg, hwnd) {
    if (!IsSet(tkSplitA) || !IsObject(tkSplitA))
        return
    if (wParam = tkSplitA.Hwnd || wParam = tkSplitB.Hwnd) {
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32645, "Ptr"))  ; IDC_SIZENS
        return true
    }
}

TaskSplitterDown(wParam, lParam, msg, hwnd) {
    if (!IsSet(tkSplitA) || !IsObject(tkSplitA))
        return
    if (hwnd = tkSplitA.Hwnd || hwnd = tkSplitB.Hwnd) {
        SetTimer(TaskSplitterDrag.Bind(hwnd = tkSplitA.Hwnd), -1)
        return 0
    }
}

; Bar A: Up next grows / shrinks (the list above takes the rest).
; Bar B: moves the line between Up next and the notes.
TaskSplitterDrag(isA) {
    global taskListH, taskNotesH
    try {
        CoordMode("Mouse", "Screen")
        tkGui.GetClientPos(, , , &ch)
        MouseGetPos(, &startY)
        startList := taskListH
        startNotes := taskNotesH
        maxPanels := ch - 24 - 34 - 6 - TASK_TREE_TOP - TASK_MIN_TREE_H - 64
        while GetKeyState("LButton", "P") {
            MouseGetPos(, &y)
            dy := y - startY
            if isA {
                taskListH := Max(40, Min(startList - dy, maxPanels - taskNotesH))
            } else {                                 ; up = bigger notes, smaller Up next
                taskNotesH := Max(40, Min(startNotes - dy, startNotes + startList - 40))
                taskListH := startList + startNotes - taskNotesH
            }
            TaskRelayout()
            Sleep(15)
        }
        IniWrite(taskListH, TASK_INI, "Window", "ListH")
        IniWrite(taskNotesH, TASK_INI, "Window", "NotesH")
    }
}

; Timer buttons come from the QuickTimers setting
TaskSetupTimerButtons() {
    global taskQuick
    taskQuick := TaskDurationList(TaskSetting("QuickTimers"), TASK_MAX_QUICK)
    for i, b in tkTimerBtns {
        if (i <= taskQuick.Length) {
            b.Text := TaskDurLabel(taskQuick[i])
            b.Visible := true
        } else {
            b.Visible := false
        }
    }
    TaskRelayout()
}

; view: 0 = keep the current one. activate: false = show it without taking
; the focus from what you're doing
TaskShowWindow(view := 0, activate := true) {
    global pendingShowLinked
    if (view = TASK_VIEW_LINKED && ctxId = "")
        pendingShowLinked := true        ; switch once an app reports what it has open
    if (view && view != taskView)
        TaskSetView(view)
    if !TaskWindowShown() {
        x := TaskIniRead("Window", "X", "")
        y := TaskIniRead("Window", "Y", "")
        w := TaskIniRead("Window", "W", "")
        h := TaskIniRead("Window", "H", "")
        opts := (IsInteger(w) && IsInteger(h)) ? "w" w " h" h : "w660 h780"
        if (IsInteger(x) && IsInteger(y) && TaskPointOnScreen(x + 40, y + 20))
            opts .= " x" x " y" y
        tkGui.Show(opts (activate ? "" : " NoActivate"))
    } else {
        tkGui.Show(activate ? "" : "NoActivate")
    }
    if !activate
        return
    try WinActivate("ahk_id " tkGui.Hwnd)
    try tkTree.Focus()
}

TaskWindowShown() {
    try return DllCall("IsWindowVisible", "Ptr", tkGui.Hwnd) && WinGetMinMax("ahk_id " tkGui.Hwnd) != -1
    return false
}

TaskHide() {
    TaskSaveWindowPos()
    tkGui.Hide()
}

TaskSaveWindowPos() {
    try {
        if !DllCall("IsWindowVisible", "Ptr", tkGui.Hwnd) || WinGetMinMax("ahk_id " tkGui.Hwnd) != 0
            return
        tkGui.GetPos(&x, &y)
        tkGui.GetClientPos(, , &w, &h)
        IniWrite(x, TASK_INI, "Window", "X")
        IniWrite(y, TASK_INI, "Window", "Y")
        IniWrite(w, TASK_INI, "Window", "W")
        IniWrite(h, TASK_INI, "Window", "H")
    }
}

TaskPointOnScreen(x, y) {
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return true
    }
    return false
}

; The hotkey: open, or hide when it's in front. Pressed while an app that
; sends Tasks its open item (the Companion) is in front: opens on that item.
TaskSummon(*) {
    if WinActive("ahk_id " tkGui.Hwnd) {
        TaskHide()
        return
    }
    fromApp := false
    for app, hwnd in ctxApps
        if WinActive("ahk_id " hwnd)
            fromApp := true
    TaskShowWindow(fromApp ? TASK_VIEW_LINKED : 0)
}

TaskApplyHotkey() {
    global taskHotkey
    if (taskHotkey != "") {
        try Hotkey(taskHotkey, "Off")
    }
    taskHotkey := Trim(TaskSetting("Hotkey"))
    if (taskHotkey = "")
        return
    try {
        Hotkey(taskHotkey, TaskSummon, "On")
    } catch as err {
        TaskStatus("The Tasks hotkey (" taskHotkey ") could not be set: " err.Message)
        taskHotkey := ""
    }
}

TaskShowHelp() {
    tkGui.Opt("+OwnDialogs")
    MsgBox("Mouse:`n"
        . "  Drag a task onto another: drop on its top edge = above it, bottom edge = below it,`n"
        . "  the middle = inside it (as a subtask). Esc while dragging cancels.`n"
        . "  The buttons above the list add, move, tick and delete. Right-click for the rest.`n"
        . "  Click a selected task again to rename it.`n`n"
        . "Keyboard (in the list):`n"
        . "  Enter = new task · Ctrl+Enter or Insert = new subtask`n"
        . "  Tab / Shift+Tab = in / out a level · Ctrl+Up / Ctrl+Down = move`n"
        . "  F2 = rename · Space = done · Delete · Ctrl+Z = bring back the last deleted`n"
        . "  While typing a new task's name: Enter = save it and start the next one`n"
        . "  (Enter on an empty one stops) · Tab / Shift+Tab = in / out · Esc = cancel`n`n"
        . "Views:`n"
        . "  Linked to current = the tasks of what another app has open (the Companion: the`n"
        . "  live or reviewed call). New top-level tasks made there are linked to it.`n`n"
        . "Timers:`n"
        . "  Timer buttons / Custom… start one now (5, 30s, 1h 30, or a clock time like 3:30 pm).`n"
        . "  Plan… saves a timer with the task, to start later: by you, or when the task above`n"
        . "  it is ticked. A planned timer can also ask how long when it starts.`n"
        . "  Alerts stay until you choose Done, Snooze, After my call, Open or Hide.`n"
        . "  Hide keeps the timer: it stays 'overdue' at the top of Up next and the alert`n"
        . "  comes back every few minutes (settings). Only Done or Stop ends a timer.`n"
        . "  Right-click > Timer history shows everything that happened to a task's timers.`n`n"
        . "Ask before done (right-click): a task asks a question when ticked, like the case`n"
        . "link, and adds the answer to its notes. 🔗 Links opens any link in the checklist.`n`n"
        . "Open / close this window from anywhere: " TaskHotkeyText(),
        "Tasks - help", "Iconi")
}

TaskHotkeyText() {
    k := taskHotkey
    if (k = "")
        return "(no hotkey set)"
    out := ""
    for pair in [["^", "Ctrl+"], ["+", "Shift+"], ["!", "Alt+"], ["#", "Win+"]]
        if InStr(k, pair[1]) {
            out .= pair[2]
            k := StrReplace(k, pair[1])
        }
    return out StrUpper(k)
}

TaskStatus(text) {
    try tkStatus.Text := text
}

; ==============================================================================
; The task tree
; ==============================================================================
TaskSetView(view) {
    global taskView
    taskView := view
    tkView.Value := view
    try IniWrite(view, TASK_INI, "Window", "View")
    TaskRebuildTree()
}

TaskOnViewChange(*) {
    TaskSetView(tkView.Value)
}

TaskOnShowDone(*) {
    global taskShowDone
    taskShowDone := tkShowDone.Value
    try IniWrite(taskShowDone, TASK_INI, "Window", "ShowDone")
    TaskRebuildTree()
}

TaskRootVisible(n) {
    if (taskView = TASK_VIEW_LINKED)
        return TaskLinkIsCurrent(n["link"])
    if (taskView = TASK_VIEW_UNLINKED)
        return !(n["link"] is Map)
    return true
}

TaskNodeVisible(n) {
    return taskShowDone || !n["done"]
}

TaskRebuildTree(selectId := "") {
    global tvToTask, taskToTv
    if (selectId = "")
        selectId := TaskSelectedId()
    tkTree.Opt("-Redraw")
    try {
        tkTree.Delete()
        tvToTask := Map()
        taskToTv := Map()
        for n in taskDoc["tasks"]
            if (TaskRootVisible(n) && TaskNodeVisible(n))
                TaskAddTv(n, 0)
        if (selectId != "" && taskToTv.Has(selectId))
            tkTree.Modify(taskToTv[selectId], "Select Vis")
    } finally {
        tkTree.Opt("+Redraw")
    }
    if (selectId != "" && taskToTv.Has(selectId))
        try tkTree.Modify(taskToTv[selectId], "Vis")   ; scroll to it (again, now it's drawn)
    TaskShowSelected()
    TaskRefreshHeader()
}

TaskAddTv(n, parentItem) {
    item := tkTree.Add(TaskLabel(n), parentItem, n["done"] ? "Check" : "")
    tvToTask[item] := n["id"]
    taskToTv[n["id"]] := item
    for c in n["children"]
        if TaskNodeVisible(c)
            TaskAddTv(c, item)
    if (!n["collapsed"] && n["children"].Length)
        tkTree.Modify(item, "Expand")
    return item
}

TaskLabel(n) {
    t := TaskTitle(n)
    if TaskHasUrl(n)
        t .= "  🔗"
    a := n["askOnDone"]
    if ((a is Map) && !n["done"])
        t .= "  (asks for " ((a["label"] != "") ? a["label"] : "an answer") " when ticked)"
    s := TaskTimerText(n)
    if (s != "")
        t .= "      " s
    l := n["link"]
    if (taskView != TASK_VIEW_LINKED && (l is Map) && TaskIsRoot(n) && l.Get("label", "") != "")
        t .= "      [" l["label"] "]"
    return t
}

TaskTimerText(n) {
    tm := n["timer"]
    if (tm is Map) {
        switch tm.Get("state", "running") {
            case "running":
                return "⏱ " TaskFmtLeft(TaskSecsUntil(tm["dueAtUtc"]))
            case "due":
                return (TaskHoldAlerts() && !TAlertShown(n["id"])) ? "🔔 when you're free" : "🔔 time's up"
            case "afterCall":
                return "🔔 after your call"
            case "hidden":
                return "🔴 overdue " TaskOverdueText(tm)
        }
    }
    at := n["autoTimer"]
    if (!n["done"] && (at is Map))
        return "(" TaskPlanText(at) ")"
    return ""
}

; "planned 5m, starts after the task above"
TaskPlanText(at) {
    txt := at["ask"] ? "planned timer, asks how long" : "planned " TaskDurLabel(at["seconds"])
    switch at["start"] {
        case "afterPrevious": txt .= ", starts after the task above"
        case "now":           txt .= ", starts when added"
    }
    return txt
}

TaskEditing() {
    try return SendMessage(0x110F, 0, 0, tkTree) != 0      ; TVM_GETEDITCONTROL
    return false
}

; Updates one task's text in the list (skipped while a name is being typed)
TaskRelabel(n) {
    if !IsObject(n) || !taskToTv.Has(n["id"]) || TaskEditing()
        return
    item := taskToTv[n["id"]]
    label := TaskLabel(n)
    try {
        if (tkTree.GetText(item) != label)
            tkTree.Modify(item, , label)
    }
}

TaskSelectedId() {
    try {
        item := tkTree.GetSelection()
        if (item && tvToTask.Has(item))
            return tvToTask[item]
    }
    return ""
}

TaskSelectedNode() {
    id := TaskSelectedId()
    return (id != "") ? taskById.Get(id, "") : ""
}

TaskNodeOfTv(item) {
    return tvToTask.Has(item) ? taskById.Get(tvToTask[item], "") : ""
}

TaskShowSelected() {
    global taskNotesId
    n := TaskSelectedNode()
    has := IsObject(n)
    taskNotesId := has ? n["id"] : ""
    tkNotes.Enabled := has
    tkNotes.Value := has ? n["notes"] : ""
    tkNotesLbl.Text := has ? "NOTES  -  " TaskPath(n) : "NOTES  -  pick a task"
    for b in tkTimerBtns
        b.Enabled := has
    tkBtnCustom.Enabled := has
    tkBtnPlan.Enabled := has
    tkBtnStop.Enabled := has && (n["timer"] is Map)
    for i, b in tkToolbar
        if (i > 1)
            b.Enabled := has
}

; The bar under the view picker. Yellow while showing what an app has open.
TaskRefreshHeader() {
    busy := TaskIsBusy() ? "   ·   busy (on a call)" : ""
    linked := (taskView = TASK_VIEW_LINKED)
    if linked {
        if (ctxId = "")
            txt := "  Nothing open yet. Press Tasks in the Companion (or this hotkey while it's in front)."
        else
            txt := "  LINKED TO   " ctxLabel (ctxNote != "" ? "   (" ctxNote ")" : "") busy
    } else {
        txt := (ctxId = "") ? "  No app connected" : "  Open in " ctxApp ":  " ctxLabel busy
    }
    try {
        tkBanner.Opt(linked ? "+Background3B3215" : "+Background11151D")
        tkBanner.SetFont(linked ? "cFBBF24 bold" : "c9BA8BA norm")
        tkBanner.Text := txt
    }
}

TaskOnExpand(ctrl, item, expanded) {
    n := TaskNodeOfTv(item)
    if !IsObject(n)
        return
    v := expanded ? 0 : 1
    if (n["collapsed"] != v) {
        n["collapsed"] := v
        TaskSaveSoon()
    }
}

TaskOnCheck(ctrl, item, checked) {
    n := TaskNodeOfTv(item)
    if !IsObject(n)
        return
    if ((checked ? 1 : 0) = (n["done"] ? 1 : 0))
        return                            ; already so (e.g. the list being redrawn)
    TaskSetDone(n, checked)
}

TaskToggleDoneSelected(*) {
    n := TaskSelectedNode()
    if IsObject(n)
        TaskSetDone(n, !n["done"])
}

TaskSetDone(n, done) {
    if !IsObject(n)
        return
    if (done && !n["done"] && !TaskAskBeforeDone(n)) {
        if taskToTv.Has(n["id"])                  ; cancelled: untick it again
            try tkTree.Modify(taskToTv[n["id"]], "-Check")
        return
    }
    n["done"] := done ? 1 : 0
    n["doneAtUtc"] := done ? TaskNowIso() : ""
    if done {
        TaskStopTimer(n, "done")
        TaskStartNextPlanned(n)
    }
    TaskSaveSoon()
    if (done && !taskShowDone) {
        TaskRebuildTree()
        return
    }
    if taskToTv.Has(n["id"])
        try tkTree.Modify(taskToTv[n["id"]], done ? "Check" : "-Check")
    TaskRelabel(n)
    TaskShowSelected()
}

; ==============================================================================
; Ask before done, and links in notes
; ==============================================================================
; Asks the task's question before it's ticked; the answer goes into its notes
; as "label: answer" (replacing an earlier answer). False = cancelled.
TaskAskBeforeDone(n) {
    a := n["askOnDone"]
    if !(a is Map)
        return true
    label := (a["label"] != "") ? a["label"] : "Answer"
    prev := TaskNoteValue(n["notes"], label)
    hint := a["required"] ? "" : "`n`n(You can leave it empty.)"
    v := ""
    Loop {
        if TaskWindowShown()
            tkGui.Opt("+OwnDialogs")
        r := InputBox(a["question"] hint, "Before ticking: " TaskTitle(n), "w480 h170", prev)
        if (r.Result != "OK")
            return false
        v := Trim(r.Value)
        if (v != "" || !a["required"])
            break
        hint := "`n`n(An answer is needed before this can be ticked. Cancel to leave it open.)"
    }
    if (v != "") {
        n["notes"] := TaskSetNoteValue(n["notes"], label, v)
        if (taskNotesId = n["id"])
            tkNotes.Value := n["notes"]
        TaskSaveSoon()
    }
    return true
}

; The value of a "label: value" line in notes, or ""
TaskNoteValue(notes, label) {
    if RegExMatch(notes, "im)^\Q" label "\E:[ \t]*(.*?)\r?$", &m)
        return Trim(m[1])
    return ""
}

TaskSetNoteValue(notes, label, value) {
    line := label ": " value
    if RegExMatch(notes, "im)^\Q" label "\E:.*$")
        return RegExReplace(notes, "im)^\Q" label "\E:.*?(?=\r?$)", StrReplace(line, "$", "$$"), , 1)
    return (Trim(notes) = "") ? line : RTrim(notes, "`r`n") "`n" line
}

; Web links in a piece of text (www. ones get https://)
TaskUrlsIn(text) {
    urls := []
    pos := 1
    while (pos := RegExMatch(text, "i)\b(?:https?://|www\.)[^\s<>`"]+", &m, pos)) {
        u := RegExReplace(m[0], "[).,;:!?'\]]+$")
        if !InStr(u, "://")
            u := "https://" u
        urls.Push(u)
        pos += m.Len[0]
    }
    return urls
}

TaskHasUrl(n) {
    return TaskUrlsIn(n["title"] "`n" n["notes"]).Length > 0
}

; Every link in the task's whole checklist (its top-level task and all under
; it), the task's own first: the case link is one click away from any step
TaskLinksAround(n) {
    out := []
    seen := Map()
    TaskCollectUrls(n, out, seen)
    TaskEachIn(TaskRoot(n), (x) => TaskCollectUrls(x, out, seen))
    return out
}

; Each link is named by the text before it on its line ("Case link: https://..."
; -> "Case link"), or by its task's name when the line is just the link
TaskCollectUrls(x, out, seen) {
    for line in StrSplit(x["title"] "`n" x["notes"], "`n", "`r") {
        name := Trim(RegExReplace(line, "i)\b(?:https?://|www\.).*$"), " `t:-–")
        for u in TaskUrlsIn(line) {
            if seen.Has(u)
                continue
            seen[u] := true
            out.Push({url: u, title: (name != "") ? name : TaskTitle(x)})
        }
    }
}

; One link: opens it. Several: a menu to pick from.
TaskOpenLinks(n) {
    if !IsObject(n) {
        TaskStatus("Pick a task first.")
        return
    }
    links := TaskLinksAround(n)
    if !links.Length {
        TaskStatus("No links in this checklist yet (paste one into a task's notes).")
        return
    }
    if (links.Length = 1) {
        TaskOpenUrl(links[1].url)
        return
    }
    m := Menu()
    for i, l in links {
        u := StrLen(l.url) > 60 ? SubStr(l.url, 1, 57) "..." : l.url
        m.Add(i ".  " l.title "  -  " u, TaskOpenUrl.Bind(l.url))
    }
    m.Show()
}

TaskOpenUrl(url, *) {
    try {
        Run(url)
        TaskStatus("Opened " url)
    } catch as err {
        TaskStatus("Could not open the link: " err.Message)
    }
}

; Set / change / remove what a task asks before it can be ticked
TaskAskDialog(n) {
    if !IsObject(n)
        return
    a := n["askOnDone"]
    has := (a is Map)
    g := Gui("+Owner" tkGui.Hwnd " -MinimizeBox", "Ask before done")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "xm w440", "For: " TaskPath(n))
    g.Add("Text", "xm y+6 w440 c666666", "When this task is ticked, Tasks asks this first. The answer is added to the task's notes as `"Name: answer`". Links in notes open with the 🔗 Links button.")
    g.Add("Text", "xm y+12", "Question")
    q := g.Add("Edit", "xm y+4 w440", has ? a["question"] : "")
    g.Add("Text", "xm y+10", "Name for the answer in the notes (like Case link)")
    lbl := g.Add("Edit", "xm y+4 w220", has ? a["label"] : "")
    req := g.Add("Checkbox", "xm y+12", "An answer is needed before it can be ticked")
    req.Value := has ? a["required"] : 1
    save := g.Add("Button", "xm y+18 w90 Default", "Save")
    remove := g.Add("Button", "x+8 w110", "Remove")
    cancel := g.Add("Button", "x+8 w90", "Cancel")
    TipSet(remove, "Take this question off the task (it won't be asked any more)")
    remove.Enabled := has
    save.OnEvent("Click", DoSave)
    remove.OnEvent("Click", DoRemove)
    cancel.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show()

    DoSave(*) {
        if (Trim(q.Value) = "") {
            g.Opt("+OwnDialogs")
            MsgBox("Type the question to ask.", "Ask before done", "Icon!")
            return
        }
        n["askOnDone"] := TaskNormAsk(TaskNewMap("question", q.Value, "label", lbl.Value, "required", req.Value))
        g.Destroy()
        TaskSaveSoon()
        TaskRelabel(n)
        TaskStatus("'" TaskTitle(n) "' will ask before it's ticked")
    }

    DoRemove(*) {
        n["askOnDone"] := Json.Null
        g.Destroy()
        TaskSaveSoon()
        TaskRelabel(n)
        TaskStatus("'" TaskTitle(n) "' no longer asks before it's ticked")
    }
}

; The name box opens with just the name (the list also shows timers and links)
TaskOnBeginEdit(ctrl, lParam) {
    try {
        n := TaskSelectedNode()
        hEdit := SendMessage(0x110F, 0, 0, tkTree)                 ; TVM_GETEDITCONTROL
        if (IsObject(n) && hEdit)
            DllCall("SetWindowText", "Ptr", hEdit, "Str", n["title"])
    }
    return 0
}

; Saves the typed name. Returns 0 so the list doesn't paste the raw text in;
; the label is redrawn from the task instead.
TaskOnEndEdit(ctrl, lParam) {
    global taskNewEditId
    try {
        item := NumGet(lParam, 4 * A_PtrSize, "Ptr")              ; NMTVDISPINFO.item.hItem
        pText := NumGet(lParam, 5 * A_PtrSize + 8, "Ptr")         ; .item.pszText (0 = cancelled)
        n := TaskNodeOfTv(item)
        if IsObject(n) {
            if pText {
                n["title"] := Trim(StrGet(pText, "UTF-16"))
                TaskSaveSoon()
            }
            if (Trim(n["title"]) = "" && n["id"] = taskNewEditId)
                SetTimer(TaskDropNew.Bind(n["id"]), -10)        ; a new task left without a name
            else
                SetTimer(TaskRelabel.Bind(n), -10)
        }
    }
    taskNewEditId := ""
    return 0
}

TaskBeginEdit(id) {
    if !taskToTv.Has(id)
        return
    item := taskToTv[id]
    tkTree.Modify(item, "Select Vis")
    tkTree.Focus()
    SendMessage(0x1141, 0, item, tkTree)                      ; TVM_EDITLABELW
}

TaskDropNew(id) {
    n := taskById.Get(id, "")
    if (!IsObject(n) || Trim(n["title"]) != "" || n["children"].Length)
        return
    list := TaskSiblings(n)
    i := TaskIndexIn(list, n)
    if !i
        return
    list.RemoveAt(i)
    TaskStructureChanged(i > 1 ? list[i - 1]["id"] : (IsObject(p := TaskParentOf(n)) ? p["id"] : ""))
}

; After adding / moving / deleting: rebuild the index and the list, save
TaskStructureChanged(selectId := "") {
    TaskReindex()
    TaskRebuildTree(selectId)
    TaskRefreshUpNext()
    TaskSaveSoon()
}

; A task that becomes top-level keeps showing where it was: it takes the link
; of the top-level task it came from / was dropped next to
TaskBecameRoot(n, linkFrom) {
    if (n["link"] is Map)
        return
    l := IsObject(linkFrom) ? linkFrom["link"] : ""
    n["link"] := (l is Map) ? TaskNewLink(l["app"], l["id"], l["label"]) : Json.Null
}

TaskAddSibling(*) {
    global taskNewEditId
    sel := TaskSelectedNode()
    n := TaskNewNode()
    if IsObject(sel) {
        list := TaskSiblings(sel)
        list.InsertAt(TaskIndexIn(list, sel) + 1, n)
        if TaskIsRoot(sel)
            TaskBecameRoot(n, sel)
    } else {
        TaskAddRoot(n)
    }
    taskNewEditId := n["id"]
    TaskStructureChanged(n["id"])
    SetTimer(TaskBeginEdit.Bind(n["id"]), -30)
}

TaskAddChild(*) {
    global taskNewEditId
    sel := TaskSelectedNode()
    if !IsObject(sel) {
        TaskAddSibling()
        return
    }
    n := TaskNewNode()
    sel["children"].Push(n)
    sel["collapsed"] := 0
    if (sel["done"] && !taskShowDone)
        sel["done"] := 0                  ; otherwise the new subtask would be hidden
    taskNewEditId := n["id"]
    TaskStructureChanged(n["id"])
    SetTimer(TaskBeginEdit.Bind(n["id"]), -30)
}

; New top-level task: linked to what's open when you're looking at it
TaskAddRoot(n) {
    if (taskView = TASK_VIEW_LINKED) {
        if (ctxId != "") {
            n["link"] := TaskNewLink(ctxApp, ctxId, ctxLabel)
        } else {
            TaskStatus("Nothing is open in another app, so the task was added without a link (showing All tasks).")
            TaskSetView(TASK_VIEW_ALL)
        }
    }
    taskDoc["tasks"].Push(n)
}

; Tab: becomes the last subtask of the task above it
TaskIndent(*) {
    n := TaskSelectedNode()
    if !IsObject(n)
        return
    list := TaskSiblings(n)
    i := TaskIndexIn(list, n)
    if (i <= 1)
        return
    prev := list[i - 1]
    list.RemoveAt(i)
    prev["children"].Push(n)
    prev["collapsed"] := 0
    n["link"] := Json.Null                    ; subtasks follow their top-level task
    TaskStructureChanged(n["id"])
}

; Shift+Tab: moves out to sit just below its parent
TaskOutdent(*) {
    n := TaskSelectedNode()
    if !IsObject(n) || TaskIsRoot(n)
        return
    p := TaskParentOf(n)
    p["children"].RemoveAt(TaskIndexIn(p["children"], n))
    outer := TaskSiblings(p)
    outer.InsertAt(TaskIndexIn(outer, p) + 1, n)
    if TaskIsRoot(p)
        TaskBecameRoot(n, p)
    TaskStructureChanged(n["id"])
}

TaskMove(dir, *) {
    n := TaskSelectedNode()
    if !IsObject(n)
        return
    list := TaskSiblings(n)
    i := TaskIndexIn(list, n)
    j := i + dir
    if (j < 1 || j > list.Length)
        return
    other := list[j]
    list[j] := n
    list[i] := other
    TaskStructureChanged(n["id"])
}

TaskDeleteSelected(*) {
    global taskLastDeleted
    n := TaskSelectedNode()
    if !IsObject(n)
        return
    if n["children"].Length {
        tkGui.Opt("+OwnDialogs")
        count := TaskCountUnder(n)
        if (MsgBox("Delete '" TaskTitle(n) "' and its " count " subtask(s)?`n`nCtrl+Z brings it back.", "Delete task", "YesNo Icon? Default2") != "Yes")
            return
    }
    list := TaskSiblings(n)
    i := TaskIndexIn(list, n)
    p := TaskParentOf(n)
    taskLastDeleted := {node: n, parentId: IsObject(p) ? p["id"] : "", index: i}
    TaskEachIn(n, (x) => TAlertClose(x["id"]))
    list.RemoveAt(i)
    nextSel := (i <= list.Length) ? list[i]["id"] : (i > 1 ? list[i - 1]["id"] : (IsObject(p) ? p["id"] : ""))
    TaskStructureChanged(nextSel)
    TaskStatus("Deleted '" TaskTitle(n) "'.  Ctrl+Z brings it back.")
}

TaskUndoDelete() {
    global taskLastDeleted
    if !IsObject(taskLastDeleted)
        return
    d := taskLastDeleted
    taskLastDeleted := ""
    p := (d.parentId != "") ? taskById.Get(d.parentId, "") : ""
    list := IsObject(p) ? p["children"] : taskDoc["tasks"]
    list.InsertAt(Min(Max(1, d.index), list.Length + 1), d.node)
    TaskStructureChanged(d.node["id"])
    TaskStatus("Brought back '" TaskTitle(d.node) "'.")
}

TaskOnNotesChange(*) {
    n := (taskNotesId != "") ? taskById.Get(taskNotesId, "") : ""
    if !IsObject(n)
        return
    v := tkNotes.Value
    if (n["notes"] != v) {
        hadUrl := TaskHasUrl(n)
        n["notes"] := v
        TaskSaveSoon()
        if (TaskHasUrl(n) != hadUrl)
            TaskRelabel(n)                    ; the 🔗 mark comes / goes
    }
}

TaskOnContextMenu(ctrl, item, isRightClick, x, y) {
    if item
        tkTree.Modify(item, "Select")
    n := TaskSelectedNode()
    m := Menu()
    m.Add("New task below`tEnter", (*) => TaskAddSibling())
    if IsObject(n) {
        m.Add("New subtask`tCtrl+Enter", (*) => TaskAddChild())
        m.Add("Rename`tF2", (*) => TaskBeginEdit(n["id"]))
        m.Add(n["done"] ? "Mark not done`tSpace" : "Mark done`tSpace", (*) => TaskSetDone(n, !n["done"]))
        m.Add()
        tm := Menu()
        for secs in TaskDurationList(TaskSetting("QuickTimers"), 10)
            tm.Add(TaskDurLabel(secs), TaskTimerFromMenu.Bind(n["id"], secs))
        tm.Add("Custom…", (*) => TaskCustomTimer(n))
        m.Add("Start a timer now", tm)
        if (n["timer"] is Map)
            m.Add("Stop the timer", (*) => TaskStopTimer(n))
        m.Add(n["autoTimer"] is Map ? "Change the planned timer…" : "Plan a timer…", (*) => TaskPlanDialog(n))
        if (n["autoTimer"] is Map)
            m.Add("Start the planned timer now", (*) => TaskStartPlanned(n))
        if n["history"].Length
            m.Add("Timer history…", (*) => TaskHistoryWindow(n))
        m.Add(n["askOnDone"] is Map ? "Change what it asks before done…" : "Ask for something before done…", (*) => TaskAskDialog(n))
        m.Add()
        if TaskLinksAround(n).Length
            m.Add("🔗 Open a link from this checklist", (*) => TaskOpenLinks(n))
        rm := Menu()
        rm.Add("This task (and its notes)", (*) => TaskReadAloud(n, false))
        rm.Add("This task and its subtasks", (*) => TaskReadAloud(n, true))
        rm.Add("Stop reading", (*) => TaskSpeak(""))
        m.Add("Read aloud", rm)
        m.Add()
        l := TaskLinkOf(n)
        if IsObject(l)
            m.Add("Open " l["label"] " in " l["app"], (*) => TaskOpenLink(n))
        if TaskIsRoot(n) {
            if (ctxId != "" && !TaskLinkIsCurrent(n["link"]))
                m.Add("Link to " ctxLabel, (*) => TaskSetLink(n, true))
            if (n["link"] is Map)
                m.Add("Remove the link", (*) => TaskSetLink(n, false))
        }
        m.Add("Save as a template…", (*) => TaskSaveAsTemplate(n))
        m.Add()
        m.Add("Delete`tDel", (*) => TaskDeleteSelected())
    }
    m.Show()
}

TaskSetLink(n, link) {
    n["link"] := link ? TaskNewLink(ctxApp, ctxId, ctxLabel) : Json.Null
    TaskSaveSoon()
    TaskRebuildTree(n["id"])
    TaskStatus(link ? "Linked to " ctxLabel : "Link removed")
}

; Asks the app the task is linked to to show that item (the Companion: review the call)
TaskOpenLink(n) {
    l := TaskLinkOf(n)
    if !IsObject(l)
        return false
    hwnd := ctxApps.Get(l["app"], 0)
    if (hwnd && WinExist("ahk_id " hwnd) && TaskSendTo(hwnd, "open`t" l["id"]))
        return true
    TaskStatus(l["app"] " isn't open, so " l["label"] " can't be shown.")
    return false
}

; Shows a task wherever it is: switches view / shows done tasks / opens its
; parents / scrolls to it. view: the view to prefer (0 = keep, if it shows the task)
TaskOpenTask(id, view := 0) {
    global taskShowDone, taskView
    n := taskById.Get(id, "")
    if !IsObject(n)
        return
    if view {
        taskView := view                      ; set quietly; the rebuild below draws it
        tkView.Value := view
    }
    if !TaskRootVisible(TaskRoot(n)) {
        taskView := TASK_VIEW_ALL
        tkView.Value := TASK_VIEW_ALL
    }
    try IniWrite(taskView, TASK_INI, "Window", "View")
    hidden := false
    x := n
    while IsObject(x) {
        if x["done"]
            hidden := true
        if (x["id"] != n["id"])
            x["collapsed"] := 0
        x := TaskParentOf(x)
    }
    if (hidden && !taskShowDone) {
        taskShowDone := 1
        tkShowDone.Value := 1
    }
    TaskRebuildTree(id)
    TaskShowWindow()
}

; Open from an alert / Up next: the task, and its linked item in its app (the
; Companion opens the call). Once the app says it has that item open, Tasks
; switches to "Linked to current" so both windows show the same call.
TaskOpenTaskAndLink(id) {
    global taskPendingFocus
    n := taskById.Get(id, "")
    if !IsObject(n)
        return
    l := TaskLinkOf(n)
    if !IsObject(l) {
        TaskOpenTask(id)
        return
    }
    if TaskLinkIsCurrent(l) {                 ; already open there
        TaskOpenTask(id, TASK_VIEW_LINKED)
        TaskOpenLink(n)
        return
    }
    TaskOpenTask(id)                          ; show it straight away...
    if TaskOpenLink(n) {
        taskPendingFocus := id                ; ...and move to its call's view when it's open
        SetTimer(TaskPendingFocusTimeout, -3000)
    }
}

TaskPendingFocusTimeout() {
    global taskPendingFocus
    taskPendingFocus := ""
}

; ==============================================================================
; Drag and drop with the mouse
; ==============================================================================
TaskOnBeginDrag(ctrl, lParam) {
    global taskDragId
    try {
        tvitem := (A_PtrSize = 8) ? 56 : 40                         ; sizeof(TVITEMW)
        item := NumGet(lParam, 5 * A_PtrSize + tvitem, "Ptr")       ; NMTREEVIEW.itemNew.hItem
        n := TaskNodeOfTv(item)
        if !IsObject(n)
            return 0
        taskDragId := n["id"]
        tkTree.Modify(item, "Select")
        SetTimer(TaskDragLoop, -1)
    }
    return 0
}

TaskDragLoop() {
    global taskDragId
    n := taskById.Get(taskDragId, "")
    taskDragId := ""
    if !IsObject(n)
        return
    target := ""
    where := ""
    cancelled := false
    try {
        while GetKeyState("LButton", "P") {
            if GetKeyState("Escape", "P") {
                cancelled := true
                break
            }
            TaskDragHover(n, &target, &where)
            Sleep(30)
        }
    }
    ToolTip()
    try SendMessage(0x110B, 8, 0, tkTree)            ; TVM_SELECTITEM TVGN_DROPHILITE: clear
    if (cancelled || !IsObject(target))
        return
    TaskDropOn(n, target, where)
}

; Where the mouse is: which task, and above / inside / below it
TaskDragHover(n, &target, &where) {
    target := ""
    where := ""
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", tkTree.Hwnd, "Ptr", pt)
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")
    tkTree.GetPos(, , , &th)
    if (y < 12)
        SendMessage(0x0115, 0, 0, tkTree)            ; WM_VSCROLL SB_LINEUP: scroll while dragging
    else if (y > th - 12)
        SendMessage(0x0115, 1, 0, tkTree)            ; SB_LINEDOWN
    hti := Buffer(A_PtrSize = 8 ? 24 : 16, 0)        ; TVHITTESTINFO
    NumPut("Int", x, hti, 0)
    NumPut("Int", y, hti, 4)
    item := SendMessage(0x1111, 0, hti, tkTree)      ; TVM_HITTEST
    if (A_PtrSize = 4 && item < 0)
        item += 0x100000000
    t := item ? TaskNodeOfTv(item) : ""
    if !IsObject(t) {
        SendMessage(0x110B, 8, 0, tkTree)
        ToolTip("Drop on a task")
        return
    }
    if TaskIsInside(t, n) {
        SendMessage(0x110B, 8, 0, tkTree)
        ToolTip("Can't drop a task into itself")
        return
    }
    rc := Buffer(16, 0)
    NumPut("Ptr", item, rc, 0)
    SendMessage(0x1104, 0, rc, tkTree)               ; TVM_GETITEMRECT (whole row)
    top := NumGet(rc, 4, "Int")
    bottom := NumGet(rc, 12, "Int")
    q := Max(2, (bottom - top) // 4)
    where := (y < top + q) ? "before" : (y >= bottom - q) ? "after" : "inside"
    target := t
    SendMessage(0x110B, 8, item, tkTree)             ; highlight the target
    ToolTip((where = "before") ? "▲ above  " TaskTitle(t)
        : (where = "after") ? "▼ below  " TaskTitle(t)
        : "➜ inside  " TaskTitle(t))
}

TaskDropOn(n, t, where) {
    if (t["id"] = n["id"])
        return
    list := TaskSiblings(n)
    list.RemoveAt(TaskIndexIn(list, n))
    if (where = "inside") {
        t["children"].Push(n)
        t["collapsed"] := 0
        n["link"] := Json.Null                ; subtasks follow their top-level task
    } else {
        tl := TaskSiblings(t)
        i := TaskIndexIn(tl, t)
        tl.InsertAt(where = "after" ? i + 1 : i, n)
        if TaskIsRoot(t)
            TaskBecameRoot(n, t)
        else
            n["link"] := Json.Null
    }
    TaskStructureChanged(n["id"])
    TaskStatus("Moved '" TaskTitle(n) "'")
}

; ==============================================================================
; Read aloud (Windows speech; voice and speed in settings)
; ==============================================================================
TaskReadAloud(n, withSubtasks) {
    TaskSpeak(TaskReadText(n, withSubtasks))
}

TaskReadText(n, withSubtasks) {
    text := TaskTitle(n) ".`n"
    if (Trim(n["notes"]) != "")
        text .= n["notes"] "`n"
    if withSubtasks
        for c in n["children"]
            text .= TaskReadText(c, true)
    return text
}

; text "" = stop reading
TaskSpeak(text, voiceName := "", rate := "") {
    global taskVoice
    try {
        if !IsObject(taskVoice)
            taskVoice := ComObject("SAPI.SpVoice")
        if (text = "") {
            taskVoice.Speak("", 3)                   ; purge = stop
            return
        }
        want := (voiceName != "") ? voiceName : TaskSetting("ReadVoice")
        if (want != "") {
            for v in taskVoice.GetVoices()
                if (v.GetDescription() = want) {
                    taskVoice.Voice := v
                    break
                }
        }
        r := (rate != "") ? rate : TaskSettingInt("ReadRate", -10, 10)
        taskVoice.Rate := IsInteger(r) ? Min(10, Max(-10, Integer(r))) : 0
        taskVoice.Speak(text, 3)                     ; 1 = don't wait, 2 = stop what's playing
    } catch as err {
        TaskStatus("Read aloud doesn't work here: " err.Message)
    }
}

TaskVoiceNames() {
    names := []
    try {
        v := ComObject("SAPI.SpVoice")
        for t in v.GetVoices()
            names.Push(t.GetDescription())
    }
    return names
}

; ==============================================================================
; Up next: every timer, soonest first
; ==============================================================================
; Order: overdue (hidden) · ringing · running soonest first · after your call ·
; then (if shown) today's finished timers, newest first
TaskSortKey(tm) {
    switch tm.Get("state", "running") {
        case "hidden": return -2 - Max(0, -TaskSecsUntil(tm["dueAtUtc"])) / 1000000
        case "due": return -1
        case "afterCall": return 999999999
    }
    return Max(0, TaskSecsUntil(tm["dueAtUtc"]))
}

TaskRefreshUpNext() {
    global taskUpNextIds, taskUpNextSig
    rows := []
    for id, n in taskById {
        tm := n["timer"]
        if (tm is Map)
            TaskInsertRow(rows, {id: id, key: TaskSortKey(tm), when: TaskTimerText(n), title: TaskPath(n), link: TaskLinkLabel(n), fixed: ""})
        if taskShowFinished
            TaskAddFinishedRows(rows, id, n)
    }
    sig := ""
    for r in rows
        sig .= r.id "|" r.title "|" r.link "|" r.fixed "`n"
    try {
        if (sig != taskUpNextSig) {
            tkList.Opt("-Redraw")
            tkList.Delete()
            ids := []
            for r in rows {
                tkList.Add(, r.when, r.title, r.link)
                ids.Push(r.id)
            }
            tkList.Opt("+Redraw")
            taskUpNextIds := ids
            taskUpNextSig := sig
        } else {
            for i, r in rows
                if (tkList.GetText(i, 1) != r.when)
                    tkList.Modify(i, "Col1", r.when)
        }
    }
}

TaskInsertRow(rows, r) {
    i := rows.Length
    while (i >= 1 && rows[i].key > r.key)
        i -= 1
    rows.InsertAt(i + 1, r)
}

; Timers of this task that ended today ("✓ done 2:20 PM", "⏹ stopped 2:13 PM")
TaskAddFinishedRows(rows, id, n) {
    today := FormatTime(A_Now, "yyyyMMdd")
    for e in n["history"] {
        if (e.Get("kind", "") != "end" || TaskIsoLocal(e.Get("at", ""), "yyyyMMdd") != today)
            continue
        what := e.Get("what", "")
        when := ((what = "done") ? "✓ done " : "⏹ " what " ") TaskIsoLocal(e["at"], "h:mm tt")
        stamp := TaskIsoStamp(e["at"])
        TaskInsertRow(rows, {id: id, key: 1000000000000000 - stamp, when: when, title: TaskPath(n), link: TaskLinkLabel(n), fixed: when})
    }
}

TaskOnShowFinished(*) {
    global taskShowFinished, taskUpNextSig
    taskShowFinished := tkShowFinished.Value
    try IniWrite(taskShowFinished, TASK_INI, "Window", "ShowFinished")
    taskUpNextSig := ""
    TaskRefreshUpNext()
}

TaskOnUpNextOpen(ctrl, row) {
    if (row >= 1 && row <= taskUpNextIds.Length)
        TaskOpenTaskAndLink(taskUpNextIds[row])
}

; ==============================================================================
; Timers
; ==============================================================================
; why: what the history says ("" = "timer 5m started")
TaskStartTimer(n, seconds, why := "") {
    if (!IsObject(n) || seconds <= 0)
        return
    seconds := Round(seconds)
    n["timer"] := TaskNewMap("dueAtUtc", TaskIsoIn(seconds), "seconds", seconds, "state", "running"
        , "afterSinceUtc", "", "sawBusy", 0, "hiddenAtUtc", "")
    TaskHistory(n, "start", (why != "") ? why : "timer " TaskDurLabel(seconds) " started")
    TAlertClose(n["id"])
    TaskSaveSoon()
    TaskRelabel(n)
    TaskRefreshUpNext()
    TaskShowSelected()
    TaskStatus("Timer started: " TaskDurLabel(seconds) " for '" TaskTitle(n) "'")
}

; The only way a timer ends: the task is done, or you stop it in Tasks.
; reason goes into the history ("done" / "stopped").
TaskStopTimer(n, reason := "stopped") {
    if !IsObject(n)
        return
    had := (n["timer"] is Map)
    n["timer"] := Json.Null
    TAlertClose(n["id"])
    if had {
        TaskHistory(n, "end", reason)
        TaskSaveSoon()
        TaskRelabel(n)
        TaskRefreshUpNext()
        TaskShowSelected()
    }
}

TaskQuickTimer(i, *) {
    n := TaskSelectedNode()
    if (IsObject(n) && i <= taskQuick.Length)
        TaskStartTimer(n, taskQuick[i])
}

TaskTimerFromMenu(id, secs, *) {
    TaskStartTimer(taskById.Get(id, ""), secs)
}

TaskCustomTimer(n, question := "") {
    if !IsObject(n)
        return
    secs := TaskAskDuration(question, n)
    if (secs > 0)
        TaskStartTimer(n, secs)
}

; Asks how long. Returns seconds, or -1 if cancelled.
TaskAskDuration(question, n) {
    q := (question != "") ? question "`n`n" : ""
    Loop {
        tkGui.Opt("+OwnDialogs")
        r := InputBox(q "How long? Like 5 (minutes), 30s, 1h 30 - or a clock time like 3:30 pm:",
            "Timer - " TaskTitle(n), "w440 h180")
        if (r.Result != "OK")
            return -1
        secs := TaskParseDuration(r.Value)
        if (secs > 0)
            return secs
        q := "Couldn't read '" r.Value "'. Try again.`n`n"
    }
}

; Starts a task's planned timer: its length, or asks how long
TaskStartPlanned(n) {
    at := n["autoTimer"]
    if !(at is Map)
        return
    if at["ask"] {
        TaskShowWindow()
        TaskCustomTimer(n, at["question"])
    } else if (at["seconds"] > 0) {
        TaskStartTimer(n, at["seconds"], "planned timer " TaskDurLabel(at["seconds"]) " started")
    }
}

; Ticking a task starts the planned timer of the task below it, if that one
; is set to start that way
TaskStartNextPlanned(n) {
    list := TaskSiblings(n)
    i := TaskIndexIn(list, n)
    if (!i || i >= list.Length)
        return
    nx := list[i + 1]
    at := nx["autoTimer"]
    if (nx["done"] || (nx["timer"] is Map) || !(at is Map))
        return
    if (at["start"] = "afterPrevious")
        TaskStartPlanned(nx)
}

; Plan / change / remove a task's planned timer
TaskPlanDialog(n) {
    if !IsObject(n)
        return
    at := n["autoTimer"]
    has := (at is Map)
    g := Gui("+Owner" tkGui.Hwnd " -MinimizeBox", "Planned timer")
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "xm w440", "For: " TaskPath(n))
    g.Add("Text", "xm y+6 w440 c666666", "A planned timer is kept with the task and started later: by you (right-click > Start the planned timer now), or by itself when the task above is ticked done.")
    rFixed := g.Add("Radio", "xm y+12 Group", "Length:")
    dur := g.Add("Edit", "x+8 yp-3 w110", (has && !at["ask"]) ? TaskDurLabel(at["seconds"]) : "5m")
    g.Add("Text", "x+8 yp+3 c666666", "like 5 (minutes), 30s, 1h 30")
    rAsk := g.Add("Radio", "xm y+14", "Ask me how long when it starts, with this question:")
    q := g.Add("Edit", "xm+20 y+6 w420", has ? at["question"] : "")
    auto := g.Add("Checkbox", "xm y+14", "Start it by itself when the task above is ticked done")
    rFixed.Value := !(has && at["ask"])
    rAsk.Value := has && at["ask"]
    auto.Value := has ? (at["start"] = "afterPrevious") : 1
    save := g.Add("Button", "xm y+18 w90 Default", "Save")
    remove := g.Add("Button", "x+8 w150", "Remove planned timer")
    cancel := g.Add("Button", "x+8 w90", "Cancel")
    remove.Enabled := has
    save.OnEvent("Click", DoSave)
    remove.OnEvent("Click", DoRemove)
    cancel.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show()

    DoSave(*) {
        g.Opt("+OwnDialogs")
        secs := 0
        if rFixed.Value {
            secs := TaskParseDuration(dur.Value, false)
            if (secs <= 0) {
                MsgBox("Type how long, like 5 (minutes), 30s or 1h 30.", "Planned timer", "Icon!")
                return
            }
        }
        start := auto.Value ? "afterPrevious" : "manual"
        if (has && at["start"] = "now" && !auto.Value)
            start := "now"                        ; keep a template's "starts when added"
        n["autoTimer"] := TaskNewMap("seconds", Max(0, secs), "ask", rAsk.Value ? 1 : 0
            , "question", Trim(q.Value), "start", start)
        g.Destroy()
        TaskSaveSoon()
        TaskRelabel(n)
        TaskStatus("Planned timer saved for '" TaskTitle(n) "'")
    }

    DoRemove(*) {
        n["autoTimer"] := Json.Null
        g.Destroy()
        TaskSaveSoon()
        TaskRelabel(n)
        TaskStatus("Planned timer removed")
    }
}

TaskSnooze(n, seconds) {
    TaskStartTimer(n, seconds, "snoozed " TaskDurLabel(seconds))
    TaskStatus("Snoozed '" TaskTitle(n) "' for " TaskDurLabel(seconds))
}

; "Hide" on an alert: the popup goes, the timer stays as overdue (top of Up
; next, red in the list) and the alert comes back every RemindHiddenMin
TaskHideAlert(n) {
    if !IsObject(n)
        return
    tm := n["timer"]
    if !(tm is Map) {
        TAlertClose(n["id"])
        return
    }
    tm["state"] := "hidden"
    tm["hiddenAtUtc"] := TaskNowIso()
    every := TaskSettingInt("RemindHiddenMin", 0, 1440)
    TaskHistory(n, "hide", "alert hidden" (every ? " (reminds again in " every "m)" : ""))
    TAlertClose(n["id"])
    TaskSaveSoon()
    TaskRelabel(n)
    TaskRefreshUpNext()
    TaskStatus("Hidden: '" TaskTitle(n) "' stays overdue in Up next"
        . (every ? " and comes back in " every " min" : ""))
}

; Adds a line to a task's timer history (kept to TASK_HISTORY_MAX)
TaskHistory(n, kind, what) {
    h := n["history"]
    if !(h is Array) {
        h := []
        n["history"] := h
    }
    h.Push(TaskNewMap("at", TaskNowIso(), "kind", kind, "what", what))
    while (h.Length > TASK_HISTORY_MAX)
        h.RemoveAt(1)
    TaskSaveSoon()
}

TaskIsoLocal(iso, fmt) {
    st := TaskIsoStamp(iso)
    if (st = "")
        return ""
    return FormatTime(DateAdd(st, DateDiff(A_Now, A_NowUTC, "Seconds"), "Seconds"), fmt)
}

; "45s" / "12m" since a timer was due
TaskOverdueText(tm) {
    s := Max(0, -TaskSecsUntil(tm["dueAtUtc"]))
    return (s < 60) ? s "s" : TaskDurLabel(s // 60 * 60)
}

; A task's timer history in its own window (read-only; Copy for the case notes)
TaskHistoryWindow(n) {
    if !IsObject(n)
        return
    g := Gui("+Owner" tkGui.Hwnd " +Resize -MinimizeBox", "Timer history - " TaskTitle(n))
    g.SetFont("s10", "Segoe UI")
    g.Add("Text", "xm w520", TaskPath(n) ((TaskLinkLabel(n) != "") ? "   ·   " TaskLinkLabel(n) : ""))
    lv := g.Add("ListView", "xm y+6 w520 h300 -Multi NoSortHdr ReadOnly", ["When", "What happened"])
    text := TaskPath(n) "`n"
    for e in n["history"] {
        when := TaskIsoLocal(e.Get("at", ""), "MMM d  h:mm:ss tt")
        lv.Add(, when, e.Get("what", ""))
        text .= when "   " e.Get("what", "") "`n"
    }
    if !n["history"].Length
        lv.Add(, "", "No timers yet")
    lv.ModifyCol(1, 170)
    lv.ModifyCol(2, 330)
    copy := g.Add("Button", "xm y+8 w140", "Copy as text")
    close := g.Add("Button", "x+8 w90 Default", "Close")
    TipSet(copy, "Copy this timer history to the clipboard")
    copy.OnEvent("Click", (*) => (A_Clipboard := text, TaskStatus("Timer history copied")))
    close.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.OnEvent("Size", (gg, mm, w, h) => (mm = -1 ? 0 : (lv.Move(, , w - 2 * gg.MarginX, h - 110), copy.Move(, h - 38), close.Move(, h - 38))))
    g.Show()
    lv.Modify(lv.GetCount(), "Vis")
}

; "After my call": comes back once you're no longer busy, or after a while if
; you weren't busy when you pressed it
TaskSnoozeAfterCall(n) {
    if !IsObject(n)
        return
    tm := n["timer"]
    if !(tm is Map) {
        tm := TaskNewMap("dueAtUtc", TaskNowIso(), "seconds", 0)
        n["timer"] := tm
    }
    busy := TaskIsBusy()
    tm["state"] := "afterCall"
    tm["afterSinceUtc"] := TaskNowIso()
    tm["sawBusy"] := busy ? 1 : 0
    TaskHistory(n, "after", "After my call")
    TAlertClose(n["id"])
    TaskSaveSoon()
    TaskRelabel(n)
    TaskRefreshUpNext()
    TaskStatus(busy
        ? "'" TaskTitle(n) "' comes back when your call ends"
        : "Not on a call: '" TaskTitle(n) "' comes back in " TaskSettingInt("AfterCallFallbackMin", 0, 600) " min, or after your next call")
}

TaskIsBusy() {
    for app, b in busyApps
        if b
            return true
    return false
}

TaskAfterCallReady(tm) {
    if TaskIsBusy()
        return false
    since := tm.Get("afterSinceUtc", "")
    delay := TaskSettingInt("AfterCallDelaySec", 0, 3600)
    if tm.Get("sawBusy", 0)                   ; you were busy: wait until that ended
        return lastBusyEndUtc != "" && TaskIsoStamp(lastBusyEndUtc) >= TaskIsoStamp(since)
            && -TaskSecsUntil(lastBusyEndUtc) >= delay
    return -TaskSecsUntil(since) >= TaskSettingInt("AfterCallFallbackMin", 0, 600) * 60
}

; "Hold alerts while busy" on: true while busy and shortly after
TaskHoldAlerts() {
    if (TaskSetting("DuringCall") != "wait")
        return false
    if TaskIsBusy()
        return true
    return lastBusyEndUtc != "" && -TaskSecsUntil(lastBusyEndUtc) < TaskSettingInt("AfterCallDelaySec", 0, 3600)
}

TaskSetBusy(app, busy) {
    global lastBusyEndUtc
    was := TaskIsBusy()
    busyApps[app] := busy ? true : false
    if (was && !TaskIsBusy())
        lastBusyEndUtc := TaskNowIso()
}

; Every second: timers, alerts, labels, up next, are the apps still there?
TaskTick() {
    global taskTickCount
    taskTickCount += 1
    for app, hwnd in ctxApps.Clone() {
        if !WinExist("ahk_id " hwnd) {            ; that app closed
            ctxApps.Delete(app)
            TaskSetBusy(app, false)
            TaskRefreshHeader()
        }
    }
    changed := false
    hold := TaskHoldAlerts()
    busy := TaskIsBusy()
    for id, n in taskById {
        tm := n["timer"]
        if !(tm is Map)
            continue
        st := tm.Get("state", "running")
        if (st = "running" && TaskSecsUntil(tm["dueAtUtc"]) <= 0) {
            tm["state"] := st := "due"
            TaskHistory(n, "rang", "time's up")
            changed := true
        } else if (st = "afterCall") {
            if (busy && !tm.Get("sawBusy", 0)) {
                tm["sawBusy"] := 1
                changed := true
            }
            if TaskAfterCallReady(tm) {
                tm["state"] := st := "due"
                TaskHistory(n, "rang", "back after your call")
                changed := true
            }
        } else if (st = "hidden") {
            every := TaskSettingInt("RemindHiddenMin", 0, 1440)
            if (every > 0 && tm.Get("hiddenAtUtc", "") != ""
                && -TaskSecsUntil(tm["hiddenAtUtc"]) >= every * 60) {
                tm["state"] := st := "due"
                TaskHistory(n, "remind", "reminded again (overdue " TaskOverdueText(tm) ")")
                changed := true
            }
        }
        if (st = "due" && !hold)
            TAlertShow(n)
        TaskRelabel(n)
    }
    if changed {
        TaskSaveSoon()
        TaskShowSelected()
    }
    TAlertSoundTick()
    TaskRefreshUpNext()
    TaskSendItemStatus()
    if (Mod(taskTickCount, 60) = 0)
        TaskCheckVersion()
}

; An update replaced the app folder: restart on the new code (timers are saved)
TaskCheckVersion() {
    v := PkgReadVersion(A_ScriptDir)
    if (v = taskLoadedVersion || TaskEditing())
        return
    TaskLog("app updated (" taskLoadedVersion " -> " v "), restarting")
    TaskSaveNow()
    try {
        Run(Format('"{}" "{}" /restart', A_AhkPath, A_ScriptFullPath), A_ScriptDir)
        ExitApp()
    }
}

; ==============================================================================
; Templates
;   {"templates": [{"id", "name", "steps": [step, ...]}]}
;   step: {"title", "notes", "children": [step, ...],
;          "timer": {"duration": "5m"  or  "ask": true, "question": "...",
;                    "start": "afterPrevious" | "manual" | "now"},
;          "askWhenDone": {"question": "...", "label": "Case link", "required": true}}
; ==============================================================================
TaskLoadTemplates() {
    global taskTemplates
    taskTemplates := []
    if (!FileExist(TASK_TPL_PATH) && FileExist(TASK_TPL_DEFAULT))
        try FileCopy(TASK_TPL_DEFAULT, TASK_TPL_PATH)
    if !FileExist(TASK_TPL_PATH)
        return
    try {
        d := Json.Parse(FileRead(TASK_TPL_PATH, "UTF-8"))
        TaskAddNewDefaultTemplates(d)
        for t in d["templates"]
            if ((t is Map) && Trim(t.Get("name", "")) != "" && (t.Get("steps", "") is Array))
                taskTemplates.Push(t)
    } catch as err {
        TaskLog("templates file problem: " err.Message)
        SetTimer(() => TaskStatus("The templates file has a problem: " err.Message "  (Templates ▼ > Edit templates file)"), -500)
    }
}

; Templates that came with an update are added to your file once (by id).
; One you deleted isn't brought back: the ids already offered are in tasks.ini.
TaskAddNewDefaultTemplates(d) {
    if !FileExist(TASK_TPL_DEFAULT)
        return
    try {
        def := Json.Parse(FileRead(TASK_TPL_DEFAULT, "UTF-8"))
        seen := Map()
        seen.CaseSense := false
        for id in StrSplit(TaskIniRead("Templates", "Offered", ""), ",")
            if (Trim(id) != "")
                seen[Trim(id)] := true
        mine := Map()
        mine.CaseSense := false
        for t in d["templates"]
            if (t is Map)
                mine[String(t.Get("id", ""))] := true
        added := 0
        for t in def["templates"] {
            id := (t is Map) ? String(t.Get("id", "")) : ""
            if (id = "" || seen.Has(id))
                continue
            if !mine.Has(id) {
                d["templates"].Push(t)
                added += 1
            }
            seen[id] := true
        }
        ids := ""
        for id in seen
            ids .= (ids = "" ? "" : ",") id
        IniWrite(ids, TASK_INI, "Templates", "Offered")
        if added {
            TaskWriteTemplates(d)
            TaskLog("added " added " new template(s) from the update")
        }
    } catch as err {
        TaskLog("could not check for new templates: " err.Message)
    }
}

TaskWriteTemplates(d) {
    tmp := DATA_DIR "\.task-templates." A_TickCount ".tmp"
    f := FileOpen(tmp, "w", "UTF-8")
    f.Write(Json.Stringify(d))
    f.Close()
    FileMove(tmp, TASK_TPL_PATH, true)
}

TaskReloadTemplates() {
    TaskLoadTemplates()
    TaskStatus("Templates loaded: " taskTemplates.Length)
}

TaskEditTemplates() {
    if (!FileExist(TASK_TPL_PATH) && FileExist(TASK_TPL_DEFAULT))
        try FileCopy(TASK_TPL_DEFAULT, TASK_TPL_PATH)
    try {
        Run('notepad.exe "' TASK_TPL_PATH '"')
        TaskStatus("Templates opened in Notepad. Save there, then Templates ▼ > Reload templates.")
    } catch as err {
        TaskStatus("Could not open the templates file: " err.Message)
    }
}

TaskShowTemplateMenu(*) {
    m := Menu()
    for t in taskTemplates
        m.Add(t["name"], TaskApplyTemplate.Bind(t))
    if !taskTemplates.Length {
        m.Add("(no templates)", (*) => 0)
        m.Disable("(no templates)")
    }
    m.Add()
    m.Add("Save the selected task as a template…", (*) => TaskSaveAsTemplate(TaskSelectedNode()))
    m.Add("Edit templates file", (*) => TaskEditTemplates())
    m.Add("Reload templates", (*) => TaskReloadTemplates())
    m.Show()
}

TaskApplyTemplate(t, *) {
    root := TaskFromTemplate(t)
    TaskAddRoot(root)
    TaskStructureChanged(root["id"])
    TaskEachIn(root, TaskStartIfNow)          ; planned timers marked "now" start straight away
    l := root["link"]
    TaskStatus("Added '" t["name"] "'" ((l is Map) ? " for " l["label"] : ""))
}

; A new top-level task (not added yet) with the template's steps under it
TaskFromTemplate(t) {
    root := TaskNewNode(t["name"])
    for step in t["steps"]
        root["children"].Push(TaskNodeFromStep(step))
    return root
}

TaskTemplateById(id) {
    for t in taskTemplates
        if (String(t.Get("id", "")) = id)
            return t
    return ""
}

; ==============================================================================
; New / dropped items from an app (the Companion: a new call / a call it threw
; away) and progress sent back to it
; ==============================================================================
; newitem  appHwnd  appName  itemId  itemLabel
; Adds the "new item" template's checklist, linked to it (once per item), and
; shows Tasks if that's switched on. Both are in settings.
TaskOnNewItem(p) {
    while (p.Length < 5)
        p.Push("")
    app := (Trim(p[3]) = "") ? "App" : Trim(p[3])
    if IsInteger(p[2])
        ctxApps[app] := Integer(p[2])
    id := p[4]
    if (id = "")
        return
    tplId := Trim(TaskSetting("NewItemTemplate"))
    if (tplId != "" && !TaskHasLinked(app, id)) {
        t := TaskTemplateById(tplId)
        if IsObject(t) {
            root := TaskFromTemplate(t)
            root["link"] := TaskNewLink(app, id, p[5])
            root["auto"] := 1                     ; may be removed if the item is thrown away untouched
            taskDoc["tasks"].Push(root)
            TaskStructureChanged()
            TaskEachIn(root, TaskStartIfNow)
            TaskStatus("Added '" t["name"] "' for " p[5])
        } else {
            TaskLog("new item: no template with id '" tplId "' (settings > new calls)")
        }
    }
    if (TaskSetting("NewItemShow") = "1")
        TaskShowWindow(TASK_VIEW_LINKED, false)
}

TaskHasLinked(app, id) {
    for r in taskDoc["tasks"] {
        l := r["link"]
        if ((l is Map) && l["id"] = id && l["app"] = app)
            return true
    }
    return false
}

; dropitem  appHwnd  appName  itemId
; The app threw that item away (e.g. an empty call): its automatic checklist
; goes too, but only if nothing was done with it
TaskOnDropItem(p) {
    while (p.Length < 4)
        p.Push("")
    app := (Trim(p[3]) = "") ? "App" : Trim(p[3])
    list := taskDoc["tasks"]
    removed := 0
    i := list.Length
    while (i >= 1) {
        r := list[i]
        l := r["link"]
        if ((l is Map) && l["id"] = p[4] && l["app"] = app && r.Get("auto", 0) && TaskUntouched(r)) {
            TaskEachIn(r, (x) => TAlertClose(x["id"]))
            list.RemoveAt(i)
            removed += 1
        }
        i -= 1
    }
    if removed {
        TaskStructureChanged()
        TaskLog("removed " removed " untouched automatic checklist(s) of a dropped item")
    }
}

; Nothing ticked, no timer ever started
TaskUntouched(n) {
    if (n["done"] || (n["timer"] is Map) || n["history"].Length)
        return false
    for c in n["children"]
        if !TaskUntouched(c)
            return false
    return true
}

; Tells the app how many of the tasks linked to its open item are still open,
; whenever that changes (the Companion colours its Tasks button with it).
; Counts the tasks at the end of each branch; a ticked parent counts as all done.
;   itemstatus  itemId  open  total
TaskSendItemStatus() {
    global taskLastStatus
    hwnd := ctxApps.Get(ctxApp, 0)
    if (ctxId = "" || !hwnd)
        return
    open := 0
    total := 0
    for r in taskDoc["tasks"]
        if TaskLinkIsCurrent(r["link"])
            TaskCountOpen(r, false, &open, &total)
    msg := "itemstatus`t" ctxId "`t" open "`t" total
    if ((msg . hwnd) = taskLastStatus)
        return
    if TaskSendTo(hwnd, msg)
        taskLastStatus := msg hwnd
}

TaskCountOpen(n, parentDone, &open, &total) {
    d := parentDone || n["done"]
    if !n["children"].Length {
        total += 1
        if !d
            open += 1
        return
    }
    for c in n["children"]
        TaskCountOpen(c, d, &open, &total)
}

TaskStartIfNow(n) {
    at := n["autoTimer"]
    if ((at is Map) && at["start"] = "now")
        TaskStartPlanned(n)
}

TaskNodeFromStep(step) {
    n := TaskNewNode()
    if !(step is Map)
        return n
    n["title"] := String(step.Get("title", ""))
    n["notes"] := String(step.Get("notes", ""))
    n["autoTimer"] := TaskNormAuto(step.Get("timer", ""))
    n["askOnDone"] := TaskNormAsk(step.Get("askWhenDone", ""))
    kids := step.Get("children", "")
    if (kids is Array)
        for k in kids
            n["children"].Push(TaskNodeFromStep(k))
    return n
}

TaskStepFromNode(n) {
    s := TaskNewMap("title", n["title"])
    if (Trim(n["notes"]) != "")
        s["notes"] := n["notes"]
    at := n["autoTimer"]
    if (at is Map) {
        tm := TaskNewMap("start", at["start"])
        if at["ask"] {
            tm["ask"] := 1
            if (at["question"] != "")
                tm["question"] := at["question"]
        } else {
            tm["duration"] := TaskDurLabel(at["seconds"])
        }
        s["timer"] := tm
    }
    a := n["askOnDone"]
    if (a is Map)
        s["askWhenDone"] := TaskNewMap("question", a["question"], "label", a["label"], "required", a["required"])
    if n["children"].Length {
        kids := []
        for c in n["children"]
            kids.Push(TaskStepFromNode(c))
        s["children"] := kids
    }
    return s
}

; Saves a task and everything under it as a template (names, notes, planned timers)
TaskSaveAsTemplate(n) {
    if !IsObject(n) {
        TaskStatus("Pick a task first, then save it as a template.")
        return
    }
    tkGui.Opt("+OwnDialogs")
    r := InputBox("Name for the template:", "Save as a template", "w380 h130", TaskTitle(n))
    name := Trim(r.Value)
    if (r.Result != "OK" || name = "")
        return
    try {
        d := FileExist(TASK_TPL_PATH) ? Json.Parse(FileRead(TASK_TPL_PATH, "UTF-8")) : TaskNewMap("templates", [])
        if !(d.Get("templates", "") is Array)
            d["templates"] := []
        list := d["templates"]
        steps := []
        for c in n["children"]
            steps.Push(TaskStepFromNode(c))
        tpl := TaskNewMap("id", "tpl-" TaskNewId(), "name", name, "steps", steps)
        for i, t in list {
            if ((t is Map) && t.Get("name", "") = name) {
                if (MsgBox("A template called '" name "' already exists. Replace it?", "Save as a template", "YesNo Icon?") != "Yes")
                    return
                list[i] := tpl
                tpl := ""
                break
            }
        }
        if IsObject(tpl)
            list.Push(tpl)
        TaskWriteTemplates(d)
        TaskLoadTemplates()
        TaskStatus("Saved template '" name "'")
    } catch as err {
        TaskStatus("Could not save the template: " err.Message)
    }
}

; ==============================================================================
; Messages (see the top of this file)
; ==============================================================================
TaskOnCopyData(wParam, lParam, msg, hwnd) {
    if (hwnd != tkGui.Hwnd)
        return
    try {
        if (NumGet(lParam, 0, "UPtr") != TASK_TAG)
            return
        text := StrGet(NumGet(lParam, A_PtrSize * 2, "Ptr"), "UTF-16")
    } catch {
        return
    }
    SetTimer(TaskHandleMessage.Bind(text), -1)   ; answer the sender right away
    return true
}

TaskHandleMessage(text, *) {
    p := StrSplit(text, "`t")
    switch p[1] {
        case "ctx":          TaskSetContext(p)
        case "show":         TaskShowWindow()
        case "showlinked":   TaskShowWindow(TASK_VIEW_LINKED)
        case "togglelinked": TaskToggleLinked()
        case "hide":         TaskHide()
        case "settings":     TaskOpenSettings()
        case "newitem":      TaskOnNewItem(p)
        case "dropitem":     TaskOnDropItem(p)
        case "quit":         ExitApp()
    }
}

; An app's button: hide if open on its item, otherwise open on it
TaskToggleLinked() {
    if (TaskWindowShown() && taskView = TASK_VIEW_LINKED)
        TaskHide()
    else
        TaskShowWindow(TASK_VIEW_LINKED)
}

; ctx  appHwnd  appName  itemId  itemLabel  note  busy
TaskSetContext(p) {
    global ctxApp, ctxId, ctxLabel, ctxNote, pendingShowLinked, taskPendingFocus
    while (p.Length < 7)
        p.Push("")
    app := Trim(p[3]) = "" ? "App" : Trim(p[3])
    if IsInteger(p[2])
        ctxApps[app] := Integer(p[2])
    TaskSetBusy(app, p[7] = "1")
    newId := p[4]
    changed := (newId != ctxId || app != ctxApp)
    ctxApp := app
    ctxId := newId
    ctxLabel := p[5]
    ctxNote := p[6]
    ; the label often gets better later (e.g. the caller's name): keep links fresh
    relabel := false
    if (newId != "" && ctxLabel != "")
        for n in taskDoc["tasks"]
            if (TaskLinkIsCurrent(n["link"]) && n["link"]["label"] != ctxLabel) {
                n["link"]["label"] := ctxLabel
                relabel := true
            }
    if relabel
        TaskSaveSoon()
    if (taskPendingFocus != "") {             ; Open was clicked: the app now has its item open?
        pf := taskById.Get(taskPendingFocus, "")
        if (IsObject(pf) && TaskLinkIsCurrent(TaskLinkOf(pf))) {
            taskPendingFocus := ""
            TaskOpenTask(pf["id"], TASK_VIEW_LINKED)
            return
        }
    }
    if (pendingShowLinked && ctxId != "") {
        pendingShowLinked := false
        TaskSetView(TASK_VIEW_LINKED)
        return
    }
    if ((changed && taskView = TASK_VIEW_LINKED) || relabel)
        TaskRebuildTree()
    else
        TaskRefreshHeader()
}

TaskSendTo(hwnd, msg) {
    buf := Buffer(StrPut(msg, "UTF-16"))
    StrPut(msg, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("Ptr", TASK_TAG, cds, 0)
    NumPut("UInt", buf.Size, cds, A_PtrSize)
    NumPut("Ptr", buf.Ptr, cds, A_PtrSize * 2)
    try {
        SendMessage(0x4A, 0, cds, , "ahk_id " hwnd, , , , 2000)
        return true
    }
    return false
}

; ==============================================================================
; Settings (data\tasks.ini [Settings]; defaults in TASK_SETTING_DEFAULTS)
; ==============================================================================
TaskSetting(key) {
    def := TASK_SETTING_DEFAULTS.Has(key) ? TASK_SETTING_DEFAULTS[key] : ""
    try return IniRead(TASK_INI, "Settings", key, def)
    return def
}

TaskSettingInt(key, lo, hi) {
    v := TaskSetting(key)
    if !IsInteger(v)
        v := TASK_SETTING_DEFAULTS[key]
    return Min(hi, Max(lo, Integer(v)))
}

TaskIniRead(section, key, def := "") {
    try return IniRead(TASK_INI, section, key, def)
    return def
}

TaskIniInt(section, key, def, lo, hi) {
    v := TaskIniRead(section, key, def)
    return IsInteger(v) ? Min(hi, Max(lo, Integer(v))) : def
}

TaskOpenSettings() {
    static sg := ""
    if IsObject(sg) {
        try sg.Destroy()
        sg := ""
    }
    LW := "w340"                                   ; label column
    sg := Gui("-MinimizeBox +AlwaysOnTop", "Tasks - settings")
    g := sg
    g.SetFont("s10", "Segoe UI")
    g.SetFont("s10 bold")
    g.Add("Text", "xm ym", "Alerts")
    g.SetFont("s10 norm")
    g.Add("Text", "xm y+10 " LW, "Where alerts appear")
    pos := g.Add("DropDownList", "x+10 yp-4 w220", TALERT_POSITIONS)
    TaskDdlSelect(pos, TALERT_POSITIONS, TaskSetting("Position"))
    g.Add("Text", "xm y+12 " LW, "Alert width (pixels)")
    tw := g.Add("Edit", "x+10 yp-4 w80 Number", TaskSettingInt("ToastWidth", 300, 800))
    snd := g.Add("Checkbox", "xm y+12 " LW, "Play a sound with alerts")
    snd.Value := (TaskSetting("Sound") = "1")
    g.Add("Text", "xm y+12 " LW, "Sound file (.wav; empty = Windows sound)")
    file := g.Add("Edit", "x+10 yp-4 w220", TaskSetting("SoundFile"))
    browse := g.Add("Button", "xm+350 y+4 w106", "Browse…")
    testSnd := g.Add("Button", "x+8 w106", "Test sound")
    g.Add("Text", "xm y+12 " LW, "Repeat the sound every (seconds, 0 = once)")
    rep := g.Add("Edit", "x+10 yp-4 w80 Number", TaskSettingInt("RepeatSoundSec", 0, 3600))
    g.Add("Text", "xm y+12 " LW, "Snooze buttons (like 30s, 2, 5m - plain numbers are minutes)")
    snz := g.Add("Edit", "x+10 yp-4 w220", TaskSetting("SnoozeMinutes"))
    g.Add("Text", "xm y+12 " LW, "When a timer runs out while you're on a call")
    dur := g.Add("DropDownList", "x+10 yp-4 w220", ["Hold it until the call ends", "Show the alert right away"])
    dur.Value := (TaskSetting("DuringCall") = "show") ? 2 : 1
    g.Add("Text", "xm y+12 " LW, "Held / 'After my call' alerts come back (seconds after the call)")
    acd := g.Add("Edit", "x+10 yp-4 w80 Number", TaskSettingInt("AfterCallDelaySec", 0, 3600))
    g.Add("Text", "xm y+12 " LW, "'After my call' when not on a call: back in (minutes)")
    acf := g.Add("Edit", "x+10 yp-4 w80 Number", TaskSettingInt("AfterCallFallbackMin", 0, 600))
    g.Add("Text", "xm y+12 " LW, "Hidden alerts come back every (minutes, 0 = never)")
    rhm := g.Add("Edit", "x+10 yp-4 w80 Number", TaskSettingInt("RemindHiddenMin", 0, 1440))

    g.SetFont("s10 bold")
    g.Add("Text", "xm y+18", "New calls (when the Companion starts one)")
    g.SetFont("s10 norm")
    g.Add("Text", "xm y+10 " LW, "Add this checklist to the new call")
    tplNames := ["(none)"]
    tplIds := [""]
    for t in taskTemplates {
        tplNames.Push(t["name"])
        tplIds.Push(String(t.Get("id", "")))
    }
    nit := g.Add("DropDownList", "x+10 yp-4 w220", tplNames)
    nit.Value := 1
    for i, tid in tplIds
        if (i > 1 && tid != "" && tid = TaskSetting("NewItemTemplate"))
            nit.Value := i
    nis := g.Add("Checkbox", "xm y+12", "Also show the Tasks window (without taking the focus)")
    nis.Value := (TaskSetting("NewItemShow") = "1")

    g.SetFont("s10 bold")
    g.Add("Text", "xm y+18", "Tasks window")
    g.SetFont("s10 norm")
    g.Add("Text", "xm y+10 " LW, "Timer buttons (like 30s, 2, 5, 15)")
    qt := g.Add("Edit", "x+10 yp-4 w220", TaskSetting("QuickTimers"))
    g.Add("Text", "xm y+12 " LW, "Hotkey to open / close Tasks")
    hk := g.Add("Hotkey", "x+10 yp-4 w220", TaskSetting("Hotkey"))

    g.SetFont("s10 bold")
    g.Add("Text", "xm y+18", "Read aloud")
    g.SetFont("s10 norm")
    voices := ["Windows default"]
    for v in TaskVoiceNames()
        voices.Push(v)
    g.Add("Text", "xm y+10 " LW, "Voice")
    voice := g.Add("DropDownList", "x+10 yp-4 w220", voices)
    TaskDdlSelect(voice, voices, TaskSetting("ReadVoice") = "" ? "Windows default" : TaskSetting("ReadVoice"))
    g.Add("Text", "xm y+12 " LW, "Speed (-10 slow ... 10 fast)")
    rate := g.Add("Edit", "x+10 yp-4 w80", TaskSettingInt("ReadRate", -10, 10))
    testVoice := g.Add("Button", "x+8 w132", "Test voice")

    save := g.Add("Button", "xm y+22 w100 Default", "Save")
    testAlert := g.Add("Button", "x+8 w160", "Save && test alert")
    cancel := g.Add("Button", "x+8 w100", "Cancel")

    TipSetAll([[browse, "Pick a .wav sound file"], [testSnd, "Play the alert sound now"]
        , [testVoice, "Hear how tasks are read aloud with this voice and speed"]
        , [save, "Save and close"], [testAlert, "Save, then show a sample alert"]])
    browse.OnEvent("Click", PickSound)
    testSnd.OnEvent("Click", (*) => TAlertPlaySound(Trim(file.Value) = "" ? "*48" : Trim(file.Value)))
    testVoice.OnEvent("Click", (*) => TaskSpeak("Hello, this is how tasks are read aloud.", voice.Value = 1 ? "" : voice.Text, rate.Value))
    save.OnEvent("Click", (*) => DoSave(true))
    testAlert.OnEvent("Click", (*) => DoSave(false) && TAlertTest())
    cancel.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show()

    PickSound(*) {
        g.Opt("+OwnDialogs")
        f := FileSelect(1, file.Value, "Pick a sound", "Sounds (*.wav)")
        if (f != "")
            file.Value := f
    }

    ; close: also close the window. Returns true when saved.
    DoSave(close) {
        g.Opt("+OwnDialogs")
        if !TaskDurationList(snz.Value, 6).Length {
            MsgBox("Snooze buttons: type at least one length, like 30s, 2, 5m.", "Settings", "Icon!")
            return false
        }
        if !TaskDurationList(qt.Value, TASK_MAX_QUICK).Length {
            MsgBox("Timer buttons: type at least one length, like 30s, 2, 5.", "Settings", "Icon!")
            return false
        }
        r := Trim(rate.Value)
        vals := Map("Position", pos.Text, "Sound", snd.Value ? 1 : 0, "SoundFile", Trim(file.Value)
            , "RepeatSoundSec", rep.Value = "" ? 0 : rep.Value
            , "SnoozeMinutes", snz.Value
            , "DuringCall", dur.Value = 2 ? "show" : "wait"
            , "AfterCallDelaySec", acd.Value = "" ? 0 : acd.Value
            , "AfterCallFallbackMin", acf.Value = "" ? 0 : acf.Value
            , "RemindHiddenMin", rhm.Value = "" ? 0 : rhm.Value
            , "QuickTimers", qt.Value
            , "Hotkey", hk.Value
            , "ToastWidth", tw.Value = "" ? TASK_SETTING_DEFAULTS["ToastWidth"] : tw.Value
            , "ReadVoice", voice.Value = 1 ? "" : voice.Text
            , "ReadRate", IsInteger(r) ? Min(10, Max(-10, Integer(r))) : 0
            , "NewItemTemplate", tplIds[nit.Value]
            , "NewItemShow", nis.Value ? 1 : 0)
        try {
            for k, v in vals
                IniWrite(v, TASK_INI, "Settings", k)
        } catch as err {
            MsgBox("Could not save the settings: " err.Message, "Settings", "Icon!")
            return false
        }
        if close
            g.Destroy()
        TaskApplyHotkey()
        TaskSetupTimerButtons()
        TAlertRefreshAll()
        TaskStatus("Settings saved")
        return true
    }
}

TaskDdlSelect(ddl, items, text) {
    for i, t in items
        if (t = text) {
            ddl.Value := i
            return
        }
    ddl.Value := 1
}

; ==============================================================================
; Log, errors, exit
; ==============================================================================
TaskLog(line) {
    try {
        if (FileExist(TASK_LOG) && FileGetSize(TASK_LOG) > 500000)
            FileMove(TASK_LOG, TASK_LOG ".old", true)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " line "`n", TASK_LOG, "UTF-8")
    }
}

; Anything no try/catch handled: log it, keep running (no AutoHotkey error box)
TaskOnError(err, mode) {
    TaskLog("error: " err.Message " (" err.What ", line " err.Line ")")
    TaskStatus("Something went wrong (written to data\tasks.log): " err.Message)
    return true
}

TaskOnExit(*) {
    try {
        OnMessage(0x0201, TaskSplitterDown, 0)
        OnMessage(0x0020, TaskSplitterCursor, 0)
    }
    try TaskSaveWindowPos()
    try TaskSaveNow()
    try TAlertCloseAll()
    try TaskSpeak("")
}
