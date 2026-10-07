@echo off
rem DanmakuFactory parameter GUI launcher
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DanmakuFactoryGUI.ps1"
