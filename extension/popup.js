// popup：手动触发一次同步并显示结果类别（不显示用量数字本身 —— 那在菜单栏 app 里看）。
const statusEl = document.getElementById("status");
const button = document.getElementById("sync");

const LABELS = {
  ok: "Synced ✓ — check the UsageBar menu bar app.",
  logged_out: "Not signed in to claude.ai. Open claude.ai and sign in.",
  no_session: "No claude.ai tab open. Open claude.ai in a tab, then retry.",
  error: "Sync failed. Make sure a claude.ai tab is open and signed in.",
};

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
  });
});
