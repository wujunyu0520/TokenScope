import Foundation
import SwiftUI
import TokenScopeCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var usageRecords: [UsageRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var cacheUpdatedAt: Date?
    @Published private(set) var providerUsageSnapshots: [Provider: ProviderUsageSnapshot] = [:]
    @Published private(set) var usageRefreshStates: [Provider: UsageRefreshState] = [:]
    @Published private(set) var usageErrors: [Provider: String] = [:]

    let priceBook = PriceBook()
    let usageCache = UsageCache()
    let providerUsageCache = ProviderUsageCache()
    let detailLoader = SessionDetailLoader()
    let usageSettings = UsageSettingsStore()
    let codexLoginController = CodexAccountLoginController()
    lazy var aggregator = UsageAggregator(priceBook: priceBook)

    @Published var pricesRevision: Int = 0

    func upsertPrice(_ price: ModelPrice) {
        priceBook.upsert(price)
        pricesRevision &+= 1
    }

    func removePrice(model: String) {
        priceBook.remove(modelName: model)
        pricesRevision &+= 1
    }

    func loadCached() {
        if let snapshot = usageCache.load() {
            self.sessions = snapshot.sessions.sorted { $0.startedAt > $1.startedAt }
            self.usageRecords = snapshot.records
            self.cacheUpdatedAt = snapshot.updatedAt
        }
        if let providerSnapshot = providerUsageCache.load() {
            self.providerUsageSnapshots = Dictionary(uniqueKeysWithValues: providerSnapshot.snapshots.map { ($0.provider, $0) })
        }
    }

    func loadAll() async {
        isLoading = true
        defer { isLoading = false }

        let cached = usageCache.load()
        let scanned = await Task.detached(priority: .userInitiated) {
            let claude = ClaudeCodeScanner().scan()
            let codex = CodexScanner().scan()
            let opencode = OpenCodeScanner().scan()
            let sessions: [SessionRecord] = claude.map(\.session) + codex.map(\.session) + opencode.map(\.session)
            var records: [UsageRecord] = []
            records.append(contentsOf: claude.flatMap(\.usageRecords))
            records.append(contentsOf: codex.flatMap(\.usageRecords))
            records.append(contentsOf: opencode.flatMap(\.usageRecords))
            return (sessions, records)
        }.value

        let merged = UsageCache.merge(
            cached: cached,
            scannedSessions: scanned.0,
            scannedRecords: scanned.1
        )
        self.sessions = merged.sessions
        self.usageRecords = merged.records

        let sessionsCopy = merged.sessions
        let recordsCopy = merged.records
        let cache = usageCache
        Task.detached(priority: .background) {
            cache.save(sessions: sessionsCopy, records: recordsCopy)
        }
        self.cacheUpdatedAt = Date()
    }

    func loadDetail(for session: SessionRecord) async -> SessionDetail {
        let records = usageRecords
        let loader = detailLoader
        return await Task.detached(priority: .userInitiated) {
            (try? loader.loadDetail(for: session, usageRecords: records))
                ?? SessionDetail(
                    session: session,
                    mode: .usageOnly,
                    usageRecords: records.filter { $0.provider == session.provider && $0.sessionId == session.id }.sorted { $0.timestamp < $1.timestamp },
                    notice: L10n.string("Failed to load detailed session records.")
                )
        }.value
    }

    func refreshUsage() async {
        for provider in [Provider.claudeCode, .codex, .zai] {
            await refreshUsage(for: provider)
        }
    }

    func refreshUsage(for provider: Provider) async {
        usageRefreshStates[provider] = .loading
        usageErrors[provider] = nil

        do {
            let snapshot: ProviderUsageSnapshot
            switch provider {
            case .claudeCode:
                snapshot = try await ClaudeCodeUsageProvider(sessions: sessions).fetchSnapshot()
            case .codex:
                snapshot = try await CodexUsageProvider(
                    sessions: sessions,
                    usageRecords: usageRecords,
                    priceBook: priceBook,
                    accounts: usageSettings.codexAccounts,
                    activeSource: usageSettings.codexActiveSource
                ).fetchSnapshot()
            case .zai:
                let apiKey = usageSettings.loadZaiAPIKey()
                snapshot = try await ZaiUsageProvider(apiKey: apiKey, region: usageSettings.zaiRegion).fetchSnapshot()
            default:
                throw NSError(
                    domain: "TokenScope",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.string("Usage is unavailable for this provider.")]
                )
            }

            providerUsageSnapshots[provider] = snapshot
            usageRefreshStates[provider] = .loaded
            usageErrors[provider] = nil
            providerUsageCache.save(snapshots: providerUsageSnapshots.values.sorted { $0.provider.rawValue < $1.provider.rawValue })
        } catch {
            usageRefreshStates[provider] = .failed
            usageErrors[provider] = error.localizedDescription
        }
    }

    func setCodexActiveAccount(id: UUID?) async {
        usageSettings.setCodexActiveAccount(id: id)
        await refreshUsage(for: .codex)
    }

    func addCodexAccount() async throws {
        _ = try await codexLoginController.authenticateManagedAccount()
        usageSettings.reloadCodexAccounts()
        if let newest = usageSettings.codexAccounts.first {
            usageSettings.setCodexActiveAccount(id: newest.id)
        }
        await refreshUsage(for: .codex)
    }

    func reloadCodexAccounts() {
        usageSettings.reloadCodexAccounts()
    }
}
