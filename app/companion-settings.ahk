; ==============================================================================
; companion-settings.ahk  -  the Companion's Settings window (prefix CSet*)
;
; * Opened by the ⚙ button (top left, next to 📍) and tray > "Settings...". Sections on the
;   left, that section's settings on the right, Save / Close / Defaults at the bottom.
; * The tray menu keeps ALL its items too (owner's choice 2026-11-22: people used to the tray
;   keep it). Both places use the same functions (CallerToggle, QASaveValue, PoolLinkToggle...),
;   so they never disagree: the tray's ticks follow a Save here, and this window reads the
;   current state every time it opens.
; * Ticks, numbers, lists and texts apply on Save - only the ones you changed here, so a tray
;   change made while this window was open is kept. Buttons act right away.
; * Built from one list (CSetFields): a new setting = one entry. Types:
;     head    {label}                          a heading
;     note    {label}                          grey text
;     check   {key, label, get, flip, def}     get() -> true/false; flip() switches it (the tray's own toggle)
;     num     {key, label, hint, min, max, get, set, def}
;     choice  {key, label, hint, choices, get, set, def}     get/set use the shown text
;     text    {key, label, hint, rows, need, get, set, def}  multi-line; need = text it must contain
;     buttons {items: [[label, fn], ...]}      a row of buttons (act right away)
;     live    {get}                            a line of text, get() asked again every second (a status)
;     app     {key, label, get, flip, def, items}   an On tick + that app's buttons on one row
;   Every field has sec (its section number, see CSET_SECTIONS); tip = its hover tip (buttons: [label, fn, tip]).
; * The other apps (Tasks, Screen ask, Same value, Agent, the pool) keep their own settings
;   windows: Apps only switches them on/off and opens them.
; * Every entry point is wrapped in try/catch: captions and the call are never affected.
; Hooks: CSetInit() (after TutInit: its tray item goes on top), CSetShow()
; ==============================================================================

CSET_SECTIONS := ["Calls && 3CX", "Q status", "Headset check", "Copilot", "Apps", "Captions && mic", "Updates && help", "Troubleshooting"]
CSET_TRAY := "Settings..."
CSET_TIPS_TRAY := "Show tips on buttons (all apps)"
CSET_PAGE_X := 206                 ; the scrolling page (a child window) right of the section list
CSET_PAGE_W := 674                 ; its width (room for the scroll bar)
CSET_PAGE_H := 540                 ; its height (down to the line above Save / Close)
CSET_PX := 8                       ; where the rows start, inside the page
CSET_PW := 640                     ; row width
cSetGui := 0
cSetPage := 0                      ; the scrolling page inside cSetGui
cSetSecH := Map()                  ; section -> its content height (DPI-scaled units)
cSetScroll := 0                    ; how far the page is scrolled down (pixels)
cSetContentPx := 0                 ; this section's content height (pixels)
cSetPagePx := 0                    ; the page's visible height (pixels)
cSetFieldList := []
cSetSec := 1

CSetInit() {
    try {
        A_TrayMenu.Insert("1&")
        A_TrayMenu.Insert("1&", CSET_TIPS_TRAY, (*) => CSetTipsToggle())
        A_TrayMenu.Insert("1&", CSET_TRAY, (*) => CSetShow())
        CSetTipsSyncTray()
        OnMessage(0x0115, CSetOnVScroll)         ; WM_VSCROLL: the page's scroll bar
        OnMessage(0x020A, CSetOnWheel)           ; WM_MOUSEWHEEL over the page
    } catch as err {
        CSetReport(err)
    }
}

; Tips on / off for every app (data\tips.ini), from the tray or Settings > Updates & help
CSetTipsToggle() {
    TipsSetEnabled(!TipsEnabled())
    CSetTipsSyncTray()
    statusText.Text := "Status: tips on buttons are now " (TipsEnabled() ? "on" : "off") " (in every app)"
}

CSetTipsSyncTray() {
    try {
        if TipsEnabled()
            A_TrayMenu.Check(CSET_TIPS_TRAY)
        else
            A_TrayMenu.Uncheck(CSET_TIPS_TRAY)
    }
}

; ------------------------------------------------------------------ the list
; tip: shown when the mouse rests on the setting. Buttons: [label, fn, tip].
CSetFields() {
    f := []
    ; ---- 1  Calls & 3CX
    f.Push({sec: 1, type: "head", label: "3CX caller"})
    f.Push(CSetCallerFlag("Enabled", "Detect calls from 3CX"
        , "Watch 3CX for ringing and answered calls and show who is calling. The app only reads 3CX, it never clicks or types in it."))
    f.Push(CSetCallerFlag("AutoNewCall", "Start a new call record when a call rings"
        , "When a call rings, the call on screen is saved to Call history and a fresh one starts by itself"))
    f.Push(CSetCallerFlag("Popup", "Show the caller card near 3CX"
        , "A small card next to the 3CX window with the caller and Salesforce search buttons (not shown when the automatic Salesforce search is on)"))
    f.Push(CSetCallerFlag("FocusOnRing", "Switch to the Companion when a call rings"
        , "Bring the Companion window to the front when a call rings"))
    f.Push(CSetCallerFlag("AutoSearch", "Open Salesforce search automatically when a call rings"
        , "Searches the caller's name, then their number (that tab ends up in front). It waits until you are on the virtual desktop with 3CX, so the tabs open in the browser there. Not for a second call while you are on one. The SF # / SF name buttons still work."))
    f.Push(CSetCallerFlag("AutoSearchRefocus", "   ...then give focus back to the window I was in"
        , "The browser comes to the front when a tab opens; this puts the window you were using (e.g. 3CX) straight back"))
    ; ---- 2  Q status: ONE Q detector (q-watch.ahk), used by the Q-login alert and the headset check
    f.Push({sec: 2, type: "head", label: "Q detection  (used by the Q-login alert and the headset check)"})
    f.Push({sec: 2, type: "live", get: QAStatusText})
    f.Push(CSetQaNum("IntervalSec", "How often 3CX and its Q login are checked - for the Q-login alert and the headset check (how fast it sees you back in Q)"))
    f.Push({sec: 2, type: "head", label: "Q-login alert"})
    f.Push({sec: 2, type: "check", key: "QA.Enabled", label: QA_ITEM_ON, def: 1
        , tip: "A small alert when 3CX is closed or you're not logged in to the queue (Q)"
        , get: () => QAlertSetting("Enabled", 1) = "1", flip: () => QAToggle()})
    f.Push({sec: 2, type: "choice", key: "QA.Position", label: "Where the alert shows", choices: QA_POSITIONS
        , tip: "Where on the screen the alert appears. `"Near the 3CX window`" follows 3CX."
        , def: QA_DEFAULT_POS, get: () => QAlertSetting("Position", QA_DEFAULT_POS), set: CSetQaPosition})
    f.Push(CSetQaNum("ToastSeconds", "How long each alert stays before it closes by itself"))
    f.Push(CSetQaNum("MaxToasts", "Most alerts on the screen at once; the oldest closes when a new one comes"))
    f.Push(CSetQaNum("SnoozeMinutes", "How long the alert's Snooze button silences it (for extra after-call work)"))
    f.Push({sec: 2, type: "buttons", items: [["Show a test alert", () => QAShowToast(true)
        , "Show an alert now, to see where and how it appears"]
        , ["Snooze the alert now", () => QASnooze(), "Silence the Q alert for the snooze length above; it comes back by itself"]]})
    f.Push({sec: 3, type: "head", label: "Headset check"})
    f.Push({sec: 3, type: "note", label: "Beeps in your headset and listens: answer after the beep (say `"yep`", tap the mic). Nothing heard = a reminder. "
        . "Uses Q detection (see Q status), also with the Q alert off. Calibrate first."})
    f.Push({sec: 3, type: "check", key: "HS.Enabled", label: HS_ITEM_ON, def: 0
        , tip: "Off by default. Turning it on the first time opens Calibrate; it turns on when you Save there."
        , get: HsEnabled, flip: HsToggle})
    f.Push({sec: 3, type: "check", key: "HS.AckOn", label: HS_ITEM_ACK, def: 1
        , tip: "The moment it hears you it stops listening and plays the sound again, so you know you can stop answering"
        , get: HsAckOn, flip: HsAckToggle})
    f.Push({sec: 3, type: "choice", key: "HS.Position", label: "Where the reminder shows", choices: QA_POSITIONS
        , tip: "Its own spot. If you pick the same spot as the Q-login alert, their toasts stack instead of covering each other."
        , def: HS_DEFAULT_POS, get: HsPosition, set: HsSetPosition})
    for key in ["ListenSec", "MinAwaySec", "StartDelaySec", "MinSoundMs", "ThresholdDb", "LightEveryMin", "StrictEverySec", "ReminderSec"]
        f.Push(CSetHsNum(key))
    f.Push({sec: 3, type: "buttons", items: [["Calibrate...", () => HsSafe(() => HsCalOpen(false))
            , "Pick the sound and mic, and teach it your room's noise and your answer"]
        , ["Check now", () => HsSafe(() => HsRunCheck("now")), "Beep and listen now, the way it does when you log back in to Q"]]})

    ; ---- 2  Copilot
    f.Push({sec: 4, type: "head", label: "Copilot pool (the 💬 and ^ buttons beside the helpers)"})
    f.Push({sec: 4, type: "check", key: "Pool.Enabled", label: POOLLINK_USE, def: 1
        , tip: "Copilot pages inside the app answer the 💬 and ^ buttons and the auto helpers.`nOff = only 🤖 (paste into Copilot in your browser)."
        , get: PoolLinkEnabled, flip: PoolLinkToggle})
    f.Push({sec: 4, type: "buttons", items: [["Open the pool window", PoolLinkShowWindow
            , "Sign in to Copilot, see whether the pool is ready, pick the chat site"]
        , ["Restart the pool", PoolLinkRestart, "Close the pool and start it again. Its Copilot windows close; you stay signed in."]
        , ["Sign out of Copilot...", PoolLinkSignOut, "Sign out (e.g. to use another account) and start the pool again"]]})
    f.Push({sec: 4, type: "head", label: "Copilot pool memory guard"})
    f.Push({sec: 4, type: "check", key: "Pool.MemGuard", label: "Memory guard: tidy idle Copilot pages", def: 1
        , tip: "On: idle pages use less memory, and a page that grew too big is reloaded when nobody is using it.`nOff: pages are never touched (more memory used, but nothing reloads - try it if Screen ask or 💬 is slow to start).`nApplies within 30 seconds."
        , get: () => PoolLinkMemGet("MemGuard") != 0, flip: PoolLinkMemGuardToggle})
    f.Push(CSetPoolNum("PageMaxMB", "A page bigger than this is reloaded when idle (MB)", "100 to 4000", 100, 4000
        , "A reload makes the next question wait while Copilot loads again. Higher = fewer reloads, more memory."))
    f.Push(CSetPoolNum("TotalMaxMB", "All Copilot pages together over this: trim (MB)", "300 to 8000", 300, 8000
        , "When the whole built-in browser uses more than this, the biggest idle page is reloaded and spare pages are closed"))
    f.Push(CSetPoolNum("IdleLowMemSec", "Idle pages use less memory after (seconds)", "10 to 3600", 10, 3600
        , "A hidden page nobody used for this long is told to free memory; it wakes up when it gets a question"))
    f.Push({sec: 4, type: "head", label: "Auto helpers"})
    f.Push({sec: 4, type: "note", label: "To pick which helpers follow the call by themselves: right-click a helper button > Auto-run during calls."})
    f.Push(CSetAutoNum("MinChars", "New customer letters before a follow-up", "1 = any new words", 1, 5000
        , "How much new customer speech is needed before an auto helper sends a follow-up"))
    f.Push(CSetAutoNum("QuietMs", "Customer quiet this long = finished (ms)", "1000 ms = 1 second", 100, 30000
        , "The customer must be quiet this long before a follow-up goes, so it isn't sent in the middle of a sentence"))
    f.Push(CSetAutoNum("MinGapMs", "At least this long between follow-ups (ms)", "0 = no wait", 0, 600000
        , "The shortest time between two follow-ups to the same helper"))
    f.Push({sec: 4, type: "text", key: "Auto.FollowUpPrompt", rows: 4, need: "{{new}}"
        , label: "Follow-up message  ({{new}} = what the customer just said)"
        , tip: "What an auto helper sends when the customer said something new. {{new}} is replaced by those words."
        , def: StrReplace(AUTO_DEFAULTS["FollowUpPrompt"], "\n", "`n")
        , get: () => StrReplace(AutoSetting("FollowUpPrompt"), "\n", "`n")
        , set: (v) => IniWrite(StrReplace(v, "`n", "\n"), MIC_INI, "AutoHelpers", "FollowUpPrompt")})
    f.Push({sec: 4, type: "head", label: "Paste into Copilot (the 🤖 buttons)"})
    f.Push({sec: 4, type: "buttons", items: [["Learn: message box", () => AssistStartLearn("Input")
            , "Teach 🤖 where Copilot's message box is: rest the mouse on it in your browser and press F8 (Esc cancels)"]
        , ["Learn: Send button", () => AssistStartLearn("Send"), "Teach 🤖 where Copilot's Send button is (mouse on it, F8)"]
        , ["Learn: New chat button", () => AssistStartLearn("NewChat"), "Teach 🤖 where Copilot's New chat button is (mouse on it, F8)"]]})

    ; ---- 3  Apps
    f.Push({sec: 5, type: "note", label: "Each app runs on its own: if one has a problem, captions and the call carry on. "
        . "On = it starts with the Companion. The buttons work while an app is off too."})
    f.Push({sec: 5, type: "app", key: "App.Tasks", label: TASKLINK_ITEM, def: 1, get: TaskLinkEnabled, flip: TaskLinkToggle
        , tip: "Timers, checklists and reminders in their own window. They keep counting when the Companion closes."
        , items: [["Open", () => TaskLinkShowApp("show"), "Open the Tasks window"]
            , ["Settings...", () => TaskLinkShowApp("settings"), "Tasks' own settings (alerts, sounds, timer buttons)"]]})
    f.Push({sec: 5, type: "app", key: "App.MainHelper", label: MAINHELPER_ITEM, def: 0, get: MainHelperEnabled
        , tip: "Extra shortcut keys, like a Salesforce or ServiceChannel search for what's on the clipboard"
        , flip: MainHelperToggle, items: []})
    f.Push({sec: 5, type: "app", key: "App.ScreenAsk", label: SALINK_MENU, def: 0, get: SaLinkEnabled, flip: SaLinkToggle
        , tip: "Ctrl+Shift+Alt+A freezes your screens: mark something and ask Copilot about it"
        , items: [["Capture now", CSetScreenAskNow, "Freeze the screens now and mark something (this window steps aside)"]
            , ["Settings...", () => SaLinkCommand("settings"), "Screen ask's own settings (shortcut, colour)"]]})
    f.Push({sec: 5, type: "app", key: "App.SameValue", label: SVLINK_MENU, def: 0, get: SvLinkEnabled, flip: SvLinkToggle
        , tip: "Hold CapsLock: equal values on your screens light up in the same colour (a tap stays CapsLock)"
        , items: [["Show now", () => SvLinkCommand("show"), "Show the highlights now, without holding the key"]
            , ["Settings...", () => SvLinkCommand("settings"), "Its own settings (the key, what counts as a value, colours)"]]})
    f.Push({sec: 5, type: "app", key: "App.Agent", label: AGTLINK_MENU, def: AppIsDev() ? 1 : 0, get: AgtLinkEnabled
        , tip: "An AI that uses tools on your PC, asking your OK first (early test)"
        , flip: AgtLinkToggle, items: [["Open", AgtLinkOpen, "Open the Agent window"]]})
    f.Push({sec: 5, type: "note", label: "The Copilot pool is under Copilot."})

    ; ---- 4  Captions & mic
    f.Push({sec: 6, type: "head", label: "Windows Live Captions"})
    f.Push({sec: 6, type: "check", key: "Lct.Auto", label: "Start Windows Live Captions by itself", def: 1
        , tip: "The Companion needs Live Captions: when it isn't running (at start, or it was closed), the Companion opens it for you"
        , get: LctAutoOn, flip: LctAutoToggle})
    f.Push({sec: 6, type: "note", label: "Restart and Test are also in the right-click menu of the chat view."})
    f.Push({sec: 6, type: "buttons", items: [["Restart Live Captions", LctSafe(LctRestart)
            , "Close and reopen Windows Live Captions - try it when captions stop coming"]
        , ["Test Live Captions (plays a sample voice)", LctSafe(LctTest)
            , "Plays a short sample voice, so you can see captions arrive in the Companion"]]})
    for fld in SpkChatFields(6)                  ; speaker detection (speaker-chat.ahk)
        f.Push(fld)
    f.Push({sec: 6, type: "head", label: "Mic captions (experimental: your own voice)"})
    if micAvailable {
        devs := [MicDeviceLabel(0)]
        for name in micDeviceNames
            devs.Push(name)
        f.Push({sec: 6, type: "check", key: "Mic.On", label: "Experimental: Mic captions", def: 0
            , tip: "Also caption what YOU say, from your microphone (experimental; uses more of the PC)"
            , get: () => micEnabled, flip: () => ToggleMicCaptions()})
        f.Push({sec: 6, type: "choice", key: "Mic.Device", label: "Microphone", choices: devs, def: MicDeviceLabel(0)
            , tip: "Which microphone mic captions listen to"
            , get: () => MicDeviceLabel(micCurrentDevice), set: CSetMicDevice})
    } else {
        f.Push({sec: 6, type: "note", label: "Not available on this PC (the speech files for mic captions aren't installed)."})
    }

    ; ---- 5  Updates & help
    f.Push({sec: 7, type: "head", label: "Updates  (this copy: version " APP_VERSION ")"})
    f.Push({sec: 7, type: "buttons", items: [["Check for updates", UpdSafe(() => UpdStartCheck(true))
            , "Look for a new version now (it also checks by itself every few hours)"]
        , ["Set update link...", UpdSafe(UpdSetLink), "Where updates come from - change it only if you were told to"]
        , ["Go back to the previous version...", UpdSafe(UpdRollback)
            , "Undo the last update and go back to the version before (copies installed with Setup.bat)"]]})
    f.Push({sec: 7, type: "head", label: "Tips"})
    f.Push({sec: 7, type: "check", key: "Tips.On", label: "Show a tip when the mouse rests on a button", def: 1
        , tip: "These little explanations. Off = no tips in any of the apps (Tasks, Screen ask, ... too).", get: TipsEnabled
        , flip: CSetTipsToggle})
    f.Push({sec: 7, type: "head", label: "Help and your data"})
    f.Push({sec: 7, type: "buttons", items: [["Tutorial (how to use the app)", CSetTutorial
            , "A guided tour of the Companion (this window closes first)"]
        , ["Open data folder", () => Run('explorer.exe "' DATA_DIR '"'), "Your calls, helpers, settings and logs"]]})
    f.Push({sec: 7, type: "buttons", items: [["Import && merge from another copy...", () => MergeImportStart()
        , "Bring in calls and helpers from another copy or a backup. It shows what will change first; duplicates are skipped."]]})

    ; ---- 6  Troubleshooting
    f.Push({sec: 8, type: "head", label: "Debug trace"})
    f.Push({sec: 8, type: "check", key: "Dbg.On", label: DBG_ITEM, def: 0
        , tip: "Writes the timing of every click and step to a file, to find delays. Never what's said on the call."
        , get: () => IniRead(DBG_INI, "Trace", "On", "0") = "1", flip: () => DbgToggle()})
    f.Push({sec: 8, type: "head", label: "Logs"})
    f.Push({sec: 8, type: "buttons", items: [["Debug trace", () => CSetOpenFile(DBG_FILE), "Open the debug trace (timings)"]
        , ["Errors", () => CSetOpenFile(ERR_LOG), "Problems the app ran into"]
        , ["3CX caller / Q alert", () => CSetOpenFile(CALLER_LOG), "What call detection and the Q-login alert saw"]]})
    f.Push({sec: 8, type: "buttons", items: [["Updates", () => CSetOpenFile(UPD_LOG), "What the update checks and installs did"]
        , ["Paste into Copilot", () => CSetOpenFile(ASSIST_LOG), "What the 🤖 buttons did"]
        , ["Copilot targets file", () => CSetOpenFile(ASSIST_TARGETS), "Where the Learn buttons saved Copilot's message box and buttons"]]})
    f.Push({sec: 8, type: "head", label: "Try without a real call"})
    f.Push({sec: 8, type: "buttons", items: [["Simulate incoming call...", CallerSafe(CallerSimulateRing)
            , "Pretend a call is ringing, to try the caller strip and the caller card"]
        , ["Simulate call ended", CallerSafe(CallerOnIdle), "Pretend the call just ended"]]})
    f.Push({sec: 8, type: "head", label: "Memory"})
    f.Push({sec: 8, type: "buttons", items: [["Built-in browser memory (Copilot pool, Screen ask)...", PoolLinkMemoryReport
        , "How much memory the built-in browsers use, and which app uses them"]]})
    return f
}

; Entry makers: each call gets its own variables (closures made in a loop would all share one)
CSetCallerFlag(key, label, tip) {
    return {sec: 1, type: "check", key: "Caller." key, label: label, tip: tip, def: CALLER_DEFAULTS.Get(key, 0)
        , get: () => CallerFlag(key), flip: () => CallerToggle(key)}
}

CSetQaNum(key, tip) {
    c := QA_CHOICES[key]
    return {sec: 2, type: "num", key: "QA." key, label: c[1] (c[3] != "" ? " (" c[3] ")" : ""), hint: c[5] " to " c[6]
        , tip: tip, min: c[5], max: c[6], def: c[4], get: () => QAInt(key), set: (v) => QASaveValue(key, Integer(v))}
}

CSetHsNum(key) {
    c := HS_NUMS[key]
    return {sec: 3, type: "num", key: "HS." key, label: c[1], hint: c[3] " to " c[4], tip: c[5], min: c[3], max: c[4], def: c[2]
        , get: () => HsNum(key), set: (v) => HsSetNum(key, v)}
}

CSetPoolNum(key, label, hint, lo, hi, tip) {
    return {sec: 4, type: "num", key: "Pool." key, label: label, hint: hint, tip: tip, min: lo, max: hi, def: POOLLINK_MEM_DEFAULTS[key]
        , get: () => PoolLinkMemGet(key), set: (v) => PoolLinkMemSet(key, v)}
}

CSetAutoNum(key, label, hint, lo, hi, tip) {
    return {sec: 4, type: "num", key: "Auto." key, label: label, hint: hint, tip: tip, min: lo, max: hi, def: AUTO_DEFAULTS[key]
        , get: () => AutoNum(key), set: (v) => IniWrite(Integer(v), MIC_INI, "AutoHelpers", key)}
}

CSetQaPosition(v) {
    IniWrite(v, MIC_INI, "QAlert", "Position")
    QASyncMenu()
}

CSetMicDevice(v) {
    if (v = MicDeviceLabel(0)) {
        SetMicDevice(0)
        return
    }
    for i, name in micDeviceNames
        if (name = v)
            return SetMicDevice(i)
}

; Screen ask freezes the whole screen: this window steps aside first
CSetScreenAskNow() {
    try cSetGui.Hide()
    SetTimer(() => SaLinkCommand("capture"), -250)
}

; The tutorial points at the main window: this window closes first (asks about unsaved changes)
CSetTutorial() {
    if CSetClose()
        SetTimer(TutSafe(TutStart), -200)
}

CSetOpenFile(path) {
    if !FileExist(path) {
        CSetStatus("Nothing written there yet (" path ")")
        return
    }
    Run('notepad.exe "' path '"')
}

; ------------------------------------------------------------------ the window
CSetShow(*) {
    global cSetGui, cSetFieldList, cSetSec, cSetPage, cSetSecH, cSetScroll
    try {
        if IsObject(cSetGui) {
            if !CSetDirty()
                CSetFill(false)                  ; pick up changes made from the tray meanwhile
            cSetGui.Show()
            return
        }
        try cSetSec := Integer(IniRead(MIC_INI, "Settings", "LastSection", 1))
        if (cSetSec < 1 || cSetSec > CSET_SECTIONS.Length)
            cSetSec := 1
        g := Gui("-MinimizeBox +Owner" myGui.Hwnd, "Live Caption Companion - Settings")
        g.SetFont("s10", "Segoe UI")
        names := []
        for s in CSET_SECTIONS
            names.Push(StrReplace(s, "&&", "&"))
        list := g.Add("ListBox", "x12 y12 w186 h520 vSections Choose" cSetSec, names)
        list.OnEvent("Change", (ctl, *) => CSetShowSection(ctl.Value))
        ; The page is its own child window with a vertical scroll bar: a section taller than the page
        ; scrolls instead of running into the Save / Close bar (Copilot's last rows once were drawn over it)
        pg := Gui("-Caption +Parent" g.Hwnd " +0x200000")       ; WS_VSCROLL
        pg.SetFont("s10", "Segoe UI")
        pg.OnEvent("Escape", (*) => CSetClose())
        cSetPage := pg
        cSetScroll := 0                          ; a new page starts at the top
        cSetFieldList := CSetFields()
        rowY := Map()
        for f in cSetFieldList {
            y := rowY.Has(f.sec) ? rowY[f.sec] : 12
            if (f.type = "head" && y > 12)
                y += 8                           ; a little air above each heading but the first
            f.ctls := []
            CSetAddField(pg, f, y, &used)
            rowY[f.sec] := y + used
        }
        cSetSecH := rowY                         ; each section's content height (for the scroll bar)
        g.Add("Text", "x12 y544 w856 h1 0x10")       ; a thin line above the buttons (SS_ETCHEDHORZ)
        b := g.Add("Button", "x12 y556 w100 h30 Default", "Save")
        b.OnEvent("Click", (*) => CSetSave())
        TipSet(b, "Apply the ticks and values you changed (the window stays open)")
        b := g.Add("Button", "x120 y556 w90 h30", "Close")
        b.OnEvent("Click", (*) => CSetClose())
        TipSet(b, "Close the window (asks first if something isn't saved)")
        b := g.Add("Button", "x218 y556 w190 h30", "Defaults (this section)")
        b.OnEvent("Click", (*) => CSetDefaults())
        TipSet(b, "Fill in the values the app ships with, for this section only. Nothing changes until Save.")
        g.Add("Text", "x420 y552 w448 h40 cGray vStatus", "Ticks and values apply when you press Save. Buttons act right away.")
        g.OnEvent("Close", (*) => !CSetClose())  ; true = keep the window (Cancel on the question)
        g.OnEvent("Escape", (*) => CSetClose())
        cSetGui := g
        ; Show scales w / h for the screen's zoom (DPI) but not x / y: scale the place ourselves
        pg.Show("x" Round(CSET_PAGE_X * A_ScreenDPI / 96) " y0 w" CSET_PAGE_W " h" CSET_PAGE_H " NA")
        CSetFill(false)
        g.Show("w880 h600")
        CSetShowSection(cSetSec)
        CSetLiveTick()
        SetTimer(CSetLiveTick, 1000)             ; "live" rows (e.g. the Q status now) refresh every second
    } catch as err {
        CSetReport(err)
    }
}

; ------------------------------------------------------------------ the page's scroll bar
; Sets the scroll bar for the section on show (Windows hides it when the section fits)
CSetScrollSetup() {
    global cSetContentPx, cSetPagePx
    try {
        if !IsObject(cSetPage)
            return
        WinGetClientPos(, , , &ph, cSetPage.Hwnd)
        cSetPagePx := ph
        cSetContentPx := Round(((cSetSecH.Has(cSetSec) ? cSetSecH[cSetSec] : 0) + 12) * A_ScreenDPI / 96)
        si := Buffer(28, 0)                      ; SCROLLINFO: range 0..content-1, page = visible height, pos 0
        NumPut("UInt", 28, "UInt", 0x7, "Int", 0, "Int", cSetContentPx - 1, "UInt", cSetPagePx, "Int", 0, si)
        DllCall("SetScrollInfo", "Ptr", cSetPage.Hwnd, "Int", 1, "Ptr", si, "Int", 1)   ; SB_VERT, redraw
    }
}

; Scrolls the page so pixel row pos is at the top (kept within the content)
CSetScrollTo(pos) {
    global cSetScroll
    try {
        if !IsObject(cSetPage)
            return
        pos := Max(0, Min(Max(0, cSetContentPx - cSetPagePx), Round(pos)))
        dy := cSetScroll - pos
        if !dy
            return
        DllCall("ScrollWindow", "Ptr", cSetPage.Hwnd, "Int", 0, "Int", dy, "Ptr", 0, "Ptr", 0)   ; moves every row
        cSetScroll := pos
        DllCall("SetScrollPos", "Ptr", cSetPage.Hwnd, "Int", 1, "Int", pos, "Int", 1)
        DllCall("RedrawWindow", "Ptr", cSetPage.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x1 | 0x4 | 0x80 | 0x100)
    }
}

; WM_VSCROLL: arrows, clicks and dragging on the page's own scroll bar
CSetOnVScroll(wParam, lParam, msg, hwnd) {
    if (!IsObject(cSetPage) || hwnd != cSetPage.Hwnd || lParam)
        return
    line := Round(30 * A_ScreenDPI / 96)
    switch wParam & 0xFFFF {
        case 0: p := cSetScroll - line           ; SB_LINEUP
        case 1: p := cSetScroll + line           ; SB_LINEDOWN
        case 2: p := cSetScroll - cSetPagePx     ; SB_PAGEUP
        case 3: p := cSetScroll + cSetPagePx     ; SB_PAGEDOWN
        case 4, 5: p := (wParam >> 16) & 0xFFFF  ; SB_THUMBPOSITION / SB_THUMBTRACK
        case 6: p := 0                           ; SB_TOP
        case 7: p := cSetContentPx               ; SB_BOTTOM
        default: return 0
    }
    CSetScrollTo(p)
    return 0
}

; WM_MOUSEWHEEL with the mouse over the page scrolls it (a multi-line text box scrolls itself)
CSetOnWheel(wParam, lParam, msg, hwnd) {
    if (!IsObject(cSetPage) || cSetContentPx <= cSetPagePx)
        return
    try {
        MouseGetPos(, , &win, &under, 2)
        if (win != cSetGui.Hwnd)
            return
        if !(under = cSetPage.Hwnd || DllCall("IsChild", "Ptr", cSetPage.Hwnd, "Ptr", under))
            return
        if (WinGetClass("ahk_id " under) = "Edit" && (WinGetStyle("ahk_id " under) & 0x4))   ; ES_MULTILINE
            return
        d := (wParam >> 16) & 0xFFFF
        if (d > 0x7FFF)
            d -= 0x10000
        CSetScrollTo(cSetScroll - Round(d / 120 * 60 * A_ScreenDPI / 96))
        return 0
    }
}

; Refreshes the "live" rows while the window is open; stops by itself when it closes
CSetLiveTick() {
    if !IsObject(cSetGui) {
        SetTimer(CSetLiveTick, 0)
        return
    }
    for f in cSetFieldList {
        if (f.type != "live")
            continue
        try {
            getFn := f.get                       ; (f.get() would pass f as a first parameter)
            t := getFn()
            if (f.ctl.Value != t)
                f.ctl.Value := t
        }
    }
}

; One setting's controls at height y (page coordinates). used = height it took.
CSetAddField(g, f, y, &used) {
    px := CSET_PX, pw := CSET_PW, lw := 300
    switch f.type {
        case "head":
            g.SetFont("s10 bold")
            f.ctls.Push(g.Add("Text", "x" px " y" y " w" pw " h22", f.label))
            g.SetFont("s10 norm")
            used := 28
        case "note":
            lines := Ceil(StrLen(f.label) / 92)
            f.ctls.Push(g.Add("Text", "x" px " y" y " w" pw " h" (20 * lines) " cGray", f.label))
            used := 20 * lines + 8
        case "live":
            f.ctl := g.Add("Text", "x" px " y" y " w" pw " h20", "")
            f.ctls.Push(f.ctl)
            used := 28
        case "check":
            f.ctl := g.Add("CheckBox", "x" px " y" y " w" pw " h24", f.label)
            f.ctls.Push(f.ctl)
            if f.HasOwnProp("tip")
                TipSet(f.ctl, f.tip)
            used := 30
        case "num", "choice":
            f.ctls.Push(g.Add("Text", "x" px " y" (y + 3) " w" (lw - 8) " h20", f.label))
            cw := f.type = "num" ? 90 : 250
            if (f.type = "choice")
                f.choices := f.choices.Clone()   ; our own copy (CSetPut may add to it; QA_POSITIONS feeds the tray)
            if (f.type = "num")
                f.ctl := g.Add("Edit", "x" (px + lw) " y" y " w" cw " h26")
            else
                f.ctl := g.Add("DropDownList", "x" (px + lw) " y" y " w" cw, f.choices)
            f.ctls.Push(f.ctl)
            if f.HasOwnProp("tip")
                TipSet(f.ctl, f.tip)
            if (f.HasOwnProp("hint") && f.hint != "") {
                hx := px + lw + cw + 10
                f.ctls.Push(g.Add("Text", "x" hx " y" (y + 3) " w" (px + pw - hx) " h20 cGray", f.hint))
            }
            used := 34
        case "text":
            f.ctls.Push(g.Add("Text", "x" px " y" y " w" pw " h20", f.label))
            h := f.rows * 20 + 8
            f.ctl := g.Add("Edit", "x" px " y" (y + 24) " w" pw " h" h " Multi WantReturn VScroll")
            f.ctls.Push(f.ctl)
            if f.HasOwnProp("tip")
                TipSet(f.ctl, f.tip)
            used := 24 + h + 8
        case "buttons":
            bx := px
            for it in f.items {
                w := CSetButtonW(it[1])
                b := g.Add("Button", "x" bx " y" y " w" w " h28", it[1])
                b.OnEvent("Click", CSetRun.Bind(it[2]))
                if (it.Length >= 3)
                    TipSet(b, it[3])
                f.ctls.Push(b)
                bx += w + 8
            }
            used := 36
        case "app":
            f.ctl := g.Add("CheckBox", "x" px " y" (y + 2) " w380 h24", f.label)
            f.ctls.Push(f.ctl)
            if f.HasOwnProp("tip")
                TipSet(f.ctl, f.tip)
            bx := px + 390
            for it in f.items {
                w := Max(100, CSetButtonW(it[1]))
                b := g.Add("Button", "x" bx " y" y " w" w " h28", it[1])
                b.OnEvent("Click", CSetRun.Bind(it[2]))
                if (it.Length >= 3)
                    TipSet(b, it[3])
                f.ctls.Push(b)
                bx += w + 8
            }
            used := 38
        default:
            used := 0
    }
}

CSetButtonW(label) => Max(90, StrLen(StrReplace(label, "&&", "&")) * 8 + 24)

CSetShowSection(i) {
    global cSetSec
    try {
        CSetScrollTo(0)                          ; back to the top before switching (all rows move together)
        cSetSec := i
        for f in cSetFieldList
            for c in f.ctls
                c.Visible := (f.sec = i)
        try IniWrite(i, MIC_INI, "Settings", "LastSection")
        CSetScrollSetup()
        SetTimer(() => (IsObject(cSetGui) ? RepaintWindow(cSetGui.Hwnd) : 0), -60)
    } catch as err {
        CSetReport(err)
    }
}

; A button: runs now; the status line then shows what the main window's status line says
CSetRun(fn, *) {
    try {
        fn()
        SetTimer(CSetMirrorStatus, -400)
    } catch as err {
        CSetReport(err)
    }
}

CSetMirrorStatus() {
    try {
        t := statusText.Text
        if (SubStr(t, 1, 8) = "Status: ")
            t := SubStr(t, 9)
        CSetStatus(t)
    }
}

CSetStatus(text) {
    try cSetGui["Status"].Value := text
}

; ------------------------------------------------------------------ values
CSetHasValue(f) => (f.type = "check" || f.type = "app" || f.type = "num" || f.type = "choice" || f.type = "text")

; What the control shows now, in the same form as f.orig
CSetRead(f) {
    switch f.type {
        case "check", "app": return f.ctl.Value ? 1 : 0
        case "choice":       return f.ctl.Text
        case "text":         return StrReplace(f.ctl.Value, "`r")
        default:             return Trim(f.ctl.Value)
    }
}

CSetPut(f, v) {
    switch f.type {
        case "check", "app":
            f.ctl.Value := v ? 1 : 0
        case "choice":
            pick := 0
            for i, c in f.choices
                if (c = String(v))
                    pick := i
            if !pick {                           ; a value not in the list (typed in the file): add it
                f.ctl.Add([String(v)])
                f.choices.Push(String(v))
                pick := f.choices.Length
            }
            f.ctl.Choose(pick)
        case "text":
            f.ctl.Value := StrReplace(v, "`n", "`r`n")
        default:
            f.ctl.Value := v
    }
}

; Fills in the current state (defaults = only this section's shipped values; they're saved on Save)
CSetFill(defaults) {
    for f in cSetFieldList {
        if !CSetHasValue(f)
            continue
        try {
            if defaults {
                if (f.sec = cSetSec)
                    CSetPut(f, f.def)
                continue
            }
            getFn := f.get                       ; (f.get() would pass f as a first parameter)
            v := getFn()
            if (f.type = "check" || f.type = "app")
                v := v ? 1 : 0
            CSetPut(f, v)
            f.orig := CSetRead(f)                ; what Save compares with
        } catch as err {
            CSetReport(err, f.key)
        }
    }
}

CSetDefaults() {
    CSetFill(true)
    CSetStatus("The shipped defaults of " StrReplace(CSET_SECTIONS[cSetSec], "&&", "&") " are filled in - press Save to keep them.")
}

CSetDirty() {
    if !IsObject(cSetGui)
        return false
    for f in cSetFieldList
        if (CSetHasValue(f) && f.HasOwnProp("orig") && !(CSetRead(f) == f.orig))
            return true
    return false
}

; "" = fine, else what's wrong
CSetCheck(f, v) {
    switch f.type {
        case "num":
            if !IsInteger(v)
                return "must be a whole number"
            if (Integer(v) < f.min || Integer(v) > f.max)
                return "must be from " f.min " to " f.max
        case "text":
            if (Trim(v, " `t`n") = "")
                return "can't be empty"
            if (f.HasOwnProp("need") && !InStr(v, f.need))
                return "must contain " f.need
    }
    return ""
}

; Checks everything first; then applies only what changed here. True if saved.
CSetSave() {
    try {
        problems := "", firstBad := 0
        for f in cSetFieldList {
            if !CSetHasValue(f)
                continue
            err := CSetCheck(f, CSetRead(f))
            if (err != "") {
                problems .= (problems = "" ? "" : "   ·   ") f.label ": " err
                if !firstBad
                    firstBad := f
            }
        }
        if (problems != "") {
            if (firstBad.sec != cSetSec) {
                cSetGui["Sections"].Choose(firstBad.sec)
                CSetShowSection(firstBad.sec)
            }
            CSetStatus("Not saved - " problems)
            return false
        }
        n := 0
        for f in cSetFieldList {
            if !CSetHasValue(f) || !f.HasOwnProp("orig")
                continue
            v := CSetRead(f)
            if (v == f.orig)
                continue
            try {
                if (f.type = "check" || f.type = "app") {
                    getFn := f.get, flipFn := f.flip  ; (f.get() would pass f as a first parameter)
                    if ((getFn() ? 1 : 0) != v)       ; the tray's own toggle: menus, starting/stopping follow
                        flipFn()
                } else {
                    setFn := f.set
                    setFn(v)
                }
                f.orig := v
                n += 1
            } catch as err {
                CSetReport(err, f.key)
            }
        }
        CSetStatus(n ? "Saved (" n " change" (n = 1 ? "" : "s") ")." : "Nothing changed.")
        if n
            statusText.Text := "Status: settings saved (" n " change" (n = 1 ? "" : "s") ")"
        return true
    } catch as err {
        CSetReport(err)
        return false
    }
}

; Closes the window; asks first if something isn't saved. False = stay open (Cancel).
CSetClose() {
    global cSetGui, cSetPage, cSetScroll
    try {
        if !IsObject(cSetGui)
            return true
        if CSetDirty() {
            cSetGui.Opt("+OwnDialogs")
            r := MsgBox("Save your changes first?", "Settings", "YesNoCancel Icon?")
            if (r = "Cancel")
                return false
            if (r = "Yes" && !CSetSave())
                return false                     ; a value is wrong: the status line says which
        }
        cSetGui.Destroy()
    } catch as err {
        CSetReport(err)
    }
    cSetGui := 0
    cSetPage := 0
    cSetScroll := 0
    return true
}

CSetReport(err, where := "") {
    msg := "Settings" (where != "" ? " (" where ")" : "") ": " err.Message
    try statusText.Text := "Status: " msg " (captions keep running)"
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "  [" err.What " line " err.Line "]`n", ERR_LOG, "UTF-8")
}
