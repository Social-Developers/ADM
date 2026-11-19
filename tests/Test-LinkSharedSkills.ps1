#requires -Version 5.1
<#
.SYNOPSIS
  Scratch harness for scripts\Link-SharedSkills.ps1.
.DESCRIPTION
  Builds a throwaway agents root and a throwaway profile, then runs the linker
  against them in child processes and checks what it reports.

  Scenarios:
    1. report only      - plans the one missing link, skips the collision, writes nothing
    2. apply            - creates the junction and the registry
    3. apply again      - creates nothing and reports both entries as skipped
    4. forced failure   - denies CreateDirectories on one agent's skills directory so
                          New-Item -ItemType Junction raises a real access-denied error,
                          exercising the LINK FAILED branch and its registry entry
    5. partial failure  - adds an agent that sorts first and links successfully while the
                          deny rule from scenario 4 is still in place, so one run both
                          creates links and reports a failure
    6. partial failure  - re-enables claude's skills directory and adds a shared skill whose
                          trailing dot only survives through a \\?\ path, so the junction
                          target cannot resolve: one link is created, the next fails

  Isolation: every run creates a unique %TEMP% folder with a random name and a
  sentinel file, maps a free drive letter to a folder inside it with subst, and
  deletes only that folder after the sentinel matches. No existing drive root,
  Q:\_admtest path or real agent data is touched. Exit code 0 means every check
  passed.
.EXAMPLE
  powershell -NoProfile -File tests\Test-LinkSharedSkills.ps1
#>
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Link-SharedSkills.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Link-SharedSkills.ps1 not found at $scriptPath." }

$runId = [guid]::NewGuid().ToString('N')
$tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$runRoot = Join-Path $tempBase ('adm-link-harness-' + $runId)
if (Test-Path -LiteralPath $runRoot) { throw "Refusing to reuse existing scratch root: $runRoot" }
New-Item -ItemType Directory -Path $runRoot | Out-Null
$sentinelPath = Join-Path $runRoot '.adm-link-harness'
Set-Content -LiteralPath $sentinelPath -Value $runId

$script:scratchLetters = @()
$rootLetter = ''
$root = ''
$volumeDir = ''
$profileDir = ''
$claudeHome = ''
$cursorHome = ''
$claudeSkills = ''
$linksPath = ''
$dotSkill = ''
$dotSkillPhysical = ''
$denyActive = $false
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

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
function Invoke-LinkScript {
    param([string[]]$Extra = @())
    $lines = & powershell.exe -NoProfile -File $scriptPath -Root $root @Extra 2>&1
    $code = $LASTEXITCODE
    $mode = if ($Extra.Count -gt 0) { $Extra -join ' ' } else { 'report only' }
    Check ($code -eq 0) ("script exited 0 ({0})" -f $mode)
    return (@($lines) | ForEach-Object { "$_" }) -join "`n"
}
function Set-CreateDirectoriesDeny([string]$Path, [switch]$Remove) {
    if ($Remove) { & icacls $Path /remove:d $me | Out-Null }
    else { & icacls $Path /deny "$($me):(AD)" | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with $LASTEXITCODE on $Path." }
}
function Initialize-Scratch {
    foreach ($p in @($root, $profileDir)) {
        if (Test-Path -LiteralPath $p) { throw "Refusing to reuse scratch path: $p" }
    }
    New-Item -ItemType Directory -Path (Join-Path $root 'registry'), (Join-Path $root 'shared\skills'), (Join-Path $root 'agents'), $profileDir -Force | Out-Null

    foreach ($s in @('shared-demo', 'private-skill')) {
        $dir = Join-Path $root "shared\skills\$s"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Value "# $s"
    }

    # claude: activated junction, own skills dir with a private skill that collides with the pool
    New-Item -ItemType Directory -Path (Join-Path $claudeSkills 'private-skill') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $claudeSkills 'private-skill\SKILL.md') -Value '# private'
    New-Item -ItemType Junction -Path (Join-Path $profileDir '.claude') -Target $claudeHome | Out-Null

    # cursor: activated junction, no skills dir at all
    New-Item -ItemType Directory -Path $cursorHome -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $profileDir '.cursor') -Target $cursorHome | Out-Null

    # gemini: never activated, so the legacy path is not a junction
    $manifest = [pscustomobject]@{
        schema  = 1
        root    = $root
        entries = @(
            [pscustomobject]@{ id = 'claude'; source = (Join-Path $profileDir '.claude'); destination = $claudeHome; state = 'active' }
            [pscustomobject]@{ id = 'cursor'; source = (Join-Path $profileDir '.cursor'); destination = $cursorHome; state = 'active' }
            [pscustomobject]@{ id = 'gemini'; source = (Join-Path $profileDir '.gemini'); destination = (Join-Path $root 'agents\gemini'); state = 'discovered' }
        )
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'registry\migration-manifest.json') -Encoding UTF8
}

try {
    $volumeDir = Join-Path $runRoot 'volume'
    $rootLetter = New-ScratchVolume $volumeDir
    # The linker requires an intermediate component: X:\<something>\agents.
    $root = "${rootLetter}:\scratch\agents"
    $profileDir = Join-Path $runRoot 'profile'
    $claudeHome = Join-Path $root 'agents\claude'
    $cursorHome = Join-Path $root 'agents\cursor'
    $claudeSkills = Join-Path $claudeHome 'skills'
    $linksPath = Join-Path $root 'registry\skill-links.json'
    $dotSkill = Join-Path $root 'shared\skills\zz-dot.'
    $dotSkillPhysical = Join-Path $volumeDir 'scratch\agents\shared\skills\zz-dot.'

    Initialize-Scratch
    Write-Host ''
    Write-Host '=== setup ==='
    Write-Host "root    : $root"
    Write-Host "profile : $profileDir"

    Write-Host ''
    Write-Host '=== 1. report only ==='
    $out = Invoke-LinkScript
    Write-Host $out
    Check-Text $out 'would link: shared-demo' 'plans the missing link'
    Check-Text $out 'would skip: private-skill (already present)' 'explains the skipped collision'
    Check-Text $out 'summary: confirmed=1 failed=0 unconfirmed=1 blocked=1 links planned=1' 'summary counts the planned link'
    Check (-not (Test-Path -LiteralPath (Join-Path $claudeSkills 'shared-demo'))) 'report mode created no junction'
    Check (-not (Test-Path -LiteralPath $linksPath)) 'report mode wrote no registry'

    Write-Host ''
    Write-Host '=== 2. apply ==='
    $out = Invoke-LinkScript @('-Apply')
    Write-Host $out
    Check-Text $out 'links created=1' 'reports one link created'
    Check-Text $out 'linked    : shared-demo' 'names the link it created'
    $demo = Get-Item -LiteralPath (Join-Path $claudeSkills 'shared-demo') -Force
    Check ($demo.LinkType -eq 'Junction') 'shared-demo is a junction'
    Check ((Test-Path -LiteralPath (Join-Path $claudeSkills 'shared-demo\SKILL.md'))) 'shared skill reads through the junction'
    $reg = Get-Content -LiteralPath $linksPath -Raw | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'CONFIRMED') 'registry records CONFIRMED'
    Check (@($claude.createdThisRun) -contains 'shared-demo') 'registry records the created link'

    Write-Host ''
    Write-Host '=== 3. apply again (idempotent) ==='
    $out = Invoke-LinkScript @('-Apply')
    Write-Host $out
    Check-Text $out 'links created=0' 'creates nothing on the second run'
    Check-Text $out 'skipped   : private-skill (already present), shared-demo (already linked)' 'distinguishes a collision from an existing link'
    $reg = Get-Content -LiteralPath $linksPath -Raw | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check (@($claude.createdThisRun).Count -eq 0) 'registry records nothing created this run'

    Write-Host ''
    Write-Host '=== 4. forced junction failure ==='
    # one pool skill that cannot be created, sorted last so the skips still report
    $failSkill = Join-Path $root 'shared\skills\zz-fail'
    New-Item -ItemType Directory -Path $failSkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $failSkill 'SKILL.md') -Value '# zz-fail'
    Set-CreateDirectoriesDeny $claudeSkills
    $denyActive = $true
    Write-Host "denied CreateDirectories for $me on $claudeSkills"
    $out = Invoke-LinkScript @('-Apply')
    Write-Host $out
    Check-Text $out 'LINK FAILED' 'reports the failed link'
    Check-Text $out 'failed    : zz-fail' 'names the skill that failed'
    Check ($out -match '(?m)^\s+reason\s+: \S') 'prints a non-empty failure reason'
    Check-Text $out 'skipped   : private-skill (already present), shared-demo (already linked)' 'still reports the skills it skipped'
    Check-Text $out 'LINK FAILED: claude' 'lists the failed agent'
    Check-Text $out 'failed=1' 'summary counts the failure'
    Check (-not (Test-Path -LiteralPath (Join-Path $claudeSkills 'zz-fail'))) 'no junction left for the failed skill'
    $reg = Get-Content -LiteralPath $linksPath -Raw | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'LINK FAILED') 'registry records LINK FAILED'
    Check (@($claude.linked) -contains 'shared-demo') 'registry keeps the link that already existed'
    Check (@($claude.createdThisRun).Count -eq 0) 'registry records nothing created this run'

    Write-Host ''
    Write-Host '=== 5. partial failure across agents ==='
    # aider sorts before claude, so its links are created before claude reaches the
    # deny rule that scenario 4 left on claude's skills directory.
    $aiderHome = Join-Path $root 'agents\aider'
    $aiderSkills = Join-Path $aiderHome 'skills'
    New-Item -ItemType Directory -Path $aiderSkills -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $profileDir '.aider') -Target $aiderHome | Out-Null
    $manifestPath = Join-Path $root 'registry\migration-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.entries = @($manifest.entries) + [pscustomobject]@{
        id = 'aider'; source = (Join-Path $profileDir '.aider'); destination = $aiderHome; state = 'active'
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $out = Invoke-LinkScript @('-Apply')
    Write-Host $out
    Check-Text $out 'CONFIRMED (+3 linked)' 'reports the links created before the failure'
    Check-Text $out 'links created=3' 'counts the links that were created'
    Check-Text $out 'failed=1' 'counts the later failure'
    Check ((Test-Path -LiteralPath (Join-Path $aiderSkills 'shared-demo\SKILL.md'))) 'earlier link survives the later failure'
    Check (-not (Test-Path -LiteralPath (Join-Path $claudeSkills 'zz-fail'))) 'denied agent still has no link'
    $reg = Get-Content -LiteralPath $linksPath -Raw | ConvertFrom-Json
    $aider = $reg.agents | Where-Object { $_.id -eq 'aider' }
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($aider.status -eq 'CONFIRMED') 'registry keeps the earlier agent confirmed'
    Check (@($aider.createdThisRun).Count -eq 3) 'registry records the earlier links'
    Check ($claude.status -eq 'LINK FAILED') 'registry records the later failure'
    Check (@($claude.createdThisRun).Count -eq 0) 'registry credits nothing to the failed agent'

    Write-Host ''
    Write-Host '=== 6. partial failure in one agent ==='
    # Scenario 4 still denies claude's skills directory; lift that and drop the link
    # scenario 2 created so this run recreates it. -Agent keeps scenario 5's extra agent
    # out of the picture.
    Set-CreateDirectoriesDeny $claudeSkills -Remove
    $denyActive = $false
    [IO.Directory]::Delete((Join-Path $claudeSkills 'shared-demo'))

    # Denying the directory fails every name, and any existing destination reads as present,
    # so failing one skill needs a name Win32 cannot address. A trailing dot survives only
    # through a \\?\ path: it is listed as zz-dot., but New-Item resolves the target to
    # zz-dot and throws. Skills sorting before it still link.
    [IO.Directory]::CreateDirectory('\\?\' + $dotSkillPhysical) | Out-Null
    $out = Invoke-LinkScript -Extra @('-Apply', '-Agent', 'claude')
    Write-Host $out
    Check-Text $out 'LINK FAILED (+1 linked)' 'labels the partial failure with its linked count'
    Check-Text $out 'linked    : shared-demo' 'names the link created before the failure'
    Check-Text $out 'failed    : zz-dot.' 'names the skill that failed'
    Check ((Test-Path -LiteralPath (Join-Path $claudeSkills 'shared-demo\SKILL.md'))) 'created link survives the failure'
    $reg = Get-Content -LiteralPath $linksPath -Raw | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'LINK FAILED') 'registry records LINK FAILED with the link'
    Check (@($claude.createdThisRun) -contains 'shared-demo') 'registry credits the created link'
}
finally {
    if ($denyActive -and $claudeSkills) {
        try { Set-CreateDirectoriesDeny $claudeSkills -Remove } catch { Write-Host "WARNING: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    # A trailing-dot name cannot be removed through a Win32 path; drop it explicitly.
    if ($dotSkillPhysical) {
        try { [IO.Directory]::Delete('\\?\' + $dotSkillPhysical, $true) }
        catch [System.IO.DirectoryNotFoundException] { }
        catch { Write-Host "WARNING: could not remove $dotSkillPhysical : $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    foreach ($letter in $script:scratchLetters) { & subst.exe "${letter}:" /D | Out-Null }

    $removable = $false
    if (Test-Path -LiteralPath $sentinelPath) {
        $token = (Get-Content -LiteralPath $sentinelPath -Raw).Trim()
        $insideTemp = ([IO.Path]::GetFullPath($runRoot)).StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)
        $removable = ($token -eq $runId) -and $insideTemp -and ((Split-Path $runRoot -Leaf) -like 'adm-link-harness-*')
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
