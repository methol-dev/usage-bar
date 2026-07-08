# CLAUDE.md

@AGENTS.md

> 上面一行用 Claude Code 的 `@import` 语法把 [`AGENTS.md`](./AGENTS.md)（治理入口 + Rules Index）完整加载为上下文。

以下仅 Claude Code 专属：

- 用 `AskUserQuestion` 触发 hard gate 升级（给 2~3 个具体选项 + 推荐项，不要开放式问）
- 用 `TaskCreate` 追踪 brainstorming → spec → plan 进度，每步 `TaskUpdate`
- `superpowers:brainstorming` skill 是设计任务的入口；`writing-plans` 是后续 plan 阶段
- codex 工具不可用时**直接走 `general-purpose` subagent fallback，不要停下问用户**（已记 memory）
- Mock server 使用与还原要求见 [`.agent/rules/mock-server.md`](./.agent/rules/mock-server.md)
