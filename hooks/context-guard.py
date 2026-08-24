#!/usr/bin/env python3
"""UserPromptSubmit hook: следит за размером контекста сессии.

Считает реальный размер контекста по последней записи usage в транскрипте
сессии и, когда он переваливает порог, просит модель предупредить и
зафиксировать состояние в файлах.

Пороги настраиваются через env:
  CLAUDE_CONTEXT_WARN  (по умолчанию 250000) - мягкое предупреждение
  CLAUDE_CONTEXT_HARD  (по умолчанию 400000) - настоятельное
  CLAUDE_CONTEXT_STEP  (по умолчанию 100000) - шаг повторного напоминания
"""
import json
import os
import sys

WARN = int(os.environ.get("CLAUDE_CONTEXT_WARN", "__WARN__"))
HARD = int(os.environ.get("CLAUDE_CONTEXT_HARD", "__HARD__"))
STEP = int(os.environ.get("CLAUDE_CONTEXT_STEP", "100000"))
TAIL_BYTES = 2_000_000


def bail():
    sys.exit(0)


try:
    payload = json.load(sys.stdin)
except Exception:
    bail()

path = payload.get("transcript_path") or ""
session_id = payload.get("session_id") or "unknown"
if not path or not os.path.exists(path):
    bail()

# Транскрипт бывает на сотни мегабайт - читаем только хвост.
try:
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        fh.seek(max(0, size - TAIL_BYTES))
        chunk = fh.read()
except OSError:
    bail()

used = 0
for line in reversed(chunk.split(b"\n")):
    if b'"usage"' not in line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    usage = (obj.get("message") or {}).get("usage") or {}
    if not usage:
        continue
    total = (
        (usage.get("input_tokens") or 0)
        + (usage.get("cache_read_input_tokens") or 0)
        + (usage.get("cache_creation_input_tokens") or 0)
    )
    if total > 0:
        used = total
        break

if used < WARN:
    bail()

# Не спамим на каждый промпт: напоминаем при эскалации или росте на STEP.
state_dir = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "cache"
)
state_file = os.path.join(state_dir, "context-guard-%s" % session_id)
last = 0
try:
    with open(state_file) as fh:
        last = int(fh.read().strip() or 0)
except Exception:
    last = 0

escalated = used >= HARD > last
if not escalated and used < last + STEP:
    bail()

try:
    os.makedirs(state_dir, exist_ok=True)
    with open(state_file, "w") as fh:
        fh.write(str(used))
except OSError:
    pass

k = round(used / 1000)
if used >= HARD:
    urgency = (
        "Контекст сессии ~%dk токенов - это уже много, качество работы падает. "
        "ПРЕЖДЕ чем брать в работу текущий запрос, настоятельно порекомендуй "
        "пользователю начать новую сессию." % k
    )
else:
    urgency = (
        "Контекст сессии ~%dk токенов. Если текущая задача на естественной границе "
        "(этап закончен, следующий шаг самостоятелен) - порекомендуй новую сессию." % k
    )

context = (
    "<context-budget>\n"
    + urgency
    + "\n\nКак предупреждать (одним абзацем, в начале ответа, без паникёрства):\n"
    "1. Назови текущий размер контекста (~%dk).\n"
    "2. Скажи, что именно уже зафиксировано в файлах, а что живёт только в этой переписке.\n"
    "3. Если несохранённое есть - предложи сначала запустить /sync-memory, чтобы "
    "решения и договорённости легли в файлы памяти и новая сессия поднялась без потерь.\n"
    "После предупреждения продолжай выполнять запрос пользователя как обычно - "
    "решение о новой сессии за ним.\n"
    "</context-budget>" % k
)

print(json.dumps({
    "systemMessage": "Контекст сессии: ~%dk токенов" % k,
    "suppressOutput": True,
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    },
}, ensure_ascii=False))
