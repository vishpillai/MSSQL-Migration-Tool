[CmdletBinding()]
param(
    [Parameter()][string] $Configuration = 'Release',
    [Parameter()][switch] $StageOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$stagingRoot = Join-Path $PSScriptRoot 'obj\staging'

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
$appRoot = Join-Path $stagingRoot 'App'
$null = New-Item -ItemType Directory -Path $appRoot -Force -ErrorAction Stop

$runtimeFiles = @(
    'Initialize-DbMigrationWebAuth.ps1',
    'Invoke-DbMigration.ps1',
    'Invoke-DbMigrationGui.ps1',
    'Invoke-DbMigrationPatch.ps1',
    'Invoke-DbMigrationWeb.ps1',
    'Invoke-DbMigrationWebPlan.ps1',
    'Register-DbMigrationWebHttps.ps1',
    'Start-PortableDbMigrationWeb.ps1'
)
foreach ($relativePath in $runtimeFiles) {
    $source = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required runtime file is missing: $relativePath"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $appRoot $relativePath) -Force
}
foreach ($directoryName in @('config', 'src', 'web')) {
    $source = Join-Path $repoRoot $directoryName
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Required runtime directory is missing: $directoryName"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $appRoot $directoryName) -Recurse -Force
}

$prerequisitePath = Join-Path $repoRoot 'Install-DbMigrationPrerequisites.ps1'
if (-not (Test-Path -LiteralPath $prerequisitePath -PathType Leaf)) {
    throw 'Required prerequisite installer is missing.'
}
Copy-Item -LiteralPath $prerequisitePath -Destination (Join-Path $stagingRoot 'Install-DbMigrationPrerequisites.ps1') -Force

$launcherPath = Join-Path $stagingRoot 'Start-DbMigrationWeb.cmd'
@'
@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell 7 is required. Install PowerShell 7.2 or later and try again.
    exit /b 9009
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DbMigrationWeb.ps1" %*
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath $launcherPath -Encoding ASCII

$runtimeLauncherPath = Join-Path $stagingRoot 'Start-DbMigrationWeb.ps1'
@'
[CmdletBinding()]
param(
    [Parameter()][string] $HostName = 'localhost',
    [Parameter()][ValidateRange(1, 65535)][int] $Port = 9080,
    [Parameter()][string] $Username = 'migration-admin',
    [Parameter()][string] $Password
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.2') {
    throw 'PowerShell 7.2 or later is required.'
}

if (-not (Get-Module -ListAvailable -Name dbatools)) {
    & (Join-Path $PSScriptRoot 'Install-DbMigrationPrerequisites.ps1') -Scope CurrentUser | Out-Null
}

$appRoot = Join-Path $PSScriptRoot 'App'
& (Join-Path $appRoot 'Start-PortableDbMigrationWeb.ps1') `
    -HostName $HostName -Port $Port -Username $Username -Password $Password -AppRoot $appRoot
'@ | Set-Content -LiteralPath $runtimeLauncherPath -Encoding UTF8

$null = New-Item -ItemType Directory -Path (Join-Path $appRoot 'portable\auth') -Force -ErrorAction Stop
$null = New-Item -ItemType Directory -Path (Join-Path $appRoot 'portable\logs') -Force -ErrorAction Stop

if ($StageOnly) {
    Write-Host "Portable application staged at: $stagingRoot"
    return
}

$manifest = [System.Collections.Generic.List[string]]::new()
$manifest.Add('<?xml version="1.0" encoding="utf-8"?>')
$manifest.Add('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
$manifest.Add('  <Package Name="Db Migration Tool" Manufacturer="Vishal Pillai" Version="1.0.0.0" UpgradeCode="5D339A8D-CA1E-45D4-A266-4F0812FE5981" Language="1033" Scope="perUser">')
$manifest.Add('    <MediaTemplate CompressionLevel="high" />')
$manifest.Add('    <Feature Id="MainFeature" Title="Db Migration Tool" Level="1">')
$manifest.Add('      <ComponentGroupRef Id="AppFiles" />')
$manifest.Add('      <ComponentRef Id="AppStartMenuShortcut" />')
$manifest.Add('      <ComponentRef Id="AppDesktopShortcut" />')
$manifest.Add('    </Feature>')
$manifest.Add('    <StandardDirectory Id="LocalAppDataFolder">')
$manifest.Add('      <Directory Id="INSTALLFOLDER" Name="DbMigrationTool" />')
$manifest.Add('    </StandardDirectory>')
$manifest.Add('    <StandardDirectory Id="ProgramMenuFolder" />')
$manifest.Add('    <StandardDirectory Id="DesktopFolder" />')
$manifest.Add('    <Component Id="AppStartMenuShortcut" Directory="ProgramMenuFolder" Guid="{2D9E0C4A-F9A1-4A55-B4F6-09D0CBF82E0D}">')
$manifest.Add('      <Shortcut Id="AppShortcut" Name="Db Migration Tool" Target="[INSTALLFOLDER]Start-DbMigrationWeb.cmd" WorkingDirectory="INSTALLFOLDER" />')
$manifest.Add('      <RegistryValue Root="HKCU" Key="Software\DbMigrationTool" Name="StartMenuShortcut" Type="integer" Value="1" KeyPath="yes" />')
$manifest.Add('    </Component>')
$manifest.Add('    <Component Id="AppDesktopShortcut" Directory="DesktopFolder" Guid="{919DEE3A-6F4E-4EA8-A09B-0F8A356D82B2}">')
$manifest.Add('      <Shortcut Id="DesktopShortcut" Name="Db Migration Tool" Target="[INSTALLFOLDER]Start-DbMigrationWeb.cmd" WorkingDirectory="INSTALLFOLDER" />')
$manifest.Add('      <RegistryValue Root="HKCU" Key="Software\DbMigrationTool" Name="DesktopShortcut" Type="integer" Value="1" KeyPath="yes" />')
$manifest.Add('    </Component>')
$manifest.Add('  </Package>')
$manifest.Add('  <Fragment>')
$manifest.Add('    <DirectoryRef Id="INSTALLFOLDER">')

$componentRefs = [System.Collections.Generic.List[string]]::new()

function Get-SafeId {
    param([Parameter(Mandatory)][string] $Value)
    $safe = ($Value -replace '[^A-Za-z0-9_]', '_').Trim('_')
    if ([string]::IsNullOrEmpty($safe)) { $safe = 'item' }
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    return $safe
}

function Get-StableGuid {
    param([Parameter(Mandatory)][string] $Value)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("DbMigrationTool:$Value"))
    }
    finally {
        $sha1.Dispose()
    }

    $hex = [System.BitConverter]::ToString($hash, 0, 16).Replace('-', '').ToLowerInvariant()
    $variant = [Convert]::ToInt32($hex.Substring(16, 1), 16)
    $hex = $hex.Substring(0, 12) + '5' + $hex.Substring(13, 3) +
        [Convert]::ToString(($variant -band 0x3) -bor 0x8, 16) + $hex.Substring(17)
    return ([guid]::ParseExact($hex, 'N')).ToString('B')
}

function Add-DirectoryCleanupComponent {
    param(
        [Parameter(Mandatory)][string] $DirectoryId,
        [Parameter(Mandatory)][string] $LogicalPath
    )

    $safePath = Get-SafeId -Value $LogicalPath
    $componentId = 'cmp_cleanup_' + $safePath
    $removeFolderId = 'remove_' + $safePath
    $guid = Get-StableGuid -Value "cleanup:$LogicalPath"
    $manifest.Add('      <Component Id="' + $componentId + '" Guid="' + $guid + '" Directory="' + $DirectoryId + '">')
    $manifest.Add('        <RemoveFolder Id="' + $removeFolderId + '" On="uninstall" />')
    $manifest.Add('        <RegistryValue Root="HKCU" Key="Software\DbMigrationTool\AppFiles" Name="' + $componentId + '" Type="integer" Value="1" KeyPath="yes" />')
    $manifest.Add('      </Component>')
    $componentRefs.Add('      <ComponentRef Id="' + $componentId + '" />')
}

function Add-DirectoryEntries {
    param(
        [Parameter(Mandatory)][string] $CurrentPath,
        [Parameter(Mandatory)][string] $ParentDirectoryId,
        [Parameter(Mandatory)][string] $LogicalPath
    )

    $entries = Get-ChildItem -LiteralPath $CurrentPath -Force | Sort-Object Name
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer) {
            $dirId = 'dir_' + (Get-SafeId -Value ($LogicalPath + '_' + $entry.Name))
            $manifest.Add('      <Directory Id="' + $dirId + '" Name="' + $entry.Name + '">')
            Add-DirectoryCleanupComponent -DirectoryId $dirId -LogicalPath ($LogicalPath + '_' + $entry.Name)
            Add-DirectoryEntries -CurrentPath $entry.FullName -ParentDirectoryId $dirId -LogicalPath ($LogicalPath + '_' + $entry.Name)
            $manifest.Add('      </Directory>')
            continue
        }

        $componentId = 'cmp_' + (Get-SafeId -Value ($LogicalPath + '_' + $entry.Name))
        $fileId = 'file_' + (Get-SafeId -Value ($LogicalPath + '_' + $entry.Name))
        $source = [System.IO.Path]::GetRelativePath($PSScriptRoot, $entry.FullName) -replace '\\', '/'
        $guid = Get-StableGuid -Value "file:$LogicalPath\$($entry.Name)"
        $manifest.Add('      <Component Id="' + $componentId + '" Guid="' + $guid + '" Directory="' + $ParentDirectoryId + '">')
        $manifest.Add('        <File Id="' + $fileId + '" Source="' + $source + '" />')
        $manifest.Add('        <RegistryValue Root="HKCU" Key="Software\DbMigrationTool\AppFiles" Name="' + $componentId + '" Type="string" Value="' + $source + '" KeyPath="yes" />')
        $manifest.Add('      </Component>')
        $componentRefs.Add('      <ComponentRef Id="' + $componentId + '" />')
    }
}

Add-DirectoryCleanupComponent -DirectoryId 'INSTALLFOLDER' -LogicalPath 'installfolder'

Get-ChildItem -LiteralPath $stagingRoot -Force | Sort-Object Name | ForEach-Object {
    if ($_.PSIsContainer) {
        $dirId = 'dir_' + (Get-SafeId -Value ('root_' + $_.Name))
        $manifest.Add('      <Directory Id="' + $dirId + '" Name="' + $_.Name + '">')
        Add-DirectoryCleanupComponent -DirectoryId $dirId -LogicalPath ('root_' + $_.Name)
        Add-DirectoryEntries -CurrentPath $_.FullName -ParentDirectoryId $dirId -LogicalPath ('root_' + $_.Name)
        $manifest.Add('      </Directory>')
        return
    }

    $componentId = 'cmp_' + (Get-SafeId -Value ('root_' + $_.Name))
    $fileId = 'file_' + (Get-SafeId -Value ('root_' + $_.Name))
    $source = [System.IO.Path]::GetRelativePath($PSScriptRoot, $_.FullName) -replace '\\', '/'
    $guid = Get-StableGuid -Value "file:root\$($_.Name)"
    $manifest.Add('      <Component Id="' + $componentId + '" Guid="' + $guid + '" Directory="INSTALLFOLDER">')
    $manifest.Add('        <File Id="' + $fileId + '" Source="' + $source + '" />')
    $manifest.Add('        <RegistryValue Root="HKCU" Key="Software\DbMigrationTool\AppFiles" Name="' + $componentId + '" Type="string" Value="' + $source + '" KeyPath="yes" />')
    $manifest.Add('      </Component>')
    $componentRefs.Add('      <ComponentRef Id="' + $componentId + '" />')
}

$manifest.Add('    </DirectoryRef>')
$manifest.Add('    <ComponentGroup Id="AppFiles">')
foreach ($ref in $componentRefs) {
    $manifest.Add($ref)
}
$manifest.Add('    </ComponentGroup>')
$manifest.Add('  </Fragment>')
$manifest.Add('</Wix>')

$manifestPath = Join-Path $PSScriptRoot 'Product.wxs'
$manifest.ToArray() | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$legacyAppFilesPath = Join-Path $PSScriptRoot 'AppFiles.wxs'
if (Test-Path -LiteralPath $legacyAppFilesPath) {
    Remove-Item -LiteralPath $legacyAppFilesPath -Force
}

$projectPath = Join-Path $PSScriptRoot 'DbMigrationTool.Installer.wixproj'
& dotnet build $projectPath -c $Configuration --nologo
if ($LASTEXITCODE -ne 0) {
    throw 'WiX build failed.'
}

$artifact = Get-ChildItem -Path (Join-Path $PSScriptRoot 'bin') -Recurse -File -Filter '*.msi' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
if (-not $artifact) {
    throw 'No MSI was generated.'
}

Write-Host "Installer artifact: $($artifact.FullName)"
