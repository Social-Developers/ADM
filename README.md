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
│   └── logs\
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

### 5. Test each agent

Launch each affected agent and confirm that its settings, private skills, memories, and plugins work. Make a disposable write through its usual data path and confirm the data reaches the selected drive. Remove the test file and reconcile any newly written files against the held original. A strict comparison may fail if the destination changed after activation; do not overwrite new user data to make it pass.

Check state:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Status
```

To exercise the migration phases without touching live agent data, run the scratch harness:

```powershell
powershell -NoProfile -File tests\Test-MigrateAgents.ps1
```

It builds a throwaway profile and a unique sentinel-guarded folder under `%TEMP%`, maps two free drive letters to folders inside it with `subst`, and runs an unblocked copy of the script there. It covers the refusal paths for Copy, Verify, Activate and Cleanup, plus recovery from interrupted copy, activation and cleanup. The volumes are unmapped and the folder removed at the end; no existing drive root, `Q:\_admtest` path or agent data is touched. Exit code 0 means every check passed.

### 6. Link shared skills (optional)

`scripts\Link-SharedSkills.ps1` links the shared pool into each migrated agent's own skills directory. It reads `registry\migration-manifest.json`, confirms each legacy path is still a junction to its verified destination, and then **discovers** the agent's skills directory inside that destination (a directory named `skill` or `skills`, ignoring builtin, plugin, extension, staging and cache locations).

```powershell
.\scripts\Link-SharedSkills.ps1 -DriveLetter $driveLetter          # report only
.\scripts\Link-SharedSkills.ps1 -DriveLetter $driveLetter -Apply    # create junctions
```

Each shared skill becomes one junction inside the agent's skills directory. Existing entries are never overwritten and private skills are never replaced. An agent is linked only when exactly one skills directory is found; agents with none, or with several, are listed as `UNCONFIRMED` and left untouched, and agents whose junction is missing are listed as `BLOCKED`. There is no built-in path table to guess from. Results are written to `registry\skill-links.json`.

For a dry run before activation exists, classify unlinked homes explicitly:

```powershell
.\scripts\Link-SharedSkills.ps1 -IncludeHome "$env:USERPROFILE\.claude;$env:USERPROFILE\.codex"
```

To exercise the linker without touching live agent directories, run the scratch harness:

```powershell
powershell -NoProfile -File tests\Test-LinkSharedSkills.ps1
```

It builds a throwaway agents root and profile in a unique sentinel-guarded folder under `%TEMP%`, maps a free drive letter to that folder with `subst`, then runs the linker against them in child processes. It covers report-only, apply, idempotent re-apply, a forced junction failure, a partial run where earlier links are created before a later agent fails, and a same-agent partial failure that produces the `LINK FAILED (+N linked)` label. The temporary ACL deny rule, the volume mapping and the folder are removed at the end, and no existing drive root or `Q:\_admtest` path is touched; exit code 0 means every check passed.

### 7. Cleanup (optional, destructive)

**Only after independent operational testing**, identify the exact hold directories proposed for deletion and explicitly approve them. Supply an existing backup root on an independent device; `R:` below is just an example:

```powershell
.\scripts\migrate-agents.ps1 -DriveLetter $driveLetter -Phase Cleanup `
  -BackupRoot 'R:\agent-migration-backup' `
  -ConfirmAgentsValidated `
  -ApproveDeletion
```

Cleanup copies the hold directory to the backup root, verifies it, rechecks the destination, and then deletes the verified hold directory. **The script only checks that the backup uses a different drive letter; you must confirm physical independence yourself.** It does not independently detect active agent processes or confirm application tests. Never pass the confirmation switches unless those checks have actually been completed.

To limit operations to one agent, add `-Agent claude` (or `codex`, `gemini`, `cursor`, `opencode`) to the relevant phase. The selected agent must already exist in the migration manifest.

## Safety model

| Stage | Effect on original data | Safety check |
| --- | --- | --- |
| Inventory | No source changes | Records discovered paths and sizes |
| Copy | Leaves source intact | Rejects collisions; verifies copied tree |
| Verify | Leaves source intact | Compares hashes and layout |
| Activate | Renames source to hold; creates junction | Requires stopped-agent confirmation and re-verification |
| Cleanup | **Deletes held original** | Requires explicit approval, operational-test assertion, verified backup and final comparison |

If a step fails, **stop**. Do not manually delete hold directories, rerun Inventory over an existing manifest, or force-overwrite a destination. Investigate the manifest, source, hold directory, and junction before attempting recovery.

## Known limitations

- Only the five user-level discovery paths above are implemented. Project-specific configurations, custom paths, and additional agents are out of scope.
- The shared-skills folder and `skills.json` inventory are created, and linking them into agents is opt-in through `Link-SharedSkills.ps1`. There is no automatic deduplication, compatibility conversion, or content rewriting, and an agent whose skills directory cannot be identified unambiguously is reported `UNCONFIRMED` instead of being linked.
- Hash checks verify file contents, not every filesystem property (for example alternate data streams, ownership, all ACL semantics, or sparse-file details).
- The script does not calculate free-space requirements, detect active processes, or perform agent startup tests automatically. The skill instructs the operator/agent to perform these checks separately.
- The script has no general-purpose automated rollback command. Failed operations may require careful manual recovery.
- The script rejects source trees containing reparse points and does not automatically resolve file changes made during or after migration.
- Do not treat `-ConfirmAgentsValidated` or `-ApproveDeletion` as proof that a test was performed; they are explicit operator assertions.

## Security

Agent directories can contain tokens, credentials, session information, and private memory. Keep backups, logs, manifests, and destination directories access-controlled. Do not publish your actual migration manifest or agent data to GitHub.

## License

No license is included in this package. Add a `LICENSE` file if you intend to grant public reuse rights.
