import XCTest
@testable import TokenScopeCore

final class ClaudeCodeParserTests: XCTestCase {
    func testParseBasicSession() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("session_\(UUID()).jsonl")
        let lines = [
            #"{"type":"user","sessionId":"","cwd":"/tmp/proj","timestamp":"2026-04-01T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","cwd":"/tmp/proj","timestamp":"2026-04-01T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":10}}}"#,
            #"{"type":"assistant","sessionId":"abc","cwd":"/tmp/proj","timestamp":"2026-04-01T10:00:10.000Z","message":{"role":"assistant","model":"claude-opus-4-6","usage":{"input_tokens":50,"output_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":20}}}"#,
        ].joined(separator: "\n")
        try lines.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = ClaudeCodeParser()
        let result = try parser.parse(fileURL: tmp)
        XCTAssertEqual(result.session.id, "abc")
        XCTAssertEqual(result.usageRecords.map(\.sessionId), ["abc", "abc"])
        XCTAssertEqual(result.session.projectPath, "/tmp/proj")
        XCTAssertEqual(result.usageRecords.count, 2)
        XCTAssertEqual(result.session.totalUsage.inputTokens, 150)
        XCTAssertEqual(result.session.totalUsage.outputTokens, 32)
        XCTAssertEqual(result.session.totalUsage.cacheReadTokens, 30)
        XCTAssertEqual(result.session.modelsUsed, ["claude-opus-4-6"])
    }

    func testFallsBackToFilenameWhenEmbeddedSessionIDIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("fallback-session.jsonl")
        let line = #"{"type":"assistant","cwd":"/tmp/proj","timestamp":"2026-04-01T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":20}}}"#
        try line.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try ClaudeCodeParser().parse(fileURL: fileURL)

        XCTAssertEqual(result.session.id, "fallback-session")
        XCTAssertEqual(result.usageRecords.map(\.sessionId), ["fallback-session"])
    }

    func testSubagentPathUsesFilenameIDInsteadOfEmbeddedParentSessionID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subagentsDirectory = directory.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = subagentsDirectory.appendingPathComponent("agent-42.jsonl")
        let line = #"{"type":"assistant","sessionId":"parent-session","cwd":"/tmp/proj","timestamp":"2026-04-01T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":20}}}"#
        try line.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try ClaudeCodeParser().parse(fileURL: fileURL)

        XCTAssertEqual(result.session.id, "subagent:agent-42")
        XCTAssertEqual(result.usageRecords.map(\.sessionId), ["subagent:agent-42"])
    }

    func testAggregator() {
        let r1 = UsageRecord(sessionId: "s1", messageIndex: 0, provider: .claudeCode, accountId: nil, model: "claude-opus-4-6", timestamp: Date(timeIntervalSince1970: 1800000000), usage: TokenUsage(inputTokens: 100, outputTokens: 20))
        let r2 = UsageRecord(sessionId: "s1", messageIndex: 1, provider: .claudeCode, accountId: nil, model: "claude-opus-4-6", timestamp: Date(timeIntervalSince1970: 1800000600), usage: TokenUsage(inputTokens: 50, outputTokens: 10))
        let agg = UsageAggregator(priceBook: PriceBook())
        let buckets = agg.dailyBuckets(records: [r1, r2])
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].usage.inputTokens, 150)
        XCTAssertGreaterThan(buckets[0].costUSD, 0)
    }
}
