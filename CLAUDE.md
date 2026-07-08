# CLAUDE.md

@AGENTS.md

> 上面一行用 Claude Code 的 `@import` 语法把 [`AGENTS.md`](./AGENTS.md)（治理入口 + Rules Index）完整加载为上下文。

以下仅 Claude Code 专属：

- 用 `AskUserQuestion` 触发 hard gate 升级（给 2~3 个具体选项 + 推荐项，不要开放式问）
- 功能开发用 `EnterPlanMode` 制定计划；plan review 用 `general-purpose` subagent（评审工具不可用时同样 fallback 到 subagent，不要停下问用户，已记 memory）
- 用 `TaskCreate` / `TaskUpdate` 追踪 plan → 实施 → review 各步进度
- 代码检查用 `/review` + `/security-review`；开 PR 前用 `/simplify` 精简冗余代码
- Mock server 使用与还原要求见 [`.agent/rules/mock-server.md`](./.agent/rules/mock-server.md)
