// Tiny UAT harness shared by the uat/* mini apps (each bundle has its own
// copy). A check returns { status: "PASS" | "FAIL" | "INFO", detail, raw }.
(() => {
  const checks = [];
  const results = new Map();
  const violations = [];

  document.addEventListener("securitypolicyviolation", (event) => {
    violations.push({
      directive: event.effectiveDirective || event.violatedDirective,
      blockedURI: event.blockedURI,
      disposition: event.disposition,
    });
  });

  function errorInfo(error) {
    if (!error || typeof error !== "object") return { thrown: String(error) };
    return {
      name: error.name,
      code: error.code,
      message: error.message,
      data: error.data,
    };
  }

  function stringify(value) {
    if (value === undefined) return "(undefined)";
    try {
      const text = JSON.stringify(
        value,
        (_key, item) => (item instanceof Error ? errorInfo(item) : item),
        2,
      );
      return text.length > 6000
        ? `${text.slice(0, 6000)}\n… (${text.length} chars, truncated)`
        : text;
    } catch (_error) {
      return String(value);
    }
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // Resolves { ok, value } or { ok: false, error }; never rejects.
  async function settle(promise) {
    try {
      return { ok: true, value: await promise };
    } catch (error) {
      return { ok: false, error: errorInfo(error) };
    }
  }

  // Runs fn synchronously; reports whether it threw.
  function attempt(fn) {
    try {
      return { threw: false, value: fn() };
    } catch (error) {
      return { threw: true, error: `${error.name}: ${error.message}` };
    }
  }

  // Waits for CSP violation events (they are dispatched asynchronously) and
  // returns the ones recorded since `mark` for the given directive.
  async function violationsSince(mark, directive, waitMs = 500) {
    await sleep(waitMs);
    return violations
      .slice(mark)
      .filter((v) => !directive || v.directive === directive);
  }

  function define(id, title, expected, run, options = {}) {
    checks.push({ id, title, expected, run, manual: Boolean(options.manual) });
  }

  function updateSummary() {
    const counts = { PASS: 0, FAIL: 0, INFO: 0 };
    for (const result of results.values()) {
      counts[result.status] = (counts[result.status] || 0) + 1;
    }
    const notRun = checks.length - results.size;
    document.getElementById("uat-summary").textContent =
      `Summary: ${counts.PASS} PASS, ${counts.FAIL} FAIL, ${counts.INFO} INFO, ${notRun} not run (of ${checks.length})`;
  }

  async function runCheck(check) {
    const { line, raw, button } = check.nodes;
    button.disabled = true;
    line.className = "result running";
    line.textContent = `RESULT ${check.id}: RUNNING…`;
    raw.textContent = "";
    let result;
    try {
      result = await check.run((note) => {
        line.textContent = `RESULT ${check.id}: RUNNING… ${note}`;
      });
    } catch (error) {
      result = {
        status: "FAIL",
        detail: "Check threw unexpectedly.",
        raw: errorInfo(error),
      };
    }
    results.set(check.id, result);
    line.className = `result ${result.status.toLowerCase()}`;
    line.textContent = `RESULT ${check.id}: ${result.status} — ${result.detail}`;
    raw.textContent = stringify(result.raw);
    button.disabled = false;
    updateSummary();
    return result;
  }

  function render() {
    const list = document.getElementById("uat-checks");
    list.replaceChildren();
    for (const check of checks) {
      const item = el("li", "check");
      const head = el("div", "check-head");
      head.append(el("strong", null, `${check.id} ${check.title}`));
      if (check.manual) head.append(el("span", "tag", "needs tester"));
      const button = el("button", null, "Run");
      button.type = "button";
      head.append(button);
      item.append(head);
      item.append(el("p", "expected", `Expected: ${check.expected}`));
      const line = el("p", "result", `RESULT ${check.id}: not run`);
      const raw = el("pre", "raw");
      item.append(line, raw);
      list.append(item);
      check.nodes = { line, raw, button };
      button.addEventListener("click", () => runCheck(check));
    }

    document
      .getElementById("uat-run-all")
      .addEventListener("click", async (event) => {
        event.target.disabled = true;
        for (const check of checks) {
          if (!check.manual) await runCheck(check);
        }
        event.target.disabled = false;
      });
    updateSummary();
  }

  function setStatus(text, isError) {
    const status = document.getElementById("uat-status");
    status.textContent = text;
    status.classList.toggle("fail", Boolean(isError));
  }

  window.UAT = Object.freeze({
    define,
    render,
    setStatus,
    settle,
    attempt,
    sleep,
    stringify,
    errorInfo,
    violations,
    violationsSince,
    pass: (detail, raw) => ({ status: "PASS", detail, raw }),
    fail: (detail, raw) => ({ status: "FAIL", detail, raw }),
    info: (detail, raw) => ({ status: "INFO", detail, raw }),
    verdict: (ok, detail, raw) => ({
      status: ok ? "PASS" : "FAIL",
      detail,
      raw,
    }),
  });
})();
