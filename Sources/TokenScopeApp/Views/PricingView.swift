import SwiftUI
import TokenScopeCore

struct PricingView: View {
    @EnvironmentObject var store: AppStore
    @State private var prices: [ModelPrice] = []
    @State private var sortOrder: [KeyPathComparator<ModelPrice>] = [
        KeyPathComparator(\.provider.rawValue),
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
            TableColumn(L10n.string("Provider"), value: \.provider.rawValue) { p in
                Text(p.provider.displayName)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
            TableColumn(L10n.string("Model"), value: \.model) { p in
                Text(p.model)
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
                Text(sourceText(p.source))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        p.source == .user
                            ? Color.accentColor.opacity(0.2)
                            : Color.secondary.opacity(0.1),
                        in: Capsule()
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(p) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let p = prices.first(where: { $0.id == id }) {
                Button(L10n.string("Edit…")) { editing = p; showForm = true }
                if p.source == .user {
                    Button(L10n.string("Delete Override"), role: .destructive) {
                        store.removePrice(model: p.model)
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

    @State private var provider: Provider = .anthropicAPI
    @State private var model: String = ""
    @State private var inputStr: String = "0"
    @State private var outputStr: String = "0"
    @State private var cacheReadStr: String = "0"
    @State private var cacheCreateStr: String = "0"
    @State private var currency: String = "USD"

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
                    Picker(L10n.string("Provider"), selection: $provider) {
                        ForEach(Provider.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    TextField(L10n.string("Model name (e.g. glm-4.7)"), text: $model)
                        .disabled(isEditing)
                        .textFieldStyle(.roundedBorder)
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
                    let price = ModelPrice(
                        provider: provider,
                        model: model.trimmingCharacters(in: .whitespaces),
                        inputPerMillion: Double(inputStr) ?? 0,
                        outputPerMillion: Double(outputStr) ?? 0,
                        cacheReadPerMillion: Double(cacheReadStr) ?? 0,
                        cacheCreationPerMillion: Double(cacheCreateStr) ?? 0,
                        currency: currency,
                        source: .user
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
                provider = p.provider
                model = p.model
                inputStr = format(p.inputPerMillion)
                outputStr = format(p.outputPerMillion)
                cacheReadStr = format(p.cacheReadPerMillion)
                cacheCreateStr = format(p.cacheCreationPerMillion)
                currency = p.currency
            }
        }
    }

    private func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        return String(format: "%g", v)
    }
}
