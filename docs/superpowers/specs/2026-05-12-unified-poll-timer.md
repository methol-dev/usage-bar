---
id: 2026-05-12-unified-poll-timer
title: ProviderCoordinator 统一后台 timer（收编 Claude 的 backoff）+ Codex 菜单栏专属 glyph
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.11
related_adrs: [0005]
related_research: []
related_specs: [2026-05-12-multi-provider-refactor, 2026-05-12-settings-provider-list, 2026-05-12-codex-provider]
spec_criteria:
  - id: SC1
    criterion: "**`UsageProvider` 协议泛化（为统一 timer 做准备）**：`UsageProvider` 加两个**有默认实现**的成员（放 `extension UsageProvider`，默认 `nil`）—— (a) `var nextEligibleRefresh: Date? { get }`（「在这个时刻之前别 tick 我」—— 给做指数 backoff 的 provider 用；nil = 随时可 tick）；(b) `var onPollTick: (@MainActor () -> Void)? { get set }`（后台 tick 时额外回调 —— 用来驱动该 provider 的本机统计刷新；`CodexProvider` 已有此属性，本 spec 把它**提到协议**，`CodexProvider` 的声明保留即满足 conformance）。`UsageService` 实现 `nextEligibleRefresh`（返回内部 backoff 截止时刻 —— 见 SC2）并新增可写的 `var onPollTick: (@MainActor () -> Void)? = nil`。`StubProvider`（测试用）若不显式实现这两个 → 走默认（nil / 可读可写的存储属性需在 stub 里加 `var onPollTick: ... = nil`，因为协议要求 `get set`）。"
    done: true
    evidence: "`UsageProvider`：协议体加 `var nextEligibleRefresh: Date? { get }`（**协议要求** —— 必须如此，否则经 `any UsageProvider` 调会静态派发到 extension 默认值绕过 conformer override；实测踩过这个坑）+ `var onPollTick: (@MainActor () -> Void)? { get set }`；`extension UsageProvider` 给 `nextEligibleRefresh` 默认实现 `nil`。`UsageService` 加 `var nextEligibleRefresh: Date? { backoffUntil }` + `var onPollTick: (@MainActor () -> Void)?`。`CodexProvider.onPollTick` 已有（满足）。`StubProvider`(`ProviderAbstractionTests`) 加 `var onPollTick = nil`/`refreshNowCallCount`/`nextEligibleRefreshOverride`+`nextEligibleRefresh` 计算属性。251 tests 全绿。"
  - id: SC2
    criterion: "**`UsageService` 退役自持 timer，backoff 改成「截止时刻」语义**：删 `private var timer: Timer?` / `private func scheduleTimer()` / 所有 `timer?.invalidate(); timer = nil` 散点。删 `private var currentInterval: TimeInterval`（它原本只是「下次 timer 的间隔 = base 或 backoff」），改成 `private var currentBackoffSeconds: TimeInterval = 0`（0 = 不在 backoff）+ `private var backoffUntil: Date? = nil`。`fetchUsage()` 里：(a) 429 分支 —— `let retryAfter = http.value(\"Retry-After\").flatMap(Double.init); let prev = currentBackoffSeconds == 0 ? baseInterval : currentBackoffSeconds; currentBackoffSeconds = Self.backoffInterval(retryAfter: retryAfter, currentInterval: prev); backoffUntil = Date().addingTimeInterval(currentBackoffSeconds); lastError = \"Rate limited — backing off to \\(Int(currentBackoffSeconds))s\"; runtime.setError(...)`（不再 `scheduleTimer()`）；(b) 成功分支末尾的「`if currentInterval != baseInterval { currentInterval = baseInterval; scheduleTimer() }`」改成「`currentBackoffSeconds = 0; backoffUntil = nil`」（清 backoff，不再 reschedule）。`var nextEligibleRefresh: Date? { backoffUntil }`。`Self.backoffInterval(retryAfter:currentInterval:)` 函数签名/语义**不变**（仍 `min(max(retryAfter ?? currentInterval, currentInterval * 2), maxBackoffInterval)`；`testBackoffIntervalCapsAtSixtyMinutes` 不动）。`updatePollingInterval(_:)` 改成：写 `pollingMinutes` + `UserDefaults[\"pollingMinutes\"]`（不变）+ 若 `isAuthenticated` 则 `Task { await fetchUsage() }`（立即拉一次）—— **不再** `currentInterval = ...` / `scheduleTimer()`（recurring 由 coordinator 的 timer 负责，它监听 `pollingMinutes` 变化重起，见 SC3）。"
    done: true
    evidence: "`UsageService` 删 `private var timer: Timer?`/`private func scheduleTimer()`/`func startPolling()`；删 `private var currentInterval`，加 `private var currentBackoffSeconds: TimeInterval = 0` + `private var backoffUntil: Date?`；`fetchUsage` 429 分支 → `let prev = currentBackoffSeconds == 0 ? baseInterval : currentBackoffSeconds; currentBackoffSeconds = Self.backoffInterval(retryAfter: http.value(\"Retry-After\").flatMap(Double.init), currentInterval: prev); backoffUntil = Date() + currentBackoffSeconds; lastError = \"Rate limited — backing off to \(Int(currentBackoffSeconds))s\"; runtime.setError(...)`（不再 scheduleTimer）；成功分支 → `currentBackoffSeconds = 0; backoffUntil = nil`；signOut/expireSession 也清这俩。`backoffInterval(...)` 函数不变（`testBackoffIntervalCapsAtSixtyMinutes` 不动）。`updatePollingInterval` → 写 `pollingMinutes`+`UserDefaults` + `if isAuthenticated { currentFetchTask = Task { await fetchUsage() } }`（不再 scheduleTimer/currentInterval）。init 删 `currentInterval = ...`。`UsageServiceTests` 追加 `testFetchUsageSuccessClearsBackoff` + `testFetchUsageDoesNotSignOutWhenRetriedRequestIsRateLimited` 补断言 `nextEligibleRefresh`。`SC_AUTO_NO_TIMER` grep 无命中。"
  - id: SC3
    criterion: "**`ProviderCoordinator` 的后台 timer 现在覆盖所有 enabled provider（含 Claude）**：`onBackgroundTick()` 改成遍历 `availableIDs` 里**全部** provider（不再 `where id != .claude`）：对每个 provider `p`，若 `let due = p.nextEligibleRefresh, due > Date()` → **跳过这一 tick**（还在 backoff 窗口里）；否则 `Task { await p.refreshNow() }` + `p.onPollTick?()`（`onPollTick` 现在是协议成员，不需 `as? CodexProvider` 向下转型了）。`refreshAllEnabledOnOpen()`：对 `availableIDs` 里每个 provider，若 `nextEligibleRefresh` 在未来 → 跳过；否则 —— 非-Claude provider `await refreshNow()`；**Claude 仍保留特判**（只在 `claude.runtime.snapshot == nil`（首屏还空、且不在 backoff）时才 `await refreshNow()` —— 避免「每次打开 popover 都硬拉 Claude」打乱其速率配额）；`shouldRefreshClaudeOnOpen` 计算属性**保留**（= `claude.runtime.snapshot == nil && (claude.nextEligibleRefresh == nil || claude.nextEligibleRefresh! <= Date())`）。`startBackgroundPolling(...)` 不再需要 `codexOnPollTick:` 参数（改成无参 —— 各 provider 的 `onPollTick` 由装配处单独设；见 SC4）；`backgroundIntervalSeconds` / 监听 `UserDefaults.didChangeNotification` 重起逻辑不变。**backoff 解析度变粗（预期行为变化）**：v0.2.10 之前 Claude 的自持 timer 精确按 backoff 间隔重试；现在 coordinator 是固定 `pollingMinutes` 间隔的 tick，被跳过的 provider 要等到 `backoffUntil` 之后的**第一个 tick** 才重试（重试时刻向上 round 到下一个 `pollingMinutes` tick 边界）。若 `Retry-After ≤ pollingMinutes`：最坏多等 ~`pollingMinutes`；若 `Retry-After > pollingMinutes`（如 P=30min、R=70min）：会跳过 ⌊R/P⌋ 个 tick，实际等到 R 之后第一个 tick（如 90min）。backoff 本就是「别 hammer 服务器」，向上 round 无害。"
    done: true
    evidence: "`ProviderCoordinator.onBackgroundTick()` 遍历 `availableIDs` **全部**（删 `where id != .claude`）：`if let due = p.nextEligibleRefresh, due > Date() { continue }` 否则 `Task { await p.refreshNow() }` + `p.onPollTick?()`（协议成员，不再 `as? CodexProvider`）。`refreshAllEnabledOnOpen()`：遍历 availableIDs，跳过 backoff 窗口内的；非-Claude 直接 `refreshNow`；Claude 仅 `shouldRefreshClaudeOnOpen`（snapshot==nil 且不在 backoff）时兜一次。`shouldRefreshClaudeOnOpen` = `snapshot==nil && !(nextEligibleRefresh in future)`。`startBackgroundPolling()` 去 `codexOnPollTick:` 参数；`backgroundIntervalSeconds`/监听 `UserDefaults.didChangeNotification` 重起不变。`ProviderCoordinatorTests`：`testOnBackgroundTickAlsoTicksClaude`（旧 testOnBackgroundTickDoesNotTouchClaude 改名 + 断言 `claude.runtime.lastError == \"Not signed in\"`）、`testBackoffWindowSkipsProvider`（StubProvider override `nextEligibleRefresh` 在未来 → tick 跳过 `refreshNowCallCount==0`、override=nil → tick 到 `==1`）、`testRefreshAllEnabledOnOpenTicksClaudeWhenSnapshotNil`。全绿。"
  - id: SC4
    criterion: "**装配处（`ClaudeUsageBarApp`）改线**：`.task` 里 —— 删 `coordinator.claude.startPolling()`（`UsageService.startPolling()` 整个方法删掉，见 SC5）；改成 `coordinator.claude.refreshNow()` 立即拉一次 + `coordinator.claude.onPollTick = { Task.detached { await usageStats.refresh() } }`（Claude 的本机统计刷新随后台 tick；原来这条逻辑在 `UsageService.scheduleTimer()` 里的 `Task.detached { await usageStats.refresh() }`）；`coordinator.provider(.codex)?.onPollTick = { Task.detached { await codexStats.refresh() } }`（替代原来 `startBackgroundPolling(codexOnPollTick:)` 传参）；最后 `coordinator.startBackgroundPolling()`（无参，起统一 timer + 立即各拉一次）。`await usageStats.refresh()` / `await codexStats.refresh()` 这两行启动期的初次刷新保留。`fetchProfile`（账号 email）—— 原本在 `startPolling()` 里「`if accountEmail == nil { fetchProfile() }`」—— 移到 `UsageService.refreshNow()`（或 `kickoffNow()`）里同样判断（实施确认 `refreshNow` conform `UsageProvider` 后里面调 `fetchUsage` + 该判断）。"
    done: true
    evidence: "`ClaudeUsageBarApp.task`：删 `coordinator.claude.startPolling()`；改成 `coordinator.claude.onPollTick = { Task.detached { await usageStats.refresh() } }` + `coordinator.provider(.codex)?.onPollTick = { Task.detached { await codexStats.refresh() } }` + `coordinator.startBackgroundPolling()`（无参；立即 `onBackgroundTick()` 那次就拉了 Claude，不再单独 `claude.refreshNow()`）。`await usageStats.refresh()`/`await codexStats.refresh()` 启动期那两行保留。`fetchProfile` 并进 `UsageService.refreshNow()`（`await fetchUsage(); if accountEmail == nil { await fetchProfile() }`）。build 通过。"
  - id: SC5
    criterion: "**`UsageService` 各「曾 `startPolling()` / 操作 timer」的散点改对**：(a) `startPolling()` 方法删除 —— 它的内容（立即 `fetchUsage()` + `if accountEmail == nil { fetchProfile() }` + `scheduleTimer()`）拆解：fetch+profile 那段成为 `refreshNow()` 的行为（`UsageService` 已 conform `UsageProvider`、有 `refreshNow()` —— 让它额外补 profile 判断），timer 那段没了。(b) `switchAccount(to:)`：删 `timer?.invalidate(); timer = nil`；末尾 `startPolling()` → `currentFetchTask = Task { [weak self] in await self?.fetchUsage(); if self?.accountEmail == nil { await self?.fetchProfile() } }`（即「立即拉一次」—— recurring 由 coordinator timer）。(c) `addAccount`/`signIn` 路径里的 `if !isFirst { ... timer?.invalidate(); timer = nil ... }` → 删 timer 那行；末尾 `startPolling()` → 同 (b) 的「立即拉一次」。(d) `signOut()`：删 `timer?.invalidate(); timer = nil`（其余 cancel currentFetchTask/refreshTask 不动）。(e) `expireSession` 的 CLI 凭证恢复路径里 `timer?.invalidate(); timer = nil` 那段（约 :820）—— 删（凭证恢复后下一轮 coordinator tick 自然用新 token；原注释「timer 不动」现在变成「没 timer」，同义）；`expireSession` 走原硬过期路径时若有 `startPolling()` —— 改「立即拉一次」。**逐一 grep `timer` / `scheduleTimer` / `startPolling` 在 `UsageService.swift` 确保清零**（`currentFetchTask` 保留）。"
    done: true
    evidence: "`UsageService` 散点改对：`startPolling()` 方法删（内容拆进 `refreshNow()` + 没了 timer）；`switchAccount` 删 `timer?.invalidate(); timer = nil`、末尾 `startPolling()` → `currentFetchTask = Task { await fetchUsage(); if accountEmail == nil { await fetchProfile() } }`；`addAccount`/signIn 删 `if !isFirst` 块里的 `timer?.invalidate(); timer = nil`、末尾 `await fetchProfile(); startPolling()` → `await fetchProfile(); currentFetchTask = Task { await fetchUsage() }`；`signOut()` 删 `timer?.invalidate(); timer = nil`（加 `backoffUntil = nil; currentBackoffSeconds = 0`）；`expireSession` 删 `timer?.invalidate(); timer = nil`（同样加清 backoff）+ 注释更新。`grep -nE 'private var timer\b|scheduleTimer|func startPolling|private var currentInterval' UsageService.swift` 无命中。`UsageProvider.swift` / `ProviderCoordinator.swift` / `ClaudeUsageBarApp.swift` 里的过期注释（「startPolling」「coordinator 只统管非-Claude」等）已更新。"
  - id: SC6
    criterion: "**Codex 菜单栏专属 glyph（取代 SF Symbol `terminal`）**：`MenuBarIconRenderer` 里 `drawProviderGlyph(for: .codex, ...)` 改成**代码绘制的单色 glyph**（不引入新图片资源 —— 不动 `Resources/` / `verify-release.sh`）。**画一个粗的 `</>` 尖括号对**（`NSBezierPath` 描边或填充，12pt 模板尺寸下三笔画清晰；语义对「code generation」也贴切；**无商标风险**）—— 不复刻 OpenAI 的六瓣花结 logo（app 用 Anthropic 官方 Claude logo PNG 是「自家 API 客户端」情形、性质不同；给第三方 provider 复刻其商标 logo 有风险）。填色 `NSColor.black`（template image 自动适配菜单栏明暗）。其它未注册 provider（cursor/copilot/gemini）仍走 SF Symbol。`drawProviderGlyph(for: .claude, ...)` 字节不变。`renderIcon`/`renderUnauthenticatedIcon` 签名不变。代码注释写明「自绘的 `</>` 标记，非任何品牌 logo」。"
    done: true
    evidence: "`MenuBarIconRenderer.drawProviderGlyph(for:.codex,...)` → `drawCodeBracketsGlyph(x:y:size:)`：`NSBezierPath` 描边画 `</>`（笔宽 `max(size*0.16, 1.4)`、圆角接头；`<`/`>` 尖端在垂直中点、`/` 从右上到左下；填色 `NSColor.black`，template image 自动适配明暗）；坐标用 flipped 上下文（小 y 在上）—— 与同文件的 `logo.draw`/`drawBar` 一致。代码注释写明「自绘的 `</>` 标记，非任何品牌 logo」。`.claude` 走 PNG 不变；其它 provider 仍 SF Symbol。`renderIcon`/`renderUnauthenticatedIcon` 签名不变。build 通过（无新测试，靠 manual smoke + manual_checks）。"
  - id: SC7
    criterion: "**Claude / 既有行为零回归**：`UsageService` 的 OAuth / refresh / 多账号 / `currentFetchTask` race-fix（epoch）/ `fetchUsage` 的 200/HTTP-error/decode/race-guard 分支 —— 除「429 backoff 现在记 `backoffUntil` 而非 `scheduleTimer`」「成功后清 `currentBackoffSeconds`/`backoffUntil` 而非 reschedule」「没有 `timer` 了」之外**逻辑不变**；`pollingMinutes` 的 `UserDefaults` key 不变；`backoffInterval(retryAfter:currentInterval:)` 函数不变（`testBackoffIntervalCapsAtSixtyMinutes` 不动）；菜单栏在 menu-bar provider == Claude 时渲染与本版本前完全一致（PNG glyph + 5h/7d）；popover 渲染不变；`UsageStatsService`/`UsageHistoryService` 数据流不变（Claude 的 `usageStats.refresh()` 现在由 `coordinator.claude.onPollTick` 在后台 tick 时调，而非 `scheduleTimer` 里的 `Task.detached` —— 节奏一致（都跟 `pollingMinutes`），效果不变）；`ProviderCoordinator` 的 `orderedProviderIDs`/`enabledProviderIDs`/`menuBarProviderID`/`availableIDs`/Settings Providers section / `PopoverView` 的刷新纪律（切 tab 不刷新等）—— 全不动。Codex/其它 provider 的 v0.2.10 行为照旧（除 Codex 菜单栏 glyph 换了）。另：`UsageProvider.swift` 里那段「Claude 的后台 timer + 429 backoff 仍归 `UsageService` 自己（`claude.startPolling()`）」注释要更新成「所有 provider 的后台轮询由 `ProviderCoordinator` 统管；provider 用 `nextEligibleRefresh` hint 表达 backoff」（避免文档腐烂）。"
    done: true
    evidence: "`UsageService` 的 OAuth/refresh/多账号/`currentFetchTask` race-fix(epoch)/`fetchUsage` 200·HTTP-error·decode·race-guard 分支 —— 除「429 记 backoffUntil 而非 scheduleTimer」「成功/signOut/expireSession 清 backoff 而非 reschedule」「没有 timer 了」外逻辑不变；`pollingMinutes` key 不变；`backoffInterval` 函数不变（`testBackoffIntervalCapsAtSixtyMinutes`/`testBackoffIntervalNeverReducesSixtyMinutePolling`/`testFetchUsageDoesNotSignOutWhenRetriedRequestIsRateLimited` 全绿、文案 `\"Rate limited — backing off to 3600s\"` 不变）；菜单栏 Claude 时渲染走 PNG glyph + 5h/7d 不变；popover 渲染不变；`UsageStatsService`/`UsageHistoryService` 数据流不变（Claude 的 `usageStats.refresh()` 改由 `coordinator.claude.onPollTick` 在后台 tick 时调 —— 节奏一致）；`ProviderCoordinator` 的 orderedProviderIDs/enabledProviderIDs/menuBarProviderID/availableIDs/Settings Providers section/PopoverView 刷新纪律全不动；Codex/其它 provider 的 v0.2.10 行为照旧（除 Codex 菜单栏 glyph）；过期注释已更新。251 tests 全绿。"
  - id: SC8
    criterion: "`swift build -c release` 通过、无新警告；`swift test` 全绿 —— 新增/改动测试：`UsageServiceTests` 追加（429 响应后 `nextEligibleRefresh` 在未来、`runtime.lastError` 含 backing off；下一次成功 `fetchUsage` 后 `nextEligibleRefresh == nil`；`testBackoffIntervalCapsAtSixtyMinutes` 不动）；`ProviderCoordinatorTests` 改/追加（`onBackgroundTick()` 现在也 tick Claude —— 用注入了「`nextEligibleRefresh` 返回未来时刻」的 fake provider 验证「在 backoff 窗口里被跳过」、「窗口过后被 tick」；`refreshAllEnabledOnOpen()` 现在对 Claude 也调 `refreshNow`（用真 `UsageService` 未登录实例，调用不崩、`runtime.snapshot` 仍 nil 即可，或断言 `onBackgroundTick` 调到了 fake claude 的 refreshNow）；旧 `testOnBackgroundTickDoesNotTouchClaude` 删除/改名 —— 现在它**会**碰 Claude（这是本 spec 的点））；`CodexProviderTests` 的 `testSupportsBackgroundPollingIsFalse` 不动；`MenuBarIconRendererTests`（若有）确保不挂。`make release-artifacts` + `verify-release.sh`（zip/dmg）均 OK。"
    done: true
    evidence: "`swift build -c release` 通过、无新警告；`swift test` = 251 tests 0 失败（新增 `UsageServiceTests.testFetchUsageSuccessClearsBackoff` + 该文件 429 测试补 `nextEligibleRefresh` 断言；`ProviderCoordinatorTests` 改 `testOnBackgroundTickAlsoTicksClaude` + 新增 `testBackoffWindowSkipsProvider`/`testRefreshAllEnabledOnOpenTicksClaudeWhenSnapshotNil` + `StubProviderForCoordTest`；`StubProvider`/相关测试加成员）；`make release-artifacts` 产出 zip+dmg；`verify-release.sh` 对二者均「Release archive looks good」；`make install` 装机 OK；`SC_AUTO_NO_TIMER` grep 无命中。"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
  - "SC_AUTO_VERIFY_ZIP: bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip"
  - "SC_AUTO_NO_TIMER: grep -nE 'private var timer\\b|scheduleTimer|func startPolling|private var currentInterval' macos/Sources/ClaudeUsageBar/UsageService.swift  →  无命中（自持 timer / 私有 currentInterval 已退役；保留的 static func backoffInterval(...currentInterval:) 同名参数刻意不在此 grep 范围）"
manual_checks:
  - "改 Settings 的 Polling Interval（如 30→5min）→ Claude 与 Codex 的后台刷新都跟着变（看 popover 里各自的 Updated 时间在 ~5min 内更新）；改回 30min 同样跟随。"
  - "正常用一段时间不报错（无 429）→ Claude/Codex 的 Updated 时间按 pollingMinutes 节奏更新；切 Settings → Account section 仍没有；菜单栏 ✓ 切 Codex → 显示新的 Codex glyph（不是 SF terminal）。"
  - "（若能触发 429）Claude 进 backoff → popover Claude tab 显示「Rate limited — backing off to Ns」；过了 backoff 窗口（下一个 pollingMinutes tick 之后）自动恢复拉取、错误清掉。"
reviews:
  - gate: G2
    date: 2026-05-12
    reviewer: independent design-reviewer subagent（codex-rescue → general-purpose fallback，独立判断）
    scope: design-review + light security-review（不读新文件、不动凭证）
    verdict: approved-after-revisions
    notes: >
      无 must-fix。6 should-fix（已全部应用）：① SC3「最坏多等 ~pollingMinutes」措辞不准 —— 已改成精确描述（Retry-After ≤ P → 多等 ~P；> P → round 到 R 之后第一个 tick）；② `refreshAllEnabledOnOpen` 改成对 Claude 也调是隐性行为变化（每次开 popover 都拉 Claude）—— 已改回「Claude 仍只在 snapshot==nil 且不在 backoff 时兜一次」，保留 `shouldRefreshClaudeOnOpen`；③ 装配处 `coordinator.claude.refreshNow()` 与 `startBackgroundPolling()` 的立即 tick 重叠 —— 已去掉装配处那次、由立即 tick 承担（强调 onPollTick 必须先于 `startBackgroundPolling()` 设好）；④ Codex glyph 商标风险 —— SC6 改为优先 `</>`、明确不复刻 OpenAI 花结 logo；⑤ `SC_AUTO_NO_TIMER` grep 补 `currentInterval`；⑥ SC7 零回归含 `UsageProvider.swift` 注释更新。3 nit（已应用）：风险 #4 补「coordinator-map 方案为何拒绝」、SC2/SC5 边界说明、SC5(b) 的 `guard isAuthenticated` 去留留实施确认。核心设计（backoff 表达成 `nextEligibleRefresh` hint + coordinator 单 timer 跳过窗口内 provider；`backoffInterval()` 纯函数不动；`UsageService` 彻底无 timer）—— 获认可；timer 散点列举（SC2+SC5）经核对基本完整（唯一补点：`addAccount` 路径里 `await fetchProfile()` 已先调，`refreshNow` 里的 `if accountEmail == nil` 不会重复）。
  - gate: G5
    date: 2026-05-12
    reviewer: independent code-reviewer subagent（codex-rescue → general-purpose fallback，独立判断）
    scope: code-review + light security-review（重点核 UsageService timer 退役 + backoff 改写 + 账号切换 race）
    verdict: approved-with-nits
    notes: >
      无 must-fix。逐项确认通过：① UsageService timer 真清零（`grep -nE 'private var timer\b|scheduleTimer|func startPolling|private var currentInterval'` 零命中）；② backoff 语义正确（429 → prev/backoffInterval/backoffUntil 指数链递增到 cap；首次 429 文案仍 "Rate limited — backing off to 3600s"；成功/signOut/expireSession 清；backoffInterval 纯函数未动；nextEligibleRefresh { backoffUntil }）；③ **账号切换 race 安全**（coordinator 的 `Task { await p.refreshNow() }` 对 Claude 不持有/不可 cancel，但 fetchUsage 入口捕获 epoch + 收响应后/performRefresh 写 credentials 前都有 accountSwitchEpoch guard → 切换时在飞响应被丢弃）；④ switchAccount/addAccount/signOut/expireSession 散点改对（末尾从 startPolling() → 各自持有 currentFetchTask = Task{fetchUsage + profile-if-nil}）；⑤ updatePollingInterval → coordinator 经 UserDefaults.didChangeNotification 感知重起；⑥ UsageProvider 协议体有 nextEligibleRefresh { get }（必须）+ onPollTick { get set }，各 conformer 满足；⑦ coordinator onBackgroundTick 遍历全部 provider（含 Claude）+ 跳过 backoff 窗口 + 无向下转型；refreshAllEnabledOnOpen 保留 Claude 特判；startBackgroundPolling() 无参 + 装配顺序对；⑧ Task 并发/observer 生命周期与既有策略一致；⑨ </> glyph flipped 坐标正确正立、12pt 清晰、注释「非品牌 logo」、renderIcon 签名未动、.claude 走 PNG；⑩ 零回归（fetchUsage 各分支/pollingMinutes key/菜单栏 Claude/usageStats.refresh 节奏/Settings/PopoverView 全不动）；⑪ 测试覆盖 OK；⑫ 安全（无新文件读/网络/落盘；backoff 文案只含整数秒）。swift build 绿、swift test 251 全绿。
      1 should-fix（已应用）：testBackoffWindowSkipsProvider 的 sleep 40→100ms（防 CI flaky）。
      1 nit（已应用）：switchAccount doc comment 去掉残留「+ timer」字样。
---

# ProviderCoordinator 统一后台 timer（收编 Claude 的 backoff）+ Codex 菜单栏专属 glyph

## 1. 背景与目标

v0.2.10 让 `ProviderCoordinator` 统管了「非-Claude provider」的统一后台 timer，但 Claude 的后台 timer + 429 backoff 仍留在 `UsageService` 自己手里（迁移风险高，当时明确推后）。用户 2026-05-12 选了两个 v0.2.10 留后续项：

1. **把 Claude 的 backoff timer 也收编进 `ProviderCoordinator`** —— 真正「一个 timer 统管所有 provider」。
2. **给 Codex 做菜单栏专属 glyph**（v0.2.10 临时用 SF Symbol `terminal`）。

**关键设计**：不把 backoff「间隔」搬出去，而是把 backoff 表达成 provider 的一个**只读 hint**「`nextEligibleRefresh: Date?`」（「这个时刻之前别 tick 我」）。coordinator 的单个固定间隔（= `pollingMinutes`）timer 在每次 tick 时跳过还在 backoff 窗口里的 provider。这样 `UsageService` 彻底不再持有 `Timer`，backoff 状态收敛成两个简单字段（`currentBackoffSeconds` + `backoffUntil`），`backoffInterval()` 纯函数不动。代价：backoff 解析度被 round 到 `pollingMinutes` 边界（最坏多等一个 tick）—— 可接受。

**不含**：菜单栏在 menu-bar provider 是 Codex 时显示趋势箭头（仍 `showTrend == .claude`，留后续）；给 Codex 做真·图片资源 logo（先用代码绘制的 glyph）；`UsageService` 的 OAuth/refresh/多账号逻辑改动（只动 timer/backoff 那块）。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 怎么收编 Claude 的 backoff | provider 暴露只读 `nextEligibleRefresh: Date?`（默认 nil）；coordinator 的单 timer 每 tick 跳过窗口内的 provider；`UsageService` 删自持 timer、429 时设 `backoffUntil` | 不需要在 coordinator 里管「每 provider 一个变间隔 timer」；`UsageService` 的 timer 散点（startPolling/scheduleTimer/switchAccount/signOut/expireSession）一并清掉；`backoffInterval()` 纯函数不动 |
| backoff 解析度变粗 | 接受（最坏多等 ~`pollingMinutes`） | backoff 本就是「别 hammer」，多等无害；要精确就得 coordinator 动态调 timer 间隔（复杂、YAGNI） |
| `onPollTick` 提到协议 | 是 —— `UsageProvider` 加 `var onPollTick: (@MainActor () -> Void)? { get set }`（默认… 协议 `get set` 没法给「默认存储属性」，所以各 conformer 自己声明 `var onPollTick: ... = nil`；`CodexProvider` 已有、`UsageService` 新增、`StubProvider` 新增一行） | 统一「后台 tick 时驱动该 provider 的本机统计刷新」入口；`onBackgroundTick` 不再 `as? CodexProvider` 向下转型；Claude 的 `usageStats.refresh()` 也走这个口 |
| `startBackgroundPolling` 去掉 `codexOnPollTick:` 参数 | 是 —— 各 provider 的 `onPollTick` 由装配处单独设（`coordinator.claude.onPollTick = ...; coordinator.provider(.codex)?.onPollTick = ...; coordinator.startBackgroundPolling()`） | 不让 coordinator 知道有几个 provider 要 onPollTick；装配处本就知道 `usageStats`/`codexStats` |
| Claude 的「立即拉一次」 | 装配处 `coordinator.claude.refreshNow()`；`switchAccount`/`addAccount` 末尾 `currentFetchTask = Task { fetchUsage + profile-if-nil }` | `startPolling()` 没了；「立即一次」散到各调用点（其实就是 `refreshNow` + profile 判断） |
| Codex 菜单栏 glyph | 代码绘制的单色 `NSBezierPath` glyph —— **`</>` 尖括号对**（不复刻 OpenAI 商标 logo），不引入图片资源 | 没有 Codex logo PNG 可放；`</>` 12pt 下清晰、语义贴切、无商标风险；真·资源可后续替换 |

## 3. 设计

### 3.1 改动文件

| 文件 | 改动 |
|---|---|
| `UsageProvider.swift` | `extension UsageProvider` 加 `var nextEligibleRefresh: Date? { nil }`（默认）；协议体加 `var onPollTick: (@MainActor () -> Void)? { get set }`（无默认实现 —— conformer 各自声明存储属性）。`supportsBackgroundPolling` 的 TODO 注释不动（仍死 flag）。 |
| `UsageService.swift` | 删 `private var timer: Timer?` / `private func scheduleTimer()` / `func startPolling()` / 所有 `timer?.invalidate(); timer = nil`；删 `private var currentInterval` → 加 `private var currentBackoffSeconds: TimeInterval = 0` + `private var backoffUntil: Date? = nil`；`var nextEligibleRefresh: Date? { backoffUntil }`；`var onPollTick: (@MainActor () -> Void)? = nil`；`fetchUsage()` 的 429/成功分支按 SC2 改；`updatePollingInterval` 按 SC2 改；`switchAccount`/`addAccount`/`signOut`/`expireSession` 按 SC5 改；`refreshNow()`（已存在，conform UsageProvider）里 `await fetchUsage(); if accountEmail == nil { await fetchProfile() }`（把 profile 判断从删掉的 `startPolling` 搬来）。`init` 里 `currentInterval = ...` 那两行删（baseInterval 仍是计算属性）。 |
| `ProviderCoordinator.swift` | `onBackgroundTick()` 遍历 `availableIDs` 全部（不再 `where id != .claude`）：跳过 `nextEligibleRefresh > now` 的；`Task{await refreshNow()}` + `onPollTick?()`（协议成员、不向下转型）。`refreshAllEnabledOnOpen()`：非-Claude 跳过 backoff 窗口内的、否则 `await refreshNow()`；Claude 仍只在 `shouldRefreshClaudeOnOpen`（snapshot==nil 且不在 backoff）时拉一次（保留这个特判）。`startBackgroundPolling()` 去掉 `codexOnPollTick:` 参数（无参）。`backgroundIntervalSeconds` / `UserDefaults.didChangeNotification` 重起逻辑不动。 |
| `MenuBarIconRenderer.swift` | `drawProviderGlyph(for:.codex,...)` → 代码绘制的单色 glyph（`NSBezierPath`）。其它 case 不动（Claude PNG / 其它 SF Symbol）。 |
| `ClaudeUsageBarApp.swift` | `.task` 里：删 `coordinator.claude.startPolling()`；加 `await coordinator.claude.refreshNow()`（或放在已有的 `await usageStats.refresh()` 附近）+ `coordinator.claude.onPollTick = { Task.detached { await usageStats.refresh() } }` + `coordinator.provider(.codex)?.onPollTick = { Task.detached { await codexStats.refresh() } }` + `coordinator.startBackgroundPolling()`（无参）。原 `coordinator.startBackgroundPolling(codexOnPollTick:)` 的写法换掉。 |
| 测试 | `UsageServiceTests`（追加 429→backoffUntil / 成功→清）；`ProviderCoordinatorTests`（改 `testOnBackgroundTickDoesNotTouchClaude` → 现在会碰 Claude；加「fake provider 的 `nextEligibleRefresh` 在未来 → 这次 tick 跳过、之后 tick 到」；`refreshAllEnabledOnOpen` 对 Claude 也调）；`ProviderAbstractionTests` 的 `StubProvider` 加 `var onPollTick: ... = nil` conformance；`MenuBarIconRendererTests`（若有）确认不挂。 |

### 3.2 数据流（统一后台 timer）

```
ProviderCoordinator.backgroundTimer（Timer.publish every backgroundIntervalSeconds = pollingMinutes×60；监听 UserDefaults.didChangeNotification 变了重起）
        │  每 tick → onBackgroundTick()
        ▼
  for id in availableIDs:                                     // 现在含 .claude
        let p = registry.provider(id)
        if let due = p.nextEligibleRefresh, due > Date() { continue }   // 还在 backoff 窗口（仅 Claude 会用到）
        Task { await p.refreshNow() }                          // Claude: fetchUsage + profile-if-nil；Codex: refreshNow
        p.onPollTick?()                                        // Claude: { Task.detached { usageStats.refresh() } }；Codex: { Task.detached { codexStats.refresh() } }

UsageService.fetchUsage() 遇 429 → currentBackoffSeconds = backoffInterval(retryAfter, prev); backoffUntil = now + currentBackoffSeconds
                          成功     → currentBackoffSeconds = 0; backoffUntil = nil
                          → nextEligibleRefresh 反映 backoffUntil

popover 打开 → PopoverView.task（无 id）→ coordinator.refreshAllEnabledOnOpen()：非-Claude 跳过 backoff 窗口内的、否则 await refreshNow()；Claude 仅 shouldRefreshClaudeOnOpen（snapshot==nil 且不在 backoff）时拉一次
切 tab / 任何操作 → 不刷新（v0.2.10 已建立，不变）
底栏 Refresh → coordinator.refreshNow(selectedProvider)（不变）
装配处 ClaudeUsageBarApp.task → 设各 onPollTick → coordinator.claude.refreshNow()（立即一次）→ coordinator.startBackgroundPolling()
switchAccount / addAccount → currentFetchTask?.cancel() → ... → currentFetchTask = Task { fetchUsage + profile-if-nil }（立即一次；recurring 靠 coordinator timer）
```

### 3.3 测试方案（要点）

- `UsageServiceTests`：stub 一个 429 响应的 `URLSession`（带 / 不带 `Retry-After`）→ `await svc.fetchUsage()` → `XCTAssertNotNil(svc.nextEligibleRefresh)`、`XCTAssert(svc.nextEligibleRefresh! > Date())`、`svc.runtime.lastError` 含 "backing off"；再 stub 一个 200 → `await svc.fetchUsage()` → `XCTAssertNil(svc.nextEligibleRefresh)`。`testBackoffIntervalCapsAtSixtyMinutes` 不动（纯函数）。`grep` 确认 `UsageService.swift` 无 `private var timer` / `scheduleTimer` / `func startPolling`。
- `ProviderCoordinatorTests`：(a) `testOnBackgroundTickAlsoTicksClaude`（旧 `testOnBackgroundTickDoesNotTouchClaude` 改名 —— 用 fake claude？`ProviderCoordinator.claude` 类型固定 `UsageService`，没法塞 fake。折中：用真 `UsageService`（未登录）—— `onBackgroundTick()` 后它的 `refreshNow`→`fetchUsage` 走未登录分支不发网络、`runtime.lastError == "Not signed in"`；断言 `c.claude.runtime.lastError == "Not signed in"`（= 它确实被 tick 到了，而 v0.2.10 之前它不会被 onBackgroundTick 碰）。(b) `testBackoffWindowSkipsProvider`：注入一个 `StubProvider`（id 任意非 claude，如 `.cursor` —— 但 cursor 默认 enabled？是，allCases 全 enabled —— 注册它）覆写 `nextEligibleRefresh = Date().addingTimeInterval(3600)` → `onBackgroundTick()` → 断言该 stub 的 `refreshNowCallCount == 0`（给 StubProvider 加个计数器）；再把它的 `nextEligibleRefresh = nil` → `onBackgroundTick()` → `refreshNowCallCount == 1`。(c) `testRefreshAllEnabledOnOpenTicksClaude`：真 `UsageService` 未登录 → `await c.refreshAllEnabledOnOpen()` → `c.claude.runtime.lastError == "Not signed in"`（被拉过）。
- `ProviderAbstractionTests`：`StubProvider` 已有 `runtime`/`refreshNow`/`supportsBackgroundPolling` —— 加 `var onPollTick: (@MainActor () -> Void)? = nil` + 一个 `var refreshNowCallCount = 0`（`refreshNow` 里 `+= 1`）满足新协议成员 & 给 (b) 用。既有 `testCoordinatorDefaultsToClaude`/`testCoordinatorMenuBarSwitchTracksRuntime` 不动（除非编译要求 `StubProvider` 补成员 —— 补了就行）。
- `swift build` + `swift test` 全绿；`make release-artifacts` + `verify-release.sh`（zip/dmg）OK。SC6（Codex glyph）无自动化单测、靠 `swift build` + manual smoke。

CI 跑 `swift build -c release` + `swift test` + `make release-artifacts` + `verify-release.sh`，全绿。

## 4. 风险 / Open questions

1. **`UsageService` timer 散点遗漏** —— 最大风险点。`scheduleTimer()` 被 `startPolling`/`updatePollingInterval`/`fetchUsage`(429+recovery) 调；`timer?.invalidate(); timer = nil` 在 `switchAccount`/`addAccount`/`signOut`/`expireSession`(恢复路径)。SC5 逐一列了；实施时 **grep `timer`/`scheduleTimer`/`startPolling` 在 `UsageService.swift` 必须清零**（除 `currentFetchTask`）。`SC_AUTO_NO_TIMER` 自动 grep 守。
2. **backoff 解析度变粗** —— 重试时刻向上 round 到 `backoffUntil` 之后的第一个 `pollingMinutes` tick；`Retry-After ≤ pollingMinutes` 时最坏多等 ~`pollingMinutes`，`> pollingMinutes` 时跳过 ⌊R/P⌋ 个 tick。已在 §1/§2/SC3 写明、manual_checks 提了。可接受（backoff = 别 hammer 服务器）。
3. **`switchAccount`/`addAccount` 末尾的「立即拉一次」要带 epoch 语义** —— 原 `startPolling()` 里 `currentFetchTask = Task {...}` 已经持有 task 供 cancel；改写时保持「`currentFetchTask = Task { [weak self] in await self?.fetchUsage(); if self?.accountEmail == nil { await self?.fetchProfile() } }`」即可（epoch 比对在 `fetchUsage` 内部，不变）。
4. **`onPollTick` 协议成员要 `get set`** —— 协议没法给「默认存储属性」，所以每个 conformer（`UsageService`/`CodexProvider`/`StubProvider`）都得有 `var onPollTick: (@MainActor () -> Void)? = nil` 存储属性。`CodexProvider` 已有；实施给另两个加。考虑过的替代：coordinator 维护 `[ProviderID: @MainActor () -> Void]` map（不动协议）—— 拒绝，因为 `onBackgroundTick` 那时还得按 id 查 map 再调、并不更干净，且 `CodexProvider` 已有这个属性、改 map 反要动它；取这个轻微的协议污染换「`onBackgroundTick` 不向下转型」。
5. **Codex glyph 在 12pt 模板尺寸下要清晰** —— 六瓣花结太细可能糊；实施时先 build + `make install` 看一眼，糊就退回更粗的 `</>` 或简化形状（SC6 给了 fallback）。manual_checks 验。

## 5. 引用

- 前置 spec：[`2026-05-12-multi-provider-refactor.md`](./2026-05-12-multi-provider-refactor.md)、[`2026-05-12-settings-provider-list.md`](./2026-05-12-settings-provider-list.md)（v0.2.10：coordinator 统管非-Claude timer）、[`2026-05-12-codex-provider.md`](./2026-05-12-codex-provider.md)
- ADR：[`../adr/0005-reopen-multi-provider-direction.md`](../adr/0005-reopen-multi-provider-direction.md)
- 落地版本：[`../versions/v0.2.11-unified-poll-timer.md`](../versions/v0.2.11-unified-poll-timer.md)
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)

## Verification log

> G6 验收依据（详见 frontmatter `spec_criteria` 的 evidence）。

- [x] SC1 — `UsageProvider` 加 `nextEligibleRefresh` / `onPollTick`（协议成员）
- [x] SC2 — `UsageService` 退役自持 timer、backoff 改「截止时刻」语义
- [x] SC3 — `ProviderCoordinator.onBackgroundTick`/`refreshAllEnabledOnOpen` 覆盖所有 enabled provider（含 Claude，跳过 backoff 窗口内的）
- [x] SC4 — 装配处改线（各 onPollTick 单独设 + `startBackgroundPolling()` 无参）
- [x] SC5 — `UsageService` 各 timer 散点改对（grep 清零）
- [x] SC6 — Codex 菜单栏专属 glyph（代码绘制）
- [x] SC7 — Claude / 既有行为零回归
- [x] SC8 — swift build / swift test（含新测试）/ make release-artifacts + verify 全绿
