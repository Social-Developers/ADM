#requires -Version 5.1
<#
.SYNOPSIS
  Link shared skills into each migrated agent's own skills directory.
.DESCRIPTION
  Manifest-driven and discovery-based. For every entry in registry\migration-manifest.json
  the script confirms the legacy path is a junction to the verified destination, then
  locates that agent's own skills directory inside the destination by searching for a
  directory named 'skill' or 'skills' (excluding builtin, plugin, extension, staging and
  cache locations).

  Exactly one candidate is CONFIRMED. No candidate, or more than one, is UNCONFIRMED:
  the agent is reported and left untouched. Entries that are not activated are BLOCKED.

  For a confirmed agent, each non-dot, non-reparse directory in <root>\shared\skills becomes one junction
  inside that agent's skills directory. Existing entries are skipped, never overwritten.
  Report-only unless -Apply. Apply writes a report for this selection to registry\skill-links.json.
.PARAMETER Agent
  Limit the run to one agent id. Default 'all'.
.PARAMETER Root
  Explicit root, e.g. D:\agents. Use instead of -DriveLetter.
.PARAMETER DriveLetter
  Destination drive whose <letter>:\agents root should be used.
.PARAMETER IncludeHome
  Optional ';'-separated agent home paths to classify for a dry run before activation
  exists. These are reported as not linked and are never written to.
.PARAMETER Apply
  Create the junctions. Omit for a report-only run.
.EXAMPLE
  .\Link-SharedSkills.ps1 -DriveLetter Q
  .\Link-SharedSkills.ps1 -DriveLetter Q -Apply
  .\Link-SharedSkills.ps1 -IncludeHome "$env:USERPROFILE\.claude;$env:USERPROFILE\.codex"
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z][a-z0-9_]{0,47}$')]
    [string]$Agent = 'all',
    [string]$Root,
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DriveLetter,
    [string]$IncludeHome,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function FullPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\')
}
function SamePath([string]$Left, [string]$Right) {
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-PlainPath([string]$Path) {
    # Check ancestors first: a regular child of a junction is not a safe write location.
    $parent = [IO.Directory]::GetParent($Path)
    if ($null -ne $parent) { Assert-PlainPath $parent.FullName }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        Assert-Condition (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "Refusing redirected path: $Path"
    }
}
function Save-Json([object]$Object, [string]$Path) {
    $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    $json = ConvertTo-Json -InputObject $Object -Depth 15
    try {
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    } finally { [IO.File]::Delete($tmp) }
}
function Get-JunctionTarget([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or $item.LinkType -ne 'Junction') { return '' }
    $targets = @($item.Target)
    if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace($targets[0])) { return '' }
    return (FullPath $targets[0])
}
function Resolve-Root {
    Assert-Condition (([string]::IsNullOrWhiteSpace($Root)) -or ([string]::IsNullOrWhiteSpace($DriveLetter))) 'Specify either -Root or -DriveLetter, not both.'
    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
        $script:RootPath = "${letter}:\agents"
    } elseif (-not [string]::IsNullOrWhiteSpace($Root)) {
        $script:RootPath = FullPath $Root
        Assert-Condition ($script:RootPath -match '^[A-Za-z]:\\(?:.*\\)?agents$') 'Root must end in \agents, e.g. D:\agents.'
    } else {
        Assert-Condition ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) 'Drive selection required: specify -DriveLetter D (or -Root D:\agents) for unattended use.'
        $answer = Read-Host 'Which drive holds the agents folder? (example D)'
        Assert-Condition ($answer -match '^[A-Za-z]:?$') 'Enter one drive letter only, e.g. D.'
        $script:RootPath = "$($answer.TrimEnd(':').ToUpperInvariant()):\agents"
    }
}

# Vendored / tooling locations that never hold an agent's own skill definitions.
$script:SkipSegments = '^(node_modules|\.git|builtin|plugins?|extensions?|\.tmp|staging|sessions|projects|logs|caches?|CachedData|Code Cache|GPUCache)$'

function Find-SkillDirs([string]$Base, [int]$Depth = 3) {
    foreach ($dir in (Get-ChildItem -LiteralPath $Base -Directory -Force -ErrorAction Stop)) {
        if ($dir.Name -match $script:SkipSegments) { continue }
        if ($dir.Name -match '^skills?$') {
            $dir   # never discover a skill's *contents* as another installation directory
        } elseif ($Depth -gt 0 -and -not ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Assert-Condition ($dir.Name -notmatch '[. ]$') "Cannot safely inspect Win32-normalized directory: $($dir.FullName)"
            Find-SkillDirs $dir.FullName ($Depth - 1)
        }
    }
}

Assert-Condition ($env:OS -eq 'Windows_NT') 'Windows is required.'
Assert-Condition (-not ($Apply -and $PSBoundParameters.ContainsKey('IncludeHome'))) '-IncludeHome is report-only; omit -Apply.'
Resolve-Root

$manifestPath = Join-Path $script:RootPath 'registry\migration-manifest.json'
$sharedPath = Join-Path $script:RootPath 'shared\skills'
$linksPath = Join-Path $script:RootPath 'registry\skill-links.json'

$targets = @()
Assert-PlainPath $manifestPath
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Condition ($manifest.schema -eq 1) 'Unsupported manifest schema.'
    Assert-Condition (SamePath (FullPath $manifest.root) $script:RootPath) 'Root differs from manifest.'
    foreach ($e in $manifest.entries) {
        if ($Agent -ne 'all' -and $e.id -ne $Agent) { continue }
        $targets += [pscustomobject]@{
            id       = $e.id
            legacy   = $e.source
            home     = $e.destination
            state    = $e.state
            linkable = $true
        }
    }
} elseif ([string]::IsNullOrWhiteSpace($IncludeHome)) {
    throw "No migration manifest at $manifestPath. Run Inventory, Copy, Verify and Activate first, or pass -IncludeHome for a dry run."
}

if (-not [string]::IsNullOrWhiteSpace($IncludeHome)) {
    foreach ($h in ($IncludeHome -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $homePath = FullPath $h.Trim()
        $homeId = [IO.Path]::GetFileName($homePath).TrimStart('.')
        if ($Agent -ne 'all' -and $homeId -ne $Agent) { continue }
        if (-not (Test-Path -LiteralPath $homePath -PathType Container)) {
            Write-Host "Skipping missing home: $homePath" -ForegroundColor DarkYellow
            continue
        }
        $targets += [pscustomobject]@{
            id       = $homeId
            legacy   = $homePath
            home     = $homePath
            state    = 'not activated'
            linkable = $false
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Host "No matching agents to inspect for -Agent $Agent. Nothing was changed."
    exit 0
}

$sharedSkills = @()
Assert-PlainPath $sharedPath
if (Test-Path -LiteralPath $sharedPath -PathType Container) {
    $sharedSkills = @(Get-ChildItem -LiteralPath $sharedPath -Directory -Force |
        Where-Object { $_.Name -notmatch '^\.' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Sort-Object Name)
}
if ($Apply) {
    Assert-PlainPath $linksPath
    Assert-Condition (-not (Test-Path -LiteralPath $linksPath -PathType Container)) "Registry path is a directory: $linksPath"
}

Write-Host "root        : $($script:RootPath)"
Write-Host ("shared pool : {0} ({1} skill(s))" -f $sharedPath, $sharedSkills.Count)
Write-Host ("mode        : {0}" -f $(if ($Apply) { 'APPLY' } else { 'report only' }))
Write-Host ''

$results = @()
foreach ($t in @($targets | Sort-Object id)) {
    $status = ''
    $skillsDir = ''
    $reason = ''
    $linked = @()
    $linkedNow = @()
    $planned = @()
    $skipped = @()
    $failedSkill = ''

    if ($t.linkable) {
        try {
            Assert-Condition ($t.id -is [string] -and $t.id -cmatch '\A[a-z][a-z0-9_]{0,47}\z' -and $t.id -notmatch '^(all|con|prn|aux|nul|com[1-9]|lpt[1-9])$') "Invalid manifest agent id: $($t.id)"
            Assert-Condition ($t.state -in @('Activated','BackupVerified','Complete')) "manifest state is not activated: $($t.state)"
            $expected = Join-Path $script:RootPath "agents\$($t.id)"
            Assert-Condition (SamePath $t.home $expected) "unexpected manifest destination: $($t.home)"
            Assert-PlainPath $expected
            Assert-Condition (Test-Path -LiteralPath $expected -PathType Container) "destination missing: $expected"
            $target = Get-JunctionTarget $t.legacy
            Assert-Condition ([bool]$target) "legacy path is not a junction: $($t.legacy)"
            Assert-Condition (SamePath $target $expected) "legacy junction points elsewhere: $target"
        } catch {
            $status = 'BLOCKED'
            $reason = $_.Exception.Message
        }
    }

    if ($status -ne 'BLOCKED') {
        try {
            if (-not $t.linkable) { Assert-PlainPath $t.home }
            $candidates = @(Find-SkillDirs -Base $t.home)
            Assert-Condition ($candidates.Count -gt 0) 'no skill/skills directory found in this agent home'
            if ($candidates.Count -gt 1) { throw ('ambiguous: ' + (($candidates | ForEach-Object { $_.FullName }) -join ' | ')) }
            Assert-Condition (-not ($candidates[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) "skills directory is itself a reparse point: $($candidates[0].FullName)"
            $skillsDir = $candidates[0].FullName
            $status = 'CONFIRMED'
            if (-not $t.linkable) { $reason = 'inspection only (-IncludeHome); not linked' }
        } catch {
            $status = 'UNCONFIRMED'
            $reason = $_.Exception.Message
        }
    }

    if ($status -eq 'CONFIRMED' -and $t.linkable) {
        foreach ($s in $sharedSkills) {
            try {
                Assert-Condition ($s.Name -notmatch '[. ]$') "Skill name cannot be addressed without Win32 normalization: $($s.Name)"
                $dest = Join-Path $skillsDir $s.Name
                if (Test-Path -LiteralPath $dest) {
                    $why = 'already present'
                    if (SamePath (Get-JunctionTarget $dest) $s.FullName) {
                        $why = 'already linked'
                        $linkedNow += $s.Name
                    }
                    $skipped += [pscustomobject]@{ name = $s.Name; why = $why }
                    continue
                }
                # After a failure, only inspect remaining collisions for the report.
                if ($failedSkill) { continue }
                if ($Apply) {
                    # PS 5.1 expands wildcards in -Target. Resolve the exact directory
                    # first; '.' works even for names containing brackets and backticks.
                    Push-Location -LiteralPath $s.FullName
                    try { New-Item -ItemType Junction -Path $dest -Target '.' -ErrorAction Stop | Out-Null }
                    finally { Pop-Location }
                    $linked += $s.Name
                    $linkedNow += $s.Name
                } else { $planned += $s.Name }
            } catch {
                if (-not $failedSkill) {
                    $status = 'LINK FAILED'
                    $failedSkill = $s.Name
                    $reason = $_.Exception.Message
                }
            }
        }
    }

    $results += [pscustomobject]@{
        id        = $t.id
        legacy    = $t.legacy
        home      = $t.home
        skillsDir = $skillsDir
        status    = $status
        reason    = $reason
        failedSkill = $failedSkill
        linked    = @($linked)
        planned   = @($planned)
        linkedNow = @($linkedNow)
        skipped   = @($skipped | ForEach-Object { $_.name })
    }

    $label = if ($linked.Count -gt 0) { "$status (+$($linked.Count) linked)" } else { $status }
    Write-Host ("{0,-9} {1,-14} {2}" -f $t.id, $label, $(if ($skillsDir) { $skillsDir } else { $reason }))
    if ($failedSkill) { Write-Host ("          failed    : {0}" -f $failedSkill) -ForegroundColor Red }
    if ($reason -and $skillsDir) { Write-Host ("          reason    : {0}" -f $reason) -ForegroundColor Yellow }
    if ($planned.Count -gt 0) { Write-Host ("          would link: {0}" -f ($planned -join ', ')) -ForegroundColor Cyan }
    if ($linked.Count -gt 0) { Write-Host ("          linked    : {0}" -f ($linked -join ', ')) -ForegroundColor Green }
    if ($skipped.Count -gt 0) {
        $skipLabel = if ($Apply) { 'skipped   ' } else { 'would skip' }
        $notes = @($skipped | ForEach-Object { "{0} ({1})" -f $_.name, $_.why })
        Write-Host ("          {0}: {1}" -f $skipLabel, ($notes -join ', ')) -ForegroundColor DarkYellow
    }
}

$confirmed = @($results | Where-Object { $_.status -eq 'CONFIRMED' })
$failed = @($results | Where-Object { $_.status -eq 'LINK FAILED' })
$unconfirmed = @($results | Where-Object { $_.status -eq 'UNCONFIRMED' })
$blocked = @($results | Where-Object { $_.status -eq 'BLOCKED' })
$linkedCount = @($results | ForEach-Object { $_.linked }).Count
$plannedCount = @($results | ForEach-Object { $_.planned }).Count

Write-Host ''
Write-Host ("summary: confirmed={0} failed={1} unconfirmed={2} blocked={3} links {4}={5}" -f `
    $confirmed.Count, $failed.Count, $unconfirmed.Count, $blocked.Count, `
    $(if ($Apply) { 'created' } else { 'planned' }), $(if ($Apply) { $linkedCount } else { $plannedCount }))
if ($failed.Count -gt 0) {
    Write-Host ("LINK FAILED: {0}" -f (($failed | ForEach-Object { $_.id }) -join ', ')) -ForegroundColor Red
}
if ($unconfirmed.Count -gt 0) {
    Write-Host ("UNCONFIRMED: {0}" -f (($unconfirmed | ForEach-Object { $_.id }) -join ', ')) -ForegroundColor Yellow
    Write-Host 'No link was created for these agents. Confirm the real skills path from the agent''s own documentation before linking.'
}
if ($blocked.Count -gt 0) {
    Write-Host ("BLOCKED: {0} (activation incomplete or legacy path redirected)" -f (($blocked | ForEach-Object { $_.id }) -join ', ')) -ForegroundColor Yellow
}
if (-not $Apply) {
    Write-Host 'Report only. Use -Apply without -IncludeHome to link confirmed manifest entries.'
} else {
    Save-Json ([pscustomobject]@{
            generatedUtc = [DateTime]::UtcNow.ToString('o')
            root         = $script:RootPath
            sharedPool   = $sharedPath
            selection    = $Agent
            agents       = @($results | ForEach-Object {
                    [pscustomobject]@{
                        id        = $_.id
                        legacy    = $_.legacy
                        destination = $_.home
                        skillsDir = $_.skillsDir
                        status    = $_.status
                        reason    = $_.reason
                        failedSkill = $_.failedSkill
                        linked    = @($_.linkedNow)
                        createdThisRun = @($_.linked)
                        skipped   = @($_.skipped)
                    }
                })
        }) $linksPath
    Write-Host "Link registry written: $linksPath"
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
