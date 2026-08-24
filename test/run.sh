#!/usr/bin/env bash
# Test suite for claude-sync-memory.
#
#   bash test/run.sh            run everything
#   bash test/run.sh settings   run only groups whose name matches
#
# Runs fully offline against throwaway CLAUDE_CONFIG_DIR profiles and local git repos.
# It never touches your real ~/.claude, your projects, or the network.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/csm-test.XXXXXX")"
# TMPDIR often ends in a slash, and the doubled separator that produces makes every
# prefix comparison against $(pwd) fail. Normalise once, here.
TMP="$(cd "$TMP" && pwd)"
FILTER="${1:-}"
PASS=0 FAIL=0 SKIP=0 GROUP="" CURRENT=""
FAILURES=()

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

group() {
    GROUP="$1"
    if [ -n "$FILTER" ] && [[ "$GROUP" != *"$FILTER"* ]]; then GROUP="__skip__"; return; fi
    printf '\n\033[1m%s\033[0m\n' "$1"
}
it() { CURRENT="$1"; }
skipping() { [ "$GROUP" = "__skip__" ]; }

pass() { PASS=$((PASS + 1)); printf '  %s %s\n' "$(green ✓)" "$CURRENT"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILURES+=("$GROUP / $CURRENT: $1")
    printf '  %s %s\n      %s\n' "$(red ✗)" "$CURRENT" "$(dim "$1")"
}

assert_contains() {
    case "$1" in *"$2"*) pass ;; *) fail "expected to contain: $2" ;; esac
}
assert_not_contains() {
    case "$1" in *"$2"*) fail "expected NOT to contain: $2" ;; *) pass ;; esac
}
assert_eq() {
    [ "$1" = "$2" ] && pass || fail "expected [$1], got [$2]"
}
assert_file() { [ -f "$1" ] && pass || fail "missing file: $1"; }
assert_no_file() { [ -f "$1" ] && fail "file should not exist: $1" || pass; }

# ---------------------------------------------------------------- fixtures ---

# make_transcript <path> <real-user-turns> [service]
# "service" marks it as a /sync-memory run, which every filter must reject.
make_transcript() {
    local path="$1" turns="$2" kind="${3:-normal}" i
    mkdir -p "$(dirname "$path")"
    : > "$path"
    if [ "$kind" = "service" ]; then
        printf '{"type":"user","cwd":"/Users/x/p","timestamp":"2026-08-01T10:00:00Z","isSidechain":false,"message":{"role":"user","content":"<command-name>/sync-memory</command-name>"}}\n' >> "$path"
    fi
    for ((i = 0; i < turns; i++)); do
        printf '{"type":"user","cwd":"%s","timestamp":"2026-08-01T10:0%d:00Z","isSidechain":false,"message":{"role":"user","content":"real question %d"}}\n' "${TRANSCRIPT_CWD:-/Users/x/p}" "$i" "$i" >> "$path"
    done
    # Noise every filter must ignore: tool results and subagent turns.
    printf '{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","content":"out"}]}}\n' >> "$path"
    printf '{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent"}}\n' >> "$path"
    printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":10,"cache_read_input_tokens":%d},"content":[{"type":"text","text":"reply"}]}}\n' "${TRANSCRIPT_TOKENS:-1000}" >> "$path"
}

# fresh_profile [name] -> prints the profile path
fresh_profile() {
    local p="$TMP/profile-${1:-$RANDOM}-$$-$PASS$FAIL"
    rm -rf "$p"; mkdir -p "$p"
    printf '%s' "$p"
}

install_into() {  # install_into <profile> [extra args...]
    local p="$1"; shift
    CLAUDE_CONFIG_DIR="$p" bash "$SRC/install.sh" --yes "$@" 2>&1
}

json_get() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1" 2>/dev/null; }

# ============================================================== settings.json ===
group "settings.json is merged, never overwritten"
if ! skipping; then
    P="$(fresh_profile settings)"
    cat > "$P/settings.json" <<'EOF'
{ "model": "opus", "env": { "FOO": "bar" },
  "hooks": { "SessionEnd": [ { "matcher": "", "hooks": [ { "type": "command", "command": "/other/hook.sh", "timeout": 7 } ] } ] } }
EOF
    OUT="$(install_into "$P")"

    it "keeps unrelated top-level keys"
    assert_eq "opus" "$(json_get "$P/settings.json" "['model']")"

    it "keeps unrelated env vars"
    assert_eq "bar" "$(json_get "$P/settings.json" "['env']['FOO']")"

    it "keeps someone else's hook in an event it also uses"
    assert_contains "$(cat "$P/settings.json")" "/other/hook.sh"

    it "adds its own three hooks"
    assert_eq "3" "$(python3 - "$P/settings.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
marks = ("sync-memory-session-end", "sync-memory-session-start", "context-guard.py")
print(sum(1 for ev in h.values() for g in ev for x in g["hooks"] if any(m in x["command"] for m in marks)))
PY
)"

    it "backs the previous settings up"
    assert_file "$P/settings.json.bak-sync-memory"

    it "reinstalling does not duplicate hook entries"
    install_into "$P" >/dev/null
    assert_eq "3" "$(python3 - "$P/settings.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
marks = ("sync-memory-session-end", "sync-memory-session-start", "context-guard.py")
print(sum(1 for ev in h.values() for g in ev for x in g["hooks"] if any(m in x["command"] for m in marks)))
PY
)"

    it "refuses to proceed on a broken settings.json"
    P2="$(fresh_profile broken)"
    printf 'not json at all' > "$P2/settings.json"
    OUT2="$(install_into "$P2")"
    assert_contains "$OUT2" "not valid JSON"

    it "leaves the broken file untouched"
    assert_eq "not json at all" "$(cat "$P2/settings.json")"
fi

# ================================================================= uninstall ===
group "uninstall removes only its own"
if ! skipping; then
    P="$(fresh_profile uninst)"
    cat > "$P/settings.json" <<'EOF'
{ "model": "opus", "hooks": { "SessionEnd": [ { "matcher": "", "hooks": [ { "type": "command", "command": "/other/hook.sh", "timeout": 7 } ] } ] } }
EOF
    install_into "$P" >/dev/null
    MEM="$P/projects/$(printf '%s' "$HOME" | sed 's/[\/.]/-/g')/memory"
    printf 'my memory\n' > "$MEM/kept.md"
    OUT="$(CLAUDE_CONFIG_DIR="$P" bash "$P/sync-memory/src/install.sh" --uninstall 2>&1)"

    it "drops its own hooks"
    assert_not_contains "$(cat "$P/settings.json")" "sync-memory-session-end"

    it "keeps the foreign hook"
    assert_contains "$(cat "$P/settings.json")" "/other/hook.sh"

    it "removes the command file"
    assert_no_file "$P/commands/sync-memory.md"

    it "never deletes memory files"
    assert_file "$MEM/kept.md"
fi

# ============================================================= queue filters ===
group "the queue takes real sessions and rejects the rest"
if ! skipping; then
    P="$(fresh_profile queue)"
    install_into "$P" >/dev/null
    HOOK="$P/scripts/sync-memory-session-end.sh"
    Q="$P/scripts/.pending-memory.log"
    : > "$Q"
    fire() {  # fire <session-id> <cwd> <transcript> [env assignments...]
        printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s"}' "$1" "$2" "$3" \
            | env CLAUDE_CONFIG_DIR="$P" ${4:-IGNORE=1} bash "$HOOK"
    }

    make_transcript "$TMP/live.jsonl" 2
    fire S-live /Users/x/p "$TMP/live.jsonl"
    it "queues a session with real user turns"
    assert_contains "$(cat "$Q")" "S-live"

    fire S-missing /Users/x/p "$TMP/does-not-exist.jsonl"
    it "rejects a session whose transcript never appeared"
    assert_not_contains "$(cat "$Q")" "S-missing"
    it "records why it rejected it"
    assert_contains "$(cat "$P/scripts/.session-end-skipped.log")" "no-transcript"

    make_transcript "$TMP/empty.jsonl" 0
    fire S-empty /Users/x/p "$TMP/empty.jsonl"
    it "rejects a session that is only tool results and subagents"
    assert_not_contains "$(cat "$Q")" "S-empty"

    make_transcript "$TMP/service.jsonl" 2 service
    fire S-service /Users/x/p "$TMP/service.jsonl"
    it "rejects a /sync-memory run so the queue cannot feed itself"
    assert_not_contains "$(cat "$Q")" "S-service"

    fire S-excluded /Users/x/notes/diary "$TMP/live.jsonl" "CLAUDE_MEMORY_EXCLUDE=/Users/x/notes/*"
    it "respects an excluded folder"
    assert_not_contains "$(cat "$Q")" "S-excluded"

    fire S-config "$P/some/dir" "$TMP/live.jsonl"
    it "never records sessions run inside the Claude config folder"
    assert_not_contains "$(cat "$Q")" "S-config"

    it "a single real turn is enough - one-shot research sessions count"
    make_transcript "$TMP/one.jsonl" 1
    fire S-one /Users/x/p "$TMP/one.jsonl"
    assert_contains "$(cat "$Q")" "S-one"
fi

# ========================================================= start-up reminder ===
group "the start-up reminder"
if ! skipping; then
    P="$(fresh_profile start)"
    install_into "$P" >/dev/null
    START="$P/scripts/sync-memory-session-start.sh"

    it "says nothing when the queue is empty"
    : > "$P/scripts/.pending-memory.log"
    assert_eq "" "$(cd "$TMP" && CLAUDE_CONFIG_DIR="$P" bash "$START")"

    it "reports the count when sessions are waiting"
    printf 'a|/Users/x/p|t\nb|/Users/x/q|t\n' > "$P/scripts/.pending-memory.log"
    assert_contains "$(cd "$TMP" && CLAUDE_CONFIG_DIR="$P" bash "$START")" "2"

    it "stays quiet inside the Claude config folder"
    mkdir -p "$P/sub"
    assert_eq "" "$(cd "$P/sub" && CLAUDE_CONFIG_DIR="$P" bash "$START")"
fi

# =================================================================== seeding ===
group "seeding the first run"
if ! skipping; then
    P="$(fresh_profile seed)"
    export TRANSCRIPT_CWD=/Users/x/big
    make_transcript "$P/projects/-Users-x-big/aaa.jsonl" 9
    export TRANSCRIPT_CWD=/Users/x/small
    make_transcript "$P/projects/-Users-x-small/bbb.jsonl" 1
    export TRANSCRIPT_CWD=/Users/x/svc
    make_transcript "$P/projects/-Users-x-svc/ccc.jsonl" 5 service
    unset TRANSCRIPT_CWD
    OUT="$(install_into "$P")"
    Q="$P/scripts/.pending-memory.log"

    it "queues a substantial past session"
    assert_contains "$(cat "$Q")" "aaa"

    it "skips sessions below the three-turn bar"
    assert_not_contains "$(cat "$Q")" "bbb"

    it "skips /sync-memory runs"
    assert_not_contains "$(cat "$Q")" "ccc"

    it "takes the working directory from inside the transcript"
    assert_contains "$(cat "$Q")" "/Users/x/big"

    it "states the token cost before asking"
    assert_contains "$OUT" "costs tokens"

    it "points at the first run in the closing message"
    assert_contains "$OUT" "Your first run"

    it "does not seed again when reinstalling"
    BEFORE="$(wc -l < "$Q")"
    install_into "$P" >/dev/null
    assert_eq "$BEFORE" "$(wc -l < "$Q")"

    it "respects exclusions"
    P2="$(fresh_profile seedx)"
    export TRANSCRIPT_CWD=/Users/x/notes/diary
    make_transcript "$P2/projects/-Users-x-notes-diary/ddd.jsonl" 9
    unset TRANSCRIPT_CWD
    CLAUDE_MEMORY_EXCLUDE='/Users/x/notes/*' install_into "$P2" >/dev/null
    assert_not_contains "$(cat "$P2/scripts/.pending-memory.log" 2>/dev/null || echo "")" "ddd"
fi

# ======================================================= memory dir resolver ===
group "memory folder resolution"
if ! skipping; then
    P="$(fresh_profile memdir)"
    RES="$SRC/lib/memory-dir.sh"
    R="$TMP/repo"; mkdir -p "$R/deep/nested"
    git init -q "$R" && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    PLAIN="$TMP/plain"; mkdir -p "$PLAIN"
    munged() { printf '%s' "$1" | sed 's/[\/.]/-/g'; }

    it "outside a repository the key is the folder itself"
    assert_eq "$P/projects/$(munged "$PLAIN")/memory" "$(CLAUDE_CONFIG_DIR="$P" bash "$RES" "$PLAIN")"

    it "inside a repository the key is the repository root"
    assert_eq "$P/projects/$(munged "$R")/memory" "$(CLAUDE_CONFIG_DIR="$P" bash "$RES" "$R/deep/nested")"

    it "a worktree resolves back to its main repository"
    git -C "$R" worktree add -q "$TMP/wt" -b feature 2>/dev/null
    R_PHYS="$(cd "$R" && pwd -P)"
    assert_eq "$P/projects/$(munged "$R_PHYS")/memory" "$(CLAUDE_CONFIG_DIR="$P" bash "$RES" "$TMP/wt")"

    it "keeps the path spelling the user typed, not the symlink-resolved one"
    LINKED="$TMP/linked"; ln -sfn "$R" "$LINKED"
    assert_eq "$P/projects/$(munged "$LINKED")/memory" "$(CLAUDE_CONFIG_DIR="$P" bash "$RES" "$LINKED")"

    it "a folder that already exists wins over the computed one"
    mkdir -p "$P/projects/$(munged "$R/deep/nested")/memory"
    assert_eq "$P/projects/$(munged "$R/deep/nested")/memory" "$(CLAUDE_CONFIG_DIR="$P" bash "$RES" "$R/deep/nested")"
fi

# ============================================================== update check ===
group "the weekly update check"
if ! skipping; then
    P="$(fresh_profile upd)"
    mkdir -p "$P/sync-memory"
    ORIGIN="$TMP/origin.git"; CLONE="$TMP/clone"
    git init -q --bare "$ORIGIN"
    git init -q "$TMP/seedrepo"
    ( cd "$TMP/seedrepo" && echo one > f && git add -A && git -c user.email=t@t -c user.name=t commit -qm one \
        && git remote add origin "$ORIGIN" && git push -q origin HEAD:refs/heads/main ) >/dev/null 2>&1
    git clone -q -b main "$ORIGIN" "$CLONE" 2>/dev/null
    printf '{"src":"%s","updates":true}\n' "$CLONE" > "$P/sync-memory/config.json"
    STAMP="$P/sync-memory/.last-update-check"
    FLAG="$P/sync-memory/.update-available"

    it "says nothing while the clone is current"
    echo 1787600000 > "$STAMP"
    CLAUDE_CONFIG_DIR="$P" bash "$SRC/update-check.sh"
    assert_no_file "$FLAG"

    it "keeps the weekly clock after a successful check"
    assert_eq "1787600000" "$(cat "$STAMP")"

    ( cd "$TMP/seedrepo" && echo two > f2 && git add -A && git -c user.email=t@t -c user.name=t commit -qm two \
        && git push -q origin HEAD:refs/heads/main ) >/dev/null 2>&1

    it "raises a flag once the clone falls behind"
    CLAUDE_CONFIG_DIR="$P" bash "$SRC/update-check.sh"
    assert_file "$FLAG"

    it "names how far behind it is"
    assert_contains "$(cat "$FLAG")" "1"

    it "the reminder surfaces the flag at the next session start"
    install_into "$P" >/dev/null
    printf '{"src":"%s","updates":true}\n' "$CLONE" > "$P/sync-memory/config.json"
    echo "an update is available (1 new commits)" > "$FLAG"
    assert_contains "$(cd "$TMP" && CLAUDE_CONFIG_DIR="$P" bash "$P/scripts/sync-memory-session-start.sh")" "--update"

    it "clears the flag once the clone catches up"
    git -C "$CLONE" pull -q --ff-only
    echo 1787600000 > "$STAMP"
    CLAUDE_CONFIG_DIR="$P" bash "$SRC/update-check.sh"
    assert_no_file "$FLAG"

    it "a failed fetch rewinds the clock instead of burning the week"
    git -C "$CLONE" remote set-url origin file:///nonexistent/repo.git
    echo 1787600000 > "$STAMP"
    CLAUDE_CONFIG_DIR="$P" bash "$SRC/update-check.sh"
    assert_no_file "$STAMP"

    it "a detached HEAD is not treated as a transient fault"
    git -C "$CLONE" remote set-url origin "$ORIGIN"
    git -C "$CLONE" checkout -q --detach HEAD
    echo 1787600000 > "$STAMP"
    CLAUDE_CONFIG_DIR="$P" bash "$SRC/update-check.sh"
    assert_eq "1787600000" "$(cat "$STAMP" 2>/dev/null)"
fi

# ============================================================= context guard ===
group "the context guard"
if ! skipping; then
    P="$(fresh_profile guard)"
    install_into "$P" >/dev/null
    G="$P/hooks/context-guard.py"
    export TRANSCRIPT_TOKENS=300000
    make_transcript "$TMP/heavy.jsonl" 2
    export TRANSCRIPT_TOKENS=1000
    make_transcript "$TMP/light.jsonl" 2
    unset TRANSCRIPT_TOKENS
    ring() { printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | env CLAUDE_CONFIG_DIR="$P" ${3:-IGNORE=1} python3 "$G"; }

    it "stays silent on a light session"
    assert_eq "" "$(ring light "$TMP/light.jsonl")"

    it "speaks up once the context is heavy"
    assert_contains "$(ring heavy "$TMP/heavy.jsonl")" "systemMessage"

    it "does not repeat itself on the very next prompt"
    assert_eq "" "$(ring heavy "$TMP/heavy.jsonl")"

    it "gets insistent past the hard threshold"
    assert_contains "$(ring hard "$TMP/heavy.jsonl" "CLAUDE_CONTEXT_HARD=200000")" "strongly recommend"

    it "sends the user to /sync-memory for anything uncaptured"
    assert_contains "$(ring advice "$TMP/heavy.jsonl")" "/sync-memory"

    it "asks for the warning in the user's own language"
    assert_contains "$(ring lang "$TMP/heavy.jsonl")" "language the user is speaking"

    it "stays silent when the transcript is unreadable"
    assert_eq "" "$(ring gone "$TMP/nowhere.jsonl")"
fi

# ================================================================= changelog ===
group "the changelog reader"
if ! skipping; then
    CL="$SRC/lib/changelog.sh"
    F="$TMP/CHANGELOG.md"
    cat > "$F" <<'EOF'
# Changelog

## 2.0.0 - 2026-01-03

- big one

## 1.10.0 - 2026-01-02

- ten beats two

## 1.2.0 - 2026-01-01

- older
EOF

    it "returns only what came after the version you have"
    OUT="$(bash "$CL" "$F" 1.2.0)"
    assert_contains "$OUT" "2.0.0"

    it "leaves out what you already have"
    assert_not_contains "$OUT" "1.2.0 - 2026"

    it "orders by number, not by string - 1.10 is newer than 1.2"
    assert_contains "$(bash "$CL" "$F" 1.2.0)" "1.10.0"

    it "says nothing when you are already current"
    assert_eq "" "$(bash "$CL" "$F" 2.0.0)"

    it "names the newest version for the one-line notice"
    assert_eq "2.0.0" "$(bash "$CL" "$F" 0.0.0 --version-only)"

    it "reads from stdin, so the remote copy can be checked without pulling it"
    assert_eq "2.0.0" "$(cat "$F" | bash "$CL" - 0.0.0 --version-only)"

    it "survives a heading that is not a version"
    printf '\n## Unreleased\n\n- wip\n' >> "$F"
    assert_contains "$(bash "$CL" "$F" 1.2.0)" "2.0.0"

    it "the shipped changelog parses and knows the current version"
    assert_eq "$(cat "$SRC/VERSION")" "$(bash "$CL" "$SRC/CHANGELOG.md" 0.0.0 --version-only)"
fi

# ==================================================================== report ===
printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf '\033[1m%s\033[0m  %d passed\n' "$(green "All good.")" "$PASS"
else
    printf '\033[1m%s\033[0m  %d passed, %d failed\n\n' "$(red "Failures.")" "$PASS" "$FAIL"
    for f in "${FAILURES[@]}"; do printf '  %s\n' "$f"; done
fi
[ "$SKIP" -gt 0 ] && printf '  %d skipped\n' "$SKIP"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
