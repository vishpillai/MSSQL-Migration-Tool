Set-StrictMode -Version Latest

function Add-MigrationJsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Record
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    $json = ConvertTo-Json -InputObject $Record -Depth 12 -Compress -ErrorAction Stop
    [System.IO.File]::AppendAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-MigrationJsonLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidateRange(1, 2000)][int] $Limit
    )

    $records = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $lines = @(Get-Content -LiteralPath $Path -Tail $Limit -ErrorAction Stop)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([string]::IsNullOrWhiteSpace($lines[$index])) { continue }
        try {
            $records.Add((ConvertFrom-Json -InputObject $lines[$index] -AsHashtable -ErrorAction Stop))
        }
        catch {
            throw "Could not read reporting record $($index + 1) from '$Path': $($_.Exception.Message)"
        }
    }
    return @($records)
}

function Get-MigrationAuditKey {
    param(
        [Parameter(Mandatory)][string] $KeyPath,
        [Parameter()][switch] $Create
    )

    $entropy = [System.Text.Encoding]::UTF8.GetBytes('DbMigrationTool-AuditKey-v1')
    if (Test-Path -LiteralPath $KeyPath -PathType Leaf) {
        try {
            Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
            $protectedKey = [System.IO.File]::ReadAllBytes($KeyPath)
            return [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protectedKey,
                $entropy,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
        }
        catch {
            throw "Could not unlock the audit integrity key '$KeyPath' for the current Windows account: $($_.Exception.Message)"
        }
    }
    if (-not $Create) { return $null }

    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
    $key = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
    $protectedKey = [System.Security.Cryptography.ProtectedData]::Protect(
        $key,
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $directory = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    [System.IO.File]::WriteAllBytes($KeyPath, $protectedKey)
    return $key
}

function Get-MigrationAuditMac {
    param(
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][string] $PreviousHash,
        [Parameter(Mandatory)][string] $Payload
    )

    $message = [System.Text.Encoding]::UTF8.GetBytes("$PreviousHash`n$Payload")
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return [Convert]::ToHexString($hmac.ComputeHash($message)).ToLowerInvariant()
    }
    finally {
        $hmac.Dispose()
    }
}

function Write-MigrationAuditHead {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][byte[]] $Key,
        [Parameter(Mandatory)][int] $EntryCount,
        [Parameter(Mandatory)][int] $LegacyCount,
        [Parameter(Mandatory)][string] $HeadHash
    )

    $signature = Get-MigrationAuditMac -Key $Key -PreviousHash 'AUDIT-HEAD-v1' -Payload "$EntryCount`n$LegacyCount`n$HeadHash"
    $checkpoint = @{
        SchemaVersion = 1
        EntryCount = $EntryCount
        LegacyCount = $LegacyCount
        HeadHash = $HeadHash
        Signature = $signature
    } | ConvertTo-Json -Compress -ErrorAction Stop
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
            try {
                $writer.Write($checkpoint)
                $writer.Flush()
                $stream.Flush($true)
            }
            finally { $writer.Dispose() }
        }
        finally { $stream.Dispose() }
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function Get-MigrationAuditLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $KeyPath,
        [Parameter()][string] $HeadPath = "$Path.head",
        [Parameter()][ValidateRange(1, 10000)][int] $Limit = 500,
        [Parameter()][string] $Search = '',
        [Parameter()][string] $Actor = '',
        [Parameter()][string] $Category = '',
        [Parameter()][string] $Severity = '',
        [Parameter()][string] $Outcome = '',
        [Parameter()][string] $FromUtc = '',
        [Parameter()][string] $ToUtc = ''
    )

    $records = [System.Collections.Generic.List[object]]::new()
    $zeroHash = '0' * 64
    $previousHash = $zeroHash
    $legacyCount = 0
    $verifiedCount = 0
    $envelopeCount = 0
    $integrityStatus = 'Verified'
    $integrityError = ''
    $key = $null
    $hasEnvelope = $false
    $matchingCount = 0

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadLines($Path)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $envelope = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop
                }
                catch {
                    $integrityStatus = 'Tampered'
                    $integrityError = "Invalid JSON at audit record $($legacyCount + $verifiedCount + 1)."
                    break
                }

                if ($envelope -is [System.Collections.IDictionary] -and $envelope.Contains('Payload') -and
                    $envelope.Contains('PreviousHash') -and $envelope.Contains('Hash')) {
                    $hasEnvelope = $true
                    if (-not $key) {
                        $key = Get-MigrationAuditKey -KeyPath $KeyPath
                    }
                    if (-not $key) {
                        $integrityStatus = 'KeyUnavailable'
                        $integrityError = 'The DPAPI-protected audit key is missing.'
                        break
                    }
                    if ([string]$envelope.PreviousHash -cne $previousHash) {
                        $integrityStatus = 'Tampered'
                        $integrityError = "Audit chain mismatch at record $($legacyCount + $verifiedCount + 1)."
                        break
                    }
                    $expectedHash = Get-MigrationAuditMac -Key $key -PreviousHash $previousHash -Payload ([string]$envelope.Payload)
                    $expectedBytes = [Convert]::FromHexString($expectedHash)
                    try { $actualBytes = [Convert]::FromHexString([string]$envelope.Hash) }
                    catch { $actualBytes = [byte[]]::new(0) }
                    if ($actualBytes.Length -ne $expectedBytes.Length -or
                        -not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedBytes, $actualBytes)) {
                        $integrityStatus = 'Tampered'
                        $integrityError = "Audit signature mismatch at record $($legacyCount + $verifiedCount + 1)."
                        break
                    }
                    try {
                        $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$envelope.Payload))
                        $record = ConvertFrom-Json -InputObject $payloadJson -AsHashtable -ErrorAction Stop
                    }
                    catch {
                        $integrityStatus = 'Tampered'
                        $integrityError = "Audit payload is invalid at record $($legacyCount + $verifiedCount + 1)."
                        break
                    }
                    $previousHash = [string]$envelope.Hash
                    $verifiedCount++
                    $envelopeCount++
                    $record.Integrity = 'Verified'
                    $record.PreviousIntegrityHash = [string]$envelope.PreviousHash
                    $record.IntegrityHash = [string]$envelope.Hash
                }
                else {
                    if ($hasEnvelope) {
                        $integrityStatus = 'Tampered'
                        $integrityError = "Unchained audit record found after the integrity chain began at record $($legacyCount + $verifiedCount + 1)."
                        break
                    }
                    $legacyCount++
                    $record = $envelope
                    if ($record -is [System.Collections.IDictionary]) {
                        $record.Integrity = 'Legacy'
                    }
                    $previousHash = $zeroHash
                }

                $timestamp = [DateTimeOffset]::MinValue
                $recordTimestamp = if ($record -is [System.Collections.IDictionary] -and $record.Contains('Timestamp')) { [string]$record.Timestamp } else { '' }
                $hasTimestamp = [DateTimeOffset]::TryParse(
                    $recordTimestamp,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal,
                    [ref]$timestamp
                )
                $field = { param([string]$Name) if ($record -is [System.Collections.IDictionary] -and $record.Contains($Name)) { [string]$record[$Name] } else { '' } }
                $details = if ($record -is [System.Collections.IDictionary] -and $record.Contains('Details')) {
                    ConvertTo-Json -InputObject $record.Details -Depth 12 -Compress
                }
                else { '' }
                $searchText = (@(
                    (& $field Actor), (& $field ActorType), (& $field Action), (& $field Outcome), (& $field Category),
                    (& $field Severity), (& $field ResourceType), (& $field ResourceName), (& $field RunId),
                    (& $field ClientAddress), (& $field RequestId), $details
                ) -join ' ')
                $matches = (-not $Search -or $searchText.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                    (-not $Actor -or (& $field Actor).IndexOf($Actor, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                    (-not $Category -or [string]::Equals((& $field Category), $Category, [StringComparison]::OrdinalIgnoreCase)) -and
                    (-not $Severity -or [string]::Equals((& $field Severity), $Severity, [StringComparison]::OrdinalIgnoreCase)) -and
                    (-not $Outcome -or [string]::Equals((& $field Outcome), $Outcome, [StringComparison]::OrdinalIgnoreCase)) -and
                    (-not $FromUtc -or ($hasTimestamp -and $timestamp -ge [DateTimeOffset]::Parse($FromUtc, [Globalization.CultureInfo]::InvariantCulture))) -and
                    (-not $ToUtc -or ($hasTimestamp -and $timestamp -lt [DateTimeOffset]::Parse($ToUtc, [Globalization.CultureInfo]::InvariantCulture)))
                if ($matches) {
                    $matchingCount++
                    $records.Add($record)
                }
                while ($records.Count -gt $Limit) {
                    $records.RemoveAt(0)
                }
            }
            if ($integrityStatus -ne 'Tampered') {
                if (Test-Path -LiteralPath $HeadPath -PathType Leaf) {
                    if (-not $key) { $key = Get-MigrationAuditKey -KeyPath $KeyPath }
                    if (-not $key) {
                        $integrityStatus = 'KeyUnavailable'
                        $integrityError = 'The DPAPI-protected audit key is missing.'
                    }
                    else {
                        try {
                            $checkpoint = Get-Content -LiteralPath $HeadPath -Raw -ErrorAction Stop |
                                ConvertFrom-Json -AsHashtable -ErrorAction Stop
                            $headHash = if ($envelopeCount -gt 0) { $previousHash } else { $zeroHash }
                            $expectedSignature = Get-MigrationAuditMac -Key $key -PreviousHash 'AUDIT-HEAD-v1' `
                                -Payload "$envelopeCount`n$legacyCount`n$headHash"
                            if ([int]$checkpoint.EntryCount -ne $envelopeCount -or
                                [int]$checkpoint.LegacyCount -ne $legacyCount -or
                                [string]$checkpoint.HeadHash -cne $headHash -or
                                [string]$checkpoint.Signature -cne $expectedSignature) {
                                $integrityStatus = 'Tampered'
                                $integrityError = 'Audit log does not match its signed head checkpoint.'
                            }
                        }
                        catch {
                            $integrityStatus = 'Tampered'
                            $integrityError = "Audit head checkpoint is invalid: $($_.Exception.Message)"
                        }
                    }
                }
                elseif ($envelopeCount -gt 0) {
                    $integrityStatus = 'Tampered'
                    $integrityError = 'The signed audit head checkpoint is missing.'
                }
            }
        }
        elseif ((Test-Path -LiteralPath $HeadPath -PathType Leaf) -or (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
            $integrityStatus = 'Tampered'
            $integrityError = 'The audit ledger file is missing while its integrity state still exists.'
        }
    }
    catch {
        if ($_.Exception.Message -like 'Could not unlock the audit integrity key*') {
            $integrityStatus = 'KeyUnavailable'
            $integrityError = $_.Exception.Message
        }
        else {
            throw
        }
    }
    finally {
        if ($key) { [Array]::Clear($key, 0, $key.Length) }
    }

    if ($integrityStatus -eq 'Verified' -and $legacyCount -gt 0) {
        $integrityStatus = 'LegacyPresent'
    }
    [pscustomobject]@{
        Records = @($records)
        MatchingEntries = $matchingCount
        Integrity = [pscustomobject]@{
            Status = $integrityStatus
            VerifiedEntries = $verifiedCount
            LegacyEntries = $legacyCount
            Error = $integrityError
            LastVerifiedHash = if ($verifiedCount -gt 0) { $previousHash } else { $null }
        }
    }
}

function Add-MigrationAuditRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $KeyPath,
        [Parameter()][string] $HeadPath = "$Path.head",
        [Parameter(Mandatory)][System.Collections.IDictionary] $Record
    )

    $existing = Get-MigrationAuditLog -Path $Path -KeyPath $KeyPath -HeadPath $HeadPath -Limit 1
    if ($existing.Integrity.Status -in @('Tampered', 'KeyUnavailable')) {
        throw "Audit logging stopped because audit integrity status is '$($existing.Integrity.Status)': $($existing.Integrity.Error)"
    }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $null = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read).Dispose()
    }
    $key = Get-MigrationAuditKey -KeyPath $KeyPath -Create
    try {
        $completeRecord = [ordered]@{
            SchemaVersion = 1
            EventId = [guid]::NewGuid().ToString('N')
            Timestamp = [DateTime]::UtcNow.ToString('o')
        }
        foreach ($keyName in $Record.Keys) {
            if ($keyName -notin @('SchemaVersion', 'EventId', 'Timestamp', 'Integrity')) {
                $completeRecord[$keyName] = $Record[$keyName]
            }
        }
        $payloadJson = ConvertTo-Json -InputObject $completeRecord -Depth 12 -Compress -ErrorAction Stop
        $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
        $previousHash = if ($existing.Integrity.LastVerifiedHash) { $existing.Integrity.LastVerifiedHash } else { '0' * 64 }
        $hash = Get-MigrationAuditMac -Key $key -PreviousHash $previousHash -Payload $payload
        $envelope = @{
            SchemaVersion = 1
            PreviousHash = $previousHash
            Payload = $payload
            Hash = $hash
        } | ConvertTo-Json -Compress -ErrorAction Stop

        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
            try {
                $writer.WriteLine($envelope)
                $writer.Flush()
                $stream.Flush($true)
            }
            finally { $writer.Dispose() }
        }
        finally { $stream.Dispose() }
        $entryCount = $existing.Integrity.VerifiedEntries + 1
        Write-MigrationAuditHead -Path $HeadPath -Key $key -EntryCount $entryCount `
            -LegacyCount $existing.Integrity.LegacyEntries -HeadHash $hash
        return [pscustomobject]@{ EventId = $completeRecord.EventId; Hash = $hash }
    }
    finally {
        if ($key) { [Array]::Clear($key, 0, $key.Length) }
    }
}

function Get-MigrationReportingData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AuditPath,
        [Parameter(Mandatory)][string] $LogDirectory,
        [Parameter(Mandatory)][string] $ReportDirectory,
        [Parameter()][ValidateRange(1, 500)][int] $Limit = 100,
        [Parameter()][string] $AuditKeyPath = "$AuditPath.key",
        [Parameter()][string] $AuditHeadPath = "$AuditPath.head",
        [Parameter()][switch] $OmitAuditRecords
    )

    $auditLog = if ($OmitAuditRecords) {
        [pscustomobject]@{
            Records = @()
            Integrity = [pscustomobject]@{ Status = 'NotChecked'; VerifiedEntries = 0; LegacyEntries = 0; Error = ''; LastVerifiedHash = $null }
        }
    }
    else {
        Get-MigrationAuditLog -Path $AuditPath -KeyPath $AuditKeyPath -HeadPath $AuditHeadPath -Limit $Limit
    }
    $auditRecords = @($auditLog.Records | Sort-Object { [string]$_.Timestamp } -Descending)
    $runRecords = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $LogDirectory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $LogDirectory -Filter '*-*.jsonl' -File -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Limit) {
            foreach ($record in Get-MigrationJsonLines -Path $file.FullName -Limit $Limit) {
                $runRecords.Add($record)
            }
        }
    }
    $recentRunRecords = @($runRecords | Sort-Object { [string]$_.Timestamp } -Descending | Select-Object -First $Limit)

    $patchSummaries = foreach ($group in ($runRecords | Where-Object Operation -eq 'Patch' | Group-Object RunId)) {
        $records = @($group.Group | Sort-Object { [string]$_.Timestamp })
        $started = @($records | Where-Object RecordType -eq 'RunStarted' | Select-Object -First 1)
        $completed = @($records | Where-Object RecordType -eq 'RunCompleted' | Select-Object -Last 1)
        $summary = if ($started.Count -gt 0) { $started[0] } else { $records[0] }
        [pscustomobject]@{
            RunId = [string]$group.Name
            Action = [string]$summary.Action
            KB = [string]$summary.KB
            Targets = @($summary.Targets)
            Timestamp = [string]$summary.Timestamp
            Status = if ($completed.Count -gt 0) { [string]$completed[0].Status } else { 'InProgress' }
            ExitCode = if ($completed.Count -gt 0) { $completed[0].ExitCode } else { $null }
            Messages = @($records | Where-Object RecordType -eq 'ProcessOutput' | ForEach-Object Message)
        }
    }

    $migrationReports = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $ReportDirectory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $ReportDirectory -Filter 'Migration-*.csv' -File -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Limit) {
            $rows = @(Import-Csv -LiteralPath $file.FullName -ErrorAction Stop)
            $databaseRows = @($rows | Where-Object {
                $_.Database -and $_.Database -ne '*' -and $_.Stage -eq 'DatabaseOutcome'
            })
            if ($databaseRows.Count -eq 0) {
                $databaseRows = @($rows | Where-Object {
                    $_.Database -and $_.Database -ne '*' -and $_.Stage -eq 'Database'
                })
            }
            $databaseRows = @($databaseRows | Group-Object {
                "$($_.Source)`0$($_.Target)`0$($_.Database)"
            } | ForEach-Object { $_.Group[-1] })
            $discoveryRows = @()
            $discoveryFile = Get-ChildItem -LiteralPath $ReportDirectory -Filter 'Discovery-*.csv' -File -ErrorAction Stop |
                Sort-Object LastWriteTimeUtc -Descending |
                Where-Object {
                    $candidateRows = @(Import-Csv -LiteralPath $_.FullName -ErrorAction Stop)
                    @($candidateRows | Where-Object {
                        $_.Source -in @($rows | Select-Object -ExpandProperty Source -Unique) -and
                        $_.Target -in @($rows | Select-Object -ExpandProperty Target -Unique)
                    }).Count -gt 0
                } |
                Select-Object -First 1
            if ($discoveryFile) {
                $discoveryRows = @(Import-Csv -LiteralPath $discoveryFile.FullName -ErrorAction Stop)
            }
            $serverObjectReports = foreach ($pair in ($rows | Where-Object { $_.Source -and $_.Target } |
                    Select-Object Source, Target -Unique)) {
                $inventory = @($discoveryRows | Where-Object {
                    $_.Source -eq $pair.Source -and $_.Target -eq $pair.Target
                } | Select-Object -First 1)
                $pairRows = @($rows | Where-Object {
                    $_.Source -eq $pair.Source -and $_.Target -eq $pair.Target
                })
                $loginStage = $pairRows | Where-Object Stage -eq 'ServerObjects' | Select-Object -Last 1
                $linkedServerStage = $pairRows | Where-Object Stage -eq 'LinkedServers' | Select-Object -Last 1
                [pscustomobject]@{
                    Source = $pair.Source
                    Target = $pair.Target
                    SourceLoginCount = if ($inventory.Count -gt 0 -and $inventory[0].SourceLoginCount -match '^\d+$') {
                        [int]$inventory[0].SourceLoginCount
                    } else { $null }
                    SourceAgentJobCount = if ($inventory.Count -gt 0 -and $inventory[0].SourceAgentJobCount -match '^\d+$') {
                        [int]$inventory[0].SourceAgentJobCount
                    } else { $null }
                    SourceLinkedServerCount = if ($inventory.Count -gt 0 -and $inventory[0].SourceLinkedServerCount -match '^\d+$') {
                        [int]$inventory[0].SourceLinkedServerCount
                    } else { $null }
                    LoginMigrationStatus = if ($loginStage -and $loginStage.PSObject.Properties['Status']) {
                        [string]$loginStage.Status
                    } else { 'Not run' }
                    LinkedServerMigrationStatus = if ($linkedServerStage -and $linkedServerStage.PSObject.Properties['Status']) {
                        [string]$linkedServerStage.Status
                    } else { 'Not run' }
                }
            }
            $migrationReports.Add([pscustomobject]@{
                Name = $file.Name
                GeneratedAt = $file.LastWriteTimeUtc.ToString('o')
                Sources = @($rows | Where-Object Source | Select-Object -ExpandProperty Source -Unique)
                Targets = @($rows | Where-Object Target | Select-Object -ExpandProperty Target -Unique)
                DatabaseCount = @($databaseRows | Select-Object -ExpandProperty Database -Unique).Count
                CompletedCount = @($databaseRows | Where-Object Status -eq 'Completed').Count
                SkippedCount = @($databaseRows | Where-Object Status -eq 'Skipped').Count
                FailedCount = if ($databaseRows.Count -gt 0) {
                    @($databaseRows | Where-Object Status -eq 'Failed').Count
                }
                else {
                    @($rows | Where-Object Status -eq 'Failed').Count
                }
                ServerObjectReports = @($serverObjectReports)
                Rows = @($rows | Select-Object -First $Limit)
            })
        }
    }

    $hostLogs = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $LogDirectory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $LogDirectory -Filter 'WebHost-*.log' -File -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 5) {
            foreach ($line in Get-Content -LiteralPath $file.FullName -Tail $Limit -ErrorAction Stop) {
                if ($line -match '^\[(?<Timestamp>[^\]]+)\] \[(?<Level>[^\]]+)\] (?<Message>.*)$') {
                    $hostLogs.Add([pscustomobject]@{
                        Timestamp = $Matches.Timestamp
                        Level = $Matches.Level
                        Message = $Matches.Message
                    })
                }
            }
        }
    }

    [pscustomobject]@{
        RefreshedAt = [DateTime]::UtcNow.ToString('o')
        AuditRecords = $auditRecords
        AuditIntegrity = $auditLog.Integrity
        RunRecords = $recentRunRecords
        HostLogs = @($hostLogs | Sort-Object Timestamp -Descending | Select-Object -First $Limit)
        MigrationReports = @($migrationReports)
        PatchSummaries = @($patchSummaries | Sort-Object Timestamp -Descending | Select-Object -First $Limit)
    }
}

Export-ModuleMember -Function Add-MigrationJsonLine, Add-MigrationAuditRecord, Get-MigrationAuditLog, Get-MigrationReportingData
