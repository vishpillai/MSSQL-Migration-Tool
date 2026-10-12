# How to use the SQL migration tool

This guide explains how to run the migration framework in the recommended order and how to verify each step before starting a production migration.

## 1. Prerequisites

Before running the tool, make sure you have:

- Windows operating system
- PowerShell 7.2 or later and dbatools for SQL Server discovery and migration
- Pester installed if you want to run the unit tests
- No separate browser UI packages or Node.js installation are required
- Network access from the migration host to the source and target SQL Server instances
- SQL permissions to:
  - read the source databases
  - inspect TDE metadata and target key metadata (usually requires `VIEW SERVER STATE`, or `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022)
  - create or restore databases on the target
  - copy server-level objects such as logins, jobs, and operators
  - repair orphaned users and update statistics if enabled
- Backup paths visible to the SQL Server service accounts and writable by the migration process

For initial current-user setup, use the bootstrap. It installs PowerShell 7.2+ through winget if missing, then installs dbatools from PowerShell Gallery only if missing:

```cmd
Setup-DbMigrationTool.cmd
```

This bootstrap needs internet access only when a prerequisite is missing. For a disconnected workstation, install PowerShell 7.2+ and dbatools from your approved offline software repository first. Install Pester separately only if you plan to run tests.

Manual module installation:

```powershell
Install-Module dbatools -Scope CurrentUser -Force
Install-Module Pester -Scope CurrentUser -Force
```

## 2. Review the configuration

Open the main configuration file:

```powershell
notepad .\config\migration.config.json
```

Key settings:

- `SourceTargets`: one source/target pair per migration target
- `OutputPath`: folder for generated HTML and CSV reports
- `LinkedServersCsv`: CSV file for linked server definitions
- `ExcludeDatabases`: optional database exclusions
- `ThrottleLimit`: concurrency level for backup/restore operations
- `BackupFileCount`: number of striped files created for each database backup (default 4)
- `RestoreSpaceBufferPercent`: additional target disk headroom required beyond allocated database data/log size; defaults to 20%
- `AllowTargetReplace`: keep `false` for normal operation; the GUI asks individually before replacing any selected target database
- `UpdateStatistics`: enable `sp_updatestats` after migration when needed

Each `SourceTargets` entry should include:

- `Source`: source SQL Server instance name or network address
- `Target`: target SQL Server instance name or network address
- `BackupPath`: network or shared backup directory used by the migration process

Full-data migrations do not change source database contents or settings. The source is read for discovery and a native `COPY_ONLY` backup; restores, user repair, statistics updates, and server-object copies are applied only to the target. SQL Server records native backup history in the source `msdb`. Backup compression and checksumming can consume source CPU and I/O. During browser migrations, live backup/restore percentage, request CPU time, and elapsed time are read from `sys.dm_exec_requests`; this requires `VIEW SERVER STATE` (or `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022). Without that permission, the app reports the telemetry error and continues with elapsed-stage heartbeats.

## 3. Validate the environment

Before running any migration, validate the project and environment:

```powershell
Invoke-Pester .\tests
```

Also check that PowerShell and dbatools are present:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable dbatools
```

## 4. Run the command-line workflow

From the project directory, run the migration workflow in order:

```powershell
.\Invoke-DbMigration.ps1 -Mode Discover
.\Invoke-DbMigration.ps1 -Mode Validate
.\Invoke-DbMigration.ps1 -Mode Migrate
```

What each mode does:

- `Discover`: identifies eligible user databases and writes reports
- `Validate`: checks connectivity, version compatibility, and backup-share visibility from source and target SQL Server services
- `Migrate`: performs the backup/restore workflow, post-migration tasks, and report generation

The migration preflight compares allocated source data/log file sizes plus the configured buffer to free space on the target's default data/log volumes. It checks source TDE status and, for full migrations of encrypted databases, verifies that the target has the matching private-key certificate or asymmetric key before creating a backup. It also checks whether source full-text indexes or dependent modules require Full-Text Search; if so, migration is blocked before backup or target replacement unless that SQL Server feature is installed on the target. If a TDE key is missing or a required feature cannot be verified, that database is blocked before transfer. Discovery displays TDE state and target-key readiness. Schema-only migrations report TDE but do not require the target key because they do not restore an encrypted database backup. These checks do not export or transfer private keys. Capacity remains an estimate, so check for concurrent storage use and expected growth. A database is not marked complete until it is confirmed visible, online, and accessible on the target. The GUI reports live database-stage and server-object events in its progress panel and log, including failures. For each selected database already on the target, the GUI asks whether to overwrite it; choosing No skips that database and leaves the existing target untouched. Command-line replacement still requires explicit `AllowTargetReplace` approval.

Each source/target run writes checksummed, compressed, verified full-copy-only backups, striped across `BackupFileCount` files, into a unique per-run folder with a separate child directory for each database. Restore is given only the selected database's stripe files to prevent parallel restores from scanning or locking other databases' files. The run folder is removed only when every enabled migration stage succeeds. If any step fails, the folder is retained for troubleshooting/retry; after a successful retry, retained run folders referenced by the selected database state are removed. This is temporary migration staging, not a backup-retention strategy—keep separate durable backups if recovery policy requires them.

If a target data or log file already exists on the target host but is not owned by a database on the selected SQL instance, migration retries with unique destination filenames only when the target database does not already exist. The file already on disk is not overwritten. Other restore failures and conflicts during an approved replacement are reported without retry.

Schema-only targets use unique data/log filenames to avoid orphaned-file collisions. If a schema copy fails after creating a new target database, that incomplete database is removed so a later retry is not blocked by a partial target.

## 5. Install or create a portable package

For a conventional current-user installation with shortcuts, start with `Setup-DbMigrationTool.cmd`. It installs PowerShell 7.2+ through winget when missing, then installs dbatools from PowerShell Gallery only if it is missing. The setup downloads are only for missing prerequisites. System-wide installation requires elevation.

To create a clean folder for copying to another Windows device, run this from the repository root:

```powershell
pwsh -NoProfile -File .\installer\Build-Installer.ps1 -StageOnly
```

The output is `installer\obj\staging`. Its root contains:

- `Start-DbMigrationWeb.cmd` — double-click launcher
- `Start-DbMigrationWeb.ps1` — checks PowerShell and ensures dbatools is installed
- `Install-DbMigrationPrerequisites.ps1` — prerequisite setup script
- `App\` — application scripts, PowerShell modules, configuration, web UI, and portable data folders

Development tests, repository metadata, and documentation are not included in the staged runtime. Create a ZIP from the stage with:

```powershell
New-Item -ItemType Directory -Path .\installer\bin -Force | Out-Null
Compress-Archive -Path .\installer\obj\staging\* -DestinationPath .\installer\bin\DbMigrationTool-Portable.zip -Force
```

On the destination Windows device, install PowerShell 7.2+ and make sure `pwsh.exe` is available on `PATH`, then extract the entire ZIP into a writable folder and run `Start-DbMigrationWeb.cmd`. dbatools is installed for the current user on first launch if it is missing. No SQL Server is bundled; the host still needs network access, SQL permissions, and access to any required backup shares. This package is a portable app folder, not a self-contained EXE.

Portable authentication and logs are saved under `App\portable`. On a fresh install, start the app and create the first administrator in the browser setup screen. Enter the one-time setup code printed in the PowerShell host window; for security, initial setup is accepted only from a browser on the host computer. If you copy a folder after first setup, it also copies that installation's authentication record. To replace the credentials on the destination, run this from the extracted package root:

```powershell
pwsh -NoProfile -File .\App\Initialize-DbMigrationWebAuth.ps1 -PortableMode -AppRoot .\App
```

The WiX MSI can be built with `pwsh -NoProfile -File .\installer\Build-Installer.ps1`; it remains experimental. Use `-StageOnly` to regenerate the portable folder without building an MSI.

## 6. Run the GUI

The GUI is intended for interactive execution on a Windows desktop session:

```powershell
.\Invoke-DbMigrationGui.ps1
```

The GUI allows you to:

- enter the source and target SQL instances
- select a backup directory
- discover databases
- choose specific databases to migrate
- enable or disable server-level migration actions
- start the migration with a confirmation prompt

Copied SQL Agent jobs are disabled on the target to prevent them from running before they are reviewed and explicitly enabled by an administrator.

Important: the GUI intentionally uses the first configured source/target pair from the config and runs the same migration logic as the command-line script.

## 7. Run the browser interface

At the application sign-in screen, select **Remember username on this device** to prefill the username on the next visit. This stores only the username in that browser's local storage; it does not store the password or keep the authenticated session alive. Uncheck the option to remove the saved username.

There are two supported browser modes:

- Server-hosted HTTPS mode for network deployment on a Windows migration server.
- Portable local mode for a single workstation or USB-style deployment without admin privileges.

### Portable local mode

For a local, portable run without machine-level HTTPS registration, use the launcher script:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-PortableDbMigrationWeb.ps1
```

This starts the app on a loopback address such as `http://localhost:9080/` or the next available free local port. It stores auth and logs under the project folder (`portable\auth\auth.json` and `portable\logs`). On first launch, create the first administrator in the browser. The host displays a random, single-use setup code in its PowerShell window; enter that code in the browser on the same computer, then choose the username and a password of at least 14 characters. The setup code is not written to application logs and expires when the host stops. Use `Initialize-DbMigrationWebAuth.ps1 -PortableMode` later to reset credentials.

The launcher leaves authentication uninitialized until the GUI setup succeeds. `Initialize-DbMigrationWebAuth.ps1` remains an administrative command-line option for credential provisioning or reset, but fresh installations use the browser setup flow by default.

### Server-hosted HTTPS mode

The browser interface can be used by authorized users on the network while the PowerShell host runs on a Windows migration server. Source, target, and shared backup paths are entered in the browser. Run the following HTTPS setup once with administrative rights, using a DNS name covered by a valid certificate installed in `LocalMachine\My`:

```powershell
.\Register-DbMigrationWebHttps.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443 `
  -CertificateThumbprint 'CERTIFICATE_THUMBPRINT' `
  -RunAsAccount 'CONTOSO\svc-db-migration'
```

For application-password authentication, start the host as the dedicated Windows account:

```powershell
.\Invoke-DbMigrationWeb.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443
```

If no auth record exists, use the one-time setup code printed by the host and complete first administrator setup in a browser on the server itself. Then sign in remotely using HTTPS. The password is stored as a salted PBKDF2 hash with access restricted to the host account, SYSTEM, and local administrators. `Initialize-DbMigrationWebAuth.ps1` remains available for command-line provisioning and credential resets.

The first application account is the installation **Super Admin**. Open **Administration** to create accounts and select feature access: Migration, Patching, Live server monitor, Custom SQL, Disk usage, and Logs & audit. The server enforces those grants on feature API routes, and changing or disabling a user signs out their active sessions. The Super Admin cannot disable or delete itself. Super Admins can also set installation-local white-label text, login copy, Light/Dark/Blue themes, an accent color, and an optional embedded PNG/JPEG logo up to 256 KiB. Existing one-account auth files are upgraded while preserving that account as Super Admin.

To use Active Directory Windows Integrated Authentication instead of the application password, skip `Initialize-DbMigrationWebAuth.ps1` and start the host with an AD group allowlist:

```powershell
.\Invoke-DbMigrationWeb.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443 `
  -AuthenticationMode Windows `
  -WindowsAuthGroup 'CONTOSO\DbMigrationUsers'
```

Windows mode requires HTTPS, a domain service account, and an HTTP SPN for the host DNS name registered to that account for Kerberos. The app authenticates each browser request with Negotiate and authorizes AD group membership. SQL Server and backup-share operations still run under the web-host service account; running SQL as each signed-in user requires separate Kerberos constrained delegation and is not enabled.

For application-password auth, the first-run GUI requires a password of at least 14 characters and stores only salted PBKDF2 hashes. Open `https://db-migration.contoso.com:8443/` from an authorized client after completing the one-time setup locally on the server. Restrict the server firewall to intended client systems. SQL Server, backup-share, reports, and migration state operations use the Windows identity running the host; browser users do not delegate their own Windows credentials. Use a least-privilege host identity. Application users can use only their granted workspaces. Windows-authenticated group members currently receive all workspaces; application user and branding administration is not available in Windows mode.

The browser UI has fields for source SQL instance, target SQL instance, and shared backup directory (use the UNC path visible to both SQL Server service accounts). Enter a hostname, `HOST\INSTANCE`, IP address, and shared path manually. Choose **Validate pair** to check SQL connectivity, supported SQL versions, and whether both SQL Server services can access the shared path. Choose **Discover databases** for pair inventory and capacity preflight. After discovery, select databases and use **Assess readiness only** for a report without starting a migration. It checks source/target version direction, database state and compatibility level, target database-name conflicts, Full-Text Search, FILESTREAM, In-Memory OLTP, FileTables, CDC/replication, Service Broker, selected security settings, TDE key readiness, restore capacity, and candidate references to a limited set of deprecated/legacy T-SQL constructs in stored modules. Download the report as HTML, CSV, or JSON. The feature is inspired by DMA-style readiness checks; it is not Microsoft DMA, does not use DMA's retired assessment rules, and cannot certify application compatibility. Static code matches can be false positives; application code, dynamic SQL, workloads, Agent jobs, and external dependencies need separate review. Microsoft retired DMA on July 16, 2025; see the [DMA retirement notice](https://techcommunity.microsoft.com/blog/MicrosoftDataMigration/announcing-retirement-of-microsoft-data-migration-assistant-dma-tool/4424400) and current [Azure Arc migration assessment documentation](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/migration-assessment?view=sql-server-ver17).

For one-off work without a migration pair, use **Individual SQL instance** in the T-SQL workspace. The account needs the **Custom SQL** feature grant (or **Patching** for standalone patch discovery). The host connects to SQL Server using its own Windows identity; the signed-in app user's password is not used for SQL. Ensure the host identity can reach the server and connect/read database metadata. Connection failures now report the SQL error and record the instance/error type in the audit trail. After discovery, query its selected database or add it as a standalone patch target. Choose **Any SQL instances (multiple)** to enter any reachable SQL Server names one per line or comma-separated, independent of configured pairs. A `host,port` entry remains one server. The same database and statement run sequentially on each server; results and failures are reported per server, and one failure does not stop later targets. Confirm the target list and statement carefully before running. Successful output can be downloaded for one server, selected servers, or all targets in CSV, JSON, TSV, or XML. CSV/TSV combine rows with instance/database/status columns; failed targets are represented in the combined export, and formula-like cells are escaped for spreadsheet safety. JSON/XML retain per-target errors and metadata. Exports are generated in the browser and are not persisted by the host. Validation results are cleared when endpoint values change. Add up to three migration pairs. Select **Remember source, target, and shared backup paths in this browser** to save those connection settings in that browser's local storage; uncheck it to remove the saved settings. This does not write endpoint changes to `config/migration.config.json`.

Use **Disk usage** in the workspace navigation to check one or more SQL Server hosts, independent of configured migration pairs. Enter SQL instances one per line or comma-separated; `host,port` remains one endpoint. The app connects to each SQL instance to resolve its Windows host, then reads volume size and free space through dbatools. Results show used/free GB and a graphical utilization bar per volume, with warning colors at 80% and 90%. Checks continue for other servers if one fails. The web host's Windows identity must have SQL connectivity and permission to read remote disk inventory (including any required Windows remote-management firewall and authorization settings). No credentials are requested or stored by this view.

Discover each pair, select its databases, and review overwrite approvals. The browser workflow runs the pairs sequentially, and each pair's selected databases one at a time. For each database, it runs validation and capacity preflight, performs the backup and restore, verifies target access, runs selected post-migration checks, and deletes that database's temporary backup folder before starting the next database. Server-level objects run after that pair's databases and before the next pair. A failed validation, migration, post-migration action, backup cleanup, or server-object stage stops the sequence; it does not advance to the next database or pair. The command-line and desktop GUI workflows retain their configured concurrency behavior.

The **Live migration monitor** shows the current database and source/target pair, stage-level percentage when SQL Server reports it, and an overall completed-job percentage. Job counts distinguish completed, skipped, in-progress, pending, and failed databases. The monitor refreshes every second; stage percentage is unavailable for work that does not expose SQL Server progress, while job counts still update as database outcomes arrive.

Select **Logs & audit** in the top navigation to open the separate reporting view; it is hidden from the main workspace by default. Review migration CSV summaries, source user/login, SQL Agent job, and linked-server inventory counts alongside their migration-stage status, durable patch summaries, audit events, and recent application/run logs. Counts are read from the latest matching discovery report, so run discovery first for current inventory. Use **Refresh reports** after an operation completes; **Export snapshot (JSON)** downloads the reporting data. The audit view supports server-side free-text, actor, category, severity, outcome, and UTC date filtering; it reports the total match count and returns at most the newest 500 matching events per query. **Export audit (JSON/CSV)** downloads only the current filtered result and includes integrity status; CSV fields are escaped against spreadsheet formula injection.

The application-password account can use **Administrator actions** to permanently reset host, migration/patch activity, and audit logs. The reset requires the current application password and typing `CLEAR`, is rate-limited, and is blocked while a migration or patch operation is running. It removes the previous audit ledger, key, and checkpoint, then records the reset as the first event in a new signed audit chain. Generated migration and patch report files are preserved. Windows-authentication deployments do not expose this action because there is no application password to re-confirm. After updating the app files, fully stop and restart the web host before using the reset; refreshing only the browser does not load the new server-side API route.

Audit events include application sign-in outcomes, authorized Windows-authenticated principals observed by the host, Windows group-membership denials, migration/patch launch and lifecycle/control actions, validation and discovery outcomes, rejected API operations, and custom SQL request/completion metadata. Records include actor, UTC timestamp, action, category, severity, outcome, resource, client address, request ID, and run ID where applicable. Passwords and custom SQL text are never recorded. Events are HMAC-SHA256 chained and a signed head checkpoint detects truncation; the HMAC key is protected by Windows DPAPI for the current Windows account. The server verifies the chain and labels older unchained entries as legacy. A damaged chain/checkpoint or unavailable key is surfaced as an integrity error and blocks further audit appends.

This integrity control is tamper-evident, not immutable: someone able to run the app as its host account can produce valid events, while a privileged administrator can replace the log, checkpoint, and key. Do not manually edit or truncate audit files. The password-confirmed administrator reset described above is an intentional, destructive exception: it permanently discards the previous chain and begins a newly signed chain with the reset event; use it only when authorized by your retention policy. Keep `Audit.jsonl`, `Audit.jsonl.head`, and `Audit.key` together. Restrict the host log directory to the dedicated host identity and authorized administrators, protect backups, and forward/archive records to a separately administered immutable or write-once system. The log contains user names, client IP addresses, server/database names, and operational metadata; follow organizational access, privacy, retention, and incident-response policies. Standard-mode audit files are in `%LOCALAPPDATA%\DbMigrationWeb\Logs`; portable mode uses its configured portable log directory. Keep the audit key with protected backups and restore it under the same Windows account/profile; a different host account may not be able to verify the existing chain.

### Remap linked servers to replacement instances

Linked-server configuration is skipped by default. The browser migration has one opt-in, **Configure linked servers (optional)**; when selected, its highlighted option card opens the mapping controls. Load definitions separately for each source/target pair, then review every row and change **Data source** (and catalog, if needed) to the replacement endpoint. Definitions can also be added manually. Inventory contains linked-server metadata only; SQL Server does not make saved remote passwords recoverable.

For `SpecifiedSecurityContext` (SQL authentication), enter the remote login and its current password for the destination. Passwords are collected only for the current run, are not written to browser storage, plan JSON, reports, or the generated CSV, and are cleared from the form after submission. The host passes them to the migration worker through per-run environment variables. Use HTTPS in server-hosted mode; portable local mode binds to loopback. Use `CurrentSecurityContext` only when the destination supports the Windows identity used by the migration host.

The source inventory reports when it finds multiple or login-specific linked-login mappings. The browser workflow configures one mapping per linked server; review those warnings and recreate any additional per-login mappings separately on the target. A linked server with the same name already present on a target is left unchanged rather than overwritten, so verify the target definition before the run or update it separately. A failed linked-server configuration stops the migration sequence and is reported in the run results.

### Patch selected SQL instances

The local web app provides an interactive SQL Server patch advisor for configured pair endpoints or an individually validated SQL instance. Select the target endpoint(s) before refreshing; the KB dropdown only lists matching SQL major versions and service-pack branches, plus applicable forward service-pack upgrades. Migration and local package installation do not require internet access. Refreshing Microsoft/dbatools build metadata and downloading a selected KB require internet access from the app host; updates are not downloaded automatically.

Expand **Patch selected SQL instances**, select endpoints, and choose **Refresh patch catalog**. Select a listed KB, then choose **Assess eligibility** to review installed build/KB, product and service-pack matching, already-installed or superseded status, and support lifecycle for each instance. Only rows marked eligible can be applied. Enter a repository folder accessible to both the app host and target Windows server, then choose **Download selected KB** or stage the matching Microsoft package there yourself. Downloading does not install the package.

Choose **Apply eligible instances** to patch only the currently assessed eligible rows. Selected instances run sequentially and stop at the first failure. SQL Server services may restart as part of patch installation. Restarting the Windows host is a separate option and is off by default. This workflow rejects clustered SQL Server instances; use a cluster-aware patch procedure for those systems. For remote targets, the app identity needs the remote administration permissions required by dbatools and PowerShell remoting. Do not run a patch during a migration, and schedule a maintenance window before starting.

### Live server monitor

Open **Live server monitor** from the navigation and add one or more SQL hostnames, `HOST\INSTANCE` names, or `HOST,PORT` addresses, or select configured pair endpoints. Select no more than 10 instances and start monitoring for automatic 15-second snapshots. The dashboard graphs SQL/host CPU, system RAM, and disk utilization over the last 20 samples held in browser memory. It also shows SQL memory, page life expectancy, pending memory grants, user sessions, active requests, blocking, data-volume free capacity, per-sample storage I/O latency, and threshold-based pressure alerts. No monitor snapshots are written to application logs, audit logs, or disk. Use **Refresh now** for an immediate snapshot or **Stop monitoring** to end automatic polling. Instance-level connection, query, and permission failures are displayed independently.

When a migration starts, its source and target instances are automatically selected and monitoring starts. Automatic monitoring stops when the migration ends; a manually started monitor continues until stopped. The web host's Windows identity needs SQL connectivity and `VIEW SERVER STATE` for performance and disk metrics; SQL Server 2022 and later may require `VIEW SERVER PERFORMANCE STATE` instead. Grant only the required permissions to the host identity.

The browser UI shows discovery metadata, a full-data/schema-only mode for every pair, per-database overwrite checkboxes and confirmations, migration options, live run and per-step percentages, and Pause, Resume, and Stop controls. Migration and Patching are separate full-screen workspaces selected from the navigation; the live migration monitor appears only in Migration. A selected existing target without explicit overwrite approval is skipped. Schema-only mode scripts database objects without copying table data and does not copy linked servers or other server-level objects. An approved schema-only overwrite drops and recreates the existing target database, deleting its data; review each overwrite decision before starting. Linked-server configuration is skipped by default; select the single **Configure linked servers (optional)** option to opt in and open the per-pair definition mapping controls. Pause takes effect at the next safe stage boundary; Resume continues the run. Stop allows the active database or server-object stage to finish safely before preventing later work. Do not stop the web host while the plan is running.

## 8. Review migration results

After a run completes, check:

- the generated CSV and HTML reports in the configured output folder
- `MigrationState.json` in the project directory or the custom state path
- the log output for warnings or failed database records

The GUI discovery list shows each database's size, and its summary shows source login, linked-server, and Agent-job counts. The discovery report also includes these counts, compatibility level, recovery model and state, data/log file locations and file sizes, source volumes' capacity/free space, and the target server's default data/log paths and corresponding volume capacity/free space. Use the target free-space fields to review capacity before restoring; the report does not guarantee future free space or estimate compression and growth.

The state file is designed to support resumable execution. A database is skipped only when the recorded status is `Completed` and the target database is still online and accessible. If the target copy is missing, the tool attempts to reuse the recorded backup or creates a new backup. Failed work remains eligible for retry.

## 9. Recommended safety checklist

Before each migration:

- confirm the source and target SQL Server instances are correct
- confirm the backup share is writable and accessible by SQL Server service accounts
- review capacity preflight against expected growth, restore staging, and storage use by other applications
- confirm the target database names are expected and safe to replace
- verify `-WithReplace` behavior is acceptable for the target environment
- confirm linked server data is correct in the CSV file
- review any selected server-level object migration options
- validate orphan-user repair and statistics updates are appropriate for the target workload

## 10. Example

Example discovery and validation flow:

```powershell
.\Invoke-DbMigration.ps1 -Mode Discover
.\Invoke-DbMigration.ps1 -Mode Validate
```

Example migrate flow:

```powershell
.\Invoke-DbMigration.ps1 -Mode Migrate -ConfigPath .\config\migration.config.json -StatePath .\MigrationState.json -OutputPath .\reports
```

## 11. Troubleshooting

If a migration fails, check the following:

- is PowerShell 7 installed?
- is dbatools installed and importable?
- can the host reach the source and target SQL instances?
- do the service accounts have permission to write to the backup directory?
- does the target instance have permission to restore the databases?
- are the configured database exclusions correct?
- does the output folder exist and have write permissions?

When needed, fix the configuration and rerun the migration; the framework records progress and supports resume behavior for completed or partially completed work.
