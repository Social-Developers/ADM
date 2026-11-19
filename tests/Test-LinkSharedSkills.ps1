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

  Nothing outside the scratch root and the temp profile is touched; the deny rule is
  removed and both trees deleted at the end. Exit code 0 means every check passed.
.PARAMETER DriveLetter
  Scratch volume for the throwaway root, e.g. Q.
.EXAMPLE
  powershell -NoProfile -File tests\Test-LinkSharedSkills.ps1
#>
param(
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DriveLetter = 'Q'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Link-SharedSkills.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Link-SharedSkills.ps1 not found at $scriptPath." }

$root = '{0}:\_admtest\agents' -f $DriveLetter.TrimEnd(':').ToUpperInvariant()
$profileDir = Join-Path $env:TEMP 'adm-link-harness-profile'
$claudeHome = Join-Path $root 'agents\claude'
$cursorHome = Join-Path $root 'agents\cursor'
$claudeSkills = Join-Path $claudeHome 'skills'
$linksPath = Join-Path $root 'registry\skill-links.json'
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
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
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

$denyActive = $false
try {
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
    Check-Text $out 'denied' 'carries the access-denied reason'
    Check-Text $out 'skipped   : private-skill (already present), shared-demo (already linked)' 'still reports the skills it skipped'
    Check-Text $out 'LINK FAILED: claude' 'lists the failed agent'
    Check-Text $out 'failed=1' 'summary counts the failure'
    Check (-not (Test-Path -LiteralPath (Join-Path $claudeSkills 'zz-fail'))) 'no junction left for the failed skill'
    $reg = Get-Content -LiteralPath $linksPath -Raw | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'LINK FAILED') 'registry records LINK FAILED'
    Check (@($claude.linked) -contains 'shared-demo') 'registry keeps the link that already existed'
    Check (@($claude.createdThisRun).Count -eq 0) 'registry records nothing created this run'
}
finally {
    if ($denyActive) {
        try { Set-CreateDirectoriesDeny $claudeSkills -Remove } catch { Write-Host "WARNING: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    foreach ($p in @($root, $profileDir)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
    $scratchParent = Split-Path $root -Parent
    if ((Test-Path -LiteralPath $scratchParent) -and -not (Get-ChildItem -LiteralPath $scratchParent -Force)) {
        Remove-Item -LiteralPath $scratchParent -Force
    }
    Write-Host ''
    Write-Host ("leftovers root/profile : {0}/{1}" -f (Test-Path -LiteralPath $root), (Test-Path -LiteralPath $profileDir))
    Write-Host ("leftovers parent       : {0}" -f (Test-Path -LiteralPath $scratchParent))
    Write-Host ("checks: {0} run, {1} failed" -f $script:checks, $script:failures)
}
if ($script:failures -gt 0) { exit 1 }
Write-Host 'all checks passed'
exit 0
