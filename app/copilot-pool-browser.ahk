; ==============================================================================
; copilot-pool-browser.ahk  -  browser TABS in the pool (prefix PoolTab*): a normal web page an app drives
;
; * Not a Copilot page: it never enters `views`, never gets the worker script and can't send messages to
;   the pool (no WebMessageReceived). It only shares the pool's browser engine = the same sign-in
;   (so work sites with single sign-on open signed in).
; * One tab per name ("agent" for the Agent), shown as its own window so you watch what it does (and can
;   use it yourself). It remembers its place ([Window tab-<name>] in copilot-pool.ini).
; * https only. Links that would open a new window open in the same tab. Script dialogs are off.
; * Closes when you close its window, on {op:"close"}, or when the app that owns it is gone
;   (memory guard rule: never outlive its users).
; * The log never holds page text, addresses or typed text: only ops and times.
;
; Message (WM_COPYDATA, POOL_TAG):
;   app -> pool {t:"tab", id, hwnd (reply to), owner (hwnd that must stay alive), tab (name), op, args}
;   pool -> app {t:"tab-done", id, ok, text, image (PNG path in APP_IMAGE_INBOX), error}
;   ops: open {url?}  navigate {url}  back  forward  reload  snapshot {textChars?}  click {ref | x,y,
;        button: left|right|middle, double}  hover {ref | x,y}  type {ref?, text, clear?, submit?}
;        key {key: "Enter" | "Ctrl+A" | ...}  scroll {direction: down|up|left|right, amount?, ref?}
;        select {ref, option}  screenshot  close
;   refs come from the last snapshot (data-agt-ref attributes on the page).
; Included by copilot-pool.ahk (uses env, POOL_INI, PoolSendTo, PoolLog, POOL_DEV).
; ==============================================================================
poolTabs := Map()
SetTimer(PoolTabWatch, 5000)

PoolTabHandle(m, hwnd) {
    id := m.Get("id", ""), op := StrLower(m.Get("op", "")), name := m.Get("tab", "agent")
    args := m.Get("args", Map())
    if !(args is Map)
        args := Map()
    t0 := A_TickCount
    try {
        res := PoolTabDo(name, op, args, m.Get("owner", hwnd))
        out := Map("t", "tab-done", "id", id, "ok", 1, "text", res.Get("text", ""))
        if res.Has("image")
            out["image"] := res["image"]
        PoolLog("tab " name ": " op " in " (A_TickCount - t0) " ms")
    } catch as err {
        out := Map("t", "tab-done", "id", id, "ok", 0, "error", err.Message)
        PoolLog("tab " name ": " op " failed after " (A_TickCount - t0) " ms")
    }
    if (IsInteger(hwnd) && hwnd)
        PoolSendTo(hwnd, out)
}

PoolTabDo(name, op, args, owner) {
    if (op = "close") {
        PoolTabClose(name)
        return Map("text", "The browser tab is closed.")
    }
    tab := poolTabs.Has(name) && !poolTabs[name].dead ? poolTabs[name] : 0
    if !IsObject(tab) {
        if !(op = "open" || op = "navigate")
            throw Error("no browser tab is open - open one first (browser_open)")
        tab := PoolTabOpen(name, owner)
    }
    tab.owner := owner
    wv := tab.wv
    switch op {
        case "open", "navigate":
            url := Trim(args.Get("url", ""))
            if (url != "") {
                wv.Navigate(PoolTabUrl(url))
                PoolTabSettle(tab, 800)
            } else if (op = "navigate") {
                throw Error("give the address (url)")
            } else if (wv.Source = "") {                 ; a new tab with no address: an empty page
                wv.Navigate("about:blank")
                PoolTabSettle(tab, 300)
            }
            try tab.gui.Show("NoActivate")
            return Map("text", PoolTabSnap(tab, 1500))
        case "back", "forward":
            PoolTabJs(tab, "history." op "()")
            PoolTabSettle(tab, 800)
            return Map("text", PoolTabSnap(tab, 1500))
        case "reload":
            wv.Reload()
            PoolTabSettle(tab, 800)
            return Map("text", PoolTabSnap(tab, 1500))
        case "snapshot":
            n := args.Get("textChars", 4000)
            return Map("text", PoolTabSnap(tab, IsInteger(n) ? Max(0, Min(30000, Integer(n))) : 3000, false))
        case "click", "hover":
            p := PoolTabPoint(tab, args)
            btn := StrLower(args.Get("button", "left"))
            if !(btn = "left" || btn = "right" || btn = "middle")
                throw Error('button must be "left", "right" or "middle"')
            PoolTabMouse(tab, "mouseMoved", p, "none", 0)
            if (op = "click") {
                clicks := (args.Get("double", false) = true || args.Get("double", 0) = 1) ? 2 : 1
                Loop clicks {
                    PoolTabMouse(tab, "mousePressed", p, btn, A_Index)
                    PoolTabMouse(tab, "mouseReleased", p, btn, A_Index)
                }
            }
            PoolTabSettle(tab, 500)
            what := op = "hover" ? "Moved the mouse over" : (btn = "left" ? "" : btn "-") (args.Has("double") && args["double"] ? "double-" : "") "clicked"
            return Map("text", what " " p.what ".`n`n" PoolTabSnap(tab, 800))
        case "drag":
            ; from / to: a ref, or x,y (fromX/fromY, toX/toY). Both brought into view, then the start is read
            ; again (bringing the target into view may have moved it).
            fa := args.Has("from") ? Map("ref", args["from"]) : Map("x", args.Get("fromX", ""), "y", args.Get("fromY", ""))
            ta := args.Has("to") ? Map("ref", args["to"]) : Map("x", args.Get("toX", ""), "y", args.Get("toY", ""))
            PoolTabPoint(tab, fa, "nearest")
            pt := PoolTabPoint(tab, ta, "nearest")
            pf := PoolTabPoint(tab, fa, "none")
            ; items marked draggable use the browser's own drag and drop, which mouse events from the
            ; protocol don't start: those get the drag events directly; everything else a real mouse drag
            how := PoolTabJs(tab, "((fx, fy, tx, ty) => { const s = document.elementFromPoint(fx, fy); const d = s && s.closest('[draggable=`"true`"]');"
                . " if (!d) return 'mouse'; const t = document.elementFromPoint(tx, ty); if (!t) return 'mouse';"
                . " const dt = new DataTransfer(); const ev = (n, el, x, y) => el.dispatchEvent(new DragEvent(n, {bubbles: true, cancelable: true, dataTransfer: dt, clientX: x, clientY: y}));"
                . " ev('dragstart', d, fx, fy); ev('drag', d, fx, fy); ev('dragenter', t, tx, ty); ev('dragover', t, tx, ty); ev('drop', t, tx, ty); ev('dragend', d, tx, ty);"
                . " return 'html5'; })(" pf.x ", " pf.y ", " pt.x ", " pt.y ")")
            if (how != "html5") {
                PoolTabMouse(tab, "mouseMoved", pf, "none", 0)
                PoolTabMouse(tab, "mousePressed", pf, "left", 1)
                n := 12
                Loop n {                                 ; small steps, like a hand (drag libraries need movement)
                    Sleep(15)
                    PoolTabMouse(tab, "mouseMoved", {x: pf.x + (pt.x - pf.x) * A_Index / n, y: pf.y + (pt.y - pf.y) * A_Index / n},
                        "left", 0, 1)
                }
                Sleep(60)
                PoolTabMouse(tab, "mouseReleased", pt, "left", 1)
            }
            PoolTabSettle(tab, 500)
            return Map("text", "Dragged " pf.what " to " pt.what (how = "html5" ? " (as drag-and-drop)" : "") ".`n`n" PoolTabSnap(tab, 800))
        case "type":
            if args.Has("ref") || args.Has("x") {
                p := PoolTabPoint(tab, args)
                PoolTabMouse(tab, "mousePressed", p, "left", 1)
                PoolTabMouse(tab, "mouseReleased", p, "left", 1)
                Sleep(150)
            }
            if (args.Get("clear", true) = true || args.Get("clear", 1) = 1) {
                PoolTabKey(tab, "Ctrl+A")
                PoolTabKey(tab, "Backspace")
            }
            text := String(args.Get("text", ""))
            if (text != "")
                PoolTabCdp(tab, "Input.insertText", Map("text", text))
            if (args.Get("submit", false) = true || args.Get("submit", 0) = 1)
                PoolTabKey(tab, "Enter")
            PoolTabSettle(tab, 500)
            return Map("text", "Typed " StrLen(text) " characters" (args.Get("submit", 0) ? " and pressed Enter" : "") ".`n`n" PoolTabSnap(tab, 800))
        case "key":
            k := Trim(args.Get("key", ""))
            if (k = "")
                throw Error("give the key, e.g. Enter, Tab, Escape, ArrowDown, Ctrl+A")
            PoolTabKey(tab, k)
            PoolTabSettle(tab, 400)
            return Map("text", "Pressed " k ".`n`n" PoolTabSnap(tab, 800))
        case "scroll":
            dir := StrLower(args.Get("direction", "down"))
            amt := args.Get("amount", 600)
            amt := IsInteger(amt) ? Integer(amt) : 600
            dx := dir = "left" ? -amt : dir = "right" ? amt : 0
            dy := dir = "up" ? -amt : dir = "down" ? amt : 0
            if (args.Has("ref") || args.Has("x"))
                p := PoolTabPoint(tab, args)
            else {
                vp := PoolTabJs(tab, "({w: innerWidth, h: innerHeight})")
                p := {x: vp["w"] / 2, y: vp["h"] / 2, what: "the page"}
            }
            PoolTabCdp(tab, "Input.dispatchMouseEvent", Map("type", "mouseWheel", "x", p.x, "y", p.y, "deltaX", dx, "deltaY", dy))
            Sleep(400)
            return Map("text", "Scrolled " dir " " amt " px.`n`n" PoolTabSnap(tab, 800))
        case "select":
            ref := args.Get("ref", "")
            opt := String(args.Get("option", ""))
            r := PoolTabJs(tab, "((ref, want) => { const e = document.querySelector('[data-agt-ref=`"' + ref + '`"]');"
                . " if (!e || e.tagName !== 'SELECT') return 'no dropdown (select) with that ref - take a new snapshot';"
                . " const o = [...e.options].find(o => o.text.trim() === want || o.value === want) || [...e.options].find(o => o.text.trim().toLowerCase().includes(want.toLowerCase()));"
                . " if (!o) return 'no option like that; options: ' + [...e.options].map(o => o.text.trim()).join(' | ');"
                . " e.value = o.value; e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true}));"
                . " return 'ok: ' + o.text.trim(); })(" Json.Stringify(String(ref)) ", " Json.Stringify(opt) ")")
            if (SubStr(r, 1, 3) != "ok:")
                throw Error(r)
            PoolTabSettle(tab, 400)
            return Map("text", "Selected " SubStr(r, 5) ".`n`n" PoolTabSnap(tab, 800))
        case "screenshot":
            vp := PoolTabJs(tab, "({w: innerWidth, h: innerHeight, d: devicePixelRatio})")
            ; scaled so 1 image pixel = 1 page pixel: x/y read off the image work for click
            res := Json.Parse(PoolTabCdp(tab, "Page.captureScreenshot", Map("format", "png",
                "clip", Map("x", 0, "y", 0, "width", vp["w"], "height", vp["h"], "scale", 1 / vp["d"]))))
            DirCreate(APP_IMAGE_INBOX)
            path := APP_IMAGE_INBOX "\tab-" name "-" A_TickCount ".png"
            PoolTabSaveBase64(res["data"], path)
            return Map("text", "Screenshot of the tab (" vp["w"] "x" vp["h"] " page pixels; x/y on it can be clicked).", "image", path)
    }
    throw Error("unknown browser op: " op)
}

; ------------------------------------------------------------------------------
; The tab window
; ------------------------------------------------------------------------------
PoolTabOpen(name, owner) {
    if (env = 0)
        throw Error("the pool's browser engine isn't ready yet - try again in a moment")
    tab := {name: name, owner: owner, gui: 0, ctrl: 0, wv: 0, nav: false, dead: false}
    g := Gui("+Resize +MinSize400x300", "Agent browser (Caption Companion)")
    tab.gui := g
    g.OnEvent("Size", PoolTabSized.Bind(tab))
    g.OnEvent("Close", (*) => PoolTabClose(name))
    sec := "Window tab-" name
    x := IniRead(POOL_INI, sec, "X", ""), y := IniRead(POOL_INI, sec, "Y", "")
    w := IniRead(POOL_INI, sec, "W", 1200), h := IniRead(POOL_INI, sec, "H", 850)
    if !(IsInteger(w) && IsInteger(h) && w >= 500 && h >= 400)
        w := 1200, h := 850
    pos := (IsInteger(x) && IsInteger(y) && PoolOnScreen(x, y)) ? "x" x " y" y " " : ""
    g.Show(pos "w" w " h" h " NoActivate")
    try {
        tab.ctrl := env.CreateCoreWebView2ControllerAsync(g.Hwnd).await(30000)
        tab.ctrl.IsVisible := true
        tab.wv := tab.ctrl.CoreWebView2
        try tab.wv.Settings.AreDefaultScriptDialogsEnabled := false
        try tab.wv.Settings.AreDevToolsEnabled := POOL_DEV
        ; acts as focused even when its window isn't (typing and clicks without stealing your focus)
        try tab.wv.CallDevToolsProtocolMethodAsync("Emulation.setFocusEmulationEnabled", '{"enabled":true}').await(5000)
        tab.wv.add_NavigationStarting(PoolTabNavStarting.Bind(tab))
        tab.wv.add_NavigationCompleted(PoolTabNavDone.Bind(tab))
        tab.wv.add_NewWindowRequested(PoolTabPopup.Bind(tab))
        tab.wv.add_ProcessFailed((*) => (tab.dead := true))
        tab.ctrl.Fill()
    } catch as err {
        try tab.ctrl.Close()
        try g.Destroy()
        throw Error("couldn't open a browser tab: " err.Message)
    }
    poolTabs[name] := tab
    PoolLog("tab " name " opened")
    return tab
}

PoolTabSized(tab, g, minMax, *) {
    if (minMax != -1 && IsObject(tab.ctrl))
        try tab.ctrl.Fill()
}

PoolTabClose(name) {
    if !poolTabs.Has(name)
        return
    tab := poolTabs[name]
    poolTabs.Delete(name)
    try {
        if (WinGetMinMax("ahk_id " tab.gui.Hwnd) = 0) {
            tab.gui.GetPos(&x, &y)
            tab.gui.GetClientPos(, , &w, &h)
            sec := "Window tab-" name
            IniWrite(x, POOL_INI, sec, "X"), IniWrite(y, POOL_INI, sec, "Y")
            IniWrite(w, POOL_INI, sec, "W"), IniWrite(h, POOL_INI, sec, "H")   ; (already in DPI-scaled units)
        }
    }
    tab.dead := true
    try tab.ctrl.Close()
    try tab.gui.Destroy()
    PoolLog("tab " name " closed")
}

PoolTabCloseAll() {
    for name in poolTabs.Clone()
        PoolTabClose(name)
}

; the owning app is gone: its tab goes too
PoolTabWatch() {
    for name, tab in poolTabs.Clone()
        if (tab.dead || !DllCall("IsWindow", "Ptr", tab.owner))
            PoolTabClose(name)
}

PoolTabNavStarting(tab, sender, args) {
    try {
        if !RegExMatch(args.Uri, "i)^(https://|about:blank)") {
            args.Cancel := true
            return
        }
        tab.nav := true
    }
}

PoolTabNavDone(tab, sender, args) {
    tab.nav := false
    try tab.gui.Title := "Agent browser - " sender.DocumentTitle " (Caption Companion)"
}

PoolTabPopup(tab, sender, args) {
    uri := ""
    try uri := args.Uri
    try args.Handled := true
    if RegExMatch(uri, "i)^https://")
        SetTimer(() => tab.wv.Navigate(uri), -1)
}

PoolTabUrl(url) {
    if RegExMatch(url, "i)^https://")
        return url
    if RegExMatch(url, "i)^\w+:")
        throw Error("only https:// addresses can be opened")
    return "https://" url
}

; waits for a page load the action started (if any), then a moment for the page to update
PoolTabSettle(tab, ms) {
    Sleep(ms)
    t := A_TickCount
    while (tab.nav && A_TickCount - t < 20000)
        Sleep(100)
    t := A_TickCount
    while (A_TickCount - t < 5000) {
        try {
            if (PoolTabJs(tab, "document.readyState") = "complete")
                break
        }
        Sleep(200)
    }
}

; ------------------------------------------------------------------------------
; Page access: script, DevTools protocol (in-process; no debugging port), input
; ------------------------------------------------------------------------------
PoolTabJs(tab, js) {
    raw := tab.wv.ExecuteScriptAsync(js).await(10000)
    return (raw = "" || raw = "null") ? "" : Json.Parse(raw)
}

PoolTabCdp(tab, method, params) {
    return tab.wv.CallDevToolsProtocolMethodAsync(method, Json.Stringify(params)).await(10000)
}

PoolTabMouse(tab, type, p, button, clicks, held := 0) {   ; held: buttons kept down while moving (drag)
    bits := Map("none", 0, "left", 1, "right", 2, "middle", 4)
    PoolTabCdp(tab, "Input.dispatchMouseEvent", Map("type", type, "x", p.x, "y", p.y, "button", button,
        "buttons", type = "mousePressed" ? bits[button] : held, "clickCount", clicks))
}

; {ref} -> the middle of that element (scrolled into view), or {x, y} as given (page pixels)
PoolTabPoint(tab, args, scroll := "center") {   ; scroll: center | nearest | none
    if args.Has("ref") {
        ref := String(args["ref"])
        r := PoolTabJs(tab, "((ref, sc) => { const e = document.querySelector('[data-agt-ref=`"' + ref + '`"]'); if (!e) return null;"
            . " if (sc !== 'none') e.scrollIntoView({block: sc, inline: sc, behavior: 'instant'}); const r = e.getBoundingClientRect();"
            . " const x = r.left + r.width / 2, y = r.top + r.height / 2; const top = document.elementFromPoint(x, y);"
            . " const lab = (e.getAttribute('aria-label') || e.innerText || e.value || e.getAttribute('title') || e.tagName).replace(/\s+/g, ' ').trim().slice(0, 60);"
            . " return {x, y, lab, covered: !!top && top !== e && !e.contains(top) && !top.contains(e)}; })(" Json.Stringify(ref) ", " Json.Stringify(scroll) ")")
        if !(r is Map)
            throw Error("no element [" ref "] on the page now - take a new snapshot (refs change when the page changes)")
        return {x: r["x"], y: r["y"], what: "[" ref "] `"" r["lab"] "`"" (r["covered"] ? " (something was on top of it - check it worked)" : "")}
    }
    if (args.Has("x") && args.Has("y") && IsNumber(args["x"]) && IsNumber(args["y"]))
        return {x: args["x"] + 0, y: args["y"] + 0, what: "the point " args["x"] "," args["y"]}
    throw Error("give ref (from the snapshot) or x and y")
}

; "Enter", "Tab", "Escape", "ArrowDown", "Ctrl+A", "Shift+Tab", "a" ...
PoolTabKey(tab, combo) {
    static named := Map("enter", [13, "Enter", "`r"], "tab", [9, "Tab", ""], "escape", [27, "Escape", ""], "esc", [27, "Escape", ""],
        "backspace", [8, "Backspace", ""], "delete", [46, "Delete", ""], "space", [32, " ", " "],
        "arrowup", [38, "ArrowUp", ""], "arrowdown", [40, "ArrowDown", ""], "arrowleft", [37, "ArrowLeft", ""],
        "arrowright", [39, "ArrowRight", ""], "up", [38, "ArrowUp", ""], "down", [40, "ArrowDown", ""],
        "left", [37, "ArrowLeft", ""], "right", [39, "ArrowRight", ""], "home", [36, "Home", ""], "end", [35, "End", ""],
        "pageup", [33, "PageUp", ""], "pagedown", [34, "PageDown", ""], "f5", [116, "F5", ""])
    parts := StrSplit(combo, "+")
    k := Trim(parts.Pop())
    mods := 0
    for p in parts
        switch StrLower(Trim(p)) {
            case "alt": mods |= 1
            case "ctrl", "control": mods |= 2
            case "meta", "win": mods |= 4
            case "shift": mods |= 8
            default: throw Error("unknown modifier " p " (use Ctrl, Alt, Shift)")
        }
    if named.Has(StrLower(k)) {
        d := named[StrLower(k)]
        vk := d[1], key := d[2], text := d[3]
    } else if (StrLen(k) = 1) {
        vk := Ord(StrUpper(k)), key := k, text := k
    } else {
        throw Error("unknown key " k)
    }
    if (mods & 7)                                ; with Ctrl/Alt: a shortcut, no typed character
        text := ""
    code := StrLen(key) = 1 ? (IsDigit(key) ? "Digit" key : "Key" StrUpper(key)) : key
    down := Map("type", text != "" ? "keyDown" : "rawKeyDown", "key", key, "code", code,
        "windowsVirtualKeyCode", vk, "nativeVirtualKeyCode", vk, "modifiers", mods)
    if (text != "")
        down["text"] := text, down["unmodifiedText"] := text
    if (StrLower(k) = "a" && mods = 2)
        down["commands"] := ["selectAll"]        ; Chromium needs the command for Ctrl+A from the protocol
    PoolTabCdp(tab, "Input.dispatchKeyEvent", down)
    PoolTabCdp(tab, "Input.dispatchKeyEvent", Map("type", "keyUp", "key", key, "code", code,
        "windowsVirtualKeyCode", vk, "nativeVirtualKeyCode", vk, "modifiers", mods))
}

; What the AI sees: title, address, the things it can use (numbered refs), then the page's text
PoolTabSnap(tab, textChars, brief := true) {   ; brief: after an action - only what is on screen, short
    static js := "
    (
    ((maxText, maxItems, onlyView) => {
      document.querySelectorAll('[data-agt-ref]').forEach(e => e.removeAttribute('data-agt-ref'));
      const sel = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=combobox],[role=textbox],[role=switch],[role=treeitem],[contenteditable=""],[contenteditable=true],[onclick],[draggable=true]';
      const clean = s => (s || '').replace(/\s+/g, ' ').trim();
      const label = e => clean(e.getAttribute('aria-label') || (e.labels && e.labels[0] && e.labels[0].innerText) || e.getAttribute('placeholder')
        || e.getAttribute('title') || (e.tagName !== 'SELECT' && e.innerText) || (e.type !== 'password' ? e.value : '') || e.getAttribute('alt') || e.getAttribute('name') || '').slice(0, 80);
      const out = []; let n = 0, skipped = 0;
      for (const e of document.querySelectorAll(sel)) {
        const r = e.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) continue;
        const s = getComputedStyle(e);
        if (s.visibility === 'hidden' || s.display === 'none' || s.opacity === '0') continue;
        const off = r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth;
        if ((onlyView && off) || n >= maxItems) { skipped++; continue; }
        n++;
        e.setAttribute('data-agt-ref', n);
        const tag = e.tagName.toLowerCase();
        let role = e.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? 'input-' + (e.type || 'text') : tag);
        let extra = '';
        if (tag === 'input' || tag === 'textarea') {
          if (e.type === 'checkbox' || e.type === 'radio') extra = e.checked ? ' [checked]' : ' [not checked]';
          else if (e.type === 'password') extra = e.value ? ' (has a password)' : ' (empty)';
          else extra = ' value="' + clean(e.value).slice(0, 60) + '"';
        }
        if (tag === 'select') extra = ' selected="' + clean(e.selectedOptions[0] && e.selectedOptions[0].text) + '" options: '
          + [...e.options].slice(0, 20).map(o => clean(o.text)).join(' | ');
        if (e.getAttribute('aria-expanded')) extra += ' [expanded=' + e.getAttribute('aria-expanded') + ']';
        if (e.disabled || e.getAttribute('aria-disabled') === 'true') extra += ' [disabled]';
        if (off) extra += ' [off-screen]';
        out.push('[' + n + '] ' + role + ' "' + label(e) + '"' + extra);
      }
      const text = (document.body ? document.body.innerText : '').replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim();
      const max = Math.max(0, document.documentElement.scrollHeight - innerHeight);
      return 'Title: ' + document.title + '\nAddress: ' + location.href + '\nScrolled: ' + Math.round(scrollY) + ' of ' + max + ' px'
        + (document.querySelector('iframe') ? '\n(The page has frames: things inside them are not listed - use a screenshot and x/y.)' : '')
        + '\n\nThings you can use ([ref] kind "label"):\n' + (out.length ? out.join('\n') : '(none)')
        + (skipped ? '\n(+' + skipped + (onlyView ? ' more off-screen or not listed: scroll, or browser_snapshot for the full list)' : ' more not listed)') : '')
        + (maxText > 0 ? '\n\nPage text' + (text.length > maxText ? ' (first ' + maxText + ' of ' + text.length + ' characters)' : '') + ':\n' + text.slice(0, maxText) : '');
    })
    )"
    try {
        return PoolTabJs(tab, js "(" textChars (brief ? ", 60, true)" : ", 200, false)"))
    } catch as err {
        return "(couldn't read the page: " err.Message ")"
    }
}

PoolTabSaveBase64(b64, path) {
    DllCall("crypt32\CryptStringToBinaryW", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &size := 0, "Ptr", 0, "Ptr", 0)
    if !size
        throw Error("the screenshot came back empty")
    buf := Buffer(size)
    DllCall("crypt32\CryptStringToBinaryW", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", buf, "UInt*", &size, "Ptr", 0, "Ptr", 0)
    f := FileOpen(path, "w")
    f.RawWrite(buf, size)
    f.Close()
}
