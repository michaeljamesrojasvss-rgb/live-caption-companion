#Requires AutoHotkey v2.0
#SingleInstance Force
; ==============================================================================
; net-check.ahk  -  can this PC reach what automatic updates and the shared
; helpers folder need?
;
; Uses AutoHotkey's Download(), the same call the updater uses, so the result
; matches what the app will really get (proxy settings and all).
;
; Run on a work PC:   runtime\AutoHotkey32.exe tools\dev\net-check.ahk
; It shows the result and copies it to the clipboard - paste it back to Claude.
; A blocked site can take a while to time out, so give it a minute.
; ==============================================================================

OWNER_REPO := "michaeljamesrojasvss-rgb/live-caption-companion"
FOLDER_ID  := "1kmcBPxqwzidrPOgHAykkSLYStPIAwMaI"
MANIFEST_ID := "1Mj4EqHN2YA6qtLmU9gk3vqUHL6tEG6Me"      ; today's Drive version.json

; [name, url, kind]   kind: "text" shows a preview, "bin" doesn't, "folder" counts entries
tests := [
    ["GitHub website", "https://github.com/" OWNER_REPO, "text"],
    ["GitHub raw files (raw.githubusercontent.com)", "https://raw.githubusercontent.com/" OWNER_REPO "/main/README.md", "text"],
    ["GitHub API (finds a real release file to test)", "https://api.github.com/repos/AutoHotkey/AutoHotkey/releases/latest", "api"],
    ["Release file download (the host real releases come from)", "", "bin"],
    ["Your release link (404 is normal until the first release)", "https://github.com/" OWNER_REPO "/releases/latest/download/version.json", "text"],
    ["Drive file download (what the updater uses today)", "https://drive.google.com/uc?export=download&id=" MANIFEST_ID, "text"],
    ["Drive shared folder listing", "https://drive.google.com/embeddedfolderview?id=" FOLDER_ID, "folder"],
]

report := "Network check " FormatTime(, "yyyy-MM-dd HH:mm") "`n"
    . "AutoHotkey " A_AhkVersion "  |  " A_ComputerName "`n`n"
releaseAsset := ""

for i, t in tests {
    name := t[1], url := t[2], kind := t[3]
    ToolTip("Testing " i " of " tests.Length ": " name)

    if (kind = "bin" && url = "")
        url := releaseAsset
    if (url = "") {
        report .= "SKIPPED  " name "`n         (needs the GitHub API test to work first)`n`n"
        continue
    }

    tmp := A_Temp "\netcheck-" i ".tmp"
    try FileDelete(tmp)
    started := A_TickCount
    try {
        Download(url, tmp)
        ms := A_TickCount - started
        size := FileGetSize(tmp)
        line := "OK       " name "`n         " size " bytes in " ms " ms"
        if (kind = "api") {
            body := FileRead(tmp, "UTF-8")
            if RegExMatch(body, '"browser_download_url"\s*:\s*"([^"]+\.zip)"', &m)
                releaseAsset := m[1]
            else
                line .= "`n         (no .zip file found in the answer, so the release-file test is skipped)"
        } else if (kind = "text") {
            line .= "`n         starts with: " Preview(FileRead(tmp, "UTF-8"))
        } else if (kind = "folder") {
            body := FileRead(tmp, "UTF-8")
            n := 0, pos := 1
            while (pos := RegExMatch(body, 'id="entry-([^"]+)"', &m, pos)) {
                n += 1
                pos += StrLen(m[0])
            }
            line .= "`n         file entries found in the folder page: " n
            if (n = 0)
                line .= "  (page loaded but no entries - empty folder, or Google changed the page)"
        }
        report .= line "`n`n"
    } catch as err {
        report .= "FAILED   " name "`n         " url "`n         " err.Message "  (after " (A_TickCount - started) " ms)`n`n"
    }
    try FileDelete(tmp)
}

ToolTip()
A_Clipboard := report
MsgBox(report "(copied to the clipboard)", "Network check", "Iconi")
ExitApp

Preview(text) {
    text := RegExReplace(SubStr(text, 1, 80), "\s+", " ")
    return '"' text '"'
}
