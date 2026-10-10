[CmdletBinding()]
param(
    [Parameter()][string] $InstallPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PowerShell7Path {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles} 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-PowerShellVersion {
    param([Parameter(Mandatory)][string] $Executable)
    $versionText = & $Executable -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
    if ($LASTEXITCODE -ne 0) {
        throw "Could not query PowerShell version from '$Executable'."
    }
    [Version]$versionText
}

$powerShellPath = Get-PowerShell7Path
$needsInstall = -not $powerShellPath
if ($powerShellPath -and (Get-PowerShellVersion -Executable $powerShellPath) -lt [Version]'7.2') {
    $needsInstall = $true
}

if ($needsInstall) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'PowerShell 7.2+ is missing and winget is unavailable. Install PowerShell 7.2+ manually, then run this setup again.'
    }

    Write-Host 'Installing/updating PowerShell 7 for the current user through winget.'
    & $winget.Source install --id Microsoft.PowerShell --exact --scope user --silent `
        --accept-package-agreements --accept-source-agreements --force
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install PowerShell 7 (exit code $LASTEXITCODE)."
    }
    $powerShellPath = Get-PowerShell7Path
}

if (-not $powerShellPath -or (Get-PowerShellVersion -Executable $powerShellPath) -lt [Version]'7.2') {
    throw 'PowerShell 7.2+ is still unavailable after bootstrap. Install it manually and retry.'
}

$installerPath = Join-Path $PSScriptRoot 'Install-DbMigrationWeb.ps1'
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath, '-CurrentUser')
if ($InstallPath) {
    $arguments += @('-InstallPath', $InstallPath)
}
& $powerShellPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Db Migration Tool installation failed (exit code $LASTEXITCODE)."
}