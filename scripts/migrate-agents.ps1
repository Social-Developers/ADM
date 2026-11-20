#requires -Version 5.1
<#
.SYNOPSIS
  Conservative Windows agent-data migration to a user-selected drive\agents.
.DESCRIPTION
  Phases: Inventory, Copy, Verify, Activate, Rollback, Cleanup, Status,
  PruneSnapshots, AdoptSnapshots, RestoreSnapshot.
  Activation creates legacy-path junctions after moving the original directories
  to same-volume hold directories. Cleanup requires independent verified backup.
  Rollback snapshots are hash-verified, lease-guarded and retained until pruned.
  This script does not relocate application binaries or project repositories.
.EXAMPLE
  .\migrate-agents.ps1 -Phase Inventory -DriveLetter D
  .\migrate-agents.ps1 -Phase Copy
  .\migrate-agents.ps1 -Phase Verify
  .\migrate-agents.ps1 -Phase Activate -Agent claude -ConfirmAgentsStopped
  .\migrate-agents.ps1 -Phase Rollback -Agent claude -ConfirmAgentsStopped -ApproveRollback
  .\migrate-agents.ps1 -Phase PruneSnapshots -Agent claude -KeepLast 3 -ApproveSnapshotDeletion
  .\migrate-agents.ps1 -Phase AdoptSnapshots -Agent claude -SnapshotPath 'D:\agents\migration\rollbacks\claude-...' -ApproveSnapshotAdoption
  .\migrate-agents.ps1 -Phase RestoreSnapshot -Agent claude -SnapshotPath 'D:\agents\migration\rollbacks\claude-...' -ConfirmAgentsStopped -ApproveSnapshotRestore
  .\migrate-agents.ps1 -Phase Cleanup -Agent claude -BackupRoot 'R:\agent-migration-backup' -ConfirmAgentsValidated -ApproveDeletion
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Inventory','Copy','Verify','Activate','Rollback','Cleanup','Status','PruneSnapshots','AdoptSnapshots','RestoreSnapshot')]
    [string]$Phase = 'Inventory',
    [string]$Root,
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DriveLetter,
    [ValidateSet('all','claude','codex','gemini','cursor','opencode')]
    [string]$Agent = 'all',
    [string]$BackupRoot,
    [switch]$ConfirmAgentsStopped,
    [switch]$ConfirmAgentsValidated,
    [switch]$ApproveDeletion,
    [switch]$ApproveRollback,
    [switch]$AcceptDestinationChanges,
    [ValidateRange(1, 2)]
    [int]$AdoptDigestVersion = 2,
    [switch]$ApproveSnapshotDeletion,
    [switch]$ApproveSnapshotAdoption,
    [switch]$ApproveSnapshotRestore,
    [int]$KeepLast = -1,
    [int]$KeepDays = -1,
    [string]$SnapshotPath,
    [switch]$Quick,
    [switch]$AsJson,
    [switch]$Strict,
    [switch]$DeduplicateSnapshots
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function FullPath([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd('\') }
function IsWithin([string]$Path, [string]$Parent) {
    $p = (FullPath $Path) + '\'; $q = (FullPath $Parent) + '\'
    return $p.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-NoReparse([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse point: $Path"
    }
}
function Assert-TreeSafe([string]$Path) {
    Assert-NoReparse $Path
    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop | ForEach-Object {
            if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing tree containing reparse point: $($_.FullName)"
            }
        }
    }
}
function Wait-SnapshotFailpoint([string]$Failpoint, [string]$Marker) {
    if ($env:ADM_TEST_FAILPOINT -ne $Failpoint) { return }
    Set-Content -LiteralPath $Marker -Value 'ready'
    $release = $Marker + '.release'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $release) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $release -Force -ErrorAction SilentlyContinue
}
function Save-Json([object]$Object, [string]$Path, [switch]$Backup) {
    $tmp = "$Path.tmp.$PID"
    $json = ConvertTo-Json -InputObject $Object -Depth 20
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        if ($Backup) { [IO.File]::Copy($Path, "$Path.bak", $true) }
        [IO.File]::Replace($tmp, $Path, [NullString]::Value)
    } else { [IO.File]::Move($tmp, $Path) }
}
function Load-Json([string]$Path) {
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "Missing manifest: $Path. Run Inventory first."
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch {
        if (Test-Path -LiteralPath "$Path.bak" -PathType Leaf) {
            Write-Warning "Manifest unreadable; loading backup: $Path.bak"
            return (Get-Content -LiteralPath "$Path.bak" -Raw | ConvertFrom-Json)
        }
        throw
    }
}
function FileHash([string]$Path) {
    # Hashed directly so -WhatIf cannot suppress the read the way it does for Get-FileHash.
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Files-In([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction Stop | Sort-Object FullName)
}
function Relative([string]$Base, [string]$Path) {
    return $Path.Substring((FullPath $Base).Length).TrimStart('\')
}
function Assert-EqualTrees([string]$A, [string]$B) {
    Assert-TreeSafe $A
    Assert-TreeSafe $B
    $af = @(Files-In $A)
    $bf = @(Files-In $B)
    Assert-Condition ($af.Count -eq $bf.Count) "File count mismatch: $A ($($af.Count)) vs $B ($($bf.Count))"
    $lookup = @{}
    foreach ($f in $bf) { $lookup[(Relative $B $f.FullName).ToLowerInvariant()] = $f }
    foreach ($f in $af) {
        $rel = Relative $A $f.FullName
        $key = $rel.ToLowerInvariant()
        Assert-Condition $lookup.ContainsKey($key) "Missing destination file: $rel"
        $other = $lookup[$key]
        Assert-Condition ($f.Length -eq $other.Length) "Size mismatch: $rel"
        Assert-Condition ((FileHash $f.FullName) -eq (FileHash $other.FullName)) "SHA-256 mismatch: $rel"
    }
    $ad = @(Get-ChildItem -LiteralPath $A -Force -Recurse -Directory | ForEach-Object { (Relative $A $_.FullName).ToLowerInvariant() } | Sort-Object)
    $bd = @(Get-ChildItem -LiteralPath $B -Force -Recurse -Directory | ForEach-Object { (Relative $B $_.FullName).ToLowerInvariant() } | Sort-Object)
    Assert-Condition ((@($ad) -join "`n") -ceq (@($bd) -join "`n")) "Directory layout mismatch: $A vs $B"
}
function Get-TreeDiff([string]$Reference, [string]$Current) {
    $referenceFiles = @{}
    foreach ($f in @(Files-In $Reference)) { $referenceFiles[(Relative $Reference $f.FullName).ToLowerInvariant()] = $f }
    $currentFiles = @{}
    foreach ($f in @(Files-In $Current)) { $currentFiles[(Relative $Current $f.FullName).ToLowerInvariant()] = $f }
    $added = @(); $removed = @(); $changed = @()
    foreach ($key in $currentFiles.Keys) {
        if (-not $referenceFiles.ContainsKey($key)) { $added += $key; continue }
        $a = $referenceFiles[$key]; $b = $currentFiles[$key]
        if ($a.Length -ne $b.Length -or (FileHash $a.FullName) -ne (FileHash $b.FullName)) { $changed += $key }
    }
    foreach ($key in $referenceFiles.Keys) { if (-not $currentFiles.ContainsKey($key)) { $removed += $key } }
    return [pscustomobject]@{
        added = @($added | Sort-Object); removed = @($removed | Sort-Object); changed = @($changed | Sort-Object)
    }
}
function Get-TreeDigest([string]$Path, [int]$Version = 1) {
    Assert-TreeSafe $Path
    $lines = @(Files-In $Path | ForEach-Object {
            $rel = (Relative $Path $_.FullName).Replace('\', '/').ToLowerInvariant()
            "$rel|$($_.Length)|$(FileHash $_.FullName)"
        })
    if ($Version -ge 2) {
        $dirs = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -Directory -ErrorAction Stop | ForEach-Object {
                (Relative $Path $_.FullName).Replace('\', '/').ToLowerInvariant()
            } | Sort-Object)
        $lines += @($dirs | ForEach-Object { "dir|$_" })
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((@($lines | Sort-Object) -join "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}
function Get-TreeLogicalBytes([string]$Path) {
    $bytes = [long]0
    foreach ($f in @(Files-In $Path)) { $bytes += [long]$f.Length }
    return $bytes
}
function Get-ClusterSize([string]$Volume) {
    if (-not ('AdmVolumeInfo' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AdmVolumeInfo {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetDiskFreeSpaceW(string root, out uint sectorsPerCluster, out uint bytesPerSector, out uint freeClusters, out uint totalClusters);
}
'@
    }
    $sectors = [uint32]0; $sectorBytes = [uint32]0; $free = [uint32]0; $total = [uint32]0
    if ([AdmVolumeInfo]::GetDiskFreeSpaceW($Volume, [ref]$sectors, [ref]$sectorBytes, [ref]$free, [ref]$total)) {
        return ([long]$sectors * [long]$sectorBytes)
    }
    return [long]0
}
function Get-SnapshotRequiredBytes([string]$Source, [long]$ClusterSize = 0) {
    $bytes = [long]0
    foreach ($f in @(Files-In $Source)) {
        $length = [long]$f.Length
        if ($ClusterSize -gt 0 -and $length -gt 0) {
            $blocks = [long]([Math]::Ceiling([double]$length / [double]$ClusterSize))
            $bytes += $blocks * $ClusterSize
        } else { $bytes += $length }
    }
    # One spare mebibyte keeps the copy itself from exhausting the volume.
    return $bytes + 1MB
}
function Assert-SnapshotSpace([string]$Source, [string]$SnapshotRoot, [long]$AvailableBytes = -1, [long]$ClusterSize = 0) {
    # The optional availability argument lets the harness test the refusal boundary
    # without creating a nearly full volume; production callers omit it.
    $volume = [IO.Path]::GetPathRoot((FullPath $SnapshotRoot))
    if ($ClusterSize -le 0 -and $AvailableBytes -lt 0) { $ClusterSize = Get-ClusterSize $volume }
    $required = Get-SnapshotRequiredBytes $Source $ClusterSize
    if ($AvailableBytes -lt 0) {
        $drive = New-Object -TypeName IO.DriveInfo -ArgumentList $volume
        $AvailableBytes = $drive.AvailableFreeSpace
        $volume = $drive.Name
    }
    Assert-Condition ($AvailableBytes -ge $required) (`
            "Insufficient free space for destination snapshot on {0}: need {1} bytes, have {2}." -f $volume, $required, $AvailableBytes)
}
function New-Issue([string]$Code, [string]$Message, [string]$Scope = '') {
    return [pscustomobject]@{ code = $Code; message = $Message; scope = $Scope }
}
function Get-SnapshotRecordPath([object]$Record) {
    if ($null -eq $Record) { return $null }
    if ($Record -is [string]) { return [string]$Record }
    $property = $Record.PSObject.Properties['path']
    if ($null -ne $property) { return [string]$property.Value }
    return [string]$Record
}
function Get-SnapshotRecordHash([object]$Record) {
    if ($null -eq $Record -or $Record -is [string]) { return $null }
    $property = $Record.PSObject.Properties['hash']
    if ($null -ne $property) { return [string]$property.Value }
    return $null
}
function Get-SnapshotRecordBytes([object]$Record) {
    if ($null -eq $Record -or $Record -is [string]) { return [long]0 }
    $property = $Record.PSObject.Properties['bytes']
    if ($null -ne $property) { return [long]$property.Value }
    return [long]0
}
function Get-SnapshotRecordVersion([object]$Record) {
    if ($null -eq $Record -or $Record -is [string]) { return 1 }
    $property = $Record.PSObject.Properties['digestVersion']
    if ($null -ne $property) { return [int]$property.Value }
    return 1
}
function Get-SnapshotRecordCreatedUtc([object]$Record) {
    if ($null -eq $Record -or $Record -is [string]) { return $null }
    $property = $Record.PSObject.Properties['createdUtc']
    if ($null -eq $property) { return $null }
    try { return [DateTime]::Parse([string]$property.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}
function Test-SnapshotRecordPinned([object]$Record) {
    if ($null -eq $Record -or $Record -is [string]) { return $false }
    $property = $Record.PSObject.Properties['pinned']
    if ($null -eq $property) { return $false }
    return [bool]$property.Value
}
function Get-SnapshotRecords([object]$E) {
    $history = $E.PSObject.Properties['destinationSnapshots']
    if ($null -eq $history) { return @() }
    $records = @()
    foreach ($record in @($history.Value)) {
        if ($null -eq $record) { continue }
        if ([string]::IsNullOrWhiteSpace([string](Get-SnapshotRecordPath $record))) { continue }
        $records += $record
    }
    return @($records)
}
function Get-SnapshotReferencePaths([object]$E) {
    $paths = @()
    $latest = $E.PSObject.Properties['destinationSnapshot']
    if ($null -ne $latest -and -not [string]::IsNullOrWhiteSpace([string]$latest.Value)) { $paths += [string]$latest.Value }
    foreach ($record in @(Get-SnapshotRecords $E)) { $paths += Get-SnapshotRecordPath $record }
    return @($paths)
}
function New-SnapshotRecord([string]$Path, [string]$Hash, [long]$Bytes, [DateTime]$CreatedUtc, [object]$Changes, [int]$DigestVersion) {
    $added = 0; $removed = 0; $changed = 0
    if ($null -ne $Changes) {
        $added = @($Changes.added).Count; $removed = @($Changes.removed).Count; $changed = @($Changes.changed).Count
    }
    return [pscustomobject]@{
        path = $Path; hash = $Hash; bytes = $Bytes; createdUtc = $CreatedUtc.ToUniversalTime().ToString('o')
        digestVersion = $DigestVersion; pinned = $false; added = $added; removed = $removed; changed = $changed
    }
}
function Add-SnapshotHistoryRecord([object]$E, [object]$Record) {
    $records = @(Get-SnapshotRecords $E)
    $records += $Record
    $E | Add-Member -NotePropertyName destinationSnapshots -NotePropertyValue @($records) -Force
}
function Add-SnapshotRecord([object]$E, [object]$Record) {
    Add-SnapshotHistoryRecord $E $Record
    $E | Add-Member -NotePropertyName destinationSnapshot -NotePropertyValue $Record.path -Force
    $E | Add-Member -NotePropertyName destinationSnapshotHash -NotePropertyValue $Record.hash -Force
    $E | Add-Member -NotePropertyName destinationSnapshotDigestVersion -NotePropertyValue $Record.digestVersion -Force
}
function Remove-SnapshotRecord([object]$E, [string]$Path) {
    $key = (FullPath $Path).ToLowerInvariant()
    $remaining = @()
    foreach ($record in @(Get-SnapshotRecords $E)) {
        $raw = Get-SnapshotRecordPath $record
        if ([string]::IsNullOrWhiteSpace([string]$raw)) { continue }
        try { $recordKey = (FullPath ([string]$raw)).ToLowerInvariant() } catch { $remaining += $record; continue }
        if ($recordKey -ne $key) { $remaining += $record }
    }
    $E | Add-Member -NotePropertyName destinationSnapshots -NotePropertyValue @($remaining) -Force
}
function Get-SnapshotProblems([object]$E, [switch]$Quick) {
    $property = $E.PSObject.Properties['destinationSnapshot']
    if ($null -eq $property) { return @() }
    $snapText = [string]$property.Value
    if ([string]::IsNullOrWhiteSpace($snapText)) { return @(New-Issue 'snapshot_path_missing' 'destination snapshot path missing' $E.id) }
    $rollbacks = Join-Path $script:Root 'migration\rollbacks'
    try { $snap = FullPath $snapText } catch { return @(New-Issue 'snapshot_path_invalid' 'destination snapshot path invalid' $E.id) }
    if ($snap -ieq (FullPath $rollbacks) -or -not (IsWithin $snap $rollbacks)) { return @(New-Issue 'snapshot_outside_rollbacks' 'destination snapshot outside rollbacks' $E.id) }
    if (-not (Test-Path -LiteralPath $snap -PathType Container)) { return @(New-Issue 'snapshot_missing' 'destination snapshot missing' $E.id) }
    $hashProperty = $E.PSObject.Properties['destinationSnapshotHash']
    if ($null -eq $hashProperty -or [string]::IsNullOrWhiteSpace([string]$hashProperty.Value)) { return @(New-Issue 'snapshot_hash_missing' 'destination snapshot hash missing' $E.id) }
    if ($Quick) { return @() }
    $version = 1
    $versionProperty = $E.PSObject.Properties['destinationSnapshotDigestVersion']
    if ($null -ne $versionProperty) { $version = [int]$versionProperty.Value }
    try { $actual = Get-TreeDigest $snap $version } catch { return @(New-Issue 'snapshot_unreadable' 'destination snapshot unreadable' $E.id) }
    if ($actual -ne ([string]$hashProperty.Value).ToLowerInvariant()) { return @(New-Issue 'snapshot_corrupted' 'destination snapshot corrupted' $E.id) }
    return @()
}
function Get-SnapshotHistoryProblems([object]$E, [switch]$Quick) {
    $historyProperty = $E.PSObject.Properties['destinationSnapshots']
    if ($null -eq $historyProperty) { return @() }
    $rollbacks = FullPath (Join-Path $script:Root 'migration\rollbacks')
    $latestPath = $null
    $latestProperty = $E.PSObject.Properties['destinationSnapshot']
    if ($null -ne $latestProperty -and -not [string]::IsNullOrWhiteSpace([string]$latestProperty.Value)) {
        try { $latestPath = (FullPath ([string]$latestProperty.Value)).ToLowerInvariant() } catch { }
    }
    $issues = @()
    $seen = @{}
    $latestInHistory = $false
    foreach ($record in @(Get-SnapshotRecords $E)) {
        $raw = Get-SnapshotRecordPath $record
        if ([string]::IsNullOrWhiteSpace([string]$raw)) { $issues += New-Issue 'snapshot_history_invalid' 'snapshot history entry has no path' $E.id; continue }
        try { $path = FullPath ([string]$raw) } catch { $issues += New-Issue 'snapshot_history_invalid' ("snapshot history path invalid: {0}" -f $raw) $E.id; continue }
        $key = $path.ToLowerInvariant()
        if ($null -ne $latestPath -and $key -eq $latestPath) {
            if ($latestInHistory) { $issues += New-Issue 'snapshot_history_duplicate' ("snapshot history duplicates a path: {0}" -f $path) $E.id }
            $latestInHistory = $true
            continue
        }
        if ($seen.ContainsKey($key)) { $issues += New-Issue 'snapshot_history_duplicate' ("snapshot history duplicates a path: {0}" -f $path) $E.id; continue }
        $seen[$key] = $true
        if ($path -ieq $rollbacks -or -not (IsWithin $path $rollbacks)) { $issues += New-Issue 'snapshot_history_outside_rollbacks' ("snapshot history outside rollbacks: {0}" -f $path) $E.id; continue }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { $issues += New-Issue 'snapshot_history_missing' ("snapshot history missing: {0}" -f $path) $E.id; continue }
        $leaf = Split-Path $path -Leaf
        if ($leaf -like '.incomplete-*' -or $leaf -like '.deleting-*' -or $leaf -like '.restore-*') { $issues += New-Issue 'snapshot_history_staging' ("snapshot history points at staging: {0}" -f $path) $E.id; continue }
        $hash = Get-SnapshotRecordHash $record
        if (-not $Quick -and -not [string]::IsNullOrWhiteSpace([string]$hash)) {
            $version = Get-SnapshotRecordVersion $record
            try { $actual = Get-TreeDigest $path $version } catch { $issues += New-Issue 'snapshot_history_unreadable' ("snapshot history unreadable: {0}" -f $path) $E.id; continue }
            if ($actual -ne ([string]$hash).ToLowerInvariant()) { $issues += New-Issue 'snapshot_history_corrupted' ("snapshot history corrupted: {0}" -f $path) $E.id }
        }
    }
    if ($null -ne $latestPath -and -not $latestInHistory) {
        $issues += New-Issue 'snapshot_history_latest_missing' 'destination snapshot is not in destinationSnapshots' $E.id
    }
    return @($issues)
}
function Get-SnapshotSidecarPath([string]$Snapshot) { return "$Snapshot.snapshot.json" }
function Save-SnapshotSidecar([string]$Snapshot, [object]$Record, [string]$Agent) {
    $sidecar = [pscustomobject]@{
        agent = $Agent; path = $Record.path; hash = $Record.hash; bytes = $Record.bytes
        createdUtc = $Record.createdUtc; digestVersion = $Record.digestVersion
        added = $Record.added; removed = $Record.removed; changed = $Record.changed
    }
    Save-Json $sidecar (Get-SnapshotSidecarPath $Snapshot)
}
function Get-SnapshotBaseName([string]$Agent, [DateTime]$Timestamp) {
    return $Agent + '-' + $Timestamp.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
}
function Resolve-SnapshotPath([string]$Rollbacks, [string]$Agent, [DateTime]$Timestamp) {
    $base = Join-Path $Rollbacks (Get-SnapshotBaseName $Agent $Timestamp)
    $snapshot = $base
    $suffix = 2
    while (Test-Path -LiteralPath $snapshot) { $snapshot = "$base-$suffix"; $suffix++ }
    return $snapshot
}
function Get-SnapshotLeasePath([string]$Rollbacks) { return (Join-Path $Rollbacks '.snapshot-lease.json') }
function Read-SnapshotLease([string]$Rollbacks) {
    $path = Get-SnapshotLeasePath $Rollbacks
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}
function Test-SnapshotLeaseActive([object]$Lease) {
    if ($null -eq $Lease) { return $false }
    $pidProperty = $Lease.PSObject.Properties['pid']
    if ($null -eq $pidProperty) { return $true }
    $hostProperty = $Lease.PSObject.Properties['host']
    if ($null -eq $hostProperty -or [string]$hostProperty.Value -ne [Environment]::MachineName) { return $true }
    $startedProperty = $Lease.PSObject.Properties['startedUtc']
    if ($null -ne $startedProperty) {
        try {
            $started = [DateTime]::Parse([string]$startedProperty.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if ($started.ToUniversalTime() -lt [DateTime]::UtcNow.AddHours(-24)) { return $false }
        } catch { }
    }
    $process = Get-Process -Id ([int]$pidProperty.Value) -ErrorAction SilentlyContinue
    return ($null -ne $process)
}
function Assert-NoActiveSnapshotLease([string]$Rollbacks) {
    if (-not (Test-Path -LiteralPath $Rollbacks -PathType Container)) { return }
    $lease = Read-SnapshotLease $Rollbacks
    if (Test-SnapshotLeaseActive $lease) {
        $agent = if ($null -ne $lease.PSObject.Properties['agent']) { [string]$lease.agent } else { 'unknown' }
        throw "Snapshot operation already in progress for $agent (PID $($lease.pid))."
    }
}
function Enter-SnapshotLease([string]$Rollbacks, [string]$Agent, [string]$Staging, [string]$Snapshot) {
    New-Item -ItemType Directory -Path $Rollbacks -Force | Out-Null
    $path = Get-SnapshotLeasePath $Rollbacks
    $lease = [pscustomobject]@{
        pid = $PID; host = [Environment]::MachineName; agent = $Agent; startedUtc = [DateTime]::UtcNow.ToString('o')
        staging = $Staging; snapshot = $Snapshot
    }
    $json = ConvertTo-Json -InputObject $lease -Depth 10
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            return $lease
        } catch [IO.IOException] {
            $existing = $null
            for ($readAttempt = 0; $readAttempt -lt 3; $readAttempt++) {
                $existing = Read-SnapshotLease $Rollbacks
                if ($null -ne $existing) { break }
                Start-Sleep -Milliseconds 50
            }
            if ($null -eq $existing) {
                $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                if ($null -ne $item -and $item.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(-10)) {
                    throw 'Snapshot operation already in progress (lease unreadable).'
                }
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                continue
            }
            if (Test-SnapshotLeaseActive $existing) {
                $existingAgent = if ($null -ne $existing.PSObject.Properties['agent']) { [string]$existing.agent } else { 'unknown' }
                $existingPid = if ($null -ne $existing.PSObject.Properties['pid']) { $existing.pid } else { 'unknown' }
                throw "Snapshot operation already in progress for $existingAgent (PID $existingPid)."
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    throw "Could not acquire the snapshot lease: $path"
}
function Remove-OwnSnapshotLease([string]$Rollbacks) {
    $lease = Read-SnapshotLease $Rollbacks
    if ($null -eq $lease) { return }
    $pidProperty = $lease.PSObject.Properties['pid']
    $hostProperty = $lease.PSObject.Properties['host']
    if ($null -eq $pidProperty -or $null -eq $hostProperty) { return }
    if ([int]$pidProperty.Value -ne $PID) { return }
    if ([string]$hostProperty.Value -ne [Environment]::MachineName) { return }
    Remove-Item -LiteralPath (Get-SnapshotLeasePath $Rollbacks) -Force -ErrorAction SilentlyContinue
}
function Invoke-SnapshotDedupe([string]$Snapshot, [string]$Previous) {
    $previousFiles = @{}
    foreach ($f in @(Files-In $Previous)) { $previousFiles[(Relative $Previous $f.FullName).ToLowerInvariant()] = $f }
    foreach ($f in @(Files-In $Snapshot)) {
        $key = (Relative $Snapshot $f.FullName).ToLowerInvariant()
        if (-not $previousFiles.ContainsKey($key)) { continue }
        $source = $previousFiles[$key]
        if ($source.Length -ne $f.Length) { continue }
        if ((FileHash $source.FullName) -ne (FileHash $f.FullName)) { continue }
        $target = $f.FullName
        $tempLink = $target + '.dedupe-' + [guid]::NewGuid().ToString('N')
        try {
            New-Item -ItemType HardLink -Path $tempLink -Target $source.FullName -ErrorAction Stop | Out-Null
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            Move-Item -LiteralPath $tempLink -Destination $target -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $tempLink) { Remove-Item -LiteralPath $tempLink -Force -ErrorAction SilentlyContinue }
            if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $source.FullName -Destination $target -Force -ErrorAction SilentlyContinue }
        }
    }
}
function New-DestinationSnapshot([object]$E, [string]$Rollbacks, [object]$Changes, [switch]$LeaseHeld) {
    New-Item -ItemType Directory -Path $Rollbacks -Force | Out-Null
    $timestamp = [DateTime]::UtcNow
    $snapshot = Resolve-SnapshotPath $Rollbacks $E.id $timestamp
    $staging = Join-Path $Rollbacks ('.incomplete-' + $E.id + '-' + [guid]::NewGuid().ToString('N'))
    $ownsLease = -not $LeaseHeld
    if ($ownsLease) { $lease = Enter-SnapshotLease $Rollbacks $E.id $staging $snapshot }
    $snapshotCreated = $false
    try {
        foreach ($stale in @(Get-ChildItem -LiteralPath $Rollbacks -Directory -Force -Filter '.incomplete-*')) {
            try { Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction Stop }
            catch { throw "Snapshot staging cleanup failed: $($_.Exception.Message)" }
        }
        Assert-SnapshotSpace $E.destination $Rollbacks
        Copy-Tree $E.destination $staging
        if ($DeduplicateSnapshots) {
            $previousRecords = @(Get-SnapshotRecords $E)
            if ($previousRecords.Count -gt 0) {
                $previousPath = Get-SnapshotRecordPath $previousRecords[-1]
                try { $previousPath = FullPath ([string]$previousPath) } catch { $previousPath = $null }
                if ($previousPath -and (Test-Path -LiteralPath $previousPath -PathType Container)) { Invoke-SnapshotDedupe $staging $previousPath }
            }
        }
        $snapshotHash = Get-TreeDigest $staging 2
        Move-Item -LiteralPath $staging -Destination $snapshot -ErrorAction Stop
        $snapshotCreated = $true
        $finalHash = Get-TreeDigest $snapshot 2
        Assert-Condition ($finalHash -eq $snapshotHash) "Snapshot verification failed after rename: $snapshot"
        $bytes = Get-TreeLogicalBytes $snapshot
        $record = New-SnapshotRecord $snapshot $snapshotHash $bytes $timestamp $Changes 2
        try { Save-SnapshotSidecar $snapshot $record $E.id } catch { Write-Warning "Snapshot sidecar not written: $($_.Exception.Message)" }
        return $record
    } catch {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        if ($snapshotCreated -and (Test-Path -LiteralPath $snapshot)) { Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($ownsLease) { Remove-OwnSnapshotLease $Rollbacks }
    }
}
function Ensure-LatestSnapshotRecord([object]$E) {
    $latestProperty = $E.PSObject.Properties['destinationSnapshot']
    if ($null -eq $latestProperty -or [string]::IsNullOrWhiteSpace([string]$latestProperty.Value)) { return $false }
    $latest = $null
    try { $latest = FullPath ([string]$latestProperty.Value) } catch { return $false }
    foreach ($record in @(Get-SnapshotRecords $E)) {
        $raw = Get-SnapshotRecordPath $record
        if ([string]::IsNullOrWhiteSpace([string]$raw)) { continue }
        try { if ((FullPath ([string]$raw)) -ieq $latest) { return $false } } catch { }
    }
    $hash = $null
    $hashProperty = $E.PSObject.Properties['destinationSnapshotHash']
    if ($null -ne $hashProperty) { $hash = [string]$hashProperty.Value }
    $version = 1
    $versionProperty = $E.PSObject.Properties['destinationSnapshotDigestVersion']
    if ($null -ne $versionProperty) { $version = [int]$versionProperty.Value }
    $bytes = [long]0
    $created = [DateTime]::UtcNow
    if (Test-Path -LiteralPath $latest -PathType Container) {
        if ([string]::IsNullOrWhiteSpace([string]$hash)) { $hash = Get-TreeDigest $latest $version }
        $bytes = Get-TreeLogicalBytes $latest
        $created = (Get-Item -LiteralPath $latest -Force).LastWriteTimeUtc
    }
    if ([string]::IsNullOrWhiteSpace([string]$hash)) { return $false }
    Add-SnapshotHistoryRecord $E (New-SnapshotRecord $latest $hash $bytes $created $null $version)
    return $true
}
function Copy-Tree([string]$Source, [string]$Destination) {
    Assert-TreeSafe $Source
    Assert-Condition (-not (Test-Path -LiteralPath $Destination)) "Destination exists; refusing overwrite: $Destination"
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    # Robocopy preserves data, attributes, timestamps, NTFS ACLs, and directory timestamps.
    # /XJ excludes junctions; preflight rejects all reparse points, including symlinks.
    & robocopy.exe $Source $Destination /E /COPY:DATS /DCOPY:DAT /XJ /R:1 /W:1 /NP /NFL /NDL | Out-Null
    $code = $LASTEXITCODE
    Assert-Condition ($code -lt 8) "Robocopy failed (exit $code): $Source"
    Assert-EqualTrees $Source $Destination
}
function DriveId([string]$Path) { return [IO.Path]::GetPathRoot((FullPath $Path)).ToUpperInvariant() }
function Resolve-DestinationRoot {
    Assert-Condition (-not (-not [string]::IsNullOrWhiteSpace($Root) -and -not [string]::IsNullOrWhiteSpace($DriveLetter))) 'Specify either -Root or -DriveLetter, not both.'
    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
        $script:Root = "${letter}:\agents"
    } elseif (-not [string]::IsNullOrWhiteSpace($Root)) {
        $script:Root = FullPath $Root
        Assert-Condition ($script:Root -match '^[A-Za-z]:\\agents$') 'Root must be a drive-root agents folder, e.g. D:\agents.'
    } else {
        Assert-Condition ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) 'Drive selection required: specify -DriveLetter D (or -Root D:\agents) for unattended use.'
        $answer = Read-Host 'Which destination drive letter should store the agents folder? (example D)'
        Assert-Condition ($answer -match '^[A-Za-z]:?$') 'Enter one drive letter only, e.g. D.'
        $letter = $answer.TrimEnd(':').ToUpperInvariant()
        $script:Root = "${letter}:\agents"
    }
}
function Require-Root {
    Assert-Condition ($env:OS -eq 'Windows_NT') 'Windows is required.'
    Resolve-DestinationRoot
    $drive = DriveId $script:Root
    Assert-Condition (Test-Path -LiteralPath $drive -PathType Container) "Destination drive $drive is unavailable."
    Assert-NoReparse $script:Root
    $script:Registry = Join-Path $script:Root 'registry'
    $script:ManifestPath = Join-Path $script:Registry 'migration-manifest.json'
}
function Discover {
    $homePath = $env:USERPROFILE
    $candidates = @(
        @{id='claude'; path=(Join-Path $homePath '.claude')},
        @{id='codex'; path=(Join-Path $homePath '.codex')},
        @{id='gemini'; path=(Join-Path $homePath '.gemini')},
        @{id='cursor'; path=(Join-Path $homePath '.cursor')},
        @{id='opencode'; path=(Join-Path $env:APPDATA 'opencode')}
    )
    $out = @()
    foreach ($c in $candidates) {
        if ($Agent -ne 'all' -and $Agent -ne $c.id) { continue }
        if (-not (Test-Path -LiteralPath $c.path -PathType Container)) { continue }
        Assert-TreeSafe $c.path
        $dest = Join-Path (Join-Path $script:Root 'agents') $c.id
        Assert-Condition (-not (IsWithin $dest $c.path)) "Destination nested inside source: $($c.path)"
        $files = @(Files-In $c.path)
        $bytes = [long]0
        foreach ($f in $files) { $bytes += $f.Length }
        $out += [pscustomobject]@{ id=$c.id; source=(FullPath $c.path); destination=$dest; hold=($c.path + '.qagents-migration-hold'); files=$files.Count; bytes=$bytes; state='Inventoried' }
    }
    return $out
}
function Update-State([object]$Manifest, [object]$Entry, [string]$State) {
    $Entry.state = $State
    $Manifest.updatedUtc = [DateTime]::UtcNow.ToString('o')
    Save-Json $Manifest $script:ManifestPath -Backup
}
function Ensure-Skeleton {
    foreach ($p in @('agents','shared\skills','shared\rules','shared\knowledge','shared\templates','shared\resources','registry','migration\reports','migration\logs','backups')) {
        New-Item -ItemType Directory -Path (Join-Path $script:Root $p) -Force | Out-Null
    }
}
function Selected([object]$Manifest) { return @($Manifest.entries | Where-Object { $Agent -eq 'all' -or $_.id -eq $Agent }) }
function Assert-OriginalOrHold([object]$E) {
    $sourceExists = Test-Path -LiteralPath $E.source -PathType Container
    $holdExists = Test-Path -LiteralPath $E.hold -PathType Container
    if ($holdExists) { Assert-TreeSafe $E.hold; return $E.hold }
    Assert-Condition $sourceExists "Neither source nor hold exists for $($E.id)"
    Assert-TreeSafe $E.source
    return $E.source
}
function Make-SkillsRegistry([object]$Manifest) {
    $items = @()
    foreach ($e in $Manifest.entries) {
        $skillsPath = Join-Path $e.destination 'skills'
        if (Test-Path -LiteralPath $skillsPath -PathType Container) {
            foreach ($s in @(Get-ChildItem -LiteralPath $skillsPath -Directory -Force)) {
                $items += [pscustomobject]@{agent=$e.id; name=$s.Name; path=$s.FullName; shared=$false}
            }
        }
    }
    # Registry only: do not merge skills automatically without compatibility review.
    Save-Json ([pscustomobject]@{generatedUtc=[DateTime]::UtcNow.ToString('o'); skills=@($items); sharedPool=(Join-Path $script:Root 'shared\skills')}) (Join-Path $script:Registry 'skills.json')
}

Require-Root
if ($Phase -eq 'Inventory') {
    Ensure-Skeleton
    Assert-Condition (-not (Test-Path -LiteralPath $script:ManifestPath)) 'Manifest already exists. Inspect Status; do not overwrite migration state.'
    $entries = @(Discover)
    Assert-Condition ($entries.Count -gt 0) 'No supported agent data directories found.'
    foreach ($e in $entries) {
        Assert-Condition (-not (Test-Path -LiteralPath $e.destination)) "Destination already exists: $($e.destination)"
        Assert-Condition (-not (Test-Path -LiteralPath $e.hold)) "Hold directory already exists: $($e.hold)"
    }
    $manifest = [pscustomobject]@{schema=1; createdUtc=[DateTime]::UtcNow.ToString('o'); updatedUtc=[DateTime]::UtcNow.ToString('o'); root=$script:Root; entries=$entries}
    Save-Json $manifest $script:ManifestPath
    $entries | Format-Table id,files,bytes,source,destination -AutoSize
    Write-Host "Inventory saved: $script:ManifestPath"
    exit 0
}
$manifest = Load-Json $script:ManifestPath
Assert-Condition ($manifest.schema -eq 1) 'Unsupported manifest schema.'
Assert-Condition ((FullPath $manifest.root) -ieq $script:Root) 'Root differs from manifest.'
$entries = @(Selected $manifest)
Assert-Condition ($entries.Count -gt 0) 'No matching agents in manifest.'

switch ($Phase) {
    'Status' {
        $rollbacks = Join-Path $script:Root 'migration\rollbacks'
        $rollbackDirs = @()
        if (Test-Path -LiteralPath $rollbacks -PathType Container) {
            $rollbackDirs = @(Get-ChildItem -LiteralPath $rollbacks -Directory -Force)
        }
        $lease = Read-SnapshotLease $rollbacks
        $leaseActive = Test-SnapshotLeaseActive $lease
        $activeStagingKey = $null
        if ($leaseActive -and $null -ne $lease) {
            $stagingProperty = $lease.PSObject.Properties['staging']
            if ($null -ne $stagingProperty -and -not [string]::IsNullOrWhiteSpace([string]$stagingProperty.Value)) {
                try { $activeStagingKey = (FullPath ([string]$stagingProperty.Value)).ToLowerInvariant() } catch { }
            }
        }
        $globalIssues = @()
        if ($null -ne $lease -and -not $leaseActive) { $globalIssues += New-Issue 'snapshot_lease_stale' ("Stale snapshot operation lease under {0}" -f $rollbacks) }
        if ($leaseActive) {
            $leaseAgent = if ($null -ne $lease.PSObject.Properties['agent']) { [string]$lease.agent } else { 'unknown' }
            $globalIssues += New-Issue 'snapshot_operation_active' ("Snapshot operation in progress for {0} under {1}" -f $leaseAgent, $rollbacks)
        }
        $referencedSnapshots = @{}
        foreach ($manifestEntry in @($manifest.entries)) {
            foreach ($referencePath in @(Get-SnapshotReferencePaths $manifestEntry)) {
                if ([string]::IsNullOrWhiteSpace([string]$referencePath)) { continue }
                try { $referencedSnapshots[(FullPath ([string]$referencePath)).ToLowerInvariant()] = $true } catch { }
            }
        }
        $orphanStaging = @()
        $restoreStaging = @()
        $unreferencedSnapshots = @()
        $deletingSnapshots = @()
        foreach ($dir in $rollbackDirs) {
            $key = (FullPath $dir.FullName).ToLowerInvariant()
            if ($dir.Name -like '.incomplete-*') {
                if (-not ($leaseActive -and $null -ne $activeStagingKey -and $key -eq $activeStagingKey)) { $orphanStaging += $dir }
                continue
            }
            if ($dir.Name -like '.deleting-*') { $deletingSnapshots += $dir; continue }
            if ($dir.Name -like '.restore-*') {
                if (-not ($leaseActive -and $null -ne $activeStagingKey -and $key -eq $activeStagingKey)) { $restoreStaging += $dir }
                continue
            }
            if (-not $referencedSnapshots.ContainsKey($key)) { $unreferencedSnapshots += $dir }
        }
        foreach ($dir in $orphanStaging) { $globalIssues += New-Issue 'staging_orphaned' ("Orphaned snapshot staging folder under {0}: {1}" -f $rollbacks, $dir.Name) }
        foreach ($dir in $restoreStaging) { $globalIssues += New-Issue 'restore_staging_orphaned' ("Orphaned restore staging folder under {0}: {1}" -f $rollbacks, $dir.Name) }
        foreach ($dir in $unreferencedSnapshots) { $globalIssues += New-Issue 'snapshot_unreferenced' ("Unreferenced destination snapshot folder under {0}: {1}" -f $rollbacks, $dir.Name) }
        foreach ($dir in $deletingSnapshots) { $globalIssues += New-Issue 'snapshot_delete_pending' ("Pending snapshot deletion under {0}: {1}" -f $rollbacks, $dir.Name) }
        $report = @()
        $allIssues = @()
        $restoreAlerts = @()
        foreach ($e in $entries) {
            $entryIssues = @()
            $destination = if (Test-Path -LiteralPath $e.destination -PathType Container) { 'present' } else { 'missing' }
            $hold = if (Test-Path -LiteralPath $e.hold -PathType Container) { 'present' } else { 'missing' }
            $legacy = 'missing'
            if (Test-Path -LiteralPath $e.source) {
                $item = Get-Item -LiteralPath $e.source -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $legacy = 'directory'
                } elseif ($item.LinkType -ne 'Junction') {
                    $legacy = 'other reparse point'
                } else {
                    $targets = @($item.Target)
                    if ($targets.Count -gt 0 -and (FullPath $targets[0]) -ieq (FullPath $e.destination)) { $legacy = 'junction' }
                    else { $legacy = 'redirected' }
                }
            }
            if ($destination -eq 'missing' -and $e.state -ne 'Inventoried') { $entryIssues += New-Issue 'destination_missing' 'destination missing or unavailable' $e.id }
            $destinationParent = Split-Path $e.destination -Parent
            $destinationLeaf = Split-Path $e.destination -Leaf
            if (Test-Path -LiteralPath $destinationParent -PathType Container) {
                $strandedBackups = @(Get-ChildItem -LiteralPath $destinationParent -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($destinationLeaf + '.pre-restore-*') })
                foreach ($backup in $strandedBackups) {
                    $strandedIssue = New-Issue 'restore_destination_stranded' ("stranded pre-restore destination backup: {0}" -f $backup.FullName) $e.id
                    $entryIssues += $strandedIssue
                    $restoreAlerts += $strandedIssue
                }
            }
            $entryIssues += @(Get-SnapshotProblems $e -Quick:$Quick)
            $entryIssues += @(Get-SnapshotHistoryProblems $e -Quick:$Quick)
            switch ($e.state) {
                { $_ -in @('Activated', 'BackupVerified') } {
                    if ($legacy -eq 'missing') { $entryIssues += New-Issue 'legacy_junction_missing' 'legacy junction missing' $e.id }
                    elseif ($legacy -eq 'redirected') { $entryIssues += New-Issue 'legacy_junction_redirected' 'legacy junction redirected' $e.id }
                    elseif ($legacy -ne 'junction') { $entryIssues += New-Issue 'legacy_not_junction' 'legacy path is not a junction' $e.id }
                    if ($hold -eq 'missing') { $entryIssues += New-Issue 'hold_missing' 'hold missing' $e.id }
                }
                'Complete' {
                    if ($legacy -ne 'junction') { $entryIssues += New-Issue 'legacy_junction_missing' 'legacy junction missing or redirected' $e.id }
                    if ($hold -eq 'present') { $entryIssues += New-Issue 'hold_present' 'hold still present' $e.id }
                }
                default {
                    if ($legacy -eq 'junction' -or $legacy -eq 'redirected') { $entryIssues += New-Issue 'legacy_junction_unexpected' ("legacy path is a junction while state is $($e.state)") $e.id }
                }
            }
            $records = @(Get-SnapshotRecords $e)
            $snapshotBytes = [long]0
            foreach ($record in $records) { $snapshotBytes += (Get-SnapshotRecordBytes $record) }
            $allIssues += @($entryIssues)
            $report += [pscustomobject]@{
                id = $e.id; state = $e.state; destination = $destination; hold = $hold; legacy = $legacy
                snapshotCount = $records.Count; snapshotBytes = $snapshotBytes
                issues = @($entryIssues); issuesText = (@($entryIssues | ForEach-Object { $_.message }) -join '; ')
            }
        }
        $allIssues += @($globalIssues)
        $issueCount = $allIssues.Count
        $inventory = @($report | ForEach-Object { [pscustomobject]@{ id = $_.id; snapshots = $_.snapshotCount; bytes = $_.snapshotBytes } })
        if ($AsJson) {
            $result = [pscustomobject]@{
                schema = 1; generatedUtc = [DateTime]::UtcNow.ToString('o'); root = $script:Root
                healthy = ($issueCount -eq 0); issueCount = $issueCount
                issues = @($allIssues); entries = @($report); inventory = @($inventory)
            }
            Write-Output (ConvertTo-Json -InputObject $result -Depth 20)
            if ($Strict -and $issueCount -gt 0) { exit 2 }
            exit 0
        }
        $report | Format-Table id, state, destination, hold, legacy, snapshotCount, snapshotBytes, issuesText -AutoSize
        foreach ($issue in $restoreAlerts) { Write-Warning $issue.message }
        foreach ($issue in $globalIssues) { Write-Warning $issue.message }
        if ($issueCount -gt 0) { Write-Warning ("Status found {0} issue(s); reconcile them before the next phase." -f $issueCount) }
        else { Write-Host 'Status: manifest matches disk for the selected agents.' }
        if ($Strict -and $issueCount -gt 0) { exit 2 }
        break
    }
    'Copy' {
        foreach ($e in $entries) {
            Assert-Condition ($e.state -eq 'Inventoried') "Cannot copy $($e.id) in state $($e.state)"
            Assert-Condition (-not (Test-Path -LiteralPath $e.hold)) 'Unexpected hold directory.'
            Assert-Condition (-not (Test-Path -LiteralPath $e.destination)) 'Destination exists: manual reconciliation required.'
            Copy-Tree $e.source $e.destination
            Update-State $manifest $e 'Copied'
            Write-Host "Copied and hashed: $($e.id)"
        }
        Make-SkillsRegistry $manifest
        break
    }
    'Verify' {
        foreach ($e in $entries) {
            Assert-Condition ($e.state -in @('Copied','Verified','Activated','BackupVerified','Complete')) "Cannot verify state $($e.state)"
            $from = Assert-OriginalOrHold $e
            Assert-EqualTrees $from $e.destination
            if ($e.state -eq 'Copied') { Update-State $manifest $e 'Verified' }
            Write-Host "Verified: $($e.id)"
        }
        break
    }
    'Activate' {
        if (-not $WhatIfPreference) { Assert-Condition $ConfirmAgentsStopped 'Close affected agents and pass -ConfirmAgentsStopped.' }
        foreach ($e in $entries) {
            Assert-Condition ($e.state -eq 'Verified') "Agent $($e.id) must be Verified before activation."
            Assert-Condition (-not (Test-Path -LiteralPath $e.hold)) "Hold already exists: $($e.hold)"
            Assert-TreeSafe $e.source
            Assert-EqualTrees $e.source $e.destination
            if ($WhatIfPreference) {
                [void]$PSCmdlet.ShouldProcess($e.source, "Rename to $($e.hold) and link to $($e.destination)")
                Write-Host ("would activate: {0} -> {1}" -f $e.source, $e.destination)
                continue
            }
            # Ensure source has not changed after verification before cutover.
            Rename-Item -LiteralPath $e.source -NewName ([IO.Path]::GetFileName($e.hold)) -ErrorAction Stop
            try {
                New-Item -ItemType Junction -Path $e.source -Target $e.destination -ErrorAction Stop | Out-Null
                Assert-Condition (Test-Path -LiteralPath $e.source -PathType Container) 'Junction inaccessible.'
                Assert-EqualTrees $e.hold $e.destination
                Update-State $manifest $e 'Activated'
                Write-Host "Activated junction: $($e.source) -> $($e.destination)"
            } catch {
                if (Test-Path -LiteralPath $e.source) {
                    $link = Get-Item -LiteralPath $e.source -Force
                    if (($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Remove-Item -LiteralPath $e.source -Force }
                }
                if (-not (Test-Path -LiteralPath $e.source)) { Rename-Item -LiteralPath $e.hold -NewName ([IO.Path]::GetFileName($e.source)) }
                throw
            }
        }
        break
    }
    'Rollback' {
        if (-not $WhatIfPreference) {
            Assert-Condition $ConfirmAgentsStopped 'Close affected agents and pass -ConfirmAgentsStopped.'
            Assert-Condition $ApproveRollback 'Explicit -ApproveRollback is required.'
        }
        $rollbacks = Join-Path $script:Root 'migration\rollbacks'
        $leaseHeld = $false
        if (-not $WhatIfPreference) {
            New-Item -ItemType Directory -Path $rollbacks -Force | Out-Null
            $lease = Enter-SnapshotLease $rollbacks $Agent '' ''
            $leaseHeld = $true
        }
        try {
        foreach ($e in $entries) {
            Assert-Condition ($e.state -in @('Activated','BackupVerified')) "Cannot roll back $($e.id) in state $($e.state)"
            Assert-Condition (Test-Path -LiteralPath $e.hold -PathType Container) "Hold missing: $($e.hold)"
            Assert-Condition (Test-Path -LiteralPath $e.destination -PathType Container) "Destination missing: $($e.destination)"
            Assert-TreeSafe $e.hold
            Assert-TreeSafe $e.destination
            $diff = Get-TreeDiff $e.hold $e.destination
            $diffCount = $diff.added.Count + $diff.removed.Count + $diff.changed.Count
            if ($diffCount -gt 0) {
                Write-Host ("destination differs: added={0} removed={1} changed={2}" -f $diff.added.Count, $diff.removed.Count, $diff.changed.Count)
                foreach ($kind in @('added', 'removed', 'changed')) {
                    $items = @($diff.$kind)
                    if ($items.Count -gt 0) { Write-Host ("  {0,-8}: {1}" -f $kind, (($items | Select-Object -First 10) -join ', ')) }
                }
                if (-not $AcceptDestinationChanges -and -not $WhatIfPreference) {
                    throw "Destination changed since activation; refusing rollback of $($e.id) without -AcceptDestinationChanges."
                }
                if ($WhatIfPreference) { Write-Host ("  note      : changed destination would be kept at {0}" -f $e.destination) }
                else { Write-Warning "Destination changed since activation; keeping the changed destination at $($e.destination)." }
            }
            if ($diffCount -gt 0 -and $AcceptDestinationChanges -and -not $WhatIfPreference) {
                try { $record = New-DestinationSnapshot $e $rollbacks $diff -LeaseHeld }
                catch { throw "Snapshot copy failed for $($e.id); no snapshot retained. $($_.Exception.Message)" }
                # The destination must not change while the snapshot is being copied.
                $after = Get-TreeDiff $e.hold $e.destination
                $beforeKey = (@($diff.added) -join '|') + '#' + (@($diff.removed) -join '|') + '#' + (@($diff.changed) -join '|')
                $afterKey = (@($after.added) -join '|') + '#' + (@($after.removed) -join '|') + '#' + (@($after.changed) -join '|')
                if ($beforeKey -ne $afterKey) {
                    if (Test-Path -LiteralPath $record.path) { Remove-Item -LiteralPath $record.path -Recurse -Force -ErrorAction SilentlyContinue }
                    $sidecar = Get-SnapshotSidecarPath $record.path
                    if (Test-Path -LiteralPath $sidecar) { Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue }
                    throw "Destination changed while snapshotting $($e.id); refusing rollback."
                }
                Wait-SnapshotFailpoint 'RollbackBeforeManifest' (Join-Path $rollbacks '.test-rollback-ready')
                Add-SnapshotRecord $e $record
                Write-Host "Destination snapshot: $($record.path)"
            }
            $sourceExists = Test-Path -LiteralPath $e.source
            if ($sourceExists) {
                $link = Get-Item -LiteralPath $e.source -Force
                Assert-Condition (($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Legacy path is not a junction; refusing rollback.'
                Assert-Condition ($link.LinkType -eq 'Junction') 'Legacy path is not a junction; refusing rollback.'
                $targets = @($link.Target)
                Assert-Condition ($targets.Count -gt 0 -and (FullPath $targets[0]) -ieq (FullPath $e.destination)) 'Legacy junction points elsewhere; refusing rollback.'
            }
            if ($WhatIfPreference) {
                [void]$PSCmdlet.ShouldProcess($e.source, "Remove junction and restore $($e.hold)")
                Write-Host ("would roll back: {0} (destination kept at {1})" -f $e.source, $e.destination)
                continue
            }
            if ($sourceExists) {
                [IO.Directory]::Delete($e.source)
                Assert-Condition (-not (Test-Path -LiteralPath $e.source)) 'Junction removal incomplete.'
            }
            Rename-Item -LiteralPath $e.hold -NewName ([IO.Path]::GetFileName($e.source)) -ErrorAction Stop
            Assert-Condition (Test-Path -LiteralPath $e.source -PathType Container) 'Restored source is missing.'
            Assert-NoReparse $e.source
            $e | Add-Member -NotePropertyName rolledBackUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            $e | Add-Member -NotePropertyName rolledBackWithChanges -NotePropertyValue ($diffCount -gt 0) -Force
            $e | Add-Member -NotePropertyName destinationChanges -NotePropertyValue ([pscustomobject]@{
                    added = $diff.added.Count; removed = $diff.removed.Count; changed = $diff.changed.Count
                }) -Force
            Update-State $manifest $e 'Verified'
            Write-Host "Rolled back $($e.id): $($e.source) (destination left at $($e.destination))"
        }
        } finally {
            if ($leaseHeld) { Remove-OwnSnapshotLease $rollbacks }
        }
        break
    }
    'Cleanup' {
        if (-not $WhatIfPreference) {
            Assert-Condition $ConfirmAgentsValidated 'Manually test each agent startup, skills, memory and writes; then pass -ConfirmAgentsValidated.'
            Assert-Condition $ApproveDeletion 'Explicit -ApproveDeletion is required.'
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($BackupRoot)) 'Independent -BackupRoot is required.'
        }
        $backup = if ([string]::IsNullOrWhiteSpace($BackupRoot)) { '' } else { FullPath $BackupRoot }
        if ($backup) {
            Assert-Condition (Test-Path -LiteralPath $backup -PathType Container) 'BackupRoot must exist.'
            Assert-Condition ((DriveId $backup) -ne (DriveId $script:Root)) 'Backup must be on a different drive than the destination.'
            foreach ($e in $entries) { Assert-Condition ((DriveId $backup) -ne (DriveId $e.source)) 'Backup must also be on a different drive than each source.' }
        }
        foreach ($e in $entries) {
            Assert-Condition ($e.state -in @('Activated','BackupVerified')) "Not activated: $($e.id)"
            Assert-Condition (Test-Path -LiteralPath $e.hold -PathType Container) "Hold missing: $($e.hold)"
            Assert-TreeSafe $e.hold
            $junction = Get-Item -LiteralPath $e.source -Force
            Assert-Condition (($junction.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Legacy path is not a junction.'
            Assert-Condition ($junction.LinkType -eq 'Junction') 'Legacy path is not a junction.'
            Assert-Condition ((FullPath $junction.Target) -ieq (FullPath $e.destination)) 'Legacy junction points elsewhere.'
            Assert-EqualTrees $e.hold $e.destination
            $backPath = if ($backup) { Join-Path $backup ("agents-" + $e.id) } else { '<BackupRoot>\agents-' + $e.id }
            if ($WhatIfPreference) {
                if ($e.state -eq 'Activated') { [void]$PSCmdlet.ShouldProcess($backPath, 'Copy verified hold to backup') }
                [void]$PSCmdlet.ShouldProcess($e.hold, 'Delete verified hold')
                Write-Host ("would clean up: {0} (backup at {1})" -f $e.hold, $backPath)
                continue
            }
            if ($e.state -eq 'Activated') {
                if (Test-Path -LiteralPath $backPath -PathType Container) {
                    # A rollback after an interrupted cleanup leaves the backup behind.
                    try { Assert-EqualTrees $e.hold $backPath }
                    catch { throw "Existing backup differs from the hold; refusing cleanup: $backPath. $($_.Exception.Message)" }
                    Update-State $manifest $e 'BackupVerified'
                    Write-Host "Resuming cleanup with existing backup: $backPath"
                } else {
                    Copy-Tree $e.hold $backPath
                    Update-State $manifest $e 'BackupVerified'
                }
            } else {
                Assert-Condition (Test-Path -LiteralPath $backPath -PathType Container) "Backup missing for BackupVerified entry: $backPath"
                Assert-EqualTrees $e.hold $backPath
            }
            # Revalidate immediately before destructive operation.
            Assert-EqualTrees $e.hold $e.destination
            Assert-EqualTrees $e.hold $backPath
            Write-Warning "Deleting ONLY verified hold directory: $($e.hold)"
            Remove-Item -LiteralPath $e.hold -Recurse -Force -ErrorAction Stop
            Assert-Condition (-not (Test-Path -LiteralPath $e.hold)) 'Hold cleanup incomplete.'
            Update-State $manifest $e 'Complete'
            Write-Host "Cleanup complete for $($e.id). Independent backup: $backPath"
        }
        break
    }
    'PruneSnapshots' {
        Assert-Condition ($KeepLast -ge 0 -or $KeepDays -ge 0) 'Specify -KeepLast N or -KeepDays N.'
        if (-not $WhatIfPreference) { Assert-Condition $ApproveSnapshotDeletion 'Explicit -ApproveSnapshotDeletion is required.' }
        $rollbacks = Join-Path $script:Root 'migration\rollbacks'
        Assert-Condition (Test-Path -LiteralPath $rollbacks -PathType Container) 'No rollbacks folder to prune.'
        Assert-NoActiveSnapshotLease $rollbacks
        $leaseHeld = $false
        if (-not $WhatIfPreference) {
            $lease = Enter-SnapshotLease $rollbacks $Agent '' ''
            $leaseHeld = $true
        }
        try {
        if (-not $WhatIfPreference) {
            foreach ($pending in @(Get-ChildItem -LiteralPath $rollbacks -Directory -Force -Filter '.deleting-*')) {
                Remove-Item -LiteralPath $pending.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($e in $entries) {
            $records = @(Get-SnapshotRecords $e)
            if ($records.Count -eq 0) { continue }
            $latestPath = $null
            $latestProperty = $e.PSObject.Properties['destinationSnapshot']
            if ($null -ne $latestProperty -and -not [string]::IsNullOrWhiteSpace([string]$latestProperty.Value)) {
                try { $latestPath = FullPath ([string]$latestProperty.Value) } catch { $latestPath = $null }
            }
            $latestKey = if ($null -ne $latestPath) { $latestPath.ToLowerInvariant() } else { $null }
            $keep = @{}
            if ($null -ne $latestKey) { $keep[$latestKey] = $true }
            $count = $records.Count
            for ($i = 0; $i -lt $count; $i++) {
                $record = $records[$i]
                $raw = Get-SnapshotRecordPath $record
                if ([string]::IsNullOrWhiteSpace([string]$raw)) { continue }
                try { $key = (FullPath ([string]$raw)).ToLowerInvariant() } catch { continue }
                $keepIt = $false
                if ($KeepLast -ge 0 -and $i -ge ($count - $KeepLast)) { $keepIt = $true }
                if ($KeepDays -ge 0) {
                    $created = Get-SnapshotRecordCreatedUtc $record
                    if ($null -eq $created -or $created.ToUniversalTime() -ge [DateTime]::UtcNow.AddDays(-$KeepDays)) { $keepIt = $true }
                }
                if (Test-SnapshotRecordPinned $record) { $keepIt = $true }
                if ($keepIt) { $keep[$key] = $true }
            }
            for ($i = 0; $i -lt $count; $i++) {
                $record = $records[$i]
                $raw = Get-SnapshotRecordPath $record
                if ([string]::IsNullOrWhiteSpace([string]$raw)) { continue }
                try { $full = FullPath ([string]$raw) } catch { continue }
                $key = $full.ToLowerInvariant()
                if ($keep.ContainsKey($key)) { continue }
                if ($null -ne $latestKey -and $key -eq $latestKey) { continue }
                if ($full -ieq (FullPath $rollbacks) -or -not (IsWithin $full $rollbacks)) { throw "Refusing to prune a snapshot outside rollbacks: $full" }
                if ($WhatIfPreference) { Write-Host "would prune snapshot: $full"; continue }
                if (-not (Test-Path -LiteralPath $full -PathType Container)) {
                    Remove-SnapshotRecord $e $full
                    Save-Json $manifest $script:ManifestPath -Backup
                    Write-Host "Pruned missing snapshot record: $full"
                    continue
                }
                $deleting = Join-Path $rollbacks ('.deleting-' + $e.id + '-' + [guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $full -Destination $deleting -ErrorAction Stop
                Remove-SnapshotRecord $e $full
                Save-Json $manifest $script:ManifestPath -Backup
                Remove-Item -LiteralPath $deleting -Recurse -Force -ErrorAction SilentlyContinue
                $sidecar = Get-SnapshotSidecarPath $full
                if (Test-Path -LiteralPath $sidecar) { Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue }
                Write-Host "Pruned snapshot: $full"
            }
            if (-not $WhatIfPreference -and (Ensure-LatestSnapshotRecord $e)) { Save-Json $manifest $script:ManifestPath -Backup }
        }
        } finally {
            if ($leaseHeld) { Remove-OwnSnapshotLease $rollbacks }
        }
        break
    }
    'AdoptSnapshots' {
        $rollbacks = Join-Path $script:Root 'migration\rollbacks'
        Assert-Condition (Test-Path -LiteralPath $rollbacks -PathType Container) 'No rollbacks folder to adopt from.'
        Assert-NoActiveSnapshotLease $rollbacks
        if (-not $WhatIfPreference) { Assert-Condition $ApproveSnapshotAdoption 'Explicit -ApproveSnapshotAdoption is required.' }
        $leaseHeld = $false
        if (-not $WhatIfPreference) {
            $lease = Enter-SnapshotLease $rollbacks $Agent '' ''
            $leaseHeld = $true
        }
        try {
        $changed = $false
        if (-not $WhatIfPreference) {
            foreach ($e in $entries) { if (Ensure-LatestSnapshotRecord $e) { $changed = $true } }
            if ($changed) { Save-Json $manifest $script:ManifestPath -Backup }
        }
        $referenced = @{}
        foreach ($manifestEntry in @($manifest.entries)) {
            foreach ($referencePath in @(Get-SnapshotReferencePaths $manifestEntry)) {
                if ([string]::IsNullOrWhiteSpace([string]$referencePath)) { continue }
                try { $referenced[(FullPath ([string]$referencePath)).ToLowerInvariant()] = $true } catch { }
            }
        }
        $candidates = @()
        foreach ($dir in @(Get-ChildItem -LiteralPath $rollbacks -Directory -Force)) {
            if ($dir.Name -like '.incomplete-*' -or $dir.Name -like '.deleting-*' -or $dir.Name -like '.restore-*') { continue }
            $key = (FullPath $dir.FullName).ToLowerInvariant()
            if (-not $referenced.ContainsKey($key)) { $candidates += $dir }
        }
        if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
            $wanted = FullPath $SnapshotPath
            $candidates = @($candidates | Where-Object { (FullPath $_.FullName) -ieq $wanted })
            Assert-Condition ($candidates.Count -eq 1) "Snapshot path is not an unreferenced folder under rollbacks: $SnapshotPath"
        }
        foreach ($dir in $candidates) {
            $owner = $null
            foreach ($candidateEntry in @($manifest.entries)) {
                if ($dir.Name -like ($candidateEntry.id + '-*')) {
                    if ($null -eq $owner -or $candidateEntry.id.Length -gt $owner.id.Length) { $owner = $candidateEntry }
                }
            }
            if ($null -eq $owner) { Write-Warning "Cannot attribute snapshot folder: $($dir.Name)"; continue }
            if ($Agent -ne 'all' -and $owner.id -ne $Agent) { continue }
            $path = FullPath $dir.FullName
            Assert-TreeSafe $path
            $version = $AdoptDigestVersion
            $sidecarPath = Get-SnapshotSidecarPath $path
            if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
                try {
                    $sidecar = Get-Content -LiteralPath $sidecarPath -Raw | ConvertFrom-Json
                    $sidecarVersion = $sidecar.PSObject.Properties['digestVersion']
                    if ($null -ne $sidecarVersion) { $version = [int]$sidecarVersion.Value }
                } catch { }
            }
            $hash = Get-TreeDigest $path $version
            $bytes = Get-TreeLogicalBytes $path
            $stamp = $dir.Name.Substring($owner.id.Length + 1)
            $stamp = $stamp -replace '-\d+$', ''
            $created = $null
            try { $created = [DateTime]::ParseExact($stamp, 'yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) } catch { $created = $dir.LastWriteTimeUtc }
            if ($WhatIfPreference) { Write-Host "would adopt snapshot: $path ($($owner.id))"; continue }
            $record = New-SnapshotRecord $path $hash $bytes $created $null $version
            Add-SnapshotHistoryRecord $owner $record
            Save-Json $manifest $script:ManifestPath -Backup
            try { Save-SnapshotSidecar $path $record $owner.id } catch { Write-Warning "Snapshot sidecar not written: $($_.Exception.Message)" }
            Write-Host "Adopted snapshot: $path ($($owner.id))"
        }
        } finally {
            if ($leaseHeld) { Remove-OwnSnapshotLease $rollbacks }
        }
        break
    }
    'RestoreSnapshot' {
        Assert-Condition ($Agent -ne 'all') 'Select one agent with -Agent for snapshot restore.'
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) 'Specify -SnapshotPath.'
        $rollbacks = Join-Path $script:Root 'migration\rollbacks'
        Assert-Condition (Test-Path -LiteralPath $rollbacks -PathType Container) 'No rollbacks folder.'
        Assert-NoActiveSnapshotLease $rollbacks
        $e = $entries[0]
        Assert-Condition ($e.state -in @('Activated', 'BackupVerified')) "Cannot restore snapshot for $($e.id) in state $($e.state)"
        $destinationParent = Split-Path $e.destination -Parent
        $destinationLeaf = Split-Path $e.destination -Leaf
        $strandedBackups = @()
        if (Test-Path -LiteralPath $destinationParent -PathType Container) {
            $strandedBackups = @(Get-ChildItem -LiteralPath $destinationParent -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($destinationLeaf + '.pre-restore-*') })
        }
        $staleRestoreStaging = @(Get-ChildItem -LiteralPath $rollbacks -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('.restore-' + $e.id + '-*') })
        if ($strandedBackups.Count -gt 0) { throw "Previous restore left a stranded pre-restore destination; reconcile it before restoring: $($strandedBackups.FullName -join ', ')" }
        if ($staleRestoreStaging.Count -gt 0) { throw "Previous restore left incomplete staging; reconcile it before restoring: $($staleRestoreStaging.FullName -join ', ')" }
        Assert-Condition (Test-Path -LiteralPath $e.destination -PathType Container) "Destination missing; reconcile it before restoring: $($e.destination)"
        $target = FullPath $SnapshotPath
        Assert-Condition (Test-Path -LiteralPath $target -PathType Container) "Snapshot not found: $target"
        $rollbacksFull = FullPath $rollbacks
        Assert-Condition ($target -ine $rollbacksFull -and (IsWithin $target $rollbacksFull)) 'Snapshot must be under migration\rollbacks.'
        $pathKey = $target.ToLowerInvariant()
        $referencedKeys = @{}
        foreach ($referencePath in @(Get-SnapshotReferencePaths $e)) {
            if ([string]::IsNullOrWhiteSpace([string]$referencePath)) { continue }
            try { $referencedKeys[(FullPath ([string]$referencePath)).ToLowerInvariant()] = $true } catch { }
        }
        Assert-Condition ($referencedKeys.ContainsKey($pathKey)) 'Snapshot is not referenced by this agent; adopt it first.'
        Assert-TreeSafe $target
        $expectedHash = $null
        $version = 2
        $latestProperty = $e.PSObject.Properties['destinationSnapshot']
        $latestKey = $null
        if ($null -ne $latestProperty -and -not [string]::IsNullOrWhiteSpace([string]$latestProperty.Value)) {
            try { $latestKey = (FullPath ([string]$latestProperty.Value)).ToLowerInvariant() } catch { }
        }
        if ($null -ne $latestKey -and $latestKey -eq $pathKey) {
            $hashProperty = $e.PSObject.Properties['destinationSnapshotHash']
            if ($null -ne $hashProperty) { $expectedHash = [string]$hashProperty.Value }
            $versionProperty = $e.PSObject.Properties['destinationSnapshotDigestVersion']
            if ($null -ne $versionProperty) { $version = [int]$versionProperty.Value }
        } else {
            foreach ($record in @(Get-SnapshotRecords $e)) {
                $raw = Get-SnapshotRecordPath $record
                if ([string]::IsNullOrWhiteSpace([string]$raw)) { continue }
                try { if ((FullPath ([string]$raw)) -ieq $target) { $expectedHash = Get-SnapshotRecordHash $record; $version = Get-SnapshotRecordVersion $record; break } } catch { }
            }
        }
        Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$expectedHash)) 'Snapshot has no recorded hash; adopt or repair it first.'
        $actual = Get-TreeDigest $target $version
        Assert-Condition ($actual -eq ([string]$expectedHash).ToLowerInvariant()) 'Snapshot hash does not match; refusing restore.'
        if (-not $WhatIfPreference) {
            Assert-Condition $ConfirmAgentsStopped 'Close affected agents and pass -ConfirmAgentsStopped.'
            Assert-Condition $ApproveSnapshotRestore 'Explicit -ApproveSnapshotRestore is required.'
        } else {
            [void]$PSCmdlet.ShouldProcess($e.destination, "Restore $target")
            Write-Host "would restore: $target -> $($e.destination)"
            break
        }
        $lease = Enter-SnapshotLease $rollbacks $e.id '' ''
        try {
            $diff = Get-TreeDiff $e.hold $e.destination
            $safety = New-DestinationSnapshot $e $rollbacks $diff -LeaseHeld
            Wait-SnapshotFailpoint 'RestoreBeforeSafetyManifest' (Join-Path $rollbacks '.test-restore-ready')
            Add-SnapshotRecord $e $safety
            Save-Json $manifest $script:ManifestPath -Backup
            Assert-SnapshotSpace $target $rollbacks
            $staging = Join-Path $rollbacks ('.restore-' + $e.id + '-' + [guid]::NewGuid().ToString('N'))
            $backupDest = $e.destination + '.pre-restore-' + [guid]::NewGuid().ToString('N')
            try {
                Copy-Tree $target $staging
                Rename-Item -LiteralPath $e.destination -NewName (Split-Path $backupDest -Leaf) -ErrorAction Stop
                if ($env:ADM_TEST_FAILPOINT -eq 'AfterDestinationRename') { [Environment]::Exit(98) }
                try {
                    Move-Item -LiteralPath $staging -Destination $e.destination -ErrorAction Stop
                    Assert-EqualTrees $target $e.destination
                } catch {
                    if (Test-Path -LiteralPath $e.destination) { Remove-Item -LiteralPath $e.destination -Recurse -Force -ErrorAction SilentlyContinue }
                    if (Test-Path -LiteralPath $backupDest) { Rename-Item -LiteralPath $backupDest -NewName (Split-Path $e.destination -Leaf) -ErrorAction Stop }
                    throw
                }
                if (Test-Path -LiteralPath $backupDest) { Remove-Item -LiteralPath $backupDest -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Host "Restored snapshot: $target -> $($e.destination)"
            } finally {
                if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            }
        } finally {
            Remove-OwnSnapshotLease $rollbacks
        }
        break
    }
}
