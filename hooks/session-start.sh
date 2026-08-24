#!/usr/bin/env bash
# SessionStart: reminds about unprocessed sessions and about a released update.
# This script's stdout reaches the model as additional context.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOME_DIR="$CLAUDE_DIR/sync-memory"
QUEUE="$CLAUDE_DIR/scripts/.pending-memory.log"

case "$(pwd)" in
    "$CLAUDE_DIR"*) exit 0 ;;
esac

# --- the queue of unprocessed sessions ---
if [ -f "$QUEUE" ] && [ -s "$QUEUE" ]; then
    COUNT="$(wc -l < "$QUEUE" | tr -d ' ')"
    if [ "$COUNT" -gt 0 ]; then
        echo "📝 Memory: $COUNT unprocessed session(s). Run /sync-memory to update the memory files."
    fi
fi

# --- updates: show the last check's result, run the next one in the background ---
if [ -s "$HOME_DIR/.update-available" ]; then
    echo "⬆️  Claude Sync Memory: $(cat "$HOME_DIR/.update-available"). Update with: bash $HOME_DIR/src/install.sh --update"
fi

if [ -x "$HOME_DIR/src/update-check.sh" ]; then
    STAMP="$HOME_DIR/.last-update-check"
    NOW="$(date +%s)"
    LAST=0
    [ -f "$STAMP" ] && LAST="$(cat "$STAMP" 2>/dev/null || echo 0)"
    case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
    # Once a week. The check is detached so it cannot slow down session start:
    # git fetch against an unreachable network outlasts the hook timeout.
    if [ $((NOW - LAST)) -gt 604800 ]; then
        echo "$NOW" > "$STAMP"
        nohup "$HOME_DIR/src/update-check.sh" >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
fi

exit 0
