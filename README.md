# MSSQL-Migration-Tool

**Version:** 1.0.0 — see [CHANGELOG.md](CHANGELOG.md) for release history.

A modular PowerShell 7 framework for migrating user databases from SQL Server 2012 through 2025 to the same or a newer SQL Server version. It supports multiple source/target pairs, parallel database backup/restore, resumable execution, discovery and validation, server-level objects, linked servers, post-migration repair/statistics, and CSV/HTML reports.

## Requirements

- PowerShell 7.2 or later and dbatools, required for SQL Server discovery, validation, and migration.
- Pester 5 for tests (`Install-Module Pester -Scope CurrentUser -Force`).
- The browser UI uses built-in HTML, CSS, and JavaScript; it does not require Node.js, npm, a frontend framework, or CDN access.
- Network connectivity from the PowerShell host to SQL Server instances and required backup shares. Migration operations are local/on-prem and do not require internet access; only optional patch-catalog refresh and package download use the internet.
- Backup paths accessible to the SQL Server service accounts on both source and target. Provide an isolated path for each source/target pair.
- Permissions to read source databases, create/restore target databases, copy server objects, repair users, and update statistics.

Authentication uses the current Windows security context/dbatools connection defaults. No passwords are stored in the JSON configuration. Remote linked-server credentials, when needed, are read from the environment variable named by `PasswordEnvironmentVariable` in the CSV.

## Validation and troubleshooting

The project includes a unit-test suite and a PowerShell parser validation path for the migration scripts. Run the tests from the project directory:

```powershell
Invoke-Pester .\tests
```

For first-time setup, run `Setup-DbMigrationTool.cmd`. It installs PowerShell 7.2+ for the current user through winget when missing, then installs dbatools from PowerShell Gallery only if missing. These downloads happen only when a prerequisite is absent; disconnected environments can install both from an approved offline source. The GUI and web host require PowerShell 7.2+.

Validate the environment after setup:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable dbatools
```

If `dbatools` is not available, install it first:

```powershell
Install-Module dbatools -Scope CurrentUser -Force
```

The GUI and CLI both expect SQL connectivity, appropriate permissions, and valid backup paths. If a migration run fails, review the state file and generated reports in the configured output folder before retrying.

## Configure

Edit `config/migration.config.json`:

- `SourceTargets`: one entry per source/target pair; source major versions 11, 13, and 15 are accepted, and targets must be major version 16.
- `BackupPath`: a shared path visible to SQL Server services. Use separate folders per pair to avoid backup-name collisions.
- `ExcludeDatabases`: optional additional database names. `master`, `model`, `msdb`, and `tempdb` are always excluded.
- `ThrottleLimit`: number of databases backed up/restored concurrently.
- `BackupFileCount`: number of striped backup files per database; defaults to 4 (valid range 1–32).
- `RestoreSpaceBufferPercent`: extra free-space buffer required beyond current data/log file allocation before a restore is allowed; defaults to 20%.
- `AllowTargetReplace`: defaults to `false`; command-line replacement must be explicitly enabled. The GUI instead asks Yes/No for each selected database already on the target; answering No skips that database without changing the target.
- `OutputPath`: destination for generated HTML and CSV reports.
- `LinkedServersCsv`: linked-server definition CSV path.

Configure `config/LinkedServers.csv` with one linked server per row. Required columns are `LinkedServer`, `Provider`, `Product`, `DataSource`, and `SecurityMode`. `SecurityMode` must be `NoConnection`, `WithoutSecurityContext`, `CurrentSecurityContext`, or `SpecifiedSecurityContext`. `Catalog`, `RemoteUser`, and `PasswordEnvironmentVariable` are optional. For a remote login, select `SpecifiedSecurityContext`, set `RemoteUser` and the name of an environment variable containing the password; do not put the password itself in the CSV.

## Run

Run the script from the project directory (or provide absolute paths):

```powershell
.\Invoke-DbMigration.ps1 -Mode Discover
.\Invoke-DbMigration.ps1 -Mode Validate
.\Invoke-DbMigration.ps1 -Mode Migrate
```

For an interactive Windows desktop interface, run:

```powershell
.\Invoke-DbMigrationGui.ps1
```

For a network-accessible browser interface, see [Network browser interface](#network-browser-interface). It uses HTTPS and a dedicated application login; enter up to three source/target pairs in the browser.

The GUI starts with the first source/target pair from the configuration. Enter or edit the instances and backup path, validate the pair, discover databases, then check the databases and server-level objects to migrate. Pair validation checks connectivity, supported source/target versions, and visibility of the shared backup path from both SQL Server services. Capacity preflight runs during discovery and is repeated before migration. After discovery, **Assess readiness only** checks selected databases without starting a migration and provides downloadable HTML, CSV, and JSON reports. The report covers SQL Server version direction, database state and compatibility level, target-name conflicts, selected feature dependencies (Full-Text Search, FILESTREAM, In-Memory OLTP, FileTables, CDC/replication, and Service Broker), TDE key readiness, target restore capacity, security-sensitive database settings, and candidate references to a limited list of legacy T-SQL constructs in stored modules. This is a local DMA-inspired preflight, not Microsoft DMA and not an exhaustive application-compatibility analysis; code matches are lexical candidates and may be false positives. Application code outside stored modules, dynamic SQL, workloads, agent jobs, and external dependencies still require separate testing. See [Microsoft's DMA retirement notice](https://techcommunity.microsoft.com/blog/MicrosoftDataMigration/announcing-retirement-of-microsoft-data-migration-assistant-dma-tool/4424400) and [Azure Arc migration assessment](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/migration-assessment?view=sql-server-ver17) for current Microsoft guidance. The migration verifies target access and requires post-migration actions and backup cleanup to succeed before marking a database complete. It writes its normal reports and state file. If a selected database already exists on the target, the GUI asks whether to replace it; Yes authorizes replacement of that database, while No records it as skipped and leaves the target unchanged.

## Network browser interface and portable mode

The browser UI is hosted by `Invoke-DbMigrationWeb.ps1` on Windows PowerShell 7.2 or later. It supports manual hostname, `HOST\INSTANCE`, IP, and shared-backup-path entry; per-pair validation; database discovery; overwrite approval; migration options; and live run monitoring. **Validate pair** checks SQL connectivity, supported source/target versions, and backup-path visibility from both SQL Server services. Discovery adds database inventory and capacity checks. The migration repeats preflight immediately before work, then verifies restored databases, post-migration actions, and temporary-backup cleanup before marking each database complete. Connection settings can be remembered in that browser's local storage; those settings do not alter `config/migration.config.json`.

The T-SQL workspace supports configured pair endpoints, an independently entered instance, or **any number of independently entered SQL instances** that the app host can reach and authenticate to. Multiple-instance mode accepts one server name, `HOST\INSTANCE`, or `HOST,PORT` per line, and runs the same statement sequentially against the selected database on each instance. Results and failures are reported separately per server; a failed connection does not prevent later targets from running. Review the target list and SQL carefully before confirming, especially for changes that cannot be rolled back.

The **Disk usage** workspace checks one or more SQL Server hosts independently of migration pairs and displays used/free capacity for each volume as a graphical utilization bar. It uses the web host's Windows identity to connect to SQL Server and read remote volume inventory through dbatools; that identity needs the appropriate SQL and Windows remote-management permissions. Per-server errors are shown without stopping checks for the other servers.

The separate **Live server monitor** workspace checks up to 10 selected SQL instances, including instances unrelated to migration pairs. It shows SQL/host CPU, system RAM, SQL memory, page life expectancy, pending memory grants, user sessions, active requests, blocking, database-volume capacity, and per-sample storage I/O latency, with rolling CPU/RAM/disk graphs and threshold alerts. Snapshots refresh every 15 seconds and are held only in browser memory for up to 20 samples: they are not written to application logs, audit logs, or disk. When a migration starts, its source and target instances are selected and monitored automatically; automatic monitoring stops when that migration ends. The web host identity needs SQL connectivity and `VIEW SERVER STATE` (or `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022+) for performance and disk metrics. Each server reports its own query or permission failures.

The live migration monitor reports the current database and source/target pair, job counts (completed, skipped, in progress, pending, and failed), overall job completion, and current-stage percentage when SQL Server provides it. It refreshes the status and events every second.

The web UI includes an interactive patch advisor for configured pairs and individually validated SQL instances. Select one or more endpoints before refreshing the catalog; the KB dropdown is filtered to those servers' SQL major version and servicing branch, plus applicable forward service-pack upgrades. Assess each server's installed build/KB, compatibility, and support lifecycle before downloading or applying. Download uses dbatools `Get-DbaKbUpdate`/`Save-DbaKbUpdate` to retrieve the selected package from Microsoft; it is not installed until Apply is confirmed. Alternatively, stage packages yourself and use the same local repository path. The repository must be accessible to the app host and target Windows server, and the app identity needs remote-administration permissions. SQL services can restart during patching. A Windows host restart is optional and off by default. Clustered SQL Server instances are deliberately rejected; patch them with a cluster-aware process.

Select **Logs & audit** in the top navigation to open the separate reporting view; it is hidden from the main workspace by default. It combines generated migration CSV summaries, source user/login, SQL Agent job, and linked-server inventory counts with migration-stage status, durable patch run summaries, the audit trail, and recent host/run logs. The audit trail records application sign-in outcomes, authorized Windows-authenticated principals observed by the host, Windows group-membership denials, migration/patch launch and lifecycle/control events, validation/discovery outcomes, rejected API operations, and custom SQL request/completion metadata. It records actor, UTC time, action/category/severity/outcome, resource, client address, request ID, and run ID where applicable; passwords and custom SQL text are never recorded. Audit events are HMAC-SHA256 chained, with a signed head checkpoint to detect edits and tail truncation; the integrity key is protected with Windows DPAPI for the current Windows account. The audit view verifies the chain on the server and supports server-side search, actor/category/severity/outcome/date filters, plus audit-only JSON and CSV exports (up to 500 matching newest events per query). CSV export escapes spreadsheet formulas. Pre-existing JSONL entries are shown as legacy and are not retroactively authenticated.

The integrity indicator is not a claim of immutable or regulatory-certified storage: a user able to run the application as its host account can generate valid new events, and a privileged administrator can remove or replace the log, signed head checkpoint, and protected key. A damaged chain, checkpoint, or unavailable key is reported and prevents further audit appends; do not manually edit, truncate, or silently replace the evidence. The Logs & audit workspace provides an intentional, password-confirmed administrator reset that permanently discards the previous host/run/audit log files and starts a new signed audit chain with a reset event; generated migration and patch reports are preserved. Use this destructive operation only when authorized by your retention policy. Keep `Audit.jsonl`, `Audit.jsonl.head`, and `Audit.key` together, restrict the log directory to the dedicated host identity and authorized administrators, maintain protected backups, and forward/periodically archive audit records to a separately administered immutable or write-once system. Audit records include usernames, client IP addresses, server names, database names, and operational metadata; apply your privacy, access, retention, and incident-response policies. Standard-mode audit files are under `%LOCALAPPDATA%\DbMigrationWeb\Logs`; portable mode uses its configured portable log folder. The broader reporting workspace can also export a JSON snapshot.

## Windows install and portable package

For a conventional current-user installation with desktop and Start menu shortcuts, run `Setup-DbMigrationTool.cmd`. It bootstraps PowerShell 7.2+ with winget when needed, then installs dbatools only if it is missing.

To create a clean folder that can be copied to another Windows device, first install PowerShell 7.2+ on the destination (the runtime is not bundled). Build the portable stage:

```powershell
pwsh -NoProfile -File .\installer\Build-Installer.ps1 -StageOnly
```

The staged application is in `installer\obj\staging`. The package root contains `Start-DbMigrationWeb.cmd`, `Start-DbMigrationWeb.ps1`, and `Install-DbMigrationPrerequisites.ps1`; runtime application scripts, modules, web UI, and configuration are grouped under `App\`. Tests, repository metadata, and development documentation are excluded. To make a portable ZIP:

```powershell
New-Item -ItemType Directory -Path .\installer\bin -Force | Out-Null
Compress-Archive -Path .\installer\obj\staging\* -DestinationPath .\installer\bin\DbMigrationTool-Portable.zip -Force
```

Copy the ZIP to a Windows device, extract the complete contents to a writable folder, and run `Start-DbMigrationWeb.cmd`. PowerShell 7.2+ must be installed and discoverable as `pwsh.exe`; the launcher installs dbatools for the current user if it is missing. Internet access is needed only for missing dependencies. The app is not a self-contained EXE and does not bundle PowerShell, dbatools, SQL Server connectivity, or database permissions.

Portable authentication and logs are stored in `App\portable`. For a fresh installation, launch the app and create its first administrator through the browser setup form. Enter the one-time code shown in the PowerShell host console from a browser on that same computer. If you copy a folder after first setup, its authentication record is copied too; reset credentials on the destination with:

```powershell
pwsh -NoProfile -File .\App\Initialize-DbMigrationWebAuth.ps1 -PortableMode -AppRoot .\App
```

The WiX MSI can be built with `pwsh -NoProfile -File .\installer\Build-Installer.ps1`, but remains experimental and is not the recommended distribution path.

The project is validated by an automated Pester suite covering configuration, install/uninstall behavior, portable app storage, prerequisite setup, endpoint validation, patch safeguards, and migration logic. The portable folder/ZIP is suitable for copying between Windows devices, subject to the prerequisites above; the WiX MSI remains experimental.

## Conventional installation

For a first-time current-user setup, launch `Setup-DbMigrationTool.cmd`. If PowerShell 7.2+ is missing, it installs PowerShell through winget; the installer then installs dbatools from PowerShell Gallery only if missing. Internet is needed only to obtain missing prerequisites. The migration itself is on-premises and does not require internet access.

```cmd
Setup-DbMigrationTool.cmd
```

This bootstraps PowerShell 7.2+ via winget if needed, then runs the app installer. The installer installs dbatools at the current-user scope only when it is missing.

Install for the current user when PowerShell 7 is already available:

```powershell
.\Install-DbMigrationWeb.ps1 -CurrentUser
```

Install machine-wide (requires elevation):

```powershell
.\Install-DbMigrationWeb.ps1
```

Use a custom install folder:

```powershell
.\Install-DbMigrationWeb.ps1 -InstallPath 'C:\Tools\DbMigrationTool'
```

To uninstall later:

```powershell
.\Uninstall-DbMigrationWeb.ps1
```

This installer creates a runnable Windows app bundle with shortcuts. It is separate from the clean portable folder/ZIP staged by `installer\Build-Installer.ps1 -StageOnly`.

For a local portable run without machine-level HTTPS registration, use `Start-PortableDbMigrationWeb.ps1`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-PortableDbMigrationWeb.ps1
```

This launches the app on a loopback address such as `http://localhost:9080/` or the next free local port and stores auth and logs in the project folder under `portable\auth` and `portable\logs`. On a fresh installation, create the first administrator in the browser. Enter the random one-time setup code shown in the PowerShell host console from a browser on the host computer; choose the username and a password of at least 14 characters. The setup code is held only in host memory and expires when the host stops. The same first-run setup flow applies to a fresh HTTPS server-hosted installation; complete it locally on the host. Existing `Initialize-DbMigrationWebAuth.ps1` provisioning/reset remains available.

MAC-address registration is not used: browsers cannot reliably read a device's MAC address, and MACs change with network adapters, virtualization, and privacy randomization and can be spoofed. If you need licensing or device activation, use a server-managed activation record tied to a generated installation key or managed device certificate rather than a MAC address.

The web migration plan runs source/target pairs in order and databases within each pair one at a time. Full-data mode runs the regular preflight, including TDE detection and target encryptor verification for encrypted databases, before backup/restore; it then checks restore access, runs enabled post-migration actions, and cleans temporary backups. Full-text indexes and modules that use full-text predicates are also checked before transfer; migrations are blocked before backup or target replacement when the target lacks the SQL Server Full-Text Search feature. A missing or unverifiable target TDE key blocks that database before backup. Source database contents and settings are not modified: the source is read for discovery and a `COPY_ONLY` backup; restores, schema changes, user repair, statistics updates, and server-object copies are applied only to the target. SQL Server records native backup history in the source `msdb`, and backup compression/checksum work can consume source CPU and I/O. The monitor polls SQL Server request progress during backup and restore; this telemetry requires permission to read `sys.dm_exec_requests` (`VIEW SERVER STATE`, or `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022). If that permission is unavailable, the UI reports that percentage telemetry is unavailable and continues showing elapsed-stage heartbeats.

Schema-only mode uses SMO scripting/transfer with data copying disabled, creates a new target database using the source collation and recovery model, and verifies the destination is online with zero user-table rows. It does not copy server-level objects such as linked servers, logins, or Agent jobs, and does not require the shared backup path. If a schema-only target already exists, it is left unchanged unless overwrite is explicitly approved for that database; an approved overwrite drops and recreates that target database, permanently removing its existing data. Review the per-database overwrite list carefully. The web UI skips linked-server configuration by default; select **Configure linked servers (optional)** to opt in and load/review definitions. The next database starts only after its mode-specific checks complete. A reported stage failure stops the sequence. Other server-level objects run after the databases for full-data pairs and before the next pair. Pause takes effect at a safe stage boundary. Stop lets the active database or server-object stage finish safely, then prevents later work from starting. This sequential mode overrides `ThrottleLimit` for browser migration throughput; the command-line workflow is unchanged.

The app requires a DNS name and a currently valid certificate with that name in its DNS SAN, installed in `LocalMachine\My`. Register its HTTPS binding and URL reservation from an elevated PowerShell session:

```powershell
.\Register-DbMigrationWebHttps.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443 `
  -CertificateThumbprint 'CERTIFICATE_THUMBPRINT' `
  -RunAsAccount 'CONTOSO\svc-db-migration'
```

Start the host as the dedicated Windows account. On a fresh application-auth installation, use the one-time setup code printed by the host and complete first administrator setup from a browser on the server itself; then users can sign in remotely over HTTPS. The account is stored as a salted PBKDF2-SHA256 hash in `%ProgramData%\DbMigrationWeb\auth.json`, with access restricted to the host account, SYSTEM, and local administrators. `Initialize-DbMigrationWebAuth.ps1` remains available for command-line provisioning or credential resets:

```powershell
.\Invoke-DbMigrationWeb.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443
```

For on-premises Active Directory sign-in instead, start the HTTPS host with Windows Integrated Authentication and an AD security group:

```powershell
.\Invoke-DbMigrationWeb.ps1 `
  -HostName 'db-migration.contoso.com' `
  -Port 8443 `
  -AuthenticationMode Windows `
  -WindowsAuthGroup 'CONTOSO\DbMigrationUsers'
```

Windows mode uses Negotiate and requires HTTPS, a domain service account, and an HTTP SPN for the host DNS name registered to that account for Kerberos. Configure clients to allow integrated authentication for the site. The app checks AD group membership on each request; SQL and file operations still run as the host account. Per-user SQL credentials require separate Kerberos constrained delegation and are not enabled by this mode.

Open `https://db-migration.contoso.com:8443/` from an authorized client. Restrict inbound firewall access to the intended client network. In either auth mode, SQL connections and file/report access run under the Windows identity hosting the web app, not the browser user's Windows identity. Run the host under a dedicated least-privilege account with only the required SQL and file permissions. Any authenticated application user or member of the configured AD group can operate every configured migration pair. The app enforces same-origin POST requests and does not provide unauthenticated endpoints for migration actions.

Do not stop the web host while a migration is running. It does not offer a cancellation control because terminating a backup or restore mid-operation can leave work requiring investigation. Review the normal migration reports and state file when the run completes.

Modes:

- `Discover`: inventories eligible user databases on each source and writes HTML/CSV reports with database size, source login/linked-server/Agent-job counts, compatibility and recovery settings, data/log file locations, source volume capacity/free space, and target default data/log volume capacity/free space.
- `Validate`: checks connectivity, configured source/target SQL Server versions, and visibility of each backup path from both SQL Server services.
- `Migrate`: runs validation first, then backs up and restores eligible databases in parallel; copies logins except `sa`, copies SQL Agent jobs disabled on the target, and copies operators; creates configured linked servers; repairs orphan users; and runs `sp_updatestats` when enabled.

When using the GUI, the selected database list and object checkboxes limit those migration actions for that run. Existing command-line runs retain their configured behavior.

`MigrationState.json` is created in the project directory by default. A database is skipped on rerun only when the state says `Completed` and the target database is still online and accessible. If the target is missing, the tool reuses a recorded backup when available or takes a new one. Failed work is recorded and is eligible for retry. Override the location with `-StatePath`; override reports destination with `-OutputPath`.

Database migration uses full, copy-only, checksummed, compressed backups, verifies each backup, and stripes it across `BackupFileCount` files. Each source/target migration run writes to a uniquely named folder, with a separate child folder per database so parallel workers cannot read or lock each other's backup stripes. Restore is given only that database's explicit stripe-file list. The run folder is deleted only after database transfer and all enabled migration stages for the pair succeed. If any stage fails, the folder is retained for retry and investigation. On a later successful retry, retained run folders referenced by the selected database state are cleaned up. This cleanup means successful temporary backups are not retained for disaster recovery; configure a separate durable backup/retention process if required.

If a restore finds that a destination data or log file already exists on the target host but is not owned by a database on the target instance, the tool retries with unique destination filenames only when the target database itself does not exist. The pre-existing file is left untouched. Other restore errors, and file conflicts while replacing an existing database, are not retried.

Schema-only transfers also use unique data/log filenames for the newly created database so orphaned files cannot be overwritten. If a schema transfer fails after creating its target database, the incomplete database created by that run is removed; the underlying file names remain unique on the next attempt.

Review the target and backup-path configuration carefully before running migration mode.

Before starting each database transfer, migration compares the source data/log file allocations (plus `RestoreSpaceBufferPercent`) with free space on the target's default data and log volumes. Capacity checks are estimates, not guarantees: concurrent storage use and file growth can reduce available space after preflight. A target database is only recorded as completed after it is visible, online, and accessible. Existing target databases are not replaced by command-line runs unless `AllowTargetReplace` is explicitly enabled.

For production, retain migration reports, state files, and logs according to your organization's retention policy; protect them because they contain server names, database names, paths, and operational details. Test backup restoration and application behavior in a representative non-production environment before production cutover. This framework provides operational safeguards but does not by itself certify compliance with any regulatory or industry standard.

## Tests

From the project directory:

```powershell
Invoke-Pester .\tests
```

The tests cover configuration validation, backup stripe settings and per-run folders, state persistence/resume data, migration state key separation, database exclusions and selection, inaccessible-target handling, discovery/capacity reporting, server-object selection, and post-migration actions. SQL Server integration tests require a separately configured test environment and are not run by this unit test suite.
