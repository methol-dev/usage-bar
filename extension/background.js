// UsageBar — Claude Web Usage 扩展的 service worker（编排层）。
//
// 职责：在**用户已登录的 claude.ai 页面上下文**里取订阅用量（真正同源、浏览器自动带 cookie），
// 把结果经 Native Messaging 交给 UsageBar 的 host。SW 本身不 fetch claude.ai（SW 对 claude.ai
// 是跨源，SameSite cookie 可能带不上），也不读取 / 导出任何 cookie。
//
// 合规原则：请求由用户浏览器在真实会话里发出；扩展只转发用量数字。
//
// 自动同步：不需要用户手动点。多路触发 —— 周期 alarm + 打开/切到 claude.ai 标签页 + 浏览器获焦，
// 全部经一个去抖门（MIN_SYNC_GAP_MS）汇流，避免频繁触发时反复拉起 host。手动「Sync now」强制绕过去抖。

const HOST_NAME = "com.tuzhihao.usagebar.host";
const ALARM_NAME = "usagebar-sync";
const DEFAULT_PERIOD_MINUTES = 5; // alarm 是同步下限（兜底）；事件触发覆盖绝大多数场景。MV3 alarms 最小 1min。
const MIN_SYNC_GAP_MS = 60 * 1000; // 去抖：自动触发最多每分钟一次（跨所有触发源共享），手动不受限。
const LAST_SYNC_KEY = "lastSyncAt"; // chrome.storage.local，供去抖判断 + popup 显示「上次同步」。

// onAlarm 监听器必须在顶层同步注册 —— MV3 SW 会被杀，alarm 唤醒后重跑本脚本，顶层注册才能重新挂上。
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) syncUsage({ reason: "alarm" });
});

chrome.runtime.onInstalled.addListener(() => {
  ensureAlarm();
  syncUsage({ reason: "installed" });
});
chrome.runtime.onStartup.addListener(() => {
  ensureAlarm();
  syncUsage({ reason: "startup" });
});

// 一个 claude.ai 标签页加载 / 导航完成 —— 会话正热，是同步的好时机。
chrome.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (changeInfo.status === "complete" && tab.url && tab.url.startsWith("https://claude.ai/")) {
    syncUsage({ reason: "tab" });
  }
});

// 用户把焦点切回某个浏览器窗口 —— 去抖窗口外则顺带刷新一次。
chrome.windows.onFocusChanged.addListener((windowId) => {
  if (windowId !== chrome.windows.WINDOW_ID_NONE) syncUsage({ reason: "focus" });
});

// popup 的「Sync now」按钮 —— 强制同步（绕过去抖）。
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "sync-now") {
    syncUsage({ reason: "manual", force: true }).then(sendResponse);
    return true; // 异步 sendResponse
  }
  return false;
});

async function ensureAlarm() {
  // Chrome alarm 跨扩展更新 / 浏览器重启持久 —— 老版本装过 15min alarm 的用户升级后不会自动变。
  // 所以周期不符也要重建（create 同名即替换），确保 DEFAULT_PERIOD_MINUTES 的调整对存量安装生效。
  const existing = await chrome.alarms.get(ALARM_NAME);
  if (!existing || existing.periodInMinutes !== DEFAULT_PERIOD_MINUTES) {
    await chrome.alarms.create(ALARM_NAME, { periodInMinutes: DEFAULT_PERIOD_MINUTES });
  }
}

// 去抖同步。自动触发受 MIN_SYNC_GAP_MS 限制；force=true（手动）直接放行。
// 无论成功失败都记录尝试时刻 —— 坏会话不会在每次 focus 变化时反复拉起 host。
async function syncUsage({ reason, force = false } = {}) {
  if (!force) {
    const stored = await chrome.storage.local.get(LAST_SYNC_KEY);
    const last = stored[LAST_SYNC_KEY] || 0;
    if (Date.now() - last < MIN_SYNC_GAP_MS) {
      return { status: "skipped", ts: Date.now() };
    }
  }
  let payload;
  try {
    payload = await collectFromClaudeTab();
  } catch (e) {
    payload = { status: "error", error: categorize(e), ts: Date.now() };
  }
  await chrome.storage.local.set({ [LAST_SYNC_KEY]: Date.now() });
  try {
    // sendNativeMessage（一次性）：Chrome 拉起短命 host，host 写文件后 exit。
    await chrome.runtime.sendNativeMessage(HOST_NAME, payload);
  } catch (_e) {
    // host 写完文件即退出，扩展侧会收到 "Native host has exited" —— 属预期，忽略。
    // （host 未安装 / manifest 缺失也会落到这里；用量已尽力送达，无需上报。）
  }
  return payload;
}

// 在一个已打开的 claude.ai 标签页上下文里取数（真同源）。无标签页 → no_session。
async function collectFromClaudeTab() {
  const tabs = await chrome.tabs.query({ url: "https://claude.ai/*" });
  const tab = tabs.find((t) => typeof t.id === "number");
  if (!tab) {
    return { status: "no_session", ts: Date.now() };
  }
  const results = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: pageFetchUsage, // 注入进 claude.ai 页；函数须自包含（不引用外部变量）。
  });
  const result = results && results[0] && results[0].result;
  return result || { status: "error", error: "no_result", ts: Date.now() };
}

// —— 以下函数被注入 claude.ai 页面上下文执行；必须完全自包含 ——
async function pageFetchUsage() {
  const now = () => Date.now();
  try {
    const orgResp = await fetch("https://claude.ai/api/organizations", {
      credentials: "include",
      headers: { accept: "application/json" },
    });
    if (orgResp.status === 401 || orgResp.status === 403) return { status: "logged_out", ts: now() };
    if (!orgResp.ok) return { status: "error", error: "orgs_http_" + orgResp.status, ts: now() };
    const orgs = await orgResp.json();
    const org = Array.isArray(orgs) ? orgs[0] : null;
    const orgId = org && (org.uuid || org.id);
    if (!orgId) return { status: "error", error: "no_org", ts: now() };

    const usageResp = await fetch(
      "https://claude.ai/api/organizations/" + encodeURIComponent(orgId) + "/usage",
      { credentials: "include", headers: { accept: "application/json" } }
    );
    if (usageResp.status === 401 || usageResp.status === 403) return { status: "logged_out", ts: now() };
    if (!usageResp.ok) return { status: "error", error: "usage_http_" + usageResp.status, ts: now() };
    const usage = await usageResp.json();
    // usage 原样回传 —— app 侧的 ClaudeWebUsageMapper 负责映射（真实 schema 待 Phase 0 定稿）。
    return { status: "ok", ts: now(), usage: usage };
  } catch (e) {
    return { status: "error", error: "fetch_failed", ts: now() };
  }
}

// SC7 精神：只上报错误类别，不带 URL / 响应体。
function categorize(e) {
  const name = (e && e.name) || "";
  if (name) return String(name);
  return "error";
}
