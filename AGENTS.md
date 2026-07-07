# AGENTS.md — AI 治理入口

> 任意 AI runner（Claude Code / Codex / Cursor / Cline / …）进入本仓库的**第一份**要读的文件。
> 中立 runner，不依赖任何特定厂商的 idiom。Claude Code 专属补充见 [`CLAUDE.md`](./CLAUDE.md)。

---

## L0 — 30 秒指引

**项目**：macOS 14+ 菜单栏 app（SwiftUI + Swift Charts + Sparkle），展示 Claude / Codex API 用量。AI-led（[ADR 0003](./docs/adr/0003-ai-led-development.md)）。

**拿到任务先查路径**（完整反向索引见 [`docs/agents/quickstart.md`](./docs/agents/quickstart.md)）：

| 我要做什么 | 看这里 |
|---|---|
| 接 GitHub issue / 修 bug / 小功能 | [`docs/workflow/issue-driven.md`](./docs/workflow/issue-driven.md) + `scripts/issues/kickoff.sh` |
| 做新功能（跨多文件，需 spec） | 本文件 §3 主回路 → brainstorming → spec → plan |
| 发版 | [`docs/runbooks/release.md`](./docs/runbooks/release.md) |
| 改 / 写 ADR | [`docs/adr/_TEMPLATE.md`](./docs/adr/_TEMPLATE.md) + 本文件 §5 hard gates |
| 日常 swift / make 命令 | [`docs/agents/operations.md`](./docs/agents/operations.md) |
| frontmatter / 命名规范 | [`docs/agents/conventions.md`](./docs/agents/conventions.md) |

**第一次进项目，5 分钟流程**：读完本文件 → 看 [`docs/agents/quickstart.md`](./docs/agents/quickstart.md) → 看 [`docs/versions/README.md`](./docs/versions/README.md) 知道当前在做什么版本。

---

## L1 — 必读骨架

### 1. 项目快照

- **形态**：macOS 14+ 菜单栏 app
- **当前 tag**：fork 自 Blimp-Labs 截止 `v0.0.6`；本仓库自 `v0.0.7` 起独立编号（[ADR 0004](./docs/adr/0004-fork-divergence-from-blimp-labs.md)）
- **Remote**：`github.com/methol-dev/usage-bar`
- **架构原则**：
  - Swift 原生、不引入 Electron/Tauri（[ADR 0001](./docs/adr/0001-swift-native-only.md)）
  - 多 provider（[ADR 0005](./docs/adr/0005-reopen-multi-provider-direction.md)，supersede 0002）
  - AI 主导，人类辅助（[ADR 0003](./docs/adr/0003-ai-led-development.md)）

### 2. 文档地图

```
docs/
├─ agents/             AI 操作工作台（quickstart / operations / conventions）  ★ AI 必看
├─ research/           长期事实性调研（业界 / 竞品 / 外部 API）
├─ superpowers/specs/  单次设计 spec（brainstorming 产出）
├─ superpowers/plans/  实施 plan（writing-plans 产出）
├─ adr/                架构决策记录（append-only，不可变）
├─ versions/           版本路线 + 验收 + release notes 草稿
├─ runbooks/           AI 可执行的标准操作流程
├─ workflow/           轻量协作流程（issue-driven）
├─ artifacts/issues/   issue 驱动产物（自动维护）
└─ user-guide/         面向用户中文文档（v1.0 前主要占位）

根目录：
├─ AGENTS.md           本文件（治理入口）
├─ CLAUDE.md           Claude Code 专用提示（Mock server / Sparkle 等坑）
├─ CHANGELOG.md        用户视角变更记录（AI 在发版 runbook 自动维护）
├─ README.md           面向用户与 contributor 的产品介绍
└─ CONTRIBUTING.md     人类 contributor 指南（项目实际 AI-led）
```

完整治理框架见母法 spec：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)。

### 3. 工作流主回路

```
research/  ─G1─►  spec/ADR  ─G2─►  plan  ─G3─►  implementation
                                                       │
                                                       ▼
                                                     ─G4 (per commit)
                                                       │
                                                       ▼
                                                     PR  ─G5─►  merge  ─G6─►
                                                                           │
                                                                           ▼
                                                                   versions/vX.md
                                                                           │
                                                                           ▼
                                                                release runbook ─G7─► tag
```

### 4. 7 个 Review Gate

每个产出在前进前必须通过 gate。Gate 由独立 reviewer（跨模型 / 跨 session / 自动化）通过，**禁止 AI 自审自批**。

| Gate | 触发 | 通过条件 |
|---|---|---|
| **G1** | 调研报告写完 | reviewer 无 "contradicted-by-evidence" 标记 |
| **G2** | spec / ADR 写完，或 ADR 状态变更 | verdict ∈ {approved, approved-after-revisions} |
| **G3** | plan（实施计划）写完 | plan 每步可独立验证、有 success criteria |
| **G4** | 每个 commit-able 工作单元（含纯文档 commit） | 代码 commit：`swift build` + `swift test` 绿；文档 commit：linkcheck + frontmatter lint ✅ |
| **G5** | PR 创建前 | reviewer verdict = approved |
| **G6** | merge 前 | CI 绿 + spec `## Verification log` 全勾完 |
| **G7** | 打 minor/major tag 前 | integration review + release runbook pre-flight 全绿 + 24h health 回访 |

详细 gate 定义见母法 spec §4.2~§4.5。

### 5. Hard gates — 必须停下问人类的 6 种情形

[ADR 0003](./docs/adr/0003-ai-led-development.md) 的默认是 *"完全自治"*。以下情形**必须**升级人类：

1. **凭证 / 密钥操作**：Apple Developer 账号、公证证书、Sparkle 私钥导出 / 重置、GitHub PAT 重置
2. **引入新第三方依赖** / 修改 LICENSE / 改变商业模式（开源 / 收费）
3. **同一 review gate ≥ 2 轮分歧** 且 reviewer 给两个等价但语义不同的方案、无明显推荐项
4. **G7 发版后 24h 内 health check 报警**（Sparkle appcast 异常、用户反馈核心崩溃）
5. **spec / ADR 内部出现违反既有 ADR** 但作者认为 ADR 应被 supersede
6. **触发法律 / 合规风险信号**（用户隐私、第三方 API ToS、商标）

升级方式：用 `AskUserQuestion` 或等价交互工具，**给 2~3 个具体选项 + 推荐项**，而非开放式提问。

---

## L2 — 扩展引用

### 工具 preflight（不同 runner 的等价物）

完整 fallback 表见 [`docs/agents/operations.md`](./docs/agents/operations.md) §3。一句话：**走 fallback，不要停下问用户**（Claude Code runner 已记 memory；其他 runner 按表执行）。

### 写作约定

完整规范见 [`docs/agents/conventions.md`](./docs/agents/conventions.md)。摘要：

- 日期 `YYYY-MM-DD`，中文优先，不用 emoji（除非用户明确要求）
- spec / ADR / version 文档第一行必须是 `---`
- commit message：中文 + 含 spec id 引用
- frontmatter schema：[`conventions.md`](./docs/agents/conventions.md) §2；权威 schema 见母法 spec §3.3

### CHANGELOG 维护

由 AI 在发版 runbook（[`docs/runbooks/release.md`](./docs/runbooks/release.md) §5）自动生成。规则与翻译模板见 [`docs/agents/operations.md`](./docs/agents/operations.md) §5。

### 引用

- 母法 spec：[`docs/superpowers/specs/2026-05-11-docs-governance.md`](./docs/superpowers/specs/2026-05-11-docs-governance.md)
- ADR 索引：[`docs/adr/README.md`](./docs/adr/README.md)
- 当前版本路线：[`docs/versions/README.md`](./docs/versions/README.md)
- 当前 spec 列表：[`docs/superpowers/specs/README.md`](./docs/superpowers/specs/README.md)
- 调研基线：[`docs/research/competitive-analysis.md`](./docs/research/competitive-analysis.md)
- Claude Code 专用：[`CLAUDE.md`](./CLAUDE.md)
- 三大模板：[spec](./docs/superpowers/specs/_TEMPLATE.md) / [ADR](./docs/adr/_TEMPLATE.md) / [version](./docs/versions/_TEMPLATE.md)
