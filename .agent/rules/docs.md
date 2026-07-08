---
alwaysApply: false
globs: "docs/**/*.md, *.md"
---

# 文档写作规则

写 spec / ADR / version / runbook / 索引时的统一规范。**完整 schema 与字段语义在 [母法 spec](../../docs/superpowers/specs/2026-05-11-docs-governance.md) §3.3，本文件是速查版**。

## 1. 写作风格

- **日期**：ISO 8601 `YYYY-MM-DD`，以提交者本地日期为准
- **frontmatter**：spec / ADR / version 文档第一行必须是 `---`
- **中文优先**：技术术语、命令、API 名称、模型 ID 保留英文
- **不写 emoji**（除非用户明确要求）
- **commit message**：中文；含变更主题 + 相关 spec id 引用
  - 例：`docs: 立项 v0.0.7 文档治理 [spec:2026-05-11-docs-governance]`
- **PR title**：与 commit 一致，中文；PR body 可中英混排，必含 spec id 与 version 链接
- **superpowers/ 目录命名**：是工艺名而非工具名 — 即使 superpowers skill 改名或弃用，目录保持

## 2. Frontmatter 速查

### 2.1 Spec（`docs/superpowers/specs/_TEMPLATE.md`）

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | `YYYY-MM-DD-<slug>`，与文件名一致 |
| `title` | ✅ | 一句话主题 |
| `status` | ✅ | `draft` 起步，G2 后改 `accepted`，G6 全勾后改 `implemented` |
| `created` / `updated` | ✅ | ISO 日期；`updated` 每次实质改动后同步 |
| `owner` | ✅ | `claude-code` / `human` / 其他 runner 名 |
| `model` | ✅ | 写作模型 ID |
| `target_version` | ✅ | 该 spec 计划落地的 `vX.Y.Z` |
| `related_adrs` / `related_research` | 可空 | ADR 编号数组 / research slug 数组 |
| `spec_criteria` | ✅ | 对象数组 `[{id, criterion, done, evidence}]`，G6 据此判定 |
| `automated_checks` / `manual_checks` | 可空 | 命令字符串 / 检查描述 |
| `reviews` | 初始 `[]` | 每过一次 review gate append 一条 verdict |

### 2.2 ADR（`docs/adr/_TEMPLATE.md`，[MADR 风格](https://adr.github.io/madr/)）

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 4 位数字，严格递增 |
| `title` | ✅ | 决策总结 |
| `status` | ✅ | `proposed` / `accepted` / `superseded-by NNNN` / `deprecated` |
| `date` | ✅ | ISO 日期 |
| `deciders` | ✅ | 拍板人，通常 `claude-code, methol` |

### 2.3 Version（`docs/versions/_TEMPLATE.md`）

| 字段 | 必填 | 说明 |
|---|---|---|
| `version` | ✅ | `vX.Y.Z` |
| `codename` | ✅ | 与文件名 slug 一致 |
| `status` | ✅ | `placeholder` → `planned` → `in-progress` → `shipped`（→ `yanked`） |
| `target_date` / `shipped_date` | 视状态填 | ISO 日期 或 null |
| `includes_specs` | placeholder 期为 `[]` | 首个 spec 落地时填入 spec id 并把 status 升到 `planned` |
| `release_notes_zh` | 发版前填 | 中文 multi-line block；发版时复制到 CHANGELOG.md |

## 3. Spec ↔ Version 双向链接惯例

- spec frontmatter `target_version: v0.0.8` 指向所属版本
- version frontmatter `includes_specs: [<spec-id>]` 反向引用 spec
- 触发 placeholder → planned：第一个真正 spec 落地时由作者 AI 在**同一 commit / PR** 内更新 version 文件 frontmatter + 删除文件顶部的 `> ⚠️ Placeholder guardrail` 提示框

## 4. 命名规范

### Spec 文件

- `YYYY-MM-DD-<kebab-case-slug>.md`（与 frontmatter `id` 一致）
- slug 简短、表达主题，不带版本号（版本号在 `target_version` 字段）
- 同一主题如需新版（supersede），新建文件并把旧文件 status 改为 `superseded`，**不删除旧文件**

### Version 文件

- `vX.Y.Z-<kebab-case-codename>.md`
- 版本号严格递增；不跳号；patch 含 feature 在 0.x 阶段合法
- placeholder 升级到 planned 时：清空 `includes_specs` 示例、填 `target_date`

### ADR 文件

- `NNNN-<kebab-case-slug>.md`（4 位数字 + slug）
- 编号严格递增；不复用，不重排；ADR append-only 不可变
- supersede 时：新 ADR 引用旧 ADR id 并在 `Context` 节说明替换原因；同时把旧 ADR 的 `status` 改为 `superseded-by NNNN`

### 索引文件（README.md）

- spec / ADR / version 索引必有 frontmatter（`slug` + `type=index` + `created/updated`）
- 表格列与对应文件 frontmatter 同步；frontmatter 是单源真相

## 5. 大小写与术语

- 项目名：`UsageBar`（不是 `Usage Bar` 不是 `usage-bar`；后者只用于 URL / repo 名）
- 历史名 `ClaudeUsageBar` 仅出现在 ADR 0006 与 v0.2.13 spec/version 文档中
- 模型 ID：保留厂商命名
- 命令 / 文件路径：等宽字体，反引号包裹

## 6. 链接

- 仓库内部链接用相对路径（`../adr/0001-...md`），不用绝对路径或 GitHub URL
- 跨子目录链接需明确层级（避免 `./xxx.md` 在不同位置 ambiguous）
- 外部链接（GitHub、Sparkle 等）使用完整 https URL

## 7. CHANGELOG

由 AI 在发版 runbook（[`docs/runbooks/release.md`](../../docs/runbooks/release.md) §5）自动生成，不手工日常维护。规则：

- **不要直接 copy PR 标题**（多为英文）
- 每条 PR / commit 翻译成中文 + 按"用户视角"重写
- 分类：新增 / 改进 / 修复 / 安全隐私 / 内部
- 引用对应 version 文件与 spec id
