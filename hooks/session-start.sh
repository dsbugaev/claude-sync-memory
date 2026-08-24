#!/usr/bin/env bash
# SessionStart: напоминает про неразобранные сессии и про вышедшее обновление.
# Stdout этого скрипта попадает в контекст модели как дополнительный контекст.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOME_DIR="$CLAUDE_DIR/sync-memory"
QUEUE="$CLAUDE_DIR/scripts/.pending-memory.log"

case "$(pwd)" in
    "$CLAUDE_DIR"*) exit 0 ;;
esac

# --- очередь неразобранных сессий ---
if [ -f "$QUEUE" ] && [ -s "$QUEUE" ]; then
    COUNT="$(wc -l < "$QUEUE" | tr -d ' ')"
    if [ "$COUNT" -gt 0 ]; then
        echo "📝 Память: неразобранных сессий - $COUNT. Запусти /sync-memory, чтобы обновить файлы памяти."
    fi
fi

# --- обновление: результат прошлой проверки показываем, новую запускаем фоном ---
if [ -s "$HOME_DIR/.update-available" ]; then
    echo "⬆️  Claude Sync Memory: $(cat "$HOME_DIR/.update-available"). Обновиться: bash $HOME_DIR/src/install.sh --update"
fi

if [ -x "$HOME_DIR/src/update-check.sh" ]; then
    STAMP="$HOME_DIR/.last-update-check"
    NOW="$(date +%s)"
    LAST=0
    [ -f "$STAMP" ] && LAST="$(cat "$STAMP" 2>/dev/null || echo 0)"
    case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
    # Раз в неделю. Проверка уходит в фон и на старт сессии не влияет:
    # git fetch по недоступной сети висит дольше, чем таймаут хука.
    if [ $((NOW - LAST)) -gt 604800 ]; then
        echo "$NOW" > "$STAMP"
        nohup "$HOME_DIR/src/update-check.sh" >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
fi

exit 0
