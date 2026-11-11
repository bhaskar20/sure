/*!
 * @sure/miniapp-sdk — the bridge client for Sure mini apps.
 *
 * A dependency-free classic script. Load it with <script src="sure-miniapp.js">
 * and use window.SureMiniApp, or import it as ESM through index.mjs.
 *
 * The mini app runs in a sandboxed iframe with an opaque origin. It talks to
 * Sure only through JSON-RPC 2.0 messages posted to window.parent; the host
 * checks every request against the permissions the family admin granted.
 */
(() => {
  const globalScope =
    typeof globalThis !== "undefined"
      ? globalThis
      : typeof window !== "undefined"
        ? window
        : undefined;
  if (!globalScope) return;
  if (globalScope.SureMiniApp?.version) return;

  const SDK_VERSION = "1.0.0";
  const PROTOCOL_VERSION = "2026-11-11";
  const DEFAULT_TIMEOUT_MS = 30000;

  const ErrorCodes = Object.freeze({
    PARSE_ERROR: -32700,
    INVALID_REQUEST: -32600,
    METHOD_NOT_FOUND: -32601,
    INVALID_PARAMS: -32602,
    INTERNAL_ERROR: -32603,
    TOOL_ERROR: -32000,
    PERMISSION_DENIED: -32003,
    APP_DISABLED: -32004,
    CONFIRMATION_REQUIRED: -32005,
    DECLINED: -32006,
    AI_UNAVAILABLE: -32007,
    AI_FAILED: -32008,
    RATE_LIMITED: -32029,
    TIMEOUT: -32098,
    NOT_EMBEDDED: -32099,
  });

  const EVENT_ALIASES = Object.freeze({
    dataChanged: "notifications/sure/data_changed",
  });

  class SureMiniAppError extends Error {
    constructor(code, message, data) {
      super(message || `Sure mini app error ${code}`);
      this.name = "SureMiniAppError";
      this.code = code;
      this.data = data === undefined ? null : data;
    }
  }

  function isObject(value) {
    return value !== null && typeof value === "object";
  }

  function toolResultValue(name, result) {
    if (!isObject(result)) return result;

    if (result.isError) {
      const text = firstText(result);
      throw new SureMiniAppError(
        ErrorCodes.TOOL_ERROR,
        text || `The tool ${name} failed.`,
        { tool: name },
      );
    }

    if (result.structuredContent !== undefined) return result.structuredContent;

    const text = firstText(result);
    if (text === undefined) return null;
    try {
      return JSON.parse(text);
    } catch (_error) {
      return text;
    }
  }

  function firstText(result) {
    const content = Array.isArray(result.content) ? result.content : [];
    const item = content.find(
      (entry) => isObject(entry) && entry.type === "text",
    );
    return item ? item.text : undefined;
  }

  function compact(args) {
    const out = {};
    if (!isObject(args)) return out;
    for (const key of Object.keys(args)) {
      if (args[key] !== undefined) out[key] = args[key];
    }
    return out;
  }

  class Transport {
    constructor(target) {
      this.target = target;
      this.nextId = 1;
      this.pending = new Map();
      this.listeners = new Map();
      this.onMessage = this.onMessage.bind(this);
      globalScope.addEventListener("message", this.onMessage);
    }

    request(method, params, options) {
      const id = this.nextId++;
      const timeout =
        options && options.timeout !== undefined
          ? options.timeout
          : DEFAULT_TIMEOUT_MS;

      return new Promise((resolve, reject) => {
        const entry = { resolve, reject, timer: null };
        if (timeout && timeout > 0) {
          entry.timer = setTimeout(() => {
            this.pending.delete(id);
            reject(
              new SureMiniAppError(
                ErrorCodes.TIMEOUT,
                `Sure did not answer ${method} within ${timeout} ms.`,
                { method },
              ),
            );
          }, timeout);
        }
        this.pending.set(id, entry);
        this.post({ jsonrpc: "2.0", id, method, params: params || {} });
      });
    }

    notify(method, params) {
      this.post({ jsonrpc: "2.0", method, params: params || {} });
    }

    post(message) {
      // The frame has an opaque origin and cannot name the host's origin, so
      // the target is "*". Replies are trusted only when they come from
      // window.parent (see onMessage).
      this.target.postMessage(message, "*");
    }

    on(method, handler) {
      if (!this.listeners.has(method)) this.listeners.set(method, new Set());
      this.listeners.get(method).add(handler);
      return () => this.listeners.get(method)?.delete(handler);
    }

    onMessage(event) {
      if (event.source !== this.target) return;
      const message = event.data;
      if (!isObject(message) || message.jsonrpc !== "2.0") return;

      if (message.id !== undefined && message.id !== null && !message.method) {
        const entry = this.pending.get(message.id);
        if (!entry) return;
        this.pending.delete(message.id);
        if (entry.timer) clearTimeout(entry.timer);

        if (message.error) {
          const error = message.error;
          entry.reject(
            new SureMiniAppError(error.code, error.message, error.data),
          );
        } else {
          entry.resolve(message.result);
        }
        return;
      }

      if (typeof message.method === "string") {
        const handlers = this.listeners.get(message.method);
        if (!handlers) return;
        for (const handler of Array.from(handlers)) {
          try {
            handler(message.params || {}, message);
          } catch (error) {
            console.error("[SureMiniApp] event handler failed", error);
          }
        }
      }
    }

    close() {
      globalScope.removeEventListener("message", this.onMessage);
      for (const entry of this.pending.values()) {
        if (entry.timer) clearTimeout(entry.timer);
        entry.reject(
          new SureMiniAppError(ErrorCodes.INTERNAL_ERROR, "Connection closed."),
        );
      }
      this.pending.clear();
      this.listeners.clear();
    }
  }

  function startAutoResize(transport) {
    if (typeof ResizeObserver === "undefined" || !globalScope.document) {
      return () => {};
    }
    const doc = globalScope.document;
    let lastHeight = 0;
    let frame = null;

    // scrollHeight is never smaller than the frame's viewport, so reporting it
    // would let the frame grow but never shrink. Measure the body's own box
    // plus its margins instead; apps must not give html or body height: 100%.
    const contentHeight = () => {
      const body = doc.body;
      if (!body) return doc.documentElement.getBoundingClientRect().height;
      const style = globalScope.getComputedStyle(body);
      return (
        body.getBoundingClientRect().height +
        (Number.parseFloat(style.marginTop) || 0) +
        (Number.parseFloat(style.marginBottom) || 0)
      );
    };

    const measure = () => {
      frame = null;
      const height = Math.ceil(contentHeight());
      if (height !== lastHeight) {
        lastHeight = height;
        transport.notify("ui/size-changed", { height });
      }
    };
    const schedule = () => {
      if (frame !== null) return;
      frame =
        typeof requestAnimationFrame === "function"
          ? requestAnimationFrame(measure)
          : setTimeout(measure, 16);
    };

    const observer = new ResizeObserver(schedule);
    observer.observe(doc.documentElement);
    if (doc.body) observer.observe(doc.body);
    schedule();
    return () => observer.disconnect();
  }

  function createClient(transport, init, stopResize) {
    const permissions = Array.isArray(init.permissions)
      ? init.permissions.slice()
      : [];

    const call = (name, args) =>
      transport
        .request(
          "tools/call",
          { name, arguments: compact(args) },
          // A write may wait for a person to answer Sure's confirmation dialog.
          { timeout: 0 },
        )
        .then((result) => toolResultValue(name, result));

    const tool = (name) => (args) => call(name, args);

    const storage = {
      get(collection, key) {
        return transport
          .request("sure/storage/get", { collection, key })
          .then((result) => {
            if (!isObject(result)) return null;
            return result.data === undefined ? null : result.data;
          });
      },
      set(collection, key, data) {
        return transport.request("sure/storage/set", { collection, key, data });
      },
      delete(collection, key) {
        return transport.request("sure/storage/delete", { collection, key });
      },
      list(collection, options) {
        const opts = options || {};
        return transport
          .request(
            "sure/storage/list",
            compact({
              collection,
              prefix: opts.prefix,
              limit: opts.limit,
              cursor: opts.cursor,
            }),
          )
          .then((result) => ({
            items: result?.items || [],
            nextCursor: result?.nextCursor || null,
          }));
      },
    };

    const aiCapability = isObject(init.capabilities?.ai)
      ? init.capabilities.ai
      : null;
    const ai = Object.freeze({
      // Only set when the app holds ai:use.
      available: Boolean(aiCapability?.available),
      // True when prompts run on this computer (Sure Desktop's Local AI).
      local: Boolean(aiCapability?.local),
      model: aiCapability?.model || null,
      complete(prompt, options) {
        const opts = options || {};
        return transport.request(
          "sure/ai/complete",
          compact({ prompt, instructions: opts.instructions }),
          // A local model can take a minute on a long prompt.
          { timeout: opts.timeout === undefined ? 0 : opts.timeout },
        );
      },
    });

    return Object.freeze({
      info: init,
      protocolVersion: init.protocolVersion,
      bridgeVersion: init.bridgeVersion,
      app: init.app || null,
      user: init.user || null,
      family: init.family || null,
      permissions: Object.freeze(permissions),
      writePolicy: init.writePolicy || "confirm",
      capabilities: init.capabilities || {},

      can(permission) {
        return permissions.includes(permission);
      },

      request(method, params, options) {
        return transport.request(method, params, options);
      },
      call,
      ping() {
        return transport.request("ping", {});
      },

      tools: Object.freeze({
        list() {
          return transport
            .request("tools/list", {})
            .then((result) => result?.tools || []);
        },
      }),

      accounts: Object.freeze({
        list: tool("get_accounts"),
        holdings: tool("get_holdings"),
        valuations: tool("get_valuations"),
        recordValuation: tool("record_valuation"),
        setOpeningBalance: tool("set_opening_balance"),
      }),
      transactions: Object.freeze({
        list: tool("get_transactions"),
        recurring: tool("get_recurring_transactions"),
        uncategorized: tool("get_uncategorized_transactions"),
        transferCandidates: tool("get_transfer_match_candidates"),
        create: tool("create_transaction"),
        update: tool("update_transaction"),
        delete: tool("delete_transaction"),
        matchTransfer: tool("match_transfer"),
        unmatchTransfer: tool("unmatch_transfer"),
        updateTransfer: tool("update_transfer"),
        reviewTransfer: tool("review_transfer"),
      }),
      categories: Object.freeze({
        list: tool("get_categories"),
        create: tool("create_category"),
        update: tool("update_category"),
        delete: tool("delete_category"),
      }),
      tags: Object.freeze({
        list: tool("get_tags"),
        create: tool("create_tag"),
        update: tool("update_tag"),
      }),
      merchants: Object.freeze({
        list: tool("get_merchants"),
      }),
      rules: Object.freeze({
        list: tool("get_rules"),
        options: tool("get_rule_options"),
        preview: tool("preview_rule"),
        create: tool("create_rule"),
        update: tool("update_rule"),
        apply: tool("apply_rule"),
      }),
      reports: Object.freeze({
        balanceSheet: tool("get_balance_sheet"),
        incomeStatement: tool("get_income_statement"),
        budget: tool("get_budget"),
        insights: tool("get_insights"),
      }),
      budgets: Object.freeze({
        get: tool("get_budget"),
        update: tool("update_budget"),
      }),
      goals: Object.freeze({
        create: tool("create_goal"),
      }),

      storage: Object.freeze(storage),
      ai,

      on(event, handler) {
        return transport.on(EVENT_ALIASES[event] || event, handler);
      },

      close() {
        stopResize();
        transport.close();
      },
    });
  }

  let connection = null;

  function connect(options) {
    if (connection) return connection;
    const opts = options || {};

    const parent = globalScope.parent;
    if (!parent || parent === globalScope) {
      return Promise.reject(
        new SureMiniAppError(
          ErrorCodes.NOT_EMBEDDED,
          "This page is not running inside Sure. Open it from the Apps page.",
        ),
      );
    }

    const transport = new Transport(parent);
    connection = transport
      .request(
        "ui/initialize",
        {
          protocolVersion: PROTOCOL_VERSION,
          clientInfo: { name: "@sure/miniapp-sdk", version: SDK_VERSION },
          appCapabilities: {},
        },
        { timeout: opts.timeout },
      )
      .then((init) => {
        const stopResize =
          opts.autoResize === false ? () => {} : startAutoResize(transport);
        return createClient(transport, init || {}, stopResize);
      })
      .catch((error) => {
        transport.close();
        connection = null;
        throw error;
      });

    return connection;
  }

  globalScope.SureMiniApp = Object.freeze({
    version: SDK_VERSION,
    protocolVersion: PROTOCOL_VERSION,
    ErrorCodes,
    SureMiniAppError,
    connect,
  });
})();
