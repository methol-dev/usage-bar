# UsageBar — Claude Web Usage 扩展

在**用户自己已登录的 claude.ai 会话**里读取订阅用量,经 Chrome Native Messaging 交给 UsageBar
菜单栏 app。cookie 全程留在浏览器,扩展不读取、不导出任何凭证。

## 工作原理

```
自动触发:周期 alarm(默认 5min)+ 打开/切到 claude.ai 标签页 + 浏览器获焦
  (全部经 60s 去抖门汇流,手动「Sync now」强制绕过)
  → 在已打开的 claude.ai 标签页上下文里 fetch /api/organizations/{id}/usage(真同源,浏览器自动带 cookie)
  → chrome.runtime.sendNativeMessage 交给 host "com.tuzhihao.usagebar.host"
  → host(UsageBar.app 主 binary,Chrome 以 argv[1]=扩展 origin 拉起进 host 模式)原子写 ~/.config/usage-bar/claude-web.json
  → UsageBar 菜单栏 app 读该文件,显示 Claude Web tab
```

同步是**自动**的 —— 装好并保持一个 claude.ai 标签页登录后通常无需手动点。popup 显示「上次同步」时间;
「Sync now」按钮用于强制立即同步一次。

## 安装(开发 / 自用,load unpacked)

1. 先运行一次 UsageBar.app —— 它会安装 native messaging host manifest 到
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.tuzhihao.usagebar.host.json`。
2. Chrome → `chrome://extensions` → 打开右上角 **Developer mode** → **Load unpacked** → 选本 `extension/` 目录。
3. 扩展 id 应为 `aaehoepakaalddpmbhljnhlbbigioeid`(由 `manifest.json` 的固定 `key` 决定;host manifest
   的 `allowed_origins` 已写死该 id)。若不一致,说明 `key` 被改过,需同步更新
   `NativeHostInstaller.extensionID`。
4. 保持一个 claude.ai 标签页登录状态。点扩展图标 → **Sync now** 可手动触发一次。
5. UsageBar 里启用 **Claude Web** provider(Settings → Providers),即可看到 tab。

## 隐私 / 合规

- 扩展**不请求 `cookies` 权限**,不读 `document.cookie`,不导出任何凭证。
- 请求由用户浏览器在真实登录会话里发出(content-script 注入,真正同源),不冒充任何客户端。
- 交给 app 的 payload 仅 `{status, ts, usage?, error?}` —— 用量数字 + 状态(失败时 `error` 是净化过的
  错误类别,无 URL / 响应体 / 凭证)。全程无凭证。
- claude.ai 网页用量接口未文档化,属灰区;见 `docs/adr/0009-claude-web-usage-source.md`。

## 私钥

`manifest.json` 的 `key` 是**公钥**,可入库。对应**私钥**不入库(用于日后 Web Store 打包的 `.crx`
签名),需单独妥善保管。load-unpacked 开发不需要私钥。

## Phase 0 待办

`/api/organizations/{id}/usage` 的真实响应 schema 未文档化。首次装好后,查看
`~/.config/usage-bar/claude-web.json` 的 `usage` 字段即为真实响应,据此定稿 app 侧
`ClaudeWebUsageMapper`(当前为 best-effort 猜测映射)。
