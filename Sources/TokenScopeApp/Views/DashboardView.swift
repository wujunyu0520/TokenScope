import SwiftUI
import Charts
import TokenScopeCore

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
    @State private var endDate: Date = Date()
    @State private var selectedModels: Set<String> = []
    @State private var selectedProviders: Set<Provider> = []
    @State private var includeInput = true
    @State private var includeOutput = true
    @State private var includeCacheRead = true
    @State private var includeCacheCreate = true

    @State private var buckets: [DailyBucket] = []
    @State private var monthlyBuckets: [MonthlyBucket] = []
    @State private var totals: (usage: TokenUsage, costUSD: Double) = (.zero, 0)
    @State private var pricingCoverage = PricingCoverageSummary()
    @State private var availableModels: [String] = []
    @State private var modelPalette: [String: Color] = [:]
    @State private var sourceTotals: [Provider: (usage: TokenUsage, cost: Double)] = [:]
    @State private var heatmapDays: [HeatmapDaySummary] = []
    @State private var heatmapDayBuckets: [Date: [DailyBucket]] = [:]
    @State private var expandedMonths: Set<Date> = []

    @State private var hoveredDay: Date?

    private var selectedDayRange: ClosedRange<Date> {
        let cal = Calendar.current
        let lower = cal.startOfDay(for: min(startDate, endDate))
        let upper = cal.startOfDay(for: max(startDate, endDate))
        return lower...upper
    }

    private var filter: AggregationFilter {
        let cal = Calendar.current
        let lower = cal.startOfDay(for: min(startDate, endDate))
        let upperDay = cal.startOfDay(for: max(startDate, endDate))
        let upper = cal.date(byAdding: .day, value: 1, to: upperDay) ?? upperDay
        return AggregationFilter(
            dateRange: lower...upper,
            providers: selectedProviders.isEmpty ? nil : selectedProviders,
            models: selectedModels.isEmpty ? nil : selectedModels
        )
    }

    private var sourceFilter: AggregationFilter {
        let cal = Calendar.current
        let lower = cal.startOfDay(for: min(startDate, endDate))
        let upperDay = cal.startOfDay(for: max(startDate, endDate))
        let upper = cal.date(byAdding: .day, value: 1, to: upperDay) ?? upperDay
        return AggregationFilter(
            dateRange: lower...upper,
            models: selectedModels.isEmpty ? nil : selectedModels
        )
    }

    private var filterKey: String {
        let providers = selectedProviders.map(\.rawValue).sorted().joined(separator: ",")
        return "\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)|\(selectedModels.sorted().joined(separator: ","))|\(providers)|\(store.usageRecords.count)|\(store.pricesRevision)"
    }

    private func displayedTokens(for usage: TokenUsage) -> Int {
        var v = 0
        if includeInput { v += usage.inputTokens }
        if includeOutput { v += usage.outputTokens }
        if includeCacheRead { v += usage.cacheReadTokens }
        if includeCacheCreate { v += usage.cacheCreationTokens }
        return v
    }

    private func recompute() {
        let f = filter
        let newBuckets = store.aggregator.dailyBuckets(records: store.usageRecords, filter: f)
        let newMonthlyBuckets = store.aggregator.monthlyBuckets(records: store.usageRecords, filter: f)
        let newSummary = store.aggregator.costSummary(records: store.usageRecords, filter: f)
        let models = Array(Set(store.usageRecords.map(\.model))).sorted()
        var palette: [String: Color] = [:]
        let baseColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo, .red, .mint, .cyan, .brown]
        for (i, m) in models.enumerated() {
            palette[m] = baseColors[i % baseColors.count]
        }
        let sourceBuckets = store.aggregator.dailyBuckets(records: store.usageRecords, filter: sourceFilter)
        var byProvider: [Provider: (usage: TokenUsage, cost: Double)] = [:]
        for b in sourceBuckets {
            let existing = byProvider[b.provider] ?? (.zero, 0)
            byProvider[b.provider] = (existing.usage + b.usage, existing.cost + b.costUSD)
        }
        let cal = Calendar.current
        var heatmapTotals: [Date: (usage: TokenUsage, cost: Double)] = [:]
        var heatmapDetails: [Date: [DailyBucket]] = [:]
        for bucket in newBuckets {
            let day = cal.startOfDay(for: bucket.day)
            let existing = heatmapTotals[day] ?? (.zero, 0)
            heatmapTotals[day] = (existing.usage + bucket.usage, existing.cost + bucket.costUSD)
            heatmapDetails[day, default: []].append(bucket)
        }
        for (day, rows) in heatmapDetails {
            heatmapDetails[day] = rows.sorted { lhs, rhs in
                let lhsTokens = displayedTokens(for: lhs.usage)
                let rhsTokens = displayedTokens(for: rhs.usage)
                if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                return lhs.model < rhs.model
            }
        }
        self.buckets = newBuckets
        self.monthlyBuckets = newMonthlyBuckets
        self.totals = (newSummary.usage, newSummary.costUSD)
        self.pricingCoverage = newSummary.pricingCoverage
        self.availableModels = models
        self.modelPalette = palette
        self.sourceTotals = byProvider
        self.heatmapDays = heatmapTotals
            .map { day, entry in
                HeatmapDaySummary(
                    day: day,
                    tokens: displayedTokens(for: entry.usage),
                    costUSD: entry.cost
                )
            }
            .sorted { $0.day < $1.day }
        self.heatmapDayBuckets = heatmapDetails
        self.expandedMonths = expandedMonths.intersection(Set(newMonthlyBuckets.map(\.monthStart)))
    }

    private var hoveredBuckets: [DailyBucket] {
        guard let day = hoveredDay else { return [] }
        let cal = Calendar.current
        return buckets.filter { cal.isDate($0.day, inSameDayAs: day) }
    }

    private func toggleProvider(_ p: Provider) {
        if selectedProviders.contains(p) {
            selectedProviders.remove(p)
        } else {
            selectedProviders.insert(p)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerStats
                sourceBreakdownView
                filters
                chart
                activityHeatmapSection
                monthlyUsageSection
            }
            .padding(24)
        }
        .navigationTitle(L10n.string("Dashboard"))
        .onAppear { recompute() }
        .onChange(of: filterKey) { _, _ in recompute() }
        .onChange(of: includeInput) { _, _ in recompute() }
        .onChange(of: includeOutput) { _, _ in recompute() }
        .onChange(of: includeCacheRead) { _, _ in recompute() }
        .onChange(of: includeCacheCreate) { _, _ in recompute() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.loadAll() }
                } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
    }

    private var headerStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                StatCard(title: L10n.string("Sessions"), value: "\(store.sessions.count)")
                StatCard(title: L10n.string("Total Tokens"), value: formatTokenAmount(totals.usage.totalTokens))
                StatCard(title: L10n.string("Input"), value: formatTokenAmount(totals.usage.inputTokens))
                StatCard(title: L10n.string("Output"), value: formatTokenAmount(totals.usage.outputTokens))
                StatCard(title: L10n.string("Cache R"), value: formatTokenAmount(totals.usage.cacheReadTokens))
                StatCard(title: L10n.string("API cost estimate"), value: String(format: "$%.2f", totals.costUSD))
            }
            if !pricingCoverage.isComplete {
                Label(
                    L10n.string(
                        "%d records are excluded from cost because %d models are unpriced: %@",
                        pricingCoverage.unpricedRecordCount,
                        pricingCoverage.unpricedModels.count,
                        pricingCoverage.unpricedModels.joined(separator: ", ")
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            }
        }
    }

    private var sourceBreakdownView: some View {
        let sources: [Provider] = [.claudeCode, .codex, .openCode]
        return HStack(spacing: 12) {
            ForEach(sources, id: \.self) { p in
                let entry = sourceTotals[p]
                SourceCard(
                    title: p.displayName,
                    tokens: displayedTokens(for: entry?.usage ?? .zero),
                    cost: entry?.cost ?? 0,
                    color: sourceColor(p),
                    isSelected: selectedProviders.isEmpty || selectedProviders.contains(p),
                    hasFilter: !selectedProviders.isEmpty,
                    action: { toggleProvider(p) }
                )
            }
            if !selectedProviders.isEmpty {
                Button(L10n.string("Clear")) { selectedProviders.removeAll() }
                    .buttonStyle(.link)
            }
            Spacer()
        }
    }

    private func sourceColor(_ p: Provider) -> Color {
        switch p {
        case .claudeCode: return .orange
        case .codex: return .green
        case .openCode, .zai: return .purple
        default: return .secondary
        }
    }

    private func applyPreset(_ preset: DatePreset) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let range: (Date, Date)
        switch preset {
        case .all:
            let earliest = store.usageRecords.map(\.timestamp).min().map { cal.startOfDay(for: $0) } ?? today
            range = (earliest, today)
        case .today:
            range = (today, today)
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: today) ?? today
            range = (y, y)
        case .thisWeek:
            let interval = cal.dateInterval(of: .weekOfYear, for: today)
            let start = interval.map { cal.startOfDay(for: $0.start) } ?? today
            range = (start, today)
        case .last7Days:
            let start = cal.date(byAdding: .day, value: -6, to: today) ?? today
            range = (start, today)
        case .thisMonth:
            let interval = cal.dateInterval(of: .month, for: today)
            let start = interval.map { cal.startOfDay(for: $0.start) } ?? today
            range = (start, today)
        case .lastMonth:
            guard let lastMonthDay = cal.date(byAdding: .month, value: -1, to: today),
                  let interval = cal.dateInterval(of: .month, for: lastMonthDay) else {
                range = (today, today); break
            }
            let start = cal.startOfDay(for: interval.start)
            let end = cal.date(byAdding: .day, value: -1, to: interval.end).map { cal.startOfDay(for: $0) } ?? start
            range = (start, end)
        case .last30Days:
            let start = cal.date(byAdding: .day, value: -29, to: today) ?? today
            range = (start, today)
        case .last60Days:
            let start = cal.date(byAdding: .day, value: -59, to: today) ?? today
            range = (start, today)
        case .last90Days:
            let start = cal.date(byAdding: .day, value: -89, to: today) ?? today
            range = (start, today)
        case .thisYear:
            let interval = cal.dateInterval(of: .year, for: today)
            let start = interval.map { cal.startOfDay(for: $0.start) } ?? today
            range = (start, today)
        case .lastYear:
            guard let lastYearDay = cal.date(byAdding: .year, value: -1, to: today),
                  let interval = cal.dateInterval(of: .year, for: lastYearDay) else {
                range = (today, today); break
            }
            let start = cal.startOfDay(for: interval.start)
            let end = cal.date(byAdding: .day, value: -1, to: interval.end).map { cal.startOfDay(for: $0) } ?? start
            range = (start, end)
        }
        if range.1 >= startDate {
            endDate = range.1
            startDate = range.0
        } else {
            startDate = range.0
            endDate = range.1
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DatePicker(L10n.string("From"), selection: $startDate, in: ...endDate, displayedComponents: .date)
                DatePicker(L10n.string("To"), selection: $endDate, in: startDate..., displayedComponents: .date)
                Menu {
                    ForEach(DatePreset.allCases, id: \.self) { p in
                        Button(p.label) { applyPreset(p) }
                    }
                } label: {
                    Label(L10n.string("Quick"), systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle(L10n.string("Input"), isOn: $includeInput)
                Toggle(L10n.string("Output"), isOn: $includeOutput)
                Toggle(L10n.string("Cache Read"), isOn: $includeCacheRead)
                Toggle(L10n.string("Cache Create"), isOn: $includeCacheCreate)
            }
            .toggleStyle(.checkbox)
            if !availableModels.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(
                            rows: [GridItem(.fixed(28), spacing: 6), GridItem(.fixed(28), spacing: 6)],
                            alignment: .center,
                            spacing: 6
                        ) {
                            ForEach(availableModels, id: \.self) { m in
                                ModelChip(
                                    title: m,
                                    color: modelPalette[m] ?? .accentColor,
                                    isOn: selectedModels.isEmpty || selectedModels.contains(m)
                                ) {
                                    if selectedModels.contains(m) {
                                        selectedModels.remove(m)
                                    } else {
                                        selectedModels.insert(m)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 64)

                    if !selectedModels.isEmpty {
                        Button(L10n.string("Clear")) { selectedModels.removeAll() }
                            .buttonStyle(.link)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var chart: some View {
        ChartContent(
            buckets: buckets,
            palette: modelPalette,
            hoveredDay: $hoveredDay,
            hoveredBuckets: hoveredBuckets,
            displayedTokens: displayedTokens
        )
        .frame(minHeight: 320)
    }

    private var activityHeatmapSection: some View {
        ActivityHeatmapSection(
            days: heatmapDays,
            dayBuckets: heatmapDayBuckets,
            palette: modelPalette,
            displayedTokens: displayedTokens,
            range: selectedDayRange
        )
    }

    private var monthlyUsageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Monthly Usage"))
                .font(.title2).bold()

            if monthlyBuckets.isEmpty {
                Text(L10n.string("No usage in selected range"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(monthlyBuckets) { month in
                        MonthlyBucketCard(
                            bucket: month,
                            isExpanded: expandedMonths.contains(month.monthStart),
                            displayedTokens: displayedTokens,
                            toggle: {
                                if expandedMonths.contains(month.monthStart) {
                                    expandedMonths.remove(month.monthStart)
                                } else {
                                    expandedMonths.insert(month.monthStart)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct ChartContent: View {
    let buckets: [DailyBucket]
    let palette: [String: Color]
    @Binding var hoveredDay: Date?
    let hoveredBuckets: [DailyBucket]
    let displayedTokens: (TokenUsage) -> Int

    private var sortedModels: [String] {
        Array(Set(buckets.map(\.model))).sorted()
    }

    var body: some View {
        Chart {
            ForEach(buckets) { b in
                BarMark(
                    x: .value(L10n.string("Day"), b.day, unit: .day),
                    y: .value(L10n.string("Tokens"), displayedTokens(b.usage))
                )
                .foregroundStyle(by: .value(L10n.string("Model"), b.model))
            }
            if let hoveredDay {
                RuleMark(x: .value(L10n.string("Day"), hoveredDay, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(domain: sortedModels, range: sortedModels.map { palette[$0] ?? .accentColor })
        .animation(nil, value: hoveredDay)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let n = value.as(Int.self) {
                        Text(formatTokenAmount(n)).monospacedDigit()
                    }
                }
            }
        }
        .chartXSelection(value: $hoveredDay)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let hoveredDay,
                   !hoveredBuckets.isEmpty,
                   let plotFrameAnchor = proxy.plotFrame {
                    let plot = geo[plotFrameAnchor]
                    if let xPos = proxy.position(forX: hoveredDay) {
                        TooltipView(
                            day: hoveredDay,
                            buckets: hoveredBuckets,
                            palette: palette,
                            formatTokens: displayedTokens
                        )
                        .fixedSize()
                        .position(
                            x: min(max(plot.minX + xPos + 8, plot.minX + 130), plot.maxX - 130),
                            y: plot.minY + 80
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

private enum DatePreset: CaseIterable {
    case all, today, yesterday, thisWeek, last7Days, thisMonth, lastMonth, last30Days, last60Days, last90Days, thisYear, lastYear

    var label: String {
        switch self {
        case .all: return L10n.string("All")
        case .today: return L10n.string("Today")
        case .yesterday: return L10n.string("Yesterday")
        case .thisWeek: return L10n.string("This Week")
        case .last7Days: return L10n.string("Last 7 Days")
        case .thisMonth: return L10n.string("This Month")
        case .lastMonth: return L10n.string("Last Month")
        case .last30Days: return L10n.string("Last 30 Days")
        case .last60Days: return L10n.string("Last 60 Days")
        case .last90Days: return L10n.string("Last 90 Days")
        case .thisYear: return L10n.string("This Year")
        case .lastYear: return L10n.string("Last Year")
        }
    }
}

private func formatTokenAmount(_ n: Int) -> String {
    TokenDisplayFormatter.hundredMillions(n)
}

private struct TooltipView: View {
    let day: Date
    let buckets: [DailyBucket]
    let palette: [String: Color]
    let formatTokens: (TokenUsage) -> Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).bold()
            Divider()
            ForEach(buckets) { b in
                HStack(spacing: 10) {
                    Circle().fill(palette[b.model] ?? .accentColor).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.model).font(.caption)
                        Text(L10n.string("%@ · $%@", formatTokenAmount(formatTokens(b.usage)), String(format: "%.4f", b.costUSD)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
        .shadow(radius: 6)
    }
}

private struct HeatmapDaySummary: Identifiable {
    var id: TimeInterval { day.timeIntervalSince1970 }
    let day: Date
    let tokens: Int
    let costUSD: Double
}

private struct ActivityHeatmapSection: View {
    private let model: HeatmapRenderModel
    private let dayBuckets: [Date: [DailyBucket]]
    private let palette: [String: Color]
    private let displayedTokens: (TokenUsage) -> Int

    @State private var hoveredCellID: TimeInterval?
    @Environment(\.colorScheme) private var colorScheme

    private let cellSize: CGFloat = 11
    private let cellSpacing: CGFloat = 4
    private let weekdayLabelWidth: CGFloat = 28
    private let gridSpacing: CGFloat = 8
    private let monthLabelHeight: CGFloat = 46
    private let headerSpacing: CGFloat = 8
    private let tooltipReservedHeight: CGFloat = 150

    init(
        days: [HeatmapDaySummary],
        dayBuckets: [Date: [DailyBucket]],
        palette: [String: Color],
        displayedTokens: @escaping (TokenUsage) -> Int,
        range: ClosedRange<Date>
    ) {
        self.model = HeatmapRenderModel(days: days, range: range)
        self.dayBuckets = dayBuckets
        self.palette = palette
        self.displayedTokens = displayedTokens
    }

    private var hoveredCell: HeatmapCell? {
        guard let hoveredCellID else { return nil }
        return model.cellLookup[hoveredCellID]
    }

    private var hoveredBuckets: [DailyBucket] {
        guard let hoveredCell, hoveredCell.isInSelectedRange else { return [] }
        return dayBuckets[hoveredCell.day] ?? []
    }

    private var gridWidth: CGFloat {
        weekdayLabelWidth
            + gridSpacing
            + CGFloat(model.weekColumns.count) * cellSize
            + CGFloat(max(model.weekColumns.count - 1, 0)) * cellSpacing
    }

    private var gridHeight: CGFloat {
        CGFloat(model.weekdaySymbols.count) * cellSize
            + CGFloat(max(model.weekdaySymbols.count - 1, 0)) * cellSpacing
    }

    private var heatmapBodyHeight: CGFloat {
        monthLabelHeight
            + headerSpacing
            + gridHeight
            + (hoveredBuckets.isEmpty ? 0 : tooltipReservedHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Activity Heatmap"))
                        .font(.title2)
                        .bold()
                    Text(L10n.string("Daily tokens across the selected range"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            ZStack(alignment: .topLeading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: cellSpacing) {
                            Color.clear
                                .frame(width: weekdayLabelWidth, height: monthLabelHeight)

                            HStack(spacing: cellSpacing) {
                                ForEach(Array(model.monthLabels.enumerated()), id: \.offset) { _, label in
                                    Text(label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: cellSize, alignment: .leading)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }

                        HStack(alignment: .top, spacing: gridSpacing) {
                            VStack(alignment: .trailing, spacing: cellSpacing) {
                                ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                                    Text(symbol)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: weekdayLabelWidth, height: cellSize, alignment: .trailing)
                                }
                            }

                            HStack(alignment: .top, spacing: cellSpacing) {
                                ForEach(Array(model.weekColumns.enumerated()), id: \.offset) { _, week in
                                    VStack(spacing: cellSpacing) {
                                        ForEach(week) { cell in
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(fillColor(for: cell.level))
                                                .frame(width: cellSize, height: cellSize)
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                        .stroke(borderColor(for: cell), lineWidth: cell.isInSelectedRange ? 0.5 : 0)
                                                }
                                                .onHover { isHovering in
                                                    if isHovering {
                                                        hoveredCellID = cell.id
                                                    } else if hoveredCellID == cell.id {
                                                        hoveredCellID = nil
                                                    }
                                                }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: heatmapBodyHeight, alignment: .topLeading)
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
                }

                if let hoveredCell, hoveredCell.isInSelectedRange, !hoveredBuckets.isEmpty {
                    TooltipView(
                        day: hoveredCell.day,
                        buckets: hoveredBuckets,
                        palette: palette,
                        formatTokens: displayedTokens
                    )
                    .fixedSize()
                    .position(tooltipPosition(for: hoveredCell))
                    .allowsHitTesting(false)
                }
            }

            HStack(spacing: 6) {
                Text(L10n.string("Less"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fillColor(for: level))
                        .frame(width: cellSize, height: cellSize)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(borderColor(for: .legend(level: level)), lineWidth: level == 0 ? 0.5 : 0)
                        }
                }
                Text(L10n.string("More"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var statusText: String {
        if let hoveredCell, hoveredCell.isInSelectedRange {
            return L10n.string(
                "%@ · %@ · $%@",
                hoveredCell.day.formatted(date: .abbreviated, time: .omitted),
                formatTokenAmount(hoveredCell.tokens),
                String(format: "%.2f", hoveredCell.costUSD)
            )
        }
        if model.activeDayCount == 0 {
            return L10n.string("No activity in selected range")
        }
        return L10n.string("%d active days · peak %@", model.activeDayCount, formatTokenAmount(model.peakTokens))
    }

    private func borderColor(for cell: HeatmapCell) -> Color {
        guard cell.isInSelectedRange else { return .clear }
        if cell.level == 0 {
            return Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.12)
        }
        return Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08)
    }

    private func fillColor(for level: Int) -> Color {
        switch level {
        case 1:
            return Color(red: 0.84, green: 0.92, blue: 0.79)
        case 2:
            return Color(red: 0.58, green: 0.80, blue: 0.50)
        case 3:
            return Color(red: 0.24, green: 0.67, blue: 0.34)
        case 4:
            return Color(red: 0.12, green: 0.47, blue: 0.22)
        default:
            return Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.08)
        }
    }

    private func tooltipPosition(for cell: HeatmapCell) -> CGPoint {
        let cellCenterX = weekdayLabelWidth
            + gridSpacing
            + CGFloat(cell.columnIndex) * (cellSize + cellSpacing)
            + cellSize / 2
        let cellCenterY = CGFloat(cell.rowIndex) * (cellSize + cellSpacing) + cellSize / 2
        let tooltipHalfWidth: CGFloat = 130
        let minX = min(tooltipHalfWidth, gridWidth / 2)
        let maxX = max(minX, gridWidth - tooltipHalfWidth)
        let x = min(max(cellCenterX + 14, minX), maxX)
        let minY: CGFloat = 34
        let maxY = max(minY, heatmapBodyHeight - 16)
        let y = min(max(cellCenterY + 52, minY), maxY)
        return CGPoint(x: x, y: y)
    }
}

private struct HeatmapCell: Identifiable, Equatable {
    var id: TimeInterval { day.timeIntervalSince1970 }
    let day: Date
    let tokens: Int
    let costUSD: Double
    let isInSelectedRange: Bool
    let level: Int
    let columnIndex: Int
    let rowIndex: Int
    let tooltip: String

    static func legend(level: Int) -> HeatmapCell {
        HeatmapCell(
            day: Date.distantPast.addingTimeInterval(Double(level)),
            tokens: level == 0 ? 0 : level,
            costUSD: 0,
            isInSelectedRange: true,
            level: level,
            columnIndex: 0,
            rowIndex: 0,
            tooltip: ""
        )
    }
}

private struct HeatmapRenderModel {
    let weekColumns: [[HeatmapCell]]
    let monthLabels: [String]
    let weekdaySymbols: [String]
    let activeDayCount: Int
    let peakTokens: Int
    let cellLookup: [TimeInterval: HeatmapCell]

    init(days: [HeatmapDaySummary], range: ClosedRange<Date>, calendar: Calendar = .current) {
        let startDay = calendar.startOfDay(for: range.lowerBound)
        let endDay = calendar.startOfDay(for: range.upperBound)
        let dayMap = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.day), $0) })

        let alignedStartDay: Date = {
            let weekday = calendar.component(.weekday, from: startDay)
            let offset = (weekday - calendar.firstWeekday + 7) % 7
            return calendar.date(byAdding: .day, value: -offset, to: startDay) ?? startDay
        }()

        let alignedEndDay: Date = {
            let weekday = calendar.component(.weekday, from: endDay)
            let offset = (calendar.firstWeekday + 6 - weekday + 7) % 7
            return calendar.date(byAdding: .day, value: offset, to: endDay) ?? endDay
        }()

        struct BaseCell {
            let day: Date
            let tokens: Int
            let costUSD: Double
            let isInSelectedRange: Bool
        }

        var baseCells: [BaseCell] = []
        var cursor = alignedStartDay
        while cursor <= alignedEndDay {
            let day = calendar.startOfDay(for: cursor)
            let summary = dayMap[day]
            baseCells.append(
                BaseCell(
                    day: day,
                    tokens: summary?.tokens ?? 0,
                    costUSD: summary?.costUSD ?? 0,
                    isInSelectedRange: day >= startDay && day <= endDay
                )
            )
            cursor = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }

        let nonZeroTokens = baseCells
            .filter { $0.isInSelectedRange && $0.tokens > 0 }
            .map(\.tokens)
            .sorted()
        let thresholds = Self.thresholds(for: nonZeroTokens)

        let cells = baseCells.enumerated().map { index, cell in
            let level = cell.isInSelectedRange ? Self.intensityLevel(for: cell.tokens, thresholds: thresholds) : 0
            let tooltip: String
            if cell.isInSelectedRange {
                tooltip = L10n.string(
                    "%@\n%@\n$%@",
                    cell.day.formatted(date: .abbreviated, time: .omitted),
                    formatTokenAmount(cell.tokens),
                    String(format: "%.2f", cell.costUSD)
                )
            } else {
                tooltip = ""
            }
            return HeatmapCell(
                day: cell.day,
                tokens: cell.tokens,
                costUSD: cell.costUSD,
                isInSelectedRange: cell.isInSelectedRange,
                level: level,
                columnIndex: index / 7,
                rowIndex: index % 7,
                tooltip: tooltip
            )
        }

        var columns: [[HeatmapCell]] = []
        var index = 0
        while index < cells.count {
            columns.append(Array(cells[index..<min(index + 7, cells.count)]))
            index += 7
        }

        self.weekColumns = columns
        self.monthLabels = columns.enumerated().map { index, week in
            Self.monthLabel(for: week, index: index, calendar: calendar)
        }
        self.weekdaySymbols = Self.weekdaySymbols(calendar: calendar)
        self.activeDayCount = nonZeroTokens.count
        self.peakTokens = nonZeroTokens.last ?? 0
        self.cellLookup = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
    }

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let shift = max(0, calendar.firstWeekday - 1)
        return Array(symbols[shift...]) + Array(symbols[..<shift])
    }

    private static func monthLabel(for week: [HeatmapCell], index: Int, calendar: Calendar) -> String {
        let selectedDays = week.filter { $0.isInSelectedRange }
        guard let firstVisibleDay = selectedDays.first else { return "" }
        if index == 0 {
            return firstVisibleDay.day.formatted(.dateTime.month(.abbreviated))
        }
        if let monthStart = selectedDays.first(where: { calendar.component(.day, from: $0.day) == 1 }) {
            return monthStart.day.formatted(.dateTime.month(.abbreviated))
        }
        return ""
    }

    private static func thresholds(for sortedTokens: [Int]) -> [Int] {
        guard !sortedTokens.isEmpty else { return [0, 0, 0, 0] }
        return [
            percentile(0.25, in: sortedTokens),
            percentile(0.5, in: sortedTokens),
            percentile(0.75, in: sortedTokens),
            sortedTokens[sortedTokens.count - 1]
        ]
    }

    private static func intensityLevel(for tokens: Int, thresholds: [Int]) -> Int {
        guard tokens > 0 else { return 0 }
        for (index, threshold) in thresholds.enumerated() where tokens <= threshold {
            return index + 1
        }
        return 4
    }

    private static func percentile(_ fraction: Double, in sortedTokens: [Int]) -> Int {
        guard !sortedTokens.isEmpty else { return 0 }
        let position = Int((Double(sortedTokens.count - 1) * fraction).rounded(.toNearestOrAwayFromZero))
        return sortedTokens[min(max(position, 0), sortedTokens.count - 1)]
    }
}

private struct MonthlyBucketCard: View {
    let bucket: MonthlyBucket
    let isExpanded: Bool
    let displayedTokens: (TokenUsage) -> Int
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 16) {
                    Text(bucket.monthStart.formatted(.dateTime.year().month(.wide)))
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatTokenAmount(displayedTokens(bucket.usage)))
                            .font(.body).monospacedDigit()
                        Text("$\(String(format: "%.2f", bucket.costUSD)) · \(L10n.string("%d msgs", bucket.messageCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(bucket.days) { day in
                        MonthlyDayRow(bucket: day, displayedTokens: displayedTokens)
                        if day.id != bucket.days.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.15)))
    }
}

private struct MonthlyDayRow: View {
    let bucket: MonthlyDayBucket
    let displayedTokens: (TokenUsage) -> Int

    var body: some View {
        HStack(spacing: 16) {
            Text(bucket.day.formatted(.dateTime.month(.abbreviated).day()))
                .font(.subheadline)
                .frame(width: 80, alignment: .leading)
            Spacer()
            Text(formatTokenAmount(displayedTokens(bucket.usage)))
                .font(.subheadline)
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text(String(format: "$%.2f", bucket.costUSD))
                .font(.subheadline)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text("\(bucket.messageCount)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
        .padding(12)
        .frame(minWidth: 120, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ModelChip: View {
    let title: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 84, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isOn ? color.opacity(0.18) : Color.secondary.opacity(0.08))
            .clipShape(Capsule())
            .opacity(isOn ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isHovering, arrowEdge: .bottom) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct SourceCard: View {
    let title: String
    let tokens: Int
    let cost: Double
    let color: Color
    let isSelected: Bool
    let hasFilter: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(formatTokenAmount(tokens)).font(.callout).monospacedDigit()
                        Text(String(format: "$%.2f", cost))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 150, alignment: .leading)
            .background(color.opacity(isSelected ? 0.15 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(isSelected ? 0.45 : 0.15), lineWidth: isSelected && hasFilter ? 1.5 : 1)
            )
            .opacity(isSelected ? 1.0 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
