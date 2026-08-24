# Claude Sync Memory

Cross-session memory for Claude Code. Decisions, agreements and your preferences move out
of the conversation and into files, and later sessions pick them up on their own.

Plus a context guard: it warns you when a conversation has outgrown its usefulness and it
is time to start a fresh one, before answer quality slides.

[Русская версия](README.ru.md)

## Why

Claude Code remembers across sessions already - see the next section for how this differs.
What it does not do is guarantee that anything got written down. Memory is produced by the
same model that is busy with your task, mid-flight, from a conversation that has not ended
yet. A session where the work went sideways for two hours and then landed is exactly the
one it summarises worst, because the ending had not happened yet.

Sessions also pile up. There is no way to merge them, and nothing tells you which ones were
never distilled.

This is the loop this adds: a finished session lands in a queue, you run `/sync-memory`, and
a separate agent reads the whole transcript after the fact and files away what survived.
Claude Code loads those files the next time you work in the same repository.

## How this differs from Claude Code's built-in memory

Claude Code already has auto-memory: it writes notes as the session goes, into the same
`MEMORY.md` index and topic files next to it. The format is the same, so this is not a
replacement - it is a layer on top.

The difference is when the writing happens. Built-in memory decides what to remember while
the work is in progress, using the same model and the same context that is busy with the
task. Here the pass happens after the session, over the full transcript, by a separate
agent: it can see how things ended, which decisions survived and which were reversed half
an hour later. On top of that you get the queue, so no session slips through, and routing -
what belongs in shared memory versus the repository's `docs/`.

Both can run at once; they write to the same files.

## What gets installed

Three parts, each optional.

1. **Session memory.** The `/sync-memory` command and the `memory-keeper` agent that reads
   a transcript and writes the files. This is the core.
2. **Session queue.** A closed session is recorded in a queue, and at the start of the next
   one you see a line like "3 unprocessed sessions" - so you do not forget to run the pass.
   Blank sessions (window opened and closed) never reach the queue.
3. **Context guard.** Watches the size of the conversation and, past a threshold, asks
   Claude to warn you and offer to capture anything unsaved first.

## Install

```bash
git clone https://github.com/dsbugaev/claude-sync-memory.git
cd claude-sync-memory
bash install.sh
```

The installer asks a few questions: what to install, what thresholds the context guard
should use (it measures your past sessions and shows you how large they actually run),
whether any folders should be excluded, and whether to check for updates.

At the end it offers to queue your most substantial recent sessions. Take it: on a fresh
install the queue is empty, so a first `/sync-memory` would find only the session you just
opened and write nothing at all - which reads exactly like a broken tool. With a few real
sessions queued, the first run produces something you can judge. It only happens on the
first install; updates never queue work behind your back.

Install everything with defaults and no questions:

```bash
bash install.sh --yes
```

Install from the clone: that is what lets `--update` fetch new versions for you. A
downloaded archive works exactly the same, but updating becomes a manual job.

Requires `python3`. On macOS: `xcode-select --install`.
Nothing is destroyed on install: `settings.json` is merged, and the previous version is
kept alongside as `settings.json.bak-sync-memory`.

Afterwards just start a new Claude Code session. No app restart: hooks are read at the
start of every session.

## Using it

One command:

```
/sync-memory
```

Run it when you wrap up, or when the queue has piled up. The agent processes the current
session plus every unprocessed one in the queue, and shows you a list of what it wrote.

You can aim it:

```
/sync-memory only record the decision about payments
```

## Where it writes

**Memory files** go into the Claude Code profile, in a folder per working directory:
`~/.claude/projects/<folder>/memory/`. One fact per small file, with `MEMORY.md` next to
them as the index. Claude Code loads them by itself.

Four types: who you are, how to work with you, what work is in flight, and pointers to
external resources. Memory is written in the language you work in.

**Project docs**: when you work inside a git repository, the agent additionally keeps
`docs/STATUS.md` (where the work stands), `docs/DECISIONS.md` (decisions with rationale),
`docs/GLOSSARY.md` (terms) and `docs/RECENT.md` (a short session log). It follows whatever
convention the repository already uses, commits only the files it wrote by name, and never
pushes. Your own uncommitted work is left alone.

What it will not write: secrets, ephemera like "opened such-and-such file", paths and
function names (they go stale faster than memory refreshes), and anything already visible
in the code.

## Updating

With the update check on, once a week it quietly looks for a newer version and, at session
start, prints a line offering to update. It never installs anything by itself.

```bash
bash install.sh --update
```

## Removing

```bash
bash install.sh --uninstall
```

Takes its own hooks out of the settings (leaves everyone else's alone) and deletes its own
files. Your memory files stay - they are yours.

## Settings

The context guard thresholds can be changed after install with environment variables:

| Variable | Default | What it does |
|---|---|---|
| `CLAUDE_CONTEXT_WARN` | 250000 | gentle warning, in tokens |
| `CLAUDE_CONTEXT_HARD` | 400000 | insistent warning |
| `CLAUDE_CONTEXT_STEP` | 100000 | growth before reminding again, so it does not nag |
| `CLAUDE_MEMORY_EXCLUDE` | empty | folders to keep no memory for, colon-separated |

## What is inside

```
commands/sync-memory.md    the /sync-memory command
agents/memory-keeper.md    the agent that reads a session and writes the files
hooks/session-end.sh       queues a finished session
hooks/session-start.sh     reminds about the queue and about updates
hooks/context-guard.py     watches the context size
templates/MEMORY.md        seed for the memory index
install.sh                 install, update, uninstall
```

Tested on macOS. On Windows it needs WSL: the hooks are ordinary bash scripts.

## FAQ

**Will it read my conversations?** Session transcripts are already on your disk; the agent
reads those and only those, locally. Nothing leaves your machine.

**What if it records nonsense?** Memory files are plain Markdown. Open them, delete the
line, done.

**How many sessions does it handle at once?** The queue is drained in one pass, one agent
per project. Blank and service sessions are filtered out before any of them start.

**Do I need to run it every day?** No. The queue waits and the reminder shows up at session
start. The natural moment is when you finish a chunk of work.

MIT.
