import Foundation

public struct UsageCacheSnapshot: Codable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let updatedAt: Date
    public let sessions: [SessionRecord]
    public let records: [UsageRecord]

    public init(version: Int = currentVersion, updatedAt: Date, sessions: [SessionRecord], records: [UsageRecord]) {
        self.version = version
        self.updatedAt = updatedAt
        self.sessions = sessions
        self.records = records
    }
}

public final class UsageCache: @unchecked Sendable {
    public let storageURL: URL?

    public init(storageURL: URL? = UsageCache.defaultStorageURL) {
        self.storageURL = storageURL
    }

    public static var defaultStorageURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base
            .appendingPathComponent("TokenScope", isDirectory: true)
            .appendingPathComponent("usage_cache.json")
    }

    public func load() -> UsageCacheSnapshot? {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(UsageCacheSnapshot.self, from: data),
              snapshot.version == UsageCacheSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    public func save(sessions: [SessionRecord], records: [UsageRecord]) {
        guard let url = storageURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = UsageCacheSnapshot(updatedAt: Date(), sessions: sessions, records: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func sessionKey(provider: Provider, id: String) -> String {
        "\(provider.rawValue):\(id)"
    }

    public static func recordKey(provider: Provider, sessionId: String, messageIndex: Int) -> String {
        "\(provider.rawValue):\(sessionId)#\(messageIndex)"
    }

    public static func merge(
        cached: UsageCacheSnapshot?,
        scannedSessions: [SessionRecord],
        scannedRecords: [UsageRecord]
    ) -> (sessions: [SessionRecord], records: [UsageRecord]) {
        var sessionMap: [String: SessionRecord] = [:]
        var recordMap: [String: UsageRecord] = [:]

        if let cached {
            for s in cached.sessions where !Self.isEmptyClaudeSession(s) {
                sessionMap[sessionKey(provider: s.provider, id: s.id)] = s
            }
            for r in cached.records {
                recordMap[recordKey(provider: r.provider, sessionId: r.sessionId, messageIndex: r.messageIndex)] = r
            }
        }

        let scannedSessionKeys = Set(scannedSessions.map { sessionKey(provider: $0.provider, id: $0.id) })
        for key in scannedSessionKeys {
            recordMap = recordMap.filter { entry in
                sessionKey(provider: entry.value.provider, id: entry.value.sessionId) != key
            }
        }

        for s in scannedSessions {
            sessionMap[sessionKey(provider: s.provider, id: s.id)] = s
        }
        for r in scannedRecords {
            recordMap[recordKey(provider: r.provider, sessionId: r.sessionId, messageIndex: r.messageIndex)] = r
        }

        let sessions = sessionMap.values.sorted { $0.startedAt > $1.startedAt }
        let records = Array(recordMap.values)
        return (sessions, records)
    }

    private static func isEmptyClaudeSession(_ session: SessionRecord) -> Bool {
        session.provider == .claudeCode
            && (session.messageCount == 0 || session.totalUsage.totalTokens == 0)
    }
}
