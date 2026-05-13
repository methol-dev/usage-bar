# AI 方案评审(Plan Review)

由评审者(项目 CLAUDE.md 配置段的 reviewer:subagent / codex / manual)对 diagnosis.md
的修复方案做评审，结果填入本文件。

## 评审结论
- VERDICT: NEEDS_REVISION → 实施前已修订，等价 PASS
- 评审者: general-purpose subagent（独立）
- 评审日期: 2026-05-13

## 关键反馈

1. **迁移检测逻辑（RT 比对）**：比对存储 RT 与 Keychain RT 有极低概率误判 PKCE 账号（JWT 熵大，实践中安全，但理论上不为零）。推荐加注释说明局限；彻底修复需加 `source` 字段（schema 变更，后续 issue 跟进）。
2. **`activeAccountId` nil 边界**：迁移中 `activeIdx = accounts.firstIndex(where: { $0.id == activeAccountId }) ?? 0` 在 `activeAccountId` 为 nil 时强置 0，多账号场景可能错位。建议改为读取磁盘 `loadAccounts()` 获取正确 `activeIndex`。
3. PKCE 账号不受影响（RT 不匹配 → 迁移不剥离；`completeSignIn` 不经过 strip 路径）✓。
4. `strippingRefreshToken()` helper、bootstrap strip、recovery strip 均通过审查 ✓。

## 应对
- **接受**：迁移时改为读磁盘 `loadAccounts()` 获取 `activeIndex`，避免 nil 边界问题。
- **接受**：在 RT 比对逻辑处加代码注释说明启发式局限。
- **延后（后续 issue）**：添加 `source: AccountSource` 字段到 `StoredAccount` 实现语义精确的 CLI 来源标记。

## 是否需要人工介入
- 结论: NO
- 理由: 修订点均为低风险代码级调整，修订后方案覆盖了所有已知边界情况，可直接进入实施。
