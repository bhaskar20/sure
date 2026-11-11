# FR-002: Mini apps — plug-in apps with their own UI and data access

| Field | Value |
| --- | --- |
| Status | In progress |
| Priority | P1 |
| Owner | claude-fr-002 (coordinated agent workflow) |
| Branch | `feature/FR-002-miniapps` |
| PR | — |
| Depends on | — |

## Problem

People want Sure to do things the core app will never ship: a debt-payoff
planner, a shared-expense splitter, a tax-lot report, a custom dashboard for
their country's pension scheme. Today the only way to build on Sure is a
separate app that talks to the API v1 or MCP server, with its own UI hosted
somewhere else. There is no way to plug something into Sure's own interface,
and no safe, permissioned way for third-party code to read and change a
family's data from inside the app.

## Requirements

- A **mini apps** module where a family admin can install, enable, disable and
  remove mini apps.
- A mini app **brings its own UI**, shown inside Sure in defined places (to
  decide: its own page in the sidebar, a panel on account or transaction
  detail, a dashboard widget).
- A mini app can **create, read, update and delete core data** — accounts,
  transactions, categories, tags, merchants, budgets, rules, valuations — only
  through an API that Sure provides. It never touches the database or Rails
  internals directly.
- **Permissions are explicit.** A mini app declares the data it needs in a
  manifest, the admin approves it at install, and Sure enforces it on every
  call. Approval can be revoked at any time.
- **Writes are attributable.** Every change records which mini app made it,
  and the family can see a mini app's recent activity.
- A mini app can **store its own data** (settings, its own records) without
  needing database migrations in Sure.
- Mini apps are **isolated**. A broken or malicious mini app cannot read
  Sure's cookies or session, other mini apps' data, other families' data, or
  call anything outside its granted permissions.
- **Developers can build them easily.** A published SDK, a manifest schema, a
  starter template, and a dev mode that loads a mini app from a local URL
  while it is being built.
- It works in the hosted/self-hosted web app and in Sure Desktop, offline
  included, as long as the mini app itself needs no network.
- It ships behind preview-feature gating (see
  [gating a preview feature](../llm-guides/gating-a-preview-feature.md)).

## Out of scope

- A public marketplace, reviews, payments or revenue sharing.
- Mini apps that run server-side Ruby inside Sure's process.
- Changing core screens beyond the defined extension slots.
- Mobile app support (a later feature can reuse the same bridge).

## Research: how to let others build on Sure

### What Sure already has

- **API v1** (`app/controllers/api/v1/`, about 40 controllers) covers most core
  data, authenticated by API keys or Doorkeeper OAuth tokens.
- **Scopes are coarse:** only `read` and `read_write`
  (`config/initializers/doorkeeper.rb`, `app/models/api_key.rb`). A mini app
  that only needs to tag transactions would get write access to everything.
- **An MCP server** (`app/controllers/mcp_controller.rb`) exposes the
  assistant's function tools (`app/models/assistant/function/`), including
  create/delete for transactions, categories, tags, rules and goals.
- **No outgoing webhooks or event stream** for core data changes.
- **No content security policy** is enforced
  (`config/initializers/content_security_policy.rb` is commented out). That
  matters once third-party UI is shown inside Sure.

### Approaches considered

| Approach | Used by | Fit for Sure |
| --- | --- | --- |
| In-process plugins (Rails engines or gems loaded into the app) | Discourse, Redmine | Most power, but no isolation: a plugin runs with full database access and breaks when core internals change. Actual Budget delayed its plugin system because plugins kept breaking features ([roadmap 2026](https://actualbudget.org/blog/roadmap-for-2026)). Not safe for third-party code. **Rejected.** |
| External apps over the API only | Sure today, Firefly III | Safe, and already exists, but the UI lives elsewhere, so it is not "plugged in". **Keep as the backend option, not the main model.** |
| Sandboxed iframe UI plus a host bridge | Shopify embedded apps ([session tokens](https://shopify.dev/concepts/apps/building-embedded-apps-using-session-tokens)), Figma plugin UI ([how plugins run](https://developers.figma.com/docs/plugins/how-plugins-run)) | Mini app UI runs in an isolated iframe. It talks to Sure only by `postMessage`, and Sure checks each request against the mini app's permissions. Proven for third-party UI. **Recommended core.** |
| MCP Apps (`ui://` HTML resources in sandboxed iframes, JSON-RPC over `postMessage`) | MCP ecosystem ([announcement](https://blog.modelcontextprotocol.io/posts/2025-11-21-mcp-apps/), [SEP-1865](https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp)) | Same sandbox pattern, standardized, with an SDK (`@modelcontextprotocol/ext-apps`). Sure already speaks MCP, so aligning the bridge with it lets one mini app run inside Sure and in MCP clients such as Claude. **Recommended as the protocol to align with.** |
| JavaScript sandbox for logic (QuickJS in WebAssembly) | Figma ([plugin system](https://www.figma.com/blog/how-we-built-the-figma-plugin-system/)) | Strongest isolation for code that must run without a UI. More complex than Sure needs for a first version. **Defer.** |

### Recommended design

1. **Package and manifest.** A mini app is a static bundle (HTML, JS, CSS)
   with a `miniapp.json` manifest: id, name, version, entry file, extension
   slots it uses, permissions it needs, and any outside domains it calls
   (turned into that iframe's CSP). Install by uploading a zip or from a URL.
   Bundles are stored per family; Sure Desktop keeps them in local storage.
2. **Isolation.** Each mini app renders in an iframe with
   `sandbox="allow-scripts"` and no `allow-same-origin`, so it has an opaque
   origin. It cannot read Sure's cookies, DOM or storage, and gets a strict
   CSP with no outbound network unless the manifest declares domains. Turn on
   Sure's own CSP as part of this work.
3. **Bridge, not tokens.** A host-side Stimulus controller handles JSON-RPC
   messages from the iframe (for example `transactions.list`,
   `transactions.update`, `categories.create`). It checks each call against the
   granted permissions and runs it as the current user in `Current.family`. No
   API token is ever handed to the iframe, so nothing can leak or outlive the
   session. Keep the message format close to MCP Apps (`ui/initialize`,
   `tools/call`) so the same mini app can also be served over Sure's MCP
   server.
4. **One service layer for every caller.** The bridge, API v1 and the
   assistant/MCP functions should call the same model operations, so
   validation, syncs, balance recalculation and tenancy are enforced in one
   place. Writes go through models, never raw SQL.
5. **Granular permissions.** Replace the two coarse scopes with
   resource-level ones (`transactions:read`, `transactions:write`,
   `categories:write`, `accounts:read`, …). Use them for mini apps, and offer
   them to API keys and OAuth apps too.
6. **Mini app data.** Give each mini app a namespaced key-value/document store
   per family (one table with a JSON column), plus namespaced metadata on core
   records (for example a mini app's tag on a transaction). No migrations per
   mini app.
7. **Audit.** Record the mini app as the actor on every write it makes, and
   show a per-mini-app activity view.
8. **Events.** Push core change events (for example `transaction.created`) to
   open mini app iframes over the bridge. Webhooks for mini apps with their own
   backend can come later.
9. **Mini apps with their own backend.** Optional and secondary: such a mini
   app uses OAuth (Doorkeeper) with the same granular scopes. If its UI is
   embedded, Sure issues it a short-lived signed token to prove which user and
   family is viewing, which its backend exchanges for an access token (the
   Shopify ID-token pattern).
10. **Developer kit.** An npm SDK (`@sure/miniapp-sdk`) with TypeScript types
    for every bridge call, a manifest JSON schema, a starter template, a
    developer guide, and a dev mode that loads a mini app from `localhost`.
    Version the bridge API and negotiate capabilities at `ui/initialize`, so
    old mini apps keep working as Sure changes.

## Acceptance criteria

- [ ] A family admin can install a mini app from a zip, see the permissions it
      requests, approve them, open its UI inside Sure, and remove it.
- [ ] A sample mini app built only with the published SDK lists transactions,
      creates a category and recategorizes a transaction; the changes appear
      in core Sure screens.
- [ ] A call outside the granted permissions is refused, and a test covers
      this for read and write.
- [ ] Tests show a mini app cannot reach another family's data, Sure's
      cookies or session, or another mini app's stored data.
- [ ] Every write by a mini app is attributed to it and listed in its activity
      view.
- [ ] A mini app can save and read its own settings and records without a
      migration.
- [ ] Revoking or uninstalling a mini app stops its access immediately.
- [ ] A mini app works in the web app and in Sure Desktop with no network.
- [ ] The developer guide and starter template let someone build and load a
      mini app in dev mode without reading Sure's source.
- [ ] The feature is behind preview-feature gating, with Minitest coverage and
      lint, Biome and Brakeman passing.

## Touches

- Migration `db/migrate/20261111120000_create_mini_apps.rb` and `db/schema.rb`.
- Models: `app/models/mini_app.rb`, `app/models/mini_app/{manifest,permission,package,dev_server,asset,record,activity,bridge}.rb`;
  `has_many :mini_apps` on `Family`.
- Controllers: `app/controllers/mini_apps_controller.rb`, `app/controllers/mini_app_frames_controller.rb`.
- Views: `app/views/mini_apps/`; one preview-gated nav entry in `app/helpers/application_helper.rb` / the
  layout nav list.
- JavaScript: `app/javascript/controllers/mini_app_host_controller.js`.
- Routes: a `mini_apps` resource and the `mini_app_frames` route in `config/routes.rb`.
- Locales: `config/locales/views/mini_apps/en.yml`, `config/locales/models/mini_app/en.yml`.
- Tests and fixtures under `test/models/mini_app*`, `test/controllers/mini_app*`, `test/fixtures/mini_app*`.
- SDK and docs: `packages/miniapp-sdk/`, `examples/miniapps/`, `bin/miniapp-pack`, `docs/miniapps/`.

No overlap with FR-001.

## Decisions

- 2026-11-11: Build as one feature. Granular scopes, the shared service layer
  and enabling CSP are part of FR-002, not separate features; they can still
  land as separate PRs on the feature branch.
- 2026-11-11 (product owner: "maximum flexibility, complete control"), resolving the open questions:
  - **Flexibility: the whole tool catalog.** The bridge exposes the same
    `Assistant::Function` tools that the assistant and the MCP server use, as
    MCP-style `tools/call`. That is the shared service layer: one
    implementation, three callers (assistant, MCP, mini apps). A mini app can
    do anything the assistant can, within the permissions it is granted.
  - **Control: granular, editable, revocable grants.** Each manifest permission
    (`transactions:write`, …) is shown at install; the admin can grant any
    subset, change it later, disable the app (instant kill switch) or
    uninstall it (deletes its files, storage and activity). Grants are checked
    on every call, server side.
  - **Control: a per-app write policy.** `confirm` (default) makes Sure ask the
    person in a host-rendered dialog before every write; `allow` lets writes
    through. The dialog is drawn by Sure, outside the iframe, so a mini app
    cannot fake or click it.
  - **Control: everything is on the record.** Every tool call, allowed,
    denied, declined or failed, is logged in the app's activity view with the
    user, tool and permission.
  - **Guests** get read permissions only, whatever is granted.
  - **Extension slots:** v1 ships the full-page slot (an "Apps" entry in the
    nav and a page per app). Manifests may only declare `page`; panel and
    widget slots come later on the same bridge.
  - **Who installs:** family admins install, grant, disable and remove. Every
    non-guest member can open enabled apps.
  - **Trust and distribution:** install from a zip the admin uploads; Sure
    records the bundle's SHA-256 and shows it. No marketplace or signing in
    v1. Dev mode loads from a `localhost` URL, only in development or
    Sure Desktop (2026-11-11: narrowed from all self-hosted installs, because a
    dev-server app runs outside the frame CSP and its `network` list cannot be
    enforced).
  - **MCP Apps alignment:** JSON-RPC 2.0 over `postMessage` with `ui/initialize`,
    `tools/list` and `tools/call` as MCP Apps defines them, plus Sure-namespaced
    `sure/storage/*` methods and `notifications/sure/*` events. Tool names and
    schemas are the MCP server's, so a mini app's calls work against
    `/mcp` too.
  - **Logic without UI** (jobs, webhooks, QuickJS) is deferred.
  - **Granular scopes for API keys/OAuth and an app-wide CSP** are deferred
    to a follow-up PR on this branch: mini app frames get their own strict
    CSP now; turning on an app-wide policy needs its own testing of every
    existing inline script and third-party embed.

## Build contract (v1)

Agents build to this contract in parallel. Change it here first if it must change.

### Data (`db/migrate/20261111120000_create_mini_apps.rb`, uuid ids)

- `mini_apps`: `family_id` (fk, not null), `installed_by_id` (fk users, null, nullify),
  `app_key` (manifest id), `name`, `version`, `description`, `manifest` (jsonb), `icon`,
  `source` (`bundle` | `dev_server`), `dev_url`, `bundle_sha256`, `status`
  (`enabled` | `disabled`, default `enabled`), `granted_permissions` (string array, default `{}`),
  `write_policy` (`confirm` | `allow`, default `confirm`), `last_opened_at`, timestamps.
  Unique `[family_id, app_key]`.
- `mini_app_assets`: `mini_app_id` (fk cascade), `path`, `content_type`, `content` (binary),
  `byte_size`, timestamps. Unique `[mini_app_id, path]`.
- `mini_app_records`: `mini_app_id` (fk cascade), `collection`, `key`, `data` (jsonb), timestamps.
  Unique `[mini_app_id, collection, key]`.
- `mini_app_activities`: `mini_app_id` (fk cascade), `user_id` (fk null, nullify), `rpc_method`,
  `tool`, `permission`, `outcome` (`ok` | `denied` | `declined` | `error`), `write` (bool),
  `summary` (jsonb), `error_message`, `created_at`. Index `[mini_app_id, created_at]`.

### Models

- `MiniApp` — `belongs_to :family`, `has_many :assets, :records, :activities` (dependent delete).
  `enabled?`, `enable!`, `disable!`, `requested_permissions`, `granted?(permission)`,
  `update_grants!(permissions:, write_policy:)` (keeps only requested ∩ catalog),
  `effective_permissions_for(user)` (granted, minus writes for guests),
  `confirm_writes?`, `entry_path`, `network_origins`, `dev_server?`,
  `frame_token` / `MiniApp.find_by_frame_token(token)` (signed id, purpose `mini_app_frame`,
  12-hour expiry), `MiniApp.dev_mode_available?`.
  `MiniApp.install_bundle!(family:, user:, io:)` and
  `MiniApp.install_dev_server!(family:, user:, url:)` create or upgrade by `app_key`; an upgrade
  replaces the assets and manifest, keeps storage, and drops grants no longer requested.
- `MiniApp::Manifest.parse(json_or_hash)` → manifest or raises `MiniApp::Manifest::Invalid`
  (`#errors`). Fields: `id` (`/\A[a-z0-9][a-z0-9.\-]{2,63}\z/`), `name` (≤ 60), `version`, `description`
  (≤ 500), `entry` (default `index.html`), `icon` (default `blocks`), `permissions`, `slots`
  (only `page`; default `["page"]`), `network` (https origins), `author`, `homepage`.
- `MiniApp::Permission` — the catalog. `all`, `valid?`, `for_tool(name)`, `write?`,
  `tools(permission)`, `label`/`description` from `mini_app.permissions.*` i18n:

  | Permission | Tools |
  | --- | --- |
  | `accounts:read` | `get_accounts`, `get_holdings`, `get_valuations` |
  | `transactions:read` | `get_transactions`, `get_recurring_transactions`, `get_uncategorized_transactions`, `get_transfer_match_candidates` |
  | `transactions:write` | `create_transaction`, `update_transaction`, `delete_transaction`, `match_transfer`, `unmatch_transfer`, `update_transfer`, `review_transfer` |
  | `categories:read` / `categories:write` | `get_categories` / `create_category`, `update_category`, `delete_category` |
  | `tags:read` / `tags:write` | `get_tags` / `create_tag`, `update_tag` |
  | `merchants:read` | `get_merchants` |
  | `rules:read` / `rules:write` | `get_rules`, `get_rule_options`, `preview_rule` / `create_rule`, `update_rule`, `apply_rule` |
  | `reports:read` | `get_balance_sheet`, `get_income_statement`, `get_budget`, `get_insights` |
  | `budgets:write` | `update_budget` |
  | `goals:write` | `create_goal` |
  | `valuations:write` | `record_valuation`, `set_opening_balance` |

  A tool is callable only if it is in this table **and** in `Assistant.function_classes(user)`.
- `MiniApp::Package.new(io).read!` → `{ manifest:, assets: [{ path:, content_type:, content: }], sha256: }`.
  `miniapp.json` at the root (one wrapping folder is stripped). Limits: 10 MB zip, 20 MB unpacked,
  300 files; rejects absolute paths, `..`, symlinks and a missing entry file. Raises `MiniApp::Package::Invalid`.
- `MiniApp::Record` — per-app storage. `collection` `/\A[a-z0-9_\-]{1,64}\z/`, `key` 1–255 chars,
  `data` ≤ 256 KB, at most 5,000 records per app.
- `MiniApp::Activity` — `MiniApp::Activity.log!(...)`, `recent`.

### Bridge (`MiniApp::Bridge.new(mini_app:, user:).handle(message, confirmed: false, declined: false)`)

Returns a JSON-RPC 2.0 response hash. Methods:

- `ui/initialize` → `{ protocolVersion: "2026-11-11", bridgeVersion: 1, hostInfo: { name: "Sure" },
  app: { id, name, version }, permissions: [...effective], writePolicy, user: { name, role },
  family: { currency, locale, dateFormat }, capabilities: { tools: {}, storage: {}, events: {} } }`
- `tools/list` → `{ tools: [{ name, description, inputSchema, permission, write }] }` (callable ones only)
- `tools/call` `{ name, arguments }` → `{ content: [{ type: "text", text: json }], structuredContent: result }`,
  or `isError: true` with a generic message when the tool raises.
- `sure/storage/get|set|delete|list` (`{ collection, key, data }`; list takes `prefix`, `limit` ≤ 200,
  `cursor` and returns `{ items: [{ key, data, updatedAt }], nextCursor }`).
- `ping` → `{}`.

Errors: `-32601` unknown method or tool not available to mini apps, `-32602` invalid params,
`-32003` permission denied (`data.permission`), `-32004` app disabled, `-32005` confirmation
required (`data: { tool, permission, summary }`, `summary` localized), `-32006` declined by user,
`-32029` rate limited (120 tool calls per minute per app and user). Every `tools/call` logs an
activity with its outcome.

### Host page and transport

- `GET /mini_apps/:id` renders `<div data-controller="mini-app-host"
  data-mini-app-host-bridge-url-value="/mini_apps/:id/bridge">` with an
  `<iframe sandbox="allow-scripts allow-forms allow-popups" referrerpolicy="no-referrer"
  data-mini-app-host-target="frame">` (never `allow-same-origin`) and a `<dialog
  data-mini-app-host-target="confirmDialog">` holding `data-mini-app-host-target="confirmMessage"`
  and buttons wired to `mini-app-host#approve` / `mini-app-host#decline`.
- The iframe sends JSON-RPC requests with `postMessage`. The host accepts only messages whose
  `event.source` is the frame's window, POSTs `{ message, confirmed, declined }` as JSON to the
  bridge URL with the CSRF token, and posts the response back with target origin `*` (the frame
  has an opaque origin). On `-32005` it shows the dialog and resends with `confirmed: true` or
  `declined: true`. After a successful write it posts `notifications/sure/data_changed`
  `{ tool }` to the frame. A frame notification `ui/size-changed` `{ height }` resizes the iframe.
- `POST /mini_apps/:id/bridge` (session auth, CSRF) → `MiniApp::Bridge`.
- `GET /mini_app_frames/:token/*path` serves bundle files without session auth (the opaque-origin
  frame sends no cookies), only for enabled apps, with
  `Content-Security-Policy: default-src 'none'; script-src <frame base> 'unsafe-inline'; style-src
  <frame base> 'unsafe-inline'; img-src <frame base> data: blob:; font-src <frame base> data:;
  connect-src <manifest network or 'none'>; form-action 'none'; base-uri 'none';
  frame-ancestors 'self'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
  `Access-Control-Allow-Origin: *` (the token in the path is the capability; module scripts from
  an opaque origin need CORS).
- Routes: `resources :mini_apps, only: %i[index show new create update destroy]` with member
  `get :consent`, `post :bridge`, `get :activity`; `get "mini_app_frames/:token/*path"`.
  All `mini_apps` actions are preview-gated; install/update/consent/destroy need an admin.

### SDK

`packages/miniapp-sdk/sure-miniapp.js` is a dependency-free classic script exposing
`window.SureMiniApp` (also importable as ESM through `index.mjs`), with `index.d.ts` and
`miniapp.schema.json`. `await SureMiniApp.connect()` returns a client with `app`, `permissions`,
`can(p)`, `call(name, args)`, `tools.list()`, typed helpers (`transactions`, `categories`, `tags`,
`merchants`, `accounts`, `rules`, `reports`), `storage.get|set|delete|list`, `on("dataChanged")`,
and automatic `ui/size-changed`. Errors are `SureMiniAppError` with `code` and `data`.

## Open questions

- Granular scopes for existing API keys: migrate `read`/`read_write` keys
  automatically, or keep both? (Needed for the deferred API-key PR.)
- Should hosted (managed) Sure allow zip installs from any source, or only an
  allow-list? v1 allows any zip an admin uploads, behind preview gating.

## Blockers

None.

## Progress

- 2026-11-11: Request recorded with research and a recommended design.
- 2026-11-11: Open questions resolved by the product owner's brief; build contract written; claimed.
- 2026-11-11: v1 built by a coordinated agent workflow (data layer, host JS, SDK/docs, bridge,
  controllers/views, integration, independent security review, fixes). 142 mini app tests pass;
  rubocop, erb_lint, Biome and Brakeman are clean. The full suite's 11 remaining failures are
  environment-only and were failing before this branch (libvips variants, `ANTHROPIC_BASE_URL`
  set in the shell, a date-dependent mobile release tag).
- 2026-11-11: Review fixes: frame responses carry a CSP `sandbox` directive, so a frame URL
  opened at top level still gets an opaque origin; reinstalling an existing app id needs an
  explicit "replace" and resets the write policy to `confirm`; the confirmation dialog lists the
  resolved arguments of the write (`-32005` `data.details`); Approve is inert for 800 ms with
  focus on decline; dev-server apps warn that Sure cannot limit their network access.

## Handoff

Built on `feature/FR-002-miniapps`; not pushed and no PR yet.

Contract deviations: installs only upgrade an existing app id when the admin ticks "Replace the
installed app" (and never across bundle/dev-server); `-32005` gains `data.details`; the frame CSP
adds `sandbox allow-scripts allow-forms allow-popups`.

Left to do:
- Exercise the real `postMessage` round trip in a browser (SDK ↔ host ↔ bridge) with
  `examples/miniapps/recategorizer`, in the web app and in Sure Desktop; add a system test.
- Deferred PRs on this branch: granular scopes for API keys/OAuth, an app-wide CSP.
- Then the pre-PR checklist and a PR.
