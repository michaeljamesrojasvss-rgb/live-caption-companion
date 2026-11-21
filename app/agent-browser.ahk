; ==============================================================================
; agent-browser.ahk  -  the agent's browser tools (app\agent\tools\browser.json)
;
; * The tab lives in the Copilot pool (copilot-pool-browser.ahk): the agent sends {t:"tab", op, args}
;   and waits for {t:"tab-done"} (AgtHandle stores it in agtTabReplies). One tab, named "agent";
;   it closes when this app ends (owner = agtMain).
; * Page text is task content: nothing is logged here.
; Needs agent.ahk (agtMain, AgtPoolContact, AgtSendTo, AgtStartPool, POOL_WIN, POOL_TAG).
; ==============================================================================
agtTabReplies := Map()
agtTabSeq := 0

AgtT_BrowserOpen(args, ctx) => AgtBrowser("open", args, ctx)
AgtT_BrowserNavigate(args, ctx) => AgtBrowser("navigate", args, ctx)
AgtT_BrowserSnapshot(args, ctx) => AgtBrowser("snapshot", args, ctx)
AgtT_BrowserScreenshot(args, ctx) => AgtBrowser("screenshot", args, ctx)
AgtT_BrowserClick(args, ctx) => AgtBrowser("click", args, ctx)
AgtT_BrowserHover(args, ctx) => AgtBrowser("hover", args, ctx)
AgtT_BrowserDrag(args, ctx) => AgtBrowser("drag", args, ctx)
AgtT_BrowserType(args, ctx) => AgtBrowser("type", args, ctx)
AgtT_BrowserKey(args, ctx) => AgtBrowser("key", args, ctx)
AgtT_BrowserSelect(args, ctx) => AgtBrowser("select", args, ctx)
AgtT_BrowserScroll(args, ctx) => AgtBrowser("scroll", args, ctx)
AgtT_BrowserClose(args, ctx) => AgtBrowser("close", args, ctx)
AgtT_BrowserBack(args, ctx) => AgtBrowser(StrLower(args.Get("direction", "back")) = "forward" ? "forward" : "back", args, ctx)

AgtBrowser(op, args, ctx) {
    global agtTabSeq
    t0 := A_TickCount
    loop {                                       ; the pool may still be starting
        if !(hwnd := WinExist(POOL_WIN)) {
            AgtStartPool()
            if (A_TickCount - t0 > 45000)
                throw Error("the Copilot pool (which hosts the browser tab) didn't start")
            Sleep(500)
            continue
        }
        agtTabSeq += 1
        id := "tab-" ctx.runId "-" agtTabSeq
        m := Map("t", "tab", "id", id, "hwnd", AgtPoolContact(), "owner", agtMain.Hwnd, "tab", "agent",
            "op", op, "args", args)
        if !AgtSendTo(hwnd, POOL_TAG, m)
            throw Error("couldn't reach the Copilot pool")
        sent := A_TickCount
        while !agtTabReplies.Has(id) {
            Sleep(100)
            AgtPoolContact()                     ; keep the reply window alive
            if AgtVoiceStopped(ctx)
                return Map("text", "Stopped.")
            if (A_TickCount - sent > 90000)
                throw Error("the browser tab didn't answer in 90 s")
        }
        res := agtTabReplies.Delete(id)
        if (!res.Get("ok", 0) && InStr(res.Get("error", ""), "isn't ready yet") && A_TickCount - t0 < 45000) {
            Sleep(2000)
            continue
        }
        break
    }
    if !res.Get("ok", 0)
        throw Error(res.Get("error", "the browser tab failed"))
    out := Map("text", res.Get("text", ""))
    if (res.Get("image", "") != "" && FileExist(res["image"]))
        out["images"] := [res["image"]]
    return out
}
