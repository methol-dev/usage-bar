import Foundation

// 进程入口分流。
//
// 正常启动 → SwiftUI 菜单栏 app(`UsageBarApp.main()`)。
// Chrome Native Messaging 拉起本 binary 时,argv[1] = 调用方扩展 origin(`chrome-extension://<id>/`);
// 手动测试可传 `--native-host`。两者任一命中 → 只跑 stdio 消息循环、绝不初始化 AppKit(否则会起
// 菜单栏 UI / 进 dock)。检测 argv 而非靠 wrapper 补 flag —— 因为 Chrome 无法给 manifest path 注入
// 自定义 flag,而 bundle 内放第二个可执行文件会破坏 ad-hoc codesign(它要求 MacOS/ 下每个可执行都被签)。
let launchedAsNativeHost = CommandLine.arguments.dropFirst().contains {
    $0 == "--native-host" || $0.hasPrefix("chrome-extension://")
}
if launchedAsNativeHost {
    ClaudeWebNativeHost.run()
    exit(0)
}

UsageBarApp.main()
