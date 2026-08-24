#!/usr/bin/env bash
# SessionEnd: записывает закончившуюся сессию в очередь на обработку памятью.
# Очередь разбирает команда /sync-memory.
#
# В очередь должны попадать только сессии, из которых реально есть что записать.
# Разбор живой очереди показал: из 30 записей 25 были пустышками - окно сессии
# открыли и закрыли, не отправив ни одной реплики. Такие события приходят пачками
# и делают очередь бессмысленной: счетчик обещает 35 сессий, живых среди них 5.
# Дискриминатор: у живой сессии файл транскрипта уже существует в момент
# срабатывания хука, у пустышки его нет нигде ни тогда, ни потом.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG_DIR="$CLAUDE_DIR/scripts"
QUEUE="$LOG_DIR/.pending-memory.log"
SKIPLOG="$LOG_DIR/.session-end-skipped.log"

# Папки, для которых память не ведем. Через двоеточие, поддерживается хвост *.
# Переопределяется переменной окружения, например:
#   export CLAUDE_MEMORY_EXCLUDE="$HOME/notes/*:$HOME/work/secret*"
EXCLUDE="${CLAUDE_MEMORY_EXCLUDE:-}"

# Прогон самого sync-memory не пишет сам себя в очередь (иначе цикл).
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

# Причина отсева пишется в отдельный лог: без него фильтр не проверить,
# а молчаливый отсев однажды начнет съедать нужные сессии незаметно.
skip() {
    printf '%s|%s|%s|%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$SESSION_ID" "$1" "$CWD" >> "$SKIPLOG"
    if [ "$(wc -l < "$SKIPLOG" 2>/dev/null || echo 0)" -gt 300 ]; then
        tail -n 150 "$SKIPLOG" > "$SKIPLOG.tmp" 2>/dev/null && mv "$SKIPLOG.tmp" "$SKIPLOG"
    fi
    exit 0
}

# 1. Сам конфиг Claude Code и исключенные папки память не ведут.
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

# 2. Пустышка: транскрипта на диске нет - писать в память нечего.
[ -z "$TRANSCRIPT" ] && TRANSCRIPT="$CLAUDE_DIR/projects/$(echo "$CWD" | sed 's/[\/.]/-/g')/${SESSION_ID}.jsonl"
[ -f "$TRANSCRIPT" ] || skip "нет-транскрипта"

# 3. Служебный прогон самого /sync-memory - записывать нечего по определению.
head -c 20000 "$TRANSCRIPT" 2>/dev/null | grep -q '<command-name>/sync-memory' && skip "служебная-sync-memory"

# 4. Ни одной живой реплики пользователя (результаты инструментов и субагенты не в счет).
#    Порог именно ноль, а не "меньше двух": одноходовые ресерч-сессии дают
#    полноценные файлы памяти.
TURNS="$(grep '"type":"user"' "$TRANSCRIPT" 2>/dev/null | grep -v 'tool_result' | grep -vc '"isSidechain":true' || true)"
[ -z "$TURNS" ] && TURNS=0
[ "$TURNS" -lt 1 ] && skip "нет-реплик"

printf '%s|%s|%s\n' "$SESSION_ID" "$CWD" "$(date +%Y-%m-%dT%H:%M:%S)" >> "$QUEUE"
exit 0
