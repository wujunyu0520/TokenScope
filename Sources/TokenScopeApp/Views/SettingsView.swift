import SwiftUI
import AppKit
import TokenScopeCore

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var zaiAPIKey = ""
    @State private var zaiRegion: ZaiAPIRegion = .global
    @State private var codexLoginError: String?
    @State private var isAddingCodexAccount = false

    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var claudeDataDir: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private var codexDataDir: URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private var openCodeDataDir: URL {
        home.appendingPathComponent(".local/share/opencode/storage", isDirectory: true)
    }

    private var localCacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("TokenScope", isDirectory: true)
    }

    var body: some View {
        Form {
            Section(L10n.string("About")) {
                LabeledContent(L10n.string("Version"), value: TokenScopeCore.version)
            }

            Section(L10n.string("Usage Providers")) {
                SecureField("z.ai API Key", text: $zaiAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveZaiAPIKey)
                HStack {
                    Picker(L10n.string("z.ai Region"), selection: $zaiRegion) {
                        ForEach(ZaiAPIRegion.allCases, id: \.self) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: zaiRegion) { _, newValue in
                        store.usageSettings.zaiRegion = newValue
                        Task { await store.refreshUsage(for: .zai) }
                    }
                    Button(L10n.string("Save")) { saveZaiAPIKey() }
                }
                LabeledContent("Claude Code", value: providerStatusText(.claudeCode))
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Codex", value: providerStatusText(.codex))
                    HStack {
                        Picker(L10n.string("Codex Account"), selection: codexAccountBinding) {
                            Text(L10n.string("System account")).tag("live-system")
                            ForEach(store.usageSettings.codexAccounts, id: \.id) { account in
                                Text(account.email).tag(account.id.uuidString)
                            }
                        }
                        .pickerStyle(.menu)
                        Button(isAddingCodexAccount ? L10n.string("Signing in…") : L10n.string("Add Account")) {
                            addCodexAccount()
                        }
                        .disabled(isAddingCodexAccount)
                    }
                    if let codexLoginError {
                        Text(codexLoginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                LabeledContent(
                    "z.ai",
                    value: store.usageSettings.hasZaiAPIKey()
                        ? L10n.string("Configured")
                        : L10n.string("Missing API key")
                )
            }

            Section(L10n.string("Directories")) {
                SettingsPathRow(title: L10n.string("Claude Code data dir"), url: claudeDataDir)
                SettingsPathRow(title: L10n.string("Codex data dir"), url: codexDataDir)
                SettingsPathRow(title: L10n.string("OpenCode data dir"), url: openCodeDataDir)
                SettingsPathRow(title: L10n.string("Local cache dir"), url: localCacheDir)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Settings"))
        .onAppear {
            zaiAPIKey = store.usageSettings.loadZaiAPIKey()
            zaiRegion = store.usageSettings.zaiRegion
        }
    }

    private var codexAccountBinding: Binding<String> {
        Binding(
            get: {
                switch store.usageSettings.codexActiveSource {
                case .liveSystem:
                    return "live-system"
                case let .managedAccount(id):
                    return id.uuidString
                }
            },
            set: { newValue in
                codexLoginError = nil
                Task {
                    if newValue == "live-system" {
                        await store.setCodexActiveAccount(id: nil)
                    } else if let uuid = UUID(uuidString: newValue) {
                        await store.setCodexActiveAccount(id: uuid)
                    }
                }
            }
        )
    }

    private func saveZaiAPIKey() {
        store.usageSettings.saveZaiAPIKey(zaiAPIKey)
        Task { await store.refreshUsage(for: .zai) }
    }

    private func addCodexAccount() {
        codexLoginError = nil
        isAddingCodexAccount = true
        Task {
            do {
                try await store.addCodexAccount()
            } catch {
                codexLoginError = error.localizedDescription
            }
            isAddingCodexAccount = false
        }
    }

    private func providerStatusText(_ provider: Provider) -> String {
        switch store.usageRefreshStates[provider] ?? .idle {
        case .idle:
            return store.providerUsageSnapshots[provider] == nil ? L10n.string("Not refreshed") : L10n.string("Cached")
        case .loading:
            return L10n.string("Refreshing...")
        case .loaded:
            return L10n.string("Ready")
        case .failed:
            return store.usageErrors[provider] ?? L10n.string("Failed")
        }
    }
}

private struct SettingsPathRow: View {
    let title: String
    let url: URL

    var body: some View {
        LabeledContent(title) {
            Button(url.path) {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.path)
        }
    }
}
