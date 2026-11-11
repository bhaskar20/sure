// Pure return math for Benchmark Compare. No DOM, no SDK: everything here is
// covered by tests/returns-math.test.js and runs in Node as well as the frame.
//
// Conventions:
// - Dates are "day numbers": whole days since 1970-01-01 (UTC).
// - Balances are end-of-day values, so a flow dated d is already inside V(d).
// - A flow is money the person moved into (+) or out of (-) the portfolio.
((root) => {
  const DAY_MS = 86400000;
  const DAYS_PER_YEAR = 365.25;

  function toDay(iso) {
    const [y, m, d] = String(iso).slice(0, 10).split("-").map(Number);
    if (!y || !m || !d) return Number.NaN;
    return Math.round(Date.UTC(y, m - 1, d) / DAY_MS);
  }

  function fromDay(day) {
    return new Date(day * DAY_MS).toISOString().slice(0, 10);
  }

  function yearOf(day) {
    return new Date(day * DAY_MS).getUTCFullYear();
  }

  function yearEnd(year) {
    return toDay(`${year}-12-31`);
  }

  // Adds one month the way Postgres does when it steps an interval from the
  // previous value: 31 Jan + 1 month is 28/29 Feb, and the series keeps that day.
  function addOneMonth(day) {
    const date = new Date(day * DAY_MS);
    const y = date.getUTCFullYear();
    const m = date.getUTCMonth();
    const d = date.getUTCDate();
    const lastOfNext = new Date(Date.UTC(y, m + 2, 0)).getUTCDate();
    return Math.round(Date.UTC(y, m + 1, Math.min(d, lastOfNext)) / DAY_MS);
  }

  function stepFor(interval) {
    const text = String(interval || "").toLowerCase();
    if (text.includes("month")) return addOneMonth;
    if (text.includes("week")) return (day) => day + 7;
    return (day) => day + 1;
  }

  // Sure's balance series carries start_date, end_date, interval and a bare
  // values array, without a date per value. The server builds the dates with
  // generate_series(start, end, interval) plus end_date, so rebuild them the
  // same way. When the count still disagrees, spread the values evenly and
  // say so (exact: false).
  function seriesPoints(series) {
    const values = Array.isArray(series?.values) ? series.values : [];
    if (values.length === 0) return { points: [], exact: true };

    const start = toDay(series.start_date);
    const end = toDay(series.end_date);
    if (!Number.isFinite(start) || !Number.isFinite(end)) {
      return { points: [], exact: false };
    }

    const step = stepFor(series.interval);
    const dates = [];
    for (let day = start; day <= end && dates.length <= values.length; day = step(day)) {
      dates.push(day);
    }
    if (dates[dates.length - 1] !== end) dates.push(end);

    let exact = true;
    if (dates.length !== values.length) {
      exact = false;
      dates.length = 0;
      const span = end - start;
      for (let i = 0; i < values.length; i += 1) {
        dates.push(
          values.length === 1
            ? end
            : Math.round(start + (span * i) / (values.length - 1)),
        );
      }
    }

    const points = values.map((value, i) => ({ day: dates[i], value: Number(value) || 0 }));
    return { points, exact };
  }

  // Linear interpolation inside the series; null before it starts (the account
  // did not exist yet) and the last value after it ends.
  function valueAt(points, day) {
    if (points.length === 0 || day < points[0].day) return null;
    const last = points[points.length - 1];
    if (day >= last.day) return last.value;

    let lo = 0;
    let hi = points.length - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (points[mid].day <= day) lo = mid;
      else hi = mid;
    }
    const a = points[lo];
    const b = points[hi];
    if (b.day === a.day) return b.value;
    return a.value + ((b.value - a.value) * (day - a.day)) / (b.day - a.day);
  }

  function thinDays(days, keep, maxPoints) {
    if (days.length <= maxPoints) return days;
    const out = [];
    let lastMonth = null;
    days.forEach((day, i) => {
      const date = new Date(day * DAY_MS);
      const month = date.getUTCFullYear() * 12 + date.getUTCMonth();
      if (i === 0 || i === days.length - 1 || keep.has(day) || month !== lastMonth) {
        out.push(day);
      }
      lastMonth = month;
    });
    return out;
  }

  // Combines several accounts' balance series into one portfolio value series
  // on a shared date grid. An account that starts after the grid does brings
  // its opening balance with it; whatever part of that balance the identified
  // flows do not explain is added as an "opening balance" flow, so it is not
  // mistaken for investment growth.
  function buildPortfolio(accounts, flows, options) {
    const maxPoints = options?.maxPoints || 300;
    const usable = accounts.filter((a) => a.points.length > 0);
    if (usable.length === 0) return { grid: [], flows: [] };

    const firstDays = new Set(usable.map((a) => a.points[0].day));
    const allDays = new Set();
    for (const account of usable) {
      for (const point of account.points) allDays.add(point.day);
    }
    const days = thinDays(
      [...allDays].sort((a, b) => a - b),
      firstDays,
      maxPoints,
    );

    const grid = days.map((day) => {
      let value = 0;
      for (const account of usable) value += valueAt(account.points, day) ?? 0;
      return { day, value };
    });

    const start = days[0];
    const end = days[days.length - 1];
    const inRange = (flow) => flow.day > start && flow.day <= end;
    const allFlows = flows.filter(inRange).map((flow) => ({ ...flow }));

    for (const account of usable) {
      const first = account.points[0];
      if (first.day <= start) continue;
      const explained = allFlows
        .filter((f) => f.accountId === account.id && f.day <= first.day)
        .reduce((sum, f) => sum + f.amount, 0);
      const opening = first.value - explained;
      if (Math.abs(opening) > Math.max(0.5, Math.abs(first.value) * 0.001)) {
        allFlows.push({
          day: first.day,
          amount: opening,
          accountId: account.id,
          name: "Opening balance",
          synthetic: true,
        });
      }
    }

    allFlows.sort((a, b) => a.day - b.day);
    return { grid, flows: allFlows };
  }

  // Keeps grid points inside [startDay, endDay], adding interpolated points at
  // either edge that falls between two readings, so the window ends exactly
  // where the benchmark data does. Flows on or before the new first point are
  // part of its value, so they drop out naturally.
  function clipGrid(grid, startDay, endDay) {
    const inside = grid.filter((p) => p.day >= startDay && p.day <= endDay);
    if (grid.length === 0 || startDay > endDay) return inside;
    const first = grid[0].day;
    const last = grid[grid.length - 1].day;
    if (startDay > first && startDay < last && inside[0]?.day !== startDay) {
      inside.unshift({ day: startDay, value: valueAt(grid, startDay) });
    }
    if (endDay > first && endDay < last && inside[inside.length - 1]?.day !== endDay) {
      inside.push({ day: endDay, value: valueAt(grid, endDay) });
    }
    return inside;
  }

  function flowsBetween(flows, fromDay, toDay) {
    return flows.filter((f) => f.day > fromDay && f.day <= toDay);
  }

  // Time-weighted return, chain-linking Modified Dietz sub-period returns.
  // Each sub-period runs between two grid points; a flow is weighted by the
  // share of the sub-period it was invested for. Sub-periods whose capital is
  // too small to measure (mostly the moment an empty account is first funded)
  // count as 0% and are reported in `skipped`.
  function timeWeighted(grid, flows) {
    if (grid.length < 2) {
      return { index: grid.map((p) => ({ day: p.day, value: 1 })), cumulative: null, skipped: 0, periods: [] };
    }
    const index = [{ day: grid[0].day, value: 1 }];
    const periods = [];
    let skipped = 0;
    let level = 1;

    for (let i = 1; i < grid.length; i += 1) {
      const a = grid[i - 1];
      const b = grid[i];
      const span = b.day - a.day;
      const inPeriod = flowsBetween(flows, a.day, b.day);
      const net = inPeriod.reduce((sum, f) => sum + f.amount, 0);
      const weighted = inPeriod.reduce(
        (sum, f) => sum + (f.amount * (b.day - f.day)) / span,
        0,
      );
      const capital = a.value + weighted;
      const floor = Math.max(1, 0.02 * Math.max(Math.abs(a.value), Math.abs(b.value)));

      let r = 0;
      if (capital > floor) {
        r = (b.value - a.value - net) / capital;
        if (r < -1) r = -1;
      } else if (Math.abs(b.value - a.value - net) > floor) {
        skipped += 1;
      }
      level *= 1 + r;
      periods.push({ from: a.day, to: b.day, r });
      index.push({ day: b.day, value: level });
    }

    return { index, cumulative: level - 1, skipped, periods };
  }

  function annualize(cumulative, days) {
    if (cumulative === null || !Number.isFinite(cumulative) || days < 365) return null;
    if (cumulative <= -1) return -1;
    return (1 + cumulative) ** (DAYS_PER_YEAR / days) - 1;
  }

  // XIRR: the annual rate that makes the net present value of dated cash
  // flows zero. Flows are from the investor's side: money in is negative,
  // the final value is positive. Newton's method, falling back to bisection.
  function xirr(cashflows) {
    const cfs = cashflows.filter((c) => c.amount !== 0);
    if (cfs.length < 2) return null;
    if (!cfs.some((c) => c.amount > 0) || !cfs.some((c) => c.amount < 0)) return null;

    const t0 = Math.min(...cfs.map((c) => c.day));
    const years = cfs.map((c) => (c.day - t0) / DAYS_PER_YEAR);
    const npv = (rate) =>
      cfs.reduce((sum, c, i) => sum + c.amount / (1 + rate) ** years[i], 0);
    const dnpv = (rate) =>
      cfs.reduce(
        (sum, c, i) => sum - (years[i] * c.amount) / (1 + rate) ** (years[i] + 1),
        0,
      );

    let rate = 0.1;
    for (let i = 0; i < 50; i += 1) {
      const value = npv(rate);
      const slope = dnpv(rate);
      if (!Number.isFinite(value) || !Number.isFinite(slope) || slope === 0) break;
      const next = rate - value / slope;
      if (!Number.isFinite(next) || next <= -0.9999) break;
      if (Math.abs(next - rate) < 1e-10) return next;
      rate = next;
    }

    let lo = -0.9999;
    let hi = 10;
    let flo = npv(lo);
    const fhi = npv(hi);
    if (!Number.isFinite(flo) || !Number.isFinite(fhi) || flo * fhi > 0) return null;
    for (let i = 0; i < 200; i += 1) {
      const mid = (lo + hi) / 2;
      const fmid = npv(mid);
      if (Math.abs(fmid) < 1e-9 || hi - lo < 1e-12) return mid;
      if (flo * fmid < 0) {
        hi = mid;
      } else {
        lo = mid;
        flo = fmid;
      }
    }
    return (lo + hi) / 2;
  }

  // Money-weighted return of the portfolio: the starting value and every
  // contribution go in, the ending value comes out.
  function moneyWeighted(grid, flows) {
    if (grid.length < 2) return null;
    const first = grid[0];
    const last = grid[grid.length - 1];
    const cashflows = [{ day: first.day, amount: -first.value }];
    for (const flow of flowsBetween(flows, first.day, last.day)) {
      cashflows.push({ day: flow.day, amount: -flow.amount });
    }
    cashflows.push({ day: last.day, amount: last.value });
    return xirr(cashflows);
  }

  // Contributions over the window, counting the starting value as the first.
  function netContributions(grid, flows) {
    if (grid.length === 0) return [];
    let total = grid[0].value;
    let prev = grid[0].day;
    return grid.map((point, i) => {
      if (i > 0) {
        for (const flow of flowsBetween(flows, prev, point.day)) total += flow.amount;
        prev = point.day;
      }
      return { day: point.day, value: total };
    });
  }

  // ---------------------------------------------------------------------------
  // Benchmarks
  // ---------------------------------------------------------------------------

  // Combines component benchmarks year by year (rebalanced every January).
  // Only years every component covers are kept.
  function blendReturns(components) {
    const years = components
      .map((c) => Object.keys(c.returns).map(Number))
      .reduce((acc, ys) => acc.filter((y) => ys.includes(y)));
    const out = {};
    for (const year of years) {
      out[year] = components.reduce((sum, c) => sum + c.weight * returnValue(c.returns[year]), 0);
    }
    return out;
  }

  function returnValue(entry) {
    return typeof entry === "object" && entry !== null ? Number(entry.r) : Number(entry);
  }

  // Builds a level function from calendar-year returns (percent). The level is
  // 1 at the end of the year before the first year. Within a year the level
  // grows at a constant daily rate, which is an approximation: annual data
  // cannot show what happened inside the year. The last year may be partial
  // ({ r, through: "YYYY-MM-DD" }), covering 1 January to that date.
  function buildIndex(returns) {
    const years = Object.keys(returns || {})
      .map(Number)
      .filter((y) => Number.isInteger(y) && Number.isFinite(returnValue(returns[y])))
      .sort((a, b) => a - b);
    if (years.length === 0) return null;

    // Use the contiguous run of years that ends at the latest year.
    let first = years[years.length - 1];
    while (years.includes(first - 1)) first -= 1;

    const segments = [];
    let level = 1;
    for (let year = first; year <= years[years.length - 1]; year += 1) {
      const entry = returns[year];
      const from = yearEnd(year - 1);
      let to = yearEnd(year);
      if (typeof entry === "object" && entry !== null && entry.through) {
        const through = toDay(entry.through);
        if (Number.isFinite(through) && through > from && through <= to) to = through;
      }
      const growth = 1 + returnValue(entry) / 100;
      segments.push({ year, from, to, startLevel: level, growth });
      level *= growth;
      if (to !== yearEnd(year)) break;
    }

    const startDay = segments[0].from;
    const endDay = segments[segments.length - 1].to;

    function levelAt(day) {
      if (day < startDay || day > endDay) return null;
      for (const s of segments) {
        if (day <= s.to) {
          const share = (day - s.from) / (s.to - s.from);
          return s.startLevel * Math.max(s.growth, 1e-9) ** share;
        }
      }
      return null;
    }

    return { startDay, endDay, firstYear: first, levelAt };
  }

  // "What your money would have become": the starting value buys units of the
  // benchmark, every contribution buys more and every withdrawal sells some,
  // at the benchmark's level on the flow's date.
  function replayFlows(index, grid, flows) {
    if (grid.length === 0) return [];
    let units = grid[0].value / index.levelAt(grid[0].day);
    let prev = grid[0].day;
    return grid.map((point, i) => {
      if (i > 0) {
        for (const flow of flowsBetween(flows, prev, point.day)) {
          units += flow.amount / index.levelAt(flow.day);
        }
        prev = point.day;
      }
      return { day: point.day, value: units * index.levelAt(point.day) };
    });
  }

  function indexReturn(index, fromDay, toDay) {
    const a = index.levelAt(fromDay);
    const b = index.levelAt(toDay);
    if (a === null || b === null || a === 0) return null;
    return b / a - 1;
  }

  // Calendar-year returns from a level series (the portfolio's time-weighted
  // index). Years cut short by the window are marked partial.
  function calendarYears(levelSeries) {
    if (levelSeries.length < 2) return [];
    const first = levelSeries[0].day;
    const last = levelSeries[levelSeries.length - 1].day;
    const out = [];
    for (let year = yearOf(first); year <= yearOf(last); year += 1) {
      const from = Math.max(yearEnd(year - 1), first);
      const to = Math.min(yearEnd(year), last);
      if (to <= from) continue;
      const a = valueAt(levelSeries, from);
      const b = valueAt(levelSeries, to);
      if (a === null || b === null || a === 0) continue;
      out.push({
        year,
        from,
        to,
        r: b / a - 1,
        partial: from !== yearEnd(year - 1) || to !== yearEnd(year),
      });
    }
    return out;
  }

  function bestAndWorst(years) {
    const full = years.filter((y) => !y.partial);
    const pool = full.length > 0 ? full : years;
    if (pool.length === 0) return { best: null, worst: null };
    let best = pool[0];
    let worst = pool[0];
    for (const y of pool) {
      if (y.r > best.r) best = y;
      if (y.r < worst.r) worst = y;
    }
    return { best, worst };
  }

  // ---------------------------------------------------------------------------
  // Flows from transactions
  // ---------------------------------------------------------------------------

  const RETURN_PATTERN = /dividend|interest|coupon|distribution|capital gain|reinvest|\bfees?\b|commission|advisory|management charge/i;
  const FLOW_PATTERN = /contribution|deposit|withdraw|transfer|rollover|\bach\b|\bwire\b|payroll|employer|funding|top.?up/i;

  // Sorts transactions on the selected accounts into contributions or
  // withdrawals (flows) and everything else.
  //
  // mode "auto": transfers from accounts outside the selection, plus rows whose
  //   text reads like a deposit or withdrawal. Dividends, interest and fees
  //   stay inside the return. Anything else is listed as unclassified.
  // mode "all": every row except dividends, interest and fees is a flow.
  // mode "none": no flows; returns are raw balance growth.
  // overrides: { [transactionId]: "flow" | "return" } chosen by the person.
  function classifyTransactions(transactions, options) {
    const mode = options?.mode || "auto";
    const accounts = options?.accounts || {};
    const overrides = options?.overrides || {};
    const flows = [];
    const others = [];

    for (const txn of transactions) {
      const account = accounts[txn.account];
      const day = toDay(txn.date);
      const amount = Number(txn.amount) * (txn.classification === "income" ? 1 : -1);
      const row = {
        id: txn.id,
        day,
        amount,
        name: txn.name,
        account: txn.account,
        accountId: account?.id || null,
      };

      if (!account) {
        others.push({ ...row, reason: "other_account" });
        continue;
      }
      if (txn.currency && account.currency && txn.currency !== account.currency) {
        others.push({ ...row, reason: "currency" });
        continue;
      }
      if (txn.pending) {
        others.push({ ...row, reason: "pending" });
        continue;
      }
      if (txn.is_transfer && txn.transfer_account && accounts[txn.transfer_account]) {
        others.push({ ...row, reason: "internal_transfer" });
        continue;
      }

      const override = overrides[txn.id];
      if (override === "flow") {
        flows.push({ ...row, reason: "override" });
        continue;
      }
      if (override === "return") {
        others.push({ ...row, reason: "override" });
        continue;
      }
      if (mode === "none") {
        others.push({ ...row, reason: "mode_none" });
        continue;
      }
      if (txn.is_transfer) {
        flows.push({ ...row, reason: "transfer" });
        continue;
      }

      const text = [txn.name, txn.clean_name, txn.category, txn.merchant]
        .filter(Boolean)
        .join(" ");
      if (RETURN_PATTERN.test(text)) {
        others.push({ ...row, reason: "income_or_fee" });
      } else if (mode === "all") {
        flows.push({ ...row, reason: "mode_all" });
      } else if (FLOW_PATTERN.test(text)) {
        flows.push({ ...row, reason: "looks_like_flow" });
      } else {
        others.push({ ...row, reason: "unclassified" });
      }
    }

    flows.sort((a, b) => a.day - b.day);
    return { flows, others };
  }

  // ---------------------------------------------------------------------------
  // Benchmark editor text
  // ---------------------------------------------------------------------------

  // One year per line: "2024: 25.0" or "2026: 9.1 through 2026-10-31".
  // Percent signs and commas as decimal separators are accepted.
  function parseReturnsText(text) {
    const returns = {};
    const errors = [];
    const lines = String(text || "").split(/\r?\n/);
    lines.forEach((raw, i) => {
      const line = raw.trim();
      if (!line || line.startsWith("#")) return;
      const match = line.match(
        /^(\d{4})\s*[:=\s]\s*(-?\d+(?:[.,]\d+)?)\s*%?(?:\s+(?:through|to|until)\s+(\d{4}-\d{2}-\d{2}))?$/i,
      );
      if (!match) {
        errors.push(`Line ${i + 1}: expected "YEAR: PERCENT", got "${line}"`);
        return;
      }
      const year = Number(match[1]);
      const r = Number(match[2].replace(",", "."));
      if (r <= -100) {
        errors.push(`Line ${i + 1}: a return of ${r}% is not possible`);
        return;
      }
      if (match[3]) {
        if (yearOf(toDay(match[3])) !== year || !Number.isFinite(toDay(match[3]))) {
          errors.push(`Line ${i + 1}: the "through" date must fall in ${year}`);
          return;
        }
        returns[year] = { r, through: match[3] };
      } else {
        returns[year] = r;
      }
    });

    const years = Object.keys(returns).map(Number).sort((a, b) => a - b);
    years.slice(0, -1).forEach((year) => {
      if (typeof returns[year] === "object") {
        errors.push(`${year}: only the latest year can be partial`);
      }
    });
    if (years.length === 0 && errors.length === 0) errors.push("Enter at least one year.");
    return { returns, errors };
  }

  function formatReturnsText(returns) {
    return Object.keys(returns || {})
      .map(Number)
      .sort((a, b) => a - b)
      .map((year) => {
        const entry = returns[year];
        if (typeof entry === "object" && entry !== null) {
          return `${year}: ${entry.r}${entry.through ? ` through ${entry.through}` : ""}`;
        }
        return `${year}: ${entry}`;
      })
      .join("\n");
  }

  const api = {
    toDay,
    fromDay,
    yearOf,
    yearEnd,
    seriesPoints,
    valueAt,
    buildPortfolio,
    clipGrid,
    timeWeighted,
    annualize,
    xirr,
    moneyWeighted,
    netContributions,
    blendReturns,
    buildIndex,
    replayFlows,
    indexReturn,
    calendarYears,
    bestAndWorst,
    classifyTransactions,
    parseReturnsText,
    formatReturnsText,
  };

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.BenchmarkMath = api;
  }
})(globalThis);
