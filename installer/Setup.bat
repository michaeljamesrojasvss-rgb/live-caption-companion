@echo off
rem Live Caption Companion - installer. Double-click this after extracting the zip.
setlocal
set "HERE=%~dp0"
if not exist "%HERE%runtime\AutoHotkey32.exe" goto notExtracted
if not exist "%HERE%installer\setup.ahk" goto notExtracted
start "" "%HERE%runtime\AutoHotkey32.exe" "%HERE%installer\setup.ahk"
exit /b 0

:notExtracted
echo.
echo   Setup can't find its files.
echo.
echo   Extract the whole zip first: right-click the zip ^> Extract All,
echo   then open the extracted folder and double-click Setup.bat there.
echo.
pause
exit /b 1
