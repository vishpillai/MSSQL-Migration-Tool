@echo off
setlocal
set "APPROOT=%~dp0"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%POWERSHELL%" (
    echo ERROR: Windows PowerShell could not be found at "%POWERSHELL%".
    exit /b 9009
)
if not exist "%APPROOT%Setup-DbMigrationTool.ps1" (
    echo ERROR: Setup-DbMigrationTool.ps1 was not found in "%APPROOT%".
    exit /b 2
)

"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APPROOT%Setup-DbMigrationTool.ps1" %*
set "SETUP_EXIT_CODE=%ERRORLEVEL%"
exit /b %SETUP_EXIT_CODE%