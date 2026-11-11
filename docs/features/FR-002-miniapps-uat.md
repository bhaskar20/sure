# FR-002 mini apps: user acceptance test

Date: 2026-11-11. Build: branch `feature/FR-002-miniapps`. Tested by acting as
product manager, family admin, family member and (for Piggy Bank) a parent and
a five-year-old.

## Verdict

**Accepted for preview release** (behind preview-feature gating). The platform
does what FR-002 promises: an admin installs a zip, grants exactly what they
choose, the app runs isolated inside Sure, every write is shown to the person
before it happens, and access can be narrowed, paused or removed instantly.
UAT found six defects; all six are fixed and re-tested. Nothing open blocks a
preview.

Before general availability: test in Sure Desktop, close the tool-catalog gaps
that limit investing apps, and give app developers typed results and a mock
host (see [Follow-ups](#follow-ups)).

| App | Verdict |
| --- | --- |
| Platform (install, consent, sandbox, bridge, confirmation, activity, storage, revoke) | Accept |
| Recategorizer (shipped example) | Accept |
| Piggy Bank (5-year-old savings jar) | Accept; follow up on an alternative to the 2-second hold |
| Goal Planner (goal-based investing) | Accept for preview; needs `get_goals` to avoid duplicates |
| Benchmark Compare (performance vs benchmarks) | Conditional: correct maths, but Sure's tools hide most investment flows, so results are often "can't compare reliably" |

## How it was tested

- Sure ran locally in development against a scratch database loaded with the
  demo family (`demo_data:default`, seed 42): an admin and a member, 8,679
  entries, accounts in USD, GBP and EUR.
- Apps were packed with `bin/miniapp-pack` and installed through the real
  upload form in Chrome, then used by hand. Three apps are test instruments
  (`examples/miniapps/uat/`) that print PASS/FAIL per check.
- The desktop app's built-in browser pane blocks every sandboxed iframe
  (`ERR_BLOCKED_BY_CLIENT`, even for `/up`), so testing used Chrome. This is a
  limit of that pane, not of Sure.
- Member and uninstall checks used the HTTP endpoints with each user's own
  session. One parent flow used the bridge directly (see Piggy Bank).

## Acceptance criteria

| Criterion | Result | Evidence |
| --- | --- | --- |
| Admin installs from a zip, sees the permissions, approves, opens, removes | Pass | Seven apps installed through the form; consent lists each permission, network access and the bundle SHA-256 (matched the packer's); uninstall removed the app, its 5 files and 10 activity rows |
| A sample app built with the SDK lists transactions, creates a category and recategorizes; changes appear in Sure | Pass | Recategorizer listed 8,138 transactions, created "Kids Savings" and moved a Delta Airlines transaction into it; both confirmed in Sure's data |
| A call outside the grants is refused, for read and write | Pass | Probe P04: `get_accounts`/`get_tags` → −32003; escape E12: `create_category` without permission → −32003 with no dialog; revoking `transactions:write` refused the next write |
| No access to other families, Sure's cookies or session, or other apps' storage | Pass | Escape probe 14/14: opaque origin, cookies, local/session storage, parent DOM, `top.location`, Sure's API, outside hosts and spoofed postMessages all blocked. Cross-family and cross-app storage are covered by `bridge_test.rb` |
| Every write is attributed and listed in the app's activity | Pass | Activity rows for each call with user, tool, permission and outcome (ok, denied, declined) |
| An app saves and reads its own data without a migration | Pass | Piggy Bank's savings and Goal Planner's goals survived reloads and upgrades |
| Revoking or uninstalling stops access immediately | Pass | Revoke → −32003 on the next call; disable → −32004 and the frame URL returns 404; uninstall deletes everything |
| Works in the web app and in Sure Desktop with no network | Partial | Web passes, and the apps make no network calls. **Sure Desktop not tested** |
| The guide and starter let someone build an app without reading Sure's source | Partial | Four apps were built from the guide and SDK alone, but their authors read the Ruby tools for argument and result shapes because `index.d.ts` types many results as `Loose` |
| Preview gating, tests, lint, Biome and Brakeman | Pass | 15,590 runs; the 7 failures are environment-only and also fail without this branch. rubocop, erb_lint and Brakeman are clean (0 warnings); Biome is clean with a config that includes `examples/` and `packages/` |

## Control checks

| Check | Result |
| --- | --- |
| Permissions start unticked; the admin opts in to each | Pass |
| Default write policy is "Ask every time" | Pass |
| Reinstalling the same app id without "Replace the installed app" is refused with a clear message | Pass |
| An upgrade keeps storage and still-requested grants and resets the policy to "Ask every time" | Pass |
| The confirmation is drawn by Sure, names the real record and values, and Approve is inert for 0.8 s | Pass (after fixes) |
| Declining returns −32006, changes nothing and sends no data-changed event | Pass |
| A member sees enabled apps only, can open them, cannot install, manage or delete | Pass (consent and delete redirect away) |
| A disabled app disappears for members and its frame URL stops working | Pass |
| Network: the declared origin is reachable; undeclared and sibling hosts are blocked | Pass (3/3) |
| Dev mode is offered only in development and Sure Desktop | Pass |

## Defects found and fixed

| # | Where | Defect | Fix |
| --- | --- | --- | --- |
| 1 | SDK | The frame grew with its content but never shrank (it measured `scrollHeight`, which never drops below the viewport) | Measure the body's own height; documented the rule |
| 2 | Host page | The confirmation dialog sat in the top-left corner over the nav (Tailwind's reset removes `<dialog>` centring) | `m-auto` on the dialog |
| 3 | Confirmation | Amounts showed as bare numbers ("30899.37") and lists as JSON (`["Marcus High-Yield Savings"]`) | Money in the call's, account's or family's currency; plain lists; readable labels |
| 4 | Benchmark Compare | Claimed "Ahead of the S&P 500 by 1,116 percentage points a year": contributions it couldn't see counted as growth | A sustained return above 100% a year now reads "Can't compare reliably" and explains why |
| 5 | Piggy Bank | Coin buttons jumped after the first coin and when a hint appeared, so a child's next taps missed | Space reserved for the coin row; hints overlay instead of pushing content |
| 6 | Goal Planner | Suggested a $915 emergency fund, and offered the house and car as money to earmark | Use average spending when the median is implausibly low; only cash, investment and crypto accounts can be earmarked |

## App findings, as an end user

**Piggy Bank.** A five-year-old gets it at once: a big pig fills up and smiles,
coins show as coins, a teddy goal shows "10 coins to go", and reaching it
throws confetti with "You waited and saved. That is a super power!" The "need
or want?" step and weekly bonus teach the right ideas. The grown-up gate
rejected a short tap with a clear hint. A real deposit goes through Sure's own
approval, and a retry doesn't record it twice. *Not done in the browser:*
browser automation can't hold a button for two seconds, so the grown-up flow
was checked by sending its exact `create_transaction` call through the bridge.

**Goal Planner.** It reads like a planner a person would trust: inflation-
adjusted targets, monthly saving needed, an asset mix that gets more cautious
as the date approaches, and a priority table showing whether the surplus
covers every goal. Creating the goal in Sure showed a clear confirmation and
the goal appeared with the right target and date. Weak spots: it cannot read
goals back from Sure, so it can't stop duplicates, and Sure's `create_goal`
only links cash accounts.

**Benchmark Compare.** Honest framing: it states the data's limits, refuses to
mix currencies and explains its method. With the demo family, most money
reached the investment accounts through trades and balance updates that no
tool exposes, so the honest answer is "can't compare reliably". It needs
investment flows from Sure before it can answer its own question.

**Recategorizer.** Does exactly what it says, and the list refreshes after
each approved change.

## Follow-ups

Platform and SDK:

- Test in Sure Desktop.
- Tool catalog for investing apps: `get_goals`/`update_goal`; `create_goal` to
  accept investment and crypto accounts and account ids; account ids instead
  of names in `get_holdings`; dated balance series; investment activity labels
  and trades on transactions; numeric values next to formatted money in report
  tools; a `writable` flag on accounts.
- A narrower write scope, such as create-only transactions, so a child's app
  doesn't need delete rights.
- Storage compare-and-set, so two people with an app open can't overwrite each
  other.
- Bridge methods for an in-app toast/confirm and for opening a Sure page (a
  goal link from the frame).
- Typed results in `index.d.ts`, a mock host for local development, a packer
  option to exclude test files, and Biome coverage for `examples/` and
  `packages/`.
- Polish: the confirmation repeats "<App> wants to…" twice; the consent page
  shows the write policy even for apps that can't write.

Apps: an alternative to the 2-second grown-up hold (accessibility); a duplicate
check in Goal Planner once `get_goals` exists.

Outside FR-002: the income-statement tool reports median monthly expenses of
$152.50 against an average of $6,080 for the demo family, which also misleads
the AI assistant; and the demo data contains future-dated transactions.
