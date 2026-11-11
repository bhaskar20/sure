// Benchmark Compare: compares the person's investment accounts with bundled
// benchmark returns. Reads data through the Sure mini app SDK only; the return
// math lives in returns-math.js (window.BenchmarkMath).

const M = window.BenchmarkMath;
const DATA = window.BENCHMARK_DATA;

const SETTINGS = { collection: "settings", key: "preferences" };
const BENCHMARK_COLLECTION = "benchmarks";
const INVESTMENT_TYPES = ["Investment", "Crypto"];
const IMPLAUSIBLE_ANNUAL_RETURN = 1;
const MAX_TRANSACTION_PAGES = 40;
const MAX_FLOW_ROWS = 300;
const NEEDED_PERMISSIONS = ["accounts:read", "transactions:read", "reports:read"];

const DEFAULT_SETTINGS = {
  accountIds: null,
  showAllAccounts: false,
  benchmarkIds: ["us-large-cap", "global-equity", "sixty-forty", "us-cpi"],
  primaryBenchmarkId: "us-large-cap",
  period: "all_time",
  flowMode: "auto",
  chartMode: "value",
  flowOverrides: {},
};

const state = {
  sure: null,
  settings: { ...DEFAULT_SETTINGS },
  accounts: [],
  storedBenchmarks: {},
  seriesCache: {},
  transactionCache: {},
  analysis: null,
  runId: 0,
  analyzeTimer: null,
  editingId: null,
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// Status, errors and formatting
// ---------------------------------------------------------------------------

function setStatus(text, kind) {
  const status = $("status");
  status.textContent = text;
  status.className = kind === "error" ? "error" : "muted";
}

function describeError(error) {
  const codes = window.SureMiniApp.ErrorCodes;
  switch (error?.code) {
    case codes.PERMISSION_DENIED:
      return `Sure refused: the "${error.data?.permission}" permission is not granted.`;
    case codes.APP_DISABLED:
      return "This app has been disabled by a family admin.";
    case codes.RATE_LIMITED:
      return "Too many requests. Wait a minute and press Reload data.";
    case codes.NOT_EMBEDDED:
      return "Open this page from Sure's Apps page.";
    default:
      return error?.message || String(error);
  }
}

function isPermissionDenied(error) {
  return error?.code === window.SureMiniApp.ErrorCodes.PERMISSION_DENIED;
}

function locale() {
  const raw = state.sure?.family?.locale;
  try {
    return raw ? Intl.getCanonicalLocales(raw.replace("_", "-"))[0] : undefined;
  } catch {
    return undefined;
  }
}

function formatMoney(value, currency, compact) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "–";
  try {
    return new Intl.NumberFormat(locale(), {
      style: "currency",
      currency,
      maximumFractionDigits: compact || Math.abs(value) >= 1000 ? 0 : 2,
      notation: compact ? "compact" : "standard",
    }).format(value);
  } catch {
    return `${Math.round(value).toLocaleString()} ${currency}`;
  }
}

function formatPercent(value, signed = true) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "–";
  const text = new Intl.NumberFormat(locale(), {
    style: "percent",
    minimumFractionDigits: 1,
    maximumFractionDigits: 1,
    signDisplay: signed ? "exceptZero" : "auto",
  }).format(value);
  return text;
}

function formatPoints(diff) {
  const pts = Math.abs(diff * 100).toFixed(1);
  return `${pts} percentage point${pts === "1.0" ? "" : "s"}`;
}

function formatDate(day) {
  const date = new Date(day * 86400000);
  return new Intl.DateTimeFormat(locale(), {
    year: "numeric",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(date);
}

function formatSpan(days) {
  if (days < 45) return `${days} day${days === 1 ? "" : "s"}`;
  const years = days / 365.25;
  if (years >= 1.95) return `${years.toFixed(1).replace(/\.0$/, "")} years`;
  const months = Math.max(1, Math.round(days / 30.44));
  return `${months} month${months === 1 ? "" : "s"}`;
}

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "className") node.className = value;
    else if (key === "text") node.textContent = value;
    else node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function toneClass(value) {
  if (!Number.isFinite(value) || Math.abs(value) < 1e-9) return "";
  return value > 0 ? "good" : "bad";
}

// ---------------------------------------------------------------------------
// Settings and stored benchmarks
// ---------------------------------------------------------------------------

async function loadSettings() {
  try {
    const saved = await state.sure.storage.get(SETTINGS.collection, SETTINGS.key);
    state.settings = { ...DEFAULT_SETTINGS, ...(saved || {}) };
  } catch (error) {
    console.warn("Could not read settings", error);
  }
}

async function saveSettings(changes) {
  state.settings = { ...state.settings, ...changes };
  try {
    await state.sure.storage.set(SETTINGS.collection, SETTINGS.key, state.settings);
  } catch (error) {
    setStatus(`Settings not saved: ${describeError(error)}`, "error");
  }
}

async function loadStoredBenchmarks() {
  const stored = {};
  let cursor = null;
  try {
    do {
      const page = await state.sure.storage.list(BENCHMARK_COLLECTION, { limit: 200, cursor });
      for (const item of page.items) {
        if (item?.data && typeof item.data === "object") stored[item.key] = item.data;
      }
      cursor = page.nextCursor;
    } while (cursor);
  } catch (error) {
    console.warn("Could not read stored benchmarks", error);
  }
  state.storedBenchmarks = stored;
}

// Bundled benchmarks with the person's edits applied, then their custom ones.
// A blend is resolved from its components after their edits.
function allBenchmarks() {
  const list = [];
  const byId = {};
  for (const base of DATA.benchmarks) {
    const edit = state.storedBenchmarks[base.id];
    const item = {
      ...base,
      builtIn: true,
      edited: Boolean(edit?.returns),
      returns: edit?.returns || base.returns,
    };
    list.push(item);
    byId[item.id] = item;
  }
  for (const item of list) {
    if (item.blend) {
      item.returns = M.blendReturns(
        item.blend.map((c) => ({ weight: c.weight, returns: byId[c.id].returns })),
      );
    }
  }
  for (const [id, data] of Object.entries(state.storedBenchmarks)) {
    if (byId[id] || !data.custom) continue;
    list.push({
      id,
      name: data.name || id,
      source: data.source || "Entered by you",
      currency: data.currency || "",
      returns: data.returns || {},
      custom: true,
    });
  }
  return list;
}

// ---------------------------------------------------------------------------
// Data loading
// ---------------------------------------------------------------------------

async function loadAccounts() {
  const result = await state.sure.accounts.list({});
  state.accounts = (result.accounts || []).filter((a) => a.classification === "asset");
}

async function loadSeries(period) {
  if (state.seriesCache[period]) return state.seriesCache[period];
  const result = await state.sure.accounts.list({
    include_balance_series: true,
    series_period: period,
  });
  const byId = {};
  for (const account of result.accounts || []) {
    byId[account.id] = account.historical_balances || null;
  }
  state.seriesCache[period] = byId;
  return byId;
}

async function loadTransactions(accountIds, startDate) {
  const key = `${accountIds.slice().sort().join(",")}|${startDate}`;
  if (state.transactionCache[key]) return state.transactionCache[key];

  const rows = [];
  let page = 1;
  let totalPages = 1;
  do {
    const result = await state.sure.transactions.list({
      account_ids: accountIds,
      start_date: startDate,
      order: "asc",
      page,
      page_size: 100,
    });
    rows.push(...(result.transactions || []));
    totalPages = result.total_pages || 1;
    page += 1;
  } while (page <= totalPages && page <= MAX_TRANSACTION_PAGES);

  const loaded = { rows, truncated: totalPages > MAX_TRANSACTION_PAGES, totalPages };
  state.transactionCache[key] = loaded;
  return loaded;
}

// Side information. Each part fails on its own without stopping the analysis.
async function loadHoldings(accounts, currency) {
  const names = accounts.filter((a) => INVESTMENT_TYPES.includes(a.type)).map((a) => a.name);
  if (names.length === 0) return null;
  const holdings = [];
  let page = 1;
  let totalPages = 1;
  do {
    const result = await state.sure.accounts.holdings({ page, accounts: names });
    holdings.push(...(result.holdings || []));
    totalPages = result.total_pages || 1;
    page += 1;
  } while (page <= totalPages && page <= 5);
  const same = holdings.filter((h) => h.currency === currency);
  return { holdings: same, otherCurrency: holdings.length - same.length, truncated: totalPages > 5 };
}

async function loadValuationCounts(accounts) {
  const out = {};
  await Promise.all(
    accounts.map(async (account) => {
      const result = await state.sure.accounts.valuations({ account_id: account.id, page: 1 });
      out[account.id] = {
        count: result.total_results || 0,
        latest: result.valuations?.[0]?.date || null,
      };
    }),
  );
  return out;
}

async function loadTotalAssets() {
  const result = await state.sure.reports.balanceSheet({
    period: "last_30_days",
    interval: "1 week",
  });
  const values = result?.assets?.monthly_history?.values;
  if (!Array.isArray(values) || values.length === 0) return null;
  return { value: Number(values[values.length - 1]), currency: result.currency };
}

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

function selectedAccounts() {
  const ids = state.settings.accountIds || [];
  return state.accounts.filter((a) => ids.includes(a.id));
}

function selectedBenchmarks() {
  const all = allBenchmarks();
  return state.settings.benchmarkIds
    .map((id) => all.find((b) => b.id === id))
    .filter(Boolean);
}

function scheduleAnalyze() {
  clearTimeout(state.analyzeTimer);
  state.analyzeTimer = setTimeout(analyze, 200);
}

async function analyze() {
  const runId = ++state.runId;
  const stale = () => runId !== state.runId;
  const notes = [];

  let accounts = selectedAccounts();
  if (accounts.length === 0) {
    $("results").hidden = true;
    setStatus("Pick at least one account to compare.");
    return;
  }

  const currency = accounts[0].currency;
  const mixed = accounts.filter((a) => a.currency !== currency);
  if (mixed.length > 0) {
    notes.push(
      `Left out ${mixed.map((a) => a.name).join(", ")}: in a different currency from ${currency}. Compare them separately; this app does not convert currencies.`,
    );
    accounts = accounts.filter((a) => a.currency === currency);
  }

  setStatus("Loading balance history…");
  let seriesById;
  try {
    seriesById = await loadSeries(state.settings.period);
  } catch (error) {
    setStatus(describeError(error), "error");
    return;
  }
  if (stale()) return;

  const accountPoints = [];
  for (const account of accounts) {
    const series = seriesById[account.id];
    if (!series || !Array.isArray(series.values) || series.values.length === 0) {
      notes.push(`${account.name} has no balance history for this period and is left out.`);
      continue;
    }
    if (series.currency && series.currency !== currency) {
      notes.push(`${account.name}'s history is in ${series.currency}, not ${currency}, and is left out.`);
      continue;
    }
    const { points, exact } = M.seriesPoints(series);
    if (!exact) {
      notes.push(`Sure did not say which date each of ${account.name}'s balance readings belongs to; they are spread evenly between ${series.start_date} and ${series.end_date}.`);
    }
    accountPoints.push({ id: account.id, name: account.name, points });
  }
  if (accountPoints.length === 0) {
    $("results").hidden = true;
    setStatus("None of the selected accounts has balance history for this period.");
    return;
  }

  const startDay = Math.min(...accountPoints.map((a) => a.points[0].day));
  const usedAccounts = accounts.filter((a) => accountPoints.some((p) => p.id === a.id));

  let classified = { flows: [], others: [] };
  let flowSource = "transactions";
  if (state.settings.flowMode === "none") {
    flowSource = "off";
  } else if (!state.sure.can("transactions:read")) {
    flowSource = "no_permission";
  } else {
    setStatus("Looking for contributions and withdrawals…");
    try {
      const loaded = await loadTransactions(
        usedAccounts.map((a) => a.id),
        M.fromDay(startDay),
      );
      if (stale()) return;
      if (loaded.truncated) {
        notes.push(`Only the first ${MAX_TRANSACTION_PAGES * 100} transactions were read; later contributions may be missed.`);
      }
      const byName = {};
      for (const a of usedAccounts) byName[a.name] = { id: a.id, currency: a.currency };
      if (Object.keys(byName).length !== usedAccounts.length) {
        notes.push("Two selected accounts share a name, so their transactions cannot be told apart. Rename one in Sure for exact results.");
      }
      classified = M.classifyTransactions(loaded.rows, {
        accounts: byName,
        mode: state.settings.flowMode,
        overrides: state.settings.flowOverrides,
      });
    } catch (error) {
      if (stale()) return;
      flowSource = isPermissionDenied(error) ? "no_permission" : "error";
      if (flowSource === "error") notes.push(`Transactions could not be read: ${describeError(error)}`);
    }
  }

  if (flowSource === "no_permission") {
    notes.push("This app cannot read transactions (transactions:read is not granted), so deposits cannot be told apart from growth. Returns below are raw balance growth and will look better than they are if you added money.");
  } else if (flowSource === "off") {
    notes.push("Contributions are ignored, so returns are raw balance growth: any money you added shows up as gain.");
  } else if (flowSource === "transactions" && classified.flows.length === 0) {
    notes.push("No contributions or withdrawals were found. If you did add money, mark those rows under \"Contributions and withdrawals found\", or switch Contributions to \"Every cash movement\".");
  }
  const unclassified = classified.others.filter((o) => o.reason === "unclassified");
  if (unclassified.length > 0) {
    notes.push(`${unclassified.length} transaction${unclassified.length === 1 ? " was" : "s were"} not clearly a deposit or investment income and ${unclassified.length === 1 ? "is" : "are"} treated as part of the return. Review them below.`);
  }

  const portfolio = M.buildPortfolio(accountPoints, classified.flows);
  const { grid, flows } = portfolio;
  if (grid.length < 2) {
    $("results").hidden = true;
    setStatus("Not enough balance history to measure a return yet.");
    return;
  }
  if (flows.some((f) => f.synthetic)) {
    notes.push("Accounts that start part-way through bring their opening balance in as a contribution.");
  }

  // Comparison window: where the portfolio and every chosen benchmark overlap.
  const benchmarks = selectedBenchmarks()
    .map((b) => ({ ...b, index: M.buildIndex(b.returns) }))
    .filter((b) => {
      if (!b.index) notes.push(`${b.name} has no usable yearly data and is left out.`);
      return b.index;
    });

  let windowStart = grid[0].day;
  let windowEnd = grid[grid.length - 1].day;
  for (const b of benchmarks) {
    windowStart = Math.max(windowStart, b.index.startDay);
    windowEnd = Math.min(windowEnd, b.index.endDay);
  }
  const windowGrid = M.clipGrid(grid, windowStart, windowEnd);
  const windowOk =
    benchmarks.length > 0 &&
    windowGrid.length >= 2 &&
    windowGrid[windowGrid.length - 1].day - windowGrid[0].day >= 28;

  if (benchmarks.length > 0 && grid[grid.length - 1].day > windowEnd) {
    const dataEnd = Math.min(...benchmarks.map((b) => b.index.endDay));
    notes.push(`Benchmark data ends on ${formatDate(dataEnd)}, so the comparison stops there and leaves out your last ${formatSpan(grid[grid.length - 1].day - dataEnd)}. Add or update the latest year's figure under "Benchmark data" to extend it.`);
  }
  if (benchmarks.length > 0 && grid[0].day < windowStart && windowOk) {
    notes.push(`Benchmark data starts on ${formatDate(windowStart)}, so earlier history is left out of the comparison.`);
  }

  const full = summarize(grid, flows);
  const compared = windowOk ? summarize(windowGrid, flows) : null;
  const benchmarkResults = windowOk
    ? benchmarks.map((b, i) => {
        const replay = M.replayFlows(b.index, windowGrid, flows);
        const first = windowGrid[0].day;
        const last = windowGrid[windowGrid.length - 1].day;
        const cumulative = M.indexReturn(b.index, first, last);
        return {
          ...b,
          colorIndex: i,
          replay,
          finalValue: replay[replay.length - 1].value,
          cumulative,
          annual: M.annualize(cumulative, last - first),
          levels: windowGrid.map((p) => ({ day: p.day, value: b.index.levelAt(p.day) })),
          years: yearMap(b.index, first, last),
        };
      })
    : [];

  if (stale()) return;

  state.analysis = {
    currency,
    accounts: usedAccounts,
    grid,
    flows,
    classified,
    flowSource,
    full,
    compared,
    window: windowOk ? windowGrid : null,
    benchmarks: benchmarkResults,
    notes,
    side: {},
  };
  renderAnalysis();
  setStatus(`Compared ${usedAccounts.length} account${usedAccounts.length === 1 ? "" : "s"} in ${currency}.`);

  loadSideInfo(runId, usedAccounts, currency);
}

function summarize(grid, flows) {
  const first = grid[0];
  const last = grid[grid.length - 1];
  const days = last.day - first.day;
  const twr = M.timeWeighted(grid, flows);
  const contributions = M.netContributions(grid, flows);
  const mwr = M.moneyWeighted(grid, flows);
  const invested = contributions[contributions.length - 1].value;
  return {
    startDay: first.day,
    endDay: last.day,
    days,
    startValue: first.value,
    endValue: last.value,
    invested,
    gain: last.value - invested,
    twr,
    twrAnnual: M.annualize(twr.cumulative, days),
    mwr,
    mwrPeriod: mwr === null ? null : (1 + mwr) ** (days / 365.25) - 1,
    contributions,
    years: M.calendarYears(twr.index),
  };
}

function yearMap(index, fromDay, toDay) {
  const out = {};
  for (let year = M.yearOf(fromDay); year <= M.yearOf(toDay); year += 1) {
    const from = Math.max(M.yearEnd(year - 1), fromDay);
    const to = Math.min(M.yearEnd(year), toDay);
    if (to > from) out[year] = M.indexReturn(index, from, to);
  }
  return out;
}

async function loadSideInfo(runId, accounts, currency) {
  const side = {};
  const tasks = [];
  if (state.sure.can("accounts:read")) {
    tasks.push(
      loadHoldings(accounts, currency)
        .then((v) => {
          side.holdings = v;
        })
        .catch((e) => {
          side.holdingsError = describeError(e);
        }),
      loadValuationCounts(accounts)
        .then((v) => {
          side.valuations = v;
        })
        .catch(() => {}),
    );
  }
  if (state.sure.can("reports:read")) {
    tasks.push(
      loadTotalAssets()
        .then((v) => {
          side.totalAssets = v;
        })
        .catch(() => {}),
    );
  }
  await Promise.all(tasks);
  if (runId !== state.runId || !state.analysis) return;
  state.analysis.side = side;
  renderSideInfo();
}

// ---------------------------------------------------------------------------
// Rendering: setup
// ---------------------------------------------------------------------------

function renderAccounts() {
  const box = $("accounts");
  box.replaceChildren();
  const showAll = state.settings.showAllAccounts;
  const selected = selectedAccounts();
  const lockedCurrency = selected[0]?.currency;

  const visible = state.accounts.filter(
    (a) => showAll || INVESTMENT_TYPES.includes(a.type) || selected.includes(a),
  );
  if (visible.length === 0) {
    box.append(
      el("p", { className: "muted small" }, state.accounts.length === 0
        ? "No asset accounts found."
        : "No investment or crypto accounts. Tick the box below to pick another account."),
    );
    return;
  }

  for (const account of visible) {
    const checked = selected.includes(account);
    const otherCurrency = lockedCurrency && account.currency !== lockedCurrency && !checked;
    const input = el("input", {
      type: "checkbox",
      value: account.id,
      checked: checked || undefined,
      disabled: otherCurrency || undefined,
    });
    input.checked = checked;
    input.addEventListener("change", async () => {
      const ids = new Set(state.settings.accountIds || []);
      if (input.checked) ids.add(account.id);
      else ids.delete(account.id);
      await saveSettings({ accountIds: [...ids] });
      renderAccounts();
      scheduleAnalyze();
    });
    const detail = otherCurrency
      ? ` · ${account.currency}, compare separately`
      : ` · ${account.balance_formatted}`;
    box.append(
      el(
        "label",
        { className: `check${otherCurrency ? " disabled" : ""}` },
        input,
        el("span", {}, account.name, el("span", { className: "muted small" }, detail)),
      ),
    );
  }
}

function renderBenchmarkChoices() {
  const box = $("benchmarks");
  box.replaceChildren();
  const all = allBenchmarks();
  const chosen = new Set(state.settings.benchmarkIds);

  for (const b of all) {
    const input = el("input", { type: "checkbox", value: b.id });
    input.checked = chosen.has(b.id);
    input.addEventListener("change", async () => {
      const ids = all.map((x) => x.id).filter((id) =>
        id === b.id ? input.checked : state.settings.benchmarkIds.includes(id),
      );
      await saveSettings({ benchmarkIds: ids });
      renderBenchmarkChoices();
      scheduleAnalyze();
    });
    const tag = b.custom ? " · yours" : b.edited ? " · edited" : "";
    box.append(
      el("label", { className: "check" }, input, el("span", {}, b.name, el("span", { className: "muted small" }, tag))),
    );
  }

  const primary = $("primary-benchmark");
  primary.replaceChildren();
  const options = all.filter((b) => chosen.has(b.id));
  for (const b of options) primary.append(el("option", { value: b.id }, b.name));
  if (options.some((b) => b.id === state.settings.primaryBenchmarkId)) {
    primary.value = state.settings.primaryBenchmarkId;
  }
  primary.disabled = options.length === 0;
}

// ---------------------------------------------------------------------------
// Rendering: results
// ---------------------------------------------------------------------------

function renderAnalysis() {
  const a = state.analysis;
  $("results").hidden = false;
  renderNotes();
  renderVerdict(a);
  renderCards(a);
  renderChart();
  renderCompareTable(a);
  renderYears(a);
  renderFlows(a);
  renderCaveats(a);
  renderSideInfo();
}

function renderNotes() {
  const a = state.analysis;
  const notes = [...a.notes, ...(a.sideNotes || [])];
  const box = $("notes");
  box.hidden = notes.length === 0;
  box.replaceChildren(
    el("strong", {}, "About this data"),
    el("ul", {}, notes.map((n) => el("li", {}, n))),
  );
}

function primaryBenchmark(a) {
  return (
    a.benchmarks.find((b) => b.id === state.settings.primaryBenchmarkId) ||
    a.benchmarks.find((b) => !["us-cpi", "cash"].includes(b.id)) ||
    a.benchmarks[0]
  );
}

// The per-year rate when the window is a year or longer, otherwise the return
// over the window, with a matching label.
function headline(annual, cumulative, days) {
  return days >= 365
    ? { value: annual, unit: "a year" }
    : { value: cumulative, unit: "in total" };
}

function renderVerdict(a) {
  const box = $("verdict");
  box.replaceChildren();
  const c = a.compared;
  const primary = primaryBenchmark(a);

  if (!c || !primary) {
    box.append(
      el("p", { className: "verdict-lead" },
        a.benchmarks.length === 0 && selectedBenchmarks().length === 0
          ? "Pick a benchmark to compare with."
          : "Your history and the benchmark data do not overlap enough to compare."),
    );
    const f = a.full;
    box.append(
      el("p", {}, `Over ${formatSpan(f.days)} your accounts returned ${formatPercent(f.twr.cumulative)} (time-weighted).`),
    );
    return;
  }

  const mine = headline(c.twrAnnual, c.twr.cumulative, c.days);
  const theirs = headline(primary.annual, primary.cumulative, c.days);
  const diff = mine.value - theirs.value;
  const span = formatSpan(c.days);
  const short = c.days < 365;
  const close = Math.abs(diff) < (short ? 0.01 : 0.005);

  // Without identified contributions the "return" includes deposits, so a
  // confident ahead/behind headline would mislead.
  // Contributions made through trades or balance updates are invisible to the
  // transaction tools, so they show up as growth. A sustained return above
  // 100% a year is far more likely to be missed deposits than skill.
  const implausible =
    c.days >= 365 && c.twrAnnual !== null && c.twrAnnual > IMPLAUSIBLE_ANNUAL_RETURN;
  const fair = a.flowSource === "transactions" && !implausible;
  let lead;
  if (implausible) {
    lead = `Can't compare reliably: ${formatPercent(c.twrAnnual)} a year is not believable, so most of the money you added was probably not found (for example, deposits recorded as trades or balance updates). Check the Contributions setting before trusting these figures.`;
  } else if (!fair) {
    lead = `Not a fair comparison yet: money you added counts as growth here, so these figures flatter you against ${primary.name}.`;
  } else if (close) {
    lead = `Roughly in line with ${primary.name}.`;
  } else if (diff > 0) {
    lead = `Ahead of ${primary.name} by ${formatPoints(diff)}${short ? "" : " a year"}.`;
  } else {
    lead = `Behind ${primary.name} by ${formatPoints(diff)}${short ? "" : " a year"}.`;
  }
  box.append(el("p", { className: "verdict-lead" }, lead));

  const measure = fair
    ? "measured time-weighted so your deposits do not count as growth"
    : "as raw balance growth, including any money you added";
  box.append(
    el(
      "p",
      {},
      `From ${formatDate(c.startDay)} to ${formatDate(c.endDay)} (${span}), your accounts returned ${formatPercent(mine.value)} ${mine.unit}, ${measure}. ${primary.name} returned about ${formatPercent(theirs.value)} ${theirs.unit}.`,
    ),
  );

  const moneyDiff = c.endValue - primary.finalValue;
  if (fair) box.append(
    el(
      "p",
      {},
      `Had your starting balance and every contribution gone into ${primary.name} on the same days, you would have about ${formatMoney(primary.finalValue, a.currency)} instead of ${formatMoney(c.endValue, a.currency)} — ${moneyDiff >= 0 ? `${formatMoney(moneyDiff, a.currency)} less than you have` : `${formatMoney(-moneyDiff, a.currency)} more than you have`}.`,
    ),
  );

  const cpi = a.benchmarks.find((b) => b.id === "us-cpi");
  if (fair && cpi && c.days >= 365 && c.twrAnnual !== null && cpi.annual !== null) {
    const real = (1 + c.twrAnnual) / (1 + cpi.annual) - 1;
    box.append(
      el("p", {}, `After US inflation, that is roughly ${formatPercent(real)} a year in real terms.`),
    );
  }

  if (short) {
    box.append(
      el("p", { className: "muted" }, "Less than a year of overlap is far too short to tell skill from luck; treat this as a snapshot."),
    );
  } else if (c.days < 3 * 365) {
    box.append(
      el("p", { className: "muted" }, "Under three years is still short: one good or bad stretch can swing this result."),
    );
  }
  if (a.flowSource !== "transactions") {
    box.append(
      el("p", { className: "bad" }, "Contributions are not separated from growth, so your return is likely overstated."),
    );
  }
}

function card(label, value, hint, tone) {
  return el(
    "div",
    { className: "card" },
    el("div", { className: "label" }, label),
    el("div", { className: `value ${tone || ""}` }, value),
    hint ? el("div", { className: "hint" }, hint) : null,
  );
}

function renderCards(a) {
  const s = a.compared || a.full;
  const box = $("cards");
  const yearly = s.days >= 365;
  const best = M.bestAndWorst(s.years);

  box.replaceChildren(
    s.endDay === a.full.endDay
      ? card("Value now", formatMoney(s.endValue, a.currency), `on ${formatDate(s.endDay)}`)
      : card(
          `Value on ${formatDate(s.endDay)}`,
          formatMoney(s.endValue, a.currency),
          `end of the comparison; ${formatMoney(a.full.endValue, a.currency)} on ${formatDate(a.full.endDay)}`,
        ),
    card(
      "Net contributed",
      formatMoney(s.invested, a.currency),
      "starting balance plus deposits minus withdrawals",
    ),
    card("Gain", formatMoney(s.gain, a.currency), "value minus net contributed", toneClass(s.gain)),
    card(
      yearly ? "Time-weighted, yearly" : "Time-weighted",
      formatPercent(yearly ? s.twrAnnual : s.twr.cumulative),
      yearly ? `${formatPercent(s.twr.cumulative)} in total` : "over the window",
      toneClass(s.twr.cumulative),
    ),
    card(
      yearly ? "Money-weighted (XIRR)" : "Money-weighted",
      formatPercent(yearly ? s.mwr : s.mwrPeriod),
      "includes the timing of your deposits",
      toneClass(yearly ? s.mwr : s.mwrPeriod),
    ),
    card(
      "Best / worst year",
      best.best ? `${formatPercent(best.best.r)} / ${formatPercent(best.worst.r)}` : "–",
      best.best ? `${best.best.year}${best.best.partial ? "*" : ""} / ${best.worst.year}${best.worst.partial ? "*" : ""}` : "needs a calendar year of history",
    ),
  );
}

function renderCompareTable(a) {
  const head = $("compare-head");
  const body = $("compare-body");
  const c = a.compared;
  head.replaceChildren();
  body.replaceChildren();
  if (!c) {
    body.append(el("tr", {}, el("td", { className: "muted" }, "No overlapping period to compare.")));
    return;
  }
  const yearly = c.days >= 365;
  head.append(
    el(
      "tr",
      {},
      el("th", { scope: "col" }, ""),
      el("th", { scope: "col", className: "num" }, yearly ? "Return a year" : "Return"),
      el("th", { scope: "col", className: "num" }, "Your money would be"),
      el("th", { scope: "col", className: "num" }, "vs. what you have"),
    ),
  );
  body.append(
    el(
      "tr",
      {},
      el("th", { scope: "row" }, "Your accounts (time-weighted)"),
      el("td", { className: "num" }, formatPercent(yearly ? c.twrAnnual : c.twr.cumulative)),
      el("td", { className: "num" }, formatMoney(c.endValue, a.currency)),
      el("td", { className: "num muted" }, "–"),
    ),
  );
  for (const b of a.benchmarks) {
    const diff = b.finalValue - c.endValue;
    body.append(
      el(
        "tr",
        {},
        el("th", { scope: "row" }, el("span", { className: `swatch s-${b.colorIndex}` }), b.name),
        el("td", { className: "num" }, formatPercent(yearly ? b.annual : b.cumulative)),
        el("td", { className: "num" }, formatMoney(b.finalValue, a.currency)),
        el("td", { className: `num ${toneClass(-diff)}` }, diff >= 0 ? `${formatMoney(diff, a.currency)} more` : `${formatMoney(-diff, a.currency)} less`),
      ),
    );
  }
}

function renderYears(a) {
  const head = $("years-head");
  const body = $("years-body");
  head.replaceChildren();
  body.replaceChildren();
  const years = (a.compared || a.full).years;
  if (years.length === 0) {
    body.append(el("tr", {}, el("td", { className: "muted" }, "Not enough history.")));
    return;
  }
  head.append(
    el(
      "tr",
      {},
      el("th", { scope: "col" }, "Year"),
      el("th", { scope: "col", className: "num" }, "You"),
      a.benchmarks.map((b) => el("th", { scope: "col", className: "num" }, b.name)),
    ),
  );
  for (const y of years.slice().reverse()) {
    body.append(
      el(
        "tr",
        {},
        el("th", { scope: "row" }, `${y.year}${y.partial ? "*" : ""}`),
        el("td", { className: `num ${toneClass(y.r)}` }, formatPercent(y.r)),
        a.benchmarks.map((b) => {
          const r = b.years[y.year];
          return el("td", { className: "num" }, r === undefined ? "–" : formatPercent(r));
        }),
      ),
    );
  }
}

const FLOW_REASONS = {
  transfer: "Transfer from or to another account",
  looks_like_flow: "Reads like a deposit or withdrawal",
  mode_all: "Cash movement",
  override: "Your choice",
  unclassified: "Unclear, counted as return",
  income_or_fee: "Income or fee, counted as return",
  internal_transfer: "Between selected accounts, ignored",
  pending: "Pending, ignored",
  currency: "Different currency, ignored",
  mode_none: "Contributions are ignored",
};

function renderFlows(a) {
  const box = $("flows");
  box.replaceChildren();
  if (a.flowSource === "no_permission") {
    box.append(el("p", { className: "muted" }, "Needs the transactions:read permission. Ask a family admin to grant it."));
    return;
  }
  if (a.flowSource === "off") {
    box.append(el("p", { className: "muted" }, "Contributions are set to Ignore, so no transactions were read."));
    return;
  }

  const real = a.classified.flows.map((f) => ({ ...f, counted: true }));
  const choosable = a.classified.others
    .filter((o) => ["unclassified", "income_or_fee", "override", "mode_none"].includes(o.reason))
    .map((o) => ({ ...o, counted: false }));
  const synthetic = a.flows.filter((f) => f.synthetic).map((f) => ({ ...f, counted: true }));
  const rows = [...real, ...choosable, ...synthetic].sort((x, y) => y.day - x.day);

  if (rows.length === 0) {
    box.append(el("p", { className: "muted" }, "No transactions on these accounts in this period."));
    return;
  }

  const totalIn = real.concat(synthetic).filter((f) => f.amount > 0).reduce((s, f) => s + f.amount, 0);
  const totalOut = real.concat(synthetic).filter((f) => f.amount < 0).reduce((s, f) => s + f.amount, 0);
  box.append(
    el("p", { className: "small" }, `Counted: ${formatMoney(totalIn, a.currency)} in, ${formatMoney(Math.abs(totalOut), a.currency)} out.`),
  );

  const tbody = el("tbody");
  for (const row of rows.slice(0, MAX_FLOW_ROWS)) {
    let control;
    if (row.synthetic) {
      control = el("span", { className: "muted small" }, "Opening balance");
    } else {
      control = el(
        "select",
        { "aria-label": `How to count ${row.name}` },
        el("option", { value: "" }, `Automatic: ${FLOW_REASONS[row.reason] || row.reason}`),
        el("option", { value: "flow" }, "Contribution or withdrawal"),
        el("option", { value: "return" }, "Part of the return"),
      );
      control.value = state.settings.flowOverrides[row.id] || "";
      control.addEventListener("change", async () => {
        const overrides = { ...state.settings.flowOverrides };
        if (control.value) overrides[row.id] = control.value;
        else delete overrides[row.id];
        await saveSettings({ flowOverrides: overrides });
        scheduleAnalyze();
      });
    }
    tbody.append(
      el(
        "tr",
        {},
        el("td", {}, M.fromDay(row.day)),
        el("td", {}, row.name || "–", el("div", { className: "muted small" }, row.account || "")),
        el("td", { className: `num ${row.counted ? "" : "muted"}` }, formatMoney(row.amount, a.currency)),
        el("td", {}, control),
      ),
    );
  }
  box.append(
    el(
      "div",
      { className: "table-wrap" },
      el(
        "table",
        {},
        el(
          "thead",
          {},
          el("tr", {},
            el("th", { scope: "col" }, "Date"),
            el("th", { scope: "col" }, "Transaction"),
            el("th", { scope: "col", className: "num" }, "Amount"),
            el("th", { scope: "col" }, "Counted as")),
        ),
        tbody,
      ),
    ),
  );
  if (rows.length > MAX_FLOW_ROWS) {
    box.append(el("p", { className: "muted small" }, `Showing the latest ${MAX_FLOW_ROWS} of ${rows.length} rows.`));
  }
}

function renderCaveats(a) {
  const items = [
    "This is not financial advice. It describes the past and says nothing reliable about the future.",
    "Results depend heavily on the start and end dates. Try other periods before concluding anything.",
    "Index returns carry no costs. A real index fund charges a fee (often 0.03% to 0.25% a year) and trails its index slightly; your own balances are already after your fees.",
    "Compare like with like: a 100% stock index is riskier than a mix of stocks, bonds and cash. If you hold bonds or cash, the 60/40 mix may be the fairer yardstick.",
    "Taxes, and money held outside the selected accounts, are not considered.",
    `Benchmark figures are approximate calendar-year totals (as of ${DATA.asOfYear}), spread evenly through each year, so month-to-month moves are smoothed.`,
  ];
  if (a.currency !== "USD") {
    items.push(`Your accounts are in ${a.currency} but the bundled benchmarks are in US dollars. Currency moves alone can explain several points a year; add a custom benchmark measured in ${a.currency} for a fairer comparison.`);
  }
  if (a.compared?.twr.skipped > 0) {
    items.push(`${a.compared.twr.skipped} short stretch${a.compared.twr.skipped === 1 ? "" : "es"} where the balance was too small to measure (usually just as an account was first funded) count as 0%.`);
  }
  $("caveats").replaceChildren(...items.map((t) => el("li", {}, t)));
}

function renderSideInfo() {
  const a = state.analysis;
  if (!a) return;
  const side = a.side || {};
  const panel = $("holdings-panel");
  const box = $("holdings");
  box.replaceChildren();

  const sideNotes = [];
  if (side.valuations) {
    for (const account of a.accounts) {
      const v = side.valuations[account.id];
      if (v && v.count > 1 && !account.is_linked) {
        sideNotes.push(`${account.name} is updated by hand (${v.count} recorded valuations). Between valuations Sure carries the balance forward, so returns over short stretches are approximate.`);
      }
    }
  }
  if (side.totalAssets && side.totalAssets.currency === a.currency && side.totalAssets.value > 0) {
    const share = a.full.endValue / side.totalAssets.value;
    if (share > 0 && share <= 1.05) {
      sideNotes.push(`These accounts are about ${formatPercent(Math.min(share, 1), false)} of the assets you can see in Sure.`);
    }
  }
  a.sideNotes = sideNotes;
  renderNotes();

  const h = side.holdings;
  if (side.holdingsError) {
    panel.hidden = false;
    box.append(el("p", { className: "muted" }, `Holdings could not be read: ${side.holdingsError}`));
    return;
  }
  if (!h || h.holdings.length === 0) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;
  const total = h.holdings.reduce((s, x) => s + (Number(x.amount) || 0), 0);
  const withCost = h.holdings.filter((x) => Number.isFinite(x.average_cost) && x.average_cost > 0);
  const cost = withCost.reduce((s, x) => s + x.average_cost * x.quantity, 0);
  const valueWithCost = withCost.reduce((s, x) => s + x.amount, 0);

  box.append(
    el("p", { className: "small" },
      `${h.holdings.length} position${h.holdings.length === 1 ? "" : "s"} worth ${formatMoney(total, a.currency)}.`,
      withCost.length > 0
        ? ` Where Sure knows the cost, ${formatMoney(valueWithCost, a.currency)} of holdings cost ${formatMoney(cost, a.currency)} (${formatPercent(valueWithCost / cost - 1)} unrealised).`
        : ""),
  );
  const top = h.holdings.slice().sort((x, y) => y.amount - x.amount).slice(0, 8);
  box.append(
    el("div", { className: "table-wrap" },
      el("table", {},
        el("thead", {}, el("tr", {},
          el("th", { scope: "col" }, "Holding"),
          el("th", { scope: "col" }, "Account"),
          el("th", { scope: "col", className: "num" }, "Value"),
          el("th", { scope: "col", className: "num" }, "Share"))),
        el("tbody", {}, top.map((x) => el("tr", {},
          el("td", {}, x.ticker || "", el("div", { className: "muted small" }, x.name || "")),
          el("td", {}, x.account),
          el("td", { className: "num" }, formatMoney(x.amount, a.currency)),
          el("td", { className: "num" }, total > 0 ? formatPercent(x.amount / total, false) : "–")))))),
  );
  const extra = [];
  if (h.otherCurrency > 0) extra.push(`${h.otherCurrency} holding${h.otherCurrency === 1 ? " is" : "s are"} priced in another currency and not shown.`);
  if (h.truncated) extra.push("Only the first 250 holdings were read.");
  extra.push("Holdings are today's snapshot; Sure's tools do not expose holdings history, so they are not used in the return.");
  box.append(el("p", { className: "muted small" }, extra.join(" ")));
}

// ---------------------------------------------------------------------------
// Chart (inline SVG)
// ---------------------------------------------------------------------------

const SVG_NS = "http://www.w3.org/2000/svg";

function svg(tag, attrs) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs || {})) node.setAttribute(key, value);
  return node;
}

function niceTicks(min, max, count) {
  if (min === max) {
    const pad = Math.abs(min) * 0.1 || 1;
    return niceTicks(min - pad, max + pad, count);
  }
  const raw = (max - min) / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) || 10 * mag;
  const ticks = [];
  for (let v = Math.floor(min / step) * step; ticks.length < 20; v += step) {
    ticks.push(v);
    if (v >= max) break;
  }
  return ticks;
}

function chartSeries(a) {
  const mode = state.settings.chartMode;
  const c = a.compared;
  const shown = a.window || a.grid;
  const summary = c || a.full;
  const series = [];

  if (mode === "growth") {
    const base = summary.twr.index;
    series.push({ name: "Your accounts", cls: "s-actual", points: base.map((p) => ({ day: p.day, value: p.value * 100 })) });
    for (const b of a.benchmarks) {
      const start = b.levels[0].value;
      series.push({ name: b.name, cls: `s-${b.colorIndex}`, points: b.levels.map((p) => ({ day: p.day, value: (p.value / start) * 100 })) });
    }
    return { series, money: false };
  }

  series.push({ name: "Your accounts", cls: "s-actual", points: shown });
  series.push({ name: "Net contributed", cls: "s-contrib", points: summary.contributions });
  for (const b of a.benchmarks) {
    series.push({ name: `${b.name}, same contributions`, cls: `s-${b.colorIndex}`, points: b.replay });
  }
  return { series, money: true };
}

function renderChart() {
  const a = state.analysis;
  const box = $("chart");
  const legend = $("legend");
  box.replaceChildren();
  legend.replaceChildren();
  $("chart-readout").textContent = "";
  if (!a) return;

  const { series, money } = chartSeries(a);
  $("chart-title").textContent = money ? "What your contributions became" : "Growth of 100";
  const all = series.flatMap((s) => s.points).filter((p) => Number.isFinite(p.value));
  if (all.length < 2) return;

  const W = 720;
  const H = 300;
  const pad = { l: 64, r: 12, t: 12, b: 28 };
  const minDay = Math.min(...all.map((p) => p.day));
  const maxDay = Math.max(...all.map((p) => p.day));
  const values = all.map((p) => p.value);
  const lowest = money ? Math.min(0, ...values) : Math.min(...values);
  const ticks = niceTicks(lowest, Math.max(...values), 4);
  const minV = ticks[0];
  const maxV = ticks[ticks.length - 1];
  const x = (day) => pad.l + ((day - minDay) / Math.max(1, maxDay - minDay)) * (W - pad.l - pad.r);
  const y = (v) => pad.t + (1 - (v - minV) / Math.max(1e-9, maxV - minV)) * (H - pad.t - pad.b);

  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": $("chart-title").textContent });
  const axis = svg("g", { class: "axis" });
  for (const t of ticks) {
    axis.append(svg("line", { class: "gridline", x1: pad.l, x2: W - pad.r, y1: y(t), y2: y(t) }));
    const label = svg("text", { x: pad.l - 6, y: y(t) + 4, "text-anchor": "end" });
    label.textContent = money ? formatMoney(t, a.currency, true) : String(Math.round(t));
    axis.append(label);
  }
  const firstYear = M.yearOf(minDay);
  const lastYear = M.yearOf(maxDay);
  const yearStep = Math.max(1, Math.ceil((lastYear - firstYear + 1) / 8));
  if (lastYear > firstYear) {
    for (let year = firstYear + 1; year <= lastYear; year += yearStep) {
      const day = M.toDay(`${year}-01-01`);
      const label = svg("text", { x: x(day), y: H - 8, "text-anchor": "middle" });
      label.textContent = String(year);
      axis.append(label);
    }
  } else {
    for (const day of [minDay, maxDay]) {
      const label = svg("text", { x: x(day), y: H - 8, "text-anchor": day === minDay ? "start" : "end" });
      label.textContent = formatDate(day);
      axis.append(label);
    }
  }
  root.append(axis);

  for (const s of series.slice().reverse()) {
    const d = s.points
      .filter((p) => Number.isFinite(p.value))
      .map((p, i) => `${i === 0 ? "M" : "L"}${x(p.day).toFixed(1)},${y(p.value).toFixed(1)}`)
      .join("");
    root.append(svg("path", { class: `line ${s.cls}`, d }));
    legend.prepend(el("li", {}, el("span", { className: `swatch ${s.cls}` }), s.name));
  }

  const cursor = svg("line", { class: "cursor", y1: pad.t, y2: H - pad.b, x1: -10, x2: -10 });
  root.append(cursor);
  const overlay = svg("rect", { x: pad.l, y: pad.t, width: W - pad.l - pad.r, height: H - pad.t - pad.b, fill: "transparent" });
  overlay.addEventListener("pointermove", (event) => {
    const rect = root.getBoundingClientRect();
    const px = ((event.clientX - rect.left) / rect.width) * W;
    const day = minDay + ((px - pad.l) / (W - pad.l - pad.r)) * (maxDay - minDay);
    const ref = series[0].points;
    let nearest = ref[0];
    for (const p of ref) if (Math.abs(p.day - day) < Math.abs(nearest.day - day)) nearest = p;
    cursor.setAttribute("x1", x(nearest.day));
    cursor.setAttribute("x2", x(nearest.day));
    const parts = series.map((s) => {
      const value = M.valueAt(s.points, nearest.day);
      return `${s.name}: ${money ? formatMoney(value, a.currency) : value === null ? "–" : value.toFixed(1)}`;
    });
    $("chart-readout").textContent = `${formatDate(nearest.day)} — ${parts.join(" · ")}`;
  });
  overlay.addEventListener("pointerleave", () => {
    cursor.setAttribute("x1", -10);
    cursor.setAttribute("x2", -10);
  });
  root.append(overlay);
  box.append(root);
}

// ---------------------------------------------------------------------------
// Benchmark editor
// ---------------------------------------------------------------------------

function renderEditor() {
  $("dataset-note").textContent = `${DATA.note} Figures run to ${DATA.asOfYear}. Your edits are stored in this app and shared with your family; the bundled figures are never changed.`;
  const select = $("edit-select");
  const all = allBenchmarks();
  select.replaceChildren(
    ...all.map((b) => el("option", { value: b.id }, `${b.name}${b.custom ? " (yours)" : b.edited ? " (edited)" : ""}`)),
    el("option", { value: "__new" }, "New custom benchmark…"),
  );
  if (!state.editingId || (state.editingId !== "__new" && !all.some((b) => b.id === state.editingId))) {
    state.editingId = all[0]?.id || "__new";
  }
  select.value = state.editingId;
  fillEditor();
}

function fillEditor() {
  const id = state.editingId;
  const b = allBenchmarks().find((x) => x.id === id);
  const isNew = id === "__new";
  const isBlend = Boolean(b?.blend);

  $("edit-name").value = isNew ? "" : b.name;
  $("edit-name").disabled = Boolean(b?.builtIn);
  $("edit-source").value = isNew ? "" : b.source || "";
  $("edit-source").disabled = Boolean(b?.builtIn);
  $("edit-returns").value = isNew ? "" : M.formatReturnsText(b.returns);
  $("edit-returns").disabled = isBlend;
  $("edit-save").disabled = isBlend;
  $("edit-reset").hidden = !b?.builtIn || isBlend;
  $("edit-reset").disabled = !b?.edited;
  $("edit-delete").hidden = !b?.custom;
  $("edit-message").className = "small muted";
  $("edit-message").textContent = isBlend
    ? "This mix is worked out from its parts each year, including any edits you make to them."
    : b?.source
      ? `Source: ${b.source}`
      : "";
}

async function saveEditor(event) {
  event.preventDefault();
  const message = $("edit-message");
  const { returns, errors } = M.parseReturnsText($("edit-returns").value);
  if (!errors.length && !M.buildIndex(returns)) errors.push("Enter at least one year.");
  if (errors.length) {
    message.className = "small error";
    message.textContent = errors.join(" ");
    return;
  }

  let id = state.editingId;
  let record;
  if (id === "__new") {
    const name = $("edit-name").value.trim();
    if (!name) {
      message.className = "small error";
      message.textContent = "Give the benchmark a name.";
      return;
    }
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "benchmark";
    id = `custom-${slug}-${Date.now().toString(36)}`;
    record = { custom: true, name, source: $("edit-source").value.trim(), returns };
  } else {
    const existing = allBenchmarks().find((b) => b.id === id);
    record = existing.custom
      ? { custom: true, name: $("edit-name").value.trim() || existing.name, source: $("edit-source").value.trim(), returns }
      : { returns };
  }

  try {
    await state.sure.storage.set(BENCHMARK_COLLECTION, id, record);
  } catch (error) {
    message.className = "small error";
    message.textContent = describeError(error);
    return;
  }
  state.storedBenchmarks[id] = record;
  if (record.custom && !state.settings.benchmarkIds.includes(id)) {
    await saveSettings({ benchmarkIds: [...state.settings.benchmarkIds, id] });
  }
  state.editingId = id;
  renderEditor();
  renderBenchmarkChoices();
  $("edit-message").className = "small good";
  $("edit-message").textContent = "Saved.";
  scheduleAnalyze();
}

async function removeStored(id, done) {
  try {
    await state.sure.storage.delete(BENCHMARK_COLLECTION, id);
  } catch (error) {
    $("edit-message").className = "small error";
    $("edit-message").textContent = describeError(error);
    return;
  }
  delete state.storedBenchmarks[id];
  await done();
  renderEditor();
  renderBenchmarkChoices();
  scheduleAnalyze();
}

// ---------------------------------------------------------------------------
// Start-up
// ---------------------------------------------------------------------------

function showMissingPermissions() {
  const missing = NEEDED_PERMISSIONS.filter((p) => !state.sure.can(p));
  const notice = $("missing");
  notice.hidden = missing.length === 0;
  const effects = {
    "accounts:read": "accounts and balance history cannot be read, so there is nothing to compare",
    "transactions:read": "contributions cannot be separated from growth",
    "reports:read": "the share of your total assets is not shown",
  };
  notice.textContent = `Not granted: ${missing.map((p) => `${p} (${effects[p]})`).join("; ")}. A family admin can grant these on the app's page.`;
}

function defaultAccountIds() {
  const investments = state.accounts.filter((a) => INVESTMENT_TYPES.includes(a.type));
  const familyCurrency = state.sure.family?.currency;
  const preferred = investments.filter((a) => a.currency === familyCurrency);
  const pool = preferred.length > 0 ? preferred : investments.filter((a) => a.currency === investments[0]?.currency);
  return pool.map((a) => a.id);
}

async function reload() {
  state.seriesCache = {};
  state.transactionCache = {};
  if (!state.sure.can("accounts:read")) {
    setStatus("This app needs the accounts:read permission to read your accounts.", "error");
    return;
  }
  try {
    setStatus("Loading accounts…");
    await loadAccounts();
  } catch (error) {
    setStatus(describeError(error), "error");
    return;
  }
  const known = new Set(state.accounts.map((a) => a.id));
  const kept = (state.settings.accountIds || []).filter((id) => known.has(id));
  if (state.settings.accountIds === null || (kept.length === 0 && state.settings.accountIds.length > 0)) {
    await saveSettings({ accountIds: defaultAccountIds() });
  } else if (kept.length !== state.settings.accountIds.length) {
    await saveSettings({ accountIds: kept });
  }
  renderAccounts();
  await analyze();
}

function bindControls() {
  $("period").value = state.settings.period;
  $("flow-mode").value = state.settings.flowMode;
  $("chart-mode").value = state.settings.chartMode;
  $("show-all-accounts").checked = Boolean(state.settings.showAllAccounts);

  $("period").addEventListener("change", async (event) => {
    await saveSettings({ period: event.target.value });
    scheduleAnalyze();
  });
  $("flow-mode").addEventListener("change", async (event) => {
    await saveSettings({ flowMode: event.target.value });
    scheduleAnalyze();
  });
  $("chart-mode").addEventListener("change", async (event) => {
    await saveSettings({ chartMode: event.target.value });
    renderChart();
  });
  $("show-all-accounts").addEventListener("change", async (event) => {
    await saveSettings({ showAllAccounts: event.target.checked });
    renderAccounts();
  });
  $("primary-benchmark").addEventListener("change", async (event) => {
    await saveSettings({ primaryBenchmarkId: event.target.value });
    if (state.analysis) renderAnalysis();
  });
  $("refresh").addEventListener("click", reload);

  $("edit-select").addEventListener("change", (event) => {
    state.editingId = event.target.value;
    fillEditor();
  });
  $("edit-form").addEventListener("submit", saveEditor);
  $("edit-reset").addEventListener("click", () => removeStored(state.editingId, async () => {}));
  $("edit-delete").addEventListener("click", () => {
    const id = state.editingId;
    removeStored(id, async () => {
      state.editingId = null;
      await saveSettings({ benchmarkIds: state.settings.benchmarkIds.filter((x) => x !== id) });
    });
  });
}

async function main() {
  try {
    state.sure = await window.SureMiniApp.connect();
  } catch (error) {
    setStatus(describeError(error), "error");
    return;
  }

  showMissingPermissions();
  await Promise.all([loadSettings(), loadStoredBenchmarks()]);
  bindControls();
  renderBenchmarkChoices();
  renderEditor();

  await reload();
}

main();
