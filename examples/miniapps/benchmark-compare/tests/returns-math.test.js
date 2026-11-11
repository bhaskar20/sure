// Run with: node --test examples/miniapps/benchmark-compare/tests/returns-math.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../returns-math.js");
const DATA = require("../benchmarks-data.js");

const d = M.toDay;
const close = (actual, expected, tolerance = 1e-6) =>
  assert.ok(
    Math.abs(actual - expected) <= tolerance,
    `expected ${expected}, got ${actual}`,
  );

test("seriesPoints rebuilds weekly dates and appends the end date", () => {
  const { points, exact } = M.seriesPoints({
    start_date: "2024-01-01",
    end_date: "2024-01-20",
    interval: "1 week",
    values: [100, 101, 102, 103],
  });
  assert.equal(exact, true);
  assert.deepEqual(
    points.map((p) => M.fromDay(p.day)),
    ["2024-01-01", "2024-01-08", "2024-01-15", "2024-01-20"],
  );
});

test("seriesPoints steps months like Postgres and falls back when counts disagree", () => {
  const monthly = M.seriesPoints({
    start_date: "2024-01-31",
    end_date: "2024-04-30",
    interval: "1 month",
    values: [1, 2, 3, 4, 5],
  });
  assert.equal(monthly.exact, true);
  assert.deepEqual(
    monthly.points.map((p) => M.fromDay(p.day)),
    ["2024-01-31", "2024-02-29", "2024-03-29", "2024-04-29", "2024-04-30"],
  );

  const odd = M.seriesPoints({
    start_date: "2024-01-01",
    end_date: "2024-01-11",
    interval: "1 day",
    values: [1, 2, 3],
  });
  assert.equal(odd.exact, false);
  assert.deepEqual(odd.points.map((p) => M.fromDay(p.day)), ["2024-01-01", "2024-01-06", "2024-01-11"]);
});

test("time-weighted return ignores contributions", () => {
  // 1000 grows 10%, then 1000 is added, then everything grows 10%.
  const grid = [
    { day: d("2024-01-01"), value: 1000 },
    { day: d("2024-07-01"), value: 2100 },
    { day: d("2025-01-01"), value: 2310 },
  ];
  const flows = [{ day: d("2024-07-01"), amount: 1000 }];
  const twr = M.timeWeighted(grid, flows);
  close(twr.cumulative, 0.21);
  assert.equal(twr.skipped, 0);
});

test("raw growth with no flows equals the balance change", () => {
  const grid = [
    { day: d("2024-01-01"), value: 1000 },
    { day: d("2025-01-01"), value: 1080 },
  ];
  close(M.timeWeighted(grid, []).cumulative, 0.08);
});

test("annualize needs at least a year", () => {
  assert.equal(M.annualize(0.1, 200), null);
  close(M.annualize(0.21, 2 * 365.25), 0.1);
});

test("xirr solves a known case", () => {
  // -1000 now, +1100 a year later: 10%.
  close(
    M.xirr([
      { day: d("2023-01-01"), amount: -1000 },
      { day: d("2024-01-01"), amount: 1100 },
    ]),
    0.1,
    2e-3,
  );
  // Excel's documented XIRR example: 0.373362535.
  close(
    M.xirr([
      { day: d("2008-01-01"), amount: -10000 },
      { day: d("2008-03-01"), amount: 2750 },
      { day: d("2008-10-30"), amount: 4250 },
      { day: d("2009-02-15"), amount: 3250 },
      { day: d("2009-04-01"), amount: 2750 },
    ]),
    0.3734,
    2e-3,
  );
  assert.equal(M.xirr([{ day: 0, amount: -1 }]), null);
});

test("money-weighted return punishes a badly timed contribution", () => {
  // Small start, big deposit right before a fall: TWR is about flat but the
  // money-weighted return is clearly negative.
  const grid = [
    { day: d("2024-01-01"), value: 1000 },
    { day: d("2024-06-30"), value: 11200 },
    { day: d("2024-12-31"), value: 10080 },
  ];
  const flows = [{ day: d("2024-06-30"), amount: 10000 }];
  const twr = M.timeWeighted(grid, flows).cumulative;
  const mwr = M.moneyWeighted(grid, flows);
  close(twr, 1.2 * 0.9 - 1, 1e-9);
  assert.ok(mwr < -0.1, `mwr ${mwr}`);
});

test("buildPortfolio sums accounts and adds unexplained opening balances", () => {
  const a = { id: "a", points: [
    { day: d("2024-01-01"), value: 100 },
    { day: d("2024-02-01"), value: 110 },
    { day: d("2024-03-01"), value: 120 },
  ] };
  const b = { id: "b", points: [
    { day: d("2024-02-01"), value: 500 },
    { day: d("2024-03-01"), value: 500 },
  ] };
  const flows = [{ day: d("2024-02-01"), amount: 200, accountId: "b" }];
  const { grid, flows: out } = M.buildPortfolio([a, b], flows);
  assert.deepEqual(grid.map((p) => p.value), [100, 610, 620]);
  const opening = out.find((f) => f.synthetic);
  assert.equal(opening.amount, 300);
  assert.equal(out.reduce((s, f) => s + f.amount, 0), 500);
});

test("clipGrid interpolates the window edges", () => {
  const grid = [
    { day: d("2025-01-01"), value: 100 },
    { day: d("2025-12-01"), value: 200 },
    { day: d("2026-01-01"), value: 300 },
  ];
  const clipped = M.clipGrid(grid, d("2024-06-01"), d("2025-12-31"));
  assert.deepEqual(clipped.map((p) => M.fromDay(p.day)), ["2025-01-01", "2025-12-01", "2025-12-31"]);
  close(clipped[2].value, 200 + (100 * 30) / 31);
});

test("benchmark index compounds annual returns and interpolates inside a year", () => {
  const index = M.buildIndex({ 2020: 10, 2021: -10 });
  close(index.levelAt(d("2019-12-31")), 1);
  close(index.levelAt(d("2020-12-31")), 1.1);
  close(index.levelAt(d("2021-12-31")), 0.99);
  const mid = index.levelAt(d("2020-07-01"));
  assert.ok(mid > 1.04 && mid < 1.06);
  assert.equal(index.levelAt(d("2022-06-01")), null);
});

test("benchmark index supports a partial last year and stops at gaps", () => {
  const index = M.buildIndex({ 2018: 5, 2020: 10, 2021: { r: 6, through: "2021-06-30" } });
  assert.equal(index.firstYear, 2020);
  assert.equal(M.fromDay(index.endDay), "2021-06-30");
  close(index.levelAt(d("2021-06-30")), 1.1 * 1.06);
});

test("replaying flows into a benchmark", () => {
  const index = M.buildIndex({ 2020: 10, 2021: 10 });
  const grid = [
    { day: d("2019-12-31"), value: 1000 },
    { day: d("2020-12-31"), value: 2000 },
    { day: d("2021-12-31"), value: 2000 },
  ];
  const flows = [{ day: d("2020-12-31"), amount: 1000 }];
  const replay = M.replayFlows(index, grid, flows);
  close(replay[1].value, 2100);
  close(replay[2].value, 2310);
});

test("blendReturns weights components year by year", () => {
  const blend = M.blendReturns([
    { weight: 0.6, returns: { 2020: 10, 2021: 20 } },
    { weight: 0.4, returns: { 2020: 0, 2022: 5 } },
  ]);
  assert.deepEqual(Object.keys(blend), ["2020"]);
  close(blend[2020], 6);
});

test("calendar years and best/worst prefer full years", () => {
  const index = M.buildIndex({ 2020: 10, 2021: -5, 2022: 20 });
  const series = [];
  for (let day = d("2020-06-30"); day <= d("2022-12-31"); day += 7) {
    series.push({ day, value: index.levelAt(day) });
  }
  series.push({ day: d("2022-12-31"), value: index.levelAt(d("2022-12-31")) });
  const years = M.calendarYears(series);
  assert.deepEqual(years.map((y) => [y.year, y.partial]), [[2020, true], [2021, false], [2022, false]]);
  close(years[1].r, -0.05, 3e-3);
  const { best, worst } = M.bestAndWorst(years);
  assert.equal(best.year, 2022);
  assert.equal(worst.year, 2021);
});

test("classifyTransactions separates flows, income, internal transfers and currency mismatches", () => {
  const accounts = {
    Brokerage: { id: "a1", currency: "USD" },
    IRA: { id: "a2", currency: "USD" },
  };
  const txns = [
    { id: "1", date: "2024-01-05", amount: 500, classification: "income", account: "Brokerage", is_transfer: true, transfer_account: "Checking", currency: "USD" },
    { id: "2", date: "2024-01-06", amount: 300, classification: "expense", account: "Brokerage", is_transfer: true, transfer_account: "IRA", currency: "USD" },
    { id: "3", date: "2024-01-07", amount: 12, classification: "income", account: "Brokerage", name: "VTI Dividend", currency: "USD" },
    { id: "4", date: "2024-01-08", amount: 200, classification: "income", account: "IRA", name: "Employer contribution", currency: "USD" },
    { id: "5", date: "2024-01-09", amount: 50, classification: "expense", account: "IRA", name: "Something", currency: "USD" },
    { id: "6", date: "2024-01-10", amount: 70, classification: "income", account: "IRA", name: "Deposit", currency: "EUR" },
    { id: "7", date: "2024-01-11", amount: 70, classification: "expense", account: "IRA", name: "Withdrawal", currency: "USD", pending: true },
  ];

  const auto = M.classifyTransactions(txns, { accounts });
  assert.deepEqual(auto.flows.map((f) => [f.id, f.amount]), [["1", 500], ["4", 200]]);
  const reasons = Object.fromEntries(auto.others.map((o) => [o.id, o.reason]));
  assert.deepEqual(reasons, {
    2: "internal_transfer",
    3: "income_or_fee",
    5: "unclassified",
    6: "currency",
    7: "pending",
  });

  const all = M.classifyTransactions(txns, { accounts, mode: "all" });
  assert.deepEqual(all.flows.map((f) => [f.id, f.amount]), [["1", 500], ["4", 200], ["5", -50]]);

  const none = M.classifyTransactions(txns, { accounts, mode: "none", overrides: { 3: "flow" } });
  assert.deepEqual(none.flows.map((f) => f.id), ["3"]);
});

test("parse and format the benchmark editor text", () => {
  const { returns, errors } = M.parseReturnsText("# comment\n2024: 25,0%\n2025 = -3.5\n2026: 7 through 2026-10-31");
  assert.deepEqual(errors, []);
  assert.deepEqual(returns, { 2024: 25, 2025: -3.5, 2026: { r: 7, through: "2026-10-31" } });
  assert.equal(M.formatReturnsText(returns), "2024: 25\n2025: -3.5\n2026: 7 through 2026-10-31");

  assert.equal(M.parseReturnsText("2024: abc").errors.length, 1);
  assert.equal(M.parseReturnsText("2024: 5 through 2025-01-01").errors.length, 1);
  assert.equal(M.parseReturnsText("2024: 1 through 2024-06-30\n2025: 2").errors.length, 1);
});

test("the bundled dataset is contiguous and the 60/40 blend resolves", () => {
  const byId = Object.fromEntries(DATA.benchmarks.map((b) => [b.id, b]));
  for (const b of DATA.benchmarks.filter((x) => x.returns)) {
    const index = M.buildIndex(b.returns);
    assert.equal(index.firstYear, 2000, b.id);
    assert.equal(M.fromDay(index.endDay), `${DATA.asOfYear}-12-31`, b.id);
  }
  const blend = M.blendReturns(
    byId["sixty-forty"].blend.map((c) => ({ weight: c.weight, returns: byId[c.id].returns })),
  );
  close(blend[2008], 0.6 * -37 + 0.4 * 5.2);
});
