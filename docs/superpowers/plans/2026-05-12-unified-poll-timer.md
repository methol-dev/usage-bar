# 统一后台 timer + Codex 菜单栏 glyph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans。步骤用 checkbox。

**Goal:** `ProviderCoordinator` 真正统管所有 provider 的后台轮询 timer（含 Claude）—— `UsageService` 退役自持 `Timer`，429 backoff 改成只读 hint `nextEligibleRefresh: Date?`，coordinator 单 timer 每 tick 跳过 backoff 窗口内的 provider；Codex 菜单栏改用代码绘制的 `</>` glyph。Claude / 既有行为零回归。

**Architecture:** `UsageProvider` 加 `var nextEligibleRefresh: Date? { nil }`（默认实现）+ `var onPollTick: (@MainActor () -> Void)? { get set }`（协议成员，conformer 各自加存储属性）。`UsageService` 删 `timer`/`scheduleTimer()`/`startPolling()`/`currentInterval`，加 `currentBackoffSeconds`+`backoffUntil`，`nextEligibleRefresh { backoffUntil }`，`onPollTick`；`fetchUsage` 429→设 backoffUntil、成功→清；`refreshNow()` 里补 profile 判断；`switchAccount`/`addAccount`/`signOut`/`expireSession` 的 timer 散点改对。`ProviderCoordinator.onBackgroundTick()` 遍历全部 enabled provider、跳过 `nextEligibleRefresh > now` 的、`Task{await refreshNow()}` + `onPollTick?()`；`refreshAllEnabledOnOpen()` 非-Claude 各拉、Claude 仅 `shouldRefreshClaudeOnOpen` 时拉；`startBackgroundPolling()` 无参。`ClaudeUsageBarApp` 改：设各 onPollTick → `startBackgroundPolling()`（不再单独 `claude.refreshNow()`）。`MenuBarIconRenderer.drawProviderGlyph(for:.codex,...)` 改 `NSBezierPath` 画 `</>`。

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit / Combine（coordinator 的 `Timer.publish` 不变）/ XCTest。命令用绝对路径（`cd /Users/methol/data/code-methol/usage-bar/macos` 或 repo 根）。

> 对应 spec：[`../specs/2026-05-12-unified-poll-timer.md`](../specs/2026-05-12-unified-poll-timer.md)（G2 approved-after-revisions，8 SC）。机械细节以 spec §3.1 为准。**最大风险点（spec §4 #1）：`UsageService` timer 散点遗漏** —— 实施时逐一 grep `timer`/`scheduleTimer`/`startPolling`/`currentInterval` 在 `UsageService.swift` 必须清零（`currentFetchTask` 保留）。

---

## File Structure

改：`UsageProvider.swift`、`UsageService.swift`、`ProviderCoordinator.swift`、`ClaudeUsageBarApp.swift`、`MenuBarIconRenderer.swift`；测试 `UsageServiceTests.swift`（追加）、`ProviderCoordinatorTests.swift`（改/追加）、`ProviderAbstractionTests.swift`（`StubProvider` 加成员）。

---

## Task 1: `UsageProvider` 协议泛化 + `UsageService` 退役自持 timer + backoff 改「截止时刻」

**Files:** Modify `UsageProvider.swift`、`UsageService.swift`；`UsageServiceTests.swift`（追加失败测试）；`ProviderAbstractionTests.swift`（`StubProvider` 补 `onPollTick` 让编译过）。

- [x] **Step 1: 写失败测试（追加到 `UsageServiceTests.swift`）** —— 仿既有 `UsageServiceTests` 的 stub session 套路（看现有文件怎么 stub `URLSession`）：

```swift
    @MainActor
    func testFetchUsage429SetsBackoffUntil() async throws {
        // stub 一个返回 429 + Retry-After: 120 的 URLSession，凭证用 fake（让 loadCredentials() != nil）
        let svc = makeServiceWith429(retryAfterSeconds: 120)   // helper：构造 UsageService（注入 stub session + 临时 credentialsStore + 预写一个 fake credentials.json）
        await svc.fetchUsage()
        XCTAssertNotNil(svc.nextEligibleRefresh)
        XCTAssertGreaterThan(svc.nextEligibleRefresh!, Date())
        XCTAssertTrue((svc.runtime.lastError ?? "").contains("backing off"))
    }
    @MainActor
    func testFetchUsageSuccessClearsBackoff() async throws {
        let svc = makeServiceWith429(retryAfterSeconds: 120)
        await svc.fetchUsage()
        XCTAssertNotNil(svc.nextEligibleRefresh)
        // 换成 200 响应后再 fetch 一次
        svc.swapStubTo200(usageJSON: <一段合法的 UsageResponse JSON>)
        await svc.fetchUsage()
        XCTAssertNil(svc.nextEligibleRefresh)
    }
```

> 注：上面的 `makeServiceWith429` / `swapStubTo200` 是要在测试里写的 helper —— **实施时先看 `UsageServiceTests.swift` 现有怎么注入 stub `URLSession` 和 `credentialsStore`**（`UsageService.init` 收 `session:` / `credentialsStore:`），照搬。一段合法 `UsageResponse` JSON：现有测试里应有（`five_hour`/`seven_day` 那个 schema）。`testBackoffIntervalCapsAtSixtyMinutes` 不动。

- [x] **Step 2: 跑确认失败** — `cd /Users/methol/data/code-methol/usage-bar/macos && swift test --filter UsageServiceTests` → 编译失败（`svc.nextEligibleRefresh` 不存在）。

- [x] **Step 3: 改 `UsageProvider.swift`**
  - 协议体加 `var onPollTick: (@MainActor () -> Void)? { get set }`（无默认实现）。
  - `extension UsageProvider` 加 `var nextEligibleRefresh: Date? { nil }`（默认实现）。
  - 更新文件顶部的 doc 注释（删「Claude 的后台 timer + 429 backoff 仍归 `UsageService` 自己（`claude.startPolling()`）」那段，改成「所有 provider 的后台轮询由 `ProviderCoordinator` 统管；provider 用 `nextEligibleRefresh` hint 表达 backoff、`onPollTick` 驱动本机统计刷新」）。`supportsBackgroundPolling` 的 TODO 注释不动。

- [x] **Step 4: 改 `UsageService.swift`**
  - 删 `private var timer: Timer?`（约 :28）；删 `private func scheduleTimer() { ... }`（约 :228-241）；删 `func startPolling() { ... }`（约 :217-226）。
  - `private var currentInterval: TimeInterval`（:39 + init :114）→ 改成 `private var currentBackoffSeconds: TimeInterval = 0` + `private var backoffUntil: Date? = nil`；init 里 `self.currentInterval = ...` 那行删（`baseInterval` 仍是计算属性 `TimeInterval(pollingMinutes * 60)`，不动）。
  - 加 `var onPollTick: (@MainActor () -> Void)? = nil`。
  - 加 `var nextEligibleRefresh: Date? { backoffUntil }`。
  - `func refreshNow()`（已存在、conform `UsageProvider`）—— 改成（保留它原来调 `fetchUsage()` 的语义 + 补 profile）：
    ```swift
    func refreshNow() async {
        await fetchUsage()
        if accountEmail == nil { await fetchProfile() }
    }
    ```
    （实施时读现有 `refreshNow()` 确认它现在长啥样 —— 大概就是 `await fetchUsage()`，加一行 profile 判断即可。注意：`startPolling()` 里那次 `currentFetchTask = Task { ... }` 持有 task 是为了 `switchAccount` 能 cancel —— 见 Step 5(b)/(c) 各调用点自己持有。）
  - `updatePollingInterval(_ minutes:)`（:60-67）→ 改成：
    ```swift
    func updatePollingInterval(_ minutes: Int) {
        pollingMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "pollingMinutes")
        if isAuthenticated { currentFetchTask = Task { [weak self] in await self?.fetchUsage() } }
    }
    ```
    （删 `currentInterval = ...` / `scheduleTimer()`；recurring 由 coordinator timer，它监听 `UserDefaults.didChangeNotification` 自动重起。）
  - `fetchUsage()` 里 429 分支（约 :464-475）：
    ```swift
    if http.statusCode == 429 {
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        let prev = currentBackoffSeconds == 0 ? baseInterval : currentBackoffSeconds
        currentBackoffSeconds = Self.backoffInterval(retryAfter: retryAfter, currentInterval: prev)
        backoffUntil = Date().addingTimeInterval(currentBackoffSeconds)
        lastError = "Rate limited — backing off to \(Int(currentBackoffSeconds))s"
        runtime.setError(lastError ?? "Rate limited", clearSnapshot: false)
        return
    }
    ```
    （删 `scheduleTimer()`。注意 `backoffInterval` 现在第一个参数是 `Double?`（`retryAfter` 直接传 optional）—— 函数签名 `backoffInterval(retryAfter: TimeInterval?, currentInterval:)` 本来就收 optional，OK；原来代码是 `.flatMap(Double.init) ?? currentInterval` 再传非-optional —— 现在改成传 optional 让函数内部 `?? currentInterval` 处理，等价。）
  - `fetchUsage()` 成功分支末尾（约 :490-493）：把 `if currentInterval != baseInterval { currentInterval = baseInterval; scheduleTimer() }` 改成：
    ```swift
    currentBackoffSeconds = 0
    backoffUntil = nil
    ```
  - 删 `init` 里的 `self.currentInterval = TimeInterval(minutes * 60)`（:114）。

- [x] **Step 5: 改 `UsageService.swift` 的 timer 散点（依赖 Step 4 已删 `timer`/`startPolling`）**
  - (b) `switchAccount(to:)`（约 :160-208）：删 `timer?.invalidate(); timer = nil`（:167-168）；末尾的 `startPolling()`（:207）→ `currentFetchTask = Task { [weak self] in await self?.fetchUsage(); if self?.accountEmail == nil { await self?.fetchProfile() } }`。
  - (c) `addAccount`/`completeSignIn` 路径（约 :355-402）：`if !isFirst { ... currentFetchTask?.cancel(); ...; timer?.invalidate(); timer = nil; accountSwitchEpoch += 1; ... }` → 删 `timer?.invalidate(); timer = nil` 那行（其余 cancel/epoch 不动）；末尾 `await fetchProfile(); startPolling()`（:400-401）→ `await fetchProfile(); currentFetchTask = Task { [weak self] in await self?.fetchUsage() }`（profile 已先调，不用再 `if accountEmail == nil`）。
  - (d) `signOut()`（约 :409-420）：删 `timer?.invalidate(); timer = nil`（:417-418）（其余 `currentFetchTask?.cancel()` / `refreshTask?.cancel()` 不动）。
  - (e) `expireSession`（约 :805-830）：CLI 凭证恢复成功路径里那段 `timer?.invalidate(); timer = nil`（:820-821）→ 删（恢复后下一轮 coordinator tick 自然用新 token）；走原硬过期路径时若有 `startPolling()` —— 改成 `currentFetchTask = Task { [weak self] in await self?.fetchUsage() }`（实施时读 `expireSession` 确认有没有这一支）。
  - **grep 验证**：`grep -n 'private var timer\|scheduleTimer\|func startPolling\|currentInterval' Sources/ClaudeUsageBar/UsageService.swift` → 无命中。`grep -n 'startPolling' Sources/` → 只剩……（`coordinator.claude.startPolling()` 那行在 `ClaudeUsageBarApp` 会在 Task 3 删；本 Task 暂时会编译失败 —— 见 Step 6 注）。

- [x] **Step 6: `ProviderAbstractionTests.swift` 的 `StubProvider` 加 `var onPollTick: (@MainActor () -> Void)? = nil`**（满足新协议成员，让测试编译过）+ 顺手加 `var refreshNowCallCount = 0`、`var nextEligibleRefreshOverride: Date? = nil` + `nextEligibleRefresh` 计算属性返回 override、`refreshNow()` 里 `refreshNowCallCount += 1`（给 Task 2 的测试用）。`ClaudeUsageBarApp.swift` 里 `coordinator.claude.startPolling()` 还在 —— **本 Task 不动它**（Task 3 改）；为让 `swift build` 在本 Task 结束时过，临时把 `ClaudeUsageBarApp.swift` 那行 `coordinator.claude.startPolling()` 改成 `coordinator.claude.refreshNow()` 包一个 `Task { await ... }`（或直接删掉 —— Task 3 会重写这段）；`ProviderCoordinator.startBackgroundPolling(codexOnPollTick:)` 调用点（`ClaudeUsageBarApp`）也还在、本 Task 不动（Task 3 改）—— 但 `startBackgroundPolling` 的 `onBackgroundTick` 里 `(p as? CodexProvider)?.onPollTick?()` 仍能编译（`CodexProvider.onPollTick` 还在）。⚠️ 实施时若本 Task 改完编译不过、就把 `ClaudeUsageBarApp` / `ProviderCoordinator` 的相关行临时桥一下让 build 过，Task 3 正式改。

- [x] **Step 7: 跑确认通过** — `swift test --filter UsageServiceTests` → all PASS。

- [x] **Step 8: build + 全量 test** — `swift build -c release && swift test` → 全绿。

- [x] **Step 9: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/ClaudeUsageBar/{UsageProvider,UsageService}.swift macos/Tests/ClaudeUsageBarTests/{UsageServiceTests,ProviderAbstractionTests}.swift macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift
git commit -m "feat: v0.2.11 — UsageProvider 加 nextEligibleRefresh hint + onPollTick（协议成员）；UsageService 退役自持 Timer（删 timer/scheduleTimer/startPolling/currentInterval），429 backoff 改成 backoffUntil 截止时刻语义、成功清；refreshNow 补 profile 判断；switchAccount/addAccount/signOut/expireSession 的 timer 散点改对 [spec:2026-05-12-unified-poll-timer]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `ProviderCoordinator` 后台 timer 覆盖所有 provider（含 Claude）

**Files:** Modify `ProviderCoordinator.swift`；`ProviderCoordinatorTests.swift`（改/追加）。

- [x] **Step 1: 改测试** —— `ProviderCoordinatorTests.swift`：
  - 旧 `testOnBackgroundTickDoesNotTouchClaude` → 改名 `testOnBackgroundTickAlsoTicksClaude`，断言改成「`onBackgroundTick()` 后 `c.claude.runtime.lastError == "Not signed in"`」（真 `UsageService` 未登录 → `refreshNow`→`fetchUsage` 走未登录分支不发网络、设 `lastError`/`runtime.setError`）；先 `await Task.yield(); try? await Task.sleep(nanoseconds: 50_000_000)` 等异步 tick。
  - 加 `testBackoffWindowSkipsProvider`：构造 `ProviderCoordinator(claude: makeUnauthClaude(), additionalProviders: [stub], defaults: freshDefaults())` 其中 `stub = StubProvider(id: .cursor)`（cursor 默认 enabled）；`stub.nextEligibleRefreshOverride = Date().addingTimeInterval(3600)`；`c.onBackgroundTick()` → `await Task.yield(); try? await Task.sleep(nanoseconds: 30_000_000)` → `XCTAssertEqual(stub.refreshNowCallCount, 0)`；再 `stub.nextEligibleRefreshOverride = nil` → `c.onBackgroundTick()` → 等 → `XCTAssertEqual(stub.refreshNowCallCount, 1)`。（注：`makeUnauthClaude()` = `UsageService(credentialsStore: StoredCredentialsStore(directoryURL: tmpDir()))`，仿现有 helper。）
  - `testRefreshAllEnabledOnOpenTicksClaudeWhenSnapshotNil`：真未登录 `UsageService` → `await c.refreshAllEnabledOnOpen()` → `c.claude.runtime.lastError == "Not signed in"`（snapshot==nil、不在 backoff → 被拉一次）。
  - `testShouldRefreshClaudeOnOpenWhenSnapshotNil` 若还在 —— 保留（语义不变：未登录 UsageService 的 `runtime.snapshot == nil` → true）。

- [x] **Step 2: 跑确认失败** — `swift test --filter ProviderCoordinatorTests` → 编译失败 / 旧 `testOnBackgroundTickDoesNotTouchClaude` 找不到。

- [x] **Step 3: 改 `ProviderCoordinator.swift`**
  - `onBackgroundTick()`：
    ```swift
    func onBackgroundTick() {
        for id in availableIDs {                          // 现在含 .claude（去掉 `where id != .claude`）
            guard let p = registry.provider(id) else { continue }
            if let due = p.nextEligibleRefresh, due > Date() { continue }   // 还在 backoff 窗口里 → 这一 tick 跳过
            Task { await p.refreshNow() }
            p.onPollTick?()                               // 协议成员，不再 `as? CodexProvider`
        }
    }
    ```
  - `shouldRefreshClaudeOnOpen`：改成 `var shouldRefreshClaudeOnOpen: Bool { claude.runtime.snapshot == nil && (claude.nextEligibleRefresh == nil || claude.nextEligibleRefresh! <= Date()) }`。
  - `refreshAllEnabledOnOpen()`：
    ```swift
    func refreshAllEnabledOnOpen() async {
        for id in availableIDs {
            guard let p = registry.provider(id) else { continue }
            if let due = p.nextEligibleRefresh, due > Date() { continue }
            if id == .claude {
                if shouldRefreshClaudeOnOpen { await p.refreshNow() }   // Claude 仅首屏空时兜一次
            } else {
                await p.refreshNow()
            }
        }
    }
    ```
  - `startBackgroundPolling(codexOnPollTick:)` → `startBackgroundPolling()`（去参数）：体里删「`(registry.provider(.codex) as? CodexProvider)?.onPollTick = codexOnPollTick`」那行（各 provider 的 onPollTick 由装配处设）；其余（`rescheduleBackgroundTimer()` + 立即 `onBackgroundTick()` + 注册 `UserDefaults.didChangeNotification` observer）不变。

- [x] **Step 4: 跑确认通过** — `swift test --filter ProviderCoordinatorTests` → all PASS（`onBackgroundTick` 那行 `p.onPollTick?()` —— 此时 `UsageService.onPollTick` 已在 Task 1 加、`CodexProvider.onPollTick` 已有、`StubProvider.onPollTick` Task 1 Step 6 加 → 协议成员调用 OK）。`ClaudeUsageBarApp` 里 `startBackgroundPolling(codexOnPollTick:)` 调用点现在编译失败 —— 临时改成 `startBackgroundPolling()` + 把 `codexOnPollTick` 那个闭包暂时丢一边（Task 3 正式改）；为 build 过。

- [x] **Step 5: build + 全量 test** — `swift build -c release && swift test` → 全绿。

- [x] **Step 6: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{ProviderCoordinator,ClaudeUsageBarApp}.swift macos/Tests/ClaudeUsageBarTests/ProviderCoordinatorTests.swift
git commit -m "feat: v0.2.11 — ProviderCoordinator.onBackgroundTick 覆盖所有 enabled provider（含 Claude，跳过 nextEligibleRefresh > now 的）+ onPollTick 不再向下转型；refreshAllEnabledOnOpen 非-Claude 各拉、Claude 仅 snapshot==nil 时兜；startBackgroundPolling 去 codexOnPollTick 参数 [spec:2026-05-12-unified-poll-timer]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 装配处改线 + Codex 菜单栏 `</>` glyph

**Files:** Modify `ClaudeUsageBarApp.swift`、`MenuBarIconRenderer.swift`、`CodexProvider.swift`（删 `onPollTick` 上的「装配处用它驱动」注释微调 —— 可选）。无新单测（装配 + 纯渲染，靠 build + manual smoke）。

- [x] **Step 1: 改 `ClaudeUsageBarApp.swift`** —— `.task` 里那段（v0.2.10 是 `coordinator.startBackgroundPolling(codexOnPollTick: { Task.detached { await codexStats.refresh() } })`，加上 Task 1/2 临时桥的痕迹）改成：
```swift
// 各 provider 的本机统计刷新随后台 tick 走 onPollTick（Claude 的逻辑原在 UsageService.scheduleTimer 里）
coordinator.claude.onPollTick = { Task.detached { await usageStats.refresh() } }
coordinator.provider(.codex)?.onPollTick = { Task.detached { await codexStats.refresh() } }
// 起统一后台 timer（含 Claude；监听 pollingMinutes 变化重起）+ 立即各拉一次（这一次就拉了 Claude，不用再单独 refreshNow）
coordinator.startBackgroundPolling()
```
（删 `coordinator.claude.startPolling()`（已没这个方法）；`await usageStats.refresh()` / `await codexStats.refresh()` 启动期那两行保留 —— 它们在上面这段之前。`fetchProfile` 已并进 `UsageService.refreshNow()`，不用在这里管。）

- [x] **Step 2: 改 `MenuBarIconRenderer.swift`** —— `drawProviderGlyph(for:.codex,...)` 分支改成代码绘制 `</>`：
```swift
private func drawProviderGlyph(for id: ProviderID, x: CGFloat, y: CGFloat, size: CGFloat) {
    if id == .claude, let logo = claudeLogoImage {
        logo.draw(in: NSRect(x: x, y: y, width: size, height: size)); return
    }
    if id == .codex {
        // 自绘的 `</>` 标记（非任何品牌 logo）—— 三笔画：左尖括号 `<`、中斜杠 `/`、右尖括号 `>`。
        let lw = max(size * 0.16, 1.4)            // 笔宽随尺寸缩放，下限 1.4pt
        let path = NSBezierPath()
        path.lineWidth = lw
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let cx = x + size / 2, top = y + size * 0.18, bot = y + size * 0.82, mid = y + size / 2
        let lOuter = x + size * 0.10, lInner = x + size * 0.34
        let rOuter = x + size * 0.90, rInner = x + size * 0.66
        // `<`
        path.move(to: NSPoint(x: lInner, y: top)); path.line(to: NSPoint(x: lOuter, y: mid)); path.line(to: NSPoint(x: lInner, y: bot))
        // `>`
        path.move(to: NSPoint(x: rInner, y: top)); path.line(to: NSPoint(x: rOuter, y: mid)); path.line(to: NSPoint(x: rInner, y: bot))
        // `/`（中间斜杠）
        path.move(to: NSPoint(x: cx + size * 0.10, y: top)); path.line(to: NSPoint(x: cx - size * 0.10, y: bot))
        NSColor.black.setStroke()
        path.stroke()
        return
    }
    // 其它未注册 provider：SF Symbol
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    if let sym = NSImage(systemSymbolName: sfSymbolName(for: id), accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        sym.isTemplate = true
        let s = sym.size; let scale = min(size / max(s.width, 1), size / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        sym.draw(in: NSRect(x: x + (size - w) / 2, y: y + (size - h) / 2, width: w, height: h))
    }
}
```
（注：`y` 方向 —— renderer 的绘图上下文是 `NSImage(size:flipped: true)`，`top`/`bot` 用 `y + size*小` / `y + size*大`，flipped 下「小 y」在上，所以 `<`/`>` 的尖端在中间、`/` 从右上到左下 —— 视觉上是个标准 `</>`。`sfSymbolName(for:)` 的 `.codex` case 可保留（现在走不到了）也可删，无碍。）`drawProviderGlyph(for:.claude,...)` 字节不变；`renderIcon`/`renderUnauthenticatedIcon` 签名不变。

- [x] **Step 3: build + 全量 test** — `swift build -c release && swift test` → 全绿（无新测试，回归确认）。

- [x] **Step 4: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{ClaudeUsageBarApp,MenuBarIconRenderer}.swift
git commit -m "feat: v0.2.11 — 装配处改线（各 provider onPollTick 单独设 + startBackgroundPolling() 无参，含 Claude）；Codex 菜单栏改用代码自绘的 </> glyph（取代 SF Symbol terminal，无商标风险）[spec:2026-05-12-unified-poll-timer]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 全量验收 + 回填文档（G6）

- [x] **Step 1: build + test + artifacts + verify + grep**

```bash
cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release && swift test
cd /Users/methol/data/code-methol/usage-bar && make release-artifacts && bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip
grep -n 'private var timer\|scheduleTimer\|func startPolling\|currentInterval' macos/Sources/ClaudeUsageBar/UsageService.swift   # 期望无命中（SC_AUTO_NO_TIMER）
```
Expected: build OK；全部 tests PASS；zip/dmg + verify「Release archive looks good」；grep 无命中。

- [x] **Step 2: `make install` + 手动 smoke** —
  - 重开 app：Claude tab 正常拉数（Updated 时间按 pollingMinutes 节奏更新）；改 Settings 的 Polling Interval（30→5min）→ Claude 与 Codex 的 Updated 时间在 ~5min 内更新；改回 30min 同样跟随。
  - 菜单栏 ✓ 切到 Codex → 显示新的 `</>` glyph（不是 SF terminal）；切回 Claude → PNG logo。
  - Settings 里没 Account section（v0.2.10 已去）；popover 底栏有 Sign Out（已登录时）。
  把观察记进 spec evidence + Verification log。

- [x] **Step 3: 回填 spec/version** — `2026-05-12-unified-poll-timer.md`：`spec_criteria[].done` 全 true + evidence、Verification log 全勾、`status: accepted → implemented`、`updated` 同步、append G5 verdict（Task 5 后）。`docs/versions/v0.2.11-unified-poll-timer.md`：`status: planned → in-progress`、填 `release_notes_zh`（改进：—— 内部为主，用户视角变化小；可写「内部：后台轮询统一由 ProviderCoordinator 管理（含 Claude 的 429 backoff）；Codex 菜单栏图标换成自绘的 </> 标记。注：429 限速时的重试时刻现在 round 到下一个轮询周期」）、G6 checklist 勾。`docs/versions/README.md` + `docs/superpowers/specs/README.md` 同步状态。本 plan 勾掉步骤（除 Task 5 的 G5/PR）。Commit。

- [ ] **Step 4: G5 + PR + merge** — 独立 reviewer（codex `codex-rescue` / `general-purpose` subagent）code-review + light security-review（敏感面小，但**重点核 `UsageService` 的 timer 散点是否真清零 + backoff 语义正确 + race-fix(epoch) 没被破坏**）。verdict approved/approved-with-nits 后 `gh pr create`（中文，含 spec id + version 链接），等 CI（"build" job）绿 → `git checkout main && git merge --ff-only feat/v0.2.11-unified-poll-timer && git push origin main` + 删分支。G5 verdict append 进 spec `reviews:`。`make install` 装最终 main。

---

## Self-Review

- **Spec coverage**：SC1→Task1 Step3（协议）+ Step4（UsageService 加 nextEligibleRefresh/onPollTick）；SC2→Task1 Step4（退役 timer + backoff 截止时刻）；SC3→Task2 Step3（onBackgroundTick 含 Claude / refreshAllEnabledOnOpen / startBackgroundPolling 无参）；SC4→Task3 Step1（装配改线）；SC5→Task1 Step5（timer 散点）+ Task4 Step1 的 grep；SC6→Task3 Step2（</> glyph）；SC7→贯穿（各 Task 末「全量 test」守既有全绿 + `backoffInterval` 纯函数不动 + Claude 行为只动 timer/backoff 那块 + UsageProvider 注释更新）；SC8→各 Task build/test + Task4 Step1。
- **Placeholder scan**：关键代码（`onBackgroundTick`/`refreshAllEnabledOnOpen` 新体、`fetchUsage` 429/成功分支改法、`</>` glyph 全代码、装配改线）已给出；机械的（`UsageService` timer 散点删除、`switchAccount`/`addAccount` 的 `currentFetchTask = Task{...}` 替换）以「读现有 X 照改 Y + spec §3.1」代替 —— 每处说清了改哪行成什么 + 行号大约。
- **风险点已标注**：Task1 的 `UsageService` timer 散点遗漏（最大风险 —— Step5 逐一列 + grep 守 + `SC_AUTO_NO_TIMER`）；Task1/2 中途编译过的桥接（Step6 / Task2 Step4 callout —— 临时改 `ClaudeUsageBarApp`/`ProviderCoordinator` 调用点让 build 过，Task3 正式改）；Task3 的 `</>` glyph 在 12pt 下清晰度（manual smoke 验，糊就调笔宽/坐标 —— SC6 本就允许微调）；测试里 `Task.yield + sleep(50ms)` 等异步 tick 的脆弱性（继承自既有测试，不是本 spec 引入）。
- **Type consistency**：`UsageProvider.nextEligibleRefresh: Date?`（默认 nil）/ `UsageProvider.onPollTick: (@MainActor () -> Void)? { get set }`；`UsageService.{currentBackoffSeconds: TimeInterval, backoffUntil: Date?, onPollTick, nextEligibleRefresh, refreshNow()}`，删 `{timer, scheduleTimer(), startPolling(), currentInterval}`；`ProviderCoordinator.{onBackgroundTick(), refreshAllEnabledOnOpen(), shouldRefreshClaudeOnOpen, startBackgroundPolling()}`（去 `codexOnPollTick:`）；`MenuBarIconRenderer.drawProviderGlyph(for:x:y:size:)` 签名不变；`StubProvider.{onPollTick, refreshNowCallCount, nextEligibleRefreshOverride, nextEligibleRefresh}`；`ClaudeUsageBarApp` 装配 `coordinator.claude.onPollTick = ...; coordinator.provider(.codex)?.onPollTick = ...; coordinator.startBackgroundPolling()` —— 各 Task 间一致。
