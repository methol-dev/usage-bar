# Issue #10 诊断

- 链接：https://github.com/methol/usage-bar/issues/10
- 标题：[bug] codex数据刷新时间和claude不一致

## 复现与定位

每次点击菜单栏图标打开 popover，`PopoverView` 的 `.task` modifier 触发：
```swift
.task { await coordinator.refreshAllEnabledOnOpen() }
```
在 `ProviderCoordinator.refreshAllEnabledOnOpen()`（`ProviderCoordinator.swift:143`）中：
- Claude：检查 `shouldRefreshClaudeOnOpen`，仅在 `runtime.snapshot == nil`（首屏空数据）时才刷新
- 非 Claude（Codex）：**无条件**调用 `refreshNow()`，每次打开都刷

→ Codex 的"上次刷新时间"被每次打开 popover 的操作重置，与 Claude 不一致。

## 根因

`refreshAllEnabledOnOpen()` 对 Claude 和 Codex 的刷新策略不对称：

```swift
// 当前代码（ProviderCoordinator.swift:143-153）
func refreshAllEnabledOnOpen() async {
    for id in availableIDs {
        guard let p = registry.provider(id) else { continue }
        if let due = p.nextEligibleRefresh, due > Date() { continue }
        if id == .claude {
            if shouldRefreshClaudeOnOpen { await p.refreshNow() }  // 有保护
        } else {
            await p.refreshNow()  // BUG：无保护，每次打开都刷
        }
    }
}
```

## 修复方案

统一所有 provider 的刷新策略：仅当 `runtime.snapshot == nil`（还没有数据）时才刷新。

```swift
func refreshAllEnabledOnOpen() async {
    for id in availableIDs {
        guard let p = registry.provider(id) else { continue }
        if let due = p.nextEligibleRefresh, due > Date() { continue }
        guard p.runtime.snapshot == nil else { continue }
        await p.refreshNow()
    }
}
```

同步删除已无用的 `shouldRefreshClaudeOnOpen` 计算属性（`ProviderCoordinator.swift:136-140`），
因为其逻辑已被上面的 `guard p.runtime.snapshot == nil` 覆盖（backoff 检查已在循环外层做）。

修改文件：`macos/Sources/UsageBar/ProviderCoordinator.swift`（约 -10 行 / +3 行）

## 影响范围

- 修改文件：`macos/Sources/UsageBar/ProviderCoordinator.swift`
- 风险点：
  - `startBackgroundPolling()` 在 app 启动时已做一次立即 tick（`onBackgroundTick()`），会先拉一次数据。若 app 刚起 + 用户极快打开 popover（background fetch 还未完成），`snapshot == nil` 仍成立，会触发刷新 —— 等价于现有"首屏兜底"逻辑，行为正确。
  - 用户手动点 Refresh 按钮走 `refreshNow(_ id:)` 不受影响。
- 测试计划：
  - `cd macos && swift build -c release` + `swift test`
  - 手动：启动 app → 等 snapshot 加载 → 多次打开关闭 popover → 观察 Codex 刷新时间不再变化

## 守护线自检

- [x] 不触碰凭证 / 密钥链路（不改 OAuth / token / Sparkle 相关）
- [x] 不引入新第三方依赖
- [x] 不修改 `docs/adr/` 下已 `accepted` 的 ADR
- [x] 不在 `UsageService` 之外重复 fetch / auth / 轮询逻辑（修复的是刷新纪律，不是新增轮询）
- [x] 不手改 `Info.plist` 里的版本号
- [x] 影响文件仅 1 个，改动量 ≤ 5 文件

## 是否需要人工介入

- 结论：NO
- 理由：守护线全绿，改动范围极小（单文件约 10 行），无架构变动
