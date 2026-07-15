import Foundation

public struct SessionDetailLoader: Sendable {
    public init() {}

    public func loadDetail(for session: SessionRecord, usageRecords: [UsageRecord]) throws -> SessionDetail {
        let records = usageRecords
            .filter { $0.provider == session.provider && $0.sessionId == session.id }
            .sorted { $0.timestamp < $1.timestamp }
        switch session.provider {
        case .claudeCode:
            return try loadClaudeDetail(for: session, usageRecords: records)
        case .openCode:
            return try loadOpenCodeDetail(for: session, usageRecords: records)
        case .codex:
            return SessionDetail(
                session: session,
                mode: .usageOnly,
                usageRecords: records,
                notice: CoreL10n.string("Transcript unavailable for Codex yet; showing usage events.")
            )
        default:
            return SessionDetail(
                session: session,
                mode: .usageOnly,
                usageRecords: records,
                notice: CoreL10n.string("Detailed transcript is unavailable for this provider.")
            )
        }
    }

    private func loadClaudeDetail(
        for session: SessionRecord,
        usageRecords: [UsageRecord]
    ) throws -> SessionDetail {
        let data = try Data(contentsOf: session.sourceFile)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var messages: [SessionMessage] = []

        for rawLine in data.split(separator: UInt8(ascii: "\n")) {
            guard !rawLine.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  let type = obj["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let message = obj["message"] as? [String: Any]
            else { continue }

            let timestamp: Date = {
                if let s = obj["timestamp"] as? String, let d = iso.date(from: s) { return d }
                return session.startedAt
            }()
            let role = (message["role"] as? String) ?? type
            let model = message["model"] as? String
            let usageDict = message["usage"] as? [String: Any]
            let usage = TokenUsage(
                inputTokens: (usageDict?["input_tokens"] as? Int) ?? 0,
                outputTokens: (usageDict?["output_tokens"] as? Int) ?? 0,
                cacheCreationTokens: (usageDict?["cache_creation_input_tokens"] as? Int) ?? 0,
                cacheReadTokens: (usageDict?["cache_read_input_tokens"] as? Int) ?? 0
            )
            let contentText = flattenClaudeContent(message["content"])
            let preview = contentText?.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(SessionMessage(
                id: (obj["uuid"] as? String) ?? UUID().uuidString,
                role: role,
                model: model,
                usage: usage,
                timestamp: timestamp,
                contentText: contentText,
                contentPreview: preview.map { String($0.prefix(240)) }
            ))
        }

        return SessionDetail(
            session: session,
            mode: .messages,
            messages: messages.sorted { $0.timestamp < $1.timestamp },
            usageRecords: usageRecords
        )
    }

    private func loadOpenCodeDetail(
        for session: SessionRecord,
        usageRecords: [UsageRecord]
    ) throws -> SessionDetail {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let messageDir = home
            .appendingPathComponent(".local/share/opencode/storage/message", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: messageDir, includingPropertiesForKeys: nil)) ?? []
        let sortedFiles = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("msg_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var messages: [SessionMessage] = []
        for file in sortedFiles {
            guard let data = try? Data(contentsOf: file),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = obj["role"] as? String
            else { continue }

            let time = obj["time"] as? [String: Any]
            let createdMs = (time?["created"] as? Double) ?? 0
            let timestamp = Date(timeIntervalSince1970: createdMs / 1000.0)
            let model = (obj["modelID"] as? String) ?? ((obj["model"] as? [String: Any])?["modelID"] as? String)
            let tokens = obj["tokens"] as? [String: Any]
            let cache = tokens?["cache"] as? [String: Any]
            let usage = TokenUsage(
                inputTokens: (tokens?["input"] as? Int) ?? 0,
                outputTokens: ((tokens?["output"] as? Int) ?? 0) + ((tokens?["reasoning"] as? Int) ?? 0),
                cacheCreationTokens: (cache?["write"] as? Int) ?? 0,
                cacheReadTokens: (cache?["read"] as? Int) ?? 0
            )
            let summary = (obj["summary"] as? [String: Any])?["title"] as? String
            let errorMessage = ((obj["error"] as? [String: Any])?["message"] as? String)
            let content = errorMessage ?? summary
            messages.append(SessionMessage(
                id: (obj["id"] as? String) ?? UUID().uuidString,
                role: role,
                model: model,
                usage: usage,
                timestamp: timestamp,
                contentText: content,
                contentPreview: content
            ))
        }

        return SessionDetail(
            session: session,
            mode: .messages,
            messages: messages.sorted { $0.timestamp < $1.timestamp },
            usageRecords: usageRecords,
            notice: CoreL10n.string("OpenCode currently exposes summaries, usage, and errors rather than full transcript text.")
        )
    }

    private func flattenClaudeContent(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        guard let blocks = raw as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String else { return nil }
            switch type {
            case "text":
                return block["text"] as? String
            case "thinking":
                return nil
            default:
                return nil
            }
        }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
