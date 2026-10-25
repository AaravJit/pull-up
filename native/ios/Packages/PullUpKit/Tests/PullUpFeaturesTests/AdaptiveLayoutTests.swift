import CoreGraphics
import Testing
@testable import PullUpFeatures

/// Layout decisions come from the measured space, so any window shape gets
/// a sensible answer, not only the phone sizes tested here.
struct DashboardLayoutTests {
    @Test func portraitPhoneStacks() {
        let layout = DashboardLayout(size: CGSize(width: 393, height: 759), isAccessibilitySize: false, analogGauge: true)
        #expect(layout.arrangement == .stacked)
        #expect(layout.metricColumns == 3)
        #expect(layout.gaugeHeight == 300)
    }

    @Test func landscapePhoneGoesSideBySide() {
        // A small phone on its side: wide and short.
        let layout = DashboardLayout(size: CGSize(width: 667, height: 375), isAccessibilitySize: false, analogGauge: true)
        #expect(layout.arrangement == .sideBySide)
        #expect(layout.metricColumns == 2)
        // The gauge fits beside the status row and above the controls.
        #expect(layout.gaugeHeight <= 375 - 150)
    }

    @Test func largeSquareishWindowStacksWithinAReadableWidth() {
        // Regular width and regular height, taller than wide.
        let layout = DashboardLayout(size: CGSize(width: 820, height: 1000), isAccessibilitySize: false, analogGauge: true)
        #expect(layout.arrangement == .stacked)
        #expect(layout.maxContentWidth < 820)
    }

    @Test func largeWideWindowUsesTheWidth() {
        // Regular width and regular height, wider than tall.
        let layout = DashboardLayout(size: CGSize(width: 1000, height: 700), isAccessibilitySize: false, analogGauge: false)
        #expect(layout.arrangement == .sideBySide)
        #expect(layout.maxContentWidth >= 1000)
        #expect(layout.gaugeHeight == 210)
    }

    @Test func nearlySquareWindowStacks() {
        let layout = DashboardLayout(size: CGSize(width: 700, height: 680), isAccessibilitySize: false, analogGauge: true)
        #expect(layout.arrangement == .stacked)
    }

    @Test func narrowShortWindowStaysOneColumn() {
        // Wider than tall but too narrow for two readable columns.
        let layout = DashboardLayout(size: CGSize(width: 480, height: 300), isAccessibilitySize: false, analogGauge: true)
        #expect(layout.arrangement == .stacked)
    }

    @Test func accessibilitySizesShrinkTheGaugeAndColumns() {
        let portrait = DashboardLayout(size: CGSize(width: 393, height: 759), isAccessibilitySize: true, analogGauge: true)
        #expect(portrait.gaugeHeight < 300)
        #expect(portrait.metricColumns == 2)
        let landscape = DashboardLayout(size: CGSize(width: 667, height: 375), isAccessibilitySize: true, analogGauge: true)
        #expect(landscape.metricColumns == 1)
        #expect(landscape.gaugeHeight <= 220)
    }

    @Test func unmeasuredSizeStacks() {
        let layout = DashboardLayout(size: .zero, isAccessibilitySize: false, analogGauge: true)
        #expect(layout.arrangement == .stacked)
    }
}

struct PickerLayoutTests {
    @Test func cardsFollowThePanelWidthWithinLimits() {
        #expect(PickerLayout.cardWidth(panelWidth: 0, compact: false) == 212)
        let phone = PickerLayout.cardWidth(panelWidth: 393, compact: false)
        #expect(phone > 200 && phone < 220)
        #expect(PickerLayout.cardWidth(panelWidth: 640, compact: false) == 240)
        #expect(PickerLayout.cardWidth(panelWidth: 280, compact: false) == 180)
    }

    @Test func compactCardsAreNeverLarger() {
        for width in stride(from: CGFloat(0), through: 800, by: 40) {
            #expect(PickerLayout.cardWidth(panelWidth: width, compact: true) <= PickerLayout.cardWidth(panelWidth: width, compact: false))
        }
    }
}

struct MapLayoutTests {
    @Test func meetCardIsCappedOnWideWindows() {
        #expect(MapLayout.meetCardWidth(availableWidth: 0) == 270)
        #expect(MapLayout.meetCardWidth(availableWidth: 1200) == 320)
        #expect(MapLayout.meetCardWidth(availableWidth: 300) == 240)
    }

    @Test func unknownSizesUseThePhoneEstimate() {
        let camera = MapLayout.camera(contentWidth: 10_000, contentHeight: 4_000, map: .zero, clear: .zero)
        #expect(camera.distance == 32_000)
        #expect(camera.northOffset == 1_000)
    }

    @Test func wideContentNeedsLessDistanceOnAWideMap() {
        let phone = CGSize(width: 393, height: 852)
        let wide = CGSize(width: 1100, height: 700)
        let onPhone = MapLayout.camera(contentWidth: 30_000, contentHeight: 5_000, map: phone, clear: CGRect(x: 0, y: 200, width: 393, height: 450))
        let onWide = MapLayout.camera(contentWidth: 30_000, contentHeight: 5_000, map: wide, clear: CGRect(x: 0, y: 200, width: 1100, height: 400))
        #expect(onWide.distance < onPhone.distance)
    }

    @Test func aShortMapZoomsOutForTallContent() {
        let tall = CGSize(width: 393, height: 852)
        let short = CGSize(width: 852, height: 393)
        let onTall = MapLayout.camera(contentWidth: 5_000, contentHeight: 20_000, map: tall, clear: CGRect(x: 0, y: 150, width: 393, height: 550))
        let onShort = MapLayout.camera(contentWidth: 5_000, contentHeight: 20_000, map: short, clear: CGRect(x: 0, y: 150, width: 852, height: 200))
        // Ground shown per point of clear height must still cover the content.
        let shownOnShort = onShort.distance / 393 * 200
        #expect(shownOnShort >= 20_000)
        #expect(onShort.distance > 0 && onTall.distance > 0)
    }

    @Test func contentIsCentredInTheClearArea() {
        let map = CGSize(width: 393, height: 852)
        // Header covers more than the strip: look north so content sits lower.
        let camera = MapLayout.camera(contentWidth: 10_000, contentHeight: 10_000, map: map, clear: CGRect(x: 0, y: 250, width: 393, height: 450))
        #expect(camera.northOffset > 0)
        let centred = MapLayout.camera(contentWidth: 10_000, contentHeight: 10_000, map: map, clear: CGRect(x: 0, y: 200, width: 393, height: 452))
        #expect(abs(centred.northOffset) < 1)
    }

    @Test func neverCloserThanTheMinimum() {
        let camera = MapLayout.camera(contentWidth: 10, contentHeight: 10, map: CGSize(width: 393, height: 852), clear: CGRect(x: 0, y: 200, width: 393, height: 450))
        #expect(camera.distance == 6_000)
    }
}
