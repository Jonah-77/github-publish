# check.ps1 - read-only GitHub state check. Never stages, commits, pushes or changes the repo.
# ASCII only on purpose: runs under Windows PowerShell 5.1 and pwsh 7.x without BOM issues.
#
# Usage:
#   & '<skill dir>\scripts\check.ps1' -Repo 'C:\path\to\repo'
#   & '<skill dir>\scripts\check.ps1' -Repo 'C:\path\to\repo' -Branch 'dev'

param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Remote = 'origin',
    [string]$Branch = '',
    [string]$Git = 'C:\Program Files\Git\cmd\git.exe',
    [string]$Gh = 'C:\Program Files\GitHub CLI\gh.exe'
)

function Emit([string]$status, [string]$sha, [string]$remoteState, [string]$note) {
    Write-Output "STATUS=$status"
    Write-Output "CLASS=r"
    Write-Output "SHA=$sha"
    Write-Output "REMOTE=$remoteState"
    Write-Output "NOTE=$note"
    exit 0
}

if (-not (Test-Path -LiteralPath $Repo)) {
    Emit 'failed' '-' 'n/a' "repo path not found: $Repo"
}

$null = & $Git -C $Repo rev-parse --git-dir 2>&1
if ($LASTEXITCODE -ne 0) {
    Emit 'failed' '-' 'n/a' "not a git repository: $Repo"
}

if (-not $Branch) { $Branch = ((& $Git -C $Repo rev-parse --abbrev-ref HEAD) -join '').Trim() }
$localFull = ((& $Git -C $Repo rev-parse HEAD) -join '').Trim()
$localShort = ((& $Git -C $Repo rev-parse --short HEAD) -join '').Trim()

# --- auth ---
$a = (& $Gh auth status 2>&1) -join "`n"
$auth = 'missing'
if ($a -match 'Logged in to github\.com account') { $auth = 'logged-in' }

# --- working tree ---
$porcelain = (& $Git -C $Repo status --porcelain)
$dirty = 'no'
if ($porcelain) { $dirty = 'yes' }

# --- remote head (no fetch: ls-remote keeps this read-only) ---
$remoteLine = ((& $Git -C $Repo ls-remote --heads $Remote $Branch) -join '').Trim()
$remoteFull = ''
if ($remoteLine -match '^([0-9a-f]{40})') { $remoteFull = $matches[1] }

$remoteState = 'n/a'
$ahead = '0'
$behind = '0'
if (-not $remoteFull) {
    $remoteState = 'n/a'
}
elseif ($remoteFull -eq $localFull) {
    $remoteState = 'in-sync'
}
else {
    $null = & $Git -C $Repo cat-file -e "$remoteFull^{commit}" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $counts = ((& $Git -C $Repo rev-list --left-right --count "HEAD...$remoteFull") -join '').Trim()
        $parts = $counts -split '\s+'
        if ($parts.Count -ge 2) { $ahead = $parts[0]; $behind = $parts[1] }
        if ([int]$behind -gt 0 -and [int]$ahead -gt 0) { $remoteState = 'diverged' }
        elseif ([int]$behind -gt 0) { $remoteState = 'behind' }
        else { $remoteState = 'ahead' }
    }
    else {
        $remoteState = 'ahead'
    }
}

# --- repo slug from remote url ---
$url = ((& $Git -C $Repo remote get-url $Remote) -join '').Trim()
$slug = ''
if ($url -match 'github\.com[:/]+([^/]+)/([^/.]+)') { $slug = "$($matches[1])/$($matches[2])" }

# --- CI + Pages (best effort, never fatal) ---
$ci = 'n/a'
$pages = 'n/a'
if ($slug) {
    try {
        $run = (& $Gh run list --repo $slug --limit 1 --json status,conclusion,headBranch 2>&1) -join ''
        if ($run -match '"conclusion":"([^"]*)"') { $ci = $matches[1] }
        if ($run -match '"status":"([^"]*)"') { if ($ci -eq '' -or $ci -eq 'null') { $ci = $matches[1] } }
    }
    catch { $ci = 'n/a' }
    try {
        $p = ((& $Gh api "repos/$slug/pages/builds/latest" --jq '.status' 2>&1) -join '').Trim()
        if ($p) { $pages = $p }
    }
    catch { $pages = 'n/a' }
}

# --- detail block ---
Write-Output "---"
Write-Output "repo      : $Repo"
Write-Output "branch    : $Branch"
Write-Output "auth      : $auth"
Write-Output "dirty     : $dirty"
Write-Output "local     : $localShort"
Write-Output "remote    : $(if ($remoteFull) { $remoteFull.Substring(0,7) } else { '-' })"
Write-Output "ahead     : $ahead"
Write-Output "behind    : $behind"
Write-Output "ci-latest : $ci"
Write-Output "pages     : $pages"
if ($dirty -eq 'yes') { Write-Output "---"; Write-Output $porcelain }

$note = 'no action needed'
if ($auth -eq 'missing') { $note = 'gh not logged in; run the device-code flow in SKILL.md section 8' }
elseif ($remoteState -eq 'behind') { $note = "remote is $behind commit(s) ahead; sync before pushing" }
elseif ($remoteState -eq 'diverged') { $note = "local $ahead / remote $behind; needs a human decision before any push" }
elseif ($remoteState -eq 'ahead') { $note = "local has $ahead commit(s) not on remote" }
elseif ($dirty -eq 'yes') { $note = 'working tree has uncommitted changes' }

Emit 'ok' $localShort $remoteState $note
