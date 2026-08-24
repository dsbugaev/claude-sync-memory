#!/usr/bin/env bash
# Prints the changelog entries released after a given version.
#
#   changelog.sh <changelog-path|-> <from-version> [--version-only]
#
# With --version-only it prints just the newest version number, for the one-line
# "an update is out" notice. Reading from - takes the changelog on stdin, which is how
# the update check inspects the remote copy without pulling it.

set -uo pipefail

FILE="${1:-}"
FROM="${2:-0.0.0}"
MODE="${3:-full}"
[ -z "$FILE" ] && exit 1

if [ "$FILE" = "-" ]; then
    CONTENT="$(cat)"
else
    [ -f "$FILE" ] || exit 1
    CONTENT="$(cat "$FILE")"
fi

printf '%s' "$CONTENT" | python3 -c '
import re, sys

frm, mode = sys.argv[1], sys.argv[2]


def key(v):
    # Unparsable parts sort as 0 rather than blowing up: a changelog is documentation,
    # and a stray heading must not take the updater down with it.
    out = []
    for part in v.split("."):
        digits = re.match(r"\d+", part)
        out.append(int(digits.group()) if digits else 0)
    while len(out) < 3:
        out.append(0)
    return tuple(out[:3])


sections, current = [], None
for line in sys.stdin.read().splitlines():
    m = re.match(r"^##\s+v?(\d+(?:\.\d+)*)\b", line)
    if m:
        current = {"version": m.group(1), "lines": [line]}
        sections.append(current)
    elif current is not None:
        current["lines"].append(line)

newer = [s for s in sections if key(s["version"]) > key(frm)]

if mode == "--version-only":
    if sections:
        print(max((s["version"] for s in sections), key=key))
    sys.exit(0)

for s in newer:
    body = "\n".join(s["lines"]).rstrip()
    print(body)
    print()
' "$FROM" "$MODE"
