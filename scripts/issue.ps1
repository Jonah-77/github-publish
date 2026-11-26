# issue.ps1 - open an issue on any GitHub repository (own or third-party) after a
# desensitisation gate. Read-only until the gate passes; -DryRun creates nothing.
# ASCII only on purpose: runs under Windows PowerShell 5.1 and pwsh 7.x without BOM issues.
#
# Usage:
#   & '<skill dir>\scripts\issue.ps1' -Repo 'owner/name' -TitleFile '<file>' -BodyFile '<file>' -DryRun
#   & '<skill dir>\scripts\issue.ps1' -Repo 'owner/name' -TitleFile '<file>' -BodyFile '<file>' -DenyList 'company','client'
#
# Output is the shared four-line contract: STATUS / CLASS=issue / URL / NOTE.
# Nothing is published unless the gate is clean (or -Force after an explicit decision).

param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$TitleFile,
    [Parameter(Mandatory = $true)][string]$BodyFile,
    [string]$Labels = '',
    [string[]]$DenyList = @(),
    [switch]$DryRun,
    [switch]$Force,
    [string]$Gh = 'C:\Program Files\GitHub CLI\gh.exe'
)

$ErrorActionPreference = 'Stop'

function Emit([string]$status, [string]$url, [string]$note, [int]$code) {
    Write-Output "STATUS=$status"
    Write-Output 'CLASS=issue'
    Write-Output "URL=$url"
    Write-Output "NOTE=$note"
    exit $code
}

function Blocked([string]$note) { Emit 'blocked' '-' $note 2 }

function Bail([string]$note) { Emit 'failed' '-' $note 1 }

if (-not (Test-Path -LiteralPath $TitleFile)) { Blocked 'title file not found' }
if (-not (Test-Path -LiteralPath $BodyFile)) { Blocked 'body file not found' }

$title = (Get-Content -LiteralPath $TitleFile -Raw -Encoding UTF8).Trim()
$body = (Get-Content -LiteralPath $BodyFile -Raw -Encoding UTF8).Trim()

if ([string]::IsNullOrWhiteSpace($title)) { Blocked 'title is empty' }
if ([string]::IsNullOrWhiteSpace($body)) { Blocked 'body is empty' }
if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') { Blocked "repo must look like owner/name: $Repo" }

# --- desensitisation gate -------------------------------------------------
# Anything published to a repository we do not own must be the smallest public
# subset of the facts. These rules catch what a script can catch; -DenyList is
# the human-supplied part (company, client, project, colleague names).
$rules = @(
    @{ Name = 'windows-abs-path'; Pattern = '[A-Za-z]:\\' },
    @{ Name = 'windows-user-path'; Pattern = 'Users\\' },
    @{ Name = 'unc-path'; Pattern = '\\\\[^\\\s]+\\' },
    @{ Name = 'github-token'; Pattern = 'gh[pous]_[A-Za-z0-9]{10,}' },
    @{ Name = 'github-pat'; Pattern = 'github_pat_[A-Za-z0-9_]{10,}' },
    @{ Name = 'email'; Pattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' },
    @{ Name = 'cn-mobile'; Pattern = '(?<![0-9])1[3-9][0-9]{9}(?![0-9])' },
    @{ Name = 'private-key'; Pattern = 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' }
)

$localNames = @($env:USERNAME, $env:COMPUTERNAME) | Where-Object { $_ -and $_.Length -gt 2 }
foreach ($name in $localNames) {
    $rules += @{ Name = 'local-identity'; Pattern = [Regex]::Escape($name) }
}
foreach ($word in $DenyList) {
    if ([string]::IsNullOrWhiteSpace($word)) { continue }
    $rules += @{ Name = ('denylist:' + $word); Pattern = [Regex]::Escape($word) }
}

$hits = New-Object System.Collections.Generic.List[string]

function Scan([string]$text, [string]$where) {
    $lines = $text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($rule in $rules) {
            if ([Regex]::IsMatch($lines[$i], $rule.Pattern, 'IgnoreCase')) {
                $hits.Add(('{0}:{1} ({2}) {3}' -f $where, ($i + 1), $rule.Name, $lines[$i].Trim()))
            }
        }
    }
}

Scan $title 'title'
Scan $body 'body'

if ($hits.Count -gt 0) {
    Write-Output 'DESENSITISATION HITS:'
    $hits | ForEach-Object { Write-Output ('  ' + $_) }
    if (-not $Force) {
        Blocked "$($hits.Count) sensitive pattern(s) found; rewrite the text (or pass -Force after an explicit decision)"
    }
    Write-Output 'proceeding because -Force was supplied'
}

Write-Output ('PAYLOAD: repo=' + $Repo + ' title=' + $title)
Write-Output ('BODY LENGTH: ' + $body.Length)

if ($DryRun) { Emit 'dry-run' '-' $title 0 }

if (-not (Test-Path -LiteralPath $Gh)) { Bail "gh not found: $Gh" }

$tmp = Join-Path $env:TEMP ('issue-body-' + [Guid]::NewGuid().ToString('N') + '.md')
[IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($false)))

$ghArgs = @('issue', 'create', '--repo', $Repo, '--title', $title, '--body-file', $tmp)
if ($Labels) {
    foreach ($label in ($Labels -split ',')) {
        if ($label.Trim()) { $ghArgs += @('--label', $label.Trim()) }
    }
}

$output = $null
$code = 1
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $output = & $Gh @ghArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) { break }
    if ($attempt -lt 2) { Start-Sleep -Seconds 3 }
}
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

if ($code -ne 0) {
    # `gh issue create` goes through GraphQL, which is unreliable on some networks.
    # Fall back to REST, but look for a duplicate first: a request that dies while
    # reading the response can still have created the issue.
    try {
        $token = (& $Gh auth token 2>$null)
        if ($token) { $token = ($token -join '').Trim() }
        if (-not $token) { throw 'gh auth token returned nothing' }

        $headers = @{
            Authorization = 'token ' + $token
            'User-Agent'  = 'github-publish-issue'
            Accept        = 'application/vnd.github+json'
        }

        $listUri = 'https://api.github.com/repos/' + $Repo + '/issues?state=all&per_page=20&sort=created&direction=desc'
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -TimeoutSec 60 |
                    Where-Object { $_.title -eq $title } | Select-Object -First 1
        if ($existing) {
            Emit 'ok' $existing.html_url 'existing issue found, nothing new created' 0
        }

        $payload = [ordered]@{ title = $title; body = $body } | ConvertTo-Json -Depth 4
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payload)
        $response = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $Repo + '/issues') -Method Post `
                    -Headers $headers -ContentType 'application/json; charset=utf-8' `
                    -Body $bytes -TimeoutSec 60

        Emit 'ok' $response.html_url ($title + ' (created via REST fallback)') 0
    }
    catch {
        Bail $_.Exception.Message
    }
}

$url = (($output | Select-Object -Last 1).ToString()).Trim()
Emit 'ok' $url $title 0
