import Foundation

public struct OpenCodeParseResult: Sendable {
    public let session: SessionRecord
    public let usageRecords: [UsageRecord]
}

public struct OpenCodeParser: Sendable {
    public init() {}

    public func parse(sessionFile: URL, messageDir: URL) throws -> OpenCodeParseResult {
        let sessionData = try Data(contentsOf: sessionFile)
        guard let sessionObj = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any] else {
            throw ClaudeCodeParseError.emptyFile
        }

        let sessionId = (sessionObj["id"] as? String) ?? sessionFile.deletingPathExtension().lastPathComponent
        let projectPath = sessionObj["directory"] as? String
        let time = sessionObj["time"] as? [String: Any]
        let createdMs = (time?["created"] as? Double) ?? 0
        let updatedMs = (time?["updated"] as? Double) ?? createdMs

        let fm = FileManager.default
        var usageRecords: [UsageRecord] = []
        var modelsSet: Set<String> = []
        var total = TokenUsage.zero
        var messageIndex = 0
        var firstMsgTime: Date?
        var lastMsgTime: Date?

        let msgFiles = (try? fm.contentsOfDirectory(at: messageDir, includingPropertiesForKeys: nil))
            ?? []
        let sortedMsgFiles = msgFiles
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("msg_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in sortedMsgFiles {
            guard let data = try? Data(contentsOf: url),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard (obj["role"] as? String) == "assistant" else { continue }

            let model = (obj["modelID"] as? String) ?? "unknown"
            let providerID = obj["providerID"] as? String
            let tokens = obj["tokens"] as? [String: Any]
            let input = (tokens?["input"] as? Int) ?? 0
            let output = (tokens?["output"] as? Int) ?? 0
            let reasoning = (tokens?["reasoning"] as? Int) ?? 0
            let cache = tokens?["cache"] as? [String: Any]
            let cacheRead = (cache?["read"] as? Int) ?? 0
            let cacheWrite = (cache?["write"] as? Int) ?? 0
            let effectiveOutput = output + reasoning

            let usage = TokenUsage(
                inputTokens: input,
                outputTokens: effectiveOutput,
                cacheCreationTokens: cacheWrite,
                cacheReadTokens: cacheRead
            )

            let msgTime = obj["time"] as? [String: Any]
            let createdAtMs = (msgTime?["created"] as? Double) ?? 0
            let ts = Date(timeIntervalSince1970: createdAtMs / 1000.0)
            if firstMsgTime == nil { firstMsgTime = ts }
            lastMsgTime = ts

            modelsSet.insert(model)

            guard usage.totalTokens > 0 else {
                messageIndex += 1
                continue
            }

            usageRecords.append(UsageRecord(
                sessionId: sessionId,
                messageIndex: messageIndex,
                provider: .openCode,
                accountId: providerID,
                model: model,
                timestamp: ts,
                usage: usage
            ))
            total += usage
            messageIndex += 1
        }

        let start = firstMsgTime ?? Date(timeIntervalSince1970: createdMs / 1000.0)
        let end = lastMsgTime ?? Date(timeIntervalSince1970: updatedMs / 1000.0)
        let session = SessionRecord(
            id: sessionId,
            provider: .openCode,
            accountId: nil,
            projectPath: projectPath,
            sourceFile: sessionFile,
            startedAt: start,
            endedAt: end,
            modelsUsed: Array(modelsSet).sorted(),
            totalUsage: total,
            messageCount: messageIndex
        )
        return OpenCodeParseResult(session: session, usageRecords: usageRecords)
    }
}

public struct OpenCodeScanner: Sendable {
    public let storageRoot: URL
    public let parser: OpenCodeParser

    public init(storageRoot: URL? = nil, parser: OpenCodeParser = OpenCodeParser()) {
        if let storageRoot {
            self.storageRoot = storageRoot
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.storageRoot = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        }
        self.parser = parser
    }

    public func scan() -> [OpenCodeParseResult] {
        let databaseURL = storageRoot.appendingPathComponent("opencode.db")
        if FileManager.default.fileExists(atPath: databaseURL.path),
           let results = try? OpenCodeSQLiteParser().parse(databaseURL: databaseURL) {
            return results
        }

        let legacyStorageRoot = storageRoot.lastPathComponent == "storage"
            ? storageRoot
            : storageRoot.appendingPathComponent("storage", isDirectory: true)
        let fm = FileManager.default
        let sessionRoot = legacyStorageRoot.appendingPathComponent("session", isDirectory: true)
        let messageRoot = legacyStorageRoot.appendingPathComponent("message", isDirectory: true)
        guard fm.fileExists(atPath: sessionRoot.path) else { return [] }

        var results: [OpenCodeParseResult] = []
        let projectDirs = (try? fm.contentsOfDirectory(at: sessionRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let sessionFiles = (try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)) ?? []
            for sessionFile in sessionFiles where sessionFile.pathExtension == "json"
                && sessionFile.lastPathComponent.hasPrefix("ses_") {
                let sessionId = sessionFile.deletingPathExtension().lastPathComponent
                let messageDir = messageRoot.appendingPathComponent(sessionId, isDirectory: true)
                if let res = try? parser.parse(sessionFile: sessionFile, messageDir: messageDir) {
                    results.append(res)
                }
            }
        }
        return results
    }
}
