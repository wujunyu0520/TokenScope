import SwiftUI
import TokenScopeCore

struct UsageView: View {
    @EnvironmentObject private var store: AppStore
    @State private var now = Date()

    private let providers: [Provider] = [.claudeCode, .codex, .openCode, .zai]

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
            now = Date()
            await store.refreshUsage()
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
            if let sourceExplanation {
                Text(sourceExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
        switch dataStatus {
        case .unavailable:
            unavailableContent
        case .cached(let updatedAt):
            if let snapshot {
                cachedStatus(updatedAt: updatedAt)
                snapshotContent(snapshot)
            } else {
                unavailableContent
            }
        case .refreshing(let previousUpdate):
            if let snapshot, let previousUpdate {
                refreshingStatus(previousUpdate: previousUpdate)
                snapshotContent(snapshot)
            } else {
                loadingContent
            }
        case .current(let updatedAt):
            if let snapshot {
                currentStatus(updatedAt: updatedAt)
                snapshotContent(snapshot)
            } else {
                unavailableContent
            }
        case .stale(let updatedAt, let message):
            if let snapshot {
                staleStatus(updatedAt: updatedAt, message: message)
                snapshotContent(snapshot)
            } else {
                failedContent(message: message)
            }
        case .failed(let message):
            failedContent(message: message)
        }
    }

    private var dataStatus: UsageDataStatus {
        UsageDataStatus.resolve(
            snapshot: snapshot,
            refreshState: state,
            errorMessage: errorMessage
        )
    }

    @ViewBuilder
    private var loadingContent: some View {
        HStack {
            ProgressView()
            Text(L10n.string("Refreshing…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    @ViewBuilder
    private var unavailableContent: some View {
        Text(emptyText(for: provider))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 40)
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: ProviderUsageSnapshot) -> some View {
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
                Text(L10n.string("API cost estimate"))
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
                    if row.unpricedRecordCount > 0 {
                        Label(
                            L10n.string(
                                "%d records are excluded from cost because %d models are unpriced: %@",
                                row.unpricedRecordCount,
                                row.unpricedModels.count,
                                row.unpricedModels.joined(separator: ", ")
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }
                Text(L10n.string("Estimated from local sessions at current official API list prices; not an actual bill."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if provider == .openCode, !snapshot.modelBreakdowns.isEmpty {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 1)
            OpenCodeModelBreakdownTable(breakdowns: snapshot.modelBreakdowns)
        }

        if let notice = snapshot.notice {
            Text(notice)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func cachedStatus(updatedAt: Date) -> some View {
        Label(
            L10n.string("Cached · %@", formatted(updatedAt)),
            systemImage: "clock.arrow.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func refreshingStatus(previousUpdate: Date) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Latest data is being verified"))
                    .font(.caption).bold()
                Text(L10n.string("Previous successful update: %@", formatted(previousUpdate)))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func currentStatus(updatedAt: Date) -> some View {
        Text(L10n.string("Last successful update: %@", formatted(updatedAt)))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func staleStatus(updatedAt: Date, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Not live"))
                    .bold()
                Text(L10n.string("Snapshot updated: %@", formatted(updatedAt)))
                Text(L10n.string("Refresh error: %@", message))
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func failedContent(message: String) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }

    private var sourceExplanation: String? {
        switch provider {
        case .claudeCode:
            return L10n.string("Local session logs; not an official subscription quota.")
        case .codex:
            return L10n.string("Quota from OpenAI's official API; local cost is an estimate.")
        case .openCode:
            return L10n.string("Local OpenCode database; not an official subscription quota.")
        default:
            return nil
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func color(for provider: Provider) -> Color {
        switch provider {
        case .claudeCode:
            return .orange
        case .codex:
            return Color(red: 0.165, green: 0.616, blue: 0.561)
        case .openCode:
            return .indigo
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
        case .claudeCode, .codex, .openCode:
            return L10n.string("No usage data available yet.")
        default:
            return L10n.string("No usage data available.")
        }
    }
}

private struct OpenCodeModelBreakdownTable: View {
    let breakdowns: [ProviderUsageBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("OpenCode models"))
                .font(.subheadline).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        header(L10n.string("Model"), width: 180)
                        header(L10n.string("Sessions"), width: 54, alignment: .trailing)
                        header(L10n.string("Msgs"), width: 54, alignment: .trailing)
                        header(L10n.string("Total Tokens"), width: 82, alignment: .trailing)
                        header(L10n.string("Input"), width: 72, alignment: .trailing)
                        header(L10n.string("Output"), width: 72, alignment: .trailing)
                        header(L10n.string("Reasoning"), width: 72, alignment: .trailing)
                        header(L10n.string("Cache Read"), width: 84, alignment: .trailing)
                        header(L10n.string("Cache Create"), width: 84, alignment: .trailing)
                        header(L10n.string("API est."), width: 76, alignment: .trailing)
                    }
                    Divider()
                        .gridCellColumns(10)
                    ForEach(breakdowns) { row in
                        GridRow {
                            modelCell(row)
                            metric(String(row.sessionCount), width: 54)
                            metric(String(row.messageCount), width: 54)
                            metric(formatTokens(row.totalTokens), width: 82)
                            metric(formatTokens(row.inputTokens), width: 72)
                            metric(formatTokens(row.outputTokens), width: 72)
                            metric(formatTokens(row.reasoningTokens), width: 72)
                            metric(formatTokens(row.cacheReadTokens), width: 84)
                            metric(formatTokens(row.cacheCreationTokens), width: 84)
                            metric(costText(row), width: 76)
                        }
                    }
                }
                .font(.caption)
                .padding(.vertical, 2)
            }
            Text(L10n.string("Estimated at current official API list prices; subscription plans and discounts are not included."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            let unpriced = breakdowns.filter { $0.pricingCoverage == .unpriced }
            if !unpriced.isEmpty {
                Label(
                    L10n.string(
                        "Unpriced models are excluded: %@",
                        unpriced.map(\.modelID).sorted().joined(separator: ", ")
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
    }

    private func header(_ title: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func modelCell(_ row: ProviderUsageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(row.groupName) · \(row.modelID)")
                .lineLimit(1)
            Text(row.providerID)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 180, alignment: .leading)
    }

    private func metric(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: width, alignment: .trailing)
    }

    private func formatTokens(_ value: Int) -> String {
        TokenDisplayFormatter.usageSummary(value)
    }

    private func formatCost(_ value: Double) -> String {
        let digits = value > 0 && value < 0.01 ? 4 : 2
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }

    private func costText(_ row: ProviderUsageBreakdown) -> String {
        switch row.pricingCoverage {
        case .priced, .free:
            return formatCost(row.estimatedCostUSD)
        case .unpriced:
            return L10n.string("Unpriced")
        }
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindowSnapshot
    let color: Color
    let now: Date

    @ViewBuilder
    var body: some View {
        if window.kind == .tokenSummary {
            tokenSummaryBody
        } else {
            quotaBody
        }
    }

    private var quotaBody: some View {
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

    private var tokenSummaryBody: some View {
        let usage = window.tokenUsage ?? .zero
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.subheadline).bold()
                Spacer()
                Text(TokenDisplayFormatter.usageSummary(usage.totalTokens))
                    .font(.title3).bold()
                    .monospacedDigit()
                Text(L10n.string("Total Tokens"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                tokenMetric(L10n.string("Input"), value: usage.inputTokens)
                tokenMetric(L10n.string("Output"), value: usage.outputTokens)
                tokenMetric(L10n.string("Cache Create"), value: usage.cacheCreationTokens)
                tokenMetric(L10n.string("Cache Read"), value: usage.cacheReadTokens)
            }

            if let description = window.resetDescription {
                HStack {
                    Spacer()
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tokenMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(TokenDisplayFormatter.usageSummary(value))
                .font(.caption)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if let resetsAt = window.quotaResetDate {
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
