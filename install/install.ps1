# install.ps1 -- install the Windows side of this skill only.
#
# It copies the shared docs plus the .ps1 scripts. The bash ports are never touched
# or copied: a Windows box without bash has no use for them.
#
# Usage:
#   .\install\install.ps1                        # target defaults to $env:DSH_HOME\skills\github-publish
#                                                # when DSH_HOME is set, else ~\.agent-skills\github-publish
#   .\install\install.ps1 -Target "$HOME\skills\github-publish"
#   .\install\install.ps1 -DryRun
#   .\install\install.ps1 -Force
#   .\install\install.ps1 -Uninstall

param(
    [string]$Target = '',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Src = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# Default target: if a client exports DSH_HOME, that is where it scans for skills;
# otherwise use a neutral per-user path. -Target always wins.
if (-not $Target) {
    if ($env:DSH_HOME) { $Target = Join-Path $env:DSH_HOME 'skills\github-publish' }
    else { $Target = Join-Path $HOME '.agent-skills\github-publish' }
}

# shared + this platform only. No .sh here on purpose.
# The installer copies itself too, so the printed uninstall command actually exists.
$Files = @(
    'SKILL.md',
    'README.md',
    'LICENSE',
    'platforms.json',
    'install\install.ps1',
    'scripts\check.ps1',
    'scripts\publish.ps1',
    'scripts\scan-traces.ps1',
    'scripts\issue.ps1'
)
$Dirs = @('install', 'scripts')

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $Target)) { 'nothing to remove: target does not exist'; exit 0 }
    $marker = Join-Path $Target '.platform'
    if (-not (Test-Path -LiteralPath $marker)) { "refusing: $Target has no platform marker"; exit 1 }
    $text = Get-Content -LiteralPath $marker -Raw
    if ($text -notmatch 'github-publish windows') { "refusing: $Target is not a windows install"; exit 1 }
    if ($DryRun) { "[dry-run] would remove $Target"; exit 0 }
    Remove-Item -LiteralPath $Target -Recurse -Force
    'removed skill copy'
    'gh login state and installed tools are untouched; revoke them yourself if you want them gone'
    exit 0
}

if ((Test-Path -LiteralPath $Target) -and (-not $Force)) {
    "target exists: $Target"
    'rerun with -Force to replace it, or -Uninstall to remove it first'
    exit 1
}

"source  : $Src"
"target  : $Target"
'platform: windows (PowerShell) -- bash ports are skipped'
''

foreach ($f in $Files) {
    if (-not (Test-Path -LiteralPath (Join-Path $Src $f))) { "missing in source: $f"; exit 1 }
    "  $f"
}

if ($DryRun) { ''; '[dry-run] nothing copied'; exit 0 }

New-Item -ItemType Directory -Path $Target -Force | Out-Null
foreach ($d in $Dirs) { New-Item -ItemType Directory -Path (Join-Path $Target $d) -Force | Out-Null }
foreach ($f in $Files) {
    Copy-Item -LiteralPath (Join-Path $Src $f) -Destination (Join-Path $Target $f) -Force
}
Set-Content -LiteralPath (Join-Path $Target '.platform') -Value 'github-publish windows' -Encoding utf8NoBOM

''
'--- next ---'
"  1. $Target\scripts\check.ps1 -Repo '<repo>'      # read-only state check"
"  2. $Target\scripts\publish.ps1 -Repo '<repo>' -Message '<what changed and why>'"
'  3. if gh is missing: winget install --id GitHub.cli -e   then: gh auth login'
''
'uninstall:'
"  $Target\install\install.ps1 -Uninstall   (or: Remove-Item -Recurse -Force $Target)"
