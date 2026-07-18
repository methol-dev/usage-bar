// UsageBar — Claude Web Usage 扩展的 service worker（编排层）。
//
// 职责：在**用户已登录的 claude.ai 页面上下文**里取订阅用量（真正同源、浏览器自动带 cookie），
// 把结果经 Native Messaging 交给 UsageBar 的 host。SW 本身不 fetch claude.ai，也不读/导出任何 cookie。
//
// 控制通道（ADR 0011）：本扩展**主动**每 ~1min 轮询 host 拉「控制配置」（poll），据此决定行为 ——
//   • paused          → 停止 claude.ai 取数（app 里 Claude 或 Web 源被关）
//   • syncNonce 变化  → 立即取数一次（app 端点了 Refresh）
//   • intervalSeconds → 自主取数节奏
//   • ts 陈旧 / 拉不到 → app 不在世 / host 不可达 → 退避「休眠」（拉长心跳周期）
// 取数仍走原路：在 claude.ai 页面上下文 fetch → sendNativeMessage(usage) → host 写 claude-web.json。
// 合规不变：poll 不 fetch claude.ai；取数由用户浏览器在真实会话里发出；无 cookie 权限。

const HOST_NAME = "com.tuzhihao.usagebar.host";
const ALARM_NAME = "usagebar-heartbeat";
const ACTIVE_MIN = 1; // active 心跳周期（分钟）。MV3 alarms 最小 1min。
const BACKOFF_STEPS = [1, 2, 5, 10]; // 拉不到配置时心跳周期沿此阶梯退避（封顶 10min）= 休眠。
const CONTROL_STALE_MS = 5 * 60 * 1000; // control.ts 超过此龄 → app 视为不在世 → 休眠。
const MIN_SYNC_GAP_MS = 60 * 1000; // 取数去抖：自动触发最多每分钟一次（手动 force 不受限）。
const DEFAULT_INTERVAL_MS = 30 * 60 * 1000; // control 缺 intervalSeconds 时的兜底取数间隔。

const K = {
  lastSync: "lastSyncAt", // 上次取数尝试时刻
  heartbeat: "heartbeatMin", // 当前心跳周期（退避状态，持久化以跨 SW 重启）
  nonce: "lastNonce", // 上次应用过的 syncNonce
  control: "lastControlAt", // 上次成功收到 control 的时刻（正向信号：通道是活的）
};

// —— 顶层同步注册监听器（MV3 SW 会被杀，唤醒后重跑本脚本，顶层注册才能重新挂上）——
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === ALARM_NAME) heartbeat();
});
chrome.runtime.onInstalled.addListener(() => {
  ensureAlarm();
  heartbeat();
});
chrome.runtime.onStartup.addListener(() => {
  ensureAlarm();
  heartbeat();
});
// claude.ai 标签页加载/导航完成、或浏览器窗口获焦 —— 会话正热，唤醒并顺带取数。
chrome.tabs.onUpdated.addListener((_id, ci, tab) => {
  if (ci.status === "complete" && tab.url && tab.url.startsWith("https://claude.ai/")) wake();
});
chrome.windows.onFocusChanged.addListener((wid) => {
  if (wid !== chrome.windows.WINDOW_ID_NONE) wake();
});
// popup：手动「Sync now」强制取数；「get-status」给 popup 显示通道状态。
chrome.runtime.onMessage.addListener((msg, _s, reply) => {
  if (msg && msg.type === "sync-now") {
    syncUsage({ force: true }).then(reply);
    return true;
  }
  if (msg && msg.type === "get-status") {
    chrome.storage.local.get([K.lastSync, K.control, K.heartbeat]).then(reply);
    return true;
  }
  return false;
});

async function ensureAlarm() {
  // 恢复**持久化**的心跳周期（退避可能已把它拉长）——不强制回 active，否则与退避打架。
  const st = await chrome.storage.local.get(K.heartbeat);
  const min = st[K.heartbeat] || ACTIVE_MIN;
  const ex = await chrome.alarms.get(ALARM_NAME);
  if (!ex || ex.periodInMinutes !== min) {
    await chrome.alarms.create(ALARM_NAME, { periodInMinutes: min });
  }
}

async function setHeartbeat(min) {
  await chrome.storage.local.set({ [K.heartbeat]: min });
  await chrome.alarms.create(ALARM_NAME, { periodInMinutes: min }); // 同名即替换
}

// 一次心跳：拉配置。拉不到 → 退避休眠；拉到 → 应用。
async function heartbeat() {
  const control = await pollControl();
  if (!control) return backoff();
  await applyControl(control, { eventForce: false });
}

// 事件唤醒：回 active，拉配置，会话热时顺带取数（仍受 paused / 去抖约束）。
async function wake() {
  await setHeartbeat(ACTIVE_MIN);
  const control = await pollControl();
  if (!control) return backoff();
  await applyControl(control, { eventForce: true });
}

// 向 host 要 control。host 不可达 / 无 control → null（= 主程序没反馈）。
async function pollControl() {
  let resp;
  try {
    resp = await chrome.runtime.sendNativeMessage(HOST_NAME, { type: "poll" });
  } catch (_e) {
    return null; // host 未装 / 不可达
  }
  const c = resp && resp.control;
  return c && typeof c === "object" ? c : null;
}

// 应用 control。eventForce=true 时（用户刚访问 claude.ai）即使未到 interval 也取数一次。
async function applyControl(control, { eventForce }) {
  // 陈旧：app 已关/崩（不再刷新 ts）→ 休眠。**先判陈旧**：host 仍会返回旧文件,只有「新鲜」control
  // 才算 app 在世 —— 故 lastControlAt 只在非陈旧分支盖章,否则 popup 的「app 在世」判据永远为真。
  const ageMs = Date.now() - (Number(control.ts) || 0) * 1000;
  if (ageMs > CONTROL_STALE_MS) return backoff();
  await chrome.storage.local.set({ [K.control]: Date.now() }); // 正向信号：收到**新鲜** control = app 在世
  // 有效反馈 → 回 active。
  await setHeartbeat(ACTIVE_MIN);
  if (control.paused) return; // app 要求暂停 → 不取数（心跳继续，等 unpause）
  const st = await chrome.storage.local.get([K.nonce, K.lastSync]);
  const secs = Number(control.intervalSeconds);
  const interval = secs > 0 ? Math.max(60, secs) * 1000 : DEFAULT_INTERVAL_MS; // 缺/非法 → 30min 兜底
  if (control.syncNonce !== st[K.nonce]) {
    // app 端主动 Refresh → 立即取数。先记 nonce，避免重复触发。
    await chrome.storage.local.set({ [K.nonce]: control.syncNonce });
    await syncUsage({ force: true });
  } else if (eventForce || Date.now() - (st[K.lastSync] || 0) >= interval) {
    await syncUsage({});
  }
}

// 退避：心跳周期沿阶梯增长（封顶），持久化 = 「休眠」。
async function backoff() {
  const st = await chrome.storage.local.get(K.heartbeat);
  const cur = st[K.heartbeat] || ACTIVE_MIN;
  const next = BACKOFF_STEPS.find((m) => m > cur) || BACKOFF_STEPS[BACKOFF_STEPS.length - 1];
  await setHeartbeat(next);
}

// 取数入口。自动路径（心跳/事件）经 applyControl/wake 已判 paused，不会在 paused 下取数；
// 手动「Sync now」(force) 是用户显式操作，即使 app 暂停也放行（app 未启用 web 源时忽略这次写入，无害）。
// 自动触发受 MIN_SYNC_GAP_MS 去抖；force=true（手动 / nonce 变化）放行。
async function syncUsage({ force = false } = {}) {
  if (!force) {
    const st = await chrome.storage.local.get(K.lastSync);
    if (Date.now() - (st[K.lastSync] || 0) < MIN_SYNC_GAP_MS) return { status: "skipped", ts: Date.now() };
  }
  let payload;
  try {
    payload = await collectFromClaudeTab();
  } catch (e) {
    payload = { status: "error", error: categorize(e), ts: Date.now() };
  }
  await chrome.storage.local.set({ [K.lastSync]: Date.now() });
  try {
    // usage 的 ack 也带回最新 control → 搭便车更新元信息（但**不**从这里触发同步，避免与刚做的同步成环）。
    const ack = await chrome.runtime.sendNativeMessage(HOST_NAME, payload);
    const c = ack && ack.control;
    if (c && typeof c === "object") {
      const patch = {};
      // 只在 control 新鲜时盖 lastControlAt（同 applyControl 的 liveness 语义）。
      if (Date.now() - (Number(c.ts) || 0) * 1000 <= CONTROL_STALE_MS) patch[K.control] = Date.now();
      if (c.syncNonce !== undefined) patch[K.nonce] = c.syncNonce; // 对齐 nonce，避免下拍重复取数
      await chrome.storage.local.set(patch);
    }
  } catch (_e) {
    // host 写完文件即退出，扩展侧可能收到 "Native host has exited" —— 属预期，忽略。
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
