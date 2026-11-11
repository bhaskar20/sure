const $ = (id) => document.getElementById(id);

function setStatus(text, isError) {
  const status = $("status");
  status.textContent = text;
  status.classList.toggle("error", Boolean(isError));
}

function describeError(error) {
  const codes = window.SureMiniApp.ErrorCodes;
  switch (error.code) {
    case codes.PERMISSION_DENIED:
      return `Not allowed: ask a family admin to grant ${error.data?.permission}.`;
    case codes.APP_DISABLED:
      return "This app has been disabled.";
    case codes.NOT_EMBEDDED:
      return "Open this page from Sure's Apps page.";
    default:
      return error.message || String(error);
  }
}

async function main() {
  let sure;
  try {
    sure = await window.SureMiniApp.connect();
  } catch (error) {
    setStatus(describeError(error), true);
    return;
  }

  $("title").textContent = sure.app.name;
  setStatus(`Connected as ${sure.user.name} (${sure.user.role}).`);

  const list = $("permissions");
  if (sure.permissions.length === 0) {
    const item = document.createElement("li");
    item.textContent = "No permissions granted.";
    list.append(item);
  }
  for (const permission of sure.permissions) {
    const item = document.createElement("li");
    item.textContent = permission;
    list.append(item);
  }

  const loadButton = $("load-accounts");
  loadButton.disabled = !sure.can("accounts:read");
  loadButton.addEventListener("click", async () => {
    const accounts = $("accounts");
    accounts.replaceChildren();
    try {
      const result = await sure.accounts.list();
      for (const account of result.accounts) {
        const item = document.createElement("li");
        item.textContent = `${account.name}: ${account.balance_formatted}`;
        accounts.append(item);
      }
    } catch (error) {
      setStatus(describeError(error), true);
    }
  });

  const note = $("note");
  const saved = await sure.storage.get("settings", "note");
  note.value = typeof saved?.text === "string" ? saved.text : "";
  note.disabled = false;
  $("save-note").disabled = false;

  $("note-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
      await sure.storage.set("settings", "note", { text: note.value });
      $("note-status").textContent = "Saved.";
    } catch (error) {
      $("note-status").textContent = describeError(error);
    }
  });
}

main();
