# @sure/miniapp-sdk

The client SDK for [Sure](https://github.com/we-promise/sure) mini apps: small
web apps that run inside Sure, in a sandboxed frame, and read or change a
family's data only through permissions a family admin granted.

The package contains:

| File | What it is |
| --- | --- |
| `sure-miniapp.js` | The SDK. A dependency-free classic script that sets `window.SureMiniApp`. |
| `index.mjs` | The same SDK as an ES module (`import { connect } from "@sure/miniapp-sdk"`). |
| `index.d.ts` | TypeScript types for every bridge call and tool helper. |
| `miniapp.schema.json` | JSON Schema for `miniapp.json`, the mini app manifest. |

The full developer guide is [`docs/miniapps/README.md`](../../docs/miniapps/README.md).

## Use it

Mini app frames have no network unless the manifest declares it, so ship the
SDK inside your bundle rather than loading it from a CDN. `bin/miniapp-pack`
adds `sure-miniapp.js` to the zip for you.

```html
<script src="sure-miniapp.js"></script>
<script>
  (async () => {
    const sure = await SureMiniApp.connect();

    if (sure.can("transactions:read")) {
      const { transactions } = await sure.transactions.list({ page_size: 10 });
      console.log(transactions);
    }

    await sure.storage.set("settings", "theme", { compact: true });
    sure.on("dataChanged", ({ tool }) => console.log("changed by", tool));
  })();
</script>
```

With a bundler:

```js
import { connect, ErrorCodes, SureMiniAppError } from "@sure/miniapp-sdk";
```

## API

`SureMiniApp.connect(options?)` sends `ui/initialize` to Sure and resolves a
client. It rejects with `NOT_EMBEDDED` when the page is not inside Sure.
Options: `timeout` (ms, default 30000) and `autoResize` (default `true`; posts
`ui/size-changed` whenever the document height changes).

The client has:

- `app`, `user`, `family`, `permissions`, `writePolicy`, `capabilities`,
  `protocolVersion`, `bridgeVersion`, and the raw `info`.
- `can(permission)`: whether a permission is in effect for the current person.
- `call(name, args)`: run any tool by name (MCP `tools/call`). Resolves the
  tool's `structuredContent`. It never times out, because a write can wait for
  the person to confirm it.
- `tools.list()`: the tools this app can call, with their input schemas.
- Typed helpers that map to tool names:

  | Helper | Tool |
  | --- | --- |
  | `accounts.list` / `holdings` / `valuations` | `get_accounts` / `get_holdings` / `get_valuations` |
  | `accounts.recordValuation` / `setOpeningBalance` | `record_valuation` / `set_opening_balance` |
  | `transactions.list` / `recurring` / `uncategorized` / `transferCandidates` | `get_transactions` / `get_recurring_transactions` / `get_uncategorized_transactions` / `get_transfer_match_candidates` |
  | `transactions.create` / `update` / `delete` | `create_transaction` / `update_transaction` / `delete_transaction` |
  | `transactions.matchTransfer` / `unmatchTransfer` / `updateTransfer` / `reviewTransfer` | `match_transfer` / `unmatch_transfer` / `update_transfer` / `review_transfer` |
  | `categories.list` / `create` / `update` / `delete` | `get_categories` / `create_category` / `update_category` / `delete_category` |
  | `tags.list` / `create` / `update` | `get_tags` / `create_tag` / `update_tag` |
  | `merchants.list` | `get_merchants` |
  | `rules.list` / `options` / `preview` / `create` / `update` / `apply` | `get_rules` / `get_rule_options` / `preview_rule` / `create_rule` / `update_rule` / `apply_rule` |
  | `reports.balanceSheet` / `incomeStatement` / `budget` / `insights` | `get_balance_sheet` / `get_income_statement` / `get_budget` / `get_insights` |
  | `budgets.get` / `update` | `get_budget` / `update_budget` |
  | `goals.create` | `create_goal` |

- `storage.get(collection, key)`, `storage.set(collection, key, data)`,
  `storage.delete(collection, key)`, `storage.list(collection, { prefix, limit, cursor })`.
- `on("dataChanged", fn)`, or `on(method, fn)` for any host notification.
  Returns an unsubscribe function.
- `request(method, params, { timeout })` for raw bridge methods, `ping()`, and
  `close()`.

Failed requests reject with `SureMiniAppError` (`code`, `message`, `data`).
`SureMiniApp.ErrorCodes` names every code; see the developer guide for what
each one means. Tools report expected failures, such as a validation error, as
a normal result: `{ success: false, error, message }`.

## License

AGPL-3.0, like Sure.
