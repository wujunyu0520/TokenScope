import Foundation

public enum BuiltinPrices {
    private static let verifiedOn = "2026-07-15"

    public static let all: [ModelPrice] = [
        // Anthropic public list prices, USD per 1M tokens. Cache writes use the default 5-minute rate.
        price(.anthropicAPI, .anthropic, "claude-fable-5", 10, 50, 1, 12.5, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-opus-4-8", 5, 25, 0.5, 6.25, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-opus-4-7", 5, 25, 0.5, 6.25, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-opus-4-6", 5, 25, 0.5, 6.25, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-opus-4-5", 5, 25, 0.5, 6.25, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-opus-4", 15, 75, 1.5, 18.75, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-sonnet-4-6", 3, 15, 0.3, 3.75, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-sonnet-4-5", 3, 15, 0.3, 3.75, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-sonnet-4", 3, 15, 0.3, 3.75, source: anthropicURL),
        price(.anthropicAPI, .anthropic, "claude-haiku-4-5", 1, 5, 0.1, 1.25, source: anthropicURL),

        // OpenAI standard processing prices. The 272K rule applies per request.
        price(
            .openAIAPI, .openAI, "gpt-5.6-sol", 5, 30, 0.5, 6.25,
            aliases: ["gpt-5.6"], source: openAIGPT56URL, rule: .openAILongContext
        ),
        price(
            .openAIAPI, .openAI, "gpt-5.6-terra", 2.5, 15, 0.25, 3.125,
            source: openAIGPT56URL, rule: .openAILongContext
        ),
        price(
            .openAIAPI, .openAI, "gpt-5.6-luna", 1, 6, 0.1, 1.25,
            source: openAIGPT56URL, rule: .openAILongContext
        ),
        price(
            .openAIAPI, .openAI, "gpt-5.5", 5, 30, 0.5, 5,
            source: openAIGPT55URL, rule: .openAILongContext
        ),
        price(
            .openAIAPI, .openAI, "gpt-5.4", 2.5, 15, 0.25, 2.5,
            source: openAIGPT54URL, rule: .openAILongContext
        ),
        price(.openAIAPI, .openAI, "gpt-5.4-mini", 0.75, 4.5, 0.075, 0.75, source: openAIModelsURL),
        price(.openAIAPI, .openAI, "gpt-5.4-nano", 0.2, 1.25, 0.02, 0.2, source: openAIModelsURL),
        price(.openAIAPI, .openAI, "gpt-5.3-codex", 1.75, 14, 0.175, 1.75, source: openAIModelsURL),
        price(.openAIAPI, .openAI, "gpt-5.3", 1.75, 14, 0.175, 1.75, source: openAIModelsURL),
        price(.openAIAPI, .openAI, "gpt-5.2-codex", 0.875, 7, 0.175, 0.875, source: openAIModelsURL),
        price(.openAIAPI, .openAI, "gpt-5.2", 0.875, 7, 0.175, 0.875, source: openAIModelsURL),
        price(.openAIAPI, .openAI, "gpt-5-codex", 1.25, 10, 0.125, 1.25, source: openAIModelsURL),
        price(.openAIAPI, .openAI, "gpt-5", 1.25, 10, 0.125, 1.25, source: openAIModelsURL),

        // LongCat, DeepSeek, and Kimi public API list prices.
        price(
            .openCode, .longCat, "LongCat-2.0", 0.75, 2.95, 0.015, 0.75,
            source: longCatURL
        ),
        price(
            .openCode, .deepSeek, "deepseek-v4-pro", 0.435, 0.87, 0.003625, 0.435,
            source: deepSeekURL
        ),
        price(
            .openCode, .deepSeek, "deepseek-v4-flash", 0.14, 0.28, 0.0028, 0.14,
            source: deepSeekURL
        ),
        price(
            .openCode, .kimi, "kimi-k2.7-code", 0.95, 4, 0.19, 0.95,
            aliases: ["k2p7"], source: kimiK27URL
        ),
        price(
            .openCode, .kimi, "kimi-k2.7-code-highspeed", 1.9, 8, 0.38, 1.9,
            aliases: ["k2p7-highspeed", "kimi-for-coding-highspeed"], source: kimiK27URL
        ),
        price(
            .openCode, .kimi, "kimi-k2.6", 0.95, 4, 0.16, 0.95,
            aliases: ["k2p6"], source: kimiK26URL
        ),

        // GLM prices retained from the existing TokenScope catalog.
        price(.glmAPI, .zhipu, "glm-4.5", 0.6, 2.2, 0.11, 0),
        price(.glmAPI, .zhipu, "glm-4.6", 0.6, 2.2, 0.11, 0),
        price(.glmAPI, .zhipu, "glm-4.7", 0.6, 2.2, 0.11, 0),
        price(.glmAPI, .zhipu, "glm-5", 1, 3.2, 0.2, 0),
        price(.glmAPI, .zhipu, "glm-5-turbo", 1.2, 4, 0.24, 0),
        price(.glmAPI, .zhipu, "glm-5.1", 1.4, 4.4, 0.26, 0),

        // Only explicitly identified free OpenCode models are treated as zero-cost.
        price(.openCode, .openCode, "mimo-v2.5-free", 0, 0, 0, 0, isFree: true),
        price(.openCode, .openCode, "deepseek-v4-flash-free", 0, 0, 0, 0, isFree: true),
        price(.openCode, .openCode, "minimax-m3-free", 0, 0, 0, 0, isFree: true),
    ]

    private static func price(
        _ provider: Provider,
        _ vendor: PricingVendor,
        _ model: String,
        _ input: Double,
        _ output: Double,
        _ cacheRead: Double,
        _ cacheCreation: Double,
        aliases: [String] = [],
        source: URL? = nil,
        isFree: Bool = false,
        rule: PricingRule = .standard
    ) -> ModelPrice {
        ModelPrice(
            provider: provider,
            vendor: vendor,
            model: model,
            aliases: aliases,
            inputPerMillion: input,
            outputPerMillion: output,
            cacheReadPerMillion: cacheRead,
            cacheCreationPerMillion: cacheCreation,
            sourceURL: source,
            verifiedOn: verifiedOn,
            isFree: isFree,
            rule: rule
        )
    }

    private static let anthropicURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")
    private static let openAIModelsURL = URL(string: "https://developers.openai.com/api/docs/models")
    private static let openAIGPT54URL = URL(string: "https://developers.openai.com/api/docs/models/gpt-5.4")
    private static let openAIGPT55URL = URL(string: "https://developers.openai.com/api/docs/models/gpt-5.5")
    private static let openAIGPT56URL = URL(string: "https://developers.openai.com/api/docs/models/gpt-5.6-sol")
    private static let longCatURL = URL(string: "https://longcat.chat/platform/docs/Pricing/LongCat-2.0.html")
    private static let deepSeekURL = URL(string: "https://api-docs.deepseek.com/quick_start/pricing")
    private static let kimiK27URL = URL(string: "https://www.kimi.com/resources/kimi-k2-7-code-pricing")
    private static let kimiK26URL = URL(string: "https://www.kimi.com/resources/kimi-k2-6-pricing")
}
