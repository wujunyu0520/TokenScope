import Foundation

public final class PriceBook: @unchecked Sendable {
    private var builtin: [String: ModelPrice]
    private var userOverrides: [String: ModelPrice]
    private let storageURL: URL?

    public init(
        builtin: [ModelPrice] = BuiltinPrices.all,
        userOverrides: [ModelPrice] = [],
        storageURL: URL? = PriceBook.defaultStorageURL
    ) {
        self.builtin = Dictionary(uniqueKeysWithValues: builtin.map { (Self.storageKey(for: $0), $0) })
        self.userOverrides = Dictionary(uniqueKeysWithValues: userOverrides.map { (Self.storageKey(for: $0), $0) })
        self.storageURL = storageURL
        if userOverrides.isEmpty {
            loadFromDisk()
        }
    }

    public static var defaultStorageURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base
            .appendingPathComponent("TokenScope", isDirectory: true)
            .appendingPathComponent("user_prices.json")
    }

    public func price(for key: PricingKey) -> ModelPrice? {
        findPrice(in: userOverrides.values, key: key)
            ?? findPrice(in: builtin.values, key: key)
    }

    public func price(forModel model: String) -> ModelPrice? {
        let matches = PricingVendor.allCases.compactMap { vendor in
            price(for: PricingKey(
                sourceProvider: vendor.legacyProvider,
                upstreamProviderID: vendor.rawValue,
                modelID: model
            ))
        }
        let unique = Dictionary(uniqueKeysWithValues: matches.map { ($0.id, $0) })
        return unique.count == 1 ? unique.values.first : nil
    }

    public func estimate(for record: UsageRecord) -> CostEstimate {
        estimate(for: record.usage, key: PricingKey(record: record))
    }

    public func estimate(for usage: TokenUsage, key: PricingKey) -> CostEstimate {
        guard let price = price(for: key) else {
            return CostEstimate(
                estimatedUSD: 0,
                coverage: .unpriced,
                canonicalModel: nil,
                vendor: key.vendor,
                sourceURL: nil,
                verifiedOn: nil
            )
        }

        return CostEstimate(
            estimatedUSD: price.cost(for: usage),
            coverage: price.isFree ? .free : .priced,
            canonicalModel: price.model,
            vendor: price.vendor,
            sourceURL: price.sourceURL,
            verifiedOn: price.verifiedOn
        )
    }

    @discardableResult
    public func upsert(_ price: ModelPrice) -> ModelPrice {
        let stored = ModelPrice(
            provider: price.provider,
            vendor: price.vendor,
            model: price.model,
            aliases: price.aliases,
            inputPerMillion: price.inputPerMillion,
            outputPerMillion: price.outputPerMillion,
            cacheReadPerMillion: price.cacheReadPerMillion,
            cacheCreationPerMillion: price.cacheCreationPerMillion,
            currency: price.currency,
            source: .user,
            sourceURL: price.sourceURL,
            verifiedOn: price.verifiedOn,
            isFree: price.isFree,
            rule: price.rule
        )
        userOverrides[Self.storageKey(for: stored)] = stored
        saveToDisk()
        return stored
    }

    public func remove(vendor: PricingVendor, modelName: String) {
        userOverrides.removeValue(forKey: Self.storageKey(vendor: vendor, model: modelName))
        saveToDisk()
    }

    public func remove(modelName: String) {
        userOverrides = userOverrides.filter { $0.value.model != modelName }
        saveToDisk()
    }

    public func resetUserOverrides() {
        userOverrides.removeAll()
        saveToDisk()
    }

    public func isUserOverride(vendor: PricingVendor, model: String) -> Bool {
        userOverrides[Self.storageKey(vendor: vendor, model: model)] != nil
    }

    public func isUserOverride(model: String) -> Bool {
        userOverrides.values.contains { $0.model == model }
    }

    public func cost(for usage: TokenUsage, model: String) -> Double {
        price(forModel: model)?.cost(for: usage) ?? 0
    }

    public func listAll() -> [ModelPrice] {
        var merged = builtin
        for (key, value) in userOverrides { merged[key] = value }
        return merged.values.sorted { lhs, rhs in
            if lhs.vendor != rhs.vendor {
                return lhs.vendor.rawValue < rhs.vendor.rawValue
            }
            return lhs.model < rhs.model
        }
    }

    public func listUserOverrides() -> [ModelPrice] {
        userOverrides.values.sorted {
            if $0.vendor != $1.vendor { return $0.vendor.rawValue < $1.vendor.rawValue }
            return $0.model < $1.model
        }
    }

    private func findPrice(
        in prices: Dictionary<String, ModelPrice>.Values,
        key: PricingKey
    ) -> ModelPrice? {
        let normalizedModel = Self.normalize(key.modelID)
        let vendorPrices = prices.filter { $0.vendor == key.vendor }

        if let exact = vendorPrices.first(where: { Self.normalize($0.model) == normalizedModel }) {
            return exact
        }
        if let alias = vendorPrices.first(where: { price in
            price.aliases.contains { Self.normalize($0) == normalizedModel }
        }) {
            return alias
        }
        return vendorPrices.first { price in
            Self.isApprovedSnapshot(model: normalizedModel, canonicalModel: Self.normalize(price.model))
                || price.aliases.contains {
                    Self.isApprovedSnapshot(model: normalizedModel, canonicalModel: Self.normalize($0))
                }
        }
    }

    private static func isApprovedSnapshot(model: String, canonicalModel: String) -> Bool {
        if model.hasPrefix(canonicalModel + "[") && model.hasSuffix("]") {
            return true
        }
        guard model.hasPrefix(canonicalModel + "-") else { return false }
        let suffix = String(model.dropFirst(canonicalModel.count + 1))
        if suffix.count == 8, suffix.allSatisfy(\.isNumber) { return true }
        let parts = suffix.split(separator: "-")
        return parts.count == 3
            && parts[0].count == 4
            && parts[1].count == 2
            && parts[2].count == 2
            && parts.joined().allSatisfy(\.isNumber)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func storageKey(for price: ModelPrice) -> String {
        storageKey(vendor: price.vendor, model: price.model)
    }

    private static func storageKey(vendor: PricingVendor, model: String) -> String {
        "\(vendor.rawValue):\(normalize(model))"
    }

    private func loadFromDisk() {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ModelPrice].self, from: data)
        else { return }
        for price in items {
            userOverrides[Self.storageKey(for: price)] = ModelPrice(
                provider: price.provider,
                vendor: price.vendor,
                model: price.model,
                aliases: price.aliases,
                inputPerMillion: price.inputPerMillion,
                outputPerMillion: price.outputPerMillion,
                cacheReadPerMillion: price.cacheReadPerMillion,
                cacheCreationPerMillion: price.cacheCreationPerMillion,
                currency: price.currency,
                source: .user,
                sourceURL: price.sourceURL,
                verifiedOn: price.verifiedOn,
                isFree: price.isFree,
                rule: price.rule
            )
        }
    }

    private func saveToDisk() {
        guard let url = storageURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let items = Array(userOverrides.values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
