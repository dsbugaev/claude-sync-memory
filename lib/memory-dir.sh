#!/usr/bin/env bash
# Prints the memory folder Claude Code uses for a given working directory.
#
# Usage: memory-dir.sh <cwd>
#
# The key is the repository root, not the working directory: inside a git repository every
# subdirectory and every worktree shares the repository's memory folder. This was wrong once
# already - computing the key from CWD sent memory into a folder Claude Code never reads -
# which is why it lives in a script with tests around it instead of in prose.

set -uo pipefail

CWD="${1:-$PWD}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BASE="$CLAUDE_DIR/projects"

munge() { printf '%s' "$1" | sed 's/[\/.]/-/g'; }
candidate() { printf '%s/%s/memory' "$BASE" "$(munge "$1")"; }

ROOT_PHYS=""
ROOT_LOGICAL=""
if ROOT_PHYS="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"; then
    # A worktree points back at its main repository through the common git dir.
    COMMON="$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null)"
    case "$COMMON" in
        /*) ROOT_PHYS="$(dirname "$COMMON")" ;;
    esac

    # Claude Code keys the folder by the path string it was launched with, and on macOS that
    # string usually runs through a symlink (/var -> /private/var, /tmp -> /private/tmp) that
    # git resolves away. Walk up from the given CWD by the same number of levels instead of
    # taking git's answer verbatim, so the spelling the user actually types is preserved.
    CWD_PHYS="$(cd "$CWD" 2>/dev/null && pwd -P)" || CWD_PHYS="$CWD"
    ROOT_LOGICAL="$ROOT_PHYS"
    case "$CWD_PHYS" in
        "$ROOT_PHYS"|"$ROOT_PHYS"/*)
            REL="${CWD_PHYS#"$ROOT_PHYS"}"
            ROOT_LOGICAL="$CWD"
            OLD_IFS="$IFS"; IFS='/'
            for part in $REL; do
                [ -z "$part" ] && continue
                ROOT_LOGICAL="$(dirname "$ROOT_LOGICAL")"
            done
            IFS="$OLD_IFS"
            ;;
    esac
fi

# A folder that already exists wins over any computed one: it is what Claude Code
# demonstrably uses. Only when nothing exists yet do we pick the best guess.
for key in "$CWD" "$ROOT_LOGICAL" "$ROOT_PHYS"; do
    [ -z "$key" ] && continue
    if [ -d "$(candidate "$key")" ]; then
        candidate "$key"
        exit 0
    fi
done

if [ -n "$ROOT_LOGICAL" ]; then
    candidate "$ROOT_LOGICAL"
else
    candidate "$CWD"
fi
