# app\lib - third-party code (kept unmodified)

| File | From | Version | License |
|---|---|---|---|
| `WebView2\WebView2.ahk` | thqby/ahk2_lib on GitHub (`WebView2/WebView2.ahk`) | 2.0.5, repo commit of 2026-01-21 | MIT (`LICENSE-thqby-ahk2_lib.txt`) |
| `Promise.ahk`, `ComVar.ahk` | thqby/ahk2_lib (needed by WebView2.ahk via `#Include ..\`) | same commit | MIT |
| `WebView2\32bit\WebView2Loader.dll` | Microsoft NuGet package `Microsoft.Web.WebView2` 1.0.4314.35, `build\native\x86` | 1.0.4314.35, signed by Microsoft | `WebView2\LICENSE-Microsoft-WebView2.txt` |
| `WebView2\64bit\WebView2Loader.dll` | same package, `build\native\x64` | same | same |

- WebView2.ahk picks `32bit\` or `64bit\` by itself (from `A_PtrSize`), so the 32-bit
  `runtime\AutoHotkey32.exe` works with it.
- It needs the **Microsoft Edge WebView2 Runtime**, which is part of Windows 11.
- Always pass our own user-data folder (under `DATA_DIR`) when creating a WebView. If it is
  left empty, WebView2.ahk falls back to the real Edge profile folder - never do that.
- To update: replace the files from the same sources, update the table, and test in 32-bit.
