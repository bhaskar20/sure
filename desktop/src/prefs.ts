import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { P, S, U } from "./strings";
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


// Local AI is configured in Sure itself (Settings → Local AI).
import { AI } from "./strings";
$("ai-title").textContent = AI.title;
$("ai-moved").textContent = AI.moved;

interface UpdateInfo {
  enabled: boolean;
  current: string;
  checking: boolean;
  checked: boolean;
  available: boolean;
  latest: string | null;
  installable: boolean;
  installing: boolean;
  progress: number | null;
  error: string | null;
}

$("updates-title").textContent = U.title;
$("update-check").textContent = U.check;

function renderUpdate(info: UpdateInfo) {
  lastUpdate = info;
  const status = $("update-status");
  const download = $("update-download");
  const check = $("update-check") as HTMLButtonElement;
  check.classList.toggle("hidden", !info.enabled);
  check.disabled = info.checking || info.installing;
  download.classList.toggle("hidden", !(info.available && info.latest) || info.installing);
  status.dataset.kind = info.error && !info.checking ? "error" : "";
  if (!info.enabled) status.textContent = U.disabled(info.current);
  else if (info.checking) status.textContent = U.checking;
  else if (info.installing && info.latest) {
    const percent = info.progress === null ? null : Math.round(info.progress * 100);
    status.textContent = U.installing(info.latest, percent);
  } else if (info.available && info.latest) {
    if (info.installable) {
      status.textContent = info.error
        ? U.installFailed(info.latest, info.error)
        : U.installable(info.latest, info.current);
      download.textContent = U.install(info.latest);
    } else {
      status.textContent = U.available(info.latest, info.current);
      download.textContent = U.download(info.latest);
    }
  } else if (info.error) status.textContent = U.failed(info.current);
  else if (info.checked) status.textContent = U.upToDate(info.current);
  else status.textContent = U.current(info.current);
}

$("update-check").addEventListener("click", () => {
  invoke<UpdateInfo>("check_for_updates").then(renderUpdate).catch(() => {});
});
let lastUpdate: UpdateInfo | null = null;
$("update-download").addEventListener("click", () => {
  const command = lastUpdate?.installable ? "install_update" : "download_update";
  invoke(command).catch((err) => ($("update-status").textContent = String(err)));
});
listen<UpdateInfo>("updates://changed", (e) => renderUpdate(e.payload));
invoke<UpdateInfo>("update_status").then(renderUpdate);
