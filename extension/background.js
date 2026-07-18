// UsageBar — Web Usage 扩展的 service worker（编排层，ADR 0011/0012）。
//
// 职责：在**用户已登录的 provider 网页上下文**里取订阅用量（真正同源、浏览器自动带 cookie），
// 把结果经 Native Messaging 交给 UsageBar 的 host。SW 本身不 fetch provider 网页，也不读/导出任何
// cookie；Codex 的 bearer token 只在 chatgpt.com 页面上下文里用于同源请求，绝不回传给 app。
//
// 支持两个 provider（一个扩展同管）：
//   • claude → claude.ai/api/organizations/{id}/usage
//   • codex  → chatgpt.com/backend-api/wham/usage（先取 chatgpt.com/api/auth/session 的 accessToken）
//
// 控制通道：本扩展**主动**每 ~1min 轮询 host 拉「控制信封」（poll），host 回传的信封含每个 provider 的
// 独立控制（byProvider）+ 顶层扁平字段（= Claude，向后兼容）。据此对每个 provider 决定行为：
//   • paused          → 停止该 provider 取数（app 里对应 provider 或其 Web 源被关）
//   • syncNonce 变化  → 立即取数一次（app 端对该 provider 点了 Refresh）
//   • intervalSeconds → 自主取数节奏
//   • 顶层 ts 陈旧 / 拉不到 → app 不在世 / host 不可达 → 退避「休眠」（拉长心跳周期）
// 合规不变：poll 不 fetch 任何 provider 网页；取数由用户浏览器在真实会话里发出；无 cookie 权限；token 不出浏览器。

const HOST_NAME = "com.tuzhihao.usagebar.host";
const ALARM_NAME = "usagebar-heartbeat";
const ACTIVE_MIN = 1; // active 心跳周期（分钟）。MV3 alarms 最小 1min。
const BACKOFF_STEPS = [1, 2, 5, 10]; // 拉不到配置时心跳周期沿此阶梯退避（封顶 10min）= 休眠。
const CONTROL_STALE_MS = 5 * 60 * 1000; // 顶层 control.ts 超过此龄 → app 视为不在世 → 休眠。
const MIN_SYNC_GAP_MS = 60 * 1000; // 取数去抖：自动触发最多每分钟一次（手动 force 不受限）。
const DEFAULT_INTERVAL_MS = 30 * 60 * 1000; // control 缺 intervalSeconds 时的兜底取数间隔。

const PROVIDERS = ["claude", "codex"];
const PROVIDER_URL = { claude: "https://claude.ai/", codex: "https://chatgpt.com/" };
const PROVIDER_QUERY = { claude: "https://claude.ai/*", codex: "https://chatgpt.com/*" };

const K = {
  heartbeat: "heartbeatMin", // 当前心跳周期（退避状态，持久化以跨 SW 重启）
  control: "lastControlAt", // 上次成功收到**新鲜** control 的时刻（正向信号：通道是活的）
};
const kLastSync = (p) => "lastSyncAt:" + p; // 上次取数尝试时刻（每 provider）
const kNonce = (p) => "lastNonce:" + p; // 上次应用过的 syncNonce（每 provider）

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
// provider 标签页加载/导航完成 —— 会话正热，唤醒并对**该 provider**顺带取数。
chrome.tabs.onUpdated.addListener((_id, ci, tab) => {
  if (ci.status !== "complete" || !tab.url) return;
  for (const p of PROVIDERS) if (tab.url.startsWith(PROVIDER_URL[p])) wake(p);
});
// 浏览器窗口获焦 —— 唤醒拉配置，但不强制任何 provider 取数（不知是哪个 provider 的窗口，避免误覆盖）。
chrome.windows.onFocusChanged.addListener((wid) => {
  if (wid !== chrome.windows.WINDOW_ID_NONE) wake(null);
});
// popup：手动「Sync now」强制取所有 provider；「get-status」给 popup 显示通道状态。
chrome.runtime.onMessage.addListener((msg, _s, reply) => {
  if (msg && msg.type === "sync-now") {
    Promise.all(PROVIDERS.map((p) => syncUsage(p, { force: true }))).then((rs) => reply(pickStatus(rs)));
    return true;
  }
  if (msg && msg.type === "get-status") {
    chrome.storage.local
      .get([K.control, K.heartbeat, ...PROVIDERS.map(kLastSync)])
      .then((st) => reply(shapeStatus(st)));
    return true;
  }
  return false;
});

// popup 状态整形：把每 provider 的 lastSync 汇成「最近一次」，附控制通道 liveness。
function shapeStatus(st) {
  const syncs = PROVIDERS.map((p) => st[kLastSync(p)]).filter((v) => typeof v === "number");
  return {
    lastSyncAt: syncs.length ? Math.max(...syncs) : undefined,
    lastControlAt: st[K.control],
    heartbeatMin: st[K.heartbeat],
  };
}

// 从多个 sync 结果里挑一个给 popup 展示（优先 ok，其次任意非 skipped）。
function pickStatus(results) {
  return results.find((r) => r && r.status === "ok") || results.find((r) => r && r.status !== "skipped") || results[0];
}

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

// 一次心跳：拉配置。拉不到 → 退避休眠；拉到 → 应用（无 provider 被强制，仅按各自 interval）。
async function heartbeat() {
  const envelope = await pollControl();
  if (!envelope) return backoff();
  await applyControl(envelope, { forceProvider: null });
}

// 事件唤醒：回 active，拉配置，`forceProvider` 会话热时对该 provider 顺带取数一次（仍受 paused 约束）。
async function wake(forceProvider) {
  await setHeartbeat(ACTIVE_MIN);
  const envelope = await pollControl();
  if (!envelope) return backoff();
  await applyControl(envelope, { forceProvider });
}

// 向 host 要控制信封。host 不可达 / 无 control → null（= 主程序没反馈）。
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

// 从控制信封里取某 provider 的控制：优先 byProvider[provider]；缺失时对 claude 回退顶层扁平字段
// （向后兼容旧 app），对其它 provider 视为「本 app 不支持」→ null（不取数）。
function controlFor(envelope, provider) {
  const bp = envelope.byProvider;
  if (bp && typeof bp === "object" && bp[provider] && typeof bp[provider] === "object") return bp[provider];
  if (provider === "claude") return envelope;
  return null;
}

// 应用控制信封：先判顶层陈旧（app 在世？）→ 再对每个 provider 按其独立控制取数。
async function applyControl(envelope, { forceProvider }) {
  // 陈旧：app 已关/崩（不再刷新 ts）→ 休眠。**先判陈旧**：host 仍会返回旧文件，只有「新鲜」信封
  // 才算 app 在世 —— 故 lastControlAt 只在非陈旧分支盖章，否则 popup 的「app 在世」判据永远为真。
  const ageMs = Date.now() - (Number(envelope.ts) || 0) * 1000;
  if (ageMs > CONTROL_STALE_MS) return backoff();
  await chrome.storage.local.set({ [K.control]: Date.now() }); // 正向信号：收到**新鲜** control = app 在世
  await setHeartbeat(ACTIVE_MIN); // 有效反馈 → 回 active
  for (const p of PROVIDERS) {
    const control = controlFor(envelope, p);
    if (!control || control.paused) continue; // 不支持 / 要求暂停 → 不取数
    await maybeSync(p, control, p === forceProvider);
  }
}

// 对单个 provider：nonce 变化立即取数；否则按 interval / eventForce 取数。
async function maybeSync(provider, control, eventForce) {
  const st = await chrome.storage.local.get([kNonce(provider), kLastSync(provider)]);
  const secs = Number(control.intervalSeconds);
  const interval = secs > 0 ? Math.max(60, secs) * 1000 : DEFAULT_INTERVAL_MS; // 缺/非法 → 30min 兜底
  if (control.syncNonce !== st[kNonce(provider)]) {
    // app 端对该 provider 主动 Refresh → 立即取数。先记 nonce，避免重复触发。
    await chrome.storage.local.set({ [kNonce(provider)]: control.syncNonce });
    await syncUsage(provider, { force: true });
  } else if (eventForce || Date.now() - (st[kLastSync(provider)] || 0) >= interval) {
    await syncUsage(provider, {});
  }
}

// 退避：心跳周期沿阶梯增长（封顶），持久化 = 「休眠」。
async function backoff() {
  const st = await chrome.storage.local.get(K.heartbeat);
  const cur = st[K.heartbeat] || ACTIVE_MIN;
  const next = BACKOFF_STEPS.find((m) => m > cur) || BACKOFF_STEPS[BACKOFF_STEPS.length - 1];
  await setHeartbeat(next);
}

// 取数入口。自动路径经 applyControl/maybeSync 已判 paused，不会在 paused 下取数；
// 手动「Sync now」(force) 是用户显式操作，即使 app 暂停也放行（app 未启用对应 web 源时忽略这次写入，无害）。
// 自动触发受 MIN_SYNC_GAP_MS 去抖；force=true（手动 / nonce 变化）放行。
async function syncUsage(provider, { force = false } = {}) {
  if (!force) {
    const st = await chrome.storage.local.get(kLastSync(provider));
    if (Date.now() - (st[kLastSync(provider)] || 0) < MIN_SYNC_GAP_MS) return { status: "skipped", ts: Date.now(), provider };
  }
  let payload;
  try {
    payload = await collectFromTab(provider);
  } catch (e) {
    payload = { status: "error", error: categorize(e), ts: Date.now() };
  }
  payload.provider = provider; // 让 host 分派写入 <provider>-web.json
  await chrome.storage.local.set({ [kLastSync(provider)]: Date.now() });
  try {
    // usage 的 ack 也带回最新控制信封 → 搭便车更新元信息（但**不**从这里触发同步，避免与刚做的同步成环）。
    const ack = await chrome.runtime.sendNativeMessage(HOST_NAME, payload);
    const env = ack && ack.control;
    if (env && typeof env === "object") {
      const patch = {};
      // 只在信封新鲜时盖 lastControlAt（同 applyControl 的 liveness 语义）。
      if (Date.now() - (Number(env.ts) || 0) * 1000 <= CONTROL_STALE_MS) patch[K.control] = Date.now();
      const c = controlFor(env, provider);
      if (c && c.syncNonce !== undefined) patch[kNonce(provider)] = c.syncNonce; // 对齐 nonce，避免下拍重复取数
      await chrome.storage.local.set(patch);
    }
  } catch (_e) {
    // host 写完文件即退出，扩展侧可能收到 "Native host has exited" —— 属预期，忽略。
  }
  return payload;
}

// 在一个已打开的 provider 标签页上下文里取数（真同源）。无标签页 → no_session。
async function collectFromTab(provider) {
  const tabs = await chrome.tabs.query({ url: PROVIDER_QUERY[provider] });
  const tab = tabs.find((t) => typeof t.id === "number");
  if (!tab) return { status: "no_session", ts: Date.now() };
  const func = provider === "codex" ? pageFetchCodexUsage : pageFetchClaudeUsage;
  const results = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func, // 注入进 provider 页；函数须自包含（不引用外部变量）。
  });
  const result = results && results[0] && results[0].result;
  return result || { status: "error", error: "no_result", ts: Date.now() };
}

// —— 以下函数被注入 provider 页面上下文执行；必须完全自包含 ——

async function pageFetchClaudeUsage() {
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
    // usage 原样回传 —— app 侧的 ClaudeWebUsageMapper 负责映射。
    return { status: "ok", ts: now(), usage: usage };
  } catch (e) {
    return { status: "error", error: "fetch_failed", ts: now() };
  }
}

// Codex：先取 chatgpt.com 登录会话的 accessToken（**token 只在本页面上下文里用于同源请求，绝不回传给 app**），
// 再带 Bearer 调 wham/usage（与 Codex CLI 同端点/同 schema）。app 侧 CodexWebUsageMapper 负责映射。
async function pageFetchCodexUsage() {
  const now = () => Date.now();
  try {
    const sessResp = await fetch("https://chatgpt.com/api/auth/session", {
      credentials: "include",
      headers: { accept: "application/json" },
    });
    if (sessResp.status === 401 || sessResp.status === 403) return { status: "logged_out", ts: now() };
    if (!sessResp.ok) return { status: "error", error: "session_http_" + sessResp.status, ts: now() };
    const session = await sessResp.json();
    const token = session && session.accessToken;
    if (!token) return { status: "logged_out", ts: now() }; // 无 token（多为未登录）→ 引导登录

    const usageResp = await fetch("https://chatgpt.com/backend-api/wham/usage", {
      credentials: "include",
      headers: { accept: "application/json", authorization: "Bearer " + token },
    });
    if (usageResp.status === 401 || usageResp.status === 403) return { status: "logged_out", ts: now() };
    if (!usageResp.ok) return { status: "error", error: "usage_http_" + usageResp.status, ts: now() };
    const usage = await usageResp.json();
    // 只回传用量数字；token 留在浏览器、不进 payload。
    return { status: "ok", ts: now(), usage: usage };
  } catch (e) {
    return { status: "error", error: "fetch_failed", ts: now() };
  }
}

// SC7 精神：只上报错误类别，不带 URL / 响应体 / token。
function categorize(e) {
  const name = (e && e.name) || "";
  if (name) return String(name);
  return "error";
}
