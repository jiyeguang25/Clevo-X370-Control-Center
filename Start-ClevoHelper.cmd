@echo off
rem ClevoHelper - control panel launcher. No admin required.
rem
rem Prefers the packaged single-file exe (dist\ClevoHelper.exe): it carries every script and
rem its own copy of InsydeDCHU.dll, unpacks them under %LOCALAPPDATA%\ClevoHelper\app and
rem starts the panel detached. Falls back to running the script directly in dev mode.
setlocal
set "EXE=%~dp0dist\ClevoHelper.exe"
if exist "%EXE%" (
    start "" "%EXE%"
    exit /b 0
)
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\ClevoHelper.ps1"
