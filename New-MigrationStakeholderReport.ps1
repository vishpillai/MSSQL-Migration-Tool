<#
.SYNOPSIS
    Generates a stakeholder-facing HTML summary for the SQL Server 2016/2019 to 2022 migration program.

.DESCRIPTION
    Combines the migration tool's own run output (Migration-*.csv and Discovery-*.csv in the
    configured reports folder) with the program tracker (docs/MIGRATION-TRACKER.csv) into a
    single self-contained HTML report that stakeholders can open in a browser.

    The report shows overall progress, per source/target pair status (including logins and
    linked-server migration status), per-database outcomes merged with tracker ownership and
    sign-off, and a per-wave rollup. No SQL Server connectivity or dbatools module is required;
    the script only reads files.

.EXAMPLE
    .\New-MigrationStakeholderReport.ps1

.EXAMPLE
    .\New-MigrationStakeholderReport.ps1 -ReportDirectory .\reports -TrackerPath .\docs\MIGRATION-TRACKER.csv
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config\migration.config.json'),

    [Parameter()]
    [string] $ReportDirectory,

    [Parameter()]
    [string] $TrackerPath = (Join-Path $PSScriptRoot 'docs\MIGRATION-TRACKER.csv'),

    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [ValidateRange(1, 10000)]
    [int] $Limit = 2000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-HtmlEscaped {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-StatusBadgeClass {
    param([string] $Status)
    switch ($Status) {
        'Passed' { 'status-pass' }
        'Completed' { 'status-pass' }
        'Complete' { 'status-pass' }
        'Failed' { 'status-fail' }
        'Blocked' { 'status-fail' }
        'Skipped' { 'status-skip' }
        'In Progress' { 'status-inprogress' }
        'InProgress' { 'status-inprogress' }
        'Started' { 'status-inprogress' }
        'Not Started' { 'status-neutral' }
        default { 'status-neutral' }
    }
}

function Get-PairRag {
    param([int] $Failed, [int] $InProgress, [int] $Completed, [int] $Total)
    if ($Total -eq 0 -or ($Completed -eq 0 -and $InProgress -eq 0 -and $Failed -eq 0)) { return 'Grey' }
    if ($Failed -gt 0) { return 'Red' }
    if ($Completed -eq $Total) { return 'Green' }
    return 'Amber'
}

# Resolve the report directory from configuration when not supplied.
if (-not $ReportDirectory) {
    $ReportDirectory = '.\reports'
    if (Test-Path -LiteralPath $ConfigPath) {
        $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($configuration.OutputPath) {
            $ReportDirectory = [string]$configuration.OutputPath
        }
    }
}
if (-not [System.IO.Path]::IsPathRooted($ReportDirectory)) {
    $ReportDirectory = Join-Path $PSScriptRoot $ReportDirectory
}
if (-not $OutputPath) {
    $OutputPath = $ReportDirectory
}
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot $OutputPath
}
$null = New-Item -ItemType Directory -Path $OutputPath -Force

# --- Collect per-database outcomes from migration run reports (latest row wins) ---
$databaseOutcomes = [ordered]@{}
$pairStages = @{}
if (Test-Path -LiteralPath $ReportDirectory -PathType Container) {
    $migrationFiles = @(Get-ChildItem -LiteralPath $ReportDirectory -Filter 'Migration-*.csv' -File |
        Sort-Object LastWriteTimeUtc | Select-Object -Last $Limit)
    foreach ($file in $migrationFiles) {
        foreach ($row in @(Import-Csv -LiteralPath $file.FullName)) {
            if (-not $row.PSObject.Properties['Stage']) { continue }
            if ($row.Database -and $row.Database -ne '*' -and $row.Stage -in @('DatabaseOutcome', 'Database')) {
                $key = "$($row.Source)|$($row.Target)|$($row.Database)"
                $databaseOutcomes[$key] = $row
            }
            elseif ($row.Stage -in @('ServerObjects', 'LinkedServers') -and $row.Source -and $row.Target) {
                $pairStages["$($row.Source)|$($row.Target)|$($row.Stage)"] = $row
            }
        }
    }
}

# --- Collect latest discovery inventory counts per pair ---
$pairInventory = @{}
if (Test-Path -LiteralPath $ReportDirectory -PathType Container) {
    $discoveryFiles = @(Get-ChildItem -LiteralPath $ReportDirectory -Filter 'Discovery-*.csv' -File |
        Sort-Object LastWriteTimeUtc | Select-Object -Last $Limit)
    foreach ($file in $discoveryFiles) {
        foreach ($row in @(Import-Csv -LiteralPath $file.FullName)) {
            if ($row.Source -and $row.Target) {
                $pairInventory["$($row.Source)|$($row.Target)"] = $row
            }
        }
    }
}

# --- Load the program tracker ---
$trackerRows = @()
if (Test-Path -LiteralPath $TrackerPath -PathType Leaf) {
    $trackerRows = @(Import-Csv -LiteralPath $TrackerPath)
}

# --- Merge tool outcomes with tracker rows into one per-database view ---
$merged = [ordered]@{}
foreach ($row in $trackerRows) {
    $key = "$($row.SourceInstance)|$($row.TargetInstance)|$($row.Database)"
    $merged[$key] = [pscustomobject]@{
        Wave = $row.Wave
        Source = $row.SourceInstance
        Target = $row.TargetInstance
        Database = $row.Database
        Status = if ($row.OverallStatus) { $row.OverallStatus } else { 'Not Started' }
        Message = ''
        Owner = $row.ApplicationOwner
        PlannedDate = $row.PlannedDate
        CutoverDate = $row.CutoverDate
        SignOff = $row.UATSignOff
        RAG = $row.RAG
        Notes = $row.Notes
    }
}
foreach ($key in $databaseOutcomes.Keys) {
    $outcome = $databaseOutcomes[$key]
    if ($merged.Contains($key)) {
        $entry = $merged[$key]
        $entry.Status = [string]$outcome.Status
        $entry.Message = [string]$outcome.Message
    }
    else {
        $merged[$key] = [pscustomobject]@{
            Wave = ''
            Source = $outcome.Source
            Target = $outcome.Target
            Database = $outcome.Database
            Status = [string]$outcome.Status
            Message = [string]$outcome.Message
            Owner = ''
            PlannedDate = ''
            CutoverDate = ''
            SignOff = ''
            RAG = ''
            Notes = ''
        }
    }
}

$allDatabases = @($merged.Values)
$totalCount = $allDatabases.Count
$completedCount = @($allDatabases | Where-Object Status -in @('Completed', 'Complete')).Count
$failedCount = @($allDatabases | Where-Object Status -eq 'Failed').Count
$skippedCount = @($allDatabases | Where-Object Status -eq 'Skipped').Count
$inProgressCount = @($allDatabases | Where-Object Status -in @('InProgress', 'Started', 'In Progress')).Count
$notStartedCount = $totalCount - $completedCount - $failedCount - $skippedCount - $inProgressCount
$percentComplete = if ($totalCount -gt 0) { [math]::Round(100.0 * $completedCount / $totalCount, 1) } else { 0 }

# --- Per-pair rollup ---
$pairKeys = @($allDatabases | Group-Object { "$($_.Source)|$($_.Target)" } | ForEach-Object { $_.Name })
$pairRows = foreach ($pairKey in $pairKeys) {
    $source, $target = $pairKey -split '\|', 2
    $pairDatabases = @($allDatabases | Where-Object { $_.Source -eq $source -and $_.Target -eq $target })
    $pairCompleted = @($pairDatabases | Where-Object Status -in @('Completed', 'Complete')).Count
    $pairFailed = @($pairDatabases | Where-Object Status -eq 'Failed').Count
    $pairInProgress = @($pairDatabases | Where-Object Status -in @('InProgress', 'Started', 'In Progress')).Count
    $inventory = $pairInventory[$pairKey]
    $loginStage = $pairStages["$pairKey|ServerObjects"]
    $linkedStage = $pairStages["$pairKey|LinkedServers"]
    [pscustomobject]@{
        Source = $source
        Target = $target
        Databases = $pairDatabases.Count
        Completed = $pairCompleted
        Failed = $pairFailed
        InProgress = $pairInProgress
        Logins = if ($inventory -and $inventory.SourceLoginCount) { $inventory.SourceLoginCount } else { '-' }
        LoginStatus = if ($loginStage) { [string]$loginStage.Status } else { 'Not run' }
        LinkedServers = if ($inventory -and $inventory.SourceLinkedServerCount) { $inventory.SourceLinkedServerCount } else { '-' }
        LinkedServerStatus = if ($linkedStage) { [string]$linkedStage.Status } else { 'Not run' }
        AgentJobs = if ($inventory -and $inventory.SourceAgentJobCount) { $inventory.SourceAgentJobCount } else { '-' }
        RAG = Get-PairRag -Failed $pairFailed -InProgress $pairInProgress -Completed $pairCompleted -Total $pairDatabases.Count
    }
}

# --- Per-wave rollup from the tracker ---
$waveRows = foreach ($waveGroup in ($trackerRows | Group-Object Wave | Sort-Object Name)) {
    $waveDatabases = @($waveGroup.Group)
    $waveComplete = @($waveDatabases | Where-Object OverallStatus -in @('Completed', 'Complete')).Count
    $waveFailed = @($waveDatabases | Where-Object OverallStatus -eq 'Failed').Count
    $waveInProgress = @($waveDatabases | Where-Object OverallStatus -in @('InProgress', 'In Progress')).Count
    [pscustomobject]@{
        Wave = $waveGroup.Name
        Databases = $waveDatabases.Count
        Completed = $waveComplete
        Failed = $waveFailed
        InProgress = $waveInProgress
        NotStarted = $waveDatabases.Count - $waveComplete - $waveFailed - $waveInProgress
        RAG = Get-PairRag -Failed $waveFailed -InProgress $waveInProgress -Completed $waveComplete -Total $waveDatabases.Count
    }
}

$generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

# --- Build HTML ---
$pairTableRows = foreach ($pair in $pairRows) {
    $ragClass = "rag-$($pair.RAG.ToLowerInvariant())"
    $loginBadge = Get-StatusBadgeClass -Status $pair.LoginStatus
    $linkedBadge = Get-StatusBadgeClass -Status $pair.LinkedServerStatus
    "<tr><td>$(ConvertTo-HtmlEscaped $pair.Source)</td><td>$(ConvertTo-HtmlEscaped $pair.Target)</td>" +
    "<td>$($pair.Databases)</td><td>$($pair.Completed)</td><td>$($pair.Failed)</td><td>$($pair.InProgress)</td>" +
    "<td>$($pair.Logins)</td><td><span class=`"status-badge $loginBadge`">$(ConvertTo-HtmlEscaped $pair.LoginStatus)</span></td>" +
    "<td>$($pair.LinkedServers)</td><td><span class=`"status-badge $linkedBadge`">$(ConvertTo-HtmlEscaped $pair.LinkedServerStatus)</span></td>" +
    "<td>$($pair.AgentJobs)</td><td><span class=`"rag-dot $ragClass`"></span>$($pair.RAG)</td></tr>"
}
if (-not $pairTableRows) {
    $pairTableRows = @('<tr><td colspan="12" class="empty-state">No migration pairs found yet. Run discovery or a migration, or fill in the tracker.</td></tr>')
}

$databaseTableRows = foreach ($database in ($allDatabases | Sort-Object Source, Database)) {
    $badge = Get-StatusBadgeClass -Status ([string]$database.Status)
    "<tr><td>$(ConvertTo-HtmlEscaped $database.Wave)</td><td>$(ConvertTo-HtmlEscaped $database.Source)</td>" +
    "<td>$(ConvertTo-HtmlEscaped $database.Target)</td><td>$(ConvertTo-HtmlEscaped $database.Database)</td>" +
    "<td><span class=`"status-badge $badge`">$(ConvertTo-HtmlEscaped $database.Status)</span></td>" +
    "<td>$(ConvertTo-HtmlEscaped $database.Owner)</td><td>$(ConvertTo-HtmlEscaped $database.PlannedDate)</td>" +
    "<td>$(ConvertTo-HtmlEscaped $database.CutoverDate)</td><td>$(ConvertTo-HtmlEscaped $database.SignOff)</td>" +
    "<td>$(ConvertTo-HtmlEscaped $database.RAG)</td><td>$(ConvertTo-HtmlEscaped $database.Message)</td></tr>"
}
if (-not $databaseTableRows) {
    $databaseTableRows = @('<tr><td colspan="11" class="empty-state">No database records yet.</td></tr>')
}

$waveTableRows = foreach ($wave in $waveRows) {
    $ragClass = "rag-$($wave.RAG.ToLowerInvariant())"
    "<tr><td>$(ConvertTo-HtmlEscaped $wave.Wave)</td><td>$($wave.Databases)</td><td>$($wave.Completed)</td>" +
    "<td>$($wave.Failed)</td><td>$($wave.InProgress)</td><td>$($wave.NotStarted)</td>" +
    "<td><span class=`"rag-dot $ragClass`"></span>$($wave.RAG)</td></tr>"
}
if (-not $waveTableRows) {
    $waveTableRows = @('<tr><td colspan="7" class="empty-state">Tracker not started. Fill in docs/MIGRATION-TRACKER.csv to see wave progress.</td></tr>')
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SQL Server Migration - Stakeholder Report</title>
<style>
body { font-family: 'Segoe UI', Tahoma, sans-serif; margin: 2rem; color: #1f2933; background: #f5f7fa; }
h1 { font-size: 1.5rem; margin-bottom: 0.25rem; }
h2 { font-size: 1.1rem; margin-top: 2rem; border-bottom: 2px solid #d9e2ec; padding-bottom: 0.3rem; }
.subtitle { color: #52606d; margin-top: 0; }
.summary-grid { display: flex; flex-wrap: wrap; gap: 1rem; margin: 1.25rem 0; }
.summary-card { background: #fff; border-radius: 8px; padding: 0.9rem 1.4rem; min-width: 120px; box-shadow: 0 1px 3px rgba(15,23,42,.12); text-align: center; }
.summary-card strong { display: block; font-size: 1.6rem; }
.summary-label { font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; color: #52606d; }
.summary-card.pass strong { color: #15803d; } .summary-card.fail strong { color: #b91c1c; }
.summary-card.skip strong { color: #a16207; } .summary-card.progress strong { color: #1d4ed8; }
.progress-wrap { background: #e4e7eb; border-radius: 999px; height: 22px; overflow: hidden; margin: 0.5rem 0 1.5rem; }
.progress-bar { background: #15803d; color: #fff; height: 100%; line-height: 22px; font-size: .8rem; text-align: center; min-width: 2.5rem; }
table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(15,23,42,.12); border-radius: 8px; overflow: hidden; }
th, td { padding: .55rem .75rem; text-align: left; border-bottom: 1px solid #e4e7eb; font-size: .88rem; }
th { background: #1f2933; color: #fff; font-weight: 600; }
tr:nth-child(even) td { background: #f8fafc; }
.status-badge { display: inline-block; padding: .15rem .6rem; border-radius: 999px; font-size: .78rem; font-weight: 600; }
.status-pass { background: #dcfce7; color: #15803d; } .status-fail { background: #fee2e2; color: #b91c1c; }
.status-skip { background: #fef9c3; color: #a16207; } .status-inprogress { background: #dbeafe; color: #1d4ed8; }
.status-neutral { background: #e4e7eb; color: #52606d; }
.rag-dot { display: inline-block; width: 12px; height: 12px; border-radius: 50%; margin-right: .4rem; vertical-align: middle; }
.rag-green { background: #22c55e; } .rag-amber { background: #f59e0b; } .rag-red { background: #ef4444; } .rag-grey { background: #9aa5b1; }
.empty-state { text-align: center; color: #52606d; padding: 1.5rem; }
.footer { margin-top: 2rem; font-size: .8rem; color: #52606d; }
</style>
</head>
<body>
<h1>SQL Server 2016/2019 &rarr; 2022 Migration &mdash; Stakeholder Report</h1>
<p class="subtitle">Generated $generatedAt from migration run reports and the program tracker.</p>

<h2>Overall progress</h2>
<div class="summary-grid">
<div class="summary-card"><span class="summary-label">Databases</span><strong>$totalCount</strong></div>
<div class="summary-card pass"><span class="summary-label">Completed</span><strong>$completedCount</strong></div>
<div class="summary-card progress"><span class="summary-label">In Progress</span><strong>$inProgressCount</strong></div>
<div class="summary-card fail"><span class="summary-label">Failed</span><strong>$failedCount</strong></div>
<div class="summary-card skip"><span class="summary-label">Skipped</span><strong>$skippedCount</strong></div>
<div class="summary-card"><span class="summary-label">Not Started</span><strong>$notStartedCount</strong></div>
</div>
<div class="progress-wrap"><div class="progress-bar" style="width:$percentComplete%">$percentComplete% complete</div></div>

<h2>Source &rarr; target pairs</h2>
<table>
<thead><tr><th>Source</th><th>Target</th><th>DBs</th><th>Done</th><th>Failed</th><th>In Progress</th><th>Logins</th><th>Login Migration</th><th>Linked Servers</th><th>Linked Server Migration</th><th>Agent Jobs</th><th>RAG</th></tr></thead>
<tbody>$($pairTableRows -join "`n")</tbody>
</table>

<h2>Migration waves</h2>
<table>
<thead><tr><th>Wave</th><th>Databases</th><th>Completed</th><th>Failed</th><th>In Progress</th><th>Not Started</th><th>RAG</th></tr></thead>
<tbody>$($waveTableRows -join "`n")</tbody>
</table>

<h2>Database detail</h2>
<table>
<thead><tr><th>Wave</th><th>Source</th><th>Target</th><th>Database</th><th>Status</th><th>App Owner</th><th>Planned</th><th>Cutover</th><th>UAT Sign-off</th><th>RAG</th><th>Latest Message</th></tr></thead>
<tbody>$($databaseTableRows -join "`n")</tbody>
</table>

<p class="footer">Status is merged from the migration tool's run reports (latest run wins) and docs/MIGRATION-TRACKER.csv.
See docs/MIGRATION-CHECKLIST.md for the full phase checklist, including users/logins and linked-server remapping steps for the new environment.</p>
</body>
</html>
"@

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $OutputPath "StakeholderReport-$timestamp.html"
[System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($false))

Write-Host "Stakeholder report written to $reportPath"
return $reportPath
