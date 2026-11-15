// Parses a month-by-account net worth spreadsheet exported as CSV.
//
// Layout it expects (blank cells are allowed anywhere):
//
//   ,,,2022,Jan 2023,Mar 2023,...      header: name, currency, -, one column per month
//   ,USD,,82.58,82.20,...              exchange rates: blank name, currency, rate per month
//   SC-cash,INR,,"1,200,175",...       asset rows
//   TOTAL,...                          closes the assets
//   Loan,INR,,"2,000,000",...          liability rows
//   TOTAL,...                          closes the liabilities
//   comment,,,,,"Market tanked",...    optional notes per month
//
// A column whose header is not a month (such as "GAP") is ignored, and a
// header of just a year means December of that year. Everything after the
// second TOTAL except the comment row is derived data and is ignored.
(function (global) {
	const MONTHS = [
		"jan",
		"feb",
		"mar",
		"apr",
		"may",
		"jun",
		"jul",
		"aug",
		"sep",
		"oct",
		"nov",
		"dec",
	];

	function parseCsv(text) {
		const rows = [];
		let row = [];
		let cell = "";
		let quoted = false;
		const source = text.replace(/^﻿/, "");

		for (let i = 0; i < source.length; i++) {
			const char = source[i];
			if (quoted) {
				if (char === '"' && source[i + 1] === '"') {
					cell += '"';
					i++;
				} else if (char === '"') {
					quoted = false;
				} else {
					cell += char;
				}
			} else if (char === '"') {
				quoted = true;
			} else if (char === ",") {
				row.push(cell);
				cell = "";
			} else if (char === "\n" || char === "\r") {
				if (char === "\r" && source[i + 1] === "\n") i++;
				row.push(cell);
				rows.push(row);
				row = [];
				cell = "";
			} else {
				cell += char;
			}
		}
		if (cell !== "" || row.length) {
			row.push(cell);
			rows.push(row);
		}
		return rows;
	}

	// "Jan 2023", "April 2023", "Sept 2026", "2022" -> "2023-01", ...; else null.
	function parseMonthHeader(header) {
		const text = header.trim().toLowerCase();
		const yearOnly = text.match(/^(\d{4})$/);
		if (yearOnly) return `${yearOnly[1]}-12`;

		const named = text.match(/^([a-z]+)\.?\s+(\d{4})$/);
		if (!named) return null;
		const index = MONTHS.indexOf(named[1].slice(0, 3));
		if (index < 0) return null;
		return `${named[2]}-${String(index + 1).padStart(2, "0")}`;
	}

	// "1,200,175" -> 1200175, "" -> null, "27%" -> null.
	function parseAmount(value) {
		const text = (value || "").replace(/[,\s]/g, "");
		if (text === "") return null;
		if (!/^-?\d+(\.\d+)?$/.test(text)) return null;
		return Number(text);
	}

	function isCurrency(value) {
		return /^[A-Z]{3}$/.test((value || "").trim());
	}

	function lastDayOfMonth(month) {
		const [year, monthNumber] = month.split("-").map(Number);
		const day = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
		return `${month}-${String(day).padStart(2, "0")}`;
	}

	// A guess at the Sure account type, from the row's name and section.
	function guessType(name, section) {
		const text = name.toLowerCase();
		if (section === "liability") {
			if (/card/.test(text)) return "CreditCard";
			if (/loan|mortgage/.test(text)) return "Loan";
			return "OtherLiability";
		}
		if (/cash|bank|saving/.test(text)) return "Depository";
		if (/\b(re|home|house|flat|property)\b/.test(text)) return "Property";
		if (/crypto|btc|eth/.test(text)) return "Crypto";
		if (/gold|misc|loan|splitwise/.test(text)) return "OtherAsset";
		return "Investment";
	}

	function parseLegacy(text) {
		const rows = parseCsv(text);
		if (rows.length < 2) throw new Error("The file has no rows.");

		const header = rows[0];
		const columns = [];
		for (let index = 3; index < header.length; index++) {
			const month = parseMonthHeader(header[index] || "");
			if (month) columns.push({ index, month, label: header[index].trim() });
		}
		if (columns.length === 0) {
			throw new Error(
				"No month columns found. The first row should hold months such as 'Jan 2023' from the fourth column on.",
			);
		}

		const fx = {}; // { "2023-01": { USD: 82.2, SGD: 62.33 } }
		const notes = {};
		const accounts = [];
		const totals = { asset: {}, liability: {} };
		let section = "asset";
		let done = false;

		const valuesOf = (row) => {
			const values = {};
			for (const column of columns) {
				const amount = parseAmount(row[column.index]);
				if (amount !== null) values[column.month] = amount;
			}
			return values;
		};

		for (const row of rows.slice(1)) {
			const name = (row[0] || "").trim();
			const currency = (row[1] || "").trim();

			if (name.toLowerCase() === "comment") {
				for (const column of columns) {
					const note = (row[column.index] || "").replace(/\s+/g, " ").trim();
					if (note) notes[column.month] = note;
				}
				continue;
			}
			if (done) continue;

			if (name.toUpperCase() === "TOTAL") {
				totals[section] = valuesOf(row);
				if (section === "asset") section = "liability";
				else done = true;
				continue;
			}

			if (!name) {
				if (isCurrency(currency) && section === "asset" && accounts.length === 0) {
					for (const [month, rate] of Object.entries(valuesOf(row))) {
						fx[month] = fx[month] || {};
						fx[month][currency] = rate;
					}
				}
				continue;
			}

			accounts.push({
				key: `${section}:${name}:${currency}`,
				name,
				currency: isCurrency(currency) ? currency : null,
				section,
				type: guessType(name, section),
				values: valuesOf(row),
			});
		}

		if (accounts.length === 0) throw new Error("No account rows found.");

		// The reporting currency is the one the rates are quoted in: the account
		// currency that has no rate row of its own.
		const rated = new Set(Object.values(fx).flatMap((rates) => Object.keys(rates)));
		const reportingCurrency =
			accounts.map((account) => account.currency).find((code) => code && !rated.has(code)) || null;

		// Two rows with the same name (one per currency, or an asset and a
		// liability) need different Sure account names.
		const nameCounts = {};
		for (const account of accounts) nameCounts[account.name] = (nameCounts[account.name] || 0) + 1;
		for (const account of accounts) {
			account.suggestedName = account.name;
			if (nameCounts[account.name] > 1) {
				const sameSection = accounts.filter(
					(other) => other.name === account.name && other.section === account.section,
				);
				account.suggestedName =
					sameSection.length > 1
						? `${account.name} (${account.currency})`
						: account.section === "liability"
							? `${account.name} (owed)`
							: account.name;
			}
		}

		return {
			months: columns.map((column) => column.month),
			fx,
			notes,
			accounts,
			totals,
			reportingCurrency,
		};
	}

	// Value of every account in the reporting currency for one month. Rows
	// without a value that month count as zero, as in the spreadsheet.
	function monthTotals(accounts, valuesFor, rates, reportingCurrency) {
		const sums = { asset: 0, liability: 0, missingRates: [] };
		for (const account of accounts) {
			const amount = valuesFor(account);
			if (amount === null || amount === undefined) continue;
			let rate = 1;
			if (account.currency && account.currency !== reportingCurrency) {
				rate = rates?.[account.currency];
				if (!rate) {
					if (!sums.missingRates.includes(account.currency)) sums.missingRates.push(account.currency);
					continue;
				}
			}
			sums[account.section] += amount * rate;
		}
		sums.net = sums.asset - sums.liability;
		return sums;
	}

	global.LegacyCsv = { parseCsv, parseLegacy, parseMonthHeader, parseAmount, lastDayOfMonth, monthTotals, guessType };
	if (typeof module !== "undefined") module.exports = global.LegacyCsv;
})(typeof window !== "undefined" ? window : globalThis);
