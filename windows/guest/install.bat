@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\Install.ps1
exit /b %ERRORLEVEL%
