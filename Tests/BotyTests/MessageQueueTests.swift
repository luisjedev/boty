import XCTest

@testable import Boty

/// Regresión: se puede escribir mientras un bot responde. El mensaje queda
/// visible en el chat y en cola hasta el siguiente hueco (fin natural de la
/// cadena), donde se procesa como un turno propio en orden FIFO.
/// Usa el gancho de cadena para no lanzar `muse` real.
@MainActor
final class MessageQueueTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    /// Enviar durante una respuesta en curso encola en vez de descartar.
    func testSendWhileRunningQueuesInsteadOfDropping() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }

        viewModel.debugMarkRunning(conversationId: conversationId, botName: "Asistente")
        viewModel.inputText = "feedback"
        viewModel.send()

        // Visible en el chat y en cola, sin descarte.
        XCTAssertTrue(
            store.activeConversation?.messages.contains { $0.role == "user" && $0.text == "feedback" } ?? false
        )
        XCTAssertEqual(viewModel.queuedMessages(for: conversationId), ["feedback"])
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertEqual(viewModel.queuedCount, 1)

        viewModel.debugClearRunning(conversationId: conversationId)
        viewModel.clearQueue(conversationId: conversationId)
        XCTAssertEqual(viewModel.queuedCount, 0)
    }

    /// La cola se procesa en orden FIFO, un turno por hueco, sin pedir nada.
    func testQueueDrainsInOrder() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        var chained: [String] = []
        viewModel.chainHook = { _, _, text in chained.append(text) }

        viewModel.debugMarkRunning(conversationId: conversationId, botName: "Asistente")
        viewModel.inputText = "primero"
        viewModel.send()
        viewModel.inputText = "segundo"
        viewModel.send()
        XCTAssertEqual(viewModel.queuedMessages(for: conversationId), ["primero", "segundo"])
        viewModel.debugClearRunning(conversationId: conversationId)

        // Hueco: el primero se lanza directo y el segundo sigue en cola.
        viewModel.drainQueue(conversationId: conversationId)
        XCTAssertEqual(chained, ["primero"])
        XCTAssertEqual(viewModel.queuedMessages(for: conversationId), ["segundo"])
        XCTAssertEqual(viewModel.queuedCount, 1)

        // Siguiente hueco: el segundo.
        viewModel.drainQueue(conversationId: conversationId)
        XCTAssertEqual(chained, ["primero", "segundo"])
        XCTAssertTrue(viewModel.queuedMessages(for: conversationId).isEmpty)
        XCTAssertEqual(viewModel.queuedCount, 0)
    }

    /// En reposo con cola pendiente (p. ej. tras Detener), lo nuevo se encola
    /// y se lanza lo más antiguo primero.
    func testIdleSendDispatchesOldestFirst() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        var chained: [String] = []
        viewModel.chainHook = { _, _, text in chained.append(text) }

        viewModel.debugMarkRunning(conversationId: conversationId, botName: "Asistente")
        viewModel.inputText = "viejo"
        viewModel.send()
        // Detener deja la cola pendiente en reposo.
        viewModel.debugClearRunning(conversationId: conversationId)
        XCTAssertFalse(viewModel.isRunning)

        viewModel.inputText = "nuevo"
        viewModel.send()

        XCTAssertEqual(chained, ["viejo"])
        XCTAssertEqual(viewModel.queuedMessages(for: conversationId), ["nuevo"])

        viewModel.drainQueue(conversationId: conversationId)
        XCTAssertEqual(chained, ["viejo", "nuevo"])
        XCTAssertTrue(viewModel.queuedMessages(for: conversationId).isEmpty)
    }

    /// Cada conversación tiene su propia cola: encolar en un bot no afecta
    /// a otro, y el contador sigue a la conversación visible.
    func testQueueIsIndependentPerConversation() {
        let store = makeIsolatedStore()
        XCTAssertGreaterThanOrEqual(store.bots.count, 2)
        let botA = store.bots[0]
        let botB = store.bots[1]
        guard let convA = store.thread(for: botA.id),
              let convB = store.thread(for: botB.id)
        else { return XCTFail("faltan los hilos por bot") }
        let viewModel = ChatViewModel(store: store)
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }

        viewModel.debugMarkRunning(conversationId: convA.id, botName: botA.name)
        viewModel.inputText = "para A"
        viewModel.send()
        XCTAssertEqual(viewModel.queuedMessages(for: convA.id), ["para A"])
        XCTAssertEqual(viewModel.queuedCount, 1)

        store.activeBotId = botB.id
        XCTAssertEqual(viewModel.queuedCount, 0)
        viewModel.inputText = "para B"
        viewModel.send()
        // B está libre: se lanza directo en su propio hilo.
        XCTAssertEqual(chained.count, 1)
        XCTAssertEqual(chained.first?.conversationId, convB.id)
        XCTAssertEqual(chained.first?.targets.map(\.id), [botB.id])
        XCTAssertEqual(chained.first?.text, "para B")
        XCTAssertTrue(viewModel.queuedMessages(for: convB.id).isEmpty)

        store.activeBotId = botA.id
        XCTAssertEqual(viewModel.queuedCount, 1)

        viewModel.debugClearRunning(conversationId: convA.id)
        viewModel.clearQueue(conversationId: convA.id)
        XCTAssertTrue(viewModel.queuedMessages(for: convA.id).isEmpty)
    }

    /// Vaciar un hilo descarta su cola sin tocar a los demás.
    func testClearThreadDropsItsQueue() {
        let store = makeIsolatedStore()
        XCTAssertGreaterThanOrEqual(store.bots.count, 2)
        let botA = store.bots[0]
        let botB = store.bots[1]
        guard let convA = store.thread(for: botA.id),
              let convB = store.thread(for: botB.id)
        else { return XCTFail("faltan los hilos por bot") }
        let viewModel = ChatViewModel(store: store)

        viewModel.debugMarkRunning(conversationId: convA.id, botName: botA.name)
        viewModel.inputText = "para A"
        viewModel.send()
        viewModel.debugMarkRunning(conversationId: convB.id, botName: botB.name)
        XCTAssertEqual(viewModel.queuedMessages(for: convA.id).count, 1)

        viewModel.clearThread(botId: botA.id)

        XCTAssertTrue(viewModel.queuedMessages(for: convA.id).isEmpty)
        XCTAssertEqual(viewModel.queuedCount, 0)
        XCTAssertFalse(viewModel.isBotRunning(botA.id))
        XCTAssertTrue(viewModel.isBotRunning(botB.id))
    }
}
