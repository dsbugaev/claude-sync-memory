#!/usr/bin/env bash
# Quietly checks whether a newer version was released. Started in the background from
# SessionStart once a week. Writes the result to .update-available, which the hook prints
# at the next session start. Installs nothing on its own.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOME_DIR="$CLAUDE_DIR/sync-memory"
FLAG="$HOME_DIR/.update-available"
STAMP="$HOME_DIR/.last-update-check"

# SessionStart stamps the clock before launching us, so a storm of background gits is
# impossible. The cost is that a check which never got to run still burns the whole week.
# Rewind the clock on a failure that might not repeat, so the next session tries again.
retry_next_time() { rm -f "$STAMP"; exit 0; }

SRC="$(python3 -c "
import json
try: print(json.load(open('$HOME_DIR/config.json',encoding='utf-8')).get('src',''))
except Exception: print('')
" 2>/dev/null)"

command -v git >/dev/null || exit 0
[ -n "$SRC" ] || exit 0
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Offline, or a repository that has moved: worth another go rather than a week of silence.
git -C "$SRC" fetch --quiet 2>/dev/null || retry_next_time

LOCAL="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo x)"
REMOTE="$(git -C "$SRC" rev-parse '@{u}' 2>/dev/null || echo x)"
if [ "$LOCAL" = "x" ] || [ "$REMOTE" = "x" ]; then
    # No upstream to compare against - a detached HEAD, usually. Not a transient fault.
    exit 0
fi

if [ "$LOCAL" != "$REMOTE" ]; then
    BEHIND="$(git -C "$SRC" rev-list --count HEAD..'@{u}' 2>/dev/null || echo "")"
    if [ -n "$BEHIND" ] && [ "$BEHIND" -gt 0 ] 2>/dev/null; then
        # A version number tells the user something; "5 new commits" does not. Read the
        # changelog off the fetched branch without touching the working copy.
        HAVE="$(python3 -c "
import json,sys
try: print(json.load(open('$HOME_DIR/config.json',encoding='utf-8')).get('version',''))
except Exception: print('')
" 2>/dev/null)"
        THERE="$(git -C "$SRC" show '@{u}':CHANGELOG.md 2>/dev/null \
            | bash "$SRC/lib/changelog.sh" - 0.0.0 --version-only 2>/dev/null || true)"
        if [ -n "$THERE" ] && [ -n "$HAVE" ] && [ "$THERE" != "$HAVE" ]; then
            echo "version $THERE is out, you have $HAVE" > "$FLAG"
        elif [ -n "$THERE" ]; then
            echo "version $THERE is out" > "$FLAG"
        else
            echo "an update is available ($BEHIND new commits)" > "$FLAG"
        fi
    fi
else
    rm -f "$FLAG"
fi

exit 0
