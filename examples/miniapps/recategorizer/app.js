// Recategorizer: lists transactions, creates a category and moves a selected
// transaction into it, using only the Sure mini app SDK.

const SETTINGS = { collection: "settings", key: "preferences" };
const DEFAULT_SETTINGS = {
  onlyUncategorized: false,
  pageSize: 25,
  lastCategoryId: null,
};

const state = {
  sure: null,
  settings: { ...DEFAULT_SETTINGS },
  transactions: [],
  categories: [],
  selectedId: null,
  refreshTimer: null,
};

const $ = (id) => document.getElementById(id);

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
    case codes.DECLINED:
      return "You declined the change. Nothing was saved.";
    case codes.APP_DISABLED:
      return "This app has been disabled by a family admin.";
    case codes.RATE_LIMITED:
      return "Too many requests. Wait a moment and try again.";
    case codes.NOT_EMBEDDED:
      return "Open this page from Sure's Apps page.";
    default:
      return error?.message || String(error);
  }
}

// Tools report expected failures (validation, not found) as a value.
function assertSuccess(result) {
  if (result && result.success === false) {
    throw new Error(result.message || result.error);
  }
  return result;
}

async function loadSettings() {
  try {
    const saved = await state.sure.storage.get(
      SETTINGS.collection,
      SETTINGS.key,
    );
    state.settings = { ...DEFAULT_SETTINGS, ...(saved || {}) };
  } catch (error) {
    console.warn("Could not read settings", error);
  }
  $("only-uncategorized").checked = Boolean(state.settings.onlyUncategorized);
  $("page-size").value = String(state.settings.pageSize);
}

async function saveSettings(changes) {
  state.settings = { ...state.settings, ...changes };
  try {
    await state.sure.storage.set(
      SETTINGS.collection,
      SETTINGS.key,
      state.settings,
    );
  } catch (error) {
    setStatus(describeError(error), "error");
  }
}

async function loadCategories() {
  if (!state.sure.can("categories:read")) return;

  const categories = [];
  let page = 1;
  let totalPages = 1;
  do {
    const result = await state.sure.categories.list({ page, page_size: 100 });
    categories.push(...result.categories);
    totalPages = result.total_pages;
    page += 1;
  } while (page <= totalPages && page <= 10);

  state.categories = categories;
  renderCategories();
}

async function loadTransactions() {
  if (!state.sure.can("transactions:read")) return;

  const args = { page_size: Number(state.settings.pageSize), order: "desc" };
  if (state.settings.onlyUncategorized) args.categories = ["Uncategorized"];

  const result = await state.sure.transactions.list(args);
  state.transactions = result.transactions;
  if (!state.transactions.some((txn) => txn.id === state.selectedId)) {
    state.selectedId = null;
  }
  renderTransactions();
  setStatus(
    `Showing ${result.transactions.length} of ${result.total_results} transactions.`,
  );
}

async function refresh() {
  try {
    await Promise.all([loadCategories(), loadTransactions()]);
  } catch (error) {
    setStatus(describeError(error), "error");
  }
}

function scheduleRefresh() {
  clearTimeout(state.refreshTimer);
  state.refreshTimer = setTimeout(refresh, 150);
}

function renderCategories() {
  const select = $("category");
  const current = select.value || state.settings.lastCategoryId;
  select.replaceChildren();

  const placeholder = document.createElement("option");
  placeholder.value = "";
  placeholder.textContent = "Choose a category…";
  select.append(placeholder);

  for (const category of state.categories) {
    const option = document.createElement("option");
    option.value = category.id;
    option.textContent = category.name_with_parent;
    select.append(option);
  }

  if (current && state.categories.some((c) => c.id === current)) {
    select.value = current;
  }
  updateControls();
}

function renderTransactions() {
  const body = $("transactions");
  body.replaceChildren();
  $("empty").hidden = state.transactions.length > 0;

  for (const txn of state.transactions) {
    const row = document.createElement("tr");
    row.classList.toggle("selected", txn.id === state.selectedId);

    const pick = document.createElement("td");
    const radio = document.createElement("input");
    radio.type = "radio";
    radio.name = "transaction";
    radio.value = txn.id;
    radio.checked = txn.id === state.selectedId;
    radio.setAttribute("aria-label", `Select ${txn.name}`);
    radio.addEventListener("change", () => {
      state.selectedId = txn.id;
      renderTransactions();
    });
    pick.append(radio);

    const amount = cell(
      `${txn.classification === "income" ? "+" : "−"}${txn.formatted_amount}`,
    );
    amount.className = `num ${txn.classification}`;

    row.append(
      pick,
      cell(txn.date),
      cell(txn.name),
      cell(txn.category || "Uncategorized", !txn.category ? "muted" : ""),
      amount,
    );
    row.addEventListener("click", (event) => {
      if (event.target !== radio) radio.click();
    });
    body.append(row);
  }
  updateControls();
}

function cell(text, className) {
  const td = document.createElement("td");
  td.textContent = text;
  if (className) td.className = className;
  return td;
}

function updateControls() {
  const sure = state.sure;
  $("recategorize").disabled =
    !sure?.can("transactions:write") ||
    !state.selectedId ||
    !$("category").value;
  $("create").disabled = !sure?.can("categories:write");
}

function showMissingPermissions() {
  const needed = [
    "transactions:read",
    "transactions:write",
    "categories:read",
    "categories:write",
  ];
  const missing = needed.filter((permission) => !state.sure.can(permission));
  const notice = $("missing");
  notice.hidden = missing.length === 0;
  notice.textContent = `Some features are off because these permissions are not granted: ${missing.join(", ")}.`;
}

async function recategorize(event) {
  event.preventDefault();
  const txn = state.transactions.find((t) => t.id === state.selectedId);
  const categoryId = $("category").value;
  if (!txn || !categoryId) return;

  const button = $("recategorize");
  button.disabled = true;
  setStatus(`Moving "${txn.name}"… Sure may ask you to confirm.`);
  try {
    const result = assertSuccess(
      await state.sure.transactions.update({
        id: txn.id,
        category_id: categoryId,
      }),
    );
    await saveSettings({ lastCategoryId: categoryId });
    setStatus(
      `Moved "${result.transaction.name}" to ${result.transaction.category?.name}.`,
    );
    scheduleRefresh();
  } catch (error) {
    setStatus(describeError(error), "error");
  } finally {
    updateControls();
  }
}

async function createCategory(event) {
  event.preventDefault();
  const input = $("new-category");
  const name = input.value.trim();
  if (!name) return;

  $("create").disabled = true;
  setStatus(`Creating "${name}"… Sure may ask you to confirm.`);
  try {
    const result = assertSuccess(await state.sure.categories.create({ name }));
    input.value = "";
    await saveSettings({ lastCategoryId: result.category.id });
    await loadCategories();
    $("category").value = result.category.id;
    setStatus(`Created "${result.category.name_with_parent}".`);
  } catch (error) {
    setStatus(describeError(error), "error");
  } finally {
    updateControls();
  }
}

async function main() {
  try {
    state.sure = await window.SureMiniApp.connect();
  } catch (error) {
    setStatus(describeError(error), "error");
    return;
  }

  showMissingPermissions();
  await loadSettings();

  $("only-uncategorized").addEventListener("change", async (event) => {
    await saveSettings({ onlyUncategorized: event.target.checked });
    refresh();
  });
  $("page-size").addEventListener("change", async (event) => {
    await saveSettings({ pageSize: Number(event.target.value) });
    refresh();
  });
  $("refresh").addEventListener("click", refresh);
  $("category").addEventListener("change", updateControls);
  $("recategorize-form").addEventListener("submit", recategorize);
  $("create-form").addEventListener("submit", createCategory);

  // Sure notifies the frame after each successful write this app makes.
  state.sure.on("dataChanged", scheduleRefresh);

  await refresh();
}

main();
