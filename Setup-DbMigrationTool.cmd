@echo off
setlocal
set "APPROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APPROOT%Setup-DbMigrationTool.ps1" %*
exit /b %ERRORLEVEL%