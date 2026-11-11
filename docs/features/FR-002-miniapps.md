# FR-002: Mini apps — plug-in apps with their own UI and data access

| Field | Value |
| --- | --- |
| Status | Proposed |
| Priority | P1 |
| Owner | — |
| Branch | — |
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

Expected areas; refine before building.

- New models: `MiniApp`, `MiniApp::Installation` (per family, granted
  permissions), `MiniApp::Record` (mini app data), activity/audit records.
- New controllers and views for the mini apps settings page, the install and
  consent flow, and the page or panel that hosts the iframe.
- `app/javascript/controllers/`: the bridge Stimulus controller.
- `config/initializers/content_security_policy.rb`: enable a policy.
- `config/initializers/doorkeeper.rb`, `app/models/api_key.rb`: granular
  scopes.
- `app/controllers/api/v1/` and `app/models/assistant/function/`: share the
  service layer with the bridge.
- `app/controllers/mcp_controller.rb`: optionally serve mini app UIs as MCP
  Apps resources.
- New `docs/miniapps/` developer guide and a separate SDK package.

## Decisions

- 2026-11-11: Build as one feature. Granular scopes, the shared service layer
  and enabling CSP are part of FR-002, not separate features; they can still
  land as separate PRs on the feature branch.

## Open questions

- **Which extension slots in the first version?** A sidebar page is the
  simplest; panels on account/transaction detail and dashboard widgets need
  more design work.
- **Who may install?** Family admins only, or any member? Self-hosted
  instance admins may also want to allow-list mini apps for every family.
- **Trust and distribution.** Install from any zip/URL, or only signed bundles
  from a list Sure maintains? A hosted Sure needs a stricter answer than a
  self-hosted or desktop install.
- **How far to align with MCP Apps?** Use its message format and SDK directly,
  or a Sure-specific bridge modeled on it?
- **Mini app logic without UI** (scheduled jobs, reacting to new
  transactions while no one has it open): needed in the first version, or
  later via webhooks or a QuickJS sandbox?
- **Granular scopes for existing API keys:** migrate `read`/`read_write` keys
  to the new scopes automatically, or keep both?

## Blockers

Waiting on answers to the open questions about extension slots, trust and
distribution, and how far to align with MCP Apps, before moving to `Ready`.

## Progress

- 2026-11-11: Request recorded with research and a recommended design.

## Handoff

Not started.
