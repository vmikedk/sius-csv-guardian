@echo off
rem Same as Run-SIUS-CSV-Guardian.cmd, but sets aside rows with shooter number 0
rem (saved to <name>.skipped.csv next to the repaired copy; never reassigned).
call "%~dp0Run-SIUS-CSV-Guardian.cmd" -ExcludePlayerZero
exit /b %ERRORLEVEL%
