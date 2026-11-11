// Tests for planner.js. Run: node examples/miniapps/goal-planner/planner.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

await import("./planner.js");
const P = globalThis.GoalPlanner;

const close = (actual, expected, tolerance = 0.01) =>
	assert.ok(
		Math.abs(actual - expected) <= tolerance,
		`expected ${actual} to be within ${tolerance} of ${expected}`,
	);

test("monthsBetween counts whole months and goes negative in the past", () => {
	assert.equal(P.monthsBetween("2026-11-11", "2027-11-11"), 12);
	assert.equal(P.monthsBetween("2026-11-11", "2027-11-10"), 11);
	assert.equal(P.monthsBetween("2026-11-11", "2026-11-30"), 0);
	assert.equal(P.monthsBetween("2026-11-11", "2026-05-11"), -6);
	assert.equal(P.monthsBetween("2026-11-11", "not a date"), 0);
});

test("monthlyRate compounds back to the annual rate", () => {
	close((1 + P.monthlyRate(0.06)) ** 12 - 1, 0.06, 1e-12);
	assert.equal(P.monthlyRate(0), 0);
});

test("inflate grows today's money and ignores past dates", () => {
	close(P.inflate(100000, 0.03, 10), 134391.64);
	assert.equal(P.inflate(1000, 0.03, -2), 1000);
	assert.equal(P.inflate(1000, 0, 10), 1000);
});

test("growingAnnuityFactor matches a month-by-month simulation", () => {
	const r = P.monthlyRate(0.06);
	const g = P.monthlyRate(0.03);
	let value = 0;
	let payment = 1;
	for (let k = 0; k < 120; k++) {
		value = value * (1 + r) + payment;
		payment *= 1 + g;
	}
	close(P.growingAnnuityFactor(0.06, 0.03, 120), value, 1e-9);
});

test("growingAnnuityFactor handles zero return and equal rates", () => {
	assert.equal(P.growingAnnuityFactor(0, 0, 24), 24);
	const r = P.monthlyRate(0.05);
	close(P.growingAnnuityFactor(0.05, 0.05, 12), 12 * (1 + r) ** 11, 1e-9);
	assert.equal(P.growingAnnuityFactor(0.05, 0.02, 0), 0);
	assert.equal(P.growingAnnuityFactor(0.05, 0.02, -3), 0);
});

test("required contribution with zero return is a straight division", () => {
	const result = P.requiredMonthlyContribution({
		futureTarget: 12000,
		currentValue: 0,
		annualReturn: 0,
		annualGrowth: 0,
		months: 12,
	});
	assert.equal(result.monthly, 1000);
});

test("required contribution reaches the target exactly", () => {
	const args = {
		futureTarget: 50000,
		currentValue: 5000,
		annualReturn: 0.06,
		annualGrowth: 0.03,
		months: 60,
	};
	const { monthly } = P.requiredMonthlyContribution(args);
	const reached =
		P.futureValue(5000, 0.06, 60) +
		monthly * P.growingAnnuityFactor(0.06, 0.03, 60);
	close(reached, 50000, 1e-6);
	// A growing plan starts lower than a level one.
	const level = P.requiredMonthlyContribution({ ...args, annualGrowth: 0 });
	assert.ok(monthly < level.monthly);
});

test("a target date in the past makes the gap due now", () => {
	const result = P.requiredMonthlyContribution({
		futureTarget: 10000,
		currentValue: 4000,
		annualReturn: 0.05,
		annualGrowth: 0,
		months: -3,
	});
	assert.equal(result.monthly, null);
	assert.equal(result.dueNow, 6000);
});

test("an already funded goal needs nothing", () => {
	const result = P.requiredMonthlyContribution({
		futureTarget: 10000,
		currentValue: 12000,
		annualReturn: 0.05,
		annualGrowth: 0,
		months: 24,
	});
	assert.equal(result.monthly, 0);
});

test("profiles are capped by horizon", () => {
	assert.equal(P.horizonFor(1), "short");
	assert.equal(P.horizonFor(5), "medium");
	assert.equal(P.horizonFor(20), "long");
	assert.equal(P.effectiveProfile("growth", "short"), "conservative");
	assert.equal(P.effectiveProfile("growth", "medium"), "balanced");
	assert.equal(P.effectiveProfile("conservative", "long"), "conservative");
	assert.equal(P.effectiveProfile("bogus", "long"), "balanced");
});

test("planGoal inflates the target and reports status", () => {
	const goal = {
		targetAmount: 100000,
		targetDate: "2036-11-11",
		riskProfile: "growth",
	};
	const base = {
		goal,
		assumptions: {},
		today: "2026-11-11",
		currentValue: 10000,
	};
	const plan = P.planGoal({ ...base, contribution: 0 });
	assert.equal(plan.months, 120);
	assert.equal(plan.profile, "growth");
	close(
		plan.futureTarget,
		100000 * 1.03 ** P.yearsBetween("2026-11-11", "2036-11-11"),
	);
	assert.equal(plan.status, "off_track");

	const onTrack = P.planGoal({ ...base, contribution: plan.requiredMonthly });
	assert.equal(onTrack.status, "on_track");
	close(onTrack.projected, onTrack.futureTarget, 0.01);

	const atRisk = P.planGoal({
		...base,
		contribution: plan.requiredMonthly * 0.85,
	});
	assert.equal(atRisk.status, "at_risk");

	const nominal = P.planGoal({
		...base,
		assumptions: { targetsInTodaysMoney: false },
		contribution: 0,
	});
	assert.equal(nominal.futureTarget, 100000);
});

test("planGoal handles past dates and funded goals", () => {
	const past = P.planGoal({
		goal: {
			targetAmount: 5000,
			targetDate: "2025-01-01",
			riskProfile: "balanced",
		},
		assumptions: {},
		today: "2026-11-11",
		currentValue: 1000,
		contribution: 0,
	});
	assert.equal(past.status, "overdue");
	assert.equal(past.requiredMonthly, null);
	assert.equal(past.dueNow, 4000);
	assert.equal(past.futureTarget, 5000);

	const funded = P.planGoal({
		goal: {
			targetAmount: 5000,
			targetDate: "2027-11-11",
			riskProfile: "balanced",
		},
		assumptions: { inflation: 0 },
		today: "2026-11-11",
		currentValue: 6000,
		contribution: 0,
	});
	assert.equal(funded.status, "funded");
	assert.equal(funded.requiredMonthly, 0);
});

test("mergeAssumptions keeps valid overrides only", () => {
	const merged = P.mergeAssumptions({
		returns: { growth: 0.1, balanced: "x" },
		inflation: 0.02,
		contributionGrowth: -5,
	});
	assert.equal(merged.returns.growth, 0.1);
	assert.equal(merged.returns.balanced, 0.06);
	assert.equal(merged.inflation, 0.02);
	assert.equal(merged.contributionGrowth, 0.03);
});

test("projectionSeries starts at today's value and ends at the target date", () => {
	const plan = P.planGoal({
		goal: {
			targetAmount: 20000,
			targetDate: "2031-11-11",
			riskProfile: "balanced",
		},
		assumptions: {},
		today: "2026-11-11",
		currentValue: 2000,
		contribution: 0,
	});
	const series = P.projectionSeries(plan, {});
	assert.equal(series[0].month, 0);
	assert.equal(series[0].planned, 2000);
	const last = series[series.length - 1];
	assert.equal(last.month, plan.months);
	close(last.required, plan.futureTarget, 0.01);
	assert.ok(series.length <= 42);
});

test("prioritize shares the surplus in priority order", () => {
	const result = P.prioritize(
		[
			{
				id: "house",
				priority: "medium",
				targetDate: "2030-01-01",
				requiredMonthly: 800,
			},
			{
				id: "emergency",
				priority: "high",
				targetDate: "2027-06-01",
				requiredMonthly: 500,
			},
			{
				id: "trip",
				priority: "low",
				targetDate: "2027-01-01",
				requiredMonthly: 300,
			},
			{
				id: "car",
				priority: "medium",
				targetDate: "2028-01-01",
				requiredMonthly: 0,
				ownContribution: 100,
			},
		],
		1200,
	);
	assert.deepEqual(
		result.rows.map((r) => r.id),
		["emergency", "car", "house", "trip"],
	);
	assert.deepEqual(
		result.rows.map((r) => r.allocated),
		[500, 100, 600, 0],
	);
	assert.deepEqual(
		result.rows.map((r) => r.fits),
		[true, true, false, false],
	);
	assert.equal(result.totalNeed, 1700);
	assert.equal(result.shortfall, 500);

	const unknown = P.prioritize(
		[{ id: "a", priority: "high", requiredMonthly: 10 }],
		null,
	);
	assert.equal(unknown.surplus, null);
	assert.equal(unknown.rows[0].fits, null);
});

test("earmarkTotals flags over-allocated accounts", () => {
	const totals = P.earmarkTotals(
		[
			{
				earmarks: [
					{ accountId: "a", amount: 600 },
					{ accountId: "b", amount: 50 },
				],
			},
			{ earmarks: [{ accountId: "a", amount: 500 }] },
		],
		{ a: 1000 },
	);
	assert.equal(totals.a.allocated, 1100);
	assert.equal(totals.a.over, true);
	assert.equal(totals.a.free, -100);
	assert.equal(totals.b.balance, null);
	assert.equal(totals.b.over, false);
});

test("parseFormattedMoney reads Sure's formatted amounts", () => {
	assert.equal(P.parseFormattedMoney("$1,234.56"), 1234.56);
	assert.equal(P.parseFormattedMoney("-$1,234.56"), -1234.56);
	assert.equal(P.parseFormattedMoney("€1.234,56"), 1234.56);
	assert.equal(P.parseFormattedMoney("1 234,56 kr"), 1234.56);
	assert.equal(P.parseFormattedMoney("-1 234,56 kr"), -1234.56);
	assert.equal(P.parseFormattedMoney("¥1,235"), 1235);
	assert.equal(P.parseFormattedMoney("₹1,23,456.78"), 123456.78);
	assert.equal(P.parseFormattedMoney("CHF 1'234.50"), 1234.5);
	assert.equal(P.parseFormattedMoney("$0.00"), 0);
	assert.equal(P.parseFormattedMoney(42), 42);
	assert.equal(P.parseFormattedMoney(""), null);
	assert.equal(P.parseFormattedMoney(null), null);
});

test("median and date helpers", () => {
	assert.equal(P.median([3, 1, 2]), 2);
	assert.equal(P.median([4, 1, 2, 3]), 2.5);
	assert.equal(P.median([]), null);
	assert.equal(P.addMonths("2026-01-31", 1), "2026-02-28");
	assert.deepEqual(P.completedMonthsRange("2026-11-11", 6), {
		start_date: "2026-05-01",
		end_date: "2026-10-31",
	});
	assert.deepEqual(P.completedMonthsRange("2026-01-15", 2), {
		start_date: "2025-11-01",
		end_date: "2025-12-31",
	});
});
