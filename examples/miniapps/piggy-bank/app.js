// Piggy Bank: a savings jar for a young child, used together with a grown-up.
//
// The child's coins, goal, history and settings live only in this app's
// storage (sure.storage). Sure is touched in two places, both behind the
// grown-up gate: get_accounts (accounts:read) to pick the account that holds
// the real money, and create_transaction (transactions:write) to record the
// coins saved since the last time as a real transaction there.

const STORE = { collection: "piggy", key: "bank" };
const COINS = [1, 2, 5, 10];
const MAX_DROPS = 200;
const MAX_COINS_SHOWN = 24;
const HOLD_MS = 2000;
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;
const BONUS_CHOICES = [0, 5, 10, 25];
const PRICE_MIN = 1;
const PRICE_MAX = 500;

const GOAL_IDEAS = [
	["🚲", "Bike"],
	["🧸", "Teddy"],
	["🎮", "Game"],
	["📚", "Book"],
	["⚽", "Ball"],
	["🦄", "Unicorn"],
	["🍦", "Ice cream"],
	["🎨", "Paints"],
	["🚂", "Train"],
	["🪁", "Kite"],
	["🦖", "Dino"],
	["🎁", "Surprise"],
];

const PERMISSION_NAMES = {
	"accounts:read": "See accounts (accounts:read)",
	"transactions:write": "Add transactions (transactions:write)",
};

function defaultBank() {
	return {
		version: 1,
		balance: 0,
		goal: null,
		drops: [],
		settings: { bonusPercent: 10, accountId: null, sound: true },
		lastBonusAt: null,
		// Net coins added (or spent) since the last real record in Sure.
		unrecorded: 0,
		// A record that was sent to Sure but not confirmed; retried with the same
		// external_id so Sure never writes it twice.
		pendingRecord: null,
		lastRecord: null,
	};
}

const state = {
	sure: null,
	bank: defaultBank(),
	storageReady: false,
	saveChain: Promise.resolve(),
	accounts: [],
	accountsLoaded: false,
	writeDenied: false,
	readDenied: false,
	recording: false,
	goalDraft: null,
	spend: { amount: 0, kind: null },
	gateAnswer: null,
	pendingBonus: null,
	audio: null,
	toastTimer: null,
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function newId() {
	const random = Math.random().toString(36).slice(2, 8);
	return `${Date.now().toString(36)}-${random}`;
}

function todayIso() {
	const now = new Date();
	const pad = (n) => String(n).padStart(2, "0");
	return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

function selectedAccount() {
	const id = state.bank.settings.accountId;
	return state.accounts.find((account) => account.id === id) || null;
}

function currency() {
	return selectedAccount()?.currency || state.sure?.family?.currency || "USD";
}

function locale() {
	return state.sure?.family?.locale || undefined;
}

function money(amount) {
	try {
		return new Intl.NumberFormat(locale(), {
			style: "currency",
			currency: currency(),
			minimumFractionDigits: 0,
			maximumFractionDigits: 2,
		}).format(amount);
	} catch (_error) {
		return String(amount);
	}
}

function signedMoney(amount) {
	return `${amount < 0 ? "−" : "+"}${money(Math.abs(amount))}`;
}

function coinWord(n) {
	return n === 1 ? "1 coin" : `${n} coins`;
}

function shortDate(iso) {
	const date = new Date(iso);
	const days = Math.floor((startOfDay(new Date()) - startOfDay(date)) / DAY_MS);
	if (days === 0) return "Today";
	if (days === 1) return "Yesterday";
	try {
		return date.toLocaleDateString(locale(), {
			weekday: "short",
			day: "numeric",
			month: "short",
		});
	} catch (_error) {
		return iso.slice(0, 10);
	}
}

function startOfDay(date) {
	return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

// Splits an amount into 10, 5, 2 and 1 coins, biggest first.
function coinBreakdown(amount) {
	const coins = [];
	let left = Math.max(0, Math.floor(amount));
	for (const value of [...COINS].reverse()) {
		while (left >= value) {
			coins.push(value);
			left -= value;
		}
	}
	return coins;
}

function coinElement(value, tag = "span") {
	const coin = document.createElement(tag);
	coin.className = `coin coin-${value}`;
	coin.textContent = String(value);
	return coin;
}

function renderCoinRow(container, amount) {
	container.replaceChildren();
	const coins = coinBreakdown(amount);
	for (const value of coins.slice(0, MAX_COINS_SHOWN)) {
		container.append(coinElement(value));
	}
	if (coins.length > MAX_COINS_SHOWN) {
		const more = document.createElement("span");
		more.className = "coin-more";
		more.textContent = `+${coins.length - MAX_COINS_SHOWN} more`;
		container.append(more);
	}
}

function toast(text, kind) {
	const el = $("toast");
	el.textContent = text;
	el.className = `toast ${kind || ""}`;
	el.hidden = false;
	clearTimeout(state.toastTimer);
	state.toastTimer = setTimeout(() => {
		el.hidden = true;
	}, 4500);
}

// Friendly words for bridge errors. Kid-facing copy stays short; the grown-up
// screens get the detail.
function describeError(error) {
	const codes = window.SureMiniApp.ErrorCodes;
	switch (error?.code) {
		case codes.PERMISSION_DENIED:
			return `This app is not allowed to do that yet. Ask a Sure admin to turn on “${
				PERMISSION_NAMES[error.data?.permission] || error.data?.permission
			}”.`;
		case codes.DECLINED:
			return "No problem, nothing was changed in Sure.";
		case codes.APP_DISABLED:
			return "A Sure admin has switched this app off.";
		case codes.RATE_LIMITED:
			return "Too fast! Wait a minute and try again.";
		case codes.NOT_EMBEDDED:
			return "Open Piggy Bank from the Apps page in Sure.";
		case codes.TIMEOUT:
			return "Sure is not answering. Try again in a moment.";
		default:
			return "Oops, something went wrong. Try again.";
	}
}

// ---------------------------------------------------------------------------
// Sound: a tiny "clink" made in the browser, no audio files
// ---------------------------------------------------------------------------

function clink(notes) {
	if (!state.bank.settings.sound) return;
	try {
		if (!state.audio) {
			const AudioCtx = window.AudioContext || window.webkitAudioContext;
			if (!AudioCtx) return;
			state.audio = new AudioCtx();
		}
		const ctx = state.audio;
		let at = ctx.currentTime;
		for (const freq of notes) {
			const osc = ctx.createOscillator();
			const gain = ctx.createGain();
			osc.type = "triangle";
			osc.frequency.value = freq;
			gain.gain.setValueAtTime(0.0001, at);
			gain.gain.exponentialRampToValueAtTime(0.25, at + 0.01);
			gain.gain.exponentialRampToValueAtTime(0.0001, at + 0.25);
			osc.connect(gain).connect(ctx.destination);
			osc.start(at);
			osc.stop(at + 0.3);
			at += 0.09;
		}
	} catch (_error) {
		// Sound is a nicety; ignore browsers that refuse it.
	}
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

async function loadBank() {
	const saved = await state.sure.storage.get(STORE.collection, STORE.key);
	const base = defaultBank();
	if (saved && typeof saved === "object") {
		state.bank = {
			...base,
			...saved,
			settings: { ...base.settings, ...(saved.settings || {}) },
			drops: Array.isArray(saved.drops) ? saved.drops : [],
		};
	}
	state.storageReady = true;
}

// Saves are chained so two quick taps never write out of order.
function saveBank() {
	if (!state.storageReady) {
		toast(
			"The piggy bank could not open its storage, so this was not saved.",
			"error",
		);
		return Promise.resolve(false);
	}
	const snapshot = JSON.parse(JSON.stringify(state.bank));
	state.saveChain = state.saveChain
		.then(() => state.sure.storage.set(STORE.collection, STORE.key, snapshot))
		.then(
			() => true,
			(error) => {
				toast(`Not saved. ${describeError(error)}`, "error");
				return false;
			},
		);
	return state.saveChain;
}

function addDrop(drop) {
	state.bank.drops.unshift({
		id: newId(),
		at: new Date().toISOString(),
		...drop,
	});
	if (state.bank.drops.length > MAX_DROPS) {
		state.bank.drops.length = MAX_DROPS;
	}
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

const SCREENS = [
	"loading",
	"home",
	"goal",
	"spend",
	"celebrate",
	"bonus",
	"gate",
	"parent",
];

function show(name) {
	for (const screen of SCREENS) {
		$(`screen-${screen}`).hidden = screen !== name;
	}
	// The frame grows to fit its content, so the page itself never scrolls.
	// Ask the browser to bring the top of the new screen into view instead.
	try {
		$("app").scrollIntoView({ block: "start", behavior: "smooth" });
	} catch (_error) {
		// Older browsers: ignore.
	}
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

function bonusInfo() {
	const percent = Number(state.bank.settings.bonusPercent) || 0;
	const last = state.bank.lastBonusAt
		? new Date(state.bank.lastBonusAt).getTime()
		: 0;
	const elapsed = Date.now() - last;
	const ready = !last || elapsed >= WEEK_MS;
	const sleeps = ready
		? 0
		: Math.max(1, Math.ceil((WEEK_MS - elapsed) / DAY_MS));
	const amount =
		percent > 0 && state.bank.balance > 0
			? Math.max(1, Math.round((state.bank.balance * percent) / 100))
			: 0;
	return { percent, ready, sleeps, amount };
}

// Average coins added per week over the last four weeks, for "about N weeks".
function weeklySavingRate() {
	const since = Date.now() - 4 * WEEK_MS;
	let added = 0;
	let oldest = Date.now();
	for (const drop of state.bank.drops) {
		const at = new Date(drop.at).getTime();
		if (at < since) break;
		if (drop.amount > 0) added += drop.amount;
		oldest = Math.min(oldest, at);
	}
	const weeks = Math.max(1, (Date.now() - oldest) / WEEK_MS);
	return added / weeks;
}

function renderHome() {
	const { bank } = state;
	const goal = bank.goal;

	$("total-figure").textContent = money(bank.balance);
	renderCoinRow($("total-coins"), bank.balance);

	const fill = goal
		? Math.min(1, bank.balance / goal.price)
		: Math.min(1, bank.balance / 50);
	$("pig-fill").style.transform = `scaleY(${fill})`;
	$("pig-mouth").setAttribute(
		"d",
		bank.balance > 0 ? "M78 146 q12 10 24 0" : "M78 150 h24",
	);

	if (goal) {
		const left = Math.max(0, goal.price - bank.balance);
		$("goal-emoji").textContent = goal.emoji;
		$("goal-title").textContent = `${goal.name} · ${money(goal.price)}`;
		$("goal-progress").style.width =
			`${Math.round(Math.min(1, bank.balance / goal.price) * 100)}%`;
		if (left === 0) {
			$("goal-left").textContent = "You have enough! 🎉";
		} else {
			const rate = weeklySavingRate();
			const weeks = rate > 0 ? Math.ceil(left / rate) : null;
			$("goal-left").textContent = weeks
				? `${coinWord(left)} to go · about ${weeks === 1 ? "1 week" : `${weeks} weeks`}`
				: `${coinWord(left)} to go`;
		}
	} else {
		$("goal-emoji").textContent = "⭐";
		$("goal-title").textContent = "Pick a goal!";
		$("goal-progress").style.width = "0%";
		$("goal-left").textContent = "What do you want to save for?";
	}

	const bonus = bonusInfo();
	const banner = $("bonus-banner");
	banner.hidden = bonus.percent === 0;
	if (bonus.ready) {
		banner.textContent = "🎁 Bonus day! Ask a grown-up.";
	} else {
		banner.textContent = `🌱 Bonus in ${bonus.sleeps} ${bonus.sleeps === 1 ? "sleep" : "sleeps"}`;
	}

	$("spend-button").disabled = bank.balance <= 0;
	renderHistory();
}

const DROP_ICONS = {
	add: "🪙",
	bonus: "🌱",
	goal: "⭐",
	need: "🍎",
	want: "🎈",
};

function renderHistory() {
	const list = $("history");
	list.replaceChildren();
	const drops = state.bank.drops.slice(0, 30);
	$("history-empty").hidden = drops.length > 0;

	for (const drop of drops) {
		const item = document.createElement("li");
		item.className = drop.amount < 0 ? "out" : "in";

		const icon = document.createElement("span");
		icon.className = "history-icon";
		icon.setAttribute("aria-hidden", "true");
		icon.textContent =
			drop.kind === "spend"
				? DROP_ICONS[drop.need] || "🛍️"
				: DROP_ICONS[drop.kind] || "🪙";

		const label = document.createElement("span");
		label.className = "history-label";
		label.textContent = drop.label || "Coin";

		const when = document.createElement("span");
		when.className = "history-when";
		when.textContent = shortDate(drop.at);

		const amount = document.createElement("span");
		amount.className = "history-amount";
		amount.textContent = signedMoney(drop.amount);

		item.append(icon, label, when, amount);
		list.append(item);
	}
}

function renderAddCoins() {
	const container = $("add-coins");
	container.replaceChildren();
	for (const value of COINS) {
		const button = coinElement(value, "button");
		button.type = "button";
		button.setAttribute("aria-label", `Add ${coinWord(value)}`);
		button.addEventListener("click", () => addCoin(value));
		container.append(button);
	}
}

async function addCoin(value) {
	const { bank } = state;
	bank.balance += value;
	bank.unrecorded += value;
	addDrop({ kind: "add", amount: value, label: "Coin in" });
	dropAnimation(value);
	clink([880, 1320]);
	renderHome();
	await saveBank();
	maybeCelebrate();
}

function dropAnimation(value) {
	const stage = $("coin-drop");
	const coin = coinElement(value);
	coin.classList.add("falling");
	coin.addEventListener("animationend", () => coin.remove());
	stage.append(coin);

	const pig = $("pig");
	pig.classList.remove("wiggle");
	// Restart the animation on repeated taps.
	void pig.getBoundingClientRect();
	pig.classList.add("wiggle");
}

function maybeCelebrate() {
	const goal = state.bank.goal;
	if (!goal) return;
	const reached = state.bank.balance >= goal.price;
	if (reached && !goal.celebrated) {
		goal.celebrated = true;
		saveBank();
		showCelebration();
	} else if (!reached && goal.celebrated) {
		// Spent below the goal again: celebrate again when it is reached next time.
		goal.celebrated = false;
		saveBank();
	}
}

// ---------------------------------------------------------------------------
// Goal
// ---------------------------------------------------------------------------

function openGoal() {
	const goal = state.bank.goal;
	state.goalDraft = goal
		? { emoji: goal.emoji, name: goal.name, price: goal.price }
		: { emoji: GOAL_IDEAS[0][0], name: GOAL_IDEAS[0][1], price: 20 };
	renderGoalPicker();
	show("goal");
}

function renderGoalPicker() {
	const draft = state.goalDraft;
	const grid = $("goal-emojis");
	grid.replaceChildren();
	for (const [emoji, name] of GOAL_IDEAS) {
		const button = document.createElement("button");
		button.type = "button";
		button.className = "emoji-choice";
		button.textContent = emoji;
		button.setAttribute("role", "radio");
		button.setAttribute("aria-label", name);
		button.setAttribute("aria-checked", String(draft.emoji === emoji));
		button.addEventListener("click", () => {
			const previousIdea = GOAL_IDEAS.find(([e]) => e === draft.emoji);
			// Keep a name the child typed; replace the suggestion otherwise.
			if (!draft.name || (previousIdea && draft.name === previousIdea[1])) {
				draft.name = name;
			}
			draft.emoji = emoji;
			renderGoalPicker();
		});
		grid.append(button);
	}
	$("goal-name").value = draft.name;
	$("goal-price").textContent = money(draft.price);
	renderCoinRow($("goal-price-coins"), draft.price);
}

async function saveGoal() {
	const draft = state.goalDraft;
	const name =
		$("goal-name").value.trim() ||
		GOAL_IDEAS.find(([e]) => e === draft.emoji)?.[1] ||
		"My goal";
	state.bank.goal = {
		emoji: draft.emoji,
		name,
		price: draft.price,
		celebrated: false,
	};
	clink([660, 880, 990]);
	renderHome();
	show("home");
	await saveBank();
	maybeCelebrate();
}

// ---------------------------------------------------------------------------
// Celebration
// ---------------------------------------------------------------------------

function showCelebration() {
	const goal = state.bank.goal;
	$("celebrate-emoji").textContent = goal.emoji;
	$("celebrate-text").textContent =
		`You saved ${money(goal.price)} for your ${goal.name}!`;
	launchConfetti();
	clink([523, 659, 784, 1046]);
	show("celebrate");
}

function launchConfetti() {
	const box = $("confetti");
	box.replaceChildren();
	const bits = ["🪙", "⭐", "🎉", "✨", "🐷", "💖"];
	for (let i = 0; i < 36; i += 1) {
		const bit = document.createElement("span");
		bit.textContent = bits[i % bits.length];
		bit.style.left = `${Math.random() * 100}%`;
		bit.style.animationDelay = `${Math.random() * 1.2}s`;
		bit.style.fontSize = `${18 + Math.random() * 22}px`;
		box.append(bit);
	}
}

async function buyGoal() {
	const goal = state.bank.goal;
	if (!goal || state.bank.balance < goal.price) return;
	state.bank.balance -= goal.price;
	state.bank.unrecorded -= goal.price;
	addDrop({
		kind: "goal",
		amount: -goal.price,
		label: `Got ${goal.emoji} ${goal.name}!`,
	});
	state.bank.goal = null;
	renderHome();
	show("home");
	toast(`Enjoy your ${goal.emoji}! Pick a new goal when you are ready.`);
	await saveBank();
}

// ---------------------------------------------------------------------------
// Spending: amount, need or want, then a gentle check
// ---------------------------------------------------------------------------

function openSpend() {
	state.spend = { amount: 0, kind: null };
	spendStep("amount");
	renderSpend();
	show("spend");
}

function spendStep(step) {
	$("spend-amount-step").hidden = step !== "amount";
	$("spend-kind-step").hidden = step !== "kind";
	$("spend-check-step").hidden = step !== "check";
}

function renderSpend() {
	const { amount } = state.spend;
	$("spend-figure").textContent = money(amount);
	renderCoinRow($("spend-coins"), amount);
	$("spend-next").disabled = amount <= 0;

	const container = $("spend-coin-buttons");
	container.replaceChildren();
	for (const value of COINS) {
		const button = coinElement(value, "button");
		button.type = "button";
		button.disabled = amount + value > state.bank.balance;
		button.setAttribute("aria-label", `Spend ${coinWord(value)}`);
		button.addEventListener("click", () => {
			state.spend.amount += value;
			clink([660]);
			renderSpend();
		});
		container.append(button);
	}
}

function chooseKind(kind) {
	state.spend.kind = kind;
	const { amount } = state.spend;
	const goal = state.bank.goal;
	const after = state.bank.balance - amount;

	if (kind === "need") {
		$("spend-check-emoji").textContent = "👍";
		$("spend-check-title").textContent = "Needs come first";
		$("spend-check-text").textContent =
			`Spend ${money(amount)}? You will still have ${money(after)}.`;
	} else if (goal && after < goal.price) {
		const left = goal.price - after;
		$("spend-check-emoji").textContent = goal.emoji;
		$("spend-check-title").textContent = "Your goal is waiting!";
		$("spend-check-text").textContent =
			`If you spend ${money(amount)}, you need ${coinWord(left)} more for your ${goal.name}. Wait a bit?`;
	} else {
		$("spend-check-emoji").textContent = "🤔";
		$("spend-check-title").textContent = "Are you sure?";
		$("spend-check-text").textContent =
			`Wants can wait. Spend ${money(amount)} now?`;
	}
	spendStep("check");
}

async function confirmSpend() {
	const { amount, kind } = state.spend;
	if (amount <= 0 || amount > state.bank.balance) return;
	state.bank.balance -= amount;
	state.bank.unrecorded -= amount;
	addDrop({
		kind: "spend",
		need: kind,
		amount: -amount,
		label: kind === "need" ? "Spent on a need" : "Spent on a want",
	});
	clink([660, 440]);
	renderHome();
	show("home");
	await saveBank();
	maybeCelebrate();
}

function keepSaving() {
	clink([880, 1320]);
	toast("Great choice! Your piggy is proud of you. 🐷");
	show("home");
}

// ---------------------------------------------------------------------------
// Grown-up gate: hold the button for 2 seconds, then answer a sum
// ---------------------------------------------------------------------------

function setupHold() {
	const button = $("grownup-hold");
	let timer = null;
	let opened = false;

	const start = (event) => {
		if (timer) return;
		if (event.type === "pointerdown")
			button.setPointerCapture?.(event.pointerId);
		button.classList.add("holding");
		$("hold-hint").hidden = false;
		timer = setTimeout(() => {
			stop();
			opened = true;
			openGate();
		}, HOLD_MS);
	};
	const stop = () => {
		clearTimeout(timer);
		timer = null;
		button.classList.remove("holding");
		$("hold-hint").hidden = true;
	};

	button.addEventListener("pointerdown", start);
	for (const type of ["pointerup", "pointercancel", "pointerleave"]) {
		button.addEventListener(type, stop);
	}
	button.addEventListener("keydown", (event) => {
		if ((event.key === "Enter" || event.key === " ") && !event.repeat) {
			event.preventDefault();
			start(event);
		}
	});
	button.addEventListener("keyup", stop);
	button.addEventListener("contextmenu", (event) => event.preventDefault());
	button.addEventListener("click", (event) => {
		// A quick tap does nothing on its own; say how to get in.
		if (opened) {
			opened = false;
			return;
		}
		if (event.detail > 0) toast("Grown-ups: press and hold for 2 seconds.");
	});
}

function openGate() {
	const a = 3 + Math.floor(Math.random() * 7);
	const b = 3 + Math.floor(Math.random() * 7);
	state.gateAnswer = a * b;
	$("gate-question").textContent = `${a} × ${b} = ?`;
	$("gate-answer").value = "";
	$("gate-error").hidden = true;
	show("gate");
	$("gate-answer").focus();
}

function submitGate(event) {
	event.preventDefault();
	if (Number($("gate-answer").value.trim()) === state.gateAnswer) {
		state.gateAnswer = null;
		openParent();
	} else {
		$("gate-error").hidden = false;
		$("gate-answer").select();
	}
}

// ---------------------------------------------------------------------------
// Grown-up settings
// ---------------------------------------------------------------------------

function canRead() {
	return state.sure.can("accounts:read") && !state.readDenied;
}

function canWrite() {
	return state.sure.can("transactions:write") && !state.writeDenied;
}

async function openParent() {
	renderParent();
	show("parent");
	if (canRead() && !state.accountsLoaded) await loadAccounts();
}

async function loadAccounts() {
	if (!canRead()) return;
	$("account-balance").textContent = "Loading accounts…";
	try {
		const result = await state.sure.accounts.list();
		// Savings live in asset accounts; loans and cards are not a piggy bank.
		state.accounts = (result.accounts || []).filter(
			(account) => account.classification === "asset",
		);
		state.accountsLoaded = true;
	} catch (error) {
		if (error?.code === window.SureMiniApp.ErrorCodes.PERMISSION_DENIED) {
			state.readDenied = true;
		}
		$("account-balance").textContent = describeError(error);
		renderParent();
		return;
	}
	renderParent();
	renderHome();
}

function renderParent() {
	const { bank } = state;
	const sure = state.sure;

	// Missing permissions: say what is off and why, rather than failing later.
	const missing = Object.keys(PERMISSION_NAMES).filter((p) => !sure.can(p));
	if (state.readDenied && !missing.includes("accounts:read"))
		missing.push("accounts:read");
	if (state.writeDenied && !missing.includes("transactions:write"))
		missing.push("transactions:write");
	const notice = $("parent-missing");
	notice.hidden = missing.length === 0;
	notice.textContent = `Some features are off because a Sure admin has not granted: ${missing
		.map((p) => PERMISSION_NAMES[p])
		.join(", ")}. The piggy bank itself still works.`;

	// Weekly bonus
	const bonus = bonusInfo();
	const segmented = $("bonus-percent");
	segmented.replaceChildren();
	for (const percent of BONUS_CHOICES) {
		const button = document.createElement("button");
		button.type = "button";
		button.setAttribute("role", "radio");
		button.setAttribute("aria-checked", String(bonus.percent === percent));
		button.textContent = percent === 0 ? "Off" : `${percent}%`;
		button.addEventListener("click", async () => {
			bank.settings.bonusPercent = percent;
			renderParent();
			renderHome();
			await saveBank();
		});
		segmented.append(button);
	}
	const giveButton = $("bonus-give");
	if (bonus.percent === 0) {
		$("bonus-status").textContent = "The bonus is off.";
		giveButton.hidden = true;
	} else {
		giveButton.hidden = false;
		giveButton.disabled = !bonus.ready || bonus.amount === 0;
		giveButton.textContent = `Give bonus ${signedMoney(bonus.amount || 0)}`;
		if (!bonus.ready) {
			$("bonus-status").textContent =
				`Next bonus in ${bonus.sleeps} ${bonus.sleeps === 1 ? "day" : "days"}.`;
		} else if (bonus.amount === 0) {
			$("bonus-status").textContent =
				"Nothing saved yet, so no bonus this week.";
		} else {
			$("bonus-status").textContent =
				`${bonus.percent}% of ${money(bank.balance)} saved. Hand over the real coins too!`;
		}
	}

	// Real money in Sure
	const mirrorCard = $("mirror-card");
	mirrorCard.hidden =
		!sure.can("accounts:read") && !sure.can("transactions:write");

	const select = $("account-select");
	$("account-field").hidden = !canRead() || state.accounts.length === 0;
	const empty = $("account-empty");
	if (!canRead()) {
		empty.hidden = false;
		empty.textContent =
			"Ask a Sure admin to grant “See accounts” so you can choose an account.";
	} else if (state.accountsLoaded && state.accounts.length === 0) {
		empty.hidden = false;
		empty.textContent = "There are no savings or cash accounts in Sure yet.";
	} else {
		empty.hidden = true;
	}

	select.replaceChildren();
	const placeholder = document.createElement("option");
	placeholder.value = "";
	placeholder.textContent = "Choose an account…";
	select.append(placeholder);
	for (const account of state.accounts) {
		const option = document.createElement("option");
		option.value = account.id;
		option.textContent = account.is_linked
			? `${account.name} (linked to a bank)`
			: account.name;
		select.append(option);
	}
	select.value = selectedAccount() ? bank.settings.accountId : "";

	const account = selectedAccount();
	if (account) {
		$("account-balance").textContent =
			`In Sure today: ${account.balance_formatted}. In the piggy bank: ${money(bank.balance)}.`;
	} else if (state.accountsLoaded) {
		$("account-balance").textContent = "";
	}

	renderRecordBlock(account);
	$("sound-toggle").textContent =
		`Sound: ${bank.settings.sound ? "on" : "off"}`;
}

function renderRecordBlock(account) {
	const { bank } = state;
	const block = $("record-block");
	block.hidden = !canWrite();
	if (block.hidden) return;

	const pending = bank.pendingRecord;
	const amount = pending ? pending.amount : bank.unrecorded;
	const target = pending
		? state.accounts.find((a) => a.id === pending.accountId) || account
		: account;
	const button = $("record-button");

	if (pending) {
		$("record-status").textContent =
			`Sure has not confirmed the last record (${signedMoney(amount)}). Record it again: Sure will not add it twice.`;
	} else if (amount === 0) {
		$("record-status").textContent =
			"Everything in the piggy bank is already recorded in Sure.";
	} else {
		$("record-status").textContent =
			amount > 0
				? `${money(amount)} saved since the last record.`
				: `${money(-amount)} spent since the last record.`;
	}

	button.disabled = state.recording || amount === 0 || !target;
	button.textContent = target
		? `Record ${signedMoney(amount)} in ${target.name}`
		: "Choose an account first";

	$("record-policy").textContent =
		state.sure.writePolicy === "allow"
			? "Your Sure admin lets this app write without asking, so this is recorded straight away."
			: "Sure will ask a grown-up to approve before anything is written.";

	const last = bank.lastRecord;
	$("record-last").textContent = last
		? `Last recorded: ${signedMoney(last.amount)} in ${last.accountName}, ${shortDate(last.at)}.`
		: "";
}

async function giveBonus() {
	const bonus = bonusInfo();
	if (!bonus.ready || bonus.amount === 0) return;
	const before = state.bank.balance;
	state.bank.balance += bonus.amount;
	state.bank.unrecorded += bonus.amount;
	state.bank.lastBonusAt = new Date().toISOString();
	addDrop({
		kind: "bonus",
		amount: bonus.amount,
		label: `Bonus ${bonus.percent}%`,
	});
	// Shown to the child when the grown-up taps Done.
	state.pendingBonus = { before, amount: bonus.amount, percent: bonus.percent };
	renderParent();
	renderHome();
	toast("Bonus added. Tap Done to show your child.");
	await saveBank();
}

function leaveParent() {
	if (state.pendingBonus) {
		const { before, amount } = state.pendingBonus;
		state.pendingBonus = null;
		$("bonus-text").textContent =
			`You had ${money(before)}. Bonus ${signedMoney(amount)}. Now you have ${money(before + amount)}!`;
		renderCoinRow($("bonus-coins"), amount);
		clink([523, 659, 784]);
		show("bonus");
		return;
	}
	show("home");
	maybeCelebrate();
}

async function recordInSure() {
	const { bank } = state;
	if (state.recording || !canWrite()) return;

	let pending = bank.pendingRecord;
	if (!pending) {
		const account = selectedAccount();
		if (!account || bank.unrecorded === 0) return;
		pending = {
			id: newId(),
			amount: bank.unrecorded,
			accountId: account.id,
			accountName: account.name,
		};
		bank.pendingRecord = pending;
		if (!(await saveBank())) {
			bank.pendingRecord = null;
			return;
		}
	}

	state.recording = true;
	renderParent();
	$("record-status").textContent =
		state.sure.writePolicy === "allow"
			? "Recording…"
			: "Waiting for a grown-up to approve in Sure…";

	try {
		const result = await state.sure.transactions.create({
			account_id: pending.accountId,
			date: todayIso(),
			amount: Math.abs(pending.amount),
			type: pending.amount > 0 ? "income" : "expense",
			name: pending.amount > 0 ? "Piggy Bank savings" : "Piggy Bank spending",
			notes: "Recorded from the Piggy Bank mini app.",
			// Same id on a retry, so Sure returns the first record instead of a copy.
			external_id: `piggy-bank-${pending.id}`,
			source: "piggy-bank",
		});

		if (result && result.success === false) {
			// Validation failures are reported as a value and write nothing.
			bank.pendingRecord = null;
			await saveBank();
			toast(
				result.error === "account_not_found"
					? "You cannot add transactions to that account. Choose another one."
					: `Sure could not record it: ${result.message || result.error}`,
				"error",
			);
			return;
		}

		bank.unrecorded -= pending.amount;
		bank.pendingRecord = null;
		bank.lastRecord = {
			at: new Date().toISOString(),
			amount: pending.amount,
			accountName: pending.accountName,
		};
		await saveBank();
		toast(
			`Recorded ${signedMoney(pending.amount)} in ${pending.accountName}. ✅`,
		);
		state.accountsLoaded = false;
		loadAccounts();
	} catch (error) {
		const codes = window.SureMiniApp.ErrorCodes;
		if (
			error?.code === codes.DECLINED ||
			error?.code === codes.PERMISSION_DENIED
		) {
			// Nothing was written, so a later record starts fresh.
			bank.pendingRecord = null;
			await saveBank();
		}
		if (error?.code === codes.PERMISSION_DENIED) state.writeDenied = true;
		toast(describeError(error), error?.code === codes.DECLINED ? "" : "error");
	} finally {
		state.recording = false;
		renderParent();
	}
}

async function resetBank() {
	const ok = window.confirm(
		"Empty the piggy bank and clear its history? Nothing is deleted in Sure.",
	);
	if (!ok) return;
	const settings = state.bank.settings;
	state.bank = { ...defaultBank(), settings };
	renderParent();
	renderHome();
	await saveBank();
	toast("The piggy bank is empty and ready to start again.");
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

function wire() {
	renderAddCoins();
	setupHold();

	$("goal-card").addEventListener("click", openGoal);
	$("spend-button").addEventListener("click", openSpend);

	$("goal-cancel").addEventListener("click", () => show("home"));
	$("goal-save").addEventListener("click", saveGoal);
	$("goal-name").addEventListener("input", (event) => {
		state.goalDraft.name = event.target.value;
	});
	for (const button of document.querySelectorAll("#screen-goal .step")) {
		button.addEventListener("click", () => {
			const step = Number(button.dataset.step);
			state.goalDraft.price = Math.min(
				PRICE_MAX,
				Math.max(PRICE_MIN, state.goalDraft.price + step),
			);
			renderGoalPicker();
		});
	}

	$("spend-clear").addEventListener("click", () => {
		state.spend.amount = 0;
		renderSpend();
	});
	$("spend-next").addEventListener("click", () => spendStep("kind"));
	$("spend-cancel").addEventListener("click", () => show("home"));
	$("spend-need").addEventListener("click", () => chooseKind("need"));
	$("spend-want").addEventListener("click", () => chooseKind("want"));
	$("spend-kind-back").addEventListener("click", () => spendStep("amount"));
	$("spend-keep").addEventListener("click", keepSaving);
	$("spend-confirm").addEventListener("click", confirmSpend);

	$("celebrate-buy").addEventListener("click", buyGoal);
	$("celebrate-keep").addEventListener("click", () => show("home"));
	$("bonus-ok").addEventListener("click", () => {
		show("home");
		maybeCelebrate();
	});

	$("gate-form").addEventListener("submit", submitGate);
	$("gate-cancel").addEventListener("click", () => show("home"));

	$("parent-done").addEventListener("click", leaveParent);
	$("bonus-give").addEventListener("click", giveBonus);
	$("account-select").addEventListener("change", async (event) => {
		state.bank.settings.accountId = event.target.value || null;
		renderParent();
		renderHome();
		await saveBank();
	});
	$("record-button").addEventListener("click", recordInSure);
	$("parent-goal").addEventListener("click", openGoal);
	$("sound-toggle").addEventListener("click", async () => {
		state.bank.settings.sound = !state.bank.settings.sound;
		renderParent();
		await saveBank();
	});
	$("reset-button").addEventListener("click", resetBank);

	// Sure sends this after each successful write by this app.
	state.sure.on("dataChanged", () => {
		if (canRead()) loadAccounts();
	});
}

async function main() {
	try {
		state.sure = await window.SureMiniApp.connect();
	} catch (error) {
		$("loading-text").textContent = describeError(error);
		return;
	}

	try {
		await loadBank();
	} catch (error) {
		$("loading-text").textContent =
			`The piggy bank could not open. ${describeError(error)}`;
		return;
	}

	wire();
	renderHome();
	show("home");

	// Show the account's currency on the coins once it is known.
	if (canRead() && state.bank.settings.accountId) loadAccounts();
}

main();
