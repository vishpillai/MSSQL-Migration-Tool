# SQL Server Migration Runbook — 2016/2019 to 2022

Operational runbook for executing one migration wave with this tool. It is written for the DBA/operator running the migration and the stakeholders tracking it. Complete the [MIGRATION-CHECKLIST.md](MIGRATION-CHECKLIST.md) items for the wave first; record progress in [MIGRATION-TRACKER.csv](MIGRATION-TRACKER.csv); generate the stakeholder summary with `New-MigrationStakeholderReport.ps1`.

**Scope of one runbook execution:** one source/target pair (one SQL 2016 or 2019 source instance to one SQL 2022 target instance) and its selected databases, logins, SQL Agent jobs, and linked servers (remapped to new-environment endpoints).

---

## 1. Key facts and safety rules

- The tool never modifies source databases: it reads metadata and takes a native `COPY_ONLY` backup. Restores, user repair, statistics updates, and server-object copies happen only on the target.
- A database is marked complete only when it is verified online and accessible on the target, post-migration actions succeeded, and its temporary backup folder was cleaned up.
- Runs are resumable: `MigrationState.json` records per-database status. A database recorded `Completed` and still online on the target is skipped on retry; failed work stays eligible for retry.
- Backups are checksummed, compressed, verified, and striped across `BackupFileCount` files in a unique per-run folder under the pair's `BackupPath`. The run folder is deleted only when every stage succeeds; on failure it is retained for troubleshooting/retry.
- Copied SQL Agent jobs are **disabled** on the target until an administrator reviews and enables them.
- Linked-server configuration is **opt-in** and skipped by default; existing same-name linked servers on the target are left unchanged, not overwritten.
- Keep `AllowTargetReplace` at `false`; approve overwrites individually in the GUI/web UI.
- Do not run patching and migration at the same time. Do not stop the web host while a plan is running.

## 2. Roles and contacts (fill in before the window)

| Role | Name | Contact |
|------|------|---------|
| Migration lead / operator (runs the tool) | | |
| Target SQL 2022 DBA | | |
| Application owner(s) | | |
| Network/firewall contact (linked-server endpoints) | | |
| Change manager / CAB approver | | |
| Stakeholder report recipient(s) | | |

## 3. Prerequisites (complete before T-7 days)

On the migration host:

```powershell
# From the project directory
Setup-DbMigrationTool.cmd          # installs PowerShell 7.2+ and dbatools if missing
Invoke-Pester .\tests              # all tests must pass
$PSVersionTable.PSVersion          # 7.2 or later
Get-Module -ListAvailable dbatools # present
```

Access and permissions:

- Migration host reaches source and target SQL instances over the network.
- The Windows identity running the tool can: read source databases, inspect TDE metadata (`VIEW SERVER STATE`, or `VIEW SERVER PERFORMANCE STATE` on SQL 2022), create/restore databases on the target, copy server objects, repair users, and update statistics.
- The pair's `BackupPath` share is visible to **both** SQL Server service accounts (verified by Validate mode / **Validate pair**).
- Target data/log volumes have free space ≥ allocated source data/log sizes + `RestoreSpaceBufferPercent` (default 20%).
- For TDE databases: the matching certificate with private key (or asymmetric key) already exists on the target — the tool blocks the database before transfer otherwise and never exports keys.
- Full-Text Search (and any other required features) installed on the target when source databases depend on them; the preflight blocks the database otherwise.

## 4. Configuration (T-7 to T-3 days)

1. Edit `config\migration.config.json` — one `SourceTargets` entry for this pair with its isolated `BackupPath`; set `ExcludeDatabases`, `ThrottleLimit`, `BackupFileCount`, `UpdateStatistics` as agreed.
2. Edit `config\LinkedServers.csv` — one row per linked server with the **new-environment** `DataSource` (and `Catalog` if changing). Never put passwords in the CSV. For `SpecifiedSecurityContext`, set `RemoteUser` and the name of an environment variable that will hold the password.
3. Stage linked-server passwords as environment variables on the migration host (same session/user that runs the tool):

```powershell
# Example: name matches PasswordEnvironmentVariable in the CSV
[Environment]::SetEnvironmentVariable('LS_ERP_PASSWORD', '<secret>', 'User')
```

4. Confirm firewall openings from the target SQL 2022 host to every new linked-server endpoint.
5. Take and verify full pre-migration backups of all in-scope source databases (your normal backup solution — separate from the tool's temporary staging backups).

## 5. Execution timeline

### T-7 to T-3 days — Discovery and readiness

```powershell
.\Invoke-DbMigration.ps1 -Mode Discover
.\Invoke-DbMigration.ps1 -Mode Validate
```

- Review the Discovery report: database sizes, compatibility levels, recovery models, TDE state, source login / linked-server / Agent-job counts, target free space.
- Run **Assess readiness only** (GUI or web UI) for the selected databases; download the HTML/CSV/JSON report.
- Resolve or formally accept every readiness finding (feature dependencies, TDE keys, legacy T-SQL candidates, security settings, name conflicts).
- Update the tracker: `DiscoveryStatus`, `ReadinessStatus`, `ValidationStatus` per database.

### T-2 days — Final checks

- Re-run `Validate`; all checks pass.
- Confirm maintenance window, application quiesce plan, and rollback decision criteria with the change manager.
- Confirm monitoring/alert suppression is scheduled for the window.
- Generate a baseline stakeholder report and circulate it:

```powershell
.\New-MigrationStakeholderReport.ps1
```

### T-0 — Migration window

Choose one execution path (CLI, GUI, or web). The CLI is shown; the GUI (`.\Invoke-DbMigrationGui.ps1`) and web UI (`.\Invoke-DbMigrationWeb.ps1`) follow the same stages with on-screen prompts, live progress, and Pause/Resume/Stop controls.

**Step 1 — Quiesce applications.** Stop application services / set databases read-only on the source per the cutover plan. Record the time.

**Step 2 — Run the migration.**

```powershell
.\Invoke-DbMigration.ps1 -Mode Migrate
```

Per database the tool runs: validation and capacity preflight → striped verified `COPY_ONLY` backup → restore → target access verification → post-migration actions (orphaned-user repair, statistics update) → temporary backup cleanup. After the pair's databases, server-level stages run: logins/Agent jobs (`ServerObjects`) and linked servers (`LinkedServers`, from the updated CSV when opted in).

- Watch the console (or the web **Live migration monitor**); note any `Failed` or `Skipped` rows immediately.
- If a database fails: the run folder is retained. Fix the cause and rerun `-Mode Migrate` — completed databases are skipped, failed ones retried.

**Step 3 — Review run output.**

- Open the latest `Migration-*.html` / `Migration-*.csv` in the configured `OutputPath`.
- Check `MigrationState.json` — every in-scope database should be `Completed`.
- Zero unexplained `Failed`/`Skipped` rows before proceeding.

### T+0 (same window) — Post-migration validation

Run these on the **target** (the web UI's T-SQL workspace can run them across instances):

```sql
-- 1. All migrated databases online, multi-user, expected recovery model
SELECT name, state_desc, user_access_desc, recovery_model_desc, compatibility_level
FROM sys.databases WHERE database_id > 4 ORDER BY name;

-- 2. Orphaned users (expect none after repair)
EXEC sp_change_users_login 'Report';  -- per database, or use dbatools:
```

```powershell
Get-DbaDbOrphanUser -SqlInstance <target> | Format-Table
Test-DbaLinkedServerConnection -SqlInstance <target>   # every linked server, new endpoints
Get-DbaAgentJob -SqlInstance <target> | Where-Object IsEnabled -eq $false  # review, then enable approved jobs
```

- Spot-check row counts per database against the source (largest tables first).
- `DBCC CHECKDB` on migrated databases (run inside the window if sized, otherwise schedule immediately after).
- Verify SQL logins can authenticate (application service accounts first).
- Verify every linked server with `sp_testlinkedserver` **and** a real query through it (four-part name or `OPENQUERY`) — this proves the new endpoint, firewall, and remote login.
- Review and explicitly enable the copied (disabled) SQL Agent jobs; confirm schedules.
- Confirm the target maintenance solution (Ola Hallengren or existing) is installed and scheduled.
- Keep source compatibility levels initially; plan the raise to 160 after validation, ideally with Query Store capture for plan-regression comparison.

### T+0 — Cutover

1. Repoint connection strings / DNS CNAMEs / listeners to the SQL 2022 target.
2. Repoint SSIS, SSRS, ETL, monitoring, and backup integrations.
3. Application smoke tests per database — record results in the tracker (`SmokeTest`).
4. Business owner UAT sign-off — record in the tracker (`UATSignOff`, `CutoverDate`).
5. Set source databases read-only (freeze) — do not delete anything.
6. Update the tracker and regenerate the stakeholder report:

```powershell
.\New-MigrationStakeholderReport.ps1
```

### T+1 to T+5 — Stabilization

- Compare target performance against the pre-migration baseline; investigate regressions (Query Store, wait stats).
- Raise compatibility level to 160 per database after validation, one change at a time.
- Keep the source instance read-only for the agreed retention period, then follow the decommission plan.

## 6. Rollback procedure

Trigger: any rollback criterion from the change record (e.g., smoke-test failure that cannot be fixed in-window, data validation failure, critical linked-server dependency unavailable).

1. Log the decision, time, and approver.
2. Repoint connection strings / DNS back to the source instance.
3. Bring source databases back online/read-write (they were never modified by the tool).
4. Validate applications against the source.
5. Leave the target copies in place for forensics unless storage requires removal; record what was removed.
6. Raise an incident/problem record; update the tracker (`OverallStatus = Blocked`, notes) and regenerate the stakeholder report.

## 7. Troubleshooting quick reference

| Symptom | First checks |
|---|---|
| Pair validation fails | Host reaches both instances; both SQL service accounts see the `BackupPath` share; supported versions (source 11/13/15, target 16) |
| Database blocked before transfer | TDE key missing on target; Full-Text Search (or other required feature) not installed on target; insufficient target free space incl. buffer |
| Restore fails | Target free space; orphaned data/log files on target host (tool retries with unique names only when the target DB does not exist); share permissions |
| Login works on source but not target | Orphaned users — check `Get-DbaDbOrphanUser`; confirm `ServerObjects` stage completed |
| Linked server fails on target | New endpoint reachable from target host (firewall); remote password env variable set in the runner's session; per-login mappings recreated (tool creates one mapping per linked server); same-name linked server already on target is left unchanged |
| Agent jobs not running | They are copied **disabled** by design — review and enable |
| Need to retry | Fix the cause and rerun `-Mode Migrate`; state file skips completed databases, retained run folders are reused/cleaned after successful retry |
| Audit/integrity error (web) | Do not edit `Audit.jsonl*`; use the password-confirmed administrator reset only when authorized |

Full troubleshooting list: [HOW-TO-USE.md](../HOW-TO-USE.md) section 11.

## 8. Artifacts produced per wave

| Artifact | Location | Audience |
|---|---|---|
| Discovery / readiness reports (HTML/CSV/JSON) | configured `OutputPath` | DBA, stakeholders |
| Migration run reports (`Migration-*.html/csv`) | configured `OutputPath` | DBA, stakeholders |
| State file (`MigrationState.json`) | project directory | Operator |
| Stakeholder report (`StakeholderReport-*.html`) | configured `OutputPath` | Stakeholders |
| Updated tracker | `docs/MIGRATION-TRACKER.csv` | All |
| Audit trail (web mode) | `%LOCALAPPDATA%\DbMigrationWeb\Logs` | Security/compliance |
| Report portal (view/download all reports) | `.\Start-MigrationReportPortal.ps1` (default `http://localhost:8080/`) | Stakeholders |
