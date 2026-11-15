// Net Worth Tracker: imports a month-by-account spreadsheet into Sure and
// records each later month from one form.
//
// Sure holds the balances: every value becomes a valuation on a Sure account
// (accounts:write creates the accounts, valuations:write records the values).
// Sure converts every account to the family currency with the exchange rates
// it fetches itself, so this app keeps no rates. Its own storage keeps which
// accounts are tracked and in which section, and each month's entered values
// and note, so the form can show last month's figures.

const STORE = {
	settings: "settings",
	settingsKey: "tracker",
	months: "months",
};
const ACCOUNT_TYPES = [
	"Depository",
	"Investment",
	"Crypto",
	"Property",
	"Vehicle",
	"OtherAsset",
	"CreditCard",
	"Loan",
	"OtherLiability",
];
const LIABILITY_TYPES = new Set(["CreditCard", "Loan", "OtherLiability"]);
const BATCH_SIZE = 120;
const IMPORT_SOURCE = "Legacy net worth tracker spreadsheet (grade: B)";
const entrySource = (date) => `Net worth check-in ${date} (grade: B)`;

const state = {
	sure: null,
	settings: { accounts: [], importedRows: {} },
	months: {}, // "2026-10" -> { values: { accountId: amount }, note }
	sureAccounts: [],
	parsed: null,
	importing: false,
	stopRequested: false,
};

const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, children = []) => {
	const node = Object.assign(document.createElement(tag), props);
	for (const child of [].concat(children)) {
		if (child !== null && child !== undefined) node.append(child);
	}
	return node;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function setStatus(text, isError = false) {
	$("status").textContent = text;
	$("status").classList.toggle("error", isError);
}

function describeError(error) {
	const codes = window.SureMiniApp.ErrorCodes;
	switch (error?.code) {
		case codes.PERMISSION_DENIED:
			return `Not allowed: a family admin needs to grant ${error.data?.permission} on Sure's Apps page.`;
		case codes.DECLINED:
			return "You declined the change in Sure.";
		case codes.RATE_LIMITED:
			return "Too many changes in a minute. Wait a moment and try again.";
		case codes.NOT_EMBEDDED:
			return "Open this page from Sure's Apps page.";
		case codes.METHOD_NOT_FOUND:
			return "This Sure version can't do that yet (turn on preview features in Settings → Preferences).";
		default:
			return error?.message || String(error);
	}
}

function formatAmount(value, currency) {
	if (value === null || value === undefined || Number.isNaN(value)) return "—";
	const number = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(value);
	return currency ? `${number} ${currency}` : number;
}

function currentMonth() {
	const now = new Date();
	return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
}

function today() {
	const now = new Date();
	return `${currentMonth()}-${String(now.getDate()).padStart(2, "0")}`;
}

// An imported month's value is dated its last day. The month in progress is
// dated today: Sure treats a future date as scheduled and leaves it out of
// balances until then.
function importDate(month) {
	const last = window.LegacyCsv.lastDayOfMonth(month);
	return last > today() ? today() : last;
}

function previousMonth(month) {
	const earlier = Object.keys(state.months)
		.filter((key) => key < month)
		.sort();
	return earlier.length ? earlier[earlier.length - 1] : null;
}

function sureAccount(id) {
	return state.sureAccounts.find((account) => account.id === id);
}

async function saveSettings() {
	await state.sure.storage.set(STORE.settings, STORE.settingsKey, state.settings);
}

async function saveMonth(month) {
	await state.sure.storage.set(STORE.months, month, state.months[month]);
}

async function loadAll() {
	const saved = await state.sure.storage.get(STORE.settings, STORE.settingsKey);
	if (saved && typeof saved === "object") Object.assign(state.settings, saved);
	if ("reportingCurrency" in state.settings) {
		delete state.settings.reportingCurrency;
		await saveSettings();
	}

	state.months = {};
	let cursor = null;
	do {
		const page = await state.sure.storage.list(STORE.months, { limit: 200, cursor });
		for (const item of page.items) {
			state.months[item.key] = item.data;
			// Version 1.0 saved exchange rates here; Sure provides them now.
			if (item.data?.fx) {
				delete item.data.fx;
				await saveMonth(item.key);
			}
		}
		cursor = page.nextCursor;
	} while (cursor);

	await loadSureAccounts();
}

async function loadSureAccounts() {
	const result = await state.sure.accounts.list();
	state.sureAccounts = result.accounts || [];
}

// Tracked accounts that still exist in Sure, in the order they were added.
function trackedAccounts() {
	return state.settings.accounts
		.map((tracked) => {
			const account = sureAccount(tracked.accountId);
			return account ? { ...tracked, name: account.name, currency: account.currency, balance: account.balance } : null;
		})
		.filter(Boolean);
}

// Sure's own month-end assets, liabilities and net worth in the family
// currency. Sure returns a point on the 1st of each month (the previous
// month's closing balance) and a last point for today, so the series starts
// the month after the first one with data.
async function loadSureHistory() {
	const months = Object.keys(state.months).sort();
	const first = months.length ? months[0] : currentMonth();
	const [firstYear, firstMonth] = first.split("-").map(Number);
	const start = new Date(Date.UTC(firstYear, firstMonth, 1)).toISOString().slice(0, 10);
	const sheet = await state.sure.reports.balanceSheet({ start_date: start, end_date: today(), interval: "1 month" });
	const series = (part) => part?.monthly_history?.values || [];
	const net = series(sheet.net_worth);
	const startDate = sheet.net_worth?.monthly_history?.start_date || start;
	const [year, month] = startDate.split("-").map(Number);
	const label = (offset) => {
		const date = new Date(Date.UTC(year, month - 1 + offset, 1));
		return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
	};

	return {
		currency: sheet.currency,
		current: sheet.net_worth?.current,
		rows: net.map((value, index) => ({
			// The last point is today: the month in progress.
			month: index === net.length - 1 ? `${currentMonth()} (so far)` : label(index - 1),
			key: index === net.length - 1 ? currentMonth() : label(index - 1),
			asset: series(sheet.assets)[index],
			// Sure reports liabilities as negative balances.
			liability: Math.abs(series(sheet.liabilities)[index] ?? 0),
			net: value,
		})),
	};
}

// Entered values summed per currency: Sure does the conversion.
function sumsByCurrency(accounts, valueFor) {
	const sums = {};
	for (const account of accounts) {
		const amount = valueFor(account);
		if (amount === null || amount === undefined) continue;
		const sign = account.section === "liability" ? -1 : 1;
		sums[account.currency] = (sums[account.currency] || 0) + sign * amount;
	}
	return sums;
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function showTab(name) {
	for (const tab of document.querySelectorAll("[role=tab]")) {
		tab.setAttribute("aria-selected", String(tab.dataset.tab === name));
	}
	for (const panel of document.querySelectorAll(".panel")) {
		panel.hidden = panel.id !== `tab-${name}`;
	}
	if (name === "monthly") renderMonthly();
	if (name === "history") renderHistory();
}

// ---------------------------------------------------------------------------
// Monthly entry
// ---------------------------------------------------------------------------

function renderMonthly() {
	const month = currentMonth();
	const record = state.months[month];
	const previous = previousMonth(month);
	const previousRecord = previous ? state.months[previous] : null;
	const accounts = trackedAccounts();

	$("monthly-empty").hidden = accounts.length > 0;

	const groups = $("monthly-groups");
	groups.replaceChildren();
	for (const [section, title] of [
		["asset", "Assets"],
		["liability", "Liabilities"],
	]) {
		const rows = accounts.filter((account) => account.section === section);
		if (rows.length === 0) continue;
		const list = el("div", { className: "entry-list" });
		for (const account of rows) {
			const saved = record?.values?.[account.accountId];
			const last = previousRecord?.values?.[account.accountId];
			const input = el("input", {
				type: "number",
				step: "any",
				inputMode: "decimal",
				className: "value-input",
				value: saved ?? "",
				placeholder: last !== undefined ? String(last) : "",
			});
			input.dataset.accountId = account.accountId;
			input.setAttribute("aria-label", `${account.name} (${account.currency})`);

			const copy = el("button", { type: "button", className: "link", textContent: "same as last" });
			copy.hidden = last === undefined;
			copy.addEventListener("click", () => {
				input.value = String(last);
				updateMonthlySummary();
			});

			const remove = el("button", { type: "button", className: "link muted", textContent: "untrack" });
			remove.addEventListener("click", async () => {
				state.settings.accounts = state.settings.accounts.filter((tracked) => tracked.accountId !== account.accountId);
				await saveSettings();
				renderMonthly();
			});

			list.append(
				el("div", { className: "entry" }, [
					el("div", { className: "entry-name" }, [
						el("strong", { textContent: account.name }),
						el("span", {
							className: "muted small",
							textContent:
								last !== undefined
									? ` ${account.currency} · last ${formatAmount(last)} (${previous})`
									: ` ${account.currency}`,
						}),
					]),
					input,
					el("div", { className: "entry-actions" }, [copy, remove]),
				]),
			);
		}
		groups.append(el("h2", { textContent: title }), list);
	}

	$("month-note").value = record?.note || "";

	const select = $("add-account");
	select.replaceChildren(el("option", { value: "", textContent: "Choose an account…" }));
	const tracked = new Set(state.settings.accounts.map((item) => item.accountId));
	for (const account of state.sureAccounts.filter((item) => !tracked.has(item.id))) {
		select.append(
			el("option", { value: account.id, textContent: `${account.name} (${account.currency})` }),
		);
	}

	updateMonthlySummary();
}

function readMonthlyForm() {
	const values = {};
	for (const input of document.querySelectorAll(".value-input")) {
		if (input.value !== "") values[input.dataset.accountId] = Number(input.value);
	}
	return { values, note: $("month-note").value.trim() };
}

function updateMonthlySummary() {
	const month = currentMonth();
	const form = readMonthlyForm();
	const accounts = trackedAccounts();
	const previous = previousMonth(month);
	const previousRecord = previous ? state.months[previous] : null;

	// Rows left blank keep their last value, so each currency is comparable.
	const now = sumsByCurrency(accounts, (account) => form.values[account.accountId] ?? previousRecord?.values?.[account.accountId]);
	const before = previousRecord ? sumsByCurrency(accounts, (account) => previousRecord.values?.[account.accountId]) : null;
	const filled = Object.keys(form.values).length;

	const parts = Object.keys(now)
		.sort()
		.map((currency) => {
			const change = before?.[currency] !== undefined ? now[currency] - before[currency] : null;
			return el("div", {}, [
				el("span", { className: "muted", textContent: `Net ${currency} ` }),
				formatAmount(now[currency]),
				change === null || change === 0
					? null
					: el("span", { className: change < 0 ? "negative small" : "positive small", textContent: ` ${change > 0 ? "+" : ""}${formatAmount(change)}` }),
			]);
		});
	parts.push(
		el("div", {
			className: "muted small",
			textContent: `${filled} of ${accounts.length} accounts filled in; blank rows keep their last value. Sure converts to ${state.sure.family?.currency || "your currency"} with its own exchange rates.`,
		}),
	);
	$("monthly-summary").replaceChildren(...parts);
}

async function saveMonthToSure(event) {
	event.preventDefault();
	// Balances entered in the form are dated the day they are entered.
	const month = currentMonth();
	const date = today();
	const form = readMonthlyForm();
	const entries = Object.entries(form.values);
	if (entries.length === 0) {
		$("save-status").textContent = "Fill in at least one account.";
		return;
	}

	const button = $("save-month");
	button.disabled = true;
	const failures = [];
	const savedIds = new Set();
	let done = 0;

	for (const [accountId, amount] of entries) {
		$("save-status").textContent = `Saving ${done + 1} of ${entries.length}…`;
		try {
			const result = await state.sure.call("record_valuation", {
				account_id: accountId,
				date,
				amount,
				source: entrySource(date),
			});
			if (result?.success === false) throw new Error(result.message);
			savedIds.add(accountId);
			done++;
		} catch (error) {
			failures.push(`${sureAccount(accountId)?.name || accountId}: ${describeError(error)}`);
			if (error?.code === window.SureMiniApp.ErrorCodes.DECLINED) break;
		}
	}

	const existing = state.months[month] || { values: {} };
	const saved = Object.fromEntries(entries.filter(([accountId]) => savedIds.has(accountId)));
	state.months[month] = {
		values: { ...existing.values, ...saved },
		note: form.note,
		enteredOn: date,
	};
	await saveMonth(month);

	button.disabled = false;
	$("save-status").textContent = failures.length
		? `Saved ${done} of ${entries.length}. ${failures.join(" · ")}`
		: `Saved ${done} balances to Sure as of ${date}.`;
	$("save-status").classList.toggle("error", failures.length > 0);
	await loadSureAccounts();
	updateMonthlySummary();
}

async function addTrackedAccount() {
	const id = $("add-account").value;
	if (!id) return;
	state.settings.accounts.push({ accountId: id, section: $("add-section").value });
	await saveSettings();
	renderMonthly();
}

function suggestSection() {
	const account = sureAccount($("add-account").value);
	if (account) $("add-section").value = account.classification === "liability" ? "liability" : "asset";
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

async function onFileChosen() {
	const file = $("csv-file").files[0];
	if (file) await readCsv(await file.text());
}

async function readCsv(text) {
	$("import-log").replaceChildren();
	try {
		state.parsed = window.LegacyCsv.parseLegacy(text);
	} catch (error) {
		$("preview").hidden = true;
		setStatus(`Could not read the file: ${error.message}`, true);
		return;
	}
	await loadSureAccounts();
	renderPreview();
}

function renderPreview() {
	const parsed = state.parsed;
	const valueCount = parsed.accounts.reduce((sum, account) => sum + Object.keys(account.values).length, 0);
	const first = parsed.months[0];
	const last = parsed.months[parsed.months.length - 1];

	// Check our reading of the file against its own TOTAL rows.
	let checked = 0;
	let matched = 0;
	for (const month of parsed.months) {
		if (parsed.totals.asset[month] === undefined) continue;
		const totals = window.LegacyCsv.monthTotals(
			parsed.accounts,
			(account) => account.values[month],
			parsed.fx[month],
			parsed.reportingCurrency,
		);
		checked++;
		const assetOk = Math.abs(totals.asset - parsed.totals.asset[month]) <= 2;
		const liabilityOk =
			parsed.totals.liability[month] === undefined || Math.abs(totals.liability - parsed.totals.liability[month]) <= 2;
		if (assetOk && liabilityOk) matched++;
	}

	$("preview-summary").replaceChildren(
		el("div", {}, `${parsed.accounts.length} accounts · ${parsed.months.length} months (${first} to ${last}) · ${valueCount} values`),
		el("div", { className: "muted" }, "Checked with the file's own rates; Sure converts with the rates it fetches."),
		el("div", { className: matched === checked ? "positive" : "error" }, `Totals check: ${matched} of ${checked} months match the file's TOTAL rows`),
	);

	const tbody = $("mapping").querySelector("tbody");
	tbody.replaceChildren();
	for (const row of parsed.accounts) {
		tbody.append(mappingRow(row));
	}

	updateWriteCount();
	$("preview").hidden = false;
	setStatus("Check the accounts, then import.");
}

function mappingRow(row) {
	const values = Object.entries(row.values);
	const latest = values.length ? values[values.length - 1] : null;

	const target = el("select", { className: "target" });
	target.append(el("option", { value: "new", textContent: "Create new account" }));
	target.append(el("option", { value: "skip", textContent: "Skip" }));
	const matches = state.sureAccounts.filter((account) => account.currency === row.currency);
	const others = state.sureAccounts.filter((account) => account.currency !== row.currency);
	for (const account of [...matches, ...others]) {
		target.append(el("option", { value: account.id, textContent: `${account.name} (${account.currency})` }));
	}

	// An earlier import of the same row, or an account with the same name.
	const previousId = state.settings.importedRows?.[row.key];
	const sameName = matches.find((account) => account.name.toLowerCase() === row.suggestedName.toLowerCase());
	if (previousId && sureAccount(previousId)) target.value = previousId;
	else if (sameName) target.value = sameName.id;
	if (values.length === 0) target.value = "skip";

	const name = el("input", { type: "text", className: "name", value: row.suggestedName, maxLength: 60 });
	const type = el("select", { className: "type" });
	for (const option of ACCOUNT_TYPES) {
		if (LIABILITY_TYPES.has(option) !== (row.section === "liability")) continue;
		type.append(el("option", { value: option, textContent: option.replace(/([a-z])([A-Z])/g, "$1 $2") }));
	}
	type.value = row.type;

	const sync = () => {
		const isNew = target.value === "new";
		name.disabled = !isNew;
		type.disabled = !isNew;
		updateWriteCount();
	};
	target.addEventListener("change", sync);
	sync();

	const tr = el("tr", {}, [
		el("td", {}, [
			el("strong", { textContent: row.name }),
			el("div", { className: "muted small", textContent: `${row.currency} · ${row.section}` }),
		]),
		el("td", { className: "num", textContent: String(values.length) }),
		el("td", { className: "num", textContent: latest ? `${formatAmount(latest[1])} (${latest[0]})` : "—" }),
		el("td", {}, target),
		el("td", {}, name),
		el("td", {}, type),
	]);
	tr.dataset.key = row.key;
	return tr;
}

function plannedRows() {
	return [...$("mapping").querySelectorAll("tbody tr")]
		.map((tr) => {
			const row = state.parsed.accounts.find((account) => account.key === tr.dataset.key);
			return {
				row,
				target: tr.querySelector(".target").value,
				name: tr.querySelector(".name").value.trim() || row.suggestedName,
				type: tr.querySelector(".type").value,
			};
		})
		.filter((plan) => plan.target !== "skip");
}

function updateWriteCount() {
	const plans = plannedRows();
	const writes = plans.reduce(
		(sum, plan) =>
			sum + (plan.target === "new" ? 1 : 0) + Math.ceil(Object.keys(plan.row.values).length / BATCH_SIZE),
		0,
	);
	$("write-count").textContent = String(writes);
	$("policy-notice").hidden = state.sure.writePolicy !== "confirm";
}

function log(text, kind = "") {
	$("import-log").append(el("li", { className: kind, textContent: text }));
}

async function runImport() {
	const parsed = state.parsed;
	const plans = plannedRows();
	if (plans.length === 0) return;

	state.importing = true;
	state.stopRequested = false;
	$("import-button").disabled = true;
	$("cancel-import").hidden = false;
	const progress = $("import-progress");
	progress.hidden = false;
	progress.max = plans.length;
	progress.value = 0;
	$("import-log").replaceChildren();

	const imported = []; // { plan, accountId }
	for (const plan of plans) {
		if (state.stopRequested) {
			log("Stopped. Run the import again to continue: imported rows are reused.", "error");
			break;
		}
		const row = plan.row;
		const values = Object.entries(row.values);
		try {
			let accountId = plan.target;
			let toRecord = values;
			let recorded = 0;
			if (plan.target === "new") {
				// The account opens on its first value's date with that value, so
				// it adds nothing to earlier months; later values are valuations.
				const [firstMonth, firstValue] = values[0] || [parsed.months[0], 0];
				const created = await state.sure.call("create_account", {
					name: plan.name,
					accountable_type: plan.type,
					currency: row.currency,
					balance: firstValue,
					opening_balance_date: importDate(firstMonth),
				});
				if (!created?.success) throw new Error(created?.message || "Could not create the account.");
				accountId = created.account.id;
				log(`Created ${plan.name} (${row.currency}), opening ${importDate(firstMonth)}.`);
				toRecord = values.slice(1);
				recorded = values.length ? 1 : 0;
			}

			state.settings.importedRows = { ...state.settings.importedRows, [row.key]: accountId };
			if (!state.settings.accounts.some((tracked) => tracked.accountId === accountId)) {
				state.settings.accounts.push({ accountId, section: row.section });
			}
			await saveSettings();

			for (let start = 0; start < toRecord.length; start += BATCH_SIZE) {
				const batch = toRecord.slice(start, start + BATCH_SIZE).map(([month, amount]) => ({
					date: importDate(month),
					amount,
				}));
				const result = await state.sure.call("record_valuations", {
					account_id: accountId,
					source: IMPORT_SOURCE,
					valuations: batch,
				});
				recorded += result?.recorded_count || 0;
				if (result?.error) throw new Error(result.message);
				for (const failure of result?.failed || []) {
					log(`${plan.name} ${failure.date}: ${failure.message}`, "error");
				}
			}
			log(`${plan.name}: recorded ${recorded} of ${values.length} months.`, "positive");
			imported.push({ plan, accountId });
		} catch (error) {
			log(`${plan.name}: ${describeError(error)}`, "error");
			if (error?.code === window.SureMiniApp.ErrorCodes.DECLINED) {
				log("Import stopped because a change was declined.", "error");
				break;
			}
		}
		progress.value += 1;
	}

	// Keep each month's values and note, for the monthly form.
	await saveSettings();
	for (const month of parsed.months) {
		const record = state.months[month] || { values: {} };
		delete record.fx;
		if (parsed.notes[month]) record.note = parsed.notes[month];
		for (const { plan, accountId } of imported) {
			const value = plan.row.values[month];
			if (value !== undefined) record.values = { ...record.values, [accountId]: value };
		}
		state.months[month] = record;
	}
	await Promise.all(parsed.months.map((month) => saveMonth(month)));

	state.importing = false;
	$("import-button").disabled = false;
	$("cancel-import").hidden = true;
	await loadSureAccounts();
	log(`Done: ${imported.length} of ${plans.length} accounts imported. Sure is updating balances in the background.`, "positive");
	setStatus("Import finished. Use Monthly entry for new months.");
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

async function renderHistory() {
	const tbody = $("history").querySelector("tbody");
	$("history-caption").textContent = "Loading Sure's balance sheet…";
	let history;
	try {
		history = await loadSureHistory();
	} catch (error) {
		$("history-caption").textContent = describeError(error);
		return;
	}

	// Newest first; the series includes the month in progress.
	const rows = history.rows.slice().reverse();
	tbody.replaceChildren();
	$("history-empty").hidden = rows.length > 0;
	$("history-caption").textContent =
		`Sure's balance sheet for all your accounts, in ${history.currency} at Sure's exchange rate for each date. ` +
		`Net worth today: ${history.current}.`;

	rows.forEach((row, index) => {
		const older = rows[index + 1];
		const change = older ? row.net - older.net : null;
		const percent = older?.net ? (change / Math.abs(older.net)) * 100 : null;
		tbody.append(
			el("tr", {}, [
				el("td", { textContent: row.month }),
				el("td", { className: "num", textContent: formatAmount(row.asset) }),
				el("td", { className: "num", textContent: formatAmount(row.liability) }),
				el("td", { className: "num strong", textContent: formatAmount(row.net) }),
				el("td", {
					className: `num ${change < 0 ? "negative" : "positive"}`,
					textContent: percent === null ? "" : `${percent.toFixed(0)}%`,
				}),
				el("td", { className: "muted small", textContent: state.months[row.key]?.note || "" }),
			]),
		);
	});
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function main() {
	try {
		state.sure = await window.SureMiniApp.connect();
	} catch (error) {
		setStatus(describeError(error), true);
		return;
	}

	const missing = ["accounts:read", "accounts:write", "valuations:write", "reports:read"].filter(
		(permission) => !state.sure.can(permission),
	);
	try {
		await loadAll();
	} catch (error) {
		setStatus(describeError(error), true);
		return;
	}
	setStatus(
		missing.length
			? `Missing permissions: ${missing.join(", ")}. A family admin can grant them on Sure's Apps page.`
			: `Connected as ${state.sure.user.name}.`,
		missing.length > 0,
	);

	for (const tab of document.querySelectorAll("[role=tab]")) {
		tab.addEventListener("click", () => showTab(tab.dataset.tab));
	}
	$("entry-date").textContent = today();
	$("monthly-form").addEventListener("input", updateMonthlySummary);
	$("monthly-form").addEventListener("submit", saveMonthToSure);
	$("add-account").addEventListener("change", suggestSection);
	$("add-account-button").addEventListener("click", addTrackedAccount);
	$("csv-file").addEventListener("change", onFileChosen);
	$("csv-text-button").addEventListener("click", () => {
		if ($("csv-text").value.trim()) readCsv($("csv-text").value);
	});
	$("import-button").addEventListener("click", runImport);
	$("cancel-import").addEventListener("click", () => {
		state.stopRequested = true;
	});
	state.sure.on("dataChanged", () => {
		if (!state.importing) loadSureAccounts();
	});

	showTab(state.settings.accounts.length ? "monthly" : "import");
}

main();
