---
name: agent-directory-migration
description: Migrate supported Windows AI agent user data into <DRIVE>:\agents using the bundled PowerShell script, verify integrity, activate legacy junctions, inventory skills, and reclaim source space only after independent backup and explicit deletion approval. Use when consolidating agent storage or installing this migration skill from Downloads.
---

# Centralized agent migration — Windows

## Objective and scope

Use the **bundled** `scripts/migrate-agents.ps1` as the sole migration engine. Its canonical target is `<DRIVE>:\agents`, with one directory per supported agent in `<DRIVE>:\agents\agents\<id>`, and a shared skill directory at `<DRIVE>:\agents\shared\skills`. Do not implement ad hoc copy/move/delete commands in place of the script.

Shared-skill linkage is likewise a bundled step: use `scripts\Link-SharedSkills.ps1` rather than hand-creating skill links or repeated `New-Item -ItemType Junction` commands of your own.

The bundled implementation supports **user-profile** directories for `claude`, `codex`, `gemini`, `cursor`, and `opencode` (see `Discover` in the script for exact source paths). It does **not** relocate application binaries, all AppData trees, project-level instructions, repositories, custom agent paths, or unknown agents. The migration script creates the shared pool and a skills inventory, but it never deduplicates, converts, or installs skills across agents; compatibility must be assessed separately. Linking is a separate, explicitly invoked step performed by `scripts\Link-SharedSkills.ps1`, which discovers each agent's own skills directory and refuses to guess. Never claim automatic cross-agent skill installation.

## Starting from Downloads

When invoked and the current working directory is the user's default Downloads folder, or the user says the skill and script were downloaded:

1. Resolve Downloads using `[Environment]::GetFolderPath('UserProfile')` plus `Downloads` **as a candidate**, and also inspect the current working directory. Downloads may be redirected; do not assume it is always under the profile.
2. Find the exact installed skill directory and its `scripts\migrate-agents.ps1` and `scripts\Link-SharedSkills.ps1`. Prefer the scripts **adjacent to this SKILL.md**. If only `migrate-agents.ps1` is present in Downloads, inspect its content and ensure it matches the expected script before using it. Never silently run an arbitrary similarly named script, and do not substitute a locally rewritten linkage script for the bundled one.
3. If the user downloaded the ZIP package, extract it into a dedicated `agent-directory-migration` directory, preserving `SKILL.md` and both files under `scripts\` together. Avoid extracting over an existing directory without reviewing conflicts.
4. Inspect the script and verify its SHA-256 against a trusted, independently supplied digest if available. A digest shipped in the same ZIP is useful for detecting accidental corruption, **not** for authenticating the download.
5. Use a full absolute script path for all invocations. Do not require the user to change working directory.
6. Never use `Invoke-Expression`, remote script downloads, `-ExecutionPolicy Bypass`, or unreviewed privilege elevation as a shortcut.

PowerShell 5.1 or newer and Windows are required. If execution policy blocks the script, explain the block and ask the user to select an approved local execution method; do not bypass policy automatically.

## Mandatory preflight

Before changing data:

- **Ask the user which destination drive letter to use** (for example `D`, `E`, or `Q`). Do not assume Q or pick a drive silently. The canonical root is always `<DRIVE>:\agents`, and the remaining directory layout is unchanged.
- Record the selected drive letter and pass `-DriveLetter <letter>` to **every** script phase. Do not ask again during the same migration unless the user requests a change; never change drives after inventory without a new migration plan.

- Confirm the user approves the selected destination `<DRIVE>:\agents`.
- Confirm the selected drive exists, is writable, and has sufficient free space for the inventoried data and operational headroom. If it is removable, mapped, encrypted, or network-backed, assess persistence and startup availability; warn if unreliable.
- Confirm the script is present, inspect its parameters, and ensure it is not a symlink or unexpected file.
- Discover active agent processes and request closure before activation. The `-ConfirmAgentsStopped` flag is a **user/agent assertion**, not automatic process detection.
- Explain that per-agent source directories will become junctions and original contents will temporarily live in sibling `.qagents-migration-hold` directories.
- Confirm no existing manifest, hold directory, or target collision requires reconciliation. Do not overwrite an existing migration manifest.
- Review user-owned paths, secrets, ACLs, reparse points, and disk space. The script refuses reparse points in migrated trees; stop rather than bypass that protection.
- Do not assume hashes verify ACLs, alternate data streams, sparse file semantics, or all filesystem metadata. If those matter, add independent validation before cleanup.

## Execution: use the bundled script, sequentially

In the commands below, `$scriptPath` must be the absolute path of the reviewed bundled `scripts\migrate-agents.ps1`.

```powershell
$scriptPath = Join-Path $skillDirectory 'scripts\migrate-agents.ps1'
$driveLetter = '<USER_SELECTED_DRIVE_LETTER>' # replace after asking the user
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Bundled migration script missing: $scriptPath"
}
& $scriptPath -DriveLetter $driveLetter -Phase Inventory
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { throw 'Inventory failed' }
```

**Important:** For PowerShell scripts that throw terminating errors, catch exceptions or use `-ErrorAction Stop` in the caller; do not rely exclusively on `$LASTEXITCODE`, which is not a reliable success indicator for in-process PowerShell scripts.

Next, after reviewing the manifest at `<DRIVE>:\agents\registry\migration-manifest.json`, run:

```powershell
& $scriptPath -DriveLetter $driveLetter -Phase Copy
& $scriptPath -DriveLetter $driveLetter -Phase Verify
```

Do not proceed if either command fails, if files changed during copying, if inventory coverage is incomplete, or if any mismatch is detected. Inspect the registry and the script's status output:

```powershell
& $scriptPath -DriveLetter $driveLetter -Phase Status
```

After the user has closed affected agents and the agent has verified they are stopped, run:

```powershell
& $scriptPath -DriveLetter $driveLetter -Phase Activate -ConfirmAgentsStopped
```

The script renames each original source directory to a sibling hold directory and creates a legacy junction to the verified the selected drive destination. It must never be invoked on live directories with active writes. If activation fails, stop and diagnose. Do not delete the hold directory manually.

## Operational verification before cleanup

For **each** migrated agent, independently check:

1. The original legacy path resolves through a junction to the intended destination, not merely to some reparse point.
2. The agent launches successfully after activation.
3. Existing private skills, settings, memories, and plugins remain available.
4. A disposable new write through the agent's normal persistence mechanism lands on the selected drive; remove the test file afterwards.
5. The destination has the expected files and directory layout and no unexpected modifications or permission failures.
6. `& $scriptPath -DriveLetter $driveLetter -Phase Verify` succeeds after agent testing. Be aware the script compares the hold tree against the active destination: new writes made during testing can cause this check to fail. Reconcile differences without deleting new user data. Do **not** treat a failed comparison as permission to overwrite the destination.

If any agent cannot be launched or tested, label it **UNVERIFIED** and do not clean its source hold directory. You may use `-Agent <id>` for independently verified agents only.

To rehearse the phases before touching live data, run the bundled migration harness:

```powershell
$harness = Join-Path $skillDirectory 'tests\Test-MigrateAgents.ps1'
& $harness
```

It builds a throwaway profile and a unique sentinel-guarded folder under `%TEMP%`, maps two free drive letters to folders inside it with `subst`, and runs an unblocked copy of the script there. It covers the Copy, Verify, Activate and Cleanup refusal paths and recovery from interrupted copy, activation and cleanup, then unmaps the volumes and removes the folder. No existing drive root, `Q:\_admtest` path or agent data is touched; exit code 0 means every check passed. Run it only when the harness exists in the skill's `tests\` folder, and report its absence rather than reconstructing it.

## Cleanup: separately authorized, never implicit

The user requesting a migration or asking the agent to “do everything” is **not** sufficient authorization to erase the source directories without showing exact deletion paths and asking for final confirmation.

Before cleanup, show the user the list of exact `*.qagents-migration-hold` paths to be deleted, the verified backup destination, and the result of the operational tests. Ask for explicit approval to delete those paths. Never delete the legacy junctions, the destination, a project directory, or a parent user profile directory.

Require an existing, writable **independent** backup location on a different physical storage device where practical. The script checks drive letters, not physical-device independence: independently confirm this before proceeding. The script creates and hash-verifies a backup during Cleanup; ensure sufficient free space on the backup drive.

Only after explicit approval and all required validation:

```powershell
& $scriptPath -DriveLetter $driveLetter -Phase Cleanup `
    -Agent claude `
    -BackupRoot 'R:\agent-migration-backup' `
    -ConfirmAgentsValidated `
    -ApproveDeletion
```

`claude` and `R:\agent-migration-backup` are **examples**, not defaults. Choose the approved agent and actual backup path. To clean multiple agents, prefer one agent at a time and review each result. Never fabricate a backup path or claim validation occurred when it did not.

After cleanup, run Status, test the legacy junction again, and record the bytes reclaimed using actual before/after measurements if available. Keep the independent backup until the user chooses to retire it.

## Shared skills and ongoing use

The migration script creates `<DRIVE>:\agents\shared\skills` and `<DRIVE>:\agents\registry\skills.json`, but it does not rewrite any agent's native skill discovery path. Linkage is a separate step performed by the bundled `scripts\Link-SharedSkills.ps1`.

That helper is **manifest-driven and discovery-based**. It contains no per-agent skills path table, so it never links into a path nobody verified:

1. It reads `<DRIVE>:\agents\registry\migration-manifest.json` and takes each entry's `source` (the legacy path) and `destination`.
2. It requires the legacy path to be a junction whose target is that entry's `destination`. Entries whose junction is missing or redirected are reported `BLOCKED` and skipped.
3. It finds the agent's own skills directory inside the destination by searching for a directory named `skill` or `skills` (depth 3), excluding `builtin`, `plugins`, `extensions`, `.tmp`, `staging`, caches, sessions, projects and logs, so vendored plugin skills are not mistaken for the agent's own.
4. Exactly one candidate is `CONFIRMED`. Zero candidates, or several, are `UNCONFIRMED`: report the agent and create no link for it.
5. For a confirmed agent, each directory in the shared pool becomes one junction inside that skills directory. Existing names are skipped, never overwritten, and the whole skills directory is never replaced, so agent-private skills stay visible.

```powershell
$linkScript = Join-Path $skillDirectory 'scripts\Link-SharedSkills.ps1'
& $linkScript -DriveLetter $driveLetter          # report only
& $linkScript -DriveLetter $driveLetter -Apply    # create junctions
```

Always run the report-only form first and read the `CONFIRMED` / `UNCONFIRMED` / `BLOCKED` table. Run the helper only after `Activate`, or use `-IncludeHome` for a dry run against unlinked homes. Never invent a skills path for an `UNCONFIRMED` agent: confirm the real location from that agent's own documentation, then pass it with `-IncludeHome` to see how it classifies before linking. Results are recorded in `<DRIVE>:\agents\registry\skill-links.json`.

To exercise the linker without touching real agent directories, run the bundled scratch harness:

```powershell
$harness = Join-Path $skillDirectory 'tests\Test-LinkSharedSkills.ps1'
& $harness
```

It builds a throwaway agents root and profile in a unique sentinel-guarded folder under `%TEMP%`, maps a free drive letter to that folder with `subst`, then runs the linker against them in child processes. It covers report-only, apply, idempotent re-apply, a forced junction failure, a cross-agent partial run and a same-agent partial failure whose output carries `LINK FAILED (+N linked)`. The ACL deny rule, the volume mapping and the folder are removed at the end, and no existing drive root or `Q:\_admtest` path is touched; exit code 0 means every check passed. Run it only after confirming the harness exists in the skill's `tests\` folder; if it is missing, report that instead of reconstructing it.

Never replace agent-private skills with shared copies based solely on matching names, and do not copy credentials, private memories, or sessions into the shared pool. Agents with this skill should prefer `<DRIVE>:\agents` for supported persistent data and respect the legacy junctions. Do not promise universal enforcement across agents that do not have the skill installed or do not support relocation.

## Recovery and error handling

- Stop immediately on exceptions, mismatches, insufficient disk space, unexpected paths, or changed source data.
- Do not rerun `Inventory` when a manifest exists; use `Status` and inspect state.
- If a source was renamed but its junction was not created, restore the source only after checking that no newer data exists in the destination.
- If the destination is unavailable, do not silently write new persistent data back to `C:`.
- Never use `Remove-Item -Recurse` against arbitrary paths. Only the reviewed script's Cleanup phase may remove the specifically verified hold directories.
- Record all failures and request intervention instead of guessing or forcing progress.

## Completion report

Report which agents were discovered, copied, hash-verified, activated, operationally tested, and cleaned. Include unresolved paths, backup location, shared skill inventory status, which agents were linked, which were reported `UNCONFIRMED` or `BLOCKED`, and actual disk-space recovery. Use `COMPLETE` only for fully validated in-scope agents. Otherwise report `PARTIAL` or `FAILED` with reasons.
