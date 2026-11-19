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
    Assert-Condition (-not (-not [string]::IsNullOrWhiteSpace($Root) -and -not [string]::IsNullOrWhiteSpace($DriveLetter))) 'Specify either -Root or -DriveLetter, not both.'
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
    $found = @(Get-ChildItem -LiteralPath $baseFull -Directory -Recurse -Depth $Depth -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^skills?$' })
    $keep = @()
    foreach ($d in $found) {
        $rel = $d.FullName.Substring($baseFull.Length).Trim('\')
        if ($rel -match $script:SkipSegments) { continue }
        $keep += $d
    }
    return $keep
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
    $detail = ''
    $linked = @()
    $skipped = @()

    if ($t.linkable) {
        $target = Get-ReparseTarget $t.legacy
        if (-not $target) {
            $status = 'BLOCKED'
            $detail = "legacy path is not a junction: $($t.legacy)"
        } elseif ($target -ine (FullPath $t.home)) {
            $status = 'BLOCKED'
            $detail = "legacy junction points elsewhere: $target"
        }
    } else {
        $status = 'DRY RUN'
    }

    if ($status -eq '' -or $status -eq 'DRY RUN') {
        $candidates = @(Find-SkillDirs -Base $t.home)
        if ($candidates.Count -eq 1) {
            $skillsDir = $candidates[0].FullName
            $status = 'CONFIRMED'
            $detail = $skillsDir
        } elseif ($candidates.Count -eq 0) {
            $status = 'UNCONFIRMED'
            $detail = 'no skill/skills directory found in this agent home'
        } else {
            $status = 'UNCONFIRMED'
            $detail = 'ambiguous: ' + (($candidates | ForEach-Object { $_.FullName }) -join ' | ')
        }
    }

    $ownLink = if ($skillsDir) { Get-ReparseTarget $skillsDir } else { '' }
    if ($skillsDir -and $ownLink) {
        $status = 'UNCONFIRMED'
        $detail = "skills directory is itself a reparse point -> $ownLink; review manually"
    }

    if ($skillsDir -and $t.linkable -and $sharedSkills.Count -gt 0) {
        foreach ($s in $sharedSkills) {
            $dest = Join-Path $skillsDir $s.Name
            if (Test-Path -LiteralPath $dest) {
                $skipped += $s.Name
                continue
            }
            if ($Apply) {
                try {
                    New-Item -ItemType Junction -Path $dest -Target $s.FullName -ErrorAction Stop | Out-Null
                    $linked += $s.Name
                } catch {
                    $status = 'LINK FAILED'
                    $detail = $_.Exception.Message
                    break
                }
            } else {
                $skipped += $s.Name
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
        detail    = $detail
        linked    = @($linked)
        linkedNow = @($linkedNow)
        skipped   = @($skipped)
    }

    $label = if ($linked.Count -gt 0) { "$status (+$($linked.Count) linked)" } else { $status }
    Write-Host ("{0,-9} {1,-14} {2}" -f $t.id, $label, $(if ($detail) { $detail } else { $skillsDir }))
    if ($linked.Count -gt 0) { Write-Host ("          linked : {0}" -f ($linked -join ', ')) -ForegroundColor Green }
    if ($skipped.Count -gt 0 -and $Apply) { Write-Host ("          skipped: {0} (already present)" -f ($skipped -join ', ')) -ForegroundColor DarkYellow }
}

$confirmed = @($results | Where-Object { $_.status -eq 'CONFIRMED' -or $_.status -eq 'LINK FAILED' -or $_.linked.Count -gt 0 })
$unconfirmed = @($results | Where-Object { $_.status -eq 'UNCONFIRMED' })
$blocked = @($results | Where-Object { $_.status -eq 'BLOCKED' })
$created = @($results | ForEach-Object { $_.linked }).Count

Write-Host ''
Write-Host ("summary: confirmed={0} unconfirmed={1} blocked={2} links {3}={4}" -f `
    $confirmed.Count, $unconfirmed.Count, $blocked.Count, $(if ($Apply) { 'created' } else { 'planned' }), $created)
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
