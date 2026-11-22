# publish.ps1 - the incremental-sync path (intent=sync) from the github-publish skill.
# Fixed order, do not reorder:
#   identity gate -> desensitize gate -> trace gate -> fetch/compare -> add -> commit -> push -> verify
# It never creates a repo, never touches Pages/topics/releases, never force-pushes.
# ASCII only on purpose: runs under Windows PowerShell 5.1 and pwsh 7.x without BOM issues.
#
# Usage:
#   & '<skill dir>\scripts\publish.ps1' -Repo 'C:\path\to\repo' -Message "Fix the title bar colour"
#   & '<skill dir>\scripts\publish.ps1' -Repo 'C:\path\to\repo' -MessageFile 'C:\tmp\msg.txt'
#   & '<skill dir>\scripts\publish.ps1' -Repo 'C:\path\to\repo' -AllowFetchSync
#   & '<skill dir>\scripts\publish.ps1' -Repo 'C:\path\to\repo' -DryRun      # gates + compare only
#   & '<skill dir>\scripts\publish.ps1' -Repo 'C:\path\to\repo' -Message "..." -WaitCi
#
# Exit codes: 0 ok / nothing-to-push, 2 blocked (needs a human), 1 failed (command error).

param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Message,
    [string]$MessageFile,
    [switch]$SkipGates,
    [switch]$AllowFetchSync,
    [switch]$NoFetch,
    [switch]$DryRun,
    [switch]$WaitCi,
    [int]$CiTimeoutSec = 120,
    [string]$Remote = 'origin',
    [string]$Branch = '',
    [string]$Git = 'C:\Program Files\Git\cmd\git.exe',
    [string]$Gh = 'C:\Program Files\GitHub CLI\gh.exe'
)

function Finish([string]$status, [string]$sha, [string]$remoteState, [string]$note, [int]$code) {
    Write-Output "STATUS=$status"
    Write-Output "CLASS=sync"
    Write-Output "SHA=$sha"
    Write-Output "REMOTE=$remoteState"
    Write-Output "NOTE=$note"
    exit $code
}

function Fail([string]$note) { Finish 'failed' '-' 'n/a' $note 1 }
function Block([string]$note, [string]$sha, [string]$remoteState) { Finish 'blocked' $sha $remoteState $note 2 }

if (-not (Test-Path -LiteralPath $Repo)) { Fail "repo path not found: $Repo" }
Push-Location -LiteralPath $Repo
try {
    $null = & $Git rev-parse --git-dir 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "not a git repository: $Repo" }

    if (-not $Branch) { $Branch = ((& $Git rev-parse --abbrev-ref HEAD) -join '').Trim() }
    $null = & $Git rev-parse --verify --quiet HEAD 2>&1
    if ($LASTEXITCODE -eq 0) { $sha = ((& $Git rev-parse --short HEAD) -join '').Trim() } else { $sha = '-' }

    # --- concurrency / half-finished state ---
    $gitDir = ((& $Git rev-parse --git-dir) -join '').Trim()
    foreach ($marker in @('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'index.lock')) {
        if (Test-Path -LiteralPath (Join-Path $gitDir $marker)) {
            Block "git operation in progress ($marker); finish or abort it first" $sha 'n/a'
        }
    }

    # --- gate 1: identity ---
    $userName = ((& $Git config --local user.name) -join '').Trim()
    $userMail = ((& $Git config --local user.email) -join '').Trim()
    if (-not $userName -or -not $userMail) {
        Block 'repo-local user.name/user.email is empty; set them before committing' $sha 'n/a'
    }

    # --- gates 2 and 3: desensitize + trace scan, before anything is staged ---
    if (-not $SkipGates) {
        # tracked files plus untracked-but-not-ignored files: a secret usually arrives in a NEW file,
        # which `git ls-files` alone would miss because nothing has been staged yet.
        $tracked = (& $Git ls-files --cached --others --exclude-standard)
        $binary = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.bmp', '.pdf', '.zip', '.dll', '.exe', '.pdb', '.woff', '.woff2', '.ttf', '.mp4', '.wav')
        $patterns = @(
            @{ name = 'local-user-path'; re = 'C:\\Users\\' },
            @{ name = 'token-ghp'; re = 'ghp_[A-Za-z0-9]{20,}' },
            @{ name = 'token-pat'; re = 'github_pat_[A-Za-z0-9_]{20,}' },
            @{ name = 'private-key'; re = 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY' },
            @{ name = 'real-email'; re = '@(qq|163|126|gmail|outlook)\.com' },
            @{ name = 'phone'; re = '1[3-9][0-9]{9}' }
        )
        $hits = New-Object System.Collections.ArrayList
        foreach ($f in $tracked) {
            $ext = [System.IO.Path]::GetExtension($f).ToLower()
            if ($binary -contains $ext) { continue }
            if ($f -match '(?i)^\.env') { [void]$hits.Add("dotenv-file: $f"); continue }
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $f).Path, [System.Text.Encoding]::UTF8)
            foreach ($p in $patterns) {
                if ($text -match $p.re) { [void]$hits.Add("$($p.name): $f") }
            }
        }
        if ($hits.Count -gt 0) {
            Write-Output '--- desensitize gate ---'
            foreach ($h in $hits) { Write-Output "  $h" }
            Block "desensitize gate hit $($hits.Count) item(s); fix them, or rerun with -SkipGates after a human review" $sha 'n/a'
        }

        $scanner = Join-Path $PSScriptRoot 'scan-traces.ps1'
        if (Test-Path -LiteralPath $scanner) {
            $scan = (& $scanner -Repo $Repo 2>&1) -join "`n"
            if ($scan -notmatch 'clean: no candidate traces found') {
                Write-Output '--- trace gate (candidates only, judge each one) ---'
                Write-Output $scan
                Block 'trace scan found candidates; judge them by hand (the scanner never edits)' $sha 'n/a'
            }
        }
    }

    # --- gate 4: fetch and compare with the remote ---
    $remoteState = 'n/a'
    $ahead = 0
    $behind = 0
    if (-not $NoFetch) {
        $null = & $Git fetch $Remote $Branch 2>&1
        $ref = "$Remote/$Branch"
        $null = & $Git rev-parse --verify --quiet $ref 2>&1
        if ($LASTEXITCODE -eq 0) {
            $counts = ((& $Git rev-list --left-right --count "HEAD...$ref") -join '').Trim()
            $parts = $counts -split '\s+'
            if ($parts.Count -ge 2) { $ahead = [int]$parts[0]; $behind = [int]$parts[1] }
            if ($behind -gt 0 -and $ahead -gt 0) { $remoteState = 'diverged' }
            elseif ($behind -gt 0) { $remoteState = 'behind' }
            elseif ($ahead -gt 0) { $remoteState = 'ahead' }
            else { $remoteState = 'in-sync' }

            if ($remoteState -eq 'behind') {
                if ($AllowFetchSync) {
                    $null = & $Git merge --ff-only $ref 2>&1
                    if ($LASTEXITCODE -ne 0) { Block 'fast-forward failed; sync by hand (section B.2 of SKILL.md)' $sha 'behind' }
                    $sha = ((& $Git rev-parse --short HEAD) -join '').Trim()
                    $remoteState = 'in-sync'
                    $behind = 0
                }
                else {
                    Block "remote is $behind commit(s) ahead; rerun with -AllowFetchSync or sync by hand" $sha 'behind'
                }
            }
            if ($remoteState -eq 'diverged') {
                Block "diverged: local $ahead / remote $behind; a human must choose the merge before any push" $sha 'diverged'
            }
        }
    }

    # --- stage and commit ---
    $pending = (& $Git status --porcelain) -join ''
    $hasPending = -not [string]::IsNullOrWhiteSpace($pending)

    if ($DryRun) {
        Write-Output '--- dry run ---'
        if ($hasPending) { Write-Output $pending } else { Write-Output '  (no local change)' }
        $note = 'dry run: nothing would be committed'
        if ($hasPending) { $note = 'dry run: local changes detected, no commit and no push performed' }
        if (-not $hasPending -and $remoteState -eq 'in-sync') { $note = 'dry run: already in sync' }
        Finish 'ok' $sha $remoteState $note 0
    }

    $null = & $Git add -A
    if ($LASTEXITCODE -ne 0) { Fail 'git add failed' }

    $staged = (& $Git diff --cached --name-only) -join ''
    $hasStaged = -not [string]::IsNullOrWhiteSpace($staged)

    if ($hasStaged) {
        if ($MessageFile) {
            if (-not (Test-Path -LiteralPath $MessageFile)) { Fail "message file not found: $MessageFile" }
            $null = & $Git commit -q -F $MessageFile
        }
        elseif ($Message) {
            $null = & $Git commit -q -m $Message
        }
        else {
            Block 'changes are staged but no -Message / -MessageFile was given; refusing to invent a commit message' $sha $remoteState
        }
        if ($LASTEXITCODE -ne 0) { Fail 'git commit failed' }
        $sha = ((& $Git rev-parse --short HEAD) -join '').Trim()
    }

    if (-not $hasStaged -and $remoteState -eq 'in-sync') {
        Finish 'nothing-to-push' $sha 'in-sync' 'working tree clean and remote already matches HEAD' 0
    }

    # --- push, one retry on this host's flaky network ---
    $attempt = 0
    $pushed = $false
    while ($attempt -lt 2) {
        $attempt++
        & $Git push $Remote $Branch 2>&1 | ForEach-Object { Write-Output $_ }
        if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
        if ($attempt -lt 2) {
            Write-Output 'push failed, retrying once (network reset is common on this host)'
            Start-Sleep -Seconds 3
        }
    }
    if (-not $pushed) { Fail 'git push failed after 2 attempts' }

    # --- verify: never trust "the command did not error" ---
    $localFull = ((& $Git rev-parse HEAD) -join '').Trim()
    $remoteLine = ((& $Git ls-remote --heads $Remote $Branch) -join '').Trim()
    $remoteFull = ''
    if ($remoteLine -match '^([0-9a-f]{40})') { $remoteFull = $matches[1] }
    if ($remoteFull -ne $localFull) {
        Fail "push reported success but remote head ($remoteFull) != local head ($localFull)"
    }

    $note = 'pushed and verified against ls-remote'

    # --- optional: wait for the CI conclusion of the pushed commit ---
    if ($WaitCi) {
        $url = ((& $Git remote get-url $Remote) -join '').Trim()
        $slug = ''
        if ($url -match 'github\.com[:/]+([^/]+)/([^/.]+)') { $slug = "$($matches[1])/$($matches[2])" }
        if (-not $slug) {
            $note = "$note; CI=unknown (no github.com remote)"
        }
        else {
            $deadline = (Get-Date).AddSeconds($CiTimeoutSec)
            $ci = 'pending'
            while ((Get-Date) -lt $deadline) {
                $raw = (& $Gh run list --repo $slug --limit 3 --json headSha,status,conclusion 2>&1) -join ''
                # only trust a run whose headSha is the commit we just pushed: right after a push
                # the newest run may still be the previous one.
                $hasOwn = $false
                if ($raw -match "`"headSha`":`"$localFull`"") { $hasOwn = $true }
                if ($hasOwn -and $raw -match '"conclusion":"([^"]+)"') { $ci = $matches[1]; break }
                Start-Sleep -Seconds 10
            }
            if ($ci -eq 'pending') { $ci = 'pending (timeout waiting for a run of this commit)' }
            $note = "$note; CI=$ci"
        }
    }

    Finish 'ok' $sha 'in-sync' $note 0
}
finally {
    Pop-Location
}
