import Combine
import XCTest

@testable import Boty

/// Regresión: al seleccionar otro bot en el sidebar, la vista principal
/// (cabecera + mensajes) debe actualizarse. ChatView solo observa al
/// ChatViewModel, así que este debe republicar los cambios del BotStore.
@MainActor
final class ChatViewModelTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    func testSelectingAnotherBotNotifiesViewModel() {
        let store = makeIsolatedStore()
        XCTAssertGreaterThanOrEqual(store.bots.count, 2)
        let viewModel = ChatViewModel(store: store)

        let notified = XCTestExpectation(description: "view model republica el cambio de bot")
        viewModel.objectWillChange
            .sink { _ in notified.fulfill() }
            .store(in: &cancellables)

        store.activeBotId = store.bots[1].id

        wait(for: [notified], timeout: 1.0)
        XCTAssertEqual(viewModel.activeBot?.id, store.bots[1].id)
        XCTAssertEqual(viewModel.conversation?.botId, store.bots[1].id)
    }

    func testAppendingMessageNotifiesViewModel() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }

        let notified = XCTestExpectation(description: "view model republica nuevos mensajes")
        viewModel.objectWillChange
            .sink { _ in notified.fulfill() }
            .store(in: &cancellables)

        store.appendMessage(ChatMessage(role: "user", text: "hola"), conversationId: conversationId)

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(viewModel.conversation?.messages.contains { $0.text == "hola" } ?? false)
    }

    func testActivityReplacesNeverAccumulates() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        viewModel.debugMarkRunning(conversationId: conversationId, botName: "Coder")
        viewModel.setActivity(conversationId: conversationId, headline: "💭 Pensando…")
        viewModel.setActivity(conversationId: conversationId, headline: "🔧 comando…")
        // Un solo titular: el más reciente, también en la cabecera visible.
        XCTAssertEqual(viewModel.headline(for: conversationId), "🔧 comando…")
        XCTAssertEqual(viewModel.runningHeadline, "🔧 comando…")
        viewModel.setActivity(conversationId: conversationId, headline: nil)
        XCTAssertEqual(viewModel.headline(for: conversationId), "")
        XCTAssertEqual(viewModel.runningHeadline, "")
    }

    func testRunElapsedFormatsCompactClock() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(formatRunElapsed(from: start, to: start.addingTimeInterval(7)), "0:07")
        XCTAssertEqual(formatRunElapsed(from: start, to: start.addingTimeInterval(83)), "1:23")
        XCTAssertEqual(formatRunElapsed(from: start, to: start.addingTimeInterval(725)), "12:05")
    }
}
