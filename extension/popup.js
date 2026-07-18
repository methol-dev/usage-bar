// popup：显示上次同步时间 + 手动触发一次同步（不显示用量数字本身 —— 那在菜单栏 app 里看）。
// 自动同步由 background 的 alarm + 事件触发负责，用户通常无需点这个按钮。
const statusEl = document.getElementById("status");
const lastSyncEl = document.getElementById("lastSync");
const button = document.getElementById("sync");

const LABELS = {
  ok: "Synced ✓ — check the UsageBar menu bar app.",
  logged_out: "Not signed in to claude.ai. Open claude.ai and sign in.",
  no_session: "No claude.ai tab open. Open claude.ai in a tab, then retry.",
  error: "Sync failed. Make sure a claude.ai tab is open and signed in.",
  skipped: "Just synced a moment ago.",
};

const LAST_SYNC_KEY = "lastSyncAt";

function formatAgo(ms) {
  if (!ms) return "Last synced: never";
  const secs = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (secs < 60) return "Last synced: just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return "Last synced: " + mins + " min ago";
  const hours = Math.round(mins / 60);
  return "Last synced: " + hours + "h ago";
}

async function refreshLastSync() {
  const stored = await chrome.storage.local.get(LAST_SYNC_KEY);
  lastSyncEl.textContent = formatAgo(stored[LAST_SYNC_KEY]);
}

refreshLastSync();

button.addEventListener("click", () => {
  statusEl.textContent = "Syncing…";
  button.disabled = true;
  chrome.runtime.sendMessage({ type: "sync-now" }, (payload) => {
    button.disabled = false;
    if (chrome.runtime.lastError || !payload) {
      statusEl.textContent = "Could not reach the extension worker.";
      return;
    }
    statusEl.textContent = LABELS[payload.status] || ("Status: " + payload.status);
    refreshLastSync();
  });
});
