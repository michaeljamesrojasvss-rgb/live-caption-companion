# Edge bridge probe (dev only, not shipped)

Can the Copilot pool (and later the Agent) use **your own Edge** - your sign-ins, sessions, history -
instead of its built-in browser? This probe checks it, especially on the **work PC**. Plan and
decisions: `docs\COPILOT-POOL.md` > "Your own Edge instead of the built-in browser".

## Steps (about 5 minutes)

1. From the repo folder run:
   `runtime\AutoHotkey32.exe tools\dev\edge-bridge-probe\edge-bridge-probe.ahk`
   The top box shows the company policies that could block this. Click **Copy policy report** and keep it.
2. Click **1a. Open edge://extensions**. Switch on **Developer mode**. Click **Load unpacked** and paste the
   folder path that **1b** copies (`tools\dev\edge-bridge-probe\extension`).
   - If Developer mode or Load unpacked is missing/greyed out: the work PC blocks it - stop here and send the
     policy report.
3. Copy the extension's **ID** (32 letters under its name), click **2. Register the bridge...**, paste it.
   (Writes only to your own user's registry, no admin.)
4. In Edge, pin the extension (puzzle-piece icon) and click it. The **probe window** opens:
   - it measures the round trip by itself,
   - click **Copilot: background tab**, wait ~15 s, then **Copilot: visible tab**, wait ~15 s.
   - If nothing opens and the icon shows a red **ERR**: native messaging is blocked or the ID was wrong
     (redo step 3). edge://extensions > the extension > "service worker" shows the reason.
5. Click **Copy report** and paste it, together with the policy report, to Claude:
   "Here's the Edge bridge probe report from the <home/work> PC".
   (Also saved in `tools\dev\edge-bridge-probe\probe-report.txt`.)

The probe only reads pages (title, address, is there a message box, is the page visible). It never types or
sends anything to Copilot. To undo: **Remove the registration** in the setup window, and Remove the
extension in edge://extensions.

## What the answers decide

- Policies / Developer mode / native messaging allowed on the work PC -> build the real bridge
  (Settings > Copilot switch: built-in browser / my Edge). Blocked -> ask IT, or stay with the built-in browser.
- Copilot ready in a **background** tab -> pool tabs can stay out of sight; if not, they need small windows.
