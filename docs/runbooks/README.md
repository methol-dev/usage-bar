# Runbooks

AI 可执行的标准操作流程。每份 runbook 都是"命令式"的——按步骤跑、每步有可观察的"完成信号"。

> Runbook 写作要求：
> - 步骤化、命令式、原子化
> - 每步要么有可粘贴执行的命令，要么有可勾选的判定条件
> - 失败处理路径与回滚路径必须明示
> - 含 `## Runs log` 表，AI 每次跑完 append 一行（含日期 / 版本 / 结果 / evidence URL）

## 当前清单

### Active runbooks（可执行）

| Runbook | 用途 |
|---|---|
| [`release.md`](./release.md) | 标准发版流程（含 AI 自动写 CHANGELOG） |
| [`add-new-provider.md`](./add-new-provider.md) | 接入新用量数据源 provider 的实施清单 |

### Placeholder runbooks（占位，未来落地）

> 这些文件仅有骨架，**真正执行前必须先按 [`AGENTS.md`](../../AGENTS.md) §6 hard gate 升级人类**。

| Runbook | 用途 | 触发时机 |
|---|---|---|
| [`notarization.md`](./notarization.md) | Apple Developer ID 公证 | v0.2.1 落地时填 |
| [`sparkle-keys.md`](./sparkle-keys.md) | Sparkle Ed25519 密钥操作 | 凭证操作时填 |
| [`incident-response.md`](./incident-response.md) | 应急响应 + 回滚 + 复盘 | 首次 incident 时填 |

## 编写新 runbook

1. 复制其他 runbook 的结构（背景 / 前置检查 / 步骤 / 失败处理 / Runs log）
2. 每个步骤明示触发命令与判定条件
3. 任何涉及人类持有凭证（Apple 账号、Sparkle 私钥等）的步骤标注 ⚠️ HARD GATE
4. 第一次跑 runbook 时 AI 必须 append 一行 Runs log，并在 release/PR 关联此 evidence
