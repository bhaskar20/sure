# Building Sure mini apps

A mini app is a small web app (HTML, JavaScript and CSS) that runs inside Sure.
It has its own page under **Apps**, and it reads and changes a family's data
through the same tools that Sure's assistant and MCP server use, limited to the
permissions a family admin granted it.

You do not need Sure's source code to build one. You need:

- the SDK, [`packages/miniapp-sdk/sure-miniapp.js`](../../packages/miniapp-sdk/sure-miniapp.js)
  (also published as `@sure/miniapp-sdk`, with [TypeScript types](../../packages/miniapp-sdk/index.d.ts));
- a manifest, `miniapp.json`, validated by [the manifest schema](../../packages/miniapp-sdk/miniapp.schema.json);
- a starting point: [the starter template](../../examples/miniapps/starter/) or
  [the recategorizer sample](../../examples/miniapps/recategorizer/).

Mini apps are a preview feature. Turn on **Settings → Preferences → Preview
features** to see **Apps** in the navigation.

## Concepts

| Term | Meaning |
| --- | --- |
| Mini app | A static bundle: a folder with `miniapp.json` and the files it serves. |
| Manifest | `miniapp.json`. Names the app, its entry file and the permissions it requests. |
| Bridge | The JSON-RPC 2.0 channel between the app's frame and Sure, carried by `postMessage`. |
| Tool | A named operation such as `get_transactions` or `update_transaction`. The same tools power the assistant and `/mcp`. |
| Permission | A grant such as `transactions:write`. Each tool needs exactly one. |
| Write policy | `confirm` (default): Sure asks the person before every write. `allow`: writes go through. Set by the admin. |
| Storage | A per-app key-value store for settings and records. No database migrations. |
| Activity | Sure's log of every tool call the app made, with its outcome. |

## Security model

Mini apps are third-party code, so Sure treats them as untrusted.

- **Sandboxed frame with an opaque origin.** The app runs in
  `<iframe sandbox="allow-scripts allow-forms allow-popups">`, never with
  `allow-same-origin`. It cannot read Sure's cookies, session, DOM or storage,
  and it cannot read another app's frame. `localStorage`, `sessionStorage`,
  IndexedDB and cookies are unavailable inside the frame; use the bridge's
  storage instead.
- **No tokens in the frame.** Sure never gives the app an API key or session
  token. Every request goes through the bridge and runs as the person who has
  the app open, in their family, with their account access.
- **Strict content security policy.** Bundled files are served with:

  ```
  sandbox allow-scripts allow-forms allow-popups;
  default-src 'none'; script-src <frame base> 'unsafe-inline';
  style-src <frame base> 'unsafe-inline'; img-src <frame base> data: blob:;
  font-src <frame base> data:; connect-src <manifest network or 'none'>;
  form-action 'none'; base-uri 'none'; frame-ancestors 'self'
  ```

  The `sandbox` directive keeps every bundle file on an opaque origin even
  when its URL is opened directly in a tab, so app code never runs as Sure.

  Scripts, styles, images and fonts must come from your bundle. Nothing loads
  from a CDN.
- **No network unless declared.** `fetch`, XHR and WebSockets reach only the
  HTTPS origins listed in the manifest's `network` field. With no `network`
  entries the app is fully offline.
- **Server-side permission checks.** Every call is checked against the
  permissions the admin granted, on the server, on every call. Guests get read
  permissions only, whatever is granted.
- **Host-drawn confirmation.** With the `confirm` write policy, Sure shows its
  own dialog, outside the frame, before every write. The dialog lists what the
  call would change, worked out by Sure from the call's real arguments (the
  record, amounts, category and so on), not from anything the app shows. The
  app cannot draw, fake or click it, and **Allow** only becomes clickable a
  moment after the dialog opens.
- **Everything is on the record.** Every tool call, allowed, denied, declined
  or failed, appears in the app's activity view with the person, tool and
  permission.
- **Kill switch.** An admin can change grants, disable the app (all calls stop
  at once) or uninstall it (its files, storage and activity are deleted).

## Permissions

Request only what you use. The admin sees each permission at install and can
grant any subset.

| Permission | Tools |
| --- | --- |
| `accounts:read` | `get_accounts`, `get_holdings`, `get_valuations` |
| `transactions:read` | `get_transactions`, `get_recurring_transactions`, `get_uncategorized_transactions`, `get_transfer_match_candidates` |
| `transactions:write` | `create_transaction`, `update_transaction`, `delete_transaction`, `match_transfer`, `unmatch_transfer`, `update_transfer`, `review_transfer` |
| `categories:read` | `get_categories` |
| `categories:write` | `create_category`, `update_category`, `delete_category` |
| `tags:read` | `get_tags` |
| `tags:write` | `create_tag`, `update_tag` |
| `merchants:read` | `get_merchants` |
| `rules:read` | `get_rules`, `get_rule_options`, `preview_rule` |
| `rules:write` | `create_rule`, `update_rule`, `apply_rule` |
| `reports:read` | `get_balance_sheet`, `get_income_statement`, `get_budget`, `get_insights` |
| `budgets:write` | `update_budget` |
| `goals:write` | `create_goal` |
| `valuations:write` | `record_valuation`, `set_opening_balance` |

A tool is callable only when it is in this table and also available to the
person in Sure (some tools depend on configuration). `tools/list` returns
exactly what the app can call right now.

## Manifest reference

```json
{
  "id": "com.example.recategorizer",
  "name": "Recategorizer",
  "version": "1.0.0",
  "description": "Moves transactions between categories.",
  "entry": "index.html",
  "icon": "tags",
  "permissions": ["transactions:read", "transactions:write", "categories:read", "categories:write"],
  "slots": ["page"],
  "network": [],
  "author": "Example Ltd",
  "homepage": "https://example.com/recategorizer"
}
```

| Field | Required | Rules |
| --- | --- | --- |
| `id` | yes | `^[a-z0-9][a-z0-9.-]{2,63}$`. Stable: installing a bundle with the same `id` upgrades the app and keeps its storage, but only when the admin ticks **Replace the installed app**; otherwise the install is refused. |
| `name` | yes | At most 60 characters. |
| `version` | yes | Letters, digits, `.`, `+` and `-`, at most 32 characters. Shown to the admin. |
| `description` | no | At most 500 characters. |
| `entry` | no | HTML file to open, relative to the bundle root. Default `index.html`. Must exist. |
| `icon` | no | A [Lucide](https://lucide.dev/icons) icon name (`^[a-z0-9-]{1,40}$`). Default `blocks`. |
| `permissions` | no | Values from the permissions table. |
| `slots` | no | Only `page` in bridge version 1. Default `["page"]`. |
| `network` | no | HTTPS origins (`https://host` or `https://host:port`) the app may call. |
| `author`, `homepage` | no | Shown at install. `author` is at most 100 characters. Unknown keys are ignored. |

On upgrade, grants for permissions the new manifest no longer requests are
dropped. New permissions are not granted until an admin approves them. The
write policy goes back to `confirm`, so the new version cannot change data
without asking until the admin allows it again. An app installed from a zip
cannot be upgraded from a dev server, or the other way round; uninstall it
first.

To get editor validation, map `miniapp.json` to
`packages/miniapp-sdk/miniapp.schema.json` in your editor's JSON schema
settings.

## The bridge

The frame and Sure exchange [JSON-RPC 2.0](https://www.jsonrpc.org/specification)
messages with `postMessage`. The frame posts to `window.parent` with target
origin `*` (its own origin is opaque, so it cannot name one) and accepts
messages only from `window.parent`. Sure accepts messages only from the app's
frame. The SDK does all of this for you.

The format follows [MCP Apps](https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp):
`ui/initialize`, `tools/list` and `tools/call` behave as MCP defines them, and
tool names and input schemas are those of Sure's MCP server. Sure-specific
methods live under `sure/` and `notifications/sure/`.

### Methods

| Method | Params | Result |
| --- | --- | --- |
| `ui/initialize` | `{ protocolVersion, clientInfo, appCapabilities }` | `{ protocolVersion: "2026-11-11", bridgeVersion: 1, hostInfo: { name: "Sure" }, app: { id, name, version }, permissions, writePolicy, user: { name, role }, family: { currency, locale, dateFormat }, capabilities: { tools, storage, events } }` |
| `tools/list` | `{}` | `{ tools: [{ name, description, inputSchema, permission, write }] }`, only the callable tools |
| `tools/call` | `{ name, arguments }` | `{ content: [{ type: "text", text }], structuredContent }`. When the tool raises: `isError: true` with a generic message. |
| `sure/storage/get` | `{ collection, key }` | The record's `{ key, data, updatedAt }`, or no `data` when absent |
| `sure/storage/set` | `{ collection, key, data }` | The saved record |
| `sure/storage/delete` | `{ collection, key }` | Confirmation |
| `sure/storage/list` | `{ collection, prefix?, limit? (≤ 200), cursor? }` | `{ items: [{ key, data, updatedAt }], nextCursor }` |
| `ping` | `{}` | `{}` |

Tools report expected failures (not found, validation) inside a normal result
as `{ success: false, error, message }`. Check `success` on write results.

### Notifications

| Direction | Method | Params |
| --- | --- | --- |
| Sure → app | `notifications/sure/data_changed` | `{ tool }`, sent after each successful write this app made |
| App → Sure | `ui/size-changed` | `{ height }`; Sure resizes the frame. The SDK sends it automatically. |

### Error codes

| Code | Name in `ErrorCodes` | Meaning |
| --- | --- | --- |
| `-32601` | `METHOD_NOT_FOUND` | Unknown method, or a tool that mini apps cannot call. |
| `-32602` | `INVALID_PARAMS` | Missing or malformed parameters, including storage limits. |
| `-32003` | `PERMISSION_DENIED` | The permission is not granted. `data.permission` names it. |
| `-32004` | `APP_DISABLED` | An admin disabled the app. |
| `-32005` | `CONFIRMATION_REQUIRED` | Handled by Sure: it asks the person and retries. Apps do not see it. `data: { tool, permission, summary, details: [{ label, value }] }`. |
| `-32006` | `DECLINED` | The person declined the write in Sure's dialog. |
| `-32029` | `RATE_LIMITED` | More than 120 tool calls per minute for this app and person. |
| `-32000` | `TOOL_ERROR` | SDK only: the tool raised (`isError: true`). |
| `-32098` | `TIMEOUT` | SDK only: a non-tool request got no answer in 30 s. |
| `-32099` | `NOT_EMBEDDED` | SDK only: the page is not running inside Sure. |

## SDK

Load the SDK as a classic script from your bundle:

```html
<script src="sure-miniapp.js"></script>
<script src="app.js"></script>
```

```js
const sure = await SureMiniApp.connect();

sure.app;          // { id, name, version }
sure.user;         // { name, role }
sure.family;       // { currency, locale, dateFormat }
sure.permissions;  // effective permissions for this person
sure.can("transactions:write");

const { transactions } = await sure.transactions.list({ page_size: 20, categories: ["Uncategorized"] });
const { categories } = await sure.categories.list({ page_size: 100 });
const created = await sure.categories.create({ name: "Coffee" });
if (created.success) {
  await sure.transactions.update({ id: transactions[0].id, category_id: created.category.id });
}

await sure.call("get_merchants", { search: "coffee" }); // any tool by name
await sure.tools.list();

sure.on("dataChanged", ({ tool }) => refresh());
```

- `connect()` returns the same client on repeated calls.
- `call()` and the helpers resolve the tool's `structuredContent`. They never
  time out, because a write can wait for a person to answer the confirmation
  dialog. Other requests time out after 30 seconds.
- Errors are `SureMiniAppError` with `code`, `message` and `data`:

  ```js
  try {
    await sure.transactions.update({ id, category_id });
  } catch (error) {
    if (error.code === SureMiniApp.ErrorCodes.DECLINED) showMessage("Not changed.");
    else if (error.code === SureMiniApp.ErrorCodes.PERMISSION_DENIED) showMessage(`Needs ${error.data.permission}`);
    else throw error;
  }
  ```

The [SDK README](../../packages/miniapp-sdk/README.md) lists every helper and
the tool it calls. Read argument shapes in `index.d.ts`, or call
`sure.tools.list()` for the live JSON schemas.

## Storage

Each app has its own store, separate from every other app and family.

- `sure.storage.set(collection, key, data)`, `get`, `delete`, and
  `list(collection, { prefix, limit, cursor })`.
- `collection`: `^[a-z0-9_-]{1,64}$`. `key`: 1 to 255 characters. `data`: any
  JSON value up to 256 KB.
- At most 5,000 records per app. `list` returns up to 200 items per page; pass
  `nextCursor` back as `cursor` for the next page.
- Storage survives upgrades and is deleted when the app is uninstalled.
- Storage is shared by every member of the family who opens the app. Key
  records by person yourself if you need per-person data.

## Dev mode

Dev mode loads your app from a local web server, so you can edit files and
reload without packaging. It is available in development and in self-hosted
installs, including Sure Desktop.

1. Copy the SDK into your app folder (the packer adds it automatically to
   zips, but a dev server serves the folder as is):

   ```sh
   bin/miniapp-pack examples/miniapps/starter --sdk
   ```

2. Serve the folder:

   ```sh
   cd examples/miniapps/starter
   python3 -m http.server 5174
   ```

3. In Sure, open **Apps → Install**, choose the local URL option and enter
   `http://localhost:5174`. Sure reads `miniapp.json` from that URL, shows the
   permissions, and installs the app as a dev-server app.
4. Open the app and reload the page after each change.

Notes:

- The frame is still sandboxed with an opaque origin. Classic
  `<script src>` tags work from any server. ES module scripts need the server
  to send `Access-Control-Allow-Origin: *`, which `python3 -m http.server` does
  not, so use classic scripts or a dev server that sends CORS headers.
- Sure's frame CSP applies to installed bundles only. A dev-server app can
  reach any server, whatever its `network` field says, and Sure says so on the
  consent and app pages. Test with the zip before you ship, so you catch a CDN
  link or undeclared network call.

## Packaging

```sh
bin/miniapp-pack path/to/my-app                 # writes <id>-<version>.zip
bin/miniapp-pack path/to/my-app -o dist/app.zip
```

The packer checks that `miniapp.json` exists and is valid, that the entry file
exists, and that the bundle fits Sure's limits. It adds
`packages/miniapp-sdk/sure-miniapp.js` as `sure-miniapp.js` unless your folder
already has one, skips hidden files, `node_modules` and zips, and prints the
bundle's SHA-256.

Bundle rules Sure enforces at install:

- `miniapp.json` at the root of the zip (one wrapping folder is allowed).
- At most 10 MB zipped, 20 MB unpacked and 300 files.
- No absolute paths, no `..`, no symlinks; the entry file must exist.

## Installing

1. A family admin opens **Apps → Install** and uploads the zip.
2. Sure shows the app's name, version, the bundle's SHA-256 and every requested
   permission. Compare the SHA-256 with the one `bin/miniapp-pack` printed.
3. The admin grants any subset of the permissions and picks the write policy
   (`confirm` by default).
4. Every non-guest member can then open the app from **Apps**.

Admins can change grants and the write policy, disable, re-enable, upgrade (by
uploading a newer zip with the same `id` and ticking **Replace the installed
app**) or uninstall the app at any time, and
review its activity.

## Offline and Sure Desktop

Installed bundles are stored by Sure and served from Sure itself, so an app
with no `network` entries works with no internet connection, including in Sure
Desktop. Do not load fonts, scripts or styles from a CDN; ship them in the
bundle.

## MCP alignment

The bridge uses MCP Apps' messages and Sure's MCP tool catalog. The calls an
app makes with `tools/call` are the same tools, with the same arguments, that
an MCP client can call on Sure's `/mcp` endpoint. A mini app written against
these tools can later be served as an MCP App to clients such as Claude, and
an integration prototyped over MCP can become a mini app without changing its
calls.

## Examples

- [Starter](../../examples/miniapps/starter/): connects, lists its
  permissions, reads accounts and saves a note in storage.
- [Recategorizer](../../examples/miniapps/recategorizer/): lists transactions,
  creates a category, recategorizes a selected transaction, remembers its
  filter in storage and refreshes when data changes.
