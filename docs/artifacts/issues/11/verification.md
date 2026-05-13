# 验证记录

## 命令 / 步骤
- 纯文档改动，按 CLAUDE.md 规范：链接核对 + 内容准确性人工检查

## 结果 / 截图
- 截图 URL 可访问：两张 GitHub user-attachments CDN URL 均返回 HTTP 302（正常）
- Codex 认证描述与代码核实一致：CodexCredentials.swift 明确标注 app 只读不写 ~/.codex/auth.json
- demo.png 引用仅在 README.md，移除后无其他引用断裂

## 本地验证清单
- [N/A] 单测 / 集成测试：纯文档，无需
- [N/A] 构建：纯文档，无代码变更
- [x] 接口契约：Codex 认证描述已核实与代码一致
- [x] 手动回归：检查新 README 内容完整性，截图链接、功能描述、数据存储、项目结构均已更新

## CI
- PR checks 状态由 ship/merge 阶段记录
