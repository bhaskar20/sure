# Sure Desktop (macOS + Windows)

Native shell (Tauri 2) that renders the full Sure web app. It has two modes:

- **Local (packaged builds):** Sure runs entirely on this computer: no server,
  no Docker, no account anywhere else. This is what the `.dmg` and the Windows
  installer ship.
- **Remote (`tauri dev` / builds without the runtime):** connects to a Sure
  server you already run, same trust model as a browser.

## Local mode

A packaged build bundles a `runtime/` resource folder:

| Folder | Contents |
| --- | --- |
| `ruby/` | Relocatable Ruby (built from source on macOS with static OpenSSL/libyaml; RubyInstaller on Windows) |
| `app/` | The Rails app: production gems vendored, assets precompiled |
| `postgres/` | PostgreSQL server ([zonky embedded binaries](https://github.com/zonkyio/embedded-postgres-binaries)) |
| `valkey/` | `valkey-server`, a BSD-licensed Redis-compatible server, for Sidekiq + cache |
| `llama/` | llama.cpp's `llama-server` (Metal on Macs, Vulkan with CPU fallback on Windows) for local AI |
| `libvips/` | libvips for image variants (avatars, logos, attachment previews) |
| `ssl/` | CA bundle for outbound HTTPS (exchange rates, bank sync providers) |

On launch, `src-tauri/src/local_backend.rs` starts PostgreSQL, Valkey and
Puma (with Sidekiq embedded in the Puma process, see `config/puma.rb`), all
bound to `127.0.0.1` with generated passwords. It runs `db:prepare` and opens
the main window on the local server once `/up` answers. Quitting the app stops
all three. All state lives in the app's local data folder:

- macOS: `~/Library/Application Support/app.sure.desktop/local/`
- Windows: `%LOCALAPPDATA%\app.sure.desktop\local\`

The folder holds `secrets.json` (the Rails secret, which also derives the
encryption keys, so back it up with the data), `pgdata/`, `valkey/`, `storage/`
(uploads) and `logs/`. On the first launch you create your account on the
local Sure, exactly like a fresh self-hosted install.

### Developing on a Mac

Mac builds are made locally; CI only builds Windows (and Mac DMGs on request).
Everything below runs from `desktop/` after `npm ci`.

| Command | What it does | Time |
|---|---|---|
| `npm run runtime:mac` | Build the whole bundled runtime into `runtime/` (Ruby, Rails app, PostgreSQL, Valkey, llama-server, libvips). Downloads are cached in `build/`. | ~15 min first time |
| `npm run runtime:app` | Re-stage only the Rails app into `runtime/` after changing Rails code | ~1 min |
| `npm run dev:local` | Human testing: Sure on port 3000 (stopping a Sure app already there), then pick an account to sign in as | ~10 s to a running Sure |
| `npm run dev:agent` | For coding agents: first free port from 3100, separate data; never touches the human's app ([CLAUDE.md](CLAUDE.md)) | ~10 s |
| `npm run seed:dev` / `seed:agent` | With the dev app running: add test accounts and the demo family to its data (safe to re-run) | ~1.5 min first time |
| `npm run build:app` | Build `Sure.app` (copies `runtime/` into the bundle) | ~2 min |
| `npm run build:mac` | Build `Sure.app` and the `.dmg` | ~3 min |
| `npm run test:rust` / `test:smoke` | Rust tests / boot `runtime/` end to end | seconds / ~30 s |

`seed:dev` creates these sign-ins (local development fixtures only):

| Email | Password | What's there |
|---|---|---|
| `desktop-tester@example.com` | `SureDesktop-dev1!` | Admin of a small household: checking + credit card, categories, ~2 months of transactions, a rule, a few uncategorized rows to try AI categorization on |
| `dev-member@example.com` | `SureDesktop-dev1!` | Member of the same household |
| `user@example.com` (or `demo@example.com` if that address was already signed up) | `Password1!` | Sure's demo family: ~8,700 transactions, investments, budgets, goals |

`scripts/local-rails.sh --dev …` runs any other Rails command (`console`,
`runner`, rake tasks) against the dev data.

Dev mode keeps its data in `…/app.sure.desktop/local-dev-<id>/`, one folder per
checkout (worktrees included), separate from an installed Sure's `local/`, so
they can all run at once without stopping each other's services. The path is
written to `desktop/.dev-data-dir`. Ctrl+C (or SIGTERM) quits like ⌘Q: the
database, Valkey and the model server stop too.
`Sure.app` before rebuilding it, since the build replaces its files in place.

Build on the target architecture (Apple Silicon or Intel). Set
`APPLE_SIGNING_IDENTITY` to sign the bundled executables for notarization.

### Build the Windows installer (.exe)
On Windows x64 with Git for Windows, 7-Zip, Node, Rust and MSYS2 at `C:\msys64`:
```bash
# In an MSYS2 MSYS shell:
desktop/scripts/build-valkey-msys2.sh
# In PowerShell:
desktop/scripts/build-runtime-windows.ps1
cd desktop; npm ci; npx tauri build --config src-tauri/tauri.local.conf.json
# Output: src-tauri/target/release/bundle/nsis/Sure_<ver>_x64-setup.exe
```

CI builds the Windows installer in `.github/workflows/desktop-local-build.yml`
on every manual run or `desktop-v*` tag; tick "Also build the macOS DMGs" on a
manual run to build those in CI too.

### Local AI

**Preferences → Local AI** runs an LLM on this computer for Sure's assistant
and auto-categorization, so prompts never leave the machine:

- Pick a model from a short catalog (Qwen3 4B Instruct is recommended; Qwen3
  1.7B for older machines; Llama 3.2 3B; Qwen3 8B for 16 GB+ machines) or add
  any GGUF by `https://` URL or file path. Catalog downloads are checked
  against pinned sizes and SHA-256s; every model file must have a GGUF header.
- Models live in `local/models/` in the data folder; nothing is bundled.
- While on, `llama-server` serves the model on 127.0.0.1 with a generated API
  key, and the launcher points Sure's OpenAI-compatible provider at it
  (`OPENAI_URI_BASE`, `OPENAI_MODEL=sure-local`, a 32K `LLM_CONTEXT_WINDOW`,
  longer timeouts, one AI thread). Turning it off restores whatever AI
  provider is configured in Sure's own settings. Switching models restarts only
  llama-server; turning local AI on/off or changing the context restarts Puma.
- 32K context is the minimum: Sure's assistant prompt with its tool
  definitions is about 14K tokens, and one tool call's results push the next
  request past 16K. The KV cache is 8-bit to keep that affordable.
- Measured on an M-series Mac: the 4B model answers a tool-using question in
  about 40 s (most of it processing Sure's 14K-token prompt), and
  categorizes a batch of transactions in about 30 s.

### Troubleshooting
If startup fails, the window shows the error and the logs folder
(`postgres.log`, `valkey.log`, `rails.log`).

## Remote mode

## Requirements
- Rust (stable), Node 18+, Xcode command line tools, macOS 12+.

## Run in development
```bash
cd desktop
npm install
npm run build      # builds the injected bridge.js + onboarding assets
npm run tauri dev
```
On first launch, enter your Sure server URL (e.g. `http://localhost:3000` when
running `bin/dev`). The app health-checks `{server}/up`, then loads the real
`/sessions/new` where you sign in with password or SSO (MFA supported).

## Build a release .dmg (unsigned)
```bash
cd desktop
# Single-arch (host only):
npm run tauri build
# Universal (Apple Silicon + Intel) — what releases ship:
rustup target add aarch64-apple-darwin x86_64-apple-darwin
npm run tauri build -- --target universal-apple-darwin
# Output: src-tauri/target/universal-apple-darwin/release/bundle/dmg/Sure_<ver>_universal.dmg
```

## Publishing a release
The desktop build runs automatically as part of the normal Sure `v*` release.
The version comes from the release tag and is written to generated `.sure-version`; it is
stamped into `desktop/package.json` and `desktop/src-tauri/tauri.conf.json`
only while building. The universal `.dmg` is attached to that same GitHub
Release—there is no separate desktop action, tag, or version.

## Installing an unsigned build (end users)
The published `.dmg` is only ad-hoc signed (no Developer ID, not notarized), so
macOS Gatekeeper blocks the first launch. To open it:
1. Drag Sure to Applications and open it from there, not from the mounted disk
   image; dismiss the warning.
2. **System Settings → Privacy & Security**, scroll down, click **Open Anyway**,
   and confirm. (On macOS 15 Sequoia the old right-click→Open shortcut is gone;
   this Settings path is the way.)
3. If your server is on your local network (for example `http://192.168.x.x:3000`),
   click **Allow** when macOS asks whether Sure may find devices on your local
   network. If you declined, turn Sure on under **System Settings → Privacy &
   Security → Local Network**.

If macOS instead says the app is "damaged", the download was quarantined — strip
it once in Terminal:
```bash
xattr -cr /Applications/Sure.app
```
Signing + notarization (below) removes this friction entirely.

## Tests
```bash
cd desktop/src-tauri
cargo test                      # unit + integration tests (launcher, servers, windows)
# End-to-end smoke test of a built runtime: boots it with the app's launcher
# code, signs up, restarts and signs in (CI runs this before packaging).
SURE_RUNTIME_DIR=$PWD/../runtime cargo test --test packaged_runtime_test -- --nocapture
# Local AI end to end (downloads a model): checksum, server, API key, tool call.
SURE_RUNTIME_DIR=$PWD/../runtime SURE_TEST_LOCAL_AI=1 cargo test --test local_ai_server_test -- --nocapture
```
The Rails suite (`bin/rails test`) also runs on the bundled runtime: install the
test gems with `runtime/ruby/bin/bundle`, point `DB_*`/`REDIS_URL` at a running
local install (see `scripts/local-rails.sh` for the variables), and invoke
`ruby bin/rails test` (not `bin/rails`: on macOS the `/usr/bin/env` shebang
drops the `DYLD_*` variable that locates the bundled libvips).

## Reports and downloads

Files your Sure server sends as downloads (CSV exports, statements, transaction
attachments, the import sample CSV) are saved in the macOS Downloads folder,
even when the app could display them. When a download finishes or fails, Sure
shows its usual message in the window, or in the main window when the download
came from a window that closed itself. A native notification is also sent when
that window is not in front, and replaces the message when the window is hidden
or the server is too old to provide it (allow Sure notifications in System
Settings to see them). The notification uses the message's text in Sure's
language, and is in English only with a server too old to provide the message.
Repeated downloads get a numbered filename.

Print Report opens a separate Sure window using the current signed-in session,
then the native print dialog once the report has loaded. Print it, or choose
PDF → Save as PDF. Close the report window to return to the app.

Other links that open a new window follow the same rule: pages of your Sure
server open in a separate Sure window with your session, and other websites
open in your default browser. Only the main window has the desktop
integrations: notifications and SSO in your browser. Downloads are only
accepted from pages of your saved servers.

To verify changes to this flow, run `npm run build` in `desktop`, then
`cargo test --locked` in `desktop/src-tauri`. In the desktop app, export a
report CSV twice and check both files in Downloads. Download a statement PDF
and a transaction attachment, check that the app page stays in place, and open
Print Report to save a PDF. Open a CSV statement with its view link (the eye
icon on an account's statements): the file is saved in Downloads, no empty Sure
window stays open, and the message appears in the main window.
Open an external link (for example the Discord help icon) and check that it
opens in your browser. Repeat against a server mounted under a URL prefix, if
applicable.

## Deep links
Registered scheme: `sure://{host}[:port]/{path}` → opens the app to that
server/page. Example: `open "sure://localhost:3000/accounts"`. (Works from the
bundled `.app`, not `tauri dev`.)

## Code signing & notarization (required for distribution — NOT wired up)
No Apple Developer credentials are needed to build/run locally. To ship a
distributable, signed, notarized `.dmg`, add:
1. An **Apple Developer ID Application** certificate in your login keychain.
2. Tauri signing config in `src-tauri/tauri.conf.json` under `bundle.macOS`:
   replace the ad-hoc `"signingIdentity": "-"` with
   `"signingIdentity": "Developer ID Application: <NAME> (<TEAMID>)"`,
   `"hardenedRuntime": true`, and an `entitlements` plist if needed.
3. Notarization after build:
   ```bash
   VERSION="<release-version>"
   xcrun notarytool submit "src-tauri/target/universal-apple-darwin/release/bundle/dmg/Sure_${VERSION}_universal.dmg" \
     --apple-id "<APPLE_ID>" --team-id "<TEAMID>" --password "<APP_SPECIFIC_PW>" --wait
   xcrun stapler staple "src-tauri/target/universal-apple-darwin/release/bundle/dmg/Sure_${VERSION}_universal.dmg"
   ```
These steps require an Apple Developer account and are intentionally left as a
documented follow-up.

## Not built yet (see spec §9)
- Balance-with-sparkline glance widget (Tauri floating panel and/or a WidgetKit
  Notification Center widget with App Group data sharing), fed by an
  auto-provisioned read-only API key polling `/api/v1`. Deferred by design.
