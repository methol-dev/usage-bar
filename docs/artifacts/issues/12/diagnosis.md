# Issue #12 诊断

- 链接：https://github.com/methol/usage-bar/issues/12
- 标题：[feat] 打包支持intel芯片的macOS

## 复现与定位

当前 `build.sh` 使用 `swift build -c release`（无 `--arch` 参数），在 Apple Silicon 构建机上只生成 arm64 二进制文件，Intel Mac 用户无法运行已发布的 app。CI 运行在 `macos-14`（Apple Silicon），发布物也是 arm64-only。

Issue 要求：
1. 打包时同时支持 Intel（x86_64）芯片的 macOS（生成通用二进制）
2. 在 README 里描述最低支持的 macOS 版本（以及支持的芯片架构）

## 根因

`build.sh` 第 100 行 `swift build -c release` 未指定 `--arch`，默认只编译宿主机架构。

## 修复方案

### 1. `macos/scripts/build.sh`

**swift build + 二进制合并**：替换 `build_app_bundle()` 中 swift build 和 binary 路径逻辑：

```bash
# 旧（arm64-only）：
swift build -c release
local binary="$BUILD_DIR/release/$APP_NAME"

# 新（universal：arm64 + x86_64）：
swift build -c release --arch arm64 --arch x86_64
local arm_binary="$BUILD_DIR/arm64-apple-macosx/release/$APP_NAME"
local x86_binary="$BUILD_DIR/x86_64-apple-macosx/release/$APP_NAME"
mkdir -p "$BUILD_DIR/universal"
echo "==> Merging into universal binary..."
lipo -create -output "$BUILD_DIR/universal/$APP_NAME" "$arm_binary" "$x86_binary"
local binary="$BUILD_DIR/universal/$APP_NAME"
```

**资源 bundle 查找**：从旧的通用 `find` 改为显式先取 arm64（内容与 x86_64 完全相同），fallback 保留：

```bash
# 旧：
local resource_bundle="$BUILD_DIR/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    resource_bundle="$(find "$BUILD_DIR" -path "*/release/${APP_NAME}_${APP_NAME}.bundle" -type d | head -n 1 || true)"
fi

# 新：
local resource_bundle="$BUILD_DIR/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    # fallback：single-arch 或其他路径
    resource_bundle="$(find "$BUILD_DIR" -path "*/release/${APP_NAME}_${APP_NAME}.bundle" -type d | head -n 1 || true)"
fi
```

**Sparkle.framework 查找**：同样显式先取 arm64（Sparkle 是预构建 XCFramework，arm64 slice 与 x86_64 均有效），fallback 保留：

```bash
# 旧：
sparkle_framework="$(find "$BUILD_DIR" -path '*/Sparkle.framework' -type d | head -n 1 || true)"

# 新：
sparkle_framework="$BUILD_DIR/arm64-apple-macosx/release/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
    sparkle_framework="$(find "$BUILD_DIR" -path '*/Sparkle.framework' -type d | head -n 1 || true)"
fi
```

说明：
- `verify-release.sh` 不改动（受保护文件，现有 invariant 检查对 universal binary 同样有效）
- `make build`（`cd macos && swift build -c release`）保持不变，仍为快速 arm64 构建验证

### 2. `README.md`

- 说明：universal binary，支持 Apple Silicon & Intel Mac
- 明确 minimum requirement：macOS 14+ (Sonoma)
- 更新 badge / 文字

## 影响范围

- 修改文件：`macos/scripts/build.sh`、`README.md`（2 个文件）
- 风险点：
  - `swift build --arch arm64 --arch x86_64` 在 Swift 5.9 上是正式支持的功能
  - CI 运行在 `macos-14`（Apple Silicon），x86_64 为 cross-compile，Swift toolchain 内置支持
  - `lipo` 工具在所有 macOS 系统均内置
  - 不改动 `verify-release.sh`（受保护文件）
- 测试计划：
  - `cd macos && swift build -c release`（快速验证代码编译）
  - `cd macos && swift test`（单元测试）
  - `make release-artifacts`（验证全链路：universal build + 打包 + verify-release.sh 检查）
  - `lipo -info macos/UsageBar.app/Contents/MacOS/UsageBar`（验证 universal binary 确实包含两个架构）

## 守护线自检

- [x] 不触碰凭证 / 密钥链路（不改 OAuth / token / Sparkle 相关）
- [x] 不引入新第三方依赖（`lipo` 是 macOS 内置工具）
- [x] 不修改 `docs/adr/` 下已 `accepted` 的 ADR
- [x] 不在 `UsageService` 之外重复 fetch / auth / 轮询逻辑
- [x] 不手改 `Info.plist` 里的版本号
- [x] 影响文件 2 个，不跨三大块（仅"发版链路"+"文档"）
- [x] 不修改 `verify-release.sh` 的 invariant 检查（受保护项）

## 是否需要人工介入

- 结论：NO
- 理由：守护线全绿，build.sh 不在受保护文件列表，lipo 是标准工具，不涉及 release.yml / verify-release.sh 改动
