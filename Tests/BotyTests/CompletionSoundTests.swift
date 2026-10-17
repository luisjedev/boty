import XCTest

@testable import Boty

/// Regresión: al terminar el trabajo (cadena en reposo y sin cola
/// pendiente) suena un aviso; con más trabajo por delante, tras Detener o
/// con el aviso desactivado en Ajustes, no suena.
/// Usa el gancho de cadena para no lanzar `muse` real.
@MainActor
final class CompletionSoundTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    /// Fin natural sin cola pendiente: suena una vez.
    func testFinishChainWithoutQueuePlaysSound() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        var beeps = 0
        viewModel.soundPlayer = { beeps += 1 }

        viewModel.finishChain(conversationId: conversationId, cancelled: false)

        XCTAssertEqual(beeps, 1)
    }

    /// Fin natural con cola pendiente: se lanza lo encolado sin sonar; el
    /// aviso llega al terminar esa continuación.
    func testFinishChainWithQueueDispatchesWithoutSound() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        var chained: [String] = []
        viewModel.chainHook = { _, _, text in chained.append(text) }
        var beeps = 0
        viewModel.soundPlayer = { beeps += 1 }

        viewModel.debugMarkRunning(conversationId: conversationId, botName: "Asistente")
        viewModel.inputText = "luego"
        viewModel.send()
        viewModel.debugClearRunning(conversationId: conversationId)

        viewModel.finishChain(conversationId: conversationId, cancelled: false)

        XCTAssertEqual(chained, ["luego"])
        XCTAssertEqual(viewModel.queuedMessages(for: conversationId), [])
        XCTAssertEqual(beeps, 0)

        viewModel.finishChain(conversationId: conversationId, cancelled: false)

        XCTAssertEqual(beeps, 1)
    }

    /// Tras Detener (cancelado): sin aviso y la cola queda intacta.
    func testFinishChainCancelledStaysSilent() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        var beeps = 0
        viewModel.soundPlayer = { beeps += 1 }

        viewModel.debugMarkRunning(conversationId: conversationId, botName: "Asistente")
        viewModel.inputText = "esperando"
        viewModel.send()
        viewModel.debugClearRunning(conversationId: conversationId)

        viewModel.finishChain(conversationId: conversationId, cancelled: true)

        XCTAssertEqual(beeps, 0)
        XCTAssertEqual(viewModel.queuedMessages(for: conversationId), ["esperando"])
    }

    /// Con el aviso desactivado en Ajustes: fin natural silencioso.
    func testDisabledSettingStaysSilent() {
        let store = makeIsolatedStore()
        store.settings.completionSoundEnabled = false
        let viewModel = ChatViewModel(store: store)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        var beeps = 0
        viewModel.soundPlayer = { beeps += 1 }

        viewModel.finishChain(conversationId: conversationId, cancelled: false)

        XCTAssertEqual(beeps, 0)
    }

    /// El aviso viene activado por defecto, también al leer ajustes
    /// guardados antes de que existiera.
    func testCompletionSoundDefaultsToEnabled() {
        XCTAssertTrue(AppSettings().completionSoundEnabled)
        let legacy = try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy?.completionSoundEnabled ?? false)
    }
}
