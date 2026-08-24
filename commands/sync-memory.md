---
description: Update memory files from the current session, or from past ones in the queue
---

Run the `memory-keeper` subagent to update memory files from the current session.

Pass it:
- `SESSION_ID` of the current session (pass it if you can tell from context, otherwise let
  the agent find the latest transcript itself)
- `CWD` - the current working directory
- `TRANSCRIPT_PATH` if you know it

If `$ARGUMENTS` is present, forward it to the agent as an extra instruction
(for example: "only record the decision about payments", "leave RECENT alone, DECISIONS only").

## The queue of unprocessed sessions

Check `~/.claude/scripts/.pending-memory.log` (lines look like `SESSION_ID|CWD|TIMESTAMP`).
If it has entries, work through them as follows.

### 1. Triage before spawning any agent

- **Deduplicate** by the `SESSION_ID|CWD` pair: one session lands in the log several times.
- **Drop the dead ones.** A transcript lives at
  `~/.claude/projects/<CWD with / and . replaced by ->/<SESSION_ID>.jsonl`.
  No file, no processing - mark it for removal.
- **Drop the service runs.** Sessions that were themselves `/sync-memory` runs (first user
  message is `<command-name>/sync-memory</command-name>`) and obviously empty ones (a tiny
  transcript, "answer in one word" tests) get removed without processing.

### 2. Processing: one agent per project, not per session

- Group the live sessions by `CWD` and spawn **one** `memory-keeper` per project with the
  full list of its sessions.
- **Temporary files.** Tell every agent in its prompt to write intermediate files only into
  its own scratchpad subfolder (`<scratchpad>/<project-name>/`): parallel agents share one
  scratchpad and will overwrite each other's files.
- **Shared memory gets a single writer.** Only the agent handling the home-directory group,
  or you at the very end, may write to shared memory. Forbid it explicitly for the project
  agents: they return cross-project findings under a "GLOBAL CANDIDATES" heading, and you
  apply those after every agent has finished, checking against the existing files so
  duplicates do not pile up.

### 3. Cleaning the queue

- Back the file up next to itself first (`.pending-memory.log.bak-<date>`).
- Remove only the lines from your own snapshot (processed, dead, service). Leave entries the
  hook appended while you were running for next time.

Finish with a summary of everything that changed.
