@echo off
rem Live Caption Companion - uninstaller. Double-click it.
rem   Uninstall.bat                    asks first, then removes the app
rem   Uninstall.bat /silent            no windows; also deletes call history, helpers and settings
rem   Uninstall.bat /silent /keepdata  no windows; keeps call history, helpers and settings
rem It needs uninstall.ahk next to it (or in an "installer" folder next to it). The AutoHotkey that
rem the app installed is used, so these two files can be copied alone to any PC that has the app.
setlocal
set "HERE=%~dp0"
set "SCRIPT="
if exist "%HERE%installer\uninstall.ahk" set "SCRIPT=%HERE%installer\uninstall.ahk"
if not defined SCRIPT if exist "%HERE%uninstall.ahk" set "SCRIPT=%HERE%uninstall.ahk"
if not defined SCRIPT goto noScript

set "AHK="
for %%R in ("%LOCALAPPDATA%\CaptionCompanion" "%USERPROFILE%\CaptionCompanion" "%HERE%" "%HERE%..") do if not defined AHK if exist "%%~R\runtime\AutoHotkey32.exe" set "AHK=%%~R\runtime\AutoHotkey32.exe"
if not defined AHK goto noAhk

rem Run from a temp copy, so the install folder (which holds its own AutoHotkey) can be deleted
set "T=%TEMP%\CaptionCompanion-uninstall-%RANDOM%"
mkdir "%T%" >nul 2>&1
copy /y "%AHK%" "%T%\AutoHotkey32.exe" >nul 2>&1
copy /y "%SCRIPT%" "%T%\uninstall.ahk" >nul 2>&1
if not exist "%T%\AutoHotkey32.exe" goto copyFailed
if not exist "%T%\uninstall.ahk" goto copyFailed
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%T%\AutoHotkey32.exe'" >nul 2>&1

start "" /wait "%T%\AutoHotkey32.exe" "%T%\uninstall.ahk" %*
set "CODE=%ERRORLEVEL%"
rd /s /q "%T%" >nul 2>&1
exit /b %CODE%

:noScript
echo.
echo   Can't find uninstall.ahk. Keep it in the same folder as Uninstall.bat
echo   (or in a folder called "installer" next to it), then run this again.
echo.
goto fail

:noAhk
echo.
echo   Can't find AutoHotkey32.exe. It is normally in the app's "runtime" folder:
echo     %LOCALAPPDATA%\CaptionCompanion\runtime
echo   If the app was installed to a folder of your own, copy that "runtime" folder
echo   next to this Uninstall.bat and run it again.
echo.
goto fail

:copyFailed
echo.
echo   Couldn't copy the uninstaller to %TEMP%. Check there is free space and try again.
echo.
goto fail

:fail
if /i not "%~1"=="/silent" pause
exit /b 1
