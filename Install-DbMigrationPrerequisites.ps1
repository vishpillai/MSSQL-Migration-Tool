[CmdletBinding()]
param(
    [Parameter()][ValidateSet('CurrentUser', 'AllUsers')][string] $Scope = 'CurrentUser'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.2') {
    throw "PowerShell 7.2 or later is required. Run Setup-DbMigrationTool.cmd to install PowerShell for the current user."
}

$availableModules = @(Get-Module -ListAvailable -Name dbatools)
$installedModule = if ($Scope -eq 'AllUsers') {
    $allUsersModuleRoots = @(
        (Join-Path $env:ProgramFiles 'PowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $PSHOME 'Modules')
    )
    @($availableModules | Where-Object {
        $modulePath = [System.IO.Path]::GetFullPath($_.ModuleBase)
        @($allUsersModuleRoots | Where-Object {
            $modulePath.StartsWith([System.IO.Path]::GetFullPath($_), [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
    } | Sort-Object Version -Descending | Select-Object -First 1)
}
else {
    @($availableModules | Sort-Object Version -Descending | Select-Object -First 1)
}
$installedModule = @($installedModule) | Select-Object -First 1
$installedByScript = $false

if (-not $installedModule) {
    Write-Host 'dbatools is missing. Installing it from PowerShell Gallery for the current setup scope.'
    try {
        Install-Module -Name dbatools -Repository PSGallery -Scope $Scope -Force -AllowClobber -ErrorAction Stop
    }
    catch {
        throw "Could not install dbatools for scope '$Scope'. Confirm PowerShell Gallery access and permissions, then retry. $($_.Exception.Message)"
    }
    $installedByScript = $true
    $availableModules = @(Get-Module -ListAvailable -Name dbatools)
    $installedModule = if ($Scope -eq 'AllUsers') {
        @($availableModules | Where-Object {
            $modulePath = [System.IO.Path]::GetFullPath($_.ModuleBase)
            @($allUsersModuleRoots | Where-Object {
                $modulePath.StartsWith([System.IO.Path]::GetFullPath($_), [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
        } | Sort-Object Version -Descending | Select-Object -First 1)
    }
    else {
        @($availableModules | Sort-Object Version -Descending | Select-Object -First 1)
    }
    $installedModule = @($installedModule) | Select-Object -First 1
}

if (-not $installedModule) {
    throw 'dbatools installation did not produce an available module.'
}

Import-Module dbatools -ErrorAction Stop
[pscustomobject]@{
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    DbatoolsVersion = $installedModule.Version.ToString()
    DbatoolsPath = $installedModule.ModuleBase
    InstalledByScript = $installedByScript
    Scope = $Scope
}