import SwiftUI
import TokenScopeCore

struct UsageView: View {
    @EnvironmentObject private var store: AppStore
    @State private var now = Date()

    private let providers: [Provider] = [.claudeCode, .codex, .zai]

    private var lastUpdatedText: String {
        let latest = store.providerUsageSnapshots.values.map(\.updatedAt).max()
        return latest?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("Provider Usage"))
                            .font(.title2).bold()
                        Text(L10n.string("Last updated: %@", lastUpdatedText))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        now = Date()
                        Task { await store.refreshUsage() }
                    } label: {
                        Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                    }
                }

                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(providers, id: \.self) { provider in
                        UsageProviderCard(
                            provider: provider,
                            snapshot: store.providerUsageSnapshots[provider],
                            state: store.usageRefreshStates[provider] ?? .idle,
                            errorMessage: store.usageErrors[provider],
                            now: now,
                            refresh: {
                                now = Date()
                                Task { await store.refreshUsage(for: provider) }
                            },
                            selectAccount: { accountID in
                                guard provider == .codex else { return }
                                Task {
                                    if accountID == "live-system" {
                                        await store.setCodexActiveAccount(id: nil)
                                    } else if let uuid = UUID(uuidString: accountID) {
                                        await store.setCodexActiveAccount(id: uuid)
                                    }
                                }
                            }
                        )
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(L10n.string("Usage"))
        .task {
            if store.providerUsageSnapshots.isEmpty {
                await store.refreshUsage()
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
    }
}

private struct UsageProviderCard: View {
    let provider: Provider
    let snapshot: ProviderUsageSnapshot?
    let state: UsageRefreshState
    let errorMessage: String?
    let now: Date
    let refresh: () -> Void
    let selectAccount: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            divider
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            Circle()
                .fill(color(for: provider))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.headline)
                    if let planName = snapshot?.planName {
                        Text(planName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(color(for: provider).opacity(0.15), in: Capsule())
                            .foregroundStyle(color(for: provider))
                    }
                }
                if let email = snapshot?.accountDisplayName ?? snapshot?.identitySummary {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let sourceLabel = snapshot?.sourceLabel {
                    Text(sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(L10n.string("Refresh")) { refresh() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        if state == .loading && snapshot == nil {
            HStack {
                ProgressView()
                Text(L10n.string("Refreshing…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        } else if let snapshot {
            if provider == .codex,
               !snapshot.accountOptions.isEmpty {
                Picker(L10n.string("Account"), selection: Binding(
                    get: { snapshot.selectedAccountID ?? "live-system" },
                    set: { selectAccount($0) }
                )) {
                    ForEach(snapshot.accountOptions) { account in
                        Text(account.displayName).tag(account.id)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
            }

            if snapshot.windows.isEmpty {
                Text(snapshot.notice ?? L10n.string("No usage data available."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(snapshot.windows) { window in
                        UsageWindowRow(
                            window: window,
                            color: color(for: provider),
                            now: now
                        )
                        if window.id != snapshot.windows.last?.id {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.1))
                                .frame(height: 1)
                        }
                    }
                }
            }

            if let creditsText = snapshot.creditsText {
                Text(creditsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !snapshot.costRows.isEmpty {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("Cost"))
                        .font(.subheadline).bold()
                    ForEach(Array(snapshot.costRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.title)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(row.amountText)
                                .monospacedDigit()
                            if let detail = row.detailText {
                                Text(detail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
            }

            if let notice = snapshot.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 40)
        } else {
            Text(emptyText(for: provider))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private func color(for provider: Provider) -> Color {
        switch provider {
        case .claudeCode:
            return .orange
        case .codex:
            return Color(red: 0.165, green: 0.616, blue: 0.561)
        case .zai:
            return .purple
        default:
            return .accentColor
        }
    }

    private func emptyText(for provider: Provider) -> String {
        switch provider {
        case .zai:
            return L10n.string("Configure a z.ai API key in Settings to load usage.")
        case .claudeCode, .codex:
            return L10n.string("No usage data available yet.")
        default:
            return L10n.string("No usage data available.")
        }
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindowSnapshot
    let color: Color
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.subheadline).bold()
                Spacer()
                Text(percentText)
                    .font(.title3).bold()
                    .monospacedDigit()
            }

            progressBar

            HStack(alignment: .firstTextBaseline) {
                if let usageText {
                    Text(usageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if let reserveText {
                    Text(reserveText)
                        .font(.caption2)
                        .foregroundStyle(Color.green)
                }
                Spacer()
                if let resetText {
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var percentText: String {
        L10n.string("%d%% left", Int(window.remainingPercent.rounded()))
    }

    private var usageText: String? {
        guard let used = window.usedValue, let limit = window.limitValue, limit > 0 else { return nil }
        if window.unitLabel == "tokens" {
            return "\(TokenDisplayFormatter.hundredMillions(used)) / \(TokenDisplayFormatter.hundredMillions(limit))"
        }

        let usedStr = formatCount(used)
        let limitStr = formatCount(limit)
        if let unit = window.unitLabel, !unit.isEmpty {
            return "\(usedStr) / \(limitStr) \(unit)"
        }
        return "\(usedStr) / \(limitStr)"
    }

    private func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    @ViewBuilder
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(color.opacity(0.2))
                Rectangle()
                    .fill(color)
                    .frame(width: geo.size.width * (window.remainingPercent / 100.0))
                if let reserve = window.reservePercent, reserve < 0 {
                    let expectedX = geo.size.width * ((100 - window.usedPercent + reserve) / 100.0)
                    Rectangle()
                        .fill(Color.red.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: expectedX)
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var reserveText: String? {
        guard let reserve = window.reservePercent else { return nil }
        let value = Int(abs(reserve).rounded())
        guard value >= 1 else { return nil }
        if reserve < 0 {
            return L10n.string("%d%% over pace", value)
        } else {
            return L10n.string("%d%% in reserve", value)
        }
    }

    private var resetText: String? {
        if let resetsAt = window.resetsAt {
            let text = resetCountdown(from: resetsAt, now: now)
            return L10n.string("Resets %@", text)
        }
        return window.resetDescription
    }

    private func resetCountdown(from date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 1 { return L10n.string("now") }
        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return L10n.string("in %dd %dh", days, hours) }
            return L10n.string("in %dd", days)
        }
        if hours > 0 {
            if minutes > 0 { return L10n.string("in %dh %dm", hours, minutes) }
            return L10n.string("in %dh", hours)
        }
        return L10n.string("in %dm", totalMinutes)
    }
}
