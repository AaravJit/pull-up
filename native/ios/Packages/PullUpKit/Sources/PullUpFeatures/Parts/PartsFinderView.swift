import SwiftUI
import PullUpDesign
import PullUpDomain

/// Parts finder, Stage A: builds a vehicle-aware eBay search and opens it in
/// Safari. Pull Up shows no listings, prices or sellers, and says so, because
/// it has no eBay API access yet (docs/MARKETPLACE_FEASIBILITY.md).
struct PartsFinderView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.clusterTheme) private var theme

    let vehicleKind: VehicleKind?
    @State private var query: PartsQuery

    init(vehicle: Vehicle?) {
        vehicleKind = vehicle?.kind
        _query = State(initialValue: vehicle.map { PartsQuery(vehicle: $0) } ?? PartsQuery())
    }

    private var campaign: AffiliateCampaign? {
        AffiliateCampaign(id: Bundle.main.object(forInfoDictionaryKey: "PullUpEPNCampaignID") as? String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                NoticeStrip("Pull Up doesn't show eBay listings, prices or sellers. Searching opens eBay in Safari, where you check fitment, condition and the seller before you buy.")
                VStack(alignment: .leading, spacing: Space.l) {
                    field("Vehicle", text: $query.vehicle, prompt: "Year, make, model", id: "parts-vehicle")
                    field("Part", text: $query.part, prompt: "Brake pads, part number…", id: "parts-part")
                        .submitLabel(.search)
                        .onSubmit(search)
                    suggestions
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("Condition")
                        SwitchBank(PartsQuery.Condition.allCases, selection: $query.condition) { $0.label }
                    }
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    Legend("Sent to eBay")
                    Text(query.canSearch ? "“\(query.keywords)” in Parts & Accessories\(query.condition == .any ? "" : ", \(query.condition.label.lowercased()) only")" : "Nothing yet. Add a part to search for.")
                        .font(ClusterFont.body(.footnote))
                        .foregroundStyle(ClusterColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("parts-preview")
                    Button(action: search) {
                        Label("Search eBay", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.cluster)
                    .disabled(!query.canSearch)
                    .accessibilityIdentifier("parts-search")
                    if campaign != nil {
                        Text(AffiliateCampaign.disclosure)
                            .font(ClusterFont.body(.caption))
                            .foregroundStyle(ClusterColor.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("eBay's results and fitment data aren't checked by Pull Up. Only the words above leave your phone, and only when you tap Search.")
                        .font(ClusterFont.body(.caption))
                        .foregroundStyle(ClusterColor.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
        }
        .canvasBackground()
        .clusterNavigation("Find parts")
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
                ForEach(PartsQuery.suggestions(for: vehicleKind), id: \.self) { part in
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
        openURL(url)
    }
}
