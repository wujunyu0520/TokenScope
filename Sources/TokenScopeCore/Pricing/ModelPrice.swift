import Foundation

public enum PricingVendor: String, Codable, CaseIterable, Sendable, Hashable {
    case anthropic
    case openAI = "openai"
    case deepSeek = "deepseek"
    case kimi
    case longCat = "longcat"
    case zhipu
    case openCode = "opencode"
    case custom

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .longCat: return "LongCat"
        case .zhipu: return "Zhipu AI"
        case .openCode: return "OpenCode"
        case .custom: return "Custom"
        }
    }

    public var legacyProvider: Provider {
        switch self {
        case .anthropic: return .anthropicAPI
        case .openAI: return .openAIAPI
        case .zhipu: return .glmAPI
        case .deepSeek, .kimi, .longCat, .openCode, .custom: return .openCode
        }
    }

    static func inferred(from provider: Provider) -> PricingVendor {
        switch provider {
        case .claudeCode, .anthropicAPI:
            return .anthropic
        case .codex, .openAIAPI:
            return .openAI
        case .zai, .glmPlan, .glmAPI:
            return .zhipu
        case .openCode:
            return .openCode
        }
    }
}

public struct PricingKey: Sendable, Hashable {
    public let sourceProvider: Provider
    public let upstreamProviderID: String?
    public let vendor: PricingVendor
    public let modelID: String

    public init(
        sourceProvider: Provider,
        upstreamProviderID: String?,
        modelID: String
    ) {
        self.sourceProvider = sourceProvider
        self.upstreamProviderID = upstreamProviderID
        self.vendor = Self.resolveVendor(
            sourceProvider: sourceProvider,
            upstreamProviderID: upstreamProviderID
        )
        self.modelID = modelID
    }

    public init(record: UsageRecord) {
        self.init(
            sourceProvider: record.provider,
            upstreamProviderID: record.accountId,
            modelID: record.model
        )
    }

    private static func resolveVendor(
        sourceProvider: Provider,
        upstreamProviderID: String?
    ) -> PricingVendor {
        guard sourceProvider == .openCode else {
            return PricingVendor.inferred(from: sourceProvider)
        }

        switch upstreamProviderID?.lowercased() {
        case "longcat": return .longCat
        case "deepseek": return .deepSeek
        case "kimi-for-coding", "kimi": return .kimi
        case "openai": return .openAI
        case "anthropic": return .anthropic
        case "opencode": return .openCode
        default: return .custom
        }
    }
}

public enum PricingCoverage: String, Codable, Sendable, Hashable {
    case priced
    case free
    case unpriced
}

public struct CostEstimate: Sendable, Hashable {
    public let estimatedUSD: Double
    public let coverage: PricingCoverage
    public let canonicalModel: String?
    public let vendor: PricingVendor
    public let sourceURL: URL?
    public let verifiedOn: String?

    public init(
        estimatedUSD: Double,
        coverage: PricingCoverage,
        canonicalModel: String?,
        vendor: PricingVendor,
        sourceURL: URL?,
        verifiedOn: String?
    ) {
        self.estimatedUSD = estimatedUSD
        self.coverage = coverage
        self.canonicalModel = canonicalModel
        self.vendor = vendor
        self.sourceURL = sourceURL
        self.verifiedOn = verifiedOn
    }
}

public struct PricingRule: Codable, Sendable, Hashable {
    public let longContextThreshold: Int?
    public let longContextInputMultiplier: Double
    public let longContextOutputMultiplier: Double

    public init(
        longContextThreshold: Int? = nil,
        longContextInputMultiplier: Double = 1,
        longContextOutputMultiplier: Double = 1
    ) {
        self.longContextThreshold = longContextThreshold
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
    }

    public static let standard = PricingRule()
    public static let openAILongContext = PricingRule(
        longContextThreshold: 272_000,
        longContextInputMultiplier: 2,
        longContextOutputMultiplier: 1.5
    )
}

public struct ModelPrice: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable { case builtin, user }

    public var id: String { "\(vendor.rawValue):\(model)" }
    public let provider: Provider
    public let vendor: PricingVendor
    public let model: String
    public let aliases: [String]
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheCreationPerMillion: Double
    public let currency: String
    public let source: Source
    public let sourceURL: URL?
    public let verifiedOn: String?
    public let isFree: Bool
    public let rule: PricingRule

    public init(
        provider: Provider,
        vendor: PricingVendor? = nil,
        model: String,
        aliases: [String] = [],
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheReadPerMillion: Double,
        cacheCreationPerMillion: Double,
        currency: String = "USD",
        source: Source = .builtin,
        sourceURL: URL? = nil,
        verifiedOn: String? = nil,
        isFree: Bool = false,
        rule: PricingRule = .standard
    ) {
        self.provider = provider
        self.vendor = vendor ?? PricingVendor.inferred(from: provider)
        self.model = model
        self.aliases = aliases
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheCreationPerMillion = cacheCreationPerMillion
        self.currency = currency
        self.source = source
        self.sourceURL = sourceURL
        self.verifiedOn = verifiedOn
        self.isFree = isFree
        self.rule = rule
    }

    public func cost(for usage: TokenUsage) -> Double {
        guard !isFree else { return 0 }

        let totalInput = usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens
        let usesLongContextPrice = rule.longContextThreshold.map { totalInput > $0 } ?? false
        let inputMultiplier = usesLongContextPrice ? rule.longContextInputMultiplier : 1
        let outputMultiplier = usesLongContextPrice ? rule.longContextOutputMultiplier : 1
        let million = 1_000_000.0

        return Double(usage.inputTokens) * inputPerMillion * inputMultiplier / million
            + Double(usage.outputTokens) * outputPerMillion * outputMultiplier / million
            + Double(usage.cacheReadTokens) * cacheReadPerMillion * inputMultiplier / million
            + Double(usage.cacheCreationTokens) * cacheCreationPerMillion * inputMultiplier / million
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case vendor
        case model
        case aliases
        case inputPerMillion
        case outputPerMillion
        case cacheReadPerMillion
        case cacheCreationPerMillion
        case currency
        case source
        case sourceURL
        case verifiedOn
        case isFree
        case rule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(Provider.self, forKey: .provider)
        self.provider = provider
        self.vendor = try container.decodeIfPresent(PricingVendor.self, forKey: .vendor)
            ?? PricingVendor.inferred(from: provider)
        self.model = try container.decode(String.self, forKey: .model)
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.inputPerMillion = try container.decode(Double.self, forKey: .inputPerMillion)
        self.outputPerMillion = try container.decode(Double.self, forKey: .outputPerMillion)
        self.cacheReadPerMillion = try container.decode(Double.self, forKey: .cacheReadPerMillion)
        self.cacheCreationPerMillion = try container.decode(Double.self, forKey: .cacheCreationPerMillion)
        self.currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        self.source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .user
        self.sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        self.verifiedOn = try container.decodeIfPresent(String.self, forKey: .verifiedOn)
        self.isFree = try container.decodeIfPresent(Bool.self, forKey: .isFree) ?? false
        self.rule = try container.decodeIfPresent(PricingRule.self, forKey: .rule) ?? .standard
    }
}
