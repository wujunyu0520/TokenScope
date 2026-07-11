import XCTest
@testable import TokenScopeCore

final class ProviderUsageFixTests: XCTestCase {
    func testClaudeUsageUsesRecordTimestampsAndLatestNonemptySession() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let recentDate = now.addingTimeInterval(-24 * 60 * 60)
        let validUsage = TokenUsage(
            inputTokens: 110,
            outputTokens: 20,
            cacheCreationTokens: 30,
            cacheReadTokens: 40
        )
        let sessions = [
            makeSession(
                id: "empty-journal",
                startedAt: now,
                usage: .zero,
                messageCount: 0
            ),
            makeSession(
                id: "valid",
                startedAt: oldDate,
                usage: validUsage,
                messageCount: 2
            ),
        ]
        let records = [
            makeRecord(
                sessionID: "valid",
                index: 0,
                timestamp: oldDate,
                usage: TokenUsage(inputTokens: 10)
            ),
            makeRecord(
                sessionID: "valid",
                index: 1,
                timestamp: recentDate,
                usage: TokenUsage(
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheCreationTokens: 30,
                    cacheReadTokens: 40
                )
            ),
        ]

        let snapshot = try await ClaudeCodeUsageProvider(
            sessions: sessions,
            usageRecords: records,
            now: now
        ).fetchSnapshot()

        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].kind, .tokenSummary)
        XCTAssertEqual(snapshot.windows[0].tokenUsage, validUsage)
        XCTAssertEqual(snapshot.windows[1].tokenUsage?.totalTokens, 190)
        XCTAssertEqual(snapshot.windows[2].tokenUsage, validUsage)
        XCTAssertNil(snapshot.windows[2].resetsAt)
        XCTAssertFalse(snapshot.windows.contains { $0.tokenUsage?.totalTokens == 0 })
    }

    func testClaudeUsageFallsBackToSessionTotalsWhenRecordsAreMissing() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = TokenUsage(inputTokens: 10, outputTokens: 2, cacheReadTokens: 20)
        let session = makeSession(
            id: "cached-without-records",
            startedAt: now.addingTimeInterval(-24 * 60 * 60),
            usage: usage,
            messageCount: 1
        )

        let snapshot = try await ClaudeCodeUsageProvider(
            sessions: [session],
            usageRecords: [],
            now: now
        ).fetchSnapshot()

        XCTAssertEqual(snapshot.windows[0].tokenUsage, usage)
        XCTAssertEqual(snapshot.windows[1].tokenUsage, usage)
        XCTAssertEqual(snapshot.windows[2].tokenUsage, usage)
    }

    func testClaudeLatestSessionUsesMostRecentUsageActivity() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newerStart = makeSession(
            id: "newer-start",
            startedAt: now.addingTimeInterval(-60 * 60),
            usage: TokenUsage(inputTokens: 10),
            messageCount: 1
        )
        let laterActivity = makeSession(
            id: "later-activity",
            startedAt: now.addingTimeInterval(-2 * 60 * 60),
            usage: TokenUsage(inputTokens: 200, outputTokens: 20),
            messageCount: 1
        )
        let records = [
            makeRecord(
                sessionID: "newer-start",
                index: 0,
                timestamp: now.addingTimeInterval(-30 * 60),
                usage: TokenUsage(inputTokens: 10)
            ),
            makeRecord(
                sessionID: "later-activity",
                index: 0,
                timestamp: now.addingTimeInterval(-5 * 60),
                usage: TokenUsage(inputTokens: 200, outputTokens: 20)
            ),
            makeRecord(
                sessionID: "newer-start",
                index: 1,
                timestamp: now.addingTimeInterval(-60),
                usage: .zero
            ),
        ]

        let snapshot = try await ClaudeCodeUsageProvider(
            sessions: [newerStart, laterActivity],
            usageRecords: records,
            now: now
        ).fetchSnapshot()

        let latest = try XCTUnwrap(snapshot.windows.first { $0.id == "latest-session" })
        XCTAssertEqual(latest.tokenUsage, TokenUsage(inputTokens: 200, outputTokens: 20))
        XCTAssertEqual(latest.usedValue, 220)
    }

    func testClaudeLatestSessionFallsBackToEndedAtWhenRecordsAreMissing() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recorded = makeSession(
            id: "recorded",
            startedAt: now.addingTimeInterval(-2 * 60 * 60),
            endedAt: now.addingTimeInterval(-5 * 60),
            usage: TokenUsage(inputTokens: 10),
            messageCount: 1
        )
        let cachedWithoutRecords = makeSession(
            id: "cached-without-records",
            startedAt: now.addingTimeInterval(-3 * 60 * 60),
            endedAt: now.addingTimeInterval(-2 * 60),
            usage: TokenUsage(inputTokens: 300),
            messageCount: 1
        )
        let records = [
            makeRecord(
                sessionID: "recorded",
                index: 0,
                timestamp: now.addingTimeInterval(-5 * 60),
                usage: TokenUsage(inputTokens: 10)
            ),
        ]

        let snapshot = try await ClaudeCodeUsageProvider(
            sessions: [recorded, cachedWithoutRecords],
            usageRecords: records,
            now: now
        ).fetchSnapshot()

        XCTAssertEqual(snapshot.windows.first { $0.id == "latest-session" }?.usedValue, 300)
    }

    func testClaudeLatestSessionUsesDeterministicIDTieBreak() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let startedAt = now.addingTimeInterval(-60 * 60)
        let sessions = [
            makeSession(id: "a", startedAt: startedAt, usage: TokenUsage(inputTokens: 10), messageCount: 1),
            makeSession(id: "b", startedAt: startedAt, usage: TokenUsage(inputTokens: 20), messageCount: 1),
        ]
        let records = [
            makeRecord(sessionID: "a", index: 0, timestamp: now, usage: TokenUsage(inputTokens: 10)),
            makeRecord(sessionID: "b", index: 0, timestamp: now, usage: TokenUsage(inputTokens: 20)),
        ]

        let snapshot = try await ClaudeCodeUsageProvider(
            sessions: sessions,
            usageRecords: records,
            now: now
        ).fetchSnapshot()

        XCTAssertEqual(snapshot.windows.first { $0.id == "latest-session" }?.usedValue, 20)
    }

    func testClaudeScannerSkipsLogsWithoutUsage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = #"{"type":"user","timestamp":"2026-07-11T01:00:00.000Z","message":{"role":"user","content":"hi"}}"#
        try empty.write(to: root.appendingPathComponent("journal.jsonl"), atomically: true, encoding: .utf8)

        let valid = #"{"type":"assistant","timestamp":"2026-07-11T01:00:01.000Z","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}"#
        try valid.write(to: root.appendingPathComponent("valid.jsonl"), atomically: true, encoding: .utf8)

        let results = ClaudeCodeScanner(root: root).scan()

        XCTAssertEqual(results.map(\.session.id), ["valid"])
        XCTAssertEqual(results.first?.session.totalUsage.totalTokens, 19)
    }

    func testUsageCacheDropsPreviouslyCachedEmptyClaudeSessions() {
        let empty = makeSession(
            id: "cached-empty",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            usage: .zero,
            messageCount: 0
        )
        let cached = UsageCacheSnapshot(
            updatedAt: .distantPast,
            sessions: [empty],
            records: []
        )

        let merged = UsageCache.merge(cached: cached, scannedSessions: [], scannedRecords: [])

        XCTAssertTrue(merged.sessions.isEmpty)
    }

    func testCodexDecodesSnakeCaseUsageWindows() throws {
        let json = #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":50,"reset_at":1800001000,"limit_window_seconds":18000},"secondary_window":{"used_percent":9,"reset_at":1800600000,"limit_window_seconds":604800}}}"#

        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.rateLimit?.primaryWindow?.usedPercent, 50)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.usedPercent, 9)
    }

    func testCodexCredentialsPreferOAuthTokensOverAPIKey() throws {
        let json = #"{"OPENAI_API_KEY":"sk-api-key","tokens":{"access_token":"oauth-access","refresh_token":"oauth-refresh","id_token":"oauth-id","account_id":"account-1"}}"#

        let credentials = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))

        XCTAssertEqual(credentials.accessToken, "oauth-access")
        XCTAssertEqual(credentials.refreshToken, "oauth-refresh")
        XCTAssertEqual(credentials.accountId, "account-1")
    }

    func testCodexAccountFingerprintIsStableAndDoesNotExposeAccountID() {
        let fingerprint = CodexAccountFingerprint.make(" account-1 ")

        XCTAssertEqual(
            fingerprint,
            "e09b8d91b2532962cef5b852d9027cca6f0d2e7e4bfefc0452365774a1b0dd9d"
        )
        XCTAssertFalse(fingerprint?.contains("account-1") == true)
        XCTAssertNil(CodexAccountFingerprint.make("   "))
    }

    func testProviderSnapshotRoundTripsCodexAccountFingerprint() throws {
        let snapshot = ProviderUsageSnapshot(
            provider: .codex,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceLabel: "OAuth",
            providerAccountFingerprint: "synthetic-fingerprint"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            ProviderUsageSnapshot.self,
            from: encoder.encode(snapshot)
        )

        XCTAssertEqual(decoded.providerAccountFingerprint, "synthetic-fingerprint")
    }

    func testProviderUsageCacheRejectsVersionOneAndRoundTripsVersionTwo() throws {
        XCTAssertEqual(ProviderUsageCacheSnapshot.currentVersion, 2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let oldSnapshot = ProviderUsageCacheSnapshot(version: 1, updatedAt: .distantPast, snapshots: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(oldSnapshot).write(to: url)

        let cache = ProviderUsageCache(storageURL: url)
        XCTAssertNil(cache.load())

        cache.save(snapshots: [])
        XCTAssertEqual(cache.load()?.version, 2)
    }

    func testProviderUsageCacheRejectsNonemptyLegacyVersionOneFixture() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-cache-v1-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = #"{"version":1,"updatedAt":"2026-07-11T00:00:00Z","snapshots":[{"provider":"claude_code","updatedAt":"2026-07-11T00:00:00Z","sourceLabel":"Local sessions","accountOptions":[],"windows":[{"id":"all-time","title":"All sessions","usedValue":10,"usedPercent":0}],"costRows":[]}]}"#
        try Data(legacy.utf8).write(to: url)

        XCTAssertNil(ProviderUsageCache(storageURL: url).load())
    }

    func testQuotaWindowRemainsTheDefaultForOtherProviders() {
        let window = UsageWindowSnapshot(id: "zai", title: "z.ai", usedPercent: 25)

        XCTAssertEqual(window.kind, .quota)
        XCTAssertEqual(window.remainingPercent, 75)
    }

    func testExactTokenFormatterUsesGroupedIntegers() {
        XCTAssertEqual(TokenDisplayFormatter.exact(1_234_567), "1,234,567")
        XCTAssertEqual(TokenDisplayFormatter.exact(0), "0")
    }

    func testTokenSummaryIgnoresCachedQuotaResetDate() {
        let window = UsageWindowSnapshot(
            id: "latest-session",
            title: "Latest session",
            kind: .tokenSummary,
            tokenUsage: TokenUsage(inputTokens: 1),
            usedValue: 1,
            usedPercent: 0,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            resetDescription: "Jul 11, 2026"
        )

        XCTAssertNil(window.quotaResetDate)
        XCTAssertEqual(window.resetDescription, "Jul 11, 2026")
    }

    private func makeSession(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        usage: TokenUsage,
        messageCount: Int
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            provider: .claudeCode,
            accountId: nil,
            projectPath: "/tmp/project",
            sourceFile: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            startedAt: startedAt,
            endedAt: endedAt ?? startedAt,
            modelsUsed: ["claude-test"],
            totalUsage: usage,
            messageCount: messageCount
        )
    }

    private func makeRecord(
        sessionID: String,
        index: Int,
        timestamp: Date,
        usage: TokenUsage
    ) -> UsageRecord {
        UsageRecord(
            sessionId: sessionID,
            messageIndex: index,
            provider: .claudeCode,
            accountId: nil,
            model: "claude-test",
            timestamp: timestamp,
            usage: usage
        )
    }
}
