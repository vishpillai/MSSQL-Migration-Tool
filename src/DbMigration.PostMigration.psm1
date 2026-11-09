Set-StrictMode -Version Latest

function Get-MigrationDatabaseAlignedLogin {
    <#
    .SYNOPSIS
        Finds logins whose database footprint is limited to databases that will not
        exist on the migration target. A login qualifies when every database in which
        it owns a user is excluded, or when it owns no users anywhere and its default
        database is excluded. Logins holding fixed server-role membership and the
        current connection identity are never reported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SqlInstance,

        [Parameter(Mandatory)]
        [string[]] $ExcludedDatabases
    )

    $excludedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($databaseName in $ExcludedDatabases) {
        if (-not [string]::IsNullOrWhiteSpace($databaseName)) { $null = $excludedSet.Add($databaseName) }
    }
    if ($excludedSet.Count -eq 0) { return }

    $server = Connect-DbaInstance -SqlInstance $SqlInstance -ErrorAction Stop
    $trueLogin = [string]$server.ConnectionContext.TrueLogin
    $roleMembers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($member in @(Get-DbaServerRoleMember -SqlInstance $SqlInstance -EnableException -ErrorAction Stop)) {
        $null = $roleMembers.Add([string]$member.Name)
    }
    $databasesByLoginSid = @{}
    foreach ($user in @(Get-DbaDbUser -SqlInstance $SqlInstance -ExcludeSystemUser -EnableException -ErrorAction Stop)) {
        if (-not $user.Sid) { continue }
        $sidKey = [Convert]::ToHexString([byte[]]$user.Sid)
        if (-not $databasesByLoginSid.ContainsKey($sidKey)) {
            $databasesByLoginSid[$sidKey] = [System.Collections.Generic.List[string]]::new()
        }
        $databasesByLoginSid[$sidKey].Add([string]$user.Database)
    }

    $logins = @(Get-DbaLogin -SqlInstance $SqlInstance -EnableException -ErrorAction Stop |
        Where-Object { $_.LoginType -in @('SqlLogin', 'WindowsUser', 'WindowsGroup') })
    foreach ($login in $logins) {
        $loginName = [string]$login.Name
        if ($loginName -like '##*' -or $loginName -like 'NT *' -or
            [string]::Equals($loginName, $trueLogin, [StringComparison]::OrdinalIgnoreCase) -or
            $roleMembers.Contains($loginName)) {
            continue
        }
        $sidKey = if ($login.Sid) { [Convert]::ToHexString([byte[]]$login.Sid) } else { '' }
        $mappedDatabases = @()
        if ($sidKey -and $databasesByLoginSid.ContainsKey($sidKey)) {
            $mappedDatabases = @($databasesByLoginSid[$sidKey] | Select-Object -Unique)
        }
        $defaultDatabase = [string]$login.DefaultDatabase
        $alignedDatabases = $null
        if ($mappedDatabases.Count -gt 0 -and
            @($mappedDatabases | Where-Object { -not $excludedSet.Contains($_) }).Count -eq 0) {
            $alignedDatabases = $mappedDatabases
        }
        elseif ($mappedDatabases.Count -eq 0 -and $defaultDatabase -and $excludedSet.Contains($defaultDatabase)) {
            $alignedDatabases = @($defaultDatabase)
        }
        if ($alignedDatabases) {
            [pscustomobject]@{
                Name = $loginName
                LoginType = [string]$login.LoginType
                AlignedDatabases = @($alignedDatabases)
            }
        }
    }
}

function Invoke-ServerObjectMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Pair,

        [Parameter()]
        [bool] $MigrateLogins = $true,

        [Parameter()]
        [bool] $MigrateAgentJobs = $true,

        [Parameter()]
        [bool] $MigrateAgentOperators = $true,

        [Parameter()]
        [string[]] $ExcludedDatabases = @()
    )

    # Each phase is isolated: a hard failure is emitted as a phase result object and
    # the remaining phases still run, so one bad login or job cannot block the rest.
    if ($MigrateLogins) {
        try {
            $excludedLogins = [System.Collections.Generic.List[string]]::new()
            $excludedLogins.Add('sa')
            if (@($ExcludedDatabases).Count -gt 0) {
                $alignedLogins = @(Get-MigrationDatabaseAlignedLogin -SqlInstance ([string]$Pair.Source) `
                    -ExcludedDatabases $ExcludedDatabases -ErrorAction Stop)
                foreach ($alignedLogin in $alignedLogins) {
                    $excludedLogins.Add([string]$alignedLogin.Name)
                    [pscustomobject]@{
                        SourceServer = [string]$Pair.Source
                        DestinationServer = [string]$Pair.Target
                        Name = [string]$alignedLogin.Name
                        Type = "Login - $($alignedLogin.LoginType)"
                        Status = 'Skipped'
                        Notes = "Aligned to database(s) not migrated to the target ($($alignedLogin.AlignedDatabases -join ', ')); not copied."
                        DateTime = Get-Date
                    }
                }
            }
            # Only well-formed result objects may stream on: dbatools internals occasionally leak
            # SMO/data objects whose console serialization downstream throws PropertyNotFoundException.
            Copy-DbaLogin -Source $Pair.Source -Destination $Pair.Target -ExcludeLogin $excludedLogins.ToArray() -Force -EnableException |
                ForEach-Object {
                    if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Status') { $_ }
                }
        }
        catch {
            [pscustomobject]@{
                SourceServer = [string]$Pair.Source
                DestinationServer = [string]$Pair.Target
                Name = '*'
                Type = 'Login phase'
                Status = 'Failed'
                Notes = "Login migration phase failed: $($_.Exception.Message)"
                IsPhaseFailure = $true
                DateTime = Get-Date
            }
        }
    }
    if ($MigrateAgentJobs) {
        try {
            Copy-DbaAgentJob -Source $Pair.Source -Destination $Pair.Target -DisableOnDestination -Force -EnableException |
                ForEach-Object {
                    if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Status') { $_ }
                }
        }
        catch {
            [pscustomobject]@{
                SourceServer = [string]$Pair.Source
                DestinationServer = [string]$Pair.Target
                Name = '*'
                Type = 'Agent job phase'
                Status = 'Failed'
                Notes = "Agent job migration phase failed: $($_.Exception.Message)"
                IsPhaseFailure = $true
                DateTime = Get-Date
            }
        }
    }
    if ($MigrateAgentOperators) {
        try {
            Copy-DbaAgentOperator -Source $Pair.Source -Destination $Pair.Target -Force -EnableException |
                ForEach-Object {
                    if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Status') { $_ }
                }
        }
        catch {
            [pscustomobject]@{
                SourceServer = [string]$Pair.Source
                DestinationServer = [string]$Pair.Target
                Name = '*'
                Type = 'Agent operator phase'
                Status = 'Failed'
                Notes = "Agent operator migration phase failed: $($_.Exception.Message)"
                IsPhaseFailure = $true
                DateTime = Get-Date
            }
        }
    }
}

function Invoke-LinkedServerConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pair,
        [Parameter(Mandatory)][string] $CsvPath
    )

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Linked server configuration CSV not found: $CsvPath"
    }
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    foreach ($requiredColumn in @('LinkedServer', 'Provider', 'Product', 'DataSource', 'SecurityMode')) {
        if ($rows.Count -gt 0 -and $requiredColumn -notin $rows[0].PSObject.Properties.Name) {
            throw "Linked server CSV is missing required column '$requiredColumn'."
        }
    }

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row.LinkedServer) -or [string]::IsNullOrWhiteSpace($row.Provider) -or
            [string]::IsNullOrWhiteSpace($row.Product) -or [string]::IsNullOrWhiteSpace($row.DataSource)) {
            throw 'Each linked server CSV row must provide LinkedServer, Provider, Product, and DataSource values.'
        }
        $parameters = @{
            SqlInstance = $Pair.Target
            LinkedServer = $row.LinkedServer
            Provider = $row.Provider
            ServerProduct = $row.Product
            DataSource = $row.DataSource
            SecurityContext = $row.SecurityMode
            EnableException = $true
        }
        if ($row.SecurityMode -notin @('NoConnection', 'WithoutSecurityContext', 'CurrentSecurityContext', 'SpecifiedSecurityContext')) {
            throw "Linked server '$($row.LinkedServer)' has an unsupported SecurityMode '$($row.SecurityMode)'."
        }
        if ($row.PSObject.Properties.Name -contains 'Catalog' -and $row.Catalog) {
            $parameters.Catalog = $row.Catalog
        }
        if ($row.PSObject.Properties.Name -contains 'RemoteUser' -and $row.RemoteUser) {
            if (-not ($row.PSObject.Properties.Name -contains 'PasswordEnvironmentVariable') -or -not $row.PasswordEnvironmentVariable) {
                throw "Linked server '$($row.LinkedServer)' specifies RemoteUser but no PasswordEnvironmentVariable."
            }
            $password = [Environment]::GetEnvironmentVariable($row.PasswordEnvironmentVariable)
            if ([string]::IsNullOrEmpty($password)) {
                throw "Environment variable '$($row.PasswordEnvironmentVariable)' is not set for linked server '$($row.LinkedServer)'."
            }
            if ($row.SecurityMode -ne 'SpecifiedSecurityContext') {
                throw "Linked server '$($row.LinkedServer)' must use SecurityMode 'SpecifiedSecurityContext' when RemoteUser is set."
            }
            $parameters.SecurityContextRemoteUser = $row.RemoteUser
            $parameters.SecurityContextRemoteUserPassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        }
        elseif ($row.SecurityMode -eq 'SpecifiedSecurityContext') {
            throw "Linked server '$($row.LinkedServer)' requires RemoteUser and PasswordEnvironmentVariable for SpecifiedSecurityContext."
        }
        $existingLinkedServer = @(Get-DbaLinkedServer -SqlInstance $Pair.Target -LinkedServer $row.LinkedServer -EnableException)
        if ($existingLinkedServer.Count -gt 0) {
            Write-Verbose "Linked server '$($row.LinkedServer)' already exists on '$($Pair.Target)'; leaving it unchanged."
            continue
        }
        New-DbaLinkedServer @parameters
    }
}

function Invoke-DatabasePostMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SqlInstance,
        [Parameter(Mandatory)][string] $Database,
        [Parameter()][bool] $UpdateStatistics = $true,
        [Parameter()][bool] $RepairOrphanUsers = $true
    )

    if ($RepairOrphanUsers) {
        Repair-DbaDbOrphanUser -SqlInstance $SqlInstance -Database $Database -EnableException
    }
    if ($UpdateStatistics) {
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database $Database -Query 'EXEC sys.sp_updatestats;' -EnableException
    }
}

function Install-OlaHallengrenMaintenanceSolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SqlInstance
    )

    Install-DbaMaintenanceSolution -SqlInstance $SqlInstance -Database master `
        -Confirm:$false -EnableException -ErrorAction Stop
}

Export-ModuleMember -Function Invoke-ServerObjectMigration, Invoke-LinkedServerConfiguration, Invoke-DatabasePostMigration, Install-OlaHallengrenMaintenanceSolution
