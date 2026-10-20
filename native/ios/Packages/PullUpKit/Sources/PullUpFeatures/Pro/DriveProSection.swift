import Charts
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain
import PullUpTelemetry

/// Pro analytics and export on a drive summary: time in each speed band, and
/// the person's own track as GPX or CSV. Locked cards without Pro.
struct DriveProSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme

    let drive: Drive
    let track: [LocationSample]
    let series: [SpeedPoint]

    @State private var showingPro = false
    @State private var highlight: ProFeature?
    @State private var exports: [TrackExport.Format: URL] = [:]
    @State private var exportError: String?

    private var unit: SpeedUnit { theme.unit }
    private var bandWidth: Int { unit == .mph ? 10 : 20 }
    private var bands: [SpeedBand] {
        SpeedDistribution.bands(offsets: series.map(\.offset), speeds: series.map(\.speed), unit: unit, width: bandWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("Analytics") { if !app.pro.isPro { ProBadge() } }
            if app.pro.isPro {
                speedBands
                exportRow
            } else {
                ProLockedCard(feature: .driveAnalytics) { open(.driveAnalytics) }
                    .accessibilityIdentifier("unlock-analytics")
                if track.count > 1 {
                    ProLockedCard(feature: .trackExport) { open(.trackExport) }
                        .accessibilityIdentifier("unlock-export")
                }
            }
        }
        .proSheet(isPresented: $showingPro, highlight: highlight)
        .task(id: app.pro.isPro) {
            guard app.pro.isPro, track.count > 1 else { return }
            do {
                exports = try Self.write(track, drive: drive)
                exportError = nil
            } catch {
                exportError = "Couldn't prepare the export: \(error.localizedDescription)"
            }
        }
    }

    private func open(_ feature: ProFeature) {
        highlight = feature
        showingPro = true
    }

    @ViewBuilder
    private var speedBands: some View {
        let bands = bands
        let total = bands.reduce(0) { $0 + $1.seconds }
        if total > 0 {
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Time moving in each speed band")
                Chart(bands) { band in
                    BarMark(
                        x: .value("Minutes", band.seconds / 60),
                        y: .value("Speed", "\(band.lower)–\(band.upper)")
                    )
                    .foregroundStyle(theme.accentColor)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(verbatim: "\(Int((band.seconds / total * 100).rounded()))%")
                            .font(ClusterFont.body(.caption2))
                            .foregroundStyle(ClusterColor.inkSecondary)
                    }
                }
                .chartXAxisLabel("min")
                .chartYAxisLabel(unit.label)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(ClusterColor.rule)
                        AxisValueLabel()
                    }
                }
                .frame(height: CGFloat(max(3, bands.count)) * 26 + 30)
                .accessibilityLabel("Time in each speed band")
                .accessibilityValue(bands.filter { $0.seconds > 0 }.map {
                    "\($0.lower) to \($0.upper) \(unit.label): \(Format.duration($0.seconds))"
                }.joined(separator: ", "))
                Text("From phone GPS, counting only time on the move.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
            }
            .accessibilityIdentifier("speed-bands")
        } else {
            NoticeStrip("Not enough moving data for speed bands.")
        }
    }

    @ViewBuilder
    private var exportRow: some View {
        if track.count > 1 {
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Export your track")
                HStack(spacing: Space.m) {
                    ForEach(TrackExport.Format.allCases, id: \.self) { format in
                        if let url = exports[format] {
                            ShareLink(item: url) {
                                Label(format.label, systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.clusterSecondary)
                            .accessibilityIdentifier("export-\(format.rawValue)")
                        }
                    }
                }
                if let exportError { ErrorLine(message: exportError) }
                Text("Exports include your full route, protected places too. Only share them with people you trust.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static var exportsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Removes every export file left on this phone (full routes), on
    /// sign-out and account deletion.
    static func removeExports() {
        try? FileManager.default.removeItem(at: exportsFolder)
    }

    /// Writes both formats to a per-drive temporary folder, replacing any
    /// earlier export of the drive so old copies don't pile up.
    static func write(_ track: [LocationSample], drive: Drive) throws -> [TrackExport.Format: URL] {
        let folder = exportsFolder.appendingPathComponent(drive.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = drive.startedAt.formatted(.iso8601.year().month().day())
        let base = "Pull Up \(day) \(drive.title)"
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .prefix(80)
        var urls: [TrackExport.Format: URL] = [:]
        for format in TrackExport.Format.allCases {
            let url = folder.appendingPathComponent("\(base).\(format.fileExtension)")
            // Same protection as saved drives: the file holds the full route.
            let data = Data(TrackExport.render(track, name: drive.title, format: format).utf8)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: [.atomic])
            #endif
            urls[format] = url
        }
        return urls
    }
}
