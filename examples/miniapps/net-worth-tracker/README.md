# Net Worth Tracker

A Sure mini app for people who tracked net worth in a spreadsheet: one row per
account, one column per month.

- **Import spreadsheet** reads the sheet exported as CSV, checks its reading
  against the sheet's own TOTAL rows, and maps each row to a new or existing
  Sure account. Every month's value becomes a valuation on that account, dated
  the month's last day (today for the month in progress)
  (`create_account`, `record_valuations`). Running it again reuses the accounts
  it created and replaces values on the same dates, so it is safe to repeat.
- **Monthly entry** is a form with one field per tracked account, in that
  account's own currency, and a note. Saving records each filled-in value in Sure
  (`record_valuation`) dated the day it is entered.
- **History** shows Sure's balance sheet per month (`get_balance_sheet`):
  assets, liabilities and net worth in the family currency, converted with
  the exchange rates Sure fetches. Set the currency in Settings → Preferences
  and the rate provider in Settings → Self-Hosting (Frankfurter needs no key).

Sure holds the balances and does every currency conversion. The app's own
storage keeps only which accounts it tracks, each month's entered values and
note; it stores no exchange rates. The file's rate rows are used only to check
the import against its TOTAL rows.

Expected CSV layout: a header row with months from the fourth column
(`Jan 2023`, `April 2023`, or a bare year for December), exchange-rate rows
with a blank name and a currency code, asset rows (`name,currency,,values…`),
a `TOTAL` row, liability rows, a second `TOTAL` row and an optional `comment`
row. Columns that are not months (such as `GAP`) and rows after the second
`TOTAL` are ignored.

Permissions: `accounts:read`, `accounts:write`, `valuations:write`,
`reports:read`. The write
tools are preview tools, so the person needs preview features turned on. An
import makes one write per new account plus one per 120 values; set the app to
"Allow writes" on the Apps page to skip a confirmation for each.

Pack it with `bin/miniapp-pack examples/miniapps/net-worth-tracker`.
