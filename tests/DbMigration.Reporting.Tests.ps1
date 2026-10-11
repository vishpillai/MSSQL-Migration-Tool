BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Reporting.psm1') -Force
}

Describe 'Migration reporting data' {
    It 'writes and reads structured JSONL records' {
        $path = Join-Path $TestDrive 'logs\Audit.jsonl'

        Add-MigrationJsonLine -Path $path -Record @{
            Timestamp = '2026-01-01T00:00:00Z'
            Action = 'Migration started'
            Details = @{ DatabaseCount = 2 }
        }
        $result = Get-MigrationReportingData -AuditPath $path -AuditKeyPath (Join-Path $TestDrive 'Audit.key') -LogDirectory (Join-Path $TestDrive 'missing-logs') `
            -ReportDirectory (Join-Path $TestDrive 'missing-reports') -Limit 10

        $result.AuditRecords.Count | Should -Be 1
        $result.AuditRecords[0].Action | Should -Be 'Migration started'
        $result.AuditRecords[0].Details.DatabaseCount | Should -Be 2
        $result.AuditRecords[0].Integrity | Should -Be 'Legacy'
        $result.AuditIntegrity.Status | Should -Be 'LegacyPresent'
    }

    It 'aggregates migration report and patch run records' {
        $logs = Join-Path $TestDrive 'logs'
        $reports = Join-Path $TestDrive 'reports'
        $null = New-Item -ItemType Directory -Path $logs, $reports -Force
        Add-MigrationJsonLine -Path (Join-Path $logs 'Patch-run123.jsonl') -Record @{
            Timestamp = '2026-01-01T00:00:00Z'
            Operation = 'Patch'
            RunId = 'run123'
            RecordType = 'RunStarted'
            Action = 'Apply'
            KB = '5104824'
            Targets = @('sql01')
        }
        Add-MigrationJsonLine -Path (Join-Path $logs 'Patch-run123.jsonl') -Record @{
            Timestamp = '2026-01-01T00:01:00Z'
            Operation = 'Patch'
            RunId = 'run123'
            RecordType = 'RunCompleted'
            Status = 'Succeeded'
            ExitCode = 0
        }
        @(
            [pscustomobject]@{ Source = 'sql01'; Target = 'sql02'; Database = 'AdventureWorks'; Stage = 'DatabaseOutcome'; Status = 'Completed' }
            [pscustomobject]@{ Source = 'sql01'; Target = 'sql02'; Database = 'Sales'; Stage = 'DatabaseOutcome'; Status = 'Failed' }
            [pscustomobject]@{ Source = 'sql01'; Target = 'sql02'; Database = '*'; Stage = 'ServerObjects'; Status = 'Completed' }
            [pscustomobject]@{ Source = 'sql01'; Target = 'sql02'; Database = '*'; Stage = 'LinkedServers'; Status = 'Completed' }
        ) | Export-Csv -LiteralPath (Join-Path $reports 'Migration-test.csv') -NoTypeInformation
        [pscustomobject]@{
            Source = 'sql01'
            Target = 'sql02'
            SourceLoginCount = 12
            SourceAgentJobCount = 4
            SourceLinkedServerCount = 3
        } | Export-Csv -LiteralPath (Join-Path $reports 'Discovery-test.csv') -NoTypeInformation

        $result = Get-MigrationReportingData -AuditPath (Join-Path $logs 'Audit.jsonl') -AuditKeyPath (Join-Path $logs 'Audit.key') `
            -LogDirectory $logs -ReportDirectory $reports -Limit 10

        $result.PatchSummaries.Count | Should -Be 1
        $result.PatchSummaries[0].Status | Should -Be 'Succeeded'
        $result.PatchSummaries[0].ExitCode | Should -Be 0
        $result.MigrationReports.Count | Should -Be 1
        $result.MigrationReports[0].DatabaseCount | Should -Be 2
        $result.MigrationReports[0].CompletedCount | Should -Be 1
        $result.MigrationReports[0].FailedCount | Should -Be 1
        $result.MigrationReports[0].ServerObjectReports.Count | Should -Be 1
        $result.MigrationReports[0].ServerObjectReports[0].SourceLoginCount | Should -Be 12
        $result.MigrationReports[0].ServerObjectReports[0].SourceAgentJobCount | Should -Be 4
        $result.MigrationReports[0].ServerObjectReports[0].SourceLinkedServerCount | Should -Be 3
        $result.MigrationReports[0].ServerObjectReports[0].LoginMigrationStatus | Should -Be 'Completed'
        $result.MigrationReports[0].ServerObjectReports[0].LinkedServerMigrationStatus | Should -Be 'Completed'
    }

    It 'reports server-object stages as not run when migration rows omit those stages' {
        $reports = Join-Path $TestDrive 'database-only-reports'
        $null = New-Item -ItemType Directory -Path $reports -Force
        [pscustomobject]@{
            Source = 'sql01'
            Target = 'sql02'
            Database = 'AdventureWorks'
            Stage = 'DatabaseOutcome'
            Status = 'Completed'
        } | Export-Csv -LiteralPath (Join-Path $reports 'Migration-database-only.csv') -NoTypeInformation

        $result = Get-MigrationReportingData -AuditPath (Join-Path $TestDrive 'missing-audit.jsonl') `
            -AuditKeyPath (Join-Path $TestDrive 'missing-audit.key') `
            -LogDirectory (Join-Path $TestDrive 'missing-database-only-logs') -ReportDirectory $reports -Limit 10

        $result.MigrationReports[0].ServerObjectReports.Count | Should -Be 1
        $result.MigrationReports[0].ServerObjectReports[0].LoginMigrationStatus | Should -Be 'Not run'
        $result.MigrationReports[0].ServerObjectReports[0].LinkedServerMigrationStatus | Should -Be 'Not run'
    }

    It 'reports malformed audit data as an integrity failure' {
        $path = Join-Path $TestDrive 'malformed.jsonl'
        Set-Content -LiteralPath $path -Value '{not-json'

        $result = Get-MigrationReportingData -AuditPath $path -AuditKeyPath (Join-Path $TestDrive 'Audit.key') `
            -LogDirectory (Join-Path $TestDrive 'missing-logs') -ReportDirectory (Join-Path $TestDrive 'missing-reports') -Limit 10

        $result.AuditIntegrity.Status | Should -Be 'Tampered'
        $result.AuditIntegrity.Error | Should -Match 'Invalid JSON'
        $result.AuditRecords | Should -BeNullOrEmpty
    }

    It 'writes structured HMAC-chained events and verifies them' {
        $path = Join-Path $TestDrive 'protected\Audit.jsonl'
        $keyPath = Join-Path $TestDrive 'protected\Audit.key'
        $null = Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{
            Actor = 'CONTOSO\operator'
            ActorType = 'WindowsUser'
            Category = 'Change'
            Severity = 'Information'
            Action = 'Migration started'
            Outcome = 'Succeeded'
            ResourceType = 'Migration'
            ResourceName = 'sql01 -> sql02'
            RunId = 'run-1'
            RequestId = 'request-1'
            Details = @{ DatabaseCount = 2 }
        }
        $null = Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{
            Actor = 'CONTOSO\operator'
            Category = 'Change'
            Severity = 'Information'
            Action = 'Migration completed'
            Outcome = 'Succeeded'
            Details = @{ DatabaseCount = 2 }
        }

        $result = Get-MigrationAuditLog -Path $path -KeyPath $keyPath -Limit 10
        $result.Integrity.Status | Should -Be 'Verified'
        $result.Integrity.VerifiedEntries | Should -Be 2
        $result.Records.Count | Should -Be 2
        $result.Records[0].SchemaVersion | Should -Be 1
        $result.Records[0].EventId | Should -Match '^[a-f0-9]{32}$'
        $result.Records[0].ActorType | Should -Be 'WindowsUser'
        $result.Records[0].ResourceName | Should -Be 'sql01 -> sql02'
        $result.Records[0].Integrity | Should -Be 'Verified'
    }

    It 'detects edited audit events and refuses to append after tampering' {
        $path = Join-Path $TestDrive 'tampered\Audit.jsonl'
        $keyPath = Join-Path $TestDrive 'tampered\Audit.key'
        $null = Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{
            Actor = 'operator'
            Category = 'Security'
            Severity = 'Error'
            Action = 'Login attempt failed'
            Outcome = 'Failed'
            Details = @{ RemainingAttempts = 3 }
        }
        $envelope = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($envelope.Payload)).Replace('operator', 'attacker')
        $envelope.Payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
        $envelope | ConvertTo-Json -Compress | Set-Content -LiteralPath $path

        $result = Get-MigrationAuditLog -Path $path -KeyPath $keyPath -Limit 10
        $result.Integrity.Status | Should -Be 'Tampered'
        { Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{ Action = 'Should not append' } } |
            Should -Throw '*Audit logging stopped*'
    }

    It 'detects truncation using the signed audit-head checkpoint' {
        $path = Join-Path $TestDrive 'truncated\Audit.jsonl'
        $keyPath = Join-Path $TestDrive 'truncated\Audit.key'
        foreach ($actor in @('operator-one', 'operator-two')) {
            $null = Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{
                Actor = $actor
                Category = 'Security'
                Severity = 'Information'
                Action = 'User signed in'
                Outcome = 'Succeeded'
            }
        }
        $firstRecord = (Get-Content -LiteralPath $path)[0]
        Set-Content -LiteralPath $path -Value $firstRecord

        $result = Get-MigrationAuditLog -Path $path -KeyPath $keyPath -Limit 10
        $result.Integrity.Status | Should -Be 'Tampered'
        $result.Integrity.Error | Should -Match 'head checkpoint'
    }

    It 'reports a missing DPAPI key and refuses further writes' {
        $path = Join-Path $TestDrive 'missing-key\Audit.jsonl'
        $keyPath = Join-Path $TestDrive 'missing-key\Audit.key'
        $null = Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{
            Actor = 'operator'
            Category = 'Security'
            Severity = 'Information'
            Action = 'User signed in'
            Outcome = 'Succeeded'
        }
        Remove-Item -LiteralPath $keyPath -Force

        $result = Get-MigrationAuditLog -Path $path -KeyPath $keyPath -Limit 10
        $result.Integrity.Status | Should -Be 'KeyUnavailable'
        { Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{ Action = 'Should not append' } } |
            Should -Throw '*Audit logging stopped*'
    }

    It 'filters audit events across the ledger and reports total matching entries' {
        $path = Join-Path $TestDrive 'filtered\Audit.jsonl'
        $keyPath = Join-Path $TestDrive 'filtered\Audit.key'
        foreach ($entry in @(
            @{ Actor = 'operator-one'; Category = 'Security'; Severity = 'Error'; Action = 'Login attempt failed'; Outcome = 'Failed'; Timestamp = '2026-01-01T00:00:00Z' }
            @{ Actor = 'operator-two'; Category = 'Change'; Severity = 'Information'; Action = 'Migration started'; Outcome = 'Succeeded'; Timestamp = '2026-01-02T00:00:00Z' }
            @{ Actor = 'operator-one'; Category = 'Security'; Severity = 'Error'; Action = 'Login attempt failed'; Outcome = 'Failed'; Timestamp = '2026-01-03T00:00:00Z' }
            @{ Actor = 'operator-one'; Category = 'Security'; Severity = 'Error'; Action = 'Login attempt failed'; Outcome = 'Failed'; Timestamp = '2026-01-04T00:00:00Z' }
        )) {
            $null = Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record $entry
        }

        $result = Get-MigrationAuditLog -Path $path -KeyPath $keyPath -Limit 1 -Actor 'operator-one' `
            -Category 'Security' -Outcome 'Failed' -FromUtc '2020-01-01T00:00:00Z' -Search 'LOGIN'
        $result.Integrity.Status | Should -Be 'Verified'
        $result.MatchingEntries | Should -Be 3
        $result.Records.Count | Should -Be 1
        $result.Records[0].Actor | Should -Be 'operator-one'
    }

    It 'preserves legacy events and starts a verified chain for new events' {
        $path = Join-Path $TestDrive 'legacy\Audit.jsonl'
        $keyPath = Join-Path $TestDrive 'legacy\Audit.key'
        Add-MigrationJsonLine -Path $path -Record @{ Timestamp = '2026-01-01T00:00:00Z'; Actor = 'old-user'; Action = 'Old event' }
        $null = Add-MigrationAuditRecord -Path $path -KeyPath $keyPath -Record @{
            Actor = 'new-user'
            Category = 'Operations'
            Severity = 'Information'
            Action = 'New event'
            Outcome = 'Succeeded'
        }

        $result = Get-MigrationAuditLog -Path $path -KeyPath $keyPath -Limit 10
        $result.Integrity.Status | Should -Be 'LegacyPresent'
        $result.Integrity.LegacyEntries | Should -Be 1
        $result.Integrity.VerifiedEntries | Should -Be 1
        $result.Records[0].Integrity | Should -Be 'Legacy'
        $result.Records[1].Integrity | Should -Be 'Verified'
    }
}
