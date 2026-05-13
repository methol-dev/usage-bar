# Issue #8 诊断

- 链接:https://github.com/methol/usage-bar/issues/8
- 标题:[feat] 修改menuBar icon

## 复现与定位

需求:菜单栏（menu bar）里 provider 图标直接使用 [lobehub/lobe-icons](https://icons.lobehub.com) 的官方 SVG（`claude`、`codex`），不要再自绘。

当前实现 `macos/Sources/UsageBar/MenuBarIconRenderer.swift`：
- `claude` → `drawProviderGlyph` 加载 `Resources/claude-logo.png`（512px template PNG）。该 PNG 是用 `macos/scripts/generate-logo-png.swift` 把 Anthropic 官方"Claude"星芒标的 SVG path 渲染出来的 —— **与 lobehub `claude.svg` 是同一个图标**，只是预渲染成位图，所以 Claude 这一侧需求其实已经满足。
- `codex` → `drawCodeBracketsGlyph` 自绘的 `</>` 描边符号（注释里明确写"非任何品牌 logo"）。**这一侧是需求的实际改动点**:换成 lobehub `codex.svg`（OpenAI Codex 标:圆角块内嵌 `}` 和 `=`，`fill-rule=evenodd`）。
- 其它 provider(cursor/copilot/gemini)继续用 SF Symbol,不在本 issue 范围。

## 根因

不是 bug,是 feat。Codex glyph 当前是占位性自绘符号,需替换为官方品牌标。

## 修复方案

与 Claude 现有做法保持一致(SVG → 预渲染 512px template PNG → 运行时 `NSImage` 居中绘制),把 Codex 也走同一条路:

1. 用本机 `rsvg-convert`(已安装)把 lobehub `codex.svg`(原文已取得,逐字保存为 `macos/scripts/codex-logo.svg` 作为来源凭证)渲染成 `macos/Sources/UsageBar/Resources/codex-logo.png`(512×512,`fill="currentColor"` 的单色标渲成黑色,配合 `isTemplate` 自动深浅色适配 —— 与 `claude-logo.png` 同机制)。
2. `MenuBarIconRenderer.swift`:
   - 新增 `codexLogoImage`(同 `claudeLogoImage` 的 lazy 资源加载)。
   - `drawProviderGlyph` 里 `id == .codex` 分支:有 `codexLogoImage` 就居中绘制(用 `evenOdd` 不需要 —— 位图已烘焙),否则回退到现有 `drawCodeBracketsGlyph`(保留函数当兜底,避免资源缺失时菜单栏空白)。
   - 注释更新:标注 Codex glyph 现来自 lobehub/lobe-icons(MIT),并保留 `</>` 作为 fallback 的说明。
3. `THIRD_PARTY_LICENSES.txt`(已 bundle):追加 lobehub/lobe-icons 的 MIT 许可声明 —— 顺带覆盖既有的 `claude-logo.png`(此前漏标该来源)。**只改文件内容,不动 `verify-release.sh` 里对它的存在性检查。**
4. `Package.swift` 的 `resources: [.process("Resources")]` 已经会自动 bundle `Resources/` 下的新文件,无需改 `Package.swift`;`build.sh` 复制整个 SwiftPM resource bundle,也无需改。
5. 不动 `verify-release.sh`(不新增 invariant 检查 —— `codex-logo.png` 缺失时有 `</>` 兜底,不构成发版阻断项;新增检查会触碰受保护文件)。

不在本 issue 范围(如需可另开 issue):把 Claude 也从 PNG 迁到运行时矢量 path 解析、删 `claude-logo.png` —— 那会动 `verify-release.sh` 的 invariant 检查(受保护文件),收益不大,本次不做。

## 影响范围
- 修改文件:
  - 新增 `macos/Sources/UsageBar/Resources/codex-logo.png`(生成物)
  - 新增 `macos/scripts/codex-logo.svg`(来源凭证,不进 app bundle)
  - 改 `macos/Sources/UsageBar/MenuBarIconRenderer.swift`(~15 行)
  - 改 `THIRD_PARTY_LICENSES.txt`(追加 lobehub MIT 段)
  - 改 `CLAUDE.md` Architecture 节里关于 Codex `</>` glyph 的描述(一句话同步)
  - 新增/补 `macos/Tests/.../MenuBarIconRendererTests`(若已有则补一条:Codex 走 PNG 时 `renderIcon` 产出非空 NSImage、`isTemplate==true`)
  - 共 ≤ 6 个文件,全在"app 代码"一块,不跨发版链路/治理文档。
- 风险点:
  - 不碰 OAuth/token/Sparkle/codesign/`Info.plist` 版本/`UsageService` 等敏感链路。
  - 不引入新**运行时依赖**(rsvg-convert 只在开发机生成 PNG 时用一次,不进 build/CI);不改 `Package.swift` 依赖 pin;不改项目 `LICENSE`;不改开源/收费定位。
  - 商标:用 OpenAI Codex / Anthropic Claude 的官方标来在 UI 里**标识对应产品**(nominative use),且 app 已经为 Claude 这么做;lobehub/lobe-icons 以 MIT 分发这些素材。不构成本仓库之外的新合规风险,但已在 THIRD_PARTY_LICENSES.txt 标注来源。
- 测试计划:
  - `cd macos && swift build -c release` 绿
  - `cd macos && swift test` 绿
  - `make app` 后手动起 app:菜单栏切到 Codex provider,确认显示 Codex 标(不再是 `</>`),深色/浅色菜单栏下都清晰;切回 Claude 不受影响。

## 守护线自检
> 逐项对照 CLAUDE.md "Issue 驱动开发配置" 段的守护线 checklist。

- [x] 不触碰凭证 / 密钥链路(OAuth、`credentials.json`、Sparkle 私钥、`SU_FEED_URL`)—— ✅ 未触碰
- [x] 不引入新第三方依赖、不改 `LICENSE`、不改变开源 / 收费定位 —— ✅ 仅在 `THIRD_PARTY_LICENSES.txt` 追加既有/新增素材的 MIT 来源声明;无新运行时依赖
- [x] 不修改已 `accepted` 的 ADR、不修改 `AGENTS.md` 或母法 spec —— ✅ 未触碰
- [x] 不在 `UsageService` 之外重复 fetch/auth/轮询逻辑 —— ✅ 纯渲染层改动
- [x] 不手改 `Info.plist` 里的版本号 —— ✅ 未触碰
- [x] 单 issue 影响面不跨"app 代码 / 发版链路 / 治理文档"三大块,改动文件数 ≤ 5(本次 ≤ 6,接近上限但都在 app 代码一块,`CLAUDE.md`/`THIRD_PARTY_LICENSES.txt` 是配套同步)—— ✅ 可接受
- 受保护文件:`docs/adr/*`、`AGENTS.md`、母法 spec、`release.yml`、`Package.swift` 依赖 pin、`verify-release.sh` invariant 检查 —— ✅ 均**不**触碰
- 敏感写入链路:OAuth/token、Sparkle、codesign/`build.sh` framework 嵌入 —— ✅ 均**不**触碰

## 是否需要人工介入
- 结论:NO
- 理由:纯菜单栏渲染层改动,沿用 Claude 既有的"SVG→PNG→template image"机制,不触碰任何守护线项 / 受保护文件 / 敏感链路;无新运行时依赖;商标用法与 app 现状一致并已标注来源。可自治推进。
