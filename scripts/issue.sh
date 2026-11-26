#!/usr/bin/env bash
# issue.sh -- open an issue on any GitHub repository (own or third-party) after a
# desensitisation gate. Reads only until the gate passes; --dry-run creates nothing.
#
# Usage:
#   ./issue.sh --repo owner/name --title-file /tmp/t.txt --body-file /tmp/b.md --dry-run
#   ./issue.sh --repo owner/name --title-file /tmp/t.txt --body-file /tmp/b.md \
#              --deny-list 'company,client,project'
#
# Output is the shared four-line contract: STATUS / CLASS=issue / URL / NOTE.
# Tool paths: --gh, or GH_BIN, or the first gh on PATH. Requires bash 4+ and gh.

set -u

REPO=''
TITLE_FILE=''
BODY_FILE=''
LABELS=''
DENY=''
DRY_RUN=0
FORCE=0
GH_ARG=''

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)       REPO="${2:-}"; shift 2 ;;
        --title-file) TITLE_FILE="${2:-}"; shift 2 ;;
        --body-file)  BODY_FILE="${2:-}"; shift 2 ;;
        --labels)     LABELS="${2:-}"; shift 2 ;;
        --deny-list)  DENY="${2:-}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --force)      FORCE=1; shift ;;
        --gh)         GH_ARG="${2:-}"; shift 2 ;;
        -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

GH="$GH_ARG"; [ -n "$GH" ] || GH="${GH_BIN:-}"; [ -n "$GH" ] || GH="$(command -v gh 2>/dev/null || true)"

emit() {  # status url note code
    echo "STATUS=$1"
    echo "CLASS=issue"
    echo "URL=$2"
    echo "NOTE=$3"
    exit "$4"
}

[ -n "$TITLE_FILE" ] && [ -f "$TITLE_FILE" ] || emit 'blocked' '-' 'title file not found' 2
[ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ] || emit 'blocked' '-' 'body file not found' 2

TITLE="$(tr -d '\r' < "$TITLE_FILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [ -z "$TITLE" ]; then emit 'blocked' '-' 'title is empty' 2; fi
if ! grep -q '[^[:space:]]' "$BODY_FILE"; then emit 'blocked' '-' 'body is empty' 2; fi
case "$REPO" in
    */*) ;;
    *) emit 'blocked' '-' "repo must look like owner/name: ${REPO:-<empty>}" 2 ;;
esac

# --- desensitisation gate -------------------------------------------------
# Anything published to a repository we do not own must be the smallest public
# subset of the facts. These patterns catch what a script can catch; --deny-list
# is the human-supplied part (company, client, project, colleague names).
PATTERNS='[A-Za-z]:\\|Users\\|\\\\[^\\ ]+\\|gh[pous]_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY'
LOCAL_USER="$(printf '%s' "${USER:-}" | tr -d '\r')"
LOCAL_HOST="$(printf '%s' "${HOSTNAME:-}" | tr -d '\r')"
[ ${#LOCAL_USER} -gt 2 ] && PATTERNS="$PATTERNS|$(printf '%s' "$LOCAL_USER" | sed 's/[][\.*^$(){}?+|/]/\\&/g')"
[ ${#LOCAL_HOST} -gt 2 ] && PATTERNS="$PATTERNS|$(printf '%s' "$LOCAL_HOST" | sed 's/[][\.*^$(){}?+|/]/\\&/g')"

IFS=',' read -r -a WORDS <<< "$DENY"
for w in "${WORDS[@]}"; do
    w="$(printf '%s' "$w" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$w" ] && continue
    PATTERNS="$PATTERNS|$(printf '%s' "$w" | sed 's/[][\.*^$(){}?+|/]/\\&/g')"
done
# Chinese mobile numbers need their own rule: alternation plus word boundaries.
PATTERNS="$PATTERNS|(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)"

HITS="$( { grep -nE "$PATTERNS" "$BODY_FILE" 2>/dev/null | sed 's/^/body:/'; printf '%s\n' "$TITLE" | grep -nE "$PATTERNS" 2>/dev/null | sed 's/^/title:/'; } || true )"

if [ -n "$HITS" ]; then
    echo 'DESENSITISATION HITS:'
    printf '%s\n' "$HITS"
    if [ "$FORCE" -ne 1 ]; then
        emit 'blocked' '-' "$(printf '%s\n' "$HITS" | wc -l | tr -d ' ') sensitive pattern(s) found; rewrite the text (or pass --force after an explicit decision)" 2
    fi
    echo 'proceeding because --force was supplied'
fi

echo "PAYLOAD: repo=$REPO title=$TITLE"
echo "BODY BYTES: $(wc -c < "$BODY_FILE" | tr -d ' ')"

if [ "$DRY_RUN" -eq 1 ]; then emit 'dry-run' '-' "$TITLE" 0; fi

if [ -z "$GH" ] || ! command -v "$GH" >/dev/null 2>&1; then emit 'failed' '-' 'gh not found' 1; fi

ARGS=(issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE")
if [ -n "$LABELS" ]; then
    IFS=',' read -r -a LBL <<< "$LABELS"
    for l in "${LBL[@]}"; do
        l="$(printf '%s' "$l" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$l" ] && ARGS+=(--label "$l")
    done
fi

OUT=''
CODE=1
for attempt in 1 2; do
    OUT="$("$GH" "${ARGS[@]}" 2>&1)"; CODE=$?
    [ "$CODE" -eq 0 ] && break
    [ "$attempt" -lt 2 ] && sleep 3
done

if [ "$CODE" -ne 0 ]; then
    # `gh issue create` goes through GraphQL, which is unreliable on some networks.
    # Fall back to REST, but look for a duplicate first: a request that dies while
    # reading the response can still have created the issue.
    DUPE="$("$GH" api "repos/$REPO/issues?state=all&per_page=20&sort=created&direction=desc" 2>/dev/null \
        | TITLE="$TITLE" python3 -c '
import json,os,sys
want=os.environ.get("TITLE","")
try: data=json.load(sys.stdin)
except Exception: sys.exit(1)
for it in data:
    if it.get("title")==want:
        print(it.get("html_url","")); break
' 2>/dev/null)"
    if [ -n "$DUPE" ]; then emit 'ok' "$DUPE" 'existing issue found, nothing new created' 0; fi

    RESP="$("$GH" api -X POST "repos/$REPO/issues" -f "title=$TITLE" -F "body=@$BODY_FILE" 2>&1)"
    if [ $? -eq 0 ]; then
        URL="$(printf '%s' "$RESP" | grep -o '"html_url": *"[^"]*"' | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')"
        emit 'ok' "${URL:--}" "$TITLE (created via REST fallback)" 0
    fi
    emit 'failed' '-' "$(printf '%s' "$RESP" | tail -1)" 1
fi

URL="$(printf '%s' "$OUT" | tail -1 | tr -d '\r')"
emit 'ok' "$URL" "$TITLE" 0
