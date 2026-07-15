import Foundation
import XCTest
@testable import TokenScopeCore

final class PricingEstimateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBuiltinCatalogContainsAllCurrentPrices() throws {
        struct ExpectedPrice {
            let provider: Provider
            let upstreamProviderID: String?
            let model: String
            let canonical: String
            let rates: [Double]
        }
        let expected = [
            ExpectedPrice(provider: .codex, upstreamProviderID: nil, model: "gpt-5.6-sol", canonical: "gpt-5.6-sol", rates: [5, 0.5, 6.25, 30]),
            ExpectedPrice(provider: .codex, upstreamProviderID: nil, model: "gpt-5.6-terra", canonical: "gpt-5.6-terra", rates: [2.5, 0.25, 3.125, 15]),
            ExpectedPrice(provider: .codex, upstreamProviderID: nil, model: "gpt-5.6-luna", canonical: "gpt-5.6-luna", rates: [1, 0.1, 1.25, 6]),
            ExpectedPrice(provider: .codex, upstreamProviderID: nil, model: "gpt-5.5", canonical: "gpt-5.5", rates: [5, 0.5, 5, 30]),
            ExpectedPrice(provider: .claudeCode, upstreamProviderID: nil, model: "claude-fable-5", canonical: "claude-fable-5", rates: [10, 1, 12.5, 50]),
            ExpectedPrice(provider: .claudeCode, upstreamProviderID: nil, model: "claude-opus-4-8", canonical: "claude-opus-4-8", rates: [5, 0.5, 6.25, 25]),
            ExpectedPrice(provider: .openCode, upstreamProviderID: "longcat", model: "LongCat-2.0", canonical: "LongCat-2.0", rates: [0.75, 0.015, 0.75, 2.95]),
            ExpectedPrice(provider: .openCode, upstreamProviderID: "deepseek", model: "deepseek-v4-pro", canonical: "deepseek-v4-pro", rates: [0.435, 0.003625, 0.435, 0.87]),
            ExpectedPrice(provider: .openCode, upstreamProviderID: "deepseek", model: "deepseek-v4-flash", canonical: "deepseek-v4-flash", rates: [0.14, 0.0028, 0.14, 0.28]),
            ExpectedPrice(provider: .openCode, upstreamProviderID: "kimi-for-coding", model: "k2p7", canonical: "kimi-k2.7-code", rates: [0.95, 0.19, 0.95, 4]),
            ExpectedPrice(provider: .openCode, upstreamProviderID: "kimi-for-coding", model: "k2p7-highspeed", canonical: "kimi-k2.7-code-highspeed", rates: [1.9, 0.38, 1.9, 8]),
            ExpectedPrice(provider: .openCode, upstreamProviderID: "kimi-for-coding", model: "k2p6", canonical: "kimi-k2.6", rates: [0.95, 0.16, 0.95, 4]),
        ]
        let book = PriceBook(storageURL: nil)

        for item in expected {
            let price = try XCTUnwrap(book.price(for: PricingKey(
                sourceProvider: item.provider,
                upstreamProviderID: item.upstreamProviderID,
                modelID: item.model
            )), item.model)
            XCTAssertEqual(price.model, item.canonical)
            XCTAssertEqual(
                [price.inputPerMillion, price.cacheReadPerMillion, price.cacheCreationPerMillion, price.outputPerMillion],
                item.rates,
                item.model
            )
            XCTAssertEqual(price.verifiedOn, "2026-07-15")
        }
    }

    func testExactAliasesDoNotFallBackToOlderModelPrefixes() {
        let book = PriceBook(storageURL: nil)

        let gpt55 = book.estimate(for: record(provider: .codex, model: "gpt-5.5", usage: basicUsage))
        let gpt56 = book.estimate(for: record(provider: .codex, model: "gpt-5.6-sol", usage: basicUsage))
        let opus48 = book.estimate(for: record(provider: .claudeCode, model: "claude-opus-4-8", usage: basicUsage))
        let unknown = book.estimate(for: record(provider: .codex, model: "gpt-5.7", usage: basicUsage))

        XCTAssertEqual(gpt55.canonicalModel, "gpt-5.5")
        XCTAssertEqual(gpt55.estimatedUSD, 0.000035, accuracy: 0.000000001)
        XCTAssertEqual(gpt56.canonicalModel, "gpt-5.6-sol")
        XCTAssertEqual(gpt56.estimatedUSD, 0.000035, accuracy: 0.000000001)
        XCTAssertEqual(opus48.canonicalModel, "claude-opus-4-8")
        XCTAssertEqual(opus48.estimatedUSD, 0.000030, accuracy: 0.000000001)
        XCTAssertEqual(unknown.coverage, .unpriced)
        XCTAssertEqual(unknown.estimatedUSD, 0)
    }

    func testApprovedDateSnapshotAndKimiProviderAliasResolveExactly() {
        let book = PriceBook(storageURL: nil)
        let snapshot = book.estimate(for: record(
            provider: .codex,
            model: "gpt-5.6-sol-2026-07-15",
            usage: TokenUsage(inputTokens: 1)
        ))
        let kimi = book.estimate(for: record(
            provider: .openCode,
            upstreamProviderID: "kimi-for-coding",
            model: "k2p7",
            usage: TokenUsage(inputTokens: 1_000, outputTokens: 100, cacheReadTokens: 500)
        ))
        let wrongVendor = book.estimate(for: record(
            provider: .openCode,
            upstreamProviderID: "deepseek",
            model: "k2p7",
            usage: TokenUsage(inputTokens: 1)
        ))

        XCTAssertEqual(snapshot.canonicalModel, "gpt-5.6-sol")
        XCTAssertEqual(kimi.canonicalModel, "kimi-k2.7-code")
        XCTAssertEqual(kimi.estimatedUSD, 0.001445, accuracy: 0.000000001)
        XCTAssertEqual(wrongVendor.coverage, .unpriced)
    }

    func testOpenAILongContextRuleAppliesOnlyAbove272KPerRecord() {
        let book = PriceBook(storageURL: nil)
        let atThreshold = book.estimate(for: record(
            provider: .codex,
            model: "gpt-5.5",
            usage: TokenUsage(
                inputTokens: 200_000,
                outputTokens: 10_000,
                cacheCreationTokens: 12_000,
                cacheReadTokens: 60_000
            )
        ))
        let aboveThreshold = book.estimate(for: record(
            provider: .codex,
            model: "gpt-5.5",
            usage: TokenUsage(
                inputTokens: 200_001,
                outputTokens: 10_000,
                cacheCreationTokens: 12_000,
                cacheReadTokens: 60_000
            )
        ))

        XCTAssertEqual(atThreshold.estimatedUSD, 1.39, accuracy: 0.000000001)
        XCTAssertEqual(aboveThreshold.estimatedUSD, 2.63001, accuracy: 0.000000001)
    }

    func testOpenCodeFormulaIncludesReasoningAtOutputPriceAndIgnoresRecordedCost() async throws {
        let usage = TokenUsage(
            inputTokens: 1_000,
            outputTokens: 230,
            cacheCreationTokens: 40,
            cacheReadTokens: 700
        )
        let record = record(
            provider: .openCode,
            upstreamProviderID: "longcat",
            model: "LongCat-2.0",
            usage: usage
        )
        let session = SessionRecord(
            id: "longcat",
            provider: .openCode,
            accountId: "longcat",
            projectPath: "/tmp/project",
            sourceFile: URL(fileURLWithPath: "/tmp/opencode.db"),
            startedAt: now,
            endedAt: now,
            modelsUsed: ["LongCat-2.0"],
            totalUsage: usage,
            messageCount: 1
        )

        let snapshot = try await OpenCodeUsageProvider(
            sessions: [session],
            usageRecords: [record],
            databaseURL: URL(fileURLWithPath: "/tmp/missing-opencode-\(UUID().uuidString).db"),
            now: now,
            priceBook: PriceBook(storageURL: nil)
        ).fetchSnapshot()

        let breakdown = try XCTUnwrap(snapshot.modelBreakdowns.first)
        XCTAssertEqual(breakdown.estimatedCostUSD, 0.001469, accuracy: 0.000000001)
        XCTAssertEqual(breakdown.pricingCoverage, .priced)
    }

    func testOpenCodeBreakdownAppliesLongContextThresholdPerMessage() async throws {
        let perMessage = TokenUsage(inputTokens: 150_000, outputTokens: 1_000)
        let records = [
            record(
                sessionID: "openai",
                index: 0,
                provider: .openCode,
                upstreamProviderID: "openai",
                model: "gpt-5.5",
                usage: perMessage
            ),
            record(
                sessionID: "openai",
                index: 1,
                provider: .openCode,
                upstreamProviderID: "openai",
                model: "gpt-5.5",
                usage: perMessage
            ),
        ]
        let session = SessionRecord(
            id: "openai",
            provider: .openCode,
            accountId: "openai",
            projectPath: "/tmp/project",
            sourceFile: URL(fileURLWithPath: "/tmp/opencode.db"),
            startedAt: now,
            endedAt: now,
            modelsUsed: ["gpt-5.5"],
            totalUsage: perMessage + perMessage,
            messageCount: 2
        )

        let snapshot = try await OpenCodeUsageProvider(
            sessions: [session],
            usageRecords: records,
            databaseURL: URL(fileURLWithPath: "/tmp/missing-opencode-\(UUID().uuidString).db"),
            now: now,
            priceBook: PriceBook(storageURL: nil)
        ).fetchSnapshot()

        XCTAssertEqual(snapshot.modelBreakdowns.first?.estimatedCostUSD ?? -1, 1.56, accuracy: 0.000000001)
    }

    func testFreeAndUnpricedCoverageAreDistinctAndExcludedFromCost() {
        let book = PriceBook(storageURL: nil)
        let priced = record(
            provider: .openCode,
            upstreamProviderID: "deepseek",
            model: "deepseek-v4-pro",
            usage: TokenUsage(inputTokens: 1_000, outputTokens: 100)
        )
        let free = record(
            provider: .openCode,
            upstreamProviderID: "opencode",
            model: "mimo-v2.5-free",
            usage: TokenUsage(inputTokens: 10_000, outputTokens: 1_000)
        )
        let unknown = record(
            provider: .openCode,
            upstreamProviderID: "opencode",
            model: "big-pickle",
            usage: TokenUsage(inputTokens: 10_000, outputTokens: 1_000)
        )

        XCTAssertEqual(book.estimate(for: free).coverage, .free)
        XCTAssertEqual(book.estimate(for: unknown).coverage, .unpriced)

        let summary = UsageAggregator(priceBook: book).costSummary(records: [priced, free, unknown])
        XCTAssertEqual(summary.costUSD, 0.000522, accuracy: 0.000000001)
        XCTAssertEqual(summary.pricingCoverage.pricedRecordCount, 1)
        XCTAssertEqual(summary.pricingCoverage.freeRecordCount, 1)
        XCTAssertEqual(summary.pricingCoverage.unpricedRecordCount, 1)
        XCTAssertEqual(summary.pricingCoverage.unpricedModels, ["big-pickle"])
    }

    func testMixedModelSessionSumsMessageLevelPrices() {
        let book = PriceBook(storageURL: nil)
        let records = [
            record(
                sessionID: "mixed",
                index: 0,
                provider: .codex,
                model: "gpt-5.5",
                usage: TokenUsage(inputTokens: 1_000, outputTokens: 100)
            ),
            record(
                sessionID: "mixed",
                index: 1,
                provider: .codex,
                model: "gpt-5.6-terra",
                usage: TokenUsage(inputTokens: 2_000, outputTokens: 200)
            ),
        ]

        let summary = UsageAggregator(priceBook: book).costSummary(records: records)

        XCTAssertEqual(summary.costUSD, 0.016, accuracy: 0.000000001)
        XCTAssertTrue(summary.pricingCoverage.isComplete)
    }

    func testUserOverrideWinsOnlyForExactVendorAndLegacyJSONStillDecodes() throws {
        let override = ModelPrice(
            provider: .openAIAPI,
            vendor: .openAI,
            model: "gpt-5.5",
            inputPerMillion: 1,
            outputPerMillion: 2,
            cacheReadPerMillion: 0.1,
            cacheCreationPerMillion: 1,
            source: .user
        )
        let book = PriceBook(userOverrides: [override], storageURL: nil)
        let estimate = book.estimate(for: record(provider: .codex, model: "gpt-5.5", usage: basicUsage))

        XCTAssertEqual(estimate.estimatedUSD, 0.000003, accuracy: 0.000000001)

        let legacy = #"{"provider":"openai_api","model":"legacy-model","inputPerMillion":1,"outputPerMillion":2,"cacheReadPerMillion":0.1,"cacheCreationPerMillion":1,"currency":"USD","source":"user"}"#
        let decoded = try JSONDecoder().decode(ModelPrice.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.vendor, .openAI)
        XCTAssertEqual(decoded.aliases, [])
        XCTAssertEqual(decoded.rule, .standard)
    }

    private var basicUsage: TokenUsage {
        TokenUsage(inputTokens: 1, outputTokens: 1)
    }

    private func record(
        sessionID: String = "session",
        index: Int = 0,
        provider: Provider,
        upstreamProviderID: String? = nil,
        model: String,
        usage: TokenUsage
    ) -> UsageRecord {
        UsageRecord(
            sessionId: sessionID,
            messageIndex: index,
            provider: provider,
            accountId: upstreamProviderID,
            model: model,
            timestamp: now,
            usage: usage
        )
    }
}
