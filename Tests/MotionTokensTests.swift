import XCTest
#if canImport(SwiftUI)
import SwiftUI
@testable import IysCodeMovilCore
#endif

final class MotionTokensTests: XCTestCase {
    #if canImport(SwiftUI)
    func testThemeAccentGradientStopsAreProgressiveAndBounded() {
        for theme in IysTheme.allCases {
            let stops = theme.accentGradientStops
            XCTAssertTrue((4...5).contains(stops.count), "Expected 4-5 stops for \(theme.rawValue)")
            XCTAssertEqual(stops.first?.location ?? -1, 0.0, accuracy: 0.0001)
            XCTAssertEqual(stops.last?.location ?? -1, 1.0, accuracy: 0.0001)

            var previousLocation: CGFloat = -0.001
            for stop in stops {
                XCTAssertGreaterThan(stop.location, previousLocation)
                XCTAssertGreaterThanOrEqual(stop.location, 0.0)
                XCTAssertLessThanOrEqual(stop.location, 1.0)
                previousLocation = stop.location
            }

            _ = theme.accentGradient
        }
    }

    func testOCMotionCurvesAndSpringsInvariants() {
        XCTAssertEqual(OCMotion.curve.x1, 0.17, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.curve.y1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.curve.x2, 0.83, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.curve.y2, 1.0, accuracy: 0.0001)

        XCTAssertEqual(OCMotion.materialStandard.x1, 0.40, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.materialStandard.y1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.materialStandard.x2, 0.20, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.materialStandard.y2, 1.0, accuracy: 0.0001)

        XCTAssertEqual(OCMotion.expoOutCurve.x1, 0.19, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.expoOutCurve.y1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.expoOutCurve.x2, 0.22, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.expoOutCurve.y2, 1.0, accuracy: 0.0001)

        XCTAssertEqual(OCMotion.softOutCurve.x1, 0.22, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.softOutCurve.y1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.softOutCurve.x2, 0.36, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.softOutCurve.y2, 1.0, accuracy: 0.0001)

        XCTAssertEqual(OCMotion.overshootCurve.x1, 0.19, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.overshootCurve.y1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.overshootCurve.x2, 0.15, accuracy: 0.0001)
        XCTAssertEqual(OCMotion.overshootCurve.y2, 1.11, accuracy: 0.0001)

        let curves = [
            OCMotion.curve,
            OCMotion.materialStandard,
            OCMotion.expoOutCurve,
            OCMotion.softOutCurve,
            OCMotion.overshootCurve
        ]
        for c in curves {
            XCTAssertGreaterThanOrEqual(c.x1, 0.0)
            XCTAssertLessThanOrEqual(c.x1, 1.0)
            XCTAssertGreaterThanOrEqual(c.x2, 0.0)
            XCTAssertLessThanOrEqual(c.x2, 1.0)
        }

        _ = OCMotion.shimmerSweep()
        _ = OCMotion.expoOut()
        _ = OCMotion.softOut()
        _ = OCMotion.overshoot()
        _ = OCMotion.springSelection
        _ = OCMotion.springSnappy
        _ = OCMotion.springOverscroll
        _ = OCMotion.springSoft
    }

    func testViewHelpersAndSkeletonModifierCompile() {
        _ = OCSkeletonModifier(isLoading: true)
        _ = Text("Test").ocBlurReplaceTransition()
        _ = Image(systemName: "sparkles").ocSymbolReplace()
    }
    #endif
}
