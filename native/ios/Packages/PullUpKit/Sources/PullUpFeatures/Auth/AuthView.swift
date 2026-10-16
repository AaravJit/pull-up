import AuthenticationServices
import CryptoKit
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// Sign in with Apple or email. Sign in with Apple is native: the identity
/// token and a hashed nonce go to Supabase, which verifies them with Apple.
struct AuthView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    enum Mode: String, CaseIterable, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
        var label: String { self == .signIn ? "Sign in" : "Create account" }
    }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var busy = false
    @State private var message: String?
    @State private var nonce = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
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
                    Text("Your garage, your drives, your meets.")
                        .font(ClusterFont.body(.title3))
                        .foregroundStyle(ClusterColor.inkSecondary)
                }
                .padding(.top, Space.xxxl)
                TickRule()

                SignInWithAppleButton(.continue) { request in
                    nonce = Nonce.random()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Nonce.sha256(nonce)
                } onCompletion: { result in
                    Task { await handleApple(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(ChamferedRectangle(cut: Radius.chamferSmall))

                HStack {
                    Hairline()
                    Legend("or email")
                    Hairline()
                }

                SwitchBank(Mode.allCases, selection: $mode) { $0.label }
                VStack(alignment: .leading, spacing: Space.l) {
                    FieldRow(label: "Email", text: $email, keyboard: .emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Legend("Password")
                        SecureField("", text: $password)
                            .textContentType(mode == .signIn ? .password : .newPassword)
                            .padding(.vertical, Space.xs)
                        Hairline(color: ClusterColor.ruleStrong)
                    }
                    if mode == .signUp {
                        FieldRow(label: "Username", text: $username, prompt: "lowercase, 3–30")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if let message { NoticeStrip(message, tone: .caution) }
                Button {
                    Task { await submit() }
                } label: {
                    Text(busy ? "Working" : mode.label).frame(maxWidth: .infinity)
                }
                .buttonStyle(.cluster)
                .disabled(busy || email.isEmpty || password.count < 8 || (mode == .signUp && username.count < 3))
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

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            switch mode {
            case .signIn:
                try await app.backend.signIn(email: email, password: password)
            case .signUp:
                if try await app.backend.signUp(email: email, password: password, username: username.lowercased()) == .confirmEmail {
                    message = "Check your email to confirm the account, then sign in."
                    mode = .signIn
                    return
                }
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                message = "Apple didn't return an identity token."
                return
            }
            busy = true
            defer { busy = false }
            do {
                try await app.backend.signInWithApple(idToken: token, nonce: nonce)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
        }
    }
}

enum Nonce {
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset[Int.random(in: 0..<charset.count, using: &generator)] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
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
