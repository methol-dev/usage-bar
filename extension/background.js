// UsageBar — Claude Web Usage 扩展的 service worker（编排层）。
//
// 职责：周期性地在**用户已登录的 claude.ai 页面上下文**里取订阅用量（真正同源、浏览器自动带
// cookie），把结果经 Native Messaging 交给 UsageBar 的 host。SW 本身不 fetch claude.ai
// （SW 对 claude.ai 是跨源，SameSite cookie 可能带不上），也不读取 / 导出任何 cookie。
//
// 合规原则：请求由用户浏览器在真实会话里发出；扩展只转发用量数字。

const HOST_NAME = "com.tuzhihao.usagebar.host";
const ALARM_NAME = "usagebar-sync";
const PERIOD_MINUTES = 15; // MV3 alarms 最小 1min；15min 足够且省电。

// onAlarm 监听器必须在顶层同步注册 —— MV3 SW 会被杀，alarm 唤醒后重跑本脚本，顶层注册才能重新挂上。
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) {
    syncUsage();
  }
});

chrome.runtime.onInstalled.addListener(() => ensureAlarm());
chrome.runtime.onStartup.addListener(() => ensureAlarm());

// popup 的「Sync now」按钮。
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "sync-now") {
    syncUsage().then(sendResponse);
    return true; // 异步 sendResponse
  }
  return false;
});

async function ensureAlarm() {
  const existing = await chrome.alarms.get(ALARM_NAME);
  if (!existing) {
    await chrome.alarms.create(ALARM_NAME, { periodInMinutes: PERIOD_MINUTES });
  }
}

async function syncUsage() {
  let payload;
  try {
    payload = await collectFromClaudeTab();
  } catch (e) {
    payload = { status: "error", error: categorize(e), ts: Date.now() };
  }
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
