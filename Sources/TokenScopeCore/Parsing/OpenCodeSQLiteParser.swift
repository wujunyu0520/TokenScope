import Foundation
import SQLite3

public enum OpenCodeSQLiteParseError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return message
        case .queryFailed(let message):
            return message
        case .stepFailed(let message):
            return message
        }
    }
}

public struct OpenCodeSQLiteParser: Sendable {
    public init() {}

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    public func parse(databaseURL: URL) throws -> [OpenCodeParseResult] {
        let snapshot = try load(databaseURL: databaseURL)
        return snapshot.results
    }

    public func modelBreakdowns(databaseURL: URL) throws -> [ProviderUsageBreakdown] {
        let snapshot = try load(databaseURL: databaseURL)
        return makeBreakdowns(from: snapshot.messages)
    }

    private func load(databaseURL: URL) throws -> OpenCodeSQLiteSnapshot {
        let db = try openDatabase(at: databaseURL)
        defer { sqlite3_close(db) }

        let sessions = try fetchSessions(from: db, sourceFile: databaseURL)
        let messages = try fetchAssistantMessages(from: db, sessions: sessions)
        let results = makeResults(sessions: sessions, messages: messages, sourceFile: databaseURL)
        return OpenCodeSQLiteSnapshot(results: results, messages: messages)
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open OpenCode database."
            sqlite3_close(db)
            throw OpenCodeSQLiteParseError.openFailed(message)
        }
        return db
    }

    private func fetchSessions(from db: OpaquePointer?, sourceFile: URL) throws -> [String: OpenCodeSQLiteSessionSeed] {
        let sql = """
        SELECT id, directory, model, cost, tokens_input, tokens_output, tokens_reasoning,
               tokens_cache_read, tokens_cache_write, time_created, time_updated
        FROM session
        """
        let statement = try prepare(db, sql: sql)
        defer { sqlite3_finalize(statement) }

        var sessions: [String: OpenCodeSQLiteSessionSeed] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw OpenCodeSQLiteParseError.stepFailed(errorMessage(from: db))
            }

            let id = text(statement, 0) ?? UUID().uuidString
            let modelInfo = parseSessionModel(text(statement, 2))
            let usage = TokenUsage(
                inputTokens: int(statement, 4),
                outputTokens: int(statement, 5) + int(statement, 6),
                cacheCreationTokens: int(statement, 8),
                cacheReadTokens: int(statement, 7)
            )
            sessions[id] = OpenCodeSQLiteSessionSeed(
                id: id,
                directory: text(statement, 1),
                providerID: modelInfo.providerID,
                modelID: modelInfo.modelID,
                cost: double(statement, 3),
                aggregateUsage: usage,
                createdAt: date(from: int64(statement, 9)),
                updatedAt: date(from: int64(statement, 10)),
                sourceFile: sourceFile
            )
        }
        return sessions
    }

    private func fetchAssistantMessages(
        from db: OpaquePointer?,
        sessions: [String: OpenCodeSQLiteSessionSeed]
    ) throws -> [OpenCodeSQLiteAssistantMessage] {
        let sql = """
        SELECT id, session_id, time_created, data
        FROM message
        ORDER BY session_id, time_created, id
        """
        let statement = try prepare(db, sql: sql)
        defer { sqlite3_finalize(statement) }

        var messages: [OpenCodeSQLiteAssistantMessage] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw OpenCodeSQLiteParseError.stepFailed(errorMessage(from: db))
            }

            let sessionID = text(statement, 1) ?? ""
            guard let dataText = text(statement, 3),
                  let data = dataText.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["role"] as? String) == "assistant"
            else { continue }

            let tokens = obj["tokens"] as? [String: Any]
            let cache = tokens?["cache"] as? [String: Any]
            let input = numericInt(tokens?["input"])
            let output = numericInt(tokens?["output"])
            let reasoning = numericInt(tokens?["reasoning"])
            let cacheRead = numericInt(cache?["read"])
            let cacheWrite = numericInt(cache?["write"])
            let usage = TokenUsage(
                inputTokens: input,
                outputTokens: output + reasoning,
                cacheCreationTokens: cacheWrite,
                cacheReadTokens: cacheRead
            )
            let sessionSeed = sessions[sessionID]
            let modelID = normalizedString(obj["modelID"]) ?? sessionSeed?.modelID ?? "unknown"
            let providerID = normalizedString(obj["providerID"]) ?? sessionSeed?.providerID ?? "unknown"
            let time = obj["time"] as? [String: Any]
            let createdValue = numericInt64(time?["created"]) ?? int64(statement, 2)

            messages.append(OpenCodeSQLiteAssistantMessage(
                id: text(statement, 0) ?? UUID().uuidString,
                sessionID: sessionID,
                providerID: providerID,
                modelID: modelID,
                timestamp: date(from: createdValue),
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: reasoning,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheWrite,
                costUSD: numericDouble(obj["cost"]) ?? 0,
                usage: usage
            ))
        }
        return messages
    }

    private func makeResults(
        sessions: [String: OpenCodeSQLiteSessionSeed],
        messages: [OpenCodeSQLiteAssistantMessage],
        sourceFile: URL
    ) -> [OpenCodeParseResult] {
        let messagesBySession = Dictionary(grouping: messages, by: \.sessionID)

        return sessions.values
            .sorted { $0.createdAt > $1.createdAt }
            .map { seed in
                let sessionMessages = messagesBySession[seed.id] ?? []
                var modelsSet = Set(sessionMessages.map(\.modelID))
                if modelsSet.isEmpty, let modelID = seed.modelID {
                    modelsSet.insert(modelID)
                }

                let records = sessionMessages
                    .filter { $0.usage.totalTokens > 0 }
                    .enumerated()
                    .map { index, message in
                        UsageRecord(
                            sessionId: seed.id,
                            messageIndex: index,
                            provider: .openCode,
                            accountId: message.providerID,
                            model: message.modelID,
                            timestamp: message.timestamp,
                            usage: message.usage
                        )
                    }
                let messageTotal = records.reduce(TokenUsage.zero) { $0 + $1.usage }
                let totalUsage = messageTotal.totalTokens > 0 ? messageTotal : seed.aggregateUsage
                let startedAt = sessionMessages.map(\.timestamp).min() ?? seed.createdAt
                let endedAt = sessionMessages.map(\.timestamp).max() ?? seed.updatedAt
                let messageCount = records.isEmpty && seed.aggregateUsage.totalTokens > 0
                    ? 1
                    : records.count

                let session = SessionRecord(
                    id: seed.id,
                    provider: .openCode,
                    accountId: sessionMessages.first?.providerID ?? seed.providerID,
                    projectPath: seed.directory,
                    sourceFile: sourceFile,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    modelsUsed: Array(modelsSet).sorted(),
                    totalUsage: totalUsage,
                    messageCount: messageCount
                )
                return OpenCodeParseResult(session: session, usageRecords: records)
            }
    }

    private func makeBreakdowns(from messages: [OpenCodeSQLiteAssistantMessage]) -> [ProviderUsageBreakdown] {
        var accumulators: [String: OpenCodeBreakdownAccumulator] = [:]
        for message in messages where message.totalTokens > 0 || message.costUSD > 0 {
            let key = "\(message.providerID)\u{1f}\(message.modelID)"
            accumulators[key, default: OpenCodeBreakdownAccumulator(
                groupName: groupName(for: message.providerID),
                providerID: message.providerID,
                modelID: message.modelID
            )].add(message)
        }
        return accumulators.values
            .map { $0.snapshot }
            .sorted(by: sortBreakdowns)
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

    private func prepare(_ db: OpaquePointer?, sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw OpenCodeSQLiteParseError.queryFailed(errorMessage(from: db))
        }
        return statement
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: cString)
    }

    private func int(_ statement: OpaquePointer?, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    private func int64(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private func double(_ statement: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    private func date(from timestamp: Int64) -> Date {
        if timestamp > 100_000_000_000 {
            return Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        }
        return Date(timeIntervalSince1970: Double(timestamp))
    }

    private func parseSessionModel(_ text: String?) -> (providerID: String?, modelID: String?) {
        guard let text,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, normalizedString(text))
        }
        return (
            normalizedString(obj["providerID"]),
            normalizedString(obj["id"]) ?? normalizedString(obj["modelID"])
        )
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func numericInt(_ value: Any?) -> Int {
        guard let int64 = numericInt64(value) else { return 0 }
        return Int(int64)
    }

    private func numericInt64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as Double:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    private func numericDouble(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private func errorMessage(from db: OpaquePointer?) -> String {
        guard let db else { return "OpenCode database error." }
        return String(cString: sqlite3_errmsg(db))
    }
}

private struct OpenCodeSQLiteSnapshot {
    let results: [OpenCodeParseResult]
    let messages: [OpenCodeSQLiteAssistantMessage]
}

private struct OpenCodeSQLiteSessionSeed {
    let id: String
    let directory: String?
    let providerID: String?
    let modelID: String?
    let cost: Double
    let aggregateUsage: TokenUsage
    let createdAt: Date
    let updatedAt: Date
    let sourceFile: URL
}

private struct OpenCodeSQLiteAssistantMessage {
    let id: String
    let sessionID: String
    let providerID: String
    let modelID: String
    let timestamp: Date
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let costUSD: Double
    let usage: TokenUsage

    var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheCreationTokens
    }
}

private struct OpenCodeBreakdownAccumulator {
    let groupName: String
    let providerID: String
    let modelID: String
    var sessionIDs: Set<String> = []
    var messageCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var costUSD: Double = 0

    mutating func add(_ message: OpenCodeSQLiteAssistantMessage) {
        sessionIDs.insert(message.sessionID)
        messageCount += 1
        inputTokens += message.inputTokens
        outputTokens += message.outputTokens
        reasoningTokens += message.reasoningTokens
        cacheReadTokens += message.cacheReadTokens
        cacheCreationTokens += message.cacheCreationTokens
        costUSD += message.costUSD
    }

    var snapshot: ProviderUsageBreakdown {
        ProviderUsageBreakdown(
            groupName: groupName,
            providerID: providerID,
            modelID: modelID,
            sessionCount: sessionIDs.count,
            messageCount: messageCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            costUSD: costUSD
        )
    }
}
