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

public struct ProviderUsageSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: Provider { provider }

    public let provider: Provider
    public let updatedAt: Date
    public let sourceLabel: String
    public let identitySummary: String?
    public let planName: String?
    public let accountDisplayName: String?
    public let accountOptions: [Account]
    public let selectedAccountID: String?
    public let windows: [UsageWindowSnapshot]
    public let creditsText: String?
    public let costRows: [ProviderUsageCostSnapshot]
    public let notice: String?

    public init(
        provider: Provider,
        updatedAt: Date,
        sourceLabel: String,
        identitySummary: String? = nil,
        planName: String? = nil,
        accountDisplayName: String? = nil,
        accountOptions: [Account] = [],
        selectedAccountID: String? = nil,
        windows: [UsageWindowSnapshot] = [],
        creditsText: String? = nil,
        costRows: [ProviderUsageCostSnapshot] = [],
        notice: String? = nil
    ) {
        self.provider = provider
        self.updatedAt = updatedAt
        self.sourceLabel = sourceLabel
        self.identitySummary = identitySummary
        self.planName = planName
        self.accountDisplayName = accountDisplayName
        self.accountOptions = accountOptions
        self.selectedAccountID = selectedAccountID
        self.windows = windows
        self.creditsText = creditsText
        self.costRows = costRows
        self.notice = notice
    }
}

public enum UsageRefreshState: String, Codable, Sendable, Hashable {
    case idle
    case loading
    case loaded
    case failed
}
