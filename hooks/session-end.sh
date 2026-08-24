#!/usr/bin/env bash
# SessionEnd: queues a finished session for memory processing.
# The queue is drained by the /sync-memory command.
#
# Only sessions that actually have something to record belong in the queue.
# Auditing a live queue showed 25 of 30 entries were blanks - a session window opened
# and closed without a single message. Those events arrive in bursts and make the queue
# meaningless: the counter promises 35 sessions, 5 of them are real.
# The discriminator: a real session already has its transcript file on disk by the time
# this hook fires, a blank one has it nowhere, then or ever.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG_DIR="$CLAUDE_DIR/scripts"
QUEUE="$LOG_DIR/.pending-memory.log"
SKIPLOG="$LOG_DIR/.session-end-skipped.log"

# Directories to keep no memory for. Colon-separated, a trailing * is honoured.
# Override with an environment variable, for example:
#   export CLAUDE_MEMORY_EXCLUDE="$HOME/notes/*:$HOME/work/secret*"
EXCLUDE="${CLAUDE_MEMORY_EXCLUDE:-}"

# A sync-memory run does not queue itself, or it would loop.
[ -n "${CLAUDE_SYNC_MEMORY_RUN:-}" ] && exit 0

INPUT="$(cat 2>/dev/null || true)"

read -r SESSION_ID CWD TRANSCRIPT <<EOF
$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("session_id") or "-", d.get("cwd") or "-", d.get("transcript_path") or "-")
' 2>/dev/null || echo "- - -")
EOF

[ "$CWD" = "-" ] && CWD="$(pwd)"
[ "$TRANSCRIPT" = "-" ] && TRANSCRIPT=""
[ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "-" ] && exit 0

mkdir -p "$LOG_DIR"

# The reason for skipping goes to its own log: without it the filter cannot be checked,
# and a silent filter will one day start eating sessions you needed.
skip() {
    printf '%s|%s|%s|%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$SESSION_ID" "$1" "$CWD" >> "$SKIPLOG"
    if [ "$(wc -l < "$SKIPLOG" 2>/dev/null || echo 0)" -gt 300 ]; then
        tail -n 150 "$SKIPLOG" > "$SKIPLOG.tmp" 2>/dev/null && mv "$SKIPLOG.tmp" "$SKIPLOG"
    fi
    exit 0
}

# 1. No memory for the Claude Code config itself or for excluded directories.
case "$CWD" in
    "$CLAUDE_DIR"*) exit 0 ;;
esac
if [ -n "$EXCLUDE" ]; then
    IFS=':' read -ra PATTERNS <<< "$EXCLUDE"
    for p in "${PATTERNS[@]}"; do
        [ -z "$p" ] && continue
        # shellcheck disable=SC2254
        case "$CWD" in $p) exit 0 ;; esac
    done
fi

# 2. A blank: no transcript on disk means there is nothing to record.
[ -z "$TRANSCRIPT" ] && TRANSCRIPT="$CLAUDE_DIR/projects/$(echo "$CWD" | sed 's/[\/.]/-/g')/${SESSION_ID}.jsonl"
[ -f "$TRANSCRIPT" ] || skip "no-transcript"

# 3. A /sync-memory run itself - nothing to record by definition.
head -c 20000 "$TRANSCRIPT" 2>/dev/null | grep -q '<command-name>/sync-memory' && skip "service-sync-memory"

# 4. Not a single real user turn (tool results and subagents do not count).
#    The threshold is zero, not "fewer than two": single-turn research sessions
#    produce perfectly good memory files.
TURNS="$(grep '"type":"user"' "$TRANSCRIPT" 2>/dev/null | grep -v 'tool_result' | grep -vc '"isSidechain":true' || true)"
[ -z "$TURNS" ] && TURNS=0
[ "$TURNS" -lt 1 ] && skip "no-turns"

printf '%s|%s|%s\n' "$SESSION_ID" "$CWD" "$(date +%Y-%m-%dT%H:%M:%S)" >> "$QUEUE"
exit 0
