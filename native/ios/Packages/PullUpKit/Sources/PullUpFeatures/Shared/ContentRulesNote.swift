import SwiftUI
import PullUpDesign
import PullUpDomain

/// Shown where people publish (the post and meet composers, and every
/// conversation, including a new message request): what sending confirms,
/// with links to the Terms, Community Guidelines and Privacy Policy.
///
/// When the server refuses a write because this account hasn't accepted the
/// current terms or answered the age question (PUC01 / PUC02), the composer's
/// error says so; a new `failure` re-checks the status, and this offers the
/// terms in a sheet so the draft stays open.
struct ContentRulesNote: View {
    enum Context { case post, meet, message }

    @Environment(AppModel.self) private var app
    let context: Context
    /// The composer's latest error, if any.
    var failure: String?
    @State private var reviewing = false

    private var text: String {
        switch context {
        case .post:
            "Only post photos, videos and words you own or have permission to share, including of the people shown. Posts must follow the Terms and Community Guidelines."
        case .meet:
            "Host only events you have permission to hold at the venue. No public-road racing or speed runs. Meets must follow the Terms and Community Guidelines."
        case .message:
            "Messages must follow the Community Guidelines. Only send photos you own or have permission to share."
        }
    }

    private var pages: [LegalLinks.Page] {
        [LegalLinks.Page.terms, .community, .privacy].filter { LegalLinks.url(for: $0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if app.needsConsent {
                NoticeStrip(app.consent?.isUnderMinimum == true
                            ? "This account doesn't meet Pull Up's minimum age, so it can't publish."
                            : "Accept Pull Up's current Terms and Community Guidelines before you post, host or message.",
                            tone: .caution)
                if app.consent?.isUnderMinimum != true {
                    Button("Review the terms") { reviewing = true }
                        .buttonStyle(.clusterSecondary)
                        .accessibilityIdentifier("rules-review-terms")
                }
            }
            Text(text)
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !pages.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.m) { links }
                    VStack(alignment: .leading, spacing: Space.xs) { links }
                }
                .font(ClusterFont.body(.caption))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("content-rules")
        .task(id: failure) {
            if failure != nil { await app.refreshConsent(showGate: false) }
        }
        .sheet(isPresented: $reviewing) {
            NavigationStack {
                ConsentGateView(inSheet: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reviewing = false } }
                    }
            }
        }
    }

    @ViewBuilder
    private var links: some View {
        ForEach(pages, id: \.self) { page in
            if let url = LegalLinks.url(for: page) { Link(page.title, destination: url) }
        }
    }
}
