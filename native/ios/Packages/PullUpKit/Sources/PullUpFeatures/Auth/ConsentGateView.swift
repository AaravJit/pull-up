import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// The minimum-age question and the Terms and Community Guidelines, before
/// onboarding and whenever the terms change (`AppModel.consentGate`). Also
/// shown in a sheet from a composer whose post the server refused for want
/// of them (`inSheet`), so the draft stays open.
///
/// The date of birth stays on this iPhone: only whether it meets the
/// minimum is sent. That is a self-declared answer, not age verification;
/// the server only records it and refuses publishing without it.
struct ConsentGateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var inSheet = false

    @State private var birthDate = Date.now
    @State private var pickedDate = false
    @State private var confirmingAge = false
    @State private var busy = false
    @State private var error: String?
    @State private var deleting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let consent = app.consent {
                    if consent.isUnderMinimum {
                        unavailable(consent)
                    } else if consent.needsAgeCheck {
                        ageStep(consent)
                    } else if consent.needsTerms {
                        termsStep(consent)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } else {
                    loadFailed
                }
                if let error { ErrorLine(message: error) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.xl)
        }
        .canvasBackground()
        .accessibilityIdentifier("consent-gate")
        .sheet(isPresented: $deleting) { DeleteAccountView() }
        .onChange(of: app.consent?.isSatisfied) { _, satisfied in
            if inSheet, satisfied == true { dismiss() }
        }
    }

    // MARK: Age

    private func ageStep(_ consent: ConsentStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ScreenTitle("Your date of birth", subtitle: "Before you start")
            Text("Pull Up uses it once, on this iPhone, to check the age requirement in its terms. Only the result is saved to your account. The date itself is never sent or stored.")
                .font(ClusterFont.body())
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Date of birth", selection: $birthDate, in: AgeGate.earliestBirthDate()...Date.now, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: birthDate) { pickedDate = true }
                .accessibilityIdentifier("consent-birth-date")
            Button {
                confirmingAge = true
            } label: {
                Text(busy ? "Saving" : "Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.cluster)
            .disabled(!pickedDate || busy)
            .accessibilityIdentifier("consent-age-continue")
            signOutButton
        }
        .confirmationDialog(
            "Is \(birthDate.formatted(date: .long, time: .omitted)) your date of birth?",
            isPresented: $confirmingAge, titleVisibility: .visible
        ) {
            Button("Yes, continue") { Task { await recordAge(consent) } }
            Button("Change it", role: .cancel) {}
        } message: {
            Text("Check it before you continue. Your answer is saved to your account.")
        }
    }

    private func recordAge(_ consent: ConsentStatus) async {
        guard let service = app.backend as? any ConsentService else { return }
        busy = true
        defer { busy = false }
        let meets = AgeGate.meetsMinimum(birthDate: birthDate, minimumAge: consent.minimumAge)
        do {
            let status = try await service.recordAgeCheck(meetsMinimum: meets)
            // Nothing keeps the date once it's been used.
            birthDate = .now
            pickedDate = false
            error = nil
            app.applyConsent(status, showGate: !inSheet)
        } catch {
            self.error = error.localizedDescription
            await app.refreshConsent(showGate: !inSheet)
        }
    }

    // MARK: Terms

    private func termsStep(_ consent: ConsentStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ScreenTitle(consent.isTermsUpdate ? "Pull Up's terms have changed" : "The rules of the road",
                        subtitle: "Updated \(consent.termsDateText)")
            if consent.isTermsUpdate {
                Text(consent.termsSummary.isEmpty
                     ? "Review the updated Terms and Community Guidelines to keep posting, commenting and messaging."
                     : consent.termsSummary)
                    .font(ClusterFont.body())
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.m) {
                RuleRow(symbol: "steeringwheel", text: "No public-road racing, speed challenges or stunts. Set up and check the app only while safely parked.")
                RuleRow(symbol: "person.2", text: "Respect people: no harassment, hate or threats, and no sharing someone's private details or location.")
                RuleRow(symbol: "photo.on.rectangle", text: "Share only photos, videos, music and text you own or have permission to share, including of the people shown.")
                RuleRow(symbol: "flag", text: "Content that breaks the rules can be reported and removed, and accounts restricted.")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach([LegalLinks.Page.terms, .community, .privacy], id: \.self) { page in
                    if let url = LegalLinks.url(for: page) {
                        LinkRow(label: page.title, destination: url)
                            .accessibilityIdentifier("consent-link-\(page.rawValue)")
                    }
                }
            }
            if LegalLinks.terms == nil || LegalLinks.community == nil {
                NoticeStrip("This build has no link to the full Terms or Community Guidelines.", tone: .caution)
            }
            Text("By tapping I agree, you accept the Terms and the Community Guidelines. Pull Up records which version you accepted and when. The Privacy Policy explains how your information is handled.")
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await accept(consent) }
            } label: {
                Text(busy ? "Saving" : "I agree").frame(maxWidth: .infinity)
            }
            .buttonStyle(.cluster)
            .disabled(busy)
            .accessibilityIdentifier("consent-agree")
            signOutButton
        }
    }

    private func accept(_ consent: ConsentStatus) async {
        guard let service = app.backend as? any ConsentService else { return }
        busy = true
        defer { busy = false }
        do {
            let status = try await service.acceptTerms(version: consent.termsVersion)
            error = nil
            app.applyConsent(status, showGate: !inSheet)
        } catch {
            // Usually the terms changed meanwhile: show the new version.
            self.error = error.localizedDescription
            await app.refreshConsent(showGate: !inSheet)
        }
    }

    // MARK: Under the minimum

    private func unavailable(_ consent: ConsentStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ScreenTitle("Pull Up isn't available to you", subtitle: "Age requirement")
            Text("Pull Up is only for people \(consent.minimumAge) and older, so this account can't post, comment, message or follow, and it's hidden from other people. You can delete the account and everything in it now.")
                .font(ClusterFont.body())
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                deleting = true
            } label: {
                Text("Delete account").frame(maxWidth: .infinity)
            }
            .buttonStyle(.clusterDestructive)
            .accessibilityIdentifier("consent-delete-account")
            signOutButton
            if let support = LegalLinks.support {
                LinkRow(label: "Support", destination: support)
            }
        }
    }

    private var loadFailed: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ScreenTitle("Couldn't reach Pull Up", subtitle: "Terms")
            Text("Pull Up needs to check your account before you continue.")
                .font(ClusterFont.body())
                .foregroundStyle(ClusterColor.inkSecondary)
            Button {
                Task { await app.refreshConsent(showGate: !inSheet) }
            } label: {
                Text("Try again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.cluster)
            signOutButton
        }
    }

    @ViewBuilder
    private var signOutButton: some View {
        if !inSheet {
            Button {
                Task { await app.signOut() }
            } label: {
                Text("Sign out").frame(maxWidth: .infinity)
            }
            .buttonStyle(.clusterSecondary)
            .disabled(busy)
            .accessibilityIdentifier("consent-sign-out")
        }
    }
}

private struct RuleRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(ClusterColor.inkSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(ClusterFont.body(.subheadline))
                .foregroundStyle(ClusterColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
