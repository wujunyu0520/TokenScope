import Foundation

public struct ProviderUsageCacheSnapshot: Codable, Sendable {
    public static let currentVersion = 3

    public let version: Int
    public let updatedAt: Date
    public let snapshots: [ProviderUsageSnapshot]

    public init(version: Int = currentVersion, updatedAt: Date, snapshots: [ProviderUsageSnapshot]) {
        self.version = version
        self.updatedAt = updatedAt
        self.snapshots = snapshots
    }
}

public final class ProviderUsageCache: @unchecked Sendable {
    public let storageURL: URL?

    public init(storageURL: URL? = ProviderUsageCache.defaultStorageURL) {
        self.storageURL = storageURL
    }

    public static var defaultStorageURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base
            .appendingPathComponent("TokenScope", isDirectory: true)
            .appendingPathComponent("provider_usage_cache.json")
    }

    public func load() -> ProviderUsageCacheSnapshot? {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(ProviderUsageCacheSnapshot.self, from: data),
              snapshot.version == ProviderUsageCacheSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    public func save(snapshots: [ProviderUsageSnapshot]) {
        guard let url = storageURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = ProviderUsageCacheSnapshot(updatedAt: Date(), snapshots: snapshots)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
