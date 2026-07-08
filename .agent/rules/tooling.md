---
alwaysApply: false
description: "进入仓库先确认核心工具可用；过 review gate 选 reviewer 工具时读"
---

# 跨 runner 工具 preflight 与 fallback

进入仓库后 AI 应先确认核心工具可用。任何一项不可用，**走 fallback 而不停下问用户**（除非所有路径都失败）。

| 角色 | Claude Code 工具 | 其他 runner 等价 | Fallback |
|---|---|---|---|
| brainstorming | `superpowers:brainstorming` | 手写本 spec _TEMPLATE.md + 对话 | 直接对话 + 模板 |
| 写 spec | `Write` / `Edit` | 等价文件操作 | 直接编辑 |
| writing-plans | `superpowers:writing-plans` | 手写 plan markdown + checklist | TODO.md 风格清单 |
| 实施 / verification | `superpowers:verification-before-completion` | 自检 checklist | 手动跑 `swift build && swift test` |
| 跨模型 design-review (G2) | `codex:codex-rescue` / `codex:rescue` | Codex CLI / API；换 Claude 子会话 | `general-purpose` subagent（prompt 显式要求独立判断） |
| 跨 session plan-review (G3) | `general-purpose` subagent | 新开会话 + 完整 prompt | 主会话 self-review + cool-down 后重读 |
| code-review (G5) | `superpowers:requesting-code-review` + `/review` | Codex / Cursor review | 跨模型 review + 自动化 lint |
| security-review | `/security-review` slash | 等价 prompt | 手写凭证 / 权限 checklist |
| fact-check | `Explore` subagent | 只读快速查找 | grep / find 手动 |
| integration-review (G7) | `/ultrareview` slash | 多 agent 并发抽样 | 多次独立 review + cross-check |

> **Claude Code runner 已记 memory**：codex 工具不可用时**不要停下问用户**，直接走 `general-purpose` subagent fallback。
