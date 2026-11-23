#!/usr/bin/env bash
# setup.sh -- install the toolchain this skill needs, and RECORD exactly what was installed.
# The record is what makes an uninstall clean: teardown.sh removes only the things listed here.
#
# Usage:
#   ./setup.sh                 # git + gh (recommended)
#   ./setup.sh --minimal       # git only, push with a stored token instead of gh
#   ./setup.sh --dry-run       # print the plan, install nothing
#   ./setup.sh --no-copy       # do not drop the standalone uninstaller into $HOME
#
# State file: ${GITHUB_PUBLISH_HOME:-$HOME/.github-publish}/state.tsv
# It lives OUTSIDE the skill directory on purpose: if you delete the skill folder,
# teardown still knows what to clean up, and $HOME/github-publish-uninstall.sh still works.

set -u

MINIMAL=0
DRY_RUN=0
NO_COPY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --minimal) MINIMAL=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-copy) NO_COPY=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

HOME_DIR="${GITHUB_PUBLISH_HOME:-$HOME/.github-publish}"
STATE="$HOME_DIR/state.tsv"
TS="$(date +%Y-%m-%dT%H:%M:%S)"

# --- environment detection ---
# Termux-family detection keys off the `pkg` wrapper, which only Termux ships; the path check
# is a fallback because custom builds (a Termux bundled inside another app) may use a prefix
# that never contains "com.termux".
if command -v pkg >/dev/null 2>&1; then
    ENV_NAME='termux'; PKG_INSTALL='pkg install -y'; PKG_UNINSTALL='pkg uninstall -y'
elif [ -n "${PREFIX:-}" ] && printf '%s' "$PREFIX" | grep -qE 'com\.termux|/termux/'; then
    ENV_NAME='termux'; PKG_INSTALL='pkg install -y'; PKG_UNINSTALL='pkg uninstall -y'
elif command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
        ENV_NAME='debian'; PKG_INSTALL='apt-get install -y'; PKG_UNINSTALL='apt-get remove -y'
    elif command -v sudo >/dev/null 2>&1; then
        ENV_NAME='debian (sudo)'; PKG_INSTALL='sudo apt-get install -y'; PKG_UNINSTALL='sudo apt-get remove -y'
    else
        ENV_NAME='debian (no sudo)'; PKG_INSTALL=''; PKG_UNINSTALL=''
    fi
elif command -v dnf >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
        ENV_NAME='rhel'; PKG_INSTALL='dnf install -y'; PKG_UNINSTALL='dnf remove -y'
    elif command -v sudo >/dev/null 2>&1; then
        ENV_NAME='rhel (sudo)'; PKG_INSTALL='sudo dnf install -y'; PKG_UNINSTALL='sudo dnf remove -y'
    else
        ENV_NAME='rhel (no sudo)'; PKG_INSTALL=''; PKG_UNINSTALL=''
    fi
elif command -v brew >/dev/null 2>&1; then
    ENV_NAME='brew'; PKG_INSTALL='brew install'; PKG_UNINSTALL='brew uninstall'
else
    ENV_NAME='unknown'; PKG_INSTALL=''; PKG_UNINSTALL=''
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; else echo "  \$ $*"; "$@"; fi
}

record() {  # kind name action
    [ "$DRY_RUN" -eq 1 ] && return 0
    mkdir -p "$HOME_DIR"
    if [ ! -f "$STATE" ]; then
        printf 'kind\tname\taction\tstamp\n' > "$STATE"
    fi
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$TS" >> "$STATE"
}

echo "environment : $ENV_NAME"
echo "state file  : $STATE"
echo

# --- packages ---
install_pkg() {  # name
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "$name: already present ($(command -v "$name"))"
        record pkg "$name" preexisting
        return 0
    fi
    if [ -z "$PKG_INSTALL" ]; then
        echo "$name: MISSING and no known package manager here. Install it yourself, then rerun." >&2
        MISSING=1
        return 1
    fi
    echo "$name: not found, installing via $ENV_NAME"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] $PKG_INSTALL $name"
        record pkg "$name" installed
        return 0
    fi
    # shellcheck disable=SC2086
    if $PKG_INSTALL "$name"; then
        record pkg "$name" installed
        echo "$name: installed and recorded"
    else
        echo "$name: install FAILED (nothing recorded)" >&2
        FAILED_INSTALL=1
        return 1
    fi
}

MISSING=0
FAILED_INSTALL=0
install_pkg git || true
if [ "$MINIMAL" -eq 0 ]; then
    install_pkg gh || true
fi

# curl helps for API calls and token checks; record it so teardown can drop it again
if ! command -v curl >/dev/null 2>&1; then
    echo 'curl: not found (optional, useful for API fallbacks)'
fi
echo

# --- git credential helper wired to gh ---
GIT_BIN="$(command -v git 2>/dev/null || true)"
if [ -n "$GIT_BIN" ] && [ "$MINIMAL" -eq 0 ] && command -v gh >/dev/null 2>&1; then
    GH_PATH="$(command -v gh)"
    CURRENT="$("$GIT_BIN" config --global --get 'credential.https://github.com.helper' 2>/dev/null || true)"
    if [ -z "$CURRENT" ]; then
        echo 'credential helper: wiring git to gh (no GCM needed on this platform)'
        if [ "$DRY_RUN" -eq 0 ]; then
            "$GIT_BIN" config --global 'credential.https://github.com.helper' "!$GH_PATH auth git-credential"
            record gitconfig 'credential.https://github.com.helper' set
        else
            echo "  [dry-run] git config --global credential.https://github.com.helper \"!$GH_PATH auth git-credential\""
        fi
    else
        echo "credential helper: already set ($CURRENT), left untouched"
    fi
elif [ "$MINIMAL" -eq 1 ]; then
    echo 'credential helper: minimal mode, use a token instead (git config --global credential.helper store)'
fi

# --- standalone uninstaller: survives deleting this skill folder ---
TEARDOWN="$(dirname "$0")/teardown.sh"
if [ "$NO_COPY" -eq 0 ] && [ -f "$TEARDOWN" ]; then
    target="$HOME/github-publish-uninstall.sh"
    if [ "$DRY_RUN" -eq 0 ]; then
        cp "$TEARDOWN" "$target" && chmod +x "$target"
        record file "$target" created
        echo "uninstaller : $target  (run it before deleting the skill)"
    else
        echo "  [dry-run] copy teardown.sh -> $target"
    fi
fi

echo
echo '--- verify ---'
if command -v git >/dev/null 2>&1; then echo "git  : $(git --version)"; else echo 'git  : MISSING'; fi
if command -v gh >/dev/null 2>&1; then
    echo "gh   : $(gh --version 2>/dev/null | head -1)"
    if gh auth status 2>&1 | grep -q 'Logged in to github.com account'; then
        echo 'auth : logged in'
    else
        echo 'auth : NOT logged in -> gh auth login  (device code, you paste it yourself)'
    fi
else
    echo 'gh   : not installed (minimal mode)'
fi
echo
echo '--- uninstall later ---'
echo "  $HOME/github-publish-uninstall.sh            # shows the plan, changes nothing"
echo "  $HOME/github-publish-uninstall.sh --yes      # actually removes what was installed here"
echo
[ "$MISSING" -eq 0 ] && [ "$FAILED_INSTALL" -eq 0 ] && exit 0
exit 1
