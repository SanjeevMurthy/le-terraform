// LinkForge web tier.
//
// Every request below is a RELATIVE path. That is deliberate: the Ingress
// serves the web tier and the API tier from the same hostname, routing /api
// and /r to the API Service and everything else here. Same origin means no
// CORS configuration, and no API hostname baked into the image at build time.

const $ = (id) => document.getElementById(id);

async function api(path, options) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      detail = body.detail || body.error || detail;
    } catch (_) { /* response was not JSON */ }
    throw new Error(detail);
  }
  return res.status === 204 ? null : res.json();
}

function showError(message) {
  const el = $("error");
  if (!message) { el.hidden = true; return; }
  el.textContent = message;
  el.hidden = false;
}

function render(links) {
  const table = $("links");
  const empty = $("empty");
  const body = $("links-body");
  body.replaceChildren();

  if (!links.length) {
    empty.textContent = "No links yet. Shorten one above.";
    empty.hidden = false;
    table.hidden = true;
    return;
  }

  empty.hidden = true;
  table.hidden = false;

  for (const link of links) {
    const shortUrl = `${window.location.origin}${link.short_path}`;
    const tr = document.createElement("tr");

    const codeCell = document.createElement("td");
    const anchor = document.createElement("a");
    anchor.href = link.short_path;
    anchor.textContent = `/r/${link.code}`;
    anchor.target = "_blank";
    anchor.rel = "noopener";
    codeCell.append(anchor);

    const targetCell = document.createElement("td");
    targetCell.className = "target";
    targetCell.title = link.target_url;
    targetCell.textContent = link.target_url;

    const clicksCell = document.createElement("td");
    clicksCell.className = "num";
    clicksCell.textContent = link.clicks;

    const actions = document.createElement("td");
    actions.className = "actions";

    const copy = document.createElement("button");
    copy.className = "link";
    copy.type = "button";
    copy.textContent = "Copy";
    copy.addEventListener("click", async () => {
      await navigator.clipboard.writeText(shortUrl);
      copy.textContent = "Copied";
      setTimeout(() => { copy.textContent = "Copy"; }, 1200);
    });

    const del = document.createElement("button");
    del.className = "link danger";
    del.type = "button";
    del.textContent = "Delete";
    del.addEventListener("click", async () => {
      try {
        await api(`/api/links/${link.code}`, { method: "DELETE" });
        await load();
      } catch (err) { showError(err.message); }
    });

    actions.append(copy, del);
    tr.append(codeCell, targetCell, clicksCell, actions);
    body.append(tr);
  }
}

async function load() {
  try {
    render(await api("/api/links"));
    showError("");
  } catch (err) {
    $("empty").textContent = "Could not reach the API.";
    $("empty").hidden = false;
    showError(err.message);
  }
}

async function loadVersion() {
  try {
    const info = await api("/api/version");
    $("version").textContent = info.version;
    $("pod").textContent = info.pod;
  } catch (_) {
    $("version").textContent = "unreachable";
  }
}

$("create-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const btn = $("submit-btn");
  const input = $("target");
  btn.disabled = true;
  try {
    await api("/api/links", {
      method: "POST",
      body: JSON.stringify({ target_url: input.value }),
    });
    input.value = "";
    showError("");
    await load();
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
  }
});

$("refresh-btn").addEventListener("click", () => { load(); loadVersion(); });

load();
loadVersion();
