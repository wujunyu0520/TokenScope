import Foundation
import TokenScopeCore

@MainActor
final class UsageSettingsStore: ObservableObject {
    @Published var zaiRegion: ZaiAPIRegion {
        didSet {
            UserDefaults.standard.set(zaiRegion.rawValue, forKey: Self.zaiRegionKey)
        }
    }

    @Published private(set) var codexAccounts: [CodexManagedAccount] = []
    @Published var codexActiveSource: CodexActiveSource {
        didSet {
            saveCodexActiveSource()
        }
    }

    private let keychain = KeychainSecretStore()
    private let codexAccountStore = FileCodexManagedAccountStore()
    private static let zaiRegionKey = "usage.zai.region"
    private static let zaiAPIKeyAccount = "zai-api-key"
    private static let codexActiveSourceKey = "usage.codex.activeSource"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.zaiRegionKey)
        self.zaiRegion = raw.flatMap(ZaiAPIRegion.init(rawValue:)) ?? .global

        if let data = UserDefaults.standard.data(forKey: Self.codexActiveSourceKey),
           let decoded = try? JSONDecoder().decode(CodexActiveSource.self, from: data) {
            self.codexActiveSource = decoded
        } else {
            self.codexActiveSource = .liveSystem
        }

        reloadCodexAccounts()
        normalizeCodexActiveSource()
    }

    func loadZaiAPIKey() -> String {
        keychain.load(account: Self.zaiAPIKeyAccount) ?? ""
    }

    func saveZaiAPIKey(_ value: String) {
        keychain.store(value, account: Self.zaiAPIKeyAccount)
    }

    func hasZaiAPIKey() -> Bool {
        !(keychain.load(account: Self.zaiAPIKeyAccount) ?? "").isEmpty
    }

    func reloadCodexAccounts() {
        let snapshot = (try? codexAccountStore.loadAccounts()) ?? CodexManagedAccountSet(version: FileCodexManagedAccountStore.currentVersion, accounts: [])
        codexAccounts = snapshot.accounts.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.email < rhs.email
        }
        normalizeCodexActiveSource()
    }

    func saveCodexAccounts(_ accounts: [CodexManagedAccount]) throws {
        try codexAccountStore.storeAccounts(CodexManagedAccountSet(version: FileCodexManagedAccountStore.currentVersion, accounts: accounts))
        reloadCodexAccounts()
    }

    func setCodexActiveAccount(id: UUID?) {
        codexActiveSource = id.map { .managedAccount(id: $0) } ?? .liveSystem
    }

    func selectedCodexAccount() -> CodexManagedAccount? {
        guard case let .managedAccount(id) = codexActiveSource else { return nil }
        return codexAccounts.first { $0.id == id }
    }

    func codexAccountOptions() -> [Account] {
        let live = Account(id: "live-system", provider: .codex, identifier: "live-system", displayName: L10n.string("System account"))
        let managed = codexAccounts.map {
            Account(
                id: $0.id.uuidString,
                provider: .codex,
                identifier: $0.providerAccountID ?? $0.email,
                displayName: $0.email
            )
        }
        return [live] + managed
    }

    private func normalizeCodexActiveSource() {
        if case let .managedAccount(id) = codexActiveSource,
           codexAccounts.contains(where: { $0.id == id }) == false {
            codexActiveSource = .liveSystem
        }
    }

    private func saveCodexActiveSource() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(codexActiveSource) else { return }
        UserDefaults.standard.set(data, forKey: Self.codexActiveSourceKey)
    }
}
