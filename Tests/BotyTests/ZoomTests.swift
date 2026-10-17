import AppKit
import XCTest

@testable import Boty

/// Regresión del zoom de la escala de la app (menú Vista > Acercar/Alejar,
/// ⌘+ / ⌘− / ⌘0): pasos acotados, escala geométrica, tamaños base del
/// sistema y persistencia.
final class ZoomTests: XCTestCase {
    func testDefaultStepIsNormalScale() {
        XCTAssertEqual(zoomScale(forZoomStep: 0), 1.0)
    }

    func testStepsClampOutOfRange() {
        XCTAssertEqual(clampedZoomStep(-100), zoomStepMin)
        XCTAssertEqual(clampedZoomStep(100), zoomStepMax)
        XCTAssertEqual(zoomScale(forZoomStep: -100), zoomScale(forZoomStep: zoomStepMin))
        XCTAssertEqual(zoomScale(forZoomStep: 100), zoomScale(forZoomStep: zoomStepMax))
    }

    func testScaleGrowsWithStep() {
        let scales = (zoomStepMin ... zoomStepMax).map(zoomScale(forZoomStep:))
        XCTAssertEqual(scales, scales.sorted())
        XCTAssertLessThan(scales.first!, 1.0)
        XCTAssertGreaterThan(scales.last!, 1.0)
    }

    func testPointSizeMatchesSystemAtDefaultScale() {
        // A escala 1.0 el zoom debe ser idéntico al estilo del sistema.
        for style: NSFont.TextStyle in [.body, .callout, .caption1, .caption2, .headline, .subheadline, .title2, .title3] {
            XCTAssertEqual(
                zoomPointSize(for: style, scale: 1.0),
                NSFont.preferredFont(forTextStyle: style).pointSize,
                "estilo \(style.rawValue)"
            )
        }
    }

    func testPointSizeScalesLinearly() {
        for style: NSFont.TextStyle in [.body, .caption1] {
            XCTAssertEqual(
                zoomPointSize(for: style, scale: 2.0),
                2 * zoomPointSize(for: style, scale: 1.0),
                "estilo \(style.rawValue)"
            )
        }
    }

    func testEditorSingleLineHeightGrowsWithFontSize() {
        XCTAssertGreaterThan(
            GrowingTextEditor.singleLineHeight(fontSize: 26),
            GrowingTextEditor.singleLineHeight(fontSize: 13)
        )
    }

    @MainActor
    func testStoreZoomClampsAndPersists() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        let store = BotStore(storageDirectory: dir)
        XCTAssertEqual(store.settings.zoomStep, 0)

        store.zoomIn()
        XCTAssertEqual(store.settings.zoomStep, 1)
        store.zoomOut()
        XCTAssertEqual(store.settings.zoomStep, 0)
        store.zoomOut()
        XCTAssertEqual(store.settings.zoomStep, -1)
        store.zoomReset()
        XCTAssertEqual(store.settings.zoomStep, 0)

        for _ in 0 ..< 100 { store.zoomIn() }
        XCTAssertEqual(store.settings.zoomStep, zoomStepMax)
        for _ in 0 ..< 100 { store.zoomOut() }
        XCTAssertEqual(store.settings.zoomStep, zoomStepMin)

        // Persistido: una nueva instancia lo recupera del disco.
        let reopened = BotStore(storageDirectory: dir)
        XCTAssertEqual(reopened.settings.zoomStep, zoomStepMin)
    }

    func testSettingsDecodeWithoutZoomStepKeepsDefault() throws {
        let data = Data(#"{"musePath": ""}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.zoomStep, 0)
    }
}
