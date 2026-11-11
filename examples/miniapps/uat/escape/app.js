// Every check here passes when the attempt is blocked.

function hostOrigin() {
  const ancestors = window.location.ancestorOrigins;
  if (ancestors && ancestors.length > 0) return ancestors[0];
  // The frame's URL is served by Sure, so its URL origin is Sure's origin
  // even though the document's own origin is opaque.
  return window.location.origin;
}

function throwsCheck(id, title, expected, fn) {
  UAT.define(id, title, expected, async () => {
    const res = UAT.attempt(fn);
    return UAT.verdict(
      res.threw,
      res.threw
        ? `Blocked: ${res.error}`
        : `NOT blocked, got ${UAT.stringify(res.value)}`,
      res,
    );
  });
}

// Passes when the fetch fails and a connect-src CSP violation is recorded.
function fetchBlockedCheck(id, title, urlFn) {
  UAT.define(
    id,
    title,
    "fetch rejects AND a securitypolicyviolation event for connect-src fires.",
    async () => {
      const url = urlFn();
      const mark = UAT.violations.length;
      const res = await UAT.settle(fetch(url, { cache: "no-store" }));
      const seen = await UAT.violationsSince(mark, "connect-src");
      const raw = {
        url,
        fetch: res.ok
          ? { status: res.value.status, type: res.value.type }
          : res.error,
        violations: seen,
      };
      if (res.ok)
        return UAT.fail(
          `NOT blocked: ${url} answered ${res.value.status}.`,
          raw,
        );
      if (seen.length === 0)
        return UAT.fail(
          `fetch failed but no CSP violation was reported (CORS or network, not CSP): ${url}`,
          raw,
        );
      return UAT.pass(`Blocked by CSP connect-src: ${url}`, raw);
    },
  );
}

function defineChecks(sure) {
  const { ErrorCodes } = window.SureMiniApp;

  UAT.define(
    "E01",
    "Frame origin is opaque",
    'window.origin is "null". (location.origin is the URL origin of Sure, shown for reference.)',
    async () => {
      const raw = {
        windowOrigin: window.origin,
        selfOrigin: self.origin,
        locationOrigin: window.location.origin,
        ancestorOrigins: window.location.ancestorOrigins
          ? Array.from(window.location.ancestorOrigins)
          : "(unsupported)",
        href: window.location.href.replace(
          /mini_app_frames\/[^/]+/,
          "mini_app_frames/<token>",
        ),
      };
      return UAT.verdict(
        window.origin === "null",
        `window.origin = ${JSON.stringify(window.origin)}; host origin = ${hostOrigin()}`,
        raw,
      );
    },
  );

  throwsCheck(
    "E02",
    "document.cookie is unreadable",
    "Reading document.cookie throws SecurityError.",
    () => document.cookie,
  );
  throwsCheck(
    "E03",
    "localStorage is unavailable",
    "Accessing window.localStorage throws SecurityError.",
    () => window.localStorage.getItem("x"),
  );
  throwsCheck(
    "E04",
    "sessionStorage is unavailable",
    "Accessing window.sessionStorage throws SecurityError.",
    () => window.sessionStorage.getItem("x"),
  );
  throwsCheck(
    "E05",
    "window.parent.document is unreachable",
    "Accessing window.parent.document throws SecurityError (cross-origin).",
    () => window.parent.document.title,
  );
  throwsCheck(
    "E06",
    "window.top.location is unreadable",
    "Reading window.top.location.href throws SecurityError.",
    () => window.top.location.href,
  );

  fetchBlockedCheck(
    "E07",
    'fetch("/api/v1/accounts") blocked',
    () => "/api/v1/accounts",
  );
  fetchBlockedCheck(
    "E08",
    'fetch(host origin + "/") blocked',
    () => `${hostOrigin()}/`,
  );
  fetchBlockedCheck(
    "E09",
    'fetch("https://example.com") blocked',
    () => "https://example.com/",
  );

  UAT.define(
    "E10",
    "External <img> blocked",
    "img onerror fires (onload does not) AND a securitypolicyviolation for img-src fires.",
    async () => {
      const mark = UAT.violations.length;
      const outcome = await new Promise((resolve) => {
        const img = new Image();
        const timer = setTimeout(() => resolve("timeout"), 5000);
        img.onload = () => {
          clearTimeout(timer);
          resolve("load");
        };
        img.onerror = () => {
          clearTimeout(timer);
          resolve("error");
        };
        img.src = `https://example.com/x.png?t=${Date.now()}`;
      });
      const seen = await UAT.violationsSince(mark, "img-src");
      const ok = outcome === "error" && seen.length > 0;
      return UAT.verdict(
        ok,
        `image ${outcome}; img-src violations: ${seen.length}`,
        { outcome, violations: seen },
      );
    },
  );

  UAT.define(
    "E11",
    "postMessage spoofing is ignored",
    "After posting a fake JSON-RPC response, a fake dialog approval and a fake data_changed to window.parent, the host sends nothing back for 3 s and no Sure dialog appears (tester: confirm no dialog). A ping afterwards still works.",
    async (note) => {
      const received = [];
      const listener = (event) => {
        if (event.source === window.parent) received.push(event.data);
      };
      window.addEventListener("message", listener);
      const spoofs = [
        {
          jsonrpc: "2.0",
          id: 424242,
          result: { confirmed: true, structuredContent: { success: true } },
        },
        { jsonrpc: "2.0", id: 1, result: { approved: true } },
        { jsonrpc: "2.0", method: "ui/confirm", params: { confirmed: true } },
        {
          jsonrpc: "2.0",
          method: "notifications/sure/data_changed",
          params: { tool: "delete_transaction" },
        },
        { type: "mini-app:confirm", decision: "approve", confirmed: true },
        JSON.stringify({ jsonrpc: "2.0", id: 424243, result: { ok: true } }),
      ];
      for (const spoof of spoofs) window.parent.postMessage(spoof, "*");
      note("listening 3 s for any reply…");
      await UAT.sleep(3000);
      window.removeEventListener("message", listener);
      const ping = await UAT.settle(sure.ping());
      const ok = received.length === 0 && ping.ok;
      return UAT.verdict(
        ok,
        `${received.length} message(s) from host after spoofs; ping afterwards ${ping.ok ? "OK" : "FAILED"}`,
        { spoofs, received, ping },
      );
    },
  );

  UAT.define(
    "E12",
    "Write tool without permission",
    "tools/call create_category → -32003 PERMISSION_DENIED with data.permission categories:write within 10 s, and NO Sure dialog appears (tester: confirm).",
    async () => {
      const res = await UAT.settle(
        sure.request(
          "tools/call",
          {
            name: "create_category",
            arguments: { name: "UAT escape MUST NOT EXIST" },
          },
          { timeout: 10000 },
        ),
      );
      const ok =
        !res.ok &&
        res.error.code === ErrorCodes.PERMISSION_DENIED &&
        res.error.data?.permission === "categories:write";
      const detail = res.ok
        ? "call SUCCEEDED (category may have been created!)"
        : `error ${res.error.code}${res.error.code === ErrorCodes.TIMEOUT ? " (timed out: was a dialog shown?)" : ""}`;
      return UAT.verdict(ok, detail, res);
    },
  );

  UAT.define(
    "E13",
    "tools/list is empty and reads are refused",
    "tools/list returns no tools; tools/call get_transactions → -32003.",
    async () => {
      const list = await UAT.settle(sure.request("tools/list", {}));
      const read = await UAT.settle(
        sure.request("tools/call", { name: "get_transactions", arguments: {} }),
      );
      const count = list.ok ? (list.value?.tools || []).length : null;
      const ok =
        count === 0 &&
        !read.ok &&
        read.error.code === ErrorCodes.PERMISSION_DENIED;
      return UAT.verdict(
        ok,
        `tools/list count=${count}; get_transactions → ${read.ok ? "succeeded" : read.error.code}`,
        { list, read },
      );
    },
  );

  UAT.define(
    "E14",
    "2 MB message is ignored",
    "A ping carrying 2 MB of padding gets no answer (SDK timeout -32098 after 5 s); a normal ping afterwards still works.",
    async (note) => {
      note("waiting 5 s for the timeout…");
      const big = await UAT.settle(
        sure.request(
          "ping",
          { padding: "x".repeat(2 * 1024 * 1024) },
          { timeout: 5000 },
        ),
      );
      const ping = await UAT.settle(sure.ping());
      const ok = !big.ok && big.error.code === ErrorCodes.TIMEOUT && ping.ok;
      return UAT.verdict(
        ok,
        `2 MB ping → ${big.ok ? "ANSWERED" : big.error.code}; normal ping → ${ping.ok ? "OK" : "FAILED"}`,
        { big, ping },
      );
    },
  );

  UAT.define(
    "E15",
    'window.open("/") (informational)',
    "Popups are allowed by the sandbox, so a tab may open. Reported as INFO. Tester: the new tab's page should itself be sandboxed (no app code runs as Sure).",
    async () => {
      const res = UAT.attempt(() => window.open("/", "_blank"));
      if (res.threw) return UAT.info(`window.open threw: ${res.error}`, res);
      const win = res.value;
      if (!win)
        return UAT.info("window.open returned null (popup blocked).", res);
      const href = UAT.attempt(() => win.location.href);
      return UAT.info(
        `window.open returned a window; reading its location ${href.threw ? `threw (${href.error})` : `gave ${href.value}`}`,
        { opened: true, href },
      );
    },
    { manual: true },
  );
}

async function main() {
  let sure;
  try {
    sure = await window.SureMiniApp.connect();
  } catch (error) {
    UAT.setStatus(`Not connected: ${UAT.stringify(error)}`, true);
    return;
  }
  UAT.setStatus(
    `Connected as ${sure.user?.name}. Frame origin: ${JSON.stringify(window.origin)}. Host origin: ${hostOrigin()}. Permissions: [${sure.permissions.join(", ")}].`,
  );
  defineChecks(sure);
  UAT.render();
}

main();
