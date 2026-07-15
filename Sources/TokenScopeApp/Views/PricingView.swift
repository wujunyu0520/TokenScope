import SwiftUI
import TokenScopeCore

struct PricingView: View {
    @EnvironmentObject var store: AppStore
    @State private var prices: [ModelPrice] = []
    @State private var sortOrder: [KeyPathComparator<ModelPrice>] = [
        KeyPathComparator(\.vendor.rawValue),
        KeyPathComparator(\.model),
    ]
    @State private var showForm = false
    @State private var editing: ModelPrice?
    @State private var selectedID: String?

    private var sortedPrices: [ModelPrice] {
        prices.sorted(using: sortOrder)
    }

    private var selectedPrice: ModelPrice? {
        prices.first { $0.id == selectedID }
    }

    private func beginEditing(_ price: ModelPrice) {
        selectedID = price.id
        editing = price
        showForm = true
    }

    var body: some View {
        Table(sortedPrices, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn(L10n.string("Vendor"), value: \.vendor.rawValue) { p in
                Text(p.vendor.displayName)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Model"), value: \.model) { p in
                Text(p.model)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Aliases")) { p in
                Text(p.aliases.isEmpty ? "—" : p.aliases.joined(separator: ", "))
                    .lineLimit(1)
                    .foregroundStyle(p.aliases.isEmpty ? .secondary : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Input / 1M"), value: \.inputPerMillion) { p in
                Text(String(format: "$%.3f", p.inputPerMillion))
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Output / 1M"), value: \.outputPerMillion) { p in
                Text(String(format: "$%.3f", p.outputPerMillion))
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Cache R / 1M"), value: \.cacheReadPerMillion) { p in
                Text(String(format: "$%.3f", p.cacheReadPerMillion))
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Cache W / 1M"), value: \.cacheCreationPerMillion) { p in
                Text(String(format: "$%.3f", p.cacheCreationPerMillion))
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Source")) { p in
                HStack(spacing: 5) {
                    Text(sourceText(p.source))
                        .font(.caption)
                    if let sourceURL = p.sourceURL {
                        Link(destination: sourceURL) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .help(L10n.string("Open official pricing source"))
                    }
                }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Verified")) { p in
                Text(p.verifiedOn ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let p = prices.first(where: { $0.id == id }) {
                Button(L10n.string("Edit…")) { editing = p; showForm = true }
                if p.source == .user {
                    Button(L10n.string("Delete Override"), role: .destructive) {
                        store.removePrice(vendor: p.vendor, model: p.model)
                    }
                }
            }
        }
        .navigationTitle(L10n.string("Pricing"))
        .toolbar {
            ToolbarItem {
                Button {
                    editing = nil
                    showForm = true
                } label: {
                    Label(L10n.string("Add Price"), systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    if let p = selectedPrice {
                        editing = p
                        showForm = true
                    }
                } label: {
                    Label(L10n.string("Edit"), systemImage: "pencil")
                }
                .disabled(selectedID == nil)
            }
        }
        .sheet(isPresented: $showForm) {
            PriceFormSheet(initial: editing) { newPrice in
                store.upsertPrice(newPrice)
            }
        }
        .onAppear { refresh() }
        .onChange(of: store.pricesRevision) { _, _ in refresh() }
    }

    private func refresh() {
        prices = store.priceBook.listAll()
    }

    private func sourceText(_ source: ModelPrice.Source) -> String {
        switch source {
        case .builtin:
            return L10n.string("Builtin")
        case .user:
            return L10n.string("User")
        }
    }
}

private struct PriceFormSheet: View {
    let initial: ModelPrice?
    let onSave: (ModelPrice) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var vendor: PricingVendor = .anthropic
    @State private var model: String = ""
    @State private var aliasesStr: String = ""
    @State private var inputStr: String = "0"
    @State private var outputStr: String = "0"
    @State private var cacheReadStr: String = "0"
    @State private var cacheCreateStr: String = "0"
    @State private var currency: String = "USD"
    @State private var isFree = false

    private var isEditing: Bool { initial != nil }

    private var canSave: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? L10n.string("Edit Price") : L10n.string("Add Price"))
                    .font(.title3).bold()
                Spacer()
            }
            .padding()
            Divider()

            Form {
                Section(L10n.string("Model")) {
                    Picker(L10n.string("Vendor"), selection: $vendor) {
                        ForEach(PricingVendor.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .disabled(isEditing)
                    TextField(L10n.string("Model name (e.g. glm-4.7)"), text: $model)
                        .disabled(isEditing)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.string("Aliases (comma separated)"), text: $aliasesStr)
                        .textFieldStyle(.roundedBorder)
                    Toggle(L10n.string("Free model"), isOn: $isFree)
                }
                Section(L10n.string("Pricing (USD per 1M tokens)")) {
                    LabeledContent(L10n.string("Input")) {
                        TextField("0", text: $inputStr).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(L10n.string("Output")) {
                        TextField("0", text: $outputStr).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(L10n.string("Cache Read")) {
                        TextField("0", text: $cacheReadStr).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(L10n.string("Cache Create")) {
                        TextField("0", text: $cacheCreateStr).textFieldStyle(.roundedBorder)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 360)

            Divider()
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? L10n.string("Save") : L10n.string("Add")) {
                    let aliases = aliasesStr
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let price = ModelPrice(
                        provider: vendor.legacyProvider,
                        vendor: vendor,
                        model: model.trimmingCharacters(in: .whitespaces),
                        aliases: aliases,
                        inputPerMillion: Double(inputStr) ?? 0,
                        outputPerMillion: Double(outputStr) ?? 0,
                        cacheReadPerMillion: Double(cacheReadStr) ?? 0,
                        cacheCreationPerMillion: Double(cacheCreateStr) ?? 0,
                        currency: currency,
                        source: .user,
                        sourceURL: initial?.sourceURL,
                        verifiedOn: initial?.verifiedOn,
                        isFree: isFree,
                        rule: initial?.rule ?? .standard
                    )
                    onSave(price)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            if let p = initial {
                vendor = p.vendor
                model = p.model
                aliasesStr = p.aliases.joined(separator: ", ")
                inputStr = format(p.inputPerMillion)
                outputStr = format(p.outputPerMillion)
                cacheReadStr = format(p.cacheReadPerMillion)
                cacheCreateStr = format(p.cacheCreationPerMillion)
                currency = p.currency
                isFree = p.isFree
            }
        }
    }

    private func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        return String(format: "%g", v)
    }
}
