import AVKit
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// Photo-first feed. Media runs edge to edge; text-only posts are set large
/// so they don't masquerade as image placeholders.
public struct FeedView: View {
    @Environment(AppModel.self) private var app
    @State private var scope: FeedScope = .following
    @State private var posts: [Post] = []
    @State private var isLoaded = false
    @State private var error: String?
    @State private var composing = false
    @State private var commentsFor: Post?
    @State private var sharing: Post?
    @State private var reporting: Post?
    @State private var blockTarget: Post?
    @State private var confirmingBlock = false
    @State private var deleteTarget: Post?
    @State private var confirmingDelete = false
    /// Hidden at once after a block, before the server's next page agrees.
    @State private var blockedAuthors: Set<UserID> = []
    @State private var actionError: String?
    @State private var path = NavigationPath()

    public init() {}

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    header
                        .padding(.horizontal, Space.gutter)
                    if let error {
                        ErrorLine(message: error) { Task { await load() } }.padding(.horizontal, Space.gutter)
                    } else if !isLoaded {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                    } else if posts.isEmpty {
                        EmptyState(
                            title: scope == .following ? "Quiet in here" : "Nothing yet",
                            message: scope == .following ? "Follow people from Discover or a meet and their posts show up here." : "Public posts appear here."
                        )
                    }
                    if let actionError {
                        ErrorLine(message: actionError).padding(.horizontal, Space.gutter)
                    }
                    ForEach(posts) { post in
                        PostCard(
                            post: post, onLike: { toggleLike(post) }, onComments: { commentsFor = post }, onShare: { sharing = post },
                            isMine: post.authorID == app.userID,
                            onReport: { reporting = post },
                            onBlock: {
                                blockTarget = post
                                confirmingBlock = true
                            },
                            onDelete: {
                                deleteTarget = post
                                confirmingDelete = true
                            }
                        )
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .canvasBackground()
            .refreshable { await load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ProfileRoute.self) { route in ProfileView(userID: route.id) }
            .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
            .navigationDestination(for: MessagesRoute.self) { _ in InboxView() }
            .task(id: scope) { await load() }
            .onChange(of: app.pendingPush, initial: true) { _, route in
                // A tapped message push: open Messages, which then opens the conversation.
                guard case .conversation = route else { return }
                path = NavigationPath()
                path.append(MessagesRoute())
            }
            .sheet(isPresented: $composing, onDismiss: { Task { await load() } }) { PostComposerView() }
            .sheet(item: $commentsFor) { post in
                CommentsView(post: post, onBlocked: { hideAuthor($0) }).presentationDetents([.medium, .large])
            }
            .sheet(item: $sharing) { post in
                ShareToMessageView(shared: SharedRef(kind: .post, id: post.id))
            }
            .sheet(item: $reporting) { post in
                ReportPersonView(
                    person: author(of: post),
                    question: "What's wrong with this post?",
                    subject: ReportDetails.subject("post", id: post.id, excerpt: post.caption),
                    onBlocked: { hideAuthor(post.authorID) }
                )
            }
            .confirmationDialog("Block \(handle(blockTarget?.author))?", isPresented: $confirmingBlock, titleVisibility: .visible, presenting: blockTarget) { post in
                Button("Block", role: .destructive) { Task { await block(post.authorID) } }
            } message: { _ in
                Text("Their posts leave your feed, you won't see each other's profiles, and they can't message you. Pull Up doesn't tell them.")
            }
            .confirmationDialog("Delete this post?", isPresented: $confirmingDelete, titleVisibility: .visible, presenting: deleteTarget) { post in
                Button("Delete", role: .destructive) { Task { await delete(post) } }
            } message: { _ in
                Text("It's removed for everyone, with its likes and comments.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .bottom, spacing: Space.s) {
                ScreenTitle("Feed")
                Button {
                    composing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ClusterColor.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("New post")
                MessagesButton()
                if let me = app.userID {
                    NavigationLink(value: ProfileRoute(id: me)) {
                        Image(systemName: "person.crop.square")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(ClusterColor.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Your profile")
                    .accessibilityIdentifier("open-profile")
                }
            }
            SwitchBank(FeedScope.allCases, selection: $scope) { $0.label }
        }
    }

    private func load() async {
        do {
            posts = try await app.backend.feed(scope, before: nil).filter { !blockedAuthors.contains($0.authorID) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
    }

    private func author(of post: Post) -> ProfileStub {
        post.author ?? ProfileStub(id: post.authorID, username: "", displayName: "")
    }

    private func handle(_ author: ProfileStub?) -> String {
        guard let username = author?.username, !username.isEmpty else { return "this person" }
        return "@\(username)"
    }

    private func hideAuthor(_ id: UserID) {
        blockedAuthors.insert(id)
        posts.removeAll { $0.authorID == id }
    }

    private func block(_ id: UserID) async {
        do {
            try await app.backend.block(id)
            hideAuthor(id)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete(_ post: Post) async {
        do {
            try await app.backend.deletePost(post.id)
            posts.removeAll { $0.id == post.id }
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func toggleLike(_ post: Post) {
        guard let i = posts.firstIndex(where: { $0.id == post.id }) else { return }
        let liked = !posts[i].likedByMe
        posts[i].likedByMe = liked
        posts[i].likeCount += liked ? 1 : -1
        Task {
            do {
                try await app.backend.setLiked(liked, post: post.id)
            } catch {
                if let j = posts.firstIndex(where: { $0.id == post.id }) {
                    posts[j].likedByMe = !liked
                    posts[j].likeCount += liked ? -1 : 1
                }
            }
        }
    }
}

struct ProfileRoute: Hashable { let id: UserID }
struct SettingsRoute: Hashable {}

struct PostCard: View {
    @Environment(\.clusterTheme) private var theme
    let post: Post
    let onLike: () -> Void
    let onComments: () -> Void
    var onShare: (() -> Void)?
    var isMine = false
    var onReport: (() -> Void)?
    var onBlock: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            authorRow.padding(.horizontal, Space.gutter)
            if post.media.isEmpty {
                Text(post.caption)
                    .font(ClusterFont.title(.title3))
                    .foregroundStyle(ClusterColor.ink)
                    .padding(.horizontal, Space.gutter)
                    .padding(.vertical, Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.accentColor).frame(width: 3).padding(.vertical, Space.s)
                    }
            } else {
                MediaCarousel(media: post.media)
                Text(post.caption)
                    .font(ClusterFont.body())
                    .foregroundStyle(ClusterColor.ink)
                    .padding(.horizontal, Space.gutter)
            }
            actions.padding(.horizontal, Space.gutter)
            Hairline().padding(.horizontal, Space.gutter)
        }
        .accessibilityElement(children: .contain)
    }

    private var authorRow: some View {
        HStack(spacing: Space.xs) {
            NavigationLink(value: ProfileRoute(id: post.authorID)) {
                HStack(spacing: Space.m) {
                    Avatar(name: post.author?.displayName ?? "?", path: post.author?.avatarPath, size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(post.author?.displayName ?? "Unknown")
                            .font(ClusterFont.headline(.subheadline))
                            .foregroundStyle(ClusterColor.ink)
                        Text("@\(post.author?.username ?? "") · \(Format.relative(post.createdAt))")
                            .font(ClusterFont.body(.caption))
                            .foregroundStyle(ClusterColor.inkSecondary)
                    }
                    Spacer()
                    Legend(kindLabel)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("post-author-\(post.author?.username ?? "")")
            optionsMenu
        }
    }

    /// Delete for your own posts; Report and Block for everyone else's.
    @ViewBuilder
    private var optionsMenu: some View {
        if isMine ? onDelete != nil : (onReport != nil || onBlock != nil) {
            Menu {
                if isMine {
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) { Label("Delete post", systemImage: "trash") }
                    }
                } else {
                    if let onReport {
                        Button(action: onReport) { Label("Report post", systemImage: "flag") }
                    }
                    if let onBlock {
                        Button(role: .destructive, action: onBlock) { Label("Block @\(post.author?.username ?? "")", systemImage: "hand.raised") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClusterColor.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Post options")
            .accessibilityIdentifier("post-options-\(post.author?.username ?? "")")
        }
    }

    private var kindLabel: String {
        switch post.kind {
        case .moment: "Moment"
        case .build: "Build"
        case .meet: "Meet"
        case .drive: "Drive"
        }
    }

    private var actions: some View {
        HStack(spacing: Space.xl) {
            Button(action: onLike) {
                HStack(spacing: Space.xs) {
                    Image(systemName: post.likedByMe ? "heart.fill" : "heart")
                        .foregroundStyle(post.likedByMe ? ClusterColor.live : ClusterColor.ink)
                        .symbolEffect(.bounce, value: post.likedByMe)
                    Text(Format.compactCount(post.likeCount)).font(ClusterFont.readout(.subheadline))
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: post.likedByMe)
            .accessibilityLabel(post.likedByMe ? "Unlike" : "Like")
            .accessibilityValue("\(post.likeCount) likes")
            Button(action: onComments) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "bubble.left")
                    Text(Format.compactCount(post.commentCount)).font(ClusterFont.readout(.subheadline))
                }
            }
            .accessibilityLabel("Comments")
            .accessibilityValue("\(post.commentCount)")
            if let onShare {
                Button(action: onShare) { Image(systemName: "paperplane") }
                    .accessibilityLabel("Send in a message")
            }
            Spacer()
            VisibilityTag(post.visibility)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ClusterColor.ink)
    }
}

/// Swipeable media, sized to the first item's aspect ratio (clamped to the
/// 4:5 to 1.91:1 range so a panorama can't flatten the feed).
struct MediaCarousel: View {
    let media: [PostMedia]

    private var ratio: Double { min(1.91, max(0.8, media.first?.aspectRatio ?? 0.8)) }

    var body: some View {
        TabView {
            ForEach(media) { item in
                Group {
                    if item.mediaType == .video {
                        StorageVideo(path: item.storagePath)
                    } else {
                        StorageImage(bucket: .postMedia, path: item.storagePath) { ClusterColor.plateRaised }
                    }
                }
                .clipped()
            }
        }
        .tabViewStyle(.page(indexDisplayMode: media.count > 1 ? .automatic : .never))
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(media.count == 1 ? (media[0].mediaType == .video ? "Video" : "Photo") : "\(media.count) photos and videos")
    }
}

struct StorageVideo: View {
    @Environment(AppModel.self) private var app
    let path: String
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            ClusterColor.plateRaised
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            guard let url = await app.backend.mediaURL(.postMedia, path: path) else { return }
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }
}

struct CommentsView: View {
    @Environment(AppModel.self) private var app
    let post: Post
    /// Called with the author's ID after you block them from a comment.
    var onBlocked: ((UserID) -> Void)?
    @State private var comments: [Comment] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var reporting: Comment?
    @State private var blockTarget: Comment?
    @State private var confirmingBlock = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if comments.isEmpty {
                        Text("No comments yet.").font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
                    }
                    ForEach(comments) { comment in
                        HStack(alignment: .top, spacing: Space.m) {
                            Avatar(name: comment.author?.displayName ?? "?", path: comment.author?.avatarPath, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(comment.author?.displayName ?? "Unknown").font(ClusterFont.headline(.footnote))
                                    Text(Format.relative(comment.createdAt)).font(ClusterFont.body(.caption2)).foregroundStyle(ClusterColor.inkTertiary)
                                }
                                Text(comment.body).font(ClusterFont.body(.subheadline))
                            }
                            .foregroundStyle(ClusterColor.ink)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            if comment.authorID != app.userID {
                                Button { reporting = comment } label: { Label("Report comment", systemImage: "flag") }
                                Button(role: .destructive) {
                                    blockTarget = comment
                                    confirmingBlock = true
                                } label: {
                                    Label("Block @\(comment.author?.username ?? "")", systemImage: "hand.raised")
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("comment-\(comment.author?.username ?? "")")
                    }
                    if let error { ErrorLine(message: error) }
                }
                .padding(Space.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .canvasBackground()
            .clusterNavigation("Comments")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Space.s) {
                    TextField("Add a comment", text: $draft, axis: .vertical)
                        .font(ClusterFont.body())
                        .lineLimit(1...4)
                    Button("Post") { Task { await send() } }
                        .font(ClusterFont.headline(.subheadline))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(Space.m)
                .background(ClusterColor.plate)
                .overlay(alignment: .top) { Hairline() }
            }
            .task { comments = (try? await app.backend.comments(post: post.id)) ?? [] }
            .sheet(item: $reporting) { comment in
                ReportPersonView(
                    person: comment.author ?? ProfileStub(id: comment.authorID, username: "", displayName: ""),
                    question: "What's wrong with this comment?",
                    subject: ReportDetails.subject("comment", id: comment.id, excerpt: comment.body),
                    onBlocked: { hideAuthor(comment.authorID) }
                )
            }
            .confirmationDialog("Block @\(blockTarget?.author?.username ?? "")?", isPresented: $confirmingBlock, titleVisibility: .visible, presenting: blockTarget) { comment in
                Button("Block", role: .destructive) { Task { await block(comment.authorID) } }
            } message: { _ in
                Text("Their posts and comments leave your feed, you won't see each other's profiles, and they can't message you. Pull Up doesn't tell them.")
            }
        }
    }

    private func hideAuthor(_ id: UserID) {
        comments.removeAll { $0.authorID == id }
        onBlocked?(id)
    }

    private func block(_ id: UserID) async {
        do {
            try await app.backend.block(id)
            hideAuthor(id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            comments.append(try await app.backend.addComment(body, post: post.id))
            draft = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
