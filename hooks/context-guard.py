#!/usr/bin/env python3
"""UserPromptSubmit hook: watches how large the session context has grown.

Reads the real context size from the last usage record in the session transcript and,
once it crosses a threshold, asks the model to warn the user and to get the current
state written into files.

Thresholds are set through the environment:
  CLAUDE_CONTEXT_WARN  (default 250000) - gentle warning
  CLAUDE_CONTEXT_HARD  (default 400000) - insistent one
  CLAUDE_CONTEXT_STEP  (default 100000) - how much growth before reminding again
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

# A transcript can run to hundreds of megabytes - read only the tail.
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

# Do not fire on every prompt: remind on escalation or after STEP more tokens.
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
        "This session's context is ~%dk tokens - that is a lot, and answer quality "
        "degrades from here. BEFORE you act on the current request, strongly recommend "
        "that the user start a fresh session." % k
    )
else:
    urgency = (
        "This session's context is ~%dk tokens. If the work is at a natural boundary "
        "(a stage just finished, the next step stands on its own), suggest a fresh "
        "session." % k
    )

context = (
    "<context-budget>\n"
    + urgency
    + "\n\nHow to warn (one paragraph, at the top of your reply, no alarm):\n"
    "1. State the current context size (~%dk).\n"
    "2. Say what is already captured in files and what exists only in this conversation.\n"
    "3. If anything is uncaptured, offer to run /sync-memory first, so decisions and "
    "agreements land in the memory files and a fresh session starts with nothing lost.\n"
    "Write the warning in the language the user is speaking. After it, carry on with "
    "their request as usual - starting a new session is their call.\n"
    "</context-budget>" % k
)

print(json.dumps({
    "systemMessage": "Session context: ~%dk tokens" % k,
    "suppressOutput": True,
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    },
}, ensure_ascii=False))
