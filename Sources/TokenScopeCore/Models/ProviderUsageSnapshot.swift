import Foundation

public enum UsageWindowKind: String, Codable, Sendable, Hashable {
    case quota
    case tokenSummary
}

public struct UsageWindowSnapshot: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let kind: UsageWindowKind
    public let tokenUsage: TokenUsage?
    public let usedValue: Int?
    public let limitValue: Int?
    public let unitLabel: String?
    public let usedPercent: Double
    public let reservePercent: Double?
    public let resetsAt: Date?
    public let resetDescription: String?

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    public var quotaResetDate: Date? {
        kind == .quota ? resetsAt : nil
    }

    public init(
        id: String,
        title: String,
        kind: UsageWindowKind = .quota,
        tokenUsage: TokenUsage? = nil,
        usedValue: Int? = nil,
        limitValue: Int? = nil,
        unitLabel: String? = nil,
        usedPercent: Double,
        reservePercent: Double? = nil,
        resetsAt: Date? = nil,
        resetDescription: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.tokenUsage = tokenUsage
        self.usedValue = usedValue
        self.limitValue = limitValue
        self.unitLabel = unitLabel
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.reservePercent = reservePercent.map { min(max($0, -100), 100) }
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

public struct ProviderUsageCostSnapshot: Codable, Sendable, Hashable {
    public let title: String
    public let amountText: String
    public let detailText: String?

    public init(title: String, amountText: String, detailText: String? = nil) {
        self.title = title
        self.amountText = amountText
        self.detailText = detailText
    }
}

public struct ProviderUsageBreakdown: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(providerID):\(modelID)" }

    public let groupName: String
    public let providerID: String
    public let modelID: String
    public let sessionCount: Int
    public let messageCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let costUSD: Double

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheCreationTokens
    }

    public init(
        groupName: String,
        providerID: String,
        modelID: String,
        sessionCount: Int,
        messageCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Double
    ) {
        self.groupName = groupName
        self.providerID = providerID
        self.modelID = modelID
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
    }
}

public struct ProviderUsageSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: Provider { provider }

    public let provider: Provider
    public let updatedAt: Date
    public let sourceLabel: String
    public let identitySummary: String?
    public let providerAccountFingerprint: String?
    public let planName: String?
    public let accountDisplayName: String?
    public let accountOptions: [Account]
    public let selectedAccountID: String?
    public let windows: [UsageWindowSnapshot]
    public let creditsText: String?
    public let costRows: [ProviderUsageCostSnapshot]
    public let modelBreakdowns: [ProviderUsageBreakdown]
    public let notice: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case updatedAt
        case sourceLabel
        case identitySummary
        case providerAccountFingerprint
        case planName
        case accountDisplayName
        case accountOptions
        case selectedAccountID
        case windows
        case creditsText
        case costRows
        case modelBreakdowns
        case notice
    }

    public init(
        provider: Provider,
        updatedAt: Date,
        sourceLabel: String,
        identitySummary: String? = nil,
        providerAccountFingerprint: String? = nil,
        planName: String? = nil,
        accountDisplayName: String? = nil,
        accountOptions: [Account] = [],
        selectedAccountID: String? = nil,
        windows: [UsageWindowSnapshot] = [],
        creditsText: String? = nil,
        costRows: [ProviderUsageCostSnapshot] = [],
        modelBreakdowns: [ProviderUsageBreakdown] = [],
        notice: String? = nil
    ) {
        self.provider = provider
        self.updatedAt = updatedAt
        self.sourceLabel = sourceLabel
        self.identitySummary = identitySummary
        self.providerAccountFingerprint = providerAccountFingerprint
        self.planName = planName
        self.accountDisplayName = accountDisplayName
        self.accountOptions = accountOptions
        self.selectedAccountID = selectedAccountID
        self.windows = windows
        self.creditsText = creditsText
        self.costRows = costRows
        self.modelBreakdowns = modelBreakdowns
        self.notice = notice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(Provider.self, forKey: .provider)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        self.identitySummary = try container.decodeIfPresent(String.self, forKey: .identitySummary)
        self.providerAccountFingerprint = try container.decodeIfPresent(String.self, forKey: .providerAccountFingerprint)
        self.planName = try container.decodeIfPresent(String.self, forKey: .planName)
        self.accountDisplayName = try container.decodeIfPresent(String.self, forKey: .accountDisplayName)
        self.accountOptions = try container.decodeIfPresent([Account].self, forKey: .accountOptions) ?? []
        self.selectedAccountID = try container.decodeIfPresent(String.self, forKey: .selectedAccountID)
        self.windows = try container.decodeIfPresent([UsageWindowSnapshot].self, forKey: .windows) ?? []
        self.creditsText = try container.decodeIfPresent(String.self, forKey: .creditsText)
        self.costRows = try container.decodeIfPresent([ProviderUsageCostSnapshot].self, forKey: .costRows) ?? []
        self.modelBreakdowns = try container.decodeIfPresent([ProviderUsageBreakdown].self, forKey: .modelBreakdowns) ?? []
        self.notice = try container.decodeIfPresent(String.self, forKey: .notice)
    }
}

public enum UsageRefreshState: String, Codable, Sendable, Hashable {
    case idle
    case loading
    case loaded
    case failed
}

public enum UsageDataStatus: Sendable, Equatable {
    case unavailable
    case cached(updatedAt: Date)
    case refreshing(previousUpdate: Date?)
    case current(updatedAt: Date)
    case stale(updatedAt: Date, message: String)
    case failed(message: String)

    public static func resolve(
        snapshot: ProviderUsageSnapshot?,
        refreshState: UsageRefreshState,
        errorMessage: String?
    ) -> UsageDataStatus {
        switch refreshState {
        case .idle:
            guard let snapshot else { return .unavailable }
            return .cached(updatedAt: snapshot.updatedAt)
        case .loading:
            return .refreshing(previousUpdate: snapshot?.updatedAt)
        case .loaded:
            guard let snapshot else { return .unavailable }
            return .current(updatedAt: snapshot.updatedAt)
        case .failed:
            let message = resolvedErrorMessage(errorMessage)
            guard let snapshot else { return .failed(message: message) }
            return .stale(updatedAt: snapshot.updatedAt, message: message)
        }
    }

    private static func resolvedErrorMessage(_ errorMessage: String?) -> String {
        guard let errorMessage, !errorMessage.isEmpty else {
            return CoreL10n.string("Unknown error")
        }
        return errorMessage
    }
}
