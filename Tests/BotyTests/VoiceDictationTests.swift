import XCTest

@testable import Boty

/// Regresión del dictado por voz: fusión del parcial en vivo sobre el texto
/// del cajón y elección del locale del reconocedor. Todo sin micrófono.
final class VoiceDictationTests: XCTestCase {
    // MARK: - Fusión base + parcial

    func testEmptyLiveKeepsBase() {
        XCTAssertEqual(voiceMergedText(base: "hola", live: ""), "hola")
        XCTAssertEqual(voiceMergedText(base: "hola", live: "   "), "hola")
    }

    func testEmptyBaseTakesLive() {
        XCTAssertEqual(voiceMergedText(base: "", live: "hola mundo"), "hola mundo")
    }

    func testLiveAppendsWithSpace() {
        // El parcial sustituye al parcial anterior: la base fijada al pulsar
        // el micro no crece con cada parcial.
        XCTAssertEqual(voiceMergedText(base: "hola", live: "mundo"), "hola mundo")
        XCTAssertEqual(voiceMergedText(base: "hola", live: "mundo cruel"), "hola mundo cruel")
    }

    func testBaseWithTrailingWhitespaceNeedsNoExtraSpace() {
        XCTAssertEqual(voiceMergedText(base: "hola ", live: "mundo"), "hola mundo")
        XCTAssertEqual(voiceMergedText(base: "hola\n", live: "mundo"), "hola\nmundo")
    }

    // MARK: - Locale

    func testCanonicalLocaleID() {
        XCTAssertEqual(voiceCanonicalLocaleID("es_ES"), "es-ES")
        XCTAssertEqual(voiceCanonicalLocaleID("es-ES"), "es-ES")
    }

    func testPreferredLocaleExactMatch() {
        let available: Set<String> = ["es-ES", "en-US"]
        XCTAssertEqual(voicePreferredLocaleID(preferredID: "es-ES", availableIDs: available), "es-ES")
    }

    func testPreferredLocaleIgnoresUnderscoreVsDash() {
        // Locale.current.identifier usa `es_ES`; el reconocedor `es-ES`.
        let available: Set<String> = ["es-ES", "en-US"]
        XCTAssertEqual(voicePreferredLocaleID(preferredID: "es_ES", availableIDs: available), "es-ES")
    }

    func testPreferredLocaleSameLanguageVariant() {
        let available: Set<String> = ["es-MX", "en-US"]
        XCTAssertEqual(voicePreferredLocaleID(preferredID: "es-AR", availableIDs: available), "es-MX")
    }

    func testPreferredLocaleFallsBackToSpanishThenEnglish() {
        XCTAssertEqual(
            voicePreferredLocaleID(preferredID: "fr-FR", availableIDs: ["es-ES", "en-US"]),
            "es-ES"
        )
        XCTAssertEqual(
            voicePreferredLocaleID(preferredID: "fr-FR", availableIDs: ["en-US", "de-DE"]),
            "en-US"
        )
    }

    func testPreferredLocaleEmptyIsNil() {
        XCTAssertNil(voicePreferredLocaleID(preferredID: "es-ES", availableIDs: []))
    }

    func testPreferredLocaleLastResortIsDeterministic() {
        let available: Set<String> = ["de-DE", "fr-FR"]
        let first = voicePreferredLocaleID(preferredID: "ja-JP", availableIDs: available)
        let second = voicePreferredLocaleID(preferredID: "ja-JP", availableIDs: available)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "de-DE")
    }
}
