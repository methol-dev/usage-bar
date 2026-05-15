# Issue #36 诊断

- 链接: https://github.com/methol/usage-bar/issues/36
- 标题: [feat] 调整更新按钮位置

## 复现与定位

当前 "Check for Updates…" 按钮位于 `PopoverView.swift` 的 `BottomBarView`（第 276–283 行），
与 Quit 同排。用户希望：
1. 把该按钮**移到** `SettingsView.swift` 的 "Updates" 区段，让更新操作集中在设置里。
2. 在 menubar popover 底部栏的 Quit 按钮旁**新增版本号**（如 `v0.6.0`），方便用户识别当前版本。

## 根因

功能入口分散：检查更新的 UI 放在 popover 底部栏，缺乏和更新渠道选择的上下文聚合；
且 popover 底栏没有展示版本号。

## 修复方案

### 改动 1 — SettingsView.swift
- `SettingsWindowContent` 新增 `appUpdater: AppUpdater` 参数。
- 在 "Updates" `Section` 内，Picker 下方新增 "Check for Updates…" `Button`，
  用 `appUpdater.canCheckForUpdates` 控制 disabled，`appUpdater.isConfigured` 控制显示。

### 改动 2 — UsageBarApp.swift
- `Settings {}` block 传入 `appUpdater: appUpdater`。

### 改动 3 — PopoverView.swift
- 从 `BottomBarView` 移除原有 "Check for Updates…" 按钮。
- Quit 按钮左侧新增版本号 `Text`，读 `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`，
  显示为 `v{version}`，样式与 Quit 同级（caption + secondary）。

## 影响范围

- 修改文件：`SettingsView.swift`、`UsageBarApp.swift`、`PopoverView.swift`（共 3 个）
- 风险点：`SettingsWindowContent` 新增参数，若有单元测试构造该 View 需同步更新——
  当前无相关 XCTest，风险极低。
- 测试计划：`swift build -c release` + `swift test` 保证编译 & 回归；
  手动确认 Settings > Updates 出现按钮、popover 底栏 Quit 旁出现版本号。

## 守护线自检

- [x] 不触碰凭证 / 密钥链路：仅改 UI，未碰 OAuth token / credentials.json / Sparkle 私钥 / SUFeedURL 注入
- [x] 不引入新第三方依赖、不改 LICENSE、不改变开源/收费定位
- [x] 不修改 `docs/adr/` 已 accepted 的 ADR，不修改 AGENTS.md 或母法 spec
- [x] 不在 UsageService 之外重复 fetch / auth / 轮询逻辑
- [x] 不手改 Info.plist 里的版本号（只读取，不写入）
- [x] 改动文件数 3 ≤ 5，仅影响 app 代码块

## 是否需要人工介入

- 结论: NO
- 理由: 守护线全部通过，纯 UI 位置调整，改动文件数少，无受保护文件。
