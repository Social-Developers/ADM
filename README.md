# Agent Directory Migration

A Windows PowerShell skill for consolidating supported AI coding-agent **user data** under `<DRIVE>:\agents`, while retaining legacy paths through directory junctions.

> [!WARNING]
> **Preview / untested on real installations.** This package has not been validated on your Windows system. Start with disposable test directories and review the script before running it against important data. Migration and deletion are not fully unattended.

## What it does

- Discovers supported agent data directories in the current Windows user profile.
- Copies each discovered directory into `<DRIVE>:\agents\agents\<agent-id>`.
- Compares relative file paths, file sizes, SHA-256 hashes, and directory layout.
- Replaces original paths with junctions **only after** verification and confirmation that affected agents are stopped.
- Keeps the original directory as a sibling `*.qagents-migration-hold` during validation.
- Creates an inventory of private skills and a shared-skills directory.
- Requires a separate, verified backup and explicit approval before deleting held originals.
- Maintains a hash-verified snapshot history for accepted rollbacks, with a cluster-aware free-space preflight, lease-guarded staging, detection of interrupted restores, and adoption of orphaned snapshots.
- Supports snapshot pruning and per-agent restore, plus Quick, JSON and strict Status reporting and a single-generation manifest backup.
- Optionally links entries from the shared skills pool into each migrated agent's own skills directory, discovering that directory per agent and reporting any agent whose location cannot be confirmed.

It does **not** move application executables, migrate project repositories or project-local rules, discover every custom installation, or automatically deduplicate and install skills across agents.

## Supported discovery paths

| Agent | Discovered source | Destination |
| --- | --- | --- |
| Claude Code | `%USERPROFILE%\.claude` | `<DRIVE>:\agents\agents\claude` |
| Codex | `%USERPROFILE%\.codex` | `<DRIVE>:\agents\agents\codex` |
| Gemini CLI | `%USERPROFILE%\.gemini` | `<DRIVE>:\agents\agents\gemini` |
| Cursor | `%USERPROFILE%\.cursor` | `<DRIVE>:\agents\agents\cursor` |
| OpenCode | `%APPDATA%\opencode` | `<DRIVE>:\agents\agents\opencode` |

These are **candidate locations**, not a promise to discover every file belonging to an agent. Existing junctions/reparse points in the source tree cause the script to stop rather than follow them.

### Include another agent directory

If an agent uses another directory under `%USERPROFILE%`, include it in the **first Inventory**. For example, if your OpenCode configuration lives in `.config\opencode`, this UTF-8 JSON file adds it alongside the defaults:

```json
[
  { "id": "opencode_config", "profilePath": ".config\\opencode" }
]
```

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Inventory -AdditionalSourcesFile .\sources.json
```

Give each directory its own ID: start with a lowercase ASCII letter, then use lowercase letters, digits or underscores, up to 48 characters. Built-in IDs, `all`, and Windows device names are reserved. Use an existing, dedicated agent directory, not a shared profile folder. Inventory rejects overlapping selections. Later phases read the manifest; use `-Agent opencode_config` to operate on that directory alone. Do not rerun Inventory to append to an existing migration.

All ordinary files and empty directories inside a selected tree are included regardless of extension. Files **beside** that tree stay in place. For example, Inventory warns about `%USERPROFILE%\.claude.json` and `.claude.json.backup` when present for Claude; neither file is moved, copied, or linked.

## Repository structure

```text
agent-directory-migration/
├── README.md
├── SKILL.md
└── scripts/
    ├── migrate-agents.ps1
    └── Link-SharedSkills.ps1
```

The target layout is:

```text
<DRIVE>:\agents\
├── agents\
│   ├── claude\
│   ├── codex\
│   ├── gemini\
│   ├── cursor\
│   └── opencode\
├── shared\
│   ├── skills\
│   ├── rules\
│   ├── knowledge\
│   ├── templates\
│   └── resources\
├── registry\
│   ├── migration-manifest.json
│   └── skills.json
├── migration\
│   ├── reports\
│   ├── logs\
│   └── rollbacks\
└── backups\
```

Some folders are scaffolding only. In particular, `shared\skills` is **not automatically populated** with compatible shared skills.

## Requirements

- Windows with Windows PowerShell **5.1 or later**.
- An accessible, writable selected destination drive with enough space for the data.
- `robocopy.exe` available.
- Permission to read the source directories, preserve supported metadata, and create junctions.
- A separate writable backup destination before cleanup. Prefer a different **physical device**, not merely a different drive letter.
- All affected agents stopped before activation.

A mapped, removable, or intermittently mounted destination drive may prevent agents from starting later. Confirm it will be available whenever the agents run.

## Download and install

1. Download or clone this repository. If using a ZIP, extract it, for example to `%USERPROFILE%\Downloads\agent-directory-migration`.
2. Keep `SKILL.md` beside the `scripts` directory. Review both files before execution.
3. In a compatible coding agent, point the agent to the extracted `SKILL.md` and ask it to follow the instructions. **Simply placing the ZIP in Downloads does not install or execute the skill.**
4. Alternatively, run the script directly from PowerShell using the commands below.

Do not run a similarly named script found elsewhere without verifying its provenance. Do not bypass organizational execution policies.

## Choose your destination drive

Before migration, the skill **asks which drive letter you want to use**. Enter an existing Windows drive, such as `D`, `E`, or `Q`. The root becomes `<DRIVE>:\agents`; all subdirectories remain the same. The script also prompts interactively when no drive is supplied, but for repeatable commands pass `-DriveLetter` on every phase. In unattended execution, a drive must be explicitly supplied. Once an inventory is created, use the same drive for all subsequent phases.

## Manual workflow

Open PowerShell in the extracted repository directory. Select a drive first, for example `$driveLetter = 'D'`, and use the same letter for all phases. These phases must be run **in order**. Each command should complete without an error before continuing.

Activate, Rollback, Cleanup, PruneSnapshots, AdoptSnapshots, RestoreSnapshot and ReconcileRestore accept `-WhatIf`. A preview runs the same read-only validation but does not require their approval switches: `-ConfirmAgentsStopped` and `-ApproveRollback` are skipped for Rollback, `-ConfirmAgentsValidated` and `-ApproveDeletion` for Cleanup, `-ApproveSnapshotDeletion` for PruneSnapshots, `-ApproveSnapshotAdoption` for AdoptSnapshots, `-ConfirmAgentsStopped`/`-ApproveSnapshotRestore` for RestoreSnapshot, and `-ConfirmAgentsStopped`/`-ApproveRestoreReconciliation` for ReconcileRestore. `-BackupRoot` is optional for a Cleanup preview. It reports what would be renamed, linked, deleted, adopted or restored and changes no files or manifest state. Inventory, Copy and Verify do not support `-WhatIf` and refuse it without making changes.

### 1. Inventory

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Inventory
```

Review `<DRIVE>:\agents\registry\migration-manifest.json`. Inventory is intentionally not overwritten on a subsequent run.

### 2. Copy

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Copy
```

The script refuses to overwrite an existing destination. The copy phase verifies copied contents before recording success.

### 3. Verify

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Verify
```

This checks directory layout, relative file paths, file sizes, and SHA-256 hashes. It is not a complete validation of all NTFS metadata or application behavior.

### 4. Activate

Close the affected agents, confirm they have stopped, then run:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Activate -ConfirmAgentsStopped
```

For each selected agent, the original directory is renamed to a sibling hold directory, and a junction is created at the legacy path pointing to the new location.

**The switch asserts that you checked the agents are stopped; it does not stop processes automatically.**

### 5. Rollback (optional, recovery)

This is a recovery step, not part of the normal sequence; use it when an agent fails after activation instead of hand-editing junctions:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Rollback -Agent claude -ConfirmAgentsStopped -ApproveRollback
```

Rollback requires `-ConfirmAgentsStopped` and `-ApproveRollback`. It verifies the hold, destination and legacy junction, and removes only a junction that points at the recorded destination. If the destination changed since activation, it prints a diff summary with added, removed and changed file counts and up to ten paths per category, then refuses unless you also pass `-AcceptDestinationChanges`. That switch proceeds with the rollback while keeping the changed destination in place; the manifest records `rolledBackWithChanges` and the counts under `destinationChanges`, alongside `rolledBackUtc`. Review the summary and preserve anything the agent wrote there before approving:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Rollback -Agent claude -ConfirmAgentsStopped -ApproveRollback -AcceptDestinationChanges
```

When the switch is used and the diff is non-empty, Rollback checks free space (rounding file sizes up to the destination volume's cluster size), copies the changed destination to a temporary `.incomplete-*` folder under `migration\rollbacks` while holding a `.snapshot-lease.json` lease, verifies that copy, and only then renames it to `<DRIVE>:\agents\migration\rollbacks\<agent>-<UTC timestamp>`. A failed copy is removed and aborts the rollback before any junction or hold changes; leftover staging from an interrupted attempt is cleared at the start of the next attempt, so a retry cannot add a partial folder or duplicate snapshot. A lease left by a hard crash is reported by Status; snapshot phases clear it only after confirming the owning process is gone. Rollback holds the lease through the snapshot record update, junction/hold cleanup and state update, and RestoreSnapshot holds it from before the safety snapshot through the manifest update, destination swap and staging cleanup.

The manifest stores `destinationSnapshots` as records with `path`, `hash`, `bytes`, `createdUtc`, `digestVersion`, `pinned`, and the added/removed/changed counts, alongside the latest `destinationSnapshot`, `destinationSnapshotHash`, and `destinationSnapshotDigestVersion`. New snapshots use digest version 2, which includes directory layout; version-1 records remain readable. A sidecar `<snapshot>.snapshot.json` records the same metadata outside the tree. `-DeduplicateSnapshots` hard-links identical files to the previous snapshot when the filesystem supports it and otherwise keeps copies. Each approved rollback with a non-empty diff gets its own folder. Snapshots are retained deliberately: Cleanup does not remove them. Keep each snapshot until its contents have been reconciled or are no longer needed, then prune it explicitly. `-WhatIf` never creates one.

Rollback renames the hold back, records the time, returns the entry to `Verified`, and leaves the destination in place either way. It cannot recover an agent whose Cleanup already completed, because the hold is gone by then.

### 5a. Snapshot maintenance (optional)

Snapshots are never pruned automatically. Use `PruneSnapshots` when a retained snapshot is no longer needed:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase PruneSnapshots -Agent claude -KeepLast 3 -WhatIf
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase PruneSnapshots -Agent claude -KeepLast 3 -ApproveSnapshotDeletion
```

`-KeepLast N` and `-KeepDays N` select snapshots to retain; the current snapshot, pinned records, and paths referenced by another agent are retained. Without `-WhatIf`, the phase requires `-ApproveSnapshotDeletion`. Before renaming a snapshot to `.deleting-*`, it saves a recovery record with its original path, history position and digest. A later prune verifies and restores pending data and its record before applying the current retention options; it leaves pending data for unselected agents untouched. Collisions, digest mismatches, pending folders without recovery records, and recovery records whose data is missing require manual reconciliation. Status reports the latter as `snapshot_recovery_pending`. A missing record is removed without deleting anything outside `migration\rollbacks`.

`AdoptSnapshots` backfills a legacy string-valued `destinationSnapshots` history and adopts orphaned final snapshot folders left by an interrupted rollback:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase AdoptSnapshots -Agent claude -WhatIf
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase AdoptSnapshots -Agent claude -SnapshotPath 'D:\agents\migration\rollbacks\claude-20260101T000000000Z' -ApproveSnapshotAdoption
```

Without `-WhatIf`, adoption requires `-ApproveSnapshotAdoption`. It recomputes each adopted snapshot's digest, writes its sidecar, and appends it to history without changing the current `destinationSnapshot`. Use Status first; adopt only folders you recognize.

All manifest-writing phases acquire the same phase-wide lease, including Inventory, Copy, Verify, Activate and Cleanup. An exclusive handle on the persistent `.snapshot-lease.lock` prevents competing cooperating processes from taking over while a phase is running; `.snapshot-lease.json` describes its owner and may remain after a crash. The guard is released when the process exits, and a readable same-host lease is reclaimed only when its PID is no longer running. A live PID is never expired by age; an unreadable or remote-host lease requires manual investigation. Do not delete or replace the lock file while commands may be running. Writers reload the manifest after acquisition and check its hash before saving; external writers that ignore the lease can still race that check. Status may read the backup if the primary is unreadable, but writers refuse until the primary is reconciled. Manifest writes flush the temporary file and replace the primary with a single-generation backup; this is not a guarantee against every power-loss or filesystem failure.

`RestoreSnapshot` replaces one agent's current destination with a referenced snapshot:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase RestoreSnapshot -Agent claude -SnapshotPath 'D:\agents\migration\rollbacks\claude-20260101T000000000Z' -WhatIf
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase RestoreSnapshot -Agent claude -SnapshotPath 'D:\agents\migration\rollbacks\claude-20260101T000000000Z' -ConfirmAgentsStopped -ApproveSnapshotRestore
```

Restore accepts only a snapshot referenced by the selected agent, verifies its recorded hash, and, unless `-WhatIf` is used, requires `-ConfirmAgentsStopped` and `-ApproveSnapshotRestore`. Before hashing or copying, it rejects any snapshot tree containing a junction or other reparse point. It first creates a safety snapshot of the current destination, copies the chosen snapshot to staging, renames the current destination aside, moves staging into place, and verifies the result. If the final move or verification fails, it attempts to put the previous destination back. If the process is killed after the destination rename, Status reports the missing destination, the stranded `<destination>.pre-restore-*` backup, and any `.restore-*` staging; the next RestoreSnapshot refuses until those artifacts are reconciled. Use `ReconcileRestore` after inspecting Status and stopping the affected agent:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase ReconcileRestore -Agent claude -WhatIf
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase ReconcileRestore -Agent claude -ConfirmAgentsStopped -ApproveRestoreReconciliation
```

If the destination is missing, reconciliation restores it only when exactly one stranded backup exists. If a destination exists, it is never replaced. Other stranded backups and `.restore-*` staging are moved, without deletion, into `migration\restore-reconciliation` for review. Reconciliation refuses unsafe trees and ambiguous missing-destination cases; no data is merged or automatically discarded. Review retained artifacts before deciding separately what to do with them. Restore does not merge newer destination changes; inspect the safety snapshot and the diff before using it.

### 6. Test each agent

Launch each affected agent and confirm that its settings, private skills, memories, and plugins work. Make a disposable write through its usual data path and confirm the data reaches the selected drive. Remove the test file and reconcile any newly written files against the held original. A strict comparison may fail if the destination changed after activation; do not overwrite new user data to make it pass.

Check state:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Status
```

`Status` compares the manifest with disk. It reports a missing or redirected legacy junction, a missing hold, a missing or unavailable destination, junctions that do not fit the recorded state, any recorded snapshot that is missing, outside `migration\rollbacks`, has a bad path or duplicate entry, lacks its hash, contains a junction or other reparse point, is unreadable, or no longer matches its recorded digest, plus orphaned `.incomplete-*` staging, orphaned `.restore-*` staging, stranded `<destination>.pre-restore-*` backups, unreferenced final snapshot folders, pending `.deleting-*` folders, and active, stale or unreadable snapshot leases. A deletion seen during an active lease is reported separately as potentially in progress; it is not assumed to be abandoned. Issues carry stable codes for automation.

Use `-Quick` to skip content hashing while retaining path, existence, state and lease checks; `-AsJson` to emit a machine-readable object with `schema`, `generatedUtc`, `root`, `healthy`, `issueCount`, `issues`, `entries` and `inventory`; and `-Strict` to exit with code 2 when any issue exists. Reconcile any reported issue before the next phase; a clean run prints `Status: manifest matches disk for the selected agents.`

To exercise the migration phases without touching live agent data, run the scratch harness:

```powershell
powershell -NoProfile -File tests\Test-MigrateAgents.ps1
```

It builds a throwaway profile and a unique sentinel-guarded folder under `%TEMP%`, maps two free drive letters to folders inside it with `subst`, and runs an unblocked copy of the script there. It covers the refusal paths for Copy, Verify, Activate and Cleanup, recovery from interrupted copy, activation and cleanup, and the snapshot lifecycle: free-space preflight, digest versions, naming collisions, leases, locked staging, prune, legacy adoption, a fault-injected crash after the snapshot rename, a fault-injected crash after the restore destination rename, stranded-destination reconciliation, a tampered snapshot containing a junction, restore, deduplication, snapshot-phase and rollback/restore manifest-window lease contention, stale-manifest reload after a phase completes, Status Quick/JSON/strict modes, and manifest backup recovery. The volumes are unmapped and the folder removed at the end; no existing drive root, `Q:\_admtest` path or agent data is touched. Exit code 0 means every check passed.

### 7. Link shared skills (optional)

`scripts\Link-SharedSkills.ps1` links the shared pool into each migrated agent's own skills directory. It reads `registry\migration-manifest.json`, confirms each legacy path is still a junction to its verified destination, and then **discovers** the agent's skills directory inside that destination (a directory named `skill` or `skills`, ignoring builtin, plugin, extension, staging and cache locations).

```powershell
.\scripts\Link-SharedSkills.ps1 -DriveLetter $driveLetter          # report only
.\scripts\Link-SharedSkills.ps1 -DriveLetter $driveLetter -Apply    # create junctions
```

Each shared skill becomes one junction inside the agent's skills directory. Existing entries are never overwritten. Agents without exactly one eligible skills directory are `UNCONFIRMED`; entries without a matching activated junction are `BLOCKED`. Both are skipped. An apply run records its selected entries in `registry\skill-links.json`. If a link fails, the script keeps earlier links, records the failed skill and reason, and exits with code 1. Report-only mode leaves the registry unchanged.

Use report-only mode during migration. If you plan to run Cleanup, wait until it succeeds before using `-Apply`: the shared links are themselves reparse points, which Verify, Rollback, and Cleanup refuse to traverse.

For a dry run before activation exists, classify unlinked homes explicitly:

```powershell
.\scripts\Link-SharedSkills.ps1 -DriveLetter $driveLetter -IncludeHome "$env:USERPROFILE\.claude;$env:USERPROFILE\.codex"
```

To exercise the linker without touching live agent directories, run the scratch harness:

```powershell
powershell -NoProfile -File tests\Test-LinkSharedSkills.ps1
```

It builds a throwaway agents root and profile in a unique sentinel-guarded folder under `%TEMP%`, maps a free drive letter to that folder with `subst`, then runs the linker against them in child processes. It covers report-only, apply, idempotent re-apply, a forced junction failure, a partial run where earlier links are created before a later agent fails, and a same-agent partial failure that produces the `LINK FAILED (+N linked)` label. The temporary ACL deny rule, the volume mapping and the folder are removed at the end, and no existing drive root or `Q:\_admtest` path is touched; exit code 0 means every check passed.

### 8. Cleanup (optional, destructive)

**Only after independent operational testing**, identify the exact hold directories proposed for deletion and explicitly approve them. Supply an existing backup root on an independent device; `R:` below is just an example:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Cleanup `
  -BackupRoot 'R:\agent-migration-backup' `
  -ConfirmAgentsValidated `
  -ApproveDeletion
```

Cleanup copies the hold directory to the backup root, verifies it, rechecks the destination, and then deletes the verified hold directory. **The script only checks that the backup uses a different drive letter; you must confirm physical independence yourself.** It does not independently detect active agent processes or confirm application tests. Never pass the confirmation switches unless those checks have actually been completed.

If a rollback followed an interrupted Cleanup, its verified backup may still exist. Rerunning Cleanup with the same `-BackupRoot` reuses that backup after confirming it matches the hold, instead of refusing. A backup that differs from the hold is refused and left untouched. Cleanup does not verify, prune or delete snapshots under `migration\rollbacks`.

To limit operations to one agent, add `-Agent claude` (or `codex`, `gemini`, `cursor`, `opencode`) to the relevant phase. The selected agent must already exist in the migration manifest.

## Safety model

| Stage | Effect on original data | Safety check |
| --- | --- | --- |
| Inventory | No source changes | Records discovered paths and sizes |
| Copy | Leaves source intact | Rejects collisions; verifies copied tree |
| Verify | Leaves source intact | Compares hashes and layout |
| Activate | Renames source to hold; creates junction | Requires stopped-agent confirmation and re-verification |
| PruneSnapshots | Deletes unneeded snapshot copies | Keeps the current snapshot and pinned records; requires explicit approval; rename-before-delete |
| RestoreSnapshot | **Replaces the current destination** | Requires stopped-agent confirmation and explicit approval; verifies the snapshot, records a safety snapshot, stages the copy and re-verifies |
| Cleanup | **Deletes held original** | Requires explicit approval, operational-test assertion, verified backup and final comparison |

If a step fails, **stop**. Do not manually delete hold directories, rerun Inventory over an existing manifest, or force-overwrite a destination. Investigate the manifest, source, hold directory, and junction before attempting recovery.

## Known limitations

- Only the five paths in the table are discovered automatically. Other dedicated profile directories require `-AdditionalSourcesFile` at Inventory. Standalone files, project repositories, and application binaries are outside the migration workflow.
- The shared-skills folder and `skills.json` inventory are created, and linking them into agents is opt-in through `Link-SharedSkills.ps1`. There is no automatic deduplication, compatibility conversion, or content rewriting, and an agent whose skills directory cannot be identified unambiguously is reported `UNCONFIRMED` instead of being linked.
- Hash checks verify file contents, not every filesystem property (for example alternate data streams, ownership, all ACL semantics, or sparse-file details).
- The script preflights free space for a rollback snapshot using file sizes rounded to the destination volume's cluster size. It does not predict total migration space or guarantee headroom for other activity, detect active processes, or perform agent startup tests automatically. The skill instructs the operator/agent to perform these checks separately.
- Snapshot deduplication is opt-in and uses NTFS hard links when available; it falls back to copies and does not deduplicate across filesystems.
- Restore is per-agent and snapshot-specific. It creates a safety snapshot but does not merge newer destination changes. An interrupted restore requires approved `ReconcileRestore` or manual review; retained reconciliation artifacts are not automatically removed.
- The manifest `.bak` is a single-generation backup for interrupted writes, not a long-term version history.
- Rollback and RestoreSnapshot recover one selected agent at a time. There is no automatic multi-agent disaster recovery, and RestoreSnapshot does not merge newer destination changes.
- The script rejects source trees containing reparse points and does not automatically resolve file changes made during or after migration.
- Do not treat `-ConfirmAgentsValidated` or `-ApproveDeletion` as proof that a test was performed; they are explicit operator assertions.

## Security

Agent directories can contain tokens, credentials, session information, and private memory. Keep backups, logs, manifests, and destination directories access-controlled. Do not publish your actual migration manifest or agent data to GitHub.

## License

No license is included in this package. Add a `LICENSE` file if you intend to grant public reuse rights.
