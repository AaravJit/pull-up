import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// Rankings. Cars and motorcycles are always ranked separately. Everything
/// is computed and validated by the server (`public.leaderboard`); the
/// client only chooses the board.
struct LeaderboardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme

    enum Board: String, CaseIterable, Identifiable {
        case driving, performance
        var id: String { rawValue }
        var label: String { self == .driving ? "Driving" : "Closed course" }
    }

    @State private var board: Board = .driving
    @State private var metric: LeaderboardMetric = .distance
    @State private var scope: LeaderboardScope = .global
    @State private var period: LeaderboardPeriod = .month
    @State private var kind: VehicleKind = .car
    @State private var entries: [LeaderboardEntry] = []
    @State private var privacy: PrivacySettings?
    @State private var isLoading = false
    @State private var error: String?

    private var metrics: [LeaderboardMetric] {
        LeaderboardMetric.allCases.filter { $0.isPerformance == (board == .performance) }
    }

    private var query: LeaderboardQuery {
        LeaderboardQuery(metric: metric, scope: scope, period: period, vehicleKind: kind)
    }

    private var optedIn: Bool {
        guard let privacy else { return false }
        return board == .performance ? privacy.performanceLeaderboardOptIn : privacy.leaderboardOptIn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                SwitchBank(Board.allCases, selection: $board) { $0.label }
                if board == .performance { performanceNotice }
                filters
                optInStrip
                rankings
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
        }
        .canvasBackground()
        .clusterNavigation("Leaderboards")
        .onChange(of: board) { _, _ in metric = metrics.first ?? .distance }
        .task(id: query) { await load() }
        .task { privacy = try? await app.backend.privacySettings() }
        .accessibilityIdentifier("leaderboards")
    }

    private var performanceNotice: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label("No street racing", systemImage: "exclamationmark.octagon")
                .font(ClusterFont.headline())
                .foregroundStyle(ClusterColor.caution)
            Text("These boards only accept runs recorded at verified closed-course events (track days, autocross) by attendees who RSVP'd. Speeds from public roads are never ranked, whatever the app measured.")
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .plate(stroke: ClusterColor.caution.opacity(0.6))
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SwitchBank(metrics, selection: $metric) { $0.label }
            SwitchBank(VehicleKind.allCases, selection: $kind) { $0.pluralLabel }
            HStack(spacing: Space.m) {
                Menu {
                    Picker("Scope", selection: $scope) {
                        ForEach(LeaderboardScope.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    filterChip("Where", scope.label)
                }
                Menu {
                    Picker("Period", selection: $period) {
                        ForEach(LeaderboardPeriod.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    filterChip("When", period.label)
                }
                Spacer()
            }
        }
    }

    private func filterChip(_ legend: String, _ value: String) -> some View {
        HStack(spacing: Space.xs) {
            Legend(legend)
            Text(value).font(ClusterFont.headline(.footnote)).foregroundStyle(ClusterColor.ink)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(ClusterColor.inkTertiary)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .plate(cut: 5)
    }

    @ViewBuilder
    private var optInStrip: some View {
        if privacy != nil, !optedIn {
            HStack(alignment: .top, spacing: Space.m) {
                Text(board == .performance
                     ? "You're not on performance boards. Joining lists your verified closed-course runs with your username and vehicle."
                     : "You're not on leaderboards. Joining shows your username, vehicle and totals to everyone who can see the board.")
                    .font(ClusterFont.body(.footnote))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Join") { Task { await optIn() } }
                    .buttonStyle(.clusterSecondary)
                    .accessibilityIdentifier("leaderboard-join")
            }
        }
    }

    @ViewBuilder
    private var rankings: some View {
        if let error {
            ErrorLine(message: error) { Task { await load() } }
        } else if isLoading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if entries.isEmpty {
            EmptyState(
                title: board == .performance ? "No verified runs yet" : "No rankings yet",
                message: board == .performance
                    ? "When a verified organiser runs a closed-course event, attendees' validated runs appear here."
                    : "Nobody in this scope has opted in for this period.",
                style: kind == .car ? .coupe : .sport
            )
        } else {
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    LeaderboardRow(entry: entry, value: formatted(entry.value), unit: unitLabel)
                }
            }
        }
    }

    private var unitLabel: String {
        switch metric {
        case .distance: theme.unit.distanceLabel
        case .drives: "drives"
        case .exploration: "areas"
        case .community: "meets"
        case .zeroToSixty: "s"
        case .topSpeed: theme.unit.label
        }
    }

    private func formatted(_ value: Double) -> String {
        switch metric {
        case .distance: Format.distance(value, theme.unit)
        case .zeroToSixty: Format.zeroToSixty(value)
        case .topSpeed: Format.speed(value, theme.unit)
        default: Int(value).formatted()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await app.backend.leaderboard(query)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func optIn() async {
        guard var settings = privacy else { return }
        if board == .performance { settings.performanceLeaderboardOptIn = true } else { settings.leaderboardOptIn = true }
        do {
            try await app.backend.updatePrivacySettings(settings)
            privacy = settings
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LeaderboardRow: View {
    @Environment(\.clusterTheme) private var theme
    let entry: LeaderboardEntry
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Text("\(entry.rank)")
                .font(ClusterFont.numeral(entry.rank <= 3 ? 30 : 22))
                .foregroundStyle(entry.rank <= 3 ? theme.accentColor : ClusterColor.inkTertiary)
                .frame(width: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(entry.user.displayName)
                        .font(ClusterFont.headline(.subheadline))
                        .foregroundStyle(ClusterColor.ink)
                    if entry.isMe { Legend("You", color: theme.accentColor) }
                }
                Text(entry.vehicleTitle ?? "@\(entry.user.username)")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(ClusterFont.readout(.title3)).foregroundStyle(ClusterColor.ink)
                Text(unit).font(ClusterFont.legend(.caption2)).foregroundStyle(ClusterColor.inkSecondary)
            }
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, entry.isMe ? Space.s : 0)
        .background(entry.isMe ? ClusterColor.plateRaised : .clear)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(entry.rank), \(entry.user.displayName), \(value) \(unit)")
    }
}
