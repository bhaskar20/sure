import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { P, S } from "./strings";
import { serverErrorMessage } from "./status";

interface ServerEntry { url: string; label: string; }
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

$("prefs-title").textContent = P.title;
$("servers-title").textContent = P.servers;
$("prefs-add-btn").textContent = P.add;
$("autostart-label").textContent = P.launchAtLogin;
($("prefs-url") as HTMLInputElement).placeholder = S.urlPlaceholder;

async function renderServers() {
  const servers = await invoke<ServerEntry[]>("list_servers");
  const list = $("prefs-server-list");
  list.innerHTML = "";
  for (const s of servers) {
    const li = document.createElement("li");
    const open = document.createElement("button");
    open.className = "server-open";
    open.textContent = s.label;
    open.addEventListener("click", async () => {
      try {
        await invoke("set_active_server", { url: s.url });
        await getCurrentWindow().hide();
      } catch (err) {
        $("prefs-status").textContent = serverErrorMessage(err);
      }
    });
    const rm = document.createElement("button");
    rm.className = "server-remove";
    rm.textContent = S.remove;
    rm.addEventListener("click", async (e) => {
      e.stopPropagation();
      try {
        await invoke("remove_server", { url: s.url });
        renderServers();
      } catch (err) {
        $("prefs-status").textContent = serverErrorMessage(err);
      }
    });
    li.append(open, rm);
    list.append(li);
  }
}

$("prefs-add").addEventListener("submit", async (e) => {
  e.preventDefault();
  const url = ($("prefs-url") as HTMLInputElement).value.trim();
  if (!url) return;
  $("prefs-status").textContent = S.checking;
  try {
    const base = await invoke<string | null>("check_server", { url });
    if (!base) { $("prefs-status").textContent = S.unreachable; return; }
    await invoke("add_server", { url: base, label: "" });
    ($("prefs-url") as HTMLInputElement).value = "";
    $("prefs-status").textContent = "";
    renderServers();
  } catch (err) {
    $("prefs-status").textContent = serverErrorMessage(err);
  }
});

const autostart = $("autostart") as HTMLInputElement;
invoke<boolean>("get_launch_at_login").then((v) => (autostart.checked = v));
autostart.addEventListener("change", () => invoke("set_launch_at_login", { enabled: autostart.checked }));

renderServers();

// --- Local AI -------------------------------------------------------------
import { listen } from "@tauri-apps/api/event";
import { AI } from "./strings";

interface ModelView {
  id: string; name: string; description: string; size: number; license: string;
  ram_gb: number; recommended: boolean; custom: boolean; downloaded: boolean; active: boolean;
}
interface DownloadView { id: string; received: number; total: number; error: string | null; }
type ServerState =
  | { state: "off" } | { state: "starting" } | { state: "running" } | { state: "failed"; message: string };
interface AiView {
  available: boolean; enabled: boolean; context: number; models: ModelView[];
  download: DownloadView | null; server: ServerState; models_dir: string; log: string;
}

const gb = (bytes: number) => `${(bytes / 1e9).toFixed(bytes < 1e9 ? 2 : 1)} GB`;

function setAiStatus(msg: string, kind: "info" | "error" = "info") {
  const el = $("ai-status");
  el.textContent = msg;
  el.dataset.kind = kind;
}

async function call(cmd: string, args: Record<string, unknown> = {}) {
  try {
    setAiStatus("");
    await invoke(cmd, args);
  } catch (err) {
    setAiStatus(String(err), "error");
  }
}

function button(text: string, onClick: () => void, primary = false, disabled = false) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = primary ? "btn-small btn-small--primary" : "btn-small";
  b.textContent = text;
  b.disabled = disabled;
  b.addEventListener("click", onClick);
  return b;
}

// A delete button that asks for a second click instead of a dialog.
function confirmButton(text: string, confirmText: string, onConfirm: () => void) {
  const b = button(text, () => {
    if (b.dataset.armed === "true") return onConfirm();
    b.dataset.armed = "true";
    b.textContent = confirmText;
    setTimeout(() => { b.dataset.armed = "false"; b.textContent = text; }, 4000);
  });
  return b;
}

function renderAi(view: AiView | null) {
  if (!view || !view.available) {
    $("ai").classList.add("hidden");
    $("ai-unavailable").classList.remove("hidden");
    return;
  }
  $("ai-unavailable").classList.add("hidden");
  $("ai").classList.remove("hidden");
  ($("ai-enabled") as HTMLInputElement).checked = view.enabled;
  ($("ai-context") as HTMLSelectElement).value = String(view.context);
  $("ai-folder").textContent = AI.folder(view.models_dir);

  const active = view.models.find((m) => m.active);
  const server = $("ai-server");
  server.dataset.kind = "info";
  if (!view.enabled) server.textContent = AI.off;
  else if (!active || !active.downloaded) server.textContent = AI.noModel;
  else if (view.server.state === "starting") server.textContent = AI.starting(active.name);
  else if (view.server.state === "running") server.textContent = AI.running(active.name);
  else if (view.server.state === "failed") {
    server.textContent = AI.failed(view.server.message);
    server.dataset.kind = "error";
  } else server.textContent = "";

  const list = $("ai-models");
  list.innerHTML = "";
  const busy = !!view.download && !view.download.error;
  for (const m of view.models) {
    const li = document.createElement("li");
    li.className = "ai-model";
    li.dataset.active = String(m.active);

    const name = document.createElement("div");
    name.className = "ai-model__name";
    name.textContent = m.name;
    if (m.recommended || m.custom) {
      const badge = document.createElement("span");
      badge.className = "ai-model__badge";
      badge.textContent = m.recommended ? AI.recommended : AI.custom;
      name.append(badge);
    }
    const meta = document.createElement("div");
    meta.className = "ai-model__meta";
    const facts = [m.description, m.size ? gb(m.size) : "", m.ram_gb ? AI.ram(m.ram_gb) : "", m.license]
      .filter(Boolean);
    meta.textContent = facts.join(" · ");

    const actions = document.createElement("div");
    actions.className = "ai-model__actions";
    const dl = view.download && view.download.id === m.id ? view.download : null;
    if (dl && !dl.error) {
      actions.append(button(AI.cancel, () => call("local_ai_cancel_download")));
    } else if (m.downloaded) {
      actions.append(
        m.active
          ? button(AI.inUse, () => {}, true, true)
          : button(AI.use, () => call("local_ai_select", { id: m.id }), true),
      );
      actions.append(confirmButton(AI.delete, AI.confirmDelete, () => call("local_ai_delete", { id: m.id })));
    } else {
      actions.append(button(AI.download, () => call("local_ai_download", { id: m.id }), true, busy));
      if (m.custom) actions.append(button(AI.delete, () => call("local_ai_delete", { id: m.id })));
    }
    li.append(name, actions, meta);

    if (dl) {
      if (dl.error) {
        const err = document.createElement("div");
        err.className = "ai-model__meta";
        err.style.color = "var(--error)";
        err.textContent = dl.error;
        li.append(err);
        actions.prepend(button(AI.retry, () => call("local_ai_dismiss_error")));
      } else {
        const bar = document.createElement("div");
        bar.className = "ai-model__progress";
        const fill = document.createElement("div");
        fill.style.width = dl.total ? `${Math.min(100, (100 * dl.received) / dl.total)}%` : "0%";
        bar.append(fill);
        const text = document.createElement("div");
        text.className = "ai-model__meta";
        text.textContent = AI.downloading(gb(dl.received), dl.total ? gb(dl.total) : "?");
        li.append(bar, text);
      }
    }
    list.append(li);
  }
}

$("ai-title").textContent = AI.title;
$("ai-title-2").textContent = AI.title;
$("ai-intro").textContent = AI.intro;
$("ai-unavailable-text").textContent = AI.unavailable;
$("ai-enabled-label").textContent = AI.enable;
$("ai-context-label").textContent = AI.context;
$("ai-custom-title").textContent = AI.customTitle;
($("ai-custom-name") as HTMLInputElement).placeholder = AI.customName;
($("ai-custom-source") as HTMLInputElement).placeholder = AI.customSource;
$("ai-custom-add").textContent = AI.add;

($("ai-enabled") as HTMLInputElement).addEventListener("change", (e) =>
  call("local_ai_set_enabled", { enabled: (e.target as HTMLInputElement).checked }));
($("ai-context") as HTMLSelectElement).addEventListener("change", (e) =>
  call("local_ai_set_context", { context: Number((e.target as HTMLSelectElement).value) }));
$("ai-custom").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = ($("ai-custom-name") as HTMLInputElement).value;
  const source = ($("ai-custom-source") as HTMLInputElement).value;
  try {
    setAiStatus("");
    await invoke("local_ai_add_custom", { name, source });
    ($("ai-custom-name") as HTMLInputElement).value = "";
    ($("ai-custom-source") as HTMLInputElement).value = "";
  } catch (err) {
    setAiStatus(String(err), "error");
  }
});

listen<AiView>("local-ai-state", (e) => renderAi(e.payload));
invoke<AiView | null>("local_ai_state").then(renderAi).catch(() => renderAi(null));
