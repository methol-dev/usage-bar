---
id: 0004
title: Fork divergence from Blimp-Labs upstream — 自 v0.0.7 起独立编号 + URL 校准
status: accepted
date: 2026-05-11
deciders: claude-code, methol
---

# ADR 0004 — Fork divergence from Blimp-Labs upstream

## Context

事实快照（2026-05-11）：

- 本仓库 git remote: `github.com/methol/usage-bar`
- 上游仓库: `github.com/Blimp-Labs/claude-usage-bar`，最新 tag `v0.0.6`（2026-03-10）
- 本仓库 `git tag --sort=-v:refname`: `v0.0.6 / v0.0.5 / v0.0.4 / v0.0.3 / v0.0.2 / v0.0.1`（与上游同名，fork 时一并 pull）
- 本仓库 `README.md` 中所有链接仍指向 `Blimp-Labs/claude-usage-bar`：
  - 安装下载链接（line 37）
  - 克隆命令示例（line 47）
  - **Sparkle appcast 域名 `blimp-labs.github.io/claude-usage-bar/appcast.xml`（line 130）**——⚠️ 如本仓库走 tag-driven release 注入 `SU_FEED_URL`，发出去的 app 会从上游 GitHub Pages 拉更新，等同发布**上游版本**给本仓库用户
- 本仓库即将开始独立功能升级（v0.0.7 起）

如果不固化分叉：

- 版本号有冲突风险（上游也可能发 v0.0.7）
- README / appcast 链接错误会导致**真实的发版事故**（推到上游 Pages、用户拉到错误更新）
- ADR 0003 AI-led 决策无法在 README 体现给读者

## Decision

**自 v0.0.7 起，本仓库与 Blimp-Labs/claude-usage-bar 上游分叉**，具体规则：

1. **版本号空间独立**：本仓库的 `vX.Y.Z` tag 与上游无对应关系。上游未来发任何 tag 都不影响本仓库。
2. **不迁移 GitHub namespace**：当前仓库继续保留在 `methol/usage-bar` 路径，不改名、不迁移到组织。
3. **URL 校准（v0.0.7 范围内必须完成）**：
   - `README.md` 所有 `Blimp-Labs/claude-usage-bar` GitHub 链接 → 替换为 `methol/usage-bar`
   - Sparkle appcast URL → `methol.github.io/usage-bar/appcast.xml`（**首次发版前必须确认本仓库的 GitHub Pages 已配置**）
   - README 新增 *"Fork relationship"* 段说明：fork 自 Blimp-Labs，自 v0.0.7 起独立
4. **保留上游 fork 关系**：在 README 致谢上游作者；不删除原 commit 历史。
5. **不 cherry-pick 上游**：上游后续提交不主动合并；如确有必要单独评估并开新 ADR。
6. **CI release 流程审计**：发版 runbook（[`../runbooks/release.md`](../runbooks/release.md)）首次跑通前必须验证：
   - `SU_FEED_URL` 环境变量来源
   - GitHub Pages 部署目标
   - GitHub Release upload target

## Consequences

### Positive

- 版本号语义清晰，不受上游影响
- 发版 URL 校准消除事故风险
- README 读者看到 "AI-led fork" 的明确声明，避免与上游混淆
- 上游未来变化（包括上游停摆）不影响本仓库

### Negative

- 失去自动同步上游 bug fix 的便利（需要手动 cherry-pick + 新 ADR）
- 用户在搜索引擎找到上游 SessionWatcher 等比较文章时可能困惑（"为何 GitHub 上有两个 claude-usage-bar？"）
- 一次性 README 改动有视觉断点（fork 关系段落与主介绍并列）

### Neutral

- 不迁移 namespace 意味着 GitHub URL 仍然是 `methol/usage-bar`，与 *blimp-labs* 同名性混淆问题永远存在；接受现状

## Alternatives considered

### Alternative A — 重置版本号到 v0.1.0

- 描述：fork 完直接跳到 v0.1.0，丢弃 v0.0.x 历史 tag
- 拒绝原因：用户明确希望 *"以 0.x 版本为主，稳定可用才到 1.0"*；v0.1.0 应该留给 Phase 1 里程碑

### Alternative B — 完全迁移到 `methol/claude-usage-bar` 新 namespace

- 描述：开新 repo，从头开始
- 拒绝原因：丢失 fork 历史、丢失 PR 编号引用、增加迁移工作量

### Alternative C — 继续同步上游 + 兼容上游版本号

- 描述：每次上游发版后 cherry-pick，保持 tag 历史一致
- 拒绝原因：
  - 上游 stable 时间未知（最近 commit 2026-03-10，已停滞 2 个月）
  - 本仓库即将引入 Pace tracking / 多 strategy / 本地 cost 扫描等大改，与上游必然 conflict
  - AI 维护 cherry-pick 链路成本高

## References

- 调研：[`../research/competitive-analysis.md`](../research/competitive-analysis.md)
- 相关 ADR：[`0003-ai-led-development.md`](./0003-ai-led-development.md)
- 发版 runbook：[`../runbooks/release.md`](../runbooks/release.md)
