[CmdletBinding()]
param(
    [Parameter()][string] $Username,
    [Parameter()][string] $RunAsAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
    [Parameter()][switch] $PortableMode,
    [Parameter()][string] $AppRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.WebAuth.psm1') -Force

$storage = Resolve-MigrationWebStoragePaths -AppRoot $AppRoot -PortableMode:$PortableMode
$fullPath = $storage.AuthPath

if (-not $PortableMode) {
    if (-not [string]::Equals(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            $RunAsAccount,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Run credential initialization as the same Windows account that will host the browser app.'
    }
}

if ([string]::IsNullOrWhiteSpace($Username)) {
    $Username = Read-Host 'Dedicated migration app username'
}
$password = Read-Host 'Dedicated migration app password (14+ characters)' -AsSecureString
$confirmation = Read-Host 'Re-enter the application password' -AsSecureString
$passwordPointer = [IntPtr]::Zero
$confirmationPointer = [IntPtr]::Zero
try {
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($password)
    $confirmationPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($confirmation)
    $passwordText = [Runtime.InteropServices.Marshal]::PtrToStringUni($passwordPointer)
    $confirmationText = [Runtime.InteropServices.Marshal]::PtrToStringUni($confirmationPointer)
    if (-not [string]::Equals($passwordText, $confirmationText, [StringComparison]::Ordinal)) {
        throw 'The passwords do not match. No credentials were changed; run the script again.'
    }
    $record = New-MigrationWebPasswordRecord -Username $Username -Password $password
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPointer)
    }
    if ($confirmationPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($confirmationPointer)
    }
    $passwordText = $null
    $confirmationText = $null
    $password.Dispose()
    $confirmation.Dispose()
}

Save-MigrationWebAuthRecord -Record $record -Path $fullPath -PortableMode:$PortableMode

Write-Output "Authentication record created at $fullPath. Password material is stored only as a salted PBKDF2 hash."
