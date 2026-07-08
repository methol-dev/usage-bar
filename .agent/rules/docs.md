---
alwaysApply: false
globs: "docs/**/*.md, *.md"
---

# 文档写作规则

写 ADR / version / runbook / 索引时的统一规范。

## 1. 写作风格

- **日期**：ISO 8601 `YYYY-MM-DD`，以提交者本地日期为准
- **frontmatter**：ADR / version 文档第一行必须是 `---`
- **中文优先**：技术术语、命令、API 名称、模型 ID 保留英文
- **不写 emoji**（除非用户明确要求）
- **commit message**：中文；含变更主题 + 相关 issue / ADR 引用
  - 例：`docs: ADR 0008 落地新开发工作流 [ADR 0008]`、`fix(issue-#42): …`
- **PR title**：与 commit 一致，中文；PR body 可中英混排

## 2. Frontmatter 速查

### 2.1 ADR（`docs/adr/_TEMPLATE.md`，[MADR 风格](https://adr.github.io/madr/)）

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 4 位数字，严格递增 |
| `title` | ✅ | 决策总结 |
| `status` | ✅ | `proposed` / `accepted` / `superseded-by NNNN` / `deprecated` |
| `date` | ✅ | ISO 日期 |
| `deciders` | ✅ | 拍板人，通常 `methol, claude-code` |

### 2.2 Version（`docs/versions/_TEMPLATE.md`）

| 字段 | 必填 | 说明 |
|---|---|---|
| `version` | ✅ | `vX.Y.Z` |
| `codename` | ✅ | 与文件名 slug 一致 |
| `status` | ✅ | `placeholder` → `planned` → `in-progress` → `shipped`（→ `yanked`） |
| `target_date` / `shipped_date` | 视状态填 | ISO 日期 或 null |
| `release_notes_zh` | 发版前填 | 中文 multi-line block；发版时复制到 CHANGELOG.md |

## 3. 命名规范

### Version 文件

- `vX.Y.Z-<kebab-case-codename>.md`
- 版本号严格递增；不跳号；patch 含 feature 在 0.x 阶段合法

### ADR 文件

- `NNNN-<kebab-case-slug>.md`（4 位数字 + slug）
- 编号严格递增；不复用，不重排；被清理移除的编号保留空缺
- supersede 时：新 ADR 引用旧 ADR id 并在 `Context` 节说明替换原因；同时把旧 ADR 的 `status` 改为 `superseded-by NNNN`

### 索引文件（README.md）

- ADR / version 索引必有 frontmatter（`slug` + `type=index` + `created/updated`）
- 表格列与对应文件 frontmatter 同步；frontmatter 是单源真相

## 4. 大小写与术语

- 项目名：`UsageBar`（不是 `Usage Bar` 不是 `usage-bar`；后者只用于 URL / repo 名）
- 历史名 `ClaudeUsageBar` 仅出现在 ADR 0006 等历史文档中
- 模型 ID：保留厂商命名
- 命令 / 文件路径：等宽字体，反引号包裹

## 5. 链接

- 仓库内部链接用相对路径（`../adr/0001-...md`），不用绝对路径或 GitHub URL
- 跨子目录链接需明确层级（避免 `./xxx.md` 在不同位置 ambiguous）
- 外部链接（GitHub、Sparkle 等）使用完整 https URL
- 指向已删除历史文档（旧 spec / plan / artifacts）的引用一律用纯文本 + "见 git history"，不留链接

## 6. CHANGELOG

由 AI 在发版 runbook（[`docs/runbooks/release.md`](../../docs/runbooks/release.md) §5）自动生成，不手工日常维护。规则：

- **不要直接 copy PR 标题**（多为英文）
- 每条 PR / commit 翻译成中文 + 按"用户视角"重写
- 分类：新增 / 改进 / 修复 / 安全隐私 / 内部
- 引用对应 version 文件与 PR 号
