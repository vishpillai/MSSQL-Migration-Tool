Set-StrictMode -Version Latest

$script:MigrationWebFeatures = @(
    'Migration',
    'Patching',
    'LiveMonitor',
    'CustomSql',
    'DiskUsage',
    'LogsAudit'
)

function Get-MigrationWebDefaultBranding {
    [CmdletBinding()]
    param()

    [ordered]@{
        ProductName = 'Database Migration'
        OrganizationName = 'Vishal Pillai'
        HeaderSubtitle = 'SQL Server management workspace'
        LoginHeadline = 'Move your data with confidence.'
        LoginDescription = 'Plan, migrate, and monitor SQL Server environments from one secure workspace.'
        AccentColor = '#1769aa'
        Theme = 'Light'
        LogoDataUri = ''
    }
}

function ConvertTo-MigrationWebAuthStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Record)

    if ($Record.Contains('Users')) {
        $users = @($Record.Users)
        if ($users.Count -lt 1 -or $users.Count -gt 128) {
            throw 'The application user store must contain between 1 and 128 users.'
        }
        $normalizedUsers = [System.Collections.Generic.List[System.Collections.IDictionary]]::new()
        $usernames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $superAdminCount = 0
        foreach ($user in $users) {
            if ($user -isnot [System.Collections.IDictionary] -or
                -not $user.Contains('Username') -or -not $user.Contains('Salt') -or
                -not $user.Contains('PasswordHash') -or -not $user.Contains('Iterations')) {
                throw 'An application user record is missing required credential properties.'
            }
            $username = ([string]$user.Username).Trim()
            if ([string]::IsNullOrWhiteSpace($username) -or $username.Length -gt 128 -or
                $username -match '[\x00-\x1f\x7f]') {
                throw 'Application usernames must contain 1 to 128 printable characters.'
            }
            if (-not $usernames.Add($username)) {
                throw "Duplicate application username '$username'."
            }
            $role = if ($user.Contains('Role')) { [string]$user.Role } else { 'User' }
            if ($role -notin @('SuperAdmin', 'User')) {
                throw "Unsupported role '$role' for application user '$username'."
            }
            if ($role -eq 'SuperAdmin') { $superAdminCount++ }
            $features = if ($role -eq 'SuperAdmin') {
                @($script:MigrationWebFeatures)
            }
            elseif ($user.Contains('Features')) {
                @($user.Features | ForEach-Object { [string]$_ } | Select-Object -Unique)
            }
            else {
                @()
            }
            $unknownFeatures = @($features | Where-Object { $_ -notin $script:MigrationWebFeatures })
            if ($unknownFeatures.Count -gt 0) {
                throw "User '$username' has unsupported feature grants: $($unknownFeatures -join ', ')."
            }
            $normalizedUsers.Add([ordered]@{
                Username = $username
                Salt = [string]$user.Salt
                PasswordHash = [string]$user.PasswordHash
                Iterations = [int]$user.Iterations
                CreatedUtc = if ($user.Contains('CreatedUtc')) { [string]$user.CreatedUtc } else { [DateTime]::UtcNow.ToString('o') }
                Role = $role
                Features = @($features)
                Enabled = if ($user.Contains('Enabled')) { [bool]$user.Enabled } else { $true }
            })
        }
        if ($superAdminCount -ne 1) {
            throw 'The application user store must contain exactly one Super Admin.'
        }
        $branding = Get-MigrationWebDefaultBranding
        if ($Record.Branding -is [System.Collections.IDictionary]) {
            foreach ($key in @($Record.Branding.Keys)) {
                if (-not $branding.Contains($key)) {
                    throw "Unsupported branding setting '$key'."
                }
                $branding[$key] = [string]$Record.Branding[$key]
            }
        }
        return [ordered]@{
            SchemaVersion = 2
            Users = @($normalizedUsers.ToArray())
            Branding = $branding
        }
    }

    foreach ($property in @('Username', 'Salt', 'PasswordHash', 'Iterations')) {
        if (-not $Record.Contains($property)) {
            throw "Authentication record is missing '$property'."
        }
    }
    [ordered]@{
        SchemaVersion = 2
        Users = @([ordered]@{
            Username = [string]$Record.Username
            Salt = [string]$Record.Salt
            PasswordHash = [string]$Record.PasswordHash
            Iterations = [int]$Record.Iterations
            CreatedUtc = if ($Record.Contains('CreatedUtc')) { [string]$Record.CreatedUtc } else { [DateTime]::UtcNow.ToString('o') }
            Role = 'SuperAdmin'
            Features = @($script:MigrationWebFeatures)
            Enabled = $true
        })
        Branding = Get-MigrationWebDefaultBranding
    }
}

function New-MigrationWebUserRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Username,
        [Parameter(Mandatory)][securestring] $Password,
        [Parameter()][string[]] $Features = @()
    )

    $unknownFeatures = @($Features | Where-Object { $_ -notin $script:MigrationWebFeatures })
    if ($unknownFeatures.Count -gt 0) {
        throw "Unsupported feature grants: $($unknownFeatures -join ', ')."
    }
    $record = New-MigrationWebPasswordRecord -Username $Username -Password $Password
    [ordered]@{
        Username = $record.Username
        Salt = $record.Salt
        PasswordHash = $record.PasswordHash
        Iterations = $record.Iterations
        CreatedUtc = $record.CreatedUtc
        Role = 'User'
        Features = @($Features | Select-Object -Unique)
        Enabled = $true
    }
}

function Get-MigrationWebSafeUser {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $User)

    [ordered]@{
        Username = [string]$User.Username
        Role = [string]$User.Role
        Features = @($User.Features)
        Enabled = [bool]$User.Enabled
        CreatedUtc = [string]$User.CreatedUtc
    }
}

function Get-MigrationWebFeatureNames {
    [CmdletBinding()]
    param()
    @($script:MigrationWebFeatures)
}

function Set-MigrationWebBranding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Branding,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Updates
    )

    $allowed = Get-MigrationWebDefaultBranding
    foreach ($key in @($Updates.Keys)) {
        if (-not $allowed.Contains($key)) {
            throw "Unsupported branding setting '$key'."
        }
        if ($null -eq $Updates[$key]) {
            throw "Branding setting '$key' cannot be null."
        }
        $value = [string]$Updates[$key]
        if ($key -eq 'Theme') {
            if ($value -notin @('Light', 'Dark', 'Blue')) {
                throw 'Theme must be Light, Dark, or Blue.'
            }
        }
        elseif ($key -eq 'AccentColor') {
            if ($value -notmatch '^#[0-9A-Fa-f]{6}$') {
                throw 'AccentColor must be a six-digit CSS hex color.'
            }
        }
        elseif ($key -eq 'LogoDataUri') {
            if ($value -and $value -notmatch '^data:image/(png|jpeg);base64,([A-Za-z0-9+/]+={0,2})$') {
                throw 'LogoDataUri must be an embedded PNG or JPEG image.'
            }
            if ($value) {
                try { $logoBytes = [Convert]::FromBase64String($Matches[2]) }
                catch { throw 'LogoDataUri contains invalid Base64.' }
                if ($logoBytes.Length -gt 262144) {
                    [Array]::Clear($logoBytes, 0, $logoBytes.Length)
                    throw 'The logo must not exceed 256 KiB.'
                }
                $isPng = $value.StartsWith('data:image/png;') -and
                    $logoBytes.Length -ge 8 -and [Convert]::ToHexString($logoBytes[0..7]) -eq '89504E470D0A1A0A'
                $isJpeg = $value.StartsWith('data:image/jpeg;') -and
                    $logoBytes.Length -ge 3 -and [Convert]::ToHexString($logoBytes[0..2]) -eq 'FFD8FF'
                [Array]::Clear($logoBytes, 0, $logoBytes.Length)
                if (-not ($isPng -or $isJpeg)) {
                    throw 'LogoDataUri image content does not match its PNG or JPEG type.'
                }
            }
        }
        else {
            $maxLength = switch ($key) {
                'ProductName' { 64 }
                'OrganizationName' { 100 }
                'HeaderSubtitle' { 100 }
                'LoginHeadline' { 120 }
                'LoginDescription' { 240 }
            }
            if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt $maxLength -or $value -match '[\x00-\x1f\x7f]') {
                throw "Branding setting '$key' must contain 1 to $maxLength printable characters."
            }
            $value = $value.Trim()
        }
        $Branding[$key] = $value
    }
    $Branding
}

function New-MigrationWebPasswordRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Username,
        [Parameter(Mandatory)][securestring] $Password
    )

    if ([string]::IsNullOrWhiteSpace($Username) -or $Username.Length -gt 128 -or
        $Username -match '[\x00-\x1f\x7f]') {
        throw [ArgumentException]::new('Username must contain 1 to 128 printable characters.')
    }
    if ($Password.Length -lt 14 -or $Password.Length -gt 1024) {
        throw [ArgumentException]::new('The application password must contain between 14 and 1024 characters.')
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

Export-ModuleMember -Function New-MigrationWebPasswordRecord, Test-MigrationWebPassword, Save-MigrationWebAuthRecord, Test-MigrationWebWindowsGroupMembership, Resolve-MigrationWebStoragePaths, Get-MigrationWebDefaultBranding, ConvertTo-MigrationWebAuthStore, New-MigrationWebUserRecord, Get-MigrationWebSafeUser, Get-MigrationWebFeatureNames, Set-MigrationWebBranding
