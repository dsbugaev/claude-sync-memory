#!/usr/bin/env bash
# Claude Sync Memory - установка памяти между сессиями для Claude Code.
#
#   bash install.sh              интерактивная настройка (рекомендуется)
#   bash install.sh --yes        поставить все с дефолтами, без вопросов
#   bash install.sh --update     обновиться до свежей версии и переустановить
#   bash install.sh --uninstall  снять все, что ставили
#
# Ставится в профиль из CLAUDE_CONFIG_DIR (по умолчанию ~/.claude).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOME_DIR="$CLAUDE_DIR/sync-memory"
CONFIG="$HOME_DIR/config.json"
SETTINGS="$CLAUDE_DIR/settings.json"
VERSION="$(cat "$SRC_DIR/VERSION" 2>/dev/null || echo "0.0.0")"

CMD_FILE="$CLAUDE_DIR/commands/sync-memory.md"
AGENT_FILE="$CLAUDE_DIR/agents/memory-keeper.md"
END_HOOK="$CLAUDE_DIR/scripts/sync-memory-session-end.sh"
START_HOOK="$CLAUDE_DIR/scripts/sync-memory-session-start.sh"
GUARD_HOOK="$CLAUDE_DIR/hooks/context-guard.py"

# Дефолты; интерактивный режим их переспросит.
DO_MEMORY=1
DO_QUEUE=1
DO_GUARD=1
DO_UPDATES=1
WARN=250000
HARD=400000
EXCLUDE=""

b() { printf '\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

command -v python3 >/dev/null || { echo "Нужен python3. На macOS: xcode-select --install" >&2; exit 1; }

# ---------------------------------------------------------------- удаление ---
uninstall() {
  b "Снимаю Claude Sync Memory из $CLAUDE_DIR"
  python3 - "$SETTINGS" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
shutil.copy(path, path + ".bak-sync-memory")
try:
    s = json.load(open(path, encoding="utf-8"))
except Exception:
    print("  ! settings.json невалиден, руками почисти секцию hooks", file=sys.stderr)
    sys.exit(0)
marks = ("sync-memory-session-end", "sync-memory-session-start", "context-guard.py")
hooks = s.get("hooks", {})
for event in list(hooks):
    groups = hooks.get(event) or []
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if not any(m in h.get("command", "") for m in marks)]
    hooks[event] = [g for g in groups if g.get("hooks")]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    s.pop("hooks", None)
else:
    s["hooks"] = hooks
json.dump(s, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print("  ✓ хуки убраны из settings.json (бэкап рядом: .bak-sync-memory)")
PY
  rm -f "$CMD_FILE" "$AGENT_FILE" "$END_HOOK" "$START_HOOK" "$GUARD_HOOK"
  rm -rf "$HOME_DIR"
  ok "файлы удалены"
  dim "Сами файлы памяти не тронуты - они в $CLAUDE_DIR/projects/*/memory/"
  echo
  b "Готово. Начни новую сессию Claude Code."
  exit 0
}

# ------------------------------------------------------------- обновление ---
do_update() {
  b "Обновление Claude Sync Memory"
  local src
  src="$(python3 -c "
import json,sys
try: print(json.load(open('$CONFIG',encoding='utf-8')).get('src',''))
except Exception: print('')
" 2>/dev/null)"
  [ -z "$src" ] && src="$SRC_DIR"

  if git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    dim "источник: $src (git)"
    git -C "$src" pull --ff-only --quiet && ok "исходники обновлены" || warn "git pull не прошел, ставлю что есть"
  else
    warn "источник не git-репозиторий - обновляю из $src как есть"
  fi
  # Переустановка с сохраненными ответами.
  SYNC_MEMORY_REINSTALL=1 bash "$src/install.sh" --yes
  exit 0
}

case "${1:-}" in
  --uninstall) uninstall ;;
  --update) do_update ;;
esac

NONINTERACTIVE=0
[ "${1:-}" = "--yes" ] && NONINTERACTIVE=1
[ -t 0 ] || NONINTERACTIVE=1

# Переустановка после обновления - забираем прошлые ответы.
if [ -f "$CONFIG" ]; then
  eval "$(python3 - "$CONFIG" <<'PY'
import json, sys, shlex
try:
    c = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
m = {"DO_MEMORY": "memory", "DO_QUEUE": "queue", "DO_GUARD": "guard", "DO_UPDATES": "updates"}
for var, key in m.items():
    if key in c:
        print("%s=%d" % (var, 1 if c[key] else 0))
for var, key in (("WARN", "warn"), ("HARD", "hard")):
    if key in c:
        print("%s=%d" % (var, int(c[key])))
if c.get("exclude"):
    print("EXCLUDE=%s" % shlex.quote(c["exclude"]))
PY
)"
fi

# --------------------------------------------------------- диалог настройки ---
ask() {  # ask "вопрос" "да|нет по умолчанию (y/n)" -> 0/1
  local q="$1" def="$2" a
  if [ "$NONINTERACTIVE" = "1" ]; then [ "$def" = "y" ] && return 0 || return 1; fi
  local hint="[Y/n]"; [ "$def" = "n" ] && hint="[y/N]"
  read -r -p "  $q $hint " a </dev/tty || a=""
  a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
  [ -z "$a" ] && a="$def"
  case "$a" in y|yes|д|да) return 0 ;; *) return 1 ;; esac
}

echo
b "Claude Sync Memory $VERSION"
dim "Память между сессиями Claude Code: решения, договоренности, твои предпочтения"
dim "переезжают в файлы и подхватываются в следующих сессиях сами."
echo
dim "Профиль установки: $CLAUDE_DIR"
echo

if [ "$NONINTERACTIVE" = "1" ]; then
  dim "Неинтерактивный режим - ставлю с текущими настройками, вопросов не будет."
  echo
else
  b "1. Что поставить"
  ask "Память сессий: команда /sync-memory и агент memory-keeper?" y && DO_MEMORY=1 || DO_MEMORY=0
  ask "Очередь сессий: напоминать на старте, что есть неразобранные?" y && DO_QUEUE=1 || DO_QUEUE=0
  ask "Сторож контекста: предупреждать, когда диалог разросся?" y && DO_GUARD=1 || DO_GUARD=0
  echo
fi

# --- пороги контекста считаем по его же сессиям, а не берем с потолка ---
if [ "$DO_GUARD" = "1" ] && [ "$NONINTERACTIVE" != "1" ]; then
  b "2. Пороги сторожа контекста"
  dim "Смотрю, насколько большими выходят твои сессии..."
  STATS="$(python3 - "$CLAUDE_DIR" <<'PY'
import glob, json, os, sys
peaks = []
files = sorted(glob.glob(os.path.join(sys.argv[1], "projects", "*", "*.jsonl")),
               key=lambda p: os.path.getmtime(p), reverse=True)[:120]
for f in files:
    peak = 0
    try:
        size = os.path.getsize(f)
        with open(f, "rb") as fh:
            fh.seek(max(0, size - 2_000_000))
            for line in fh.read().split(b"\n"):
                if b'"usage"' not in line:
                    continue
                try:
                    u = (json.loads(line).get("message") or {}).get("usage") or {}
                except Exception:
                    continue
                t = ((u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
                     + (u.get("cache_creation_input_tokens") or 0))
                peak = max(peak, t)
    except Exception:
        continue
    if peak:
        peaks.append(peak)
if len(peaks) < 5:
    print("")
    sys.exit(0)
peaks.sort()
med = peaks[len(peaks) // 2]
p90 = peaks[int(len(peaks) * 0.9)]
print("%d %d %d %d" % (len(peaks), med, p90, peaks[-1]))
PY
)"
  if [ -n "$STATS" ]; then
    read -r S_N S_MED S_P90 S_MAX <<< "$STATS"
    dim "  посмотрел $S_N сессий: медиана $S_MED, p90 $S_P90, максимум $S_MAX токенов"
  else
    dim "  сессий пока мало - беру значения по умолчанию"
  fi
  dim "  Дефолт: мягкое предупреждение на ${WARN}, настойчивое на ${HARD}."
  if ask "Оставить эти пороги?" y; then :; else
    read -r -p "  мягкое предупреждение, токенов [$WARN]: " a </dev/tty || a=""
    [ -n "$a" ] && WARN="$a"
    read -r -p "  настойчивое, токенов [$HARD]: " a </dev/tty || a=""
    [ -n "$a" ] && HARD="$a"
  fi
  echo
fi

if [ "$DO_QUEUE" = "1" ] && [ "$NONINTERACTIVE" != "1" ]; then
  b "3. Папки-исключения"
  dim "Есть папки, по которым память вести не надо (личные заметки, чужие репозитории)?"
  dim "Через двоеточие, можно со звездочкой. Пример: \$HOME/notes/*:\$HOME/secret*"
  read -r -p "  исключения [${EXCLUDE:-нет}]: " a </dev/tty || a=""
  [ -n "$a" ] && EXCLUDE="$a"
  echo
fi

if [ "$NONINTERACTIVE" != "1" ]; then
  b "4. Обновления"
  ask "Проверять раз в неделю, не вышла ли новая версия?" y && DO_UPDATES=1 || DO_UPDATES=0
  echo
fi

# --------------------------------------------------------------- установка ---
b "Ставлю"
mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/hooks" "$HOME_DIR"

if [ "$DO_MEMORY" = "1" ]; then
  cp "$SRC_DIR/commands/sync-memory.md" "$CMD_FILE"
  cp "$SRC_DIR/agents/memory-keeper.md" "$AGENT_FILE"
  ok "команда /sync-memory и агент memory-keeper"
fi

if [ "$DO_QUEUE" = "1" ]; then
  cp "$SRC_DIR/hooks/session-end.sh" "$END_HOOK"
  cp "$SRC_DIR/hooks/session-start.sh" "$START_HOOK"
  chmod +x "$END_HOOK" "$START_HOOK"
  ok "очередь сессий"
fi

if [ "$DO_GUARD" = "1" ]; then
  sed -e "s/__WARN__/$WARN/" -e "s/__HARD__/$HARD/" "$SRC_DIR/hooks/context-guard.py" > "$GUARD_HOOK"
  chmod +x "$GUARD_HOOK"
  ok "сторож контекста (пороги $WARN / $HARD)"
fi

# Затравка файла памяти для домашней директории.
if [ "$DO_MEMORY" = "1" ]; then
  MUNGED="$(printf '%s' "$HOME" | sed 's/[\/.]/-/g')"
  MEM_DIR="$CLAUDE_DIR/projects/$MUNGED/memory"
  mkdir -p "$MEM_DIR"
  [ -f "$MEM_DIR/MEMORY.md" ] || cp "$SRC_DIR/templates/MEMORY.md" "$MEM_DIR/MEMORY.md"
  ok "папка памяти: $MEM_DIR"
fi

# --- settings.json: аккуратный merge, чужие ключи и хуки не трогаем ---
python3 - "$SETTINGS" "$DO_QUEUE" "$DO_GUARD" "$END_HOOK" "$START_HOOK" "$GUARD_HOOK" "$EXCLUDE" <<'PY'
import json, os, shutil, sys
path, do_queue, do_guard, end_h, start_h, guard_h, exclude = sys.argv[1:8]
s = {}
if os.path.exists(path):
    shutil.copy(path, path + ".bak-sync-memory")
    try:
        s = json.load(open(path, encoding="utf-8"))
    except Exception:
        print("  ! settings.json невалиден - почини его и запусти установку заново", file=sys.stderr)
        sys.exit(1)

def put(event, matcher, cmd, timeout):
    groups = s.setdefault("hooks", {}).setdefault(event, [])
    for g in groups:
        for h in g.get("hooks", []):
            if os.path.basename(cmd) in h.get("command", ""):
                h["command"] = cmd
                h["timeout"] = timeout
                return "обновлен"
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
    if matcher is not None:
        entry["matcher"] = matcher
    groups.append(entry)
    return "подключен"

msgs = []
if do_queue == "1":
    msgs.append("SessionEnd %s" % put("SessionEnd", "", end_h, 10))
    msgs.append("SessionStart %s" % put("SessionStart", "startup|resume", start_h, 5))
if do_guard == "1":
    msgs.append("UserPromptSubmit %s" % put("UserPromptSubmit", None, "python3 " + guard_h, 10))

if exclude:
    s.setdefault("env", {})["CLAUDE_MEMORY_EXCLUDE"] = exclude
elif isinstance(s.get("env"), dict):
    s["env"].pop("CLAUDE_MEMORY_EXCLUDE", None)
    if not s["env"]:
        del s["env"]

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
json.dump(s, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
for m in msgs:
    print("  ✓ хук " + m)
if os.path.exists(path + ".bak-sync-memory"):
    print("  ✓ бэкап настроек: %s.bak-sync-memory" % os.path.basename(path))
PY

# Исходники к себе - чтобы --update и --uninstall работали без скачанной папки.
if [ "$SRC_DIR" != "$HOME_DIR" ]; then
  rm -rf "$HOME_DIR/src"
  mkdir -p "$HOME_DIR/src"
  (cd "$SRC_DIR" && tar cf - --exclude .git . 2>/dev/null) | (cd "$HOME_DIR/src" && tar xf -)
fi

# Источник для --update: если ставили из git-чекаута, обновляемся из него,
# иначе из собственной копии (ее обновить можно только руками).
if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  CFG_SRC="$SRC_DIR"
else
  CFG_SRC="$HOME_DIR/src"
fi

python3 - "$CONFIG" "$DO_MEMORY" "$DO_QUEUE" "$DO_GUARD" "$DO_UPDATES" "$WARN" "$HARD" "$EXCLUDE" "$CFG_SRC" "$VERSION" <<'PY'
import json, os, sys
(cfg, mem, queue, guard, upd, warn, hard, exclude, src, version) = sys.argv[1:11]
os.makedirs(os.path.dirname(cfg), exist_ok=True)
json.dump({
    "version": version, "src": src,
    "memory": mem == "1", "queue": queue == "1", "guard": guard == "1",
    "updates": upd == "1", "warn": int(warn), "hard": int(hard), "exclude": exclude,
}, open(cfg, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY

if [ "$DO_UPDATES" = "1" ]; then
  ok "еженедельная проверка обновлений включена"
else
  rm -f "$HOME_DIR/.update-available" "$HOME_DIR/.last-update-check"
fi

# ------------------------------------------------------------ самопроверка ---
echo
b "Проверяю"
if [ "$DO_GUARD" = "1" ]; then
  LATEST="$(ls -t "$CLAUDE_DIR"/projects/*/*.jsonl 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ]; then
    OUT="$(printf '{"session_id":"selftest","transcript_path":"%s"}' "$LATEST" \
      | CLAUDE_CONTEXT_WARN=1 CLAUDE_CONTEXT_STEP=1 python3 "$GUARD_HOOK" 2>/dev/null || true)"
    rm -f "$CLAUDE_DIR/cache/context-guard-selftest" "$HOME/.claude/cache/context-guard-selftest"
    case "$OUT" in
      *systemMessage*) ok "сторож контекста отвечает" ;;
      *) warn "сторож промолчал - бывает на совсем свежем транскрипте, не страшно" ;;
    esac
  else
    dim "  транскриптов еще нет, сторожа проверю в следующий раз"
  fi
fi
{ [ "$DO_MEMORY" = "1" ] && [ -f "$CMD_FILE" ] && ok "команда /sync-memory на месте"; } || true
{ [ "$DO_QUEUE" = "1" ] && [ -x "$END_HOOK" ] && ok "хук очереди исполняемый"; } || true
python3 -c "import json;json.load(open('$SETTINGS',encoding='utf-8'))" 2>/dev/null && ok "settings.json валиден" || warn "settings.json не читается - проверь его"

echo
b "Готово."
dim "Начни новую сессию Claude Code - хуки подхватываются при старте, перезапуск приложения не нужен."
echo
echo "  Как пользоваться:"
echo "    /sync-memory   - разобрать сессию и записать в память"
echo
echo "  Обновиться:  bash $HOME_DIR/src/install.sh --update"
echo "  Снять:       bash $HOME_DIR/src/install.sh --uninstall"
echo
