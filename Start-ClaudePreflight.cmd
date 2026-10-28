@echo off
start "" /b powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0windows\local\ClaudeLocalUI.ps1"
