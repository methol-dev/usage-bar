# AGENTS.md — AI 治理入口

> 任意 AI runner（Claude Code / Codex / Cursor / Cline / …）进入本仓库的**第一份**要读的文件。
> **详细规则按领域拆分在 [`.agent/rules/`](./.agent/rules/) 下**，见文末 [Rules Index](#rules-index)。
> Claude Code 专属补充见 [`CLAUDE.md`](./CLAUDE.md)。

## Global Rules（全局硬规则）

1. **禁止 AI 自审自批 review gate** — 每个 gate 由独立 reviewer（跨模型 / 跨 session / 自动化）通过。
2. **工具不可用时走 fallback，不要停下问用户**（除非所有路径都失败）— fallback 表见 [`.agent/rules/tooling.md`](./.agent/rules/tooling.md)。
3. **commit message 中文**，含变更主题 + 相关 spec id / issue 号引用。
4. **代码 commit 前 `swift build` + `swift test` 必须绿**；纯文档 commit 需 linkcheck + frontmatter lint（G4）。
5. **文档不写 emoji**（除非用户明确要求）；日期 `YYYY-MM-DD`；中文优先，术语 / 命令 / 模型 ID 保留英文。
6. **不手改 `Info.plist` 版本号**（build 时由 `APP_VERSION` / git tag 注入）；**不硬写 Sparkle feed URL**。
7. **ADR append-only 不可变**；spec / 母法修改需 issue 或用户明确要求。

## 项目概览

- **形态**：macOS 14+ 菜单栏 app（SwiftUI + Swift Charts + Sparkle），展示 Claude / Codex / Gemini API 用量
- **技术栈**：Swift 5.9+ / SwiftPM；自定义 bundle 组装（非 stock SwiftPM）；Sparkle 是唯一运行时依赖
- **Remote**：`github.com/methol-dev/usage-bar`；fork 自 Blimp-Labs 截止 `v0.0.6`，自 `v0.0.7` 起独立编号（[ADR 0004](./docs/adr/0004-fork-divergence-from-blimp-labs.md)）
- **架构原则**：
  - Swift 原生、不引入 Electron/Tauri（[ADR 0001](./docs/adr/0001-swift-native-only.md)）
  - 多 provider，抽象须为新 provider 留低成本扩展位（[ADR 0005](./docs/adr/0005-reopen-multi-provider-direction.md)）
  - AI 主导，人类辅助（[ADR 0003](./docs/adr/0003-ai-led-development.md)）

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

文档地图见 [`docs/README.md`](./docs/README.md)：`adr/`（决策）、`superpowers/specs|plans/`（设计产出）、
`versions/`（版本路线）、`runbooks/`（可执行流程）、`research/`（调研）、`artifacts/issues/`（issue 产物）。

## 任务路径

| 我要做什么 | 看这里 |
|---|---|
| 接 GitHub issue / 修 bug / 小功能 | [`.agent/rules/workflows/issue-driven.md`](./.agent/rules/workflows/issue-driven.md) + `scripts/issues/kickoff.sh` |
| 做新功能（跨多文件，需 spec） | 下方工作流主回路 → brainstorming → spec → plan |
| 日常 build / test / 打包 | [`.agent/rules/build-test.md`](./.agent/rules/build-test.md) |
| 发版 | [`docs/runbooks/release.md`](./docs/runbooks/release.md) |
| 接新 provider | [`docs/runbooks/add-new-provider.md`](./docs/runbooks/add-new-provider.md) |
| 改 / 写 ADR | [`docs/adr/_TEMPLATE.md`](./docs/adr/_TEMPLATE.md) + 下方 Hard Gates |
| 写 spec / version / 文档 | [`.agent/rules/docs.md`](./.agent/rules/docs.md) + 三大模板（[spec](./docs/superpowers/specs/_TEMPLATE.md) / [ADR](./docs/adr/_TEMPLATE.md) / [version](./docs/versions/_TEMPLATE.md)） |
| 调研 | [`docs/research/README.md`](./docs/research/README.md) |
| 不在上表 | 兜底：brainstorming → spec → plan；跨多文件 / 有架构影响的任务不能跳过 spec |

**第一次进项目**：读完本文件 → [`docs/README.md`](./docs/README.md) → [`docs/versions/README.md`](./docs/versions/README.md) 知道当前在做什么版本。

## 工作流主回路与 7 个 Review Gate

```
research/ ─G1─► spec/ADR ─G2─► plan ─G3─► implementation ─G4(per commit)─► PR ─G5─► merge ─G6─► versions/vX.md ─► release runbook ─G7─► tag
```

| Gate | 触发 | 通过条件 |
|---|---|---|
| **G1** | 调研报告写完 | reviewer 无 "contradicted-by-evidence" 标记 |
| **G2** | spec / ADR 写完，或 ADR 状态变更 | verdict ∈ {approved, approved-after-revisions} |
| **G3** | plan（实施计划）写完 | plan 每步可独立验证、有 success criteria |
| **G4** | 每个 commit-able 工作单元（含纯文档 commit） | 代码 commit：`swift build` + `swift test` 绿；文档 commit：linkcheck + frontmatter lint ✅ |
| **G5** | PR 创建前 | reviewer verdict = approved |
| **G6** | merge 前 | CI 绿 + spec `## Verification log` 全勾完 |
| **G7** | 打 minor/major tag 前 | integration review + release runbook pre-flight 全绿 + 24h health 回访 |

各 gate 用什么 reviewer 工具见 [`.agent/rules/tooling.md`](./.agent/rules/tooling.md)；详细 gate 定义见
[母法 spec](./docs/superpowers/specs/2026-05-11-docs-governance.md) §4.2~§4.5。

## Hard Gates — 必须停下问人类的 6 种情形

[ADR 0003](./docs/adr/0003-ai-led-development.md) 的默认是 *"完全自治"*。以下情形**必须**升级人类：

1. **凭证 / 密钥操作**：Apple Developer 账号、公证证书、Sparkle 私钥导出 / 重置、GitHub PAT 重置
2. **引入新第三方依赖** / 修改 LICENSE / 改变商业模式（开源 / 收费）
3. **同一 review gate ≥ 2 轮分歧** 且 reviewer 给两个等价但语义不同的方案、无明显推荐项
4. **G7 发版后 24h 内 health check 报警**（Sparkle appcast 异常、用户反馈核心崩溃）
5. **spec / ADR 内部出现违反既有 ADR** 但作者认为 ADR 应被 supersede
6. **触发法律 / 合规风险信号**（用户隐私、第三方 API ToS、商标）

升级方式：用 `AskUserQuestion` 或等价交互工具，**给 2~3 个具体选项 + 推荐项**，而非开放式提问。

## Rules Index

详细规则都在 [`.agent/rules/`](./.agent/rules/)：

| File | Scope | Description |
|------|-------|-------------|
| [swift.md](./.agent/rules/swift.md) | `**/*.swift` | 架构红线（UsageService 单源、bundle 组装、Sparkle gate、发版 tag 驱动）+ 代码风格 |
| [build-test.md](./.agent/rules/build-test.md) | 全局（alwaysApply） | 构建 / 测试 / 打包命令、本地验证矩阵、G4 硬证据 |
| [docs.md](./.agent/rules/docs.md) | `docs/**/*.md`, `*.md` | 写作风格、frontmatter 速查、命名规范、CHANGELOG 规则 |
| [tooling.md](./.agent/rules/tooling.md) | Manual | 跨 runner 工具 preflight 详表与 fallback |
| [mock-server.md](./.agent/rules/mock-server.md) | Manual | Mock server 四条路由、指向 / 还原要求、凭证前提 |
| [workflows/issue-driven.md](./.agent/rules/workflows/issue-driven.md) | Manual | Issue 驱动完整生命周期 + 标签 / 守护线 / 受保护文件等项目配置 |

## 引用

- 治理母法 spec：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)（§3.1 目录树为历史快照，现状以 [ADR 0007](./docs/adr/0007-agent-rules-restructure.md) 为准）
- ADR 索引：[`docs/adr/README.md`](./docs/adr/README.md) ・ 版本路线：[`docs/versions/README.md`](./docs/versions/README.md) ・ spec 列表：[`docs/superpowers/specs/README.md`](./docs/superpowers/specs/README.md)
