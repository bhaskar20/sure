// Goal Planner math: small pure functions with no DOM or SDK access, so they
// can be tested in Node (planner.test.mjs) and used by app.js in the frame.
// Rates are annual fractions (0.05 = 5 %). Dates are "YYYY-MM-DD" strings.
(() => {
	const PROFILES = ["conservative", "balanced", "growth"];

	const DEFAULT_ASSUMPTIONS = Object.freeze({
		returns: Object.freeze({
			conservative: 0.04,
			balanced: 0.06,
			growth: 0.08,
		}),
		inflation: 0.03,
		// Contributions rise each year by this rate (a growing annuity), so the
		// first monthly payment can start lower and keep pace with pay rises.
		contributionGrowth: 0.03,
		// Targets are entered in today's money and inflated to the target date.
		targetsInTodaysMoney: true,
	});

	// Indicative mixes per profile: equity / bonds / cash, in percent.
	const MIXES = Object.freeze({
		conservative: Object.freeze({ equity: 20, bonds: 50, cash: 30 }),
		balanced: Object.freeze({ equity: 50, bonds: 40, cash: 10 }),
		growth: Object.freeze({ equity: 80, bonds: 15, cash: 5 }),
	});

	// Money needed soon should not ride the stock market: short horizons are
	// capped at conservative, medium ones at balanced.
	const HORIZON_CAP = Object.freeze({
		short: "conservative",
		medium: "balanced",
		long: "growth",
	});

	function parseDate(value) {
		const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ""));
		if (!match) return null;
		const [, y, m, d] = match.map(Number);
		const date = new Date(Date.UTC(y, m - 1, d));
		if (date.getUTCMonth() !== m - 1 || date.getUTCDate() !== d) return null;
		return date;
	}

	function toIsoDate(date) {
		return date.toISOString().slice(0, 10);
	}

	// Whole months from `from` to `to`; negative when `to` is in the past. A
	// partial month does not count, so a contribution plan never assumes a
	// payment that cannot be made in time.
	function monthsBetween(from, to) {
		const a = parseDate(from);
		const b = parseDate(to);
		if (!a || !b) return 0;
		let months =
			(b.getUTCFullYear() - a.getUTCFullYear()) * 12 +
			(b.getUTCMonth() - a.getUTCMonth());
		if (months > 0 && b.getUTCDate() < a.getUTCDate()) months -= 1;
		if (months < 0 && b.getUTCDate() > a.getUTCDate()) months += 1;
		return months;
	}

	function yearsBetween(from, to) {
		const a = parseDate(from);
		const b = parseDate(to);
		if (!a || !b) return 0;
		return (b - a) / (365.25 * 24 * 3600 * 1000);
	}

	function monthlyRate(annualRate) {
		const rate = Number(annualRate) || 0;
		if (rate <= -1) return -1;
		return (1 + rate) ** (1 / 12) - 1;
	}

	// Today's money to money of `years` from now.
	function inflate(amount, annualInflation, years) {
		return amount * (1 + (Number(annualInflation) || 0)) ** Math.max(years, 0);
	}

	function futureValue(presentValue, annualReturn, months) {
		if (months <= 0) return presentValue;
		return presentValue * (1 + monthlyRate(annualReturn)) ** months;
	}

	// Value after `months` of a payment of 1 at each month end, rising by the
	// monthly growth rate after each payment: sum (1+g)^(k-1) (1+r)^(n-k).
	function growingAnnuityFactor(annualReturn, annualGrowth, months) {
		const n = Math.floor(months);
		if (n <= 0) return 0;
		const r = monthlyRate(annualReturn);
		const g = monthlyRate(annualGrowth);
		if (Math.abs(r - g) < 1e-12) return n * (1 + r) ** (n - 1);
		return ((1 + r) ** n - (1 + g) ** n) / (r - g);
	}

	// The first monthly payment that, growing at `annualGrowth`, closes the gap
	// between what is already set aside and the target by the target date.
	// With no months left the gap is due now, so `monthly` is null and
	// `dueNow` holds the shortfall.
	function requiredMonthlyContribution({
		futureTarget,
		currentValue,
		annualReturn,
		annualGrowth,
		months,
	}) {
		const projected = futureValue(currentValue, annualReturn, months);
		const gap = Math.max(0, futureTarget - projected);
		if (months <= 0) return { monthly: null, dueNow: gap, projected };
		if (gap === 0) return { monthly: 0, dueNow: 0, projected };
		const factor = growingAnnuityFactor(annualReturn, annualGrowth, months);
		return { monthly: gap / factor, dueNow: 0, projected };
	}

	function horizonFor(years) {
		if (years < 3) return "short";
		if (years < 7) return "medium";
		return "long";
	}

	function effectiveProfile(chosen, horizon) {
		const wanted = PROFILES.includes(chosen) ? chosen : "balanced";
		const cap = HORIZON_CAP[horizon] || "growth";
		return PROFILES.indexOf(wanted) <= PROFILES.indexOf(cap) ? wanted : cap;
	}

	function mergeAssumptions(saved) {
		const base = DEFAULT_ASSUMPTIONS;
		const value = saved && typeof saved === "object" ? saved : {};
		const returns = { ...base.returns };
		for (const profile of PROFILES) {
			const rate = Number(value.returns?.[profile]);
			if (Number.isFinite(rate) && rate > -1) returns[profile] = rate;
		}
		const pick = (key) => {
			const rate = Number(value[key]);
			return Number.isFinite(rate) && rate > -1 ? rate : base[key];
		};
		return {
			returns,
			inflation: pick("inflation"),
			contributionGrowth: pick("contributionGrowth"),
			targetsInTodaysMoney:
				value.targetsInTodaysMoney === undefined
					? base.targetsInTodaysMoney
					: Boolean(value.targetsInTodaysMoney),
		};
	}

	// Everything the app shows for one goal. `currentValue` is what is
	// earmarked today; `contribution` is the first monthly payment assumed
	// (the person's own figure or their share of the surplus).
	function planGoal({ goal, assumptions, today, currentValue, contribution }) {
		const a = mergeAssumptions(assumptions);
		const months = monthsBetween(today, goal.targetDate);
		const years = Math.max(0, yearsBetween(today, goal.targetDate));
		const horizon = horizonFor(years);
		const profile = effectiveProfile(goal.riskProfile, horizon);
		const annualReturn = a.returns[profile];
		const target = Math.max(0, Number(goal.targetAmount) || 0);
		const futureTarget = a.targetsInTodaysMoney
			? inflate(target, a.inflation, years)
			: target;
		const current = Math.max(0, Number(currentValue) || 0);
		const required = requiredMonthlyContribution({
			futureTarget,
			currentValue: current,
			annualReturn,
			annualGrowth: a.contributionGrowth,
			months,
		});
		const paying = Math.max(0, Number(contribution) || 0);
		const projected =
			required.projected +
			paying * growingAnnuityFactor(annualReturn, a.contributionGrowth, months);

		return {
			months,
			years,
			horizon,
			chosenProfile: goal.riskProfile,
			profile,
			profileCapped: profile !== goal.riskProfile,
			mix: MIXES[profile],
			annualReturn,
			realReturn: (1 + annualReturn) / (1 + a.inflation) - 1,
			target,
			futureTarget,
			currentValue: current,
			projectedEarmark: required.projected,
			gap: Math.max(0, futureTarget - required.projected),
			requiredMonthly: required.monthly,
			dueNow: required.dueNow,
			contribution: paying,
			projected,
			status: statusFor({
				futureTarget,
				projected,
				projectedEarmark: required.projected,
				months,
			}),
		};
	}

	function statusFor({ futureTarget, projected, projectedEarmark, months }) {
		if (futureTarget <= 0 || projectedEarmark >= futureTarget) return "funded";
		if (months <= 0) return "overdue";
		const ratio = projected / futureTarget;
		if (ratio >= 0.999) return "on_track";
		if (ratio >= 0.8) return "at_risk";
		return "off_track";
	}

	// Value month by month, sampled to at most `points` points, for the chart:
	// what the plan reaches with the assumed contribution and with the required
	// one, against the (inflating) target.
	function projectionSeries(plan, assumptions, points = 40) {
		const a = mergeAssumptions(assumptions);
		const n = Math.max(0, plan.months);
		const step = Math.max(1, Math.ceil(n / points));
		const required = plan.requiredMonthly || 0;
		const series = [];
		for (let m = 0; m <= n; m += step) series.push(pointAt(m));
		if (series[series.length - 1].month !== n) series.push(pointAt(n));
		return series;

		function pointAt(month) {
			const base = futureValue(plan.currentValue, plan.annualReturn, month);
			const factor = growingAnnuityFactor(
				plan.annualReturn,
				a.contributionGrowth,
				month,
			);
			const years = month / 12;
			return {
				month,
				planned: base + plan.contribution * factor,
				required: base + required * factor,
				target: a.targetsInTodaysMoney
					? inflate(plan.target, a.inflation, years)
					: plan.target,
			};
		}
	}

	const PRIORITY_RANK = { high: 0, medium: 1, low: 2 };

	// Shares the monthly surplus out in priority order (then by date). A goal
	// with the person's own contribution takes that; the others take what they
	// need while surplus remains. `surplus` null means unknown.
	function prioritize(entries, surplus) {
		const ordered = entries.slice().sort((x, y) => {
			const rank =
				(PRIORITY_RANK[x.priority] ?? 1) - (PRIORITY_RANK[y.priority] ?? 1);
			if (rank !== 0) return rank;
			return String(x.targetDate).localeCompare(String(y.targetDate));
		});
		const known = Number.isFinite(surplus);
		let remaining = known ? Math.max(0, surplus) : 0;
		let cumulative = 0;
		const rows = ordered.map((entry) => {
			const need = entry.requiredMonthly || 0;
			const own = Number.isFinite(entry.ownContribution)
				? Math.max(0, entry.ownContribution)
				: null;
			let allocated;
			if (own !== null) allocated = own;
			else if (known) allocated = Math.min(need, remaining);
			else allocated = 0;
			remaining = Math.max(0, remaining - allocated);
			cumulative += own !== null ? own : need;
			return {
				id: entry.id,
				need,
				allocated,
				ownContribution: own,
				cumulative,
				fits: known ? cumulative <= surplus + 0.005 : null,
			};
		});
		const totalNeed = rows.reduce(
			(sum, row) => sum + (row.ownContribution ?? row.need),
			0,
		);
		return {
			rows,
			totalNeed,
			surplus: known ? surplus : null,
			shortfall: known ? Math.max(0, totalNeed - surplus) : null,
			shareOfSurplus: known && surplus > 0 ? totalNeed / surplus : null,
		};
	}

	// Sums earmarks per account and flags accounts promised beyond their
	// balance. `goals` carry `earmarks: [{ accountId, amount }]`.
	function earmarkTotals(goals, balances) {
		const totals = {};
		for (const goal of goals) {
			for (const earmark of goal.earmarks || []) {
				const amount = Math.max(0, Number(earmark.amount) || 0);
				totals[earmark.accountId] = (totals[earmark.accountId] || 0) + amount;
			}
		}
		const result = {};
		for (const [accountId, allocated] of Object.entries(totals)) {
			const balance = balances[accountId];
			const known = Number.isFinite(balance);
			result[accountId] = {
				allocated,
				balance: known ? balance : null,
				free: known ? balance - allocated : null,
				over: known ? allocated > balance + 0.005 : false,
			};
		}
		return result;
	}

	// Sure's report tools return money as formatted strings ("$1,234.56",
	// "€1.234,56", "-1 234,56 kr", "¥1,235"). The last "." or "," is a decimal
	// separator only when one or two digits follow it.
	function parseFormattedMoney(text) {
		if (typeof text === "number") return Number.isFinite(text) ? text : null;
		if (typeof text !== "string") return null;
		const negative = /^\s*[-−(]|[-−]\s*[^\d\s]*\d|\)\s*$/.test(text);
		const cleaned = text.replace(/[^\d.,]/g, "");
		if (!/\d/.test(cleaned)) return null;
		const lastSep = Math.max(
			cleaned.lastIndexOf("."),
			cleaned.lastIndexOf(","),
		);
		let integer = cleaned;
		let fraction = "";
		if (lastSep >= 0) {
			const tail = cleaned.slice(lastSep + 1);
			if (tail.length > 0 && tail.length <= 2) {
				integer = cleaned.slice(0, lastSep);
				fraction = tail;
			}
		}
		const digits = integer.replace(/[.,]/g, "") || "0";
		const value = Number(fraction ? `${digits}.${fraction}` : digits);
		if (!Number.isFinite(value)) return null;
		return negative ? -value : value;
	}

	function median(values) {
		const sorted = values
			.filter((v) => Number.isFinite(v))
			.sort((x, y) => x - y);
		if (sorted.length === 0) return null;
		const mid = Math.floor(sorted.length / 2);
		return sorted.length % 2
			? sorted[mid]
			: (sorted[mid - 1] + sorted[mid]) / 2;
	}

	function addMonths(isoDate, months) {
		const date = parseDate(isoDate);
		if (!date) return null;
		const day = date.getUTCDate();
		date.setUTCDate(1);
		date.setUTCMonth(date.getUTCMonth() + months);
		const lastDay = new Date(
			Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0),
		).getUTCDate();
		date.setUTCDate(Math.min(day, lastDay));
		return toIsoDate(date);
	}

	// The last `count` complete calendar months before `today`.
	function completedMonthsRange(today, count) {
		const date = parseDate(today);
		if (!date) return null;
		const firstOfThisMonth = new Date(
			Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1),
		);
		const end = new Date(firstOfThisMonth.getTime() - 24 * 3600 * 1000);
		const start = new Date(
			Date.UTC(
				firstOfThisMonth.getUTCFullYear(),
				firstOfThisMonth.getUTCMonth() - count,
				1,
			),
		);
		return { start_date: toIsoDate(start), end_date: toIsoDate(end) };
	}

	globalThis.GoalPlanner = Object.freeze({
		PROFILES,
		DEFAULT_ASSUMPTIONS,
		MIXES,
		HORIZON_CAP,
		parseDate,
		toIsoDate,
		monthsBetween,
		yearsBetween,
		monthlyRate,
		inflate,
		futureValue,
		growingAnnuityFactor,
		requiredMonthlyContribution,
		horizonFor,
		effectiveProfile,
		mergeAssumptions,
		planGoal,
		statusFor,
		projectionSeries,
		prioritize,
		earmarkTotals,
		parseFormattedMoney,
		median,
		addMonths,
		completedMonthsRange,
	});
})();
