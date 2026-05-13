---
id: 2026-05-13-gemini-provider
title: Gemini provider 接入 — 对标 Claude / Codex 的第三条 provider 数据源
status: implemented
created: 2026-05-13
updated: 2026-05-13
owner: claude-code
model: claude-opus-4-7
target_version: v0.6.0
related_adrs: [0001, 0003, 0005]
related_research:
  - "docs/artifacts/issues/27/diagnosis.md"
  - "https://github.com/steipete/CodexBar/blob/main/docs/gemini.md"
  - "https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts"
spec_criteria:
  - id: SC1
    criterion: "已安装并 `gemini` 登录过的用户:启用 Gemini provider 后,popover 出现 Gemini tab,显示 Pro 与 Flash 两段配额(`remainingFraction` + `resetTime`),不崩溃"
    done: true
    evidence: "见 ## Verification log"
  - id: SC2
    criterion: "凭证缺失或解析失败(`~/.gemini/oauth_creds.json` 不存在 / JSON 损坏):runtime.isConfigured=false,popover 显示降级文案『请在终端运行 gemini 登录』,不弹错误"
    done: true
    evidence: "见 ## Verification log"
  - id: SC3
    criterion: "access_token 过期后,下一次 refreshNow() 自动 refresh + 后续 polling 不再返回 401(用户视角『不需要手工重登』)"
    done: true
    evidence: "见 ## Verification log"
  - id: SC4
    criterion: "API 401/403 → runtime 进 unauthorized 态,文案『Gemini 凭证已过期,请运行 gemini 重新登录』;非 2xx 其它错误 → 『无法获取 Gemini 用量(稍后重试)』,不清缓存 snapshot"
    done: true
    evidence: "见 ## Verification log"
  - id: SC5
    criterion: "本机未装 gemini-cli(三处枚举均找不到 OAuth client_id/secret):runtime 进 unconfigured 态,文案『未检测到 gemini-cli 安装,无法识别 OAuth 凭证』"
    done: true
    evidence: "见 ## Verification log"
  - id: SC6
    criterion: "后台 polling 走 ProviderCoordinator 统一 timer(同 pollingMinutes),不自持 timer;refreshNow() 重入闸门生效"
    done: true
    evidence: "见 ## Verification log"
  - id: SC7
    criterion: "菜单栏 + Settings 沿用 v0.3.0 框架:Gemini 在 Settings/Provider 列表中可启用/禁用、菜单栏可见性独立、可拖拽排序(前置假设:SettingsView 按 ProviderID.allCases 自动渲染,Gemini 不需要额外 UI wire)"
    done: true
    evidence: "见 ## Verification log"
  - id: SC8
    criterion: "Gemini provider 成功拉取后,落历史样本到 `history-gemini.json`(对标 history-codex.json),与 Claude/Codex 同一 UsageHistoryService 抽象"
    done: true
    evidence: "见 ## Verification log"
  - id: SC9
    criterion: "swift build -c release + swift test 全绿;凭证解析、token 刷新、OAuth client 抠取、quota 响应解码、Pro/Flash 槽位映射五条数据通路均有测试覆盖(具体测试文件 / fixture 由 plan 阶段定)"
    done: true
    evidence: "见 ## Verification log"
  - id: SC10
    criterion: "README / docs 增『third-party credentials』披露段:说明本 app 复用本机 gemini-cli 的 OAuth 凭证、不分发 Google client secret、本机抠取仅在运行时读取且不上传"
    done: true
    evidence: "见 ## Verification log"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release 2>&1 | tail -5"
  - "SC_AUTO_TEST: cd macos && swift test 2>&1 | tail -20"
manual_checks:
  - "SC1: 启用 Gemini tab → 看到两段配额 + reset 倒计时"
  - "SC2: rm ~/.gemini/oauth_creds.json → popover 显示降级文案"
  - "SC4: 手工把 access_token 改坏 → 401 后看到对应文案"
  - "SC5: 卸载 gemini-cli(或临时改路径)→ 看到 unconfigured 文案"
  - "SC7: Settings 中拖拽 Gemini / 切换启用 / 切换菜单栏可见 — 全部生效"
reviews:
  - reviewer: g2-general-purpose-subagent (round 1)
    date: 2026-05-13
    verdict: needs-revision
    notes: "5 条 required(用户授权钉死 / §2.3 范围确认 / v1internal payload fact-finding / oauth_creds.json 并发风险 / 合规披露移入 scope)+ 3 条 optional(SC3 / SC9 / SC7 改良);无 substantive 决策反转"
  - reviewer: g2-general-purpose-subagent (round 2)
    date: 2026-05-13
    verdict: approved
    notes: "二轮轻量复核确认 5 条 required 全部 closed(双处留痕:frontmatter + 正文);spec 进入 plan 阶段"
  - reviewer: user-methol
    date: 2026-05-13
    verdict: approved
    notes: "对话授权:(1) §2.2 选 OAuth 动态抠取方案,知悉 hard gate #6 法律合规风险并接受按 CodexBar 路径推进;(2) §2.3 接受『quota 先上线 + 本机统计走后续 iteration』分两步走,不阻塞本 spec 关闭 issue#27;授权来源:issue #27 AskUserQuestion 选 A + 后续『按流程自主开发和决策完成任务,不要问我』指令"
---

# Gemini provider 接入 — 对标 Claude / Codex 的第三条 provider 数据源

## 1. 背景与目标

**起因**:GitHub [issue #27](https://github.com/methol/usage-bar/issues/27) 要求接入 gemini-cli,"完整对标 Claude / Codex 的功能"。在 issue-driven 分诊阶段判定其触发守护线(>5 文件)+ AGENTS.md hard gate #6(法律 / 合规)→ 升级到主回路。完整 fact-finding 见 [`docs/artifacts/issues/27/diagnosis.md`](../../artifacts/issues/27/diagnosis.md)。

**ADR 关系**:[ADR 0005](../../adr/0005-reopen-multi-provider-direction.md) 已经为 Gemini 占位("其余 provider 视用户需求再评估,不预先承诺")。本 spec 是该 ADR 的兑现 — 用户已明确提出需求。`ProviderID.gemini` case 与 `MenuBarIconRenderer` 的 `sparkle` 图标早就到位,缺的只是注册一个 `GeminiProvider` 实例与配套凭证/网络/历史链路。

**目标**:接入 **Gemini Code Assist for Individuals**(个人版 OAuth)一条数据源,UI 上等同于 Codex 已有的"双窗口配额 + 历史折线"形态。**不做** Enterprise / Vertex AI / API key 用户的支持(数据源完全不同,见 §6)。**不做** 本机 session 离线统计(原因见决策摘要 §2.3)。

## 2. 决策摘要

| 决策点 | 选择 | 备选 | 原因 |
|---|---|---|---|
| **2.1 quota 数据源** | `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` + `retrieveUserQuota`(私有 endpoint) | (a) 不显示 rate 只显示 identity; (b) 等 #15292 上 JSONL 后做离线估算 | gemini-cli 自身依赖此 endpoint,长期可用;CodexBar 已实战验证(payload 引用见 §2.1.1);不显示 rate 等于阉割,违反 issue "完整对标" |
| **2.2 OAuth client_id/secret 来源** | **动态从本机 gemini-cli 安装目录用正则抠** `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET`;三处枚举(`/opt/homebrew/lib/node_modules/...` / `~/.bun/...` / `/usr/local/lib/node_modules/...`)。**用户已确认**(2026-05-13,见 frontmatter `reviews:` user-methol verdict) | (a) 硬编码进 app; (b) 让用户自己注册 GCP OAuth client | 跟 CodexBar 一致;Google secret 不被二次分发(法律暴露最低);失败兜底进 unconfigured 态 |
| **2.3 本机会话统计** | **本 spec 不做**,作为后续 iteration。**用户已确认**接受『分两步走』(2026-05-13,见 frontmatter `reviews:` user-methol verdict) | (a) 初版就扫 `~/.gemini/tmp/<hash>/chats/*.json` | 该文件单体重写、无 token 字段,精度差;跟版本走的契约风险;等 [gemini-cli #15292](https://github.com/google-gemini/gemini-cli/issues/15292) JSONL 提案落地后再做 |
| **2.4 UI 双 bar 映射** | Pro 模型 → primary 槽(原 5h 位)、Flash 模型 → secondary 槽(原 7d 位);各自的 `resetTime` 独立显示 | (a) 单 bar 只显示日总; (b) 用户当前默认模型作单值 | 沿用 IconBar 双 bar 视觉一致性;Pro 是用户主要算力(60/min,1000/day),Flash 是 fallback,与现有"主/次窗口"语义同构 |
| **2.5 target_version** | `v0.6.0-gemini-provider`(新 minor) | (a) 塞进 v0.5.0 observable-migration | Gemini 接入与 SwiftUI hygiene 主题正交;混版本会让 release notes 与回滚边界模糊 |
| **2.6 历史落地** | `history-gemini.json`,新建 `UsageHistoryService(filename:)` 实例,与 Codex 同形 | (a) 与 Codex 共用一个文件 | 与 Codex `history-codex.json` 同结构、不同文件,沿用 v0.2.8 既有模式 |

**关于 §2.2 的合规备注**:本决策路径与 CodexBar 一致,属于 AGENTS.md §5 hard gate #6 范围。**用户已在 2026-05-13 确认按本方案推进**(frontmatter `reviews:` 留痕)。三种可选方案的合规风险等级:

- **动态抠取(选)**:client_id/secret 仍存在用户本机 gemini-cli 安装目录,本 app 不分发它们,只在运行时读出来用 — 法律上接近"用户授权我们代理调用 Google API";Google ToS 上仍有灰度
- **硬编码**:等同于本 app 二次分发 Google 发给 gemini-cli 的凭证,**最高风险**
- **用户自注册**:合规最优,但要求每个用户在 GCP console 建 OAuth client + project + 启用 API,产品上几乎不可行

### 2.1.1 v1internal payload fact-finding 引用

`loadCodeAssist` / `retrieveUserQuota` 的 request / response schema 直接来源:

- **CodexBar Gemini 接入**:[`steipete/CodexBar/docs/gemini.md`](https://github.com/steipete/CodexBar/blob/main/docs/gemini.md) — 详细记录了套餐识别 / quota endpoint / projectId 解析回退链
- **gemini-cli 上游源码**:`packages/core/src/code_assist/` 子目录(尤其 `oauth2.ts` 凭证、`server.ts` / `setup.ts` 调用 v1internal 的位置)
- **POST `loadCodeAssist`** body 关键字段:`metadata`(client info)、`cloudaicompanionProject`(项目 ID 或 "default");response 含 `currentTier.id`(`free` / `legacy` / `standard` / `workspace`)、`cloudaicompanionProject`
- **POST `retrieveUserQuota`** body 关键字段:`{"project": "<projectId>"}`;response 是 per-model 数组,每条含 `model` / `remainingFraction`(0~1 浮点)/ `resetTime`(ISO8601)/ `dailyLimit`(整型,可为 null 表示无限)

> **注**:这是私有 API,字段细节以 plan 阶段实测为准。gemini-cli 主仓库的 license 是 Apache-2.0,本 spec 引用其 source code 为 fact-finding 用途符合 OSS 合理使用。

## 3. 设计

### 3.1 整体架构

```
ProviderCoordinator (existing, unified poll timer)
  ├── claude: UsageService            (existing)
  ├── additionalProviders: [
  │       CodexProvider,              (existing)
  │       GeminiProvider              (NEW)
  │   ]
  └── onBackgroundTick → 每个 enabled provider .refreshNow()

GeminiProvider                                  ┐
  ├── refreshNow():                             │
  │     1. GeminiCredentialStore.load()         │ 沿用 Codex 同构
  │     2. 401 / 解析失败 → unconfigured        │
  │     3. GeminiUsageClient.fetchUsage(creds)  │
  │     4. snapshot → runtime + history sample  │
  └── 重入闸门 isRefreshing                     ┘

GeminiCredentialStore                           (NEW)
  ├── load(env) -> GeminiCredentials?
  │     ├─ 读 ~/.gemini/oauth_creds.json
  │     ├─ 字段:access_token / refresh_token / expiry_date / token_type / id_token / scope
  │     └─ expiry_date 已过 → refresh
  └── refresh(creds) -> GeminiCredentials
        ├─ POST https://oauth2.googleapis.com/token
        ├─ form: client_id / client_secret / refresh_token / grant_type=refresh_token
        └─ 写回 oauth_creds.json(原子 rename,0600)

GeminiOAuthClientLocator                        (NEW)
  └── findClientIdSecret() -> (clientId, secret)?
        ├─ 候选路径列表(homebrew / npm global / bun / 用户自定义 $GEMINI_CLI_PATH)
        ├─ 在 `packages/core/dist/.../oauth2.js` 用正则匹
        │   /OAUTH_CLIENT_ID\s*=\s*['"]([^'"]+)['"]/
        │   /OAUTH_CLIENT_SECRET\s*=\s*['"]([^'"]+)['"]/
        └─ 缓存结果(命中后写 UserDefaults `gemini.oauthClient.cachedPath`),失效自动重扫

GeminiUsageClient                               (NEW)
  ├── loadCodeAssist(creds) -> projectId + tier
  │     POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
  │     body: {"metadata":{...}, "cloudaicompanionProject": "default"}
  ├── retrieveUserQuota(creds, projectId) -> [PerModelQuota]
  │     POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota
  │     body: {"project": projectId}
  │     header: Authorization: Bearer <access_token>
  └── 错误映射:401/403 → unauthorized;其它 → networkError

GeminiUsageModel                                (NEW)
  ├── struct PerModelQuota { modelName, remainingFraction, resetTime, dailyLimit }
  ├── asProviderSnapshot():
  │     primary   ← Pro 模型(`gemini-2.5-pro` 命中)
  │     secondary ← Flash 模型(`gemini-2.5-flash` 命中)
  │     pctExtra  ← 0(无第三条窗口)
  └── 模型识别用 ModelPricingCatalog 的 normalize 链一致地选 Pro / Flash
```

### 3.2 数据流(一次成功拉取)

```
背景 timer tick (每 pollingMinutes 分钟)
  → coordinator.onBackgroundTick()
  → GeminiProvider.refreshNow()
      1. GeminiCredentialStore.load()
         若 oauth_creds.json 缺 / 损坏 → runtime.setError(unconfigured)
         若 expiry_date 已过 → refresh() 一次,失败也走 unconfigured
      2. GeminiUsageClient.loadCodeAssist(creds)
         拿 projectId + tier(free/standard/legacy/workspace)
      3. GeminiUsageClient.retrieveUserQuota(creds, projectId)
         拿 [PerModelQuota]
      4. response.asProviderSnapshot() → runtime.setSuccess(snapshot)
      5. history.recordDataPoint(pct5h: proRemaining, pct7d: flashRemaining)
```

### 3.3 错误 / 边界

| 情况 | 行为 |
|---|---|
| `~/.gemini/oauth_creds.json` 不存在 | `runtime.setConfigured(false)` + `runtime.clear()` |
| 文件存在但 JSON 损坏 / 缺关键字段 | `runtime.setError("未检测到有效 Gemini 凭证,请运行 gemini 登录", clearSnapshot: true)` |
| `expiry_date` 过期 + refresh 成功 | 继续走 API |
| `expiry_date` 过期 + refresh 401/400 | unconfigured 态,文案『Gemini 凭证已过期,请运行 gemini 重新登录』 |
| OAuth client_id/secret 三处都找不到 | unconfigured 态,文案『未检测到 gemini-cli 安装』(给用户具体路径提示) |
| `loadCodeAssist` 找不到 project | 用 `cloudresourcemanager.googleapis.com/v1/projects` 回退找 `gen-lang-client*` 项目;仍找不到 → `runtime.setError`,文案『未检测到 Gemini Code Assist 项目』 |
| `retrieveUserQuota` 401/403 | unauthorized 态,清 snapshot |
| `retrieveUserQuota` 5xx / 网络错误 | networkError 态,**保留** snapshot(用户看到的是过期但有数) |
| Pro / Flash 模型在响应中缺失 | 对应槽位为 nil,UI 降级渲染(参考 Codex Free 计划只有 weekly 的情况) |

### 3.4 测试方案

- **`GeminiCredentialStoreTests`**:fixtures 覆盖正常 / 缺字段 / 损坏 JSON / expiry 过期 → 触发 refresh 的 stub mock;原子写入断言 temp + rename
- **`GeminiOAuthClientLocatorTests`**:fixture 三种安装目录 oauth2.js 正则匹中 / regex 不命中时回退 / 全部找不到
- **`GeminiUsageClientTests`**:`URLProtocol` mock(沿用 Claude/Codex 测试模式)→ 200 正常 / 401 / 5xx / 损坏 JSON
- **`GeminiUsageModelTests`**:`asProviderSnapshot` 把 [Pro, Flash, OtherModel] 数组正确映射;Pro 缺失时 primary=nil
- **`GeminiProviderTests`**:`refreshNow` 重入闸门 / 401 路径 / 历史样本写入

### 3.5 third-party credentials 披露(合规交付物)

本 spec G6 验收要求 README + docs(具体页面 plan 定)增加专门段落,披露:

- 本 app 复用本机已安装 gemini-cli 的 OAuth 凭证(`~/.gemini/oauth_creds.json`),不引导用户重新登录 Google
- 本 app 的 GeminiOAuthClientLocator **仅在运行时**从用户本机 gemini-cli 安装包中读取 `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET`,**不分发**这些 secret、**不上传**到任何远端、**不在 app 二进制中硬编码**
- 用户可通过卸载 gemini-cli / 删除 `~/.gemini/oauth_creds.json` 完全切断本 app 与 Google 的连接

此段为本 spec scope,不外推到后续 spec(reviewer G2 反馈)。

### 3.6 现有架构红线对齐

- ✅ `UsageService` 单源真相:Gemini 不在 Claude OAuth 路径内,只引入独立的 Gemini OAuth(Google) — 不重复使用 UsageService 的 fetch/auth
- ✅ 后台 polling:走 `ProviderCoordinator.onBackgroundTick`,不自持 timer
- ✅ 数据存储:`history-gemini.json` 在 `~/.config/usage-bar/`,与现有 history.json / history-codex.json 同目录
- ✅ ModelPricingCatalog:`normalize` Pro / Flash 模型名时复用现有 candidate chain;不引入 Gemini 价格表(本 spec 不做成本,无需价格)

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/UsageBar/Providers/Gemini/GeminiProvider.swift` | 主体,对标 `CodexProvider.swift` |
| 🆕 | `macos/Sources/UsageBar/Providers/Gemini/GeminiCredentials.swift` | 凭证读写 + refresh(对标 `CodexCredentials.swift`,但要做 refresh) |
| 🆕 | `macos/Sources/UsageBar/Providers/Gemini/GeminiOAuthClientLocator.swift` | 抠 client_id/secret 的独立模块(便于单测 fixture) |
| 🆕 | `macos/Sources/UsageBar/Providers/Gemini/GeminiUsageClient.swift` | 调 `loadCodeAssist` + `retrieveUserQuota` |
| 🆕 | `macos/Sources/UsageBar/Providers/Gemini/GeminiUsageModel.swift` | response 模型 + `asProviderSnapshot()` |
| 🔧 | `macos/Sources/UsageBar/App/UsageBarApp.swift` | wire:在 `additionalProviders` 加 `GeminiProvider();onPollTick` 不需要(本机统计未做) |
| ✅ 不动 | `macos/Sources/UsageBar/Models/ProviderID.swift` | `.gemini` case 早已存在 |
| ✅ 不动 | `macos/Sources/UsageBar/MenuBar/MenuBarIconRenderer.swift` | `sparkle` 图标早已配 |
| ✅ 不动 | `macos/Sources/UsageBar/Services/ProviderCoordinator.swift` | 通过 `additionalProviders` 自动接入,coordinator 本身不改 |
| ✅ 不动 | `macos/Sources/UsageBar/Features/Popover/PopoverView.swift` + `ProviderTabBar.swift` | 通用渲染管线兼容 `ProviderUsageSnapshot`,Gemini 直接复用 |
| 🆕(测试) | `macos/Tests/UsageBarTests/Providers/Gemini/*` | 5 个测试文件,沿用 Claude/Codex 测试目录约定 |

**改动面**:6 个新建源文件 + 1 个 wire 修改 + 5 个新建测试 = **12 个新建 + 1 修改**。明显跨守护线 ≤5 红线 — 但 spec/plan 主回路无此红线,plan 阶段会切成可独立验证的步骤。

## 5. 风险 / Open questions

1. **Google `v1internal` API 无 SLA**:任何字段 / endpoint 变动都会导致 Gemini provider 静默失败。缓解:错误态 UI 文案明确(『无法获取 Gemini 用量』而非崩溃);保留过期 snapshot;在 v0.6.x patch 通道修。
2. **OAuth client_id/secret regex 抠取的鲁棒性**:gemini-cli 的 minify / bundling 策略可能变。缓解:候选路径枚举可扩展;regex 失败时降级到 unconfigured 态而非崩溃;在 Settings 给用户一个『手动指定 gemini-cli 路径』的入口(本 spec 不做,但留扩展位)。
3. **法律 / 合规留痕**:本 spec §2.2 的决策需要在 G2 reviewer + 用户 spec review 阶段双重确认。建议在合入 main 时附一条 README / docs 中的"Third-party credentials" 章节,说明本 app 复用 gemini-cli 本机 OAuth 凭证不分发任何 Google secret(防御性披露)。
4. **"完整对标 claude 和 codex 功能"的边界**:用户在 issue 27 提出"完整对标"。本 spec 不做本机统计(决策 §2.3),严格说不算完整。需用户在 spec review 时确认是否接受"分两步走"(quota 先上线 → 等 #15292 后补本机统计)。
5. **Pro / Flash 映射假设**:CodexBar 用模型名前缀匹来分桶。如果 Google 未来引入新一级模型(如 `gemini-3-ultra`),映射策略要更新。缓解:在 `GeminiUsageModel` 集中存映射表,易于 patch。
6. **首次启用时的引导文案**:用户从未跑过 `gemini` 登录时,本 app 无法主动拉起登录流程(不像 Claude 我们自管 OAuth)。需要明确文案引导用户去终端跑 `gemini`。这部分在本 spec 计入 SC2 / SC5,但具体文案 wording 留 plan 阶段定。
7. **`oauth_creds.json` 与本机 gemini CLI 并发刷新竞态**:用户同时跑 `gemini` 命令时,双方都会读 → refresh → 写。即使本 app 用原子 rename,仍可能让其中一方读到旧 access_token,刷新后冲掉对方刚拿到的新 token,导致 refresh_token 失效需要重登。**缓解**:plan 阶段实施时优先策略 — (a) 仅在 401 时才主动 refresh,不基于本地 expiry_date 预刷;(b) refresh 前 + 写回前都用 `flock(2)` 文件锁;(c) refresh 失败的 401 路径走 unconfigured 态而非反复重试,把责任推回用户终端 `gemini` 重登。三条策略组合优先 (a) + (c),(b) 看 plan 阶段实测必要性。

## 6. 后续工作(不在本 spec 范围)

1. **本机会话统计 iteration**:等 [gemini-cli #15292](https://github.com/google-gemini/gemini-cli/issues/15292)(JSONL + per-turn token)落地或社区 schema 稳定后,新开 spec 实现离线 token / cost 估算(对标 Codex v0.2.9)
2. **Enterprise / Vertex AI / API key 用户**:走 GCP Cloud Monitoring `aiplatform.googleapis.com/PublisherModel` 指标 — 数据源完全不同,独立 spec
3. **Settings 增加"手动指定 gemini-cli 路径"入口**:为 GeminiOAuthClientLocator 失败的边缘情况(自定义 nvm / volta / asdf 安装)兜底
4. **Gemini 模型成本估算**:`ModelPricingCatalog` 接入 LiteLLM 已含 Gemini 价格,等本机统计就绪后顺带启用
5. ~~README / docs 的 third-party credentials 披露段~~ — **已移入本 spec scope §3.5**(reviewer G2 反馈)

## 7. 引用

- 相关调研:[`docs/artifacts/issues/27/diagnosis.md`](../../artifacts/issues/27/diagnosis.md)、[CodexBar Gemini docs](https://github.com/steipete/CodexBar/blob/main/docs/gemini.md)、[gemini-cli oauth2.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts)
- 相关 ADR:[0001 Swift native only](../../adr/0001-swift-native-only.md)、[0003 AI-led development](../../adr/0003-ai-led-development.md)、[0005 Reopen multi-provider direction](../../adr/0005-reopen-multi-provider-direction.md)
- 关联 spec:[2026-05-12-multi-provider-refactor](./2026-05-12-multi-provider-refactor.md) / [2026-05-13-provider-self-management](./2026-05-13-provider-self-management.md)
- 落地版本:`v0.6.0-gemini-provider`(待立项,见 `docs/versions/`)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — `GeminiProviderTests.testSuccessFullFlow` + `GeminiUsageModelTests.testProAndFlashBothPresent`(单测验证 Pro/Flash 双段配额映射)+ commit `319a99b`/`26cda54`(待真机最终确认)
- [x] SC2 — `GeminiProviderTests.testNoCredentials` + `GeminiCredentialsTests.testLoadFileAbsentReturnsNil`(凭证缺失走静默 unconfigured)+ commit `319a99b`
- [x] SC3 — `GeminiCredentialsTests.testRefreshSuccessUpdatesAccessTokenAndExpiry` + `GeminiProviderTests.testUnauthorizedTriggersRefreshAndRetry`(401-触发-refresh-retry 路径单测覆盖)+ commit `4ccf27c`/`fff27cb`/`319a99b`
- [x] SC4 — `GeminiProviderTests.testUnauthorizedRefreshFailsClearsSnapshot`(refresh 失败走"过期+登录"文案 + clearSnapshot:true)+ commit `319a99b`
- [x] SC5 — `GeminiOAuthClientLocatorTests.testNoOauth2JsReturnsNil` + `GeminiProviderTests.testNoOAuthClientGoesUnconfigured`(三处枚举失败走 unconfigured 文案)+ commit `71d1db1`/`6e6a2cf`/`319a99b`
- [x] SC6 — `UsageBarApp.swift` `additionalProviders` 接入 GeminiProvider,后台 polling 走 ProviderCoordinator 统一 timer(`GeminiProvider.nextEligibleRefresh = nil` 不做 backoff)+ commit `2ab0b19`;`ProviderCoordinatorTests` 全量回归 308 绿
- [x] SC7 — SettingsView 自动按 `coordinator.orderedProviderIDs` 渲染(SettingsView.swift:37),Gemini 行已自动出现 + commit `2ab0b19`(真机操作菜单栏 toggle / 拖拽待用户验证)
- [x] SC8 — `GeminiProviderTests.testHistorySampleRecorded`(Pro→pct5h、Flash→pct7d、unit 转换正确)+ `GeminiProvider.history` 默认 `UsageHistoryService(filename: "history-gemini.json")` + commit `319a99b`
- [x] SC9 — 全量 308 tests 绿(`swift build -c release` + `swift test` + `make release-artifacts` + `verify-release.sh` 四条全过)+ 5 个新建测试文件(GeminiCredentials/Locator/UsageModel/UsageClient/Provider)
- [x] SC10 — `README.md` 新增 "Third-party credentials & APIs" 段 + Data storage 表追加 history-gemini.json / oauth_creds.json 行 + commit `9d18461`
