@echo off
setlocal
rem Extra options are passed through, e.g.  Run-SIUS-CSV-Guardian.cmd -ExcludePlayerZero
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SIUS-CSV-Guardian.ps1" %*
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" echo Review the report before uploading to SPConnector.
echo The repaired copy is in the "Upload" folder next to the selected file. The original is not changed.
pause
exit /b %exitCode%
