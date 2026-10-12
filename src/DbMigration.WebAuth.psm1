Set-StrictMode -Version Latest

function New-MigrationWebPasswordRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Username,
        [Parameter(Mandatory)][securestring] $Password
    )

    if ([string]::IsNullOrWhiteSpace($Username) -or $Username.Length -gt 128) {
        throw 'Username must contain between 1 and 128 characters.'
    }
    if ($Password.Length -lt 14 -or $Password.Length -gt 1024) {
        throw 'The application password must contain between 14 and 1024 characters.'
    }

    $passwordPointer = [IntPtr]::Zero
    try {
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        $salt = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($salt)
        $deriveBytes = [Security.Cryptography.Rfc2898DeriveBytes]::new(
            $plainText, $salt, 310000, [Security.Cryptography.HashAlgorithmName]::SHA256
        )
        try {
            $hash = $deriveBytes.GetBytes(32)
        }
        finally {
            $deriveBytes.Dispose()
        }

        [pscustomobject]@{
            Username = $Username
            Salt = [Convert]::ToBase64String($salt)
            PasswordHash = [Convert]::ToBase64String($hash)
            Iterations = 310000
            CreatedUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    finally {
        if ($passwordPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        }
        $plainText = $null
    }
}

function Test-MigrationWebPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object] $Record,
        [Parameter(Mandatory)][string] $Username,
        [Parameter(Mandatory)][string] $Password
    )

    foreach ($property in @('Salt', 'PasswordHash', 'Iterations', 'Username')) {
        if ($Record -is [System.Collections.IDictionary]) {
            $hasProperty = $Record.Contains($property)
        }
        else {
            $hasProperty = $null -ne $Record.PSObject.Properties[$property]
        }
        if (-not $hasProperty) {
            throw "Password record is missing '$property'."
        }
    }
    if ($Password.Length -gt 1024 -or $Username.Length -gt 128) {
        return $false
    }
    $salt = [Convert]::FromBase64String([string]$Record.Salt)
    $expectedHash = [Convert]::FromBase64String([string]$Record.PasswordHash)
    $iterations = [int]$Record.Iterations
    if ($iterations -lt 100000 -or $iterations -gt 2000000 -or
        $expectedHash.Length -ne 32 -or $salt.Length -lt 16 -or $salt.Length -gt 64) {
        throw 'The web authentication record contains invalid password parameters.'
    }
    $deriveBytes = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password, $salt, $iterations, [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $actualHash = $deriveBytes.GetBytes($expectedHash.Length)
    }
    finally {
        $deriveBytes.Dispose()
    }
    $passwordMatches = [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($actualHash, $expectedHash)
    $usernameMatches = [string]::Equals([string]$Record.Username, $Username, [StringComparison]::Ordinal)
    return ($passwordMatches -and $usernameMatches)
}

function Save-MigrationWebAuthRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object] $Record,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path,
        [Parameter()][switch] $PortableMode,
        [Parameter()][switch] $CreateOnly
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Authentication directory must not be a reparse point: $directory"
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $authItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($authItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Authentication file must not be a reparse point: $Path"
        }
    }
    elseif (Test-Path -LiteralPath $Path) {
        throw "Authentication path is not a file: $Path"
    }

    if (-not $PortableMode) {
        $allowedIdentities = @(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            ([System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null))
            ([System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null))
        )
        $directoryAcl = Get-Acl -LiteralPath $directory -ErrorAction Stop
        $directoryAcl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($directoryAcl.Access)) {
            $directoryAcl.RemoveAccessRuleSpecific($existingRule)
        }
        foreach ($identity in $allowedIdentities) {
            $directoryAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', 'Allow'
            ))
        }
        Set-Acl -LiteralPath $directory -AclObject $directoryAcl -ErrorAction Stop
    }

    $temporaryPath = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Record -Depth 4 -ErrorAction Stop
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if (-not $PortableMode) {
            $fileAcl = Get-Acl -LiteralPath $temporaryPath -ErrorAction Stop
            $fileAcl.SetAccessRuleProtection($true, $false)
            foreach ($existingRule in @($fileAcl.Access)) {
                $fileAcl.RemoveAccessRuleSpecific($existingRule)
            }
            foreach ($identity in $allowedIdentities) {
                $fileAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    $identity, 'FullControl', 'Allow'
                ))
            }
            Set-Acl -LiteralPath $temporaryPath -AclObject $fileAcl -ErrorAction Stop
        }
        if ($CreateOnly) {
            [IO.File]::Move($temporaryPath, $Path)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path, $true)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function Test-MigrationWebWindowsGroupMembership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Security.Principal.WindowsIdentity] $Identity,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Group
    )

    if (-not $Identity.IsAuthenticated) { return $false }
    try {
        $groupSid = if ($Group -match '^S-1-') {
            [System.Security.Principal.SecurityIdentifier]::new($Group)
        }
        else {
            ([System.Security.Principal.NTAccount]::new($Group)).Translate([System.Security.Principal.SecurityIdentifier])
        }
        $principal = [System.Security.Principal.WindowsPrincipal]::new($Identity)
        return $principal.IsInRole($groupSid)
    }
    catch {
        return $false
    }
}

function Resolve-MigrationWebStoragePaths {
    [CmdletBinding()]
    param(
        [Parameter()][string] $AppRoot,
        [Parameter()][switch] $PortableMode
    )

    $resolvedAppRoot = if ([string]::IsNullOrWhiteSpace($AppRoot)) {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }
    else {
        [System.IO.Path]::GetFullPath($AppRoot)
    }

    if ($PortableMode) {
        $authDirectory = Join-Path $resolvedAppRoot 'portable\auth'
        $logDirectory = Join-Path $resolvedAppRoot 'portable\logs'
    }
    else {
        $authDirectory = Join-Path ([System.Environment]::GetFolderPath('CommonApplicationData')) 'DbMigrationWeb'
        $logDirectory = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'DbMigrationWeb\Logs'
    }

    [pscustomobject]@{
        AppRoot = $resolvedAppRoot
        AuthDirectory = $authDirectory
        AuthPath = Join-Path $authDirectory 'auth.json'
        LogDirectory = $logDirectory
        IsPortable = [bool]$PortableMode
    }
}

Export-ModuleMember -Function New-MigrationWebPasswordRecord, Test-MigrationWebPassword, Save-MigrationWebAuthRecord, Test-MigrationWebWindowsGroupMembership, Resolve-MigrationWebStoragePaths
