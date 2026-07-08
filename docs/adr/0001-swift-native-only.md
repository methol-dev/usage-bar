---
id: 0001
title: Swift native only — 不引入 Electron / Tauri / 跨平台运行时
status: accepted
date: 2026-05-11
deciders: claude-code, methol
---

# ADR 0001 — Swift native only

## Context

`usage-bar` 是 macOS 菜单栏常驻 app，对启动速度、内存占用、能源效率、菜单栏渲染保真度极敏感：

- 菜单栏图标必须 18×18 pt 高保真自绘（含双窗口 bar、趋势箭头、动态颜色）
- 用户期望"打开即用、永远在那"——cold start < 1s，idle 内存 < 80MB
- macOS Sonoma+ 提供 `MenuBarExtra` SwiftUI 原生 API（macOS 13 起），优势明显
- 同类竞品全部 Swift 原生：[SessionWatcher](https://www.sessionwatcher.com/)、[CodexBar](https://github.com/steipete/CodexBar)、[ClaudeBar](https://github.com/tddworks/ClaudeBar) 等
- 仓库 fork 自 Blimp-Labs，已经是 SwiftPM + SwiftUI + Sparkle 2.8.1 栈，沉没成本与既有资产偏向继续 Swift

## Decision

**全栈 Swift / SwiftUI / SwiftPM**：

- UI 用 SwiftUI（含 `MenuBarExtra`、`Swift Charts`）
- 数据层用 `Foundation` / `URLSession` / `Combine` / `async/await`
- 更新走 [Sparkle](https://sparkle-project.org)（已集成）
- 包管理用 SwiftPM，**不引入 CocoaPods / Carthage / Xcode 工程文件**
- 拒绝引入 Electron / Tauri / React Native / Flutter / Web View 内嵌 UI
- 命令行工具（如未来立项）也用 Swift，复用核心 strategy 层

## Consequences

### Positive

- 启动 < 1s、idle 内存可控、能源效率最优
- 与 macOS 平台演进同步（Liquid Glass / Tahoe / 新版 MenuBarExtra 等）
- 与竞品 UI 质感对齐，避免被识别为"二等公民应用"
- 单语言栈降低 AI 维护负担

### Negative

- 失去跨平台可能性（Windows / Linux 没有计划）
- Swift 6 严格并发引入心智成本（但 CodexBar 已证明可控）
- 团队 / AI 学习曲线略陡（相比 Web 栈）

### Neutral

- 与 CodexBar 等开源竞品在技术栈上无差异化，差异化靠产品体验（定位见 [ADR 0005](./0005-reopen-multi-provider-direction.md)）

## Alternatives considered

### Alternative A — Tauri (Rust + WebView)

- 描述：用 Rust 写后端逻辑，前端 WebView 渲染 popover
- 拒绝原因：
  - 菜单栏图标无法用 WebView 渲染（必须原生 NSImage）
  - 进程数翻倍，与"轻量常驻"定位冲突
  - 失去 SwiftPM + Sparkle 既有资产

### Alternative B — Electron

- 描述：完全 Web 栈
- 拒绝原因：100+ MB 内存基线、cold start > 2s、菜单栏渲染受限——对一个"读数据条"型 app 完全过度

### Alternative C — 部分 Swift + 部分 Python helper

- 描述：用 Python 写本地 JSONL 扫描 / CLI PTY 解析
- 拒绝原因：增加分发复杂度（Python runtime 嵌入）、增加签名 / 公证表面积；Swift 完全可以胜任 JSONL 解析与 PTY 控制（CodexBar 已实现）

## References

- 调研：`competitive-analysis` §5 Swift 化执行策略（历史调研，已随 2026-07-08 文档清理移除，见 git history）
- 现有代码栈：`macos/Package.swift`、`macos/Sources/UsageBar/`
