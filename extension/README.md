# UsageBar — Web Usage 扩展

在**用户自己已登录的 claude.ai / chatgpt.com 会话**里读取订阅用量,经 Chrome Native Messaging 交给
UsageBar 菜单栏 app。cookie 全程留在浏览器,扩展不读取、不导出任何凭证;Codex 的 bearer token 只在
chatgpt.com 页面上下文里用于同源请求,不回传给 app。

## 工作原理

```
控制通道(ADR 0011):扩展**主动**每 ~1min 轮询 host 拉配置
  → sendNativeMessage({type:"poll"}) → host 读 ~/.config/usage-bar/claude-web-control.json 回传
  → 扩展据配置行动:paused(停)/ syncNonce 变化(立即取数)/ intervalSeconds(节奏)
  → 拉不到 / 配置陈旧(app 关或崩)→ 退避休眠(心跳周期拉长)
取数:在已打开的 provider 标签页上下文 fetch(真同源,浏览器自动带 cookie / 同源 token)
  claude → claude.ai/api/organizations/{id}/usage
  codex  → chatgpt.com/backend-api/wham/usage(先取同页 /api/auth/session 的 accessToken,token 不出浏览器)
  → sendNativeMessage(usage) → host 原子写 ~/.config/usage-bar/<provider>-web.json → 菜单栏 app 读它显示
自动触发:上面的心跳 + 打开/切到 provider 标签页 + 浏览器获焦(取数经 60s 去抖门,手动「Sync now」绕过)
```

同步是**自动**的 —— 装好并保持一个 claude.ai / chatgpt.com 标签页登录后通常无需手动点。
「Sync now」按钮强制立即同步一次。app 端(菜单栏 Refresh、关闭 provider 或其 Web 源)能通过控制通道
**反向指挥**扩展(≤1min 生效)。

## popup 显示什么

逐 provider 一行(Claude / Codex),各自显示:

- **app 里的配置**:Web 源开 / 关、同步间隔;若该 provider 不在 app 下发的控制信封里(app 版本旧 /
  没有这个 provider),显示「Not managed by this app version」——与用户主动关掉 Web 源是两回事。
- **最近一次同步结果**:已同步(及多久前)/ 未登录 / 没开对应站点的标签页 / 失败(净化过的错误类别)。
- 当前不是「已同步」但历史上成功过时,补一句 app 侧那份数据有多旧。

底部一行是**控制通道**状态(app 在不在世 / 休眠重试周期)。逐 provider 展示的原因:合并成一条会让
某个 provider 的失败被另一个的成功掩盖(Claude 同步成功、Codex 没开标签页时显示「Synced ✓」,
而 app 里 Codex 始终没数据),这类问题最难排查。

## 没开标签页时会发生什么

该 provider 取不到数据(`no_session`),此时扩展**不回传** host —— 否则 host 会把这条结果写进
`<provider>-web.json`,把上一次的好数据覆盖成「未登录」。只启用 Web 源的 provider 没有 CLI 兜底,
那一覆盖等于直接把用量抹掉。不回写时 app 侧数据只是自然变陈旧(超 1h 有明确提示;启用了 CLI 源
则自动回退),是可恢复的诚实状态;「哪个站点没开标签页」在本 popup 里看。

## 安装(load unpacked)

1. 先运行一次 UsageBar.app —— 它会安装 native messaging host manifest 到
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.tuzhihao.usagebar.host.json`。
2. 拿到扩展目录:从 [latest release](https://github.com/methol-dev/usage-bar/releases/latest) 下载
   `usage-bar-extension-<version>.zip` 解压;或直接用仓库里的 `extension/` 目录(开发 / 自用)。
3. Chrome → `chrome://extensions` → 打开右上角 **Developer mode** → **Load unpacked** → 选上一步的目录。
4. 扩展 id 应为 `aaehoepakaalddpmbhljnhlbbigioeid`(由 `manifest.json` 的固定 `key` 决定;host manifest
   的 `allowed_origins` 已写死该 id)。若不一致,说明 `key` 被改过,需同步更新
   `NativeHostInstaller.extensionID`。
5. 保持一个 claude.ai / chatgpt.com 标签页登录状态 —— 同步是自动的;点扩展图标 → **Sync now**
   可强制立即同步一次。想同步哪个 provider,就保持哪个站点的标签页开着。
6. UsageBar → **Settings → Providers → Claude(或 Codex)→ Sources** 启用 **Web** 源
   (ADR 0010 / 0012:Web 是该 provider 的一个数据源,非独立 tab)。

## 隐私 / 合规

- 扩展**不请求 `cookies` 权限**,不读 `document.cookie`,不导出任何凭证。
- 请求由用户浏览器在真实登录会话里发出(content-script 注入,真正同源),不冒充任何客户端。
- 交给 app 的 payload 仅 `{status, ts, provider, usage?, error?}` —— 用量数字 + 状态(失败时 `error`
  是净化过的错误类别,无 URL / 响应体 / 凭证)。全程无凭证;Codex 的 accessToken 只在 chatgpt.com
  页面上下文里用于同源请求,不进 payload。
- popup 展示的诊断信息(配置 / 结果 / 时间)全部来自扩展自己的 `chrome.storage.local`,同样只有状态与
  时间戳,无凭证、无响应体。
- claude.ai / chatgpt.com 网页用量接口未文档化,属灰区;见 `docs/adr/0009-claude-web-usage-source.md`
  与 `docs/adr/0012-codex-web-and-generalized-multi-source.md`。

## 私钥

`manifest.json` 的 `key` 是**公钥**,可入库。对应**私钥**不入库(用于日后 Web Store 打包的 `.crx`
签名),需单独妥善保管。load-unpacked 开发不需要私钥。

## Phase 0 待办

`/api/organizations/{id}/usage` 的真实响应 schema 未文档化。首次装好后,查看
`~/.config/usage-bar/claude-web.json` 的 `usage` 字段即为真实响应,据此定稿 app 侧
`ClaudeWebUsageMapper`(当前为 best-effort 猜测映射)。
