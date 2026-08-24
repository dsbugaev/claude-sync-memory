#!/usr/bin/env bash
# Claude Sync Memory - installs cross-session memory for Claude Code.
#
#   bash install.sh              interactive setup (recommended)
#   bash install.sh --yes        install everything with defaults, no questions
#   bash install.sh --update     pull the latest version and reinstall
#   bash install.sh --uninstall  remove everything this installed
#
# Installs into the profile from CLAUDE_CONFIG_DIR (~/.claude by default).

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

# Defaults; interactive mode asks about each of them.
DO_MEMORY=1
DO_QUEUE=1
DO_GUARD=1
DO_UPDATES=1
WARN=250000
HARD=400000
EXCLUDE="${CLAUDE_MEMORY_EXCLUDE:-}"

b() { printf '\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

command -v python3 >/dev/null || { echo "python3 is required. On macOS: xcode-select --install" >&2; exit 1; }

# --------------------------------------------------------------- uninstall ---
uninstall() {
  b "Removing Claude Sync Memory from $CLAUDE_DIR"
  python3 - "$SETTINGS" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
shutil.copy(path, path + ".bak-sync-memory")
try:
    s = json.load(open(path, encoding="utf-8"))
except Exception:
    print("  ! settings.json is not valid JSON, clean the hooks section by hand", file=sys.stderr)
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
print("  ✓ hooks removed from settings.json (backup alongside: .bak-sync-memory)")
PY
  rm -f "$CMD_FILE" "$AGENT_FILE" "$END_HOOK" "$START_HOOK" "$GUARD_HOOK"
  rm -rf "$HOME_DIR"
  ok "files deleted"
  dim "Your memory files are untouched - they live in $CLAUDE_DIR/projects/*/memory/"
  echo
  b "Done. Start a new Claude Code session."
  exit 0
}

# ------------------------------------------------------------------ update ---
do_update() {
  b "Updating Claude Sync Memory"
  local src was
  src="$(python3 -c "
import json,sys
try: print(json.load(open('$CONFIG',encoding='utf-8')).get('src',''))
except Exception: print('')
" 2>/dev/null)"
  [ -z "$src" ] && src="$SRC_DIR"
  # The installed version, captured before the pull overwrites it.
  was="$(python3 -c "
import json,sys
try: print(json.load(open('$CONFIG',encoding='utf-8')).get('version',''))
except Exception: print('')
" 2>/dev/null)"

  if git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    dim "source: $src (git)"
    git -C "$src" pull --ff-only --quiet && ok "sources updated" || warn "git pull failed, installing what is on disk"
  else
    warn "source is not a git repository - installing from $src as is"
  fi
  # Reinstall with the saved answers.
  SYNC_MEMORY_REINSTALL=1 bash "$src/install.sh" --yes

  # What changed, read from the changelog that just arrived. Printed last, because that is
  # where the eye lands after a wall of install output.
  if [ -n "$was" ] && [ -f "$src/CHANGELOG.md" ] && [ -f "$src/lib/changelog.sh" ]; then
    NEWS="$(bash "$src/lib/changelog.sh" "$src/CHANGELOG.md" "$was" 2>/dev/null || true)"
    if [ -n "$NEWS" ]; then
      echo
      b "New since $was"
      printf '%s\n' "$NEWS"
    else
      dim "Already on the newest version ($was)."
    fi
  fi
  exit 0
}

case "${1:-}" in
  --uninstall) uninstall ;;
  --update) do_update ;;
esac

NONINTERACTIVE=0
[ "${1:-}" = "--yes" ] && NONINTERACTIVE=1
[ -t 0 ] || NONINTERACTIVE=1

# Seeding is a first-install step. An update must not quietly queue more work.
FIRST_INSTALL=1
[ -f "$CONFIG" ] && FIRST_INSTALL=0

# Reinstall after an update - pick up the previous answers.
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

# ------------------------------------------------------------- setup dialog ---
ask() {  # ask "question" "default (y/n)" -> 0/1
  local q="$1" def="$2" a
  if [ "$NONINTERACTIVE" = "1" ]; then [ "$def" = "y" ] && return 0 || return 1; fi
  local hint="[Y/n]"; [ "$def" = "n" ] && hint="[y/N]"
  read -r -p "  $q $hint " a </dev/tty || a=""
  a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
  [ -z "$a" ] && a="$def"
  # Russian "yes" is accepted too - the first users type it out of habit.
  case "$a" in y|yes|д|да) return 0 ;; *) return 1 ;; esac
}

echo
b "Claude Sync Memory $VERSION"
dim "Cross-session memory for Claude Code: decisions, agreements and your preferences"
dim "move into files and are picked up by later sessions on their own."
echo
dim "Installing into: $CLAUDE_DIR"
echo

if [ "$NONINTERACTIVE" = "1" ]; then
  dim "Non-interactive mode - installing with the current settings, no questions."
  echo
else
  b "1. What to install"
  ask "Session memory: the /sync-memory command and the memory-keeper agent?" y && DO_MEMORY=1 || DO_MEMORY=0
  ask "Session queue: remind you at startup that some are unprocessed?" y && DO_QUEUE=1 || DO_QUEUE=0
  ask "Context guard: warn you when a conversation has grown large?" y && DO_GUARD=1 || DO_GUARD=0
  echo
fi

# --- derive the thresholds from the user's own sessions instead of guessing ---
if [ "$DO_GUARD" = "1" ] && [ "$NONINTERACTIVE" != "1" ]; then
  b "2. Context guard thresholds"
  dim "Measuring how large your sessions usually get..."
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
    dim "  looked at $S_N sessions: median $S_MED, p90 $S_P90, max $S_MAX tokens"
  else
    dim "  not enough sessions yet - using the defaults"
  fi
  dim "  Defaults: gentle warning at ${WARN}, insistent one at ${HARD}."
  if ask "Keep these thresholds?" y; then :; else
    read -r -p "  gentle warning, tokens [$WARN]: " a </dev/tty || a=""
    [ -n "$a" ] && WARN="$a"
    read -r -p "  insistent one, tokens [$HARD]: " a </dev/tty || a=""
    [ -n "$a" ] && HARD="$a"
  fi
  echo
fi

if [ "$DO_MEMORY" = "1" ] && [ "$NONINTERACTIVE" != "1" ]; then
  b "3. Excluded folders"
  dim "Any folders to keep no memory for (private notes, other people's repositories)?"
  dim "Colon-separated, wildcards allowed. Example: \$HOME/notes/*:\$HOME/secret*"
  read -r -p "  exclusions [${EXCLUDE:-none}]: " a </dev/tty || a=""
  [ -n "$a" ] && EXCLUDE="$a"
  echo
fi

if [ "$NONINTERACTIVE" != "1" ]; then
  b "4. Updates"
  ask "Check once a week whether a new version is out?" y && DO_UPDATES=1 || DO_UPDATES=0
  echo
fi

# ------------------------------------------------------------------ install ---
b "Installing"
mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/hooks" "$HOME_DIR"

if [ "$DO_MEMORY" = "1" ]; then
  cp "$SRC_DIR/commands/sync-memory.md" "$CMD_FILE"
  cp "$SRC_DIR/agents/memory-keeper.md" "$AGENT_FILE"
  ok "the /sync-memory command and the memory-keeper agent"
fi

if [ "$DO_QUEUE" = "1" ]; then
  cp "$SRC_DIR/hooks/session-end.sh" "$END_HOOK"
  cp "$SRC_DIR/hooks/session-start.sh" "$START_HOOK"
  chmod +x "$END_HOOK" "$START_HOOK"
  ok "session queue"
fi

if [ "$DO_GUARD" = "1" ]; then
  sed -e "s/__WARN__/$WARN/" -e "s/__HARD__/$HARD/" "$SRC_DIR/hooks/context-guard.py" > "$GUARD_HOOK"
  chmod +x "$GUARD_HOOK"
  ok "context guard (thresholds $WARN / $HARD)"
fi

# Seed the memory index for the home directory.
if [ "$DO_MEMORY" = "1" ]; then
  MUNGED="$(printf '%s' "$HOME" | sed 's/[\/.]/-/g')"
  MEM_DIR="$CLAUDE_DIR/projects/$MUNGED/memory"
  mkdir -p "$MEM_DIR"
  [ -f "$MEM_DIR/MEMORY.md" ] || cp "$SRC_DIR/templates/MEMORY.md" "$MEM_DIR/MEMORY.md"
  ok "memory folder: $MEM_DIR"
fi

# --- settings.json: careful merge, other keys and hooks stay untouched ---
python3 - "$SETTINGS" "$DO_QUEUE" "$DO_GUARD" "$END_HOOK" "$START_HOOK" "$GUARD_HOOK" "$EXCLUDE" <<'PY'
import json, os, shutil, sys
path, do_queue, do_guard, end_h, start_h, guard_h, exclude = sys.argv[1:8]
s = {}
if os.path.exists(path):
    shutil.copy(path, path + ".bak-sync-memory")
    try:
        s = json.load(open(path, encoding="utf-8"))
    except Exception:
        print("  ! settings.json is not valid JSON - fix it and run the install again", file=sys.stderr)
        sys.exit(1)

def put(event, matcher, cmd, timeout):
    groups = s.setdefault("hooks", {}).setdefault(event, [])
    for g in groups:
        for h in g.get("hooks", []):
            if os.path.basename(cmd) in h.get("command", ""):
                h["command"] = cmd
                h["timeout"] = timeout
                return "updated"
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
    if matcher is not None:
        entry["matcher"] = matcher
    groups.append(entry)
    return "added"

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
    print("  ✓ hook " + m)
if os.path.exists(path + ".bak-sync-memory"):
    print("  ✓ settings backup: %s.bak-sync-memory" % os.path.basename(path))
PY

# Keep a copy of the sources so --update and --uninstall work without the download.
if [ "$SRC_DIR" != "$HOME_DIR" ]; then
  rm -rf "$HOME_DIR/src"
  mkdir -p "$HOME_DIR/src"
  (cd "$SRC_DIR" && tar cf - --exclude .git . 2>/dev/null) | (cd "$HOME_DIR/src" && tar xf -)
fi

# Source for --update: a git checkout updates from itself, anything else falls back
# to our own copy (which can only be refreshed by hand).
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
  ok "weekly update check enabled"
else
  rm -f "$HOME_DIR/.update-available" "$HOME_DIR/.last-update-check"
fi

# ------------------------------------------------------- seed the first run ---
# A fresh install has an empty queue, so the first /sync-memory finds only the session
# that was just opened and writes nothing. The user concludes it does not work. Seeding
# the queue with a few substantial past sessions gives that first run something real.
if [ "$DO_MEMORY" = "1" ] && [ "$FIRST_INSTALL" = "1" ]; then
  CANDIDATES="$(python3 - "$CLAUDE_DIR" 3 "$EXCLUDE" <<'SEEDPY'
import fnmatch, glob, json, os, sys

claude_dir, want, exclude = sys.argv[1], int(sys.argv[2]), sys.argv[3]
patterns = [p for p in exclude.split(":") if p]

queued = set()
try:
    for line in open(os.path.join(claude_dir, "scripts", ".pending-memory.log"), encoding="utf-8"):
        parts = line.strip().split("|")
        if len(parts) >= 2:
            queued.add((parts[0], parts[1]))
except OSError:
    pass

files = glob.glob(os.path.join(claude_dir, "projects", "*", "*.jsonl"))
files.sort(key=lambda f: os.path.getmtime(f), reverse=True)

found = []
for path in files[:60]:
    sid = os.path.basename(path)[:-6]
    try:
        with open(path, "rb") as fh:
            if b"<command-name>/sync-memory" in fh.read(20000):
                continue
            fh.seek(0)
            raw = fh.read(3000000)
    except OSError:
        continue

    cwd, turns, stamp = "", 0, ""
    for line in raw.split(b"\n"):
        if not cwd and b'"cwd"' in line:
            try:
                cwd = json.loads(line).get("cwd") or ""
            except Exception:
                pass
        if b'"type":"user"' not in line or b"tool_result" in line or b'"isSidechain":true' in line:
            continue
        turns += 1
        if not stamp:
            try:
                stamp = (json.loads(line).get("timestamp") or "")[:10]
            except Exception:
                pass

    # Three turns is the same bar the agent uses to bother with a session at all.
    if turns < 3 or not cwd:
        continue
    if cwd.startswith(claude_dir) or any(fnmatch.fnmatch(cwd, pat) for pat in patterns):
        continue
    if (sid, cwd) in queued:
        continue
    found.append((turns, sid, cwd, stamp))

found.sort(reverse=True)
for turns, sid, cwd, stamp in found[:want]:
    print("%s|%s|%s|%s" % (sid, cwd, stamp, turns))
SEEDPY
)"

  if [ -n "$CANDIDATES" ]; then
    echo
    b "First run"
    dim "Nothing is queued yet, so a first /sync-memory would have nothing to chew on."
    dim "These past sessions look substantial enough to be worth distilling:"
    while IFS='|' read -r sid cwd stamp turns; do
      [ -z "$sid" ] && continue
      printf '    %-11s %-3s turns  %s\n' "${stamp:-?}" "$turns" "$cwd"
    done <<< "$CANDIDATES"
    dim "Processing them costs tokens, the same as any other work you ask Claude to do."
    if ask "Queue them, so your first /sync-memory has real material?" y; then
      mkdir -p "$CLAUDE_DIR/scripts"
      while IFS='|' read -r sid cwd stamp turns; do
        [ -z "$sid" ] && continue
        printf '%s|%s|%s\n' "$sid" "$cwd" "$(date +%Y-%m-%dT%H:%M:%S)" >> "$CLAUDE_DIR/scripts/.pending-memory.log"
      done <<< "$CANDIDATES"
      SEEDED="$(printf '%s\n' "$CANDIDATES" | grep -c . || true)"
      ok "queued $SEEDED session(s)"
    else
      SEEDED=0
      dim "  skipped - sessions you close from now on will queue themselves"
    fi
  fi
fi

# --------------------------------------------------------------- self-check ---
echo
b "Checking"
if [ "$DO_GUARD" = "1" ]; then
  LATEST="$(ls -t "$CLAUDE_DIR"/projects/*/*.jsonl 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ]; then
    OUT="$(printf '{"session_id":"selftest","transcript_path":"%s"}' "$LATEST" \
      | CLAUDE_CONTEXT_WARN=1 CLAUDE_CONTEXT_STEP=1 python3 "$GUARD_HOOK" 2>/dev/null || true)"
    rm -f "$CLAUDE_DIR/cache/context-guard-selftest" "$HOME/.claude/cache/context-guard-selftest"
    case "$OUT" in
      *systemMessage*) ok "context guard responds" ;;
      *) warn "guard stayed quiet - happens on a brand new transcript, nothing to worry about" ;;
    esac
  else
    dim "  no transcripts yet, will check the guard next time"
  fi
fi
{ [ "$DO_MEMORY" = "1" ] && [ -f "$CMD_FILE" ] && ok "/sync-memory command in place"; } || true
{ [ "$DO_QUEUE" = "1" ] && [ -x "$END_HOOK" ] && ok "queue hook is executable"; } || true
python3 -c "import json;json.load(open('$SETTINGS',encoding='utf-8'))" 2>/dev/null && ok "settings.json is valid" || warn "settings.json cannot be read - check it"

echo
b "Done."
dim "Start a new Claude Code session - hooks load at session start, no app restart needed."
echo
if [ "${SEEDED:-0}" -gt 0 ] 2>/dev/null; then
  echo "  Your first run - do it now, it takes a minute:"
  echo "    1. start a new Claude Code session (any folder)"
  echo "    2. run /sync-memory"
  echo
  echo "  It works through the $SEEDED queued session(s) and shows you what it wrote."
else
  echo "  How to use it:"
  echo "    /sync-memory   - process the session and write it into memory"
fi
echo
echo "  Update:     bash $HOME_DIR/src/install.sh --update"
echo "  Uninstall:  bash $HOME_DIR/src/install.sh --uninstall"
echo
