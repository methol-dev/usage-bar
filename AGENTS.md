# AGENTS.md — AI 治理入口

> 任意 AI runner（Claude Code / Codex / Cursor / Cline / …）进入本仓库的**第一份**要读的文件。
> **详细规则按领域拆分在 [`.agent/rules/`](./.agent/rules/) 下**，见文末 [Rules Index](#rules-index)。
> Claude Code 专属补充见 [`CLAUDE.md`](./CLAUDE.md)。

## Global Rules（全局硬规则）

1. **禁止 AI 自审自批** — plan review 与 code review 必须由独立 reviewer（subagent / 跨模型 / 人类）完成。
2. **首选工具不可用时走等价 fallback（如 general-purpose subagent），不要停下问用户**（除非所有路径都失败）。
3. **commit message 中文**，含变更主题 + 相关 issue / ADR 引用。
4. **代码 commit 前 `swift build` + `swift test` 必须绿**；纯文档 commit 需 markdown 链接核对 + frontmatter 核对。
5. **文档不写 emoji**（除非用户明确要求）；日期 `YYYY-MM-DD`；中文优先，术语 / 命令 / 模型 ID 保留英文。
6. **不手改 `Info.plist` 版本号**（build 时由 `APP_VERSION` / git tag 注入）；**不硬写 Sparkle feed URL**。
7. **ADR 与治理文件（本文件、`.agent/rules/`）的实质修改需用户明确要求**；ADR 编号严格递增、不复用。

## 项目概览

- **形态**：macOS 14+ 菜单栏 app（SwiftUI + Swift Charts + Sparkle），展示 Claude / Codex / Gemini API 用量
- **技术栈**：Swift 5.9+ / SwiftPM；自定义 bundle 组装（非 stock SwiftPM）；Sparkle 是唯一运行时依赖
- **Remote**：`github.com/methol-dev/usage-bar`；fork 自 Blimp-Labs 截止 `v0.0.6`，自 `v0.0.7` 起独立编号（[ADR 0004](./docs/adr/0004-fork-divergence-from-blimp-labs.md)）
- **架构原则**：
  - Swift 原生、不引入 Electron/Tauri（[ADR 0001](./docs/adr/0001-swift-native-only.md)）
  - 多 provider，抽象须为新 provider 留低成本扩展位（[ADR 0005](./docs/adr/0005-reopen-multi-provider-direction.md)）
  - AI 主导，人类辅助（[ADR 0003](./docs/adr/0003-ai-led-development.md)）；工作流现行形态见 [ADR 0008](./docs/adr/0008-retire-spec-governance.md)

## 代码结构

```
macos/Sources/UsageBar/
├── App/             # 入口、app delegate、Sparkle updater 包装
├── Models/          # 数据类型：credentials、accounts、usage snapshots
├── Services/        # UsageHistoryService、NotificationService、ProviderCoordinator
├── Providers/       # Core（UsageProvider protocol）+ Claude / Codex / Gemini
├── Pricing/         # LiteLLM 快照加载 + per-provider normalize
├── LocalCost/       # JSONL parser、aggregator、scan cursor store
├── MenuBar/         # 菜单栏 label + icon 渲染
├── Features/        # Popover（主 UI）+ Settings
├── Utilities/       # Pace / Trend 计算、formatters
└── Resources/       # Info.plist、Assets、litellm_model_prices.json
```

`docs/` 下只有两类：[`adr/`](./docs/adr/README.md)（架构决策记录，append-only）与
`runbooks/`（[release](./docs/runbooks/release.md) / [add-new-provider](./docs/runbooks/add-new-provider.md)）。
用户视角变更记录看 [`CHANGELOG.md`](./CHANGELOG.md)。

## 任务路径

| 我要做什么 | 看这里 |
|---|---|
| 接 GitHub issue / 修 bug / 小功能 | [`.agent/rules/workflows/issue-driven.md`](./.agent/rules/workflows/issue-driven.md) + `scripts/issues/kickoff.sh` |
| 做新功能（跨多文件 / 有架构影响） | 下方「开发工作流」（plan mode 起步） |
| 日常 build / test / 打包 | [`.agent/rules/build-test.md`](./.agent/rules/build-test.md) |
| 发版 | [`docs/runbooks/release.md`](./docs/runbooks/release.md) |
| 接新 provider | [`docs/runbooks/add-new-provider.md`](./docs/runbooks/add-new-provider.md) |
| 改架构 / 写 ADR | [`docs/adr/_TEMPLATE.md`](./docs/adr/_TEMPLATE.md) + 下方 Hard Gates |
| 写文档 | [`.agent/rules/docs.md`](./.agent/rules/docs.md) |
| 不在上表 | 兜底：先 plan mode 出计划、review 通过再动手 |

**第一次进项目**：读完本文件，按 Rules Index 按需读规则；看 [`CHANGELOG.md`](./CHANGELOG.md) 与 `git log` 了解最近变更。

## 开发工作流

小任务（bug / 小功能 / 文档微调）走 issue 驱动工作流；功能开发主回路（[ADR 0008](./docs/adr/0008-retire-spec-governance.md)）：

```
1. Plan          进 plan mode，探索代码库后产出实施计划（步骤 + 验收标准）
2. Plan review   独立 reviewer（subagent / 人类）审计划；通过后才动代码
3. 实施 + 测试    编码；每个 commit 保持 swift build + swift test 绿
4. 代码检查       /review（正确性 / 质量）+ /security-review（凭证 / 权限）
5. 精简          /simplify 清理冗余代码
6. PR            创建 PR；CI 绿后 squash merge
7. 发版          docs/runbooks/release.md（CHANGELOG + tag + 24h health check）
```

- 设计讨论与计划不落盘入库；决策沉淀走 ADR，版本记录只有 `CHANGELOG.md`。
- 架构级选择（新依赖、方向调整、破坏性变更）先写 ADR 再实施。

## Hard Gates — 必须停下问人类的 6 种情形

[ADR 0003](./docs/adr/0003-ai-led-development.md) 的默认是 *"完全自治"*。以下情形**必须**升级人类：

1. **凭证 / 密钥操作**：Apple Developer 账号、公证证书、Sparkle 私钥导出 / 重置、GitHub PAT 重置
2. **引入新第三方依赖** / 修改 LICENSE / 改变商业模式（开源 / 收费）
3. **同一 review ≥ 2 轮分歧** 且 reviewer 给两个等价但语义不同的方案、无明显推荐项
4. **发版后 24h 内 health check 报警**（Sparkle appcast 异常、用户反馈核心崩溃）
5. **新决策与既有 ADR 冲突** 但作者认为旧 ADR 应被 supersede
6. **触发法律 / 合规风险信号**（用户隐私、第三方 API ToS、商标）

升级方式：用 `AskUserQuestion` 或等价交互工具，**给 2~3 个具体选项 + 推荐项**，而非开放式提问。

## Rules Index

详细规则都在 [`.agent/rules/`](./.agent/rules/)：

| File | Scope | Description |
|------|-------|-------------|
| [swift.md](./.agent/rules/swift.md) | `**/*.swift` | 架构红线（UsageService 单源、bundle 组装、Sparkle gate、发版 tag 驱动）+ 代码风格 |
| [build-test.md](./.agent/rules/build-test.md) | 全局（alwaysApply） | 构建 / 测试 / 打包命令、本地验证矩阵、完成硬证据 |
| [docs.md](./.agent/rules/docs.md) | `docs/**/*.md`, `*.md` | 写作风格、frontmatter 速查（ADR / version）、命名规范、CHANGELOG 规则 |
| [mock-server.md](./.agent/rules/mock-server.md) | Manual | Mock server 四条路由、指向 / 还原要求、凭证前提 |
| [workflows/issue-driven.md](./.agent/rules/workflows/issue-driven.md) | Manual | Issue 驱动生命周期 + 标签 / 需人介入清单等项目配置 |
