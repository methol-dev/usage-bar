# 验证记录

## 命令 / 步骤(对应 CLAUDE.md 配置段「本地验证命令」中适用项)
改了 Swift 代码 + bundle 资源(`Resources/codex-logo.png`、`Resources/THIRD_PARTY_LICENSES.txt`),所以跑:

1. `cd macos && swift build -c release`
2. `cd macos && swift test`
3. `make release-artifacts`
4. `bash macos/scripts/verify-release.sh macos/UsageBar.zip`
5. 检视生成的 `codex-logo.png` 渲染结果 + 确认它进了 `.app` bundle

## 结果

| 步骤 | 结果 |
|---|---|
| `swift build -c release` | ✅ `Build complete!`(仅既有的 Swift 6 actor 警告,与本次无关) |
| `swift test` | ✅ `Executed 265 tests, with 0 failures`(含新增 `MenuBarIconRendererTests` 3 条:`renderIcon(.codex)` / `renderIcon(.claude)` / `renderUnauthenticatedIcon(.codex)` 均产出 `isTemplate==true`、非空、可 TIFF 化) |
| `make release-artifacts` | ✅ ZIP + DMG 都 `Release archive looks good`(`Verifying packaged resources` / `app signature` / `updater metadata` 全过) |
| `verify-release.sh macos/UsageBar.zip` | ✅ `Release archive looks good` |
| `codex-logo.png` 检视 | ✅ rsvg-convert 把 lobehub `codex.svg`(viewBox 24×24)渲成 512×512 RGBA;`fill=currentColor`→黑色、`fill-rule=evenodd`→`>_` 提示符被镂空 —— 即官方 OpenAI Codex 标的剪影,配合 `isTemplate` 随系统深浅色翻转 |
| `.app` bundle 内容 | ✅ `unzip -l macos/UsageBar.zip` 见 `UsageBar.app/Contents/Resources/UsageBar_UsageBar.bundle/codex-logo.png`(12834 bytes)、`claude-logo.png`、更新后的 `THIRD_PARTY_LICENSES.txt`(含 lobehub MIT 段) |

## 本地验证清单
- 单测 / 集成测试:✅ `swift test` 全 265 绿(新增 3 条菜单栏渲染 smoke)
- 构建:✅ `swift build -c release` 绿;`make release-artifacts` 绿;`verify-release.sh` 绿
- 接口契约:N/A(纯渲染层,无 API/schema 变更)
- 手动回归(建议人工补一眼):`make app` 后起 app → 菜单栏切到 Codex provider,确认显示 Codex 品牌标(不再是自绘 `</>`)、浅色与深色菜单栏下都清晰;切回 Claude 不受影响。(自动化只能验「产出可用 template 图标」,验不到「像素是不是那个标」—— 故此项留人工。)

## CI
- PR 的 `build` check 状态由 ship / merge 阶段记录。
