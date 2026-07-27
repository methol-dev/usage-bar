// popup：逐 provider 显示「app 里怎么配的 + 最近一次同步结果」+ 手动触发一次同步。
// 不显示用量数字本身 —— 那在菜单栏 app 里看。同步与配置由 background 的心跳/事件负责，
// 用户通常无需点这个按钮。
//
// 为什么要逐 provider 展示：把两个 provider 合并成一行「Synced ✓」，会让 Codex 的失败
// （比如根本没开 chatgpt.com 标签页）被 Claude 的成功掩盖，用户看着扩展显示同步成功、
// app 里却一直没数据，无从下手。这里让每个 provider 的状态各自说话。

const statusEl = document.getElementById("status");
const providersEl = document.getElementById("providers");
const channelEl = document.getElementById("channel");
const button = document.getElementById("sync");

const CHANNEL_FRESH_MS = 5 * 60 * 1000; // 与 background 的 CONTROL_STALE_MS 一致。

function ago(ms) {
  if (typeof ms !== "number") return "never";
  const secs = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (secs < 60) return "just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return mins + " min ago";
  const hours = Math.round(mins / 60);
  if (hours < 24) return hours + "h ago";
  return Math.round(hours / 24) + "d ago";
}

// 一次取数结果 → 展示文案 + severity（决定颜色）。
function describeResult(p) {
  const r = p.result;
  if (!r || !r.status) return { text: "Never synced", tone: "idle" };
  switch (r.status) {
    case "ok":
      return { text: "Synced " + ago(r.at), tone: "ok" };
    case "logged_out":
      return { text: "Signed out of " + p.host, tone: "bad" };
    case "no_session":
      // 上次取数时没标签页；但此刻可能已经开好了（tabs.onUpdated 会触发同步，只是还没落地）——
      // 那时再说「没开标签页」就与用户眼前的事实矛盾了。
      return p.tabOpen
        ? { text: "Waiting for next sync", tone: "idle" }
        : { text: "No " + p.host + " tab open", tone: "warn" };
    case "error":
      return { text: "Sync failed" + (r.error ? " (" + r.error + ")" : ""), tone: "bad" };
    default:
      return { text: String(r.status), tone: "idle" };
  }
}

// app 侧配置 + 补充说明行。
function describeMeta(p) {
  const parts = [];
  const c = p.control;
  if (!c) {
    parts.push("Waiting for the app");
  } else if (!c.supported) {
    // app 发来的控制信封里没有这个 provider —— 是 app 版本旧 / 没有该 provider，
    // 与用户主动关掉 Web 源（paused）不是一回事，别让人以为是自己设置错了。
    parts.push("Not managed by this app version");
  } else if (c.paused) {
    parts.push("Web source off in the app");
  } else {
    const mins = c.intervalSeconds ? Math.max(1, Math.round(c.intervalSeconds / 60)) : null;
    parts.push("Web source on" + (mins ? " · every " + mins + " min" : ""));
  }
  // 当前不是 ok，但历史上成功过 → 告诉用户 app 里那份数据有多旧（app 侧超 1h 会提示陈旧）。
  const r = p.result;
  if (r && r.status !== "ok" && typeof p.lastOkAt === "number") {
    parts.push("app has data from " + ago(p.lastOkAt));
  }
  // 有意不回传 app 的情形（no_session）——说明「为什么 app 那边没变化」。
  if (r && r.sent === false) parts.push("kept the app's last good data");
  return parts.join(" · ");
}

function renderProviders(providers) {
  providersEl.textContent = "";
  for (const p of providers || []) {
    const { text, tone } = describeResult(p);

    const row = document.createElement("div");
    row.className = "row";

    const head = document.createElement("div");
    head.className = "row-head";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = p.label || p.id;
    const state = document.createElement("span");
    state.className = "state " + tone;
    state.textContent = text;
    head.append(name, state);

    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = describeMeta(p);

    row.append(head, meta);
    providersEl.append(row);
  }
}

function refreshStatus() {
  chrome.runtime.sendMessage({ type: "get-status" }, (st) => {
    if (chrome.runtime.lastError || !st) return;
    renderProviders(st.providers);
    // 控制通道：近期收到过 control = app 在世；否则休眠中。
    if (st.lastControlAt && Date.now() - st.lastControlAt < CHANNEL_FRESH_MS) {
      channelEl.textContent = "App connected · config synced " + ago(st.lastControlAt);
    } else {
      channelEl.textContent =
        "App not responding — sleeping" + (st.heartbeatMin ? " (retry every " + st.heartbeatMin + "m)" : "");
    }
  });
}

refreshStatus();

button.addEventListener("click", () => {
  statusEl.textContent = "Syncing…";
  button.disabled = true;
  chrome.runtime.sendMessage({ type: "sync-now" }, (resp) => {
    button.disabled = false;
    if (chrome.runtime.lastError || !resp) {
      statusEl.textContent = "Could not reach the extension worker.";
      return;
    }
    // 逐 provider 的结果直接体现在下面的行里，这里只给一句总结。
    const results = resp.results || [];
    const ok = results.filter((r) => r && r.status === "ok").length;
    statusEl.textContent =
      ok === results.length && ok > 0
        ? "Synced all providers ✓"
        : ok > 0
          ? "Synced " + ok + " of " + results.length + " — see below"
          : "Nothing synced — see below";
    refreshStatus();
  });
});
