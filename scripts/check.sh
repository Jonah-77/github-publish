#!/usr/bin/env bash
# check.sh -- read-only GitHub state check. Never stages, commits, pushes or changes the repo.
#
# Usage:
#   ./check.sh --repo /path/to/repo
#   ./check.sh --repo /path/to/repo --branch dev
#
# Tool paths: --git / --gh, or GIT_BIN / GH_BIN, or the first git / gh on PATH.
# Requires bash 4+. Runs as-is in Termux.

set -u

REPO=''
REMOTE='origin'
BRANCH=''
GIT_ARG=''
GH_ARG=''

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)   REPO="${2:-}"; shift 2 ;;
        --remote) REMOTE="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --git)    GIT_ARG="${2:-}"; shift 2 ;;
        --gh)     GH_ARG="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

GIT="$GIT_ARG"; [ -n "$GIT" ] || GIT="${GIT_BIN:-}"; [ -n "$GIT" ] || GIT="$(command -v git 2>/dev/null || true)"
GH="$GH_ARG";   [ -n "$GH" ]  || GH="${GH_BIN:-}";   [ -n "$GH" ]  || GH="$(command -v gh 2>/dev/null || true)"

emit() {  # status sha remote-state note
    echo "STATUS=$1"
    echo "CLASS=r"
    echo "SHA=$2"
    echo "REMOTE=$3"
    echo "NOTE=$4"
    exit 0
}

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    emit 'failed' '-' 'n/a' "repo path not found: ${REPO:-<empty>}"
fi
if [ -z "$GIT" ] || ! "$GIT" -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    emit 'failed' '-' 'n/a' "not a git repository: $REPO"
fi

if [ -z "$BRANCH" ]; then
    BRANCH="$("$GIT" -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r')"
fi
LOCAL_FULL="$("$GIT" -C "$REPO" rev-parse HEAD 2>/dev/null | tr -d '\r')"
LOCAL_SHORT="$("$GIT" -C "$REPO" rev-parse --short HEAD 2>/dev/null | tr -d '\r')"

# --- auth ---
AUTH='missing'
if [ -n "$GH" ]; then
    if "$GH" auth status 2>&1 | grep -q 'Logged in to github.com account'; then AUTH='logged-in'; fi
fi

# --- working tree ---
PORCELAIN="$("$GIT" -C "$REPO" status --porcelain 2>/dev/null)"
DIRTY='no'; [ -n "$PORCELAIN" ] && DIRTY='yes'

# --- remote head (no fetch: ls-remote keeps this read-only) ---
REMOTE_LINE="$("$GIT" -C "$REPO" ls-remote --heads "$REMOTE" "$BRANCH" 2>/dev/null | tr -d '\r')"
REMOTE_FULL="$(printf '%s\n' "$REMOTE_LINE" | awk 'NF>=2 && $1 ~ /^[0-9a-f]{40}$/ {print $1; exit}')"

REMOTE_STATE='n/a'; AHEAD='0'; BEHIND='0'
if [ -z "$REMOTE_FULL" ]; then
    REMOTE_STATE='n/a'
elif [ "$REMOTE_FULL" = "$LOCAL_FULL" ]; then
    REMOTE_STATE='in-sync'
else
    if "$GIT" -C "$REPO" cat-file -e "${REMOTE_FULL}^{commit}" >/dev/null 2>&1; then
        COUNTS="$("$GIT" -C "$REPO" rev-list --left-right --count "HEAD...$REMOTE_FULL" 2>/dev/null | tr -d '\r')"
        AHEAD="$(printf '%s' "$COUNTS" | awk '{print $1}')"; BEHIND="$(printf '%s' "$COUNTS" | awk '{print $2}')"
        AHEAD="${AHEAD:-0}"; BEHIND="${BEHIND:-0}"
        if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then REMOTE_STATE='diverged'
        elif [ "$BEHIND" -gt 0 ]; then REMOTE_STATE='behind'
        else REMOTE_STATE='ahead'; fi
    else
        REMOTE_STATE='ahead'
    fi
fi

# --- repo slug from remote url ---
URL="$("$GIT" -C "$REPO" remote get-url "$REMOTE" 2>/dev/null | tr -d '\r')"
SLUG=''
case "$URL" in
    *github.com*|*GitHub.com*)
        tail="${URL#*github.com}"; tail="${tail#*GitHub.com}"
        tail="${tail#:}"; tail="${tail#/}"; tail="${tail%%\?*}"
        owner="${tail%%/*}"; repo="${tail#*/}"; repo="${repo%%/*}"; repo="${repo%.git}"
        if [ -n "$owner" ] && [ -n "$repo" ]; then SLUG="$owner/$repo"; fi
        ;;
esac

# --- CI + Pages (best effort, never fatal) ---
CI='n/a'; PAGES='n/a'
if [ -n "$SLUG" ] && [ -n "$GH" ]; then
    CI="$("$GH" run list --repo "$SLUG" --limit 1 --json status,conclusion,headBranch \
          --jq '.[0] | (.conclusion // .status // "n/a")' 2>/dev/null | tr -d '\r')"
    [ -n "$CI" ] || CI='n/a'
    PAGES_RAW="$("$GH" api "repos/$SLUG/pages/builds/latest" --jq '.status' 2>/dev/null | tr -d '\r')"
    case "$PAGES_RAW" in
        built|building|errored|null|queued) PAGES="$PAGES_RAW" ;;
        *) PAGES='n/a' ;;
    esac
fi

# --- detail block ---
echo '---'
echo "repo      : $REPO"
echo "branch    : $BRANCH"
echo "auth      : $AUTH"
echo "dirty     : $DIRTY"
echo "local     : $LOCAL_SHORT"
if [ -n "$REMOTE_FULL" ]; then echo "remote    : ${REMOTE_FULL:0:7}"; else echo 'remote    : -'; fi
echo "ahead     : $AHEAD"
echo "behind    : $BEHIND"
echo "ci-latest : $CI"
echo "pages     : $PAGES"
if [ "$DIRTY" = 'yes' ]; then echo '---'; printf '%s\n' "$PORCELAIN"; fi

NOTE='no action needed'
if [ "$AUTH" = 'missing' ]; then NOTE='gh not logged in; run the device-code flow in SKILL.md section 8'
elif [ "$REMOTE_STATE" = 'behind' ]; then NOTE="remote is $BEHIND commit(s) ahead; sync before pushing"
elif [ "$REMOTE_STATE" = 'diverged' ]; then NOTE="local $AHEAD / remote $BEHIND; needs a human decision before any push"
elif [ "$REMOTE_STATE" = 'ahead' ]; then NOTE="local has $AHEAD commit(s) not on remote"
elif [ "$DIRTY" = 'yes' ]; then NOTE='working tree has uncommitted changes'
fi

emit 'ok' "$LOCAL_SHORT" "$REMOTE_STATE" "$NOTE"
