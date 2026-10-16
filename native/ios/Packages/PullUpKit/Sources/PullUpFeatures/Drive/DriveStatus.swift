import Foundation
import PullUpDomain

/// Glanceable text for surfaces outside the main UI (CarPlay, widgets).
///
/// Deliberately leaves out current speed: the car's own speedometer is the
/// authority, and a second, laggier number on the head unit only distracts.
public struct DriveStatus: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let title: String
        public let detail: String
    }

    public let isRecording: Bool
    public let lines: [Line]

    @MainActor
    public init(recorder: DriveRecorder, unit: SpeedUnit) {
        isRecording = recorder.isRecording
        guard recorder.isRecording else {
            var lines = [Line(title: "Status", detail: "Not recording")]
            if let last = recorder.lastResult {
                lines.append(Line(title: "Last drive", detail: "\(Format.distance(last.drive.distanceMeters, unit)) \(unit.distanceLabel)"))
            }
            self.lines = lines
            return
        }
        let live = recorder.live
        var lines = [
            Line(title: "Vehicle", detail: recorder.vehicle?.displayName ?? "Guest vehicle"),
            Line(title: "Distance", detail: "\(Format.distance(live.distanceMeters, unit)) \(unit.distanceLabel)"),
            Line(title: "Elapsed", detail: Format.duration(live.elapsedSeconds)),
            Line(title: "GPS", detail: live.signal.label),
        ]
        if case .lost = live.signalState { lines[3] = Line(title: "GPS", detail: "Signal lost") }
        self.lines = lines
    }
}
