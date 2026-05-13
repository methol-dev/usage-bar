import Foundation
import Combine
import CryptoKit
import AppKit
@MainActor
class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var isAuthenticated = false
    @Published var isAwaitingCode = false
    @Published private(set) var accountEmail: String?
    // v0.1.3 multi-account (G3-B3/G2-B1: race fix via epoch + currentFetchTask)
    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var activeAccountId: UUID?
    private var accountSwitchEpoch: Int = 0
    private var currentFetchTask: Task<Void, Never>?

    // v0.2.5: 窄化成协议，便于单测注入 spy（实参仍是 UsageHistoryService / NotificationService）
    var historyService: HistoryRecording?
    var notificationService: UsageNotifying?

    /// v0.2.5 多供应商抽象：Claude provider 的 UI 状态容器（每次 fetch 后镜像写入）。
    let runtime: ProviderRuntime
    private var runtimeAuthSync: AnyCancellable?

    private let usageStats: UsageStatsService
    private let session: URLSession
    private let usageEndpoint: URL
    private let userinfoEndpoint: URL
    private let tokenEndpoint: URL
    private let credentialsStore: StoredCredentialsStore
    private let localProfileLoader: @MainActor () -> String?
    /// v0.2.7：refresh 永久失败时回退去读 Claude CLI Keychain（fail-silent，不弹 ACL）。`internal` 是为单测可替换。
    var cliKeychainLoader: () async -> StoredCredentials? = {
        try? await ClaudeCLICredentialsStrategy().loadCredentials(allowInteraction: false)
    }
    /// 429 backoff 状态：`currentBackoffSeconds` = 当前 backoff 时长（0 = 不在 backoff，用于指数递增）；`backoffUntil` = 「这之前别再拉」的截止时刻。
    /// v0.2.11：取代原 `currentInterval`（自持 timer 退役后，「下次拉的间隔」由 `ProviderCoordinator` 的统一 timer 负责）。
    private var currentBackoffSeconds: TimeInterval = 0
    private var backoffUntil: Date?
    /// 后台 tick 时额外回调（驱动 Claude 的本机用量统计刷新；装配处设成 `{ Task.detached { await usageStats.refresh() } }`）。
    var onPollTick: (@MainActor () -> Void)?
    /// `UsageProvider.nextEligibleRefresh` —— coordinator 的统一 timer 在 backoff 窗口内会跳过本 provider。
    var nextEligibleRefresh: Date? { backoffUntil }
    private enum RefreshResult {
        case success
        case permanentFailure
        case transientFailure
    }

    private var refreshTask: Task<RefreshResult, Never>?

    static let defaultPollingMinutes = 30
    static let pollingOptions = [5, 15, 30, 60]
    nonisolated static let maxBackoffInterval: TimeInterval = 60 * 60
    nonisolated static let defaultOAuthScopes = ["user:profile", "user:inference"]
    nonisolated private static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    nonisolated private static let defaultUsageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated private static let defaultUserinfoEndpoint = URL(string: "https://api.anthropic.com/api/oauth/userinfo")!
    nonisolated private static let defaultTokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    nonisolated private static let defaultRedirectURI = "https://platform.claude.com/oauth/code/callback"

    @Published private(set) var pollingMinutes: Int

    func updatePollingInterval(_ minutes: Int) {
        pollingMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "pollingMinutes")
        // 后台轮询的 recurring 由 ProviderCoordinator 的统一 timer 负责 —— 它监听 `pollingMinutes` 的 UserDefaults 变化自动重起；
        // 这里只额外立即拉一次（持有 currentFetchTask 供 switchAccount cancel）。
        if isAuthenticated { currentFetchTask = Task { [weak self] in await self?.fetchUsage() } }
    }

    private var baseInterval: TimeInterval { TimeInterval(pollingMinutes * 60) }

    nonisolated static func backoffInterval(
        retryAfter: TimeInterval?,
        currentInterval: TimeInterval
    ) -> TimeInterval {
        min(max(retryAfter ?? currentInterval, currentInterval * 2), maxBackoffInterval)
    }

    // OAuth constants
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectUri: String

    // PKCE state (lives only during an auth flow)
    private var codeVerifier: String?
    private var oauthState: String?

    // `usage` 现在只供 UsageService 内部用（reconcile + 下面三个便捷比例 + mapToSnapshot 经由 asProviderSnapshot()）；
    // UI 层读 `runtime.snapshot`（v0.2.5 多供应商重构）。
    var pct5h: Double { (usage?.fiveHour?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.sevenDay?.utilization ?? 0) / 100.0 }
    var pctExtra: Double { (usage?.extraUsage?.utilization ?? 0) / 100.0 }

    init(
        session: URLSession = .shared,
        usageEndpoint: URL = UsageService.defaultUsageEndpoint,
        userinfoEndpoint: URL = UsageService.defaultUserinfoEndpoint,
        tokenEndpoint: URL = UsageService.defaultTokenEndpoint,
        redirectUri: String = UsageService.defaultRedirectURI,
        credentialsStore: StoredCredentialsStore = StoredCredentialsStore(),
        localProfileLoader: @MainActor @escaping () -> String? = UsageService.loadLocalProfile,
        usageStats: UsageStatsService = .shared
    ) {
        self.usageStats = usageStats
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectUri = redirectUri
        self.credentialsStore = credentialsStore
        self.localProfileLoader = localProfileLoader
        let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
        let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
        self.pollingMinutes = minutes
        // v0.1.3: 用 loadAccounts 替代 loadCredentials；自动迁移旧 v1 文件
        if let file = credentialsStore.loadAccounts(defaultScopes: Self.defaultOAuthScopes) {
            self.accounts = file.accounts
            self.activeAccountId = file.activeAccount?.id
            self.isAuthenticated = !file.accounts.isEmpty
        } else {
            self.accounts = []
            self.activeAccountId = nil
            self.isAuthenticated = false
        }
        self.runtime = ProviderRuntime()
        // 保持 runtime.isConfigured 与 isAuthenticated 同步（@Published 订阅时会立刻发当前值）
        self.runtimeAuthSync = self.$isAuthenticated.sink { [runtime] authed in
            runtime.setConfigured(authed)
        }
    }

    // MARK: - Bootstrap from Claude CLI Keychain (v0.1.1)

    /// 启动期一次性尝试从 Claude CLI Keychain 复用凭证。
    /// - 已有 credentials.json：跳过（不覆盖用户主动 sign-in 的状态）
    /// - Keychain 不可读 / 解析失败：静默降级（行为退化为 v0.1.0，走原 sign-in）
    /// - SC7 安全约束：错误日志仅打印 LoadError case 名（CustomStringConvertible 已脱敏），
    ///   绝不打印 raw credential 值。
    @MainActor
    func bootstrapFromCLIIfNeeded() async {
        // 迁移：剥离已存账号中从 CLI Keychain 复制的 refresh_token（issue #22 修复）
        await migrateStripCLIRefreshToken()
        if !accounts.isEmpty { return }  // 已有任意 account 则不覆盖
        let strategy = ClaudeCLICredentialsStrategy()
        do {
            guard let creds = try await strategy.loadCredentials() else { return }
            // 只取 access_token；不持有 CLI 的 refresh_token，避免触发 OAuth Token Rotation
            // 导致 Claude Code 被迫退出登录（issue #22）。
            try saveCredentials(creds.strippingRefreshToken())
            isAuthenticated = true
        } catch {
            NSLog("[usage-bar] credentials bootstrap from CLI failed: \(error)")
        }
    }

    /// 启动期迁移：剥离历史版本从 CLI Keychain 复制来的 refresh_token（issue #22）。
    /// 检测方式：读取当前 CLI Keychain refresh_token，若与存储账号 refresh_token 相同则判定为
    /// CLI 来源并剥离。JWT 熵足够大，实践中与 PKCE 自有 RT 碰撞概率极低；
    /// 若需语义精确区分，应为 StoredAccount 添加 source 字段（留待后续 issue）。
    private func migrateStripCLIRefreshToken() async {
        guard !accounts.isEmpty else { return }
        guard let keychainCreds = await cliKeychainLoader(),
              let keychainRT = keychainCreds.refreshToken, !keychainRT.isEmpty else { return }

        var changed = false
        var newAccounts = accounts
        for i in newAccounts.indices where newAccounts[i].credentials.refreshToken == keychainRT {
            newAccounts[i].credentials = newAccounts[i].credentials.strippingRefreshToken()
            changed = true
        }
        guard changed else { return }

        // 从磁盘读取 activeIndex，避免 in-memory activeAccountId 为 nil 时回退到 0 导致账号错位
        guard let existingFile = credentialsStore.loadAccounts(defaultScopes: Self.defaultOAuthScopes) else { return }
        let file = StoredAccountsFile(version: existingFile.version, activeIndex: existingFile.activeIndex, accounts: newAccounts)
        try? credentialsStore.saveAccounts(file)
        let activeIdx = existingFile.clampedActiveIndex ?? 0
        if activeIdx < newAccounts.count {
            try? credentialsStore.save(newAccounts[activeIdx].credentials)
        }
        accounts = newAccounts
    }

    // MARK: - Multi-account (v0.1.3)

    /// 切换 active account。G2-B1/G3-B3 race fix：先 cancel 在飞 task + refreshTask + epoch++。
    /// v0.1.3 双写设计：把新 active account 的 credentials 写入 v1 credentials.json（mirror）
    /// G5 B2: 双写原子性 — saveAccounts 成功后 v1 save 失败时回滚 accounts.json，避免 v1/v2 持久分歧
    func switchAccount(to id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[idx].id != activeAccountId else { return }

        // race fix：cancel 旧 task + bump epoch
        currentFetchTask?.cancel()
        currentFetchTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        accountSwitchEpoch += 1

        // G5 B2: 双写原子性保护
        let oldAccountsFileSnapshot: StoredAccountsFile? = StoredAccountsFile(
            version: 2,
            activeIndex: accounts.firstIndex(where: { $0.id == activeAccountId }) ?? 0,
            accounts: accounts
        )
        var file = StoredAccountsFile(version: 2, activeIndex: idx, accounts: accounts)
        file.accounts[idx].lastUsed = Date()
        do {
            try credentialsStore.saveAccounts(file)
            // 双写：把新 active account 的 credentials 写到 v1 credentials.json
            do {
                try credentialsStore.save(file.accounts[idx].credentials)
            } catch {
                // v1 失败：回滚 accounts.json activeIndex 到旧值，避免持久分歧
                if let old = oldAccountsFileSnapshot {
                    try? credentialsStore.saveAccounts(old)
                }
                NSLog("[usage-bar] switchAccount v1 save: \(type(of: error)) — rolled back")
                return
            }
        } catch {
            NSLog("[usage-bar] switchAccount accounts save: \(type(of: error))")
            return
        }
        self.accounts = file.accounts
        self.activeAccountId = file.accounts[idx].id

        // 清前账号瞬态状态（SC8）
        self.usage = nil
        self.lastError = nil
        self.runtime.clear()
        // 本机 JSONL 统计是跨账号的，不随账号清/重算（spec 2026-05-12 §5 风险12）
        self.accountEmail = nil

        // 立即拉一次新账号的用量（持有 currentFetchTask 供下次 switchAccount cancel）；recurring 由 coordinator 的统一 timer。
        currentFetchTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchUsage()
            if self.accountEmail == nil { await self.fetchProfile() }
        }
    }

    /// 触发 PKCE flow 添加新账号。保持 active 不变；UI 通过 isAwaitingCode 切到 CodeEntry。
    func beginAddAccount() {
        startOAuthFlow()  // G3-B1: 实际函数名（不是 startSignInFlow）
    }

    // MARK: - Polling
    //
    // v0.2.11：自持 `Timer` 退役 —— 后台轮询的 recurring 由 `ProviderCoordinator` 的统一 timer 管（间隔 = `pollingMinutes`，
    // 监听 UserDefaults 变化重起）；每个 tick coordinator 会调 `refreshNow()`（跳过 `nextEligibleRefresh` 还在未来的）+ `onPollTick?()`。
    // 「立即拉一次」散到各调用点（`switchAccount` / `addAccount` / `updatePollingInterval` / 装配处的 `coordinator.startBackgroundPolling()` 立即 tick）。

    // MARK: - OAuth PKCE Flow

    func startOAuthFlow() {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateCodeVerifier() // random state

        codeVerifier = verifier
        oauthState = state

        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: Self.defaultOAuthScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
            isAwaitingCode = true
        }
    }

    func submitOAuthCode(_ rawCode: String) async {
        // Response format: "code#state" — parse it
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        let code = String(parts[0])

        if parts.count > 1 {
            let returnedState = String(parts[1])
            guard returnedState == oauthState else {
                lastError = "OAuth state mismatch — try again"
                isAwaitingCode = false
                codeVerifier = nil
                oauthState = nil
                return
            }
        }

        guard let verifier = codeVerifier else {
            lastError = "No pending OAuth flow"
            isAwaitingCode = false
            return
        }

        // Exchange code for token
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": oauthState ?? "",
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "code_verifier": verifier,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid token response"
                return
            }
            guard http.statusCode == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                lastError = "Token exchange failed: HTTP \(http.statusCode) \(bodyStr)"
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credentials = credentials(from: json) else {
                lastError = "Could not parse token response"
                return
            }

            // G3-B1: 抽出的 completeSignIn helper 处理首次 sign-in vs add-account 两种路径
            await completeSignIn(with: credentials)
        } catch {
            lastError = "Token exchange error: \(error.localizedDescription)"
        }
    }

    /// 完成 OAuth code 兑换 token 后的统一收尾。
    /// - accounts.isEmpty: 建第一个 account（保留 v0.1.0~v0.1.2 行为）
    /// - 否则：append 新 account + activeIndex 切到新（v0.1.3 add-account 路径）
    private func completeSignIn(with credentials: StoredCredentials) async {
        let now = Date()
        let isFirst = accounts.isEmpty
        let newAccount = StoredAccount(
            id: UUID(),
            label: "账号 \(accounts.count + 1)",
            addedAt: now,
            lastUsed: now,
            credentials: credentials
        )
        let newAccounts = accounts + [newAccount]
        let newIdx = newAccounts.count - 1
        let file = StoredAccountsFile(version: 2, activeIndex: newIdx, accounts: newAccounts)
        // G5 B2: 双写原子性 — completeSignIn (add account) 路径快照旧 accounts state for rollback
        let oldSnapshot: StoredAccountsFile?
        if !isFirst, let oldActiveIdx = accounts.firstIndex(where: { $0.id == activeAccountId }) {
            oldSnapshot = StoredAccountsFile(version: 2, activeIndex: oldActiveIdx, accounts: accounts)
        } else {
            oldSnapshot = nil
        }
        // G5 fallback R2: cancel 旧 task + bump epoch **必须在 save 之前**，
        // 避免 in-flight performRefresh 在 saveAccounts 与 epoch++ 之间完成时
        // 用旧 refresh token 覆盖刚写的新 active account 的 v1 credentials.json
        if !isFirst {
            currentFetchTask?.cancel()
            currentFetchTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            accountSwitchEpoch += 1
            // 清前账号瞬态
            self.usage = nil
            self.lastError = nil
            self.runtime.clear()
            // 本机 JSONL 统计是跨账号的，不随账号清/重算（spec 2026-05-12 §5 风险12）
            self.accountEmail = nil
        }
        do {
            try credentialsStore.saveAccounts(file)
            do {
                try credentialsStore.save(credentials)  // 双写：v1 credentials.json mirror 新 active token
            } catch {
                if let old = oldSnapshot {
                    try? credentialsStore.saveAccounts(old)
                } else {
                    credentialsStore.deleteAccounts()  // 首次 sign-in 失败时清除半成品
                }
                lastError = "Failed to save credentials: \(error.localizedDescription)"
                return
            }
        } catch {
            lastError = "Failed to save credentials: \(error.localizedDescription)"
            return
        }
        self.accounts = newAccounts
        self.activeAccountId = newAccount.id
        self.isAuthenticated = true
        self.isAwaitingCode = false
        self.lastError = nil
        self.codeVerifier = nil
        self.oauthState = nil

        await fetchProfile()
        // 立即拉一次（profile 上面已取，不用再 if accountEmail == nil）；recurring 由 coordinator 的统一 timer。
        currentFetchTask = Task { [weak self] in await self?.fetchUsage() }
    }

    func signOut() {
        // v0.1.3: signOut 清除全部 accounts（v0.2.x 留位 per-account sign-out）
        credentialsStore.deleteAccounts()
        deleteCredentials()
        accounts = []
        activeAccountId = nil
        accountSwitchEpoch += 1
        currentFetchTask?.cancel()
        currentFetchTask = nil
        isAuthenticated = false
        usage = nil
        lastUpdated = nil
        accountEmail = nil
        backoffUntil = nil
        currentBackoffSeconds = 0
        refreshTask?.cancel()
        refreshTask = nil
        lastError = nil
        runtime.clear()
        // G5 R1: 清 OAuth 中间态（避免 sign out 期间正在 add account 的状态残留）
        isAwaitingCode = false
        codeVerifier = nil
        oauthState = nil
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    // MARK: - API Fetch

    func fetchUsage() async {
        // G2-B1/G3-B3: 入口捕获 epoch；写值前比对若已变 → 丢弃响应（账号已切换）
        let epochAtStart = accountSwitchEpoch
        guard loadCredentials() != nil else {
            lastError = "Not signed in"
            isAuthenticated = false
            runtime.setError("Not signed in", clearSnapshot: true)
            return
        }

        do {
            guard let result = try await sendAuthorizedRequest(to: usageEndpoint) else {
                // sendAuthorizedRequest 返回 nil 时已设好 self.lastError（"Not signed in" /
                // refresh 失败 / session 过期）—— 把它镜像到 runtime（凭证类失败由 expireSession 自己清 snapshot）
                if let err = lastError { runtime.setError(err, clearSnapshot: false) }
                return
            }
            // race guard：账号切换导致此响应已陈旧 → 丢弃
            guard accountSwitchEpoch == epochAtStart else { return }
            let (data, http) = result
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let prev = currentBackoffSeconds == 0 ? baseInterval : currentBackoffSeconds
                currentBackoffSeconds = Self.backoffInterval(retryAfter: retryAfter, currentInterval: prev)
                backoffUntil = Date().addingTimeInterval(currentBackoffSeconds)   // coordinator 的 tick 在此前会跳过本 provider
                lastError = "Rate limited — backing off to \(Int(currentBackoffSeconds))s"
                runtime.setError(lastError ?? "Rate limited", clearSnapshot: false)
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                runtime.setError("HTTP \(http.statusCode)", clearSnapshot: false)
                return
            }
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            let reconciled = decoded.reconciled(with: usage)
            usage = reconciled
            lastError = nil
            let now = Date()
            lastUpdated = now
            runtime.setSuccess(snapshot: reconciled.asProviderSnapshot(), at: now)
            historyService?.recordDataPoint(pct5h: pct5h, pct7d: pct7d)
            notificationService?.checkAndNotify(pct5h: pct5h, pct7d: pct7d, pctExtra: pctExtra)
            currentBackoffSeconds = 0      // 成功 → 清 backoff（下个 coordinator tick 就会正常 tick 本 provider）
            backoffUntil = nil
        } catch {
            // race guard：账号已切换则不写 lastError
            guard accountSwitchEpoch == epochAtStart else { return }
            lastError = error.localizedDescription
            runtime.setError(error.localizedDescription, clearSnapshot: false)
        }
    }

    // MARK: - Profile

    func fetchProfile() async {
        if let local = localProfileLoader() {
            accountEmail = local
            return
        }

        guard let result = try? await sendAuthorizedRequest(
            to: userinfoEndpoint,
            expireSessionOnAuthFailure: false
        ) else {
            return
        }
        let (data, http) = result
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let email = json["email"] as? String, !email.isEmpty {
            accountEmail = email
        } else if let name = json["name"] as? String, !name.isEmpty {
            accountEmail = name
        }
    }

    /// Try reading the email from Claude Code's local config as a fallback.
    nonisolated private static func loadLocalProfile() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else {
            return nil
        }
        if let email = account["emailAddress"] as? String, !email.isEmpty {
            return email
        }
        if let name = account["displayName"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    // MARK: - Credential storage (v0.1.3 双写镜像设计)
    //
    // 主路径：v1 credentials.json 始终是 active account token 的镜像（保持 v0.1.0~v0.1.2
    // single-account API 行为不变，所有现有测试不回归）。accounts.json 存 metadata
    // (id/label/addedAt/lastUsed) + activeIndex + 所有 accounts 完整 credentials 副本，
    // 用于 switchAccount 切换时从其他 account 读 token 写到 v1 credentials.json。

    /// 双写：先写 v1 credentials.json（主），再镜像更新 accounts.json[active]
    private func saveCredentials(_ credentials: StoredCredentials) throws {
        try credentialsStore.save(credentials)  // 主写 v1 (loadCredentials 读这里)
        if let activeId = activeAccountId,
           let idx = accounts.firstIndex(where: { $0.id == activeId }) {
            // 已有 active account：镜像更新
            var newAccounts = accounts
            newAccounts[idx].credentials = credentials
            newAccounts[idx].lastUsed = Date()
            let file = StoredAccountsFile(version: 2, activeIndex: idx, accounts: newAccounts)
            try? credentialsStore.saveAccounts(file)  // 镜像失败不阻塞主路径
            self.accounts = newAccounts
        } else if accounts.isEmpty {
            // bootstrap 首次：建第一个 account
            let first = StoredAccount(
                id: UUID(),
                label: "账号 1",
                addedAt: Date(),
                lastUsed: Date(),
                credentials: credentials
            )
            let file = StoredAccountsFile(version: 2, activeIndex: 0, accounts: [first])
            try? credentialsStore.saveAccounts(file)
            self.accounts = [first]
            self.activeAccountId = first.id
        }
    }

    /// 主读：v1 credentials.json（与现有 v0.1.0~v0.1.2 行为一致）
    private func loadCredentials() -> StoredCredentials? {
        credentialsStore.load(defaultScopes: Self.defaultOAuthScopes)
    }

    private func deleteCredentials() {
        credentialsStore.delete()
    }

    // MARK: - Authorized requests

    private func sendAuthorizedRequest(
        to url: URL,
        expireSessionOnAuthFailure: Bool = true
    ) async throws -> (Data, HTTPURLResponse)? {
        guard let initialCredentials = loadCredentials() else {
            lastError = "Not signed in"
            isAuthenticated = false
            return nil
        }

        if initialCredentials.needsRefresh() {
            let refreshResult = await refreshCredentials(force: true)
            if refreshResult != .success, initialCredentials.isExpired() {
                switch refreshResult {
                case .permanentFailure:
                    if expireSessionOnAuthFailure {
                        await expireSession()
                    }
                case .transientFailure:
                    lastError = "Token refresh failed — will retry"
                case .success:
                    break
                }
                return nil
            }
        }

        let activeCredentials = loadCredentials() ?? initialCredentials

        var result = try await performAuthorizedRequest(
            token: activeCredentials.accessToken,
            url: url
        )

        if result.1.statusCode != 401 {
            return result
        }

        let refreshResult = await refreshCredentials(force: true)
        switch refreshResult {
        case .success:
            guard let refreshedCredentials = loadCredentials() else {
                if expireSessionOnAuthFailure {
                    await expireSession()
                }
                return nil
            }

            result = try await performAuthorizedRequest(
                token: refreshedCredentials.accessToken,
                url: url
            )

            if result.1.statusCode == 401 {
                if expireSessionOnAuthFailure {
                    await expireSession()
                }
                return nil
            }

            return result

        case .permanentFailure:
            if expireSessionOnAuthFailure {
                await expireSession()
            }
            return nil

        case .transientFailure:
            lastError = "Token refresh failed — will retry"
            return nil
        }
    }

    private func performAuthorizedRequest(
        token: String,
        url: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private func refreshCredentials(force: Bool) async -> RefreshResult {
        if let refreshTask {
            return await refreshTask.value
        }

        let task = Task { [weak self] in
            guard let self else { return RefreshResult.permanentFailure }
            return await self.performRefresh(force: force)
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func performRefresh(force: Bool) async -> RefreshResult {
        // G2-B1: 入口捕获 epoch；refresh 完成后写 saveCredentials 前比对，避免污染新 active account
        let epochAtStart = accountSwitchEpoch
        guard let currentCredentials = loadCredentials(),
              let refreshToken = currentCredentials.refreshToken,
              refreshToken.isEmpty == false else {
            return .permanentFailure
        }

        if force == false, currentCredentials.needsRefresh() == false {
            return .success
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        if currentCredentials.scopes.isEmpty == false {
            body["scope"] = currentCredentials.scopes.joined(separator: " ")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure
            }
            data = responseData
            http = httpResponse
        } catch {
            return .transientFailure
        }

        guard http.statusCode == 200 else {
            if http.statusCode >= 400, http.statusCode < 500 {
                return .permanentFailure
            }
            return .transientFailure
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updatedCredentials = credentials(
                from: json,
                fallback: currentCredentials
              ) else {
            return .transientFailure
        }

        // G2-B1: 写值前 epoch 比对，避免账号切换后用旧 refresh token 污染新 active account
        guard accountSwitchEpoch == epochAtStart else {
            return .transientFailure  // 视为暂时失败，调用方走兜底
        }
        do {
            try saveCredentials(updatedCredentials)
        } catch {
            try? await Task.sleep(nanoseconds: 100_000_000)
            do {
                try saveCredentials(updatedCredentials)
            } catch {
                return .transientFailure
            }
        }

        isAuthenticated = true
        return .success
    }

    private func credentials(
        from json: [String: Any],
        fallback: StoredCredentials? = nil
    ) -> StoredCredentials? {
        guard let accessToken = json["access_token"] as? String, accessToken.isEmpty == false else {
            return nil
        }

        let scopeString = json["scope"] as? String
        let scopes = scopeString?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? fallback?.scopes ?? Self.defaultOAuthScopes

        return StoredCredentials(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? fallback?.refreshToken,
            expiresAt: Self.expirationDate(from: json["expires_in"]) ?? fallback?.expiresAt,
            scopes: scopes
        )
    }

    private static func expirationDate(from value: Any?) -> Date? {
        let seconds: TimeInterval?
        switch value {
        case let number as NSNumber:
            seconds = number.doubleValue
        case let number as Double:
            seconds = number
        case let number as Int:
            seconds = TimeInterval(number)
        case let string as String:
            seconds = TimeInterval(string)
        default:
            seconds = nil
        }

        guard let seconds else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    private func expireSession() async {
        // v0.2.7：硬过期前先试着从 Claude CLI Keychain 续上 —— 用户的 claude CLI 往往还在正常用，
        // 此时 Keychain 里有新鲜 token，没必要逼用户重登。能恢复就直接 return（下一轮 coordinator tick 自然用新 token）。
        if await attemptCLIKeychainRecovery() { return }
        deleteCredentials()
        isAuthenticated = false
        usage = nil
        lastUpdated = nil
        accountEmail = nil
        backoffUntil = nil
        currentBackoffSeconds = 0
        refreshTask?.cancel()
        refreshTask = nil
        lastError = "Session expired — please sign in again"
        runtime.setError("Session expired — please sign in again", clearSnapshot: true)
    }

    /// v0.2.7：refresh 永久失败时，试着从 Claude CLI Keychain 续上凭证。返回 true = 已恢复（调用方不要再硬过期）。
    /// 三道门：① 单账号（不冒险用别人的 token 覆盖某个非 active 账号）；② Keychain token ≠ 刚失败的那个（防恢复循环）；
    /// ③ Keychain token 未过期（不同但已过期的同样会推迟硬过期、变相循环）。
    private func attemptCLIKeychainRecovery() async -> Bool {
        guard accounts.count <= 1 else { return false }
        let current = loadCredentials()
        guard let recovered = await cliKeychainLoader() else { return false }
        guard recovered.accessToken != current?.accessToken else { return false }
        guard !recovered.isExpired() else { return false }
        do {
            // 只取 access_token；不持有 CLI 的 refresh_token，避免触发 OAuth Token Rotation（issue #22）。
            try saveCredentials(recovered.strippingRefreshToken())
            isAuthenticated = true
            lastError = nil
            runtime.clear()              // 抹掉上一轮 expireSession 残留的「Session expired」错误（那时 snapshot 已被 clearSnapshot 清空，clear() 安全）
            runtime.setConfigured(true)  // 注：上面 isAuthenticated = true 已经经 runtimeAuthSync sink 触发过 setConfigured(true)，这里幂等、显式
            return true
        } catch {
            return false
        }
    }
}

// MARK: - UsageProvider conformance (v0.2.5 multi-provider refactor)
//
// `UsageService` 就是 Claude 的 `UsageProvider` 实现（沿用全部 OAuth/refresh/多账号/429-backoff
// 内部逻辑）。`runtime` 是类体里的存储属性；`fetchUsage()` 在成功/失败时已镜像写它。
// v0.2.11：后台轮询的 recurring 由 `ProviderCoordinator` 的统一 timer 管（`UsageService` 不再自持 `Timer`）；
// `nextEligibleRefresh`（= `backoffUntil`）让 coordinator 在 429 backoff 窗口内跳过本 provider。

extension UsageService: UsageProvider {
    var id: ProviderID { .claude }
    var isConfigured: Bool { isAuthenticated }
    var supportsBackgroundPolling: Bool { true }

    /// 「拉一次」（popover Refresh 按钮 / coordinator 的后台 tick）。不做内部节流——Refresh 按钮就是要强制重拉。
    /// 顺带补一次 profile（账号 email）—— 原本在已退役的 `startPolling()` 里。
    func refreshNow() async {
        await fetchUsage()
        if accountEmail == nil { await fetchProfile() }
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
