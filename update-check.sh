#!/usr/bin/env bash
# Тихо смотрит, не вышла ли новая версия. Запускается фоном из SessionStart
# раз в неделю. Результат кладет в .update-available - его печатает хук
# при следующем старте сессии. Ничего сам не устанавливает.

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
        echo "вышло обновление ($BEHIND новых коммитов)" > "$FLAG"
    fi
else
    rm -f "$FLAG"
fi

exit 0
