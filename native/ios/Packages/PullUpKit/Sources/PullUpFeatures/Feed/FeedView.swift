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

    public init() {}

    public var body: some View {
        NavigationStack {
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
                    ForEach(posts) { post in
                        PostCard(post: post, onLike: { toggleLike(post) }, onComments: { commentsFor = post })
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .canvasBackground()
            .refreshable { await load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ProfileRoute.self) { route in ProfileView(userID: route.id) }
            .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
            .task(id: scope) { await load() }
            .sheet(isPresented: $composing, onDismiss: { Task { await load() } }) { PostComposerView() }
            .sheet(item: $commentsFor) { post in
                CommentsView(post: post).presentationDetents([.medium, .large])
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
            posts = try await app.backend.feed(scope, before: nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
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
    @State private var comments: [Comment] = []
    @State private var draft = ""
    @State private var error: String?

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
                        }
                        .accessibilityElement(children: .combine)
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
