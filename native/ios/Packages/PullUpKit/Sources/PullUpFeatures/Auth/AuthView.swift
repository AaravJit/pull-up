import AuthenticationServices
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// Sign-in. Sign in with Apple is the only way to create an account: one
/// tap, no Pull Up password, and Apple can hide the person's email. It is
/// native: the identity token and the raw nonce go to Supabase, which checks
/// both with Apple. Email sign-in sits behind "Other ways to sign in" for
/// accounts made by Pull Up support (the App Review demo account), and the
/// build can turn it off with `PullUpEmailSignIn = NO` in Info.plist.
struct AuthView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var nonce = ""
    @State private var showEmail = false

    private var emailSignInEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "PullUpEmailSignIn") as? Bool) ?? true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                TickRule()
                if let notice = app.signedOutNotice {
                    NoticeStrip(notice, tone: .info)
                        .accessibilityIdentifier("signed-out-notice")
                }

                VStack(alignment: .leading, spacing: Space.m) {
                    SignInWithAppleButton(.continue) { request in
                        nonce = Nonce.random()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = Nonce.sha256(nonce)
                    } onCompletion: { result in
                        Task { await handleApple(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 52)
                    .clipShape(ChamferedRectangle(cut: Radius.chamferSmall))
                    .disabled(busy)
                    .accessibilityIdentifier("continue-with-apple")

                    VStack(alignment: .leading, spacing: Space.xs) {
                        promise("key", "No Pull Up password to make or forget.")
                        promise("envelope", "Hide My Email works. Pull Up never shows your email to anyone.")
                        promise("at", "New here? You'll pick a username next.")
                    }
                }

                if busy { ProgressView().frame(maxWidth: .infinity) }
                if let message {
                    NoticeStrip(message, tone: .caution).accessibilityIdentifier("auth-error")
                }

                if app.isDemo {
                    Button {
                        Task { await demoSignIn() }
                    } label: {
                        Text("Continue with demo account").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.clusterSecondary)
                    .accessibilityIdentifier("demo-sign-in")
                }

                if emailSignInEnabled { emailSection }

                Text("By continuing you agree to drive legally. Pull Up never ranks street speeds.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xl)
        }
        .canvasBackground()
        .accessibilityIdentifier("auth")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                VehicleSilhouette(.coupe, color: ClusterColor.ink, lineWidth: 1.6).frame(width: 90, height: 36)
                VehicleSilhouette(.sport, color: ClusterColor.inkSecondary, lineWidth: 1.6).frame(width: 70, height: 36)
            }
            .accessibilityHidden(true)
            Text("Pull Up")
                .font(ClusterFont.title(.largeTitle))
                .tracking(Tracking.title)
                .foregroundStyle(ClusterColor.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Drive. Meet. Connect.")
                .font(ClusterFont.body(.title3))
                .foregroundStyle(ClusterColor.inkSecondary)
        }
        .padding(.top, Space.xxxl)
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(ClusterColor.inkSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Button {
                withAnimation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion)) { showEmail.toggle() }
            } label: {
                HStack {
                    Legend("Other ways to sign in")
                    Spacer()
                    Image(systemName: showEmail ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClusterColor.inkTertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("other-sign-in")

            if showEmail {
                VStack(alignment: .leading, spacing: Space.l) {
                    Text("For accounts set up by Pull Up support. New accounts are created with Sign in with Apple.")
                        .font(ClusterFont.body(.footnote))
                        .foregroundStyle(ClusterColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FieldRow(label: "Email", text: $email, keyboard: .emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Legend("Password")
                        SecureField("", text: $password)
                            .textContentType(.password)
                            .padding(.vertical, Space.xs)
                        Hairline(color: ClusterColor.ruleStrong)
                    }
                    Button {
                        Task { await emailSignIn() }
                    } label: {
                        Text("Sign in with email").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.clusterSecondary)
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
                .transition(.opacity)
            }
        }
    }

    private func emailSignIn() async {
        busy = true
        defer { busy = false }
        do {
            try await app.backend.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            message = nil
            app.signedOutNotice = nil
        } catch {
            message = AuthMessages.server(error)
        }
    }

    /// Demo builds only: stands in for the Apple sheet, which can't complete
    /// in CI. Signs in to the labelled in-memory demo account.
    private func demoSignIn() async {
        busy = true
        defer { busy = false }
        try? await app.backend.signInWithApple(idToken: "demo", nonce: "demo")
        app.signedOutNotice = nil
    }

    private func handleApple(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                message = "Apple didn't return a sign-in token. Try again."
                return
            }
            busy = true
            defer { busy = false }
            do {
                // Apple shares the name only on the very first authorization.
                let name = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                try await app.backend.signInWithApple(idToken: token, nonce: nonce)
                app.didSignInWithApple(userIdentifier: credential.user, suggestedName: name)
                message = nil
                app.signedOutNotice = nil
            } catch {
                message = AuthMessages.server(error)
            }
        case let .failure(error):
            message = AuthMessages.apple(error)
        }
    }
}

/// Shown when the build has no server keys: explains the missing step and
/// offers the clearly labelled demo instead of pretending to work.
struct SetupRequiredView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                ScreenTitle("Server not configured", subtitle: "Pull Up")
                    .padding(.top, Space.xxxl)
                Text("This build doesn't include Supabase keys, so it can't sign in or sync. Add PULLUP_SUPABASE_HOST and PULLUP_SUPABASE_ANON_KEY to Config/Secrets.xcconfig (or the CI secrets) and rebuild.")
                    .font(ClusterFont.body())
                    .foregroundStyle(ClusterColor.ink)
                NoticeStrip("Demo mode uses made-up people, cars and meets stored only in memory. Nothing is saved and every screen is labelled.", tone: .estimate)
                Button {
                    Task { await app.enterDemo() }
                } label: {
                    Text("Explore with demo data").frame(maxWidth: .infinity)
                }
                .buttonStyle(.cluster)
            }
            .padding(.horizontal, Space.gutter)
        }
        .canvasBackground()
    }
}
