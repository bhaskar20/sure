import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { S } from "./strings";
import { serverErrorMessage } from "./status";

interface ServerEntry { url: string; label: string; }

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

// Navigate to a server's login page exactly once. connect() and the
// active-server-changed listener(s) can all request navigation for the same
// server; without this guard they fire multiple concurrent GET /sessions/new
// requests, each minting a new session + CSRF token, which race and cause
// "Can't verify CSRF token authenticity" on the POST.
function goToServer(url: string) {
  const w = window as unknown as { __sureNav?: string };
  if (w.__sureNav) return;
  w.__sureNav = url;
  // Navigate to the server root: Rails serves the dashboard if the session
  // cookie is still valid, or redirects to the login page if not — so a
  // relaunch with a live session resumes without re-logging in.
  window.location.assign(`${url}/`);
}

function fill() {
  ($("logo") as HTMLImageElement).src = new URL("./assets/logomark.svg", import.meta.url).href;
  $("title").textContent = S.title;
  $("url-label").textContent = S.serverLabel;
  ($("server-url") as HTMLInputElement).placeholder = S.urlPlaceholder;
  $("connect").textContent = S.connect;
  $("remembered-title").textContent = S.remembered;
}

function setStatus(msg: string, kind: "info" | "error" = "info") {
  const el = $("status");
  el.textContent = msg;
  el.dataset.kind = kind;
}

async function connect(rawUrl: string) {
  setStatus(S.checking, "info");
  // Remember the base check_server resolved to, not the raw input.
  let base: string | null;
  try {
    base = await invoke<string | null>("check_server", { url: rawUrl });
  } catch (e) {
    setStatus(serverErrorMessage(e), "error");
    return;
  }
  if (!base) { setStatus(S.unreachable, "error"); return; }
  try {
    const list = await invoke<ServerEntry[]>("add_server", { url: base, label: "" });
    const canonical = list.find((s) => s.url === base)?.url ?? list[0].url;
    await invoke("set_active_server", { url: canonical });
    goToServer(canonical);
  } catch (e) {
    setStatus(serverErrorMessage(e), "error");
  }
}

async function renderRemembered() {
  const servers = await invoke<ServerEntry[]>("list_servers");
  const section = $("remembered");
  const listEl = $("server-list");
  listEl.innerHTML = "";
  if (servers.length === 0) { section.classList.add("hidden"); return; }
  section.classList.remove("hidden");
  for (const s of servers) {
    const li = document.createElement("li");
    const open = document.createElement("button");
    open.className = "server-open";
    open.textContent = s.label;
    open.addEventListener("click", () => connect(s.url));
    const rm = document.createElement("button");
    rm.className = "server-remove";
    rm.textContent = S.remove;
    rm.addEventListener("click", async (e) => {
      e.stopPropagation();
      await invoke("remove_server", { url: s.url });
      renderRemembered();
    });
    li.append(open, rm);
    listEl.append(li);
  }
}

$("server-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const url = ($("server-url") as HTMLInputElement).value.trim();
  if (url) connect(url);
});

type LocalStatus =
  | { state: "not_bundled" }
  | { state: "starting"; step: string }
  | { state: "ready"; url: string; dev_login: boolean }
  | { state: "failed"; message: string; logs: string };

// Packaged builds run Sure on this computer: show progress until the local
// server answers, then open it. Returns false when this build has no bundled
// server, so the remote-server picker is used instead.
async function bootLocal(): Promise<boolean> {
  let status: LocalStatus;
  try {
    status = await invoke<LocalStatus>("local_backend_status");
  } catch {
    return false;
  }
  if (status.state === "not_bundled") return false;

  ($("logo") as HTMLImageElement).src = new URL("./assets/logomark.svg", import.meta.url).href;
  $("server-form").classList.add("hidden");
  $("remembered").classList.add("hidden");
  const show = (s: LocalStatus) => {
    if (s.state === "starting") {
      $("title").textContent = S.localTitle;
      setStatus(`${s.step}…`, "info");
    } else if (s.state === "ready") {
      if (s.dev_login) showDevAccounts(s.url);
      else goToServer(s.url);
    } else if (s.state === "failed") {
      $("title").textContent = S.localFailed;
      setStatus(`${s.message}\n${S.localLogs} ${s.logs}`, "error");
    }
  };
  // Subscribe before re-reading, so a transition between the two isn't missed.
  await listen<LocalStatus>("local-backend-status", (e) => show(e.payload));
  show(await invoke<LocalStatus>("local_backend_status"));
  return true;
}

interface DevAccount { email: string; name: string; role: string; family: string; }
interface DevSignIn { token: string; sign_in_url: string; accounts: DevAccount[]; }

// Human dev mode (debug builds): list the dev data's accounts and sign in as
// the one picked, so testing starts on that user's dashboard.
async function showDevAccounts(url: string) {
  const w = window as unknown as { __sureDevPicker?: boolean };
  if (w.__sureDevPicker) return;
  w.__sureDevPicker = true;

  let signIn: DevSignIn;
  try {
    signIn = await invoke<DevSignIn>("dev_accounts");
  } catch (e) {
    setStatus(String(e), "error");
    goToServer(url);
    return;
  }
  $("title").textContent = S.devAccountsTitle;
  setStatus("");
  $("dev-accounts-title").textContent = signIn.accounts.length ? "" : S.devAccountsEmpty;
  $("dev-skip").textContent = S.devSkip;
  $("dev-skip").addEventListener("click", () => goToServer(url));

  const list = $("dev-account-list");
  list.innerHTML = "";
  for (const account of signIn.accounts) {
    const li = document.createElement("li");
    const button = document.createElement("button");
    button.className = "server-open";
    button.textContent = `${account.name || account.email} · ${account.email}`;
    button.title = `${account.role} · ${account.family}`;
    button.addEventListener("click", () => signInAs(signIn, account.email));
    li.append(button);
    list.append(li);
  }
  $("dev-accounts").classList.remove("hidden");
}

// A form POST navigates the window to Sure, which sets the session cookie and
// redirects to the dashboard.
function signInAs(signIn: DevSignIn, email: string) {
  const form = document.createElement("form");
  form.method = "POST";
  form.action = signIn.sign_in_url;
  for (const [name, value] of [["token", signIn.token], ["email", email]]) {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = name;
    input.value = value;
    form.append(input);
  }
  document.body.append(form);
  form.submit();
}

// On launch, resume straight to the last server if there is one; otherwise
// show the picker.
async function boot() {
  if (await bootLocal()) return;
  let active: string | null = null;
  try {
    active = await invoke<string | null>("active_server");
  } catch (e) {
    // Don't let a failed read abort startup and leave a blank onboarding window.
    // eslint-disable-next-line no-console
    console.error("[sure] failed to read active server", e);
  }
  if (active) {
    goToServer(active);
    return;
  }
  fill();
  renderRemembered();
}
boot();

// Navigate when the active server changes (e.g. picked from Preferences).
listen<string>("active-server-changed", (e) => goToServer(e.payload));
