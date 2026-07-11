import Foundation

public struct ClaudeCodeParseResult: Sendable {
    public let session: SessionRecord
    public let usageRecords: [UsageRecord]
}

public enum ClaudeCodeParseError: Error {
    case emptyFile
    case invalidFormat(String)
}

public struct ClaudeCodeParser: Sendable {
    public init() {}

    public func parse(fileURL: URL) throws -> ClaudeCodeParseResult {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw ClaudeCodeParseError.emptyFile }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var embeddedSessionID: String?
        var projectCwd: String?
        var startedAt: Date?
        var endedAt: Date?
        var usageEvents: [(model: String, timestamp: Date, usage: TokenUsage)] = []
        var modelsSet: Set<String> = []
        var total = TokenUsage.zero

        let lines = data.split(separator: UInt8(ascii: "\n"))
        for rawLine in lines {
            guard !rawLine.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any]
            else { continue }

            if embeddedSessionID == nil,
               let candidate = obj["sessionId"] as? String,
               !candidate.isEmpty {
                embeddedSessionID = candidate
            }

            if let cwd = obj["cwd"] as? String { projectCwd = cwd }

            if let ts = obj["timestamp"] as? String, let d = iso.date(from: ts) {
                if startedAt == nil { startedAt = d }
                endedAt = d
            }

            guard let type = obj["type"] as? String, type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any],
                  let model = message["model"] as? String
            else { continue }

            let usage = TokenUsage(
                inputTokens: (usageDict["input_tokens"] as? Int) ?? 0,
                outputTokens: (usageDict["output_tokens"] as? Int) ?? 0,
                cacheCreationTokens: (usageDict["cache_creation_input_tokens"] as? Int) ?? 0,
                cacheReadTokens: (usageDict["cache_read_input_tokens"] as? Int) ?? 0
            )
            guard usage.totalTokens > 0 else { continue }

            let ts: Date = {
                if let s = obj["timestamp"] as? String, let d = iso.date(from: s) { return d }
                return endedAt ?? Date()
            }()

            usageEvents.append((model: model, timestamp: ts, usage: usage))
            modelsSet.insert(model)
            total += usage
        }

        let sessionId = stableSessionID(for: fileURL, embeddedSessionID: embeddedSessionID)
        let usageRecords = usageEvents.enumerated().map { messageIndex, event in
            UsageRecord(
                sessionId: sessionId,
                messageIndex: messageIndex,
                provider: .claudeCode,
                accountId: nil,
                model: event.model,
                timestamp: event.timestamp,
                usage: event.usage
            )
        }
        let start = startedAt ?? Date()
        let end = endedAt ?? start

        let session = SessionRecord(
            id: sessionId,
            provider: .claudeCode,
            accountId: nil,
            projectPath: projectCwd,
            sourceFile: fileURL,
            startedAt: start,
            endedAt: end,
            modelsUsed: Array(modelsSet).sorted(),
            totalUsage: total,
            messageCount: usageRecords.count
        )
        return ClaudeCodeParseResult(session: session, usageRecords: usageRecords)
    }

    private func stableSessionID(for fileURL: URL, embeddedSessionID: String?) -> String {
        let path = fileURL.path
        if path.contains("/subagents/") {
            let base = fileURL.deletingPathExtension().lastPathComponent
            return "subagent:\(base)"
        }
        return embeddedSessionID ?? fileURL.deletingPathExtension().lastPathComponent
    }
}
