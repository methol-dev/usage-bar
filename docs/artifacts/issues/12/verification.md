# 验证记录

## 命令 / 步骤
- `cd macos && swift build -c release`（快速 arm64 验证）
- `cd macos && swift test`
- `make release-artifacts`（universal build + verify-release.sh）
- `lipo -info macos/UsageBar.app/Contents/MacOS/UsageBar`（验证 universal binary）

## 结果 / 截图
- `swift build -c release`：Build complete
- `swift test`：All 265 tests passed（0 failures）
- `make release-artifacts`：zip 和 dmg 均通过 verify-release.sh（"Release archive looks good"）
- `lipo -info`：`Architectures in the fat file: ... are: x86_64 arm64` ✅

## 本地验证清单
- [x] 单测：265 tests passed
- [x] 构建：`swift build -c release` 绿，`make release-artifacts` 绿
- [x] 接口契约：不涉及外部接口变更
- [x] 手动回归：lipo -info 确认 binary 包含 x86_64 + arm64 两个架构；verify-release.sh 的所有已有 invariant 检查通过

## CI
- PR checks 状态由 ship/merge 阶段记录

## 技术说明
SwiftPM 使用 `--arch arm64 --arch x86_64` 时自动在 `.build/apple/Products/Release/` 创建 universal binary，无需手动调用 lipo。资源 bundle 使用 `arm64-apple-macosx/release/` 路径（flat 布局，与 verify-release.sh 期望结构兼容）。Sparkle.framework 已是预构建 fat binary，从 `arm64-apple-macosx/release/` 路径取，两架构均可用。
