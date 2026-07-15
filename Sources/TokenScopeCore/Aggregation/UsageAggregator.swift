import Foundation

public struct DailyBucket: Sendable, Hashable, Identifiable {
    public var id: String { "\(day.timeIntervalSince1970)|\(model)|\(provider.rawValue)" }
    public let day: Date
    public let provider: Provider
    public let model: String
    public let usage: TokenUsage
    public let costUSD: Double
}

public struct MonthlyDayBucket: Sendable, Hashable, Identifiable {
    public var id: String { "\(day.timeIntervalSince1970)" }
    public let day: Date
    public let usage: TokenUsage
    public let costUSD: Double
    public let messageCount: Int
}

public struct MonthlyBucket: Sendable, Hashable, Identifiable {
    public var id: String { "\(monthStart.timeIntervalSince1970)" }
    public let monthStart: Date
    public let usage: TokenUsage
    public let costUSD: Double
    public let messageCount: Int
    public let days: [MonthlyDayBucket]
}

public struct PricingCoverageSummary: Sendable, Hashable {
    public let pricedRecordCount: Int
    public let freeRecordCount: Int
    public let unpricedRecordCount: Int
    public let unpricedModels: [String]

    public var isComplete: Bool { unpricedRecordCount == 0 }

    public init(
        pricedRecordCount: Int = 0,
        freeRecordCount: Int = 0,
        unpricedRecordCount: Int = 0,
        unpricedModels: [String] = []
    ) {
        self.pricedRecordCount = pricedRecordCount
        self.freeRecordCount = freeRecordCount
        self.unpricedRecordCount = unpricedRecordCount
        self.unpricedModels = unpricedModels
    }
}

public struct CostAggregationSummary: Sendable, Hashable {
    public let usage: TokenUsage
    public let costUSD: Double
    public let pricingCoverage: PricingCoverageSummary

    public init(
        usage: TokenUsage,
        costUSD: Double,
        pricingCoverage: PricingCoverageSummary
    ) {
        self.usage = usage
        self.costUSD = costUSD
        self.pricingCoverage = pricingCoverage
    }
}

public struct AggregationFilter: Sendable {
    public var dateRange: ClosedRange<Date>?
    public var providers: Set<Provider>?
    public var models: Set<String>?
    public var accountIds: Set<String>?

    public init(
        dateRange: ClosedRange<Date>? = nil,
        providers: Set<Provider>? = nil,
        models: Set<String>? = nil,
        accountIds: Set<String>? = nil
    ) {
        self.dateRange = dateRange
        self.providers = providers
        self.models = models
        self.accountIds = accountIds
    }

    public func matches(_ r: UsageRecord) -> Bool {
        if let dr = dateRange, !dr.contains(r.timestamp) { return false }
        if let p = providers, !p.contains(r.provider) { return false }
        if let m = models, !m.contains(r.model) { return false }
        if let a = accountIds {
            guard let rid = r.accountId, a.contains(rid) else { return false }
        }
        return true
    }
}

public struct UsageAggregator: Sendable {
    public let priceBook: PriceBook
    public let calendar: Calendar

    public init(priceBook: PriceBook, calendar: Calendar = .current) {
        self.priceBook = priceBook
        self.calendar = calendar
    }

    public func dailyBuckets(records: [UsageRecord], filter: AggregationFilter = .init()) -> [DailyBucket] {
        var map: [String: (day: Date, provider: Provider, model: String, usage: TokenUsage, cost: Double)] = [:]
        for r in records where filter.matches(r) {
            let day = calendar.startOfDay(for: r.timestamp)
            let key = "\(day.timeIntervalSince1970)|\(r.provider.rawValue)|\(r.model)"
            let cost = priceBook.estimate(for: r).estimatedUSD
            if var existing = map[key] {
                existing.usage += r.usage
                existing.cost += cost
                map[key] = existing
            } else {
                map[key] = (day, r.provider, r.model, r.usage, cost)
            }
        }
        return map.values
            .map { entry in
                DailyBucket(
                    day: entry.day,
                    provider: entry.provider,
                    model: entry.model,
                    usage: entry.usage,
                    costUSD: entry.cost
                )
            }
            .sorted { a, b in
                if a.day != b.day { return a.day < b.day }
                if a.provider != b.provider { return a.provider.rawValue < b.provider.rawValue }
                return a.model < b.model
            }
    }

    public func monthlyBuckets(records: [UsageRecord], filter: AggregationFilter = .init()) -> [MonthlyBucket] {
        var dailyMap: [Date: (usage: TokenUsage, cost: Double, messageCount: Int)] = [:]
        for r in records where filter.matches(r) {
            let day = calendar.startOfDay(for: r.timestamp)
            let cost = priceBook.estimate(for: r).estimatedUSD
            if var existing = dailyMap[day] {
                existing.usage += r.usage
                existing.cost += cost
                existing.messageCount += 1
                dailyMap[day] = existing
            } else {
                dailyMap[day] = (r.usage, cost, 1)
            }
        }

        var monthMap: [Date: [MonthlyDayBucket]] = [:]
        for (day, entry) in dailyMap {
            guard let monthInterval = calendar.dateInterval(of: .month, for: day) else { continue }
            let monthStart = monthInterval.start
            let dayBucket = MonthlyDayBucket(
                day: day,
                usage: entry.usage,
                costUSD: entry.cost,
                messageCount: entry.messageCount
            )
            monthMap[monthStart, default: []].append(dayBucket)
        }

        return monthMap.map { monthStart, days in
            let sortedDays = days.sorted { $0.day > $1.day }
            let usage = sortedDays.reduce(TokenUsage.zero) { $0 + $1.usage }
            let cost = sortedDays.reduce(0) { $0 + $1.costUSD }
            let messageCount = sortedDays.reduce(0) { $0 + $1.messageCount }
            return MonthlyBucket(
                monthStart: monthStart,
                usage: usage,
                costUSD: cost,
                messageCount: messageCount,
                days: sortedDays
            )
        }
        .sorted { $0.monthStart > $1.monthStart }
    }

    public func totals(records: [UsageRecord], filter: AggregationFilter = .init()) -> (usage: TokenUsage, costUSD: Double) {
        let summary = costSummary(records: records, filter: filter)
        return (summary.usage, summary.costUSD)
    }

    public func costSummary(
        records: [UsageRecord],
        filter: AggregationFilter = .init()
    ) -> CostAggregationSummary {
        var usage = TokenUsage.zero
        var cost = 0.0
        var pricedRecordCount = 0
        var freeRecordCount = 0
        var unpricedRecordCount = 0
        var unpricedModels = Set<String>()

        for r in records where filter.matches(r) {
            usage += r.usage
            let estimate = priceBook.estimate(for: r)
            cost += estimate.estimatedUSD
            switch estimate.coverage {
            case .priced:
                pricedRecordCount += 1
            case .free:
                freeRecordCount += 1
            case .unpriced:
                unpricedRecordCount += 1
                unpricedModels.insert(r.model)
            }
        }

        return CostAggregationSummary(
            usage: usage,
            costUSD: cost,
            pricingCoverage: PricingCoverageSummary(
                pricedRecordCount: pricedRecordCount,
                freeRecordCount: freeRecordCount,
                unpricedRecordCount: unpricedRecordCount,
                unpricedModels: unpricedModels.sorted()
            )
        )
    }
}
