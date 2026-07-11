import Foundation
import XCTest
@testable import TokenScopeCore

final class FixtureRegressionTests: XCTestCase {
    func testClaudeScannerExcludesEmptyLogFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["claude-empty", "claude-one-session"] {
            let source = try fixtureURL(name, extension: "jsonl")
            let destination = root.appendingPathComponent("\(name).jsonl")
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let results = ClaudeCodeScanner(root: root).scan()

        XCTAssertEqual(results.map(\.session.id), ["claude-one-session"])
    }

    func testClaudeFixtureUsesRecordTimestampsForRollingSevenDayMetrics() async throws {
        let fixture = try fixtureURL("claude-one-session", extension: "jsonl")
        let parsed = try ClaudeCodeParser().parse(fileURL: fixture)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-08T12:00:00Z"))

        let snapshot = try await ClaudeCodeUsageProvider(
            sessions: [parsed.session],
            usageRecords: parsed.usageRecords,
            now: now
        ).fetchSnapshot()

        let allTime = try XCTUnwrap(snapshot.windows.first { $0.id == "all-time" }?.tokenUsage)
        XCTAssertEqual(allTime.totalTokens, 492)
        XCTAssertEqual(allTime.inputTokens, 303)
        XCTAssertEqual(allTime.outputTokens, 33)
        XCTAssertEqual(allTime.cacheCreationTokens, 63)
        XCTAssertEqual(allTime.cacheReadTokens, 93)

        let lastSevenDays = try XCTUnwrap(snapshot.windows.first { $0.id == "last-7d" }?.tokenUsage)
        XCTAssertEqual(lastSevenDays.totalTokens, 328)
        XCTAssertEqual(lastSevenDays.inputTokens, 202)
        XCTAssertEqual(lastSevenDays.outputTokens, 22)
        XCTAssertEqual(lastSevenDays.cacheCreationTokens, 42)
        XCTAssertEqual(lastSevenDays.cacheReadTokens, 62)
    }

    func testCodexFixtureDecodesBothUsageWindows() throws {
        let response = try JSONDecoder().decode(
            CodexUsageResponse.self,
            from: fixtureData("codex-usage", extension: "json")
        )

        XCTAssertEqual(response.rateLimit?.primaryWindow?.usedPercent, 42)
        XCTAssertEqual(response.rateLimit?.primaryWindow?.limitWindowSeconds, 18_000)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.usedPercent, 17)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.limitWindowSeconds, 604_800)
    }

    func testCodexFixturePrefersOAuthOverAPIKeyAndSupportsIdentity() throws {
        let data = try fixtureData("codex-usage", extension: "json")
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)

        let credentials = try CodexOAuthCredentialsStore.parse(data: data)

        XCTAssertEqual(credentials.accessToken, "synthetic-oauth-access-token")
        XCTAssertEqual(credentials.refreshToken, "synthetic-oauth-refresh-token")
        XCTAssertEqual(credentials.accountId, "account-fixture")
        XCTAssertNotEqual(credentials.accessToken, "synthetic-api-key-not-a-credential")

        let identity = CodexOAuthIdentity.from(credentials: credentials, response: response)
        XCTAssertEqual(identity.email, "developer@example.invalid")
        XCTAssertEqual(identity.providerAccountID, "account-fixture")
        XCTAssertEqual(identity.planName, "pro")
    }

    func testProviderCacheRejectsVersionOneFixture() throws {
        let fixture = try fixtureURL("provider-cache-v1", extension: "json")

        XCTAssertNil(ProviderUsageCache(storageURL: fixture).load())
        XCTAssertEqual(ProviderUsageCacheSnapshot.currentVersion, 2)
    }

    func testProviderCacheVersionTwoRoundTripsWithoutSchemaChange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-cache-v2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = ProviderUsageSnapshot(
            provider: .claudeCode,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceLabel: "Synthetic fixture",
            windows: [
                UsageWindowSnapshot(
                    id: "all-time",
                    title: "All sessions",
                    kind: .tokenSummary,
                    tokenUsage: TokenUsage(
                        inputTokens: 10,
                        outputTokens: 20,
                        cacheCreationTokens: 30,
                        cacheReadTokens: 40
                    ),
                    usedValue: 100,
                    usedPercent: 0
                ),
            ]
        )
        let cache = ProviderUsageCache(storageURL: url)

        cache.save(snapshots: [snapshot])

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.snapshots, [snapshot])
    }

    private func fixtureURL(_ name: String, extension fileExtension: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: fileExtension))
    }

    private func fixtureData(_ name: String, extension fileExtension: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name, extension: fileExtension))
    }
}
