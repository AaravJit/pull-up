import PhotosUI
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// First run after Sign in with Apple: username, optional photo, privacy.
/// The username is claimed on the server when leaving step 1 (so nobody can
/// take it meanwhile); onboarding is marked complete only at the end, so
/// quitting halfway brings the person back here next launch.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme

    enum Step: Int, CaseIterable {
        case username, photo, privacy
    }

    @State private var step: Step = .username
    @State private var username = ""
    @State private var displayName = ""
    @State private var status: UsernameStatus?
    @State private var checking = false
    @State private var busy = false
    @State private var error: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarPath: String?
    @State private var uploading = false
    @State private var privacy = PrivacySettings()
    @State private var prefilled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                progress
                switch step {
                case .username: usernameStep
                case .photo: photoStep
                case .privacy: privacyStep
                }
                if let error { ErrorLine(message: error) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xl)
            .animation(Motion.sheet, value: step)
        }
        .scrollDismissesKeyboard(.interactively)
        .canvasBackground()
        .accessibilityIdentifier("onboarding")
        .task { await prefill() }
        .onChange(of: app.appleSuggestedName) { Task { await prefill() } }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                if step != .username {
                    Button {
                        error = nil
                        step = Step(rawValue: step.rawValue - 1) ?? .username
                    } label: {
                        Label("Back", systemImage: "chevron.left").font(ClusterFont.headline(.subheadline))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding-back")
                }
                Spacer()
                Legend("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            }
            HStack(spacing: Space.xs) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Rectangle()
                        .fill(s.rawValue <= step.rawValue ? theme.accentColor : ClusterColor.rule)
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.top, Space.xl)
    }

    // MARK: Step 1

    private var usernameStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            ScreenTitle("Pick your handle", subtitle: "Welcome to Pull Up")
            Text("This is how people find you at meets and on the boards. You can change it later in your profile.")
                .font(ClusterFont.body())
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Legend("Username")
                HStack(spacing: 2) {
                    Text(verbatim: "@").font(ClusterFont.body()).foregroundStyle(ClusterColor.inkTertiary)
                    TextField("", text: $username, prompt: Text(verbatim: "your_handle"))
                        .font(ClusterFont.body())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.continue)
                        .onSubmit { Task { await claim() } }
                        .accessibilityLabel("Username")
                        .accessibilityIdentifier("onboarding-username")
                }
                .padding(.vertical, Space.xs)
                Hairline(color: ClusterColor.ruleStrong)
                statusLine
            }
            .task(id: username) { await check() }

            FieldRow(label: "Name on your profile (optional)", text: $displayName, prompt: "Shown above your garage")
                .textContentType(.name)

            Button {
                Task { await claim() }
            } label: {
                Text(busy ? "Saving" : "Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.cluster)
            .disabled(busy || status != .available)
            .accessibilityIdentifier("onboarding-continue")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: Space.xs) {
            if checking {
                ProgressView().controlSize(.mini)
                Text("Checking").foregroundStyle(ClusterColor.inkSecondary)
            } else if let status {
                Image(systemName: status == .available ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(status == .available ? ClusterColor.verified : ClusterColor.caution)
                Text(status.message).foregroundStyle(ClusterColor.inkSecondary)
            } else {
                Text(UsernameRules.formatHint).foregroundStyle(ClusterColor.inkTertiary)
            }
        }
        .font(ClusterFont.body(.caption))
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 20, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("username-status")
    }

    private func check() async {
        let name = UsernameRules.normalize(username)
        guard !name.isEmpty else {
            status = nil
            return
        }
        if let local = UsernameRules.localProblem(name) {
            status = local
            checking = false
            return
        }
        checking = true
        // Wait for a pause in typing; a newer keystroke cancels this task.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let result = try? await app.backend.usernameStatus(name)
        guard !Task.isCancelled else { return }
        checking = false
        status = result
        if result == nil { error = "Couldn't check that name. You can still try to continue." }
    }

    private func claim() async {
        guard status == .available, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await app.backend.claimUsername(UsernameRules.normalize(username), displayName: displayName)
            error = nil
            step = .photo
        } catch {
            self.error = AuthMessages.server(error)
            status = (try? await app.backend.usernameStatus(username)) ?? status
        }
    }

    // MARK: Step 2

    private var photoStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            ScreenTitle("Add a photo", subtitle: "Optional")
            Text("A face, a helmet, your car's grille. Anything you'd want people at a meet to recognise.")
                .font(ClusterFont.body())
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.l) {
                Avatar(name: displayName.isEmpty ? username : displayName, path: avatarPath, size: 96)
                let isUploading = uploading
                PhotosPicker(selection: $photoItem, matching: .images) {
                    MediaPickerLabel(isLoading: isUploading, symbol: "camera", title: avatarPath == nil ? "Choose photo" : "Change", width: 120, height: 96, cut: 6)
                }
                .buttonStyle(.plain)
                .disabled(uploading)
                .accessibilityIdentifier("onboarding-photo-picker")
            }
            NoticeStrip("Location and camera details are removed from the photo before it's uploaded.", tone: .info)
            VStack(spacing: Space.s) {
                Button {
                    step = .privacy
                } label: {
                    Text(avatarPath == nil ? "Skip for now" : "Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(ClusterButtonStyle(avatarPath == nil ? .secondary : .primary))
                .disabled(uploading)
                .accessibilityIdentifier("onboarding-photo-next")
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        defer {
            uploading = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let jpeg = ImageProcessing.uploadJPEG(from: data, maxDimension: 1024) else {
                error = "That photo couldn't be read."
                return
            }
            try await app.backend.uploadAvatar(jpegData: jpeg)
            avatarPath = (try? await app.backend.account())?.avatarPath
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Step 3

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            ScreenTitle("Who sees what", subtitle: "Privacy")
            Text("Drives start private and leaderboards start off. Change any of this later in Settings.")
                .font(ClusterFont.body())
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.l) {
                AudiencePicker(title: "Profile", selection: $privacy.profileVisibility)
                AudiencePicker(title: "Drive history", selection: $privacy.driveHistoryVisibility)
                PrivacyToggle(title: "Approve new followers", detail: "People must request to follow you.", isOn: $privacy.requireFollowApproval)
                PrivacyToggle(title: "Appear on leaderboards", detail: "Shows your username, vehicle and totals on the boards you qualify for.", isOn: $privacy.leaderboardOptIn)
                MessagesFromPicker(selection: $privacy.messagesFrom)
            }
            Button {
                Task { await finish() }
            } label: {
                Text(busy ? "Saving" : "Start driving").frame(maxWidth: .infinity)
            }
            .buttonStyle(.cluster)
            .disabled(busy)
            .accessibilityIdentifier("onboarding-finish")
        }
        .task {
            if let current = try? await app.backend.privacySettings() { privacy = current }
        }
    }

    private func finish() async {
        busy = true
        defer { busy = false }
        do {
            try await app.backend.updatePrivacySettings(privacy)
            try await app.backend.completeOnboarding()
            error = nil
            await app.finishOnboarding()
        } catch {
            self.error = AuthMessages.server(error)
        }
    }

    // MARK: Prefill

    private func prefill() async {
        if !prefilled, let account = try? await app.backend.account() {
            prefilled = true
            if !account.hasPlaceholderUsername, username.isEmpty { username = account.username }
            if displayName.isEmpty { displayName = account.displayName }
            avatarPath = account.avatarPath
        }
        if displayName.isEmpty, let suggested = app.appleSuggestedName { displayName = suggested }
        if username.isEmpty, !displayName.isEmpty { username = UsernameRules.suggestion(from: displayName) }
    }
}
