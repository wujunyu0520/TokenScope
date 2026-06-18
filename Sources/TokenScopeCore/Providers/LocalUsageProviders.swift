import Foundation

public struct ClaudeCodeUsageProvider: UsageStatsProvider {
    public let provider: Provider = .claudeCode
    private let sessions: [SessionRecord]

    public init(sessions: [SessionRecord]) {
        self.sessions = sessions.filter { $0.provider == .claudeCode }
    }

    public func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        let scoped = sessions.sorted { $0.startedAt > $1.startedAt }
        let latest = scoped.first
        let totalUsage = scoped.reduce(TokenUsage.zero) { $0 + $1.totalUsage }
        let weekSessions = scoped.filter {
            $0.startedAt >= Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        }
        let weekUsage = weekSessions.reduce(TokenUsage.zero) { $0 + $1.totalUsage }
        let latestUsage = latest?.totalUsage ?? .zero

        let windows = [
            UsageWindowSnapshot(
                id: "all-time",
                title: CoreL10n.string("All sessions"),
                usedValue: totalUsage.totalTokens,
                limitValue: nil,
                unitLabel: CoreL10n.string("tokens"),
                usedPercent: 0,
                resetsAt: nil,
                resetDescription: CoreL10n.string("Local history")
            ),
            UsageWindowSnapshot(
                id: "last-7d",
                title: CoreL10n.string("Last 7 days"),
                usedValue: weekUsage.totalTokens,
                limitValue: nil,
                unitLabel: CoreL10n.string("tokens"),
                usedPercent: 0,
                resetsAt: nil,
                resetDescription: CoreL10n.string("Rolling")
            ),
            UsageWindowSnapshot(
                id: "latest-session",
                title: CoreL10n.string("Latest session"),
                usedValue: latestUsage.totalTokens,
                limitValue: nil,
                unitLabel: CoreL10n.string("tokens"),
                usedPercent: 0,
                resetsAt: latest?.endedAt,
                resetDescription: latest.map { $0.endedAt.formatted(date: .abbreviated, time: .shortened) }
            )
        ]

        return ProviderUsageSnapshot(
            provider: .claudeCode,
            updatedAt: Date(),
            sourceLabel: CoreL10n.string("Local sessions"),
            identitySummary: latest?.projectPath?.components(separatedBy: "/").last,
            planName: nil,
            windows: windows,
            notice: scoped.isEmpty ? CoreL10n.string("No Claude Code sessions found.") : nil
        )
    }
}

public struct CodexUsageProvider: UsageStatsProvider {
    public let provider: Provider = .codex

    private let sessions: [SessionRecord]
    private let usageRecords: [UsageRecord]
    private let priceBook: PriceBook
    private let accounts: [CodexManagedAccount]
    private let activeSource: CodexActiveSource
    private let environment: [String: String]

    public init(
        sessions: [SessionRecord],
        usageRecords: [UsageRecord],
        priceBook: PriceBook,
        accounts: [CodexManagedAccount],
        activeSource: CodexActiveSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.sessions = sessions.filter { $0.provider == .codex }
        self.usageRecords = usageRecords.filter { $0.provider == .codex }
        self.priceBook = priceBook
        self.accounts = accounts
        self.activeSource = activeSource
        self.environment = environment
    }

    public func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        let scopedEnv = CodexHomeScope.scopedEnvironment(base: environment, codexHome: selectedAccount?.managedHomePath)
        var credentials = try CodexOAuthCredentialsStore.load(env: scopedEnv)
        if credentials.needsRefresh {
            credentials = try await CodexTokenRefresher.refresh(credentials)
            try CodexOAuthCredentialsStore.save(credentials, env: scopedEnv)
        }

        let response = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: credentials.accessToken,
            accountId: credentials.accountId,
            env: scopedEnv
        )
        let oauthSnapshot = CodexOAuthSnapshotBuilder.build(response: response, credentials: credentials)
        let costRows = buildCostRows(selectedAccount: selectedAccount, oauthIdentity: oauthSnapshot.identity)
        let accountOptions = [
            Account(id: "live-system", provider: .codex, identifier: "live-system", displayName: CoreL10n.string("System account"))
        ] + accounts.map {
            Account(id: $0.id.uuidString, provider: .codex, identifier: $0.providerAccountID ?? $0.email, displayName: $0.email)
        }

        return ProviderUsageSnapshot(
            provider: .codex,
            updatedAt: oauthSnapshot.updatedAt,
            sourceLabel: selectedAccount == nil ? CoreL10n.string("OAuth · System account") : CoreL10n.string("OAuth · Added account"),
            identitySummary: oauthSnapshot.identity.email,
            planName: oauthSnapshot.identity.planName?.capitalized,
            accountDisplayName: selectedAccount?.email ?? oauthSnapshot.identity.email ?? CoreL10n.string("System account"),
            accountOptions: accountOptions,
            selectedAccountID: selectedAccount.map { $0.id.uuidString } ?? "live-system",
            windows: oauthSnapshot.windows,
            creditsText: oauthSnapshot.creditsText,
            costRows: costRows,
            notice: oauthSnapshot.windows.isEmpty ? CoreL10n.string("No Codex usage window returned.") : nil
        )
    }

    private var selectedAccount: CodexManagedAccount? {
        guard case let .managedAccount(id) = activeSource else { return nil }
        return accounts.first { $0.id == id }
    }

    private func buildCostRows(selectedAccount: CodexManagedAccount?, oauthIdentity: CodexOAuthIdentity) -> [ProviderUsageCostSnapshot] {
        let filtered = filterUsageRecords(selectedAccount: selectedAccount, oauthIdentity: oauthIdentity)
        guard !filtered.isEmpty else { return [] }

        let aggregator = UsageAggregator(priceBook: priceBook)
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let last30Start = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        let todayTotals = aggregator.totals(records: filtered, filter: AggregationFilter(dateRange: todayStart...todayEnd))
        let last30Totals = aggregator.totals(records: filtered, filter: AggregationFilter(dateRange: last30Start...todayEnd))

        return [
            ProviderUsageCostSnapshot(
                title: CoreL10n.string("Today"),
                amountText: currency(todayTotals.costUSD),
                detailText: tokenCount(todayTotals.usage.totalTokens)
            ),
            ProviderUsageCostSnapshot(
                title: CoreL10n.string("Last 30 days"),
                amountText: currency(last30Totals.costUSD),
                detailText: tokenCount(last30Totals.usage.totalTokens)
            ),
        ]
    }

    private func filterUsageRecords(selectedAccount: CodexManagedAccount?, oauthIdentity: CodexOAuthIdentity) -> [UsageRecord] {
        if let selectedAccountID = selectedAccount?.id.uuidString {
            let matched = usageRecords.filter { $0.accountId == selectedAccountID }
            if !matched.isEmpty { return matched }
        }

        if let providerAccountID = oauthIdentity.providerAccountID {
            let matchedSessions = sessions.filter { $0.accountId == providerAccountID }.map(\.id)
            if !matchedSessions.isEmpty {
                return usageRecords.filter { matchedSessions.contains($0.sessionId) }
            }
        }

        if let email = selectedAccount?.email ?? oauthIdentity.email {
            let matchedSessions = sessions.filter { session in
                session.projectPath?.localizedCaseInsensitiveContains(email) == true || session.sourceFile.path.localizedCaseInsensitiveContains(email)
            }.map(\.id)
            if !matchedSessions.isEmpty {
                return usageRecords.filter { matchedSessions.contains($0.sessionId) }
            }
        }

        return usageRecords
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func tokenCount(_ value: Int) -> String {
        CoreL10n.string("%@ tokens", value.formatted())
    }
}
