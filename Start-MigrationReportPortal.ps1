<#
.SYNOPSIS
    Starts a lightweight read-only web portal where stakeholders can view and download all migration reports.

.DESCRIPTION
    Serves the migration reports folder (Discovery-*, Migration-*, StakeholderReport-*, and any other
    generated reports) plus the program documents in docs\ (tracker, checklist, runbook) over HTTP.

    - HTML reports open inline in the browser (View); every file can be downloaded.
    - The portal is read-only: it never writes to or deletes served files, and only files inside the
      configured reports and docs folders are reachable (path traversal is rejected).
    - No SQL Server connectivity or dbatools module is required.

    Bind to localhost (default) for a single workstation, or to a host name/'+' for network access.
    Non-localhost bindings on Windows require an elevated prompt or a one-time URL ACL, for example:
      netsh http add urlacl url=http://+:8080/ user="DOMAIN\svc-db-migration"
    Restrict access with Windows Firewall rules so only stakeholder machines can reach the port.

.EXAMPLE
    .\Start-MigrationReportPortal.ps1

.EXAMPLE
    .\Start-MigrationReportPortal.ps1 -HostName '+' -Port 8080
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config\migration.config.json'),

    [Parameter()]
    [string] $ReportDirectory,

    [Parameter()]
    [string] $DocsDirectory = (Join-Path $PSScriptRoot 'docs'),

    [Parameter()]
    [ValidatePattern('^(\+|\*|localhost|127\.0\.0\.1|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)$')]
    [string] $HostName = 'localhost',

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $Port = 8080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'7.2') {
    throw 'PowerShell 7.2 or later is required.'
}

function ConvertTo-HtmlEscaped {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

# Resolve the reports directory from configuration when not supplied.
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
$script:ReportRoot = [System.IO.Path]::GetFullPath($ReportDirectory)
$script:DocsRoot = [System.IO.Path]::GetFullPath($DocsDirectory)
$null = New-Item -ItemType Directory -Path $script:ReportRoot -Force

$contentTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.csv'  = 'text/csv; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.md'   = 'text/markdown; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8'
    '.log'  = 'text/plain; charset=utf-8'
}

function Get-ReportCategory {
    param([string] $Name)
    if ($Name -like 'StakeholderReport-*') { return 'Stakeholder summaries' }
    if ($Name -like 'Migration-*') { return 'Migration runs' }
    if ($Name -like 'Discovery-*') { return 'Discovery reports' }
    if ($Name -like 'Readiness-*' -or $Name -like 'Assessment-*') { return 'Readiness assessments' }
    return 'Other reports'
}

function Resolve-ServedFile {
    # Returns the FileInfo for a leaf file name served from the reports or docs roots, or $null.
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Name -ne [System.IO.Path]::GetFileName($Name)) { return $null }  # reject any path segments
    foreach ($root in @($script:ReportRoot, $script:DocsRoot)) {
        $candidate = Join-Path $root $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $resolved = [System.IO.Path]::GetFullPath($candidate)
            if ($resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                return Get-Item -LiteralPath $resolved
            }
        }
    }
    return $null
}

function Get-LatestMigrationSummary {
    $file = Get-ChildItem -LiteralPath $script:ReportRoot -Filter 'Migration-*.csv' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $file) { return $null }
    $rows = @(Import-Csv -LiteralPath $file.FullName)
    $databaseRows = @($rows | Where-Object { $_.Database -and $_.Database -ne '*' -and $_.Stage -in @('DatabaseOutcome', 'Database') })
    if ($databaseRows.Count -eq 0) { $databaseRows = $rows }
    return [pscustomobject]@{
        Name = $file.Name
        Completed = @($databaseRows | Where-Object Status -eq 'Completed').Count
        Failed = @($databaseRows | Where-Object Status -eq 'Failed').Count
        Skipped = @($databaseRows | Where-Object Status -eq 'Skipped').Count
        Total = $databaseRows.Count
    }
}

function Get-TrackerSummary {
    $tracker = Join-Path $script:DocsRoot 'MIGRATION-TRACKER.csv'
    if (-not (Test-Path -LiteralPath $tracker -PathType Leaf)) { return $null }
    $rows = @(Import-Csv -LiteralPath $tracker)
    return [pscustomobject]@{
        Total = $rows.Count
        Completed = @($rows | Where-Object OverallStatus -in @('Completed', 'Complete')).Count
        InProgress = @($rows | Where-Object OverallStatus -in @('InProgress', 'In Progress')).Count
        Failed = @($rows | Where-Object OverallStatus -eq 'Failed').Count
    }
}

function Get-IndexHtml {
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $files = @(Get-ChildItem -LiteralPath $script:ReportRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $contentTypes.ContainsKey($_.Extension.ToLowerInvariant()) } |
        Sort-Object LastWriteTimeUtc -Descending)

    $migrationSummary = Get-LatestMigrationSummary
    $trackerSummary = Get-TrackerSummary

    $summaryCards = @("<div class=""summary-card""><span class=""summary-label"">Reports available</span><strong>$($files.Count)</strong></div>")
    if ($migrationSummary) {
        $summaryCards += "<div class=""summary-card pass""><span class=""summary-label"">Latest run completed</span><strong>$($migrationSummary.Completed)/$($migrationSummary.Total)</strong></div>"
        $summaryCards += "<div class=""summary-card fail""><span class=""summary-label"">Latest run failed</span><strong>$($migrationSummary.Failed)</strong></div>"
    }
    if ($trackerSummary) {
        $pct = if ($trackerSummary.Total -gt 0) { [math]::Round(100.0 * $trackerSummary.Completed / $trackerSummary.Total, 1) } else { 0 }
        $summaryCards += "<div class=""summary-card progress""><span class=""summary-label"">Tracker progress</span><strong>$pct%</strong></div>"
    }

    $sections = [ordered]@{
        'Stakeholder summaries' = @()
        'Migration runs' = @()
        'Discovery reports' = @()
        'Readiness assessments' = @()
        'Other reports' = @()
    }
    foreach ($file in $files) {
        $sections[(Get-ReportCategory -Name $file.Name)] += $file
    }

    $sectionHtml = foreach ($category in $sections.Keys) {
        $categoryFiles = @($sections[$category])
        if ($categoryFiles.Count -eq 0) { continue }
        $rows = foreach ($file in $categoryFiles) {
            $encoded = [System.Web.HttpUtility]::UrlEncode($file.Name)
            $sizeKb = [math]::Max(0.1, [math]::Round($file.Length / 1KB, 1))
            $viewLink = ''
            if ($file.Extension -in @('.html', '.htm')) {
                $viewLink = "<a class=""action view"" href=""/view?name=$encoded"">View</a>"
            }
            "<tr><td>$(ConvertTo-HtmlEscaped $file.Name)</td><td>$($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))</td>" +
            "<td>$sizeKb KB</td><td>$viewLink<a class=""action download"" href=""/download?name=$encoded"">Download</a></td></tr>"
        }
        "<h2>$(ConvertTo-HtmlEscaped $category)</h2><table><thead><tr><th>Report</th><th>Generated</th><th>Size</th><th>Actions</th></tr></thead><tbody>$($rows -join "`n")</tbody></table>"
    }
    if (-not $sectionHtml) {
        $sectionHtml = @('<p class="empty-state">No reports yet. Run discovery or a migration, or generate a stakeholder report.</p>')
    }

    $docRows = foreach ($doc in @(Get-ChildItem -LiteralPath $script:DocsRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $contentTypes.ContainsKey($_.Extension.ToLowerInvariant()) } | Sort-Object Name)) {
        $encoded = [System.Web.HttpUtility]::UrlEncode($doc.Name)
        $sizeKb = [math]::Max(0.1, [math]::Round($doc.Length / 1KB, 1))
        "<tr><td>$(ConvertTo-HtmlEscaped $doc.Name)</td><td>$($doc.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))</td>" +
        "<td>$sizeKb KB</td><td><a class=""action download"" href=""/download?name=$encoded"">Download</a></td></tr>"
    }
    $docsHtml = ''
    if ($docRows) {
        $docsHtml = "<h2>Program documents</h2><table><thead><tr><th>Document</th><th>Updated</th><th>Size</th><th>Actions</th></tr></thead><tbody>$($docRows -join "`n")</tbody></table>"
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="120">
<title>SQL Server Migration - Report Portal</title>
<style>
body { font-family: 'Segoe UI', Tahoma, sans-serif; margin: 2rem; color: #1f2933; background: #f5f7fa; }
h1 { font-size: 1.5rem; margin-bottom: 0.25rem; }
h2 { font-size: 1.1rem; margin-top: 2rem; border-bottom: 2px solid #d9e2ec; padding-bottom: 0.3rem; }
.subtitle { color: #52606d; margin-top: 0; }
.summary-grid { display: flex; flex-wrap: wrap; gap: 1rem; margin: 1.25rem 0; }
.summary-card { background: #fff; border-radius: 8px; padding: 0.9rem 1.4rem; min-width: 120px; box-shadow: 0 1px 3px rgba(15,23,42,.12); text-align: center; }
.summary-card strong { display: block; font-size: 1.6rem; }
.summary-label { font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; color: #52606d; }
.summary-card.pass strong { color: #15803d; } .summary-card.fail strong { color: #b91c1c; } .summary-card.progress strong { color: #1d4ed8; }
table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(15,23,42,.12); border-radius: 8px; overflow: hidden; }
th, td { padding: .55rem .75rem; text-align: left; border-bottom: 1px solid #e4e7eb; font-size: .88rem; }
th { background: #1f2933; color: #fff; font-weight: 600; }
tr:nth-child(even) td { background: #f8fafc; }
.action { display: inline-block; padding: .2rem .7rem; border-radius: 999px; font-size: .78rem; font-weight: 600; text-decoration: none; margin-right: .4rem; }
.action.view { background: #dbeafe; color: #1d4ed8; }
.action.download { background: #dcfce7; color: #15803d; }
.refresh { margin-top: 1rem; }
.refresh a { color: #1d4ed8; text-decoration: none; font-size: .85rem; }
.empty-state { color: #52606d; padding: 1rem; }
.footer { margin-top: 2rem; font-size: .8rem; color: #52606d; }
</style>
</head>
<body>
<h1>SQL Server 2016/2019 &rarr; 2022 Migration &mdash; Report Portal</h1>
<p class="subtitle">All migration reports and program documents. Page auto-refreshes every 2 minutes. Served $generatedAt.</p>
<div class="summary-grid">$($summaryCards -join "`n")</div>
<p class="refresh"><a href="/">&#8635; Refresh now</a></p>
$($sectionHtml -join "`n")
$docsHtml
<p class="footer">Read-only portal. Reports are generated by the migration tool into $(ConvertTo-HtmlEscaped $script:ReportRoot).</p>
</body>
</html>
"@
}

function Write-HttpResponse {
    param(
        [System.Net.HttpListenerContext] $Context,
        [int] $StatusCode,
        [byte[]] $Buffer,
        [string] $ContentType,
        [string] $DownloadName
    )
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    if ($DownloadName) {
        $response.AddHeader('Content-Disposition', "attachment; filename=`"$DownloadName`"")
    }
    $response.ContentLength64 = $Buffer.Length
    $response.OutputStream.Write($Buffer, 0, $Buffer.Length)
    $response.OutputStream.Close()
}

Add-Type -AssemblyName System.Web

$prefix = "http://${HostName}:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
}
catch [System.Net.HttpListenerException] {
    throw "Could not listen on $prefix. For a non-localhost binding, run elevated or add a URL ACL once: netsh http add urlacl url=$prefix user=`"$env:USERDOMAIN\$env:USERNAME`". Original error: $($_.Exception.Message)"
}

Write-Host "Migration report portal listening on $prefix"
Write-Host "Serving reports from $($script:ReportRoot)"
if (Test-Path -LiteralPath $script:DocsRoot -PathType Container) {
    Write-Host "Serving documents from $($script:DocsRoot)"
}
Write-Host 'Press Ctrl+C to stop.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $path = $context.Request.Url.AbsolutePath.TrimEnd('/')
            $name = $context.Request.QueryString['name']
            switch ($path) {
                '' {
                    $html = Get-IndexHtml
                    Write-HttpResponse -Context $context -StatusCode 200 -ContentType 'text/html; charset=utf-8' `
                        -Buffer ([System.Text.Encoding]::UTF8.GetBytes($html))
                }
                { $_ -in @('/view', '/download') } {
                    $file = Resolve-ServedFile -Name $name
                    if (-not $file) {
                        $message = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                        Write-HttpResponse -Context $context -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Buffer $message
                        break
                    }
                    $extension = $file.Extension.ToLowerInvariant()
                    $contentType = $contentTypes[$extension]
                    if (-not $contentType) { $contentType = 'application/octet-stream' }
                    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                    if ($path -eq '/download') {
                        Write-HttpResponse -Context $context -StatusCode 200 -ContentType $contentType -Buffer $bytes -DownloadName $file.Name
                    }
                    else {
                        Write-HttpResponse -Context $context -StatusCode 200 -ContentType $contentType -Buffer $bytes
                    }
                }
                default {
                    $message = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                    Write-HttpResponse -Context $context -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Buffer $message
                }
            }
        }
        catch {
            try {
                $message = [System.Text.Encoding]::UTF8.GetBytes('Internal error')
                Write-HttpResponse -Context $context -StatusCode 500 -ContentType 'text/plain; charset=utf-8' -Buffer $message
            }
            catch { }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
