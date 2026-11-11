# Feature requests

The build queue for features developed by coordinated agents. This index is the
single place to see what is requested, who is working on what, and what is done.
Each feature has its own spec in this folder holding requirements, decisions and
handoff notes.

## Features

| ID | Feature | Status | Priority | Owner | Depends on | Spec |
| --- | --- | --- | --- | --- | --- | --- |
| FR-001 | Local coding harness for changing Sure itself | Proposed | P1 | — | — | [spec](FR-001-local-coding-harness.md) |
| FR-002 | Mini apps: plug-in apps with their own UI and data access | Proposed | P1 | — | — | [spec](FR-002-miniapps.md) |

## Statuses

| Status | Meaning |
| --- | --- |
| `Proposed` | Requested; requirements not yet agreed. Not ready to build. |
| `Ready` | Requirements and acceptance criteria agreed; any agent may claim it. |
| `In progress` | Claimed; an agent is building it on its own branch. |
| `In review` | PR open; waiting on review or CI. |
| `Blocked` | Cannot proceed; the spec's **Blockers** section says why and on whom. |
| `Done` | Merged into `main` and acceptance criteria verified. |
| `Dropped` | Will not be built; the spec says why. |

Priority is `P0` (must have next), `P1` (should have) or `P2` (nice to have).

## Protocol for agents

**Adding a request.** Take the next free `FR-NNN` ID, copy
[`_template.md`](_template.md) to `FR-NNN-short-slug.md`, fill in the problem
and requirements, and add a row here with status `Proposed`. Only a human moves a
feature from `Proposed` to `Ready`.

**Claiming.** Pick a `Ready` feature whose dependencies are `Done`, highest
priority first. Set its status to `In progress` and the owner to your session or
agent name, and commit that change on its own before starting work so other
agents see the claim. Never claim a feature someone else owns.

**Building.**

- Work on a branch named `feature/FR-NNN-short-slug`, in your own worktree.
- Before writing code, list the files and areas you expect to touch under
  **Touches** in the spec. If they overlap another `In progress` feature, stop
  and record it under **Blockers** instead of editing the same files.
- Follow [AGENTS.md](../../AGENTS.md) and the relevant
  [task guides](../llm-guides/README.md); a feature is not exempt from tests,
  lint or the pre-PR checklist.
- Record decisions that change or clarify requirements under **Decisions**, and
  add dated entries to **Progress** at meaningful milestones (not every commit).

**Handing off.** If you stop before finishing, leave the status `In progress`,
clear the owner, and write under **Handoff** what is done, what is left, the
branch name and anything the next agent must know.

**Finishing.** When the PR opens, set `In review` and link the PR in the spec.
When it merges, tick the acceptance criteria you verified, set `Done` and clear
the owner.

**Questions for a human.** Put open questions under **Open questions** in the
spec, and set `Blocked` if work cannot continue without an answer.

Keep edits to this index to the single row you are changing, so parallel
agents' branches merge cleanly.
