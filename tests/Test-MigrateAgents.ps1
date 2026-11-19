#requires -Version 5.1
<#
.SYNOPSIS
  Scratch harness for scripts\migrate-agents.ps1.
.DESCRIPTION
  Runs the migration phases against a throwaway profile and two scratch volumes,
  covering the refusal paths for Copy, Verify, Activate and Cleanup, plus
  recovery from interrupted copy, activation and cleanup.

  Isolation is deliberate: every run creates a unique folder under %TEMP% with
  a random name and a sentinel file, maps two free drive letters to folders
  inside it with subst, and deletes only that folder after the sentinel matches
  this run. No existing drive root, Q:\_admtest path or real agent data is
  touched.

  Exit code 0 means every check passed.
.EXAMPLE
  powershell -NoProfile -File tests\Test-MigrateAgents.ps1
#>
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\migrate-agents.ps1'
if (-not (Test-Path -LiteralPath $sourceScriptPath -PathType Leaf)) { throw "migrate-agents.ps1 not found at $sourceScriptPath." }

$script:checks = 0
$script:failures = 0
function Check([bool]$Condition, [string]$Label) {
    $script:checks++
    if ($Condition) {
        Write-Host ("  PASS  {0}" -f $Label) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}" -f $Label) -ForegroundColor Red
        $script:failures++
    }
}
function Check-Text([string]$Output, [string]$Needle, [string]$Label) {
    $found = $Output.Contains($Needle)
    Check $found $Label
    if (-not $found) { Write-Host ("        expected: {0}" -f $Needle) -ForegroundColor DarkYellow }
}
function Add-File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Text
}
function Invoke-Migrate {
    param([string[]]$Arguments, [switch]$ExpectFailure)
    # Expected failures write to stderr; keep that from terminating the harness.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = & powershell.exe -NoProfile -File $scriptPath @Arguments 2>&1 }
    finally { $ErrorActionPreference = $previous }
    $code = $LASTEXITCODE
    $text = (@($lines) | ForEach-Object { "$_" }) -join "`n"
    if ($ExpectFailure) {
        Check ($code -ne 0) ("rejects: {0}" -f ($Arguments -join ' '))
    } else {
        Check ($code -eq 0) ("accepts: {0}" -f ($Arguments -join ' '))
        if ($code -ne 0) { Write-Host $text -ForegroundColor DarkYellow }
    }
    return $text
}
function New-ScratchVolume([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $letter = $null
    foreach ($c in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        if (Test-Path -LiteralPath ("{0}:\" -f $c)) { continue }
        $letter = [string]$c
        break
    }
    if (-not $letter) { throw 'No free drive letter for a scratch volume.' }
    & subst.exe "${letter}:" $Path | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath "${letter}:\")) {
        throw "subst failed: ${letter}: -> $Path"
    }
    $script:scratchLetters += $letter
    return $letter
}
function Read-Manifest { return (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json) }
function Read-Entry([string]$Id) { return @((Read-Manifest).entries | Where-Object { $_.id -eq $Id })[0] }

$runId = [guid]::NewGuid().ToString('N')
$tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$runRoot = Join-Path $tempBase ('adm-migrate-harness-' + $runId)
if (Test-Path -LiteralPath $runRoot) { throw "Refusing to reuse existing scratch root: $runRoot" }
New-Item -ItemType Directory -Path $runRoot | Out-Null
$sentinelPath = Join-Path $runRoot '.adm-migrate-harness'
Set-Content -LiteralPath $sentinelPath -Value $runId

$script:scratchLetters = @()
$realProfile = $env:USERPROFILE
$realAppData = $env:APPDATA
$rootLetter = ''
$backupLetter = ''
$fakeHome = ''
$manifestPath = ''
$scriptPath = ''

try {
    # Run an unblocked copy, so a downloaded script does not trip RemoteSigned while
    # the repository copy stays untouched.
    $scriptPath = Join-Path $runRoot 'migrate-agents.ps1'
    Copy-Item -LiteralPath $sourceScriptPath -Destination $scriptPath
    Unblock-File -LiteralPath $scriptPath

    $rootLetter = New-ScratchVolume (Join-Path $runRoot 'root')
    $backupLetter = New-ScratchVolume (Join-Path $runRoot 'backup')
    $root = "${rootLetter}:\agents"
    $backupRoot = "${backupLetter}:\backup"
    $manifestPath = Join-Path $runRoot 'root\agents\registry\migration-manifest.json'

    $fakeHome = Join-Path $runRoot 'profile'
    $env:USERPROFILE = $fakeHome
    $env:APPDATA = Join-Path $fakeHome 'AppData\Roaming'
    New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
    Add-File (Join-Path $fakeHome '.claude\settings.json') '{"theme":"dark"}'
    Add-File (Join-Path $fakeHome '.claude\skills\demo\SKILL.md') '# demo'
    Add-File (Join-Path $fakeHome '.cursor\notes.txt') 'cursor notes'
    Add-File (Join-Path $fakeHome '.gemini\config.json') '{"model":"x"}'

    $claudeSource = Join-Path $fakeHome '.claude'
    $claudeHold = $claudeSource + '.qagents-migration-hold'
    $claudeDest = Join-Path $root 'agents\claude'
    $cursorSource = Join-Path $fakeHome '.cursor'
    $cursorHold = $cursorSource + '.qagents-migration-hold'
    $cursorDest = Join-Path $root 'agents\cursor'
    $claudeSettings = Join-Path $claudeDest 'settings.json'
    $claudeBackup = Join-Path $backupRoot 'agents-claude'
    $cursorBackup = Join-Path $backupRoot 'agents-cursor'

    Write-Host ''
    Write-Host '=== inventory ==='
    Write-Host ("scratch root : {0}" -f $runRoot)
    Write-Host ("volumes      : {0}: and {1}:" -f $rootLetter, $backupLetter)
    $out = Invoke-Migrate @('-Phase', 'Inventory', '-DriveLetter', $rootLetter)
    Check (Test-Path -LiteralPath $manifestPath) 'inventory writes the manifest'
    Check ((Read-Manifest).entries.Count -eq 3) 'inventory records all three agents'
    Check ((Read-Entry 'claude').state -eq 'Inventoried') 'inventory marks claude Inventoried'
    Check (Test-Path -LiteralPath (Join-Path $runRoot 'root\agents\shared\skills')) 'inventory creates the skeleton'
    $out = Invoke-Migrate @('-Phase', 'Inventory', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Manifest already exists' 'inventory refuses to overwrite an existing manifest'

    Write-Host ''
    Write-Host '=== copy ==='
    # Interrupted copy: a partial destination must not be overwritten.
    New-Item -ItemType Directory -Path $cursorDest -Force | Out-Null
    Add-File (Join-Path $cursorDest 'partial.txt') 'partial'
    $out = Invoke-Migrate @('-Phase', 'Copy', '-Agent', 'cursor', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Destination exists' 'copy refuses an existing destination'
    Check ((Read-Entry 'cursor').state -eq 'Inventoried') 'refused copy leaves the state alone'
    Check (Test-Path -LiteralPath (Join-Path $cursorDest 'partial.txt')) 'refused copy leaves the partial destination intact'
    Remove-Item -LiteralPath $cursorDest -Recurse -Force

    $out = Invoke-Migrate @('-Phase', 'Copy', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Copied') 'copy records claude as Copied'
    $out = Invoke-Migrate @('-Phase', 'Copy', '-Agent', 'cursor', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'cursor').state -eq 'Copied') 'copy records cursor as Copied'
    $out = Invoke-Migrate @('-Phase', 'Copy', '-Agent', 'claude', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Cannot copy claude in state Copied' 'copy refuses an already copied agent'

    Write-Host ''
    Write-Host '=== verify ==='
    # Same length, different bytes: the size check passes, the hash check must fail.
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"lite"}'
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'claude', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'SHA-256 mismatch' 'verify rejects a changed destination file'
    Check ((Read-Entry 'claude').state -eq 'Copied') 'failed verify leaves the state Copied'
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"dark"}'
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Verified') 'verify records claude as Verified'
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'cursor', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'cursor').state -eq 'Verified') 'verify records cursor as Verified'
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'gemini', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Cannot verify state Inventoried' 'verify refuses an uncopied agent'

    Write-Host ''
    Write-Host '=== activate ==='
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'ConfirmAgentsStopped' 'activate requires the stopped-agent switch'
    New-Item -ItemType Directory -Path $claudeHold -Force | Out-Null
    Add-File (Join-Path $claudeHold 'leftover.txt') 'leftover'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Hold already exists' 'activate refuses an existing hold directory'
    Remove-Item -LiteralPath $claudeHold -Recurse -Force

    # Interrupted activation: source already renamed, junction never created.
    Rename-Item -LiteralPath $cursorSource -NewName ([IO.Path]::GetFileName($cursorHold))
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Hold already exists' 'half-activated source is reported, not overwritten'
    Check (-not (Test-Path -LiteralPath $cursorSource)) 'half-activated source has no junction yet'
    Rename-Item -LiteralPath $cursorHold -NewName ([IO.Path]::GetFileName($cursorSource))

    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Activated') 'activate records claude as Activated'
    $claudeLink = Get-Item -LiteralPath $claudeSource -Force
    Check ($claudeLink.LinkType -eq 'Junction') 'claude legacy path is a junction'
    $claudeTargets = @($claudeLink.Target)
    Check ($claudeTargets.Count -gt 0 -and $claudeTargets[0] -ieq $claudeDest) 'claude junction targets the destination'
    Check (Test-Path -LiteralPath (Join-Path $claudeSource 'settings.json')) 'claude data reads through the junction'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'cursor').state -eq 'Activated') 'activate records cursor as Activated'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'gemini', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'must be Verified before activation' 'activate refuses an unverified agent'
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check ($out.Contains('Verified: claude')) 'verify accepts the hold after activation'

    Write-Host ''
    Write-Host '=== status reconciliation ==='
    $out = Invoke-Migrate @('-Phase', 'Status', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees with a healthy state'

    [IO.Directory]::Delete($claudeSource)
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'legacy junction missing' 'status reports a missing legacy junction'
    New-Item -ItemType Junction -Path $claudeSource -Target $claudeDest | Out-Null

    [IO.Directory]::Delete($claudeSource)
    $decoy = Join-Path $root 'agents\decoy-status'
    New-Item -ItemType Directory -Path $decoy -Force | Out-Null
    New-Item -ItemType Junction -Path $claudeSource -Target $decoy | Out-Null
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'legacy junction redirected' 'status reports a redirected junction'
    [IO.Directory]::Delete($claudeSource)
    New-Item -ItemType Junction -Path $claudeSource -Target $claudeDest | Out-Null

    Rename-Item -LiteralPath $claudeHold -NewName ([IO.Path]::GetFileName($claudeHold) + '.away')
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'hold missing' 'status reports a missing hold'
    Rename-Item -LiteralPath ($claudeHold + '.away') -NewName ([IO.Path]::GetFileName($claudeHold))

    Rename-Item -LiteralPath $claudeDest -NewName 'claude.away'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'destination missing or unavailable' 'status reports an unavailable destination'
    Rename-Item -LiteralPath (Join-Path $root 'agents\claude.away') -NewName 'claude'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees again after the restores'

    Write-Host ''
    Write-Host '=== rollback ==='
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'cursor', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'ConfirmAgentsStopped' 'rollback requires the stopped-agent switch'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'ApproveRollback' 'rollback requires explicit approval'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'gemini', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Cannot roll back gemini in state Inventoried' 'rollback refuses an agent that was never activated'
    Check ((Read-Entry 'cursor').state -eq 'Activated') 'refused rollback leaves the state alone'

    # A destination that changed since activation must not be stranded by a rollback.
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"lite"}'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Destination changed since activation' 'rollback refuses a changed destination'
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"dark"}'

    # Only a junction known to point at this destination may be removed.
    [IO.Directory]::Delete($claudeSource)
    $decoy = Join-Path $root 'agents\decoy'
    New-Item -ItemType Directory -Path $decoy -Force | Out-Null
    New-Item -ItemType Junction -Path $claudeSource -Target $decoy | Out-Null
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Legacy junction points elsewhere' 'rollback refuses a redirected junction'
    Check ((Get-Item -LiteralPath $claudeSource -Force).LinkType -eq 'Junction') 'redirected junction is left in place'
    [IO.Directory]::Delete($claudeSource)
    New-Item -ItemType Junction -Path $claudeSource -Target $claudeDest | Out-Null
    Check ((Read-Entry 'claude').state -eq 'Activated') 'failed rollback leaves claude Activated'

    # Successful rollback: restore the hold, remove only the junction, keep the destination.
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter)
    Check (-not (Test-Path -LiteralPath $cursorHold)) 'rollback renames the hold back'
    $restored = Get-Item -LiteralPath $cursorSource -Force
    Check ((($restored.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'rollback restores a real directory'
    Check (Test-Path -LiteralPath (Join-Path $cursorSource 'notes.txt')) 'restored source has its data'
    Check (Test-Path -LiteralPath (Join-Path $cursorDest 'notes.txt')) 'rollback leaves the destination in place'
    Check ((Read-Entry 'cursor').state -eq 'Verified') 'rollback returns the entry to Verified'
    Check (-not [string]::IsNullOrWhiteSpace((Read-Entry 'cursor').rolledBackUtc)) 'rollback records when it happened'

    # Half-rollback: junction already gone, hold still present, state still Activated.
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'cursor').state -eq 'Activated') 'rolled-back agent can be activated again'
    [IO.Directory]::Delete($cursorSource)
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter)
    $restored = Get-Item -LiteralPath $cursorSource -Force
    Check ((($restored.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'half-rollback resumes and restores the hold'
    Check ((Read-Entry 'cursor').state -eq 'Verified') 'resumed rollback records Verified'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'cursor').state -eq 'Activated') 'restored agent can be activated after the resume'

    Write-Host ''
    Write-Host '=== cleanup refusals ==='
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'backup') -Force | Out-Null
    $sameVolumeBackup = Join-Path $root 'backup'
    $sourceVolumeBackup = Join-Path $runRoot 'cbackup'
    New-Item -ItemType Directory -Path $sourceVolumeBackup -Force | Out-Null

    $cleanup = @('-Phase', 'Cleanup', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    $out = Invoke-Migrate ($cleanup) -ExpectFailure
    Check-Text $out 'ConfirmAgentsValidated' 'cleanup requires the validated switch'
    $out = Invoke-Migrate ($cleanup + @('-ConfirmAgentsValidated')) -ExpectFailure
    Check-Text $out 'ApproveDeletion' 'cleanup requires explicit deletion approval'
    $out = Invoke-Migrate ($cleanup + @('-ConfirmAgentsValidated', '-ApproveDeletion')) -ExpectFailure
    Check-Text $out 'BackupRoot is required' 'cleanup requires a backup root'
    $out = Invoke-Migrate ($cleanup + @('-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', (Join-Path $root 'missing'))) -ExpectFailure
    Check-Text $out 'BackupRoot must exist' 'cleanup refuses a missing backup root'
    $out = Invoke-Migrate ($cleanup + @('-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $sameVolumeBackup)) -ExpectFailure
    Check-Text $out 'different drive than the destination' 'cleanup refuses a backup on the destination drive'
    $out = Invoke-Migrate ($cleanup + @('-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $sourceVolumeBackup)) -ExpectFailure
    Check-Text $out 'different drive than each source' 'cleanup refuses a backup on the source drive'
    $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'gemini', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot) -ExpectFailure
    Check-Text $out 'Not activated: gemini' 'cleanup refuses an agent that was never activated'
    Check (Test-Path -LiteralPath $claudeHold) 'refused cleanups leave the hold intact'

    Write-Host ''
    Write-Host '=== cleanup and interrupted recovery ==='
    $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'cursor', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot)
    Check (-not (Test-Path -LiteralPath $cursorHold)) 'cleanup removes the verified hold'
    Check (Test-Path -LiteralPath $cursorBackup) 'cleanup keeps the independent backup'
    Check ((Read-Entry 'cursor').state -eq 'Complete') 'cleanup records cursor as Complete'
    Check (Test-Path -LiteralPath (Join-Path $cursorSource 'notes.txt')) 'cleanup leaves the junction readable'

    # Genuine interruption: every hold file is open without delete sharing, so the backup
    # is copied and verified and the state is saved, but Remove-Item cannot delete the hold.
    $holdHandles = @()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $claudeHold -Recurse -File)) {
            $holdHandles += [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        }
        $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot) -ExpectFailure
        Check (Test-Path -LiteralPath $claudeHold) 'failed cleanup keeps the hold'
        Check (Test-Path -LiteralPath $claudeBackup) 'failed cleanup keeps the verified backup'
        Check ((Read-Entry 'claude').state -eq 'BackupVerified') 'failed cleanup records BackupVerified'
    }
    finally {
        foreach ($handle in $holdHandles) { $handle.Dispose() }
    }
    $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot)
    Check (-not (Test-Path -LiteralPath $claudeHold)) 'resumed cleanup removes the remaining hold'
    Check (Test-Path -LiteralPath $claudeBackup) 'resumed cleanup reuses the verified backup'
    Check ((Read-Entry 'claude').state -eq 'Complete') 'resumed cleanup records claude as Complete'

    Write-Host ''
    Write-Host '=== final state ==='
    Check (Test-Path -LiteralPath (Join-Path $claudeSource 'settings.json')) 'claude destination survives cleanup'
    Check (Test-Path -LiteralPath (Join-Path $cursorSource 'notes.txt')) 'cursor destination survives cleanup'
    Check ((Read-Entry 'gemini').state -eq 'Inventoried') 'untouched agent keeps its state'
    Check ((Read-Manifest).schema -eq 1) 'manifest schema is unchanged'
    $out = Invoke-Migrate @('-Phase', 'Status', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after cleanup'
}
finally {
    $env:USERPROFILE = $realProfile
    $env:APPDATA = $realAppData

    if ($fakeHome) {
        foreach ($legacy in @((Join-Path $fakeHome '.claude'), (Join-Path $fakeHome '.cursor'))) {
            if (Test-Path -LiteralPath $legacy) {
                $item = Get-Item -LiteralPath $legacy -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [IO.Directory]::Delete($legacy) }
            }
        }
    }
    foreach ($letter in $script:scratchLetters) { & subst.exe "${letter}:" /D | Out-Null }

    $removable = $false
    if (Test-Path -LiteralPath $sentinelPath) {
        $token = (Get-Content -LiteralPath $sentinelPath -Raw).Trim()
        $insideTemp = ([IO.Path]::GetFullPath($runRoot)).StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)
        $removable = ($token -eq $runId) -and $insideTemp -and ((Split-Path $runRoot -Leaf) -like 'adm-migrate-harness-*')
    }
    if ($removable) { Remove-Item -LiteralPath $runRoot -Recurse -Force }
    else { Write-Host "WARNING: sentinel mismatch; leaving scratch root $runRoot" -ForegroundColor Yellow }

    Check (-not (Test-Path -LiteralPath $runRoot)) 'scratch root removed'
    foreach ($letter in $script:scratchLetters) {
        Check (-not (Test-Path -LiteralPath "${letter}:\")) ("scratch volume ${letter}: unmapped")
    }
    Write-Host ''
    Write-Host ("checks: {0} run, {1} failed" -f $script:checks, $script:failures)
}
if ($script:failures -gt 0) { exit 1 }
Write-Host 'all checks passed'
exit 0
