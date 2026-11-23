#!/usr/bin/env bash
# publish.sh -- the incremental-sync path (intent=sync) from the github-publish skill.
# Fixed order, do not reorder:
#   identity gate -> desensitize gate -> trace gate -> fetch/compare -> add -> commit -> push -> verify
# It never creates a repo, never touches Pages/topics/releases, never force-pushes.
#
# Usage:
#   ./publish.sh --repo /path/to/repo --message "Fix the title bar colour"
#   ./publish.sh --repo /path/to/repo --message-file /tmp/msg.txt
#   ./publish.sh --repo /path/to/repo --allow-fetch-sync
#   ./publish.sh --repo /path/to/repo --dry-run        # gates + compare only, no index change
#   ./publish.sh --repo /path/to/repo --message "..." --wait-ci
#
# Exit codes: 0 ok / nothing-to-push, 2 blocked (needs a human), 1 failed (command error).
# Requires bash 4+. Tool paths: --git / --gh, or GIT_BIN / GH_BIN, or the first one on PATH.

set -u

REPO=''
MESSAGE=''
MESSAGE_FILE=''
SKIP_GATES=0
ALLOW_FETCH_SYNC=0
NO_FETCH=0
DRY_RUN=0
WAIT_CI=0
CI_TIMEOUT=120
REMOTE='origin'
BRANCH=''
GIT_ARG=''
GH_ARG=''
USE_MSG_FILE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)              REPO="${2:-}"; shift 2 ;;
        --message)           MESSAGE="${2:-}"; shift 2 ;;
        --message-file)      MESSAGE_FILE="${2:-}"; USE_MSG_FILE=1; shift 2 ;;
        --skip-gates)        SKIP_GATES=1; shift ;;
        --allow-fetch-sync)  ALLOW_FETCH_SYNC=1; shift ;;
        --no-fetch)          NO_FETCH=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        --wait-ci)           WAIT_CI=1; shift ;;
        --ci-timeout)        CI_TIMEOUT="${2:-120}"; shift 2 ;;
        --remote)            REMOTE="${2:-origin}"; shift 2 ;;
        --branch)            BRANCH="${2:-}"; shift 2 ;;
        --git)               GIT_ARG="${2:-}"; shift 2 ;;
        --gh)                GH_ARG="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

GIT="$GIT_ARG"; [ -n "$GIT" ] || GIT="${GIT_BIN:-}"; [ -n "$GIT" ] || GIT="$(command -v git 2>/dev/null || true)"
GH="$GH_ARG";   [ -n "$GH" ]  || GH="${GH_BIN:-}";   [ -n "$GH" ]  || GH="$(command -v gh 2>/dev/null || true)"

finish() {  # status sha remote-state note code
    echo "STATUS=$1"
    echo "CLASS=sync"
    echo "SHA=$2"
    echo "REMOTE=$3"
    echo "NOTE=$4"
    exit "$5"
}
fail()  { finish 'failed'  '-' 'n/a' "$1" 1; }
block() { finish 'blocked' "$2" "$3" "$1" 2; }

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then fail "repo path not found: ${REPO:-<empty>}"; fi
if [ -z "$GIT" ]; then fail 'git not found; pass --git or set GIT_BIN'; fi
cd "$REPO" || fail "cannot enter repo: $REPO"
"$GIT" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repository: $REPO"

if [ -z "$BRANCH" ]; then
    BRANCH="$("$GIT" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r')"
fi
if "$GIT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    SHA="$("$GIT" rev-parse --short HEAD 2>/dev/null | tr -d '\r')"
else
    SHA='-'
fi

# --- concurrency / half-finished state ---
GIT_DIR="$("$GIT" rev-parse --git-dir 2>/dev/null | tr -d '\r')"
for marker in rebase-merge rebase-apply MERGE_HEAD index.lock; do
    if [ -e "$GIT_DIR/$marker" ]; then
        block "git operation in progress ($marker); finish or abort it first" "$SHA" 'n/a'
    fi
done

# --- gate 1: identity ---
USER_NAME="$("$GIT" config --local user.name 2>/dev/null | tr -d '\r')"
USER_MAIL="$("$GIT" config --local user.email 2>/dev/null | tr -d '\r')"
if [ -z "$USER_NAME" ] || [ -z "$USER_MAIL" ]; then
    block 'repo-local user.name/user.email is empty; set them before committing' "$SHA" 'n/a'
fi
# name must be a GitHub account name, not a real human name (real names usually contain a space).
case "$USER_NAME" in
    *' '*) block "repo-local user.name '$USER_NAME' looks like a real name; use the GitHub account name (no spaces)" "$SHA" 'n/a' ;;
esac
case "$USER_MAIL" in
    *noreply.github.com*) : ;;
    *) block "repo-local user.email '$USER_MAIL' is not a noreply address" "$SHA" 'n/a' ;;
esac

# --- gate 1b: history author gate (before push) ---
# Existing commits keep their original author even after local identity is set. Scan them.
HIST_AUTHORS="$("$GIT" log --all --format='%an <%ae> | %cn <%ce>' 2>/dev/null | sort -u)"
if printf '%s\n' "$HIST_AUTHORS" | grep -E -q '@(qq|163|126|gmail|outlook|hps\.com\.pl|netflix)\.com|@[a-z]+\.[a-z]{2,}>'; then
    echo '--- history author gate ---'
    printf '%s\n' "$HIST_AUTHORS" | sed 's/^/  /'
    block 'history contains a real email in author/committer; rewrite with filter-branch before push' "$SHA" 'n/a'
fi
if printf '%s\n' "$HIST_AUTHORS" | grep -E -q "^[A-Z][a-z]+ [A-Z][a-z]+ <"; then
    echo '--- history author gate ---'
    printf '%s\n' "$HIST_AUTHORS" | sed 's/^/  /'
    block 'history contains a real-looking author name; use the GitHub account name via filter-branch' "$SHA" 'n/a'
fi

# --- gates 2 and 3: desensitize + trace scan, before anything is staged ---
if [ "$SKIP_GATES" -eq 0 ]; then
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t pub)"
    trap 'rm -rf "$TMP"' EXIT
    # tracked files plus untracked-but-not-ignored files: a secret usually arrives in a NEW file,
    # which `git ls-files --cached` alone would miss because nothing has been staged yet.
    "$GIT" ls-files --cached --others --exclude-standard > "$TMP/files" 2>/dev/null

    : > "$TMP/hits"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in *.png|*.jpg|*.jpeg|*.gif|*.ico|*.bmp|*.pdf|*.zip|*.dll|*.exe|*.pdb|*.woff|*.woff2|*.ttf|*.mp4|*.wav) continue ;; esac
        case "$f" in .env*|*"/.env"*) printf 'dotenv-file: %s\n' "$f" >> "$TMP/hits"; continue ;; esac
        [ -f "$f" ] || continue
        # placeholders such as C:\Users\<me>\ or <id>+<account>@... are documentation, not leaks:
        # strip them before matching so the gate only fires on real values.
        if sed -E 's/C:\\Users\\<[^>]*>//g; s/[A-Za-z0-9._%+-]+<[^>]*>@//g; s/<[^>]*>//g' -- "$f" 2>/dev/null \
           | grep -E -q "C:\\\\Users\\\\|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|@(qq|163|126|gmail|outlook)\.com|1[3-9][0-9]{9}"; then
            printf 'sensitive-content: %s\n' "$f" >> "$TMP/hits"
        fi
    done < "$TMP/files"

    if [ -s "$TMP/hits" ]; then
        echo '--- desensitize gate ---'
        while IFS= read -r h; do echo "  $h"; done < "$TMP/hits"
        block "desensitize gate hit $(wc -l < "$TMP/hits" | tr -d ' ') file(s); fix them, or rerun with --skip-gates after a human review" "$SHA" 'n/a'
    fi

    SCANNER="$(dirname "$0")/scan-traces.sh"
    if [ -f "$SCANNER" ]; then
        SCAN="$(bash "$SCANNER" --repo "$REPO" --git "$GIT" 2>&1)"
        case "$SCAN" in
            *'clean: no candidate traces found'*) : ;;
            *)
                echo '--- trace gate (candidates only, judge each one) ---'
                echo "$SCAN"
                block 'trace scan found candidates; judge them by hand (the scanner never edits)' "$SHA" 'n/a'
                ;;
        esac
    fi
fi

# --- gate 4: fetch and compare with the remote ---
REMOTE_STATE='n/a'
AHEAD=0
BEHIND=0
if [ "$NO_FETCH" -eq 0 ]; then
    "$GIT" fetch "$REMOTE" "$BRANCH" >/dev/null 2>&1 || true
    REF="$REMOTE/$BRANCH"
    if "$GIT" rev-parse --verify --quiet "$REF" >/dev/null 2>&1; then
        COUNTS="$("$GIT" rev-list --left-right --count "HEAD...$REF" 2>/dev/null | tr -d '\r')"
        AHEAD="$(printf '%s' "$COUNTS" | awk '{print $1}')"; AHEAD="${AHEAD:-0}"
        BEHIND="$(printf '%s' "$COUNTS" | awk '{print $2}')"; BEHIND="${BEHIND:-0}"
        if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then REMOTE_STATE='diverged'
        elif [ "$BEHIND" -gt 0 ]; then REMOTE_STATE='behind'
        elif [ "$AHEAD" -gt 0 ]; then REMOTE_STATE='ahead'
        else REMOTE_STATE='in-sync'; fi

        if [ "$REMOTE_STATE" = 'behind' ]; then
            if [ "$ALLOW_FETCH_SYNC" -eq 1 ]; then
                "$GIT" merge --ff-only "$REF" >/dev/null 2>&1 \
                    || block 'fast-forward failed; sync by hand (section B.2 of SKILL.md)' "$SHA" 'behind'
                SHA="$("$GIT" rev-parse --short HEAD 2>/dev/null | tr -d '\r')"
                REMOTE_STATE='in-sync'; BEHIND=0
            else
                block "remote is $BEHIND commit(s) ahead; rerun with --allow-fetch-sync or sync by hand" "$SHA" 'behind'
            fi
        fi
        if [ "$REMOTE_STATE" = 'diverged' ]; then
            block "diverged: local $AHEAD / remote $BEHIND; a human must choose the merge before any push" "$SHA" 'diverged'
        fi
    fi
fi

# --- stage and commit ---
PENDING="$("$GIT" status --porcelain 2>/dev/null)"
HAS_PENDING=0; [ -n "$PENDING" ] && HAS_PENDING=1

if [ "$DRY_RUN" -eq 1 ]; then
    echo '--- dry run ---'
    if [ "$HAS_PENDING" -eq 1 ]; then printf '%s\n' "$PENDING"; else echo '  (no local change)'; fi
    NOTE='dry run: nothing would be committed'
    [ "$HAS_PENDING" -eq 1 ] && NOTE='dry run: local changes detected, no commit and no push performed'
    [ "$HAS_PENDING" -eq 0 ] && [ "$REMOTE_STATE" = 'in-sync' ] && NOTE='dry run: already in sync'
    finish 'ok' "$SHA" "$REMOTE_STATE" "$NOTE" 0
fi

"$GIT" add -A || fail 'git add failed'
STAGED="$("$GIT" diff --cached --name-only 2>/dev/null)"
HAS_STAGED=0; [ -n "$STAGED" ] && HAS_STAGED=1

if [ "$HAS_STAGED" -eq 1 ]; then
    if [ "$USE_MSG_FILE" -eq 1 ]; then
        [ -f "$MESSAGE_FILE" ] || fail "message file not found: $MESSAGE_FILE"
        "$GIT" commit -q -F "$MESSAGE_FILE" || fail 'git commit failed'
    elif [ -n "$MESSAGE" ]; then
        "$GIT" commit -q -m "$MESSAGE" || fail 'git commit failed'
    else
        block 'changes are staged but no --message / --message-file was given; refusing to invent a commit message' "$SHA" "$REMOTE_STATE"
    fi
    SHA="$("$GIT" rev-parse --short HEAD 2>/dev/null | tr -d '\r')"
fi

if [ "$HAS_STAGED" -eq 0 ] && [ "$REMOTE_STATE" = 'in-sync' ]; then
    finish 'nothing-to-push' "$SHA" 'in-sync' 'working tree clean and remote already matches HEAD' 0
fi

# --- push, one retry for flaky networks ---
ATTEMPT=0
PUSHED=0
while [ "$ATTEMPT" -lt 2 ]; do
    ATTEMPT=$((ATTEMPT + 1))
    if "$GIT" push "$REMOTE" "$BRANCH" 2>&1; then PUSHED=1; break; fi
    if [ "$ATTEMPT" -lt 2 ]; then
        echo 'push failed, retrying once (network reset is common)'
        sleep 3
    fi
done
[ "$PUSHED" -eq 1 ] || fail 'git push failed after 2 attempts'

# --- verify: never trust "the command did not error" ---
LOCAL_FULL="$("$GIT" rev-parse HEAD 2>/dev/null | tr -d '\r')"
REMOTE_LINE="$("$GIT" ls-remote --heads "$REMOTE" "$BRANCH" 2>/dev/null | tr -d '\r')"
REMOTE_FULL="$(printf '%s\n' "$REMOTE_LINE" | awk 'NF>=2 && $1 ~ /^[0-9a-f]{40}$/ {print $1; exit}')"
if [ "$REMOTE_FULL" != "$LOCAL_FULL" ]; then
    fail "push reported success but remote head ($REMOTE_FULL) != local head ($LOCAL_FULL)"
fi

NOTE='pushed and verified against ls-remote'

# --- optional: wait for the CI conclusion of the pushed commit ---
if [ "$WAIT_CI" -eq 1 ]; then
    URL="$("$GIT" remote get-url "$REMOTE" 2>/dev/null | tr -d '\r')"
    SLUG=''
    case "$URL" in
        *github.com*|*GitHub.com*)
            tail="${URL#*github.com}"; tail="${tail#*GitHub.com}"
            tail="${tail#:}"; tail="${tail#/}"; tail="${tail%%\?*}"
            owner="${tail%%/*}"; repo="${tail#*/}"; repo="${repo%%/*}"; repo="${repo%.git}"
            if [ -n "$owner" ] && [ -n "$repo" ]; then SLUG="$owner/$repo"; fi ;;
    esac
    if [ -z "$SLUG" ] || [ -z "$GH" ]; then
        NOTE="$NOTE; CI=unknown (no github.com remote or gh missing)"
    else
        DEADLINE=$((SECONDS + CI_TIMEOUT))
        CI='pending'
        while [ "$SECONDS" -lt "$DEADLINE" ]; do
            # only trust a run whose headSha is the commit we just pushed: right after a push
            # the newest run may still be the previous one.
            RAW="$("$GH" run list --repo "$SLUG" --limit 3 --json headSha,status,conclusion \
                   --jq ".[] | select(.headSha==\"$LOCAL_FULL\") | (.conclusion // .status)" 2>/dev/null | tr -d '\r')"
            if [ -n "$RAW" ]; then CI="$(printf '%s\n' "$RAW" | head -1)"; break; fi
            sleep 10
        done
        [ "$CI" = 'pending' ] && CI='pending (timeout waiting for a run of this commit)'
        NOTE="$NOTE; CI=$CI"
    fi
fi

finish 'ok' "$SHA" 'in-sync' "$NOTE" 0
