---
alwaysApply: false
globs: "**/*.swift"
---

# Swift 规则 — 架构红线 + 代码风格

## 架构红线（改代码前必读）

> 跨文件的"大图"无法从单个文件推断出来；本节列出实施时容易踩到的不变量。

1. **`UsageService` 是 Claude provider API 状态的单源真相**。它拥有 OAuth（PKCE + 浏览器回调粘贴）、token 刷新、polling timer、指数退避。其他类型通过 `@StateObject` 从 `UsageBarApp` 注入并读 published 属性 — **不要在其他地方重复 fetch / auth 逻辑**。位置：`Providers/Claude/UsageService.swift`（v0.3.2 同文件 `// MARK:` 分为 OAuth / Polling / Backoff 三段 + UsageProvider conformance）。

2. **注入 service 组成 app**，在 `App/UsageBarApp.swift` 中 wire：
   - `UsageService` — API 状态
   - `UsageHistoryService` — 内存 ring buffer，每 5 min + `willTerminate` flush 到磁盘；30 天保留
   - `NotificationService` — 阈值通知
   - `AppUpdater` — Sparkle 包装
   - `UsageService` 持 history/notification service 的弱引用，polling loop 推 sample 并触发 alert

3. **Token & history 存在 `~/.config/usage-bar/`**：
   - `credentials.json`（0600，含 access + refresh + expiry + scopes；回退读历史 plaintext `token` 文件 — 见 `Models/StoredCredentials.swift`）
   - `history.json`
   - 新格式首次写入时删除 legacy `token` 文件
   - v0.5.1 起 Claude 凭证 in-memory only（启动时从 Claude CLI Keychain 借读，不再落盘 `credentials.json`）

4. **模型价格数据走打包的 LiteLLM 快照**，不是手维护表。`ModelPricingCatalog` 加载 `litellm_model_prices.json`（upstream: `BerriAI/litellm` 的 `model_prices_and_context_window.json`），优先级：
   1. `~/.config/usage-bar/litellm_model_prices.json`（运行时缓存，3h 后台刷新 — 见 `ProviderCoordinator.onTickSideEffects`）
   2. 打包副本
   3. 空表（UI 降级为"定价数据未加载"）

   `build.sh` 在 `swift build` 前 `curl` 新快照到 `macos/Sources/UsageBar/Resources/litellm_model_prices.json`，组装 bundle 后 `git checkout` 回来（保持 `git status` 干净；fetch 失败就用 committed 副本）。`OpenAIPricing` / `ClaudePricing` 只保留 `normalize` / `displayName`；所有价格查询走 `ModelPricingCatalog`（含逐级回退 candidate chain 解析 codex CLI 别名）。`THIRD_PARTY_LICENSES.txt`（LiteLLM MIT）一并打包；两个资源都被 `verify-release.sh` 检查。

5. **Bundle 创建是自定义的，不是 stock SwiftPM**。`macos/scripts/build.sh` 跑 `swift build -c release`，然后手工组装 `.app/Contents/{MacOS,Resources,Frameworks}`，复制 SwiftPM 资源 bundle（`UsageBar_UsageBar.bundle`），用 `actool` 编译 `Resources/Assets.xcassets`，嵌入 `Sparkle.framework`。新增打包资源需要：
   1. 放进 SwiftPM 资源 bundle（在 `Package.swift` `resources: [.process("Resources")]` 声明）
   2. 任何新 `.app/Contents/Resources/...` 不变量也要在 `macos/scripts/verify-release.sh` 中强制检查

6. **Sparkle 在 build 时由 `SU_FEED_URL` gate**。env 变量未设（本地构建默认），`build.sh` 从 `Info.plist` 剥掉 `SUFeedURL`，updater 失效。Release CI 注入 feed URL。**不要在 `Info.plist` 中硬写 feed URL**。

7. **发版由 tag 驱动**。push `v*` tag 触发 release workflow：一次 build → 产 ZIP（Sparkle）+ DMG（手装）→ verify → 由 ZIP 生成签名 Sparkle `appcast.xml` → deploy 到 GitHub Pages。需要 `SPARKLE_PRIVATE_KEY` repo secret。`Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion` 在 build 时由 `APP_VERSION` 环境变量或 git tag 注入；plist 中写死的 `1.0.0` 是历史占位，**不要手改**。

## 代码风格

1. 第三方依赖最小化：Sparkle 是唯一运行时 dep。加新依赖属 hard gate（见 `AGENTS.md`），且要同步：`Package.swift` + `verify-release.sh`（若打包进 bundle）+ `build.sh` framework 嵌入步骤。
2. 一个文件一个主 SwiftUI view（约定：`Features/Popover/PopoverView.swift` / `Features/Settings/SettingsView.swift` / `Features/Popover/UsageChartView.swift`）。
3. 所有 UI-touching service 类是 `@MainActor`；扩展时保留这个 annotation。
4. Provider 逻辑住 `Providers/<Name>/`；`ProviderCoordinator` 驱动统一轮询周期。新 provider 走 [`docs/runbooks/add-new-provider.md`](../../docs/runbooks/add-new-provider.md)，所有目录/抽象决策必须为后续 provider 留低成本扩展位。
