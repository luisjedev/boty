import XCTest

@testable import Boty

final class UsageTrackerTests: XCTestCase {
    /// Fragmento real (con ANSI) del panel /usage capturado del TUI.
    private let panelSample = "│ \u{1B}[38;2;204;211;219;49m \u{1B}[1mSubscription · Muse Code High Usage\u{1B}[22m                \u{1B}[38;2;103;108;116;49m │\u{1B}[52;1H│ \u{1B}[38;2;204;211;219;49m \u{1B}[1m\u{1B}[38;2;138;144;152;49m  Current\u{1B}[22m\u{1B}[38;2;204;211;219;49m        9% used · Resets at 6:27 PM       \u{1B}[38;2;103;108;116;49m │\u{1B}[53;1H│ \u{1B}[38;2;204;211;219;49m \u{1B}[1m\u{1B}[38;2;138;144;152;49m  Weekly\u{1B}[22m\u{1B}[38;2;204;211;219;49m         3% used · Resets Oct 12 at 2:00 AM\u{1B}[38;2;103;108;116;49m │\u{1B}[54;1H"

    func testStripAnsiRemovesSequences() {
        let clean = stripAnsi(panelSample)
        XCTAssertFalse(clean.contains("\u{1B}"))
        XCTAssertTrue(clean.contains("Subscription · Muse Code High Usage"))
        XCTAssertTrue(clean.contains("9% used"))
    }

    func testParseUsagePanel() {
        let usage = parseUsagePanel(panelSample)
        XCTAssertEqual(
            usage,
            SubscriptionUsage(
                windowPercent: 9,
                windowResets: "6:27 PM",
                weeklyPercent: 3,
                weeklyResets: "Oct 12 at 2:00 AM",
                tier: "Muse Code High Usage"
            )
        )
    }

    func testParseUsagePanelRejectsGarbage() {
        XCTAssertNil(parseUsagePanel(""))
        XCTAssertNil(parseUsagePanel("hola, no soy un panel"))
        // Parcial: falta el bloque semanal.
        XCTAssertNil(parseUsagePanel("Subscription · X │ Current 9% used · Resets at 6:27 PM"))
    }

    func testBarFraction() {
        XCTAssertEqual(usageBarFraction(percent: 0), 0)
        XCTAssertEqual(usageBarFraction(percent: 50), 0.5)
        XCTAssertEqual(usageBarFraction(percent: 100), 1)
        // El % puede pasar de 100; la barra se recorta.
        XCTAssertEqual(usageBarFraction(percent: 134), 1)
    }

    func testAutoRefreshIntervalIsThirtyMinutes() {
        // El medidor del pie se actualiza cada 30 min (README).
        XCTAssertEqual(usageAutoRefreshInterval, 30 * 60)
    }

    func testAppSettingsIgnoresLegacyCaps() throws {
        // Ajustes guardados por versiones con topes (`maxChainHops` y topes
        // de tokens): las claves extra se ignoran y el resto se conserva.
        let legacy = """
        {"musePath":"/x/muse","followBotMentions":false,"maxChainHops":2,"sessionTokenCap":20000000,"weeklyTokenCap":100000000}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(settings.musePath, "/x/muse")
        XCTAssertFalse(settings.followBotMentions)
    }

    func testAppSettingsRoundTrip() throws {
        let settings = AppSettings(musePath: "/y", followBotMentions: false)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.musePath, "/y")
        XCTAssertFalse(decoded.followBotMentions)
    }
}
