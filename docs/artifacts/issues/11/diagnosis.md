# Issue #11 诊断

- 链接：https://github.com/methol/usage-bar/issues/11
- 标题：[feat] 修改readme

## 复现与定位

README.md 反映的是 fork 初期（v0.0.6 前后）的状态，后续多个版本新增了以下内容但均未同步：
1. **多 provider 支持（Claude + Codex）**：What it does / Usage 仅描述 Claude，未提及 Codex
2. **截图过时**：仍用 `demo.png`（单 provider UI）；issue 提供了新的两张截图
3. **数据存储变**：data storage 表格中列的是旧的 `token` 文件，现已迁移为 `credentials.json`
4. **项目结构**：文件清单不仅不完整，还有错误（`claude-logo.png` 已更名，大量新文件缺席）

## 根因

README.md 未随功能迭代同步维护。

## 修复方案

对 README.md 做如下更新：

1. **截图**：将旧的单张 `demo.png` 替换为 issue 中提供的两张新截图（直接引用 GitHub user-attachments CDN URL，已验证可访问，返回 HTTP 302 重定向正常）
2. **功能列表（What it does）**：新增 Codex provider 支持描述（provider tab 切换、Codex usage 追踪）
3. **Usage 节**：补充 Codex 使用说明。核查 `CodexCredentials.swift` 确认：
   - Codex 认证从 `~/.codex/auth.json` 读凭证（由 Codex CLI 在登录时写入），app **只读**不创建/写回
   - 因此正确描述为：**需先在终端用 `codex` CLI 登录**；app 检测到有效凭证后自动显示 Codex tab
4. **数据存储**：将 `token` 改为 `credentials.json`（0600），说明 legacy `token` 文件向后兼容迁移
5. **项目结构**：删除详细文件清单（容易过时且已有错误），保留顶层目录结构即可

## 影响范围

- 修改文件：`README.md`（仅文档，无代码变更）
- 风险点：user-attachments CDN 链接已验证可访问（HTTP 302 正常）；如未来 issue 被删除图片会 404，但这是普遍做法
- 测试计划：
  - 核查替换后的截图 URL 可访问 ✅（已验证）
  - 核查 Codex 认证流程描述与 `CodexCredentials.swift` 一致 ✅（已核实：需 codex CLI 登录后 app 才自动接入）
  - 核查 `demo.png` 在 README 之外是否还有引用（`CONTRIBUTING.md` 等）

## 守护线自检

- [x] 不触碰凭证 / 密钥链路
- [x] 不引入新第三方依赖
- [x] 不修改 `docs/adr/` 下已 `accepted` 的 ADR
- [x] 不在 `UsageService` 之外重复 fetch / auth / 轮询逻辑（纯文档改动）
- [x] 不手改 `Info.plist` 里的版本号
- [x] 影响文件仅 1 个（README.md），改动量 ≤ 5 文件

## 是否需要人工介入

- 结论：NO
- 理由：守护线全绿，纯文档改动，架构信息已核实
