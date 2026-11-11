# FR-001: Local coding harness for changing Sure itself

| Field | Value |
| --- | --- |
| Status | Proposed |
| Priority | P1 |
| Owner | — |
| Branch | — |
| PR | — |
| Depends on | — |

## Problem

People running Sure Desktop locally want to change the app to fit how they
manage money: a new report, a tweaked screen, a different categorization rule,
or a larger feature. Today that means cloning the repository, setting up a
Rails development environment and rebuilding the desktop runtime by hand.
That is out of reach for most users, and it means sending the code to a hosted
LLM, which conflicts with the local-only promise of Sure Desktop.

## Requirements

- A sibling desktop app, shipped alongside Sure Desktop and installed
  separately or together, in which a user describes a change in plain language
  and an AI coding agent makes it to their own copy of Sure.
- The agent is an existing open-source coding harness, embedded or driven by
  the sibling app rather than written from scratch. The harness reads, edits
  and runs commands in the project, and the sibling app gives it a UI.
- The model runs locally. The sibling app can:
  - start and manage its own local LLM server, reusing the bundled
    `llama-server` and the model download/catalog approach already in
    `desktop/src-tauri/src/local_ai.rs`; and
  - connect instead to an LLM server the user already runs (Ollama, LM Studio,
    llama.cpp, vLLM, or any OpenAI-compatible endpoint), by URL and optional
    API key.
- Small and large changes are both supported: a one-file tweak and a
  multi-step feature with migrations and tests.
- Every change is reviewable and reversible:
  - the user sees the plan and the diff before the change is applied;
  - each change lands as its own git commit on the user's local copy;
  - the user can undo any applied change and return to the previous working
    version of the app.
- Before a change is applied to the running app, the sibling app runs the
  relevant checks (at minimum the affected tests and the build/asset step) and
  shows the result. A failing change is not applied unless the user insists.
- Applying a change rebuilds what is needed (gems, assets, migrations) and
  restarts the local Sure backend, so the user sees the result in Sure Desktop.
- The agent works only on Sure's source. It has no access to the user's data
  folder: `pgdata/`, `secrets.json`, `storage/`, logs or the database.
- When a new Sure release arrives, the user's local changes are carried
  forward by replaying their commits onto it. Conflicts are shown to the user,
  who can ask the agent to resolve them or drop the change.
- Nothing is sent off the machine unless the user configures a remote model
  endpoint themselves, and the UI says clearly when that is the case.

## Out of scope

- A hosted or cloud model provider as the default.
- Sharing or publishing user changes upstream (opening PRs to Sure).
- Changing the sibling app itself, the Tauri shell or the bundled runtime
  binaries (Ruby, PostgreSQL, Valkey).
- Mobile apps.

## Acceptance criteria

- [ ] On macOS and Windows, a user with only Sure Desktop and the sibling app
      installed can request a small UI change, review the diff, apply it, and
      see it in Sure Desktop after the automatic restart.
- [ ] The same works for a change that adds a migration and a test.
- [ ] Undoing an applied change restores the previous version and Sure starts
      normally.
- [ ] The sibling app works with its own bundled local model server and with
      an existing Ollama or other OpenAI-compatible server.
- [ ] A test shows the agent cannot read or write files in Sure's data folder.
- [ ] A change whose checks fail is not applied by default, and the failure
      output is shown.
- [ ] After upgrading Sure, previously applied changes are replayed; a
      conflicting change is reported, not silently dropped.
- [ ] With the bundled model server and no configured remote endpoint, no
      network requests leave the machine during a change (verified by test or
      documented manual check).

## Touches

Expected areas; refine before building.

- New sibling app, likely `desktop-harness/` (Tauri 2, mirroring `desktop/`).
- `desktop/src-tauri/src/local_ai.rs`: share model management and the
  `llama-server` lifecycle, or extract it into a crate both apps use.
- `desktop/src-tauri/src/local_backend.rs`: an entry point to rebuild and
  restart the backend from a changed source tree.
- `desktop/scripts/stage-app.sh` and the build-runtime scripts: stage the app
  from a git working copy and keep the previous version for rollback.
- `.github/workflows/desktop-local-build.yml`: build and package the sibling
  app.

## Decisions

None yet.

## Open questions

- **Which open-source harness?** Candidates to evaluate for license, support
  for local OpenAI-compatible models, a headless or server mode the sibling app
  can drive, and Windows support: OpenCode (`opencode serve`), Aider, Goose,
  OpenHands (needs Docker, likely too heavy). Owner: product/human decision
  after a short spike.
- **What is "the app" the agent edits?** The packaged build ships staged
  production code in `runtime/app` without git history or test gems. Options:
  ship a full git checkout of the release source with the sibling app, or
  clone it on first run. Owner: human decision.
- **Its own local server, or Sure Desktop's?** Should the sibling app run a
  separate `llama-server` instance, or share the one Sure Desktop manages?
  Coding needs larger models and context than chat/categorization.
- **Which models?** The current catalog (3–4B models) is too weak for
  reliable code changes. Which coding models (and minimum RAM/GPU) should the
  catalog offer, and what happens on machines that cannot run them?
- **Are database migrations allowed?** A migration from a local change may not
  be reversible or may conflict with a later upstream migration. Should
  migrations be allowed, and how does undo handle them (for example a database
  snapshot before applying)?
- **Development tools on the user's machine?** Running tests needs test gems
  and possibly Node/Biome; installing them adds size. What is the minimum
  check set that must run?

## Blockers

Waiting on answers to the open questions about the harness and the editable
source before moving to `Ready`.

## Progress

- 2026-11-11: Request recorded.

## Handoff

Not started.
