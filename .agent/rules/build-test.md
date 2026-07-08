---
alwaysApply: true
---

# 构建 / 测试 / 验证规则

## 命令速查

`make` targets 从仓库根目录跑；纯 `swift` 命令必须 `cd macos/`（`Package.swift` 在那里）。

```sh
# 构建与打包
make build              # swift build -c release（自动 cd macos）
make app                # build + 组装 .app（Info.plist / Sparkle / 资源 / 签名）
make zip                # app + zip + verify-release
make dmg                # app + DMG + verify-release
make release-artifacts  # 一次构建产出 zip + dmg + verify
make install            # build + 拷到 /Applications
make clean              # swift package clean + 删 bundle/zip/dmg

# 单测（必须 cd macos/）
cd macos && swift test
cd macos && swift test --filter UsageServiceTests
cd macos && swift test --filter UsageServiceTests/testBackoffIntervalCapsAtSixtyMinutes
```

**CI**（`.github/workflows/build.yml`）每个 push/PR 跑：`swift build -c release` → `swift test` → `make release-artifacts`。本地 commit 前要保证两者绿。

## 本地验证矩阵（实施后、commit / ship 前必跑相关项）

| 触发条件 | 命令 |
|---|---|
| 改 Swift 代码 | `cd macos && swift build -c release` + `cd macos && swift test` |
| 改 build / bundle / `scripts/` | `make release-artifacts` + `bash macos/scripts/verify-release.sh macos/UsageBar.zip` |
| 改 UI | `make app` 后手动起 app 回归金路径（尽量少跑 Xcode build） |
| 改纯文档 | 链接核对 + frontmatter lint（母法 spec `automated_checks`）；无脚本则人工核对 |

## G4 硬证据

下列命令产出绿色输出 = "我做完了"的硬证据（治理框架 G4，见 `AGENTS.md`）：

```sh
cd macos && swift build -c release
cd macos && swift test
make release-artifacts
bash macos/scripts/verify-release.sh macos/UsageBar.zip
```

纯文档版本：见母法 spec frontmatter `automated_checks` 中的 `SC_AUTO_LINKCHECK` / `SC_AUTO_FRONTMATTER`。
