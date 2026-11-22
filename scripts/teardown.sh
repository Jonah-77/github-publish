#!/usr/bin/env bash
# teardown.sh -- remove ONLY what setup.sh installed, and nothing else.
# Default is a dry run: it prints the plan and changes nothing. Pass --yes to execute.
#
# Usage:
#   ./teardown.sh                # plan only
#   ./teardown.sh --yes          # remove what this skill installed
#   ./teardown.sh --yes --purge-auth   # also delete gh's stored login (~/.config/gh)
#
# Safety rules baked in:
#   - tools that were ALREADY installed before setup are never touched (recorded as "preexisting")
#   - files are only deleted when the path is under $HOME and was created by setup
#   - config keys are unset only when setup set them
# It reads ${GITHUB_PUBLISH_HOME:-$HOME/.github-publish}/state.tsv, which lives outside
# the skill folder: deleting the skill first does not lose the cleanup information.

set -u

YES=0
PURGE_AUTH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1; shift ;;
        --purge-auth) PURGE_AUTH=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

HOME_DIR="${GITHUB_PUBLISH_HOME:-$HOME/.github-publish}"
STATE="$HOME_DIR/state.tsv"

if [ ! -f "$STATE" ]; then
    echo "nothing recorded: $STATE does not exist"
    echo 'Nothing was installed by setup.sh (or the record is already gone). No changes made.'
    exit 0
fi

if [ -n "${PREFIX:-}" ] && printf '%s' "$PREFIX" | grep -q 'com.termux'; then
    PKG_UNINSTALL='pkg uninstall -y'
elif command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then PKG_UNINSTALL='apt-get remove -y'; else PKG_UNINSTALL='sudo apt-get remove -y'; fi
elif command -v dnf >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then PKG_UNINSTALL='dnf remove -y'; else PKG_UNINSTALL='sudo dnf remove -y'; fi
elif command -v brew >/dev/null 2>&1; then
    PKG_UNINSTALL='brew uninstall'
else
    PKG_UNINSTALL=''
fi

exec_run() {
    if [ "$YES" -eq 1 ]; then
        echo "  \$ $*"; "$@"
    else
        echo "  [plan] $*"
    fi
}

echo "state file : $STATE"
echo "mode       : $([ "$YES" -eq 1 ] && echo 'APPLY' || echo 'PLAN ONLY (add --yes to execute)')"
echo

PKG_INSTALLED_LIST="$(awk -F'\t' 'NR>1 && $1=="pkg" && $3=="installed" {print $2}' "$STATE" | tr '\n' ' ')"
PKG_PREEXISTING="$(awk -F'\t' 'NR>1 && $1=="pkg" && $3=="preexisting" {print $2}' "$STATE" | tr '\n' ' ')"
FILES_CREATED="$(awk -F'\t' 'NR>1 && $1=="file" {print $2}' "$STATE")"
GIT_KEYS="$(awk -F'\t' 'NR>1 && $1=="gitconfig" && $3=="set" {print $2}' "$STATE")"

echo "--- packages to remove (installed by setup) ---"
if [ -z "$PKG_INSTALLED_LIST" ]; then echo '  (none)'; else
    for p in $PKG_INSTALLED_LIST; do
        if [ -n "$PKG_UNINSTALL" ]; then
            echo "  $p: will be removed"
            # shellcheck disable=SC2086
            exec_run $PKG_UNINSTALL "$p"
        else
            echo "  $p: no package manager detected, remove it by hand"
        fi
    done
fi

if [ -n "$PKG_PREEXISTING" ]; then
    echo "--- left alone (already present before setup) ---"
    for p in $PKG_PREEXISTING; do echo "  $p: untouched"; done
fi
echo

echo '--- config keys to unset ---'
if [ -z "$GIT_KEYS" ]; then echo '  (none)'; else
    for k in $GIT_KEYS; do
        exec_run git config --global --unset "$k"
    done
fi
echo

echo '--- files created by setup ---'
if [ -z "$FILES_CREATED" ]; then echo '  (none)'; else
    printf '%s\n' "$FILES_CREATED" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            "$HOME"/*) : ;;
            *) echo "  skip (outside \$HOME): $f"; continue ;;
        esac
        if [ -e "$f" ]; then
            if [ "$YES" -eq 1 ]; then rm -rf -- "$f" && echo "  removed: $f"; else echo "  [plan] remove: $f"; fi
        else
            echo "  already gone: $f"
        fi
    done
fi
echo

if [ "$PURGE_AUTH" -eq 1 ]; then
    exec_run rm -rf "$HOME/.config/gh"
    echo '  gh login data removed (next use needs a fresh device-code login)'
else
    echo '--- kept: gh login data (~/.config/gh); add --purge-auth to remove it too ---'
fi
echo

echo '--- finished ---'
if [ "$YES" -eq 1 ]; then
    rm -rf "$HOME_DIR"
    echo "  state record deleted: $HOME_DIR"
    echo '  skill folder itself is untouched; delete it now if you want it gone'
echo '  optional: pkg autoremove   (drop dependency packages the removal left behind)'
else
    echo '  nothing was changed; rerun with --yes to apply'
fi
