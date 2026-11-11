# Sure Desktop: running the app

Sure Desktop runs the whole Sure stack (Rails, PostgreSQL, Valkey, llama.cpp)
locally from `desktop/runtime/`. There are two dev modes: one for the human
testing the app, one for agents. Several checkouts (worktrees) and several
agents may be running dev apps at the same time, so ports and data are kept
apart. See [README.md](README.md) for the full workflow.

## Agents: always use agent mode, never the human port

- Run the app with `npm run dev:agent` (from `desktop/`). Never run
  `npm run dev:local`: that is the human's mode, and it stops whatever Sure
  app holds the default port, including the one the human is testing.
- Agent mode takes the first free port from **3100** upwards (never 3000) and
  prints it: `Sure (agent mode): http://127.0.0.1:<port>`. Use that URL; do not
  assume a port. Its frontend dev server takes a free port from 1500.
- Before starting, check whether your checkout already has an agent app
  running (`lsof -nP -iTCP -sTCP:LISTEN | grep -E ':31[0-9]{2}'`, then confirm
  the process is yours). Reuse it rather than starting a second one: two
  agent apps from the same checkout share one data folder.
- Agent data lives in its own folder (`local-dev-<id>-agent`, path in
  `desktop/.dev-data-dir-agent`), separate from the human's. Seed it with
  `npm run seed:agent`; run Rails commands against it with
  `scripts/local-rails.sh --agent <command>`.
- Never stop, signal or reconfigure a Sure process you did not start, and
  never touch port 3000 or the human's data folder (`desktop/.dev-data-dir`).
- Stop your app when you are done: Ctrl+C in its terminal, or end the
  `tauri dev` process you started. It stops its database, Valkey and model
  server cleanly.

## Human testing: the default port

- `npm run dev:local` runs Sure on the default port, **3000**
  (`SURE_HUMAN_PORT` to change it), with the human's data
  (`desktop/.dev-data-dir`).
- Each run first checks the port. If a Sure app holds it, that app is stopped
  cleanly and replaced; if any other program holds it, the script stops and
  says so instead of killing it.
- Once Sure is up, the window lists the accounts in the dev data; clicking
  one signs in as that user (a dev-only route, protected by a token created
  for each launch; it does not exist in release builds). "Continue without
  signing in" goes to the normal sign-in page.
- `npm run seed:dev` adds the test accounts and the demo family:
  `desktop-tester@example.com` / `dev-member@example.com`
  (`SureDesktop-dev1!`), and the demo family (`Password1!`).

## After changing code

- Rails code: `npm run runtime:app` restages it into `runtime/` (~1 min); then
  restart the dev app.
- Rust (`src-tauri/src`): `tauri dev` rebuilds and restarts the app by itself.
- Frontend (`src/`, `*.html`): hot reload.
- Tests: `npm run test:rust`, and `npm run test:smoke` (boots the runtime end to
  end with the app's launcher). The Rails suite runs on the bundled runtime too;
  see the README.
