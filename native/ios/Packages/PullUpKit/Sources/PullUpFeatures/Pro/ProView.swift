import StoreKit
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// The Pull Up Pro paywall and subscription status. Prices come from the App
/// Store; when it has no products the screen says so instead of showing any.
struct ProView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var highlight: ProFeature?
    @State private var plan: ProPlan = .yearly
    @State private var managing = false

    private var pro: ProStore { app.pro }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    if !pro.isLive { NoticeStrip("Demo: prices are placeholders and no payment is taken.", tone: .caution) }
                    if pro.isPro { activeCard }
                    features
                    if !pro.isPro { plans }
                    status
                    freeForever
                    legal
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.l)
            }
            .canvasBackground()
            .clusterNavigation("Pull Up Pro")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("pro-close")
                }
            }
            .task {
                await pro.refresh()
                await pro.loadOffers()
            }
            .manageSubscriptionsSheet(isPresented: $managing)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend("Pull Up Pro", color: theme.accentColor)
            Text(pro.isPro ? "Thanks for supporting Pull Up." : "More ways to make the cluster yours.")
                .font(ClusterFont.title(.title2))
                .foregroundStyle(ClusterColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpecRow(label: "Plan", value: pro.entitlement.plan?.label ?? "Pro")
            if let status = pro.entitlement.status, status != .active {
                SpecRow(label: "Status", value: status.label)
            }
            if let expires = pro.entitlement.expiresAt {
                SpecRow(label: pro.entitlement.autoRenew ? "Renews" : "Ends", value: expires.formatted(date: .abbreviated, time: .omitted))
            }
            if let environment = pro.entitlement.environment, environment != "Production" {
                SpecRow(label: "Purchase", value: environment == "Sandbox" ? "Test (sandbox)" : environment)
            }
            if pro.entitlement.status == .gracePeriod {
                NoticeStrip("Apple couldn't renew your subscription. Pro stays on while you update your payment method.", tone: .caution)
                    .padding(.top, Space.s)
            }
            if pro.isLive {
                Button("Manage subscription") { managing = true }
                    .buttonStyle(.clusterSecondary)
                    .padding(.top, Space.m)
                    .accessibilityIdentifier("pro-manage")
            }
        }
        .padding(Space.m)
        .plate(stroke: theme.accentColor)
        .accessibilityIdentifier("pro-active")
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("What Pro adds")
            ForEach(ProFeature.allCases) { feature in
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                        Text(feature.detail).font(ClusterFont.body(.footnote)).foregroundStyle(ClusterColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Space.s)
                .background {
                    if feature == highlight { ChamferedRectangle(cut: 6).fill(theme.accentColor.opacity(0.12)) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var plans: some View {
        if !pro.offers.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Choose a plan")
                HStack(spacing: Space.m) {
                    ForEach(pro.offers) { offer in
                        PlanCard(offer: offer, saving: offer.plan == .yearly ? pro.yearlySaving() : nil, isSelected: plan == offer.plan) {
                            withAnimation(Motion.select) { plan = offer.plan }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: plan)
                Button {
                    Task { await pro.purchase(plan) }
                } label: {
                    Group {
                        if case .purchasing = pro.phase {
                            ProgressView()
                        } else if let offer = pro.offers.first(where: { $0.plan == plan }) {
                            Text("Subscribe for \(offer.displayPrice) a \(plan.period)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.cluster)
                .disabled(pro.phase == .purchasing(.monthly) || pro.phase == .purchasing(.yearly) || pro.phase == .loading)
                .accessibilityIdentifier("pro-subscribe")
            }
        }
        if pro.phase != .loading {
            Button { Task { await pro.restore() } } label: {
                Text("Restore purchases").frame(maxWidth: .infinity)
            }
            .buttonStyle(.clusterSecondary)
                .accessibilityIdentifier("pro-restore")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch pro.phase {
        case .idle, .purchasing:
            EmptyView()
        case .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .unavailable:
            NoticeStrip("Pull Up Pro isn't on sale yet. Its subscriptions haven't been set up in the App Store for this build, so there's nothing to buy.", tone: .caution)
                .accessibilityIdentifier("pro-unavailable")
        case .pending:
            NoticeStrip("Waiting for approval. If Ask to Buy is on, the family organiser needs to approve this. Pro turns on as soon as it's approved.")
                .accessibilityIdentifier("pro-pending")
        case let .activating(message):
            NoticeStrip(message, tone: .caution).accessibilityIdentifier("pro-activating")
        case .purchased:
            NoticeStrip("You're Pro. Every Pro feature above is unlocked.").accessibilityIdentifier("pro-purchased")
        case .restored:
            NoticeStrip("Restored. Pro is active on this account.").accessibilityIdentifier("pro-restored")
        case .nothingToRestore:
            NoticeStrip("No Pull Up Pro subscription was found for this Apple Account.").accessibilityIdentifier("pro-nothing-restored")
        case let .failed(message):
            ErrorLine(message: message).accessibilityIdentifier("pro-failed")
        }
    }

    private var freeForever: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Always free")
            ForEach(ProFeature.freeForever, id: \.self) { item in
                Label(item, systemImage: "checkmark")
                    .font(ClusterFont.body(.footnote))
                    .foregroundStyle(ClusterColor.inkSecondary)
            }
        }
    }

    private var legal: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Payment is charged to your Apple Account when you confirm. The subscription renews automatically at the same price unless you cancel at least 24 hours before the period ends. Manage or cancel it in Settings ▸ your name ▸ Subscriptions.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.l) {
                Link("Terms of Use", destination: ProLinks.terms)
                if let privacy = ProLinks.privacy { Link("Privacy Policy", destination: privacy) }
            }
            .font(ClusterFont.body(.caption))
        }
    }
}

/// Legal links shown with the subscription. Pull Up uses Apple's standard
/// EULA; the privacy policy is set per build (`PULLUP_PRIVACY_POLICY` in
/// Secrets.xcconfig, without the scheme), see docs/RELEASE_CHECKLIST.md.
enum ProLinks {
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static var privacy: URL? {
        privacyURL(from: Bundle.main.object(forInfoDictionaryKey: "PullUpPrivacyPolicyURL") as? String)
    }

    /// "pullup.app/privacy" or "https://pullup.app/privacy"; nil when unset.
    static func privacyURL(from value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        let url = URL(string: value.contains("://") ? value : "https://\(value)")
        // A dotted host: "https://pullup.app/x" left in an xcconfig reads as
        // "https:" ("//" starts a comment there) and would become "https://https:".
        return url?.scheme == "https" && (url?.host()?.contains(".") ?? false) ? url : nil
    }
}

private struct PlanCard: View {
    @Environment(\.clusterTheme) private var theme
    let offer: ProOffer
    let saving: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Legend(offer.plan.label, color: isSelected ? ClusterColor.ink : ClusterColor.inkSecondary)
                    Spacer(minLength: 0)
                    if isSelected { Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(theme.accentColor) }
                }
                Text(offer.displayPrice)
                    .font(ClusterFont.readout(.title2))
                    .foregroundStyle(ClusterColor.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("per \(offer.plan.period)")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkSecondary)
                if let saving {
                    Legend("Save \(saving)%", color: theme.accentColor)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .plate(raised: isSelected, stroke: isSelected ? theme.accentColor : nil)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("pro-plan-\(offer.plan.label.lowercased())")
    }
}

/// A Pro-only control seen without Pro: explains it and opens the paywall.
struct ProLockedCard: View {
    @Environment(\.clusterTheme) private var theme
    let feature: ProFeature
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title).font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                    Text(feature.detail).font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ProBadge()
            }
            .padding(Space.m)
            .plate()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Pull Up Pro")
    }
}

/// Small "PRO" stamp for locked choices.
struct ProBadge: View {
    @Environment(\.clusterTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
            Text("PRO").font(ClusterFont.legend()).tracking(Tracking.legend)
        }
        .foregroundStyle(theme.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay(ChamferedRectangle(cut: 3).stroke(theme.accentColor.opacity(0.6)))
        .accessibilityLabel("Pull Up Pro")
    }
}

extension View {
    /// Presents the Pro paywall, optionally pointing at one feature.
    func proSheet(isPresented: Binding<Bool>, highlight: ProFeature? = nil) -> some View {
        modifier(ProSheetModifier(isPresented: isPresented, highlight: highlight))
    }
}

private struct ProSheetModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool
    let highlight: ProFeature?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ProView(highlight: highlight).clusterTheme(app.themeStore.theme)
        }
    }
}
