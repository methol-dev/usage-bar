---
id: 0007
title: AI 开发规则改用 .agent/rules/ 目录组织
status: accepted
date: 2026-07-08
deciders: methol, claude-code
---

# ADR 0007 — AI 开发规则改用 `.agent/rules/` 目录组织

## Context

母法 spec（`2026-05-11-docs-governance`）与 v0.4.1 docs-cleanup 形成的治理文档结构为：
`AGENTS.md`（L0/L1/L2 三层入口）+ `docs/agents/` 四件套（README / quickstart / operations / conventions）
+ `docs/workflow/issue-driven.md` + `CLAUDE.md`（部分内容重复的 Claude 专用坑）。运行两个月后暴露出结构性问题：

- **同一内容多处抄写**：hard gates 六情形 3 处、跨 runner 工具 fallback 表 4 处、mock server 说明 3 处、
  make 命令表 3 处、目录地图 3 处 —— 每处都要手工同步，实际已经漂移。
- **章节号引用漂移**：AGENTS.md 重构为 L0/L1/L2 后，operations / quickstart / runbooks 里至少 8 处
  仍指向旧的 §4/§6/§7 扁平编号（AGENTS.md 已无 §6、§7）。
- **事实性过时**：operations.md §4 称 mock server 只有 1 条路由，实际是 4 条（CLAUDE.md 与
  CONTRIBUTING.md 均已更新，operations.md 漏改）—— 正是多副本无单源的直接后果。
- **占位文档无信息量**：runbooks 3 个 placeholder（notarization / sparkle-keys / incident-response）、
  `docs/user-guide/`（v1.0 前无内容）只增加导航噪音。

owner 于 2026-07-08 指示参考 [looplj/axonhub](https://github.com/looplj/axonhub) 的 AGENTS.md +
`.agent/rules/` 组织方式全面梳理，并授权删除冗余文档。axonhub 模式的要点：入口文件极简
（全局硬规则 + 项目概览 + Rules Index 表），规则按领域拆成带 `globs` frontmatter 的小文件，
每条规则是编号的、可操作的硬约束而非流程叙事。

## Decision

采用 axonhub 式组织，同时保留本项目特有的治理核心（7 Review Gates + Hard Gates，ADR 0003 的根基）：

1. **`AGENTS.md` 收敛为唯一治理入口**：Global Rules（全局硬规则）+ 项目概览 / 代码结构 + 任务路径表 +
   工作流主回路与 7 Gates + Hard Gates（六情形唯一权威副本）+ Rules Index 表。
2. **详细规则拆到 `.agent/rules/`**，每个文件带 `alwaysApply` / `globs` frontmatter：
   `swift.md`（架构红线 + 代码风格）、`build-test.md`（命令 / 验证矩阵 / G4 硬证据）、
   `docs.md`（写作约定 / frontmatter / 命名）、`tooling.md`（跨 runner preflight 与 fallback）、
   `mock-server.md`、`workflows/issue-driven.md`（生命周期 + 项目配置合并为单文件单源）。
3. **`CLAUDE.md` 极简化**：`@AGENTS.md` import + 仅 Claude Code 专属的几条 hint。
4. **删除**：`docs/agents/`（4 文件）、`docs/workflow/`、`docs/user-guide/` 占位、
   runbooks 3 个 placeholder。`docs/runbooks/`（active 的 release / add-new-provider）、
   `docs/adr|specs|plans|versions|research|artifacts` 不动。
5. **单源原则**：每条规则只允许一个权威副本；其他位置只放链接。跨文档引用 AGENTS.md 时用
   **命名章节**（如「Hard Gates」）而非数字编号，避免再次漂移。

母法 spec §3.1 的目录树自本 ADR 起视为历史快照（spec 不可变，不回改）；`docs/agents/` 与
`docs/workflow/` 相关表述以本 ADR 为准。母法 §4（gates）、§3.3（frontmatter schema）继续有效。

## Consequences

### Positive

- 每条规则单一权威副本，同步成本归零；mock server 之类的事实性漂移不再可能发生
- 规则文件带 `globs`，支持按文件类型 scope 加载的 runner（Cursor / Windsurf 等）可精准注入
- AGENTS.md 与 CLAUDE.md 合计从 178 行降到约 135 行，新 runner 首读负担下降
- 冗余文档净删 8 个文件（约 640 行）

### Negative

- 母法 spec §3.1 目录树与现状不再一致，读母法的 AI 需注意其"历史快照"标注（已在 AGENTS.md
  「引用」节与 docs/README.md 顶部标注）
- CHANGELOG / specs / versions 等历史文档中指向 `docs/agents/*`、`docs/workflow/*` 的旧链接成为
  死链 —— 属 append-only 历史记录，按惯例不回改

### Neutral

- 7 Review Gates 与 Hard Gates 治理机制本身不变，只是承载位置收敛
- `scripts/issues/*.sh`、CI、Makefile 对被删路径零引用，无行为变化

## Alternatives considered

### Alternative A — 保留 docs/agents/ 结构，只修漂移与重复

- 描述：逐处修正章节号引用、统一 mock server 说明，不动目录结构
- 拒绝原因：多副本结构是漂移的根因，修一轮之后还会再漂；owner 明确要求参考 axonhub 重组

### Alternative B — 完全照抄 axonhub（去掉 gates / hard gates 治理层）

- 描述：AGENTS.md 只留全局规则 + Rules Index，治理流程全部删除
- 拒绝原因：本项目是 AI-led（ADR 0003），7 Gates + Hard Gates 是自治边界的根基，不能丢

### Alternative C — 规则放 docs/agents/ 原地改造为 rules 风格

- 描述：目录不动，只把内容改写成带 globs 的规则文件
- 拒绝原因：`.agent/rules/` 是多个 runner 生态正在收敛的约定位置（axonhub 同时被 Trae / Windsurf
  消费），放根目录 dot 目录比藏在 docs/ 下更易被工具发现

## References

- 参考项目：[looplj/axonhub](https://github.com/looplj/axonhub)（`AGENTS.md` + `.agent/rules/` 模式）
- 母法 spec：[`../superpowers/specs/2026-05-11-docs-governance.md`](../superpowers/specs/2026-05-11-docs-governance.md)
- [ADR 0003 — AI-led development](./0003-ai-led-development.md)
- v0.4.1 docs-cleanup spec：`2026-05-13-docs-cleanup`（被本 ADR 部分替代的上一轮文档结构；历史 spec，见 git history）
