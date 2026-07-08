---
version: vX.Y.Z
codename: <slug>
status: placeholder           # placeholder → planned → in-progress → shipped (→ yanked)
target_date: null
shipped_date: null
release_notes_zh: |
  <发版时 AI 填写，复制到 CHANGELOG.md>
---

# vX.Y.Z — <Codename>

> ⚠️ **Placeholder guardrail**：开始实施本版本时，把 `status` 升到 `planned` / `in-progress`、
> 填入 `target_date`，并删除本提示框。

## 主题

<一段话说明这个版本要解决什么问题、用户能感知到什么变化。>

## 包含的变更

- PR #NN — <一句话>（关联 issue #NN / ADR NNNN，如有）

## 验收 checklist

- [ ] 计划的变更全部 merge（上方 PR 列表齐）
- [ ] CI 全绿（`swift build`、`swift test`、`make release-artifacts`）
- [ ] CHANGELOG.md 已 append 本版本 entry
- [ ] 本文件 `release_notes_zh` 已填写

## 发版 checklist

- [ ] `docs/runbooks/release.md` 全流程跑通
- [ ] tag 已推送，Sparkle appcast 已更新
- [ ] GitHub Release 已创建，资源（zip/dmg）已上传
- [ ] 24h health 回访通过

## Release notes (zh)

> 从 frontmatter `release_notes_zh` 同步过来。

## 引用

- 路线：[`README.md`](./README.md)
