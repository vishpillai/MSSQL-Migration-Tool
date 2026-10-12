BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Transfer.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.WebAuth.psm1') -Force
}

Describe 'Migration web authentication' {
    It 'verifies the configured username and password using a salted PBKDF2 record' {
        $password = ConvertTo-SecureString 'test-password-1234' -AsPlainText -Force
        $record = New-MigrationWebPasswordRecord -Username 'migration-admin' -Password $password

        Test-MigrationWebPassword -Record $record -Username 'migration-admin' -Password 'test-password-1234' |
            Should -BeTrue
        Test-MigrationWebPassword -Record $record -Username 'migration-admin' -Password 'incorrect-password' |
            Should -BeFalse
        Test-MigrationWebPassword -Record $record -Username 'other-user' -Password 'test-password-1234' |
            Should -BeFalse
        $record.PasswordHash | Should -Not -Be 'test-password-1234'
        $record.Iterations | Should -BeGreaterThan 100000
    }

    It 'rejects application passwords shorter than 14 characters' {
        $password = ConvertTo-SecureString 'too-short' -AsPlainText -Force
        { New-MigrationWebPasswordRecord -Username 'migration-admin' -Password $password } |
            Should -Throw '*between 14 and 1024 characters*'
    }

    It 'checks Windows identity membership in an AD group or SID' {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()

        Test-MigrationWebWindowsGroupMembership -Identity $identity -Group 'S-1-1-0' | Should -BeTrue
        Test-MigrationWebWindowsGroupMembership -Identity $identity -Group 'S-1-0-0' | Should -BeFalse
    }

    It 'migrates a legacy credential record into one installation Super Admin' {
        $password = ConvertTo-SecureString 'test-password-1234' -AsPlainText -Force
        try {
            $legacyRecord = New-MigrationWebPasswordRecord -Username 'legacy-admin' -Password $password

            $store = ConvertTo-MigrationWebAuthStore -Record ([ordered]@{
                Username = $legacyRecord.Username
                Salt = $legacyRecord.Salt
                PasswordHash = $legacyRecord.PasswordHash
                Iterations = $legacyRecord.Iterations
                CreatedUtc = $legacyRecord.CreatedUtc
            })

            $store.SchemaVersion | Should -Be 2
            $store.Users.Count | Should -Be 1
            $store.Users[0].Role | Should -Be 'SuperAdmin'
            $store.Users[0].Features | Should -Contain 'Migration'
            Test-MigrationWebPassword -Record $store.Users[0] -Username 'legacy-admin' -Password 'test-password-1234' |
                Should -BeTrue
        }
        finally {
            $password.Dispose()
        }
    }

    It 'creates scoped users and excludes credential material from safe user data' {
        $password = ConvertTo-SecureString 'user-password-12345' -AsPlainText -Force
        try {
            $user = New-MigrationWebUserRecord -Username 'operator' -Password $password -Features @('Patching', 'LogsAudit')
            $safeUser = Get-MigrationWebSafeUser -User $user

            $user.Role | Should -Be 'User'
            $user.Features | Should -Contain 'Patching'
            $safeUser.Keys | Should -Not -Contain 'Salt'
            $safeUser.Keys | Should -Not -Contain 'PasswordHash'
            { New-MigrationWebUserRecord -Username 'operator2' -Password $password -Features @('SuperAdmin') } |
                Should -Throw '*Unsupported feature grants*'
        }
        finally {
            $password.Dispose()
        }
    }

    It 'validates themes, colors, and branding values before storing them' {
        $branding = Get-MigrationWebDefaultBranding

        $updated = Set-MigrationWebBranding -Branding $branding -Updates @{
            Theme = 'Dark'
            AccentColor = '#123abc'
            ProductName = 'Client Migration'
        }

        $updated.Theme | Should -Be 'Dark'
        $updated.AccentColor | Should -Be '#123abc'
        $updated.ProductName | Should -Be 'Client Migration'
        { Set-MigrationWebBranding -Branding $branding -Updates @{ Theme = 'Solarized' } } |
            Should -Throw '*Theme must be Light, Dark, or Blue*'
        { Set-MigrationWebBranding -Branding $branding -Updates @{ AccentColor = 'red' } } |
            Should -Throw '*six-digit CSS hex color*'
    }
}

Describe 'Portable web storage paths' {
    It 'stores portable auth files under the app folder instead of ProgramData' {
        $storage = Resolve-MigrationWebStoragePaths -AppRoot $TestDrive -PortableMode

        $storage.IsPortable | Should -BeTrue
        $storage.AuthPath | Should -Be (Join-Path $TestDrive 'portable\auth\auth.json')
        $storage.LogDirectory | Should -Be (Join-Path $TestDrive 'portable\logs')
    }
}

Describe 'Web authentication record persistence' {
    It 'creates an authentication record atomically for first-run setup' {
        $authPath = Join-Path $TestDrive 'portable\auth\auth.json'
        $password = ConvertTo-SecureString 'test-password-1234' -AsPlainText -Force
        try {
            $record = New-MigrationWebPasswordRecord -Username 'first-admin' -Password $password

            Save-MigrationWebAuthRecord -Record $record -Path $authPath -PortableMode -CreateOnly

            $saved = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
            Test-MigrationWebPassword -Record $saved -Username 'first-admin' -Password 'test-password-1234' |
                Should -BeTrue
            { Save-MigrationWebAuthRecord -Record $record -Path $authPath -PortableMode -CreateOnly } |
                Should -Throw
        }
        finally {
            $password.Dispose()
        }
    }

    It 'writes standard-mode authentication data with restricted access controls' {
        $authPath = Join-Path $TestDrive 'standard\auth.json'
        $password = ConvertTo-SecureString 'test-password-1234' -AsPlainText -Force
        try {
            $record = New-MigrationWebPasswordRecord -Username 'first-admin' -Password $password

            Save-MigrationWebAuthRecord -Record $record -Path $authPath -CreateOnly

            $saved = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
            Test-MigrationWebPassword -Record $saved -Username 'first-admin' -Password 'test-password-1234' |
                Should -BeTrue
            (Get-Acl -LiteralPath $authPath).AreAccessRulesProtected | Should -BeTrue
            (Get-Acl -LiteralPath (Split-Path -Parent $authPath)).AreAccessRulesProtected | Should -BeTrue
        }
        finally {
            $password.Dispose()
        }
    }
}

Describe 'Migration configuration' {
    It 'loads a valid configuration and defaults exclusions and statistics' {
        $path = Join-Path $TestDrive 'migration.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        $config = Import-MigrationConfiguration -Path $path

        $config.SourceTargets.Count | Should -Be 1
        $config.SourceTargets[0].MigrationMode | Should -Be 'Full'
        $config.RestoreSpaceBufferPercent | Should -Be 20
        $config.BackupFileCount | Should -Be 4
        $config.UpdateStatistics | Should -BeTrue
        $config.ExcludeDatabases.Count | Should -Be 0
        $config.MigrateLogins | Should -BeTrue
        $config.ConfigureLinkedServers | Should -BeTrue
        $config.RepairOrphanUsers | Should -BeTrue
        $config.OverwriteExistingDatabases.Count | Should -Be 0
        $config.SkipExistingDatabases.Count | Should -Be 0
    }

    It 'accepts an explicit schema-only migration mode' {
        $path = Join-Path $TestDrive 'schema-only.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups","MigrationMode":"SchemaOnly"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        (Import-MigrationConfiguration -Path $path).SourceTargets[0].MigrationMode | Should -Be 'SchemaOnly'
    }

    It 'preserves configured migration modes in browser pair defaults' {
        $pairs = @(
            @{ Source = 'schema-source'; Target = 'schema-target'; BackupPath = 'C:\SchemaBackups'; MigrationMode = 'SchemaOnly' }
            @{ Source = 'full-source'; Target = 'full-target'; BackupPath = 'C:\FullBackups' }
        )

        $defaults = @(Get-MigrationSourceTargetPairDefaults -SourceTargets $pairs)

        $defaults.Count | Should -Be 2
        $defaults[0].MigrationMode | Should -Be 'SchemaOnly'
        $defaults[1].MigrationMode | Should -Be 'Full'
    }

    It 'rejects unknown migration modes' {
        $path = Join-Path $TestDrive 'invalid-mode.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups","MigrationMode":"SchemaAndData"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw '*MigrationMode*'
    }

    It 'rejects missing source/target values' {
        $path = Join-Path $TestDrive 'invalid.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw
    }

    It 'rejects invalid restore buffers and replacement settings' {
        $path = Join-Path $TestDrive 'invalid-safety.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv",
  "RestoreSpaceBufferPercent": 120,
  "AllowTargetReplace": "yes"
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw '*RestoreSpaceBufferPercent*'
    }

    It 'defaults to refusing target replacement' {
        $path = Join-Path $TestDrive 'safe-default.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv"
}
'@ | Set-Content -LiteralPath $path

        (Import-MigrationConfiguration -Path $path).AllowTargetReplace | Should -BeFalse
    }

    It 'requires an explicit per-database decision before replacing an existing target' {
        $config = @{
            AllowTargetReplace = $false
            OverwriteExistingDatabases = @('approved')
            SkipExistingDatabases = @('declined')
        }

        Get-MigrationTargetDatabaseDecision -Database declined -TargetExists $true -Configuration $config |
            Should -Be 'SkipRequested'
        Get-MigrationTargetDatabaseDecision -Database approved -TargetExists $true -Configuration $config |
            Should -Be 'Overwrite'
        Get-MigrationTargetDatabaseDecision -Database unchanged -TargetExists $true -Configuration $config |
            Should -Be 'Blocked'
        Get-MigrationTargetDatabaseDecision -Database completed -TargetExists $true -StateStatus Completed -Configuration $config |
            Should -Be 'SkipCompleted'
        Get-MigrationTargetDatabaseDecision -Database completed -TargetExists $true -StateStatus Completed `
            -Configuration (@{ AllowTargetReplace = $false; OverwriteExistingDatabases = @('completed'); SkipExistingDatabases = @() }) |
            Should -Be 'Overwrite'
        Get-MigrationTargetDatabaseDecision -Database newdb -TargetExists $false -Configuration $config |
            Should -Be 'Migrate'
    }

    It 'does not count linked-server work when linked servers are skipped' {
        $options = @{
            MigrateLogins = $false
            MigrateAgentJobs = $false
            MigrateAgentOperators = $false
            ConfigureLinkedServers = $true
            SkipLinkedServers = $true
        }

        Test-MigrationServerWorkEnabled -Options $options | Should -BeFalse
        Test-MigrationServerWorkEnabled -Options $options -MigrationMode SchemaOnly | Should -BeFalse

        $options.SkipLinkedServers = $false
        Test-MigrationServerWorkEnabled -Options $options | Should -BeTrue
    }

    It 'rejects backup stripe counts outside the supported range' {
        $path = Join-Path $TestDrive 'invalid-backup-file-count.json'
        @'
{
  "SourceTargets": [{"Source":"source","Target":"target","BackupPath":"C:\\backups"}],
  "OutputPath": "reports",
  "ThrottleLimit": 2,
  "LinkedServersCsv": "linked.csv",
  "BackupFileCount": 33
}
'@ | Set-Content -LiteralPath $path

        { Import-MigrationConfiguration -Path $path } | Should -Throw '*BackupFileCount*'
    }
}

Describe 'Schema-only configuration validation' {
    BeforeAll {
        Import-Module dbatools -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Discovery.psm1') -Force
    }

    It 'does not probe a shared backup path' {
        $script:connectInvocation = 0
        Mock Connect-DbaInstance -ModuleName DbMigration.Discovery {
            $script:connectInvocation++
            $majorVersion = if ($script:connectInvocation -eq 1) { 13 } else { 16 }
            [pscustomobject]@{ VersionMajor = $majorVersion }
        }
        Mock Test-DbaPath -ModuleName DbMigration.Discovery {
            throw 'Schema-only migration should not inspect a backup path.'
        }
        $configuration = @{
            SourceTargets = @(@{
                Source = 'source'
                Target = 'target'
                BackupPath = '\\unused\share'
                MigrationMode = 'SchemaOnly'
            })
        }

        $results = @(Test-MigrationConfiguration -Configuration $configuration)

        @($results | Where-Object Status -eq 'Failed').Count | Should -Be 0
        @($results | Where-Object { $_.Role -eq 'BackupPath' -and $_.Status -eq 'Skipped' }).Count | Should -Be 1
        Should -Invoke Test-DbaPath -ModuleName DbMigration.Discovery -Exactly 0
    }
}

Describe 'Custom SQL execution helpers' {
    It 'validates a custom SQL query before running it against the selected SQL instance' {
        { Invoke-MigrationCustomSql -SqlInstance 'source-sql' -Database 'master' -Query '' } |
            Should -Throw '*Custom T-SQL query cannot be empty*'

        { Invoke-MigrationCustomSql -SqlInstance '' -Database 'master' -Query 'SELECT 1' } |
            Should -Throw '*SqlInstance is required*'
    }

    It 'delegates to dbatools for the selected SQL instance and database' {
        Import-Module dbatools -ErrorAction Stop
        $expected = @([pscustomobject]@{ Result = 42 })
        Mock Invoke-MigrationCustomSqlInternal -ModuleName DbMigration.Core {
            $expected
        }

        $result = Invoke-MigrationCustomSql -SqlInstance 'target-sql' -Database 'tempdb' -Query 'SELECT 42 AS Result;'

        $result | Should -HaveCount 1
        $result[0].Result | Should -Be 42
        Should -Invoke Invoke-MigrationCustomSqlInternal -ModuleName DbMigration.Core -Times 1 -Exactly -ParameterFilter {
            $SqlInstance -eq 'target-sql' -and $Database -eq 'tempdb' -and $Query -eq 'SELECT 42 AS Result;'
        }
    }

    It 'runs a batch against arbitrary independent instances and reports failures per target' {
        Import-Module dbatools -ErrorAction Stop
        Mock Invoke-MigrationCustomSqlInternal -ModuleName DbMigration.Core {
            if ($SqlInstance -eq 'unreachable-sql') {
                throw 'connection failed'
            }
            [pscustomobject]@{ Instance = $SqlInstance; Result = 42 }
        }

        $results = @(
            Invoke-MigrationCustomSqlBatch -SqlInstances @('standalone-sql', 'unreachable-sql', 'STANDALONE-SQL') `
                -Database 'application' -Query 'SELECT 42 AS Result;'
        )

        $results | Should -HaveCount 2
        $results[0].SqlInstance | Should -Be 'standalone-sql'
        $results[0].Succeeded | Should -BeTrue
        $results[0].Rows[0].Result | Should -Be 42
        $results[1].SqlInstance | Should -Be 'unreachable-sql'
        $results[1].Succeeded | Should -BeFalse
        $results[1].Error | Should -Be 'connection failed'
        Should -Invoke Invoke-MigrationCustomSqlInternal -ModuleName DbMigration.Core -Times 2 -Exactly -ParameterFilter {
            $Database -eq 'application' -and $Query -eq 'SELECT 42 AS Result;'
        }
    }

    It 'splits comma-separated instance names while preserving host and port syntax' {
        Import-Module dbatools -ErrorAction Stop
        $script:customSqlTargets = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-MigrationCustomSqlInternal -ModuleName DbMigration.Core {
            $script:customSqlTargets.Add($SqlInstance)
            [pscustomobject]@{ Instance = $SqlInstance; Result = 42 }
        }

        $results = @(Invoke-MigrationCustomSqlBatch -SqlInstances @('localhost,localhost\NODE2', 'server.example.com,1433') `
            -Database 'master' -Query 'SELECT 1;')

        $results | Should -HaveCount 3
        @($results | ForEach-Object SqlInstance) | Should -Be @(
            'localhost',
            'localhost\NODE2',
            'server.example.com,1433'
        )
        @($script:customSqlTargets) | Should -Be @(
            'localhost',
            'localhost\NODE2',
            'server.example.com,1433'
        )
    }

    It 'rejects empty batch targets and blank instance names' {
        { Invoke-MigrationCustomSqlBatch -SqlInstances @() -Database 'master' -Query 'SELECT 1' } |
            Should -Throw '*At least one SQL instance is required*'
        { Invoke-MigrationCustomSqlBatch -SqlInstances @('server-a', ' ') -Database 'master' -Query 'SELECT 1' } |
            Should -Throw '*SQL instance names cannot be empty*'
    }
}

Describe 'Server disk usage' {
    It 'reads remote volume capacity for a SQL instance and calculates usage percentages' {
        Import-Module dbatools -ErrorAction Stop
        Mock Connect-DbaInstance -ModuleName DbMigration.Core {
            [pscustomobject]@{ ComputerName = 'sql-host' }
        }
        Mock Get-DbaDiskSpace -ModuleName DbMigration.Core {
            @(
                [pscustomobject]@{ Name = 'C:\'; SizeInGB = 100; FreeInGB = 25 }
                [pscustomobject]@{ Name = 'D:\'; SizeInGB = 500; FreeInGB = 400 }
            )
        }

        $disks = @(Get-MigrationDiskUsage -SqlInstance 'sql-host\instance')

        $disks | Should -HaveCount 2
        $disks[0].SqlInstance | Should -Be 'sql-host\instance'
        $disks[0].ComputerName | Should -Be 'sql-host'
        $disks[0].Volume | Should -Be 'C:\'
        $disks[0].UsedGB | Should -Be 75
        $disks[0].PercentUsed | Should -Be 75
        $disks[1].PercentUsed | Should -Be 20
        Should -Invoke Get-DbaDiskSpace -ModuleName DbMigration.Core -Exactly 1
    }

    It 'rejects empty SQL instances and invalid volume capacity' {
        { Get-MigrationDiskUsage -SqlInstance ' ' } | Should -Throw '*SqlInstance is required*'

        Import-Module dbatools -ErrorAction Stop
        Mock Connect-DbaInstance -ModuleName DbMigration.Core {
            [pscustomobject]@{ ComputerName = 'sql-host' }
        }
        Mock Get-DbaDiskSpace -ModuleName DbMigration.Core {
            @([pscustomobject]@{ Name = 'C:\'; SizeInGB = 0; FreeInGB = 0 })
        }

        { Get-MigrationDiskUsage -SqlInstance 'sql-host' } | Should -Throw '*invalid capacity values*'
    }
}

Describe 'Web patch target resolution' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\Invoke-DbMigrationWeb.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-WebPatchTargets' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        function Get-WebPair { param($Index) @{ Source = 'source'; Target = 'target' } }
    }

    It 'uses the supplied SqlInstance for source and target roles' {
        $targets = @(ConvertTo-WebPatchTargets -Selections @(
            @{ PairIndex = 0; Role = 'Source'; SqlInstance = 'localhost' },
            @{ PairIndex = 0; Role = 'Target'; SqlInstance = 'localhost\NODE2' }))
        $targets[0].SqlInstance | Should -Be 'localhost'
        $targets[1].SqlInstance | Should -Be 'localhost\NODE2'
    }

    It 'falls back to the configured pair when no SqlInstance is supplied' {
        $targets = @(ConvertTo-WebPatchTargets -Selections @(@{ PairIndex = 0; Role = 'Source' }))
        $targets[0].SqlInstance | Should -Be 'source'
    }
}

Describe 'Web host script safeguards' {
    BeforeAll {
        $script:webHostText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Invoke-DbMigrationWeb.ps1') -Raw
    }

    It 'never passes a comparison parameter twice to Where-Object' {
        $script:webHostText | Should -Not -Match 'Where-Object\s+\w+\s+-(ne|eq|gt|lt)\s+[^|)]*\s-and\s'
    }

    It 'refuses local SQL Server patching with a clear message when not elevated, and the launcher self-elevates' {
        $script:webHostText | Should -Match 'Test-WebHostElevated'
        $script:webHostText | Should -Match 'needs administrator rights'
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start-PortableDbMigrationWeb.ps1') -Raw) | Should -Match '-Verb RunAs'
    }

    It 'enforces a single machine-wide web host instance' {
        $script:webHostText | Should -Match 'Global\\DbMigrationToolWebHost'
        $portableText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Start-PortableDbMigrationWeb.ps1') -Raw
        $portableText | Should -Match 'Global\\DbMigrationToolWebHost'
    }
}

Describe 'Web pair backup path requirement' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\Invoke-DbMigrationWeb.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-WebPairs' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }

    It 'allows discovery without a backup path' {
        $pair = @(ConvertTo-WebPairs -Pairs @(@{ Source = 'a'; Target = 'b'; BackupPath = '' }))[0]
        $pair.BackupPath | Should -Be ''
    }

    It 'requires a backup path when migrating' {
        { ConvertTo-WebPairs -Pairs @(@{ Source = 'a'; Target = 'b'; BackupPath = '' }) -RequireBackupPath } |
            Should -Throw '*BackupPath*'
    }

    It 'preserves per-pair linked-server inventory and its loaded state' {
        $pair = @(ConvertTo-WebPairs -Pairs @(@{
            Source = 'a'
            Target = 'b'
            BackupPath = ''
            LinkedServersLoaded = $true
            LinkedServers = @(@{ LinkedServer = 'warehouse'; DataSource = 'warehouse-new' })
        }))[0]

        $pair.LinkedServersLoaded | Should -BeTrue
        $pair.LinkedServers[0].LinkedServer | Should -Be 'warehouse'
        $pair.LinkedServers[0].DataSource | Should -Be 'warehouse-new'
    }
}

Describe 'SQL Server patch helper' {
    BeforeAll {
        Import-Module dbatools -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Patching.psm1') -Force
    }

    It 'requires an existing local update repository before contacting SQL Server' {
        { Invoke-MigrationSqlServerPatch -SqlInstance 'sql01\app' -UpdatePath (Join-Path $TestDrive 'missing') -KB '5104824' } |
            Should -Throw '*update repository folder was not found*'
    }

    It 'targets the assessed instance and selected KB without rebooting by default' {
        $repository = Join-Path $TestDrive 'updates'
        $null = New-Item -ItemType Directory -Path $repository
        Set-Content -LiteralPath (Join-Path $repository 'sqlserver2022-KB5104824-x64.exe') -Value 'test-package'
        Mock Get-MigrationSqlServerPatchAssessment -ModuleName DbMigration.Patching {
            [pscustomobject]@{
                SqlInstance = 'sqlhost01\app'
                ComputerName = 'SQLHOST01'
                InstanceName = 'APP'
                CurrentVersion = '16.0.1000.6'
                PatchBuild = '16.0.4295'
                Status = 'Eligible'
            }
        }
        Mock Update-DbaInstance -ModuleName DbMigration.Patching { $null }

        $result = Invoke-MigrationSqlServerPatch -SqlInstance 'sqlhost01\app' -UpdatePath $repository -KB '5104824'

        $result.Status | Should -Be 'Completed'
        $result.CurrentVersion | Should -Be '16.0.1000.6'
        $result.KB | Should -Be '5104824'
        Should -Invoke Update-DbaInstance -ModuleName DbMigration.Patching -Times 1 -Exactly -ParameterFilter {
            @($ComputerName | ForEach-Object { $_.ComputerName }) -contains 'SQLHOST01' -and
            $InstanceName -eq 'APP' -and $Path -contains $repository -and
            $KB -eq '5104824' -and -not $Restart
        }
    }

    It 'blocks application when the selected patch is not eligible' {
        $repository = Join-Path $TestDrive 'blocked-updates'
        $null = New-Item -ItemType Directory -Path $repository
        Set-Content -LiteralPath (Join-Path $repository 'sqlserver2022-KB5104824-x64.exe') -Value 'test-package'
        Mock Get-MigrationSqlServerPatchAssessment -ModuleName DbMigration.Patching {
            [pscustomobject]@{
                SqlInstance = 'sqlcluster01\prod'
                ComputerName = 'SQLCLUSTER01'
                InstanceName = 'PROD'
                CurrentVersion = '16.0.1000.6'
                PatchBuild = '16.0.4295'
                Status = 'UnsupportedCluster'
                Reason = 'Clustered instances require a cluster-aware patch procedure.'
            }
        }
        Mock Update-DbaInstance -ModuleName DbMigration.Patching { $null }

        { Invoke-MigrationSqlServerPatch -SqlInstance 'sqlcluster01\prod' -UpdatePath $repository -KB '5104824' } |
            Should -Throw '*UnsupportedCluster*cluster-aware*'

        Should -Invoke Update-DbaInstance -ModuleName DbMigration.Patching -Times 0 -Exactly
    }

    It 'restarts the Windows host only when explicitly requested' {
        $repository = Join-Path $TestDrive 'restart-updates'
        $null = New-Item -ItemType Directory -Path $repository
        Set-Content -LiteralPath (Join-Path $repository 'sqlserver2022-KB5104824-x64.exe') -Value 'test-package'
        Mock Get-MigrationSqlServerPatchAssessment -ModuleName DbMigration.Patching {
            [pscustomobject]@{
                SqlInstance = 'sqlhost01\app'
                ComputerName = 'SQLHOST01'
                InstanceName = 'APP'
                CurrentVersion = '16.0.1000.6'
                PatchBuild = '16.0.4295'
                Status = 'Eligible'
            }
        }
        Mock Update-DbaInstance -ModuleName DbMigration.Patching { $null }

        Invoke-MigrationSqlServerPatch -SqlInstance 'sqlhost01\app' -UpdatePath $repository -KB '5104824' -Restart

        Should -Invoke Update-DbaInstance -ModuleName DbMigration.Patching -Times 1 -Exactly -ParameterFilter {
            $Restart -and $ComputerName.ComputerName -eq 'SQLHOST01' -and $KB -eq '5104824'
        }
    }

    It 'marks a same-major higher build as eligible' {
        Mock Get-MigrationSqlServerPatchByKB -ModuleName DbMigration.Patching {
            [pscustomobject]@{ KB = '5104824'; MajorVersion = '2022'; ServicePack = 'RTM'; UpdateLevel = 'CU27'; BuildLevel = '16.0.4295'; Title = 'SQL Server 2022 CU27'; SupportedUntil = (Get-Date).AddYears(5).ToString('o') }
        }
        Mock Get-MigrationSqlServerPatchServerInfoInternal -ModuleName DbMigration.Patching {
            [pscustomobject]@{ MachineName = 'SQLHOST01'; InstanceName = 'APP'; IsClustered = 0; ProductVersion = '16.0.1000.6' }
        }
        Mock Get-DbaBuild -ModuleName DbMigration.Patching {
            [pscustomobject]@{ NameLevel = '2022'; SPLevel = 'RTM'; CULevel = 'RTM'; KBLevel = ''; BuildLevel = '16.0.1000'; SupportedUntil = (Get-Date).AddYears(5) }
        }

        $assessment = Get-MigrationSqlServerPatchAssessment -SqlInstance 'sqlhost01\app' -KB '5104824'

        $assessment.Status | Should -Be 'Eligible'
        $assessment.CurrentVersion | Should -Be '16.0.1000.6'
        $assessment.PatchBuild | Should -Be '16.0.4295'
    }

    It 'marks the exact installed KB as already installed' {
        Mock Get-MigrationSqlServerPatchByKB -ModuleName DbMigration.Patching {
            [pscustomobject]@{ KB = '5104824'; MajorVersion = '2022'; ServicePack = 'RTM'; UpdateLevel = 'CU27'; BuildLevel = '16.0.4295'; Title = 'SQL Server 2022 CU27'; SupportedUntil = (Get-Date).AddYears(5).ToString('o') }
        }
        Mock Get-MigrationSqlServerPatchServerInfoInternal -ModuleName DbMigration.Patching {
            [pscustomobject]@{ MachineName = 'SQLHOST01'; InstanceName = 'APP'; IsClustered = 0; ProductVersion = '16.0.4295.3' }
        }
        Mock Get-DbaBuild -ModuleName DbMigration.Patching {
            [pscustomobject]@{ NameLevel = '2022'; SPLevel = 'RTM'; CULevel = 'CU27'; KBLevel = 'KB5104824'; BuildLevel = '16.0.4295'; SupportedUntil = (Get-Date).AddYears(5) }
        }

        (Get-MigrationSqlServerPatchAssessment -SqlInstance 'sqlhost01\app' -KB '5104824').Status | Should -Be 'AlreadyInstalled'
    }

    It 'allows a newer service-pack package on the same SQL Server major version' {
        Mock Get-MigrationSqlServerPatchByKB -ModuleName DbMigration.Patching {
            [pscustomobject]@{ KB = '5003279'; MajorVersion = '2016'; ServicePack = 'SP3'; UpdateLevel = 'Service Pack'; BuildLevel = '13.0.6300'; Title = 'SQL Server 2016 SP3'; SupportedUntil = (Get-Date).AddYears(2).ToString('o') }
        }
        Mock Get-MigrationSqlServerPatchServerInfoInternal -ModuleName DbMigration.Patching {
            [pscustomobject]@{ MachineName = 'SQLHOST01'; InstanceName = 'APP'; IsClustered = 0; ProductVersion = '13.0.5888.11' }
        }
        Mock Get-DbaBuild -ModuleName DbMigration.Patching {
            [pscustomobject]@{ NameLevel = '2016'; SPLevel = 'SP2'; CULevel = 'CU17'; KBLevel = 'KB5001092'; BuildLevel = '13.0.5888'; SupportedUntil = (Get-Date).AddYears(2) }
        }

        (Get-MigrationSqlServerPatchAssessment -SqlInstance 'sqlhost01\app' -KB '5003279').Status | Should -Be 'Eligible'
    }

    It 'blocks a patch for a different SQL Server major version' {
        Mock Get-MigrationSqlServerPatchByKB -ModuleName DbMigration.Patching {
            [pscustomobject]@{ KB = '5104824'; MajorVersion = '2022'; ServicePack = 'RTM'; UpdateLevel = 'CU27'; BuildLevel = '16.0.4295'; Title = 'SQL Server 2022 CU27'; SupportedUntil = (Get-Date).AddYears(5).ToString('o') }
        }
        Mock Get-MigrationSqlServerPatchServerInfoInternal -ModuleName DbMigration.Patching {
            [pscustomobject]@{ MachineName = 'SQLHOST01'; InstanceName = 'APP'; IsClustered = 0; ProductVersion = '15.0.4430.1' }
        }
        Mock Get-DbaBuild -ModuleName DbMigration.Patching {
            [pscustomobject]@{ NameLevel = '2019'; SPLevel = 'RTM'; CULevel = 'CU32'; KBLevel = 'KB5054833'; BuildLevel = '15.0.4430'; SupportedUntil = (Get-Date).AddYears(3) }
        }

        (Get-MigrationSqlServerPatchAssessment -SqlInstance 'sqlhost01\app' -KB '5104824').Status | Should -Be 'VersionMismatch'
    }

    It 'marks an older selected patch as superseded by the installed build' {
        Mock Get-MigrationSqlServerPatchByKB -ModuleName DbMigration.Patching {
            [pscustomobject]@{ KB = '5093420'; MajorVersion = '2022'; ServicePack = 'RTM'; UpdateLevel = 'CU26'; BuildLevel = '16.0.4265'; Title = 'SQL Server 2022 CU26'; SupportedUntil = (Get-Date).AddYears(5).ToString('o') }
        }
        Mock Get-MigrationSqlServerPatchServerInfoInternal -ModuleName DbMigration.Patching {
            [pscustomobject]@{ MachineName = 'SQLHOST01'; InstanceName = 'APP'; IsClustered = 0; ProductVersion = '16.0.4295.3' }
        }
        Mock Get-DbaBuild -ModuleName DbMigration.Patching {
            [pscustomobject]@{ NameLevel = '2022'; SPLevel = 'RTM'; CULevel = 'CU27'; KBLevel = 'KB5104824'; BuildLevel = '16.0.4295'; SupportedUntil = (Get-Date).AddYears(5) }
        }

        (Get-MigrationSqlServerPatchAssessment -SqlInstance 'sqlhost01\app' -KB '5093420').Status | Should -Be 'Superseded'
    }

    It 'refreshes and deduplicates catalog rows by SQL build and KB' {
        Mock Update-DbaBuildReference -ModuleName DbMigration.Patching {}
        Mock Get-DbaBuild -ModuleName DbMigration.Patching {
            if ($MajorVersion -eq 'SQL2022' -and $ServicePack -eq 'RTM') {
                if ($CumulativeUpdate -eq 'CU1') {
                    [pscustomobject]@{ NameLevel = '2022'; SPLevel = 'RTM'; CULevel = 'CU1'; KBLevel = 'KB5100001'; Build = '16.0.1.1'; BuildLevel = '16.0.1'; ReleaseDate = Get-Date; SupportedUntil = (Get-Date).AddYears(5); MatchType = 'Exact' }
                }
                elseif ($CumulativeUpdate -in @('CU2', 'CU3', 'CU4')) {
                    [pscustomobject]@{ NameLevel = '2022'; SPLevel = 'RTM'; CULevel = 'CU1 + GDR'; KBLevel = 'KB5100002'; Build = '16.0.2.1'; BuildLevel = '16.0.2'; ReleaseDate = (Get-Date).AddDays(1); SupportedUntil = (Get-Date).AddYears(5); MatchType = 'Exact' }
                }
            }

        }

        $catalog = @(Get-MigrationSqlServerPatchCatalog -Refresh)

        @($catalog | Where-Object KB -eq '5100001').Count | Should -Be 1
        @($catalog | Where-Object KB -eq '5100002').Count | Should -Be 1
        Should -Invoke Update-DbaBuildReference -ModuleName DbMigration.Patching -Times 1 -Exactly
    }

    It 'downloads the selected KB to the chosen repository as x64' {
        $repository = Join-Path $TestDrive 'downloaded-updates'
        Mock Get-DbaBuild -ModuleName DbMigration.Patching {
            [pscustomobject]@{ NameLevel = '2022'; SPLevel = 'RTM'; CULevel = 'CU27'; KBLevel = 'KB5104824'; Build = '16.0.4295.3'; BuildLevel = '16.0.4295'; ReleaseDate = Get-Date; SupportedUntil = (Get-Date).AddYears(5); MatchType = 'Exact' }
        }
        Mock Get-DbaKbUpdate -ModuleName DbMigration.Patching { [pscustomobject]@{ Link = 'https://catalog.example.invalid/package.exe' } }
        Mock Save-DbaKbUpdate -ModuleName DbMigration.Patching {
            Set-Content -LiteralPath (Join-Path $Path 'sqlserver2022-KB5104824-x64.exe') -Value 'mock package'
        }

        $download = Save-MigrationSqlServerPatch -KB '5104824' -Path $repository

        $download.KB | Should -Be '5104824'
        $download.Path | Should -Exist
        Should -Invoke Save-DbaKbUpdate -ModuleName DbMigration.Patching -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'KB5104824' -and $Path -contains $repository -and $Architecture -eq 'x64'
        }
    }

    It 'filters patch options to the selected SQL version and servicing branch' {
        $catalog = @(
            [pscustomobject]@{ Product = 'SQL Server 2022'; MajorVersion = '2022'; ServicePack = 'RTM'; UpdateLevel = 'CU27'; KB = '5104824'; BuildLevel = '16.0.4295'; ReleaseDate = '2026-09-15'; SupportedUntil = '' }
            [pscustomobject]@{ Product = 'SQL Server 2019'; MajorVersion = '2019'; ServicePack = 'RTM'; UpdateLevel = 'CU32'; KB = '5054833'; BuildLevel = '15.0.4430'; ReleaseDate = '2025-02-27'; SupportedUntil = '' }
            [pscustomobject]@{ Product = 'SQL Server 2016'; MajorVersion = '2016'; ServicePack = 'SP2'; UpdateLevel = 'CU17'; KB = '5001092'; BuildLevel = '13.0.5888'; ReleaseDate = '2021-03-29'; SupportedUntil = '' }
            [pscustomobject]@{ Product = 'SQL Server 2016'; MajorVersion = '2016'; ServicePack = 'SP3'; UpdateLevel = 'Service Pack'; KB = '5003279'; BuildLevel = '13.0.6300'; ReleaseDate = '2021-09-15'; SupportedUntil = '' }
            [pscustomobject]@{ Product = 'SQL Server 2016'; MajorVersion = '2016'; ServicePack = 'SP3'; UpdateLevel = 'GDR'; KB = '5102339'; BuildLevel = '13.0.7095'; ReleaseDate = '2026-07-14'; SupportedUntil = '' }
        )

        $sql2022Options = @(Get-MigrationRelevantPatchCatalog -Catalog $catalog -ServerBuilds @(
            [pscustomobject]@{ MajorVersion = '2022'; ServicePack = 'RTM'; BuildLevel = '16.0.1000' }
        ))
        $sql2016Sp2Options = @(Get-MigrationRelevantPatchCatalog -Catalog $catalog -ServerBuilds @(
            [pscustomobject]@{ MajorVersion = '2016'; ServicePack = 'SP2'; BuildLevel = '13.0.5888' }
        ))

        $sql2022Options.KB | Should -Be @('5104824')
        $sql2016Sp2Options.KB | Should -Contain '5001092'
        $sql2016Sp2Options.KB | Should -Contain '5003279'
        $sql2016Sp2Options.KB | Should -Not -Contain '5102339'
    }
}

Describe 'Migration state' {
    It 'records progress and reads it back for resume' {
        $path = Join-Path $TestDrive 'MigrationState.json'
        $output = @(Set-MigrationState -Path $path -Source source -Target target -Database appdb -Status BackupCompleted -BackupPath 'C:\backups\appdb.bak')

        $state = Get-MigrationState -Path $path
        $key = Get-MigrationStateKey -Source source -Target target -Database appdb

        $output.Count | Should -Be 0
        $state.Databases[$key].Status | Should -Be 'BackupCompleted'
        $state.Databases[$key].BackupPath | Should -Be 'C:\backups\appdb.bak'
    }

    It 'creates distinct keys for different migration endpoints' {
        $first = Get-MigrationStateKey -Source source-a -Target target -Database appdb
        $second = Get-MigrationStateKey -Source source-b -Target target -Database appdb

        $first | Should -Not -Be $second
    }

    It 'creates collision-resistant backup names for database names that contain path characters' {
        $first = Get-MigrationBackupPath -Directory 'C:\backups' -Source source -Target target -Database 'finance/archive'
        $second = Get-MigrationBackupPath -Directory 'C:\backups' -Source source -Target target -Database 'finance:archive'

        (Split-Path -Leaf $first) | Should -Not -Match '[\\/:*?"<>|]'
        $first | Should -Not -Be $second
    }

    It 'creates a unique sanitized per-source run backup directory' {
        $first = Get-MigrationRunBackupDirectory -RootDirectory '\\backup\sql' -Source 'source/one' -Target 'target' -RunId ([guid]::NewGuid())
        $second = Get-MigrationRunBackupDirectory -RootDirectory '\\backup\sql' -Source 'source/one' -Target 'target' -RunId ([guid]::NewGuid())

        $first | Should -Match '^\\\\backup\\sql\\migration-source_one-to-target-'
        $first | Should -Not -Be $second
    }

    It 'creates isolated database backup directories within the run folder' {
        $runDirectory = '\\backup\sql\migration-source-to-target-0123456789abcdef0123456789abcdef'
        $first = Get-MigrationDatabaseBackupDirectory -RunDirectory $runDirectory -Source source -Target target -Database first
        $second = Get-MigrationDatabaseBackupDirectory -RunDirectory $runDirectory -Source source -Target target -Database second
        $repeat = Get-MigrationDatabaseBackupDirectory -RunDirectory $runDirectory -Source source -Target target -Database first

        (Split-Path -Parent $first) | Should -Be $runDirectory
        $first | Should -Not -Be $second
        $repeat | Should -Be $first
    }

    It 'deletes only a matching per-run backup directory' {
        $root = Join-Path $TestDrive 'backups'
        $null = New-Item -ItemType Directory -Path $root
        $runDirectory = Get-MigrationRunBackupDirectory -RootDirectory $root -Source source -Target target -RunId ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $runDirectory
        'stripe' | Set-Content -LiteralPath (Join-Path $runDirectory 'appdb-1-of-4.bak')
        $unrelatedDirectory = Join-Path $root 'keep'
        $null = New-Item -ItemType Directory -Path $unrelatedDirectory

        Remove-MigrationRunBackupDirectory -RootDirectory $root -Directory $runDirectory -Source source -Target target | Should -BeTrue
        Test-Path -LiteralPath $runDirectory | Should -BeFalse
        Test-Path -LiteralPath $unrelatedDirectory | Should -BeTrue
        { Remove-MigrationRunBackupDirectory -RootDirectory $root -Directory $root -Source source -Target target } | Should -Throw '*Refusing to remove backup path*'
    }
}

Describe 'Migration progress events' {
    It 'writes atomic structured events for live monitoring' {
        $progressPath = Join-Path $TestDrive 'progress'
        Write-MigrationProgressEvent -ProgressPath $progressPath -Source source -Target target `
            -Database appdb -Stage Restore -Status Started -Message 'Restore started.'

        $eventFiles = @(Get-ChildItem -LiteralPath $progressPath -Filter '*.json' -File)
        $eventFiles.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $progressPath -Filter '*.tmp' -File).Count | Should -Be 0
        $progressEvent = Get-Content -LiteralPath $eventFiles[0].FullName -Raw | ConvertFrom-Json
        $progressEvent.Source | Should -Be 'source'
        $progressEvent.Target | Should -Be 'target'
        $progressEvent.Database | Should -Be 'appdb'
        $progressEvent.Stage | Should -Be 'Restore'
        $progressEvent.Status | Should -Be 'Started'
        $progressEvent.Message | Should -Be 'Restore started.'
        $progressEvent.PercentComplete | Should -Be 0
        $planProgressPath = Join-Path $TestDrive 'plan-progress'
        Write-MigrationProgressEvent -ProgressPath $planProgressPath -Source '' -Target '' `
            -Stage Migration -Status Completed -Message 'Sequential migration run completed.'
        $planEventPath = (Get-ChildItem -LiteralPath $planProgressPath -Filter '*.json' -File).FullName
        $planEvent = Get-Content -LiteralPath $planEventPath -Raw | ConvertFrom-Json
        $planEvent.Source | Should -Be ''
        $planEvent.Target | Should -Be ''
        $planEvent.Stage | Should -Be 'Migration'
        $planEvent.PercentComplete | Should -Be 100
        { Write-MigrationProgressEvent -ProgressPath $progressPath -Source source -Target target -Stage Restore -Status Invalid } |
            Should -Throw
    }

    It 'honors a stop request at a safe checkpoint' {
        $controlPath = Join-Path $TestDrive 'control.json'
        $progressPath = Join-Path $TestDrive 'control-progress'
        Set-Content -LiteralPath $controlPath -Value '{"Action":"Stop"}'

        (Wait-MigrationControl -ControlPath $controlPath -ProgressPath $progressPath `
            -Source source -Target target -HonorStop) | Should -BeFalse
        $progressEvent = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $progressPath -Filter '*.json').FullName -Raw |
            ConvertFrom-Json
        $progressEvent.Status | Should -Be 'Stopped'
    }

    It 'waits while paused and resumes at the next checkpoint' {
        $controlPath = Join-Path $TestDrive 'pause-control.json'
        $progressPath = Join-Path $TestDrive 'pause-progress'
        Set-Content -LiteralPath $controlPath -Value '{"Action":"Pause"}'
        $modulePath = Join-Path $PSScriptRoot '..\src\DbMigration.Core.psm1'
        $job = Start-Job -ArgumentList $modulePath, $controlPath, $progressPath -ScriptBlock {
            param($module, $control, $progress)
            Import-Module $module -Force
            Wait-MigrationControl -ControlPath $control -ProgressPath $progress -Source source -Target target
        }
        try {
            $pauseDeadline = [DateTime]::UtcNow.AddSeconds(10)
            $pausedEventFound = $false
            while (-not $pausedEventFound -and [DateTime]::UtcNow -lt $pauseDeadline) {
                $pausedEventFound = @(
                    Get-ChildItem -LiteralPath $progressPath -Filter '*.json' -File -ErrorAction SilentlyContinue |
                        ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Status } |
                        Where-Object { $_ -eq 'Paused' }
                ).Count -gt 0
                if (-not $pausedEventFound) {
                    Start-Sleep -Milliseconds 50
                }
            }
            $pausedEventFound | Should -BeTrue -Because 'the job must reach the pause checkpoint before it is resumed'
            Set-Content -LiteralPath $controlPath -Value '{"Action":"Resume"}'
            (Receive-Job -Job $job -Wait -AutoRemoveJob) | Should -BeTrue
            $statuses = @(Get-ChildItem -LiteralPath $progressPath -Filter '*.json' |
                ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Status })
            $statuses | Should -Contain 'Paused'
            $statuses | Should -Contain 'InProgress'
        }
        finally {
            if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Safe database restore' {
    BeforeAll {
        Import-Module dbatools -ErrorAction Stop
    }

    It 'retries an orphaned destination-file conflict with unique file names and reports the retry prefix' {
        $script:restoreAttempts = 0
        Mock Restore-DbaDatabase -ModuleName DbMigration.Transfer {
            $script:restoreAttempts++
            if ($script:restoreAttempts -eq 1) {
                throw 'File D:\Data\appdb.mdf already exists on sql-host, not owned by any database in sql-host\NODE2, will not overwrite.'
            }
        }

        $result = Invoke-MigrationSafeRestore -SqlInstance 'sql-host\NODE2' -Path @('C:\backup\stripe.bak') `
            -DatabaseName appdb -DestinationDataDirectory 'D:\Data' -DestinationLogDirectory 'D:\Log' `
            -AllowFileCollisionRetry $true

        $script:restoreAttempts | Should -Be 2
        $result.FileCollisionRetry | Should -BeTrue
        $result.DestinationFilePrefix | Should -Match '^mig_[a-f0-9]{12}_$'
        Should -Invoke Restore-DbaDatabase -ModuleName DbMigration.Transfer -Exactly 1 -ParameterFilter {
            $DestinationFilePrefix -like 'mig_*'
        }
    }

    It 'does not retry destination-file conflicts when collision retry is not enabled' {
        $script:restoreAttempts = 0
        Mock Restore-DbaDatabase -ModuleName DbMigration.Transfer {
            $script:restoreAttempts++
            throw 'File D:\Data\appdb.mdf already exists on sql-host, not owned by any database in sql-host\NODE2, will not overwrite.'
        }

        {
            Invoke-MigrationSafeRestore -SqlInstance 'sql-host\NODE2' -Path @('C:\backup\stripe.bak') `
                -DatabaseName appdb -DestinationDataDirectory 'D:\Data' -DestinationLogDirectory 'D:\Log'
        } | Should -Throw '*not owned by any database*'

        $script:restoreAttempts | Should -Be 1
        Should -Invoke Restore-DbaDatabase -ModuleName DbMigration.Transfer -Exactly 1
    }

    It 'does not retry restore errors unrelated to an orphaned destination file' {
        Mock Restore-DbaDatabase -ModuleName DbMigration.Transfer {
            throw 'Backup checksum validation failed.'
        }

        {
            Invoke-MigrationSafeRestore -SqlInstance target -Path @('C:\backup\stripe.bak') `
                -DatabaseName appdb -DestinationDataDirectory 'D:\Data' -DestinationLogDirectory 'D:\Log' `
                -AllowFileCollisionRetry $true
        } | Should -Throw '*checksum validation failed*'

        Should -Invoke Restore-DbaDatabase -ModuleName DbMigration.Transfer -Exactly 1
    }
}

Describe 'Full-text migration readiness' {
    BeforeAll {
        Import-Module dbatools -ErrorAction Stop
    }

    It 'blocks database migrations when full-text objects exist but the target feature is missing' {
        Mock Invoke-DbaQuery -ModuleName DbMigration.Transfer {
            if ($Query -match 'sys.fulltext_indexes') {
                [pscustomobject]@{ FullTextIndexCount = 3; FullTextPredicateModuleCount = 2 }
            }
            else {
                [pscustomobject]@{ FullTextInstalled = 0 }
            }
        }

        $result = Test-MigrationFullTextReadiness -Source source -Target target -Database appdb

        $result.Status | Should -Be 'Failed'
        $result.Stage | Should -Be 'FullTextPreflight'
        $result.SourceFullTextIndexCount | Should -Be 3
        $result.TargetFullTextInstalled | Should -BeFalse
        $result.Message | Should -Match 'Full-Text Search is not installed'
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.Transfer -Exactly 2
    }

    It 'allows migration when the source has no full-text objects and target search is absent' {
        Mock Invoke-DbaQuery -ModuleName DbMigration.Transfer {
            if ($Query -match 'sys.fulltext_indexes') {
                [pscustomobject]@{ FullTextIndexCount = 0; FullTextPredicateModuleCount = 0 }
            }
            else {
                [pscustomobject]@{ FullTextInstalled = 0 }
            }
        }

        $result = Test-MigrationFullTextReadiness -Source source -Target target -Database appdb

        $result.Status | Should -Be 'Passed'
        $result.TargetFullTextInstalled | Should -BeFalse
        $result.Message | Should -Match 'no full-text indexes'
    }
}

Describe 'Migration reports' {
    It 'writes valid CSV content when there are no rows to report' {
        $outputPath = Join-Path $TestDrive 'reports'

        $report = Write-MigrationReports -Rows @() -OutputPath $outputPath -Name 'Validation'

        $report.CsvPath | Should -Exist
        $report.HtmlPath | Should -Exist
        $csvContent = Get-Content -LiteralPath $report.CsvPath -Raw
        $csvContent | Should -Match 'Message'
        $csvContent | Should -Match 'No records'
    }

    It 'creates management-friendly HTML with styled status summaries' {
        $outputPath = Join-Path $TestDrive 'management-reports'
        $rows = @(
            [pscustomobject]@{ Source = 'source'; Target = 'target'; Database = 'AppDb'; Stage = 'Restore'; Status = 'Failed'; Message = 'Restore failed.' },
            [pscustomobject]@{ Source = 'source'; Target = 'target'; Database = 'AppDb'; Stage = 'Validate'; Status = 'Completed'; Message = 'Validation passed.' }
        )

        $report = Write-MigrationReports -Rows $rows -OutputPath $outputPath -Name 'Migration'
        $html = Get-Content -LiteralPath $report.HtmlPath -Raw

        $html | Should -Match '<style>'
        $html | Should -Match 'summary-card'
        $html | Should -Match 'status-fail'
        $html | Should -Match 'status-pass'
    }
}

Describe 'Application installation' {
    It 'leaves first-run account creation to the browser setup flow' {
        $runningHost = $null
        if ([System.Threading.Mutex]::TryOpenExisting('Global\DbMigrationToolWebHost', [ref]$runningHost)) {
            $runningHost.Dispose()
            Set-ItResult -Skipped -Because 'A running app host holds the machine-wide single-instance mutex.'
            return
        }

        $appRoot = Join-Path $TestDrive 'PortableFirstRun'
        $null = New-Item -ItemType Directory -Path (Join-Path $appRoot 'src') -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src\DbMigration.WebAuth.psm1') `
            -Destination (Join-Path $appRoot 'src\DbMigration.WebAuth.psm1')
        @'
param([string] $HostName, [int] $Port, [switch] $PortableMode, [string] $AppRoot)
'@ | Set-Content -LiteralPath (Join-Path $appRoot 'Invoke-DbMigrationWeb.ps1')

        $previousNoElevate = $env:DBMIGRATION_NO_ELEVATE
        $env:DBMIGRATION_NO_ELEVATE = '1'
        try {
            $output = @(
                & (Join-Path $PSScriptRoot '..\Start-PortableDbMigrationWeb.ps1') -AppRoot $appRoot 6>&1 |
                    ForEach-Object { $_.ToString() }
            ) -join "`n"
            $authPath = Join-Path $appRoot 'portable\auth\auth.json'
            $output | Should -Match 'Complete first-run administrator setup in the browser'
            $output | Should -Not -Match 'Initial portable login|Password:'
            Test-Path -LiteralPath $authPath | Should -BeFalse

            $secondLaunch = @(
                & (Join-Path $PSScriptRoot '..\Start-PortableDbMigrationWeb.ps1') -AppRoot $appRoot 6>&1 |
                    ForEach-Object { $_.ToString() }
            ) -join "`n"
            $secondLaunch | Should -Match 'Complete first-run administrator setup in the browser'
        }
        finally {
            $env:DBMIGRATION_NO_ELEVATE = $previousNoElevate
        }
    }

    It 'installs the app bundle in a stable location and cleans up correctly' {
        $installRoot = Join-Path $TestDrive 'DbMigrationTool'
        $portableAuth = Join-Path $installRoot 'portable\auth'
        $portableLogs = Join-Path $installRoot 'portable\logs'
        $null = New-Item -ItemType Directory -Path $portableAuth -Force
        $null = New-Item -ItemType Directory -Path $portableLogs -Force
        Set-Content -LiteralPath (Join-Path $portableAuth 'auth.json') -Value 'preserve-existing-auth'
        Set-Content -LiteralPath (Join-Path $portableLogs 'existing.log') -Value 'preserve-existing-log'

        & (Join-Path $PSScriptRoot '..\Install-DbMigrationWeb.ps1') -CurrentUser -InstallPath $installRoot -NoDesktopShortcut -NoStartMenuShortcut

        Test-Path -LiteralPath (Join-Path $installRoot 'Start-PortableDbMigrationWeb.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'Start-DbMigrationWeb.cmd') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'Install-DbMigrationPrerequisites.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'Setup-DbMigrationTool.cmd') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $installRoot 'Setup-DbMigrationTool.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $installRoot 'Invoke-DbMigrationPatch.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'src\DbMigration.Patching.psm1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'appinfo.json') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $installRoot 'appinfo.json') -Raw) | Should -Not -Match 'DefaultPassword|MigrationAdmin123'
        Test-Path -LiteralPath (Join-Path $installRoot 'portable\auth') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installRoot 'portable\logs') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $installRoot 'portable\auth\auth.json') -Raw).TrimEnd() | Should -Be 'preserve-existing-auth'
        (Get-Content -LiteralPath (Join-Path $installRoot 'portable\logs\existing.log') -Raw).TrimEnd() | Should -Be 'preserve-existing-log'
        Test-Path -LiteralPath (Join-Path $installRoot 'portable\auth\auth.json') | Should -BeTrue

        & (Join-Path $PSScriptRoot '..\Uninstall-DbMigrationWeb.ps1') -InstallPath $installRoot

        Test-Path -LiteralPath $installRoot | Should -BeFalse
    }

    It 'does not copy workspace portable credentials into a fresh app install' {
        $installRoot = Join-Path $TestDrive 'FreshDbMigrationTool'

        & (Join-Path $PSScriptRoot '..\Install-DbMigrationWeb.ps1') -CurrentUser -InstallPath $installRoot -NoDesktopShortcut -NoStartMenuShortcut

        Test-Path -LiteralPath (Join-Path $installRoot 'portable\auth\auth.json') | Should -BeFalse

        & (Join-Path $PSScriptRoot '..\Uninstall-DbMigrationWeb.ps1') -InstallPath $installRoot
    }
}

Describe 'Prerequisite installation' {
    It 'reuses an already available dbatools installation' {
        Import-Module dbatools -ErrorAction Stop

        $result = & (Join-Path $PSScriptRoot '..\Install-DbMigrationPrerequisites.ps1') -Scope CurrentUser

        $result.PowerShellVersion | Should -Be $PSVersionTable.PSVersion.ToString()
        $result.DbatoolsVersion | Should -Not -BeNullOrEmpty
        $result.InstalledByScript | Should -BeFalse
        $result.Scope | Should -Be 'CurrentUser'
    }
}

Describe 'Pair endpoint validation' {
    BeforeAll {
        Import-Module dbatools -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Discovery.psm1') -Force
    }

    It 'validates manually entered hostname, instance, IP, and UNC backup path' {
        Import-Module dbatools -ErrorAction Stop
        $script:connectionOrder = 0
        $script:validatedSqlInstances = @()
        Mock Connect-DbaInstance -ModuleName DbMigration.Discovery {
            $script:connectionOrder++
            $script:validatedSqlInstances += [string]$SqlInstance
            $majorVersion = if ($script:connectionOrder -eq 1) { 15 } else { 16 }
            [pscustomobject]@{ SqlInstance = $SqlInstance; VersionMajor = $majorVersion }
        }
        Mock Test-DbaPath -ModuleName DbMigration.Discovery { $true }
        $configuration = @{
            SourceTargets = @(@{
                Source = '192.168.1.20\SQL2019'
                Target = 'SQLTARGET\SQL2022'
                BackupPath = '\\NAS01\SqlBackup'
                MigrationMode = 'Full'
            })
        }

        $results = @(Test-MigrationConfiguration -Configuration $configuration)

        @($results | Where-Object { $_.Role -in @('Source', 'Target') -and $_.Status -eq 'Passed' }).Count | Should -Be 2
        @($results | Where-Object { $_.Role -eq 'BackupPath' -and $_.Status -eq 'Passed' }).Count | Should -Be 1
        $script:validatedSqlInstances | Should -Contain '192.168.1.20\SQL2019'
        $script:validatedSqlInstances | Should -Contain 'SQLTARGET\SQL2022'
        Should -Invoke Connect-DbaInstance -ModuleName DbMigration.Discovery -Times 2 -Exactly
        Should -Invoke Test-DbaPath -ModuleName DbMigration.Discovery -Times 2 -Exactly -ParameterFilter {
            $Path -eq '\\NAS01\SqlBackup'
        }
    }
}

Describe 'Migration readiness assessment' {
    BeforeAll {
        Import-Module dbatools -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Discovery.psm1') -Force
    }

    BeforeEach {
        $script:readinessSourceMajor = 16
        $script:readinessTargetMajor = 17
        $script:readinessConnectionIndex = 0
        $script:readinessLegacyModules = $false
        Mock Connect-DbaInstance -ModuleName DbMigration.Discovery {
            $script:readinessConnectionIndex++
            if ($script:readinessConnectionIndex -eq 1) {
                [pscustomobject]@{ SqlInstance = 'source-sql'; VersionMajor = $script:readinessSourceMajor }
            }
            else {
                [pscustomobject]@{ SqlInstance = 'target-sql'; VersionMajor = $script:readinessTargetMajor }
            }
        }
        Mock Invoke-DbaQuery -ModuleName DbMigration.Discovery {
            if ($Query -match 'SELECT name, state_desc AS State') { return @() }
            if ($SqlInstance -eq 'target-sql') {
                return [pscustomobject]@{ IsFullTextInstalled = $true; FilestreamConfiguredLevel = 2 }
            }
            if ($Query -match 'FROM sys\.databases') {
                return [pscustomobject]@{
                    DatabaseName = 'application'
                    State = 'ONLINE'
                    CompatibilityLevel = 160
                    RecoveryModel = 'FULL'
                    IsEncrypted = $false
                    IsCdcEnabled = $false
                    IsPublished = $false
                    IsSubscribed = $false
                    IsBrokerEnabled = $false
                    IsTrustworthyOn = $false
                    IsDbChainingOn = $false
                }
            }
            if ($Query -match 'sys\.fulltext_catalogs') {
                return [pscustomobject]@{
                    FullTextCatalogCount = 0
                    MemoryOptimizedTableCount = 0
                    FileStreamFileCount = 0
                    FileTableCount = 0
                }
            }
            if ($Query -match 'sys\.sql_modules') {
                if ($script:readinessLegacyModules) {
                    return [pscustomobject]@{ ModuleName = '[dbo].[LegacyProc]'; PatternName = 'Deprecated sp_dboption procedure' }
                }
                return @()
            }
            throw "Unexpected assessment query: $Query"
        }
        Mock Test-MigrationRestoreCapacity -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ Status = 'Passed'; Message = 'Target has sufficient restore capacity.' }
        }
    }

    It 'assesses a selected database without changes and returns structured findings' {
        $results = @(Get-MigrationReadinessAssessment -Source 'source-sql' -Target 'target-sql' -Databases @('application'))

        $results | Should -HaveCount 1
        $results[0].Readiness | Should -Be 'No blockers detected'
        $results[0].SourceVersionMajor | Should -Be 16
        $results[0].TargetVersionMajor | Should -Be 17
        @($results[0].Findings | Where-Object { $_.Check -eq 'Database compatibility level' -and $_.Status -eq 'Passed' }).Count | Should -Be 1
        @($results[0].Findings | Where-Object { $_.Check -eq 'Target restore capacity' -and $_.Status -eq 'Passed' }).Count | Should -Be 1
        Should -Invoke Test-MigrationRestoreCapacity -ModuleName DbMigration.Discovery -Times 1 -Exactly
    }

    It 'reports target downgrade as a blocker and stored-module text matches as candidates' {
        $script:readinessTargetMajor = 15
        $script:readinessLegacyModules = $true

        $results = @(Get-MigrationReadinessAssessment -Source 'source-sql' -Target 'target-sql' -Databases @('application'))

        $results[0].Readiness | Should -Be 'Blocked'
        @($results[0].Findings | Where-Object { $_.Check -eq 'Target is older than source' -and $_.Severity -eq 'Critical' }).Count | Should -Be 1
        @($results[0].Findings | Where-Object { $_.Check -eq 'Deprecated sp_dboption procedure' -and $_.Status -eq 'Candidate reference' }).Count | Should -Be 1
    }

    It 'does not run the data restore capacity check for schema-only readiness' {
        Mock Test-MigrationTdeReadiness -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ Status = 'Passed'; Message = 'Schema-only assessment does not require TDE key transfer.' }
        }

        $null = Get-MigrationReadinessAssessment -Source 'source-sql' -Target 'target-sql' `
            -Databases @('application') -MigrationMode SchemaOnly

        Should -Invoke Test-MigrationRestoreCapacity -ModuleName DbMigration.Discovery -Times 0 -Exactly
    }
}

Describe 'Database filtering' {
    It 'excludes system databases and configured exclusions' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @(
                [pscustomobject]@{ Name = 'master'; IsSystemObject = $true }
                [pscustomobject]@{ Name = 'tempdb'; IsSystemObject = $true }
                [pscustomobject]@{ Name = 'keep'; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'exclude-me'; IsSystemObject = $false }
            )
        }
        $config = @{ ExcludeDatabases = @('exclude-me') }

        $databases = @(Get-MigrationDatabase -SqlInstance source -Configuration $config)

        $databases.Name | Should -Be @('keep')
    }

    It 'returns only explicitly selected databases when an include list is configured' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @(
                [pscustomobject]@{ Name = 'keep'; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'also-keep'; IsSystemObject = $false }
            )
        }
        $config = @{ ExcludeDatabases = @(); IncludeDatabases = @('also-keep') }

        $databases = @(Get-MigrationDatabase -SqlInstance source -Configuration $config)

        $databases.Name | Should -Be @('also-keep')
    }

    It 'checks whether a database exists on the specified SQL instance' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @(
                [pscustomobject]@{ Name = 'present'; Status = 'Normal'; IsAccessible = $true; IsSystemObject = $false }
                [pscustomobject]@{ Name = 'other'; Status = 'Normal'; IsAccessible = $true; IsSystemObject = $false }
            )
        }

        Test-MigrationDatabaseExists -SqlInstance target -Database present | Should -BeTrue
        Test-MigrationDatabaseExists -SqlInstance target -Database missing | Should -BeFalse
    }

    It 'does not treat an inaccessible target database as missing' {
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @([pscustomobject]@{ Name = 'present'; Status = 'Offline'; IsAccessible = $false })
        }

        { Test-MigrationDatabaseExists -SqlInstance target -Database present } | Should -Throw '*not online and accessible*'
    }
}

Describe 'Database discovery details' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Discovery.psm1') -Force
        Mock Get-DbaDatabase -ModuleName DbMigration.Core {
            @([pscustomobject]@{
                Name = 'appdb'
                IsSystemObject = $false
                Status = 'Normal'
                IsAccessible = $true
                SizeMB = 2048
                Compatibility = 'Version150'
                RecoveryModel = 'Full'
            })
        }
        Mock Connect-DbaInstance -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ ComputerName = if ($SqlInstance -eq 'source') { 'source-host' } else { 'target-host' } }
        }
        Mock Get-DbaDiskSpace -ModuleName DbMigration.Discovery {
            @(
                [pscustomobject]@{ Name = 'D:\'; SizeInGB = 500; FreeInGB = 100; PercentFree = 20 }
                [pscustomobject]@{ Name = 'L:\'; SizeInGB = 300; FreeInGB = 50; PercentFree = 16.67 }
            )
        }
        Mock Get-DbaDefaultPath -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ Data = 'D:\Data'; Log = 'L:\Logs' }
        }
        Mock Get-DbaLogin -ModuleName DbMigration.Discovery {
            @([pscustomobject]@{ Name = 'login1' }, [pscustomobject]@{ Name = 'login2' })
        }
        Mock Get-DbaLinkedServer -ModuleName DbMigration.Discovery {
            @([pscustomobject]@{ Name = 'linked1' })
        }
        Mock Get-DbaAgentJob -ModuleName DbMigration.Discovery {
            @([pscustomobject]@{ Name = 'job1' }, [pscustomobject]@{ Name = 'job2' }, [pscustomobject]@{ Name = 'job3' })
        }
        Mock Get-DbaDbFile -ModuleName DbMigration.Discovery {
            @(
                [pscustomobject]@{ TypeDescription = 'ROWS'; LogicalName = 'appdb'; PhysicalName = 'D:\Data\appdb.mdf'; Size = [pscustomobject]@{ Byte = 2GB } }
                [pscustomobject]@{ TypeDescription = 'LOG'; LogicalName = 'appdb_log'; PhysicalName = 'L:\Logs\appdb.ldf'; Size = [pscustomobject]@{ Byte = 1GB } }
            )
        }
        Mock Invoke-DbaQuery -ModuleName DbMigration.Discovery {
            [pscustomobject]@{
                IsEncrypted = $false
                EncryptionState = $null
                EncryptorThumbprint = $null
            }
        }
    }

    It 'reports database size, file locations, compatibility, and source and target volume space' {
        $configuration = @{
            SourceTargets = @(@{ Source = 'source'; Target = 'target' })
            ExcludeDatabases = @()
        }

        $result = @(Get-MigrationDiscovery -Configuration $configuration)[0]

        $result.Database | Should -Be 'appdb'
        $result.SizeMB | Should -Be 2048
        $result.SizeGB | Should -Be 2
        $result.SourceLoginCount | Should -Be 2
        $result.SourceLinkedServerCount | Should -Be 1
        $result.SourceAgentJobCount | Should -Be 3
        $result.CompatibilityLevel | Should -Be 'Version150'
        $result.CompatibilityLevelNumber | Should -Be 150
        $result.DataFileLocations | Should -Match 'D:\\Data\\appdb\.mdf'
        $result.LogFileLocations | Should -Match 'L:\\Logs\\appdb\.ldf'
        $result.SourceVolumeSpace | Should -Match '500 GB total, 100 GB free'
        $result.TargetDataFreeGB | Should -Be 100
        $result.TargetLogFreeGB | Should -Be 50
        $result.TdeEncrypted | Should -BeFalse
        $result.TdePreflight | Should -Be 'Passed'
        $result.TdeTargetEncryptorReady | Should -BeTrue
    }

    It 'fails capacity preflight when the target volumes cannot fit the database files with buffer' {
        Mock Get-DbaDbFile -ModuleName DbMigration.Discovery {
            @(
                [pscustomobject]@{ TypeDescription = 'ROWS'; Size = [pscustomobject]@{ Byte = 200GB } }
                [pscustomobject]@{ TypeDescription = 'LOG'; Size = [pscustomobject]@{ Byte = 60GB } }
            )
        }

        $result = Test-MigrationRestoreCapacity -Source source -Target target -Database large -BufferPercent 20

        $result.Status | Should -Be 'Failed'
        $result.DataRequiredWithBufferGB | Should -Be 240
        $result.LogRequiredWithBufferGB | Should -Be 72
    }
}

Describe 'TDE migration preflight' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Discovery.psm1') -Force
    }

    It 'passes unencrypted databases without checking the target for a key' {
        Mock Invoke-DbaQuery -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ IsEncrypted = $false; EncryptionState = $null; EncryptorThumbprint = $null }
        }

        $result = Test-MigrationTdeReadiness -Source source -Target target -Database appdb

        $result.Status | Should -Be 'Passed'
        $result.TdeEncrypted | Should -BeFalse
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.Discovery -Exactly 1
    }

    It 'fails closed when source TDE status cannot be verified' {
        Mock Invoke-DbaQuery -ModuleName DbMigration.Discovery {
            throw 'VIEW SERVER STATE permission denied'
        }

        $result = Test-MigrationTdeReadiness -Source source -Target target -Database appdb

        $result.Status | Should -Be 'Failed'
        $result.TdeEncrypted | Should -BeNull
        $result.Message | Should -Match 'VIEW SERVER STATE permission denied'
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.Discovery -Exactly 1
    }

    It 'blocks an encrypted full migration when the target does not have the matching key' {
        Mock Invoke-DbaQuery -ModuleName DbMigration.Discovery {
            if ($Query -match 'dm_database_encryption_keys') {
                [pscustomobject]@{ IsEncrypted = $true; EncryptionState = 3; EncryptorThumbprint = '0xA1B2C3' }
            }
            else {
                [pscustomobject]@{ MatchingPrivateKeyCount = 0 }
            }
        }

        $result = Test-MigrationTdeReadiness -Source source -Target target -Database appdb

        $result.Status | Should -Be 'Failed'
        $result.TdeEncrypted | Should -BeTrue
        $result.TargetEncryptorReady | Should -BeFalse
        $result.Message | Should -Match 'Install and verify the TDE encryptor'
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.Discovery -Exactly 2
    }

    It 'passes an encrypted full migration when the matching key is available on the target' {
        Mock Invoke-DbaQuery -ModuleName DbMigration.Discovery {
            if ($Query -match 'dm_database_encryption_keys') {
                [pscustomobject]@{ IsEncrypted = $true; EncryptionState = 3; EncryptorThumbprint = '0xA1B2C3' }
            }
            else {
                [pscustomobject]@{ MatchingPrivateKeyCount = 1 }
            }
        }

        $result = Test-MigrationTdeReadiness -Source source -Target target -Database appdb

        $result.Status | Should -Be 'Passed'
        $result.TargetEncryptorReady | Should -BeTrue
        $result.Message | Should -Match 'matching private-key'
    }

    It 'reports encrypted schema-only databases without requiring the target key' {
        Mock Invoke-DbaQuery -ModuleName DbMigration.Discovery {
            [pscustomobject]@{ IsEncrypted = $true; EncryptionState = 3; EncryptorThumbprint = '0xA1B2C3' }
        }

        $result = Test-MigrationTdeReadiness -Source source -Target target -Database appdb -MigrationMode SchemaOnly

        $result.Status | Should -Be 'Passed'
        $result.TdeEncrypted | Should -BeTrue
        $result.TargetEncryptorReady | Should -BeNull
        $result.Message | Should -Match 'schema-only migration does not restore'
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.Discovery -Exactly 1
    }
}

Describe 'Database backup stripes' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.Transfer.psm1') -Force
    }

    It 'exports the tracked operation helper and supports the built-in job in a parallel runspace' {
        $moduleDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\src')).Path

        $result = 'probe' | ForEach-Object -Parallel {
            Import-Module (Join-Path $using:moduleDirectory 'DbMigration.Core.psm1') -Force
            Import-Module (Join-Path $using:moduleDirectory 'DbMigration.Transfer.psm1') -Force
            $helper = (Get-Command Invoke-MigrationTrackedDatabaseOperation -ErrorAction Stop).Name
            $job = Start-Job -ScriptBlock { 'background-job-ok' }
            Wait-Job -Job $job -Timeout 10 | Out-Null
            $jobResult = Receive-Job -Job $job -ErrorAction Stop
            Remove-Job -Job $job -Force -ErrorAction Stop
            "$helper|$jobResult"
        } -ThrottleLimit 1

        $result | Should -Be 'Invoke-MigrationTrackedDatabaseOperation|background-job-ok'
    }

    It 'imports the transfer module into the restore background job before invoking its helper' {
        $workerModulePath = Join-Path $TestDrive 'DbMigration.Transfer.WorkerTest.psm1'
        @'
function Invoke-MigrationSafeRestore {
    param(
        [string]$SqlInstance,
        [string[]]$Path,
        [string]$DatabaseName,
        [string]$DestinationDataDirectory,
        [string]$DestinationLogDirectory,
        [bool]$AllowFileCollisionRetry
    )
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'worker-called.txt') -Value $DatabaseName
    [pscustomobject]@{ FileCollisionRetry = $true; DestinationFilePrefix = 'mig_test_' }
}
Export-ModuleMember -Function Invoke-MigrationSafeRestore
'@ | Set-Content -LiteralPath $workerModulePath

        $operationOutput = @(Invoke-MigrationTrackedDatabaseOperation -Operation Restore -SqlInstance target `
            -Source source -Target target -Database appdb -ProgressPath '' `
            -BackupFiles @('C:\backup\appdb.bak') -DestinationDataDirectory 'D:\Data' `
            -DestinationLogDirectory 'D:\Log' -TransferModulePath $workerModulePath)

        (Get-Content -LiteralPath (Join-Path $TestDrive 'worker-called.txt') -Raw).Trim() |
            Should -Be 'appdb'
        $operationOutput.Count | Should -Be 0
    }

    It 'returns exactly the requested database stripe files in stripe order' {
        $directory = Join-Path $TestDrive 'isolated-stripes'
        $null = New-Item -ItemType Directory -Path $directory
        foreach ($stripe in @(4, 2, 1, 3)) {
            Set-Content -LiteralPath (Join-Path $directory "appdb_202610061200-$stripe-of-4.bak") -Value 'stripe'
        }

        $files = @(Get-MigrationBackupStripeFiles -Directory $directory -Database appdb -FileCount 4)

        $files.Count | Should -Be 4
        @($files | ForEach-Object Name) | Should -Be @(
            'appdb_202610061200-1-of-4.bak',
            'appdb_202610061200-2-of-4.bak',
            'appdb_202610061200-3-of-4.bak',
            'appdb_202610061200-4-of-4.bak'
        )
    }

    It 'rejects shared folders containing another database backup' {
        $directory = Join-Path $TestDrive 'mixed-stripes'
        $null = New-Item -ItemType Directory -Path $directory
        foreach ($database in @('appdb', 'otherdb')) {
            for ($stripe = 1; $stripe -le 4; $stripe++) {
                Set-Content -LiteralPath (Join-Path $directory "${database}_202610061200-$stripe-of-4.bak") -Value 'stripe'
            }
        }

        @(Get-MigrationBackupStripeFiles -Directory $directory -Database appdb -FileCount 4).Count |
            Should -Be 0
    }
}

Describe 'Server object migration' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.PostMigration.psm1') -Force
    }

    It 'copies logins without sa, agent jobs, and operators' {
        Mock Copy-DbaLogin -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentJob -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration

        Invoke-ServerObjectMigration -Pair @{ Source = 'source'; Target = 'target' }

        Should -Invoke Copy-DbaLogin -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $ExcludeLogin -contains 'sa' -and $Source.FullName -eq 'source' -and $Destination.FullName -contains 'target'
        }
        Should -Invoke Copy-DbaAgentJob -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $DisableOnDestination -and $Source.FullName -eq 'source' -and $Destination.FullName -contains 'target'
        }
        Should -Invoke Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration -Exactly 1
    }

    It 'copies only the selected server object types' {
        Mock Copy-DbaLogin -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentJob -ModuleName DbMigration.PostMigration
        Mock Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration

        Invoke-ServerObjectMigration -Pair @{ Source = 'source'; Target = 'target' } -MigrateLogins $false -MigrateAgentJobs $true -MigrateAgentOperators $false

        Should -Invoke Copy-DbaLogin -ModuleName DbMigration.PostMigration -Exactly 0
        Should -Invoke Copy-DbaAgentJob -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $DisableOnDestination
        }
        Should -Invoke Copy-DbaAgentOperator -ModuleName DbMigration.PostMigration -Exactly 0
    }
}

Describe 'Linked server configuration' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.PostMigration.psm1') -Force
    }

    It 'maps CSV metadata to dbatools linked-server parameters' {
        $path = Join-Path $TestDrive 'linked.csv'
        'LinkedServer,Provider,Product,DataSource,Catalog,SecurityMode,RemoteUser,PasswordEnvironmentVariable' |
            Set-Content -LiteralPath $path
        'warehouse,MSOLEDBSQL,SQL Server,warehouse.example.com,Analytics,CurrentSecurityContext,,' |
            Add-Content -LiteralPath $path
        Mock New-DbaLinkedServer -ModuleName DbMigration.PostMigration
        Mock Get-DbaLinkedServer -ModuleName DbMigration.PostMigration { @() }

        Invoke-LinkedServerConfiguration -Pair @{ Target = 'target' } -CsvPath $path

        Should -Invoke New-DbaLinkedServer -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $SqlInstance.FullName -contains 'target' -and $LinkedServer -eq 'warehouse' -and
            $ServerProduct -eq 'SQL Server' -and $SecurityContext -eq 'CurrentSecurityContext'
        }
    }

    It 'passes a SQL-authenticated linked-server password from its environment variable' {
        $path = Join-Path $TestDrive 'linked-sql-auth.csv'
        $environmentName = "DBMIGRATION_TEST_LINKEDSERVER_$([guid]::NewGuid().ToString('N'))"
        [Environment]::SetEnvironmentVariable($environmentName, 'test-password')
        try {
            [pscustomobject]@{
                LinkedServer = 'warehouse'
                Provider = 'MSOLEDBSQL'
                Product = 'SQL Server'
                DataSource = 'warehouse.example.com'
                Catalog = 'Analytics'
                SecurityMode = 'SpecifiedSecurityContext'
                RemoteUser = 'migration_reader'
                PasswordEnvironmentVariable = $environmentName
            } | Export-Csv -LiteralPath $path -NoTypeInformation
            Mock New-DbaLinkedServer -ModuleName DbMigration.PostMigration
            Mock Get-DbaLinkedServer -ModuleName DbMigration.PostMigration { @() }

            Invoke-LinkedServerConfiguration -Pair @{ Target = 'target' } -CsvPath $path

            Should -Invoke New-DbaLinkedServer -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
                $SecurityContext -eq 'SpecifiedSecurityContext' -and
                $SecurityContextRemoteUser -eq 'migration_reader' -and
                $SecurityContextRemoteUserPassword -is [System.Security.SecureString]
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable($environmentName, $null)
        }
    }

    It 'does not overwrite a same-name linked server already present on the target' {
        $path = Join-Path $TestDrive 'linked-existing.csv'
        'LinkedServer,Provider,Product,DataSource,Catalog,SecurityMode,RemoteUser,PasswordEnvironmentVariable' |
            Set-Content -LiteralPath $path
        'warehouse,MSOLEDBSQL,SQL Server,warehouse-new.example.com,Analytics,CurrentSecurityContext,,' |
            Add-Content -LiteralPath $path
        Mock New-DbaLinkedServer -ModuleName DbMigration.PostMigration
        Mock Get-DbaLinkedServer -ModuleName DbMigration.PostMigration { @([pscustomobject]@{ Name = 'warehouse' }) }

        Invoke-LinkedServerConfiguration -Pair @{ Target = 'target' } -CsvPath $path

        Should -Invoke New-DbaLinkedServer -ModuleName DbMigration.PostMigration -Exactly 0
    }
}

Describe 'Post-migration repair and statistics' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\DbMigration.PostMigration.psm1') -Force
    }

    It 'repairs orphan users and updates database statistics' {
        Mock Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration
        Mock Invoke-DbaQuery -ModuleName DbMigration.PostMigration

        Invoke-DatabasePostMigration -SqlInstance target -Database appdb -UpdateStatistics $true

        Should -Invoke Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration -Exactly 1
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.PostMigration -Exactly 1 -ParameterFilter {
            $Database -eq 'appdb' -and $Query -eq 'EXEC sys.sp_updatestats;'
        }
    }

    It 'can skip statistics updates while still repairing orphan users' {
        Mock Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration
        Mock Invoke-DbaQuery -ModuleName DbMigration.PostMigration

        Invoke-DatabasePostMigration -SqlInstance target -Database appdb -UpdateStatistics $false

        Should -Invoke Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration -Exactly 1
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.PostMigration -Exactly 0
    }

    It 'can skip orphan-user repair and statistics updates' {
        Mock Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration
        Mock Invoke-DbaQuery -ModuleName DbMigration.PostMigration

        Invoke-DatabasePostMigration -SqlInstance target -Database appdb -UpdateStatistics $false -RepairOrphanUsers $false

        Should -Invoke Repair-DbaDbOrphanUser -ModuleName DbMigration.PostMigration -Exactly 0
        Should -Invoke Invoke-DbaQuery -ModuleName DbMigration.PostMigration -Exactly 0
    }
}
