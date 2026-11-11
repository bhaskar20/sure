// Goal Planner: plans life goals against the family's accounts and monthly
// surplus, using only the Sure mini app SDK. The math lives in planner.js.

const P = window.GoalPlanner;

const STORE = {
	goals: "goals",
	settings: "settings",
	assumptionsKey: "assumptions",
};

const KINDS = {
	emergency: {
		label: "Emergency fund",
		priority: "high",
		risk: "conservative",
		months: 12,
	},
	house: {
		label: "House deposit",
		priority: "medium",
		risk: "balanced",
		months: 60,
	},
	education: {
		label: "Child's education",
		priority: "medium",
		risk: "balanced",
		months: 120,
	},
	retirement: {
		label: "Retirement",
		priority: "medium",
		risk: "growth",
		months: 300,
	},
	other: { label: "Other", priority: "medium", risk: "balanced", months: 36 },
};

const STATUS_LABELS = {
	funded: "Funded",
	on_track: "On track",
	at_risk: "At risk",
	off_track: "Off track",
	overdue: "Date passed",
};

const PRIORITY_LABELS = { high: "High", medium: "Medium", low: "Low" };
const PROFILE_LABELS = {
	conservative: "Conservative",
	balanced: "Balanced",
	growth: "Growth",
};
const HORIZON_LABELS = {
	short: "Short horizon",
	medium: "Medium horizon",
	long: "Long horizon",
};
const SURPLUS_MONTHS = 6;
const FUNDABLE_ACCOUNT_TYPES = ["Depository", "Investment", "Crypto"];

const state = {
	sure: null,
	today: localToday(),
	currency: "USD",
	locale: undefined,
	assumptions: P.mergeAssumptions(null),
	goals: [],
	accounts: [],
	otherCurrencyAccounts: [],
	holdingsByAccount: {},
	netWorth: null,
	surplus: null,
	surplusNote: "",
	medianExpenses: null,
	editingId: null,
	trackingId: null,
	trackError: null,
	confirmDeleteId: null,
	refreshTimer: null,
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function localToday() {
	const now = new Date();
	const pad = (n) => String(n).padStart(2, "0");
	return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

function el(tag, attrs, ...children) {
	const node = document.createElement(tag);
	for (const [key, value] of Object.entries(attrs || {})) {
		if (value === undefined || value === null || value === false) continue;
		if (key === "class") node.className = value;
		else if (key === "text") node.textContent = value;
		else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
		else if (key in node && key !== "list") node[key] = value;
		else node.setAttribute(key, value === true ? "" : value);
	}
	for (const child of children.flat()) {
		if (child === null || child === undefined || child === false) continue;
		node.append(child instanceof Node ? child : String(child));
	}
	return node;
}

function svg(tag, attrs) {
	const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
	for (const [key, value] of Object.entries(attrs || {})) {
		if (key === "text") node.textContent = value;
		else node.setAttribute(key, value);
	}
	return node;
}

const formatters = {};
function money(amount, digits = 0) {
	if (!Number.isFinite(amount)) return "—";
	const key = String(digits);
	if (!formatters[key]) {
		try {
			formatters[key] = new Intl.NumberFormat(state.locale, {
				style: "currency",
				currency: state.currency,
				minimumFractionDigits: digits,
				maximumFractionDigits: digits,
			});
		} catch (_error) {
			formatters[key] = {
				format: (v) => `${v.toFixed(digits)} ${state.currency}`,
			};
		}
	}
	return formatters[key].format(amount);
}

function percent(rate, digits = 1) {
	return `${(rate * 100).toFixed(digits)}%`;
}

function formatDate(iso) {
	const date = P.parseDate(iso);
	if (!date) return iso || "";
	try {
		return new Intl.DateTimeFormat(state.locale, {
			year: "numeric",
			month: "short",
			timeZone: "UTC",
		}).format(date);
	} catch (_error) {
		return iso;
	}
}

function newId() {
	return `g-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function setStatus(text, kind) {
	const status = $("status");
	status.textContent = text;
	status.className = kind === "error" ? "error" : "muted";
}

function describeError(error) {
	const codes = window.SureMiniApp.ErrorCodes;
	switch (error?.code) {
		case codes.PERMISSION_DENIED:
			return `Sure refused: the "${error.data?.permission}" permission is not granted to this app.`;
		case codes.CONFIRMATION_REQUIRED:
			return "Sure needs you to confirm this change but could not ask. Try again.";
		case codes.DECLINED:
			return "You declined the change in Sure. Nothing was created.";
		case codes.APP_DISABLED:
			return "A family admin has disabled this app.";
		case codes.RATE_LIMITED:
			return "Too many requests. Wait a moment and try again.";
		case codes.TOOL_ERROR:
			return "Sure could not complete that request.";
		case codes.NOT_EMBEDDED:
			return "Open this page from Sure's Apps page.";
		default:
			return error?.message || String(error);
	}
}

function can(permission) {
	return Boolean(state.sure?.can(permission));
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

async function loadGoals() {
	const goals = [];
	let cursor = null;
	for (let page = 0; page < 10; page++) {
		const { items, nextCursor } = await state.sure.storage.list(STORE.goals, {
			limit: 200,
			cursor,
		});
		for (const item of items) {
			if (item.data && typeof item.data === "object") {
				goals.push(normalizeGoal({ ...item.data, id: item.key }));
			}
		}
		if (!nextCursor) break;
		cursor = nextCursor;
	}
	goals.sort((a, b) =>
		String(a.createdAt || "").localeCompare(String(b.createdAt || "")),
	);
	state.goals = goals;
}

function normalizeGoal(goal) {
	return {
		id: goal.id,
		kind: KINDS[goal.kind] ? goal.kind : "other",
		name: String(goal.name || "Goal"),
		targetAmount: Number(goal.targetAmount) || 0,
		targetDate: goal.targetDate,
		priority: PRIORITY_LABELS[goal.priority] ? goal.priority : "medium",
		riskProfile: PROFILE_LABELS[goal.riskProfile]
			? goal.riskProfile
			: "balanced",
		monthlyContribution: Number.isFinite(goal.monthlyContribution)
			? goal.monthlyContribution
			: null,
		earmarks: Array.isArray(goal.earmarks)
			? goal.earmarks.filter((e) => e?.accountId)
			: [],
		sureGoal: goal.sureGoal || null,
		createdAt: goal.createdAt || new Date().toISOString(),
	};
}

async function saveGoal(goal) {
	const { id, ...data } = goal;
	await state.sure.storage.set(STORE.goals, id, data);
}

async function loadAssumptions() {
	const saved = await state.sure.storage.get(
		STORE.settings,
		STORE.assumptionsKey,
	);
	state.assumptions = P.mergeAssumptions(saved);
}

// ---------------------------------------------------------------------------
// Sure data
// ---------------------------------------------------------------------------

async function loadAccounts() {
	if (!can("accounts:read")) return;
	const result = await state.sure.accounts.list();
	// Only liquid accounts can fund a goal (Sure's own goals use the same
	// types); a house or a car is not money you can set aside.
	const assets = (result.accounts || []).filter(
		(account) =>
			account.classification === "asset" &&
			FUNDABLE_ACCOUNT_TYPES.includes(account.type),
	);
	state.accounts = assets
		.filter((account) => account.currency === state.currency)
		.map((account) => ({
			id: account.id,
			name: account.name,
			type: account.type,
			subtype: account.subtype,
			balance: Number(account.balance) || 0,
		}));
	state.otherCurrencyAccounts = assets.filter(
		(account) => account.currency !== state.currency,
	);

	state.holdingsByAccount = {};
	if (
		state.accounts.some((a) => a.type === "Investment" || a.type === "Crypto")
	) {
		await loadHoldings();
	}
}

async function loadHoldings() {
	const byAccount = {};
	let page = 1;
	let totalPages = 1;
	do {
		const result = await state.sure.accounts.holdings({ page });
		for (const holding of result.holdings || []) {
			if (!byAccount[holding.account]) byAccount[holding.account] = [];
			byAccount[holding.account].push(holding);
		}
		totalPages = result.total_pages || 1;
		page += 1;
	} while (page <= totalPages && page <= 5);
	state.holdingsByAccount = byAccount;
}

async function loadReports() {
	if (!can("reports:read")) return;

	const [sheet, income] = await Promise.all([
		state.sure.reports.balanceSheet({
			period: "last_7_days",
			interval: "1 day",
		}),
		state.sure.reports.incomeStatement({
			...P.completedMonthsRange(state.today, SURPLUS_MONTHS),
			group_by: "month",
		}),
	]);

	if (sheet && !sheet.error) {
		state.netWorth = {
			net: sheet.net_worth?.current,
			assets: sheet.assets?.current,
			liabilities: sheet.liabilities?.current,
		};
	}

	if (income?.error) {
		state.surplus = null;
		state.surplusNote = income.message || "Sure could not report income.";
		return;
	}
	const nets = (income?.monthly_series || []).map((month) =>
		P.parseFormattedMoney(month.net),
	);
	state.surplus = P.median(nets);
	// The median can be far below typical spending when a few large months
	// dominate; fall back to the average rather than suggest a tiny reserve.
	const median = P.parseFormattedMoney(
		income?.insights?.median_monthly_expenses,
	);
	const average = P.parseFormattedMoney(
		income?.insights?.avg_monthly_expenses,
	);
	state.medianExpenses =
		Number.isFinite(average) && (!Number.isFinite(median) || median < average / 4)
			? average
			: median;
	state.surplusNote =
		state.surplus === null
			? "No income or spending recorded in the last six months."
			: `Median monthly income minus spending over ${income.period?.start_date} to ${income.period?.end_date}.`;
}

async function refreshSureData() {
	try {
		await Promise.all([loadAccounts(), loadReports()]);
	} catch (error) {
		setStatus(describeError(error), "error");
	}
	render();
}

function scheduleRefresh() {
	clearTimeout(state.refreshTimer);
	state.refreshTimer = setTimeout(refreshSureData, 200);
}

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

function accountById(id) {
	return state.accounts.find((account) => account.id === id);
}

function earmarkedValue(goal) {
	return goal.earmarks.reduce(
		(sum, earmark) => sum + Math.max(0, Number(earmark.amount) || 0),
		0,
	);
}

// Two passes: first what each goal needs, then share the surplus by priority
// and project each goal with the contribution it is assigned.
function buildPlans() {
	const base = {};
	for (const goal of state.goals) {
		base[goal.id] = P.planGoal({
			goal,
			assumptions: state.assumptions,
			today: state.today,
			currentValue: earmarkedValue(goal),
			contribution: goal.monthlyContribution || 0,
		});
	}

	const priorities = P.prioritize(
		state.goals.map((goal) => ({
			id: goal.id,
			priority: goal.priority,
			targetDate: goal.targetDate,
			requiredMonthly: base[goal.id].requiredMonthly || 0,
			ownContribution: goal.monthlyContribution ?? undefined,
		})),
		state.surplus,
	);

	const plans = {};
	for (const goal of state.goals) {
		const row = priorities.rows.find((r) => r.id === goal.id);
		const own = goal.monthlyContribution;
		const contribution = own ?? (state.surplus !== null ? row.allocated : 0);
		const source =
			own !== null
				? "your figure"
				: state.surplus !== null
					? "share of surplus"
					: "none assumed";
		plans[goal.id] = {
			...P.planGoal({
				goal,
				assumptions: state.assumptions,
				today: state.today,
				currentValue: earmarkedValue(goal),
				contribution,
			}),
			contributionSource: source,
		};
	}
	return { plans, priorities };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function render() {
	const { plans, priorities } = buildPlans();
	renderSummary(priorities);
	renderGoals(plans);
	renderPriorities(priorities, plans);
	renderAi();
	renderAccounts();
	renderAssumptions();
}

function card(label, value, note) {
	return el(
		"div",
		{ class: "card" },
		el("div", { class: "muted small", text: label }),
		el("div", { class: "big", text: value }),
		note ? el("div", { class: "muted small", text: note }) : null,
	);
}

function renderSummary(priorities) {
	const cards = [];
	if (can("reports:read")) {
		cards.push(
			card(
				"Net worth",
				state.netWorth?.net || "—",
				state.netWorth
					? `Assets ${state.netWorth.assets} · Debts ${state.netWorth.liabilities}`
					: null,
			),
			card("Monthly surplus", money(state.surplus), state.surplusNote),
		);
	}
	const totalEarmarked = state.goals.reduce(
		(sum, goal) => sum + earmarkedValue(goal),
		0,
	);
	cards.push(card("Earmarked for goals", money(totalEarmarked)));
	cards.push(
		card(
			"Plan needs each month",
			money(priorities.totalNeed),
			priorities.shareOfSurplus !== null
				? `${percent(priorities.shareOfSurplus, 0)} of your surplus`
				: "First payments; they rise each year",
		),
	);
	$("summary").replaceChildren(...cards);

	const warning = $("surplus-warning");
	warning.hidden = true;
	if (priorities.surplus === null || state.goals.length === 0) return;
	if (priorities.surplus <= 0) {
		warning.hidden = false;
		warning.textContent = `You spent at least what you earned in a typical recent month, so there is no surplus to fund goals with. Your goals need ${money(priorities.totalNeed)} a month.`;
	} else if (priorities.shortfall > 0) {
		const unfunded = priorities.rows
			.filter((row) => row.fits === false)
			.map((row) => state.goals.find((g) => g.id === row.id)?.name)
			.filter(Boolean);
		warning.hidden = false;
		warning.textContent = `Your goals need ${money(priorities.totalNeed)} a month, ${money(priorities.shortfall)} more than your surplus of ${money(priorities.surplus)}. Not fully covered, by priority: ${unfunded.join(", ")}. Consider later dates, smaller targets or lower priorities.`;
	}
}

function renderGoals(plans) {
	const container = $("goals");
	container.replaceChildren(
		...state.goals
			.slice()
			.sort((a, b) => String(a.targetDate).localeCompare(String(b.targetDate)))
			.map((goal) => goalCard(goal, plans[goal.id])),
	);
	$("no-goals").hidden = state.goals.length > 0;
}

function badge(text, kind) {
	return el("span", { class: `badge ${kind || ""}`, text });
}

function stat(label, value, note) {
	return el(
		"div",
		{ class: "stat" },
		el("dt", { text: label }),
		el(
			"dd",
			{},
			value,
			note ? el("span", { class: "muted small", text: ` ${note}` }) : null,
		),
	);
}

function goalCard(goal, plan) {
	const a = state.assumptions;
	const yearsText =
		plan.months <= 0
			? "Target date has passed"
			: plan.years < 1
				? `${plan.months} months`
				: `${plan.years.toFixed(1)} years`;

	const needs =
		plan.requiredMonthly === null
			? stat("Due now", money(plan.dueNow))
			: stat(
					"Needs each month",
					money(plan.requiredMonthly),
					a.contributionGrowth
						? `to start, rising ${percent(a.contributionGrowth)} a year`
						: null,
				);

	const stats = el(
		"dl",
		{ class: "stats" },
		stat(
			"Time to go",
			yearsText,
			`${plan.months > 0 ? "to" : "on"} ${formatDate(goal.targetDate)}`,
		),
		stat(
			"Target",
			money(plan.futureTarget),
			a.targetsInTodaysMoney && plan.months > 0
				? `(${money(plan.target)} in today's money)`
				: null,
		),
		stat(
			"Earmarked",
			money(plan.currentValue),
			plan.months > 0 ? `→ ${money(plan.projectedEarmark)} by then` : null,
		),
		stat("Gap at target date", money(plan.gap)),
		needs,
		stat(
			"Assumed saving",
			`${money(plan.contribution)}/mo`,
			`(${plan.contributionSource})`,
		),
		stat(
			"Projected at target date",
			money(plan.projected),
			plan.futureTarget > 0
				? `(${percent(Math.min(plan.projected / plan.futureTarget, 9.99), 0)} of target)`
				: null,
		),
		stat(
			"Return assumed",
			percent(plan.annualReturn),
			`(${percent(plan.realReturn)} after inflation)`,
		),
		stat(
			"Suggested mix",
			`${plan.mix.equity}% equity · ${plan.mix.bonds}% bonds · ${plan.mix.cash}% cash`,
		),
	);

	const header = el(
		"div",
		{ class: "goal-head" },
		el(
			"div",
			{},
			el("h3", { text: goal.name }),
			KINDS[goal.kind].label === goal.name
				? null
				: el("div", { class: "muted small", text: KINDS[goal.kind].label }),
		),
		el(
			"div",
			{ class: "badges" },
			badge(STATUS_LABELS[plan.status], `status-${plan.status}`),
			badge(`${PRIORITY_LABELS[goal.priority]} priority`),
			badge(HORIZON_LABELS[plan.horizon]),
			badge(PROFILE_LABELS[plan.profile]),
		),
	);

	const capped =
		plan.profileCapped && plan.months > 0
			? el("p", {
					class: "muted small",
					text: `Using ${PROFILE_LABELS[plan.profile].toLowerCase()} instead of ${PROFILE_LABELS[goal.riskProfile].toLowerCase()}: with ${yearsText.toLowerCase()} to go there is little time to recover from a market fall.`,
				})
			: null;

	return el(
		"article",
		{ class: "goal panel" },
		header,
		capped,
		stats,
		plan.months > 0 ? chart(plan) : null,
		earmarkEditor(goal),
		goalActions(goal, plan),
		state.trackingId === goal.id ? trackPanel(goal, plan) : null,
	);
}

function chart(plan) {
	const series = P.projectionSeries(plan, state.assumptions);
	const width = 560;
	const height = 170;
	const pad = { left: 8, right: 8, top: 18, bottom: 22 };
	const maxValue =
		Math.max(
			1,
			...series.map((p) => Math.max(p.planned, p.required, p.target)),
		) * 1.05;
	const x = (month) =>
		pad.left +
		(month / Math.max(plan.months, 1)) * (width - pad.left - pad.right);
	const y = (value) =>
		height - pad.bottom - (value / maxValue) * (height - pad.top - pad.bottom);
	const path = (key) =>
		series
			.map(
				(p, i) =>
					`${i ? "L" : "M"}${x(p.month).toFixed(1)},${y(p[key]).toFixed(1)}`,
			)
			.join(" ");

	const root = svg("svg", {
		viewBox: `0 0 ${width} ${height}`,
		class: "chart",
		role: "img",
		"aria-label": `Projection: ${money(plan.projected)} expected against a target of ${money(plan.futureTarget)}.`,
	});
	root.append(
		svg("line", {
			x1: pad.left,
			x2: width - pad.right,
			y1: y(0),
			y2: y(0),
			class: "axis",
		}),
		svg("path", { d: path("target"), class: "line target" }),
		svg("path", { d: path("required"), class: "line required" }),
		svg("path", { d: path("planned"), class: "line planned" }),
		svg("text", { x: pad.left, y: 12, class: "label", text: money(maxValue) }),
		svg("text", { x: pad.left, y: height - 6, class: "label", text: "Now" }),
		svg("text", {
			x: width - pad.right,
			y: height - 6,
			class: "label",
			"text-anchor": "end",
			text: formatDate(P.addMonths(state.today, plan.months)),
		}),
	);

	const legend = el(
		"div",
		{ class: "legend small" },
		el("span", { class: "key planned", text: "With assumed saving" }),
		el("span", { class: "key required", text: "With required saving" }),
		el("span", { class: "key target", text: "Target" }),
	);
	return el("figure", { class: "chart-wrap" }, root, legend);
}

function earmarkEditor(goal) {
	const rows = goal.earmarks.map((earmark) => {
		const account = accountById(earmark.accountId);
		return el(
			"li",
			{},
			el("span", {
				text: account?.name || earmark.accountName || "Unknown account",
			}),
			el("span", { class: "num", text: money(Number(earmark.amount) || 0) }),
			account
				? null
				: el("span", { class: "muted small", text: "(no longer available)" }),
			el("button", {
				type: "button",
				class: "link",
				text: "Remove",
				onclick: () => removeEarmark(goal, earmark.accountId),
			}),
		);
	});

	const section = el(
		"div",
		{ class: "earmarks" },
		el("h4", { text: "Earmarked funds" }),
		rows.length
			? el("ul", { class: "earmark-list" }, rows)
			: el("p", { class: "muted small", text: "Nothing earmarked yet." }),
	);

	if (!can("accounts:read")) {
		section.append(
			el("p", {
				class: "muted small",
				text: "Earmarking needs the accounts:read permission.",
			}),
		);
		return section;
	}
	if (state.accounts.length === 0) return section;

	const select = el(
		"select",
		{ "aria-label": "Account" },
		state.accounts.map((account) =>
			el("option", {
				value: account.id,
				text: `${account.name} (${money(freeAmount(account.id), 0)} free)`,
			}),
		),
	);
	const amount = el("input", {
		type: "number",
		min: "0",
		step: "any",
		placeholder: "Amount",
		"aria-label": "Amount to earmark",
	});
	const fillFree = () => {
		amount.value = String(Math.max(0, Math.floor(freeAmount(select.value))));
	};
	section.append(
		el(
			"form",
			{
				class: "inline",
				onsubmit: (event) => {
					event.preventDefault();
					addEarmark(goal, select.value, Number(amount.value));
				},
			},
			select,
			amount,
			el("button", {
				type: "button",
				class: "secondary",
				text: "All free",
				onclick: fillFree,
			}),
			el("button", { type: "submit", text: "Earmark" }),
		),
	);
	return section;
}

function freeAmount(accountId) {
	const account = accountById(accountId);
	if (!account) return 0;
	const totals = P.earmarkTotals(state.goals, { [accountId]: account.balance });
	return totals[accountId] ? totals[accountId].free : account.balance;
}

function goalActions(goal) {
	const actions = el(
		"div",
		{ class: "actions" },
		el("button", {
			type: "button",
			class: "secondary",
			text: "Edit",
			onclick: () => openForm(goal),
		}),
		el("button", {
			type: "button",
			class: state.confirmDeleteId === goal.id ? "danger" : "secondary",
			text:
				state.confirmDeleteId === goal.id ? "Click again to delete" : "Delete",
			onclick: () => deleteGoal(goal),
		}),
	);

	if (goal.sureGoal) {
		const url = goal.sureGoal.url;
		actions.append(
			el(
				"span",
				{ class: "muted small" },
				"Tracked in Sure",
				/^https:\/\//.test(url || "")
					? el("a", {
							href: url,
							target: "_blank",
							rel: "noopener noreferrer",
							text: " · open",
						})
					: " (open it from Goals in Sure)",
			),
		);
	} else if (can("goals:write")) {
		actions.append(
			el("button", {
				type: "button",
				text: state.trackingId === goal.id ? "Close" : "Track in Sure",
				onclick: () => {
					state.trackingId = state.trackingId === goal.id ? null : goal.id;
					state.trackError = null;
					render();
				},
			}),
		);
	}
	return actions;
}

function trackPanel(goal, plan) {
	const panel = el(
		"div",
		{ class: "track" },
		el("h4", { text: "Track in Sure" }),
	);
	if (!can("accounts:read")) {
		panel.append(
			el("p", {
				class: "muted",
				text: "Sure goals link to your savings accounts, so this needs the accounts:read permission to list them.",
			}),
		);
		return panel;
	}
	const depository = state.accounts.filter((a) => a.type === "Depository");
	if (depository.length === 0) {
		panel.append(
			el("p", {
				class: "muted",
				text: `Sure goals must link to a cash account (checking, savings and similar) in ${state.currency}. You have none.`,
			}),
		);
		return panel;
	}

	const earmarked = new Set(goal.earmarks.map((e) => e.accountId));
	const boxes = depository.map((account) =>
		el(
			"label",
			{ class: "check" },
			el("input", {
				type: "checkbox",
				value: account.id,
				checked: earmarked.has(account.id) || depository.length === 1,
			}),
			account.name,
			earmarked.has(account.id)
				? el("span", {
						class: "muted small",
						text: `reserve ${money(Number(goal.earmarks.find((e) => e.accountId === account.id).amount) || 0)}`,
					})
				: el("span", {
						class: "muted small",
						text: "reserve what is spare",
					}),
		),
	);

	const target = Math.round(plan.futureTarget * 100) / 100;
	panel.append(
		el("p", {
			class: "muted small",
			text: `Sure will get the goal "${goal.name}" with a target of ${money(target, 2)}${plan.months > 0 ? ` by ${goal.targetDate}` : ""}. ${state.sure.writePolicy === "confirm" ? "Sure will ask you to confirm." : ""}`,
		}),
		el("div", { class: "checks" }, boxes),
	);
	if (state.trackError) {
		panel.append(state.trackError);
	}
	panel.append(
		el("button", {
			type: "button",
			text: "Create goal in Sure",
			onclick: (event) => {
				const chosen = boxes
					.map((box) => box.querySelector("input"))
					.filter((input) => input.checked)
					.map((input) => input.value);
				trackInSure(goal, plan, chosen, event.target);
			},
		}),
	);
	return panel;
}

function renderPriorities(priorities, plans) {
	const section = $("priority-section");
	section.hidden = state.goals.length === 0;
	$("priorities").replaceChildren(
		...priorities.rows.map((row) => {
			const goal = state.goals.find((g) => g.id === row.id);
			const fits = row.fits === null ? "—" : row.fits ? "Yes" : "No";
			return el(
				"tr",
				{},
				el("td", { text: goal.name }),
				el("td", { text: PRIORITY_LABELS[goal.priority] }),
				el("td", {
					class: "num",
					text:
						row.ownContribution !== null
							? `${money(row.ownContribution)} (yours)`
							: plans[row.id].requiredMonthly === null
								? `${money(plans[row.id].dueNow)} due now`
								: money(row.need),
				}),
				el("td", { class: "num", text: money(row.allocated) }),
				el("td", { class: "num", text: money(row.cumulative) }),
				el("td", { class: row.fits === false ? "error" : "", text: fits }),
			);
		}),
	);
}

// ---------------------------------------------------------------------------
// AI explanation (ai:use)
// ---------------------------------------------------------------------------

const AI_INSTRUCTIONS =
	"You are a friendly, plain-spoken financial coach. Explain the person's goal plan in at most five short sentences: whether it holds together, the biggest risk, and one practical next step. Use only the numbers given. Do not recommend specific funds, stocks or products, and do not promise returns.";

function renderAi() {
	const ai = state.sure?.ai;
	const section = $("ai-section");
	section.hidden = !can("ai:use") || state.goals.length === 0;
	if (section.hidden) return;

	const button = $("ai-explain");
	if (!ai.available) {
		$("ai-where").textContent =
			"Sure has no AI model set up yet. An admin can turn on Local AI in Sure Desktop or set up a provider in Settings.";
		button.disabled = true;
		return;
	}
	$("ai-where").textContent = ai.local
		? `Runs on this computer with ${ai.model}. Your plan does not leave this machine.`
		: `Your plan summary is sent to Sure's AI provider (${ai.model}).`;
	button.disabled = state.aiBusy === true;
}

function planSummaryForAi() {
	const { plans, priorities } = buildPlans();
	return {
		currency: state.currency,
		monthlySurplus: state.surplus,
		goals: state.goals.map((goal) => {
			const plan = plans[goal.id];
			const row = priorities.rows.find((r) => r.id === goal.id);
			return {
				name: goal.name,
				kind: goal.kind,
				priority: goal.priority,
				targetDate: goal.targetDate,
				targetTodayMoney: Math.round(plan.target),
				targetAtDate: Math.round(plan.futureTarget),
				earmarkedNow: Math.round(plan.currentValue),
				neededPerMonth: plan.requiredMonthly === null ? null : Math.round(plan.requiredMonthly),
				assignedPerMonth: Math.round(row.allocated),
				fitsSurplus: row.fits,
				status: plan.status,
				assetMix: plan.mix,
				assumedAnnualReturn: Number(plan.annualReturn.toFixed(3)),
			};
		}),
	};
}

async function explainPlan() {
	const answer = $("ai-answer");
	state.aiBusy = true;
	renderAi();
	answer.hidden = false;
	answer.textContent = state.sure.ai.local
		? "Thinking on this computer… a local model can take up to a minute."
		: "Thinking…";
	try {
		const result = await state.sure.ai.complete(
			`Here is my goal plan as JSON:\n${JSON.stringify(planSummaryForAi())}`,
			{ instructions: AI_INSTRUCTIONS },
		);
		answer.textContent = result.text || "The model returned no answer.";
	} catch (error) {
		answer.textContent =
			error?.code === -32007
				? "Sure has no AI model set up yet."
				: error?.code === -32003
					? "This app has not been given permission to use Sure's AI."
					: "The AI model could not answer. Try again in a moment.";
	} finally {
		state.aiBusy = false;
		renderAi();
	}
}

function renderAccounts() {
	const section = $("accounts-section");
	section.hidden = !can("accounts:read");
	if (section.hidden) return;

	const balances = Object.fromEntries(
		state.accounts.map((a) => [a.id, a.balance]),
	);
	const totals = P.earmarkTotals(state.goals, balances);
	$("accounts").replaceChildren(
		...state.accounts.map((account) => {
			const total = totals[account.id];
			const allocated = total ? total.allocated : 0;
			const free = account.balance - allocated;
			return el(
				"tr",
				{},
				el("td", { text: account.name }),
				el("td", { text: account.subtype || account.type }),
				el("td", { class: "num", text: money(account.balance) }),
				el("td", { class: "num", text: money(allocated) }),
				el("td", {
					class: `num ${total?.over ? "error" : ""}`,
					text: total?.over ? `${money(free)} over` : money(free),
				}),
			);
		}),
	);

	const notes = [];
	if (state.accounts.length === 0) notes.push("No asset accounts found.");
	if (state.otherCurrencyAccounts.length > 0) {
		notes.push(
			`Not shown, because they are not in ${state.currency}: ${state.otherCurrencyAccounts.map((a) => `${a.name} (${a.currency})`).join(", ")}.`,
		);
	}
	$("accounts-note").textContent = notes.join(" ");

	const holdings = Object.entries(state.holdingsByAccount).map(
		([name, items]) =>
			el(
				"details",
				{ class: "holdings" },
				el("summary", { text: `Holdings in ${name} (${items.length})` }),
				el(
					"ul",
					{},
					items.map((h) =>
						el(
							"li",
							{},
							`${h.ticker || h.name}: ${h.formatted_amount}`,
							h.weight !== null && h.weight !== undefined
								? el("span", {
										class: "muted small",
										text: ` ${h.weight}% of portfolio`,
									})
								: null,
						),
					),
				),
			),
	);
	$("holdings").replaceChildren(...holdings);
}

function renderAssumptions() {
	const a = state.assumptions;
	const set = (id, rate) => {
		if (document.activeElement !== $(id)) $(id).value = (rate * 100).toFixed(1);
	};
	set("ret-conservative", a.returns.conservative);
	set("ret-balanced", a.returns.balanced);
	set("ret-growth", a.returns.growth);
	set("inflation", a.inflation);
	set("contribution-growth", a.contributionGrowth);
	$("todays-money").checked = a.targetsInTodaysMoney;
	$("goal-amount-label").textContent = a.targetsInTodaysMoney
		? `Target amount (today's money, ${state.currency})`
		: `Target amount (${state.currency})`;
	$("mixes").replaceChildren(
		...P.PROFILES.map((profile) =>
			el(
				"tr",
				{},
				el("td", {
					text: `${PROFILE_LABELS[profile]} (${percent(a.returns[profile])})`,
				}),
				el("td", { class: "num", text: `${P.MIXES[profile].equity}%` }),
				el("td", { class: "num", text: `${P.MIXES[profile].bonds}%` }),
				el("td", { class: "num", text: `${P.MIXES[profile].cash}%` }),
			),
		),
	);
}

function showMissingPermissions() {
	const effects = {
		"accounts:read": "earmarking accounts",
		"reports:read": "net worth and monthly surplus",
		"goals:write": "tracking goals in Sure",
	};
	const missing = Object.keys(effects).filter((p) => !can(p));
	const notice = $("missing");
	notice.hidden = missing.length === 0;
	notice.textContent = `Turned off because a permission is not granted: ${missing.map((p) => `${effects[p]} (${p})`).join(", ")}. Goals still work from what you enter.`;
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

function openForm(goal) {
	state.editingId = goal ? goal.id : null;
	$("goal-form-title").textContent = goal ? `Edit ${goal.name}` : "New goal";
	$("goal-kind").value = goal ? goal.kind : "emergency";
	$("goal-name").value = goal ? goal.name : "";
	$("goal-amount").value = goal ? String(goal.targetAmount) : "";
	$("goal-date").value = goal ? goal.targetDate : "";
	$("goal-priority").value = goal ? goal.priority : "high";
	$("goal-risk").value = goal ? goal.riskProfile : "conservative";
	$("goal-contribution").value =
		goal && goal.monthlyContribution !== null
			? String(goal.monthlyContribution)
			: "";
	if (!goal) applyKindDefaults(true);
	$("goal-form").hidden = false;
	$("goal-name").focus();
}

function applyKindDefaults(force) {
	const kind = $("goal-kind").value;
	const defaults = KINDS[kind];
	const nameInput = $("goal-name");
	const previousDefault = Object.values(KINDS).some(
		(k) => k.label === nameInput.value,
	);
	if (force || !nameInput.value || previousDefault) {
		nameInput.value = kind === "other" ? "" : defaults.label;
	}
	$("goal-priority").value = defaults.priority;
	$("goal-risk").value = defaults.risk;
	$("goal-date").value = P.addMonths(state.today, defaults.months);
	if (
		kind === "emergency" &&
		!$("goal-amount").value &&
		Number.isFinite(state.medianExpenses) &&
		state.medianExpenses > 0
	) {
		$("goal-amount").value = String(Math.round(state.medianExpenses * 6));
		setStatus("Suggested six months of your typical spending as the target.");
	}
}

async function submitGoal(event) {
	event.preventDefault();
	const amount = Number($("goal-amount").value);
	const date = $("goal-date").value;
	if (!(amount > 0) || !P.parseDate(date)) {
		setStatus("Enter a target amount above zero and a valid date.", "error");
		return;
	}
	const contributionText = $("goal-contribution").value.trim();
	const existing = state.goals.find((g) => g.id === state.editingId);
	const goal = normalizeGoal({
		...(existing || { id: newId(), earmarks: [] }),
		kind: $("goal-kind").value,
		name: $("goal-name").value.trim() || KINDS[$("goal-kind").value].label,
		targetAmount: amount,
		targetDate: date,
		priority: $("goal-priority").value,
		riskProfile: $("goal-risk").value,
		monthlyContribution:
			contributionText === "" ? null : Math.max(0, Number(contributionText)),
	});
	try {
		await saveGoal(goal);
		state.goals = existing
			? state.goals.map((g) => (g.id === goal.id ? goal : g))
			: [...state.goals, goal];
		$("goal-form").hidden = true;
		state.editingId = null;
		setStatus(`Saved "${goal.name}".`);
		render();
	} catch (error) {
		setStatus(describeError(error), "error");
	}
}

async function updateGoal(goal, changes, message) {
	const updated = { ...goal, ...changes };
	try {
		await saveGoal(updated);
		state.goals = state.goals.map((g) => (g.id === goal.id ? updated : g));
		if (message) setStatus(message);
		render();
	} catch (error) {
		setStatus(describeError(error), "error");
	}
}

function addEarmark(goal, accountId, amount) {
	const account = accountById(accountId);
	if (!account || !(amount > 0)) {
		setStatus("Choose an account and an amount above zero.", "error");
		return;
	}
	const others = goal.earmarks.filter((e) => e.accountId !== accountId);
	const free =
		freeAmount(accountId) +
		(Number(goal.earmarks.find((e) => e.accountId === accountId)?.amount) || 0);
	const earmarks = [
		...others,
		{ accountId, accountName: account.name, amount },
	];
	const warning =
		amount > free + 0.005
			? ` That is ${money(amount - free)} more than ${account.name} has free.`
			: "";
	updateGoal(
		goal,
		{ earmarks },
		`Earmarked ${money(amount)} of ${account.name} for "${goal.name}".${warning}`,
	);
}

function removeEarmark(goal, accountId) {
	updateGoal(
		goal,
		{ earmarks: goal.earmarks.filter((e) => e.accountId !== accountId) },
		"Earmark removed.",
	);
}

async function deleteGoal(goal) {
	// Sandboxed frames cannot open window.confirm, so deleting takes two clicks.
	if (state.confirmDeleteId !== goal.id) {
		state.confirmDeleteId = goal.id;
		render();
		return;
	}
	state.confirmDeleteId = null;
	try {
		await state.sure.storage.delete(STORE.goals, goal.id);
		state.goals = state.goals.filter((g) => g.id !== goal.id);
		setStatus(
			goal.sureGoal
				? `Deleted "${goal.name}" here. The goal in Sure is unchanged.`
				: `Deleted "${goal.name}".`,
		);
		render();
	} catch (error) {
		setStatus(describeError(error), "error");
	}
}

async function trackInSure(goal, plan, accountIds, button) {
	if (accountIds.length === 0) {
		state.trackError = el("p", {
			class: "error",
			text: "Choose at least one account to link.",
		});
		render();
		return;
	}
	const accounts = accountIds.map(accountById).filter(Boolean);
	const earmarks = {};
	for (const account of accounts) {
		const earmark = goal.earmarks.find((e) => e.accountId === account.id);
		if (earmark && Number(earmark.amount) > 0) {
			earmarks[account.name] = Number(earmark.amount);
		}
	}
	const args = {
		name: goal.name,
		target_amount: Math.round(plan.futureTarget * 100) / 100,
		linked_account_names: accounts.map((a) => a.name),
		notes: `From Goal Planner: ${KINDS[goal.kind].label}, ${PROFILE_LABELS[plan.profile].toLowerCase()} profile at ${percent(plan.annualReturn)} a year.`,
	};
	if (plan.months > 0) args.target_date = goal.targetDate;
	if (Object.keys(earmarks).length > 0) args.earmarks = earmarks;

	button.disabled = true;
	setStatus(`Creating "${goal.name}" in Sure… Sure may ask you to confirm.`);
	try {
		const result = await state.sure.goals.create(args);
		if (result?.success === false) {
			state.trackError = trackFailure(result);
			setStatus(result.message || "Sure did not create the goal.", "error");
			render();
			return;
		}
		state.trackingId = null;
		state.trackError = null;
		await updateGoal(
			goal,
			{
				sureGoal: {
					id: result.goal_id,
					url: result.url,
					createdAt: new Date().toISOString(),
				},
			},
			`Created "${result.name}" in Sure with a target of ${result.target_amount_formatted}.`,
		);
	} catch (error) {
		state.trackError = el("p", { class: "error", text: describeError(error) });
		setStatus(describeError(error), "error");
		render();
	}
}

function trackFailure(result) {
	const box = el(
		"div",
		{ class: "notice warn" },
		el("p", { text: result.message }),
	);
	if (Array.isArray(result.available_accounts)) {
		box.append(
			el("p", { class: "small", text: "Accounts Sure can link:" }),
			el(
				"ul",
				{ class: "small" },
				result.available_accounts.map((a) =>
					el(
						"li",
						{},
						`${a.name} (${a.currency}): ${a.free_to_earmark} free`,
						a.claimed_in_full
							? " — claimed in full by another goal; earmark an amount"
							: "",
					),
				),
			),
		);
	}
	return box;
}

async function saveAssumptions(event) {
	event.preventDefault();
	const read = (id) => Number($(id).value) / 100;
	const next = P.mergeAssumptions({
		returns: {
			conservative: read("ret-conservative"),
			balanced: read("ret-balanced"),
			growth: read("ret-growth"),
		},
		inflation: read("inflation"),
		contributionGrowth: read("contribution-growth"),
		targetsInTodaysMoney: $("todays-money").checked,
	});
	try {
		await state.sure.storage.set(STORE.settings, STORE.assumptionsKey, next);
		state.assumptions = next;
		setStatus("Assumptions saved.");
		render();
	} catch (error) {
		setStatus(describeError(error), "error");
	}
}

async function resetAssumptions() {
	try {
		await state.sure.storage.delete(STORE.settings, STORE.assumptionsKey);
		state.assumptions = P.mergeAssumptions(null);
		setStatus("Assumptions reset.");
		render();
	} catch (error) {
		setStatus(describeError(error), "error");
	}
}

async function main() {
	try {
		state.sure = await window.SureMiniApp.connect();
	} catch (error) {
		setStatus(describeError(error), "error");
		return;
	}
	state.currency = state.sure.family?.currency || "USD";
	state.locale = state.sure.family?.locale || undefined;

	showMissingPermissions();

	$("add-goal").addEventListener("click", () => openForm(null));
	$("goal-cancel").addEventListener("click", () => {
		$("goal-form").hidden = true;
		state.editingId = null;
	});
	$("goal-kind").addEventListener("change", () => applyKindDefaults(false));
	$("goal-form").addEventListener("submit", submitGoal);
	$("assumptions-form").addEventListener("submit", saveAssumptions);
	$("assumptions-reset").addEventListener("click", resetAssumptions);
	$("ai-explain").addEventListener("click", explainPlan);

	// create_goal changes what accounts have free; Sure tells us after writes.
	state.sure.on("dataChanged", scheduleRefresh);

	try {
		await Promise.all([loadGoals(), loadAssumptions()]);
	} catch (error) {
		setStatus(describeError(error), "error");
	}
	render();
	setStatus("Loading your accounts and reports…");
	await refreshSureData();
	if ($("status").className !== "error") {
		setStatus(
			state.goals.length
				? `${state.goals.length} goal${state.goals.length === 1 ? "" : "s"} planned in ${state.currency}.`
				: "Add your first goal to start.",
		);
	}
}

main();
