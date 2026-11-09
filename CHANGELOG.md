# Changelog

Notable changes to the SQL Server migration tool are documented here. Versions
follow semantic versioning.

## Unreleased

- Added build-change auto-refresh: the web app tracks the host build stamp and reloads itself after an update or host restart, so open tabs never show stale state from a previous build.
- Added opt-in automatic updates: Super Admins can enable daily checks that apply the latest build and restart the host only when the app is idle (no run active, no event streams attached, no recent requests); data preservation matches manual updates.
- Terminal migration events pushed over the event stream now refresh the monitor status immediately, so background browser tabs (whose one-second status poll is throttled) still flip to Completed/Failed/Stopped the moment a run ends.
- Fixed the server-object stage failing the whole run with `The property 'Properties' cannot be found on this object`: dbatools permission-sync internals can leak non-result objects into the phase output pipeline, and serializing them for the console escaped the phase guard. Each phase now drops pipeline debris before streaming, and the runner forwards only well-formed result objects.
- Login alignment now also applies to browser-driven runs: the plan computes which planned databases are absent on the target and hands them to the server-object worker, whose database list is intentionally empty by design. Direct `Invoke-DbMigration.ps1` runs keep computing the set from the configured database list.
- Added application self-update: Administration shows the installed build versus the latest published commit, and Super Admins can apply it in place; a detached updater preserves configuration, accounts, logs, reports, and migration state, then restarts the web host automatically.
- Added real-time server-sent events at `/api/events/stream`; the web app pushes migration and patch events to the browser as they happen and keeps one-second polling as an automatic fallback.
- Fixed migration start crashing with `The property 'TargetMinCompatibilityLevel' cannot be found` when a target compatibility level was chosen: pair discovery now caches the target's supported compatibility-level bounds for plan validation, and a missing cache entry produces a clear run-discovery-again message instead of a strict-mode error.
- Contained server-object migration phases: a hard failure while copying logins, Agent jobs, or Agent operators is now reported as a phase failure (failing the run's server-object stage) while the remaining phases still run, so a crashing `Copy-DbaLogin` can no longer block Agent job and operator migration.
- Added login-alignment business logic: logins whose entire database footprint maps to databases that do not exist on the target after the database phase (all of their user mappings, or their default database when unmapped) are skipped during login migration and reported as skipped. Server-role members, local NT service principals, and the runner identity are never skipped.
- Fixed portable first-run administrator setup failing with a `SeSecurityPrivilege` error when the web host runs without elevation; the portable auth store now correctly skips ACL hardening during browser setup.
- Made the migration readiness assessment report collapsible with always-visible status summary badges; the expanded state is remembered per pair, and fresh assessments auto-expand.
- Starting a migration now collapses the setup panel and scrolls directly to the live migration monitor.
- Stripped ANSI color escape sequences from migration/patch child-process output so the live monitor and run logs show clean, readable text.
- Added an opt-in post-migration action to install Ola Hallengren's Maintenance Solution procedures into `master` once per target instance; SQL Agent jobs are not created and existing objects are not replaced.
- Added a collation readiness check that compares each source database's collation with the target tempdb collation and flags modules that create temp tables or table variables with character columns and no `COLLATE` clause, preventing post-migration "Cannot resolve the collation conflict" (Msg 468) errors.

- Added installation-scoped Super Admin user management, server-enforced workspace grants, and local white-label/theme settings with validated colors and embedded image logos.
- Migrated existing single-account authentication files to the new user store without changing the existing administrator credentials.
- Added first-run administrator creation in the browser, protected by a single-use host-console code, loopback-only setup, atomic auth-file creation, and a 14-character minimum password; fresh installs no longer receive a generated login password.
- Consolidated auth-file persistence with atomic writes and restricted ACLs for standard-mode installations.
- Portable browser mode now keeps its authentication store in the user's Local AppData (`DbMigrationWeb\Portable`) with restricted ACLs instead of beside the app, so credentials survive app-folder replacement; an existing app-folder auth file is migrated automatically on first launch.
- Documented why browser-based MAC-address registration is not used: browsers cannot reliably obtain a device MAC, and MAC addresses are mutable/spoofable identifiers.
- Added a business-oriented audit trail with structured events, failed-login and operation-request outcomes, DPAPI-protected HMAC chaining, a signed head checkpoint, integrity warnings, server-side filters, and audit-only JSON/CSV export.
- Added an original responsive SQL Server illustration to the sign-in page; it is bundled inline and works without an external image service.
- Reset transient logs, inline errors, and open dialogs when an application session ends or a user signs back in, while preserving saved server history and silently restoring live job state.
- Added consistent status colors for migration and patch progress, outcomes, metrics, and reporting tables.
- Clarified linked-server migration as a single opt-in and visually highlighted selected migration options for faster review.
- Moved the Logs & audit workspace out of the default landing view; open it from navigation when needed.
- Replaced browser-native migration errors and confirmations with accessible in-app dialogs styled to match the application.
- Added an optional sign-in preference to remember the username on this device; passwords and authentication sessions are not stored.
- Added SSMS-style history: previously used servers and backup paths are suggested as you type in the pair, patch, and standalone fields, and choosing a known source or target autofills its last-used partner and backup path. Only connection details are stored (in browser local storage, never credentials); use "Clear history" to reset.
- Discovery no longer needs a shared backup path; it is required only when starting a migration. Sample placeholders now show as watermarks instead of real values.
- Fixed the patch assessment failing with "parameter 'ne' is specified more than once", and added SQL Server 2025 to the patch catalog.
- Fixed the audit-log reader leaking a file handle on tamper-detection paths, which could block log cleanup and test-drive deletion with "file in use" errors.
- Fixed the portable launcher crashing with a raw out-of-range error instead of the clear "no free port" message when the preferred port is near 65535 and occupied.
- Only one web host can run per machine; launching a second one is refused with a clear message.
- The launcher now asks for administrator rights (UAC) so SQL Server patching of local instances works; if the host is not elevated, patching a local instance fails fast with an explanatory message instead of "Console not elevated".
- Added sequential custom T-SQL execution for arbitrary independent SQL instances, with per-instance result and failure reporting.
- Added browser-side custom T-SQL output downloads for one, selected, or all SQL instances in CSV, JSON, TSV, or XML, with spreadsheet-formula protection for CSV/TSV.
- Added a readiness-only, DMA-inspired SQL Server assessment for selected databases, with compatibility, feature, TDE, capacity, security, and legacy-module checks plus downloadable HTML/CSV/JSON reports; documents that it is not an exhaustive Microsoft DMA replacement.
- Added a graphical disk-usage workspace for one or more SQL Server hosts, with per-volume capacity bars and per-server error reporting.
- Added a separate live SQL Server monitor for up to 10 independent instances, with transient CPU/RAM/disk graphs, request details, and performance threshold alerts; active migration endpoints are monitored automatically without persisting snapshots.
- Expanded the live migration monitor with a stage progress gauge, current database and pair, an overall job percentage, and completed/skipped/in-progress/pending/failed counts.
- Added a Reports & audit workspace with migration and patch summaries, durable run/application logs, exportable JSON snapshots, and audit events that omit credentials and raw custom SQL text.
- Expanded migration summaries with source user/login, SQL Agent job, and linked-server inventory counts plus corresponding migration-stage status.
- Restore retries orphaned destination-file conflicts with unique filenames only when the target database does not exist, without overwriting the pre-existing file.
- Schema-only targets use unique file names and remove incomplete target databases after transfer failures; database migrations now preflight required SQL Server Full-Text Search support.
- Added per-pair linked-server inventory and destination remapping for browser migrations, with fresh SQL-auth credentials passed transiently to the migration worker and never written to plan files or CSVs.
- Added TDE discovery and pre-migration checks for matching private-key certificates or asymmetric keys on migration targets; unsafe encrypted database restores are blocked before backup.
- Improved the browser interface for tablet/mobile layouts and added section navigation.
- Curated the portable package staging layout: launcher and prerequisite installer at the root, runtime application under `App\`, and stable WiX component identifiers for repeatable MSI builds.
## 1.1.1 - 2026-10-11

Installer and documentation status update.

- Verified the supported Windows app bundle install/uninstall flow and documented it as the current production path.
- Confirmed the project test suite passes with 40/40 passing tests for configuration, install/uninstall, portable storage, and migration behavior.
- Clarified that the WiX MSI/EXE packaging work is experimental and not yet the recommended deployment artifact.

## 1.1.0 - 2026-10-07

Portable web mode and launcher improvements.

- Added a portable local browser mode that stores auth and logs under the app
  folder instead of `%ProgramData%`.
- Added `Start-PortableDbMigrationWeb.ps1` to launch the browser app without
  machine-level HTTPS setup or admin rights.
- Added local loopback-only handling for portable mode and automatic selection
  of a free local port.
- Kept the secure production HTTPS workflow intact for server-hosted use.
- Expanded tests and functional validation for portable web storage and startup
  behavior.

## 1.0.0 - 2026-10-06

Initial published application release.

- Added PowerShell and dbatools workflows for database discovery, validation,
  backup, restore, and post-migration checks.
- Added a secure HTTPS browser interface with sequential migration plans,
  per-database overwrite decisions, pause/resume/stop controls, and live
  progress events.
- Added full-data and schema-only migration modes.
- Added isolated striped backups, capacity preflight, migration state, and
  HTML/CSV reports.
- Added source-side `COPY_ONLY` backup behavior and documented its backup
  history, CPU, and I/O effects.
- Added automated tests and operational documentation.
