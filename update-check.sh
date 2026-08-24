#!/usr/bin/env bash
# Quietly checks whether a newer version was released. Started in the background from
# SessionStart once a week. Writes the result to .update-available, which the hook prints
# at the next session start. Installs nothing on its own.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOME_DIR="$CLAUDE_DIR/sync-memory"
FLAG="$HOME_DIR/.update-available"

SRC="$(python3 -c "
import json
try: print(json.load(open('$HOME_DIR/config.json',encoding='utf-8')).get('src',''))
except Exception: print('')
" 2>/dev/null)"

command -v git >/dev/null || exit 0
[ -n "$SRC" ] || exit 0
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || exit 0

git -C "$SRC" fetch --quiet 2>/dev/null || exit 0

LOCAL="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo x)"
REMOTE="$(git -C "$SRC" rev-parse '@{u}' 2>/dev/null || echo x)"
[ "$LOCAL" = "x" ] || [ "$REMOTE" = "x" ] && exit 0

if [ "$LOCAL" != "$REMOTE" ]; then
    BEHIND="$(git -C "$SRC" rev-list --count HEAD..'@{u}' 2>/dev/null || echo "")"
    if [ -n "$BEHIND" ] && [ "$BEHIND" -gt 0 ] 2>/dev/null; then
        echo "an update is available ($BEHIND new commits)" > "$FLAG"
    fi
else
    rm -f "$FLAG"
fi

exit 0
