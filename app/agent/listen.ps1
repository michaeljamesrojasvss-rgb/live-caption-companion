# listen.ps1 - used by the agent's "listen" tool (agent-voice.ahk). Listens on the default microphone with
# Windows' own speech recognizer (System.Speech, offline) and appends each phrase heard to $Out (UTF-8).
# Writes "$Out.done" when it ends by itself, or "$Out.err" with the reason when it can't listen.
param([string]$Out, [int]$MaxSec = 30, [double]$FirstSilenceSec = 8, [double]$NextSilenceSec = 2.5,
      [double]$EndSilenceSec = 1.0)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
try {
    Add-Type -AssemblyName System.Speech
    $all = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
    $info = $all | Where-Object { $_.Culture.Name -eq [Globalization.CultureInfo]::CurrentUICulture.Name } | Select-Object -First 1
    if (-not $info) { $info = $all | Where-Object { $_.Culture.Name -like 'en-*' } | Select-Object -First 1 }
    if (-not $info) { throw "no English speech recognizer is installed on this PC (Settings > Time & language > Speech)" }
    $e = New-Object System.Speech.Recognition.SpeechRecognitionEngine($info)
    $e.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
    $e.SetInputToDefaultAudioDevice()
    $e.EndSilenceTimeout = [TimeSpan]::FromSeconds($EndSilenceSec)
    $e.InitialSilenceTimeout = [TimeSpan]::FromSeconds($FirstSilenceSec)
    [IO.File]::WriteAllText($Out, "", $utf8)
    $end = (Get-Date).AddSeconds($MaxSec)
    while ((Get-Date) -lt $end) {
        $r = $e.Recognize()
        if (-not $r) { break }                      # silence: the answer is over
        [IO.File]::AppendAllText($Out, $r.Text + " ", $utf8)
        $e.InitialSilenceTimeout = [TimeSpan]::FromSeconds($NextSilenceSec)
    }
    [IO.File]::WriteAllText("$Out.done", "done", $utf8)
} catch {
    [IO.File]::WriteAllText("$Out.err", $_.Exception.Message, $utf8)
}
