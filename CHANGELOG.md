# Changelog

Newest first. The `--update` command prints everything released since the version you have.

## 0.6.0 - 2026-08-25

- This changelog, and `--update` now prints everything released since the version you had.
- The weekly notice names the version instead of counting commits: "version 0.6.0 is out,
  you have 0.3.0" rather than "5 new commits", which told you nothing.

## 0.5.0 - 2026-08-25

- A test suite: `bash test/run.sh`. 51 checks, offline, against throwaway profiles and local
  git repositories. Covers the settings merge, uninstall scope, every queue filter, the
  seeding gates, memory-folder resolution, the update check and the context guard.
- **Fixed: memory could land in a folder Claude Code never reads.** The resolver took git's
  answer verbatim, which is symlink-resolved, while Claude Code keys the folder by the path
  string it was launched with. On macOS that string usually runs through `/var` ->
  `/private/var`, so one repository became two memory folders.
- Memory-folder resolution moved out of the agent's prompt into `lib/memory-dir.sh`, where
  tests can reach it. It had already been wrong once as prose.

## 0.4.1 - 2026-08-25

- **Fixed: a failed update check burned the whole week.** The weekly clock was stamped before
  the check ran, so a machine that happened to be offline waited seven days for the next
  attempt. A failed fetch now rewinds the clock and the next session tries again.

## 0.4.0 - 2026-08-25

- The installer offers to queue your most substantial recent sessions, so the first
  `/sync-memory` has real material instead of writing nothing and looking broken. First
  install only - an update never queues work behind your back.
- Token cost is stated before that question, not after.
- `CLAUDE_MEMORY_EXCLUDE` is honoured as the default for the exclusions answer, so a
  non-interactive install can be configured at all.

## 0.3.0 - 2026-08-25

Hardening from the first runs against real transcripts.

- **Fixed: commits swept the working tree.** The agent committed `docs/` wholesale, so your
  own unfinished edits would land in a commit titled "sync project memory". It now adds only
  the files it wrote, by name, and checks `git status` before editing.
- **Fixed: `RECENT.md` never rotated.** Rotation counted entries, and a real log reaches 800
  lines at eighteen of them. It now rotates on file size.
- The repository's own conventions outrank the template: decisions already kept under
  `docs/decisions/` stay there, an archived `STATUS.md` stays archived.
- A session that is still running is no longer mistaken for a finished one. A recommended
  option in an unanswered question is not a decision.
- Closed four ambiguities the agent had to guess at: the three-turn boundary, which `cwd`
  wins, how far index repair reaches, and double-checking an alarming filter.

## 0.2.0 - 2026-08-25

- Translated to English, with the Russian documentation kept as `README.ru.md`.
- Memory is written in the language of the session, not in English by default.
- **Fixed: the memory folder was keyed by the working directory** rather than the repository
  root, so a session started in a subdirectory or a worktree wrote where Claude Code never
  looks.

## 0.1.0 - 2026-08-24

First release.

- `/sync-memory` and the `memory-keeper` agent: reads a finished session in full and files
  what survived into Markdown memory files and project docs.
- A session queue with filters, so blank and service sessions never reach it.
- A context guard that warns before a conversation outgrows its window.
- An installer with an interactive setup, plus `--yes`, `--update` and `--uninstall`.
