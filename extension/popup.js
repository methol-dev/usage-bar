// popup：显示上次同步时间 + 控制通道状态 + 手动触发一次同步（不显示用量数字本身 —— 那在菜单栏 app 里看）。
// 同步与配置由 background 的心跳/事件负责，用户通常无需点这个按钮。
const statusEl = document.getElementById("status");
const lastSyncEl = document.getElementById("lastSync");
const channelEl = document.getElementById("channel");
const button = document.getElementById("sync");

const LABELS = {
  ok: "Synced ✓ — check the UsageBar menu bar app.",
  logged_out: "Not signed in. Open claude.ai / chatgpt.com and sign in.",
  no_session: "No provider tab open. Open claude.ai or chatgpt.com in a tab, then retry.",
  error: "Sync failed. Make sure a claude.ai / chatgpt.com tab is open and signed in.",
  skipped: "Just synced a moment ago.",
};

const CHANNEL_FRESH_MS = 5 * 60 * 1000; // 与 background 的 CONTROL_STALE_MS 一致。

function ago(ms) {
  const secs = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (secs < 60) return "just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return mins + " min ago";
  return Math.round(mins / 60) + "h ago";
}

async function refreshStatus() {
  // 走 background 的 get-status（拿到 lastSyncAt + lastControlAt + heartbeatMin）。
  chrome.runtime.sendMessage({ type: "get-status" }, (st) => {
    if (chrome.runtime.lastError || !st) return;
    lastSyncEl.textContent = st.lastSyncAt ? "Last synced: " + ago(st.lastSyncAt) : "Last synced: never";
    // 控制通道：近期收到过 control = app 在世；否则休眠中。
    if (st.lastControlAt && Date.now() - st.lastControlAt < CHANNEL_FRESH_MS) {
      channelEl.textContent = "App connected · config synced " + ago(st.lastControlAt);
    } else {
      channelEl.textContent = "App not responding — sleeping" + (st.heartbeatMin ? " (retry every " + st.heartbeatMin + "m)" : "");
    }
  });
}

refreshStatus();

button.addEventListener("click", () => {
  statusEl.textContent = "Syncing…";
  button.disabled = true;
  chrome.runtime.sendMessage({ type: "sync-now" }, (payload) => {
    button.disabled = false;
    if (chrome.runtime.lastError || !payload) {
      statusEl.textContent = "Could not reach the extension worker.";
      return;
    }
    statusEl.textContent = LABELS[payload.status] || "Status: " + payload.status;
    refreshStatus();
  });
});
