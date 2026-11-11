const EXPECTED_PERMISSIONS = [
  "categories:read",
  "categories:write",
  "transactions:read",
];
const STORAGE_COLLECTION = "uat-probe";

const events = [];
let lastApprovedWriteAt = null;

function rawToolCall(sure, name, args, timeout) {
  return UAT.settle(
    sure.request("tools/call", { name, arguments: args || {} }, { timeout }),
  );
}

function defineChecks(sure) {
  const { ErrorCodes } = window.SureMiniApp;

  UAT.define(
    "P01",
    "ui/initialize contents",
    `app.id "uat-probe", permissions exactly ${EXPECTED_PERMISSIONS.join(", ")}, writePolicy "confirm", protocolVersion "2026-11-11", family.currency set (tester: matches the family's currency).`,
    async () => {
      const info = sure.info;
      const granted = [...(info.permissions || [])].sort();
      const problems = [];
      if (info.app?.id !== "uat-probe")
        problems.push(`app.id is ${info.app?.id}`);
      if (granted.join(",") !== EXPECTED_PERMISSIONS.join(","))
        problems.push(`permissions are [${granted.join(", ")}]`);
      if (info.writePolicy !== "confirm")
        problems.push(`writePolicy is ${info.writePolicy}`);
      if (info.protocolVersion !== "2026-11-11")
        problems.push(`protocolVersion is ${info.protocolVersion}`);
      if (typeof info.family?.currency !== "string" || !info.family.currency)
        problems.push("family.currency missing");
      const summary = `currency=${info.family?.currency}, writePolicy=${info.writePolicy}, permissions=[${granted.join(", ")}], user=${info.user?.name} (${info.user?.role})`;
      return UAT.verdict(
        problems.length === 0,
        problems.length ? `${problems.join("; ")}. ${summary}` : summary,
        info,
      );
    },
  );

  UAT.define(
    "P02",
    "tools/list lists only granted tools",
    "Every tool's permission is one of the 3 grants; includes get_transactions, get_categories, create_category; excludes get_accounts and get_tags; write flag true only for :write.",
    async () => {
      const res = await UAT.settle(sure.request("tools/list", {}));
      if (!res.ok) return UAT.fail("tools/list errored.", res.error);
      const tools = res.value?.tools || [];
      const names = tools.map((t) => t.name);
      const problems = [];
      for (const tool of tools) {
        if (!EXPECTED_PERMISSIONS.includes(tool.permission))
          problems.push(`${tool.name} has ungranted ${tool.permission}`);
        if (tool.write !== tool.permission.endsWith(":write"))
          problems.push(`${tool.name} write flag ${tool.write}`);
      }
      for (const name of [
        "get_transactions",
        "get_categories",
        "create_category",
      ]) {
        if (!names.includes(name)) problems.push(`missing ${name}`);
      }
      for (const name of ["get_accounts", "get_tags"]) {
        if (names.includes(name)) problems.push(`unexpected ${name}`);
      }
      return UAT.verdict(
        problems.length === 0,
        `${problems.length ? `${problems.join("; ")}. ` : ""}${names.length} tools: ${names.join(", ")}`,
        tools.map((t) => ({
          name: t.name,
          permission: t.permission,
          write: t.write,
        })),
      );
    },
  );

  UAT.define(
    "P03",
    "get_transactions works",
    "tools/call get_transactions {page_size: 5} returns a result (no isError) with a transactions array.",
    async () => {
      const res = await rawToolCall(sure, "get_transactions", { page_size: 5 });
      if (!res.ok) return UAT.fail(`Error ${res.error.code}.`, res.error);
      const content = res.value?.structuredContent;
      const ok = !res.value?.isError && Array.isArray(content?.transactions);
      return UAT.verdict(
        ok,
        ok
          ? `${content.transactions.length} transactions returned (total_count=${content.total_count ?? "?"}).`
          : "No transactions array in the result.",
        res.value,
      );
    },
  );

  UAT.define(
    "P04",
    "get_accounts and get_tags refused",
    "Both calls fail with -32003 PERMISSION_DENIED; data.permission is accounts:read / tags:read. (-32601 would mean the tool is not available to this user at all.)",
    async () => {
      const accounts = await rawToolCall(sure, "get_accounts", {});
      const tags = await rawToolCall(sure, "get_tags", {});
      const denied = (res, permission) =>
        !res.ok &&
        res.error.code === ErrorCodes.PERMISSION_DENIED &&
        res.error.data?.permission === permission;
      const ok = denied(accounts, "accounts:read") && denied(tags, "tags:read");
      const code = (res) => (res.ok ? "succeeded" : res.error.code);
      return UAT.verdict(
        ok,
        `get_accounts → ${code(accounts)}, get_tags → ${code(tags)}`,
        { get_accounts: accounts, get_tags: tags },
      );
    },
  );

  UAT.define(
    "P05",
    "Unknown method and unknown tool",
    'Method "sure/does_not_exist" → -32601; tools/call "no_such_tool" → -32601.',
    async () => {
      const method = await UAT.settle(sure.request("sure/does_not_exist", {}));
      const tool = await rawToolCall(sure, "no_such_tool", {});
      const notFound = (res) =>
        !res.ok && res.error.code === ErrorCodes.METHOD_NOT_FOUND;
      const code = (res) => (res.ok ? "succeeded" : res.error.code);
      return UAT.verdict(
        notFound(method) && notFound(tool),
        `unknown method → ${code(method)}, unknown tool → ${code(tool)}`,
        { method, tool },
      );
    },
  );

  UAT.define(
    "P06",
    "Storage round trip and 256 KB limit",
    "set → get returns same data → list (prefix) includes key → delete {deleted:true} → get returns null → 300 KB set fails with -32602 → 200 KB set succeeds (then cleaned up).",
    async () => {
      const key = `rt-${Date.now()}`;
      const data = { n: 42, text: "héllo ✓", list: [1, 2, 3] };
      const steps = {};
      steps.set = await UAT.settle(
        sure.storage.set(STORAGE_COLLECTION, key, data),
      );
      steps.get = await UAT.settle(sure.storage.get(STORAGE_COLLECTION, key));
      steps.list = await UAT.settle(
        sure.storage.list(STORAGE_COLLECTION, { prefix: "rt-", limit: 200 }),
      );
      steps.delete = await UAT.settle(
        sure.storage.delete(STORAGE_COLLECTION, key),
      );
      steps.getAfterDelete = await UAT.settle(
        sure.storage.get(STORAGE_COLLECTION, key),
      );
      steps.oversized = await UAT.settle(
        sure.storage.set(STORAGE_COLLECTION, `${key}-big`, {
          blob: "x".repeat(300 * 1024),
        }),
      );
      steps.nearLimit = await UAT.settle(
        sure.storage.set(STORAGE_COLLECTION, `${key}-200k`, {
          blob: "x".repeat(200 * 1024),
        }),
      );
      await UAT.settle(sure.storage.delete(STORAGE_COLLECTION, `${key}-200k`));

      const problems = [];
      if (!steps.set.ok) problems.push("set failed");
      // Storage is jsonb: values round-trip, object key order does not.
      if (canonical(steps.get.value) !== canonical(data))
        problems.push("get returned different data");
      if (!steps.list.value?.items?.some((item) => item.key === key))
        problems.push("list missing key");
      if (steps.delete.value?.deleted !== true)
        problems.push("delete did not report deleted:true");
      if (!steps.getAfterDelete.ok || steps.getAfterDelete.value !== null)
        problems.push("get after delete not null");
      if (
        steps.oversized.ok ||
        steps.oversized.error.code !== ErrorCodes.INVALID_PARAMS
      )
        problems.push(
          `300 KB set → ${steps.oversized.ok ? "accepted" : steps.oversized.error.code}`,
        );
      if (!steps.nearLimit.ok) problems.push("200 KB set rejected");

      // Keep the raw output readable: drop the big payloads.
      if (steps.nearLimit.ok) steps.nearLimit.value = "(200 KB record saved)";
      return UAT.verdict(
        problems.length === 0,
        problems.length
          ? problems.join("; ")
          : "set/get/list/delete round trip OK; 300 KB rejected with -32602; 200 KB accepted.",
        steps,
      );
    },
  );

  UAT.define(
    "P07",
    "ui/size-changed resizes the frame",
    "Showing a 1600px block grows the frame (window.innerHeight) by ≥ 1500px within 1.5 s; hiding it shrinks the frame again.",
    async (note) => {
      const block = document.getElementById("tall-block");
      block.hidden = true;
      await UAT.sleep(800);
      const before = window.innerHeight;
      note("showing tall block…");
      block.hidden = false;
      await UAT.sleep(1500);
      const tall = window.innerHeight;
      note("hiding tall block…");
      block.hidden = true;
      await UAT.sleep(1500);
      const after = window.innerHeight;
      const ok = tall - before >= 1500 && after < tall;
      return UAT.verdict(
        ok,
        `innerHeight before=${before}px, with block=${tall}px, after=${after}px`,
        { before, tall, after, scrollHeight: document.body.scrollHeight },
      );
    },
  );

  UAT.define(
    "P08",
    "create_category with approval",
    "Sure shows its own confirmation dialog (outside the frame) listing the category name. Tester clicks Allow. Call succeeds (success !== false), category appears in Sure.",
    async (note) => {
      const name = `UAT probe ${new Date().toISOString().slice(0, 19)}`;
      note(`waiting for Sure's dialog — click ALLOW (creating "${name}")`);
      const res = await rawToolCall(sure, "create_category", { name }, 0);
      if (!res.ok)
        return UAT.fail(`Error ${res.error.code}: ${res.error.message}`, res);
      const content = res.value?.structuredContent;
      const ok = !res.value?.isError && content?.success !== false;
      if (ok) lastApprovedWriteAt = events.length;
      return UAT.verdict(
        ok,
        ok ? `Created "${name}". Now run P09.` : "Tool reported failure.",
        res.value,
      );
    },
    { manual: true },
  );

  UAT.define(
    "P09",
    "dataChanged after the approved write",
    "After P08, a notifications/sure/data_changed with tool create_category arrives (waits up to 3 s).",
    async () => {
      if (lastApprovedWriteAt === null)
        return UAT.fail("Run P08 (and approve) first.", events);
      for (let i = 0; i < 30; i++) {
        const hit = events
          .slice(lastApprovedWriteAt)
          .find((e) => e.tool === "create_category");
        if (hit)
          return UAT.pass(
            `Received dataChanged ${JSON.stringify(hit)}`,
            events,
          );
        await UAT.sleep(100);
      }
      return UAT.fail("No dataChanged event for create_category.", events);
    },
    { manual: true },
  );

  UAT.define(
    "P10",
    "create_category declined",
    "Sure shows the confirmation dialog. Tester clicks Decline (or presses Esc). Call fails with -32006 DECLINED; no category is created and no dataChanged arrives.",
    async (note) => {
      const name = `UAT probe DECLINED ${new Date().toISOString().slice(0, 19)}`;
      const mark = events.length;
      note(
        `waiting for Sure's dialog — click DECLINE (would create "${name}")`,
      );
      const res = await rawToolCall(sure, "create_category", { name }, 0);
      await UAT.sleep(500);
      const changed = events.slice(mark);
      const ok =
        !res.ok &&
        res.error.code === ErrorCodes.DECLINED &&
        changed.length === 0;
      return UAT.verdict(
        ok,
        `${res.ok ? "call succeeded" : `error ${res.error.code}`}, dataChanged events since: ${changed.length}`,
        { response: res, dataChangedSince: changed },
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
  sure.on("dataChanged", (params) => {
    events.push({ ...params, receivedAt: new Date().toISOString() });
  });
  UAT.setStatus(
    `Connected as ${sure.user?.name} (${sure.user?.role}). Frame origin: ${window.origin}.`,
  );
  defineChecks(sure);
  UAT.render();
}

main();

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}
