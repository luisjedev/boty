import XCTest

@testable import Boty

/// Regresión: al abrir la app, el chat del primer bot debe bajar hasta abajo
/// del todo. El `onAppear` dispara un solo scroll que puede caer antes de que
/// el LazyVStack mida el Markdown, así que la apertura (y el cambio de bot)
/// reintentan con retardos crecientes; los mensajes en vivo no reintentan.
final class ChatScrollTests: XCTestCase {
    func testOpeningAppRetriesScrollWithGrowingDelays() {
        assertRetries(ChatScrollTrigger.initialAppear)
    }

    func testSwitchingBotRetriesScrollWithGrowingDelays() {
        assertRetries(ChatScrollTrigger.conversationChanged)
    }

    func testLiveMessagesNeverRetryScroll() {
        XCTAssertTrue(chatScrollRetryDelays(for: .newMessage).isEmpty)
        XCTAssertTrue(chatScrollRetryDelays(for: .streamingUpdate).isEmpty)
    }

    /// La vista ya no usa ancla de scroll (`.defaultScrollAnchor(.bottom)`
    /// provocaba un bucle infinito de layout al abrir hilos largos y mataba
    /// la app): quedarse abajo depende solo de estos reintentos, así que cada
    /// origen debe declarar explícitamente su política.
    func testEveryTriggerDeclaresItsRetryPolicy() {
        let withoutRetries: Set<ChatScrollTrigger> = [.newMessage, .streamingUpdate]
        for trigger in ChatScrollTrigger.allCases {
            if withoutRetries.contains(trigger) {
                XCTAssertTrue(chatScrollRetryDelays(for: trigger).isEmpty, "\(trigger)")
            } else {
                XCTAssertFalse(chatScrollRetryDelays(for: trigger).isEmpty, "\(trigger)")
            }
        }
    }

    /// Los reintentos son positivos, crecientes y acotados para no pelear con
    /// el scroll manual del usuario pasado el primer instante.
    private func assertRetries(_ trigger: ChatScrollTrigger, file: StaticString = #filePath, line: UInt = #line) {
        let delays = chatScrollRetryDelays(for: trigger)
        XCTAssertFalse(delays.isEmpty, file: file, line: line)
        XCTAssertTrue(delays.allSatisfy { $0 > 0 }, file: file, line: line)
        XCTAssertEqual(delays, delays.sorted(), file: file, line: line)
        XCTAssertLessThanOrEqual(delays.last ?? 0, 1.0, file: file, line: line)
    }
}
