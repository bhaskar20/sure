# FR-004: Classify every imported statement line as internal or external

| Field | Value |
| --- | --- |
| Status | In progress |
| Priority | P1 |
| Owner | claude-fr-004 |
| Branch | feature/FR-004-statement-counterparty-classification |
| PR | — |
| Depends on | — |

## Problem

When someone imports statements for several of their own accounts, a lot of
the lines are money moving between those accounts: salary account to savings,
savings to a credit card bill, bank to a brokerage or a wallet, one person's
account to their partner's. Today Sure only notices these when **both legs
already exist** in Sure with the exact same amount within a few days
(`Family#auto_match_transfers!`). Everything else is imported as ordinary
income and spending.

That causes three concrete problems:

1. **Inflated income and spending.** A ₹50,000 move from current account to
   savings shows up as ₹50,000 of spending in one month and ₹50,000 of income
   in the same month. Budgets, the income statement and the assistant's
   answers are wrong until the user fixes each line by hand.
2. **Import order matters.** If the savings statement is imported a week after
   the current account statement, the first import has nothing to pair with,
   and nothing goes back to classify it once the second arrives (except the
   date-window auto matcher, which misses anything outside its window or with
   a fee or FX difference).
3. **Transfers to own accounts that Sure doesn't track** (a wallet, an account
   at a bank the user hasn't added, a spouse's account in the same family) are
   never recognised at all, even though the statement line often says so
   outright ("UPI/…/own a/c", "NEFT to SELF", "IMPS-XXXX1234", "Transfer to
   savings ending 4821", the user's own name as payee).

**Goal:** after publishing any statement import, every line is classified as
one of:

| Class | Meaning | Effect in Sure |
| --- | --- | --- |
| **Internal → tracked account** | Money to/from another account of this family that exists in Sure | Linked as a `Transfer` with the right kind (`funds_movement`, `cc_payment`, `loan_payment`, `investment_contribution`); excluded from or treated in budgets exactly as transfers are today |
| **Internal → untracked own account** | Money to/from an account the family owns but doesn't track in Sure | Kind `funds_movement` (excluded from budgets) and labelled with the counterparty, plus a prompt to add that account |
| **External** | Money to/from anyone else | Ordinary transaction (`standard`), categorised as today |
| **Unknown** | Not enough evidence | Treated as external, flagged for review |

## How we will solve it

### 1. Know the family's own accounts by more than their name

Matching needs identifiers that statement lines actually contain, and today an
`Account` only has `name`, `institution_name` and `institution_domain`
(`AccountStatement::AccountMatcher` scores against those). Add an
**account identifiers** store:

- `account_identifiers` table: `account_id`, `kind`
  (`account_last4`, `card_last4`, `iban_suffix`, `payment_handle` such as a
  UPI VPA, `holder_name`, `alias`), normalised `value`, `source`
  (`statement`, `provider`, `user`, `learned`), `confirmed`.
- Only partial numbers are stored (last 4, IBAN suffix); never full account or
  card numbers. Handles and names are stored as the statement prints them.
- Populated automatically:
  - from each imported statement's header (`account_number`/last 4,
    `account_holder`, IBAN last 4 already parsed by
    `AccountStatement::TextMetadataParser` and the extractor),
  - from provider data where a provider exposes a mask or holder name,
  - from user confirmations in review (step 4), as `learned` aliases.
- Editable on the account settings page ("How this account appears on other
  statements").
- An **untracked own accounts** list on the family (a lightweight record with
  a label and the same identifiers, no balance) so "my wallet" or "my HDFC
  account I don't track" can be named once and recognised forever.

### 2. Extract a counterparty reference from each line

Add a `Transaction::CounterpartyParser` (pure Ruby, rule-based, no model) that
reads the raw description and returns structured hints:

- payment rail and direction: UPI, IMPS, NEFT, RTGS, ACH, SEPA, Faster
  Payments, Zelle, card payment, standing order, autopay;
- counterparty account/card fragments: `XXXX1234`, `ending 1234`, `A/c 1234`,
  IBAN fragments;
- payment handles (`name@bank`), beneficiary names, and "self"/"own account"
  markers;
- known payee patterns for credit card bills, loan EMIs and broker funding
  ("CC PAYMENT", "BILLDESK*CARD", "ZERODHA", "EMI").

The model path in `Provider::Openai::BankStatementExtractor` gains an optional
`counterparty` object per transaction (`{ name, account_fragment, handle,
is_self }`) so model-read statements carry the same hints; the parser runs on
every line anyway so rule-read statements (`Pdf::StatementParser`) get them
without a model. Hints are stored on the import row.

### 3. Score each line against the family's accounts

A new `Import::CounterpartyClassifier` runs after rows are generated (in the
same place reconciliation runs today) and assigns each row a class, a target
account (if any), a confidence and the reasons. Signals, strongest first:

| Signal | Example | Weight |
| --- | --- | --- |
| A learned rule for this description pattern on this account | User confirmed "NEFT-SAVINGS" → Savings before | decisive |
| Counterparty fragment or handle matches an account identifier | `XXXX4821` = Savings `account_last4` | strong |
| A mirror entry already exists in another family account | −50,000 here, +50,000 in Savings within the window (existing `transfer_match_candidates` SQL, reused) | strong |
| Beneficiary name equals an account holder name in the family | "TO A SHARMA" and the statement holder is the same person | medium |
| "Self / own account" marker on the line | `NEFT/SELF`, `own a/c` | medium |
| Payee pattern implies an account type the family has exactly one of | "CREDIT CARD PAYMENT" and the family has one card account | medium |
| Amount is round, recurring monthly, between the same two accounts | Monthly SIP / savings sweep | weak |

Rules of thumb:

- Two strong signals, or a learned rule → **internal, preselected**.
- One strong or two medium signals → **internal, suggested** (shown, not
  preselected).
- Self signals but no tracked account matches → **internal → untracked own**.
- No internal signal → **external**.
- Conflicting signals (e.g. identifier says Savings, mirror entry is in Card)
  → **unknown**, never auto-applied.

Each row keeps the reasons ("account ending 4821", "mirror entry on 12 Mar"),
so the review screen can explain itself and support can debug misclassifies.

### 4. Review before publish

The PDF import review (and the CSV transaction import review, which writes
through the same `Import::Row`) gets a **Counterparty** column:

- a badge: *Own: Savings*, *Own (untracked): Wallet*, *External*, *Unknown*;
- a picker to change it to any family account, an untracked own account,
  "add new account…", or External;
- filters "Show internal only / unknown only" and a bulk "Apply to all lines
  like this" that also saves a learned rule;
- the summary at the top: "14 of 62 lines are transfers between your accounts;
  3 need a decision".

Whenever the user changes a classification, we write a learned rule keyed on
the import account plus a normalised description pattern (via the existing
`Transaction::LabelNormalizer`), so the next statement from the same bank is
right first time. Learned rules are visible and deletable from the rules
page; they can be expressed as a `Rule` with the existing
`set_as_transfer_or_payment` action so no second rules engine appears.

### 5. Publish: link, create, or label

On publish (`PdfImport#import!` / `TransactionImport#import!`):

- **Internal → tracked, counterpart exists:** create a confirmed `Transfer`
  between the new transaction and the existing one (reusing
  `Transfer::Matcher#match_with!` so kind, categories and loan/investment
  rules behave exactly as manual matching does).
- **Internal → tracked, counterpart missing** (that account's statement
  isn't imported yet): create the counterpart leg in the target account via
  `Transfer::Matcher#match_to_account!`, marked as **provisional**
  (`import_id` set, not `reconciled_at`). When that account's own statement is
  imported later, the existing reconciliation (`already_recorded_entry`, same
  date window and amount) recognises the provisional leg as "already recorded"
  and claims it instead of creating a duplicate, upgrading it to reconciled.
  Accounts linked to a live provider are the exception: for those we **don't**
  create a leg (the provider will deliver it) and instead leave a pending
  expectation that `auto_match_transfers!` resolves on the next sync.
- **Internal → untracked own:** kind `funds_movement`, counterparty label
  stored on the transaction.
- **External / unknown:** imported as today; unknown rows keep a review flag.

Reverting the import removes its transfers and provisional legs, as it
already removes its entries.

### 6. Re-classify when the picture changes

A background `Family::CounterpartyReclassifier` job runs when:

- a new account is added or a new statement is published for another account,
- an account identifier is added or edited,
- a learned rule is added.

It re-scores unpaired, not-user-modified transactions from the last N months
(N = 13 by default) and turns new strong matches into **pending** transfers
(the same "Transfer?" suggestion the list already shows), never confirmed
ones: anything decided without the user reviewing it stays a suggestion.
This fixes the import-order problem without silently rewriting history.

## Requirements

- Every row of a statement import (PDF and CSV) is classified as internal
  tracked, internal untracked, external or unknown before publish, with a
  confidence and human-readable reasons.
- Internal-tracked rows identify the target account; publishing links or
  creates the transfer so neither side is counted as income or spending.
- Importing the second statement of a pair never duplicates a transfer leg
  created by the first.
- User corrections are remembered and applied to future imports for that
  account.
- Classification works without any LLM (rules + identifiers + mirror
  entries); the model only adds hints when it is already reading the PDF.
- Accounts store partial identifiers only (last 4, suffixes), never full
  account or card numbers, and identifiers never leave the family.
- Classification respects account access: a member only sees a counterpart
  account name they can see (`Transfer::PendingMatch` rules), and links are
  only created between accounts the importing member can write to.
- Failures and conflicting classifications are logged with
  `DebugLogEntry.capture` (category `import`, with import, account and signal
  metadata, no raw descriptions beyond what support already sees).

## Out of scope

- Matching against accounts of other families (true peer-to-peer between
  different Sure users).
- Splitting one statement line into a transfer plus a fee (handled by the
  existing transfer fee support when both legs exist).
- Changing the `Transfer` model or transaction kinds themselves.
- Provider-synced (non-import) transactions beyond the re-classifier's
  suggestions; providers already run `auto_match_transfers!`.

## Acceptance criteria

- [ ] Importing a current-account statement with a "NEFT to XXXX4821" line,
      when Savings has identifier `4821`, shows the line as *Own: Savings*,
      preselected, with the reason "account ending 4821".
- [ ] Publishing it creates a confirmed `Transfer` and a provisional inflow on
      Savings; the income statement excludes both legs.
- [ ] Importing the Savings statement afterwards reconciles the provisional
      leg and creates no duplicate; the Savings balance is unchanged by the
      second import apart from genuinely new lines.
- [ ] Importing in the opposite order produces the same end state.
- [ ] A credit card bill payment from the bank statement is linked as
      `cc_payment` to the card account.
- [ ] A line to an untracked own account the user defined ("Wallet") is
      `funds_movement` and labelled, and doesn't appear in budgets.
- [ ] Changing a row from External to *Own: Savings* in review and importing
      next month's statement classifies the same pattern correctly without
      input.
- [ ] Conflicting signals produce *Unknown* and are never auto-linked.
- [ ] Reverting the import removes its transfers and provisional legs.
- [ ] With AI disabled, a rule-read statement still gets classified.
- [ ] A member without access to the counterpart account sees "Another
      account" rather than its name, and no link is created to an account
      they can't write to.

## Touches

- New: `account_identifiers` table and `AccountIdentifier` model; untracked
  own accounts (`family_external_accounts` or similar); counterparty columns
  on `import_rows` (`counterparty_class`, `counterparty_account_id`,
  `counterparty_confidence`, `counterparty_reasons` jsonb, `counterparty_hints`
  jsonb); a counterparty label column on `transactions`.
- New: `Transaction::CounterpartyParser`, `Import::CounterpartyClassifier`,
  `Family::CounterpartyReclassifier` (+ job).
- Changed: `PdfImport` row generation and `#import!`, `TransactionImport#import!`,
  `Import::Row`, `Provider::Openai::BankStatementExtractor` prompt/schema,
  `AccountStatement` (write identifiers from statement metadata),
  `Transfer::Matcher` (provisional legs), the import review views, account
  settings view, rules (learned-rule creation).
- Reused, unchanged where possible: `Family::AutoTransferMatchable` candidate
  SQL, `AccountStatement::AccountMatcher`, `Transaction::LabelNormalizer`,
  `Rule` with `set_as_transfer_or_payment`.

## Rollout

Ship behind a preview flag (see
[gating a preview feature](../llm-guides/gating-a-preview-feature.md)) in
three slices, each useful on its own:

1. **Identifiers + mirror-entry matching in review.** Store identifiers from
   statements, score rows using identifiers and existing mirror entries, show
   the Counterparty column, link transfers on publish. No provisional legs.
2. **Provisional legs + order-independence.** Create the missing leg, have
   later imports reconcile it, add untracked own accounts.
3. **Learning + re-classification.** Learned rules from corrections, the
   background re-classifier, account settings UI for identifiers.

Measure on real imports: share of lines classified internal, share the user
changes in review (precision proxy), and share of internal lines the user
adds by hand that we missed (recall proxy).

## Decisions

- 2026-11-22: Classification is rules + identifiers + mirror entries first,
  model hints second, so it works for local-only and AI-disabled families and
  is explainable.
- 2026-11-22: Anything applied without the user reviewing it (re-classifier)
  stays a pending suggestion, matching how `auto_match_transfers!` treats its
  own guesses.
- 2026-11-22 (slice 1): Only PDF statement imports are classified. CSV
  imports can span several accounts per file and are left for later.
- 2026-11-22 (slice 1): Classification itself needs no model, but a PDF
  import still does: `ProcessPdfJob` asks a model to classify and summarize
  the document before extraction.
- 2026-11-22 (slice 1): Rows are classified while any household member has
  opted into preview features, because the job has no current user. The
  Counterparty column and picks are shown per user. When a member without
  preview access publishes, every classification is dropped first, so lines
  are never linked by someone who could not see the classification.
- 2026-11-22 (slice 1): Internal lines publish with a transfer kind and no
  category.
  - A line with a mirror entry is linked as a confirmed transfer through
    `Transfer::Matcher`, one savepoint per line.
  - A tracked-account line without a mirror keeps its transfer kind, unlinked.
    No provisional legs are created; `auto_match_transfers!` pairs it once the
    other side arrives.
  - An untracked-own line becomes `funds_movement`.
- 2026-11-22 (slice 1): Lines paid by or to a household member's own name are
  internal (not a separate "household" class), and so is a card bill payment
  on the card's own statement. Mirrors must be in the same currency and within
  7 days.
- 2026-11-22 (slice 1): `Pdf::StatementParser` keeps a row's detail lines
  across one blank line and over stray margin characters. Real DBS statements
  put the "FROM:"/"TO:" lines there, and without them the counterparty is
  lost.
- 2026-11-22 (slice 1): Publishing is the only time classifications are
  applied to a publisher. Under the import's lock, once the publish checks
  pass, a member without preview access gets plain lines. Any other member
  keeps links only to accounts they can write to; the rest become
  "not sure". Rows cannot be edited once publishing starts.
- 2026-11-22 (slice 1): Reverting or deleting a published import undoes the
  transfers it made and gives each counterpart back its earlier kind and
  category, kept on the row when the link was made. A counterpart unlinked or
  relinked since is left alone.
- 2026-11-22 (slice 1): SELF / OWN ACCOUNT count only in transfer wording, and
  never on fee lines. Only a known wallet that is itself topped up counts as
  own money; any other top-up word must match an account's name.
- 2026-11-22 (slice 1): Identifier values are encrypted deterministically
  when encryption is configured, so the per-account uniqueness still holds.
  Only partial numbers (last four) and holder names are stored.

## Open questions

- Should provisional legs be created on manual accounts that use balance
  anchors (valuations), or only suggested there? (Product owner.)
- Do spouses/partners in the same family count as "internal" for budgets, or
  should they be a fourth class ("household")? (Product owner.)
- How long should the re-classifier look back by default — 13 months, or the
  full history on first run? (Product owner, perf check on large families.)
- Which locales' rails and description formats are in the first parser set
  (India UPI/IMPS/NEFT, EU SEPA, US ACH/Zelle, UK FPS)? (Product owner.)

## Blockers

None.

## Progress

- 2026-11-22: Spec drafted.
- 2026-11-22: Slice 1 built: identifiers, counterparty parser, classifier,
  review column, and transfer linking on publish. It was checked locally
  against real Singapore and Indian bank statements (DBS/POSB, SCB). No
  statement data was committed.

## Handoff

Slice 1 is on `feature/FR-004-statement-counterparty-classification`.
Slices 2 (provisional legs, untracked own accounts) and 3 (learned rules,
re-classifier, identifier settings UI) are not started.
