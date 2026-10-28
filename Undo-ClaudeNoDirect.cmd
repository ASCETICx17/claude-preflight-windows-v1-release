@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\direct\Invoke-Admin.ps1" -Action Remove
