[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$')][string] $HostName,
    [Parameter()][ValidateRange(1, 65535)][int] $Port = 8443,
    [Parameter()][string] $ConfigPath = (Join-Path $PSScriptRoot 'config\migration.config.json'),
    [Parameter()][string] $StatePath = (Join-Path $PSScriptRoot 'MigrationState.json'),
    [Parameter()][switch] $PortableMode,
    [Parameter()][ValidateSet('Application', 'Windows')][string] $AuthenticationMode = 'Application',
    [Parameter()][string] $WindowsAuthGroup,
    [Parameter()][string] $AppRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.2') {
    throw 'PowerShell 7.2 or later is required.'
}
if ($AuthenticationMode -eq 'Windows') {
    if ($PortableMode) {
        throw 'Windows Integrated Authentication requires HTTPS server mode; it is not supported in portable HTTP mode.'
    }
    if ([string]::IsNullOrWhiteSpace($WindowsAuthGroup)) {
        throw "Windows authentication requires -WindowsAuthGroup 'DOMAIN\GroupName'."
    }
}
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.WebAuth.psm1') -Force
$storage = Resolve-MigrationWebStoragePaths -AppRoot $AppRoot -PortableMode:$PortableMode
$fullConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$fullAuthPath = $storage.AuthPath
$fullStatePath = [System.IO.Path]::GetFullPath($StatePath)
$requiredPaths = @($fullConfigPath)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Patching.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Reporting.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.WebAuth.psm1') -Force
Import-Module dbatools -ErrorAction Stop
$script:WebConfiguration = Import-MigrationConfiguration -Path $fullConfigPath
$script:AuthenticationMode = $AuthenticationMode
$script:WindowsAuthGroup = $WindowsAuthGroup
$script:AuthRecord = $null
$script:SetupToken = $null
if ($script:AuthenticationMode -eq 'Application') {
    if (Test-Path -LiteralPath $fullAuthPath -PathType Leaf) {
        $script:AuthRecord = Get-Content -LiteralPath $fullAuthPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        foreach ($property in @('Salt', 'PasswordHash', 'Iterations', 'Username')) {
            if (-not $script:AuthRecord.Contains($property)) {
                throw "Authentication record is missing '$property'. Re-run Initialize-DbMigrationWebAuth.ps1."
            }
        }
    }
    else {
        $setupBytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($setupBytes)
        $script:SetupToken = [Convert]::ToBase64String($setupBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        [Array]::Clear($setupBytes, 0, $setupBytes.Length)
    }
}

if (-not ('DbMigration.Web.ProcessOutputLine' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;

namespace DbMigration.Web
{
    public sealed class ProcessOutputLine
    {
        public string Status { get; }
        public string Message { get; }

        public ProcessOutputLine(string status, string message)
        {
            Status = status;
            Message = message;
        }
    }

    public sealed class ProcessOutputHandler
    {
        private readonly ConcurrentQueue<ProcessOutputLine> queue;
        private int droppedLines;

        public ProcessOutputHandler(ConcurrentQueue<ProcessOutputLine> queue)
        {
            this.queue = queue;
        }

        public void Attach(Process process)
        {
            process.OutputDataReceived += OnOutputDataReceived;
            process.ErrorDataReceived += OnErrorDataReceived;
        }

        private void OnOutputDataReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data != null)
                Enqueue(new ProcessOutputLine("InProgress", eventArgs.Data));
        }

        private void OnErrorDataReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data != null)
                Enqueue(new ProcessOutputLine("Failed", eventArgs.Data));
        }

        private void Enqueue(ProcessOutputLine line)
        {
            queue.Enqueue(line);
            while (queue.Count > 1000)
            {
                ProcessOutputLine discarded;
                if (!queue.TryDequeue(out discarded))
                    break;
                Interlocked.Increment(ref droppedLines);
            }
        }

        public int ConsumeDroppedLines()
        {
            return Interlocked.Exchange(ref droppedLines, 0);
        }
    }
}
'@
}

$script:HostName = $HostName.ToLowerInvariant()
$script:Port = $Port
$script:PortableMode = [bool]$PortableMode
$script:UseSecureTransport = -not $script:PortableMode
$script:Origin = if ($script:PortableMode) { "http://$($script:HostName):$Port" } elseif ($Port -eq 443) { "https://$($script:HostName)" } else { "https://$($script:HostName):$Port" }
$script:Listener = [System.Net.HttpListener]::new()
if ($script:AuthenticationMode -eq 'Windows') {
    $script:Listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Negotiate
}
$script:Listener.Prefixes.Add("$($script:Origin)/")
$script:Sessions = @{}
$script:LoginAttempts = @{}
$script:SetupAttempts = @{}
$script:AdminReauthAttempts = @{}
$script:DiscoveryByPair = @{}
$script:MigrationProcess = $null
$script:PatchProcess = $null
$script:PatchRunId = $null
$script:PatchAction = $null
$script:PatchKB = $null
$script:PatchTargets = @()
$script:PatchActor = ''
$script:PatchCompletionLoggedRunId = $null
$script:MigrationActor = ''
$script:MigrationCompletionLoggedRunId = $null
$script:CurrentProcessOperation = ''
$script:PatchCatalog = @()
$script:PatchCatalogUpdatedAt = $null
$script:RuntimeConfigPath = $null
$script:ProgressPath = $null
$script:ControlPath = $null
$script:EventBuffer = [System.Collections.Generic.List[object]]::new()
$script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
$script:ProcessOutputHandler = $null
$script:NextEventId = 1
$script:RunId = $null
$script:MigrationPairs = @()
$script:DatabaseJobCount = 0
$script:HostLogDirectory = if ($script:PortableMode) { $storage.LogDirectory } else { Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Logs' }
$script:HostLogPath = Join-Path $script:HostLogDirectory "WebHost-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').log"
$script:AuditLogPath = Join-Path $script:HostLogDirectory 'Audit.jsonl'
$script:AuditKeyPath = Join-Path $script:HostLogDirectory 'Audit.key'
$script:AuditHeadPath = Join-Path $script:HostLogDirectory 'Audit.jsonl.head'
$script:CurrentAuditRequestId = ''
$script:CurrentAuditClientAddress = ''
$script:AuditedWindowsPrincipals = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$null = New-Item -ItemType Directory -Path $script:HostLogDirectory -Force -ErrorAction Stop

function Write-WebHostLog {
    param(
        [Parameter(Mandatory)][string] $Level,
        [Parameter(Mandatory)][string] $Message
    )

    $line = '[{0}] [{1}] {2}{3}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Message, [Environment]::NewLine
    try {
        [System.IO.File]::AppendAllText($script:HostLogPath, $line, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        [Console]::Error.WriteLine("Could not write web-host log '$($script:HostLogPath)': $($_.Exception.Message)")
        [Console]::Error.WriteLine($line)
    }
    [Console]::WriteLine($line.TrimEnd())
}

function Write-WebAuditRecord {
    param(
        [Parameter(Mandatory)][string] $Action,
        [Parameter()][string] $Actor = '',
        [Parameter()][string] $RunId = '',
        [Parameter()][string] $Outcome = 'Completed',
        [Parameter()][System.Collections.IDictionary] $Details = @{}
    )

    $category = if ($Action -match 'sign in|sign out|login|authentication|denied|rejected') { 'Security' }
        elseif ($Action -match 'custom SQL') { 'Execution' }
        elseif ($Action -match 'migration|patch') { 'Change' }
        else { 'Operations' }
    $severity = if ($Outcome -match 'Partial|Warning') { 'Warning' }
        elseif ($Outcome -match 'Failed|Error|Denied|Rejected') { 'Error' }
        else { 'Information' }
    $resourceType = if ($Action -match 'migration') { 'Migration' }
        elseif ($Action -match 'patch') { 'SQLServerPatch' }
        elseif ($Action -match 'custom SQL') { 'SQLInstance' }
        elseif ($Details.Contains('SqlInstance') -or $Details.Contains('SqlInstances')) { 'SQLInstance' }
        elseif ($Action -match 'sign in|sign out') { 'Application' }
        else { 'ApplicationOperation' }
    $resourceName = if ($Details.Contains('SqlInstances')) { @($Details.SqlInstances) -join ', ' }
        elseif ($Details.Contains('SqlInstance')) { [string]$Details.SqlInstance }
        elseif ($Details.Contains('Targets')) { @($Details.Targets) -join ', ' }
        elseif ($Details.Contains('Source') -or $Details.Contains('Target')) { "$($Details.Source) -> $($Details.Target)" }
        else { '' }
    $null = Add-MigrationAuditRecord -Path $script:AuditLogPath -KeyPath $script:AuditKeyPath `
        -HeadPath $script:AuditHeadPath -Record @{
        Timestamp = [DateTime]::UtcNow.ToString('o')
        Actor = if ($Actor) { $Actor } else { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
        ActorType = if ($script:AuthenticationMode -eq 'Windows') { 'WindowsUser' } else { 'ApplicationUser' }
        Category = $category
        Severity = $severity
        Action = $Action
        Outcome = $Outcome
        ResourceType = $resourceType
        ResourceName = $resourceName
        RunId = $RunId
        ClientAddress = $script:CurrentAuditClientAddress
        RequestId = $script:CurrentAuditRequestId
        Details = $Details
    }
}

function Write-WebRunRecord {
    param(
        [Parameter(Mandatory)][ValidateSet('Migration', 'Patch')][string] $Operation,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RecordType,
        [Parameter()][System.Collections.IDictionary] $Record = @{}
    )

    Add-MigrationJsonLine -Path (Join-Path $script:HostLogDirectory "$Operation-$RunId.jsonl") -Record (
        @{
            Timestamp = [DateTime]::UtcNow.ToString('o')
            Operation = $Operation
            RunId = $RunId
            RecordType = $RecordType
        } + $Record
    )
}

function Get-WebMigrationControlAction {
    if (-not $script:ControlPath -or -not (Test-Path -LiteralPath $script:ControlPath -PathType Leaf)) {
        return 'Run'
    }
    $control = Get-Content -LiteralPath $script:ControlPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if (-not $control.Contains('Action') -or $control.Action -notin @('Run', 'Pause', 'Resume', 'Stop')) {
        throw "Migration control file has an invalid action: $($script:ControlPath)"
    }
    [string]$control.Action
}

function Set-WebMigrationControlAction {
    param(
        [Parameter(Mandatory)][ValidateSet('Pause', 'Resume', 'Stop')][string] $Action,
        [Parameter(Mandatory)][string] $Actor
    )

    if (-not ($script:MigrationProcess -and -not $script:MigrationProcess.HasExited)) {
        throw [System.InvalidOperationException]::new('There is no active migration run to control.')
    }
    $currentAction = Get-WebMigrationControlAction
    if ($currentAction -eq 'Stop') {
        throw [System.InvalidOperationException]::new('This migration is stopping and cannot be resumed.')
    }
    if ($Action -eq 'Resume' -and $currentAction -ne 'Pause') {
        throw [System.InvalidOperationException]::new('The migration is not paused.')
    }
    if ($Action -eq 'Pause' -and $currentAction -eq 'Pause') {
        return $currentAction
    }
    Write-WebAuditRecord -Action "Migration $($Action.ToLowerInvariant()) requested" -Actor $Actor `
        -RunId $script:RunId -Outcome 'Requested' -Details @{ Action = $Action }
    $temporaryPath = "$($script:ControlPath).tmp"
    $controlJson = ConvertTo-Json -InputObject @{ Action = $Action; UpdatedAt = [DateTime]::UtcNow.ToString('o') } -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $controlJson, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temporaryPath, $script:ControlPath, $true)
    Write-WebHostLog -Level Information -Message "Migration control changed to '$Action'."
    $Action
}

function Send-WebResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)][int] $StatusCode,
        [Parameter(Mandatory)][string] $ContentType,
        [Parameter(Mandatory)][byte[]] $Body
    )

    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = [Text.Encoding]::UTF8
    $Response.ContentLength64 = $Body.Length
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    if ($script:UseSecureTransport) {
        $Response.Headers['Strict-Transport-Security'] = 'max-age=31536000'
    }
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.OutputStream.Write($Body, 0, $Body.Length)
}

function Send-WebJson {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse] $Response,
        [Parameter(Mandatory)][int] $StatusCode,
        [Parameter(Mandatory)] $Value
    )
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    Send-WebResponse -Response $Response -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertTo-WebCustomSqlRows {
    param([Parameter()][object[]] $RawRows = @())

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $RawRows) {
        $flat = [ordered]@{}
        if ($item -is [System.Data.DataRow]) {
            foreach ($column in $item.Table.Columns) {
                $value = $item[$column]
                $flat[$column.ColumnName] = if ($value -is [System.DBNull]) { $null } else { $value }
            }
        }
        else {
            foreach ($property in $item.PSObject.Properties) {
                $flat[$property.Name] = $property.Value
            }
        }
        $rows.Add($flat)
    }
    return $rows.ToArray()
}

function Read-WebRequestJson {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest] $Request)
    if ($Request.ContentLength64 -gt 1048576) {
        throw [ArgumentException]::new('Request body exceeds the 1 MB limit.')
    }
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $builder = [System.Text.StringBuilder]::new()
        $buffer = [char[]]::new(4096)
        while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($builder.Length + $read -gt 1048576) {
                throw [ArgumentException]::new('Request body exceeds the 1 MB limit.')
            }
            $null = $builder.Append($buffer, 0, $read)
        }
        $body = $builder.ToString()
    }
    finally {
        $reader.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw [ArgumentException]::new('A JSON request body is required.')
    }
    try {
        return ConvertFrom-Json -InputObject $body -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [ArgumentException]::new("Request body must be valid JSON: $($_.Exception.Message)")
    }
}

function Get-WebSession {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest] $Request)
    if ($script:AuthenticationMode -eq 'Windows') {
        $windowsIdentity = $Request.User.Identity -as [System.Security.Principal.WindowsIdentity]
        if (-not $windowsIdentity -or -not $windowsIdentity.IsAuthenticated) { return $null }
        if (-not (Test-MigrationWebWindowsGroupMembership -Identity $windowsIdentity -Group $script:WindowsAuthGroup)) {
            return $null
        }
        return @{
            Username = $windowsIdentity.Name
            ExpiresUtc = [DateTime]::MaxValue
            IsWindowsAuthenticated = $true
        }
    }

    $cookie = $Request.Cookies['DbMigrationSession']
    if (-not $cookie -or -not $script:Sessions.ContainsKey($cookie.Value)) {
        return $null
    }
    $session = $script:Sessions[$cookie.Value]
    if ($session.ExpiresUtc -le [DateTime]::UtcNow) {
        $script:Sessions.Remove($cookie.Value)
        return $null
    }
    $session.ExpiresUtc = [DateTime]::UtcNow.AddHours(8)
    return $session
}

function Set-WebSessionCookie {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse] $Response,
        [Parameter()][string] $Token = ''
    )
    $secureSuffix = if ($script:UseSecureTransport) { '; Secure' } else { '' }
    if ($Token) {
        $Response.AppendHeader('Set-Cookie', "DbMigrationSession=$Token; Path=/; HttpOnly; SameSite=Strict$secureSuffix")
    }
    else {
        $Response.AppendHeader('Set-Cookie', "DbMigrationSession=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict$secureSuffix")
    }
}

function Read-WebProgressFiles {
    if (-not $script:ProgressPath -or -not (Test-Path -LiteralPath $script:ProgressPath -PathType Container)) {
        return
    }
    foreach ($eventFile in Get-ChildItem -LiteralPath $script:ProgressPath -Filter '*.json' -File | Sort-Object Name) {
        try {
            $migrationEvent = Get-Content -LiteralPath $eventFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $migrationEvent.Id = $script:NextEventId
            $script:NextEventId++
            $script:EventBuffer.Add($migrationEvent)
            Write-WebRunRecord -Operation Migration -RunId $script:RunId -RecordType Progress -Record @{
                Stage = [string]$migrationEvent.Stage
                Status = [string]$migrationEvent.Status
                Source = [string]$migrationEvent.Source
                Target = [string]$migrationEvent.Target
                Database = [string]$migrationEvent.Database
                Message = [string]$migrationEvent.Message
            }
            Remove-Item -LiteralPath $eventFile.FullName -Force -ErrorAction Stop
        }
        catch {
            Write-Error "Could not process progress event '$($eventFile.Name)': $($_.Exception.Message)"
            throw
        }
    }
    while ($script:EventBuffer.Count -gt 5000) {
        $script:EventBuffer.RemoveAt(0)
    }
}

function Read-WebProcessOutput {
    if ($script:CurrentProcessOperation -eq 'Patch' -and
        $script:PatchProcess -and $script:PatchProcess.HasExited) {
        $script:PatchProcess.WaitForExit()
    }
    elseif ($script:CurrentProcessOperation -eq 'Migration' -and
        $script:MigrationProcess -and $script:MigrationProcess.HasExited) {
        $script:MigrationProcess.WaitForExit()
    }

    $queuedOutput = $null
    while ($script:ProcessOutputQueue.TryDequeue([ref]$queuedOutput)) {
        $outputEvent = @{
            Id = $script:NextEventId
            Timestamp = [DateTime]::UtcNow.ToString('o')
            Source = ''
            Target = ''
            Database = ''
            Stage = 'ProcessOutput'
            Status = $queuedOutput.Status
            Message = $queuedOutput.Message
        }
        $script:NextEventId++
        $script:EventBuffer.Add($outputEvent)
        if ($script:CurrentProcessOperation -eq 'Patch' -and $script:PatchRunId) {
            Write-WebRunRecord -Operation Patch -RunId $script:PatchRunId -RecordType ProcessOutput -Record @{
                Status = $queuedOutput.Status
                Message = $queuedOutput.Message
                Action = $script:PatchAction
                KB = $script:PatchKB
            }
        }
        elseif ($script:CurrentProcessOperation -eq 'Migration' -and $script:RunId) {
            Write-WebRunRecord -Operation Migration -RunId $script:RunId -RecordType ProcessOutput -Record @{
                Status = $queuedOutput.Status
                Message = $queuedOutput.Message
            }
        }
        $queuedOutput = $null
    }
    if ($script:ProcessOutputHandler -and $script:ProcessOutputHandler.ConsumeDroppedLines() -gt 0) {
        $script:EventBuffer.Add(@{
            Id = $script:NextEventId
            Timestamp = [DateTime]::UtcNow.ToString('o')
            Source = ''
            Target = ''
            Database = ''
            Stage = 'ProcessOutput'
            Status = 'InProgress'
            Message = 'The process output buffer reached its limit; older console lines were discarded. Structured progress events are unaffected.'
        })
        $script:NextEventId++
    }
    while ($script:EventBuffer.Count -gt 5000) {
        $script:EventBuffer.RemoveAt(0)
    }
}

function Get-WebPair {
    param([Parameter(Mandatory)][int] $Index)
    if ($Index -lt 0 -or $Index -ge $script:WebConfiguration.SourceTargets.Count) {
        throw [ArgumentException]::new('The selected source/target pair is not configured.')
    }
    return $script:WebConfiguration.SourceTargets[$Index]
}

function Start-WebMigration {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Body)

    if ($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) {
        throw [System.InvalidOperationException]::new('A migration is already running.')
    }
    if (-not $Body.Contains('PairIndex') -or -not $Body.Contains('Databases')) {
        throw [ArgumentException]::new('PairIndex and Databases are required.')
    }
    if ($Body.PairIndex -is [bool] -or
        $Body.PairIndex -isnot [byte] -and $Body.PairIndex -isnot [int16] -and
        $Body.PairIndex -isnot [int32] -and $Body.PairIndex -isnot [int64]) {
        throw [ArgumentException]::new('PairIndex must be an integer.')
    }
    if ($Body.Databases -isnot [array]) {
        throw [ArgumentException]::new('Databases must be a JSON array.')
    }
    foreach ($option in @('MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators', 'ConfigureLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics')) {
        if (-not $Body.Contains($option) -or $Body[$option] -isnot [bool]) {
            throw [ArgumentException]::new("'$option' must be provided as a JSON boolean.")
        }
    }
    $pairIndex = [int]$Body.PairIndex
    $pair = Get-WebPair -Index $pairIndex
    if (-not $script:DiscoveryByPair.ContainsKey([string]$pairIndex)) {
        throw [ArgumentException]::new('Discover databases for this source/target pair before starting a migration.')
    }
    $availableDatabases = @($script:DiscoveryByPair[[string]$pairIndex] | ForEach-Object { [string]$_.Database })
    $selectedDatabases = @($Body.Databases | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if (@($selectedDatabases | Where-Object { $_ -notin $availableDatabases }).Count -gt 0) {
        throw [ArgumentException]::new('One or more selected databases are not in the latest discovery results.')
    }
    if ($selectedDatabases.Count -eq 0 -and
        -not ($Body.MigrateLogins -or $Body.MigrateAgentJobs -or $Body.MigrateAgentOperators -or $Body.ConfigureLinkedServers)) {
        throw [ArgumentException]::new('Select at least one database or one server-level migration option.')
    }
    $requestedOverwrites = @()
    if ($Body.Contains('OverwriteDatabases')) {
        if ($Body.OverwriteDatabases -isnot [array]) {
            throw [ArgumentException]::new('OverwriteDatabases must be a JSON array.')
        }
        $requestedOverwrites = @($Body.OverwriteDatabases | ForEach-Object { [string]$_ } | Select-Object -Unique)
    }
    if (@($requestedOverwrites | Where-Object { $_ -notin $selectedDatabases }).Count -gt 0) {
        throw [ArgumentException]::new('Overwrite authorization may only be provided for selected databases.')
    }

    Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Discovery.psm1') -Force
    $overwrites = [System.Collections.Generic.List[string]]::new()
    $skips = [System.Collections.Generic.List[string]]::new()
    foreach ($databaseName in $selectedDatabases) {
        if (Test-MigrationDatabaseExists -SqlInstance $pair.Target -Database $databaseName) {
            if ($databaseName -in $requestedOverwrites) {
                $overwrites.Add($databaseName)
            }
            else {
                $skips.Add($databaseName)
            }
        }
    }

    $runConfiguration = $script:WebConfiguration.Clone()
    foreach ($key in @($runConfiguration.Keys)) {
        if ($key -in @('MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators', 'ConfigureLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics')) {
            $runConfiguration.Remove($key)
        }
    }
    $runConfiguration.SourceTargets = @(@{
        Source = [string]$pair.Source
        Target = [string]$pair.Target
        BackupPath = [string]$pair.BackupPath
    })
    $runConfiguration.IncludeDatabases = $selectedDatabases
    $runConfiguration.OverwriteExistingDatabases = @($overwrites)
    $runConfiguration.SkipExistingDatabases = @($skips)
    foreach ($option in @('MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators', 'ConfigureLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics')) {
        $runConfiguration[$option] = $Body[$option]
    }
    $runConfiguration.AllowTargetReplace = $false
    foreach ($property in @('OutputPath', 'LinkedServersCsv')) {
        if (-not [System.IO.Path]::IsPathRooted([string]$runConfiguration[$property])) {
            $runConfiguration[$property] = Join-Path $PSScriptRoot $runConfiguration[$property]
        }
    }

    $runDirectory = Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Runs'
    $null = New-Item -ItemType Directory -Path $runDirectory -Force -ErrorAction Stop
    $script:RunId = [guid]::NewGuid().ToString('N')
    $script:RuntimeConfigPath = Join-Path $runDirectory "$($script:RunId).json"
    $script:ProgressPath = Join-Path $runDirectory "$($script:RunId)-progress"
    $null = New-Item -ItemType Directory -Path $script:ProgressPath -Force -ErrorAction Stop
    $runConfiguration | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:RuntimeConfigPath -Encoding utf8
    $script:EventBuffer.Clear()
    $script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
    $script:NextEventId = 1

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Invoke-DbMigration.ps1'),
        '-Mode', 'Migrate', '-ConfigPath', $script:RuntimeConfigPath,
        '-ProgressPath', $script:ProgressPath,
        '-StatePath', $fullStatePath
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $script:MigrationProcess = [System.Diagnostics.Process]::new()
    $script:MigrationProcess.StartInfo = $startInfo
    $script:ProcessOutputHandler = [DbMigration.Web.ProcessOutputHandler]::new($script:ProcessOutputQueue)
    $script:ProcessOutputHandler.Attach($script:MigrationProcess)
    if (-not $script:MigrationProcess.Start()) {
        throw 'Could not start the migration process.'
    }
    $script:MigrationProcess.BeginOutputReadLine()
    $script:MigrationProcess.BeginErrorReadLine()
    return @{
        RunId = $script:RunId
        Status = 'Running'
        Pair = @{ Source = $pair.Source; Target = $pair.Target }
        Databases = $selectedDatabases
        OverwriteDatabases = @($overwrites)
        SkippedExistingDatabases = @($skips)
    }
}

function Get-WebPairKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Pair)
    $identity = [string]::Join([char]0, @(
        ([string]$Pair.Source).Trim().ToLowerInvariant(),
        ([string]$Pair.Target).Trim().ToLowerInvariant()
    ))
    [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes($identity)
    )).ToLowerInvariant()
}

function ConvertTo-WebPairs {
    param(
        [Parameter(Mandatory)][object[]] $Pairs,
        [Parameter()][switch] $RequireBackupPath
    )
    if ($Pairs.Count -lt 1 -or $Pairs.Count -gt 3) {
        throw [ArgumentException]::new('Enter between one and three source/target pairs.')
    }
    $validatedPairs = [System.Collections.Generic.List[object]]::new()
    $endpointKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in $Pairs) {
        if ($pair -isnot [System.Collections.IDictionary]) {
            throw [ArgumentException]::new('Each instance entry must contain source, target, and backup path values.')
        }
        $requiredNames = if ($RequireBackupPath) { @('Source', 'Target', 'BackupPath') } else { @('Source', 'Target') }
        foreach ($name in $requiredNames) {
            if (-not $pair.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$pair[$name])) {
                throw [ArgumentException]::new("Each instance entry must include a non-empty '$name'.$(if ($name -eq 'BackupPath') { ' A shared backup path is required to migrate.' })")
            }
        }
        $rawBackupPath = if ($pair.Contains('BackupPath')) { ([string]$pair.BackupPath).Trim() } else { '' }
        if ($rawBackupPath -and -not [System.IO.Path]::IsPathRooted($rawBackupPath)) {
            throw [ArgumentException]::new('Backup paths must be absolute local or UNC paths.')
        }
        $normalizedPair = @{
            Source = ([string]$pair.Source).Trim()
            Target = ([string]$pair.Target).Trim()
            BackupPath = if ($rawBackupPath) { [System.IO.Path]::GetFullPath($rawBackupPath) } else { '' }
            MigrationMode = if ($pair.Contains('MigrationMode')) { [string]$pair.MigrationMode } else { 'Full' }
        }
        if ($pair.Contains('LinkedServers')) {
            if ($pair.LinkedServers -isnot [array]) {
                throw [ArgumentException]::new('LinkedServers must be an array for each source/target pair.')
            }
            $normalizedPair.LinkedServers = $pair.LinkedServers
        }
        if ($pair.Contains('LinkedServersLoaded')) {
            if ($pair.LinkedServersLoaded -isnot [bool]) {
                throw [ArgumentException]::new('LinkedServersLoaded must be a JSON boolean.')
            }
            $normalizedPair.LinkedServersLoaded = [bool]$pair.LinkedServersLoaded
        }
        if ($normalizedPair.MigrationMode -notin @('Full', 'SchemaOnly')) {
            throw [ArgumentException]::new("MigrationMode for '$($normalizedPair.Source)' must be 'Full' or 'SchemaOnly'.")
        }
        if ($pair.Contains('Databases')) {
            if ($pair.Databases -isnot [array]) {
                throw [ArgumentException]::new('Database selections must be provided as an array for each source/target pair.')
            }
            $normalizedPair.Databases = $pair.Databases
        }
        $endpointKey = [string]::Join([char]0, @(
            $normalizedPair.Source.ToLowerInvariant(),
            $normalizedPair.Target.ToLowerInvariant()
        ))
        if (-not $endpointKeys.Add($endpointKey)) {
            throw [ArgumentException]::new('Duplicate source/target instance pairs are not allowed.')
        }
        $validatedPairs.Add($normalizedPair)
    }
    return $validatedPairs.ToArray()
}

function Start-WebMigrationPlan {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Body,
        [Parameter()][string] $Actor = ''
    )

    if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
        ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
        throw [System.InvalidOperationException]::new('Another migration or SQL Server patch operation is already running.')
    }
    if (-not $Body.Contains('Pairs') -or $Body.Pairs -isnot [array] -or
        -not $Body.Contains('Options') -or $Body.Options -isnot [System.Collections.IDictionary]) {
        throw [ArgumentException]::new('Pairs and Options are required.')
    }
    $pairs = @(ConvertTo-WebPairs -Pairs $Body.Pairs -RequireBackupPath)
    $optionNames = @(
        'MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators',
        'ConfigureLinkedServers', 'SkipLinkedServers', 'RepairOrphanUsers', 'UpdateStatistics'
    )
    foreach ($optionName in $optionNames) {
        if (-not $Body.Options.Contains($optionName) -or $Body.Options[$optionName] -isnot [bool]) {
            throw [ArgumentException]::new("'$optionName' must be provided as a JSON boolean.")
        }
    }
    $configureLinkedServers = [bool]$Body.Options.ConfigureLinkedServers -and -not [bool]$Body.Options.SkipLinkedServers
    $linkedServerSecrets = [System.Collections.Generic.List[object]]::new()
    $linkedServerRunToken = [guid]::NewGuid().ToString('N')
    $planPairs = [System.Collections.Generic.List[object]]::new()
    for ($pairIndex = 0; $pairIndex -lt $pairs.Count; $pairIndex++) {
        $pair = $pairs[$pairIndex]
        $serverWork = Test-MigrationServerWorkEnabled -Options $Body.Options -MigrationMode $pair.MigrationMode
        $pairKey = Get-WebPairKey -Pair $pair
        if (-not $script:DiscoveryByPair.ContainsKey($pairKey)) {
            throw [ArgumentException]::new("Run discovery for '$($pair.Source)' -> '$($pair.Target)' before starting migration.")
        }
        $discovery = $script:DiscoveryByPair[$pairKey]
        if ($discovery.Pair.Source -cne $pair.Source -or $discovery.Pair.Target -cne $pair.Target) {
            throw [ArgumentException]::new('A source or target changed after discovery. Run discovery again.')
        }
        if (-not $pair.Contains('Databases') -or $pair.Databases -isnot [array]) {
            throw [ArgumentException]::new('Each pair must include a database selection array.')
        }
        $knownDatabases = @($discovery.Databases | ForEach-Object { [string]$_.Database })
        $selectedNames = @($pair.Databases | ForEach-Object { [string]$_.Database })
        if (@($selectedNames | Where-Object { $_ -notin $knownDatabases }).Count -gt 0) {
            throw [ArgumentException]::new("A selected database was not in the latest discovery for '$($pair.Source)'.")
        }
        if (@($pair.Databases | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Database) }).Count -gt 0) {
            throw [ArgumentException]::new('Database names must not be empty.')
        }
        if (@($selectedNames | Select-Object -Unique).Count -ne $selectedNames.Count) {
            throw [ArgumentException]::new("Duplicate database entries were selected for '$($pair.Source)'.")
        }
        $linkedServerDefinitions = @()
        if ($configureLinkedServers) {
            if (-not $pair.Contains('LinkedServersLoaded') -or -not $pair.LinkedServersLoaded -or
                -not $pair.Contains('LinkedServers')) {
                throw [ArgumentException]::new("Load and review linked servers for '$($pair.Source)' before starting linked-server configuration.")
            }
            if ($pair.LinkedServers.Count -gt 100) {
                throw [ArgumentException]::new("No more than 100 linked-server definitions can be configured for '$($pair.Source)' in one run.")
            }
            $linkedServerNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            for ($linkedIndex = 0; $linkedIndex -lt $pair.LinkedServers.Count; $linkedIndex++) {
                $definition = $pair.LinkedServers[$linkedIndex]
                if ($definition -isnot [System.Collections.IDictionary]) {
                    throw [ArgumentException]::new('Each linked-server definition must be an object.')
                }
                $password = if ($definition.Contains('Password')) { [string]$definition.Password } else { '' }
                $definition.Password = ''
                try {
                    foreach ($requiredField in @('LinkedServer', 'Provider', 'Product', 'DataSource', 'SecurityMode', 'RemoteUser')) {
                        if (-not $definition.Contains($requiredField)) {
                            throw [ArgumentException]::new("Linked-server definition is missing '$requiredField'.")
                        }
                    }
                    foreach ($requiredField in @('LinkedServer', 'Provider', 'Product', 'DataSource', 'SecurityMode')) {
                        if ([string]::IsNullOrWhiteSpace([string]$definition[$requiredField])) {
                            throw [ArgumentException]::new("Linked-server field '$requiredField' must not be empty.")
                        }
                    }
                    $linkedName = ([string]$definition.LinkedServer).Trim()
                    if (-not $linkedServerNames.Add($linkedName)) {
                        throw [ArgumentException]::new("Linked-server name '$linkedName' is duplicated for '$($pair.Source)'.")
                    }
                    $securityMode = [string]$definition.SecurityMode
                    if ($securityMode -notin @('NoConnection', 'WithoutSecurityContext', 'CurrentSecurityContext', 'SpecifiedSecurityContext')) {
                        throw [ArgumentException]::new("Linked server '$linkedName' has an unsupported security mode.")
                    }
                    $remoteUser = [string]$definition.RemoteUser
                    if ($securityMode -eq 'SpecifiedSecurityContext') {
                        if ([string]::IsNullOrWhiteSpace($remoteUser) -or [string]::IsNullOrEmpty($password)) {
                            throw [ArgumentException]::new("Linked server '$linkedName' requires a remote login and password for SQL authentication.")
                        }
                        $environmentName = "DBMIGRATION_LINKEDSERVER_${linkedServerRunToken}_${pairIndex}_${linkedIndex}"
                        $linkedServerSecrets.Add(@{ Name = $environmentName; Value = $password })
                    }
                    elseif (-not [string]::IsNullOrEmpty($password)) {
                        throw [ArgumentException]::new("Remove the password for linked server '$linkedName' or select SpecifiedSecurityContext.")
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($remoteUser)) {
                        throw [ArgumentException]::new("Remove the remote login for linked server '$linkedName' or select SpecifiedSecurityContext.")
                    }
                    $linkedServerDefinitions += @{
                        LinkedServer = $linkedName
                        Provider = ([string]$definition.Provider).Trim()
                        Product = ([string]$definition.Product).Trim()
                        DataSource = ([string]$definition.DataSource).Trim()
                        Catalog = [string]$definition.Catalog
                        SecurityMode = $securityMode
                        RemoteUser = $remoteUser
                        PasswordEnvironmentVariable = if ($securityMode -eq 'SpecifiedSecurityContext') { $environmentName } else { '' }
                    }
                }
                finally {
                    $definition.Password = ''
                    $password = ''
                }
            }
        }
        foreach ($database in $pair.Databases) {
            if ($database -isnot [System.Collections.IDictionary] -or
                -not $database.Contains('Overwrite') -or $database.Overwrite -isnot [bool] -or
                -not $database.Contains('Database')) {
                throw [ArgumentException]::new('Database selections must include a boolean Overwrite decision.')
            }
            $knownDatabase = @($discovery.Databases | Where-Object { $_.Database -ceq $database.Database }) | Select-Object -First 1
            if ([bool]$database.Overwrite -and -not [bool]$knownDatabase.TargetExists) {
                throw [ArgumentException]::new("Overwrite was approved for '$($database.Database)', but discovery did not show an existing target.")
            }
        }
        if ($selectedNames.Count -eq 0 -and -not $serverWork) {
            continue
        }
        $planPairs.Add(@{
            Source = $pair.Source
            Target = $pair.Target
            BackupPath = $pair.BackupPath
            MigrationMode = $pair.MigrationMode
            Databases = @($pair.Databases | ForEach-Object {
                @{ Database = [string]$_.Database; Overwrite = [bool]$_.Overwrite }
            })
            LinkedServers = @($linkedServerDefinitions)
        })
    }
    if ($planPairs.Count -eq 0) {
        throw [ArgumentException]::new('Select at least one database or server-level action for a configured pair.')
    }

    $configuration = $script:WebConfiguration.Clone()
    foreach ($property in @('OutputPath', 'LinkedServersCsv')) {
        if (-not [System.IO.Path]::IsPathRooted([string]$configuration[$property])) {
            $configuration[$property] = Join-Path $PSScriptRoot $configuration[$property]
        }
    }
    $plan = @{ Configuration = $configuration; Pairs = $planPairs.ToArray(); Options = $Body.Options }
    foreach ($pair in $planPairs) {
        $configuredPair = @($configuration.SourceTargets | Where-Object {
            $_.Source -ieq $pair.Source -and $_.Target -ieq $pair.Target
        }) | Select-Object -First 1
        if ($configuredPair) {
            $configuredPair.MigrationMode = $pair.MigrationMode
        }
    }
    $runDirectory = Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Runs'
    $null = New-Item -ItemType Directory -Path $runDirectory -Force -ErrorAction Stop
    Read-WebProcessOutput
    $script:RunId = [guid]::NewGuid().ToString('N')
    $script:MigrationPairs = @($planPairs | ForEach-Object {
        @{ Source = $_.Source; Target = $_.Target }
    })
    $script:CurrentProcessOperation = 'Migration'
    $script:MigrationActor = $Actor
    $script:MigrationCompletionLoggedRunId = $null
    $script:RuntimeConfigPath = Join-Path $runDirectory "$($script:RunId)-plan.json"
    $script:ProgressPath = Join-Path $runDirectory "$($script:RunId)-progress"
    $script:ControlPath = Join-Path $runDirectory "$($script:RunId)-control.json"
    $script:DatabaseJobCount = [int](@($planPairs | ForEach-Object { $_.Databases.Count } | Measure-Object -Sum).Sum)
    $null = New-Item -ItemType Directory -Path $script:ProgressPath -Force -ErrorAction Stop
    [System.IO.File]::WriteAllText($script:ControlPath, '{"Action":"Run"}', [System.Text.UTF8Encoding]::new($false))
    $plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:RuntimeConfigPath -Encoding utf8
    $script:EventBuffer.Clear()
    $script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
    $script:NextEventId = 1

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Invoke-DbMigrationWebPlan.ps1'),
        '-PlanPath', $script:RuntimeConfigPath,
        '-ProgressPath', $script:ProgressPath,
        '-StatePath', $fullStatePath,
        '-ControlPath', $script:ControlPath
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    foreach ($secret in $linkedServerSecrets) {
        $startInfo.Environment[$secret.Name] = $secret.Value
    }
    Write-WebAuditRecord -Action 'Migration launch requested' -Actor $Actor -RunId $script:RunId -Outcome 'Requested' -Details @{
        Pairs = @($planPairs | ForEach-Object { @{ Source = $_.Source; Target = $_.Target } })
        DatabaseCount = $script:DatabaseJobCount
    }
    $script:MigrationProcess = [System.Diagnostics.Process]::new()
    $script:MigrationProcess.StartInfo = $startInfo
    $script:ProcessOutputHandler = [DbMigration.Web.ProcessOutputHandler]::new($script:ProcessOutputQueue)
    $script:ProcessOutputHandler.Attach($script:MigrationProcess)
    try {
        if (-not $script:MigrationProcess.Start()) {
            throw 'Could not start the migration plan process.'
        }
    }
    finally {
        foreach ($secret in $linkedServerSecrets) {
            $startInfo.Environment.Remove($secret.Name)
            $secret.Value = ''
        }
    }
    $script:MigrationProcess.BeginOutputReadLine()
    $script:MigrationProcess.BeginErrorReadLine()
    Write-WebRunRecord -Operation Migration -RunId $script:RunId -RecordType RunStarted -Record @{
        Pairs = @($planPairs | ForEach-Object { @{ Source = $_.Source; Target = $_.Target } })
        DatabaseCount = $script:DatabaseJobCount
        StartedBy = $Actor
    }
    Write-WebAuditRecord -Action 'Migration started' -Actor $Actor -RunId $script:RunId -Details @{
        Pairs = @($planPairs | ForEach-Object { @{ Source = $_.Source; Target = $_.Target } })
        DatabaseCount = $script:DatabaseJobCount
    }
    return @{
        RunId = $script:RunId
        Status = 'Running'
        Sequential = $true
        DatabaseCount = $script:DatabaseJobCount
        Pairs = @($planPairs | ForEach-Object {
            @{ Source = $_.Source; Target = $_.Target; DatabaseCount = $_.Databases.Count }
        })
    }
}

function Get-WebServerPatchLevel {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Target)
    $productVersion = [string](Invoke-DbaQuery -SqlInstance $Target.SqlInstance -Database master -EnableException -ErrorAction Stop `
        -Query "SELECT CONVERT(nvarchar(50), SERVERPROPERTY('ProductVersion')) AS ProductVersion" |
        Select-Object -First 1).ProductVersion
    $build = @(Get-DbaBuild -Build $productVersion -EnableException -ErrorAction Stop | Select-Object -First 1)
    if (-not $build) {
        throw "Could not determine SQL Server build for '$($Target.SqlInstance)'."
    }
    @{
        SqlInstance = $Target.SqlInstance
        Role = $Target.Role
        PairIndex = $Target.PairIndex
        MajorVersion = [string]$build[0].NameLevel
        ServicePack = [string]$build[0].SPLevel
        BuildLevel = [string]$build[0].BuildLevel
        CurrentPatch = [string]$build[0].CULevel
        ProductVersion = $productVersion
        KB = [string]$build[0].KBLevel
    }
}

function ConvertTo-WebPatchTargets {
    param([Parameter(Mandatory)][object[]] $Selections)

    if ($Selections.Count -eq 0) {
        throw [ArgumentException]::new('Select at least one configured SQL Server instance.')
    }
    $targets = [System.Collections.Generic.List[object]]::new()
    $selectedInstances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($selection in $Selections) {
        if ($selection -isnot [System.Collections.IDictionary] -or -not $selection.Contains('Role')) {
            throw [ArgumentException]::new('Each target selection must include a Role and either SqlInstance or PairIndex.')
        }
        $role = [string]$selection.Role
        if ($role -eq 'Standalone' -and $selection.Contains('SqlInstance')) {
            $sqlInstance = ([string]$selection.SqlInstance).Trim()
            $pairIndex = -1
        }
        else {
            if (-not $selection.Contains('PairIndex') -or $selection.PairIndex -is [bool] -or
                $selection.PairIndex -isnot [byte] -and $selection.PairIndex -isnot [int16] -and
                $selection.PairIndex -isnot [int32] -and $selection.PairIndex -isnot [int64]) {
                throw [ArgumentException]::new('PairIndex must be an integer for source/target selections.')
            }
            if ($role -notin @('Source', 'Target')) {
                throw [ArgumentException]::new("Role must be 'Source', 'Target', or a standalone SqlInstance.")
            }
            $pairIndex = [int]$selection.PairIndex
            if ($selection.Contains('SqlInstance') -and -not [string]::IsNullOrWhiteSpace([string]$selection.SqlInstance)) {
                $sqlInstance = ([string]$selection.SqlInstance).Trim()
            }
            else {
                $pair = Get-WebPair -Index $pairIndex
                $sqlInstance = [string]$pair[$role]
            }
        }
        if ([string]::IsNullOrWhiteSpace($sqlInstance)) {
            throw [ArgumentException]::new('A non-empty SQL instance is required for every patch target.')
        }
        if (-not $selectedInstances.Add($sqlInstance)) {
            throw [ArgumentException]::new("SQL instance '$sqlInstance' was selected more than once.")
        }
        $targets.Add(@{ SqlInstance = $sqlInstance; Role = $role; PairIndex = $pairIndex })
    }
    $targets.ToArray()
}

function Get-WebPatchCatalogRecord {
    param([Parameter(Mandatory)][string] $KB)
    $record = @($script:PatchCatalog | Where-Object { [string]$_.KB -eq $KB } | Select-Object -First 1)
    if (-not $record) {
        throw [ArgumentException]::new("KB$KB is not in the current patch catalog. Refresh the catalog and choose a listed update.")
    }
    $record[0]
}

function Test-WebHostElevated {
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-WebSqlServerPatch {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Body,
        [Parameter(Mandatory)][ValidateSet('Download', 'Apply')][string] $Action,
        [Parameter()][string] $Actor = ''
    )

    if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
        ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
        throw [System.InvalidOperationException]::new('Another migration or SQL Server patch operation is already running.')
    }
    foreach ($property in @('KB', 'UpdatePath')) {
        if (-not $Body.Contains($property)) {
            throw [ArgumentException]::new("$property is required.")
        }
    }
    $kb = [string]$Body.KB
    if ($kb -notmatch '^\d{5,10}$') {
        throw [ArgumentException]::new('KB must be a numeric Microsoft Knowledge Base identifier.')
    }
    $patch = Get-WebPatchCatalogRecord -KB $kb
    $updatePath = [string]$Body.UpdatePath
    if ([string]::IsNullOrWhiteSpace($updatePath)) {
        throw [ArgumentException]::new('UpdatePath is required.')
    }

    $targets = @()
    $restart = $false
    if ($Action -eq 'Apply') {
        foreach ($property in @('Targets', 'Restart')) {
            if (-not $Body.Contains($property)) {
                throw [ArgumentException]::new("$property is required.")
            }
        }
        if ($Body.Targets -isnot [array] -or $Body.Restart -isnot [bool]) {
            throw [ArgumentException]::new('Targets must be an array and Restart must be a JSON boolean.')
        }
        $targets = @(ConvertTo-WebPatchTargets -Selections @($Body.Targets))
        $restart = [bool]$Body.Restart
        if (-not (Test-Path -LiteralPath $updatePath -PathType Container)) {
            throw [ArgumentException]::new('The update repository folder does not exist on the app host.')
        }
        foreach ($target in $targets) {
            $instanceHost = ([string]$target.SqlInstance -split '[\\,]')[0].Trim().ToLowerInvariant()
            $isLocalTarget = $instanceHost -in @('localhost', '.', '(local)', '127.0.0.1', '::1', $env:COMPUTERNAME.ToLowerInvariant())
            if ($isLocalTarget -and -not (Test-WebHostElevated)) {
                throw [System.InvalidOperationException]::new("Patching '$($target.SqlInstance)' needs administrator rights on this machine. Close the app and start it again with 'Run as administrator' (or accept the UAC prompt when launching), then retry.")
            }
            $assessment = Get-MigrationSqlServerPatchAssessment -SqlInstance $target.SqlInstance             -KB $kb
                        if ($assessment.Status -ne 'Eligible') {
                            throw [ArgumentException]::new("Cannot apply KB$kb to '$($target.SqlInstance)': $($assessment.Status) - $($assessment.Reason)")
                        }
                    }
    }

    $runDirectory = Join-Path $env:LOCALAPPDATA 'DbMigrationWeb\Runs'
    $null = New-Item -ItemType Directory -Path $runDirectory -Force -ErrorAction Stop
    Read-WebProcessOutput
    $script:PatchRunId = [guid]::NewGuid().ToString('N')
    $script:CurrentProcessOperation = 'Patch'
    $script:PatchAction = $Action
    $script:PatchKB = $kb
    $script:PatchTargets = @($targets | ForEach-Object { [string]$_.SqlInstance })
    $script:PatchActor = $Actor
    $script:PatchCompletionLoggedRunId = $null
    $planPath = Join-Path $runDirectory "$($script:PatchRunId)-patch.json"
    $plan = @{
        Action = $Action
        Targets = $targets
        KB = $kb
        UpdatePath = [System.IO.Path]::GetFullPath($updatePath)
        Restart = $restart
    }
    $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

    $script:ProcessOutputQueue = [System.Collections.Concurrent.ConcurrentQueue[DbMigration.Web.ProcessOutputLine]]::new()
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Invoke-DbMigrationPatch.ps1'),
        '-PlanPath', $planPath
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    Write-WebAuditRecord -Action "Patch $($Action.ToLowerInvariant()) launch requested" -Actor $Actor -RunId $script:PatchRunId -Outcome 'Requested' -Details @{
        KB = $kb
        Targets = @($targets | ForEach-Object { [string]$_.SqlInstance })
        Restart = [bool]$restart
    }
    $script:PatchProcess = [System.Diagnostics.Process]::new()
    $script:PatchProcess.StartInfo = $startInfo
    $script:ProcessOutputHandler = [DbMigration.Web.ProcessOutputHandler]::new($script:ProcessOutputQueue)
    $script:ProcessOutputHandler.Attach($script:PatchProcess)
    if (-not $script:PatchProcess.Start()) {
        throw 'Could not start the SQL Server patch process.'
    }
    $script:PatchProcess.BeginOutputReadLine()
    $script:PatchProcess.BeginErrorReadLine()
    Write-WebRunRecord -Operation Patch -RunId $script:PatchRunId -RecordType RunStarted -Record @{
        Action = $Action
        KB = $kb
        Targets = @($script:PatchTargets)
    }
    Write-WebAuditRecord -Action "Patch $($Action.ToLowerInvariant()) started" -Actor $Actor -RunId $script:PatchRunId -Details @{
        KB = $kb
        Targets = @($script:PatchTargets)
        Restart = $restart
    }

    return @{
        RunId = $script:PatchRunId
        Status = 'Running'
        Action = $Action
        TargetCount = $targets.Count
        KB = $patch.KB
        Title = $patch.Title
    }
}

$script:InstanceMutex = [System.Threading.Mutex]::new($false, 'Global\DbMigrationToolWebHost')
$script:HasInstanceLock = $false
try {
    $script:HasInstanceLock = $script:InstanceMutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $script:HasInstanceLock = $true
}
if (-not $script:HasInstanceLock) {
    $script:InstanceMutex.Dispose()
    throw 'Another Database Migration web host is already running on this machine. Only one instance can run at a time; close the existing one first.'
}

$script:Listener.Start()
Write-Output "Database migration browser UI: $($script:Origin)/"
if ($script:SetupToken) {
    Write-Output "First-run administrator setup code (enter in a browser on this computer): $($script:SetupToken)"
}
Write-Output "Web host log: $($script:HostLogPath)"
Write-Output 'Use Ctrl+C to stop the web host. Do not stop the host while a migration is running.'
Write-WebHostLog -Level Information -Message "Web host started at $($script:Origin)."
try {
    while ($script:Listener.IsListening) {
        $context = $script:Listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $script:CurrentAuditRequestId = [guid]::NewGuid().ToString('N')
        $script:CurrentAuditClientAddress = [string]$request.RemoteEndPoint.Address
        $session = $null
        try {
            $hostHeader = $request.UserHostName
            if (-not [string]::Equals($hostHeader, "$($script:HostName):$($script:Port)", [StringComparison]::OrdinalIgnoreCase) -and
                -not [string]::Equals($hostHeader, $script:HostName, [StringComparison]::OrdinalIgnoreCase)) {
                Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'Invalid host header.' }
                continue
            }
            if (-not $script:UseSecureTransport -and -not $request.IsSecureConnection) {
                $localAddress = [string]$request.LocalEndPoint.Address
                $requestIsAllowed = $request.Url.Scheme -eq 'http' -and (
                    $localAddress -eq '127.0.0.1' -or
                    $localAddress -eq '::1' -or
                    $localAddress.StartsWith('127.') -or
                    $localAddress.StartsWith('::1')
                )
                if (-not $requestIsAllowed) {
                    Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'In portable mode, only local HTTP is supported.' }
                    continue
                }
            }
            elseif (-not $request.IsSecureConnection) {
                Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'HTTPS is required.' }
                continue
            }
            $windowsSession = $null
            if ($script:AuthenticationMode -eq 'Windows') {
                $windowsSession = Get-WebSession -Request $request
                if (-not $windowsSession) {
                    $identity = $request.User.Identity
                    $isAuthenticated = $identity -and $identity.IsAuthenticated
                    $statusCode = if ($isAuthenticated) { 403 } else { 401 }
                    $message = if ($isAuthenticated) {
                        "Windows account '$($identity.Name)' is not a member of the required AD group '$($script:WindowsAuthGroup)'."
                    }
                    else {
                        'Windows Integrated Authentication is required.'
                    }
                    if ($isAuthenticated) {
                        Write-WebAuditRecord -Action 'Windows authentication denied' -Actor ([string]$identity.Name) `
                            -Outcome 'Denied' -Details @{ Reason = 'RequiredGroupMembership' }
                    }
                    Send-WebJson -Response $response -StatusCode $statusCode -Value @{ error = $message; authMode = 'Windows' }
                    continue
                }
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -in @('/', '/index.html')) {
                $indexPath = Join-Path $PSScriptRoot 'web\index.html'
                $bytes = [System.IO.File]::ReadAllBytes($indexPath)
                Send-WebResponse -Response $response -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body $bytes
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/session') {
                $session = if ($script:AuthenticationMode -eq 'Windows') { $windowsSession } else { Get-WebSession -Request $request }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    authenticated = [bool]$session
                    username = if ($session) { $session.Username } else { '' }
                    authMode = $script:AuthenticationMode
                    setupRequired = $script:AuthenticationMode -eq 'Application' -and $null -eq $script:AuthRecord
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Headers['Origin'] -ne $script:Origin) {
                Send-WebJson -Response $response -StatusCode 403 -Value @{ error = 'Request origin is not allowed.' }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/setup') {
                if ($script:AuthenticationMode -ne 'Application' -or
                    $null -ne $script:AuthRecord -or
                    [string]::IsNullOrEmpty($script:SetupToken) -or
                    (Test-Path -LiteralPath $fullAuthPath -PathType Leaf)) {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = 'First-run setup has already been completed or is unavailable.' }
                    continue
                }
                $remoteAddress = $request.RemoteEndPoint.Address
                $localAddress = $request.LocalEndPoint.Address
                $sameHostAddress = $remoteAddress.Equals($localAddress) -or
                    ($remoteAddress.IsIPv4MappedToIPv6 -and $remoteAddress.MapToIPv4().Equals($localAddress)) -or
                    ($localAddress.IsIPv4MappedToIPv6 -and $localAddress.MapToIPv4().Equals($remoteAddress))
                if (-not [System.Net.IPAddress]::IsLoopback($remoteAddress) -and -not $sameHostAddress) {
                    Send-WebJson -Response $response -StatusCode 403 -Value @{ error = 'Initial administrator setup must be completed from a browser on the web-host computer.' }
                    continue
                }
                $address = [string]$request.RemoteEndPoint.Address
                $attempts = @($script:SetupAttempts[$address] | Where-Object { $_ -gt [DateTime]::UtcNow.AddMinutes(-10) })
                if ($attempts.Count -ge 5) {
                    $script:SetupAttempts[$address] = $attempts
                    Send-WebJson -Response $response -StatusCode 429 -Value @{ error = 'Too many setup attempts. Restart the web host and try again.' }
                    continue
                }
                $body = Read-WebRequestJson -Request $request
                foreach ($property in @('SetupCode', 'Username', 'Password', 'PasswordConfirmation')) {
                    if (-not $body.Contains($property)) {
                        throw [ArgumentException]::new("$property is required.")
                    }
                }
                $providedToken = [System.Text.Encoding]::UTF8.GetBytes([string]$body.SetupCode)
                $expectedToken = [System.Text.Encoding]::UTF8.GetBytes([string]$script:SetupToken)
                $setupCodeValid = [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                    $providedToken, $expectedToken
                )
                [Array]::Clear($providedToken, 0, $providedToken.Length)
                [Array]::Clear($expectedToken, 0, $expectedToken.Length)
                if (-not $setupCodeValid) {
                    $attempts += [DateTime]::UtcNow
                    $script:SetupAttempts[$address] = $attempts
                    $body.Password = ''
                    $body.PasswordConfirmation = ''
                    Write-WebAuditRecord -Action 'Initial administrator setup code rejected' -Outcome 'Denied' `
                        -Details @{ RemainingAttempts = [Math]::Max(0, 5 - $attempts.Count) }
                    Start-Sleep -Milliseconds 350
                    Send-WebJson -Response $response -StatusCode 401 -Value @{ error = 'The one-time setup code is invalid.' }
                    continue
                }
                if (-not [string]::Equals([string]$body.Password, [string]$body.PasswordConfirmation, [StringComparison]::Ordinal)) {
                    $body.Password = ''
                    $body.PasswordConfirmation = ''
                    Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'The passwords do not match.' }
                    continue
                }
                $username = ([string]$body.Username).Trim()
                $password = [string]$body.Password
                $securePassword = $null
                $record = $null
                $body.Password = ''
                $body.PasswordConfirmation = ''
                try {
                    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
                    $record = New-MigrationWebPasswordRecord -Username $username -Password $securePassword
                    Save-MigrationWebAuthRecord -Record $record -Path $fullAuthPath `
                        -PortableMode:$script:PortableMode -CreateOnly
                }
                finally {
                    $password = ''
                    if ($securePassword) { $securePassword.Dispose() }
                }
                $script:AuthRecord = @{
                    Username = $record.Username
                    Salt = $record.Salt
                    PasswordHash = $record.PasswordHash
                    Iterations = $record.Iterations
                    CreatedUtc = $record.CreatedUtc
                }
                $script:SetupToken = $null
                $script:SetupAttempts.Remove($address)
                $tokenBytes = [byte[]]::new(32)
                [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
                $token = [Convert]::ToBase64String($tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
                $script:Sessions[$token] = @{ Username = [string]$script:AuthRecord.Username; ExpiresUtc = [DateTime]::UtcNow.AddHours(8) }
                Write-WebAuditRecord -Action 'Initial administrator account created' -Actor $script:AuthRecord.Username -Outcome 'Succeeded'
                Set-WebSessionCookie -Response $response -Token $token
                Send-WebJson -Response $response -StatusCode 201 -Value @{
                    authenticated = $true
                    username = [string]$script:AuthRecord.Username
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/login') {
                if ($script:AuthenticationMode -eq 'Windows') {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = 'Application-password login is disabled while Windows authentication is active.'; authMode = 'Windows' }
                    continue
                }
                if ($null -eq $script:AuthRecord) {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = 'Create the first administrator account before signing in.'; setupRequired = $true }
                    continue
                }
                $address = [string]$request.RemoteEndPoint.Address
                $attempts = @($script:LoginAttempts[$address] | Where-Object { $_ -gt [DateTime]::UtcNow.AddMinutes(-10) })
                if ($attempts.Count -ge 5) {
                    $script:LoginAttempts[$address] = $attempts
                    Write-WebAuditRecord -Action 'Login attempt rate limited' -Outcome 'Denied' -Details @{ WindowMinutes = 10 }
                    Send-WebJson -Response $response -StatusCode 429 -Value @{ error = 'Too many login attempts. Try again in 10 minutes.' }
                    continue
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Username') -or -not $body.Contains('Password')) {
                    throw [ArgumentException]::new('Username and Password are required.')
                }
                $valid = Test-MigrationWebPassword -Record $script:AuthRecord -Username ([string]$body.Username) -Password ([string]$body.Password)
                $body.Password = ''
                if (-not $valid) {
                    $attempts += [DateTime]::UtcNow
                    $script:LoginAttempts[$address] = $attempts
                    Write-WebAuditRecord -Action 'Login attempt failed' -Actor ([string]$body.Username) -Outcome 'Failed' -Details @{ RemainingAttempts = [Math]::Max(0, 5 - $attempts.Count) }
                    Start-Sleep -Milliseconds 350
                    Send-WebJson -Response $response -StatusCode 401 -Value @{ error = 'Invalid username or password.' }
                    continue
                }
                $script:LoginAttempts.Remove($address)
                if ($script:Sessions.Count -ge 256) {
                    Send-WebJson -Response $response -StatusCode 429 -Value @{ error = 'The maximum number of active sessions has been reached.' }
                    continue
                }
                $tokenBytes = [byte[]]::new(32)
                [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
                $token = [Convert]::ToBase64String($tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                $script:Sessions[$token] = @{ Username = [string]$script:AuthRecord.Username; ExpiresUtc = [DateTime]::UtcNow.AddHours(8) }
                Write-WebAuditRecord -Action 'User signed in' -Actor ([string]$script:AuthRecord.Username) -Outcome 'Succeeded'
                Set-WebSessionCookie -Response $response -Token $token
                Send-WebJson -Response $response -StatusCode 200 -Value @{ authenticated = $true; username = [string]$script:AuthRecord.Username }
                continue
            }

            $session = if ($script:AuthenticationMode -eq 'Windows') { $windowsSession } else { Get-WebSession -Request $request }
            if (-not $session) {
                Send-WebJson -Response $response -StatusCode 401 -Value @{ error = 'Authentication required.' }
                continue
            }
            if ($script:AuthenticationMode -eq 'Windows' -and $script:AuditedWindowsPrincipals.Add([string]$session.Username)) {
                Write-WebAuditRecord -Action 'Windows authentication observed' -Actor $session.Username -Outcome 'Succeeded'
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/logout') {
                if ($script:AuthenticationMode -eq 'Windows') {
                    Send-WebJson -Response $response -StatusCode 200 -Value @{
                        authenticated = $true
                        username = $session.Username
                        authMode = 'Windows'
                    }
                    continue
                }
                Write-WebAuditRecord -Action 'User signed out' -Actor $session.Username -Outcome 'Succeeded'
                $cookie = $request.Cookies['DbMigrationSession']
                if ($cookie) { $script:Sessions.Remove($cookie.Value) }
                Set-WebSessionCookie -Response $response
                Send-WebJson -Response $response -StatusCode 200 -Value @{ authenticated = $false }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/admin/reset-logs') {
                if ($script:AuthenticationMode -ne 'Application') {
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = 'Log reset with password confirmation is unavailable while Windows authentication is active.' }
                    continue
                }
                $address = [string]$request.RemoteEndPoint.Address
                $attempts = @($script:AdminReauthAttempts[$address] | Where-Object { $_ -gt [DateTime]::UtcNow.AddMinutes(-10) })
                if ($attempts.Count -ge 5) {
                    $script:AdminReauthAttempts[$address] = $attempts
                    Write-WebAuditRecord -Action 'Administrator log reset rate limited' -Actor $session.Username -Outcome 'Denied' -Details @{ WindowMinutes = 10 }
                    Send-WebJson -Response $response -StatusCode 429 -Value @{ error = 'Too many password confirmation attempts. Try again in 10 minutes.' }
                    continue
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Password') -or -not $body.Contains('Confirmation')) {
                    throw [ArgumentException]::new('Password and Confirmation are required.')
                }
                $password = [string]$body.Password
                $validPassword = $false
                try {
                    $validPassword = Test-MigrationWebPassword -Record $script:AuthRecord `
                        -Username $session.Username -Password $password
                }
                finally {
                    $password = ''
                    $body.Password = ''
                }
                if (-not $validPassword) {
                    $attempts += [DateTime]::UtcNow
                    $script:AdminReauthAttempts[$address] = $attempts
                    Write-WebAuditRecord -Action 'Administrator log reset password confirmation failed' `
                        -Actor $session.Username -Outcome 'Denied' -Details @{ RemainingAttempts = [Math]::Max(0, 5 - $attempts.Count) }
                    Start-Sleep -Milliseconds 350
                    Send-WebJson -Response $response -StatusCode 401 -Value @{ error = 'Password confirmation failed.' }
                    continue
                }
                if ([string]$body.Confirmation -cne 'CLEAR') {
                    Write-WebAuditRecord -Action 'Administrator log reset rejected' -Actor $session.Username `
                        -Outcome 'Rejected' -Details @{ Reason = 'ConfirmationPhraseMismatch' }
                    Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'Type CLEAR to confirm the log reset.' }
                    continue
                }
                $migrationLogsPending = $script:RunId -and $script:MigrationCompletionLoggedRunId -ne $script:RunId
                $patchLogsPending = $script:PatchRunId -and $script:PatchCompletionLoggedRunId -ne $script:PatchRunId
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited) -or
                    $migrationLogsPending -or $patchLogsPending) {
                    Write-WebAuditRecord -Action 'Administrator log reset rejected' -Actor $session.Username `
                        -Outcome 'Rejected' -Details @{ Reason = 'OperationInProgress' }
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = 'Logs cannot be reset while a migration or patch operation is running or its completion is still being recorded.' }
                    continue
                }

                $deletedFileCount = Clear-MigrationWebLogs -LogDirectory $script:HostLogDirectory
                Write-WebAuditRecord -Action 'Administrator cleared application logs and audit trail' `
                    -Actor $session.Username -Outcome 'Succeeded' -Details @{
                        DeletedFileCount = $deletedFileCount
                        Preserved = 'Generated migration and patch reports'
                    }
                Write-WebHostLog -Level Warning -Message "Administrator '$($session.Username)' cleared application host, run, and audit logs."
                $script:AdminReauthAttempts.Remove($address)
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    deletedFileCount = $deletedFileCount
                    auditResetRecorded = $true
                    reportsPreserved = $true
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/defaults') {
                $pairs = @(Get-MigrationSourceTargetPairDefaults -SourceTargets @($script:WebConfiguration.SourceTargets) -MaxPairs 3)
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    pairs = $pairs
                    maxPairs = 3
                    options = @{
                        MigrateLogins = [bool]$script:WebConfiguration.MigrateLogins
                        MigrateAgentJobs = [bool]$script:WebConfiguration.MigrateAgentJobs
                        MigrateAgentOperators = [bool]$script:WebConfiguration.MigrateAgentOperators
                        ConfigureLinkedServers = [bool]$script:WebConfiguration.ConfigureLinkedServers
                        RepairOrphanUsers = [bool]$script:WebConfiguration.RepairOrphanUsers
                        UpdateStatistics = [bool]$script:WebConfiguration.UpdateStatistics
                    }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/linked-servers') {
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Source') -or [string]::IsNullOrWhiteSpace([string]$body.Source)) {
                    throw [ArgumentException]::new('Source is required.')
                }
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Linked-server inventory is unavailable while migration or patching is running.')
                }
                $source = ([string]$body.Source).Trim()
                $inventory = @(Invoke-DbaQuery -SqlInstance $source -Database master -EnableException -ErrorAction Stop -Query @'
SELECT
    s.name AS LinkedServer,
    s.provider AS Provider,
    s.product AS Product,
    s.data_source AS DataSource,
    s.catalog AS Catalog,
    COALESCE(ll.local_principal_id, -1) AS LocalPrincipalId,
    COALESCE(ll.LoginMappingCount, 0) AS LinkedLoginMappingCount,
    CASE WHEN ll.local_principal_id = 0 THEN N'*' ELSE COALESCE(SUSER_NAME(ll.local_principal_id), N'') END AS LocalLogin,
    CASE
        WHEN ll.local_principal_id IS NULL THEN 'WithoutSecurityContext'
        WHEN ll.uses_self_credential = 1 THEN 'CurrentSecurityContext'
        WHEN NULLIF(ll.remote_name, N'') IS NOT NULL THEN 'SpecifiedSecurityContext'
        ELSE 'WithoutSecurityContext'
    END AS SecurityMode,
    COALESCE(ll.remote_name, N'') AS RemoteUser
FROM sys.servers AS s
OUTER APPLY (
    SELECT TOP (1)
        linked_login.local_principal_id,
        linked_login.uses_self_credential,
        linked_login.remote_name,
        COUNT(*) OVER () AS LoginMappingCount
    FROM sys.linked_logins AS linked_login
    WHERE linked_login.server_id = s.server_id
    ORDER BY CASE WHEN linked_login.local_principal_id = 0 THEN 0 ELSE 1 END
) AS ll
WHERE s.is_linked = 1
ORDER BY s.name;
'@)
                $definitions = @($inventory | ForEach-Object {
                    @{
                        LinkedServer = [string]$_.LinkedServer
                        Provider = [string]$_.Provider
                        Product = [string]$_.Product
                        DataSource = [string]$_.DataSource
                        Catalog = [string]$_.Catalog
                        LocalPrincipalId = [int]$_.LocalPrincipalId
                        LinkedLoginMappingCount = [int]$_.LinkedLoginMappingCount
                        LocalLogin = [string]$_.LocalLogin
                        SecurityMode = [string]$_.SecurityMode
                        RemoteUser = [string]$_.RemoteUser
                    }
                })
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    Source = $source
                    LinkedServers = $definitions
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/validate-pair') {
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Pair')) {
                    throw [ArgumentException]::new('Pair is required.')
                }
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Pair validation is unavailable while migration or patching is running.')
                }
                $pair = @(ConvertTo-WebPairs -Pairs @($body.Pair))[0]
                $validationConfiguration = $script:WebConfiguration.Clone()
                $validationConfiguration.SourceTargets = @($pair)
                $validation = @(Test-MigrationConfiguration -Configuration $validationConfiguration)
                $failedValidationCount = @($validation | Where-Object Status -eq 'Failed').Count
                Write-WebAuditRecord -Action 'Migration pair validated' -Actor $session.Username `
                    -Outcome $(if ($failedValidationCount -eq 0) { 'Succeeded' } else { 'Failed' }) -Details @{
                        Source = $pair.Source
                        Target = $pair.Target
                        PassedCount = @($validation | Where-Object Status -eq 'Passed').Count
                        FailedCount = $failedValidationCount
                        SkippedCount = @($validation | Where-Object Status -eq 'Skipped').Count
                    }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    source = $pair.Source
                    target = $pair.Target
                    backupPath = $pair.BackupPath
                    validation = $validation
                    passedCount = @($validation | Where-Object Status -eq 'Passed').Count
                    failedCount = @($validation | Where-Object Status -eq 'Failed').Count
                    skippedCount = @($validation | Where-Object Status -eq 'Skipped').Count
                    validatedAt = [DateTime]::UtcNow.ToString('o')
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/readiness-assessment') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Readiness assessment is unavailable while migration or patching is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Pair') -or -not $body.Contains('Databases') -or
                    $body.Databases -isnot [array] -or $body.Databases.Count -lt 1 -or $body.Databases.Count -gt 100) {
                    throw [ArgumentException]::new('Provide a source/target Pair and between 1 and 100 selected database names.')
                }
                $pair = @(ConvertTo-WebPairs -Pairs @($body.Pair))[0]
                $databaseNames = [System.Collections.Generic.List[string]]::new()
                $uniqueDatabaseNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($databaseName in $body.Databases) {
                    if ($databaseName -isnot [string] -or [string]::IsNullOrWhiteSpace($databaseName)) {
                        throw [ArgumentException]::new('Every Databases entry must be a non-empty database name.')
                    }
                    $normalizedDatabaseName = $databaseName.Trim()
                    if ($uniqueDatabaseNames.Add($normalizedDatabaseName)) {
                        $databaseNames.Add($normalizedDatabaseName)
                    }
                }
                $availableDatabases = @(Get-MigrationDatabase -SqlInstance $pair.Source -Configuration $script:WebConfiguration |
                    ForEach-Object { [string]$_.Name })
                $invalidDatabases = @($databaseNames | Where-Object { $_ -notin $availableDatabases })
                if ($invalidDatabases.Count -gt 0) {
                    throw [ArgumentException]::new("Refresh discovery; database(s) not available for assessment on source '$($pair.Source)': $($invalidDatabases -join ', ').")
                }
                $startedAt = [DateTime]::UtcNow
                Write-WebAuditRecord -Action 'Migration readiness assessment requested' -Actor $session.Username `
                    -Outcome 'Requested' -Details @{
                        Source = $pair.Source
                        Target = $pair.Target
                        Databases = $databaseNames.ToArray()
                        DatabaseCount = $databaseNames.Count
                        MigrationMode = $pair.MigrationMode
                    }
                try {
                    $bufferPercent = if ($script:WebConfiguration.Contains('RestoreSpaceBufferPercent')) {
                        [double]$script:WebConfiguration.RestoreSpaceBufferPercent
                    } else { 20 }
                    $assessments = @(Get-MigrationReadinessAssessment -Source $pair.Source -Target $pair.Target `
                        -Databases $databaseNames.ToArray() -MigrationMode $pair.MigrationMode -BufferPercent $bufferPercent)
                }
                catch {
                    Write-WebAuditRecord -Action 'Migration readiness assessment completed' -Actor $session.Username `
                        -Outcome 'Failed' -Details @{
                            Source = $pair.Source
                            Target = $pair.Target
                            DatabaseCount = $databaseNames.Count
                        }
                    throw
                }
                $blockedCount = @($assessments | Where-Object Readiness -eq 'Blocked').Count
                $reviewCount = @($assessments | Where-Object Readiness -eq 'Review required').Count
                Write-WebAuditRecord -Action 'Migration readiness assessment completed' -Actor $session.Username `
                    -Outcome $(if ($blockedCount -gt 0) { 'Failed' } elseif ($reviewCount -gt 0) { 'PartiallyFailed' } else { 'Succeeded' }) -Details @{
                        Source = $pair.Source
                        Target = $pair.Target
                        Databases = $databaseNames.ToArray()
                        DatabaseCount = $databaseNames.Count
                        BlockedCount = $blockedCount
                        ReviewRequiredCount = $reviewCount
                        ElapsedMilliseconds = [int](([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
                    }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    source = $pair.Source
                    target = $pair.Target
                    migrationMode = $pair.MigrationMode
                    assessments = $assessments
                    databaseCount = $assessments.Count
                    blockedCount = $blockedCount
                    reviewRequiredCount = $reviewCount
                    noBlockersCount = @($assessments | Where-Object Readiness -eq 'No blockers detected').Count
                    assessedAt = [DateTime]::UtcNow.ToString('o')
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch/catalog') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Patch catalog refresh is unavailable while a migration or patch operation is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Refresh') -or $body.Refresh -isnot [bool] -or
                    -not $body.Contains('Targets') -or $body.Targets -isnot [array]) {
                    $received = ($body.Keys | ForEach-Object { "$_=$(if ($null -eq $body[$_]) { 'null' } else { $body[$_].GetType().Name })" }) -join ', '
                    throw [ArgumentException]::new("Refresh and Targets must be provided; Refresh must be a JSON boolean and Targets an array. Received: $received. Reload the page (Ctrl+F5) if this persists.")
                }
                $targets = @(ConvertTo-WebPatchTargets -Selections @($body.Targets))
                $script:PatchCatalog = @(Get-MigrationSqlServerPatchCatalog -Refresh:$body.Refresh)
                $script:PatchCatalogUpdatedAt = [DateTime]::UtcNow.ToString('o')
                $serverBuilds = [System.Collections.Generic.List[object]]::new()
                $levelErrors = [System.Collections.Generic.List[string]]::new()
                foreach ($target in $targets) {
                    try { $serverBuilds.Add((Get-WebServerPatchLevel -Target $target)) }
                    catch { $levelErrors.Add("$($target.SqlInstance): $($_.Exception.Message)") }
                }
                if ($serverBuilds.Count -eq 0 -and $levelErrors.Count -gt 0) {
                    throw [System.InvalidOperationException]::new("Could not read the SQL Server version of any selected instance. $($levelErrors -join ' | ')")
                }
                $relevantCatalog = @(Get-MigrationRelevantPatchCatalog -Catalog $script:PatchCatalog -ServerBuilds $serverBuilds.ToArray())
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    patches = $relevantCatalog
                    catalogCount = $script:PatchCatalog.Count
                    targets = $serverBuilds.ToArray()
                    errors = $levelErrors.ToArray()
                    updatedAt = $script:PatchCatalogUpdatedAt
                    onlineRefresh = [bool]$body.Refresh
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch/levels') {
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Targets') -or $body.Targets -isnot [array]) {
                    throw [ArgumentException]::new('Targets must be provided as an array.')
                }
                $levels = foreach ($target in @(ConvertTo-WebPatchTargets -Selections @($body.Targets))) {
                    try { Get-WebServerPatchLevel -Target $target }
                    catch { @{ SqlInstance = $target.SqlInstance; Role = $target.Role; PairIndex = $target.PairIndex; Error = $_.Exception.Message } }
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{ levels = @($levels) }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch/assess') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Patch assessment is unavailable while a migration or patch operation is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('KB') -or -not $body.Contains('Targets') -or $body.Targets -isnot [array]) {
                    throw [ArgumentException]::new('KB and Targets are required.')
                }
                $kb = [string]$body.KB
                $patch = Get-WebPatchCatalogRecord -KB $kb
                $targets = @(ConvertTo-WebPatchTargets -Selections @($body.Targets))
                $results = @($targets | ForEach-Object {
                    $assessment = Get-MigrationSqlServerPatchAssessment -SqlInstance $_.SqlInstance -KB $kb
                    $assessment | Add-Member -NotePropertyName Role -NotePropertyValue $_.Role -Force
                    $assessment | Add-Member -NotePropertyName PairIndex -NotePropertyValue $_.PairIndex -Force
                    $assessment
                })
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    patch = $patch
                    results = $results
                    eligibleCount = @($results | Where-Object Status -eq 'Eligible').Count
                    alreadyInstalledCount = @($results | Where-Object Status -eq 'AlreadyInstalled').Count
                    blockedCount = @($results | Where-Object { $_.Status -ne 'Eligible' -and $_.Status -ne 'AlreadyInstalled' }).Count
                    assessedAt = [DateTime]::UtcNow.ToString('o')
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/discover-instance') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Individual SQL discovery is unavailable while a migration or patch is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('SqlInstance') -or [string]::IsNullOrWhiteSpace([string]$body.SqlInstance)) {
                    throw [ArgumentException]::new('SqlInstance is required.')
                }
                $sqlInstance = ([string]$body.SqlInstance).Trim()
                $connection = Connect-DbaInstance -SqlInstance $sqlInstance -ErrorAction Stop
                $databases = @(Get-MigrationDatabase -SqlInstance $sqlInstance -Configuration $script:WebConfiguration |
                    Select-Object Name, SizeMB, Compatibility, Status, RecoveryModel)
                Write-WebAuditRecord -Action 'SQL instance discovered' -Actor $session.Username -Outcome 'Succeeded' -Details @{
                    SqlInstance = [string]$connection.SqlInstance
                    DatabaseCount = $databases.Count
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    sqlInstance = [string]$connection.SqlInstance
                    computerName = [string]$connection.ComputerName
                    instanceName = [string]$connection.InstanceName
                    version = [string]$connection.VersionString
                    versionMajor = [int]$connection.VersionMajor
                    databases = $databases
                    discoveredAt = [DateTime]::UtcNow.ToString('o')
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/discover') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Discovery is unavailable while a migration or SQL Server patch is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Pair')) {
                    throw [ArgumentException]::new('Pair is required.')
                }
                $pair = @(ConvertTo-WebPairs -Pairs @($body.Pair))[0]
                Import-Module (Join-Path $PSScriptRoot 'src\DbMigration.Discovery.psm1') -Force
                $discoveryConfiguration = @{
                    SourceTargets = @($pair)
                    ExcludeDatabases = @($script:WebConfiguration.ExcludeDatabases)
                    RestoreSpaceBufferPercent = [double]$script:WebConfiguration.RestoreSpaceBufferPercent
                }
                $results = @(Get-MigrationDiscovery -Configuration $discoveryConfiguration)
                foreach ($result in $results) {
                    $result | Add-Member -NotePropertyName TargetExists -NotePropertyValue (
                        Test-MigrationDatabaseExists -SqlInstance $pair.Target -Database ([string]$result.Database)
                    ) -Force
                }
                Write-WebAuditRecord -Action 'Migration pair discovered' -Actor $session.Username -Outcome 'Succeeded' -Details @{
                    Source = $pair.Source
                    Target = $pair.Target
                    DatabaseCount = $results.Count
                }
                $pairKey = Get-WebPairKey -Pair $pair
                $script:DiscoveryByPair[$pairKey] = @{
                    Pair = $pair
                    Databases = @($results | ForEach-Object {
                        @{
                            Database = [string]$_.Database
                            TargetExists = [bool]$_.TargetExists
                            Overwrite = $false
                        }
                    })
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{ databases = $results }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/disk-usage') {
                if (($script:MigrationProcess -and -not $script:MigrationProcess.HasExited) -or
                    ($script:PatchProcess -and -not $script:PatchProcess.HasExited)) {
                    throw [System.InvalidOperationException]::new('Disk usage checks are unavailable while a migration or patch is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('SqlInstances') -or $null -eq $body.SqlInstances -or $body.SqlInstances -is [string]) {
                    throw [ArgumentException]::new('SqlInstances must be an array of SQL instance names.')
                }
                $sqlInstances = [System.Collections.Generic.List[string]]::new()
                foreach ($entry in $body.SqlInstances) {
                    if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                        throw [ArgumentException]::new('Every SqlInstances entry must be a non-empty string.')
                    }
                    foreach ($instance in ($entry -split ',(?=\s*(?!\d+\s*(?:,|$))\S)')) {
                        $trimmedInstance = $instance.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedInstance)) {
                            $sqlInstances.Add($trimmedInstance)
                        }
                    }
                }
                $seenInstances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $uniqueInstances = @($sqlInstances | Where-Object { $seenInstances.Add($_) })
                if ($uniqueInstances.Count -eq 0) {
                    throw [ArgumentException]::new('Enter at least one SQL instance.')
                }
                if ($uniqueInstances.Count -gt 50) {
                    throw [ArgumentException]::new('Check no more than 50 SQL instances at a time.')
                }
                $results = @($uniqueInstances | ForEach-Object {
                    $sqlInstance = $_
                    try {
                        $disks = @(Get-MigrationDiskUsage -SqlInstance $sqlInstance)
                        @{
                            instance = $sqlInstance
                            computerName = if ($disks.Count -gt 0) { [string]$disks[0].ComputerName } else { $null }
                            succeeded = $true
                            error = $null
                            disks = @($disks | ForEach-Object {
                                @{
                                    volume = $_.Volume
                                    sizeGB = $_.SizeGB
                                    freeGB = $_.FreeGB
                                    usedGB = $_.UsedGB
                                    percentUsed = $_.PercentUsed
                                }
                            })
                        }
                    }
                    catch {
                        Write-WebHostLog -Level Error -Message "Disk usage check failed for '$sqlInstance': $($_.Exception.Message)"
                        @{
                            instance = $sqlInstance
                            computerName = $null
                            succeeded = $false
                            error = $_.Exception.Message
                            disks = @()
                        }
                    }
                })
                Write-WebAuditRecord -Action 'Disk usage checked' -Actor $session.Username `
                    -Outcome $(if (@($results | Where-Object { -not $_.succeeded }).Count -eq 0) { 'Succeeded' } else { 'PartiallyFailed' }) -Details @{
                        SqlInstances = @($uniqueInstances)
                        TargetCount = $results.Count
                        FailureCount = @($results | Where-Object { -not $_.succeeded }).Count
                    }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    results = $results
                    targetCount = $results.Count
                    successCount = @($results | Where-Object succeeded).Count
                    failureCount = @($results | Where-Object { -not $_.succeeded }).Count
                    checkedAt = [DateTime]::UtcNow.ToString('o')
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/live-monitor') {
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('SqlInstances') -or $null -eq $body.SqlInstances -or $body.SqlInstances -is [string]) {
                    throw [ArgumentException]::new('SqlInstances must be an array of SQL instance names.')
                }
                $sqlInstances = [System.Collections.Generic.List[string]]::new()
                foreach ($entry in $body.SqlInstances) {
                    if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                        throw [ArgumentException]::new('Every SqlInstances entry must be a non-empty string.')
                    }
                    $instance = $entry.Trim()
                    if ($instance.Length -gt 256 -or $instance -match '[\r\n]') {
                        throw [ArgumentException]::new('Every SQL instance name must be a single line of no more than 256 characters.')
                    }
                    $sqlInstances.Add($instance)
                }
                $seenInstances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $uniqueInstances = @($sqlInstances | Where-Object { $seenInstances.Add($_) })
                if ($uniqueInstances.Count -eq 0) {
                    throw [ArgumentException]::new('Select at least one SQL instance to monitor.')
                }
                if ($uniqueInstances.Count -gt 10) {
                    throw [ArgumentException]::new('Monitor no more than 10 SQL instances at a time.')
                }

                $performanceQuery = @'
SELECT
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(32)) AS ProductVersion,
    (
        SELECT TOP (1)
            record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')
        FROM (
            SELECT [timestamp], CONVERT(xml, [record]) AS record
            FROM sys.dm_os_ring_buffers
            WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                AND [record] LIKE N'%<SystemHealth>%'
        ) AS ringBuffer
        ORDER BY [timestamp] DESC
    ) AS SqlCpuPercent,
    (
        SELECT TOP (1)
            100 - record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')
        FROM (
            SELECT [timestamp], CONVERT(xml, [record]) AS record
            FROM sys.dm_os_ring_buffers
            WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                AND [record] LIKE N'%<SystemHealth>%'
        ) AS ringBuffer
        ORDER BY [timestamp] DESC
    ) AS HostCpuPercent,
    (SELECT physical_memory_in_use_kb / 1024 FROM sys.dm_os_process_memory) AS SqlMemoryMB,
    (SELECT memory_utilization_percentage FROM sys.dm_os_process_memory) AS SqlMemoryUtilizationPercent,
    (SELECT total_physical_memory_kb FROM sys.dm_os_sys_memory) AS TotalPhysicalMemoryKB,
    (SELECT available_physical_memory_kb FROM sys.dm_os_sys_memory) AS AvailablePhysicalMemoryKB,
    (
        SELECT TOP (1) cntr_value
        FROM sys.dm_os_performance_counters
        WHERE counter_name = N'Page life expectancy'
            AND object_name LIKE N'%Buffer Manager'
    ) AS PageLifeExpectancySeconds,
    (
        SELECT TOP (1) cntr_value
        FROM sys.dm_os_performance_counters
        WHERE counter_name = N'Memory Grants Pending'
            AND object_name LIKE N'%Memory Manager'
    ) AS PendingMemoryGrants,
    (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1) AS UserSessions,
    (SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id <> @@SPID) AS ActiveRequests,
    (SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id > 0) AS BlockedRequests;
'@
                $requestsQuery = @'
SELECT TOP (10)
    sessions.session_id AS SessionId,
    COALESCE(requests.status, sessions.status) AS RequestStatus,
    sessions.login_name AS LoginName,
    sessions.host_name AS HostName,
    sessions.program_name AS ProgramName,
    DB_NAME(COALESCE(requests.database_id, sessions.database_id)) AS DatabaseName,
    requests.command AS Command,
    requests.wait_type AS WaitType,
    requests.wait_time AS WaitTimeMs,
    requests.wait_resource AS WaitResource,
    requests.blocking_session_id AS BlockingSessionId,
    COALESCE(requests.cpu_time, sessions.cpu_time) AS CpuTimeMs,
    COALESCE(requests.total_elapsed_time, 0) AS ElapsedTimeMs,
    COALESCE(requests.logical_reads + requests.reads + requests.writes, sessions.reads + sessions.writes) AS DiskIo,
    sessions.last_request_start_time AS LastRequestStartTime
FROM sys.dm_exec_sessions AS sessions
LEFT JOIN sys.dm_exec_requests AS requests
    ON requests.session_id = sessions.session_id
WHERE sessions.is_user_process = 1
    AND sessions.session_id <> @@SPID
ORDER BY
    CASE WHEN requests.blocking_session_id > 0 THEN 0 ELSE 1 END,
    requests.cpu_time DESC,
    sessions.cpu_time DESC,
    sessions.last_request_start_time DESC;
'@
                $diskQuery = @'
SELECT
    volumes.volume_mount_point AS Volume,
    CONVERT(decimal(19, 2), MAX(volumes.total_bytes) / 1073741824.0) AS SizeGB,
    CONVERT(decimal(19, 2), MAX(volumes.available_bytes) / 1073741824.0) AS FreeGB,
    CONVERT(decimal(5, 1), (1.0 - MAX(volumes.available_bytes) * 1.0 / NULLIF(MAX(volumes.total_bytes), 0)) * 100) AS PercentUsed,
    SUM(io.num_of_reads) AS NumReads,
    SUM(io.io_stall_read_ms) AS ReadStallMs,
    SUM(io.num_of_writes) AS NumWrites,
    SUM(io.io_stall_write_ms) AS WriteStallMs
FROM sys.master_files AS files
CROSS APPLY sys.dm_os_volume_stats(files.database_id, files.file_id) AS volumes
CROSS APPLY sys.dm_io_virtual_file_stats(files.database_id, files.file_id) AS io
WHERE volumes.volume_mount_point IS NOT NULL
GROUP BY volumes.volume_mount_point
ORDER BY volumes.volume_mount_point;
'@
                $checkedAt = [DateTime]::UtcNow.ToString('o')
                $results = foreach ($sqlInstance in $uniqueInstances) {
                    $result = @{
                        instance = $sqlInstance
                        checkedAt = $checkedAt
                        status = 'Error'
                        productVersion = $null
                        sqlCpuPercent = $null
                        hostCpuPercent = $null
                        sqlMemoryMB = $null
                        sqlMemoryUtilizationPercent = $null
                        systemMemoryUsedPercent = $null
                        pageLifeExpectancySeconds = $null
                        pendingMemoryGrants = $null
                        userSessions = $null
                        activeRequests = $null
                        blockedRequests = $null
                        requests = @()
                        disks = @()
                        error = $null
                        requestError = $null
                        diskError = $null
                    }
                    try {
                        $summaryRows = @(ConvertTo-WebCustomSqlRows -RawRows @(
                            Invoke-DbaQuery -SqlInstance $sqlInstance -Database master -EnableException -ErrorAction Stop -Query $performanceQuery
                        ))
                        if ($summaryRows.Count -eq 0) {
                            throw [System.InvalidOperationException]::new('SQL Server returned no performance data.')
                        }
                        $summary = $summaryRows[0]
                        $result.status = 'Online'
                        $result.productVersion = $summary.ProductVersion
                        $totalPhysicalMemoryKB = [double]$summary.TotalPhysicalMemoryKB
                        $availablePhysicalMemoryKB = [double]$summary.AvailablePhysicalMemoryKB
                        if ($totalPhysicalMemoryKB -gt 0 -and $availablePhysicalMemoryKB -ge 0) {
                            $result.systemMemoryUsedPercent = [math]::Round(
                                (1 - ($availablePhysicalMemoryKB / $totalPhysicalMemoryKB)) * 100, 1
                            )
                        }
                        foreach ($metric in @(
                            'SqlCpuPercent', 'HostCpuPercent', 'SqlMemoryMB', 'SqlMemoryUtilizationPercent',
                            'PageLifeExpectancySeconds', 'PendingMemoryGrants',
                            'UserSessions', 'ActiveRequests', 'BlockedRequests'
                        )) {
                            $value = $summary[$metric]
                            $result[(([char]::ToLowerInvariant($metric[0])) + $metric.Substring(1))] =
                                if ($null -eq $value -or $value -is [System.DBNull]) { $null } else { $value }
                        }
                        try {
                            $requestRows = @(ConvertTo-WebCustomSqlRows -RawRows @(
                                Invoke-DbaQuery -SqlInstance $sqlInstance -Database master -EnableException -ErrorAction Stop -Query $requestsQuery
                            ))
                            $result.requests = @($requestRows | ForEach-Object {
                                @{
                                    sessionId = $_.SessionId
                                    databaseName = $_.DatabaseName
                                    requestStatus = $_.RequestStatus
                                    loginName = $_.LoginName
                                    hostName = $_.HostName
                                    programName = $_.ProgramName
                                    command = $_.Command
                                    waitType = $_.WaitType
                                    waitTimeMs = $_.WaitTimeMs
                                    waitResource = $_.WaitResource
                                    blockingSessionId = if ($null -eq $_.BlockingSessionId -or $_.BlockingSessionId -is [System.DBNull]) { $null } else { $_.BlockingSessionId }
                                    cpuTimeMs = $_.CpuTimeMs
                                    elapsedTimeMs = $_.ElapsedTimeMs
                                    diskIo = $_.DiskIo
                                    lastRequestStartTime = $_.LastRequestStartTime
                                }
                            })
                        }
                        catch {
                            $result.requestError = $_.Exception.Message
                        }

                        try {
                            $diskRows = @(ConvertTo-WebCustomSqlRows -RawRows @(
                                Invoke-DbaQuery -SqlInstance $sqlInstance -Database master -EnableException -ErrorAction Stop -Query $diskQuery
                            ))
                            $result.disks = @($diskRows | ForEach-Object {
                                @{
                                    volume = $_.Volume
                                    sizeGB = $_.SizeGB
                                    freeGB = $_.FreeGB
                                    percentUsed = $_.PercentUsed
                                    numReads = $_.NumReads
                                    readStallMs = $_.ReadStallMs
                                    numWrites = $_.NumWrites
                                    writeStallMs = $_.WriteStallMs
                                }
                            })
                        }
                        catch {
                            $result.diskError = $_.Exception.Message
                        }
                    }
                    catch {
                        $result.error = $_.Exception.Message
                    }
                    $result
                }
                $resultArray = @($results)
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    results = $resultArray
                    targetCount = $resultArray.Count
                    successCount = @($resultArray | Where-Object status -eq 'Online').Count
                    failureCount = @($resultArray | Where-Object status -eq 'Error').Count
                    checkedAt = $checkedAt
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/custom-sql') {
                if ($script:PatchProcess -and -not $script:PatchProcess.HasExited) {
                    throw [System.InvalidOperationException]::new('Custom SQL execution is unavailable while SQL Server patching is running.')
                }
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Query')) {
                    throw [ArgumentException]::new('Query is required.')
                }
                if ($body.Contains('SqlInstances')) {
                    if ($null -eq $body.SqlInstances -or $body.SqlInstances -is [string]) {
                        throw [ArgumentException]::new('SqlInstances must be an array of SQL instance names.')
                    }
                    $sqlInstances = @($body.SqlInstances | ForEach-Object {
                        if ($_ -isnot [string]) {
                            throw [ArgumentException]::new('Every SqlInstances entry must be a string.')
                        }
                        $_
                    })
                    $database = if ($body.Contains('Database') -and -not [string]::IsNullOrWhiteSpace([string]$body.Database)) {
                        [string]$body.Database
                    }
                    else {
                        'master'
                    }
                    $startedAt = [DateTime]::UtcNow
                    Write-WebAuditRecord -Action 'Custom SQL execution requested' -Actor $session.Username -Outcome 'Requested' -Details @{
                        SqlInstances = @($sqlInstances)
                        Database = $database
                        TargetCount = $sqlInstances.Count
                    }
                    try {
                        $batchResults = @(Invoke-MigrationCustomSqlBatch -SqlInstances $sqlInstances -Database $database -Query ([string]$body.Query))
                    }
                    catch {
                        Write-WebAuditRecord -Action 'Custom SQL executed' -Actor $session.Username -Outcome 'Failed' -Details @{
                            SqlInstances = @($sqlInstances)
                            Database = $database
                            TargetCount = $sqlInstances.Count
                        }
                        throw
                    }
                    $failureCount = @($batchResults | Where-Object { -not $_.Succeeded }).Count
                    Write-WebAuditRecord -Action 'Custom SQL executed' -Actor $session.Username -Outcome $(if ($failureCount -eq 0) { 'Succeeded' } else { 'PartiallyFailed' }) -Details @{
                        SqlInstances = @($sqlInstances)
                        Database = $database
                        TargetCount = $sqlInstances.Count
                        FailureCount = $failureCount
                    }
                    $results = @($batchResults | ForEach-Object {
                        if (-not $_.Succeeded) {
                            Write-WebHostLog -Level Error -Message "Custom SQL execution failed on '$($_.SqlInstance)'."
                        }
                        $rows = @(ConvertTo-WebCustomSqlRows -RawRows $_.Rows)
                        $columns = if ($rows.Count -gt 0) { @($rows[0].Keys) } else { @() }
                        @{
                            instance = $_.SqlInstance
                            database = $database
                            succeeded = [bool]$_.Succeeded
                            error = $_.Error
                            rowCount = $rows.Count
                            columns = $columns
                            rows = $rows
                            elapsedMilliseconds = $_.ElapsedMilliseconds
                        }
                    })
                    Send-WebJson -Response $response -StatusCode 200 -Value @{
                        results = $results
                        targetCount = $results.Count
                        successCount = @($results | Where-Object succeeded).Count
                        failureCount = @($results | Where-Object { -not $_.succeeded }).Count
                        elapsedMilliseconds = [int](([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
                    }
                    continue
                }
                $pairIndex = $null
                if ($body.Contains('SqlInstance') -and -not [string]::IsNullOrWhiteSpace([string]$body.SqlInstance)) {
                    $sqlInstance = ([string]$body.SqlInstance).Trim()
                    $role = if ($body.Contains('ServerRole') -and [string]$body.ServerRole -in @('Source', 'Target')) { [string]$body.ServerRole } else { 'Standalone' }
                }
                else {
                    if (-not $body.Contains('PairIndex') -or -not $body.Contains('ServerRole')) {
                        throw [ArgumentException]::new('Provide either SqlInstance or both PairIndex and ServerRole.')
                    }
                    $pairIndex = [int]$body.PairIndex
                    $pair = Get-WebPair -Index $pairIndex
                    $role = [string]$body.ServerRole
                    if ($role -notin @('Source', 'Target')) {
                        throw [ArgumentException]::new("ServerRole must be 'Source' or 'Target'.")
                    }
                    $sqlInstance = if ($role -eq 'Source') { [string]$pair.Source } else { [string]$pair.Target }
                }
                $database = if ($body.Contains('Database') -and -not [string]::IsNullOrWhiteSpace([string]$body.Database)) {
                    [string]$body.Database
                }
                else {
                    'master'
                }
                $query = [string]$body.Query
                $startedAt = [DateTime]::UtcNow
                Write-WebAuditRecord -Action 'Custom SQL execution requested' -Actor $session.Username -Outcome 'Requested' -Details @{
                    SqlInstance = $sqlInstance
                    Database = $database
                    TargetCount = 1
                }
                try {
                    $rawRows = @(Invoke-MigrationCustomSql -SqlInstance $sqlInstance -Database $database -Query $query)
                }
                catch {
                    Write-WebAuditRecord -Action 'Custom SQL executed' -Actor $session.Username -Outcome 'Failed' -Details @{
                        SqlInstance = $sqlInstance
                        Database = $database
                        TargetCount = 1
                    }
                    throw
                }
                Write-WebAuditRecord -Action 'Custom SQL executed' -Actor $session.Username -Outcome 'Succeeded' -Details @{
                    SqlInstance = $sqlInstance
                    Database = $database
                    TargetCount = 1
                }
                $rows = @($rawRows | ForEach-Object {
                    $flat = [ordered]@{}
                    if ($_ -is [System.Data.DataRow]) {
                        foreach ($column in $_.Table.Columns) {
                            $value = $_[$column]
                            $flat[$column.ColumnName] = if ($value -is [System.DBNull]) { $null } else { $value }
                        }
                    }
                    else {
                        foreach ($property in $_.PSObject.Properties) {
                            $flat[$property.Name] = $property.Value
                        }
                    }
                    $flat
                })
                $elapsedMilliseconds = [int](([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
                $columns = @()
                if ($rows.Count -gt 0) {
                    $columns = @($rows[0].Keys)
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    instance = $sqlInstance
                    serverRole = $role
                    database = $database
                    rowCount = $rows.Count
                    columns = $columns
                    rows = @($rows)
                    elapsedMilliseconds = $elapsedMilliseconds
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch/download') {
                $body = Read-WebRequestJson -Request $request
                try {
                    $result = Start-WebSqlServerPatch -Body $body -Action Download -Actor $session.Username
                    Send-WebJson -Response $response -StatusCode 202 -Value $result
                }
                catch [System.InvalidOperationException] {
                    Write-WebAuditRecord -Action 'Patch operation denied' -Actor $session.Username -Outcome 'Denied' `
                        -Details @{ Operation = 'Download'; ErrorType = $_.Exception.GetType().Name }
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/patch') {
                $body = Read-WebRequestJson -Request $request
                try {
                    $result = Start-WebSqlServerPatch -Body $body -Action Apply -Actor $session.Username
                    Send-WebJson -Response $response -StatusCode 202 -Value $result
                }
                catch [System.InvalidOperationException] {
                    Write-WebAuditRecord -Action 'Patch operation denied' -Actor $session.Username -Outcome 'Denied' `
                        -Details @{ Operation = 'Apply'; ErrorType = $_.Exception.GetType().Name }
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/patch/status') {
                Read-WebProcessOutput
                $running = [bool]($script:PatchProcess -and -not $script:PatchProcess.HasExited)
                $exitCode = if ($script:PatchProcess -and $script:PatchProcess.HasExited) { $script:PatchProcess.ExitCode } else { $null }
                if ($null -ne $exitCode -and $script:PatchRunId -and $script:PatchCompletionLoggedRunId -ne $script:PatchRunId) {
                    $status = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
                    Write-WebRunRecord -Operation Patch -RunId $script:PatchRunId -RecordType RunCompleted -Record @{
                        Action = $script:PatchAction
                        KB = $script:PatchKB
                        Targets = @($script:PatchTargets)
                        Status = $status
                        ExitCode = $exitCode
                    }
                    Write-WebAuditRecord -Action "Patch $($script:PatchAction.ToLowerInvariant()) completed" -Actor $script:PatchActor -RunId $script:PatchRunId -Outcome $status -Details @{
                        KB = $script:PatchKB
                        Targets = @($script:PatchTargets)
                        ExitCode = $exitCode
                    }
                    $script:PatchCompletionLoggedRunId = $script:PatchRunId
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    runId = $script:PatchRunId
                    running = $running
                    exitCode = $exitCode
                    action = $script:PatchAction
                    KB = $script:PatchKB
                    targets = @($script:PatchTargets)
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/migrate') {
                $body = Read-WebRequestJson -Request $request
                try {
                    $result = Start-WebMigrationPlan -Body $body -Actor $session.Username
                    Send-WebJson -Response $response -StatusCode 202 -Value $result
                }
                catch [System.InvalidOperationException] {
                    Write-WebAuditRecord -Action 'Migration operation denied' -Actor $session.Username -Outcome 'Denied' `
                        -Details @{ ErrorType = $_.Exception.GetType().Name }
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/control') {
                $body = Read-WebRequestJson -Request $request
                if (-not $body.Contains('Action') -or $body.Action -notin @('Pause', 'Resume', 'Stop')) {
                    Write-WebAuditRecord -Action 'Migration control request rejected' -Actor $session.Username `
                        -Outcome 'Rejected' -Details @{ Reason = 'InvalidAction' }
                    Send-WebJson -Response $response -StatusCode 400 -Value @{ error = 'Action must be Pause, Resume, or Stop.' }
                    continue
                }
                try {
                    $action = Set-WebMigrationControlAction -Action ([string]$body.Action) -Actor $session.Username
                    Send-WebJson -Response $response -StatusCode 200 -Value @{ action = $action }
                }
                catch [System.InvalidOperationException] {
                    Write-WebAuditRecord -Action 'Migration control request denied' -Actor $session.Username `
                        -RunId $script:RunId -Outcome 'Denied' -Details @{
                            Action = [string]$body.Action
                            ErrorType = $_.Exception.GetType().Name
                        }
                    Send-WebJson -Response $response -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/status') {
                Read-WebProgressFiles
                Read-WebProcessOutput
                $running = [bool]($script:MigrationProcess -and -not $script:MigrationProcess.HasExited)
                $exitCode = if ($script:MigrationProcess -and $script:MigrationProcess.HasExited) { $script:MigrationProcess.ExitCode } else { $null }
                if ($null -ne $exitCode -and $script:RunId -and $script:MigrationCompletionLoggedRunId -ne $script:RunId) {
                    $status = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
                    Write-WebRunRecord -Operation Migration -RunId $script:RunId -RecordType RunCompleted -Record @{
                        Status = $status
                        ExitCode = $exitCode
                    }
                    Write-WebAuditRecord -Action 'Migration completed' -Actor $script:MigrationActor -RunId $script:RunId -Outcome $status -Details @{
                        ExitCode = $exitCode
                    }
                    $script:MigrationCompletionLoggedRunId = $script:RunId
                }
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    runId = $script:RunId
                    running = $running
                    exitCode = $exitCode
                    databaseCount = $script:DatabaseJobCount
                    pairs = @($script:MigrationPairs)
                    controlAction = Get-WebMigrationControlAction
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/reporting') {
                $limit = 100
                if ($request.QueryString['limit']) {
                    $parsedLimit = 0
                    if (-not [int]::TryParse($request.QueryString['limit'], [ref]$parsedLimit) -or $parsedLimit -lt 1 -or $parsedLimit -gt 500) {
                        throw [ArgumentException]::new('Reporting limit must be an integer between 1 and 500.')
                    }
                    $limit = $parsedLimit
                }
                $reportDirectory = [string]$script:WebConfiguration.OutputPath
                if (-not [System.IO.Path]::IsPathRooted($reportDirectory)) {
                    $reportDirectory = Join-Path $PSScriptRoot $reportDirectory
                }
                $data = Get-MigrationReportingData -AuditPath $script:AuditLogPath -AuditKeyPath $script:AuditKeyPath `
                    -AuditHeadPath $script:AuditHeadPath `
                    -LogDirectory $script:HostLogDirectory -ReportDirectory $reportDirectory -Limit $limit -OmitAuditRecords
                Send-WebJson -Response $response -StatusCode 200 -Value $data
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/audit') {
                $limit = 500
                if ($request.QueryString['limit']) {
                    $parsedLimit = 0
                    if (-not [int]::TryParse($request.QueryString['limit'], [ref]$parsedLimit) -or $parsedLimit -lt 1 -or $parsedLimit -gt 500) {
                        throw [ArgumentException]::new('Audit limit must be an integer between 1 and 500.')
                    }
                    $limit = $parsedLimit
                }
                $search = [string]$request.QueryString['search']
                $actor = [string]$request.QueryString['actor']
                $category = [string]$request.QueryString['category']
                $severity = [string]$request.QueryString['severity']
                $outcome = [string]$request.QueryString['outcome']
                if ($search.Length -gt 256 -or $actor.Length -gt 256 -or
                    $category.Length -gt 64 -or $severity.Length -gt 64 -or $outcome.Length -gt 64) {
                    throw [ArgumentException]::new('Audit text filters cannot exceed 256 characters; category, severity, and outcome filters cannot exceed 64 characters.')
                }
                $fromUtc = ''
                $toUtc = ''
                foreach ($dateFilter in @(
                    @{ Name = 'from'; Value = [string]$request.QueryString['from']; Destination = 'From' },
                    @{ Name = 'to'; Value = [string]$request.QueryString['to']; Destination = 'To' }
                )) {
                    if ($dateFilter.Value) {
                        $parsedDate = [DateTime]::MinValue
                        if (-not [DateTime]::TryParseExact($dateFilter.Value, 'yyyy-MM-dd',
                            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                            throw [ArgumentException]::new("Audit '$($dateFilter.Name)' date must use YYYY-MM-DD format.")
                        }
                        if ($dateFilter.Destination -eq 'To' -and $parsedDate.Date -eq [DateTime]::MaxValue.Date) {
                            throw [ArgumentException]::new("Audit '$($dateFilter.Name)' date must be before 9999-12-31.")
                        }
                        if ($dateFilter.Destination -eq 'From') { $fromUtc = $parsedDate.ToString('yyyy-MM-ddT00:00:00Z') }
                        else { $toUtc = $parsedDate.AddDays(1).ToString('yyyy-MM-ddT00:00:00Z') }
                    }
                }
                $audit = Get-MigrationAuditLog -Path $script:AuditLogPath -KeyPath $script:AuditKeyPath `
                    -HeadPath $script:AuditHeadPath -Limit $limit `
                    -Search $search -Actor $actor -Category $category `
                    -Severity $severity -Outcome $outcome `
                    -FromUtc $fromUtc -ToUtc $toUtc
                Send-WebJson -Response $response -StatusCode 200 -Value @{
                    Records = @($audit.Records | Sort-Object { [string]$_.Timestamp } -Descending)
                    Integrity = $audit.Integrity
                    MatchingEntries = $audit.MatchingEntries
                    ReturnedEntries = @($audit.Records).Count
                    Limit = $limit
                }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $request.Url.AbsolutePath -eq '/api/events') {
                Read-WebProgressFiles
                Read-WebProcessOutput
                $after = 0
                if ($request.QueryString['after']) { $after = [int]$request.QueryString['after'] }
                $events = @($script:EventBuffer | Where-Object { [int]$_.Id -gt $after })
                Send-WebJson -Response $response -StatusCode 200 -Value @{ events = $events; latestId = $script:NextEventId - 1 }
                continue
            }
            Send-WebJson -Response $response -StatusCode 404 -Value @{ error = 'Not found.' }
        }
        catch {
            $requestFailure = if ($request.Url.AbsolutePath -eq '/api/custom-sql') {
                "Web request failed for $($request.HttpMethod) $($request.Url.AbsolutePath): $($_.Exception.GetType().Name)"
            }
            else {
                "Web request failed for $($request.HttpMethod) $($request.Url.AbsolutePath): $($_.Exception.ToString())"
            }
            Write-WebHostLog -Level Error -Message $requestFailure
            if (-not $response.OutputStream.CanWrite) {
                continue
            }
            $statusCode = if ($_.Exception -is [ArgumentException] -or $_.Exception -is [FormatException]) {
                400
            }
            elseif ($_.Exception -is [System.InvalidOperationException]) {
                409
            }
            else {
                500
            }
            if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -like '/api/*') {
                try {
                    Write-WebAuditRecord -Action "API operation rejected: $($request.Url.AbsolutePath)" `
                        -Actor $(if ($session) { $session.Username } else { '' }) `
                        -Outcome 'Rejected' -Details @{
                            Method = $request.HttpMethod
                            ErrorType = $_.Exception.GetType().Name
                            HttpStatus = $statusCode
                        }
                }
                catch {
                    Write-WebHostLog -Level Critical -Message "Could not audit rejected API request '$($request.Url.AbsolutePath)': $($_.Exception.Message)"
                }
            }
            try {
                Send-WebJson -Response $response -StatusCode $statusCode -Value @{ error = $_.Exception.Message }
            }
            catch {
                Write-WebHostLog -Level Error -Message "Could not send web error response: $($_.Exception.ToString())"
            }
        }
        finally {
            $response.Close()
        }
    }
}
catch {
    Write-WebHostLog -Level Critical -Message "Web host listener stopped unexpectedly: $($_.Exception.ToString())"
    throw
}
finally {
    Write-WebHostLog -Level Information -Message 'Web host is shutting down.'
    $script:Listener.Stop()
    $script:Listener.Close()
    if ($script:HasInstanceLock) {
        $script:InstanceMutex.ReleaseMutex()
        $script:InstanceMutex.Dispose()
    }
    if (-not ($script:MigrationProcess -and -not $script:MigrationProcess.HasExited)) {
        foreach ($path in @($script:RuntimeConfigPath, $script:ProgressPath)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            }
        }
    }
}
