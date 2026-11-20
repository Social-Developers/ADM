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
function Wait-ForFile([string]$Path, [int]$TimeoutSeconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    return (Test-Path -LiteralPath $Path)
}
function Start-Migrate {
    param([string[]]$Arguments, [string]$UseScript = '', [hashtable]$Environment = @{})
    if ([string]::IsNullOrWhiteSpace($UseScript)) { $UseScript = $scriptPath }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $quoted = @('-NoProfile', '-File', ('"' + $UseScript + '"'))
    foreach ($arg in @($Arguments)) {
        if ($arg -match '[\s"]') { $quoted += ('"' + ($arg -replace '"', '\"') + '"') } else { $quoted += $arg }
    }
    $psi.Arguments = ($quoted -join ' ')
    foreach ($key in @($Environment.Keys)) { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = [System.Diagnostics.Process]::Start($psi)
    return [pscustomobject]@{
        Process = $process
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
        Arguments = @($Arguments)
    }
}
function Complete-Migrate {
    param([object]$Handle, [switch]$ExpectFailure, [int]$TimeoutSeconds = 180, [int]$ExpectedExitCode = -999)
    if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $Handle.Process.Kill() } catch { }
        try { & taskkill.exe /T /F /PID $Handle.Process.Id 2>&1 | Out-Null } catch { }
        throw "Migration command timed out after $TimeoutSeconds seconds: $($Handle.Arguments -join ' ')"
    }
    $code = $Handle.Process.ExitCode
    $text = ($Handle.Stdout.Result + "`n" + $Handle.Stderr.Result)
    if ($ExpectFailure) {
        Check ($code -ne 0) ("rejects: {0}" -f ($Handle.Arguments -join ' '))
    } else {
        Check ($code -eq 0) ("accepts: {0}" -f ($Handle.Arguments -join ' '))
        if ($code -ne 0) { Write-Host $text -ForegroundColor DarkYellow }
    }
    if ($ExpectedExitCode -ne -999) { Check ($code -eq $ExpectedExitCode) ("exit code {0} for: {1}" -f $ExpectedExitCode, ($Handle.Arguments -join ' ')) }
    return $text
}
function Invoke-Migrate {
    param([string[]]$Arguments, [switch]$ExpectFailure, [string]$UseScript = '', [int]$TimeoutSeconds = 180, [int]$ExpectedExitCode = -999)
    $handle = Start-Migrate -Arguments $Arguments -UseScript $UseScript
    return Complete-Migrate -Handle $handle -ExpectFailure:$ExpectFailure -TimeoutSeconds $TimeoutSeconds -ExpectedExitCode $ExpectedExitCode
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
    $crashScriptPath = Join-Path $runRoot 'migrate-agents-crash.ps1'
    $crashText = Get-Content -LiteralPath $scriptPath -Raw
    $failpointNeedle = 'Move-Item -LiteralPath $staging -Destination $snapshot -ErrorAction Stop'
    if (-not $crashText.Contains($failpointNeedle)) { throw 'Cannot install the snapshot crash failpoint.' }
    $crashText = $crashText.Replace($failpointNeedle, $failpointNeedle + "`n        if (`$env:ADM_TEST_FAILPOINT -eq 'AfterSnapshotRename') { [Environment]::Exit(99) }")
    $restoreFailpointNeedle = 'Rename-Item -LiteralPath $e.destination -NewName (Split-Path $backupDest -Leaf) -ErrorAction Stop'
    if (-not $crashText.Contains($restoreFailpointNeedle)) { throw 'Cannot install the restore crash failpoint.' }
    $crashText = $crashText.Replace($restoreFailpointNeedle, $restoreFailpointNeedle + "`n            if (`$env:ADM_TEST_FAILPOINT -eq 'AfterDestinationRename') { [Environment]::Exit(98) }")
    $pruneFailpointNeedle = 'Move-Item -LiteralPath $full -Destination $deleting -ErrorAction Stop'
    if (-not $crashText.Contains($pruneFailpointNeedle)) { throw 'Cannot install the prune crash failpoint.' }
    $crashText = $crashText.Replace($pruneFailpointNeedle, $pruneFailpointNeedle + "`n                if (`$env:ADM_TEST_FAILPOINT -eq 'AfterPruneRename') { [Environment]::Exit(97) }")
    Set-Content -LiteralPath $crashScriptPath -Value $crashText
    Unblock-File -LiteralPath $crashScriptPath

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
    $geminiSource = Join-Path $fakeHome '.gemini'
    $geminiHold = $geminiSource + '.qagents-migration-hold'
    $geminiDest = Join-Path $root 'agents\gemini'
    $claudeSettings = Join-Path $claudeDest 'settings.json'
    $claudeBackup = Join-Path $backupRoot 'agents-claude'
    $cursorBackup = Join-Path $backupRoot 'agents-cursor'
    $geminiBackup = Join-Path $backupRoot 'agents-gemini'

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
    Check (Test-Path -LiteralPath ($manifestPath + '.bak')) 'manifest updates keep a backup copy'
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'cursor', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'cursor').state -eq 'Verified') 'verify records cursor as Verified'
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'gemini', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Cannot verify state Inventoried' 'verify refuses an uncopied agent'

    Write-Host ''
    Write-Host '=== activate preview ==='
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-WhatIf')
    Check-Text $out 'What if:' 'activate previews without the stopped-agent switch'
    Check (Test-Path -LiteralPath $claudeSource -PathType Container) 'activate preview keeps the source directory'
    Check (-not (Test-Path -LiteralPath $claudeHold)) 'activate preview creates no hold'
    Check ((Read-Entry 'claude').state -eq 'Verified') 'activate preview leaves the state Verified'

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

    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-AsJson', '-Strict')
    $json = $out | ConvertFrom-Json
    Check ($json.healthy -eq $true -and $json.issueCount -eq 0) 'status JSON reports a healthy state'
    Check (@($json.entries | Where-Object { $_.id -eq 'claude' }).Count -eq 1) 'status JSON includes the selected entry'

    $activeStaging = Join-Path $root 'migration\rollbacks\.incomplete-claude-active'
    Add-File (Join-Path $activeStaging 'partial.txt') 'partial'
    $leasePath = Join-Path $root 'migration\rollbacks\.snapshot-lease.json'
    $lease = [pscustomobject]@{ pid = $PID; host = [Environment]::MachineName; agent = 'claude'; startedUtc = [DateTime]::UtcNow.ToString('o'); staging = $activeStaging; snapshot = '' }
    $lease | ConvertTo-Json | Set-Content -LiteralPath $leasePath
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'Snapshot operation in progress' 'status reports an active snapshot operation'
    Check (-not $out.Contains('.incomplete-claude-active')) 'status does not call active staging orphaned'
    $historyBefore = 0
    $historyProperty = (Read-Entry 'claude').PSObject.Properties['destinationSnapshots']
    if ($null -ne $historyProperty) { $historyBefore = @($historyProperty.Value).Count }
    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Snapshot operation already in progress' 'prune refuses while another snapshot phase is active'
    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Snapshot operation already in progress' 'adopt refuses while another snapshot phase is active'
    Check (Test-Path -LiteralPath $leasePath) 'refused snapshot phases leave the active lease in place'
    $historyAfter = 0
    $historyProperty = (Read-Entry 'claude').PSObject.Properties['destinationSnapshots']
    if ($null -ne $historyProperty) { $historyAfter = @($historyProperty.Value).Count }
    Check ($historyAfter -eq $historyBefore) 'refused snapshot phases leave history unchanged'
    $lease.pid = 999999
    $lease | ConvertTo-Json | Set-Content -LiteralPath $leasePath
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'Stale snapshot operation lease' 'status reports a stale snapshot lease'
    Check-Text $out 'Orphaned snapshot staging' 'stale lease leaves staging orphaned'
    Remove-Item -LiteralPath $leasePath -Force
    Remove-Item -LiteralPath $activeStaging -Recurse -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees again after clearing the active lease'

    $orphanStaging = Join-Path $root 'migration\rollbacks\.incomplete-claude-orphan'
    Add-File (Join-Path $orphanStaging 'partial.txt') 'partial'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'Orphaned snapshot staging' 'status reports orphaned snapshot staging'
    Check-Text $out '.incomplete-claude-orphan' 'status names the orphaned staging folder'
    Check-Text $out 'Status found 1 issue(s)' 'status counts the orphaned staging folder'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-AsJson', '-Strict') -ExpectFailure -ExpectedExitCode 2
    $json = $out | ConvertFrom-Json
    Check (@($json.issues | Where-Object { $_.code -eq 'staging_orphaned' }).Count -eq 1) 'status JSON exposes stable issue codes'
    Remove-Item -LiteralPath $orphanStaging -Recurse -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees again after clearing the staging folder'

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
    Write-Host '=== snapshot space preflight ==='
    # A genuinely full volume cannot be built without affecting the host, so parse
    # and load the space helpers from the script under test and inject availability.
    $spaceSource = Join-Path $runRoot 'space-source'
    New-Item -ItemType Directory -Path (Join-Path $spaceSource 'nested') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $spaceSource 'small.bin'), ('a' * 1024))
    [IO.File]::WriteAllText((Join-Path $spaceSource 'nested\large.bin'), ('b' * 2048))
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    Check (@($parseErrors).Count -eq 0) 'migration script parses for helper extraction'
    $helperNames = @('Assert-Condition', 'FullPath', 'Files-In', 'Get-ClusterSize', 'Get-SnapshotRequiredBytes', 'Assert-SnapshotSpace', 'Get-SnapshotBaseName', 'Resolve-SnapshotPath')
    $helpers = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $helperNames -contains $node.Name
            }, $true))
    Check ($helpers.Count -eq $helperNames.Count) 'snapshot space helpers are defined'
    foreach ($helper in $helpers) { . ([scriptblock]::Create($helper.Extent.Text)) }
    Check ((Get-SnapshotRequiredBytes $spaceSource) -eq ([long](1024 + 2048) + 1MB)) 'required space sums nested file sizes plus the reserve'
    $emptySource = Join-Path $runRoot 'space-empty'
    New-Item -ItemType Directory -Path $emptySource -Force | Out-Null
    Check ((Get-SnapshotRequiredBytes $emptySource) -eq 1MB) 'empty snapshot needs only the reserve'
    $required = Get-SnapshotRequiredBytes $spaceSource
    $spaceError = $null
    try { Assert-SnapshotSpace $spaceSource $root ($required - 1) } catch { $spaceError = $_.Exception.Message }
    Check (-not [string]::IsNullOrWhiteSpace([string]$spaceError)) 'insufficient free space is refused'
    Check-Text ([string]$spaceError) 'Insufficient free space for destination snapshot' 'refusal names the free-space condition'
    Check-Text ([string]$spaceError) ("need {0} bytes, have {1}." -f $required, ($required - 1)) 'refusal reports required and available bytes'
    $spaceAccepted = $true
    try { Assert-SnapshotSpace $spaceSource $root $required } catch { $spaceAccepted = $false }
    Check $spaceAccepted 'exactly the required space is accepted'
    $measured = $true
    try { Assert-SnapshotSpace $spaceSource $root } catch { $measured = $false }
    Check $measured 'real free-space measurement accepts the scratch volume'
    Check ((Get-SnapshotRequiredBytes $spaceSource 4096) -eq (([long]4096 * 2) + 1MB)) 'cluster-aware preflight rounds files up to allocation units'
    $collisionBase = Join-Path $runRoot 'snapshot-name-collision'
    New-Item -ItemType Directory -Path $collisionBase -Force | Out-Null
    $fixedTimestamp = [DateTime]::ParseExact('20260101T000000000Z', 'yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    $firstName = Resolve-SnapshotPath $collisionBase 'claude' $fixedTimestamp
    New-Item -ItemType Directory -Path $firstName -Force | Out-Null
    $secondName = Resolve-SnapshotPath $collisionBase 'claude' $fixedTimestamp
    Check ((Split-Path $secondName -Leaf) -eq 'claude-20260101T000000000Z-2') 'snapshot naming avoids collisions'

    Write-Host ''
    Write-Host '=== rollback ==='
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-WhatIf')
    Check-Text $out 'What if:' 'rollback previews without approval switches'
    Check (Test-Path -LiteralPath $claudeSource) 'rollback preview leaves the junction'
    Check (Test-Path -LiteralPath $claudeHold) 'rollback preview leaves the hold'
    Check ((Read-Entry 'claude').state -eq 'Activated') 'rollback preview leaves the state alone'
    Check ($null -eq (Read-Entry 'claude').PSObject.Properties['destinationSnapshot']) 'rollback preview records no snapshot'

    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'cursor', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'ConfirmAgentsStopped' 'rollback requires the stopped-agent switch'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'ApproveRollback' 'rollback requires explicit approval'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'gemini', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Cannot roll back gemini in state Inventoried' 'rollback refuses an agent that was never activated'
    Check ((Read-Entry 'cursor').state -eq 'Activated') 'refused rollback leaves the state alone'

    # A destination that changed since activation needs the explicit override.
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"lite"}'
    Add-File (Join-Path $claudeDest 'added.txt') 'new data'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Destination changed since activation' 'rollback refuses a changed destination'
    Check-Text $out 'destination differs' 'rollback summarizes the changed destination'
    Check-Text $out 'added=1 removed=0 changed=1' 'counts the added and changed files'
    Check ((Read-Entry 'claude').state -eq 'Activated') 'refused rollback keeps claude Activated'

    # Cleanup that cannot remove a locked staging folder must abort before copying.
    $rollbacksRoot = Join-Path $root 'migration\rollbacks'
    $lockedStaging = Join-Path $rollbacksRoot '.incomplete-claude-locked'
    Add-File (Join-Path $lockedStaging 'locked.txt') 'locked'
    $lock = [IO.File]::Open((Join-Path $lockedStaging 'locked.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DriveLetter', $rootLetter) -ExpectFailure
    } finally {
        $lock.Dispose()
    }
    Check-Text $out 'Snapshot staging cleanup failed' 'locked staging cleanup aborts the rollback'
    Check (Test-Path -LiteralPath $claudeHold) 'locked staging cleanup keeps the hold'
    Check ((Read-Entry 'claude').state -eq 'Activated') 'locked staging cleanup keeps claude Activated'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'locked staging cleanup removes the lease'
    Remove-Item -LiteralPath $lockedStaging -Recurse -Force

    # A failed snapshot copy must leave no staging or final folder and no manifest entry.
    # Put a fake robocopy.exe on PATH so only the snapshot copy fails.
    $rollbacksRoot = Join-Path $root 'migration\rollbacks'
    $stale = Join-Path $rollbacksRoot '.incomplete-claude-stale'
    Add-File (Join-Path $stale 'partial.txt') 'partial'
    $fakeTools = Join-Path $runRoot 'fake-tools'
    New-Item -ItemType Directory -Path $fakeTools -Force | Out-Null
    Add-Type -TypeDefinition 'public static class FakeRobocopy { public static int Main(string[] args) { return 8; } }' -OutputAssembly (Join-Path $fakeTools 'robocopy.exe') -OutputType ConsoleApplication
    $savedPath = $env:PATH
    $env:PATH = $fakeTools + ';' + $savedPath
    try {
        $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DriveLetter', $rootLetter) -ExpectFailure
    } finally { $env:PATH = $savedPath }
    Check-Text $out 'Snapshot copy failed' 'failed snapshot copy aborts the rollback'
    Check (-not (Test-Path -LiteralPath $stale)) 'stale incomplete snapshot is cleared before copying'
    $partials = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force -Filter '.incomplete-*')
    Check ($partials.Count -eq 0) 'failed snapshot copy leaves no staging folder'
    $finals = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force | Where-Object { $_.Name -notlike '.incomplete-*' })
    Check ($finals.Count -eq 0) 'failed snapshot copy leaves no final folder'
    Check ((Read-Entry 'claude').state -eq 'Activated') 'failed snapshot copy leaves claude Activated'
    Check ($null -eq (Read-Entry 'claude').PSObject.Properties['destinationSnapshot']) 'failed snapshot copy records no snapshot'
    Check (Test-Path -LiteralPath $claudeHold) 'failed snapshot copy keeps the hold'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'failed snapshot copy removes the lease'

    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DriveLetter', $rootLetter)
    Check (-not (Test-Path -LiteralPath $claudeHold)) 'accepted rollback restores the hold'
    $finals = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force | Where-Object { $_.Name -notlike '.incomplete-*' })
    Check ($finals.Count -eq 1) 'retry after a failed copy creates exactly one snapshot'
    $partials = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force -Filter '.incomplete-*')
    Check ($partials.Count -eq 0) 'successful snapshot leaves no staging folder'
    Check (Test-Path -LiteralPath (Join-Path $claudeDest 'added.txt')) 'accepted rollback preserves the changed destination'
    $rolledBack = Read-Entry 'claude'
    Check ($rolledBack.rolledBackWithChanges -eq $true) 'rollback records the changed destination'
    Check ($rolledBack.destinationChanges.added -eq 1 -and $rolledBack.destinationChanges.changed -eq 1) 'rollback records the change counts'
    Check ($rolledBack.state -eq 'Verified') 'accepted rollback returns the entry to Verified'
    $snapshot = $rolledBack.destinationSnapshot
    Check (-not [string]::IsNullOrWhiteSpace($snapshot)) 'rollback records the destination snapshot'
    Check ($snapshot.StartsWith((Join-Path $root 'migration\rollbacks'), [StringComparison]::OrdinalIgnoreCase)) 'snapshot lives under migration\rollbacks'
    Check (Test-Path -LiteralPath (Join-Path $snapshot 'added.txt')) 'snapshot contains the added file'
    Check ((Get-Content -LiteralPath (Join-Path $snapshot 'settings.json') -Raw) -match 'lite') 'snapshot contains the changed file'
    Check (-not [string]::IsNullOrWhiteSpace($rolledBack.destinationSnapshotHash)) 'rollback records the snapshot hash'
    Check ($rolledBack.destinationSnapshotDigestVersion -eq 2) 'rollback records the directory-aware digest version'
    Check ($rolledBack.destinationSnapshots[0].hash -eq $rolledBack.destinationSnapshotHash) 'snapshot history records the hash'
    Check ($rolledBack.destinationSnapshots[0].digestVersion -eq 2) 'snapshot history records the digest version'
    Check ($rolledBack.destinationSnapshots[0].bytes -gt 0) 'snapshot history records the size'
    Check (@($rolledBack.destinationSnapshots | Where-Object { $_.path -eq $snapshot }).Count -eq 1) 'rollback records the snapshot in its history'
    Check (Test-Path -LiteralPath ($snapshot + '.snapshot.json')) 'snapshot writes a sidecar'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status accepts an intact destination snapshot'

    # A snapshot referenced by an unselected entry must not look unreferenced.
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'cursor', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status ignores referenced snapshots for unselected agents'

    # A crash after the snapshot rename but before the manifest update leaves this folder.
    $unreferenced = Join-Path $rollbacksRoot 'claude-20260101T000000000Z'
    Add-File (Join-Path $unreferenced 'orphan.txt') 'orphan'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'cursor', '-DriveLetter', $rootLetter)
    Check-Text $out 'Unreferenced destination snapshot folder' 'status reports an unreferenced final snapshot folder for any selected agent'
    Check-Text $out 'claude-20260101T000000000Z' 'status names the unreferenced snapshot folder'
    Check-Text $out 'Status found 1 issue(s)' 'status counts the unreferenced snapshot folder'
    Remove-Item -LiteralPath $unreferenced -Recurse -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees again after removing the unreferenced snapshot'

    $snapshotAway = $snapshot + '.away'
    Rename-Item -LiteralPath $snapshot -NewName ([IO.Path]::GetFileName($snapshotAway))
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'destination snapshot missing' 'status reports a missing destination snapshot'
    Rename-Item -LiteralPath $snapshotAway -NewName ([IO.Path]::GetFileName($snapshot))

    Add-File (Join-Path $snapshot 'intruder.txt') 'tampered'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'destination snapshot corrupted' 'status reports a corrupted destination snapshot'
    Remove-Item -LiteralPath (Join-Path $snapshot 'intruder.txt') -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees again after the snapshot restore'

    # Reconcile the destination and activate again for the later cleanup cases.
    Remove-Item -LiteralPath (Join-Path $claudeDest 'added.txt') -Force
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"dark"}'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Activated') 'reconciled agent can be activated again'
    Check (Test-Path -LiteralPath (Join-Path $snapshot 'added.txt')) 'snapshot survives later destination reconciliation'

    # A destination missing a file must be reported as removed and still preserved.
    Remove-Item -LiteralPath $claudeSettings -Force
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'removed=1' 'rollback reports a file missing from the destination'
    Check-Text $out 'settings.json' 'rollback names the removed file'
    Check ((Read-Entry 'claude').state -eq 'Activated') 'missing-file refusal keeps claude Activated'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DriveLetter', $rootLetter)
    Check (-not (Test-Path -LiteralPath $claudeSettings)) 'accepted rollback preserves the missing destination file'
    Check (Test-Path -LiteralPath (Join-Path $claudeDest 'skills\demo\SKILL.md')) 'accepted rollback keeps the rest of the destination'
    Check (Test-Path -LiteralPath (Join-Path $claudeSource 'settings.json')) 'accepted rollback restores the missing source file'
    $removedEntry = Read-Entry 'claude'
    Check ($removedEntry.destinationChanges.removed -eq 1) 'rollback records the removed file count'
    Check ($removedEntry.destinationSnapshot -ne $snapshot) 'each accepted rollback gets its own snapshot'
    Check (@($removedEntry.destinationSnapshots).Count -eq 2) 'each accepted rollback appends to the snapshot history'
    Check (@($removedEntry.destinationSnapshots | Where-Object { $_.path -eq $snapshot }).Count -eq 1) 'snapshot history retains the earlier snapshot'
    Check (-not (Test-Path -LiteralPath (Join-Path $removedEntry.destinationSnapshot 'settings.json'))) 'snapshot captures the removed file state'
    Check ($removedEntry.state -eq 'Verified') 'removed-file rollback returns the entry to Verified'

    $olderSnapshot = @($removedEntry.destinationSnapshots | Where-Object { $_.path -eq $snapshot })[0].path
    $emptyDir = Join-Path $olderSnapshot 'empty-dir'
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-Quick')
    Check-Text $out 'manifest matches disk' 'quick status skips snapshot hashing'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'snapshot history corrupted' 'status detects directory tampering in snapshot history'
    Remove-Item -LiteralPath $emptyDir -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status accepts the restored historical snapshot'

    # A tampered historical snapshot must be rejected before its bytes are hashed.
    $historyTamperTarget = Join-Path $runRoot 'history-tamper-target'
    New-Item -ItemType Directory -Path $historyTamperTarget -Force | Out-Null
    $historyJunction = Join-Path $olderSnapshot 'history-junction'
    New-Item -ItemType Junction -Path $historyJunction -Target $historyTamperTarget | Out-Null
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'snapshot history contains a reparse point' 'status rejects a reparse point in snapshot history'
    [IO.Directory]::Delete($historyJunction)
    Remove-Item -LiteralPath $historyTamperTarget -Recurse -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status accepts history after removing the reparse point'

    Rename-Item -LiteralPath $olderSnapshot -NewName ([IO.Path]::GetFileName($olderSnapshot) + '.away')
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'snapshot history missing' 'status reports a missing historical snapshot'
    Rename-Item -LiteralPath ($olderSnapshot + '.away') -NewName ([IO.Path]::GetFileName($olderSnapshot))
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status accepts the restored historical snapshot'

    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-DriveLetter', $rootLetter, '-WhatIf')
    Check-Text $out 'would prune snapshot' 'prune previews without approval'
    Check (Test-Path -LiteralPath $olderSnapshot) 'prune preview keeps the older snapshot'
    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'ApproveSnapshotDeletion' 'prune requires explicit approval'
    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter)
    Check (-not (Test-Path -LiteralPath $olderSnapshot)) 'prune removes the older snapshot'
    Check (-not (Test-Path -LiteralPath ($olderSnapshot + '.snapshot.json'))) 'prune removes the older snapshot sidecar'
    Check ((Read-Entry 'claude').destinationSnapshots.Count -eq 1) 'prune updates the snapshot history'
    Check (Test-Path -LiteralPath $removedEntry.destinationSnapshot) 'prune keeps the latest snapshot'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'prune releases its lease'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after pruning'

    # A crash after moving a pruned snapshot aside but before the manifest update.
    $pruneCrash = Join-Path $rollbacksRoot 'claude-20200101T000000000Z'
    Add-File (Join-Path $pruneCrash 'pending-delete.txt') 'pending deletion'
    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $pruneCrash, '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter)
    Check-Text $out 'Adopted snapshot' 'older snapshot is adopted for the prune crash regression'
    $savedFailpoint = $env:ADM_TEST_FAILPOINT
    $env:ADM_TEST_FAILPOINT = 'AfterPruneRename'
    try {
        $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepDays', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter) -ExpectFailure -ExpectedExitCode 97 -UseScript $crashScriptPath
    } finally {
        if ($null -eq $savedFailpoint) { Remove-Item Env:ADM_TEST_FAILPOINT -ErrorAction SilentlyContinue } else { $env:ADM_TEST_FAILPOINT = $savedFailpoint }
    }
    $pendingDeletions = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force -Filter '.deleting-*')
    Check ($pendingDeletions.Count -eq 1) 'prune crash leaves one pending deletion folder'
    Check (-not (Test-Path -LiteralPath $pruneCrash)) 'prune crash moves the older snapshot aside'
    Check (@((Read-Entry 'claude').destinationSnapshots | Where-Object { $_.path -eq $pruneCrash }).Count -eq 1) 'prune crash leaves the snapshot in history'
    Check (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json')) 'prune crash leaves its lease behind'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'Pending snapshot deletion under' 'status reports the pending deletion'
    Check-Text $out $pendingDeletions[0].Name 'status names the pending deletion folder'
    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepDays', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter)
    Check (-not (Test-Path -LiteralPath $pendingDeletions[0].FullName)) 'recovery prune removes the pending deletion folder'
    Check ((Read-Entry 'claude').destinationSnapshots.Count -eq 1) 'recovery prune reconciles the snapshot history'
    Check (Test-Path -LiteralPath $removedEntry.destinationSnapshot) 'recovery prune keeps the latest snapshot'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'recovery prune releases its lease'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after the prune crash recovery'

    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"dark"}'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Activated') 'claude can be activated after the removed-file rollback'

    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"dedupe"}'
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DeduplicateSnapshots', '-DriveLetter', $rootLetter)
    $dedupeEntry = Read-Entry 'claude'
    $dedupeSnapshot = $dedupeEntry.destinationSnapshot
    Check ($dedupeSnapshot -ne $removedEntry.destinationSnapshot) 'dedupe rollback creates a new snapshot'
    Check (Test-Path -LiteralPath (Join-Path $dedupeSnapshot 'skills\demo\SKILL.md')) 'dedupe snapshot keeps identical files'
    $links = & fsutil.exe hardlink list (Join-Path $dedupeSnapshot 'skills\demo\SKILL.md') 2>&1
    $priorRelative = $removedEntry.destinationSnapshot -replace '^[A-Za-z]:', ''
    Check (($links -join "`n") -match [regex]::Escape($priorRelative)) 'dedupe hard-links identical files to the previous snapshot'
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"dark"}'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Activated') 'claude can be activated after the dedupe rollback'

    # A phase paused after loading the manifest must reload it before writing.
    $staleAdoption = Join-Path $rollbacksRoot 'claude-20260101T000001000Z'
    Add-File (Join-Path $staleAdoption 'adopted.txt') 'adopted'
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"stale-window"}'
    $staleMarker = Join-Path $rollbacksRoot '.test-before-lease'
    $staleRollback = Start-Migrate -Arguments @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DriveLetter', $rootLetter) -Environment @{ ADM_TEST_FAILPOINT = 'BeforeSnapshotLease' }
    $markerAppeared = Wait-ForFile $staleMarker 30
    Check $markerAppeared 'rollback pauses after loading the manifest'
    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $staleAdoption, '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter)
    Check-Text $out 'Adopted snapshot' 'adoption completes while the rollback is paused'
    Check (@((Read-Entry 'claude').destinationSnapshots | Where-Object { $_.path -eq $staleAdoption }).Count -eq 1) 'adoption is recorded before the paused rollback resumes'
    Set-Content -LiteralPath ($staleMarker + '.release') -Value 'release'
    $out = Complete-Migrate -Handle $staleRollback
    $afterStale = Read-Entry 'claude'
    Check ($afterStale.state -eq 'Verified') 'paused rollback completes after adopting'
    Check (@($afterStale.destinationSnapshots | Where-Object { $_.path -eq $staleAdoption }).Count -eq 1) 'rollback reload preserves the newer adoption'
    Set-Content -LiteralPath $claudeSettings -Value '{"theme":"dark"}'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Activated') 'claude reactivates after the stale-manifest regression'

    # Adoption must reload after its lease, preserving a prune that completed first.
    $staleAdoption2 = Join-Path $rollbacksRoot 'claude-20260101T000002000Z'
    Add-File (Join-Path $staleAdoption2 'adopted-2.txt') 'adopted-2'
    $adoptWindow = Start-Migrate -Arguments @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $staleAdoption2, '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter) -Environment @{ ADM_TEST_FAILPOINT = 'BeforeSnapshotLease' }
    $markerAppeared = Wait-ForFile $staleMarker 30
    Check $markerAppeared 'adoption pauses after loading the manifest'
    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').destinationSnapshots.Count -eq 1) 'prune completes while adoption is paused'
    Check (@((Read-Entry 'claude').destinationSnapshots | Where-Object { $_.path -eq $staleAdoption }).Count -eq 0) 'prune removes the earlier adopted snapshot'
    Set-Content -LiteralPath ($staleMarker + '.release') -Value 'release'
    $out = Complete-Migrate -Handle $adoptWindow
    $afterAdoptReload = Read-Entry 'claude'
    Check (@($afterAdoptReload.destinationSnapshots | Where-Object { $_.path -eq $staleAdoption }).Count -eq 0) 'adoption reload preserves the newer prune'
    Check (@($afterAdoptReload.destinationSnapshots | Where-Object { $_.path -eq $staleAdoption2 }).Count -eq 1) 'adoption reload records the new snapshot'

    # Prune must reload after its lease, preserving an adoption that completed first.
    $stalePruneOlder = Join-Path $rollbacksRoot 'claude-20260101T000004000Z'
    Add-File (Join-Path $stalePruneOlder 'older.txt') 'older'
    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $stalePruneOlder, '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter)
    Check-Text $out 'Adopted snapshot' 'older snapshot is adopted before the prune window'
    $stalePruneAdoption = Join-Path $rollbacksRoot 'claude-20260101T000005000Z'
    Add-File (Join-Path $stalePruneAdoption 'adopted-3.txt') 'adopted-3'
    $pruneWindow = Start-Migrate -Arguments @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter) -Environment @{ ADM_TEST_FAILPOINT = 'BeforeSnapshotLease' }
    $markerAppeared = Wait-ForFile $staleMarker 30
    Check $markerAppeared 'prune pauses after loading the manifest'
    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $stalePruneAdoption, '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter)
    Check-Text $out 'Adopted snapshot' 'adoption completes while the prune is paused'
    Check (@((Read-Entry 'claude').destinationSnapshots | Where-Object { $_.path -eq $stalePruneAdoption }).Count -eq 1) 'adoption is recorded before the paused prune resumes'
    Set-Content -LiteralPath ($staleMarker + '.release') -Value 'release'
    $out = Complete-Migrate -Handle $pruneWindow
    $afterPruneReload = Read-Entry 'claude'
    Check (@($afterPruneReload.destinationSnapshots | Where-Object { $_.path -eq $stalePruneAdoption }).Count -eq 1) 'prune reload preserves the newer adoption'
    Check (@($afterPruneReload.destinationSnapshots | Where-Object { $_.path -eq $staleAdoption2 }).Count -eq 0) 'prune reload removes the record pruned from its new history'
    Check (@($afterPruneReload.destinationSnapshots | Where-Object { $_.path -eq $stalePruneOlder }).Count -eq 0) 'prune reload applies KeepLast to the newer history'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'prune releases its lease after the stale-manifest window'

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
    Check ($null -eq (Read-Entry 'cursor').PSObject.Properties['destinationSnapshot']) 'unchanged rollback creates no snapshot'

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
    Write-Host '=== crash window and adoption ==='
    Add-File (Join-Path $claudeDest 'crash.txt') 'crash window'
    $savedFailpoint = $env:ADM_TEST_FAILPOINT
    $env:ADM_TEST_FAILPOINT = 'AfterSnapshotRename'
    try {
        $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DriveLetter', $rootLetter) -ExpectFailure -UseScript $crashScriptPath
    } finally {
        if ($null -eq $savedFailpoint) { Remove-Item Env:ADM_TEST_FAILPOINT -ErrorAction SilentlyContinue } else { $env:ADM_TEST_FAILPOINT = $savedFailpoint }
    }
    $knownPaths = @((Read-Entry 'claude').destinationSnapshots | ForEach-Object { $_.path })
    $crashSnapshots = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force | Where-Object { $_.Name -notlike '.*' -and $knownPaths -notcontains $_.FullName })
    Check ($crashSnapshots.Count -eq 1) 'crash leaves exactly one unreferenced snapshot'
    $crashSnapshot = $crashSnapshots[0].FullName
    Check (Test-Path -LiteralPath (Join-Path $crashSnapshot 'crash.txt')) 'crash snapshot is complete after the rename'
    Check (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json')) 'crash leaves the snapshot lease behind'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'Unreferenced destination snapshot folder' 'status reports the crash snapshot'
    Check-Text $out 'Stale snapshot operation lease' 'status reports the crash lease'
    Check ((Read-Entry 'claude').state -eq 'Activated') 'crash leaves claude Activated'

    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-DriveLetter', $rootLetter, '-WhatIf')
    Check-Text $out 'would adopt snapshot' 'adoption previews without approval'
    Check (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json')) 'adoption preview keeps the stale lease'
    Check (-not (Test-Path -LiteralPath ($crashSnapshot + '.snapshot.json'))) 'adoption preview writes no sidecar'

    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'ApproveSnapshotAdoption' 'adoption requires explicit approval'
    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter)
    Check-Text $out 'Adopted snapshot' 'adoption records the crash snapshot'
    $adopted = Read-Entry 'claude'
    Check (@($adopted.destinationSnapshots | Where-Object { $_.path -eq $crashSnapshot }).Count -eq 1) 'adopted snapshot enters history'
    Check (Test-Path -LiteralPath ($crashSnapshot + '.snapshot.json')) 'adoption writes a sidecar'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'adoption clears the stale lease'
    Check ($adopted.destinationSnapshot -ne $crashSnapshot) 'adoption does not change the current snapshot'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after adoption'
    Remove-Item -LiteralPath (Join-Path $claudeDest 'crash.txt') -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after removing the crash change'

    # Crash after renaming the destination away but before installing the staged snapshot.
    $savedFailpoint = $env:ADM_TEST_FAILPOINT
    $env:ADM_TEST_FAILPOINT = 'AfterDestinationRename'
    try {
        $out = Invoke-Migrate @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ConfirmAgentsStopped', '-ApproveSnapshotRestore', '-DriveLetter', $rootLetter) -ExpectFailure -UseScript $crashScriptPath
    } finally {
        if ($null -eq $savedFailpoint) { Remove-Item Env:ADM_TEST_FAILPOINT -ErrorAction SilentlyContinue } else { $env:ADM_TEST_FAILPOINT = $savedFailpoint }
    }
    Check (-not (Test-Path -LiteralPath $claudeDest)) 'restore crash leaves the destination renamed away'
    $strandedBackups = @(Get-ChildItem -LiteralPath (Split-Path $claudeDest -Parent) -Directory -Force | Where-Object { $_.Name -like ((Split-Path $claudeDest -Leaf) + '.pre-restore-*') })
    Check ($strandedBackups.Count -eq 1) 'restore crash leaves one stranded destination backup'
    $strandedDest = $strandedBackups[0].FullName
    Check (Test-Path -LiteralPath (Join-Path $strandedDest 'settings.json')) 'stranded destination backup contains the previous files'
    $restoreStaging = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force | Where-Object { $_.Name -like '.restore-claude-*' })
    Check ($restoreStaging.Count -eq 1) 'restore crash leaves the staged snapshot'
    Check (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json')) 'restore crash leaves the restore lease'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'stranded pre-restore destination backup' 'status reports the stranded destination backup'
    Check-Text $out 'Orphaned restore staging' 'status reports the orphaned restore staging'
    Check-Text $out 'Stale snapshot operation lease' 'status reports the restore lease'
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-AsJson')
    $json = $out | ConvertFrom-Json
    Check (@($json.issues | Where-Object { $_.code -eq 'restore_destination_stranded' }).Count -eq 1) 'status JSON exposes the stranded destination code'
    $out = Invoke-Migrate @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ConfirmAgentsStopped', '-ApproveSnapshotRestore', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'stranded pre-restore destination' 'restore refuses until the destination is reconciled'
    Check (-not (Test-Path -LiteralPath $claudeDest)) 'refused restore leaves the destination stranded'
    Check (Test-Path -LiteralPath $strandedDest) 'refused restore leaves the stranded backup intact'
    Rename-Item -LiteralPath $strandedDest -NewName (Split-Path $claudeDest -Leaf)
    Check (Test-Path -LiteralPath (Join-Path $claudeDest 'settings.json')) 'reconciled destination is back in place'
    $out = Invoke-Migrate @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ConfirmAgentsStopped', '-ApproveSnapshotRestore', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'incomplete staging' 'restore refuses while staged data remains'
    Remove-Item -LiteralPath $restoreStaging[0].FullName -Recurse -Force
    Check (-not (Test-Path -LiteralPath $restoreStaging[0].FullName)) 'reconciled restore staging is removed'

    $out = Invoke-Migrate @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-DriveLetter', $rootLetter, '-WhatIf')
    Check-Text $out 'would restore' 'restore previews without approval'
    Check (-not (Test-Path -LiteralPath (Join-Path $claudeDest 'crash.txt'))) 'restore preview leaves the destination alone'
    $out = Invoke-Migrate @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ConfirmAgentsStopped', '-ApproveSnapshotRestore', '-DriveLetter', $rootLetter)
    Check-Text $out 'Restored snapshot' 'restore replaces the destination'
    Check (Test-Path -LiteralPath (Join-Path $claudeDest 'crash.txt')) 'restore copies the chosen snapshot'
    Check ((Read-Entry 'claude').destinationSnapshots.Count -ge 3) 'restore records a safety snapshot'
    Remove-Item -LiteralPath (Join-Path $claudeDest 'crash.txt') -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after restore and cleanup'

    # A snapshot tree containing a junction must be rejected before hashing or copying.
    $tamperTarget = Join-Path $runRoot 'tamper-target'
    New-Item -ItemType Directory -Path $tamperTarget -Force | Out-Null
    $tamperJunction = Join-Path $crashSnapshot 'tamper-junction'
    New-Item -ItemType Junction -Path $tamperJunction -Target $tamperTarget | Out-Null
    $historyBefore = 0
    $historyProperty = (Read-Entry 'claude').PSObject.Properties['destinationSnapshots']
    if ($null -ne $historyProperty) { $historyBefore = @($historyProperty.Value).Count }
    $out = Invoke-Migrate @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ConfirmAgentsStopped', '-ApproveSnapshotRestore', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Refusing tree containing reparse point' 'restore rejects a snapshot containing a junction'
    Check (-not (Test-Path -LiteralPath (Join-Path $claudeDest 'crash.txt'))) 'rejected tampered snapshot leaves the destination unchanged'
    $restoreStaging = @(Get-ChildItem -LiteralPath $rollbacksRoot -Directory -Force | Where-Object { $_.Name -like '.restore-claude-*' })
    Check ($restoreStaging.Count -eq 0) 'rejected tampered snapshot copies nothing'
    $historyAfter = 0
    $historyProperty = (Read-Entry 'claude').PSObject.Properties['destinationSnapshots']
    if ($null -ne $historyProperty) { $historyAfter = @($historyProperty.Value).Count }
    Check ($historyAfter -eq $historyBefore) 'rejected tampered snapshot creates no safety snapshot'
    [IO.Directory]::Delete($tamperJunction)
    Remove-Item -LiteralPath $tamperTarget -Recurse -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after removing the tampered junction'

    # The rollback lease must span snapshot creation, the manifest update and cleanup.
    Add-File (Join-Path $claudeDest 'rollback-window.txt') 'window'
    $rollbackMarker = Join-Path $rollbacksRoot '.test-rollback-ready'
    $rollbackWindow = Start-Migrate -Arguments @('-Phase', 'Rollback', '-Agent', 'claude', '-ConfirmAgentsStopped', '-ApproveRollback', '-AcceptDestinationChanges', '-DriveLetter', $rootLetter) -Environment @{ ADM_TEST_FAILPOINT = 'RollbackBeforeManifest' }
    $markerAppeared = Wait-ForFile $rollbackMarker 30
    Check $markerAppeared 'rollback pauses after snapshot creation'
    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Snapshot operation already in progress' 'prune refuses during the rollback manifest window'
    Set-Content -LiteralPath ($rollbackMarker + '.release') -Value 'release'
    $out = Complete-Migrate -Handle $rollbackWindow
    Check ((Read-Entry 'claude').state -eq 'Verified') 'rollback completes after the manifest window'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'rollback releases its lease after the manifest update'
    Remove-Item -LiteralPath (Join-Path $claudeDest 'rollback-window.txt') -Force
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'claude', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'claude').state -eq 'Activated') 'claude reactivates after the rollback window test'

    # The restore lease must span the safety snapshot, manifest update and destination swap.
    $restoreMarker = Join-Path $rollbacksRoot '.test-restore-ready'
    $restoreWindow = Start-Migrate -Arguments @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ConfirmAgentsStopped', '-ApproveSnapshotRestore', '-DriveLetter', $rootLetter) -Environment @{ ADM_TEST_FAILPOINT = 'RestoreBeforeSafetyManifest' }
    $markerAppeared = Wait-ForFile $restoreMarker 30
    Check $markerAppeared 'restore pauses after the safety snapshot'
    $out = Invoke-Migrate @('-Phase', 'PruneSnapshots', '-Agent', 'claude', '-KeepLast', '1', '-ApproveSnapshotDeletion', '-DriveLetter', $rootLetter) -ExpectFailure
    Check-Text $out 'Snapshot operation already in progress' 'prune refuses during the restore manifest window'
    Set-Content -LiteralPath ($restoreMarker + '.release') -Value 'release'
    $out = Complete-Migrate -Handle $restoreWindow
    Check (Test-Path -LiteralPath (Join-Path $claudeDest 'crash.txt')) 'restore completes after the manifest window'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'restore releases its lease after cleanup'
    Remove-Item -LiteralPath (Join-Path $claudeDest 'crash.txt') -Force
    $out = Invoke-Migrate @('-Phase', 'Status', '-Agent', 'claude', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after the lease window regressions'

    # Restore must reload the manifest after its lease, preserving a phase that finished first.
    $staleRestoreAdoption = Join-Path $rollbacksRoot 'claude-20260101T000003000Z'
    Add-File (Join-Path $staleRestoreAdoption 'adopted-during-restore.txt') 'adopted-during-restore'
    $restoreStaleWindow = Start-Migrate -Arguments @('-Phase', 'RestoreSnapshot', '-Agent', 'claude', '-SnapshotPath', $crashSnapshot, '-ConfirmAgentsStopped', '-ApproveSnapshotRestore', '-DriveLetter', $rootLetter) -Environment @{ ADM_TEST_FAILPOINT = 'BeforeSnapshotLease' }
    $markerAppeared = Wait-ForFile $staleMarker 30
    Check $markerAppeared 'restore pauses after loading the manifest'
    $out = Invoke-Migrate @('-Phase', 'AdoptSnapshots', '-Agent', 'claude', '-SnapshotPath', $staleRestoreAdoption, '-ApproveSnapshotAdoption', '-DriveLetter', $rootLetter)
    Check-Text $out 'Adopted snapshot' 'adoption completes while the restore is paused'
    Check (@((Read-Entry 'claude').destinationSnapshots | Where-Object { $_.path -eq $staleRestoreAdoption }).Count -eq 1) 'adoption is recorded before the paused restore resumes'
    Set-Content -LiteralPath ($staleMarker + '.release') -Value 'release'
    $out = Complete-Migrate -Handle $restoreStaleWindow
    Check (Test-Path -LiteralPath (Join-Path $claudeDest 'crash.txt')) 'paused restore completes after adopting'
    $afterRestoreReload = Read-Entry 'claude'
    Check (@($afterRestoreReload.destinationSnapshots | Where-Object { $_.path -eq $staleRestoreAdoption }).Count -eq 1) 'restore reload preserves the newer adoption'
    Check (-not (Test-Path -LiteralPath (Join-Path $rollbacksRoot '.snapshot-lease.json'))) 'restore releases its lease after the stale-manifest window'
    Remove-Item -LiteralPath (Join-Path $claudeDest 'crash.txt') -Force

    Write-Host ''
    Write-Host '=== cleanup refusals ==='
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'backup') -Force | Out-Null
    $sameVolumeBackup = Join-Path $root 'backup'
    $sourceVolumeBackup = Join-Path $runRoot 'cbackup'
    New-Item -ItemType Directory -Path $sourceVolumeBackup -Force | Out-Null

    $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'claude', '-DriveLetter', $rootLetter, '-WhatIf')
    Check-Text $out 'What if:' 'cleanup previews without switches or a backup'
    Check (Test-Path -LiteralPath $claudeHold) 'cleanup preview keeps the hold'
    Check (-not (Test-Path -LiteralPath $claudeBackup)) 'cleanup preview creates no backup'
    Check ((Read-Entry 'claude').state -eq 'Activated') 'cleanup preview leaves the state alone'

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
    # Interrupt cursor's cleanup after the backup is copied, roll back, and activate
    # again: the next cleanup must resume from the existing verified backup.
    $holdHandles = @()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $cursorHold -Recurse -File)) {
            $holdHandles += [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        }
        $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'cursor', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot) -ExpectFailure
        Check (Test-Path -LiteralPath $cursorHold) 'failed cleanup keeps the cursor hold'
        Check (Test-Path -LiteralPath $cursorBackup) 'failed cleanup keeps the cursor backup'
        Check ((Read-Entry 'cursor').state -eq 'BackupVerified') 'failed cleanup records cursor BackupVerified'
    }
    finally {
        foreach ($handle in $holdHandles) { $handle.Dispose() }
    }
    $out = Invoke-Migrate @('-Phase', 'Rollback', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-ApproveRollback', '-DriveLetter', $rootLetter)
    Check (-not (Test-Path -LiteralPath $cursorHold)) 'rollback after cleanup restores the cursor hold'
    Check (Test-Path -LiteralPath $cursorBackup) 'rollback leaves the cleanup backup in place'
    Check ((Read-Entry 'cursor').state -eq 'Verified') 'rollback after cleanup returns cursor to Verified'
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'cursor', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'cursor').state -eq 'Activated') 'cursor can be activated after the cleanup rollback'

    Add-Content -LiteralPath (Join-Path $cursorBackup 'notes.txt') -Value 'extra'
    $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'cursor', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot) -ExpectFailure
    Check-Text $out 'Existing backup differs' 'cleanup refuses a mismatched existing backup'
    Check ((Read-Entry 'cursor').state -eq 'Activated') 'mismatched backup refusal leaves cursor Activated'
    Set-Content -LiteralPath (Join-Path $cursorBackup 'notes.txt') -Value 'cursor notes'

    $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'cursor', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot)
    Check-Text $out 'Resuming cleanup with existing backup' 'cleanup resumes from the existing backup'
    Check (-not (Test-Path -LiteralPath $cursorHold)) 'resumed cleanup removes the cursor hold'
    Check (Test-Path -LiteralPath $cursorBackup) 'resumed cleanup keeps the cursor backup'
    Check ((Read-Entry 'cursor').state -eq 'Complete') 'resumed cleanup records cursor as Complete'
    Check (Test-Path -LiteralPath (Join-Path $cursorSource 'notes.txt')) 'resumed cleanup leaves the junction readable'

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

    # Normal cleanup still copies a fresh backup when none exists.
    $out = Invoke-Migrate @('-Phase', 'Copy', '-Agent', 'gemini', '-DriveLetter', $rootLetter)
    $out = Invoke-Migrate @('-Phase', 'Verify', '-Agent', 'gemini', '-DriveLetter', $rootLetter)
    $out = Invoke-Migrate @('-Phase', 'Activate', '-Agent', 'gemini', '-ConfirmAgentsStopped', '-DriveLetter', $rootLetter)
    Check ((Read-Entry 'gemini').state -eq 'Activated') 'gemini can be activated for normal cleanup'
    $out = Invoke-Migrate @('-Phase', 'Cleanup', '-Agent', 'gemini', '-DriveLetter', $rootLetter, '-ConfirmAgentsValidated', '-ApproveDeletion', '-BackupRoot', $backupRoot)
    Check (-not (Test-Path -LiteralPath $geminiHold)) 'normal cleanup removes the gemini hold'
    Check (Test-Path -LiteralPath $geminiBackup) 'normal cleanup keeps the gemini backup'
    Check ((Read-Entry 'gemini').state -eq 'Complete') 'normal cleanup records gemini as Complete'

    Write-Host ''
    Write-Host '=== final state ==='
    Check (Test-Path -LiteralPath (Join-Path $claudeSource 'settings.json')) 'claude destination survives cleanup'
    Check (Test-Path -LiteralPath (Join-Path $cursorSource 'notes.txt')) 'cursor destination survives cleanup'
    Check (Test-Path -LiteralPath (Join-Path $geminiSource 'config.json')) 'gemini destination survives cleanup'
    Check ((Read-Manifest).schema -eq 1) 'manifest schema is unchanged'
    $out = Invoke-Migrate @('-Phase', 'Status', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after cleanup'

    $savedManifestText = [IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText($manifestPath, 'not json')
    $out = Invoke-Migrate @('-Phase', 'Status', '-DriveLetter', $rootLetter)
    Check-Text $out 'Manifest unreadable; loading backup' 'status falls back to the manifest backup'
    [IO.File]::WriteAllText($manifestPath, $savedManifestText)
    $out = Invoke-Migrate @('-Phase', 'Status', '-DriveLetter', $rootLetter)
    Check-Text $out 'manifest matches disk' 'status agrees after restoring the manifest'
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
