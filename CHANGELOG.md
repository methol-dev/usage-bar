# Changelog

本仓库的用户视角变更记录。由 AI 在发版 runbook 自动维护（详见 [`docs/runbooks/release.md`](./docs/runbooks/release.md) §5）。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

> 自 v0.0.7 起，本仓库与上游 `Blimp-Labs/claude-usage-bar` 独立编号 — 见 [ADR 0004](./docs/adr/0004-fork-divergence-from-blimp-labs.md)。
> v0.0.6 及之前的历史由上游维护，不在本 CHANGELOG 范围内。

---

## [v0.7.1] — 2026-07-08

> 版本: [`v0.7.1`](./docs/versions/v0.7.1-project-audit-hardening.md)

### 修复（Fixed）

- **修正用量趋势图首点失真**：选择较短时间窗（如 1h/1d）时，窗口外的旧历史点不再被折算进第一个可见数据点，首点不会再显示为整段历史的均值。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）
- **悬停无数据区域不再显示假数据**：图表 X 轴铺满所选时间窗但历史只覆盖一部分时，悬停空白区域不再弹出「0% / 0%」的伪造 tooltip。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）
- **消除重复请求与重复图表数据点**：Claude 用量刷新补上重入保护与账号切换防护，后台轮询、手动 Refresh、修改轮询间隔并发时不再产生重复网络请求和重复历史点；账号切换后在途的旧响应会被丢弃。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）
- **本机成本月度数据文件损坏不再静默丢失**：解码失败的月度文件覆盖前先备份为 `.bak`，源 JSONL 已被 Claude CLI 清理时仍可人工恢复。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）
- **订阅用量获取失败时面板不再整个不可用**：Claude 未登录 / token 过期不再整屏接管弹窗（此前连其他 provider 的 tab 也会消失）；Codex 凭证缺失时同理。Session / Weekly 卡降级为骨架占位，不依赖订阅源的本地用量折线图、本机费用统计与热力图照常显示，错误卡内提供 Retry 入口。（[#41](https://github.com/methol-dev/usage-bar/pull/41)）

### 改进（Changed）

- **popover 渲染性能优化**：费用汇总改为缓存按需重算（原先每次渲染对 31 天全量事件逐条跑正则匹配）；趋势图数据点身份稳定化，悬停不再全量重建图表；热力图分位阈值全网格只算一次；日期解析 formatter 静态缓存；定价表前缀匹配不再每次全表排序。重度用户 popover 悬停/轮询时的主线程卡顿显著减轻。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）
- **VoiceOver 可分辨选中项**：时间范围选择器与 provider tab 的选中项补上 `.isSelected` 标注。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）

### 内部（Internal）

- CI：release workflow 首步预检 `SPARKLE_PRIVATE_KEY`（原先在 GitHub Release 已发布后才校验）、发版时补跑 `swift test`、SwiftPM 依赖缓存；build.yml 去掉冗余的单架构构建。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）
- 脚本：build.sh 构建失败也还原 LiteLLM 快照；mock-server 时间戳每请求现算等 4 项修复；issue 脚本修复 `gh` 默认 30 条截断与并发合并时记错 merge commit。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）
- 文档：versions/specs 索引补缺与状态同步、28 处相对链接层级修正、8 个 spec frontmatter YAML 修复、mock server 与凭证模型描述对齐。（[#40](https://github.com/methol-dev/usage-bar/pull/40)）

### 参考

- 版本计划：[`docs/versions/v0.7.1-project-audit-hardening.md`](docs/versions/v0.7.1-project-audit-hardening.md)

---

## [v0.7.0] — 2026-05-15

> 版本: [`v0.7.0`](./docs/versions/v0.7.0-update-button-position.md)

### 改进（Changed）

- **更新检测按钮移至设置**：「检查更新」按钮从 popover 底部栏移至「Settings → Updates」区段，与更新渠道选项集中在一起，交互更符合直觉。（[#36](https://github.com/methol-dev/usage-bar/issues/36)）
- **菜单栏显示版本号**：popover 底部栏「退出」按钮旁新增当前版本号（如 `v0.7.0`），方便随时确认正在运行的版本。（[#36](https://github.com/methol-dev/usage-bar/issues/36)）

### 参考

- 版本计划：[`docs/versions/v0.7.0-update-button-position.md`](docs/versions/v0.7.0-update-button-position.md)

---

## [v0.6.0] — 2026-05-15

> spec: [`2026-05-13-gemini-provider`](./docs/superpowers/specs/2026-05-13-gemini-provider.md) · 版本: [`v0.6.0`](./docs/versions/v0.6.0-gemini-provider.md)

### 新增（Added）

- **接入 Gemini Code Assist for Individuals**：菜单栏 / Popover 现在可以显示 Pro 配额与 Flash 配额（`remainingFraction` + reset 倒计时），完整对标 Claude / Codex 现有形态。复用本机 `~/.gemini/oauth_creds.json`（由 `gemini` CLI 维护），无需重新登录。（[#27](https://github.com/methol-dev/usage-bar/issues/27)）
- **首次启动自动检测已安装的 AI 工具**：应用第一次打开时，自动检测本机已安装的工具（检测 `~/.claude/`、`~/.codex/`、`~/.gemini/` 等标准路径），仅默认开启已安装 provider 的显示开关；后续以用户自己配置的开关状态为准，不再重复检测。（[#35](https://github.com/methol-dev/usage-bar/pull/35)）

### 修复（Fixed）

- Settings 界面 Provider 列表行高从 44 调高到 60，修复 Gemini 行内容被截断的显示问题。（[#31](https://github.com/methol-dev/usage-bar/pull/31)）
- 菜单栏用量数字统一改为英文格式，修复部分 macOS 系统语言设置下数字显示为中文格式的问题。（[#30](https://github.com/methol-dev/usage-bar/pull/30)）

### 内部（Internal）

- 新增 `Providers/Gemini/` 目录：`GeminiProvider` / `GeminiCredentials`（含 OAuth token refresh + 原子写回）/ `GeminiOAuthClientLocator`（从本机 gemini-cli 安装包动态获取 OAuth client credentials）/ `GeminiUsageClient` / `GeminiUsageModel`（Pro/Flash 双段配额映射）
- 新增 `AIToolDetector`：纯文件系统检测工具类，支持 `CODEX_HOME` / `GEMINI_HOME` 环境变量覆盖，注入 `fileManager`/`environment` 便于单测
- CI 兼容 Xcode 15.4 严格 actor 隔离检查（补标 `@MainActor`）
- 新增 40+ 单元测试（Gemini 各子模块 + AIToolDetector + ProviderCoordinator 首次启动路径）

### 参考

- 版本计划：[`docs/versions/v0.6.0-gemini-provider.md`](docs/versions/v0.6.0-gemini-provider.md)
- 含 spec：`2026-05-13-gemini-provider`

---

## [v0.5.3] — 2026-05-14

> spec: [`2026-05-14-observable-migration`](./docs/superpowers/specs/2026-05-14-observable-migration.md) · 版本: [`v0.5.3`](./docs/versions/v0.5.3-observable-migration-release.md)

### 内部（Internal）

- 全仓状态管理迁移至 Swift Observation framework（`@Observable`）：9 个模型/服务类从旧的 `ObservableObject` + `@Published` 体系切换到 macOS 14 原生追踪机制，手动 Combine 聚合层（`RuntimeAggregator`）随之删除。用户无感知功能变化，内存占用略有改善，属性变化响应更精准。（[#33](https://github.com/methol-dev/usage-bar/pull/33)）

---

## [v0.5.1] — 2026-05-14

> spec: [`2026-05-14-claude-credentials-in-memory`](./docs/superpowers/specs/2026-05-14-claude-credentials-in-memory.md) · 版本: [`v0.5.1`](./docs/versions/v0.5.1-claude-credentials-in-memory.md)

### 移除（Removed）

- usage-bar 不再持久化 Claude 凭证到磁盘。in-memory cache 在启动 / token 过期时从 Claude CLI 的 Keychain 条目重读。旧 `~/.config/usage-bar/credentials.json` / `accounts.json` 不会被读取也不会被覆盖；用户可自行 `rm` 清理。
- **Claude provider 多账号 UI**：`AccountSwitcherView` 移除，`Account switcher` / `Add account` 菜单下线。请用 Claude CLI 切换当前会话；usage-bar 的"多账号"语义现在指"多 provider"（Claude / Codex / Gemini）。
- **内置 OAuth refresh 流程**：token 刷新完全交给 Claude CLI 处理，usage-bar 不再持有 refresh_token。

### 修复（Fixed）

- token 过期后 popover 卡在 "Not signed in" 状态：Retry 按钮现在真正重读 Keychain（之前因 `accounts.json` 存在被短路）。
- 从结构上消除 issue [#22](https://github.com/methol-dev/usage-bar/issues/22) 这一类 OAuth Token Rotation 失败：usage-bar 不再持有 refresh_token，CLI 轮换 token 后不会再被迫退出登录。

---

## [v0.4.1] — 2026-05-13

> spec: [`2026-05-13-docs-cleanup`](./docs/superpowers/specs/2026-05-13-docs-cleanup.md) · 版本: [`v0.4.1`](./docs/versions/v0.4.1-docs-cleanup.md)

### 内部（Internal）

**纯文档治理整理，无用户可见变更，无代码改动。**

- **AI 入口分层**：`AGENTS.md` 重构为三层结构 — L0（30 秒指引含任务反向索引）/ L1（必读骨架：项目快照、文档地图、工作流主回路、7 review gate、6 条 hard gates）/ L2（扩展引用），体量 216 → 140 行
- **CLAUDE.md 瘦身**：102 → 34 行，仅保留 Claude Code 专用坑（Mock server gotcha 与跳板）；Common commands / Issue 驱动配置 / 跨文件架构红线整段迁出
- **新建 `docs/agents/` 子目录**收编分散信息：
  - `quickstart.md` — 任务类型 → 路径反向索引（接 issue / 写新功能 / 发版 / 改 ADR / 写 spec 等）
  - `operations.md` — 构建命令 + Issue 驱动配置 + 守护线 checklist + 跨 runner 工具 preflight + 项目架构红线
  - `conventions.md` — 写作约定 + frontmatter 三表速查 + 命名规范
- **`docs/versions/README.md` 状态对齐**：索引表新增 "Main 已含" / "Tag" 两列；修复 v0.0.7 (planned → in-progress) 与 v0.4.0 (placeholder → shipped) 与 frontmatter 对齐；增加代码层 / 治理层 drift 注解
- **`CONTRIBUTING.md`**：顶部追加 AI-led 提示段（引导贡献者优先走 issue-driven 流程）；Project structure 段从 v0.3.2 之前的扁平结构更新为当前 9 子目录结构
- **runbooks/README**：将 active 与 placeholder runbook 拆为两个独立表，避免混淆

---

## [v0.4.0] — 2026-05-13

> spec: [`2026-05-13-view-layer-modernization`](./docs/superpowers/specs/2026-05-13-view-layer-modernization.md) · 版本: [`v0.4.0`](./docs/versions/v0.4.0-view-layer-modernization.md)

### 内部（Internal）

- **GCD 清理**：消除两处 `DispatchQueue.main.async` 残留，改用 Swift Concurrency（`Task { @MainActor in }` / `.task { await Task.yield() }`），与项目 Swift Concurrency 风格一致
- **Chart hover 简化**：`UsageChartView` 折线图 hover 交互从 `chartOverlay + GeometryReader` 坐标转换改为 `.chartXSelection(value:)`（macOS 14+ Charts 内置 API），删除 ~23 行代码
- **PopoverView 结构化**：5 个 `@ViewBuilder private var` helper 提升为 private nested struct（`ProviderAreaView` / `ClaudeUsageAreaView` / `BottomBarView` / `NoProvidersView` / `NotAuthenticatedView`），改善 SwiftUI diff 精确度，与现有 `ProviderUsageArea` 模式一致

---

## [v0.3.2] — 2026-05-13

> spec: [`2026-05-13-code-structure-hygiene`](./docs/superpowers/specs/2026-05-13-code-structure-hygiene.md) · 版本: [`v0.3.2`](./docs/versions/v0.3.2-code-structure-hygiene.md)

### 内部（Internal）

- 源码目录按职责分 **9 个子目录**（`App / Models / Services / Providers/{Core,Claude,Codex} / Pricing / LocalCost / MenuBar / Features/{Popover,Settings} / Utilities`）；55 个 Swift 文件全部迁移到位，保留完整 `git log --follow` 历史；为后续接入更多 provider 预留零成本扩展位（新 provider 只需新建 `Providers/<Name>/` 目录）
- `UsageService.swift`（886 行）用 `// MARK: -` + `extension UsageService` 块按 OAuth / Polling / Backoff 三段章节化；0 个 access modifier 变更、0 个 method body 变更
- `AppResources.swift` → `BundleLocator.swift`（名实相符；外部 API `usageBarResourceBundle()` 保持不变）
- 删除死资源 `macos/Resources/demo.png`（README 已替换为外链截图）

---

## [v0.3.1] — 2026-05-13

> spec: [`2026-05-13-swiftui-hygiene`](./docs/superpowers/specs/2026-05-13-swiftui-hygiene.md) · 版本: [`v0.3.1`](./docs/versions/v0.3.1-swiftui-hygiene.md)

### 修复（Fixed）

- 用量趋势图 hover：`plotFrame` 在首次布局时为 `.zero`，修复强解包崩溃路径（#25）
- 消费热力图 hover 性能优化：不再每帧重算 53×7 网格，改为 `DragGesture.onChanged` 按需更新
- 本地成本卡片改为 `Button`，VoiceOver 可识别并展开/收起（可访问性）

### 内部（Internal）

- 清理死代码：`CreditLine.currencyCode`、`UsageProvider.supportsBackgroundPolling`（协议要求早已移除，实现端残留）
- `Task.sleep(for:)` 替换 `asyncAfter`；`UsageService` 加 `final`；`onPollTick` 闭包去多余 `Task.detached`

---

## [v0.3.0] — 2026-05-13

> spec: [`2026-05-13-provider-self-management`](./docs/superpowers/specs/2026-05-13-provider-self-management.md) · 版本: [`v0.3.0`](./docs/versions/v0.3.0-provider-self-management.md)

### 新增（Added）

- **全供应商可禁用（含 Claude）**：Settings → Providers 列表每行有「启用」开关；禁用 Claude 后 popover 不再显示 Claude 登录提示，只用 Codex 的用户不受干扰
- **每 provider 独立菜单栏开关**：启用一个 provider 不等于它一定出现在菜单栏；可以「后台采集数据但不占菜单栏空间」
- **全部禁用空态**：所有 provider 都关闭时，popover 显示引导空态而非崩溃

### 修复（Fixed）

- Settings Providers 列表拖拽排序修复：`Form` 内 `ForEach.onMove` 在 macOS 不渲染拖拽手柄；改用 `List` + `.environment(\.editMode, .constant(.active))`，拖拽顺序立即同步到 popover tab 与菜单栏

### 内部（Internal）

- `ProviderCoordinator`：移除 Claude 恒在约束（`setEnabled` 不再 guard `.claude`）；新增 `menuBarVisibleProviderIDs` Set 替代旧 `menuBarProviderID` 单选
- `PopoverView`：按 `enabledIDs` 分路，不再以 `claude.isAuthenticated` 作为全局门控
- 移除 Claude OAuth sign-in / sign-out UI（凭证切为本地 CLI 模式后不再需要手动登录，功能于 issue #20/#23 下线）

---

## [v0.2.3] — 用量统计与存储重设计

> spec: [`2026-05-12-usage-store-redesign`](./docs/superpowers/specs/2026-05-12-usage-store-redesign.md) · 版本: [`v0.2.3`](./docs/versions/v0.2.3-usage-store-redesign.md)（supersede v0.1.2 local-cost-scan）

### 改进（Changed）

- 本地用量从「一次性 30 天估算」升级为**持久化存储**：`~/.config/usage-bar/data/claude/` 下按月份文件保存每次调用的 token 明细（`2026-05.json` 等），另维护按天/月/年三个聚合文件（`agg-day/month/year.json`）
- 后台采集改为**递归增量**：`FileManager.enumerator` 递归扫描 `~/.claude/projects/` 下任意层级的 `.jsonl`（含 `<session>/subagents/agent-*.jsonl` 三层深），per-file size/mtime/行偏移游标，每轮 collect 末尾批量 flush 一次游标（不再逐文件写盘）；绝大多数刷新近乎零开销；启动时一次性回填全部历史
- 金额不落盘：明细与聚合只存 token 数，金额按**当前价格表**实时折算 —— 价格表升级后历史消费自动按新价重算

### 新增（Added）

- popover 新增 **GitHub 贡献图风格的消费热力图**：从用户最早有数据那天铺到今天的网格（不限一年），打开时默认滚到最右（最新）；往左滑看历史；鼠标悬停某格 → 网格下方一行显示该天「日期 · ≈ $X · N 次」（不再用系统 tooltip）；颜色按当天估算消费额分 9 档（轻度用户也能看出梯度）
- 估算卡跟随趋势图的时间范围 picker（1h/6h/1d/7d/30d → 对应窗口的 USD 估算）；版块顺序调整为：趋势图 → 估算卡 → 热力图
- per-model 明细行新增 token 总数；金额/token 用紧凑单位（K/M/B/T，两位小数）；金额前缀简化为「$」（去掉「US」）；collapsed 头部用 SF Symbol icon 展示金额/次数/token
- 「本地估算」卡片保留（数据源切到新存储层，外观不变；标题随时间范围 picker 参数化）

### 安全隐私（Security & Privacy）

- 隐私架构守护延续 + 扩展：parser schema 层不读 `message.content`；明细与游标文件含 sessionId / 绝对路径 → 文件权限 0600（目录 0700）；错误日志只记录错误类型，不记录文件名 / 路径 / 会话 ID / 对话内容

### 内部（Internal）

- 新增 `UsageEventStore` / `ScanCursorStore` / `ClaudeUsageCollector`（actor）+ `UsageAggregator`（纯函数）+ `UsageStatsService`（`@MainActor ObservableObject`）+ `UsageHeatmapView` / `UsageHeatmapModel`
- 退役 `LocalCostScanner`（被存储层 + 采集器取代）；启动时清理 v0.1.2 旧的 `~/Library/Caches/usage-bar/cost-usage/`
- 损坏月明细 → 游标重置全量重读：`mergeEvents` 返回非空 dirtyMonths 时，清掉本轮所有已扫 jsonl 的游标 + `rebuildAllAggregates()`，避免被清空的损坏月里 pre-cursor 事件永久丢失
- 已统计数据不随源文件删除而清除：`mergeEvents` 只 union、`rebuildAggregates` 从落盘月明细重算，删掉的 jsonl 下次扫描只是跳过
- 多账号场景：本机用量统计是跨账号的，切换账号不再清空 / 重算（避免无意义闪烁）
- 新增约 40 个测试（基线 131 → ~162，含发布后迭代新增）；删除 7 个 LocalCostScannerTests
- 已知遗留：两处 Swift-6 严格并发警告（Swift 5.9 下无害），留待项目做 strict-concurrency pass 时统一处理
- 治理：spec 过 G2（含 security/privacy）/ plan 过 G3 / 实现过 G5（含 security/privacy，命中并修复「损坏月明细不清游标导致 pre-cursor 事件丢失」）；每个实施 Task 一轮 spec+quality review

## [v0.2.2] — 2026-05-11

### 新增（Added）

- **Sparkle 双通道支持**：Settings → "更新通道" Picker，可选「稳定版」/「Beta（实验性）」
- Beta 通道用户**也**收稳定版更新（不会"卡在 beta"）：beta `allowedChannels = ["stable", "beta"]`
- 切换通道无需重启 app；下次 checkForUpdates 自动按用户选择过滤 appcast items
- Settings UI 含 "Beta 通道包含未稳定版本，仅建议测试用户启用" 一行说明
- 净化机制：用户手动 `defaults write` 写入未知 channel 值时，UI 自动回归默认 stable，AppUpdater 也 fallback 到 stable

### 内部（Internal）

- 新增 `UpdateChannel.swift`：`enum { stable, beta }` + `CaseIterable` + `current(defaults:)` 双 fallback (nil + 未知 rawValue) + `allowedChannelStrings(for:)`
- 新增 `UpdaterDelegateImpl: NSObject, SPUUpdaterDelegate` 独立 class（避免 `AppUpdater` 转 NSObject 牵连 KVO 生命周期 + 解决 `nonisolated`/`@MainActor` 冲突）
- `AppUpdater.init(bundle:, defaults: UserDefaults = .standard)` 加 UserDefaults 注入 seam（测试可用 `UserDefaults(suiteName:)` 隔离）
- SPUStandardUpdaterController 通过 `updaterDelegate: delegateImpl` 接入；`AppUpdater` 强持有 `delegateImpl`（Sparkle weak 持有 delegate）
- `SettingsView` Form 内新增 `Section("更新通道")` 位置 Notifications 之后 / Account 之前；Picker 绑定 `@AppStorage("updateChannel")`；`.onAppear` 净化未知 rawValue
- `docs/runbooks/release.md` 新增 §8.5 Sparkle 双通道：tag pattern (`v*-beta.N` → beta channel)、同一 appcast、跨 channel 版本比较、公证 HARD GATE 依赖
- 新增 11 case 测试（基线 120 → 131）：8 UpdateChannelTests（含 fallback nil / fallback unknown "canary" / display name / allCases）+ 3 AppUpdaterChannelTests（用 disposable UserDefaults suite + SPUUpdaterStub helper）

### 安全 / 隐私（Security）

- channel 不涉及 token；SC7 永久警示（v0.1.1 起）继续：所有 SC_AUTO 守护（NO_PRINT_TOKENS / NO_REAL_TOKEN_PREFIX）0 匹配
- `UserDefaults.standard` per Apple docs thread-safe；Sparkle delegate 从任意线程调用 `allowedChannels(for:)` 无 race
- 现有 12 case UsageServiceTests + 3 case SettingsViewTests 单独 `--filter` 跑全绿，无回归

### 参考

- spec: [`2026-05-11-sparkle-beta-channel`](./docs/superpowers/specs/2026-05-11-sparkle-beta-channel.md)
- 版本: [`v0.2.2`](./docs/versions/v0.2.2-sparkle-beta-channel.md)
- runbook: [`release.md §8.5`](./docs/runbooks/release.md)

### 后续 prerequisite

- 实际打 beta tag 需 v0.2.1 Apple 公证落地（HARD GATE，凭证操作待用户授权）

---

## [v0.2.0] — 2026-05-11 🏁 Phase 2 里程碑

逻辑标记版本，无新功能 spec。承接 v0.1.1~v0.1.3 数据源扩展能力的稳定阶段："数据厚度赶上 CodexBar"目标达成。

### Phase 2 阶段产出

- v0.1.1 Claude CLI Keychain 凭证零配置登录
- v0.1.2 本地 JSONL 30 天 cost 估算 + parser 隐私架构守护（schema 不读 message.content）
- v0.1.3 多账号支持（accounts store + 迁移 + popover 切换器 + race fix）

### 下一阶段（v0.2.x 基建/工具链）

- v0.2.1 Apple 公证（hard gate — 凭证操作需用户授权）
- v0.2.2 Sparkle beta 通道

### 不打 tag

沿用 v0.1.0 经验：里程碑标记仅用于路线图阶段化展示，发版统一在子版本累积时考虑。

---

## [v0.1.3] — 2026-05-11

### 新增（Added）

- **多账号支持**：一份 app 同时管理多个 Claude OAuth 账号
- 数据模型升级：从单 `credentials.json` 升级到 `accounts.json` v2（含 `activeIndex` + `accounts[]` 数组）
- 自动迁移：旧 `credentials.json` / legacy token file 启动时无感升级到 `accounts[0]`（label "账号 1"）
- popover 顶部账号下拉切换器（仅 accounts 数 > 1 时显示，单账号用户零打扰）
- "添加账号..." 入口走标准 PKCE flow，完成后 append 而非覆盖；CodeEntryView 顶部标题区分 "登录" / "添加账号"
- 切换账号立即清前账号 usage / lastError / localCost30d / accountEmail 占位 + 重启 polling + 新 token fetch

### 内部（Internal）

- 新增 `StoredAccount` { id: UUID, label, addedAt, lastUsed, credentials } + `StoredAccountsFile` v2 schema（含 `activeIndex` clamp + `activeAccount` computed）
- `StoredCredentialsStore` 加 `accountsFileURL` / `loadAccounts` / `saveAccounts` / `deleteAccounts`（fileManager/encoder/decoder/ensureDirectoryExists 提升 internal）
- 双写镜像设计：v1 `credentials.json` 始终是 active account token mirror，保持 v0.1.0~v0.1.2 single-account API 行为不变（103 测试 0 回归）
- 双写原子性：`saveAccounts` 成功但 v1 `save` 失败时回滚 accounts.json（避免持久分歧）；首次 sign-in 半成品时 deleteAccounts 清理
- `UsageService` 加 `@Published accounts` + `activeAccountId` + `accountSwitchEpoch` 单调递增 + `currentFetchTask` 持有
- `switchAccount(to:)` 切换：cancel 旧 fetch + refresh + timer + epoch++ + saveAccounts + 双写 v1 mirror + 清瞬态 + startPolling
- `beginAddAccount()` 触发 `startOAuthFlow`；`completeSignIn(_ credentials:)` 抽取自 `submitOAuthCode`，empty/append 双路径 + add-account 路径先 cancel/epoch++ 再 save（避免毫秒窗口 in-flight refresh 污染）
- `fetchUsage` / `performRefresh` 入口捕获 epoch；写 `self.usage` / `saveCredentials` 前比对 epoch；不匹配则丢弃响应（race fix 防止账号切换后旧响应覆盖新清空状态）
- `signOut` 升级：deleteAccounts + 清 accounts/activeAccountId/localCost30d/codeVerifier/oauthState/isAwaitingCode + epoch++ + cancel currentFetchTask
- 新增 `AccountSwitcherView`（独立 SwiftUI 组件 G3-B5 决议）：accounts.count <= 1 自隐藏；> 1 时 Menu + 当前账号 label + 下拉切换 + "添加账号..." + a11y label
- `PopoverView` 顶层路由调整：`isAwaitingCode` 提升到 `isAuthenticated` 之外，让 add-account 流程也能看到 CodeEntryView
- 新增 17 case 测试（基线 103 → 120）：StoredAccountsFileTests 4 + StoredCredentialsStoreMigrationTests 5（含 fail-safe via SetAttributesFailureFileManager mock）+ UsageServiceMultiAccountTests 8

### 安全 / 隐私（Security）

- v0.1.1 / v0.1.2 SC7 永久警示延续 + 扩展：
  - `accounts.json` 0600 权限同 credentials.json；目录 0700
  - NSLog 仅 `type(of: error)`，不 leak account.credentials / lastPathComponent / 完整路径
  - 测试 mock 全部 `mock-` / `msg_mock_` / `req_mock_` 前缀，禁止真实 API key 前缀
- 自动化三守护：
  - `SC_AUTO_NO_PRINT_TOKENS`（扩 `account.credentials` 关键字）
  - `SC_AUTO_NO_REAL_TOKEN_PREFIX`（后置硬匹配防 spec 文字误报）
  - **`SC_AUTO_SC11_GUARD`**（git diff 自 spec 立项 commit 仅允许触白名单 5 文件 — StoredCredentials/StoredAccount/UsageService/AccountSwitcherView/PopoverView，确保不破坏 OAuth/refresh/Settings/Notifications/历史功能）
- v1 `credentials.json` 永久保留迁机风险：与 v0.1.0~v0.1.2 同款，accepted risk；后续 v0.2.x 评估 macOS Keychain item 替代 plaintext 文件
- race fix（双 G5 reviewer 命中）：accountSwitchEpoch + currentFetchTask 持有 + cancel；switchAccount 与 completeSignIn add-account 路径都先 cancel/epoch++ 再 save，避免账号切换瞬间旧 in-flight task 用旧 token 写到新 account

### 参考

- spec: [`2026-05-11-multi-account`](./docs/superpowers/specs/2026-05-11-multi-account.md)
- 版本: [`v0.1.3`](./docs/versions/v0.1.3-multi-account.md)

---

## [v0.1.2] — 2026-05-11

### 新增（Added）

- **本地 30 天成本估算**：popover 新增"本地 30 天估算 ≈ $X.XX"卡片（点击展开 per-model 调用次数 + USD 明细）
- 数据源：扫本地 Claude CLI JSONL 日志（`~/.claude/projects/**/*.jsonl` + `~/.config/claude/projects` + `$CLAUDE_CONFIG_DIR/projects` 三路径优先级）
- 价格表：LiteLLM-compatible 离线快照（截至 2026-05-11，覆盖 Opus 4 / Sonnet 4 / Haiku 4 全 family + 3.x 兼容）；未知模型不阻塞，UI 标注"含 N 条未知模型调用记录（价格表过时？）"
- 60s 内存 + 磁盘缓存（`~/Library/Caches/usage-bar/cost-usage/claude-v1.json`），连续打开 popover 不重扫
- 滚动 30 天窗口；按 `(message.id, requestId)` 元组去重流式块；`requestId` 缺失自动回退用 `msg.id` 作 dedup key
- 未装 Claude CLI / 无 JSONL 用户：cost 卡完全隐藏（不显示 $0.00 误导）

### 内部（Internal）

- 新增 `ClaudePricing.swift`（11 个已知模型 family 价 + normalize 去日期后缀 + lookup nil = unknown）
- 新增 `JSONLCostParser.swift`（actor-friendly 纯函数；schema 主动不 decode `message.content`）
- 新增 `LocalCostScanner.swift`（actor 隔离 + 60s 缓存 + 30 天滚动窗 + per-model 累积 + scanRoots 可测试 overload + Caches dir force-unwrap 加 NSTemporaryDirectory 兜底）
- 新增 `LocalCostCard.swift` 独立 SwiftUI 组件（避免 PopoverView 380+ 行膨胀）
- `UsageService.refreshLocalCostIfNeeded()` async：内部 `Task.detached` 跑 scanner + `await MainActor.run` 显式标注写回，避免 IO 期间持有 MainActor
- `UsageBarApp.task` 启动序列：bootstrap CLI → refresh local cost → startPolling；polling timer 内**不**调用 scan
- 新增 19 case 单测（4 ClaudePricing + 8 JSONLCostParser + 7 LocalCostScanner，含 SC7 守护 testEnvelopeDoesNotDecodeContentField + dedup + 30d 窗 + cache hit/miss + scanRoots env override + aggregation）；总数 84 → 103

### 安全 / 隐私（Security）

- **隐私架构强守护（v0.1.1 SC7 事故警示延续 + 扩展）**：
  - parser `Envelope.Message` schema **类型层禁止** `content` 字段（schema-level 守护，非 runtime discipline）
  - `testEnvelopeDoesNotDecodeContentField` Mirror 反射验证 `JSONLUsageEvent` 无 content/contentBlocks/text 属性，未来若有人意外添加立即红灯
  - 错误日志**只 log error type**，不 log 文件名（含 session UUID 半结构化隐私信息）
  - 测试 mock JSONL 用 `mock-` / `msg_mock_` / `req_mock_` 前缀，禁止真实 API key 前缀
- 自动化三守护：
  - `SC_AUTO_NO_PRINT_TOKENS`（扩 `lastPathComponent` / `message.content` / `jsonlLine` 关键字）
  - `SC_AUTO_NO_REAL_TOKEN_PREFIX`（后置 `[0-9a-zA-Z]` 硬匹配 `sk-ant-(oat|ort|api)` / `sk-proj-` / `AKIA[0-9A-Z]{16}` 三家真 token 前缀）
  - `SC_AUTO_NO_CONTENT_READ`（锚定 `message.content` / `JSONLUsageEvent.content` / `Envelope.Message.content:` 不误报 `let content` 变量）
- v0.1.1 事故警示永久延续：禁止把任何用户对话日志贴 commit / spec / PR / 测试 fixture；测试 fixture 全部由作者手写

### 参考

- spec: [`2026-05-11-local-cost-scan`](./docs/superpowers/specs/2026-05-11-local-cost-scan.md)
- 版本: [`v0.1.2`](./docs/versions/v0.1.2-local-cost-scan.md)

---

## [v0.1.1] — 2026-05-11

### 新增（Added）

- **Claude CLI 凭证零配置登录**：已装 Claude Code CLI 的用户首次启动 app 自动复用 OAuth 凭证（macOS Keychain `Claude Code-credentials`），无需走 PKCE 浏览器流程
- 首次启动会弹出"允许 UsageBar 访问 Claude Code-credentials"提示；选"始终允许"后续启动免提示
- 拒绝 / 取消 / 未装 Claude CLI 时静默降级走原 sign-in 流程，行为与 v0.1.0 一致
- 已 sign-in 用户不受影响（不覆盖已有 credentials.json）

### 内部（Internal）

- 新增 `ClaudeUsageStrategy` protocol 骨架（单方法 `loadCredentials() async throws -> StoredCredentials?`），为后续 v0.1.2 本地 cost 扫描 / v0.1.3 多账号 / 未来扩展数据源 spec 预留扩展点
- 新增 `ClaudeCLICredentialsStrategy` 实现：`SecItemCopyMatching` 读 Keychain（kSecAttrService + kSecAttrAccount=NSUserName()）+ Task.detached 避免主线程阻塞 + 4 种"权限/不存在" OSStatus 静默降级 + JSON schema decode
- `UsageService.bootstrapFromCLIIfNeeded()` @MainActor async：启动期一次性尝试，不破坏现有 OAuth / refresh / polling 流程
- `UsageBarApp.task` 启动序列调整：bootstrap 后再判 setupComplete，bootstrap 成功用户跳过 SetupView
- 新增 6 case 单测：valid decode / missing oauth / missing accessToken / nil 字段 / ms→s 转换 / LoadError 脱敏；总数 78 → 84

### 安全 / 隐私（Security）

- **永久安全约束 SC7**（事故警示，源自 v0.1.1 设计阶段真实 token 泄漏事故，已立即轮换）：
  - 源代码与测试中**禁止 print / NSLog / os_log / Logger 输出 credentials 任何字段**
  - 错误日志只记录 "credentials parse failed: <error type>" 不带 raw value
  - LoadError 实现 CustomStringConvertible 仅输出 case 名（不带 OSStatus 数值）
  - Swift Testing 断言禁止对 token 字段做字面比较（用 hasPrefix / count / nil-ness）
  - 测试 mock 用 'mock-' 前缀，禁止 'sk-ant-' 真实前缀
- 自动化双守护：`SC_AUTO_NO_PRINT_TOKENS`（Sources/ grep print/log×token 字段）+ `SC_AUTO_NO_REAL_TOKEN_PREFIX`（全仓 grep `sk-ant-(oat|ort|api)[0-9]` 真 token 前缀）

### 参考

- 版本计划：[`docs/versions/v0.1.1-claude-cli-credentials.md`](./docs/versions/v0.1.1-claude-cli-credentials.md)
- 含 spec：`2026-05-11-claude-cli-credentials`
- 母法：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)

---

## [v0.1.0] — 2026-05-11 — Phase 1 milestone（逻辑标记）

> **注**：本版本无新功能、无新代码、无 binary release、无 Sparkle 自动更新。
> 仅作为 "Phase 1 完成"的逻辑里程碑标记，由用户决策"不打 tag"。完整 G7 发版（Apple 公证 + Sparkle 推送）留待后续 v0.x 阶段处理。

### 聚合（aggregated from v0.0.7~v0.0.11）

Phase 1 阶段性体验目标"看起来像 SessionWatcher 了"已达成：

- 📚 **v0.0.7**：文档治理框架立项（ADR / spec / version / runbook / user-guide 六大目录 + AGENTS.md / 7 review gate / 跨模型 reviewer 矩阵）
- 🎨 **v0.0.8**：PopoverView hero 重做（5h hero 56pt 大字号 + 7d secondary 28pt + capsule 进度条 + reset countdown 紧凑格式）
- 🎨 **v0.0.9**：6h 趋势箭头 ▲▼ + 增量百分点（基于现有 history.json）
- 🎨 **v0.0.10**：菜单栏多显示模式（icon / percent / percent+trend）可在 Settings 切换
- 🎨 **v0.0.11**：5h 配速指示器（On pace / In deficit + Runs out / In reserve）

### 工程指标

- 累计 78 个 swift test，全 0 failures
- 5 个 spec 共 60 个 spec_criteria 全数 done，每版本走完 G2 / G3 / G5 / G6 四轮独立 reviewer review
- 21 个原子 commit（见 `git log`），所有视觉变更独立可 revert
- 仅 Sparkle 一个第三方运行时依赖，无新增

### 后续

Phase 2（v0.1.x）将引入数据源多路径（Claude CLI 凭证复用 / 本地 JSONL cost 扫描 / 多账号），追上 CodexBar 的功能广度。

### 参考

- 版本计划：[`docs/versions/v0.1.0-phase1-milestone.md`](./docs/versions/v0.1.0-phase1-milestone.md)
- 含 spec：聚合 v0.0.7~v0.0.11

---

## [v0.0.11] — 2026-05-11

### 新增（Added）

- **5h 配速指示器**：参考 CodexBar，hero card 进度条下方现可显示当前 5 小时窗口的配速状态
  - **N% over pace · runs out in 1h 23m**（红）— 当前速率会在 reset 前用完，给出预计耗尽时间
  - **N% under pace**（绿）— 用量比预期慢，有余量
  - **On pace** 默认不显示，避免打扰
- 早期窗口（开窗 < 3%）静默不显示，避免噪声抖动
- reset 已过容错降级为 on pace（避免显示历史窗口的"in reserve"误导）
- 7d 窗口不显示 pace（线性外推假设过强；调研 §2.7 同款决策）
- 不引入 ML 等营销话术；纯线性外推（current_rate × remaining_pct）

### 内部（Internal）

- 新增 `PaceCalculator.swift`：`enum PaceState { onPace / inDeficit / inReserve }` + 顶层 `computePaceState(currentPct:resetDate:windowDuration:now:)` 纯函数
- 新增 `PaceCalculatorTests` 9 case：happy 三态 + 边界（早期窗口隐藏 / nil 容错 / reset 已过 / currentPct=100 / runs out 数学边界附数学推导注释）
- `UsageHeroCard` 接口加可选 `pace` 参数（默认 nil，不破坏 v0.0.8/9/10 现有 call site），#Preview 升级 4 张示例覆盖 4 种 pace 状态
- `PopoverView` usageView 计算 pace5h 传入 5h hero card；7d 不传 pace
- spec 走完 G2 / G3 / G5 / G6 共四轮独立 reviewer review；G2 独立命中 reset 已过路径误导 bug + currentPct=100 edge case；G5 命中 paceText 双 Date() 时钟竞争
- commit 拆分（spec / Calculator+测试 / hero card+popover / G5 修订 / G6 收尾）

### 参考

- 版本计划：[`docs/versions/v0.0.11-pace-tracking.md`](./docs/versions/v0.0.11-pace-tracking.md)
- 含 spec：`2026-05-11-pace-tracking`
- 母法：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)

---

## [v0.0.10] — 2026-05-11

### 新增（Added）

- **菜单栏多显示模式**：Settings → General → Menubar Display 可切换 3 种显示风格
  - `Icon`（默认）：双窗口进度条图标（保持现状）
  - `Percent text`：紧凑文本如 `5h 42%`
  - `Percent + trend`：在百分比旁叠加 ▲/▼ 趋势（如 `5h 42% ▼5`，需 ≥6h history）
- 切换模式实时生效（@AppStorage 跨视图同步），不需重启 app
- 默认仍是 Icon 模式 — 升级用户菜单栏视觉无变化

### 改进（Changed）

- 复用 v0.0.9 趋势算法（`computeTrend`）：trend mode 与 hero card 同源、单位约定一致

### 内部（Internal）

- 新增 `MenuBarDisplayMode.swift`：enum + `formatMenuBarPercent` helper，9 case 单测覆盖（nil / 边界 / round / roundtrip / 默认值防御 / case 数量防御）
- 新增 `MenuBarLabel.swift`：SwiftUI View 三分支（icon / percent / percent+trend），未登录走 fallback 显示 `5h —`
- `UsageBarApp` MenuBarExtra label 替换为 MenuBarLabel；.task 闭包保留（startPolling→scheduleTimer 自带 timer?.invalidate 已幂等，重复执行安全）
- `SettingsView` 加 General section displayMode Picker，与 polling interval 同列
- @AppStorage 直接绑定 enum（SwiftUI 原生 RawRepresentable + RawValue==String 支持），消除 String<->enum 中间映射；G5 review 触发了从 Binding(get:set:) 到直接 $menubarMode 的简化重构
- spec 走完 G2 / G3 / G5 / G6 共四轮独立 reviewer review；commit 拆分（spec / enum+测试 / View+接入 / G5 修订 / G6 收尾）；不动数据层 / OAuth / Notifications / 现有 popover 视觉

### 参考

- 版本计划：[`docs/versions/v0.0.10-menubar-display-modes.md`](./docs/versions/v0.0.10-menubar-display-modes.md)
- 含 spec：`2026-05-11-menubar-display-modes`
- 母法：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)

---

## [v0.0.9] — 2026-05-11

### 新增（Added）

- **趋势箭头 ▲▼**：5h / 7d hero 卡片 label 旁显示近 6h 趋势，如 `5-Hour ▲ 12%` 表示当前比 6 小时前高 12 个百分点；可一眼看出用量在涨还是在落
- 上升趋势用红色（与现有"高用量为红"心智一致），下降趋势用绿色
- 微小波动（|Δ| < 1 个百分点）视为持平不显示，避免视觉抖动
- 数据不足时不显示（首次启动 / 清缓存后约需 6 小时累积 history）

### 改进（Changed）

- 完全复用既有 30 天 `history.json`（`~/.config/usage-bar/`），不引入新存储

### 内部（Internal）

- 新增 `TrendCalculator.swift` 顶层纯函数 `computeTrend(currentPct:points:metric:lookback:now:)`，含明确的单位约定：currentPct 0-100 / UsageDataPoint.pct5h 0-1，函数内部自动对齐
- 新增 `TrendCalculatorTests` 10 case：方向 / flat / 数据不足 / nil current / .rounded() 边界（1.4→1, 0.9→nil）/ 多 baseline 取最新 / pct7d KeyPath / **显式命名 testUnitConversion**（防御未来 baseline*100 误删）
- `UsageHeroCard` 接口加可选 `trend: TrendIndicator?` 参数（默认 nil，不破坏 v0.0.8 现有 call site），#Preview 升级为含 trend 三档示例
- spec 走完 G2 / G3 / G5 / G6 共四轮独立 reviewer review；G2 review 独立命中并修复了 currentPct 与 pct5h 单位 100x 误差 bug；commit 拆分（spec / Calculator / 接入 / G5 修订 / G6 收尾）

### 参考

- 版本计划：[`docs/versions/v0.0.9-trend-arrows.md`](./docs/versions/v0.0.9-trend-arrows.md)
- 含 spec：`2026-05-11-trend-arrows`
- 母法：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)

---

## [v0.0.8] — 2026-05-11

### 改进（Changed）

- **Popover 视觉重做**：5h 窗口提升为 hero 卡片（56pt 大字号数字 + 紧凑 reset countdown），7d 窗口降级为 secondary 卡片（28pt 数字）；不再四个窗口平权显示，更易一眼看懂当前最关键的指标
- **进度条改 capsule**：5h / 7d 进度条从默认 SwiftUI ProgressView 改为 Capsule 形状（高度 8pt，圆角与高度匹配），视觉与 hero 字号协调
- **Reset 时间紧凑显示**：原 SwiftUI 默认 `in 1 hour` 风格改为紧凑 `1h 23m` / `12m` / `<1m`，节省 hero 卡片空间；nil 与已过期时不显示
- **Popover 宽度** 340 → 360pt，容纳 hero 数字与 reset 标签
- 配色阈值与现有保持一致：< 60% 绿 / 60-80% 黄 / ≥ 80% 红
- Per-Model（Opus / Sonnet）/ Extra Usage / 历史图表 / 控制行均保留不变；OAuth 与数据层未触

### 内部（Internal）

- 新增 `UsageHeroCard.swift`（含 hero/secondary 两档尺寸 + CapsuleProgressBar 子组件 + Xcode `#Preview` 三档示例）
- 新增 `ResetCountdownFormatter.swift` 纯逻辑函数 + `ResetCountdownFormatterTests`（6 case，覆盖 ≥1h / 仅分钟 / nil / 已过期 / 亚分钟 / 60s 整点边界）
- spec 走完 G2 / G3 / G5 / G6 共四轮独立 reviewer review，每轮 verdict 与作者响应均记入 spec.reviews
- commit 拆分原则：spec 立项 / 底层组件 / PopoverView 接入 / G5 修订 / G6 收尾分离，便于单独 revert

### 参考

- 版本计划：[`docs/versions/v0.0.8-hero-popover.md`](./docs/versions/v0.0.8-hero-popover.md)
- 含 spec：`2026-05-11-hero-popover`
- 母法：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)

---

## [v0.0.7] — 2026-05-11

### 新增（Added）

- **文档治理框架**落地：研究 / 设计 spec / ADR / 版本路线 / 运维 runbook / 用户文档六大目录建立，配套模板与索引
- **AGENTS.md** 治理入口：所有 AI runner 进仓库的中立指南；含 5 分钟上手、文档地图、工作流、工具可用性 preflight、hard gates
- **4 份 ADR**：Swift 原生（0001）、Claude-only 差异化（0002）、AI 主导 + 人类辅助（0003）、与 Blimp-Labs 上游独立分叉（0004）
- **7 个 review gate**：G1~G7 完整覆盖调研、spec、plan、实施、PR、merge、release；含跨模型 / 跨 subagent reviewer 矩阵与不可用时 fallback 路径
- **版本路线**：每个版本占位文件含 frontmatter 与 placeholder guardrail（首批 13 版本路线见 `docs/versions/README.md`）
- **CHANGELOG.md** 本文件：从此存在，AI 维护

### 改进（Changed）

- `CLAUDE.md`：顶部新增 governance 跳板指向 AGENTS.md；新增 *Project state* 与 *Before claiming work done* 两节；原技术细节（commands / architecture / mock server gotcha / style）保留不变

### 修复（Fixed）

- *（无代码变更）*

### 安全 / 隐私（Security）

- *（无代码变更，但 ADR 0004 修正了 README 中的发版 URL 指向以避免本仓库发版意外推送到上游 GitHub Pages 的潜在事故）*

### 内部（Internal）

- 业界竞品调研报告归档至 `docs/research/competitive-analysis.md`（含 SessionWatcher / CodexBar / ccusage / Claude-Code-Usage-Monitor 详细分析）
- spec 母法引入 17 条机器可判定的 spec_criteria（SC1~SC17）+ `## Verification log` 区块作为 G6 验收形式
- spec 母法已通过 G2 跨 session 独立 reviewer 审查（5 BLOCKING + 8 RECOMMENDED 全数受理，详见 spec §10 review response）

### 参考

- 版本计划：[`docs/versions/v0.0.7-docs-governance.md`](./docs/versions/v0.0.7-docs-governance.md)
- 含 spec：`2026-05-11-docs-governance`
- 母法：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)
