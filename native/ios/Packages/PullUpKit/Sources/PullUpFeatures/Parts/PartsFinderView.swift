import SwiftUI
import PullUpDesign
import PullUpDomain

/// Parts finder, Stage A: builds a vehicle-aware eBay search and opens it.
/// Pull Up shows no listings, prices or sellers, and says so, because it has
/// no eBay API access yet (docs/MARKETPLACE_FEASIBILITY.md). It never checks
/// fitment either; the note under the search says what the words can and
/// can't tell.
struct PartsFinderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.clusterTheme) private var theme

    /// The garage vehicle the search started from, or nil for one typed in.
    @State private var selectedID: Vehicle.ID?
    @State private var query: PartsQuery
    @State private var openFailed: URL?

    init(vehicle: Vehicle?) {
        _selectedID = State(initialValue: vehicle?.id)
        _query = State(initialValue: vehicle.map { PartsQuery(vehicle: $0) } ?? PartsQuery())
    }

    private var garage: [Vehicle] { app.garage.active }
    private var selected: Vehicle? { garage.first { $0.id == selectedID } }

    private var campaign: AffiliateCampaign? {
        AffiliateCampaign(id: Bundle.main.object(forInfoDictionaryKey: "PullUpEPNCampaignID") as? String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                NoticeStrip("Pull Up doesn't show eBay listings, prices or sellers. Searching opens eBay, where you check fitment, condition and the seller before you buy.")
                vehicleSection
                partSection
                searchSection
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .canvasBackground()
        .clusterNavigation("Find parts")
    }

    // MARK: Vehicle

    private var vehicleSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Legend("Vehicle")
                Spacer()
                if !garage.isEmpty { vehiclePicker }
            }
            HStack(spacing: Space.m) {
                field("Year", text: $query.vehicle.year, prompt: "2019", id: "parts-year")
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 90)
                field("Make", text: $query.vehicle.make, prompt: "BMW", id: "parts-make")
            }
            HStack(spacing: Space.m) {
                field("Model", text: $query.vehicle.model, prompt: "M340i", id: "parts-model")
                field("Trim", text: $query.vehicle.trim, prompt: "Optional", id: "parts-trim")
            }
            field("Engine", text: $query.vehicle.engine, prompt: "Optional, for example B58 3.0 or 750cc", id: "parts-engine")
        }
    }

    private var vehiclePicker: some View {
        Menu {
            ForEach(garage) { vehicle in
                Button {
                    pick(vehicle)
                } label: {
                    if vehicle.id == selectedID {
                        Label(PartsVehicle(vehicle).terms, systemImage: "checkmark")
                    } else {
                        Text(PartsVehicle(vehicle).terms)
                    }
                }
            }
            Divider()
            Button("Other vehicle", systemImage: "square.and.pencil") { pick(nil) }
        } label: {
            HStack(spacing: Space.xs) {
                Text(pickerTitle).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(ClusterFont.headline(.footnote))
            .foregroundStyle(theme.accentColor)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Choose a vehicle from your garage")
        .accessibilityValue(selected.map { PartsVehicle($0).terms } ?? "Other vehicle")
        .accessibilityIdentifier("parts-vehicle-picker")
    }

    private var pickerTitle: String {
        guard let selected else { return "Other vehicle" }
        return selected.nickname.isEmpty ? "\(selected.make) \(selected.model)" : selected.nickname
    }

    private func pick(_ vehicle: Vehicle?) {
        selectedID = vehicle?.id
        // The engine is never stored, so whatever was typed stays.
        var next = vehicle.map(PartsVehicle.init) ?? PartsVehicle()
        next.engine = query.vehicle.engine
        query.vehicle = next
    }

    // MARK: Part

    private var partSection: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SwitchBank(PartsQuery.Mode.allCases, selection: $query.mode) { $0.label }
            switch query.mode {
            case .description:
                field("Part", text: $query.part, prompt: "Brake pads, oil filter…", id: "parts-part")
                    .submitLabel(.search)
                    .onSubmit(search)
                suggestions
            case .partNumber:
                field("Part number", text: $query.partNumber, prompt: "As printed on the part or in the manual", id: "parts-number")
                    .submitLabel(.search)
                    .onSubmit(search)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Brand")
                SwitchBank(PartsQuery.Source.allCases, selection: $query.source) { $0.label }
                Text("OEM parts come from the vehicle's maker or its supplier; aftermarket parts are other brands. Sellers label these themselves, so this adds a word to the search.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Condition")
                SwitchBank(PartsQuery.Condition.allCases, selection: $query.condition) { $0.label }
            }
        }
    }

    // MARK: Search

    private var preview: String {
        guard query.canSearch else {
            return query.mode == .partNumber ? "Nothing yet. Enter a part number." : "Nothing yet. Add a part to search for."
        }
        let condition = query.condition == .any ? "" : ", \(query.condition.label.lowercased()) only"
        return "\u{201C}\(query.keywords)\u{201D} in Parts & Accessories\(condition)"
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend("Sent to eBay")
            Text(preview)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("parts-preview")
            NoticeStrip(query.fitmentNote, tone: .estimate)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("parts-fitment")
            if campaign != nil {
                // Before the button, so it's seen before the link is opened.
                Text(AffiliateCampaign.disclosure)
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("parts-affiliate-disclosure")
            }
            Button(action: search) {
                Label("Search eBay", systemImage: "safari").frame(maxWidth: .infinity)
            }
            .buttonStyle(.cluster)
            .disabled(!query.canSearch)
            .accessibilityIdentifier("parts-search")
            if let openFailed {
                VStack(alignment: .leading, spacing: Space.s) {
                    NoticeStrip("eBay didn't open. Share or copy the link to open it in Safari.", tone: .caution)
                    ShareLink(item: openFailed) {
                        Label("Share link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.clusterSecondary)
                    .accessibilityIdentifier("parts-share-link")
                }
            }
            Text("Only the words above leave your phone, and only when you tap Search.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Legend(label)
            TextField(prompt, text: text)
                .font(ClusterFont.body())
                .foregroundStyle(ClusterColor.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.vertical, Space.xs)
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
            Hairline(color: ClusterColor.ruleStrong)
        }
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                ForEach(PartsQuery.suggestions(for: selected?.kind), id: \.self) { part in
                    Button {
                        query.part = part
                    } label: {
                        Text(part)
                            .font(ClusterFont.headline(.footnote))
                            .foregroundStyle(query.part == part ? ClusterColor.ink : ClusterColor.inkSecondary)
                            .padding(.horizontal, Space.m)
                            .frame(minHeight: 36)
                            .background(query.part == part ? theme.accentColor.opacity(0.18) : ClusterColor.plateRaised, in: ChamferedRectangle(cut: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(query.part == part ? .isSelected : [])
                }
            }
        }
        .accessibilityLabel("Common parts")
    }

    private func search() {
        guard let url = EbaySearchLink.url(for: query, campaign: campaign) else { return }
        openFailed = nil
        // Opens the eBay app when it's installed (eBay's universal link),
        // otherwise Safari. If neither accepts it, offer the link instead.
        openURL(url) { accepted in
            if !accepted { openFailed = url }
        }
    }
}
