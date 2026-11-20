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
    5. partial failure  - moves the deny rule to codex so claude succeeds before codex fails
    6. partial failure  - adds a shared skill whose
                          trailing dot is not safely addressable: one link is created, the next fails
    Additional fixtures cover literal/Unicode names, all five agents, empty or ambiguous
    layouts, redirected paths and unactivated homes.

  Isolation: every run creates a unique %TEMP% folder with a random name and a
  sentinel file, optionally maps a free drive letter to a folder inside it with subst, and
  deletes only that folder after the sentinel matches. No existing drive root,
  Q:\_admtest path or real agent data is touched. Exit code 0 means every check
  passed.
.EXAMPLE
  powershell -NoProfile -File tests\Test-LinkSharedSkills.ps1
.EXAMPLE
  powershell -NoProfile -File tests\Test-LinkSharedSkills.ps1 -NoSubst
#>
param([switch]$NoSubst)
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
$dotSkillPhysical = ''
$denyPath = ''
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
    Set-Content -LiteralPath (Join-Path $Path '.volume-owner') -Value $runId
    $letter = $null
    foreach ($c in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        if (Test-Path -LiteralPath ("{0}:\" -f $c)) { continue }
        $letter = [string]$c
        break
    }
    if (-not $letter) { throw 'No free drive letter for a scratch volume.' }
    & subst.exe "${letter}:" $Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "subst failed: ${letter}: -> $Path" }
    $script:scratchLetters += $letter
    if (-not (Test-Path -LiteralPath "${letter}:\")) {
        throw "subst failed: ${letter}: -> $Path"
    }
    return $letter
}
function Invoke-LinkScript {
    param([string[]]$Extra = @(), [switch]$ExpectError)
    try {
        $ErrorActionPreference = 'Continue' # capture stderr for expected refusals
        $lines = & powershell.exe -NoProfile -NonInteractive -File $scriptPath -Root $root @Extra 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    $mode = if ($Extra.Count -gt 0) { $Extra -join ' ' } else { 'report only' }
    Check (($code -ne 0) -eq [bool]$ExpectError) ("script exit code {0} ({1})" -f $code, $mode)
    return (@($lines) | ForEach-Object { "$_" }) -join "`n"
}
function New-FixtureJunction([string]$Path, [string]$Target) {
    Push-Location -LiteralPath $Target
    try { New-Item -ItemType Junction -Path $Path -Target '.' | Out-Null }
    finally { Pop-Location }
}
function Save-Manifest($Manifest) {
    # Match the migration engine's BOM-less UTF-8 (not PS 5.1's default ANSI input).
    [IO.File]::WriteAllText($manifestPath, ($Manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}
function Remove-FixtureTree([IO.DirectoryInfo]$Dir) {
    # Do not recurse through any junctions, including ones with missing targets.
    if (-not ($Dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        foreach ($child in $Dir.GetFileSystemInfos()) {
            if ($child -is [IO.DirectoryInfo]) { Remove-FixtureTree $child }
            else { $child.Delete() }
        }
    }
    $Dir.Delete()
}
function Set-CreateDirectoriesDeny([string]$Path, [switch]$Remove) {
    if ($Remove) { & icacls $Path /remove:d $me | Out-Null }
    else { & icacls $Path /deny "$($me):(AD)" | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with $LASTEXITCODE on $Path." }
}
function Initialize-Scratch {
    New-Item -ItemType Directory -Path (Join-Path $root 'registry'), (Join-Path $root 'shared\skills'), (Join-Path $root 'agents'), $profileDir -Force | Out-Null

    foreach ($s in @('shared-demo', 'private-skill')) {
        $dir = Join-Path $root "shared\skills\$s"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Value "# $s"
    }

    # claude: activated junction, own skills dir with a private skill that collides with the pool
    New-Item -ItemType Directory -Path (Join-Path $claudeSkills 'private-skill') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $claudeSkills 'private-skill\SKILL.md') -Value '# private'
    New-FixtureJunction (Join-Path $profileDir '.claude') $claudeHome

    # cursor: activated junction, no skills dir at all
    New-Item -ItemType Directory -Path $cursorHome -Force | Out-Null
    New-FixtureJunction (Join-Path $profileDir '.cursor') $cursorHome

    # gemini: never activated, so the legacy path is not a junction
    $manifest = [pscustomobject]@{
        schema  = 1
        root    = $root
        entries = @(
            [pscustomobject]@{ id = 'claude'; source = (Join-Path $profileDir '.claude'); destination = $claudeHome; state = 'Activated' }
            [pscustomobject]@{ id = 'cursor'; source = (Join-Path $profileDir '.cursor'); destination = $cursorHome; state = 'Complete' }
            [pscustomobject]@{ id = 'gemini'; source = (Join-Path $profileDir '.gemini'); destination = (Join-Path $root 'agents\gemini'); state = 'Inventoried' }
        )
    }
    Save-Manifest $manifest
}

try {
    $volumeDir = Join-Path $runRoot 'volume [dev]'
    if ($NoSubst) { $root = Join-Path $volumeDir 'agents' }
    else {
        $rootLetter = New-ScratchVolume $volumeDir
        $root = "${rootLetter}:\agents"
    }
    $profileDir = Join-Path $runRoot ('scratch profile [' + [char]0x732B + ']')
    $claudeHome = Join-Path $root 'agents\claude'
    $cursorHome = Join-Path $root 'agents\cursor'
    $claudeSkills = Join-Path $claudeHome 'skills'
    $linksPath = Join-Path $root 'registry\skill-links.json'
    $manifestPath = Join-Path $root 'registry\migration-manifest.json'
    $dotSkillPhysical = Join-Path $volumeDir 'agents\shared\skills\zz-dot.'

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
    $reg = Get-Content -LiteralPath $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'CONFIRMED') 'registry records CONFIRMED'
    Check (@($claude.createdThisRun) -contains 'shared-demo') 'registry records the created link'

    Write-Host ''
    Write-Host '=== 3. apply again (idempotent) ==='
    $out = Invoke-LinkScript @('-Apply')
    Write-Host $out
    Check-Text $out 'links created=0' 'creates nothing on the second run'
    Check-Text $out 'skipped   : private-skill (already present), shared-demo (already linked)' 'distinguishes a collision from an existing link'
    $reg = Get-Content -LiteralPath $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check (@($claude.createdThisRun).Count -eq 0) 'registry records nothing created this run'

    Write-Host ''
    Write-Host '=== 4. forced junction failure ==='
    # one pool skill that cannot be created, sorted last so the skips still report
    $failSkill = Join-Path $root 'shared\skills\zz-fail'
    New-Item -ItemType Directory -Path $failSkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $failSkill 'SKILL.md') -Value '# zz-fail'
    Set-CreateDirectoriesDeny $claudeSkills
    $denyPath = $claudeSkills
    Write-Host "denied CreateDirectories for $me on $claudeSkills"
    $out = Invoke-LinkScript @('-Apply') -ExpectError
    Write-Host $out
    Check-Text $out 'LINK FAILED' 'reports the failed link'
    Check-Text $out 'failed    : zz-fail' 'names the skill that failed'
    Check ($out -match '(?m)^\s+reason\s+: \S') 'prints a non-empty failure reason'
    Check-Text $out 'skipped   : private-skill (already present), shared-demo (already linked)' 'still reports the skills it skipped'
    Check-Text $out 'LINK FAILED: claude' 'lists the failed agent'
    Check-Text $out 'failed=1' 'summary counts the failure'
    Check (-not (Test-Path -LiteralPath (Join-Path $claudeSkills 'zz-fail'))) 'no junction left for the failed skill'
    $reg = Get-Content -LiteralPath $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'LINK FAILED') 'registry records LINK FAILED'
    Check (@($claude.linked) -contains 'shared-demo') 'registry keeps the link that already existed'
    Check (@($claude.createdThisRun).Count -eq 0) 'registry records nothing created this run'

    Write-Host ''
    Write-Host '=== 5. partial failure across agents ==='
    # A failure on codex must not erase the links or counts from claude.
    $codexHome = Join-Path $root 'agents\codex'
    $codexSkills = Join-Path $codexHome 'skills'
    New-Item -ItemType Directory -Path $codexSkills -Force | Out-Null
    New-FixtureJunction (Join-Path $profileDir '.codex') $codexHome
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.entries = @($manifest.entries) + [pscustomobject]@{
        id = 'codex'; source = (Join-Path $profileDir '.codex'); destination = $codexHome; state = 'BackupVerified'
    }
    Save-Manifest $manifest
    Set-CreateDirectoriesDeny $denyPath -Remove
    $denyPath = $codexSkills
    Set-CreateDirectoriesDeny $denyPath
    $out = Invoke-LinkScript @('-Apply') -ExpectError
    Write-Host $out
    Check-Text $out 'CONFIRMED (+1 linked)' 'reports the link created for the earlier agent'
    Check-Text $out 'links created=1' 'counts the earlier link'
    Check-Text $out 'failed=1' 'counts the failure'
    Check ((Test-Path -LiteralPath (Join-Path $claudeSkills 'zz-fail\SKILL.md'))) 'earlier link survives the later failure'
    Check (@(Get-ChildItem -LiteralPath $codexSkills).Count -eq 0) 'denied agent has no link'
    $reg = Get-Content -LiteralPath $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $codex = $reg.agents | Where-Object { $_.id -eq 'codex' }
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'CONFIRMED') 'registry keeps the earlier agent confirmed'
    Check (@($claude.createdThisRun) -contains 'zz-fail') 'registry records the earlier link'
    Check ($codex.status -eq 'LINK FAILED') 'registry records the failure'
    Check (@($codex.createdThisRun).Count -eq 0) 'registry credits nothing to the failed agent'

    Write-Host ''
    Write-Host '=== 6. partial failure in one agent ==='
    Set-CreateDirectoriesDeny $denyPath -Remove
    $denyPath = ''
    # Drop only the fixture junction so this run recreates it.
    [IO.Directory]::Delete((Join-Path $claudeSkills 'shared-demo'))

    # A trailing dot survives only through a \\?\ path. Do not let Win32 silently
    # normalize it to another skill name. Skills sorting before it still link.
    [IO.Directory]::CreateDirectory('\\?\' + $dotSkillPhysical) | Out-Null
    $out = Invoke-LinkScript -Extra @('-Apply', '-Agent', 'claude') -ExpectError
    Write-Host $out
    Check-Text $out 'LINK FAILED (+1 linked)' 'labels the partial failure with its linked count'
    Check-Text $out 'linked    : shared-demo' 'names the link created before the failure'
    Check-Text $out 'failed    : zz-dot.' 'names the skill that failed'
    Check ((Test-Path -LiteralPath (Join-Path $claudeSkills 'shared-demo\SKILL.md'))) 'created link survives the failure'
    $reg = Get-Content -LiteralPath $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $claude = $reg.agents | Where-Object { $_.id -eq 'claude' }
    Check ($claude.status -eq 'LINK FAILED') 'registry records LINK FAILED with the link'
    Check (@($claude.createdThisRun) -contains 'shared-demo') 'registry credits the created link'
    Check (@($claude.linked) -contains 'zz-fail') 'registry also counts a preexisting link sorted after the failure'
    Check ($claude.failedSkill -ceq 'zz-dot.' -and $claude.reason) 'registry records the failure and its cause'
    [IO.Directory]::Delete('\\?\' + $dotSkillPhysical)
    $dotSkillPhysical = ''

    Write-Host '=== 7. empty selections and inspection-only homes ==='
    $before = [IO.File]::ReadAllText($linksPath)
    $out = Invoke-LinkScript @('-Apply','-Agent','opencode')
    Check-Text $out 'Nothing was changed' 'uninstalled selection is an explicit no-op'
    Save-Manifest ([pscustomobject]@{ schema=1; root=$root; entries=@() })
    $out = Invoke-LinkScript @('-Apply')
    Check-Text $out 'Nothing was changed' 'empty manifest is a no-op'
    $openLegacy = Join-Path $profileDir 'AppData\Roaming\opencode'
    [IO.Directory]::CreateDirectory("$openLegacy\skill") | Out-Null
    $homes = "$openLegacy;$profileDir\.claude"
    $out = Invoke-LinkScript @('-Agent','opencode','-IncludeHome',$homes)
    Check-Text $out 'inspection only' 'IncludeHome works without a matching manifest entry'
    Check-Text $out 'summary: confirmed=1 failed=0 unconfirmed=0 blocked=0 links planned=0' 'IncludeHome never plans links or includes unselected homes'
    $out = Invoke-LinkScript @('-Apply','-IncludeHome',$homes) -ExpectError
    Check-Text $out '-IncludeHome is report-only' 'refuses mixed dry-run and apply'
    Check ([IO.File]::ReadAllText($linksPath) -ceq $before) 'empty/inspection-only selections preserved the report'
    Save-Manifest $manifest

    Write-Host '=== 8. unsafe or ambiguous layouts ==='
    $outside = Join-Path $runRoot 'not an agent'
    [IO.Directory]::CreateDirectory("$outside\skills") | Out-Null
    New-FixtureJunction "$cursorHome\skills" "$outside\skills"
    New-FixtureJunction "$cursorHome\redirect" $outside
    $out = Invoke-LinkScript @('-Apply','-Agent','cursor')
    Check-Text $out 'UNCONFIRMED: cursor' 'refuses a reparse-point skills directory'
    Check (@(Get-ChildItem -LiteralPath "$outside\skills" -Force).Count -eq 0) 'no links created through rejected candidate'
    [IO.Directory]::Delete("$cursorHome\skills")
    [IO.Directory]::CreateDirectory("$cursorHome\User\skills") | Out-Null
    [IO.Directory]::CreateDirectory("$cursorHome\other\skill") | Out-Null
    [IO.Directory]::CreateDirectory("$cursorHome\extensions\skills") | Out-Null
    $out = Invoke-LinkScript @('-Apply','-Agent','cursor')
    Check-Text $out 'ambiguous:' 'does not guess between independent plausible directories'
    Check (@(Get-ChildItem -LiteralPath "$cursorHome\User\skills").Count -eq 0) 'ambiguous candidates left untouched'
    [IO.Directory]::Delete("$cursorHome\other\skill")
    & icacls "$cursorHome\other" /deny "$($me):(RD)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not install scratch read-deny ACL.' }
    try {
        $out = Invoke-LinkScript @('-Apply','-Agent','cursor')
        Check-Text $out 'UNCONFIRMED: cursor' 'one visible candidate plus an unreadable branch is not confirmed'
        Check (@(Get-ChildItem -LiteralPath "$cursorHome\User\skills").Count -eq 0) 'incomplete discovery planned no writes'
    } finally { & icacls "$cursorHome\other" /remove:d $me | Out-Null }

    $gemini = $manifest.entries | Where-Object { $_.id -eq 'gemini' }
    [IO.Directory]::CreateDirectory("$($gemini.destination)\skills") | Out-Null
    New-FixtureJunction $gemini.source $gemini.destination
    $out = Invoke-LinkScript @('-Apply','-Agent','gemini')
    Check-Text $out 'BLOCKED: gemini' 'matching legacy junction alone does not activate an entry'
    $gemini.state = 'Activated'
    $openHome = Join-Path $root 'agents\opencode'
    $openEntry = [pscustomobject]@{ id='opencode'; source=$openLegacy; destination=$outside; state='Activated' }
    [IO.Directory]::Delete($openLegacy, $true) # our plain IncludeHome fixture
    New-FixtureJunction $openLegacy $outside
    $manifest.entries += $openEntry
    Save-Manifest $manifest
    $out = Invoke-LinkScript @('-Apply','-Agent','opencode')
    Check-Text $out 'BLOCKED: opencode' 'matching junction to a noncanonical destination is not authorization'
    Check (@(Get-ChildItem -LiteralPath "$outside\skills" -Force).Count -eq 0) 'foreign destination not modified'
    $openEntry.destination = $openHome
    [IO.Directory]::CreateDirectory("$openHome\config\skill") | Out-Null
    Save-Manifest $manifest
    $out = Invoke-LinkScript @('-Apply','-Agent','opencode')
    Check-Text $out 'legacy junction points elsewhere' 'redirected legacy path is blocked'
    [IO.Directory]::Delete($openLegacy)
    New-FixtureJunction $openLegacy $openHome

    Write-Host '=== 9. empty pool and literal skill links for every supported agent ==='
    $pool = Join-Path $root 'shared\skills'
    [IO.Directory]::Move($pool, "$pool.held")
    [IO.Directory]::CreateDirectory($pool) | Out-Null
    $out = Invoke-LinkScript @('-Apply')
    Check-Text $out 'summary: confirmed=5 failed=0 unconfirmed=0 blocked=0 links created=0' 'all supported homes handle an empty pool'
    $literal = 'team [x] ' + [char]0x96EA + ' `tool'
    $decoy = $literal.Replace('[x]', 'x')
    foreach ($name in @($literal, $decoy, 'skills', '.internal')) { [IO.Directory]::CreateDirectory("$pool\$name") | Out-Null }
    New-FixtureJunction "$pool\redirected" $outside
    $privateFile = Join-Path $codexSkills $decoy
    [IO.File]::WriteAllText($privateFile, 'keep my file')
    $dangling = Join-Path "$cursorHome\User\skills" $decoy
    $gone = Join-Path $outside 'removed target'
    [IO.Directory]::CreateDirectory($gone) | Out-Null
    New-FixtureJunction $dangling $gone
    [IO.Directory]::Delete($gone)
    # Private examples inside an installation directory are not second candidates.
    [IO.Directory]::CreateDirectory("$claudeSkills\private-skill\skills") | Out-Null
    $out = Invoke-LinkScript @('-Apply')
    $reg = Get-Content -LiteralPath $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Check (($reg.agents.id -join ',') -eq 'claude,codex,cursor,gemini,opencode') 'registry covers exactly the five supported homes'
    foreach ($a in $reg.agents) {
        $actual = Get-Item -LiteralPath (Join-Path $a.skillsDir $literal)
        Check ($actual.LinkType -eq 'Junction' -and $actual.Target[0] -ceq "$pool\$literal") "$($a.id): exact literal target, not the wildcard decoy"
        $created = if ($a.id -in @('codex','cursor')) { 2 } else { 3 }
        Check ($a.status -eq 'CONFIRMED' -and @($a.createdThisRun).Count -eq $created -and $a.linked -contains $literal) "$($a.id): registry records the literal names"
        Check (-not (Test-Path -LiteralPath "$($a.skillsDir)\redirected") -and -not (Test-Path -LiteralPath "$($a.skillsDir)\.internal")) "$($a.id): skipped redirected and internal pool entries"
    }
    $out = Invoke-LinkScript @('-Apply')
    Check-Text $out 'summary: confirmed=5 failed=0 unconfirmed=0 blocked=0 links created=0' 'skill named skills and literal names remain idempotent'
    Check ([IO.File]::ReadAllText($privateFile) -ceq 'keep my file') 'a colliding file is never replaced'
    Check ((Get-Item -LiteralPath $dangling).Target[0] -ceq $gone) 'a dangling junction is never replaced'
    Check ((Get-Content -LiteralPath "$claudeSkills\private-skill\SKILL.md" -Raw).Trim() -ceq '# private') 'private contents survived every apply'

    $custom = [pscustomobject]@{ id='custom_agent'; source="$profileDir\.extra"; destination="$root\agents\custom_agent"; state='Activated' }
    [IO.Directory]::CreateDirectory("$($custom.destination)\skills") | Out-Null
    New-FixtureJunction $custom.source $custom.destination
    $manifest.entries += $custom
    Save-Manifest $manifest
    $out = Invoke-LinkScript @('-Apply','-Agent','custom_agent')
    $reg = Get-Content -LiteralPath $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($reg.agents.Count -eq 1 -and $reg.agents[0].id -eq $custom.id -and $reg.agents[0].linked -contains $literal) 'custom selector links only the configured agent'
}
finally {
    if ($denyPath) {
        try { Set-CreateDirectoriesDeny $denyPath -Remove } catch { Write-Host "WARNING: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    # A trailing-dot name cannot be removed through a Win32 path; drop it explicitly.
    if ($dotSkillPhysical) {
        try { [IO.Directory]::Delete('\\?\' + $dotSkillPhysical) }
        catch [System.IO.DirectoryNotFoundException] { }
        catch { Write-Host "WARNING: could not remove $dotSkillPhysical : $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    foreach ($letter in $script:scratchLetters) {
        $owner = "${letter}:\.volume-owner"
        if ((Test-Path -LiteralPath $owner) -and (Get-Content -LiteralPath $owner -Raw).Trim() -eq $runId) {
            & subst.exe "${letter}:" /D | Out-Null
        } else { Write-Warning "Not unmapping ${letter}:; ownership token missing or changed." }
    }

    $removable = $false
    if (Test-Path -LiteralPath $sentinelPath) {
        $token = (Get-Content -LiteralPath $sentinelPath -Raw).Trim()
        $insideTemp = ([IO.Path]::GetFullPath($runRoot)).StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)
        $removable = ($token -eq $runId) -and $insideTemp -and ((Split-Path $runRoot -Leaf) -like 'adm-link-harness-*')
    }
    if ($removable) { Remove-FixtureTree ([IO.DirectoryInfo]$runRoot) }
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
