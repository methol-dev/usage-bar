---
id: 2026-05-12-settings-provider-list
title: Settings 改 provider 列表（拖动排序 + 启用开关 + 菜单栏单选子开关）+ 去 Account 区 + Codex 统一 polling interval + 刷新纪律
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.10
related_adrs: [0005]
related_research: [codex-data-sources]
related_specs: [2026-05-12-multi-provider-refactor, 2026-05-12-codex-provider, 2026-05-12-codex-history-trend, 2026-05-12-codex-cost-heatmap, 2026-05-12-popover-redesign]
spec_criteria:
  - id: SC1
    criterion: "**`ProviderCoordinator` 的 provider 顺序 / 启用集 / 菜单栏 provider 模型**：`ProviderCoordinator` 新增 `@Published var orderedProviderIDs: [ProviderID]`（持久化 key `providerOrder`，存 `[String]`；默认 = `registry.orderedIDs`；只含已注册的；读盘后过滤掉未注册的、补上漏掉的新 provider 接到末尾）+ `@Published var enabledProviderIDs: Set<ProviderID>`（持久化 key `enabledProviders`，存 `[String]`；默认 = 全部已注册；**Claude 强制恒在集合里**——它承载登录 UX，setter 里强制 `insert(.claude)`）。把现有 `@Published var primaryProviderID` 改名为 `menuBarProviderID`（持久化 key **沿用** `primaryProviderID` —— 兼容老用户的偏好）；约束改成「∈ `enabledProviderIDs` ∩ 已注册」，否则 setter 回退到 `orderedProviderIDs` 里第一个 enabled+registered 的（仍用 `isRevertingMenuBar` 旗标避免 didSet 递归）；去掉旧的「只允许 `supportsBackgroundPolling==true`」限制。**`init` 里读盘时也要同等容错**：读出来的存储值若不在 enabled∩registered 里（如用户手动 `defaults write` 写了非法值，或老 key 存的 provider 现在被禁用了），回退到首个 enabled+registered 的 provider（最坏 `.claude` —— 它恒在 enabled 且必注册）。新增 `func setEnabled(_ id: ProviderID, _ on: Bool)`（Claude 忽略关闭请求；关掉当前 `menuBarProviderID` 时把它移到下一个 enabled）+ `func moveProvider(from: IndexSet, to: Int)`（在 `orderedProviderIDs` 上做 `move`，持久化）。`availableIDs` 重定义为 `orderedProviderIDs.filter { registry.isAvailable($0) && enabledProviderIDs.contains($0) }`（→ popover tab 只显示 enabled 的、按用户排序）。`primaryRuntime` → `menuBarRuntime`（= `registry.provider(menuBarProviderID)?.runtime ?? claude.runtime`）。`primaryEligibleIDs` 删除（无用了）。"
    done: true
    evidence: "`ProviderCoordinator` 新增 `orderedProviderIDs`（key `providerOrder`，didSet 持久化；init 读盘 → ∩ allCases + 末尾补漏掉的）/ `enabledProviderIDs`（key `enabledProviders`，didSet 强制 insert(.claude) + 持久化 + menuBar 失效时跳下一个；从没存过默认全 allCases）/ `menuBarProviderID`（= 原 `primaryProviderID` 改名，key 沿用 `primaryProviderKey=\"primaryProviderID\"`；didSet 校验 ∈ enabled∩registered 否则 isRevertingMenuBar 回退；init 同等容错回退首个 enabled+registered 最坏 .claude）+ `setEnabled(_:_:)`（Claude 忽略关闭）+ `moveProvider(from:to:)` + `firstMenuBarEligible()` + `availableIDs`=`orderedProviderIDs.filter{registered && enabled}` + `menuBarRuntime`；`init(claude:additionalProviders:defaults:)` 注入 UserDefaults；删 `primaryEligibleIDs`。`ProviderCoordinatorTests`(15 个) 全绿。"
  - id: SC2
    criterion: "**Settings「Providers」section + Sign Out 迁到 popover**：`SettingsView` 删掉「Primary Provider」picker（连同那段「More providers coming soon」提示）和最底下的 `if service.isAuthenticated { Section(\"Account\") { ... } }` 整块（email 文本 + Sign Out 按钮）。**Sign Out 不丢功能 —— 加到 `PopoverView.bottomBar`**：在 `bottomBar` 的 HStack 里（`Refresh` 之后、`Quit` 之前的某处）加 `if claude.isAuthenticated { Button(\"Sign Out\") { claude.signOut() }.buttonStyle(.borderless).font(.caption) }`（已有的 `AccountSwitcherView` 在 accounts>1 时另有切换 UI，不冲突）。在「General」之后、「Notifications」之前加一个 `Section(\"Providers\")`：首选用 `List { ForEach(coordinator.orderedProviderIDs) { ... }.onMove { coordinator.moveProvider(from:to:) } }`（行高用 `.frame` 收紧）；每行 = `HStack { Text(id.displayName); Spacer(); Toggle(\"\", isOn: enabledBinding(id)).labelsHidden().disabled(id == .claude || !registered(id)); /* 菜单栏单选 */ Button { coordinator.menuBarProviderID = id } label: { Image(systemName: coordinator.menuBarProviderID == id ? \"checkmark.circle.fill\" : \"circle\") }.buttonStyle(.borderless).disabled(!coordinator.enabledProviderIDs.contains(id)) }`（菜单栏单选：圆圈/对勾，点了就 `menuBarProviderID = id`）。**Fallback**：若 `List + .onMove` 在 macOS 14 grouped `Form` 里拖不动（已知 SwiftUI quirk），降级成每行加 ↑/↓ 按钮调 `coordinator.moveProvider`（或 `EditButton` 触发拖动模式）—— 两种方案的 done 判据相同：能调整顺序，且 `coordinator.orderedProviderIDs` + `UserDefaults[\"providerOrder\"]` 随之更新。section 下一行 caption 说明「✓ = 显示在菜单栏；开关 = 是否启用该供应商的 tab 与后台刷新」。未注册的 provider（cursor/copilot/gemini）行：Enabled toggle + 菜单栏单选都禁用，并显示「coming soon」。`enabledBinding(_:)` 用 `Binding(get: { coordinator.enabledProviderIDs.contains(id) }, set: { coordinator.setEnabled(id, $0) })`（per-row 现造，避免闭包捕获问题）。"
    done: true
    evidence: "`SettingsView` 删 Primary Provider picker（连同 More providers 提示）+ 删 `Section(\"Account\")` 整块；General 后加 `Section(\"Providers\")`：`ForEach(orderedProviderIDs.enumerated())` → `ProviderRow`（↑/↓ 按钮重排 + 名称 + Enabled `Toggle`（`.disabled(id == .claude || !registered)`、未注册显示 coming soon）+ 菜单栏单选 ✓ `Button{menuBarProviderID=id}`（`.disabled(!enabled || !registered)`）），section 下 caption 说明。Sign Out 迁到 `PopoverView.bottomBar`（`if claude.isAuthenticated { Button(\"Sign Out\"){claude.signOut()} }`）。`enabledBinding` 用 per-row `Binding(get:set:)`。"
  - id: SC3
    criterion: "**菜单栏 provider-aware（图标 + 窗口标签）**：`MenuBarIconRenderer` 的 `drawClaudeLogo(x:y:size:)` → `drawProviderGlyph(for providerID: ProviderID, x:y:size:)`：`.claude` 走现有 512px Claude PNG 逻辑（字节不变）；其它 provider 不新增图片资源 —— 用 SF Symbol 渲染成 template image（`.codex` → `terminal`；其它 → `circle`）或退而求其次画 `id.displayName.first` 字母。`renderIcon` 改成 `renderIcon(providerID:, primaryLabel:, secondaryLabel:, pct5h:, pct7d:)`；原写死的 `\"5h\"` / `\"7d\"` 行标签改用传入的 `primaryLabel` / `secondaryLabel`（≤3 字符；Claude 仍 `5h`/`7d`、Codex 用 `5h`/`7d`-等价的短名 —— 取 `ProviderUsageSnapshot.primaryWindow?.shortLabel`，见下）。`ProviderUsageSnapshot` / `UsageWindow` 加 `var shortLabel: String`（≤3 字符菜单栏用；Claude 的 5h/7d 窗口给 `5h`/`7d`，Codex 的 Session/Weekly 给 `5h`/`7d` 或 `S`/`W` —— 由各 provider 的 model 层填，默认取 `label` 前 2 字符）。`MenuBarLabel` 加 `providerID: ProviderID` 入参，转发给 renderer；`percentText` 已是 provider 无关（读 `runtime.snapshot`）—— 不动。**`showTrend` 暂仍按「`providerID == .claude`」**（按 provider 选对应 `UsageHistoryService` 喂 `MenuBarLabel` 是更大的活，留到后续；Codex 选作菜单栏时显示 Codex 图标 + Codex 的窗口 % + 模式 icon/percent，只是 percentWithTrend 模式下不画箭头）—— 在 `UsageBarApp` 里 `showTrend: coordinator.menuBarProviderID == .claude`。"
    done: true
    evidence: "`MenuBarIconRenderer`：`cachedLabels` 静态 dict → 按需 `cachedLabel(_:)` + 缓存；`drawClaudeLogo` → `drawProviderGlyph(for: ProviderID, x:y:size:)`（`.claude` 走现有 512px PNG；其它用 `NSImage(systemSymbolName:)`：codex→terminal、cursor→cursorarrow.rays、copilot→chevron.left.forwardslash.chevron.right、gemini→sparkle，渲染成居中 template image）；`renderIcon(providerID:primaryLabel:secondaryLabel:pct5h:pct7d:)` / `renderUnauthenticatedIcon(providerID:primaryLabel:secondaryLabel:)`，写死的 5h/7d 改用传入的。`ProviderUsageSnapshot.UsageWindow` 加 `shortLabel`（init `shortLabel: String? = nil` → 默认 `label` 前 2 字符）；Claude 5h/7d、Codex Session/Weekly 各填 `\"5h\"`/`\"7d\"`。`MenuBarLabel` 加 `providerID: ProviderID` 入参，`primaryShort`/`secondaryShort` 从 `runtime.snapshot.shortLabel` 取（缺/空回退 5h/7d），转发 renderer；`percentText` 的 prefix 也用它。`showTrend` 仍 `== .claude`（按 provider 选对应 historyService 留后续）。`UsageBarApp` 传 `providerID: coordinator.menuBarProviderID`。build 通过（无新测试，靠 manual smoke）。"
  - id: SC4
    criterion: "**Codex 用统一的 polling interval**：`CodexProvider` 删掉 `static let pollIntervalSeconds: TimeInterval = 300`；加实例计算属性 `var pollIntervalSeconds: TimeInterval { let stored = defaults.integer(forKey: \"pollingMinutes\"); return TimeInterval((UsageService.pollingOptions.contains(stored) ? stored : UsageService.defaultPollingMinutes) * 60) }`（即跟随 `UsageService` 那个 `pollingMinutes` key，非法值 → 30min = 1800s）；`init(... defaults: UserDefaults = .standard)`（单测可注入）。**`CodexProvider` 本身不再自持 `Timer`**（见 SC6：后台 timer 由 `ProviderCoordinator` 持，它读 `pollIntervalSeconds` —— 注：coordinator 用的是 `pollingMinutes` 这同一个 key，所以两者天然一致）；`startPolling()` 保留作「立即拉一次 + `onPollTick?()`」入口，但不再 `Timer.publish`。`pollingMinutes` 变化的感知统一在 `ProviderCoordinator`（见 SC6），`CodexProvider` 不自己监听。"
    done: true
    evidence: "`CodexProvider` 删 `static let pollIntervalSeconds=300`，加 `init(... defaults: UserDefaults = .standard)` + 实例 `var pollIntervalSeconds: TimeInterval`（读 `defaults.integer(\"pollingMinutes\")`，非法 → `defaultPollingMinutes`=30，×60）；`CodexProviderTests.testPollIntervalFollowsPollingMinutes`（注入 suite，set 5 → 300、set 7 非法 → 1800）全绿。实际后台 timer 由 coordinator 持（同 key 同算法，见 SC6）。"
  - id: SC5
    criterion: "**刷新纪律（用户主动可感知的刷新只有 2 个入口：后台 timer、Refresh 按钮；popover 打开触发一次但优先展示缓存；切 tab / 任何其它操作不刷新）**：`PopoverView` 删掉 `.task(id: selectedProvider) { ... await coordinator.refreshNow(selectedProvider) }`（切 tab 不再触发刷新）；改成一个**无 id 的** `.task { await coordinator.refreshAllEnabledOnOpen() }`（视图首次 appear / popover 首次打开时跑一次 —— `MenuBarExtra(.window)` 的内容视图常驻、不重建，所以这是「app 生命周期里第一次开 popover 拉一次」的语义；之后靠后台 timer，符合『优先展示历史数据』）。`ProviderCoordinator` 新增 `func refreshAllEnabledOnOpen() async`：对 `availableIDs` 里每个 provider，非 Claude 的 `await provider.refreshNow()`；Claude 只在 `coordinator.claude.runtime.snapshot == nil`（从没成功拉过、首屏会空）时才 `await claude.refreshNow()` 兜一次 —— 否则不碰它（避免打乱 `UsageService` 的 429 backoff）。注：`UsageService` conform `UsageProvider`、有 `runtime: ProviderRuntime`，`runtime.snapshot` 是有效判据（实施时确认；若 `UsageService` 没把成功结果写进 `runtime.snapshot` 则改判据为等价的『从没成功过』标志）。**Claude 的刷新路径共 3 条**——`UsageService` 自己的后台 timer（含 backoff）、Refresh 按钮（via `coordinator.refreshNow(.claude)`）、`refreshAllEnabledOnOpen` 的 `snapshot==nil` 兜底——都被 `UsageService.isRefreshing` 重入闸门序列化，不冲突；用户主动可感知的入口仍是「后台 timer + Refresh 按钮」两个（兜底那次只在首屏空时发生一次）。`refreshNow(_ id:)`（Refresh 按钮 + 后台 timer 用）不变。UI 不阻塞等刷新 —— `runtime.snapshot` 是常驻内存缓存，body 立即用它渲染（已是现状，确认不回归）。`bottomBar` 的「Refresh」按钮（refresh 当前 tab 的 provider）不动。`ProviderTabBar` 切 tab 只改 `selectedProvider`、不发刷新（确认不回归）。"
    done: true
    evidence: "`PopoverView` 删 `.task(id: selectedProvider){...refreshNow}`；加无 id `.task{ await coordinator.refreshAllEnabledOnOpen() }`（视图首次 appear 跑一次）；加 `.onChange(of: coordinator.availableIDs){ _, ids in if !ids.contains(selectedProvider){ selectedProvider = .claude } }`；`providerArea` 的判据 `coordinator.isAvailable` → `coordinator.availableIDs.contains`；`bottomBar` 的 Refresh 按钮不动、加 Sign Out。`ProviderTabBar` `ForEach(ProviderID.allCases)` → `ForEach(availableIDs)`，删 `pillForeground` 的占位透明态。`ProviderCoordinator.refreshAllEnabledOnOpen()`：非-Claude 各 `refreshNow`；Claude 仅 `shouldRefreshClaudeOnOpen`（`claude.runtime.snapshot == nil`）时兜一次。`ProviderCoordinatorTests.testRefreshAllEnabledOnOpenDoesNotCrash`/`testShouldRefreshClaudeOnOpenWhenSnapshotNil` 全绿；「切 tab 不刷新」是删 `.task(id:)` 后结构性成立、靠 G5 code-review 验（无单测）。"
  - id: SC6
    criterion: "**`ProviderCoordinator` 统管非-Claude 的后台 timer**：把 `CodexProvider` 的自持 `pollCancellable` timer 撤掉 —— 改由 `ProviderCoordinator` 持一个 `backgroundTimer`（`Timer.publish(every: backgroundIntervalSeconds, on: .main, in: .common).autoconnect().sink`，其中 `backgroundIntervalSeconds` 读 `UserDefaults[\"pollingMinutes\"]`、非法 → 30min，与 `CodexProvider.pollIntervalSeconds` 同 key 同算法）；tick 的逻辑抽成 `internal func onBackgroundTick()`（可单测注入）：对 `availableIDs` 里**非 Claude** 的 provider `Task { await provider.refreshNow() }` + 调它的 `onPollTick?()`（驱动 stats 刷新 —— 对 Codex 即 `codexStats.refresh()`）。`pollingMinutes` 变化由 `ProviderCoordinator` **监听 `UserDefaults.didChangeNotification`**（observer 比对当前 interval 值，变了就 invalidate + 重起 `backgroundTimer`）—— 这是唯一的感知点，`CodexProvider` 不自己监听。Claude 的 `UsageService` 后台 timer（含 429 backoff）**保持不动**（不强行收编 —— backoff 状态机迁移风险高，留后续；这个「分裂」是刻意的，两套 timer 都读 `pollingMinutes` 同一 key，Claude 的会在 backoff 时延长，符合预期）。`UsageBarApp.task` 里：原来 `if let codex = coordinator.provider(.codex) as? CodexProvider { codex.onPollTick = ...; codex.startPolling() }` 改成 `coordinator.startBackgroundPolling()`（内部：对各 enabled 非-Claude provider 设好 `onPollTick`（Codex → `{ Task.detached { await codexStats.refresh() } }`，由 App 注入回调）→ 起统一 `backgroundTimer` → 立即各 `refreshNow()` + `onPollTick()` 一次 → 注册 `UserDefaults.didChangeNotification` observer）。`CodexProvider.isPolling` 单测 helper 退役（自持 timer 没了）。"
    done: true
    evidence: "`ProviderCoordinator` 加 `backgroundTimer: AnyCancellable?` + `defaultsObserver` + `lastBackgroundInterval` + `backgroundIntervalSeconds`（读 `pollingMinutes`，同 `CodexProvider.pollIntervalSeconds` 算法）+ `startBackgroundPolling(codexOnPollTick:)`（为 Codex 设 `onPollTick`、`rescheduleBackgroundTimer()`、立即 `onBackgroundTick()`、注册 `UserDefaults.didChangeNotification` observer 比对 interval 变了重起，observer 里 `MainActor.assumeIsolated`）+ `onBackgroundTick()`（`internal`：非-Claude enabled provider 各 `Task{await refreshNow()}` + `(p as? CodexProvider)?.onPollTick?()`，Claude 不碰）。`CodexProvider` 撤 `pollCancellable`/`isPolling`/`startPolling`（`import Combine` 也删）。`UsageBarApp.task` 里 `codex.startPolling()` 那段 → `coordinator.startBackgroundPolling(codexOnPollTick: { Task.detached { await codexStats.refresh() } })`；`claude.startPolling()` 不动。`ProviderCoordinatorTests.testBackgroundIntervalFollowsPollingMinutes`（默认 30、set 5 → 300、set 7 非法 → 1800）/ `testOnBackgroundTickDoesNotTouchClaude`（onBackgroundTick 后 claude.runtime.snapshot 仍 nil）全绿。"
  - id: SC7
    criterion: "**Claude / 既有行为零回归**：`UsageService`（含 polling timer / backoff / OAuth / 多账号）字节不变；`pollingMinutes` 的 `UserDefaults` key 不变；`menuBarProviderID` 的持久化 key 沿用 `primaryProviderID`（老用户偏好不丢）；菜单栏在 menu-bar provider == Claude 时渲染与本版本前完全一致（Claude PNG logo + `5h`/`7d` 标签 + 同样的 trend 行为）；popover 各 tab 渲染不变（除了「切 tab 不再自动刷新」这个**预期的行为变化**）；Sign Out 仍能用（popover 里）；通知阈值 / 更新通道 / Launch at Login / Menubar Display 设置不动；`UsageStatsService` / `UsageHistoryService` / 各 provider 的数据流不动。`ProviderTabBar` 只是 `availableIDs` 来源换了（现在是 enabled∩registered，按用户排序），渲染逻辑不动。"
    done: true
    evidence: "`UsageService` 字节不变（polling timer / backoff / OAuth / 多账号）；`pollingMinutes` key 不变；`menuBarProviderID` 沿用 `primaryProviderID` 持久化 key（老用户偏好不丢，老值只可能是 `claude` → 仍合法）；菜单栏 menu-bar provider == Claude 时渲染与本版本前一致（Claude PNG + 5h/7d + 同样 trend 行为）；popover 各 tab 渲染不变（除「切 tab 不再自动刷新」这个预期行为变化）；Sign Out 仍可用（popover 底栏）；通知阈值/更新通道/Launch at Login/Menubar Display 不动；`UsageStatsService`/`UsageHistoryService`/各 provider 数据流不动；`ProviderTabBar` 仅 `availableIDs` 来源换。249 tests 全绿（既有 `ProviderAbstractionTests` 改了两条命名/语义、其余不动）。"
  - id: SC8
    criterion: "`swift build -c release` 通过、无新警告；`swift test` 全绿 —— 新增/改动测试：`ProviderCoordinatorTests`（注入 in-memory `UserDefaults` + fake providers：(a) `orderedProviderIDs` 默认 = registered 顺序、读盘过滤掉未注册的 + 末尾补漏掉的新 provider；(b) `enabledProviderIDs` 默认全 registered、`setEnabled(.claude,false)` 后仍含 `.claude`、`setEnabled(.codex,false)` 后 `availableIDs` 不含 codex、当 `menuBarProviderID==.codex` 时 `setEnabled(.codex,false)` → `menuBarProviderID` 跳到 `.claude`；(c) `moveProvider(from:to:)` 改顺序并写 `UserDefaults` 的 `providerOrder`；(d) `menuBarProviderID = 未注册值` / `= 注册但 disabled 值` → 被拒、回退首个 enabled+registered；`init` 读盘到非法值同样回退；(e) `availableIDs` = `orderedProviderIDs.filter{registered && enabled}` 按序；(f) `refreshAllEnabledOnOpen()` → fake codex 的 `refreshNow` 被调；fake claude 的 `refreshNow` 仅当其 `runtime.snapshot==nil` 时被调；(g) `onBackgroundTick()`（直接调这个 internal 方法）→ fake codex `refreshNow` + `onPollTick` 被调、fake claude 不被调；改 `UserDefaults` 的 `pollingMinutes` → `backgroundIntervalSeconds` 计算值跟随（不必真等 timer））。`CodexProviderTests` 追加：`CodexProvider(... defaults: customDefaults)`，`customDefaults.set(5, forKey: pollingMinutes)` → `pollIntervalSeconds==300`；`set(7,...)`（非法）→ `==1800`；（`isPolling` 断言退役）。`PopoverViewTests`（若无则在 `ProviderCoordinatorTests` 里等价覆盖）：切 `selectedProvider` 不触发 `refreshNow`（注入 spy coordinator 断言）。`make release-artifacts` + `verify-release.sh` 对 zip/dmg 均 OK。注：SC3（菜单栏 SF Symbol glyph 渲染）无自动化单测，靠 `swift build`（编译通过）+ `manual_checks` —— 已知接受。"
    done: true
    evidence: "`swift build -c release` 通过、无新警告；`swift test` = 249 tests 0 失败（新增 `ProviderCoordinatorTests`×15 + `CodexProviderTests.testPollIntervalFollowsPollingMinutes`；删 `testCoordinatorPrimaryEligibleExcludesNonPollingProvider`/`testStartPollingIsIdempotent`；改 `ProviderAbstractionTests` 两条）；`make release-artifacts` 产出 zip+dmg；`verify-release.sh` 对二者均「Release archive looks good」；`make install` 装机 OK。"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
  - "SC_AUTO_VERIFY_ZIP: bash macos/scripts/verify-release.sh macos/UsageBar.zip"
manual_checks:
  - "Settings → Providers section：能拖动重排 Claude/Codex；Codex 关掉 Enabled → popover 顶部不再有 Codex tab、Codex 后台刷新停；Claude 的 Enabled 开关禁用（恒开）；点 Codex 行的 ✓ → 菜单栏图标变成 Codex 图标 + 显示 Codex 的窗口 %；点回 Claude 的 ✓ → 菜单栏恢复 Claude logo + 5h/7d。"
  - "Settings 最底下不再有「Account」section（email + Sign Out）；Sign Out 仍能在 popover 底栏附近找到（或 Claude tab 的某处）—— 确认没丢功能。"
  - "Polling Interval 改成 5min → Codex 的后台刷新也变成 ~5min（看 popover 里 Codex tab 的 Updated 时间）；改回 30min 同样跟随。"
  - "打开 popover → 各 enabled provider 拉一次（首屏先显示上次缓存、几秒后刷新）；在 tab 间来回切 → 不再每次切都转圈/重拉（只换显示）；点底栏「Refresh」→ 当前 tab 的 provider 重拉。"
reviews:
  - gate: G2
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: design-review + light security-review（本 spec 不读新文件、不动凭证，安全面小）
    verdict: approved-after-revisions
    notes: >
      1 must-fix：Sign Out 位置必须 spec 阶段定死 —— 已改 SC2，明确「Sign Out 加到 `PopoverView.bottomBar`（`if claude.isAuthenticated`）」。
      7 should-fix：① SC5 对「Claude 刷新入口数」模糊 —— 已补「Claude 共 3 条路径（自持 timer / Refresh 按钮 / snapshot==nil 兜底），都被 isRefreshing 序列化；用户可感知入口仍 2 个」；② `menuBarProviderID` 的 init 读盘容错 —— 已补 SC1「init 里同等校验、非法值回退首个 enabled+registered」；③ coordinator backgroundTimer 怎么感知 pollingMinutes 变化 —— 已定死 SC6「coordinator 监听 `UserDefaults.didChangeNotification`，唯一感知点，CodexProvider 不自己监听」；④ SC5 的 `runtime.snapshot` 判据 —— 已注「UsageService conform UsageProvider 有 runtime.snapshot，实施确认；不行就改等价判据」；⑤ SC2 补 fallback done 判据（List+.onMove 拖不动 → ↑/↓ 按钮，两方案 done 判据相同）；⑥ SC8 补「切 tab 不触发 refreshNow 的单测」+ backgroundTick 抽 `internal func onBackgroundTick()` 可注入；⑦ CodexProvider interval 监听方案的「实施挑」去掉 —— 统一在 coordinator。
      3 nit：SC3 加「无自动化单测、靠 swift build + manual_checks」注（已加进 SC8 尾注）；数据流图加「谁监听」注解（已在 SC6 文字里）；`related_adrs: [0005]` 确认 ADR 0005 已落地（是的 —— `docs/adr/0005-reopen-multi-provider-direction.md` 存在，v0.2.4 起 supersede 0002）。
      「不含」三项推后（Claude backoff timer 收编 / Codex 菜单栏趋势箭头 / Codex 专属 logo 图片）+「Claude 恒在 enabledProviderIDs」取舍 + 「coordinator 管非-Claude timer、Claude 自持」分裂设计 —— 均获认可（理由站得住、reentrant guard 已覆盖双重刷新风险）。
  - gate: G5
    date: 2026-05-12
    reviewer: independent code-reviewer subagent（codex-rescue → general-purpose fallback，独立判断）
    scope: code-review + light security-review（安全面小：纯 Settings/coordinator/UI，不读新文件、不动凭证；唯一新落盘 = UserDefaults 里 providerOrder/enabledProviders 两个 provider 名字符串数组）
    verdict: approved-with-nits
    notes: >
      无 must-fix / should-fix。逐项确认通过：ProviderCoordinator init 容错（stored props 全先算 local 再统一赋值、无「self used before init」）/ `enabledProviderIDs.didSet` re-enter 不无限递归（set-不含-.claude 那条路径实为死代码）/ `isRevertingMenuBar` 旗标 / `setEnabled(.claude,false)` no-op + 关掉 menuBar provider 时跳 `firstMenuBarEligible` / `availableIDs` 顺序跟 `orderedProviderIDs` / `backgroundIntervalSeconds` 与 `CodexProvider.pollIntervalSeconds` 同算法同 key / `startBackgroundPolling`+`onBackgroundTick`（observer 的 `MainActor.assumeIsolated` 安全、不碰 Claude、weak self、生命周期与既有 timer 同策略）/ CodexProvider 自持 timer 清理干净（`import Combine` 也删）/ `MenuBarIconRenderer` SF Symbol 在 flipped 上下文走 `NSImage.draw(in:)` 与既有 PNG 路径一致 / `renderIcon` 新签名调用点一致 / `SettingsView` 的 `move(fromOffsets:toOffset:)` 上移 `to:idx-1`/下移 `to:idx+2` 算法正确 + 边界 disabled / Sign Out 迁 popover.bottomBar / PopoverView 删 `.task(id:)` 后「切 tab 不刷新」结构性成立 + `.onChange(of:availableIDs)` 弹回 Claude / ProviderTabBar 改吃 `availableIDs` / UsageBarApp 装配改 `startBackgroundPolling` + `menuBarRuntime`/`menuBarProviderID`/`providerID:` / 零回归（UsageService diff 空、`pollingMinutes` key 不变、`menuBarProviderID` 沿用 `primaryProviderID` key、Claude 菜单栏渲染走 PNG 分支不变）。`swift build -c release` 零警告、`swift test` 249 全绿。
      4 nit：① `UsageProvider.swift` 注释引用了已退役的 `startPolling()` 模式（已更新为 v0.2.10 描述）；② `ProviderTabBar.swift` 「调用方在 selection 不可用时展示 ProviderComingSoonView」注释已基本不可达（已改「防御性 fallback」措辞）；③ `MenuBarIconRenderer.swift` 的 file-level `var labelCache` 在 Swift 6 strict concurrency 下会报 —— 届时加 `@MainActor` / `nonisolated(unsafe)`（当前 5.9 无碍）；④ Codex 的 Session/Weekly 短标签填 `5h`/`7d` 语义略不匹配 —— spec 明确允许，后续可换 `S`/`W`。①② 已应用，③④ 留后续。
---

# Settings provider 列表 + 去 Account 区 + Codex 统一 interval + 刷新纪律

## 1. 背景与目标

「让 Codex tab 和 Claude tab 一致」收尾后，用户对 Settings + 刷新行为提了一组要求（2026-05-12）：

1. 不需要 Primary Provider（单选下拉）—— 把支持的 provider 做成一个**列表**，用户可调整**顺序**和**开关（启用/禁用）**；再做一个**子开关**控制「是否在 menu bar 里显示」（互斥/单选）。
2. Codex 也用同一个 polling interval（现在 Codex 自持固定 5 分钟）。
3. **刷新纪律**：所有任务在后台静默执行（含拉 rate 和统计用量）；打开 popover 可触发一次，但优先展示历史数据；切 tab 和任何操作都不触发刷新 —— **刷新只有 2 个入口：后台静默 timer、用户点界面上的 Refresh 按钮**。
4. Settings 最底下去掉 Account 信息展示。
5. `ProviderCoordinator` 统管 timer / 顺序 / 启用集 / 菜单栏 provider。

**不含**（→ 后续）：把 Claude 的 `UsageService` 后台 timer + 429 backoff 也收编进 `ProviderCoordinator`（迁移风险高）；菜单栏在 menu-bar provider 是 Codex 时显示 Codex 的趋势箭头（需按 provider 选对应 `UsageHistoryService` 喂 `MenuBarLabel`，是独立的活）；给 Codex / 其它 provider 做专属菜单栏 logo 图片资源（先用 SF Symbol）。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| Primary 下拉 → 列表 | `ProviderCoordinator` 加 `orderedProviderIDs` / `enabledProviderIDs` / `menuBarProviderID`（= 原 `primaryProviderID` 改名），Settings 用 `List + ForEach + .onMove` 渲染行（拖动手柄 + Enabled toggle + 菜单栏单选 ✓） | 直接对应用户要求；`primaryProviderID` 的持久化 key 沿用，老偏好不丢 |
| 菜单栏 provider 不再限「supportsBackgroundPolling」 | 删 `primaryEligibleIDs` 限制；菜单栏渲染 provider-aware（图标 + 窗口短标签从 snapshot 来） | 现在 Codex 也有数据/历史，没理由禁止它上菜单栏；`supportsBackgroundPolling` 这个 flag 本就名不副实（v0.2.8 注释过），本版顺手退役它的「primary 资格」用途 |
| Codex 菜单栏图标 | SF Symbol（`terminal`）渲染成 template image，不新增图片资源 | 加图片资源要动 Assets.xcassets + actool + verify-release，YAGNI；SF Symbol 足够 |
| 菜单栏窗口标签 5h/7d 写死 → 从 snapshot | `ProviderUsageSnapshot`/`UsageWindow` 加 `shortLabel`（≤3 字符），各 provider 的 model 层填（Claude 5h/7d、Codex 也 5h/7d-等价短名），默认取 `label` 前 2 字符 | 菜单栏空间小；让 provider 自己说自己的短名 |
| Codex 用统一 interval | `CodexProvider` 读 `UserDefaults["pollingMinutes"]`（同 `UsageService` 那个 key），监听 `UserDefaults.didChangeNotification` 重起 timer | 零耦合（不让 `CodexProvider` 依赖 `UsageService`）；key 复用现成的 |
| 谁持后台 timer | 非-Claude 的后台刷新由 `ProviderCoordinator` 持一个统一 `backgroundTimer`（tick 调各 enabled 非-Claude provider 的 `refreshNow` + `onPollTick`）；Claude 的 `UsageService` 自持 timer（含 backoff）不动 | 用户要「coordinator 统管 timer」；但 `UsageService` 的 backoff 状态机迁移风险大，本版先收编非-Claude 的，Claude 的留到后续 |
| 切 tab 不刷新 | 删 `PopoverView.task(id: selectedProvider)` 里的 `refreshNow`；改成无 id 的 `.task` 跑一次 `refreshAllEnabledOnOpen()` | 用户明确要求；popover 打开触发一次 = 那个无 id `.task` |
| popover 打开时 Claude 要不要也硬拉 | 不（它有后台 timer + backoff，重复硬拉打乱 backoff）—— 除非 `claude.runtime.snapshot == nil`（从没成功过，首屏空）才兜一次 | 不打乱 backoff，又保证首屏不空 |
| Account section 去掉，Sign Out 怎么办 | Settings 里删掉整个「Account」section；Sign Out 仍在 popover（`bottomBar` 附近或 Claude tab 的 AccountSwitcherView/某处保留入口）—— 实施时确认 popover 里有 Sign Out 入口，没有就补一个 | 用户只要求 Settings 里去掉账号信息展示，不是删 Sign Out 功能 |

## 3. 设计

### 3.1 改动文件

| 文件 | 改动 |
|---|---|
| `ProviderCoordinator.swift` | 加 `@Published orderedProviderIDs`（key `providerOrder`）/ `@Published enabledProviderIDs`（key `enabledProviders`，Claude 强制在）/ `menuBarProviderID`（原 `primaryProviderID` 改名，key 沿用 `primaryProviderID`，约束 ∈ enabled∩registered）；`setEnabled(_:_:)` / `moveProvider(from:to:)` / `refreshAllEnabledOnOpen()` / `startBackgroundPolling()`（持 `backgroundTimer`，tick 调非-Claude enabled provider 的 `refreshNow` + `onPollTick`，`pollingMinutes` 变重起）；`availableIDs` 重定义 = `orderedProviderIDs.filter { registry.isAvailable($0) && enabledProviderIDs.contains($0) }`；`primaryRuntime` → `menuBarRuntime`；删 `primaryEligibleIDs`。读盘逻辑：`providerOrder` 过滤未注册的 + 末尾补漏掉的新 provider；`enabledProviders` 默认全 registered。 |
| `SettingsView.swift` | 删「Primary Provider」picker + 提示；删「Account」section（email + Sign Out）；General 之后加 `Section("Providers")`：`List { ForEach(coordinator.orderedProviderIDs) { row }.onMove { coordinator.moveProvider(from:to:) } }`，行 = 名称 + `Toggle` Enabled（`.disabled(id == .claude)`，未注册的也禁用并显示 coming soon）+ 菜单栏单选 `Button{ coordinator.menuBarProviderID = id } label: { Image(systemName: == ? "checkmark.circle.fill" : "circle") }`（`.disabled(!enabled)`）；section 下 caption 说明 ✓ 与开关的含义。`enabledBinding(_:)` = `Binding(get: { coordinator.enabledProviderIDs.contains($0) }, set: { coordinator.setEnabled($0, $1) })`（注意闭包捕获问题：用 `Binding(get:set:)` per-row）。 |
| `MenuBarIconRenderer.swift` | `drawClaudeLogo` → `drawProviderGlyph(for: ProviderID, x:y:size:)`（`.claude` 走原 PNG，其它 SF Symbol `terminal`/`circle` 渲染成 template）；`renderIcon(...)` 加 `providerID:` + `primaryLabel:`/`secondaryLabel:` 参数，写死的 `"5h"`/`"7d"` 改用传入的。 |
| `MenuBarLabel.swift` | 加 `var providerID: ProviderID` 入参；`iconView` 调 renderer 时传 `providerID` + `runtime.snapshot?.primaryWindow?.shortLabel ?? "5h"` / `secondaryWindow?.shortLabel ?? "7d"`。`percentText` 不动。 |
| `ProviderUsageSnapshot.swift` | `UsageWindow` 加 `var shortLabel: String`（≤3 字符；初始化器加默认参数 `shortLabel: String? = nil` → 取 `label` 前 2 字符）；`ProviderUsageSnapshot.primaryWindow`/`secondaryWindow` 透出已含。 |
| `UsageModel.swift` / `CodexUsageModel.swift` | 构造 `UsageWindow` 时给 `shortLabel`（Claude：5h 窗 `"5h"`、7d 窗 `"7d"`；Codex：Session 窗 `"5h"`-等价短名（实际是 5h 类）、Weekly 窗 `"7d"` 或 `"W"` —— 实施挑，≤3 字符即可）。 |
| `CodexProvider.swift` | 删 `static let pollIntervalSeconds`；加实例 `var pollIntervalSeconds: TimeInterval`（读注入的 `UserDefaults["pollingMinutes"]`，非法 → 30min）；`init(... defaults: UserDefaults = .standard)`；`startPolling()` 不再起 `Timer.publish`（只「立即拉一次 + `onPollTick?()`」）—— 后台 timer 由 coordinator 起。或保留一个监听 `UserDefaults.didChangeNotification` 的 observer 把 interval 变化通知 coordinator（实施挑）。 |
| `PopoverView.swift` | 删 `.task(id: selectedProvider) { ... refreshNow }`；加 `.task { await coordinator.refreshAllEnabledOnOpen() }`（无 id）。`bottomBar` Refresh 按钮不动。确认 popover 里有 Sign Out 入口（没有就在 `bottomBar` 或 Claude tab 加一个 `if claude.isAuthenticated { Button("Sign Out") { claude.signOut() } }`）。 |
| `UsageBarApp.swift` | `MenuBarLabel(... providerID: coordinator.menuBarProviderID, ...)`；`showTrend: coordinator.menuBarProviderID == .claude`；`.task` 里把 `codex.startPolling()` 那段换成 `coordinator.startBackgroundPolling()`（内部对各 enabled 非-Claude provider 设 `onPollTick = { Task.detached { await codexStats.refresh() } }`（针对 Codex）+ 起统一 timer + 立即各拉一次）；`coordinator.menuBarRuntime` 替 `primaryRuntime`。 |
| 测试 | `ProviderCoordinatorTests`（新建或追加）+ `CodexProviderTests` 追加 + （`MenuBarIconRendererTests` 若有则确保不挂）。 |

### 3.2 数据流（菜单栏 + 刷新）

```
Settings「Providers」拖动/开关/✓  →  coordinator.{orderedProviderIDs, enabledProviderIDs, menuBarProviderID}（@Published + UserDefaults）
        │
        ├─ availableIDs（= ordered ∩ registered ∩ enabled）→ ProviderTabBar 显示哪些 tab、什么顺序
        ├─ menuBarProviderID → UsageBarApp: MenuBarLabel(providerID:, runtime: coordinator.menuBarRuntime, showTrend: ==.claude)
        │                         → MenuBarIconRenderer.renderIcon(providerID:, primaryLabel: snapshot.primaryWindow.shortLabel, ...)
        └─ enabledProviderIDs（非-Claude 部分）→ coordinator.backgroundTimer tick → 各 provider.refreshNow() + onPollTick()（Codex → codexStats.refresh）
                                                  pollingMinutes 变（UserDefaults）→ 重起 backgroundTimer

popover 打开 → PopoverView.task（无 id）→ coordinator.refreshAllEnabledOnOpen()（非-Claude 各 refreshNow；Claude 仅 snapshot==nil 时）；UI 立即用 runtime.snapshot 缓存渲染
切 tab → 只改 selectedProvider，不刷新
底栏 Refresh → coordinator.refreshNow(selectedProvider)
Claude 后台刷新 → UsageService 自己的 timer（含 429 backoff），不变
```

### 3.3 测试方案（要点）

- `ProviderCoordinatorTests`：构造时注入 `UserDefaults`（in-memory suite）+ 一组 provider（fake claude + fake codex + 不注册 cursor）。
  - `orderedProviderIDs` 默认 = 注册顺序；预存 `providerOrder = ["codex","claude","gemini"]` → 读出来 = `["codex","claude"]`（gemini 未注册被过滤）+ 若注册表里有它没列的 provider 接末尾。
  - `enabledProviderIDs` 默认 = 全注册；`setEnabled(.claude, false)` 后仍含 `.claude`；`setEnabled(.codex, false)` 后 `availableIDs` 不含 codex；当 `menuBarProviderID == .codex` 时 `setEnabled(.codex,false)` → `menuBarProviderID` 跳到 `.claude`。
  - `moveProvider(from: IndexSet(integer:1), to: 0)` → 顺序变 + `UserDefaults["providerOrder"]` 更新。
  - `menuBarProviderID = .cursor`（未注册）→ 被拒、回退到首个 enabled+registered；`= .codex`（注册但 disabled）→ 被拒。
  - `availableIDs` = `orderedProviderIDs.filter { registered && enabled }`，顺序跟 `orderedProviderIDs`。
  - `refreshAllEnabledOnOpen()`：fake codex 的 `refreshNow` 被调；fake claude 的 `refreshNow` 仅当其 `runtime.snapshot == nil` 时被调。
  - `startBackgroundPolling()` 起 timer 后（用很短 interval 或直接调内部 tick 方法）→ fake codex `refreshNow` + `onPollTick` 被调、fake claude 不被调；改 `UserDefaults["pollingMinutes"]` → timer 用新 interval（断言 interval 计算值，不必真等）。
- `CodexProviderTests` 追加：`CodexProvider(... defaults: customDefaults)`，`customDefaults.set(5, forKey: "pollingMinutes")` → `pollIntervalSeconds == 300`；`set(7, ...)`（非法）→ `== 1800`（30min）；`startPolling()` 后 `isPolling`（若保留该 helper）反映「无自持 timer」/ 或退役该断言。
- `swift build` + `swift test` 全绿；`make release-artifacts` + `verify-release.sh`（zip+dmg）OK。纯 SwiftUI 的（Settings 的 List 行、菜单栏 SF Symbol glyph）靠 `swift build` + `manual_checks`。

CI 跑 `swift build -c release` + `swift test` + `make release-artifacts` + `verify-release.sh`，全绿。

## 4. 风险 / Open questions

1. **macOS `Form` 里的 `List` + `.onMove`**：`Form` 嵌 `List` 能不能拖、行高 —— 若在 grouped Form 里 `.onMove` 不灵，退而用 `EditButton` 触发拖动模式，或用上下箭头按钮替代拖动。实施时先 build 跑一下 manual check；不行就降级成「↑/↓ 按钮重排」（功能等价）。**plan 里给 fallback 路径**。
2. **`menuBarProviderID` key 沿用 `primaryProviderID`** —— 老用户存的值（只可能是 `claude`，因为旧版只有它 eligible）读出来仍合法。OK。
3. **Codex 选作菜单栏 provider 时无趋势箭头** —— `MenuBarLabel` 当前只有一个 `historyService`（Claude 的）。本版 `showTrend` 仍 `==.claude`；Codex 的菜单栏趋势留后续（要把 `historyService` 也按 provider 选）。已在 SC3 / §2 写明。可接受。
4. **`UsageService` backoff timer 不收编** —— 用户说「coordinator 统管 timer」，本版只收编非-Claude 的；Claude 的 backoff 状态机迁移留后续。已在 §1「不含」+ §2 写明。
5. **popover 打开触发一次刷新 vs `MenuBarExtra` 的 `.task` 时机** —— `MenuBarExtra(.window)` 的内容视图首次打开时创建、之后常驻；无 id `.task` 在视图 appear 时跑一次。若用户多次开关 popover 不重跑（视图没销毁）—— 这其实更符合「优先展示缓存、别每次开都刷」。若希望「每次开 popover 都刷一次」需监听 `NSPopover`/`MenuBarExtra` 的 isPresented —— YAGNI，本版「视图生命周期内开一次」够了。实施时确认行为并在 manual_checks 记。

## 5. 引用

- 前置 spec：[`2026-05-12-multi-provider-refactor.md`](./2026-05-12-multi-provider-refactor.md)、[`2026-05-12-codex-provider.md`](./2026-05-12-codex-provider.md)、[`2026-05-12-codex-history-trend.md`](./2026-05-12-codex-history-trend.md)、[`2026-05-12-codex-cost-heatmap.md`](./2026-05-12-codex-cost-heatmap.md)、[`2026-05-12-popover-redesign.md`](./2026-05-12-popover-redesign.md)
- ADR：[`../adr/0005-reopen-multi-provider-direction.md`](../../adr/0005-reopen-multi-provider-direction.md)
- 落地版本：[`../versions/v0.2.10-settings-provider-list.md`](../../versions/v0.2.10-settings-provider-list.md)
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)

## Verification log

> G6 验收依据（详见 frontmatter `spec_criteria` 的 evidence）。

- [x] SC1 — `ProviderCoordinator` 顺序/启用集/菜单栏 provider 模型
- [x] SC2 — Settings「Providers」section（拖动 + Enabled toggle + 菜单栏单选）+ 删 Account 区
- [x] SC3 — 菜单栏 provider-aware（图标 + 窗口短标签）
- [x] SC4 — Codex 用统一的 polling interval
- [x] SC5 — 刷新纪律（切 tab 不刷新；popover 打开一次；刷新只 2 入口）
- [x] SC6 — `ProviderCoordinator` 统管非-Claude 后台 timer
- [x] SC7 — Claude / 既有行为零回归
- [x] SC8 — swift build / swift test（含新测试）/ make release-artifacts + verify 全绿
