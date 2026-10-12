Set-StrictMode -Version Latest

function Get-MigrationVolumeDetails {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object[]] $Disks
    )

    $root = [System.IO.Path]::GetPathRoot($Path)
    $disk = $Disks | Where-Object { $_.Name.TrimEnd('\') -eq $root.TrimEnd('\') } | Select-Object -First 1
    if (-not $disk) {
        return [pscustomobject]@{
            Volume = $root
            CapacityGB = $null
            FreeGB = $null
            PercentFree = $null
        }
    }

    [pscustomobject]@{
        Volume = $disk.Name
        CapacityGB = [math]::Round([double]$disk.SizeInGB, 2)
        FreeGB = [math]::Round([double]$disk.FreeInGB, 2)
        PercentFree = [math]::Round([double]$disk.PercentFree, 2)
    }
}

function Test-MigrationTdeReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Source,

        [Parameter(Mandatory)]
        [string] $Target,

        [Parameter(Mandatory)]
        [string] $Database,

        [Parameter()]
        [ValidateSet('Full', 'SchemaOnly')]
        [string] $MigrationMode = 'Full'
    )

    $escapedDatabase = $Database.Replace("'", "''")
    try {
        $sourceEncryption = @(Invoke-DbaQuery -SqlInstance $Source -Database master -EnableException -ErrorAction Stop -Query @"
SELECT
    d.is_encrypted AS IsEncrypted,
    dek.encryption_state AS EncryptionState,
    CONVERT(varchar(130), dek.encryptor_thumbprint, 1) AS EncryptorThumbprint
FROM sys.databases AS d
LEFT JOIN sys.dm_database_encryption_keys AS dek
    ON dek.database_id = d.database_id
WHERE d.name = N'$escapedDatabase';
"@)
    }
    catch {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'TDEPreflight'
            Status = 'Failed'
            TdeEncrypted = $null
            EncryptionState = $null
            EncryptorThumbprint = ''
            TargetEncryptorReady = $false
            Message = "Could not verify source TDE status: $($_.Exception.Message)"
        }
    }
    if ($sourceEncryption.Count -ne 1) {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'TDEPreflight'
            Status = 'Failed'
            TdeEncrypted = $null
            EncryptionState = $null
            EncryptorThumbprint = ''
            TargetEncryptorReady = $false
            Message = "Could not determine TDE status for database '$Database' on source '$Source'."
        }
    }

    $encrypted = [bool]$sourceEncryption[0].IsEncrypted
    $thumbprint = [string]$sourceEncryption[0].EncryptorThumbprint
    if (-not $encrypted) {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'TDEPreflight'
            Status = 'Passed'
            TdeEncrypted = $false
            EncryptionState = $null
            EncryptorThumbprint = ''
            TargetEncryptorReady = $true
            Message = 'Source database is not encrypted with TDE.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($thumbprint) -or $thumbprint -notmatch '^0x[0-9A-Fa-f]+$') {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'TDEPreflight'
            Status = 'Failed'
            TdeEncrypted = $true
            EncryptionState = $sourceEncryption[0].EncryptionState
            EncryptorThumbprint = ''
            TargetEncryptorReady = $false
            Message = "Database '$Database' is TDE-encrypted on '$Source', but its encryptor thumbprint could not be determined."
        }
    }
    if ($MigrationMode -eq 'SchemaOnly') {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'TDEPreflight'
            Status = 'Passed'
            TdeEncrypted = $true
            EncryptionState = $sourceEncryption[0].EncryptionState
            EncryptorThumbprint = $thumbprint
            TargetEncryptorReady = $null
            Message = "Source database uses TDE (encryption state $($sourceEncryption[0].EncryptionState)); schema-only migration does not restore its encrypted backup."
        }
    }

    try {
        $targetEncryption = @(Invoke-DbaQuery -SqlInstance $Target -Database master -EnableException -ErrorAction Stop -Query @"
SELECT COUNT(*) AS MatchingPrivateKeyCount
FROM (
    SELECT thumbprint
    FROM master.sys.certificates
    WHERE thumbprint = CONVERT(varbinary(64), '$thumbprint', 1)
      AND pvt_key_encryption_type_desc <> N'NO_PRIVATE_KEY'
    UNION ALL
    SELECT thumbprint
    FROM master.sys.asymmetric_keys
    WHERE thumbprint = CONVERT(varbinary(64), '$thumbprint', 1)
      AND (pvt_key_encryption_type_desc <> N'NO_PRIVATE_KEY' OR cryptographic_provider_guid IS NOT NULL)
) AS target_encryptors;
"@)
    }
    catch {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'TDEPreflight'
            Status = 'Failed'
            TdeEncrypted = $true
            EncryptionState = $sourceEncryption[0].EncryptionState
            EncryptorThumbprint = $thumbprint
            TargetEncryptorReady = $false
            Message = "Could not verify TDE encryptor '$thumbprint' on target '$Target': $($_.Exception.Message)"
        }
    }
    if ($targetEncryption.Count -ne 1) {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'TDEPreflight'
            Status = 'Failed'
            TdeEncrypted = $true
            EncryptionState = $sourceEncryption[0].EncryptionState
            EncryptorThumbprint = $thumbprint
            TargetEncryptorReady = $false
            Message = "Could not verify the TDE encryptor on target '$Target' for database '$Database'."
        }
    }
    $targetReady = [int]$targetEncryption[0].MatchingPrivateKeyCount -gt 0
    $status = if ($targetReady) { 'Passed' } else { 'Failed' }
    $message = if ($targetReady) {
        "Source database is TDE-encrypted (encryption state $($sourceEncryption[0].EncryptionState)); the target has a matching private-key certificate or asymmetric key ($thumbprint)."
    }
    else {
        "Source database is TDE-encrypted (encryption state $($sourceEncryption[0].EncryptionState)), but target '$Target' does not have the matching private-key certificate or asymmetric key ($thumbprint). Install and verify the TDE encryptor on the target before migrating."
    }

    [pscustomobject]@{
        Source = $Source
        Target = $Target
        Database = $Database
        Stage = 'TDEPreflight'
        Status = $status
        TdeEncrypted = $true
        EncryptionState = $sourceEncryption[0].EncryptionState
        EncryptorThumbprint = $thumbprint
        TargetEncryptorReady = $targetReady
        Message = $message
    }
}

function Test-MigrationRestoreCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Source,

        [Parameter(Mandatory)]
        [string] $Target,

        [Parameter(Mandatory)]
        [string] $Database,

        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [double] $BufferPercent = 20
    )

    $files = @(Get-DbaDbFile -SqlInstance $Source -Database $Database -EnableException -ErrorAction Stop)
    $dataFiles = @($files | Where-Object TypeDescription -eq 'ROWS')
    $logFiles = @($files | Where-Object TypeDescription -eq 'LOG')
    if ($dataFiles.Count -eq 0 -or $logFiles.Count -eq 0) {
        throw "Could not determine both data and log file sizes for '$Database' on '$Source'."
    }

    $targetPaths = Get-DbaDefaultPath -SqlInstance $Target -EnableException -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$targetPaths.Data) -or [string]::IsNullOrWhiteSpace([string]$targetPaths.Log)) {
        throw "Target '$Target' does not have default data and log paths configured."
    }
    $targetConnection = Connect-DbaInstance -SqlInstance $Target -ErrorAction Stop
    $targetDisks = @(Get-DbaDiskSpace -ComputerName $targetConnection.ComputerName -Unit GB -EnableException -ErrorAction Stop)
    $dataVolume = Get-MigrationVolumeDetails -Path $targetPaths.Data -Disks $targetDisks
    $logVolume = Get-MigrationVolumeDetails -Path $targetPaths.Log -Disks $targetDisks
    if ($null -eq $dataVolume.FreeGB -or $null -eq $logVolume.FreeGB) {
        throw "Could not determine free space for the target data or log volume on '$Target'."
    }

    $dataBytes = (@($dataFiles | ForEach-Object { [double]$_.Size.Byte } | Measure-Object -Sum).Sum)
    $logBytes = (@($logFiles | ForEach-Object { [double]$_.Size.Byte } | Measure-Object -Sum).Sum)
    $dataRequiredGB = [math]::Round(([double]$dataBytes / 1GB), 2)
    $logRequiredGB = [math]::Round(([double]$logBytes / 1GB), 2)
    $bufferMultiplier = 1 + ($BufferPercent / 100)
    $dataRequiredWithBufferGB = [math]::Round($dataRequiredGB * $bufferMultiplier, 2)
    $logRequiredWithBufferGB = [math]::Round($logRequiredGB * $bufferMultiplier, 2)
    $dataFits = $dataVolume.FreeGB -ge $dataRequiredWithBufferGB
    $logFits = $logVolume.FreeGB -ge $logRequiredWithBufferGB
    $status = if ($dataFits -and $logFits) { 'Passed' } else { 'Failed' }
    $message = "Data requires $dataRequiredWithBufferGB GB including $BufferPercent% buffer; target has $($dataVolume.FreeGB) GB free. Log requires $logRequiredWithBufferGB GB including buffer; target has $($logVolume.FreeGB) GB free."

    [pscustomobject]@{
        Source = $Source
        Target = $Target
        Database = $Database
        Stage = 'CapacityPreflight'
        Status = $status
        DataFilesRequiredGB = $dataRequiredGB
        DataRequiredWithBufferGB = $dataRequiredWithBufferGB
        TargetDataPath = $targetPaths.Data
        TargetDataVolume = $dataVolume.Volume
        TargetDataCapacityGB = $dataVolume.CapacityGB
        TargetDataFreeGB = $dataVolume.FreeGB
        LogFilesRequiredGB = $logRequiredGB
        LogRequiredWithBufferGB = $logRequiredWithBufferGB
        TargetLogPath = $targetPaths.Log
        TargetLogVolume = $logVolume.Volume
        TargetLogCapacityGB = $logVolume.CapacityGB
        TargetLogFreeGB = $logVolume.FreeGB
        Message = $message
    }
}

function Get-MigrationServerObjectCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SqlInstance
    )

    [pscustomobject]@{
        LoginCount = @(Get-DbaLogin -SqlInstance $SqlInstance -EnableException -ErrorAction Stop).Count
        LinkedServerCount = @(Get-DbaLinkedServer -SqlInstance $SqlInstance -EnableException -ErrorAction Stop).Count
        AgentJobCount = @(Get-DbaAgentJob -SqlInstance $SqlInstance -EnableException -ErrorAction Stop).Count
    }
}

function Get-MigrationDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    foreach ($pair in $Configuration.SourceTargets) {
        $migrationMode = if ($pair.Contains('MigrationMode')) { [string]$pair.MigrationMode } else { 'Full' }
        $sourceConnection = Connect-DbaInstance -SqlInstance $pair.Source -ErrorAction Stop
        $targetConnection = Connect-DbaInstance -SqlInstance $pair.Target -ErrorAction Stop
        $sourceDisks = @(Get-DbaDiskSpace -ComputerName $sourceConnection.ComputerName -Unit GB -EnableException -ErrorAction Stop)
        $targetDisks = @(Get-DbaDiskSpace -ComputerName $targetConnection.ComputerName -Unit GB -EnableException -ErrorAction Stop)
        $targetPaths = Get-DbaDefaultPath -SqlInstance $pair.Target -EnableException -ErrorAction Stop
        $targetDataVolume = Get-MigrationVolumeDetails -Path $targetPaths.Data -Disks $targetDisks
        $targetLogVolume = Get-MigrationVolumeDetails -Path $targetPaths.Log -Disks $targetDisks
        $serverObjectCounts = Get-MigrationServerObjectCounts -SqlInstance $pair.Source

        foreach ($database in (Get-MigrationDatabase -SqlInstance $pair.Source -Configuration $Configuration)) {
            $files = @(Get-DbaDbFile -SqlInstance $pair.Source -Database $database.Name -EnableException -ErrorAction Stop)
            $tdeReadiness = Test-MigrationTdeReadiness -Source $pair.Source -Target $pair.Target `
                -Database $database.Name -MigrationMode $migrationMode
            $dataFiles = @($files | Where-Object TypeDescription -eq 'ROWS')
            $logFiles = @($files | Where-Object TypeDescription -eq 'LOG')
            $volumePaths = @($files | ForEach-Object { [System.IO.Path]::GetPathRoot($_.PhysicalName) } | Sort-Object -Unique)
            $sourceVolumeDetails = foreach ($volumePath in $volumePaths) {
                $volume = Get-MigrationVolumeDetails -Path $volumePath -Disks $sourceDisks
                if ($null -eq $volume.CapacityGB) {
                    "$($volume.Volume) (capacity/free space unavailable)"
                }
                else {
                    "$($volume.Volume) ($($volume.CapacityGB) GB total, $($volume.FreeGB) GB free, $($volume.PercentFree)% free)"
                }
            }
            $compatibility = [string]$database.Compatibility
            $compatibilityNumber = if ($compatibility -match '(\d+)$') { [int]$Matches[1] } else { $null }

            [pscustomobject]@{
                Source = $pair.Source
                Target = $pair.Target
                Database = $database.Name
                SizeMB = [math]::Round([double]$database.SizeMB, 2)
                SizeGB = [math]::Round([double]$database.SizeMB / 1024, 2)
                SourceLoginCount = $serverObjectCounts.LoginCount
                SourceLinkedServerCount = $serverObjectCounts.LinkedServerCount
                SourceAgentJobCount = $serverObjectCounts.AgentJobCount
                CompatibilityLevel = $compatibility
                CompatibilityLevelNumber = $compatibilityNumber
                State = $database.Status
                RecoveryModel = [string]$database.RecoveryModel
                TdeEncrypted = $tdeReadiness.TdeEncrypted
                TdeEncryptorThumbprint = $tdeReadiness.EncryptorThumbprint
                TdeTargetEncryptorReady = $tdeReadiness.TargetEncryptorReady
                TdePreflight = $tdeReadiness.Status
                TdeMessage = $tdeReadiness.Message
                DataFileCount = $dataFiles.Count
                LogFileCount = $logFiles.Count
                DataFileLocations = (@($dataFiles | ForEach-Object { "$($_.LogicalName): $($_.PhysicalName) ($($_.Size))" }) -join '; ')
                LogFileLocations = (@($logFiles | ForEach-Object { "$($_.LogicalName): $($_.PhysicalName) ($($_.Size))" }) -join '; ')
                SourceVolumeSpace = (@($sourceVolumeDetails) -join '; ')
                TargetDataPath = $targetPaths.Data
                TargetDataVolume = $targetDataVolume.Volume
                TargetDataCapacityGB = $targetDataVolume.CapacityGB
                TargetDataFreeGB = $targetDataVolume.FreeGB
                TargetDataPercentFree = $targetDataVolume.PercentFree
                TargetLogPath = $targetPaths.Log
                TargetLogVolume = $targetLogVolume.Volume
                TargetLogCapacityGB = $targetLogVolume.CapacityGB
                TargetLogFreeGB = $targetLogVolume.FreeGB
                TargetLogPercentFree = $targetLogVolume.PercentFree
                TargetCapacityPreflight = if ($migrationMode -eq 'SchemaOnly') {
                    'NotRequired'
                } else {
                    (Test-MigrationRestoreCapacity -Source $pair.Source -Target $pair.Target -Database $database.Name -BufferPercent $(if ($Configuration.Contains('RestoreSpaceBufferPercent')) { [double]$Configuration.RestoreSpaceBufferPercent } else { 20 })).Status
                }
                Status = 'Discovered'
            }
        }
    }
}

function Test-MigrationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    if (-not (Get-Module -Name dbatools)) {
        try {
            Import-Module dbatools -ErrorAction Stop
        }
        catch {
            throw "The dbatools module is required. Install it with Install-Module dbatools. $($_.Exception.Message)"
        }
    }

    foreach ($pair in $Configuration.SourceTargets) {
        $migrationMode = if ($pair.Contains('MigrationMode')) { [string]$pair.MigrationMode } else { 'Full' }
        $sourceMajor = $null
        foreach ($endpoint in @(
            @{ Role = 'Source'; Name = $pair.Source },
            @{ Role = 'Target'; Name = $pair.Target }
        )) {
            try {
                $instance = Connect-DbaInstance -SqlInstance $endpoint.Name -ErrorAction Stop
                $majorVersion = [int]$instance.VersionMajor
                # Supported: SQL Server 2012 (11) through 2025 (17); target must be the same or newer than source.
                $minimum = if ($endpoint.Role -eq 'Target' -and $sourceMajor) { $sourceMajor } else { 11 }
                $endpoint.AllowedVersions = @($minimum..17)
                if ($endpoint.Role -eq 'Source') { $sourceMajor = $majorVersion }
                $expectedVersions = if ($endpoint.Role -eq 'Target' -and $sourceMajor) {
                    "$minimum through 17 (same or newer than the source)"
                }
                else { '11 through 17' }
                if ($majorVersion -notin $endpoint.AllowedVersions) {
                    [pscustomobject]@{
                        Source = $pair.Source
                        Target = $pair.Target
                        Endpoint = $endpoint.Name
                        Role = $endpoint.Role
                        SqlVersionMajor = $majorVersion
                        Status = 'Failed'
                        Message = "Unsupported SQL Server version. Expected major version(s): $expectedVersions."
                    }
                }
                else {
                    [pscustomobject]@{
                        Source = $pair.Source
                        Target = $pair.Target
                        Endpoint = $endpoint.Name
                        Role = $endpoint.Role
                        SqlVersionMajor = $majorVersion
                        Status = 'Passed'
                        Message = 'Connection successful and SQL Server version is supported.'
                    }
                }
            }
            catch {
                [pscustomobject]@{
                    Source = $pair.Source
                    Target = $pair.Target
                    Endpoint = $endpoint.Name
                    Role = $endpoint.Role
                    SqlVersionMajor = $null
                    Status = 'Failed'
                    Message = $_.Exception.Message
                }
            }
        }
        if ($migrationMode -eq 'SchemaOnly' -or [string]::IsNullOrWhiteSpace([string]$pair.BackupPath)) {
            [pscustomobject]@{
                Source = $pair.Source
                Target = $pair.Target
                Endpoint = $pair.BackupPath
                Role = 'BackupPath'
                SqlVersionMajor = $null
                Status = 'Skipped'
                Message = if ($migrationMode -eq 'SchemaOnly') { 'Backup-path validation is not required for schema-only migration.' } else { 'No shared backup path entered; it is only required when migrating.' }
            }
            continue
        }
        try {
            $sourceCanSeeBackupPath = Test-DbaPath -SqlInstance $pair.Source -Path $pair.BackupPath -EnableException -ErrorAction Stop
            $targetCanSeeBackupPath = Test-DbaPath -SqlInstance $pair.Target -Path $pair.BackupPath -EnableException -ErrorAction Stop
            if ($sourceCanSeeBackupPath -and $targetCanSeeBackupPath) {
                [pscustomobject]@{
                    Source = $pair.Source
                    Target = $pair.Target
                    Endpoint = $pair.BackupPath
                    Role = 'BackupPath'
                    SqlVersionMajor = $null
                    Status = 'Passed'
                    Message = 'Backup path is visible to both SQL Server services.'
                }
            }
            else {
                [pscustomobject]@{
                    Source = $pair.Source
                    Target = $pair.Target
                    Endpoint = $pair.BackupPath
                    Role = 'BackupPath'
                    SqlVersionMajor = $null
                    Status = 'Failed'
                    Message = 'Backup path is not visible to both SQL Server services.'
                }
            }
        }
        catch {
            [pscustomobject]@{
                Source = $pair.Source
                Target = $pair.Target
                Endpoint = $pair.BackupPath
                Role = 'BackupPath'
                SqlVersionMajor = $null
                Status = 'Failed'
                Message = $_.Exception.Message
            }
        }
    }
}

function Get-MigrationReadinessAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Databases,

        [Parameter()]
        [ValidateSet('Full', 'SchemaOnly')]
        [string] $MigrationMode = 'Full',

        [Parameter()]
        [ValidateRange(0, 100)]
        [double] $BufferPercent = 20
    )

    if (-not (Get-Module -Name dbatools)) {
        try {
            Import-Module dbatools -ErrorAction Stop
        }
        catch {
            throw "The dbatools module is required. Install it with Install-Module dbatools. $($_.Exception.Message)"
        }
    }

    $sourceConnection = $null
    $targetConnection = $null
    $sourceConnectionError = $null
    $targetConnectionError = $null
    try { $sourceConnection = Connect-DbaInstance -SqlInstance $Source -ErrorAction Stop }
    catch { $sourceConnectionError = $_.Exception.Message }
    try { $targetConnection = Connect-DbaInstance -SqlInstance $Target -ErrorAction Stop }
    catch { $targetConnectionError = $_.Exception.Message }

    $sourceMajor = if ($sourceConnection) { [int]$sourceConnection.VersionMajor } else { $null }
    $targetMajor = if ($targetConnection) { [int]$targetConnection.VersionMajor } else { $null }
    $targetFullTextInstalled = $null
    $targetFilestreamConfigured = $null
    if ($targetConnection) {
        try {
            $serverFeatures = @(Invoke-DbaQuery -SqlInstance $Target -Database master -EnableException -ErrorAction Stop -Query @'
SELECT
    CONVERT(bit, SERVERPROPERTY('IsFullTextInstalled')) AS IsFullTextInstalled,
    CONVERT(int, SERVERPROPERTY('FilestreamConfiguredLevel')) AS FilestreamConfiguredLevel;
'@)
            if ($serverFeatures.Count -eq 1) {
                $targetFullTextInstalled = [bool]$serverFeatures[0].IsFullTextInstalled
                $targetFilestreamConfigured = [int]$serverFeatures[0].FilestreamConfiguredLevel
            }
        }
        catch {
            $targetFullTextInstalled = $null
            $targetFilestreamConfigured = $null
        }
    }

    foreach ($database in $Databases) {
        $findings = [System.Collections.Generic.List[object]]::new()
        $addFinding = {
            param(
                [string] $Category,
                [string] $Severity,
                [string] $Check,
                [string] $Status,
                [string] $Details,
                [string] $Recommendation
            )
            $findings.Add([pscustomobject]@{
                Category = $Category
                Severity = $Severity
                Check = $Check
                Status = $Status
                Details = $Details
                Recommendation = $Recommendation
            })
        }

        if ($sourceConnectionError) {
            & $addFinding 'Connectivity' 'Critical' 'Connect to source' 'Failed' `
                "Could not connect to source '$Source': $sourceConnectionError" `
                'Resolve source SQL connectivity and permissions, then rerun the assessment.'
        }
        if ($targetConnectionError) {
            & $addFinding 'Connectivity' 'Critical' 'Connect to target' 'Failed' `
                "Could not connect to target '$Target': $targetConnectionError" `
                'Resolve target SQL connectivity and permissions, then rerun the assessment.'
        }
        if ($sourceConnectionError -or $targetConnectionError) {
            [pscustomobject]@{
                Source = $Source
                Target = $Target
                Database = $database
                SourceVersionMajor = $sourceMajor
                TargetVersionMajor = $targetMajor
                AssessedAt = [DateTime]::UtcNow.ToString('o')
                Readiness = 'Blocked'
                Findings = $findings.ToArray()
            }
            continue
        }

        if ($sourceMajor -lt 11 -or $sourceMajor -gt 17) {
            & $addFinding 'Platform compatibility' 'Critical' 'Source SQL Server version' 'Failed' `
                "Source major version $sourceMajor is outside the supported range 11-17." `
                'Use a supported source SQL Server version or a separately validated migration path.'
        }
        else {
            & $addFinding 'Platform compatibility' 'Information' 'Source SQL Server version' 'Passed' `
                "Source SQL Server major version: $sourceMajor." 'Confirm the exact edition and servicing level required by your change policy.'
        }
        if ($targetMajor -lt 11 -or $targetMajor -gt 17) {
            & $addFinding 'Platform compatibility' 'Critical' 'Target SQL Server version' 'Failed' `
                "Target major version $targetMajor is outside the supported range 11-17." `
                'Use a supported target SQL Server version or a separately validated migration path.'
        }
        elseif ($targetMajor -lt $sourceMajor) {
            & $addFinding 'Platform compatibility' 'Critical' 'Target is older than source' 'Failed' `
                "Target SQL Server major version $targetMajor is older than source version $sourceMajor." `
                'Choose a target at the same or a newer SQL Server version, or design a tested downgrade/export-import.'
        }
        else {
            & $addFinding 'Platform compatibility' 'Information' 'Target SQL Server version' 'Passed' `
                "Target SQL Server major version $targetMajor is the same as or newer than source version $sourceMajor." `
                'Verify feature, edition, and application compatibility for this target release.'
        }

        $escapedDatabase = $database.Replace("'", "''")
        try {
            $databaseMetadata = @(Invoke-DbaQuery -SqlInstance $Source -Database master -EnableException -ErrorAction Stop -Query @"
SELECT
    d.name AS DatabaseName,
    d.state_desc AS State,
    d.compatibility_level AS CompatibilityLevel,
    d.recovery_model_desc AS RecoveryModel,
    d.is_encrypted AS IsEncrypted,
    d.is_cdc_enabled AS IsCdcEnabled,
    d.is_published AS IsPublished,
    d.is_subscribed AS IsSubscribed,
    d.is_broker_enabled AS IsBrokerEnabled,
    d.is_trustworthy_on AS IsTrustworthyOn,
    d.is_db_chaining_on AS IsDbChainingOn
FROM sys.databases AS d
WHERE d.name = N'$escapedDatabase';
"@)
            if ($databaseMetadata.Count -ne 1) {
                & $addFinding 'Database inventory' 'Critical' 'Source database exists' 'Failed' `
                    "Database '$database' was not found on source '$Source'." `
                    'Refresh discovery and select a database that exists on the source.'
                [pscustomobject]@{
                    Source = $Source
                    Target = $Target
                    Database = $database
                    SourceVersionMajor = $sourceMajor
                    TargetVersionMajor = $targetMajor
                    AssessedAt = [DateTime]::UtcNow.ToString('o')
                    Readiness = 'Blocked'
                    Findings = $findings.ToArray()
                }
                continue
            }
        }
        catch {
            & $addFinding 'Database inventory' 'Critical' 'Read source database metadata' 'Failed' `
                "Could not read database '$database' metadata: $($_.Exception.Message)" `
                'Grant the assessment identity permission to view the source database metadata, then rerun.'
            [pscustomobject]@{
                Source = $Source
                Target = $Target
                Database = $database
                SourceVersionMajor = $sourceMajor
                TargetVersionMajor = $targetMajor
                AssessedAt = [DateTime]::UtcNow.ToString('o')
                Readiness = 'Blocked'
                Findings = $findings.ToArray()
            }
            continue
        }

        $metadata = $databaseMetadata[0]
        if ($metadata.State -ne 'ONLINE') {
            & $addFinding 'Database state' 'Critical' 'Source database online' 'Failed' `
                "Source database state is '$($metadata.State)'." `
                'Bring the source database online and rerun the assessment.'
        }
        else {
            & $addFinding 'Database state' 'Information' 'Source database online' 'Passed' `
                'Source database is online.' 'No action required.'
        }

        $compatibilityLevel = [int]$metadata.CompatibilityLevel
        if ($compatibilityLevel -gt ($targetMajor * 10)) {
            & $addFinding 'Platform compatibility' 'Critical' 'Database compatibility level' 'Failed' `
                "Source database compatibility level $compatibilityLevel is higher than the target engine's maximum supported level $($targetMajor * 10)." `
                'Upgrade the target SQL Server version or lower the source database compatibility level only after application testing.'
        }
        else {
            & $addFinding 'Platform compatibility' 'Information' 'Database compatibility level' 'Passed' `
                "Source database compatibility level is $compatibilityLevel; target engine maximum is $($targetMajor * 10)." `
                'The restored database generally retains its current compatibility level; plan any compatibility-level change separately and test it.'
        }

        try {
            $targetDatabase = @(Invoke-DbaQuery -SqlInstance $Target -Database master -EnableException -ErrorAction Stop -Query @"
SELECT name, state_desc AS State
FROM sys.databases
WHERE name = N'$escapedDatabase';
"@)
            if ($targetDatabase.Count -gt 0) {
                & $addFinding 'Target state' 'Warning' 'Target database name already exists' 'Review' `
                    "A database named '$database' already exists on target '$Target' (state: $($targetDatabase[0].State)). Assessment is read-only and will not change or replace it." `
                    'Confirm ownership and take a recoverable backup. The migration must explicitly authorize any database replacement.'
            }
            else {
                & $addFinding 'Target state' 'Information' 'Target database name available' 'Passed' `
                    "No database named '$database' currently exists on target '$Target'." 'No action required.'
            }
        }
        catch {
            & $addFinding 'Target state' 'Warning' 'Check target database name' 'Not verified' `
                "Could not verify whether '$database' exists on target: $($_.Exception.Message)" `
                'Grant permission to view target database metadata and rerun; do not assume the name is available.'
        }

        try {
            $featureQuery = if ($sourceMajor -ge 12) {
                @'
SELECT
    (SELECT COUNT(*) FROM sys.fulltext_catalogs) AS FullTextCatalogCount,
    (SELECT COUNT(*) FROM sys.tables WHERE is_memory_optimized = 1) AS MemoryOptimizedTableCount,
    (SELECT COUNT(*) FROM sys.database_files WHERE type = 2) AS FileStreamFileCount,
    (SELECT COUNT(*) FROM sys.tables WHERE is_filetable = 1) AS FileTableCount;
'@
            }
            else {
                @'
SELECT
    (SELECT COUNT(*) FROM sys.fulltext_catalogs) AS FullTextCatalogCount,
    0 AS MemoryOptimizedTableCount,
    (SELECT COUNT(*) FROM sys.database_files WHERE type = 2) AS FileStreamFileCount,
    (SELECT COUNT(*) FROM sys.tables WHERE is_filetable = 1) AS FileTableCount;
'@
            }
            $features = @(Invoke-DbaQuery -SqlInstance $Source -Database $database -EnableException -ErrorAction Stop -Query $featureQuery)
            if ($features.Count -ne 1) { throw 'Feature inventory query returned no result.' }
            $feature = $features[0]

            if ([int]$feature.FullTextCatalogCount -gt 0 -and $targetFullTextInstalled -eq $false) {
                & $addFinding 'Feature support' 'Critical' 'Full-Text Search support' 'Failed' `
                    "Source database has $($feature.FullTextCatalogCount) Full-Text catalog(s), but Full-Text Search is not installed on the target." `
                    'Install and enable the matching SQL Server Full-Text Search feature on the target before migration.'
            }
            elseif ([int]$feature.FullTextCatalogCount -gt 0 -and $null -eq $targetFullTextInstalled) {
                & $addFinding 'Feature support' 'Warning' 'Full-Text Search support' 'Not verified' `
                    "Source database has $($feature.FullTextCatalogCount) Full-Text catalog(s), but target Full-Text Search support could not be verified." `
                    'Verify that Full-Text Search is installed on the target before migration.'
            }
            elseif ([int]$feature.FullTextCatalogCount -gt 0) {
                & $addFinding 'Feature support' 'Information' 'Full-Text Search support' 'Passed' `
                    "Source database has $($feature.FullTextCatalogCount) Full-Text catalog(s); target reports Full-Text Search installed." `
                    'Validate full-text indexes and language resources after migration.'
            }

            if ([int]$feature.FileStreamFileCount -gt 0 -and $null -eq $targetFilestreamConfigured) {
                & $addFinding 'Feature support' 'Warning' 'FILESTREAM target configuration' 'Not verified' `
                    "Source database uses $($feature.FileStreamFileCount) FILESTREAM data file(s), but target FILESTREAM configuration could not be verified." `
                    'Check the target SQL Server FILESTREAM configuration and Windows share access.'
            }
            elseif ([int]$feature.FileStreamFileCount -gt 0 -and $targetFilestreamConfigured -eq 0) {
                & $addFinding 'Feature support' 'Critical' 'FILESTREAM target configuration' 'Failed' `
                    "Source database uses $($feature.FileStreamFileCount) FILESTREAM data file(s), but FILESTREAM is not configured on the target." `
                    'Enable and configure FILESTREAM on the target as required by the application.'
            }
            elseif ([int]$feature.FileStreamFileCount -gt 0) {
                & $addFinding 'Feature support' 'Warning' 'FILESTREAM target configuration' 'Review' `
                    "Source database uses $($feature.FileStreamFileCount) FILESTREAM data file(s)." `
                    'Verify target FILESTREAM configuration, Windows access, paths, and application behavior.'
            }

            if ([int]$feature.MemoryOptimizedTableCount -gt 0) {
                & $addFinding 'Feature support' 'Warning' 'In-Memory OLTP objects' 'Review' `
                    "Source database contains $($feature.MemoryOptimizedTableCount) memory-optimized table(s)." `
                    'Verify target edition and In-Memory OLTP capacity, and include memory-optimized objects in application testing.'
            }
            if ([int]$feature.FileTableCount -gt 0) {
                & $addFinding 'Feature support' 'Warning' 'FileTables' 'Review' `
                    "Source database contains $($feature.FileTableCount) FileTable(s)." `
                    'Verify FILESTREAM setup, Windows share access, and FileTable application dependencies on the target.'
            }
            if ($metadata.IsCdcEnabled -or $metadata.IsPublished -or $metadata.IsSubscribed) {
                & $addFinding 'Operational dependencies' 'Warning' 'CDC or replication configuration' 'Review' `
                    "CDC: $($metadata.IsCdcEnabled); published: $($metadata.IsPublished); subscribed: $($metadata.IsSubscribed)." `
                    'Plan CDC/replication reconfiguration and validate downstream consumers; these server/database relationships may require explicit migration steps.'
            }
            if ($metadata.IsBrokerEnabled) {
                & $addFinding 'Operational dependencies' 'Warning' 'Service Broker' 'Review' `
                    'Service Broker is enabled on the source database.' `
                    'Validate broker identifiers, routes, endpoints, security, and dependent services after migration.'
            }
            if ($metadata.IsTrustworthyOn -or $metadata.IsDbChainingOn) {
                & $addFinding 'Security' 'Warning' 'Elevated database trust settings' 'Review' `
                    "TRUSTWORTHY: $($metadata.IsTrustworthyOn); DB_CHAINING: $($metadata.IsDbChainingOn)." `
                    'Review whether these settings are required; avoid enabling elevated trust or cross-database ownership chaining without security approval.'
            }
        }
        catch {
            & $addFinding 'Feature support' 'Warning' 'Read database feature inventory' 'Not verified' `
                "Could not complete the feature inventory: $($_.Exception.Message)" `
                'Grant metadata visibility on the source database and rerun; treat unverified features as unresolved.'
        }

        try {
            $moduleQuery = @'
SELECT TOP (200)
    QUOTENAME(OBJECT_SCHEMA_NAME(m.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(m.object_id)) AS ModuleName,
    candidate.PatternName
FROM sys.sql_modules AS m
CROSS APPLY (VALUES
    (N'Legacy *= outer-join operator', N'%*=%'),
    (N'Legacy =* outer-join operator', N'%=*%'),
    (N'Deprecated sp_dboption procedure', N'%sp_dboption%'),
    (N'Deprecated DBCC DBREINDEX command', N'%DBCC DBREINDEX%'),
    (N'Deprecated DBCC SHOWCONTIG command', N'%DBCC SHOWCONTIG%'),
    (N'Deprecated text data type', N'%text%'),
    (N'Deprecated ntext data type', N'%ntext%'),
    (N'Deprecated image data type', N'%image%')
) AS candidate(PatternName, Pattern)
WHERE m.definition LIKE candidate.Pattern
ORDER BY candidate.PatternName, ModuleName;
'@
            $moduleCandidates = @(Invoke-DbaQuery -SqlInstance $Source -Database $database -EnableException -ErrorAction Stop -Query $moduleQuery)
            $moduleCandidates = @($moduleCandidates | Sort-Object PatternName, ModuleName -Unique)
            foreach ($candidate in $moduleCandidates) {
                & $addFinding 'Code compatibility' 'Warning' ([string]$candidate.PatternName) 'Candidate reference' `
                    "A static text scan found a possible reference in module '$($candidate.ModuleName)'. This may be a false positive (for example, comments or string literals)." `
                    'Review the module definition and runtime usage manually; this lexical scan does not parse or execute T-SQL.'
            }
            if ($moduleCandidates.Count -eq 0) {
                & $addFinding 'Code compatibility' 'Information' 'Known legacy syntax scan' 'No candidate references found' `
                    'No matches were found for the limited set of known legacy syntax patterns scanned.' `
                    'This limited scan is not exhaustive and does not establish application compatibility.'
            }
        }
        catch {
            & $addFinding 'Code compatibility' 'Warning' 'Known legacy syntax scan' 'Not verified' `
                "Could not scan stored module definitions: $($_.Exception.Message)" `
                'Grant VIEW DEFINITION on the database and rerun; review application and dynamic SQL separately.'
        }

        if ([bool]$metadata.IsEncrypted) {
            $tdeReadiness = Test-MigrationTdeReadiness -Source $Source -Target $Target -Database $database -MigrationMode $MigrationMode
            $tdeSeverity = if ($tdeReadiness.Status -eq 'Passed') { 'Information' } else { 'Critical' }
            & $addFinding 'Encryption' $tdeSeverity 'Transparent Data Encryption' $tdeReadiness.Status `
                $tdeReadiness.Message `
                'Back up and securely transfer the TDE certificate or asymmetric key and private key; verify it on the target before restoring.'
        }
        else {
            & $addFinding 'Encryption' 'Information' 'Transparent Data Encryption' 'Not enabled' `
                'Source database is not encrypted with TDE.' 'No TDE key transfer is required.'
        }

        if ($MigrationMode -eq 'SchemaOnly') {
            & $addFinding 'Capacity' 'Information' 'Target restore capacity' 'Not required' `
                'Schema-only migration does not restore database data or log files.' `
                'Confirm the target has appropriate space for schema objects and application growth.'
        }
        else {
            try {
                $capacity = Test-MigrationRestoreCapacity -Source $Source -Target $Target -Database $database -BufferPercent $BufferPercent
                if ($capacity.Status -eq 'Failed') {
                    & $addFinding 'Capacity' 'Critical' 'Target restore capacity' 'Failed' `
                        ([string]$capacity.Message) `
                        'Free target data and log volume space or adjust the target file layout, then rerun the assessment.'
                }
                else {
                    & $addFinding 'Capacity' 'Information' 'Target restore capacity' 'Passed' `
                        ([string]$capacity.Message) 'Recheck capacity immediately before migration; this estimate can change.'
                }
            }
            catch {
                & $addFinding 'Capacity' 'Warning' 'Target restore capacity' 'Not verified' `
                    "Could not verify target restore capacity: $($_.Exception.Message)" `
                    'Check target data/log file paths and available disk space, then rerun; capacity was not assumed to be sufficient.'
            }
        }

        $readiness = if (@($findings | Where-Object Severity -eq 'Critical').Count -gt 0) {
            'Blocked'
        }
        elseif (@($findings | Where-Object Severity -eq 'Warning').Count -gt 0) {
            'Review required'
        }
        else {
            'No blockers detected'
        }
        [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $database
            SourceVersionMajor = $sourceMajor
            TargetVersionMajor = $targetMajor
            AssessedAt = [DateTime]::UtcNow.ToString('o')
            Readiness = $readiness
            Findings = $findings.ToArray()
        }
    }
}

Export-ModuleMember -Function Get-MigrationDiscovery, Get-MigrationServerObjectCounts, Test-MigrationRestoreCapacity, Test-MigrationTdeReadiness, Test-MigrationConfiguration, Get-MigrationReadinessAssessment
