import { Controller } from "@hotwired/stimulus";

// Settings → Local AI inside the Sure Desktop app. The desktop launcher owns
// the models and the llama.cpp server; this page reads its state and sends it
// commands over Tauri IPC, which the launcher allows only for its own local
// Sure server. In any other browser the page shows an "unavailable" notice.
export default class extends Controller {
  static targets = [
    "unavailable",
    "panel",
    "enabled",
    "status",
    "context",
    "models",
    "folder",
    "message",
    "customName",
    "customSource",
    "modelTemplate",
    "recommendedBadge",
    "customBadge",
    "downloadButton",
    "useButton",
    "inUseButton",
    "deleteButton",
    "cancelButton",
    "dismissButton",
  ];
  static values = { strings: Object };

  async connect() {
    const tauri = window.__TAURI__;
    if (!tauri?.core?.invoke || !tauri?.event?.listen) return this.showUnavailable();

    this.invoke = tauri.core.invoke;
    try {
      const view = await this.invoke("local_ai_state");
      if (!view?.available) return this.showUnavailable();
      this.render(view);
      this.unlisten = await tauri.event.listen("local-ai-state", (event) => this.render(event.payload));
    } catch (_error) {
      this.showUnavailable();
    }
  }

  disconnect() {
    this.unlisten?.();
  }

  // Actions -------------------------------------------------------------------

  toggle(event) {
    this.call("local_ai_set_enabled", { enabled: event.target.checked });
  }

  setContext(event) {
    this.call("local_ai_set_context", { context: Number(event.target.value) });
  }

  download(event) {
    this.call("local_ai_download", { id: this.modelId(event) });
  }

  select(event) {
    this.call("local_ai_select", { id: this.modelId(event) });
  }

  cancel() {
    this.call("local_ai_cancel_download");
  }

  dismiss() {
    this.call("local_ai_dismiss_error");
  }

  // Deleting asks for a second click instead of a dialog.
  remove(event) {
    const button = event.currentTarget;
    if (button.dataset.armed === "true") {
      this.call("local_ai_delete", { id: this.modelId(event) });
      return;
    }
    button.dataset.armed = "true";
    const label = this.label(button);
    const original = label.textContent;
    label.textContent = this.stringsValue.confirm_delete;
    setTimeout(() => {
      button.dataset.armed = "false";
      label.textContent = original;
    }, 4000);
  }

  async addCustom(event) {
    event.preventDefault();
    const name = this.customNameTarget.value;
    const source = this.customSourceTarget.value;
    if (await this.call("local_ai_add_custom", { name, source })) {
      this.customNameTarget.value = "";
      this.customSourceTarget.value = "";
    }
  }

  // Rendering -----------------------------------------------------------------

  render(view) {
    if (!view?.available) return this.showUnavailable();
    this.unavailableTarget.classList.add("hidden");
    this.panelTarget.classList.remove("hidden");

    this.enabledTarget.checked = view.enabled;
    this.contextTarget.value = String(view.context);
    this.folderTarget.textContent = this.format(this.stringsValue.folder, { path: view.models_dir });
    this.statusTarget.textContent = this.statusText(view);
    this.statusTarget.classList.toggle("text-destructive", view.enabled && view.server.state === "failed");

    const busy = Boolean(view.download && !view.download.error);
    const rows = view.models.map((model) => this.renderModel(model, view.download, busy));
    this.modelsTarget.replaceChildren(...rows);
  }

  renderModel(model, download, busy) {
    const row = this.modelTemplateTarget.content.firstElementChild.cloneNode(true);
    const field = (name) => row.querySelector(`[data-field="${name}"]`);

    if (model.active) row.classList.replace("border-transparent", "border-primary");
    field("name").textContent = model.name;
    if (model.recommended || model.custom) {
      field("badge").replaceChildren(this.cloneTemplate(model.recommended ? "recommendedBadge" : "customBadge"));
    }
    const facts = [
      model.description,
      model.size ? this.gigabytes(model.size) : null,
      model.ram_gb ? this.format(this.stringsValue.memory, { gb: model.ram_gb }) : null,
      model.license || null,
    ];
    field("meta").textContent = facts.filter(Boolean).join(" · ");

    const actions = field("actions");
    const add = (template, disabled = false) => {
      const button = this.cloneTemplate(template);
      button.dataset.desktopLocalAiIdParam = model.id;
      if (disabled) button.disabled = true;
      actions.append(button);
    };

    const mine = download && download.id === model.id ? download : null;
    if (mine && !mine.error) {
      add("cancelButton");
      field("progress").classList.remove("hidden");
      const percent = mine.total ? Math.min(100, (100 * mine.received) / mine.total) : 0;
      field("bar").style.width = `${percent}%`;
      field("progressText").textContent = this.format(this.stringsValue.downloading, {
        received: this.gigabytes(mine.received),
        total: mine.total ? this.gigabytes(mine.total) : "?",
      });
    } else if (model.downloaded) {
      add(model.active ? "inUseButton" : "useButton");
      add("deleteButton");
    } else {
      add("downloadButton", busy);
      if (model.custom) add("deleteButton");
    }

    if (mine?.error) {
      field("error").textContent = mine.error;
      field("error").classList.remove("hidden");
      add("dismissButton");
    }
    return row;
  }

  statusText(view) {
    const strings = this.stringsValue;
    const active = view.models.find((model) => model.active);
    if (!view.enabled) return strings.off;
    if (!active || !active.downloaded) return strings.no_model;
    switch (view.server.state) {
      case "starting":
        return this.format(strings.starting, { name: active.name });
      case "running":
        return this.format(strings.running, { name: active.name });
      case "failed":
        return this.format(strings.failed, { message: view.server.message });
      default:
        return "";
    }
  }

  // Helpers -------------------------------------------------------------------

  async call(command, args = {}) {
    this.messageTarget.classList.add("hidden");
    try {
      await this.invoke(command, args);
      return true;
    } catch (error) {
      this.messageTarget.textContent = String(error);
      this.messageTarget.classList.remove("hidden");
      return false;
    }
  }

  showUnavailable() {
    this.panelTarget.classList.add("hidden");
    this.unavailableTarget.classList.remove("hidden");
  }

  cloneTemplate(name) {
    return this[`${name}Target`].content.firstElementChild.cloneNode(true);
  }

  modelId(event) {
    return event.params.id ?? event.currentTarget.dataset.desktopLocalAiIdParam;
  }

  // The visible text of a DS::Button (its label span, or the button itself).
  label(button) {
    return button.querySelector("span") || button;
  }

  gigabytes(bytes) {
    return `${(bytes / 1e9).toFixed(bytes < 1e9 ? 2 : 1)} GB`;
  }

  format(template, values) {
    return template.replace(/%\{(\w+)\}/g, (_, key) => String(values[key] ?? ""));
  }
}
