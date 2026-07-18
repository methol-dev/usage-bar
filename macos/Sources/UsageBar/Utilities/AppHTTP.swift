/// 各 provider 客户端共用的 HTTP 常量。
enum AppHTTP {
    /// 诚实 User-Agent，三个 provider 统一发这个值。Claude 用量端点按 UA 分桶限流
    /// （见 `UsageService.performAuthorizedRequest` 的注释），如需调整必须三处同步 —— 收敛为单一常量。
    static let userAgent = "usage-bar"
}
