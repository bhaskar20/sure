import { Controller } from "@hotwired/stimulus";

const MAX_MESSAGE_BYTES = 1024 * 1024;
const MIN_HEIGHT = 200;
const MAX_HEIGHT = 10000;
const CONFIRMATION_REQUIRED = -32005;
// Approve stays inert this long after the dialog opens, so a click the frame
// lined up (a double-click, a held pointer) cannot land on it.
const APPROVE_ARM_DELAY_MS = 800;
const MAX_DETAIL_ROWS = 20;

// Hosts a sandboxed mini app iframe. The frame has an opaque origin, so it is
// identified by its window (event.source), and replies use target origin "*".
// Every request is forwarded to the server-side bridge, which enforces grants;
// write confirmations are drawn here, outside the frame, so the app cannot
// fake or click them.
export default class extends Controller {
  static targets = [
    "frame",
    "confirmDialog",
    "confirmMessage",
    "confirmDetails",
    "confirmDetailRow",
    "approveButton",
    "declineButton",
  ];
  static values = { bridgeUrl: String };

  connect() {
    this.queue = [];
    this.pending = null;
    this.writeTools = null;
    this.approveArmed = false;
    this.armedAt = Number.POSITIVE_INFINITY;
    this.armTimer = null;
    this.approvePressedAt = Number.NEGATIVE_INFINITY;
    this.handleMessage = this.handleMessage.bind(this);
    this.handleApprovePress = this.handleApprovePress.bind(this);
    this.handleDialogCancel = this.handleDialogCancel.bind(this);
    window.addEventListener("message", this.handleMessage);
    if (this.hasApproveButtonTarget) {
      this.approveButtonTarget.disabled = true;
      this.approveButtonTarget.addEventListener(
        "pointerdown",
        this.handleApprovePress,
      );
    }
    if (this.hasConfirmDialogTarget) {
      this.confirmDialogTarget.addEventListener(
        "cancel",
        this.handleDialogCancel,
      );
    }
  }

  disconnect() {
    window.removeEventListener("message", this.handleMessage);
    if (this.hasApproveButtonTarget) {
      this.approveButtonTarget.removeEventListener(
        "pointerdown",
        this.handleApprovePress,
      );
    }
    if (this.hasConfirmDialogTarget) {
      this.confirmDialogTarget.removeEventListener(
        "cancel",
        this.handleDialogCancel,
      );
      if (this.confirmDialogTarget.open) this.confirmDialogTarget.close();
    }
    this.disarmApprove();
    this.queue = [];
    this.pending = null;
  }

  approve(event) {
    event?.preventDefault();
    if (!this.approveArmed) return;
    // A pointer click whose press began before Approve was armed is not a
    // decision. Keyboard activation (detail 0) needs only the delay.
    if (event?.detail > 0 && this.approvePressedAt < this.armedAt) return;
    this.resolvePending({ confirmed: true });
  }

  decline(event) {
    event?.preventDefault();
    this.resolvePending({ declined: true });
  }

  handleApprovePress(event) {
    this.approvePressedAt = event.timeStamp;
  }

  handleDialogCancel(event) {
    event.preventDefault();
    this.resolvePending({ declined: true });
  }

  handleMessage(event) {
    if (!this.hasFrameTarget) return;
    if (event.source !== this.frameTarget.contentWindow) return;

    const message = this.parse(event.data);
    if (!message) return;

    if (message.id === undefined || message.id === null) {
      this.handleNotification(message);
    } else {
      this.forward(message, {});
    }
  }

  parse(data) {
    let message = data;
    try {
      const raw = typeof data === "string" ? data : JSON.stringify(data);
      if (!raw || raw.length > MAX_MESSAGE_BYTES) return null;
      if (typeof data === "string") message = JSON.parse(data);
    } catch {
      return null;
    }
    if (!message || typeof message !== "object" || Array.isArray(message))
      return null;
    if (message.jsonrpc !== "2.0" || typeof message.method !== "string")
      return null;
    const idType = typeof message.id;
    if (
      message.id !== undefined &&
      message.id !== null &&
      idType !== "string" &&
      idType !== "number"
    )
      return null;
    return message;
  }

  handleNotification(message) {
    if (message.method !== "ui/size-changed") return;
    const height = Number(message.params?.height);
    if (!Number.isFinite(height)) return;
    const clamped = Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, height));
    this.frameTarget.style.height = `${Math.round(clamped)}px`;
  }

  async forward(message, { confirmed = false, declined = false }) {
    let response;
    try {
      response = await this.post({ message, confirmed, declined });
    } catch {
      response = this.errorResponse(message.id, -32603, "Internal error");
    }

    if (response?.error?.code === CONFIRMATION_REQUIRED && !declined) {
      this.enqueueConfirmation(message, response.error.data || {});
      return;
    }

    this.learnWriteTools(message, response);
    this.reply(response);

    if (
      message.method === "tools/call" &&
      response?.result &&
      !response.result.isError &&
      response.result.structuredContent?.success !== false
    ) {
      const tool = message.params?.name;
      if (this.isWrite(tool, confirmed)) this.notifyDataChanged(tool);
    }
  }

  async post(body) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content;
    const res = await fetch(this.bridgeUrlValue, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        ...(token ? { "X-CSRF-Token": token } : {}),
      },
      body: JSON.stringify(body),
    });
    const json = await res.json();
    if (!json || typeof json !== "object") throw new Error("Bad response");
    return json;
  }

  enqueueConfirmation(message, data) {
    this.queue.push({ message, data });
    if (!this.pending) this.showNextConfirmation();
  }

  showNextConfirmation() {
    this.pending = this.queue.shift() || null;
    if (!this.pending || !this.hasConfirmDialogTarget) return;

    const { data } = this.pending;
    if (this.hasConfirmMessageTarget) {
      this.confirmMessageTarget.textContent = String(
        data.summary || data.tool || "",
      );
    }
    this.renderDetails(data.details);
    this.disarmApprove();
    if (!this.confirmDialogTarget.open) this.confirmDialogTarget.showModal();
    if (this.hasDeclineButtonTarget) this.declineButtonTarget.focus();
    this.armTimer = setTimeout(() => this.armApprove(), APPROVE_ARM_DELAY_MS);
  }

  // Rows come from the server's description of the call's real arguments.
  renderDetails(details) {
    if (!this.hasConfirmDetailsTarget) return;
    const list = this.confirmDetailsTarget;
    list.replaceChildren();
    const rows = Array.isArray(details) ? details.slice(0, MAX_DETAIL_ROWS) : [];
    for (const row of rows) {
      if (!row || typeof row !== "object") continue;
      const item = this.buildDetailRow(String(row.label ?? ""), String(row.value ?? ""));
      if (item) list.appendChild(item);
    }
    list.classList.toggle("hidden", list.childElementCount === 0);
  }

  buildDetailRow(label, value) {
    if (!this.hasConfirmDetailRowTarget) return null;
    const fragment = this.confirmDetailRowTarget.content.cloneNode(true);
    const row = fragment.firstElementChild;
    if (!row) return null;
    const term = row.querySelector("dt");
    const description = row.querySelector("dd");
    if (term) term.textContent = label;
    if (description) description.textContent = value;
    return row;
  }

  disarmApprove() {
    clearTimeout(this.armTimer);
    this.armTimer = null;
    this.approveArmed = false;
    this.armedAt = Number.POSITIVE_INFINITY;
    if (this.hasApproveButtonTarget) this.approveButtonTarget.disabled = true;
  }

  armApprove() {
    this.armTimer = null;
    if (!this.pending) return;
    this.approveArmed = true;
    this.armedAt = performance.now();
    if (this.hasApproveButtonTarget) this.approveButtonTarget.disabled = false;
  }

  resolvePending(decision) {
    const current = this.pending;
    if (!current) return;
    this.pending = null;
    this.disarmApprove();
    if (this.hasConfirmDialogTarget && this.confirmDialogTarget.open) {
      this.confirmDialogTarget.close();
    }
    this.forward(current.message, decision);
    this.showNextConfirmation();
  }

  // tools/list marks each tool's write flag; remember it when the app asks.
  learnWriteTools(message, response) {
    const tools = response?.result?.tools;
    if (message.method !== "tools/list" || !Array.isArray(tools)) return;
    this.writeTools = new Set(tools.filter((t) => t.write).map((t) => t.name));
  }

  isWrite(tool, confirmed) {
    if (typeof tool !== "string") return false;
    if (confirmed) return true;
    if (this.writeTools) return this.writeTools.has(tool);
    return !tool.startsWith("get_") && !tool.startsWith("preview_");
  }

  notifyDataChanged(tool) {
    this.reply({
      jsonrpc: "2.0",
      method: "notifications/sure/data_changed",
      params: { tool },
    });
    window.dispatchEvent(
      new CustomEvent("mini-app:data-changed", { detail: { tool } }),
    );
  }

  reply(payload) {
    this.frameTarget?.contentWindow?.postMessage(payload, "*");
  }

  errorResponse(id, code, message) {
    return { jsonrpc: "2.0", id, error: { code, message } };
  }
}
