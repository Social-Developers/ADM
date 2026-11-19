#requires -Version 5.1
<#
.SYNOPSIS
  Conservative Windows agent-data migration to a user-selected drive\agents.
.DESCRIPTION
  Phases: Inventory, Copy, Verify, Activate, Cleanup, Status.
  Activation creates legacy-path junctions after moving the original directories
  to same-volume hold directories. Cleanup requires independent verified backup.
  This script does not relocate application binaries or project repositories.
.EXAMPLE
  .\migrate-agents.ps1 -Phase Inventory -DriveLetter D
  .\migrate-agents.ps1 -Phase Copy
  .\migrate-agents.ps1 -Phase Verify
  .\migrate-agents.ps1 -Phase Activate -Agent claude -ConfirmAgentsStopped
  .\migrate-agents.ps1 -Phase Cleanup -Agent claude -BackupRoot 'R:\agent-migration-backup' -ConfirmAgentsValidated -ApproveDeletion
#>
[CmdletBinding()]
param(
    [ValidateSet('Inventory','Copy','Verify','Activate','Cleanup','Status')]
    [string]$Phase = 'Inventory',
    [string]$Root,
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DriveLetter,
    [ValidateSet('all','claude','codex','gemini','cursor','opencode')]
    [string]$Agent = 'all',
    [string]$BackupRoot,
    [switch]$ConfirmAgentsStopped,
    [switch]$ConfirmAgentsValidated,
    [switch]$ApproveDeletion
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
function FileHash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
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
    'Status' { $entries | Format-Table id,state,source,destination,hold -AutoSize; break }
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
        Assert-Condition $ConfirmAgentsStopped 'Close affected agents and pass -ConfirmAgentsStopped.'
        foreach ($e in $entries) {
            Assert-Condition ($e.state -eq 'Verified') "Agent $($e.id) must be Verified before activation."
            Assert-Condition (-not (Test-Path -LiteralPath $e.hold)) "Hold already exists: $($e.hold)"
            Assert-TreeSafe $e.source
            Assert-EqualTrees $e.source $e.destination
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
    'Cleanup' {
        Assert-Condition $ConfirmAgentsValidated 'Manually test each agent startup, skills, memory and writes; then pass -ConfirmAgentsValidated.'
        Assert-Condition $ApproveDeletion 'Explicit -ApproveDeletion is required.'
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($BackupRoot)) 'Independent -BackupRoot is required.'
        $backup = FullPath $BackupRoot
        Assert-Condition (Test-Path -LiteralPath $backup -PathType Container) 'BackupRoot must exist.'
        Assert-Condition ((DriveId $backup) -ne (DriveId $script:Root)) 'Backup must be on a different drive than the destination.'
        foreach ($e in $entries) { Assert-Condition ((DriveId $backup) -ne (DriveId $e.source)) 'Backup must also be on a different drive than each source.' }
        foreach ($e in $entries) {
            Assert-Condition ($e.state -in @('Activated','BackupVerified')) "Not activated: $($e.id)"
            Assert-Condition (Test-Path -LiteralPath $e.hold -PathType Container) "Hold missing: $($e.hold)"
            Assert-TreeSafe $e.hold
            $junction = Get-Item -LiteralPath $e.source -Force
            Assert-Condition (($junction.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Legacy path is not a junction.'
            Assert-Condition ($junction.LinkType -eq 'Junction') 'Legacy path is not a junction.'
            Assert-Condition ((FullPath $junction.Target) -ieq (FullPath $e.destination)) 'Legacy junction points elsewhere.'
            Assert-EqualTrees $e.hold $e.destination
            $backPath = Join-Path $backup ("agents-" + $e.id)
            if ($e.state -eq 'Activated') {
                Assert-Condition (-not (Test-Path -LiteralPath $backPath)) "Backup destination already exists: $backPath"
                Copy-Tree $e.hold $backPath
                Update-State $manifest $e 'BackupVerified'
            } else { Assert-EqualTrees $e.hold $backPath }
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
