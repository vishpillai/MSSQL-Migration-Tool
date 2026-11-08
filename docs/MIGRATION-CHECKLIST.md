# SQL Server Migration Checklist — 2016/2019 to 2022

Use this checklist for every source/target pair in the migration program. It is organized by phase; each item has an owner and a status. Track per-database and per-instance progress in [MIGRATION-TRACKER.csv](MIGRATION-TRACKER.csv) and generate the stakeholder summary with `New-MigrationStakeholderReport.ps1`.

**Status values:** Not Started | In Progress | Complete | Blocked | N/A

---

## Phase 0 — Governance and planning

| # | Item | Owner | Status |
|---|------|-------|--------|
| 0.1 | Migration scope agreed: list of source instances (SQL 2016/2019) and target SQL 2022 instances documented | | |
| 0.2 | Migration waves/batches defined and scheduled with business owners | | |
| 0.3 | Rollback strategy approved (source remains online and unchanged until sign-off) | | |
| 0.4 | Maintenance window and cutover plan approved by change management (CAB) | | |
| 0.5 | Stakeholder communication plan in place (status cadence, escalation path) | | |
| 0.6 | Success criteria and sign-off authority defined per application/database | | |
| 0.7 | Backup/share storage provisioned (`BackupPath` per pair, isolated folders) | | |
| 0.8 | Migration host prepared: PowerShell 7.2+, dbatools, this tool installed (`Setup-DbMigrationTool.cmd`) | | |

## Phase 1 — Discovery and assessment

| # | Item | Owner | Status |
|---|------|-------|--------|
| 1.1 | Run `Invoke-DbMigration.ps1 -Mode Discover` (or GUI/web discovery) for every pair | | |
| 1.2 | Database inventory captured: names, sizes, compatibility levels, states | | |
| 1.3 | Server-object inventory captured: logins, SQL Agent jobs, linked servers (counts in Discovery report) | | |
| 1.4 | Run **Assess readiness only** preflight; review HTML/CSV/JSON findings | | |
| 1.5 | Feature dependencies reviewed: Full-Text Search, FILESTREAM, In-Memory OLTP, FileTables, CDC/replication, Service Broker | | |
| 1.6 | TDE databases identified; certificate/key backup and target restore plan confirmed | | |
| 1.7 | Legacy T-SQL construct candidates reviewed; false positives dismissed, real findings assigned for remediation | | |
| 1.8 | Target capacity verified (data/log volumes with `RestoreSpaceBufferPercent` headroom) | | |
| 1.9 | Application dependency inventory: connection strings, SSIS packages, SSRS reports, ETL, monitoring, backup jobs referencing source instances | | |
| 1.10 | Databases excluded from scope recorded in `ExcludeDatabases` with reason | | |

## Phase 2 — Pre-migration preparation

### 2A — Users and logins

| # | Item | Owner | Status |
|---|------|-------|--------|
| 2A.1 | Login inventory exported from source (Windows and SQL logins, SIDs, default databases, roles) | | |
| 2A.2 | SQL login passwords: plan confirmed (dbatools `Copy-DbaLogin` migrates SIDs and password hashes; verify application connectivity after) | | |
| 2A.3 | Orphaned-user remediation plan in place (`Repair-DbaDbOrphanUser` runs post-migration; exceptions listed) | | |
| 2A.4 | Server role memberships and server-level permissions documented for recreation/verification | | |
| 2A.5 | Credentials and proxies (SQL Agent) inventoried and planned | | |
| 2A.6 | Service accounts for the new environment requested/created per least-privilege | | |

### 2B — Linked servers (targets change in the new environment)

| # | Item | Owner | Status |
|---|------|-------|--------|
| 2B.1 | Full linked-server inventory exported from each source (provider, data source, catalog, security mode) | | |
| 2B.2 | **New-environment mapping agreed**: every linked server's new `DataSource`/target endpoint documented and approved | | |
| 2B.3 | `config/LinkedServers.csv` updated with the **new** endpoints — one row per linked server; never store passwords in the CSV | | |
| 2B.4 | For `SpecifiedSecurityContext`, remote passwords staged in the environment variables named by `PasswordEnvironmentVariable` | | |
| 2B.5 | Network/firewall rules opened from target SQL 2022 hosts to the new linked-server endpoints (ports per provider) | | |
| 2B.6 | Dependent objects identified: stored procedures, views, jobs, SSIS using four-part names or `OPENQUERY` through each linked server | | |
| 2B.7 | Post-migration linked-server test plan defined (`sp_testlinkedserver` plus a real query per server) | | |

### 2C — Environment and configuration

| # | Item | Owner | Status |
|---|------|-------|--------|
| 2C.1 | `config/migration.config.json` updated per pair (source, target, isolated `BackupPath`) | | |
| 2C.2 | SQL 2022 target build patched to approved CU (use the tool's patch advisor) | | |
| 2C.3 | Target instance configuration reviewed against source: `sp_configure`, max memory, maxdop, tempdb sizing, trace flags | | |
| 2C.4 | Target collation confirmed compatible with source databases | | |
| 2C.5 | SQL Agent jobs, operators, alerts inventoried; in-scope jobs selected for copy | | |
| 2C.6 | Run `Invoke-DbMigration.ps1 -Mode Validate` for every pair; all checks passed | | |
| 2C.7 | Full pre-migration backups of all in-scope source databases taken and verified | | |
| 2C.8 | Monitoring/alerting adjusted for the migration window (suppress false alerts) | | |

## Phase 3 — Migration execution

| # | Item | Owner | Status |
|---|------|-------|--------|
| 3.1 | Applications placed in read-only/quiesced state or downtime window started | | |
| 3.2 | Run `Invoke-DbMigration.ps1 -Mode Migrate` (or GUI/web) for the pair | | |
| 3.3 | Backup/restore completed for every selected database (stage status = Completed) | | |
| 3.4 | Server objects migrated: logins, Agent jobs, operators (stage `ServerObjects`) | | |
| 3.5 | Linked servers created on target from updated CSV (stage `LinkedServers`) | | |
| 3.6 | Post-migration actions completed: orphaned-user repair, statistics update | | |
| 3.7 | Migration report reviewed: zero unexpected Failed/Skipped rows | | |

## Phase 4 — Post-migration validation

| # | Item | Owner | Status |
|---|------|-------|--------|
| 4.1 | Database states on target: all ONLINE, multi-user, correct recovery model | | |
| 4.2 | Row/object counts spot-checked against source per database | | |
| 4.3 | `DBCC CHECKDB` clean on migrated databases (or scheduled within window) | | |
| 4.4 | Login validation: SQL logins authenticate; no orphaned users remain | | |
| 4.5 | **Every linked server tested on the target against its new endpoint** (`sp_testlinkedserver` + sample query) | | |
| 4.6 | SQL Agent jobs enabled, schedules verified, test-run of critical jobs successful | | |
| 4.7 | Compatibility level decision applied per database (keep source level initially; raise to 160 after validation, ideally with Query Store regression capture) | | |
| 4.8 | Statistics updated / full-scan where needed; plans stable | | |
| 4.9 | Security-sensitive settings reviewed (TRUSTWORTHY, cross-db chaining, CLR) — re-enabled only with approval | | |
| 4.10 | Maintenance solution on target confirmed (Ola Hallengren or existing) — backups, integrity checks, index maintenance scheduled | | |

## Phase 5 — Cutover

| # | Item | Owner | Status |
|---|------|-------|--------|
| 5.1 | Application connection strings / DNS CNAMEs / listeners repointed to SQL 2022 targets | | |
| 5.2 | SSIS/SSRS/ETL/monitoring integrations repointed and tested | | |
| 5.3 | Application smoke tests passed per database/application | | |
| 5.4 | Business owner UAT sign-off received | | |
| 5.5 | Source databases set read-only (or taken offline) to freeze changes | | |
| 5.6 | Cutover recorded in tracker; stakeholders notified | | |

## Phase 6 — Rollback (only if required)

| # | Item | Owner | Status |
|---|------|-------|--------|
| 6.1 | Rollback trigger criteria met and decision logged with approver | | |
| 6.2 | Connection strings/DNS repointed back to source | | |
| 6.3 | Source databases confirmed online and current (source was never modified) | | |
| 6.4 | Applications validated against source; incident/problem record raised for the failed attempt | | |

## Phase 7 — Sign-off and decommission

| # | Item | Owner | Status |
|---|------|-------|--------|
| 7.1 | Final stakeholder report generated (`New-MigrationStakeholderReport.ps1`) and circulated | | |
| 7.2 | Formal sign-off recorded per database/application in the tracker | | |
| 7.3 | Source instances kept in read-only for the agreed retention period | | |
| 7.4 | Source decommission plan scheduled (after retention); backups archived per policy | | |
| 7.5 | Lessons-learned / retro completed; checklist updated for the next wave | | |

---

## Standing best practices (apply to every wave)

- Never modify source instances during migration; sources stay available for rollback until sign-off.
- One isolated backup folder per source/target pair to avoid backup-name collisions.
- Keep `AllowTargetReplace` at `false`; approve any target overwrite individually through the GUI prompt.
- Do not store passwords in JSON or CSV — use the environment-variable indirection for linked-server remote logins.
- Raise database compatibility to 160 (SQL 2022) only after post-migration validation, using Query Store to catch plan regressions.
- Capture a performance baseline on source before cutover and compare after stabilization on target.
- Every wave ends with an updated tracker and a generated stakeholder report.
