Set-StrictMode -Version Latest

function Invoke-MigrationSafeRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SqlInstance,
        [Parameter(Mandatory)][string[]] $Path,
        [Parameter(Mandatory)][string] $DatabaseName,
        [Parameter(Mandatory)][string] $DestinationDataDirectory,
        [Parameter(Mandatory)][string] $DestinationLogDirectory,
        [Parameter()][bool] $AllowFileCollisionRetry = $false
    )

    $restoreParameters = @{
        SqlInstance = $SqlInstance
        Path = $Path
        DatabaseName = $DatabaseName
        DestinationDataDirectory = $DestinationDataDirectory
        DestinationLogDirectory = $DestinationLogDirectory
        WithReplace = $true
        EnableException = $true
        ErrorAction = 'Stop'
        WarningAction = 'Stop'
    }
    try {
        Restore-DbaDatabase @restoreParameters | Out-Null
    }
    catch {
        $collisionMessages = [System.Collections.Generic.List[string]]::new()
        for ($exception = $_.Exception; $exception; $exception = $exception.InnerException) {
            if ($exception.Message) {
                $collisionMessages.Add($exception.Message)
            }
        }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $collisionMessages.Add($_.ErrorDetails.Message)
        }
        $collisionMessage = $collisionMessages -join "`n"
        if (-not $AllowFileCollisionRetry -or
            $collisionMessage -notmatch '(?is)already exists.*not owned by any database') {
            throw
        }

        $restoreParameters.DestinationFilePrefix = 'mig_' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '_'
        Restore-DbaDatabase @restoreParameters | Out-Null
        [pscustomobject]@{
            FileCollisionRetry = $true
            DestinationFilePrefix = $restoreParameters.DestinationFilePrefix
        }
    }
}

function Test-MigrationFullTextReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Database
    )

    try {
        $sourceFeatures = @(Invoke-DbaQuery -SqlInstance $Source -Database $Database -EnableException -ErrorAction Stop -Query @'
SELECT
    (SELECT COUNT_BIG(*) FROM sys.fulltext_indexes) AS FullTextIndexCount,
    (SELECT COUNT_BIG(*) FROM sys.sql_modules
     WHERE definition LIKE N'%CONTAINS%' OR definition LIKE N'%FREETEXT%') AS FullTextPredicateModuleCount;
'@)
        $targetFeatures = @(Invoke-DbaQuery -SqlInstance $Target -Database master -EnableException -ErrorAction Stop -Query @'
SELECT CONVERT(int, FULLTEXTSERVICEPROPERTY('IsFullTextInstalled')) AS FullTextInstalled;
'@)
        if ($sourceFeatures.Count -ne 1 -or $targetFeatures.Count -ne 1) {
            throw "Could not determine full-text requirements on '$Source' and feature availability on '$Target'."
        }
    }
    catch {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'FullTextPreflight'
            Status = 'Failed'
            SourceFullTextIndexCount = $null
            SourceFullTextPredicateModuleCount = $null
            TargetFullTextInstalled = $null
            Message = "Could not verify full-text readiness: $($_.Exception.Message)"
        }
    }

    $indexCount = [long]$sourceFeatures[0].FullTextIndexCount
    $predicateModuleCount = [long]$sourceFeatures[0].FullTextPredicateModuleCount
    $targetInstalled = $targetFeatures[0].FullTextInstalled -eq 1
    $requiresFullText = $indexCount -gt 0 -or $predicateModuleCount -gt 0
    if ($requiresFullText -and -not $targetInstalled) {
        return [pscustomobject]@{
            Source = $Source
            Target = $Target
            Database = $Database
            Stage = 'FullTextPreflight'
            Status = 'Failed'
            SourceFullTextIndexCount = $indexCount
            SourceFullTextPredicateModuleCount = $predicateModuleCount
            TargetFullTextInstalled = $false
            Message = "Source database uses full-text search ($indexCount index(es), $predicateModuleCount dependent module(s)), but Full-Text Search is not installed on '$Target'. Install the SQL Server Full-Text Search feature on the target before migrating."
        }
    }

    [pscustomobject]@{
        Source = $Source
        Target = $Target
        Database = $Database
        Stage = 'FullTextPreflight'
        Status = 'Passed'
        SourceFullTextIndexCount = $indexCount
        SourceFullTextPredicateModuleCount = $predicateModuleCount
        TargetFullTextInstalled = $targetInstalled
        Message = if ($requiresFullText) {
            'Target Full-Text Search is installed and supports the source database full-text objects.'
        } else {
            'Source database has no full-text indexes or dependent modules.'
        }
    }
}

function Invoke-MigrationTrackedDatabaseOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Backup', 'Restore')][string] $Operation,
        [Parameter(Mandatory)][string] $SqlInstance,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Database,
        [Parameter()][string] $TargetDatabaseName = '',
        [Parameter(Mandatory)][AllowEmptyString()][string] $ProgressPath,
        [Parameter()][string] $BackupDirectory = '',
        [Parameter()][int] $BackupFileCount = 4,
        [Parameter()][string[]] $BackupFiles = @(),
        [Parameter()][string] $DestinationDataDirectory = '',
        [Parameter()][string] $DestinationLogDirectory = '',
        [Parameter()][bool] $AllowFileCollisionRetry = $false,
        [Parameter()][bool] $TrustServerCertificate = $true,
        [Parameter(Mandatory)][string] $TransferModulePath
    )

    $job = Start-Job -Name "$Operation-$Database" -ArgumentList @(
        $Operation, $SqlInstance, $Database, $TargetDatabaseName, $BackupDirectory, $BackupFileCount,
        (ConvertTo-Json -InputObject $BackupFiles -Compress),
        $DestinationDataDirectory, $DestinationLogDirectory, $AllowFileCollisionRetry,
        $TrustServerCertificate, $TransferModulePath
    ) -ScriptBlock {
        param(
            [string]$JobOperation,
            [string]$JobSqlInstance,
            [string]$JobDatabase,
            [string]$JobTargetDatabaseName,
            [string]$JobBackupDirectory,
            [int]$JobBackupFileCount,
            [string]$JobBackupFilesJson,
            [string]$JobDestinationDataDirectory,
            [string]$JobDestinationLogDirectory,
            [bool]$JobAllowFileCollisionRetry,
            [bool]$JobTrustServerCertificate,
            [string]$JobTransferModulePath
        )

        Import-Module dbatools -ErrorAction Stop
        $null = Set-DbatoolsConfig -FullName 'sql.connection.encrypt' -Value $true -ErrorAction Stop
        $null = Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $JobTrustServerCertificate -ErrorAction Stop
        if ($JobOperation -eq 'Backup') {
            Backup-DbaDatabase -SqlInstance $JobSqlInstance -Database $JobDatabase `
                -Path $JobBackupDirectory -FileCount $JobBackupFileCount `
                -Type Full -CopyOnly -Checksum -CompressBackup -Verify `
                -EnableException -ErrorAction Stop -WarningAction Stop | Out-Null
            return
        }

        $jobBackupFiles = @(ConvertFrom-Json -InputObject $JobBackupFilesJson -ErrorAction Stop)
        Import-Module $JobTransferModulePath -Force -ErrorAction Stop
        $restoreDatabaseName = if ([string]::IsNullOrWhiteSpace($JobTargetDatabaseName)) {
            $JobDatabase
        } else {
            $JobTargetDatabaseName
        }
        Invoke-MigrationSafeRestore -SqlInstance $JobSqlInstance -Path $jobBackupFiles `
            -DatabaseName $restoreDatabaseName -DestinationDataDirectory $JobDestinationDataDirectory `
            -DestinationLogDirectory $JobDestinationLogDirectory `
            -AllowFileCollisionRetry $JobAllowFileCollisionRetry
    }

    $escapedDatabase = $Database.Replace("'", "''")
    $progressQuery = @"
SELECT TOP (1)
    CONVERT(int, percent_complete) AS PercentComplete,
    CONVERT(bigint, cpu_time) AS CpuTimeMilliseconds,
    CONVERT(bigint, total_elapsed_time) AS ElapsedMilliseconds
FROM sys.dm_exec_requests
WHERE database_id = DB_ID(N'$escapedDatabase')
  AND (command LIKE 'BACKUP%' OR command LIKE 'RESTORE%')
ORDER BY start_time DESC;
"@
    $lastProgressAt = [DateTime]::MinValue
    $lastHeartbeatAt = [DateTime]::UtcNow
    $lastPercentComplete = -1
    $progressQueryFailed = $false

    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            $now = [DateTime]::UtcNow
            if ($ProgressPath -and -not $progressQueryFailed -and ($now - $lastProgressAt).TotalSeconds -ge 2) {
                $lastProgressAt = $now
                try {
                    $operationProgress = Invoke-DbaQuery -SqlInstance $SqlInstance -Database master `
                        -Query $progressQuery -EnableException -ErrorAction Stop | Select-Object -First 1
                    if ($operationProgress) {
                        $percentComplete = [int]$operationProgress.PercentComplete
                        if ($percentComplete -ne $lastPercentComplete) {
                            $lastPercentComplete = $percentComplete
                            $cpuSeconds = [math]::Round(([double]$operationProgress.CpuTimeMilliseconds / 1000), 1)
                            $elapsedSeconds = [math]::Round(([double]$operationProgress.ElapsedMilliseconds / 1000), 1)
                            Write-MigrationProgressEvent -ProgressPath $ProgressPath `
                                -Source $Source -Target $Target -Database $Database -Stage $Operation `
                                -Status 'InProgress' -PercentComplete $percentComplete `
                                -Message ("SQL Server reports {0} progress; request CPU {1}s, elapsed {2}s." -f `
                                    $Operation.ToLowerInvariant(), $cpuSeconds, $elapsedSeconds)
                        }
                    }
                }
                catch {
                    $progressQueryFailed = $true
                    Write-MigrationProgressEvent -ProgressPath $ProgressPath `
                        -Source $Source -Target $Target -Database $Database -Stage $Operation `
                        -Status 'InProgress' -PercentComplete $lastPercentComplete `
                        -Message "SQL operation continues; live percentage is unavailable because its progress query failed: $($_.Exception.Message)"
                }
            }
            $null = Wait-Job -Job $job -Timeout 1
            if ($ProgressPath -and ($now - $lastHeartbeatAt).TotalSeconds -ge 10) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath `
                    -Source $Source -Target $Target -Database $Database -Stage $Operation `
                    -Status 'InProgress' -PercentComplete $lastPercentComplete `
                    -Message "$Operation is still running; waiting for SQL Server progress."
                $lastHeartbeatAt = [DateTime]::UtcNow
            }
        }

        if ($job.State -ne 'Completed') {
            $jobError = $job.ChildJobs[0].JobStateInfo.Reason
            if ($jobError) {
                throw $jobError
            }
            throw "$Operation job ended in state '$($job.State)'."
        }
        $jobOutput = @(Receive-Job -Job $job -ErrorAction Stop)
        foreach ($retryResult in $jobOutput) {
            if ($ProgressPath -and $retryResult -and
                $retryResult.PSObject.Properties.Name -contains 'FileCollisionRetry' -and $retryResult.FileCollisionRetry) {
                Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Source -Target $Target `
                    -Database $Database -Stage $Operation -Status 'InProgress' `
                    -Message "A destination file already exists outside this database on '$SqlInstance'. Retrying with unique destination filenames; the existing file is not overwritten. Prefix: $($retryResult.DestinationFilePrefix)"
            }
        }
    }
    finally {
        if ($job.State -in @('NotStarted', 'Running')) {
            $null = Wait-Job -Job $job
        }
        Remove-Job -Job $job -Force -ErrorAction Stop
    }
}

function Invoke-DatabaseMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pair,
        [Parameter(Mandatory)][object[]] $Databases,
        [Parameter(Mandatory)][string] $StatePath,
        [Parameter(Mandatory)][ValidateRange(1, 128)][int] $ThrottleLimit,
        [Parameter(Mandatory)][string] $ModulePath,
        [Parameter(Mandatory)][string] $TransferModulePath,
        [Parameter(Mandatory)][string] $DestinationDataDirectory,
        [Parameter(Mandatory)][string] $DestinationLogDirectory,
        [Parameter(Mandatory)][ValidateRange(1, 32)][int] $BackupFileCount,
        [Parameter()][string[]] $OverwriteDatabases = @(),
        [Parameter()][bool] $AllowTargetReplace = $false,
        [Parameter()][bool] $TrustServerCertificate = $true,
        [Parameter()][string] $ProgressPath = '',
        [Parameter()][string] $ControlPath = ''
    )

    $databasePlans = @($Databases | ForEach-Object {
        $sourceDatabase = [string]$_.Name
        $targetDatabaseName = if ($_.PSObject.Properties.Name -contains 'TargetDatabaseName' -and $_.TargetDatabaseName) {
            [string]$_.TargetDatabaseName
        } else {
            $sourceDatabase
        }
        $targetCompatibilityLevel = if ($_.PSObject.Properties.Name -contains 'TargetCompatibilityLevel') {
            $_.TargetCompatibilityLevel
        } else {
            $null
        }
        [pscustomobject]@{
            SourceDatabase = $sourceDatabase
            TargetDatabase = $targetDatabaseName
            TargetCompatibilityLevel = $targetCompatibilityLevel
        }
    })
    if ($databasePlans.Count -eq 0) {
        return
    }

    $databasePlans | ForEach-Object -Parallel {
        Import-Module $using:ModulePath -Force
        Import-Module $using:TransferModulePath -Force
        Import-Module dbatools -ErrorAction Stop
        Set-MigrationSqlConnectionSettings -TrustServerCertificate $using:TrustServerCertificate
        $source = $using:Pair.Source
        $target = $using:Pair.Target
        $database = $_.SourceDatabase
        $targetDatabase = $_.TargetDatabase
        $targetCompatibilityLevel = $_.TargetCompatibilityLevel
        $statePath = $using:StatePath
        $runBackupDirectory = $using:Pair.BackupPath
        $destinationDataDirectory = $using:DestinationDataDirectory
        $destinationLogDirectory = $using:DestinationLogDirectory
        $allowFileCollisionRetry = $false
        $backupFileCount = $using:BackupFileCount
        $progressPath = $using:ProgressPath
        $controlPath = $using:ControlPath
        $databaseBackupDirectory = Get-MigrationDatabaseBackupDirectory -RunDirectory $runBackupDirectory `
            -Source $source -Target $target -Database $database
        $backupPath = $databaseBackupDirectory
        $backupCompleted = $false
        try {
            $null = Wait-MigrationControl -ControlPath $controlPath -ProgressPath $progressPath `
                -Source $source -Target $target -Database $database
            $state = Get-MigrationState -Path $statePath
            $stateKey = Get-MigrationStateKey -Source $source -Target $target -Database $database
            $entry = $state.Databases[$stateKey]
            $completedStateNeedsRepair = $false
            $targetDatabaseExists = Test-MigrationDatabaseExists -SqlInstance $target -Database $targetDatabase
            $stateTargetDatabase = if ($entry -and $entry.TargetDatabase) {
                [string]$entry.TargetDatabase
            } else {
                [string]$database
            }
            $entryMatchesTarget = $entry -and [string]::Equals(
                $stateTargetDatabase, $targetDatabase, [StringComparison]::OrdinalIgnoreCase)
            if ($entryMatchesTarget -and $entry.Status -eq 'Completed') {
                $overwriteApproved = $using:AllowTargetReplace -or $database -in $using:OverwriteDatabases
                if ($targetDatabaseExists -and -not $overwriteApproved) {
                    [pscustomobject]@{ Source = $source; Target = $target; Database = $database; Stage = 'Database'; Status = 'Skipped'; BackupPath = $entry.BackupPath; Message = 'Already completed and present on target.' }
                    return
                }

                $completedStateNeedsRepair = $true
            }
            $allowFileCollisionRetry = -not $targetDatabaseExists
            $fullTextReadiness = Test-MigrationFullTextReadiness -Source $source -Target $target -Database $database
            if ($fullTextReadiness.Status -ne 'Passed') {
                throw $fullTextReadiness.Message
            }

            $backupIsReusable = $false
            $stripeFiles = @()
            if ($entry -and $entry.Status -in @('BackupCompleted', 'Completed') -and $entry.BackupPath) {
                if (Test-Path -LiteralPath $entry.BackupPath -PathType Leaf) {
                    $backupPath = $entry.BackupPath
                    $backupIsReusable = $true
                }
                elseif (Test-Path -LiteralPath $entry.BackupPath -PathType Container) {
                    $stripeFiles = @(Get-MigrationBackupStripeFiles -Directory $entry.BackupPath `
                        -Database $database -FileCount $backupFileCount)
                    $backupPath = $entry.BackupPath
                    $backupIsReusable = $stripeFiles.Count -eq $backupFileCount
                }
            }
            if ($backupIsReusable) {
                $backupCompleted = $true
                if ($progressPath) {
                    Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                        -Database $database -Stage 'Backup' -Status 'Completed' -Message 'Reusing verified backup stripes.'
                }
            }
            else {
                $backupPath = $databaseBackupDirectory
                if (-not (Test-Path -LiteralPath $databaseBackupDirectory -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $databaseBackupDirectory -Force
                }
                if ($progressPath) {
                    Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                        -Database $database -Stage 'Backup' -Status 'Started' -Message "Creating $backupFileCount verified backup stripes."
                }
                Invoke-MigrationTrackedDatabaseOperation -Operation Backup -SqlInstance $source `
                    -Source $source -Target $target -Database $database -ProgressPath $progressPath -BackupDirectory $databaseBackupDirectory `
                    -BackupFileCount $backupFileCount -TrustServerCertificate $using:TrustServerCertificate `
                    -TransferModulePath $using:TransferModulePath
                $stripeFiles = @(Get-MigrationBackupStripeFiles -Directory $databaseBackupDirectory `
                    -Database $database -FileCount $backupFileCount)
                if ($stripeFiles.Count -ne $backupFileCount) {
                    $totalBackupFiles = @(Get-ChildItem -LiteralPath $databaseBackupDirectory -Filter '*.bak' -File).Count
                    throw "Backup for '$database' did not produce exactly $backupFileCount valid stripe files in '$databaseBackupDirectory'; found $($stripeFiles.Count) valid stripe file(s) among $totalBackupFiles backup file(s)."
                }
                Set-MigrationState -Path $statePath -Source $source -Target $target -Database $database `
                    -TargetDatabase $targetDatabase -Status BackupCompleted -BackupPath $backupPath
                $backupCompleted = $true
                if ($progressPath) {
                    Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                        -Database $database -Stage 'Backup' -Status 'Completed' -Message "Verified $backupFileCount backup stripes."
                }
            }

            if (Test-Path -LiteralPath $backupPath -PathType Container) {
                $restoreFiles = @($stripeFiles | ForEach-Object FullName)
                if ($restoreFiles.Count -ne $backupFileCount) {
                    throw "Cannot restore '$database': expected $backupFileCount isolated stripe files in '$backupPath', found $($restoreFiles.Count)."
                }
            }
            else {
                $restoreFiles = @($backupPath)
            }
            $null = Wait-MigrationControl -ControlPath $controlPath -ProgressPath $progressPath `
                -Source $source -Target $target -Database $database
            if ($progressPath) {
                Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                    -Database $database -Stage 'Restore' -Status 'Started' -Message 'Restoring database to target.'
            }
            Invoke-MigrationTrackedDatabaseOperation -Operation Restore -SqlInstance $target `
                -Source $source -Target $target -Database $database -TargetDatabaseName $targetDatabase `
                -ProgressPath $progressPath -BackupFiles $restoreFiles `
                -DestinationDataDirectory $destinationDataDirectory `
                -DestinationLogDirectory $destinationLogDirectory `
                -AllowFileCollisionRetry $allowFileCollisionRetry `
                -TrustServerCertificate $using:TrustServerCertificate `
                -TransferModulePath $using:TransferModulePath
            if ($null -ne $targetCompatibilityLevel) {
                Set-MigrationTargetCompatibilityLevel -SqlInstance $target -DatabaseName $targetDatabase `
                    -CompatibilityLevel ([int]$targetCompatibilityLevel)
            }
            if (-not (Test-MigrationDatabaseExists -SqlInstance $target -Database $targetDatabase)) {
                throw "Restore completed without making database '$targetDatabase' visible on target '$target'."
            }
            Set-MigrationState -Path $statePath -Source $source -Target $target -Database $database `
                -TargetDatabase $targetDatabase -Status Completed -BackupPath $backupPath
            $message = if ($completedStateNeedsRepair) { 'Target database was missing; restored from backup.' } else { 'Backup and restore completed.' }
            if ($progressPath) {
                Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                    -Database $database -Stage 'Restore' -Status 'Completed' -Message 'Target database is online and accessible.'
            }
            [pscustomobject]@{ Source = $source; Target = $target; Database = $database; TargetDatabase = $targetDatabase; Stage = 'Database'; Status = 'Completed'; BackupPath = $backupPath; Message = $message }
        }
        catch {
            $migrationError = $_.Exception.Message
            try {
                $stateStatus = if ($backupCompleted) { 'BackupCompleted' } else { 'Failed' }
                Set-MigrationState -Path $statePath -Source $source -Target $target -Database $database `
                    -TargetDatabase $targetDatabase -Status $stateStatus -BackupPath $backupPath -ErrorMessage $migrationError
            }
            catch {
                Write-Error "Migration failed and state could not be recorded for $source/$database -> $target`: $($_.Exception.Message)"
            }
            if ($progressPath) {
                Write-MigrationProgressEvent -ProgressPath $progressPath -Source $source -Target $target `
                    -Database $database -Stage 'Database' -Status 'Failed' -Message $migrationError
            }
            [pscustomobject]@{ Source = $source; Target = $target; Database = $database; Stage = 'Database'; Status = 'Failed'; BackupPath = $backupPath; Message = $migrationError }
        }
    } -ThrottleLimit $ThrottleLimit
}

function Invoke-DatabaseSchemaOnlyMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pair,
        [Parameter(Mandatory)][string] $Database,
        [Parameter()][string] $TargetDatabaseName = '',
        [Parameter()][Nullable[int]] $TargetCompatibilityLevel,
        [Parameter(Mandatory)][bool] $Overwrite,
        [Parameter()][string] $ProgressPath = '',
        [Parameter()][string] $ControlPath = ''
    )

    $emit = {
        param([string]$Stage, [string]$Status, [int]$Percent, [string]$Message)
        if ($ProgressPath) {
            Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Pair.Source -Target $Pair.Target `
                -Database $Database -Stage $Stage -Status $Status -PercentComplete $Percent -Message $Message
        }
    }

    $destinationServer = $null
    $targetDatabaseCreated = $false
    if ([string]::IsNullOrWhiteSpace($TargetDatabaseName)) {
        $TargetDatabaseName = $Database
    }
    $TargetDatabaseName = ConvertTo-MigrationTargetDatabaseName -DatabaseName $TargetDatabaseName
    try {
        $null = & $emit 'SchemaTransfer' 'Started' 0 'Preparing a schema-only database transfer; table data will not be copied.'
        if (-not (Wait-MigrationControl -ControlPath $ControlPath -ProgressPath $ProgressPath `
                -Source $Pair.Source -Target $Pair.Target -Database $Database -HonorStop)) {
            return [pscustomobject]@{
                Source = $Pair.Source; Target = $Pair.Target; Database = $Database; Stage = 'SchemaTransfer'
                Status = 'Stopped'; BackupPath = $null; Message = 'Stopped before schema changes began.'
            }
        }

        $sourceServer = Connect-DbaInstance -SqlInstance $Pair.Source -ErrorAction Stop
        $sourceDatabase = Get-DbaDatabase -SqlInstance $sourceServer -Database $Database -EnableException -ErrorAction Stop |
            Select-Object -First 1
        if (-not $sourceDatabase -or $sourceDatabase.Status -ne 'Normal') {
            throw "Source database '$Database' is missing or not online on '$($Pair.Source)'."
        }
        $null = & $emit 'SchemaTransfer' 'InProgress' 10 'Connected to the source and verified that the database is online.'

        $destinationServer = Connect-DbaInstance -SqlInstance $Pair.Target -ErrorAction Stop
        $destinationDatabase = Get-DbaDatabase -SqlInstance $destinationServer -Database $TargetDatabaseName -EnableException -ErrorAction Stop |
            Select-Object -First 1
        if ($destinationDatabase -and -not $Overwrite) {
            $message = "Target database '$TargetDatabaseName' already exists; schema-only replacement was not approved, so it was left unchanged."
            $null = & $emit 'SchemaTransfer' 'Skipped' 100 $message
            return [pscustomobject]@{
                Source = $Pair.Source; Target = $Pair.Target; Database = $Database; TargetDatabase = $TargetDatabaseName; Stage = 'SchemaTransfer'
                Status = 'Skipped'; BackupPath = $null; Message = $message
            }
        }

        $fullTextReadiness = Test-MigrationFullTextReadiness -Source $Pair.Source -Target $Pair.Target -Database $Database
        if ($fullTextReadiness.Status -ne 'Passed') {
            throw $fullTextReadiness.Message
        }

        $transfer = [Microsoft.SqlServer.Management.Smo.Transfer]::new($sourceDatabase)
        $transfer.DestinationServerConnection = $destinationServer.ConnectionContext.Copy()
        $transfer.DestinationDatabase = $TargetDatabaseName
        $transfer.CreateTargetDatabase = $false
        $transfer.CopySchema = $true
        $transfer.CopyData = $false
        $transfer.CopyAllObjects = $true
        $transfer.CopyAllSchemas = $true
        $transfer.CopyAllUsers = $true
        $transfer.CopyAllRoles = $true
        $transfer.CopyAllLogins = $false
        $transfer.CopyAllDatabaseTriggers = $true
        $transfer.DropDestinationObjectsFirst = $false
        $transfer.Options.DriAll = $true
        $transfer.Options.Indexes = $true
        $transfer.Options.Triggers = $true
        $transfer.Options.FullTextCatalogs = $true
        $transfer.Options.FullTextIndexes = $true
        $transfer.Options.FullTextStopLists = $true
        $transfer.Options.Permissions = $true
        $transfer.Options.WithDependencies = $true
        $null = $transfer.ScriptTransfer()
        $null = & $emit 'SchemaTransfer' 'InProgress' 30 'Schema scripting preflight completed; no data-copy operation is enabled.'

        if (-not (Wait-MigrationControl -ControlPath $ControlPath -ProgressPath $ProgressPath `
                -Source $Pair.Source -Target $Pair.Target -Database $Database -HonorStop)) {
            return [pscustomobject]@{
                Source = $Pair.Source; Target = $Pair.Target; Database = $Database; Stage = 'SchemaTransfer'
                Status = 'Stopped'; BackupPath = $null; Message = 'Stopped before target database replacement began.'
            }
        }

        if ($destinationDatabase) {
            $null = & $emit 'SchemaTransfer' 'InProgress' 40 'Explicit overwrite approved; removing the existing target database before recreating schema only.'
            Remove-DbaDatabase -SqlInstance $destinationServer -Database $TargetDatabaseName -Confirm:$false -EnableException -ErrorAction Stop
        }
        $schemaFileSuffix = '_migration_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $null = New-DbaDatabase -SqlInstance $destinationServer -Name $TargetDatabaseName `
            -Collation $sourceDatabase.Collation -RecoveryModel $sourceDatabase.RecoveryModel `
            -DataFileSuffix $schemaFileSuffix -LogFileSuffix ($schemaFileSuffix + '_log') `
            -EnableException -ErrorAction Stop
        $targetDatabaseCreated = $true
        $null = & $emit 'SchemaTransfer' 'InProgress' 55 `
            "Created an empty target database with unique file names ($schemaFileSuffix); applying schema without table data."

        $null = $transfer.TransferData()
        $compatibilityLevel = if ($null -ne $TargetCompatibilityLevel) {
            [int]$TargetCompatibilityLevel
        } else {
            [int]$sourceDatabase.CompatibilityLevel
        }
        Set-MigrationTargetCompatibilityLevel -SqlInstance $Pair.Target -DatabaseName $TargetDatabaseName `
            -CompatibilityLevel $compatibilityLevel
        $null = & $emit 'SchemaTransfer' 'InProgress' 90 'Schema transfer completed; verifying target accessibility and absence of table rows.'
        $targetDatabase = Get-DbaDatabase -SqlInstance $destinationServer -Database $TargetDatabaseName -EnableException -ErrorAction Stop |
            Select-Object -First 1
        if (-not $targetDatabase -or $targetDatabase.Status -ne 'Normal') {
            throw "Schema transfer did not leave '$TargetDatabaseName' online and accessible on '$($Pair.Target)'."
        }
        $verification = Invoke-DbaQuery -SqlInstance $destinationServer -Database $TargetDatabaseName `
            -Query @'
SELECT COALESCE(SUM(CONVERT(bigint, p.rows)), 0) AS UserTableRows
FROM sys.tables AS t
JOIN sys.partitions AS p ON p.object_id = t.object_id
WHERE p.index_id IN (0, 1);
'@ -EnableException -ErrorAction Stop | Select-Object -Last 1
        if (-not $verification -or [long]$verification.UserTableRows -ne 0) {
            throw "Schema-only verification found table rows in '$TargetDatabaseName' on '$($Pair.Target)'."
        }
        $objectCount = Invoke-DbaQuery -SqlInstance $destinationServer -Database $TargetDatabaseName `
            -Query "SELECT COUNT_BIG(*) AS SchemaObjectCount FROM sys.objects WHERE is_ms_shipped = 0;" `
            -EnableException -ErrorAction Stop | Select-Object -Last 1
        $message = "Schema-only transfer completed; copied schema objects without table data. Verified $($objectCount.SchemaObjectCount) user objects and zero user-table rows."
        $null = & $emit 'SchemaTransfer' 'Completed' 100 $message
        [pscustomobject]@{
            Source = $Pair.Source; Target = $Pair.Target; Database = $Database; TargetDatabase = $TargetDatabaseName; Stage = 'SchemaTransfer'
            Status = 'Completed'; BackupPath = $null; Message = $message
        }
    }
    catch {
        $errorMessages = [System.Collections.Generic.List[string]]::new()
        for ($exception = $_.Exception; $exception; $exception = $exception.InnerException) {
            if ($exception.Message -and $exception.Message -notin $errorMessages) {
                $errorMessages.Add($exception.Message)
            }
        }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message -and $_.ErrorDetails.Message -notin $errorMessages) {
            $errorMessages.Add($_.ErrorDetails.Message)
        }
        $message = $errorMessages -join ' -> '
        if ($targetDatabaseCreated) {
            try {
                Remove-DbaDatabase -SqlInstance $destinationServer -Database $TargetDatabaseName `
                    -Confirm:$false -EnableException -ErrorAction Stop
                $message += ' The incomplete target database created by this run was removed.'
            }
            catch {
                $message += " Cleanup of the incomplete target database also failed: $($_.Exception.Message)"
            }
        }
        $null = & $emit 'SchemaTransfer' 'Failed' 100 $message
        [pscustomobject]@{
            Source = $Pair.Source; Target = $Pair.Target; Database = $Database; TargetDatabase = $TargetDatabaseName; Stage = 'SchemaTransfer'
            Status = 'Failed'; BackupPath = $null; Message = $message
        }
    }
}

Export-ModuleMember -Function Invoke-MigrationSafeRestore, Test-MigrationFullTextReadiness, Invoke-MigrationTrackedDatabaseOperation, Invoke-DatabaseMigration, Invoke-DatabaseSchemaOnlyMigration
