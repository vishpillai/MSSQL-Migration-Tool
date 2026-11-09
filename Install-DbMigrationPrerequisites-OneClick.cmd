@echo off
REM ============================================================================
REM  Db Migration Tool - one-click prerequisite installer (per-user, no admin)
REM
REM  Double-click to run. Installs, only when missing:
REM    - PowerShell 7.2+   (winget if available, otherwise official ZIP)
REM    - dbatools module   (PowerShell Gallery, CurrentUser scope)
REM    - Pester 5 module   (PowerShell Gallery, CurrentUser scope)
REM
REM  Requires internet access to github.com and powershellgallery.com.
REM  Nothing is installed system-wide; no elevation prompt.
REM ============================================================================
setlocal
title Db Migration Tool - Prerequisite Setup

set "PW7_DIR=%LOCALAPPDATA%\Pwsh7"
set "PW7_ZIP=%TEMP%\pwsh-win-x64.zip"
REM Update this URL to move to a newer PowerShell release.
set "PW7_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.zip"

echo ============================================================
echo   Db Migration Tool - prerequisite installer
echo ============================================================
echo.

REM ---------------------------------------------------------------- 1. pwsh --
set "PWSH="
pwsh.exe -v >nul 2>&1 && set "PWSH=pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe"        set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if not defined PWSH if exist "%PW7_DIR%\pwsh.exe"                          set "PWSH=%PW7_DIR%\pwsh.exe"

if defined PWSH (
    "%PWSH%" -NoProfile -NonInteractive -Command "if ($PSVersionTable.PSVersion -ge [Version]'7.2') { exit 0 } else { exit 1 }"
    if not errorlevel 1 goto :pwsh_ok
    echo Existing PowerShell 7 is older than 7.2 - updating...
    set "PWSH="
)

echo PowerShell 7.2+ not found - installing...
where winget.exe >nul 2>&1
if %errorlevel%==0 (
    echo Trying winget ^(per-user install^)...
    winget.exe install --id Microsoft.PowerShell --exact --scope user --silent --accept-package-agreements --accept-source-agreements --force
    pwsh.exe -v >nul 2>&1 && set "PWSH=pwsh.exe"
    if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
)

if not defined PWSH (
    echo winget unavailable or failed - downloading PowerShell 7 ZIP...
    curl.exe --ssl-no-revoke -L -sS -o "%PW7_ZIP%" "%PW7_URL%"
    if errorlevel 1 curl.exe -L -sS -o "%PW7_ZIP%" "%PW7_URL%"
    if errorlevel 1 (
        echo ERROR: could not download PowerShell 7 from %PW7_URL%
        goto :fail
    )
    if not exist "%PW7_DIR%" mkdir "%PW7_DIR%"
    tar -xf "%PW7_ZIP%" -C "%PW7_DIR%"
    if errorlevel 1 (
        echo ERROR: could not extract %PW7_ZIP%
        goto :fail
    )
    set "PWSH=%PW7_DIR%\pwsh.exe"
    echo Adding %PW7_DIR% to your user PATH...
    powershell.exe -NoProfile -NonInteractive -Command "$p=[Environment]::GetEnvironmentVariable('Path','User'); if ($p -notlike '*Pwsh7*') { [Environment]::SetEnvironmentVariable('Path', $env:LOCALAPPDATA + '\Pwsh7;' + $p, 'User') }"
)

:pwsh_ok
echo Using PowerShell: %PWSH%
echo.

REM ------------------------------------------------- 2. dbatools and Pester --
echo Checking dbatools and Pester modules ^(downloads only what is missing^)...
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -NonInteractive -Command "$ErrorActionPreference='Stop'; try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted } catch {}; if (-not (Get-Module -ListAvailable dbatools)) { Write-Host 'Installing dbatools (large download, please wait)...'; Install-Module dbatools -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck }; if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [Version]'5.0' })) { Write-Host 'Installing Pester 5...'; Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MaximumVersion 5.99.99 }; Write-Host ''; Write-Host '---- installed prerequisite versions ----'; Write-Host ('PowerShell : ' + $PSVersionTable.PSVersion); Write-Host ('dbatools   : ' + (Get-Module -ListAvailable dbatools | Sort-Object Version -Descending | Select-Object -First 1).Version); Write-Host ('Pester     : ' + (Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version)"
if errorlevel 1 goto :fail

echo.
echo SUCCESS - all prerequisites are installed for the current user.
echo Next: run Setup-DbMigrationTool.cmd, then validate with:
echo   pwsh -Command "Invoke-Pester .\tests"
echo.
pause
exit /b 0

:fail
echo.
echo FAILED - see the message above, fix the issue, and run this file again.
pause
exit /b 1
