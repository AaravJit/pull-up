import AuthenticationServices
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// Account deletion (App Store Review Guideline 5.1.1(v)). Deletion happens
/// on the server. For Sign in with Apple accounts the person confirms with
/// Apple once more, which gives the server a fresh authorization code so it
/// can revoke Pull Up's access to their Apple ID as Apple requires.
struct DeleteAccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?
    /// The Apple prompt failed or was cancelled. Only then is deleting
    /// without it offered, so revoking Apple's access isn't skipped by default.
    @State private var appleFailed = false

    private var usesApple: Bool { app.account?.signInMethods.contains(.apple) ?? false }
    private var confirmed: Bool { confirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Text("This permanently deletes your profile, garage, drives, routes, posts, photos and messages from the Pull Up server. It can't be undone.")
                        .font(ClusterFont.body())
                        .foregroundStyle(ClusterColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    FieldRow(label: "Type DELETE to confirm", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("delete-confirmation")
                    if let error { ErrorLine(message: error) }
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    if usesApple {
                        Text("Confirm with Apple so Pull Up can also disconnect your Apple Account.")
                            .font(ClusterFont.body(.footnote))
                            .foregroundStyle(ClusterColor.inkSecondary)
                        SignInWithAppleButton(.continue) { request in
                            request.requestedScopes = []
                        } onCompletion: { result in
                            Task { await confirmWithApple(result) }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                        .clipShape(ChamferedRectangle(cut: Radius.chamferSmall))
                        .disabled(!confirmed || busy)
                        .opacity(confirmed ? 1 : 0.4)
                        if appleFailed {
                            Text("Your account is still deleted without Apple, but Pull Up stays connected to your Apple Account until you remove it in Settings ▸ your name ▸ Sign in with Apple.")
                                .font(ClusterFont.body(.footnote))
                                .foregroundStyle(ClusterColor.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Delete without confirming with Apple") {
                                Task { await delete(appleCode: nil) }
                            }
                            .font(ClusterFont.body(.footnote))
                            .foregroundStyle(ClusterColor.live)
                            .disabled(!confirmed || busy)
                            .accessibilityIdentifier("delete-without-apple")
                        }
                    } else {
                        Button {
                            Task { await delete(appleCode: nil) }
                        } label: {
                            Text("Delete account").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.clusterDestructive)
                        .disabled(!confirmed || busy)
                        .accessibilityIdentifier("confirm-delete-account")
                    }
                }
                .padding(Space.gutter)
            }
            .canvasBackground()
            .clusterNavigation("Delete account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func confirmWithApple(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case let .success(authorization):
            let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            await delete(appleCode: code)
        case let .failure(failure):
            error = AuthMessages.apple(failure)
            appleFailed = true
        }
    }

    private func delete(appleCode: String?) async {
        busy = true
        defer { busy = false }
        do {
            try await app.deleteAccount(appleAuthorizationCode: appleCode)
            dismiss()
        } catch {
            self.error = AuthMessages.server(error)
        }
    }
}
