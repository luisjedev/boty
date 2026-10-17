import XCTest

@testable import Boty

/// Regresión: un parcial de streaming diminuto (p. ej. "1" al inicio de una
/// lista "1. …") no debe sustituir al spinner: se queda fijo en la burbuja
/// si hay una pausa larga hasta el siguiente trozo.
final class StreamingPartialTests: XCTestCase {
    func testTinyFragmentsKeepTypingPlaceholder() {
        for fragment in [
            "", "   ", "1", "12", "1.", "2)", "H", "¡Ho",
            "-", "*", "#", "##", "```", "```swift", ">", "~~~",
        ] {
            XCTAssertEqual(streamingDisplayText(for: fragment), "…", "fragmento: \(fragment)")
        }
    }

    func testLegiblePartialsAreShown() {
        XCTAssertEqual(streamingDisplayText(for: "Hola,"), "Hola,")
        XCTAssertEqual(streamingDisplayText(for: "1. Hola"), "1. Hola")
        XCTAssertEqual(streamingDisplayText(for: "Hola, ¿qué tal?"), "Hola, ¿qué tal?")
        XCTAssertEqual(streamingDisplayText(for: "```swift\nlet x = 1"), "```swift\nlet x = 1")
    }

    func testWhitespacePaddingIsPreservedWhenShown() {
        XCTAssertEqual(streamingDisplayText(for: "  Hola mundo  "), "  Hola mundo  ")
    }

    /// El limitador deja pasar el primer repintado y luego como máximo uno
    /// por intervalo, para no reparsear el hilo con cada delta de la ráfaga.
    func testStreamThrottlerLimitsRepaints() {
        let throttle = StreamThrottler(minInterval: 0.1)
        let start = Date()
        XCTAssertTrue(throttle.shouldPaint(now: start))
        XCTAssertFalse(throttle.shouldPaint(now: start.addingTimeInterval(0.05)))
        XCTAssertFalse(throttle.shouldPaint(now: start.addingTimeInterval(0.09)))
        XCTAssertTrue(throttle.shouldPaint(now: start.addingTimeInterval(0.11)))
        XCTAssertFalse(throttle.shouldPaint(now: start.addingTimeInterval(0.15)))
    }
}
