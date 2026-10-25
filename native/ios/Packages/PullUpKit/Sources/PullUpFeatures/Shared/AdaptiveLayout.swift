import CoreGraphics
import PullUpDesign

// Layout decisions taken from the space a screen actually has. A window can
// be any shape and any combination of size classes: a phone in either
// orientation, or whatever size the system gives the window. So nothing
// here looks at the device, its
// orientation or its size classes. These are plain functions of a measured
// size, so tests can check them without a screen.

/// How the live dashboard arranges itself in `size`, the space inside the
/// safe area.
struct DashboardLayout: Equatable {
    enum Arrangement: Equatable {
        /// One column: status, gauge, metrics, route.
        case stacked
        /// Gauge on the left, notices and metrics on the right.
        case sideBySide
    }

    var arrangement: Arrangement
    var metricColumns: Int
    /// Content is centred and stops growing here, so a wide window stays
    /// readable instead of stretching tiles across it.
    var maxContentWidth: CGFloat
    var gaugeHeight: CGFloat

    init(size: CGSize, isAccessibilitySize: Bool, analogGauge: Bool) {
        // Wide and short: two columns, so the gauge isn't squeezed by the
        // metrics below it. Too narrow for two readable columns: one.
        let sideBySide = size.width >= 520 && size.width > size.height * 1.15
        arrangement = sideBySide ? .sideBySide : .stacked
        maxContentWidth = sideBySide ? 1080 : 640
        switch (sideBySide, isAccessibilitySize) {
        case (false, false): metricColumns = 3
        case (false, true), (true, false): metricColumns = 2
        case (true, true): metricColumns = 1
        }
        var gauge: CGFloat = analogGauge ? 300 : 210
        // Large text grows everything around the gauge, so the gauge gives
        // way rather than pushing the metrics out of sight.
        if isAccessibilitySize { gauge = analogGauge ? 220 : 160 }
        if sideBySide {
            // The gauge shares the column with the status row and sits above
            // the controls, so it is held to what's left of the height.
            gauge = min(gauge, max(140, size.height - 150))
        }
        gaugeHeight = gauge
    }
}

enum PickerLayout {
    /// Width of a vehicle card in the Start Drive carousel. Roughly
    /// three-fifths of the panel, so the next card peeks in, within limits
    /// that keep the photo and two lines of text legible. `compact` is the
    /// smaller card tried when the regular one leaves no room for the Start
    /// button.
    static func cardWidth(panelWidth: CGFloat, compact: Bool) -> CGFloat {
        let lower: CGFloat = compact ? 150 : 180
        let upper: CGFloat = compact ? 180 : 240
        // Not measured yet: the card a phone in portrait gets.
        guard panelWidth > 0 else { return compact ? 180 : 212 }
        return min(upper, max(lower, (panelWidth - 2 * Space.gutter) * 0.6))
    }
}

enum MapLayout {
    /// Width of a meet card in the strip under the map: most of a phone's
    /// width so the next card peeks in, capped on wide windows.
    static func meetCardWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 270 }
        return min(320, max(240, availableWidth * 0.7))
    }

    /// A camera that fits content spanning `contentWidth` × `contentHeight`
    /// metres into `clear`, the part of a `map`-sized map that the header and
    /// meet strip leave uncovered (in the map's own coordinates).
    ///
    /// Treats the camera distance as the ground the map's height shows, so
    /// the map's shape decides how much width that gives. With 1.5 for room
    /// around the content this frames a portrait phone as before, and a wide
    /// or short window gets a distance that fits its own shape.
    ///
    /// Returns the distance and how far north of the content's centre the
    /// camera should look, both in metres, so the content sits in the middle
    /// of the clear area rather than under the header.
    static func camera(contentWidth: Double, contentHeight: Double, map: CGSize, clear: CGRect) -> (distance: Double, northOffset: Double) {
        let minimum = 6_000.0
        let room = 1.5
        guard map.width > 0, map.height > 0, clear.width > 0, clear.height > 0 else {
            // Sizes not known yet: the phone-shaped estimate.
            return (max(minimum, max(contentHeight, contentWidth) * 3.2), contentHeight * 0.25)
        }
        // Never count on less than a third of the height being clear.
        let clearHeight = max(Double(clear.height), Double(map.height) / 3)
        let metresPerPoint = max(contentWidth * room / Double(clear.width), contentHeight * room / clearHeight)
        let distance = max(minimum, metresPerPoint * Double(map.height))
        let shown = distance / Double(map.height)
        let pointsBelowCentre = Double(clear.midY) - Double(map.height) / 2
        return (distance, pointsBelowCentre * shown)
    }
}
