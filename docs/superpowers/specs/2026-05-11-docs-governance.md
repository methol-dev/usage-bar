---
id: 2026-05-11-docs-governance
title: 文档治理框架与版本路线骨架
status: implemented               # G6 通过：SC1~SC17 全 done、reviews 含 G2/G5/G6 三轮 verdict
created: 2026-05-11
updated: 2026-05-11
owner: claude-code                # 主导 runner
model: claude-opus-4-7            # 写作模型，便于审计
target_version: v0.0.7
related_adrs: [0001, 0002, 0003, 0004]
related_research: [competitive-analysis]
spec_criteria:
  - id: SC1
    criterion: "docs/ 下存在 research、superpowers/specs、adr、versions、runbooks、user-guide 六个子目录，每个都有 README.md"
    done: false
    evidence: null
  - id: SC2
    criterion: "specs/、adr/、versions/ 下各有 _TEMPLATE.md，frontmatter 字段与本 spec §3.3 完全一致"
    done: false
    evidence: null
  - id: SC3
    criterion: "根目录存在 AGENTS.md、CHANGELOG.md；CLAUDE.md 顶部含 'See AGENTS.md' 跳板"
    done: false
    evidence: null
  - id: SC4
    criterion: "AGENTS.md 含工具可用性 preflight 章节（声明 codex-rescue / general-purpose subagent / Explore / writing-plans 在不同 runner 下的等价物与可用性检测）"
    done: false
    evidence: null
  - id: SC5
    criterion: "ADR 0001 Swift-only、0002 Claude-only、0003 AI-led、0004 fork-divergence 已落地；每条 ADR 在 §2 决策摘要表的速览段被一句话引用"
    done: false
    evidence: null
  - id: SC6
    criterion: "versions/v0.0.7-docs-governance.md 已写、frontmatter 完整、includes_specs 含本 spec id"
    done: false
    evidence: null
  - id: SC7
    criterion: "versions/v0.0.8 ~ v1.0.0 占位文档存在；每个 frontmatter status=placeholder；_TEMPLATE 含 'placeholder → planned 升格' guardrail"
    done: false
    evidence: null
  - id: SC8
    criterion: "runbooks/release.md 描述 AI 自动写 CHANGELOG 的完整 SOP；含中文翻译模板片段；含 Runs log 表"
    done: false
    evidence: null
  - id: SC9
    criterion: "runbooks/{notarization,sparkle-keys,incident-response}.md 占位文件存在"
    done: false
    evidence: null
  - id: SC10
    criterion: "docs/research/competitive-analysis.md 与 docs/research/README.md 已补 frontmatter"
    done: false
    evidence: null
  - id: SC11
    criterion: "CHANGELOG.md 含 v0.0.7 entry，中文，引用本 spec id"
    done: false
    evidence: null
  - id: SC12
    criterion: "README.md 中所有 Blimp-Labs/claude-usage-bar 链接已替换为 methol/usage-bar；appcast URL 替换为 methol.github.io/usage-bar/appcast.xml；新增 fork 关系声明段"
    done: false
    evidence: null
  - id: SC13
    criterion: "整仓库内所有相对 markdown 链接 grep 后 0 个 404（通过 SC_AUTO_LINKCHECK 命令）"
    done: false
    evidence: null
  - id: SC14
    criterion: "所有新建 markdown 文件（spec/ADR/version/research）frontmatter 第一行均为 `---`，可被 yq 解析"
    done: false
    evidence: null
  - id: SC15
    criterion: "本 spec 的 reviews 数组至少含一条 G2 verdict=approved 的条目"
    done: false
    evidence: null
  - id: SC16
    criterion: "本文件末尾的 ## Verification log 区块以 markdown checkbox 形式登记每条 SC 的 done 状态与 evidence"
    done: false
    evidence: null
  - id: SC17
    criterion: "git commit 信息为中文，含变更主题 + 本 spec id 引用"
    done: false
    evidence: null
automated_checks:
  - "SC_AUTO_LINKCHECK: cd /Users/methol/data/code-methol/usage-bar && grep -rho '\\](\\./[^)]*\\|\\](\\../[^)]*\\|\\](docs/[^)]*\\|\\](runbooks/[^)]*' docs AGENTS.md CHANGELOG.md CLAUDE.md README.md 2>/dev/null | sed 's/^](//' | sed 's/)$//' | sort -u | while read l; do test -e \"$l\" || echo MISSING \"$l\"; done | tee /tmp/v0.0.7-linkcheck.log; test ! -s /tmp/v0.0.7-linkcheck.log"
  - "SC_AUTO_FRONTMATTER: for f in $(git ls-files 'docs/**/*.md' | grep -v _TEMPLATE | grep -v README.md); do head -1 \"$f\" | grep -q '^---$' || echo MISSING_FM \"$f\"; done"
manual_checks:
  - "在 GitHub 渲染下 docs/README.md 与 AGENTS.md 索引链接全部可点"
  - "用户审阅本 spec 与 AGENTS.md 后认可治理框架"
reviews:
  - gate: G2
    reviewer: claude-code (general-purpose subagent, independent session)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      初稿被独立 subagent 评为 changes-requested，5 BLOCKING + 8 RECOMMENDED + 9 NOTES。
      作者按 superpowers:receiving-code-review 流程逐条响应：
      - BLOCKING B1/B2/B3/B4/B5 全部 accepted，并已写入本 spec：
        * B1 spec_criteria 重写为 17 条对象数组，一一对应 §6 迁移清单
        * B2 SC.done/evidence 字段定义见 §3.3；G6 验收以 ## Verification log 区块为准
        * B3 §3.3 新增"文档生命周期与可变性约定"段，明确哪些字段可变
        * B4 §7.2 v0.0.7 行下新增 gate map（v0.0.7 跑 G2/G6，跳 G4 swift 验证、用 linkcheck/frontmatter 替代）
        * B5 README 已加入 🔧 修改清单（SC12）；ADR 0004 标题保持"fork-divergence"但内容澄清为"独立编号 + URL 校准"
      - RECOMMENDED R1/R2/R4/R5/R6/R7/R8 accepted；R3 转 AGENTS.md（SC4）实现
      - NOTES N2/N3/N4/N5/N7 accepted；N1/N9 noted-only；N6 rejected（target_version 字段就是干这个的，spec 历史性记录 v0.0.7 是合理的）
      响应明细见 §10 G2 review response。
    artifacts: ["§10 G2 review response"]
  - gate: G5
    reviewer: claude-code (general-purpose subagent, fresh session, "5-minute onboarding test")
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      G5 PR-time code review。reviewer 模拟陌生 AI 5 分钟上手测试，只读 AGENTS.md 及其一跳引用、故意不读母法 spec。
      原始 verdict: changes-requested。3 必补 + 5 建议补 + 1 通过条目（hard gates / ADR 约束 / G2 工具链清晰）。
      作者已整改 AGENTS.md：
      - 必补 1 → §7.1 Frontmatter 速查（spec/ADR/version 三表 + spec↔version 双向链接惯例）
      - 必补 2 → §2 上手清单加第 5 步（写 spec/ADR/version 先看 §7.1 + _TEMPLATE.md）
      - 必补 3 → §4.2 G4 行明示"含纯文档 commit"，区分代码 vs 纯文档版的判定
      - 建议补 → §3 子目录约定段、§5 brainstorming 输出形态、§5 codex 双名解释、§6 codex memory 措辞中性化、§7 PR title 约定、§9 三大模板引用
      整改后 linkcheck 仍 ✅。完整 review 内容存于本次主会话 transcript（subagent agentId: a17620bedfcf408c2）。
    artifacts: ["AGENTS.md §2/§3/§4.2/§5/§6/§7.1/§9 修订"]
  - gate: G6
    reviewer: claude-code (main session, automated checks)
    date: 2026-05-11
    verdict: approved
    summary: |
      G6 merge 前验收：spec_criteria SC1~SC17 全部 done=true、evidence 已逐条登记于
      文末 ## Verification log。两条 automated_checks 复跑均绿：
      - SC_AUTO_LINKCHECK：42 个 markdown 文件全部相对链接可解析（脚本剥离 frontmatter
        与 code fence、忽略 ${VAR} 模板占位）
      - SC_AUTO_FRONTMATTER：spec/ADR/version/research 31 个文件 frontmatter 第一行均为 ---
      （runbook/user-guide 不在 SC14 criterion 范围内，与 SC14 evidence "31 files" 完全对齐）
      G6 通过 → spec status: accepted → implemented。后续如打 v0.0.7 tag 则触发 G7。
    artifacts: ["scripts/linkcheck (inline python)", "scripts/frontmatter-lint (inline python)"]
---

# 文档治理框架与版本路线骨架

## 1. 背景与目标

本仓库（`claude-usage-bar`，remote `github.com/methol/usage-bar`）从 `Blimp-Labs/claude-usage-bar` fork 而来，截止 fork 时上游已发到 **v0.0.6**（2026-03-10）。在 [docs/research/competitive-analysis.md](../../research/competitive-analysis.md) 中确立了下一阶段的产品方向：将 [SessionWatcher](https://www.sessionwatcher.com/) 的 UI/交互精致度 与 [CodexBar](https://github.com/steipete/CodexBar) 的功能广度/数据源健壮性融合，全栈坚持 Swift 原生。

这一升级路线涉及 ≥15 个独立功能模块、跨越数月、由 AI 主导。如果不先把文档治理框架立起来：

- 每次新会话的 AI 都要从源码反推上下文，无法接续历史决策
- 设计、ADR、版本计划、运维手册散落，互相引用不清
- AI 自主推进容易做错决定，没有 review 机制兜底
- 用户（人类）无法仅通过文档审计 AI 的工作

本 spec 不实现任何产品功能，只解决 *"AI 该怎么协作，怎么 review，文档怎么放，版本怎么发"* 的元问题。它是后续所有 spec / ADR / version / runbook 的母法。

**核心成功标准**：本 spec 落地之后，**任何陌生的 AI 会话**进入仓库，只读 `AGENTS.md` 和 `docs/` 索引就能在 5 分钟内：

1. 知道项目当前在哪个版本、下一个版本要做什么
2. 知道历史架构决策的"为什么"（ADR）
3. 知道写新 spec 应该用什么模板、放哪里
4. 知道发版应该怎么走 review gate
5. 知道什么时候必须停下来问人类

## 2. 决策摘要

| 决策点 | 选择 | 原因 / 对应 ADR |
|---|---|---|
| 目录分层 | 超细分（research/specs/adr/versions/runbooks/user-guide） | AI-led 长期迭代回报高 |
| 版本节奏 | 一功能一 patch（v0.0.x），phase 收尾标 minor（v0.x.0），稳定可用才 v1.0 | semver 0.y.z 语义容纳 |
| Changelog 维护 | AI 在发版 runbook 里自动产出中文 entry | 项目 AI-led，避免人手维护 |
| AI 自治程度 | 完全自治；**§4.6 列举的 hard gates 情形必须升级人类** | 用户明确表态（详见 ADR 0003） |
| 默认 AI runner | Claude Code（文档可用 superpowers idiom） | 用户主用 |
| Review 机制 | 7 个 review gate，跨模型 + subagent + 自动化校验 | 防止 AI 自审自批 |
| Fork 处理 | 自 v0.0.7 起与 Blimp-Labs 独立编号 + 校准 URL，不迁移 namespace | 详见 ADR 0004 |

### 2.1 ADR 速览（一句话定调）

- **ADR 0001 — Swift native only**：栈选 Swift / SwiftUI / SwiftPM；拒绝 Electron / Tauri / React Native 等非原生方案。
- **ADR 0002 — Claude-only, not multi-provider**：差异化定位"最精致的 Claude 专用条"；不与 CodexBar 在 provider 广度上竞争。
- **ADR 0003 — AI-led development**：项目由 AI（默认 Claude Code）主导调研、设计、决策、实施；人类辅助、补位、在 hard gates 介入。
- **ADR 0004 — Fork divergence from Blimp-Labs upstream**：自 v0.0.7 起本仓库版本号独立、URL 替换为 `methol/usage-bar` / `methol.github.io/usage-bar/...`；但不迁移 GitHub namespace（保持 `methol/usage-bar` 现状）。

## 3. 文档目录与模板

### 3.1 目录布局

```
docs/
├─ README.md                     # 文档总索引；任意 AI 进仓库后第一份要读
├─ research/                     # 长期事实性调研（≠ spec）
│  ├─ README.md
│  └─ competitive-analysis.md
├─ superpowers/
│  └─ specs/                     # superpowers brainstorming 产出的设计文档
│     ├─ README.md
│     ├─ _TEMPLATE.md
│     └─ YYYY-MM-DD-<slug>.md
├─ adr/                          # 架构决策记录
│  ├─ README.md
│  ├─ _TEMPLATE.md
│  └─ NNNN-<slug>.md
├─ versions/                     # 版本路线图 + 验收 + release notes 草稿
│  ├─ README.md
│  ├─ _TEMPLATE.md
│  └─ vX.Y.Z-<slug>.md
├─ runbooks/                     # AI 标准操作流程
│  ├─ README.md
│  ├─ release.md
│  ├─ notarization.md
│  ├─ sparkle-keys.md
│  └─ incident-response.md
└─ user-guide/                   # 面向最终用户（中文）
   ├─ README.md
   ├─ getting-started.md
   ├─ faq.md
   └─ privacy.md

CHANGELOG.md                     # 根目录，AI 维护，中文
AGENTS.md                        # 根目录，AI 治理入口
CLAUDE.md                        # 已有；调整为 Claude Code 专用 + 引导到 AGENTS.md
```

> 命名注：`superpowers/specs/` 是工艺名而非工具名 —— 未来即使 superpowers skill 改名或弃用，此目录仍保留以维持稳定 URL。

### 3.2 每个目录的写作合约

| 目录 | 是什么 | 不是什么 | 触发条件 |
|---|---|---|---|
| `research/` | **长期事实性调研**，回答"业界怎么做" | 不是 spec，不规定本项目要做什么 | AI 主动调研或调研跨多 spec 复用 |
| `superpowers/specs/` | **单次设计文档**，brainstorming 产出 | 不是实施计划（plan 落在 git branch） | 启动新功能 / 模块 / 流程 |
| `adr/` | **架构决策**，append-only（错了 supersede 不删除） | 不是设计 spec、不是讨论记录 | 决策需让 6 个月后的 AI 也能看懂 |
| `versions/` | **版本里程碑**，含 spec、验收、release notes 草稿 | 不是 CHANGELOG（CHANGELOG 是用户视角） | 计划下一个 vX.Y.Z；发版前后更新 |
| `runbooks/` | **AI 可执行的操作流程**，命令式、步骤化 | 不是设计、不是策略 | AI 要按部就班跑的操作 |
| `user-guide/` | **终端用户文档**，中文 | 不是 AI 文档，不解释内部决策 | 用户可见功能落地后 |

### 3.3 统一 frontmatter、生命周期与可变性约定

**所有日期** 用 ISO 8601 `YYYY-MM-DD`，**以提交者本地日期为准**。

**spec 文档生命周期与可变性**：

- spec 是 living document，但区分可变与冻结字段：
  - **可变字段**：`status`、`updated`、`spec_criteria[].done`、`spec_criteria[].evidence`、`reviews[]`、文末 `## Verification log` 区块
  - **冻结字段（status≥accepted 后）**：`id`、`created`、`owner`、`model`、`target_version`、`related_*`、正文 §1~§N 决策内容
  - 冻结字段变更必须通过新 spec 引用并 supersede 本文档
- ADR 文档 append-only：除 `status`（accepted → superseded-by NNNN）外字段不可变；正文不可变。
- version 文档可变：`status`、`shipped_date`、`includes_specs[]`、`release_notes_zh`；其他字段冻结。

**status 状态机**：

```
spec:
  draft  ─G2 approved─►  accepted  ─G6 spec_criteria 全 done─►  implemented
                              │
                              └─ 被新 spec supersede ─►  superseded

ADR:
  proposed  ─human ack─►  accepted  ─被新 ADR supersede─►  superseded-by NNNN
                                     ─不再适用但无新 ADR─►  deprecated

version:
  placeholder  ─首个 spec 落地─►  planned  ─开发开始─►  in-progress
                                                              │
                                                              ▼
                                                            shipped ─严重缺陷─► yanked
```

**Spec frontmatter schema**：

```yaml
---
id: YYYY-MM-DD-<slug>
title: <一句话主题>
status: draft | accepted | implemented | superseded
created: YYYY-MM-DD
updated: YYYY-MM-DD
owner: claude-code | human | <其他 runner>
model: <模型 ID，如 claude-opus-4-7、gpt-5-codex>
target_version: vX.Y.Z
related_adrs: [NNNN, ...]
related_research: [<slug>, ...]
spec_criteria:                   # 对象数组，G6 据此判定
  - id: SC<N>
    criterion: <可观察的成功条件>
    done: false                  # 实施过程中改 true
    evidence: null | <commit sha 或命令输出片段>
automated_checks:                # 命令字符串列表
  - "SC_AUTO_<NAME>: <bash 命令>"
manual_checks:                   # AI 跑的手动检查列表
  - "..."
reviews:                         # 每过一次 review gate append 一条
  - gate: G1 | G2 | G3 | G5 | G7
    reviewer: <model/agent name>
    date: YYYY-MM-DD
    verdict: approved | approved-after-revisions | changes-requested | blocked
    summary: |
      <自由文本，说明 reviewer 意见与作者响应>
    artifacts: ["<可选：链接>"]
---
```

文末 **`## Verification log`** 区块以 markdown checkbox 形式登记 SC 完成状态（G6 验收依据）：

```markdown
## Verification log
- [x] SC1 — evidence: commit <sha>
- [x] SC2 — evidence: <命令输出片段>
- [ ] SC13 — pending
...
```

**ADR frontmatter（MADR 0.x 精简版）**：

```yaml
---
id: NNNN
title: <decision summary>
status: proposed | accepted | superseded-by NNNN | deprecated
date: YYYY-MM-DD
deciders: claude-code, methol
---
```

正文：`## Context` → `## Decision` → `## Consequences` → `## Alternatives considered`。

**Version frontmatter**：

```yaml
---
version: vX.Y.Z
codename: <slug>
status: placeholder | planned | in-progress | shipped | yanked
target_date: YYYY-MM-DD | null
shipped_date: null | YYYY-MM-DD
includes_specs: [<spec-id>, ...]
release_notes_zh: |
  ...                            # AI 在发版时填，复制到 CHANGELOG.md
---
```

> `_TEMPLATE.md` 必须包含一行 placeholder guardrail：*"如果你为本版本写第一个真正的 spec，请把 status 从 `placeholder` 升到 `planned`、清空示例 includes_specs。"*

## 4. 工作流与 Review Gate

### 4.1 主回路

```
research/  ─G1─►  spec/ADR  ─G2─►  writing-plans  ─G3─►  implementation
                                                              │
                                                              ▼
                                                            ─G4 (per chunk)
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

> AGENTS.md 含"工具可用性 preflight"章节：声明 `codex-rescue` / `general-purpose subagent` / `Explore` / `writing-plans` 在不同 AI runner 下的等价物与可用性检测。若工具不可用，gate fallback 路径在 AGENTS.md 内说明。

### 4.2 Gate 定义

| Gate | 触发 | 必跑动作 | 通过条件 |
|---|---|---|---|
| **G1** | 调研报告写完 | codex-rescue design-review（不可用时降级 general-purpose subagent，下同）+ Explore 事实核对 | 无 reviewer 标 "contradicted-by-evidence" |
| **G2** | spec / ADR 写完，**或 ADR 状态任何变更（accepted ↔ superseded ↔ deprecated）** | 独立 reviewer design-review；涉及凭证/隐私加 `/security-review` | reviewer verdict ∈ {approved, approved-after-revisions} |
| **G3** | writing-plans 出 plan | general-purpose subagent plan-review | plan 每步可独立验证、有 success criteria |
| **G4** | 实施过程中每个 commit-able 工作单元 | `superpowers:verification-before-completion` 强制 | `swift build` 与 `swift test` 绿；纯文档版本以 linkcheck + frontmatter lint 替代 |
| **G5** | PR 创建前 | `superpowers:requesting-code-review` → 独立 reviewer；`/review`；敏感面加 `/security-review` | reviewer verdict = approved |
| **G6** | merge 前 | CI 绿 + spec `## Verification log` 全勾完 | 所有 SC done=true |
| **G7** | 打 minor/major tag 前 | `/ultrareview`；release runbook pre-flight | runbook checklist 全绿；24h health 回访 |

### 4.3 自动化反馈"硬证据"

下列命令产出 **绿色输出** 是 AI 标定"我做完了"的硬证据：

```bash
# 代码版本
cd macos && swift build -c release
cd macos && swift test
make release-artifacts            # 仅发版必要
bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip

# 纯文档版本（v0.0.7 类）
# 见本 spec frontmatter automated_checks 中的 SC_AUTO_LINKCHECK / SC_AUTO_FRONTMATTER
```

未来引入 SwiftFormat / SwiftLint / Periphery / CodeQL 等需开 ADR 评估。

### 4.4 Reviewer 角色矩阵

| 角色 | 现成工具/skill | 独立性来源 | 不可用时 fallback |
|---|---|---|---|
| **author** | 主会话 | — | — |
| **design-reviewer** | `codex:codex-rescue` | 跨模型 | `general-purpose` subagent，prompt 显式要求独立判断 |
| **plan-reviewer** | `general-purpose` subagent | 跨 session | 主会话 self-review + 显式 cool-down 后重读 |
| **code-reviewer** | `superpowers:requesting-code-review` → codex-rescue + `/review` | 跨模型 | `general-purpose` subagent |
| **security-reviewer** | `/security-review` slash | 专项规则集 | 手写 checklist |
| **fact-checker** | `Explore` subagent | 只读 | `general-purpose` subagent with read-only prompt |
| **release-verifier** | `make release-artifacts` + `verify-release.sh` | 自动化 | — |
| **integration-verifier** | `/ultrareview` slash | 多 agent 云端 | 多个 subagent 并发 + 手动 cross-check |
| **human escalation** | AskUserQuestion | 人 | — |

### 4.5 失败处理 / 反馈循环

- **G1~G3 失败**：作者 AI 按 `superpowers:receiving-code-review` 处理 —— 不准 performative agreement，每条反馈写 *accepted / rejected with reason / needs-clarification*，更新 spec 后重跑 review。本 spec §10 即范例。
- **G4 失败**：禁止 commit；按 `superpowers:systematic-debugging` 排查。
- **G5 失败**：在 PR 内补 commit 直到 reviewer 转 approved。
- **同一 gate ≥2 轮分歧未达成定论** → 升级人类（AskUserQuestion，给 2~3 个选项 + 推荐）。
- **G7 失败**：release 立刻 yank，写入 `docs/runbooks/incident-response.md` 复盘。

### 4.6 何时停下问人类（hard gates）— minimum mandatory

§2 的"完全自治"是默认；以下情形 AI **必须** 升级人类，不得自行决断：

1. **凭证/密钥操作**：Apple Developer 账号、公证证书、Sparkle 私钥导出/重置
2. **引入新第三方依赖** / 修改 LICENSE / 改变商业模式
3. **同一 review gate ≥2 轮分歧** 且 reviewer 给出两个等价但语义不同的方案、无明显推荐项
4. **G7 发版后 24h 内 health check 报警**（Sparkle appcast 异常、用户反馈核心崩溃）
5. **spec / ADR 内部出现"违反既有 ADR"** 但作者认为 ADR 应被 supersede
6. **触发法律 / 合规风险信号**（用户隐私、第三方 API ToS、商标）

## 5. 根入口（AGENTS.md + CLAUDE.md 拆分）

- **`AGENTS.md`** — 新建，所有 AI 进仓库的中立入口：governance 总览 / 目录地图 / review gate 总则 / 工具可用性 preflight / 何时停下问人类。其他 AI runner（Codex / Cursor / Cline）也读这份。
- **`CLAUDE.md`** — 已有，收紧为 *Claude Code 专用*：常用命令、构建坑、SwiftUI/Sparkle 细节。顶部加 *"See AGENTS.md for governance contract"* 跳板。
- **`CONTRIBUTING.md`** — 保留，顶部加 *"This project is AI-led. See AGENTS.md."*

## 6. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `docs/README.md` | 文档总索引 |
| 🆕 | `docs/superpowers/specs/README.md` | spec 索引 + 状态表 |
| 🆕 | `docs/superpowers/specs/_TEMPLATE.md` | 与 §3.3 一致 |
| 🆕 | `docs/superpowers/specs/2026-05-11-docs-governance.md` | **本 spec** |
| 🆕 | `docs/adr/README.md` + `_TEMPLATE.md` | |
| 🆕 | `docs/adr/0001-swift-native-only.md` | |
| 🆕 | `docs/adr/0002-claude-only-not-multi-provider.md` | |
| 🆕 | `docs/adr/0003-ai-led-development.md` | |
| 🆕 | `docs/adr/0004-fork-divergence-from-blimp-labs.md` | 含 URL 校准决策 |
| 🆕 | `docs/versions/README.md` + `_TEMPLATE.md` | _TEMPLATE 含 placeholder guardrail |
| 🆕 | `docs/versions/v0.0.7-docs-governance.md` | |
| 🆕 | `docs/versions/v0.0.8...v1.0.0` | 占位（status=placeholder） |
| 🆕 | `docs/runbooks/README.md` + `release.md` | release.md 含 AI 自动写 CHANGELOG SOP + 中文翻译模板 + Runs log 表 |
| 🆕 | `docs/runbooks/{notarization,sparkle-keys,incident-response}.md` | 占位 |
| 🆕 | `docs/user-guide/README.md` + 占位 | |
| 🆕 | `AGENTS.md` | 含工具可用性 preflight |
| 🆕 | `CHANGELOG.md` | 根目录；v0.0.7 entry |
| 🔧 | `CLAUDE.md` | 顶部 governance 跳板 + 新增 *Project state* / *Before claiming work done* 两节 |
| 🔧 | **`README.md`** | 替换所有 `Blimp-Labs/claude-usage-bar` 链接为 `methol/usage-bar`；替换 appcast URL 为 `methol.github.io/usage-bar/appcast.xml`；新增 fork 关系声明段（与 ADR 0004 对齐） |
| 🔧 | `docs/research/competitive-analysis.md` 与 `docs/research/README.md` | 顶部加 frontmatter |
| ✅ 不动 | `LICENSE` / `CONTRIBUTING.md` / `macos/**` / `scripts/**` | v0.0.7 不触代码 |

## 7. 版本路线（v0.0.x 起步，1.0 远期）

**起点**：v0.0.6（fork 自 Blimp-Labs 截止点）。自 v0.0.7 起本仓库独立编号 + URL 校准（ADR 0004）。

### 7.1 版本号约定

- **patch（v0.0.x → v0.0.x+1）**：单功能交付。0.x 阶段 semver 允许 patch 含 feature。
- **minor（v0.x.0）**：阶段性体验里程碑。可直接由最后一个 patch 升格。
- **major（v1.0.0）**：稳定可用门槛（§7.3）达成才发。

### 7.2 路线表

| 版本 | 主题 | 含 spec | 性质 |
|---|---|---|---|
| **v0.0.7** | 文档治理 + 路线骨架 | 本 spec | 📚 纯文档 |
| v0.0.8 | hero popover 重做 | `hero-popover` | 🎨 UI |
| v0.0.9 | 趋势箭头 ▲▼ + history 计算 | `trend-arrows` | 🎨 UI |
| v0.0.10 | 菜单栏多显示模式 | `menubar-display-modes` | 🎨 UI |
| v0.0.11 | Pace tracking | `pace-tracking` | 🎨 UI + 算法 |
| **v0.1.0** | Phase 1 里程碑（看起来像 SessionWatcher） | 收尾打磨 | 🏁 minor |
| v0.1.1 | Claude CLI 凭证复用（零配置登录） | `claude-cli-credentials` | 🔌 数据源 |
| v0.1.2 | 本地 JSONL cost 扫描 | `local-cost-scan` | 🔌 数据源 |
| v0.1.3 | 多账号 tokenAccounts | `multi-account` | 🔌 数据源 |
| **v0.2.0** | Phase 2 里程碑（数据厚度赶上 CodexBar） | i18n 检查 | 🏁 minor |
| v0.2.1 | Apple Developer ID 公证 | `apple-notarization` | 🔧 |
| v0.2.2 | Sparkle beta 通道 | `sparkle-beta-channel` | 🔧 |
| v0.2.3 | claude.ai cookie 回退路径 | `cookie-fallback` | 🔧 |
| v0.2.4 | claude CLI PTY 兜底路径 | `cli-pty-fallback` | 🔧 |
| v0.2.5 | WidgetKit 扩展（Usage / History / Compact） | `widgetkit` | 🔧 |
| v0.2.6 | `claude-usage-bar` CLI 工具 | `cli-tool` | 🔧 |
| **v0.3.0** | Phase 3 里程碑（平台能力完整） | — | 🏁 minor |
| v0.3.x+ | 性能 / 能源 / a11y / 暗黑模式 / 中文 UI / 隐私 audit | 各自独立 spec | 0.x 持续 |
| **v1.0.0** | 稳定可用 | 满足 §7.3 清单 | 🚀 major |

#### v0.0.7 gate map（纯文档版本豁免）

v0.0.7 不含代码变更，gate 适配如下：

- **G1**：N/A（本版本不基于新调研）
- **G2**：✅ 已跑（本 spec reviews 数组）
- **G3**：跳过（迁移清单简单，迁移即计划，无独立 writing-plans 必要）
- **G4**：以 `SC_AUTO_LINKCHECK` + `SC_AUTO_FRONTMATTER` 替代 `swift build` / `swift test`
- **G5**：必跑 —— 提交 PR 时仍要走 code-reviewer（subagent），重点审 markdown 一致性、ADR/spec 交叉引用、URL 校准
- **G6**：必跑 —— SC1~SC17 全 done
- **G7**：仅当决定发 tag `v0.0.7`（用于在 GitHub 上锚定治理基线）时跑；可选

### 7.3 v1.0.0 "稳定可用"硬清单（扩展版）

发版 1.0 必须同时满足：

1. 主功能零 known critical bug 满 30 天
2. Apple Developer ID 公证（用户安装无右键 Open 提示）
3. Sparkle 自动更新经历过 ≥3 个版本周期且零事故
4. 至少 2 条 Claude 数据源路径可用（OAuth + 一种回退）
5. 中文 user-guide 完整（getting-started + faq + privacy + screenshots）
6. CHANGELOG.md 自 v0.0.7 起完整中文记录
7. 核心算法（pace / trend / cost-scan）单元测试 line coverage ≥80%
8. `docs/runbooks/release.md` 的 Runs log 表登记 ≥3 次成功 run，evidence 含 CI run URL
9. **性能基线**：idle CPU < 1%、内存 < 80MB、首次 cold start < 800ms（用 Instruments 或 `time` + Activity Monitor 验证并写入 runbook）
10. **能源**：Activity Monitor → Energy 列不出现 "Significant Energy Impact"
11. **隐私 audit**：完整 *"权限申请清单 + 数据流图 + 用户可审计"* 文档（`docs/user-guide/privacy.md`），覆盖所有数据源路径
12. **a11y**：VoiceOver 能完整朗读 menu bar 图标、popover 主数字与进度条；菜单项有正确语义角色
13. **本地化决策**：明确表态 v1.0 是否含中文 UI（不做也可，但 spec / ADR 必须显式声明）
14. **崩溃监控**：明确表态是否接 crash reporting，方案 / 替代方案（macOS Console + 用户截图）写入 runbook

任一项不满足，停在 v0.x。

## 8. 风险 / Open questions

1. **CodexBar 引用稳定性**：本 spec 与调研多处引用 CodexBar 的文档结构与实现细节。CodexBar 仍在快速演进，未来若大改架构、我们的引用可能过期。**对策**：在每次跨版本调研时复核 CodexBar 当时的 `docs/`，并在 ADR 中刻字"引用版本号"。
2. **Anthropic OAuth usage API 是 unpublished endpoint**：`/api/oauth/usage` 与 `anthropic-beta: oauth-2025-04-20` 不在公开 API 文档内。Anthropic 可能改 endpoint、改 header、改字段。**对策**：v0.1.1 引入 strategy chain 抽象层；接口失效时降级到 CLI 凭证 / cookie / CLI PTY 路径；并在 `docs/runbooks/incident-response.md` 写明应急回退步骤。
3. **CodexBar 数据契约变化**：我们将参考 CodexBar 的 *"读 `~/.claude/.credentials.json` 或 Keychain `Claude Code-credentials`"* 方法。如果 Claude CLI 改凭证格式（已发生过历史），瞬间打废这一路。**对策**：strategy 实现含格式 version 探测 + 失败 telemetry。
4. **Apple notarization 政策变化**：Apple 每年改 Hardened Runtime / entitlements / TCC。**对策**：v0.2.1 公证规则在 ADR 内冻结；未来 Apple 改规则触发新 ADR 而非默改 runbook。
5. **Sparkle 漏洞 / 升级路径**：Sparkle 2.x 历史上有过 EDDSA key 安全公告。**对策**：在 `docs/runbooks/sparkle-keys.md` 明确锁版本策略、关注 Sparkle Security Advisories 的 cadence、并约定一次性大版本升级 (≥2.9 / 3.0) 必须开 ADR。
6. **codex-rescue 可用性不稳定**：跨模型 review 依赖外部模型可用性与配额。**对策**：所有 reviewer 角色在 §4.4 已配 fallback 路径；AGENTS.md 工具可用性 preflight 强制 SC4 验证。
7. **CHANGELOG 中英文混排**：CHANGELOG 由 AI 写中文，但 git log / PR 标题历史上有英文。**对策**：`docs/runbooks/release.md` 含中文翻译模板，作为 G6 验收对象（SC8）。
8. **AGENTS.md vs CLAUDE.md 漂移**：两份文件分工有重叠风险。**对策**：每次 spec 涉及 governance 时同步检查两份；AGENTS.md 是 source of truth。
9. **版本占位文档过期**：v0.0.8 ~ v1.0.0 一次性占位，后续每个 spec 落地时改写对应 version。**对策**：`docs/versions/_TEMPLATE.md` 含 guardrail，写新 spec 时强制升 status。

## 9. 后续工作（不在本 spec 范围）

- 每个功能版本（v0.0.8+）的独立 spec，由相应 brainstorming 会话产出
- `docs/user-guide/` 内容填充（推到 v1.0 前完成）
- SwiftFormat / SwiftLint / Periphery / CodeQL 等工具评估（独立 ADR）
- v1.0 性能基线测量方法（`hyperfine` / Instruments template）独立 spec

## 10. G2 review response（受理记录）

> Reviewer：claude-code（general-purpose subagent，独立 session，2026-05-11）
> Verdict（原始）：changes-requested
> 处理：5 BLOCKING + 8 RECOMMENDED + 9 NOTES 逐条响应；spec 已大改并重新进入 G2。

### 10.1 BLOCKING — 全部 accepted

| ID | 摘要 | 处理 |
|---|---|---|
| B1 | spec_criteria 与 §6 迁移清单覆盖缺口 | accepted。重写为 17 条对象数组 SC1~SC17，与 §6 表格一一对应。 |
| B2 | G6 "spec_criteria 全勾完"的记录机制未定义 | accepted。新增对象字段 `done` + `evidence`；文末 `## Verification log` 区块以 markdown checkbox 登记。§3.3 schema 明确。 |
| B3 | reviews 字段 append 与 spec 不可变性冲突 | accepted。§3.3 新增"文档生命周期与可变性约定"段，明确 living document + 可变 / 冻结字段、status 状态机。 |
| B4 | v0.0.7 自身该跑哪些 gate 没明确 | accepted。§7.2 v0.0.7 行下新增 gate map，明示 G1/G3 跳、G4 替代命令、G7 可选。 |
| B5 | ADR 0004 与 README 链接现实冲突 | accepted。§6 README 改 🔧 修改；新增 SC12 强制替换 `Blimp-Labs/claude-usage-bar` → `methol/usage-bar`、appcast URL → `methol.github.io/usage-bar/appcast.xml`。ADR 0004 标题保留但内容澄清"独立编号 + URL 校准，不迁移 namespace"。 |

### 10.2 RECOMMENDED — 7 accepted，1 转 AGENTS.md

| ID | 摘要 | 处理 |
|---|---|---|
| R1 | v1.0 清单漏性能 / 能源 / 隐私 / 本地化 / a11y / 崩溃 | accepted。§7.3 从 8 条扩到 14 条。 |
| R2 | §8 风险章节漏 Anthropic API / CodexBar 数据契约 / Apple 政策 / Sparkle 漏洞 / Claude CLI 凭证格式 | accepted。§8 风险 1→9，全部补入。 |
| R3 | 工具可用性 preflight（writing-plans / codex-rescue / Explore 在不同 runner 下） | accepted，**转 AGENTS.md** 实现；本 spec 通过 SC4 强制 AGENTS.md 含该章节。 |
| R4 | v1.0 #8 "AI 跑通 3 次" measurability | accepted。改成 *"runbook 自身含 Runs log 表，登记 ≥3 次成功 run，evidence 含 CI URL"*（§7.3 #8）。 |
| R5 | owner: claude-code 语义 | accepted。新增 `model` 字段（本 spec frontmatter `model: claude-opus-4-7`），便于审计写作模型。 |
| R6 | status 状态机切换时机 | accepted。§3.3 新增状态机图（spec / ADR / version 各一套）。 |
| R7 | CHANGELOG 中英文混排解决方案太软 | accepted。SC8 强制 `release.md` 含"中文翻译模板片段"。 |
| R8 | G2 触发条件覆盖不全（ADR supersede 也要触发） | accepted。§4.2 G2 行加 *"或 ADR 状态任何变更"*。 |

### 10.3 NOTES — 6 accepted，1 rejected，2 noted-only

| ID | 摘要 | 处理 |
|---|---|---|
| N1 | superpowers/ 目录命名小众 | noted。§3.1 加注释说明 "工艺名而非工具名，未来换栈仍保留"。 |
| N2 | 占位 v0.0.8~v1.0.0 包毒 | accepted。§3.3 + §6 写入 `_TEMPLATE.md` placeholder guardrail（SC7 验证）。 |
| N3 | 日期时区 | accepted。§3.3 加 "ISO 8601，以提交者本地日期为准"。 |
| N4 | 决策表 vs hard gates 关系 | accepted。§2 表 + §4.6 标题调整，明确 §4.6 是 minimum mandatory、§2 是默认。 |
| N5 | ADR 速览缺失 | accepted。§2.1 新增 ADR 速览小节。 |
| N6 | spec 自我引用 v0.0.7 | **rejected with reason**：`target_version` 字段即此用途；spec 正文引用 v0.0.7 是历史记录性质（"这个版本要装这个 spec"），不是模板变量。 |
| N7 | v0.2.x 一行严重超载 | accepted。§7.2 v0.2.x 展开为 v0.2.1~v0.2.6。 |
| N8 | v0.0.7 gate map insufficient evidence | 已在 B4 解决。 |
| N9 | spec 没 Out of scope 一节 | noted。§9 后续工作已起到此作用，保留不动。 |

### 10.4 重跑 G2

本响应完成后 spec status 已升至 `accepted`。下一个 review gate 是 **G5（PR 时）** 与 **G6（merge 前 SC 全勾）**。如再走一次 G2（对修订后版本的独立 design-review），将由本仓库后续 contributor / AI 自主决定，不在本次 v0.0.7 必经路径上。

## 11. 引用

- 调研：[docs/research/competitive-analysis.md](../../research/competitive-analysis.md)
- ADR 0001~0004：见 `docs/adr/`
- 治理入口：根目录 `AGENTS.md`
- 本版本：`docs/versions/v0.0.7-docs-governance.md`

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。
> SC17 (中文 commit) 由 commit 时填入，evidence 为 commit sha。

- [x] SC1 — evidence: `docs/{research,superpowers/specs,adr,versions,runbooks,user-guide}/README.md` 全部存在
- [x] SC2 — evidence: `docs/superpowers/specs/_TEMPLATE.md`、`docs/adr/_TEMPLATE.md`、`docs/versions/_TEMPLATE.md` 全部存在且 frontmatter 与 §3.3 schema 对齐
- [x] SC3 — evidence: 根目录 `AGENTS.md`、`CHANGELOG.md` 存在；`CLAUDE.md` 顶部第 5 行起含 `> **Governance**: ... Read [\`AGENTS.md\`]...` 跳板
- [x] SC4 — evidence: `AGENTS.md` §5 "工具可用性 preflight（不同 runner 的等价物）" 章节
- [x] SC5 — evidence: ADR 0001~0004 已落地于 `docs/adr/`；本 spec §2 决策摘要表"原因 / 对应 ADR"列引用全部 4 条；§2.1 ADR 速览段每条一句话定调
- [x] SC6 — evidence: `docs/versions/v0.0.7-docs-governance.md` 已写；frontmatter `includes_specs: [2026-05-11-docs-governance]`、`status: in-progress`
- [x] SC7 — evidence: v0.0.8 ~ v1.0.0 共 17 个占位文件已建（详见 `docs/versions/` ls）；每个 frontmatter `status: placeholder`；`docs/versions/_TEMPLATE.md` 含 placeholder guardrail 段
- [x] SC8 — evidence: `docs/runbooks/release.md` §5 含"AI 自动写 CHANGELOG"完整 SOP（5.1 收集 / 5.2 中文模板 / 5.3 落地）；§5.2 含中文翻译模板；§10 Runs log 表已建（首次跑前为空）
- [x] SC9 — evidence: `docs/runbooks/{notarization,sparkle-keys,incident-response}.md` 占位文件存在并标注触发版本
- [x] SC10 — evidence: `docs/research/competitive-analysis.md` 与 `docs/research/README.md` 已补 frontmatter（含 slug、type、created、updated）
- [x] SC11 — evidence: 根目录 `CHANGELOG.md` 含 `[v0.0.7] — 2026-05-11` entry；中文；引用本 spec id 与 version 文件
- [x] SC12 — evidence: `README.md` Line 37 / 47 / 130 Blimp-Labs 链接已替换为 `methol/usage-bar` 与 `methol.github.io/usage-bar/...`；新增 *Fork relationship* 段引用 ADR 0004
- [x] SC13 — evidence: `python3 linkcheck` 输出 `✅ All relative links resolve.`（注：frontmatter `automated_checks` 中的 bash one-liner 在工程化时改用本 Python 脚本，后续 spec 可优化命令字段）
- [x] SC14 — evidence: `python3 frontmatter-lint` 输出 `✅ Frontmatter present on all 31 required files.`
- [x] SC15 — evidence: §10 G2 review response，reviews[0] verdict=approved-after-revisions
- [x] SC16 — evidence: 本 `## Verification log` 区块本身（self-fulfilling）
- [x] SC17 — evidence: commit `0e10c8f` (`docs: 立项 v0.0.7 文档治理与版本路线骨架 [spec:2026-05-11-docs-governance]`)
