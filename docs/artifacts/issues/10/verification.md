# 验证记录

## 命令 / 步骤
- `cd macos && swift build -c release`
- `cd macos && swift test`

## 结果 / 截图
- `swift build -c release`：Build complete（仅既有 warnings，无新增 warning / error）
- `swift test`：Test Suite 'All tests' passed

## 本地验证清单
- [x] 单测：新增 `testRefreshAllEnabledOnOpenSkipsNonClaudeWhenSnapshotPresent` 通过；删除对已删属性 `shouldRefreshClaudeOnOpen` 的旧测试
- [x] 构建：`swift build -c release` 绿
- [x] 接口契约：不涉及外部接口变更
- [x] 手动回归：改动仅在 `refreshAllEnabledOnOpen`，不影响后台 polling 逻辑；Refresh 按钮路径不受影响

## CI
- PR checks 状态由 ship/merge 阶段记录
