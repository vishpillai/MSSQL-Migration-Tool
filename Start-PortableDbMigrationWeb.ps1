[CmdletBinding()]
param(
    [Parameter()][string] $HostName = 'localhost',
    [Parameter()][ValidateRange(1, 65535)][int] $Port = 9080,
    [Parameter()][string] $Username = 'migration-admin',
    [Parameter()][string] $Password,
    [Parameter()][string] $AppRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FreeTcpPort {
    param([Parameter()][int] $PreferredPort)

    $candidate = $PreferredPort
    for ($offset = 0; $offset -lt 50; $offset++) {
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidate)
        try {
            $tcpListener.Start()
            return $candidate
        }
        catch {
            $candidate = $PreferredPort + $offset + 1
        }
        finally {
            $tcpListener.Stop()
        }
    }

    throw "Could not find a free loopback port near $PreferredPort."
}

Import-Module (Join-Path $AppRoot 'src\DbMigration.WebAuth.psm1') -Force

function New-InitialPortablePassword {
    $randomBytes = [byte[]]::new(32)
    $randomNumberGenerator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $randomNumberGenerator.GetBytes($randomBytes)
    }
    finally {
        $randomNumberGenerator.Dispose()
    }

    [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$existingInstance = $null
if ([System.Threading.Mutex]::TryOpenExisting('Global\DbMigrationToolWebHost', [ref]$existingInstance)) {
    $existingInstance.Dispose()
    Write-Host 'Another Database Migration web host is already running on this machine. Only one instance can run at a time; use the open browser tab or close the existing host first.'
    return
}

$isElevated = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated -and -not $env:DBMIGRATION_NO_ELEVATE) {
    Write-Host 'SQL Server patching needs administrator rights; requesting elevation (UAC prompt)...'
    $relaunchArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-HostName', $HostName, '-Port', $Port, '-AppRoot', $AppRoot)
    foreach ($name in @('Username', 'Password')) {
        if ($PSBoundParameters.ContainsKey($name)) { $relaunchArguments += @("-$name", (Get-Variable -Name $name -ValueOnly)) }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunchArguments -Verb RunAs -ErrorAction Stop
        return
    }
    catch {
        Write-Host "Elevation was declined; continuing without administrator rights. SQL Server patching of local instances will be unavailable. ($($_.Exception.Message))"
    }
}
$storage = Resolve-MigrationWebStoragePaths -AppRoot $AppRoot -PortableMode

if (-not (Test-Path -LiteralPath $storage.AuthPath -PathType Leaf)) {
    $null = New-Item -ItemType Directory -Path $storage.AuthDirectory -Force -ErrorAction Stop
    $generatedPassword = [string]::IsNullOrEmpty($Password)
    if ($generatedPassword) {
        $Password = New-InitialPortablePassword
    }
    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $record = New-MigrationWebPasswordRecord -Username $Username -Password $securePassword
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $storage.AuthPath -Encoding utf8
    if ($generatedPassword) {
        Write-Host "Initial portable login (shown once; save it securely):`nUsername: $Username`nPassword: $Password"
    }
    Write-Host "Portable auth file created at $($storage.AuthPath)"
}

$selectedPort = Get-FreeTcpPort -PreferredPort $Port
if ($selectedPort -ne $Port) {
    Write-Host "Port $Port is unavailable; starting portable web app on $selectedPort instead."
}

& (Join-Path $AppRoot 'Invoke-DbMigrationWeb.ps1') -HostName $HostName -Port $selectedPort -PortableMode -AppRoot $AppRoot
