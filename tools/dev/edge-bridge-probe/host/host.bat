@echo off
rem Started BY Edge/Chrome (native messaging). stdin/stdout are the browser's pipe: print nothing here.
"%~dp0..\..\..\..\runtime\AutoHotkey32.exe" "%~dp0host.ahk" %*
