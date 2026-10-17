import XCTest

@testable import Boty

/// Regresión: cada bot es una conversación totalmente independiente.
/// Enviar en un bot no debe mostrar "Detener" en otro, ni bloquearlo,
/// ni mezclar borradores, colas o cadenas.
@MainActor
final class ConversationIndependenceTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    /// "Detener" solo aparece en la conversación que tiene una respuesta en curso.
    func testRunningIndicatorOnlyShowsInRunningConversation() {
        let store = makeIsolatedStore()
        XCTAssertGreaterThanOrEqual(store.bots.count, 2)
        let botA = store.bots[0]
        let botB = store.bots[1]
        guard let convA = store.thread(for: botA.id),
              let convB = store.thread(for: botB.id)
        else { return XCTFail("faltan los hilos por bot") }
        let viewModel = ChatViewModel(store: store)
        XCTAssertEqual(viewModel.activeBot?.id, botA.id)

        viewModel.debugMarkRunning(conversationId: convA.id, botName: botA.name)
        XCTAssertTrue(viewModel.isRunning)
        XCTAssertEqual(viewModel.runningBotName, botA.name)

        // Cambiar al otro bot: sin "Detener" ni nombre escribiendo.
        store.activeBotId = botB.id
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.runningBotName, "")
        XCTAssertTrue(viewModel.isBotRunning(botA.id))
        XCTAssertFalse(viewModel.isBotRunning(botB.id))
        XCTAssertEqual(viewModel.runningName(for: convA.id), botA.name)
        XCTAssertNil(viewModel.runningName(for: convB.id))

        // Volver: el indicador sigue ahí.
        store.activeBotId = botA.id
        XCTAssertTrue(viewModel.isRunning)
        XCTAssertEqual(viewModel.runningBotName, botA.name)
    }

    /// Enviar en un bot libre no lo bloquea que otro esté respondiendo.
    /// Usa el gancho de cadena para no lanzar `muse`.
    func testSendInIdleConversationWhileAnotherRuns() {
        let store = makeIsolatedStore()
        let botA = store.bots[0]
        let botB = store.bots[1]
        guard let convA = store.thread(for: botA.id) else {
            return XCTFail("falta el hilo del bot A")
        }
        let viewModel = ChatViewModel(store: store)
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }

        viewModel.debugMarkRunning(conversationId: convA.id, botName: botA.name)
        store.activeBotId = botB.id
        XCTAssertFalse(viewModel.isRunning)

        viewModel.inputText = "hola"
        viewModel.send()

        // El mensaje y la cadena pertenecen al hilo B.
        let threadB = store.thread(for: botB.id)
        XCTAssertTrue(threadB?.messages.contains { $0.role == "user" && $0.text == "hola" } ?? false)
        XCTAssertEqual(chained.count, 1)
        XCTAssertEqual(chained.first?.conversationId, threadB?.id)
        XCTAssertEqual(chained.first?.targets.map(\.id), [botB.id])
        XCTAssertEqual(chained.first?.text, "hola")
        // A sigue en curso, B no.
        XCTAssertTrue(viewModel.isBotRunning(botA.id))
        XCTAssertFalse(viewModel.isBotRunning(botB.id))

        viewModel.debugClearRunning(conversationId: convA.id)
        XCTAssertFalse(viewModel.isBotRunning(botA.id))
    }

    /// Borradores de texto independientes por bot.
    func testDraftsAreIndependentPerBot() {
        let store = makeIsolatedStore()
        let botA = store.bots[0]
        let botB = store.bots[1]
        let viewModel = ChatViewModel(store: store)

        viewModel.inputText = "borrador A"

        store.activeBotId = botB.id
        XCTAssertEqual(viewModel.inputText, "")

        viewModel.inputText = "borrador B"

        store.activeBotId = botA.id
        XCTAssertEqual(viewModel.inputText, "borrador A")

        store.activeBotId = botB.id
        XCTAssertEqual(viewModel.inputText, "borrador B")
    }

    /// "Detener" (y la cancelación directa) solo afecta a su conversación.
    func testCancelOnlyAffectsItsOwnConversation() {
        let store = makeIsolatedStore()
        let botA = store.bots[0]
        let botB = store.bots[1]
        guard let convA = store.thread(for: botA.id),
              let convB = store.thread(for: botB.id)
        else { return XCTFail("faltan los hilos por bot") }
        let viewModel = ChatViewModel(store: store)

        let tokenA = MuseRunToken()
        let tokenB = MuseRunToken()
        viewModel.runTokens[convA.id] = tokenA
        viewModel.runTokens[convB.id] = tokenB

        // Cancelar desde la conversación visible (A).
        viewModel.cancel()
        XCTAssertTrue(tokenA.isCancelled)
        XCTAssertFalse(tokenB.isCancelled)

        // Cancelación directa de B.
        viewModel.cancelConversation(convB.id)
        XCTAssertTrue(tokenB.isCancelled)
    }

    /// Vaciar o eliminar un bot cancela su ejecución sin tocar a los demás.
    func testClearThreadCancelsOnlyThatBot() {
        let store = makeIsolatedStore()
        let botA = store.bots[0]
        let botB = store.bots[1]
        guard let convA = store.thread(for: botA.id),
              let convB = store.thread(for: botB.id)
        else { return XCTFail("faltan los hilos por bot") }
        let viewModel = ChatViewModel(store: store)

        let tokenA = MuseRunToken()
        let tokenB = MuseRunToken()
        viewModel.runTokens[convA.id] = tokenA
        viewModel.runTokens[convB.id] = tokenB
        viewModel.debugMarkRunning(conversationId: convA.id, botName: botA.name)
        viewModel.debugMarkRunning(conversationId: convB.id, botName: botB.name)

        viewModel.clearThread(botId: botA.id)

        XCTAssertTrue(tokenA.isCancelled)
        XCTAssertFalse(tokenB.isCancelled)
        XCTAssertNil(viewModel.runningName(for: convA.id))
        XCTAssertEqual(viewModel.runningName(for: convB.id), botB.name)
    }
}
