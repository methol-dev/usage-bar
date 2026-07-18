import Foundation

// 进程入口分流。
//
// 正常启动 → SwiftUI 菜单栏 app(`UsageBarApp.main()`)。
// Chrome Native Messaging 会经 bundle 内 wrapper `usagebar-native-host` 以 `--native-host`
// 拉起本 binary(Chrome 只能追加 argv[1]=扩展 origin,无法注入自定义 flag,故由 wrapper 补 flag);
// 该模式下只跑 stdio 消息循环、绝不初始化 AppKit(否则会起菜单栏 UI / 进 dock)。
if CommandLine.arguments.contains("--native-host") {
    ClaudeWebNativeHost.run()
    exit(0)
}

UsageBarApp.main()
