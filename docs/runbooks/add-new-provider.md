# Runbook — 接入新 Provider

> AI 标准流程：为 usage-bar 接入一个新的用量数据源（如 Cursor / Copilot / Gemini）。  
> 本文件是操作级清单；架构决策见 [ADR 0005](../adr/0005-reopen-multi-provider-direction.md) 与 spec `2026-05-12-multi-provider-refactor`（历史 spec，见 git history），  
> 扩展性设计原则见机器本地 memory `project_provider_extensibility.md`（`.claude` 项目 memory，不随仓库分发）。

---

## 0. 适用范围与前置条件

**适用**：读取某 CLI 工具留在本机的凭证、调用其 API 或扫描本地日志、展示用量/费用卡。  
**不适用**：架构级改造、引入新第三方 Swift 依赖、触动 OAuth 链路 —— 这类先走 `AGENTS.md`「开发工作流」（plan mode + plan review，必要时写 ADR）。

**前置**：

- [ ] `ProviderID` 枚举已有该 provider 的 case（`macos/Sources/UsageBar/Models/ProviderID.swift`）  
  若没有：加一行 `case <name>`（`rawValue` 同时是磁盘目录名，用小写英文，**不改现有 case**）
- [ ] 理解了凭证来源（文件路径、格式）与 API 端点（或本地日志路径）
- [ ] 新 provider 的数据接入不触碰 AGENTS.md「Hard Gates」的情形（凭证写入 / 新第三方依赖 / ADR）

---

## 1. 创建文件骨架

```bash
mkdir -p macos/Sources/UsageBar/Providers/<Name>
```

至少需要以下文件（参考 `Providers/Codex/`）：

| 文件 | 职责 |
|---|---|
| `<Name>Credentials.swift` | 读取本机凭证（只读，**不写回**；失败 → nil） |
| `<Name>UsageClient.swift` | 调 API 或读本地文件，返回结构化数据 |
| `<Name>UsageModel.swift` | 解码 API 响应 / 日志，转为 `ProviderUsageSnapshot` |
| `<Name>Provider.swift` | `UsageProvider` 协议实现（见步骤 2） |
| `<Name>UsageCollector.swift` | 可选：本机日志扫描 → `UsageStatsService`（费用卡、热力图；Codex 有，Claude 也有） |

---

## 2. 实现 `UsageProvider`

最小实现模板（`<Name>Provider.swift`）：

```swift
import Foundation

@MainActor
final class <Name>Provider: UsageProvider {
    let id: ProviderID = .<name>
    let runtime = ProviderRuntime()
    var isConfigured: Bool { runtime.isConfigured }
    var onPollTick: (@MainActor () -> Void)? = nil
    // nextEligibleRefresh 默认 nil（不做 backoff），继承 UsageProvider extension

    // 历史样本（可选；要趋势箭头 / 折线图才需要）
    let history: UsageHistoryService

    init(history: UsageHistoryService? = nil) {
        self.history = history ?? UsageHistoryService(filename: "history-<name>.json")
        // 同步探测：凭证文件在不在 → 让 tab 一打开就显示正确状态
        let present = ((try? <Name>CredentialStore.load()) ?? nil) != nil
        runtime.setConfigured(present)
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let creds = try? <Name>CredentialStore.load() else {
                runtime.setConfigured(false)
                return
            }
            let snapshot = try await <Name>UsageClient.fetchSnapshot(credentials: creds)
            history.recordDataPoint(/* ... */)
            runtime.setSuccess(snapshot: snapshot)
            runtime.setConfigured(true)
        } catch {
            runtime.setError(error, clearSnapshot: false)
        }
    }

    private var isRefreshing = false
}
```

关键协议要求核查：

- [ ] `id` 返回正确的 `ProviderID` case
- [ ] `runtime` 是 `let`（`ProviderRuntime` 是 `@MainActor class`，外部 `@ObservedObject` 持有它）
- [ ] `refreshNow()` **永不抛**，异常走 `runtime.setError`
- [ ] 凭证不存在 / 读取失败 → `runtime.setConfigured(false)`（不弹错误）
- [ ] 401/403 → 提示用户重新登录该 CLI，**不写回 / 不刷新凭证文件**
- [ ] 有 `onPollTick` 需求时（驱动本机统计刷新）：在 `init` 后由 `UsageBarApp.task` 注入

---

## 3. 注册到 `ProviderCoordinator`

文件：`macos/Sources/UsageBar/App/UsageBarApp.swift`（或 `ClaudeUsageBarApp.swift`）

```swift
// 在 @StateObject / 实例化 coordinator 处：
private let <name> = <Name>Provider()
// ...
coordinator = ProviderCoordinator(
    claude: usageService,
    additionalProviders: [codex, <name>]  // append 在现有列表末尾
)
```

如果该 provider 有独立统计服务（类似 `codexStats`）：

```swift
@StateObject private var <name>Stats = UsageStatsService(provider: .<name>)
// 在 .task 里注入 onPollTick：
coordinator.<name>.onPollTick = { Task.detached { await <name>Stats.refresh() } }
```

---

## 4. 菜单栏 glyph

文件：`macos/Sources/UsageBar/MenuBar/MenuBarIconRenderer.swift`

**选项 A：已有品牌图片资源**（推荐路径，但 logo 需 PNG template-mode，512×512 或更大）：

1. 将图片加入 `macos/Sources/UsageBar/Resources/Assets.xcassets/`（Image Set，Template rendering）  
2. 在 `drawProviderGlyph(for:x:y:size:)` 里加：
   ```swift
   if id == .<name>, let logo = <name>LogoImage {
       logo.draw(in: NSRect(x: x, y: y, width: size, height: size))
       return
   }
   ```
3. 在 renderer 的 `private lazy var <name>LogoImage` 里用 `NSImage(named:)` 加载

**选项 B：SF Symbol**（零图片资源，推荐作暂行方案）：

在 `sfSymbolName(for:)` switch 里已有 `.cursor` / `.copilot` / `.gemini` 的映射，直接填：

```swift
case .<name>: return "<sf-symbol-name>"  // 在 macOS 14 SF Symbols 5 里找合适的
```

**选项 C：代码绘制**（参考 `drawCodeBracketsGlyph`）：只在 SF Symbol 找不到合适图标时用。

---

## 5. 本机统计（可选，费用卡 + 热力图）

若该 provider 有本地日志（如 Codex 的 `~/.codex/sessions/*.jsonl`）：

1. 创建 `<Name>CostParser.swift`（解析单条 JSONL → `StoredUsageEvent`，**绝对不打印对话内容**）
2. 创建 `<Name>UsageCollector.swift`（`actor`，conform `UsageCollecting`，扫 sessions 目录，增量 cursor）
3. 在 `UsageStatsService.init(provider:)` 的 switch 里加 `case .<name>:` 分支，传入对应 collector + pricing table
4. 在 `UsageBarApp` 里加 `@StateObject var <name>Stats = UsageStatsService(provider: .<name>)`

---

## 6. 验证命令

**每步改完都要跑，不允许跳过**：

```bash
# 在 macos/ 目录下
cd macos && swift build -c release
cd macos && swift test

# 若改动了 build.sh / verify-release.sh / 新增 bundle 资源
make release-artifacts
bash macos/scripts/verify-release.sh macos/UsageBar.zip
```

成功条件：

- [ ] `swift build -c release` 零错误零警告（新文件）
- [ ] `swift test` 全绿，无回归
- [ ] 新 provider 对应的单测（至少：`isConfigured` 初始值 / `refreshNow` 成功路径 / 凭证不存在路径）
- [ ] 菜单栏 glyph 手动目视确认（`make app` 后打开 app）

---

## 7. PR checklist

- [ ] 分支名：`feat/<version>-<name>-provider`
- [ ] 受保护文件未改动（`verify-release.sh` / `AGENTS.md` / `docs/adr/` / `Package.swift` 依赖 pin）
- [ ] 凭证写入链路未改动（`UsageService.swift` / `StoredCredentials.swift`）
- [ ] `ProviderID.allCases` 顺序：新 case 加在现有末尾（Settings 排序依赖初始顺序）
- [ ] 独立 code review 通过（`/review` + `/security-review`，subagent 独立判断）

---

## Runs log

| 日期 | Provider | 版本 | 结果 | evidence / PR |
|---|---|---|---|---|
| — | — | — | — | — |
