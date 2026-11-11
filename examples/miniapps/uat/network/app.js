const DECLARED_URL = "https://api.github.com/zen";

async function probe(url) {
  const mark = UAT.violations.length;
  const res = await UAT.settle(fetch(url, { cache: "no-store" }));
  const violations = await UAT.violationsSince(mark, "connect-src");
  let body = null;
  if (res.ok) {
    const text = await UAT.settle(res.value.text());
    body = text.ok ? text.value.slice(0, 200) : text.error;
  }
  return {
    url,
    cspViolation: violations.length > 0,
    violations,
    fetch: res.ok
      ? { ok: true, status: res.value.status, type: res.value.type, body }
      : { ok: false, error: res.error },
  };
}

function blockedCheck(id, title, url) {
  UAT.define(
    id,
    title,
    "fetch rejects AND a connect-src securitypolicyviolation fires.",
    async () => {
      const raw = await probe(url);
      if (raw.fetch.ok)
        return UAT.fail(
          `NOT blocked: ${url} answered ${raw.fetch.status}.`,
          raw,
        );
      return UAT.verdict(
        raw.cspViolation,
        raw.cspViolation
          ? `Blocked by CSP connect-src: ${url}`
          : `fetch failed but no CSP violation reported: ${url}`,
        raw,
      );
    },
  );
}

function defineChecks() {
  UAT.define(
    "N01",
    `Declared origin allowed (${DECLARED_URL})`,
    "No connect-src CSP violation. NETWORK line: HTTP 200 when online; a network error with no CSP violation (offline) still counts as PASS for CSP.",
    async () => {
      const raw = await probe(DECLARED_URL);
      if (raw.cspViolation)
        return UAT.fail("Blocked by CSP although the origin is declared.", raw);
      const network = raw.fetch.ok
        ? `HTTP ${raw.fetch.status}: ${raw.fetch.body}`
        : `network error (offline or remote refused): ${raw.fetch.error.message}`;
      return UAT.pass(`CSP allowed. NETWORK: ${network}`, raw);
    },
  );

  blockedCheck(
    "N02",
    "Undeclared origin blocked (https://example.com)",
    "https://example.com/",
  );
  blockedCheck(
    "N03",
    "Sibling host of declared origin blocked (https://github.com)",
    "https://github.com/",
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
    `Connected as ${sure.user?.name}. Frame origin: ${JSON.stringify(window.origin)}. Permissions: [${sure.permissions.join(", ")}]. Declared network: https://api.github.com`,
  );
  defineChecks();
  UAT.render();
}

main();
