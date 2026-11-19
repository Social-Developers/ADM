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

  For a confirmed agent, each directory in <root>\shared\skills becomes one junction
  inside that agent's skills directory. Existing entries are skipped, never overwritten.
  Report-only unless -Apply. Results are written to registry\skill-links.json.
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
    [ValidateSet('all','claude','codex','gemini','cursor','opencode')]
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
function FullPath([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd('\') }
function Save-Json([object]$Object, [string]$Path) {
    $tmp = "$Path.tmp.$PID"
    $json = ConvertTo-Json -InputObject $Object -Depth 15
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    [IO.File]::Move($tmp, $Path)
}
function Get-ReparseTarget([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return '' }
    $target = @($item.Target)[0]
    if ([string]::IsNullOrWhiteSpace($target)) { return '' }
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path $Path -Parent) $target }
    return (FullPath $target)
}
function Resolve-Root {
    Assert-Condition (([string]::IsNullOrWhiteSpace($Root)) -or ([string]::IsNullOrWhiteSpace($DriveLetter))) 'Specify either -Root or -DriveLetter, not both.'
    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
        $script:RootPath = "${letter}:\agents"
    } elseif (-not [string]::IsNullOrWhiteSpace($Root)) {
        $script:RootPath = FullPath $Root
        Assert-Condition ($script:RootPath -match '^[A-Za-z]:\\.*\\agents$') 'Root must end in \agents, e.g. D:\agents.'
    } else {
        Assert-Condition ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) 'Drive selection required: specify -DriveLetter D (or -Root D:\agents) for unattended use.'
        $answer = Read-Host 'Which drive holds the agents folder? (example D)'
        Assert-Condition ($answer -match '^[A-Za-z]:?$') 'Enter one drive letter only, e.g. D.'
        $script:RootPath = "$($answer.TrimEnd(':').ToUpperInvariant()):\agents"
    }
}

# Vendored / tooling locations that never hold an agent's own skill definitions.
$script:SkipSegments = '(?i)(^|\\)(node_modules|\.git|builtin|plugins?|extensions?|\.tmp|staging|sessions|projects|logs|caches?|Cache|CachedData|Code Cache|GPUCache)(\\|$)'

function Find-SkillDirs([string]$Base, [int]$Depth = 3) {
    if (-not (Test-Path -LiteralPath $Base)) { return @() }
    $baseFull = FullPath $Base
    return @(Get-ChildItem -LiteralPath $baseFull -Directory -Recurse -Depth $Depth -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^skills?$' } |
        Where-Object { $_.FullName.Substring($baseFull.Length).Trim('\') -notmatch $script:SkipSegments })
}

Assert-Condition ($env:OS -eq 'Windows_NT') 'Windows is required.'
Resolve-Root

$manifestPath = Join-Path $script:RootPath 'registry\migration-manifest.json'
$sharedPath = Join-Path $script:RootPath 'shared\skills'
$linksPath = Join-Path $script:RootPath 'registry\skill-links.json'

$targets = @()
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Condition ($manifest.schema -eq 1) 'Unsupported manifest schema.'
    Assert-Condition ((FullPath $manifest.root) -ieq $script:RootPath) 'Root differs from manifest.'
    foreach ($e in @($manifest.entries)) {
        if ($Agent -ne 'all' -and $e.id -ne $Agent) { continue }
        $targets += [pscustomobject]@{
            id       = $e.id
            legacy   = $e.source
            home     = $e.destination
            state    = $e.state
            origin   = 'manifest'
            linkable = $true
        }
    }
    Assert-Condition ($targets.Count -gt 0) "No matching agents in manifest for -Agent $Agent."
} elseif ([string]::IsNullOrWhiteSpace($IncludeHome)) {
    throw "No migration manifest at $manifestPath. Run Inventory, Copy, Verify and Activate first, or pass -IncludeHome for a dry run."
}

if (-not [string]::IsNullOrWhiteSpace($IncludeHome)) {
    foreach ($h in ($IncludeHome -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $homePath = FullPath $h.Trim()
        if (-not (Test-Path -LiteralPath $homePath -PathType Container)) {
            Write-Host "Skipping missing home: $homePath" -ForegroundColor DarkYellow
            continue
        }
        $targets += [pscustomobject]@{
            id       = Split-Path $homePath -Leaf
            legacy   = $homePath
            home     = $homePath
            state    = 'not activated'
            origin   = 'IncludeHome'
            linkable = $false
        }
    }
}

Assert-Condition ($targets.Count -gt 0) 'Nothing to inspect.'

$sharedSkills = @()
if (Test-Path -LiteralPath $sharedPath -PathType Container) {
    $sharedSkills = @(Get-ChildItem -LiteralPath $sharedPath -Directory -Force |
        Where-Object { $_.Name -notmatch '^\.' })
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
    $planned = @()
    $skipped = @()
    $failedSkill = ''

    if ($t.linkable) {
        $target = Get-ReparseTarget $t.legacy
        if (-not $target) {
            $status = 'BLOCKED'
            $reason = "legacy path is not a junction: $($t.legacy)"
        } elseif ($target -ine (FullPath $t.home)) {
            $status = 'BLOCKED'
            $reason = "legacy junction points elsewhere: $target"
        }
    } else {
        $status = 'DRY RUN'
    }

    if ($status -ne 'BLOCKED') {
        $candidates = @(Find-SkillDirs -Base $t.home)
        if ($candidates.Count -eq 1) {
            $skillsDir = $candidates[0].FullName
            $status = 'CONFIRMED'
        } elseif ($candidates.Count -eq 0) {
            $status = 'UNCONFIRMED'
            $reason = 'no skill/skills directory found in this agent home'
        } else {
            $status = 'UNCONFIRMED'
            $reason = 'ambiguous: ' + (($candidates | ForEach-Object { $_.FullName }) -join ' | ')
        }
    }

    $ownLink = if ($skillsDir) { Get-ReparseTarget $skillsDir } else { '' }
    if ($skillsDir -and $ownLink) {
        $status = 'UNCONFIRMED'
        $reason = "skills directory is itself a reparse point -> $ownLink; review manually"
    }

    if ($skillsDir -and $t.linkable -and $sharedSkills.Count -gt 0) {
        foreach ($s in $sharedSkills) {
            $dest = Join-Path $skillsDir $s.Name
            if (Test-Path -LiteralPath $dest) {
                $why = 'already present'
                $destTarget = Get-ReparseTarget $dest
                if ($destTarget -and ($destTarget -ieq (FullPath $s.FullName))) { $why = 'already linked' }
                $skipped += [pscustomobject]@{ name = $s.Name; why = $why }
                continue
            }
            if ($Apply) {
                try {
                    New-Item -ItemType Junction -Path $dest -Target $s.FullName -ErrorAction Stop | Out-Null
                    $linked += $s.Name
                } catch {
                    $status = 'LINK FAILED'
                    $failedSkill = $s.Name
                    $reason = $_.Exception.Message
                    break
                }
            } else {
                $planned += $s.Name
            }
        }
    }

    # What is actually linked now, regardless of whether this run created it.
    $linkedNow = @()
    if ($skillsDir) {
        foreach ($s in $sharedSkills) {
            $dest = Join-Path $skillsDir $s.Name
            if (-not (Test-Path -LiteralPath $dest)) { continue }
            $destTarget = Get-ReparseTarget $dest
            if ($destTarget -and ($destTarget -ieq (FullPath $s.FullName))) { $linkedNow += $s.Name }
        }
    }

    $results += [pscustomobject]@{
        id        = $t.id
        legacy    = $t.legacy
        home      = $t.home
        skillsDir = $skillsDir
        status    = $status
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
    Write-Host 'Report only. Re-run with -Apply to create the junctions.'
} else {
    New-Item -ItemType Directory -Path (Split-Path $linksPath -Parent) -Force | Out-Null
    Save-Json ([pscustomobject]@{
            generatedUtc = [DateTime]::UtcNow.ToString('o')
            root         = $script:RootPath
            sharedPool   = $sharedPath
            agents       = @($results | ForEach-Object {
                    [pscustomobject]@{
                        id        = $_.id
                        legacy    = $_.legacy
                        destination = $_.home
                        skillsDir = $_.skillsDir
                        status    = $_.status
                        linked    = @($_.linkedNow)
                        createdThisRun = @($_.linked)
                        skipped   = @($_.skipped)
                    }
                })
        }) $linksPath
    Write-Host "Link registry written: $linksPath"
}
exit 0
