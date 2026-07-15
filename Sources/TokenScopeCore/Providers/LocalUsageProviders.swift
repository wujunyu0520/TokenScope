import Foundation

public struct ClaudeCodeUsageProvider: UsageStatsProvider {
    public let provider: Provider = .claudeCode
    private let sessions: [SessionRecord]
    private let usageRecords: [UsageRecord]
    private let now: Date

    public init(
        sessions: [SessionRecord],
        usageRecords: [UsageRecord],
        now: Date = Date()
    ) {
        self.sessions = sessions.filter { $0.provider == .claudeCode }
        self.usageRecords = usageRecords.filter { $0.provider == .claudeCode }
        self.now = now
    }

    public func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        let scoped = sessions
            .filter { $0.messageCount > 0 && $0.totalUsage.totalTokens > 0 }
        let validSessionIDs = Set(scoped.map(\.id))
        let validRecords = usageRecords.filter {
            validSessionIDs.contains($0.sessionId) && $0.usage.totalTokens > 0
        }
        let recordsBySession = Dictionary(grouping: validRecords, by: \.sessionId)
        let latestActivityBySessionID = recordsBySession.reduce(into: [String: Date]()) { result, entry in
            result[entry.key] = entry.value.map(\.timestamp).max()
        }
        func latestActivityDate(for session: SessionRecord) -> Date {
            latestActivityBySessionID[session.id] ?? session.endedAt
        }
        let latest = scoped.max { lhs, rhs in
            let lhsActivity = latestActivityDate(for: lhs)
            let rhsActivity = latestActivityDate(for: rhs)
            if lhsActivity == rhsActivity {
                if lhs.startedAt == rhs.startedAt { return lhs.id < rhs.id }
                return lhs.startedAt < rhs.startedAt
            }
            return lhsActivity < rhsActivity
        }
        let latestActivityAt = latest.map(latestActivityDate)
        let totalUsage = scoped.reduce(TokenUsage.zero) { partial, session in
            guard let records = recordsBySession[session.id], !records.isEmpty else {
                return partial + session.totalUsage
            }
            return partial + records.reduce(TokenUsage.zero) { $0 + $1.usage }
        }
        let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let weekUsage = scoped.reduce(TokenUsage.zero) { partial, session in
            guard let records = recordsBySession[session.id], !records.isEmpty else {
                guard session.startedAt >= weekStart, session.startedAt <= now else { return partial }
                return partial + session.totalUsage
            }
            let usage = records
                .filter { $0.timestamp >= weekStart && $0.timestamp <= now }
                .reduce(TokenUsage.zero) { $0 + $1.usage }
            return partial + usage
        }
        let latestUsage = latest.map { latestSession in
            let records = recordsBySession[latestSession.id] ?? []
            return records.isEmpty
                ? latestSession.totalUsage
                : records.reduce(TokenUsage.zero) { $0 + $1.usage }
        } ?? .zero

        let windows = [
            UsageWindowSnapshot(
                id: "all-time",
                title: CoreL10n.string("All sessions"),
                kind: .tokenSummary,
                tokenUsage: totalUsage,
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
                kind: .tokenSummary,
                tokenUsage: weekUsage,
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
                kind: .tokenSummary,
                tokenUsage: latestUsage,
                usedValue: latestUsage.totalTokens,
                limitValue: nil,
                unitLabel: CoreL10n.string("tokens"),
                usedPercent: 0,
                resetsAt: nil,
                resetDescription: latestActivityAt?.formatted(date: .abbreviated, time: .shortened)
            )
        ]

        return ProviderUsageSnapshot(
            provider: .claudeCode,
            updatedAt: Date(),
            sourceLabel: CoreL10n.string("Local sessions"),
            identitySummary: latest?.projectPath?.components(separatedBy: "/").last,
            planName: nil,
            windows: windows,
            notice: scoped.isEmpty ? CoreL10n.string("No Claude Code sessions with usage found.") : nil
        )
    }
}

public struct OpenCodeUsageProvider: UsageStatsProvider {
    public let provider: Provider = .openCode

    private let sessions: [SessionRecord]
    private let usageRecords: [UsageRecord]
    private let priceBook: PriceBook
    private let databaseURL: URL?
    private let now: Date

    public init(
        sessions: [SessionRecord],
        usageRecords: [UsageRecord],
        priceBook: PriceBook = PriceBook(),
        databaseURL: URL? = OpenCodeSQLiteParser.defaultDatabaseURL,
        now: Date = Date()
    ) {
        self.sessions = sessions.filter { $0.provider == .openCode }
        self.usageRecords = usageRecords.filter { $0.provider == .openCode }
        self.priceBook = priceBook
        self.databaseURL = databaseURL
        self.now = now
    }

    public func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        let scoped = sessions
            .filter { $0.messageCount > 0 && $0.totalUsage.totalTokens > 0 }
        let validSessionIDs = Set(scoped.map(\.id))
        let validRecords = usageRecords.filter {
            validSessionIDs.contains($0.sessionId) && $0.usage.totalTokens > 0
        }
        let recordsBySession = Dictionary(grouping: validRecords, by: \.sessionId)
        let latestActivityBySessionID = recordsBySession.reduce(into: [String: Date]()) { result, entry in
            result[entry.key] = entry.value.map(\.timestamp).max()
        }
        func latestActivityDate(for session: SessionRecord) -> Date {
            latestActivityBySessionID[session.id] ?? session.endedAt
        }
        let latest = scoped.max { lhs, rhs in
            let lhsActivity = latestActivityDate(for: lhs)
            let rhsActivity = latestActivityDate(for: rhs)
            if lhsActivity == rhsActivity {
                if lhs.startedAt == rhs.startedAt { return lhs.id < rhs.id }
                return lhs.startedAt < rhs.startedAt
            }
            return lhsActivity < rhsActivity
        }
        let latestActivityAt = latest.map(latestActivityDate)
        let totalUsage = scoped.reduce(TokenUsage.zero) { partial, session in
            guard let records = recordsBySession[session.id], !records.isEmpty else {
                return partial + session.totalUsage
            }
            return partial + records.reduce(TokenUsage.zero) { $0 + $1.usage }
        }
        let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let weekUsage = scoped.reduce(TokenUsage.zero) { partial, session in
            guard let records = recordsBySession[session.id], !records.isEmpty else {
                guard session.startedAt >= weekStart, session.startedAt <= now else { return partial }
                return partial + session.totalUsage
            }
            let usage = records
                .filter { $0.timestamp >= weekStart && $0.timestamp <= now }
                .reduce(TokenUsage.zero) { $0 + $1.usage }
            return partial + usage
        }
        let latestUsage = latest.map { latestSession in
            let records = recordsBySession[latestSession.id] ?? []
            return records.isEmpty
                ? latestSession.totalUsage
                : records.reduce(TokenUsage.zero) { $0 + $1.usage }
        } ?? .zero

        let windows = [
            UsageWindowSnapshot(
                id: "all-time",
                title: CoreL10n.string("All sessions"),
                kind: .tokenSummary,
                tokenUsage: totalUsage,
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
                kind: .tokenSummary,
                tokenUsage: weekUsage,
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
                kind: .tokenSummary,
                tokenUsage: latestUsage,
                usedValue: latestUsage.totalTokens,
                limitValue: nil,
                unitLabel: CoreL10n.string("tokens"),
                usedPercent: 0,
                resetsAt: nil,
                resetDescription: latestActivityAt?.formatted(date: .abbreviated, time: .shortened)
            )
        ]

        return ProviderUsageSnapshot(
            provider: .openCode,
            updatedAt: Date(),
            sourceLabel: CoreL10n.string("Local SQLite"),
            identitySummary: latestProjectName(from: latest),
            planName: nil,
            windows: windows,
            modelBreakdowns: loadModelBreakdowns(validRecords: validRecords),
            notice: scoped.isEmpty ? CoreL10n.string("No OpenCode sessions with usage found.") : nil
        )
    }

    private func latestProjectName(from session: SessionRecord?) -> String? {
        guard let projectPath = session?.projectPath, !projectPath.isEmpty else { return nil }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    private func loadModelBreakdowns(validRecords: [UsageRecord]) -> [ProviderUsageBreakdown] {
        if let databaseURL,
           FileManager.default.fileExists(atPath: databaseURL.path),
           let breakdowns = try? OpenCodeSQLiteParser().modelBreakdowns(databaseURL: databaseURL),
           !breakdowns.isEmpty {
            let costsByModel = breakdownCosts(from: validRecords)
            return breakdowns
                .map { repricedBreakdown($0, costsByModel: costsByModel) }
                .sorted(by: sortBreakdowns)
        }
        return deriveModelBreakdowns(from: validRecords)
    }

    private struct BreakdownCost {
        var estimatedUSD = 0.0
        var coverage: PricingCoverage?

        mutating func add(_ estimate: CostEstimate) {
            estimatedUSD += estimate.estimatedUSD
            switch (coverage, estimate.coverage) {
            case (_, .unpriced):
                coverage = .unpriced
            case (.unpriced, _):
                break
            case (.priced, _), (_, .priced):
                coverage = .priced
            case (_, .free):
                coverage = .free
            }
        }
    }

    private func breakdownCosts(from records: [UsageRecord]) -> [String: BreakdownCost] {
        var costs: [String: BreakdownCost] = [:]
        for record in records where record.usage.totalTokens > 0 {
            let key = breakdownKey(providerID: record.accountId ?? "unknown", modelID: record.model)
            var cost = costs[key, default: BreakdownCost()]
            cost.add(priceBook.estimate(for: record))
            costs[key] = cost
        }
        return costs
    }

    private func deriveModelBreakdowns(from records: [UsageRecord]) -> [ProviderUsageBreakdown] {
        struct Accumulator {
            var providerID = "unknown"
            var modelID = "unknown"
            var sessionIDs: Set<String> = []
            var messageCount = 0
            var usage = TokenUsage.zero
            var cost = BreakdownCost()
        }

        var accumulators: [String: Accumulator] = [:]
        for record in records where record.usage.totalTokens > 0 {
            let providerID = record.accountId ?? "unknown"
            let key = breakdownKey(providerID: providerID, modelID: record.model)
            var accumulator = accumulators[key, default: Accumulator()]
            accumulator.providerID = providerID
            accumulator.modelID = record.model
            accumulator.sessionIDs.insert(record.sessionId)
            accumulator.messageCount += 1
            accumulator.usage += record.usage
            accumulator.cost.add(priceBook.estimate(for: record))
            accumulators[key] = accumulator
        }

        return accumulators.map { _, value in
            return ProviderUsageBreakdown(
                groupName: groupName(for: value.providerID),
                providerID: value.providerID,
                modelID: value.modelID,
                sessionCount: value.sessionIDs.count,
                messageCount: value.messageCount,
                inputTokens: value.usage.inputTokens,
                outputTokens: value.usage.outputTokens,
                reasoningTokens: 0,
                cacheReadTokens: value.usage.cacheReadTokens,
                cacheCreationTokens: value.usage.cacheCreationTokens,
                estimatedCostUSD: value.cost.estimatedUSD,
                pricingCoverage: value.cost.coverage ?? .unpriced
            )
        }
        .sorted(by: sortBreakdowns)
    }

    private func repricedBreakdown(
        _ breakdown: ProviderUsageBreakdown,
        costsByModel: [String: BreakdownCost]
    ) -> ProviderUsageBreakdown {
        let cost = costsByModel[
            breakdownKey(providerID: breakdown.providerID, modelID: breakdown.modelID)
        ] ?? BreakdownCost()
        return ProviderUsageBreakdown(
            groupName: breakdown.groupName,
            providerID: breakdown.providerID,
            modelID: breakdown.modelID,
            sessionCount: breakdown.sessionCount,
            messageCount: breakdown.messageCount,
            inputTokens: breakdown.inputTokens,
            outputTokens: breakdown.outputTokens,
            reasoningTokens: breakdown.reasoningTokens,
            cacheReadTokens: breakdown.cacheReadTokens,
            cacheCreationTokens: breakdown.cacheCreationTokens,
            estimatedCostUSD: cost.estimatedUSD,
            pricingCoverage: cost.coverage ?? .unpriced
        )
    }

    private func breakdownKey(providerID: String, modelID: String) -> String {
        "\(providerID.lowercased())\u{1f}\(modelID.lowercased())"
    }

    private func sortBreakdowns(_ lhs: ProviderUsageBreakdown, _ rhs: ProviderUsageBreakdown) -> Bool {
        let lhsRank = groupRank(lhs.groupName)
        let rhsRank = groupRank(rhs.groupName)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
    }

    private func groupName(for providerID: String) -> String {
        switch providerID {
        case "longcat":
            return "LongCat"
        case "deepseek":
            return "DeepSeek"
        case "kimi-for-coding":
            return "Kimi"
        default:
            return "OpenCode Other"
        }
    }

    private func groupRank(_ groupName: String) -> Int {
        switch groupName {
        case "LongCat":
            return 0
        case "DeepSeek":
            return 1
        case "Kimi":
            return 2
        default:
            return 3
        }
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
            providerAccountFingerprint: CodexAccountFingerprint.make(oauthSnapshot.identity.providerAccountID),
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
        let todayTotals = aggregator.costSummary(
            records: filtered,
            filter: AggregationFilter(dateRange: todayStart...todayEnd)
        )
        let last30Totals = aggregator.costSummary(
            records: filtered,
            filter: AggregationFilter(dateRange: last30Start...todayEnd)
        )

        return [
            ProviderUsageCostSnapshot(
                title: CoreL10n.string("Today"),
                amountText: currency(todayTotals.costUSD),
                detailText: tokenCount(todayTotals.usage.totalTokens),
                unpricedRecordCount: todayTotals.pricingCoverage.unpricedRecordCount,
                unpricedModels: todayTotals.pricingCoverage.unpricedModels
            ),
            ProviderUsageCostSnapshot(
                title: CoreL10n.string("Last 30 days"),
                amountText: currency(last30Totals.costUSD),
                detailText: tokenCount(last30Totals.usage.totalTokens),
                unpricedRecordCount: last30Totals.pricingCoverage.unpricedRecordCount,
                unpricedModels: last30Totals.pricingCoverage.unpricedModels
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
        CoreL10n.string("%@ tokens", TokenDisplayFormatter.hundredMillions(value))
    }
}
