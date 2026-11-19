#requires -Version 5.1
<#
.SYNOPSIS
  Conservative Windows agent-data migration to a user-selected drive\agents.
.DESCRIPTION
  Phases: Inventory, Copy, Verify, Activate, Rollback, Cleanup, Status.
  Activation creates legacy-path junctions after moving the original directories
  to same-volume hold directories. Cleanup requires independent verified backup.
  This script does not relocate application binaries or project repositories.
.EXAMPLE
  .\migrate-agents.ps1 -Phase Inventory -DriveLetter D
  .\migrate-agents.ps1 -Phase Copy
  .\migrate-agents.ps1 -Phase Verify
  .\migrate-agents.ps1 -Phase Activate -Agent claude -ConfirmAgentsStopped
  .\migrate-agents.ps1 -Phase Rollback -Agent claude -ConfirmAgentsStopped -ApproveRollback
  .\migrate-agents.ps1 -Phase Cleanup -Agent claude -BackupRoot 'R:\agent-migration-backup' -ConfirmAgentsValidated -ApproveDeletion
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Inventory','Copy','Verify','Activate','Rollback','Cleanup','Status')]
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
    [switch]$AcceptDestinationChanges
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
function Save-Json([object]$Object, [string]$Path) {
    $tmp = "$Path.tmp.$PID"
    $json = ConvertTo-Json -InputObject $Object -Depth 15
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($tmp, $Path, [NullString]::Value)
    } else { [IO.File]::Move($tmp, $Path) }
}
function Load-Json([string]$Path) {
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "Missing manifest: $Path. Run Inventory first."
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
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
function Get-TreeDigest([string]$Path) {
    Assert-TreeSafe $Path
    $lines = @(Files-In $Path | ForEach-Object {
            $rel = (Relative $Path $_.FullName).Replace('\', '/').ToLowerInvariant()
            "$rel|$($_.Length)|$(FileHash $_.FullName)"
        })
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((@($lines) -join "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}
function Get-SnapshotRequiredBytes([string]$Source) {
    $bytes = [long]0
    foreach ($f in @(Files-In $Source)) { $bytes += [long]$f.Length }
    # One spare mebibyte keeps the copy itself from exhausting the volume.
    return $bytes + 1MB
}
function Assert-SnapshotSpace([string]$Source, [string]$SnapshotRoot, [long]$AvailableBytes = -1) {
    # The optional availability argument lets the harness test the refusal boundary
    # without creating a nearly full volume; production callers omit it.
    $required = Get-SnapshotRequiredBytes $Source
    $volume = [IO.Path]::GetPathRoot((FullPath $SnapshotRoot))
    if ($AvailableBytes -lt 0) {
        $drive = New-Object -TypeName IO.DriveInfo -ArgumentList $volume
        $AvailableBytes = $drive.AvailableFreeSpace
        $volume = $drive.Name
    }
    Assert-Condition ($AvailableBytes -ge $required) (`
            "Insufficient free space for destination snapshot on {0}: need {1} bytes, have {2}." -f $volume, $required, $AvailableBytes)
}
function Get-SnapshotProblems([object]$E) {
    $property = $E.PSObject.Properties['destinationSnapshot']
    if ($null -eq $property) { return @() }
    $snapText = [string]$property.Value
    if ([string]::IsNullOrWhiteSpace($snapText)) { return @('destination snapshot path missing') }
    $rollbacks = Join-Path $script:Root 'migration\rollbacks'
    try { $snap = FullPath $snapText } catch { return @('destination snapshot path invalid') }
    if ($snap -ieq (FullPath $rollbacks) -or -not (IsWithin $snap $rollbacks)) { return @('destination snapshot outside rollbacks') }
    if (-not (Test-Path -LiteralPath $snap -PathType Container)) { return @('destination snapshot missing') }
    $hashProperty = $E.PSObject.Properties['destinationSnapshotHash']
    if ($null -eq $hashProperty -or [string]::IsNullOrWhiteSpace([string]$hashProperty.Value)) { return @('destination snapshot hash missing') }
    try {
        $actual = Get-TreeDigest $snap
    } catch { return @('destination snapshot unreadable') }
    if ($actual -ne ([string]$hashProperty.Value).ToLowerInvariant()) { return @('destination snapshot corrupted') }
    return @()
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
    Save-Json $Manifest $script:ManifestPath
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
        $report = @()
        $issueCount = 0
        $rollbacks = Join-Path $script:Root 'migration\rollbacks'
        $orphanStaging = @()
        if (Test-Path -LiteralPath $rollbacks -PathType Container) {
            $orphanStaging = @(Get-ChildItem -LiteralPath $rollbacks -Directory -Force -Filter '.incomplete-*')
        }
        foreach ($e in $entries) {
            $problems = @()
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
            if ($destination -eq 'missing' -and $e.state -ne 'Inventoried') { $problems += 'destination missing or unavailable' }
            $problems += @(Get-SnapshotProblems $e)
            switch ($e.state) {
                { $_ -in @('Activated', 'BackupVerified') } {
                    if ($legacy -eq 'missing') { $problems += 'legacy junction missing' }
                    elseif ($legacy -eq 'redirected') { $problems += 'legacy junction redirected' }
                    elseif ($legacy -ne 'junction') { $problems += 'legacy path is not a junction' }
                    if ($hold -eq 'missing') { $problems += 'hold missing' }
                }
                'Complete' {
                    if ($legacy -ne 'junction') { $problems += 'legacy junction missing or redirected' }
                    if ($hold -eq 'present') { $problems += 'hold still present' }
                }
                default {
                    if ($legacy -eq 'junction' -or $legacy -eq 'redirected') { $problems += "legacy path is a junction while state is $($e.state)" }
                }
            }
            if ($problems.Count -gt 0) { $issueCount += $problems.Count }
            $report += [pscustomobject]@{
                id = $e.id; state = $e.state; destination = $destination; hold = $hold; legacy = $legacy
                issues = (@($problems) -join '; ')
            }
        }
        $report | Format-Table id, state, destination, hold, legacy, issues -AutoSize
        if ($orphanStaging.Count -gt 0) {
            $issueCount += $orphanStaging.Count
            Write-Warning ("Orphaned snapshot staging folder(s) under {0}: {1}" -f $rollbacks, (($orphanStaging | ForEach-Object { $_.Name }) -join ', '))
        }
        if ($issueCount -gt 0) { Write-Warning ("Status found {0} issue(s); reconcile them before the next phase." -f $issueCount) }
        else { Write-Host 'Status: manifest matches disk for the selected agents.' }
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
                $rollbacks = Join-Path $script:Root 'migration\rollbacks'
                New-Item -ItemType Directory -Path $rollbacks -Force | Out-Null
                # A killed copy leaves only our staging folder; clear it before retrying.
                foreach ($stale in @(Get-ChildItem -LiteralPath $rollbacks -Directory -Force -Filter '.incomplete-*')) {
                    Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction Stop
                }
                Assert-SnapshotSpace $e.destination $rollbacks
                $base = Join-Path $rollbacks ($e.id + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
                $snapshot = $base
                $suffix = 2
                while (Test-Path -LiteralPath $snapshot) { $snapshot = "$base-$suffix"; $suffix++ }
                $staging = Join-Path $rollbacks ('.incomplete-' + $e.id + '-' + [guid]::NewGuid().ToString('N'))
                try {
                    Copy-Tree $e.destination $staging
                    $snapshotHash = Get-TreeDigest $staging
                    Move-Item -LiteralPath $staging -Destination $snapshot -ErrorAction Stop
                } catch {
                    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
                    throw "Snapshot copy failed for $($e.id); no snapshot retained. $($_.Exception.Message)"
                }
                $e | Add-Member -NotePropertyName destinationSnapshot -NotePropertyValue $snapshot -Force
                $e | Add-Member -NotePropertyName destinationSnapshotHash -NotePropertyValue $snapshotHash -Force
                Write-Host "Destination snapshot: $snapshot"
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
}
