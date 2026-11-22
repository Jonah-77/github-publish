#!/usr/bin/env bash
# install.sh -- install the POSIX side of this skill only (Termux / Linux / macOS).
#
# It copies the shared docs plus the .sh scripts. The Windows .ps1 scripts are never
# touched or copied: a phone or a Linux box has no PowerShell, and there is no point
# in carrying code it cannot run.
#
# Usage:
#   ./install/install.sh                       # default target: ~/.agent-skills/github-publish
#   ./install/install.sh --target ~/skills/github-publish
#   ./install/install.sh --dry-run             # print what would be copied
#   ./install/install.sh --force               # replace an existing install
#   ./install/install.sh --uninstall           # remove the copied skill (not the packages)
#
# After copying, run scripts/setup.sh to install git/gh; that step is separately
# recorded and separately removable (see scripts/teardown.sh).

set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$HOME/.agent-skills/github-publish"
DRY_RUN=0
FORCE=0
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target)    TARGET="${2:-}"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --force)     FORCE=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

# shared + this platform only. No .ps1 here on purpose.
FILES=(
    SKILL.md
    README.md
    LICENSE
    platforms.json
    scripts/check.sh
    scripts/publish.sh
    scripts/scan-traces.sh
    scripts/setup.sh
    scripts/teardown.sh
)

marker() { printf 'github-publish posix\n' > "$1"; }

if [ "$UNINSTALL" -eq 1 ]; then
    if [ ! -d "$TARGET" ]; then echo "nothing to remove: $TARGET does not exist"; exit 0; fi
    if [ ! -f "$TARGET/.platform" ] || ! grep -q 'github-publish posix' "$TARGET/.platform"; then
        echo "refusing: $TARGET was not installed by this script (no posix marker)" >&2
        exit 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then echo "[dry-run] would remove $TARGET"; exit 0; fi
    rm -rf "$TARGET"
    echo "removed skill copy: $TARGET"
    echo 'packages installed by setup.sh are NOT removed here; run ~/github-publish-uninstall.sh --yes'
    exit 0
fi

if [ -d "$TARGET" ] && [ "$FORCE" -eq 0 ]; then
    echo "target exists: $TARGET" >&2
    echo 'rerun with --force to replace it, or --uninstall to remove it first' >&2
    exit 1
fi

echo "source : $SRC"
echo "target : $TARGET"
echo "platform: posix (bash 4+) -- Windows .ps1 files are skipped"
echo

for f in "${FILES[@]}"; do
    if [ ! -f "$SRC/$f" ]; then
        echo "missing in source: $f" >&2
        exit 1
    fi
    echo "  $f"
done

if [ "$DRY_RUN" -eq 1 ]; then echo; echo '[dry-run] nothing copied'; exit 0; fi

mkdir -p "$TARGET/scripts"
for f in "${FILES[@]}"; do
    cp "$SRC/$f" "$TARGET/$f"
done
chmod +x "$TARGET"/scripts/*.sh
marker "$TARGET/.platform"

echo
echo '--- next ---'
echo "  1. $TARGET/scripts/setup.sh --dry-run     # see the toolchain plan"
echo "  2. $TARGET/scripts/setup.sh               # install git/gh (recorded, removable)"
echo '  3. gh auth login --hostname github.com --git-protocol https --web'
echo "  4. $TARGET/scripts/check.sh --repo <repo>"
echo
echo 'uninstall:'
echo "  $TARGET/install/install.sh --uninstall   (or: rm -rf $TARGET)"
echo '  ~/github-publish-uninstall.sh --yes      (packages + config recorded by setup.sh)'
