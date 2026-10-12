# Changelog

Notable changes to the SQL Server migration tool are documented here. Versions
follow semantic versioning.

## Unreleased

- Added first-run administrator creation in the browser, protected by a single-use host-console code, loopback-only setup, atomic auth-file creation, and a 14-character minimum password; fresh installs no longer receive a generated login password.
- Consolidated auth-file persistence with atomic writes and restricted ACLs for standard-mode installations.
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
