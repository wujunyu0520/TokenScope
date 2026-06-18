import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ZaiAPIRegion: String, Codable, CaseIterable, Sendable, Hashable {
    case global
    case bigmodelCN = "bigmodel-cn"

    private static let quotaPath = "api/monitor/usage/quota/limit"

    public var displayName: String {
        switch self {
        case .global:
            return "Global (api.z.ai)"
        case .bigmodelCN:
            return "BigModel CN (open.bigmodel.cn)"
        }
    }

    public var baseURLString: String {
        switch self {
        case .global:
            return "https://api.z.ai"
        case .bigmodelCN:
            return "https://open.bigmodel.cn"
        }
    }

    public var quotaLimitURL: URL {
        URL(string: baseURLString)!.appendingPathComponent(Self.quotaPath)
    }
}

public enum ZaiUsageError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return CoreL10n.string("z.ai API key is not configured.")
        case .invalidCredentials:
            return CoreL10n.string("Invalid z.ai API credentials.")
        case let .networkError(message):
            return CoreL10n.string("z.ai network error: %@", message)
        case let .apiError(message):
            return CoreL10n.string("z.ai API error: %@", message)
        case let .parseFailed(message):
            return CoreL10n.string("Failed to parse z.ai response: %@", message)
        }
    }
}

public struct ZaiUsageProvider: UsageStatsProvider {
    public let provider: Provider = .zai

    private let apiKey: String
    private let region: ZaiAPIRegion
    private let environment: [String: String]

    public init(apiKey: String, region: ZaiAPIRegion, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        self.environment = environment
    }

    public func fetchSnapshot() async throws -> ProviderUsageSnapshot {
        guard !apiKey.isEmpty else { throw ZaiUsageError.missingAPIKey }
        let raw = try await Self.fetchUsage(apiKey: apiKey, region: region, environment: environment)
        return raw.toProviderUsageSnapshot(sourceLabel: region.displayName)
    }

    private static func fetchUsage(
        apiKey: String,
        region: ZaiAPIRegion,
        environment: [String: String]
    ) async throws -> ZaiUsageSnapshot {
        let quotaURL = resolveQuotaURL(region: region, environment: environment)

        var request = URLRequest(url: quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ZaiUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZaiUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ZaiUsageError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard !data.isEmpty else {
            throw ZaiUsageError.parseFailed("Empty response body (HTTP 200). Check z.ai region and API key.")
        }

        do {
            return try parseUsageSnapshot(from: data)
        } catch let error as ZaiUsageError {
            throw error
        } catch {
            throw ZaiUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func resolveQuotaURL(region: ZaiAPIRegion, environment: [String: String]) -> URL {
        if let override = quotaURL(environment: environment) {
            return override
        }
        if let host = apiHost(environment: environment), let hostURL = quotaURL(baseURLString: host) {
            return hostURL
        }
        return region.quotaLimitURL
    }

    private static func apiHost(environment: [String: String]) -> String? {
        cleaned(environment["Z_AI_API_HOST"])
    }

    private static func quotaURL(environment: [String: String]) -> URL? {
        guard let raw = cleaned(environment["Z_AI_QUOTA_URL"]) else { return nil }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(raw)")
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseUsageSnapshot(from data: Data) throws -> ZaiUsageSnapshot {
        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ZaiQuotaLimitResponse.self, from: data)

        guard apiResponse.isSuccess else {
            throw ZaiUsageError.apiError(apiResponse.msg)
        }
        guard let responseData = apiResponse.data else {
            throw ZaiUsageError.parseFailed("Missing data")
        }

        var tokenLimits: [ZaiLimitEntry] = []
        var timeLimit: ZaiLimitEntry?

        for limit in responseData.limits {
            guard let entry = limit.toLimitEntry() else { continue }
            switch entry.type {
            case .tokensLimit:
                tokenLimits.append(entry)
            case .timeLimit:
                timeLimit = entry
            }
        }

        let tokenLimit: ZaiLimitEntry?
        let sessionTokenLimit: ZaiLimitEntry?
        if tokenLimits.count >= 2 {
            let sorted = tokenLimits.sorted { ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max) }
            sessionTokenLimit = sorted.first
            tokenLimit = sorted.last
        } else {
            tokenLimit = tokenLimits.first
            sessionTokenLimit = nil
        }

        return ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            sessionTokenLimit: sessionTokenLimit,
            timeLimit: timeLimit,
            planName: responseData.planName,
            updatedAt: Date()
        )
    }

    private static func quotaURL(baseURLString: String) -> URL? {
        guard let cleaned = cleaned(baseURLString) else { return nil }
        if let url = URL(string: cleaned), url.scheme != nil {
            if url.path.isEmpty || url.path == "/" {
                return url.appendingPathComponent("api/monitor/usage/quota/limit")
            }
            return url
        }
        guard let base = URL(string: "https://\(cleaned)") else { return nil }
        if base.path.isEmpty || base.path == "/" {
            return base.appendingPathComponent("api/monitor/usage/quota/limit")
        }
        return base
    }
}

private enum ZaiLimitType: String, Decodable, Sendable {
    case timeLimit = "TIME_LIMIT"
    case tokensLimit = "TOKENS_LIMIT"
}

private enum ZaiLimitUnit: Int, Decodable, Sendable {
    case unknown = 0
    case days = 1
    case hours = 3
    case minutes = 5
    case weeks = 6
}

private struct ZaiUsageDetail: Sendable, Codable {
    let modelCode: String
    let usage: Int
}

private struct ZaiLimitEntry: Sendable {
    let type: ZaiLimitType
    let unit: ZaiLimitUnit
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Double
    let usageDetails: [ZaiUsageDetail]
    let nextResetTime: Date?

    var usedPercent: Double {
        if let computed = computedUsedPercent {
            return computed
        }
        return percentage
    }

    var windowMinutes: Int? {
        guard number > 0 else { return nil }
        switch unit {
        case .minutes: return number
        case .hours: return number * 60
        case .days: return number * 24 * 60
        case .weeks: return number * 7 * 24 * 60
        case .unknown: return nil
        }
    }

    var windowLabel: String? {
        guard number > 0 else { return nil }
        let unitLabel: String?
        switch unit {
        case .minutes: unitLabel = "minute"
        case .hours: unitLabel = "hour"
        case .days: unitLabel = "day"
        case .weeks: unitLabel = "week"
        case .unknown: unitLabel = nil
        }
        guard let unitLabel else { return nil }
        return number == 1 ? "1 \(unitLabel) window" : "\(number) \(unitLabel)s window"
    }

    var mcpDetailSummary: String? {
        guard !usageDetails.isEmpty else { return nil }
        let pieces = usageDetails.map { detail -> String in
            let name = Self.mcpDisplayName(for: detail.modelCode)
            return "\(name) \(detail.usage)"
        }
        return pieces.joined(separator: " · ")
    }

    private static func mcpDisplayName(for modelCode: String) -> String {
        switch modelCode {
        case "search-prime": return "联网搜索"
        case "web-reader": return "网页读取"
        case "zread", "open-source-repo": return "开源仓库"
        case "vision": return "视觉理解"
        default: return modelCode
        }
    }

    private var computedUsedPercent: Double? {
        guard let limit = usage, limit > 0 else { return nil }
        var usedRaw: Int?
        if let remaining = remaining {
            let usedFromRemaining = limit - remaining
            if let currentValue = currentValue {
                usedRaw = max(usedFromRemaining, currentValue)
            } else {
                usedRaw = usedFromRemaining
            }
        } else if let currentValue = currentValue {
            usedRaw = currentValue
        }
        guard let usedRaw else { return nil }
        let used = max(0, min(limit, usedRaw))
        let percent = (Double(used) / Double(limit)) * 100
        return min(100, max(0, percent))
    }
}

private struct ZaiUsageSnapshot: Sendable {
    let tokenLimit: ZaiLimitEntry?
    let sessionTokenLimit: ZaiLimitEntry?
    let timeLimit: ZaiLimitEntry?
    let planName: String?
    let updatedAt: Date

    func toProviderUsageSnapshot(sourceLabel: String) -> ProviderUsageSnapshot {
        let windows = [
            makeTokenWindow(id: "primary", title: tokenLimit?.windowLabel ?? "Primary window", limit: tokenLimit),
            makeMCPWindow(id: "secondary", limit: tokenLimit != nil ? timeLimit : nil),
            makeTokenWindow(id: "tertiary", title: sessionTokenLimit?.windowLabel ?? "Session token window", limit: sessionTokenLimit),
            tokenLimit == nil ? makeMCPWindow(id: "primary", limit: timeLimit) : nil
        ].compactMap { $0 }

        return ProviderUsageSnapshot(
            provider: .zai,
            updatedAt: updatedAt,
            sourceLabel: sourceLabel,
            identitySummary: nil,
            planName: planName,
            windows: windows
        )
    }

    private func makeTokenWindow(id: String, title: String, limit: ZaiLimitEntry?) -> UsageWindowSnapshot? {
        guard let limit else { return nil }
        return UsageWindowSnapshot(
            id: id,
            title: title,
            usedValue: resolvedUsedValue(for: limit),
            limitValue: limit.usage,
            unitLabel: "tokens",
            usedPercent: limit.usedPercent,
            resetsAt: limit.nextResetTime,
            resetDescription: limit.windowLabel
        )
    }

    private func makeMCPWindow(id: String, limit: ZaiLimitEntry?) -> UsageWindowSnapshot? {
        guard let limit else { return nil }
        let resetDescription = limit.mcpDetailSummary ?? (limit.nextResetTime == nil ? "月度 MCP 配额" : nil)
        return UsageWindowSnapshot(
            id: id,
            title: "MCP 调用 (月度)",
            usedValue: resolvedUsedValue(for: limit),
            limitValue: limit.usage,
            unitLabel: "次",
            usedPercent: limit.usedPercent,
            resetsAt: limit.nextResetTime,
            resetDescription: resetDescription
        )
    }

    private func resolvedUsedValue(for limit: ZaiLimitEntry) -> Int? {
        if let remaining = limit.remaining, let usage = limit.usage {
            return max(0, usage - remaining)
        }
        return limit.currentValue
    }
}

private struct ZaiQuotaLimitResponse: Decodable {
    let code: Int
    let msg: String
    let data: ZaiQuotaLimitData?
    let success: Bool

    var isSuccess: Bool { success && code == 200 }
}

private struct ZaiQuotaLimitData: Decodable {
    let limits: [ZaiLimitRaw]
    let planName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = try container.decodeIfPresent([ZaiLimitRaw].self, forKey: .limits) ?? []
        let candidates: [String?] = [
            try container.decodeIfPresent(String.self, forKey: .planName),
            try container.decodeIfPresent(String.self, forKey: .plan),
            try container.decodeIfPresent(String.self, forKey: .planType),
            try container.decodeIfPresent(String.self, forKey: .packageName),
            try container.decodeIfPresent(String.self, forKey: .level).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        ]
        let rawPlan = candidates.compactMap { $0 }.first
        let trimmed = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        planName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case planName
        case plan
        case planType = "plan_type"
        case packageName
        case level
    }
}

private struct ZaiLimitRaw: Codable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Int
    let usageDetails: [ZaiUsageDetail]?
    let nextResetTime: Int?

    func toLimitEntry() -> ZaiLimitEntry? {
        guard let limitType = ZaiLimitType(rawValue: type) else { return nil }
        let limitUnit = ZaiLimitUnit(rawValue: unit) ?? .unknown
        let nextReset = nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        return ZaiLimitEntry(
            type: limitType,
            unit: limitUnit,
            number: number,
            usage: usage,
            currentValue: currentValue,
            remaining: remaining,
            percentage: Double(percentage),
            usageDetails: usageDetails ?? [],
            nextResetTime: nextReset
        )
    }
}
