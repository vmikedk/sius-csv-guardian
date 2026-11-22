@echo off
setlocal
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SIUS-CSV-Guardian.ps1"
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" echo Review the report before uploading to SPConnector.
pause
exit /b %exitCode%

