import SwiftUI
import TokenScopeCore

struct SessionDetailView: View {
    let detail: SessionDetail
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var costSummary: CostAggregationSummary {
        _ = store.pricesRevision
        if !detail.usageRecords.isEmpty {
            return store.aggregator.costSummary(records: detail.usageRecords)
        }
        guard let model = detail.session.modelsUsed.first,
              detail.session.totalUsage.totalTokens > 0 else {
            return CostAggregationSummary(
                usage: detail.session.totalUsage,
                costUSD: 0,
                pricingCoverage: PricingCoverageSummary()
            )
        }
        let record = UsageRecord(
            sessionId: detail.session.id,
            messageIndex: 0,
            provider: detail.session.provider,
            accountId: detail.session.accountId,
            model: model,
            timestamp: detail.session.endedAt,
            usage: detail.session.totalUsage
        )
        return store.aggregator.costSummary(records: [record])
    }

    private var costText: String {
        let coverage = costSummary.pricingCoverage
        guard !coverage.isComplete else {
            return String(format: "$%.4f", costSummary.costUSD)
        }
        return costSummary.costUSD > 0
            ? String(format: "$%.4f*", costSummary.costUSD)
            : L10n.string("Unpriced")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let notice = detail.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            content
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.session.projectPath?.components(separatedBy: "/").last ?? detail.session.id)
                        .font(.title2).bold()
                    HStack(spacing: 16) {
                        Text(detail.session.provider.displayName)
                        Text(detail.session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("→")
                        Text(detail.session.endedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Label("\(detail.session.messageCount)", systemImage: "text.bubble")
                        Label(formatTokenAmount(detail.session.totalUsage.totalTokens), systemImage: "number")
                        Text(costText)
                            .monospacedDigit()
                            .help(
                                costSummary.pricingCoverage.isComplete
                                    ? L10n.string("Estimated at current official API list prices.")
                                    : L10n.string(
                                        "Partial estimate; unpriced models: %@",
                                        costSummary.pricingCoverage.unpricedModels.joined(separator: ", ")
                                    )
                            )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch detail.mode {
        case .messages:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(detail.messages) { message in
                        SessionMessageCard(message: message)
                    }
                }
            }
        case .usageOnly:
            Table(detail.usageRecords) {
                TableColumn(L10n.string("Time")) { record in
                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                }
                TableColumn(L10n.string("Model")) { record in
                    Text(record.model)
                }
                TableColumn(L10n.string("Input")) { record in
                    Text(formatTokenAmount(record.usage.inputTokens)).monospacedDigit()
                }
                TableColumn(L10n.string("Output")) { record in
                    Text(formatTokenAmount(record.usage.outputTokens)).monospacedDigit()
                }
                TableColumn(L10n.string("Cache R")) { record in
                    Text(formatTokenAmount(record.usage.cacheReadTokens)).monospacedDigit()
                }
                TableColumn(L10n.string("Cache W")) { record in
                    Text(formatTokenAmount(record.usage.cacheCreationTokens)).monospacedDigit()
                }
            }
        }
    }
}

private struct SessionMessageCard: View {
    let message: SessionMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(message.role.capitalized)
                    .font(.caption).bold()
                if let model = message.model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let text = message.contentText ?? message.contentPreview {
                Text(text)
                    .textSelection(.enabled)
            }
            if message.usage.totalTokens > 0 {
                HStack(spacing: 12) {
                    Text(L10n.string("Input %@", formatTokenAmount(message.usage.inputTokens)))
                    Text(L10n.string("Output %@", formatTokenAmount(message.usage.outputTokens)))
                    if message.usage.cacheReadTokens > 0 {
                        Text(L10n.string("Cache R %@", formatTokenAmount(message.usage.cacheReadTokens)))
                    }
                    if message.usage.cacheCreationTokens > 0 {
                        Text(L10n.string("Cache W %@", formatTokenAmount(message.usage.cacheCreationTokens)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

private func formatTokenAmount(_ n: Int) -> String {
    TokenDisplayFormatter.hundredMillions(n)
}
