import XCTest

@testable import Boty

/// Regresión: el marcador transitorio de "escribiendo…" nunca debe quedar
/// guardado en disco ni sobrevivir a un reinicio como un spinner eterno.
@MainActor
final class TypingPlaceholderTests: XCTestCase {
    func testTypingPlaceholderIsNotPersisted() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        let store = BotStore(storageDirectory: dir)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }

        store.appendMessage(ChatMessage(role: "user", text: "hola"), conversationId: conversationId)
        let typing = ChatMessage(role: "bot", text: "…")
        XCTAssertTrue(typing.isTypingPlaceholder)
        store.appendMessage(typing, conversationId: conversationId, persist: false)

        // En memoria sí está (la vista lo muestra mientras responde)…
        XCTAssertTrue(store.thread(for: store.activeBot!.id)?.messages.contains(typing) ?? false)

        // …pero al recargar desde disco ya no existe.
        let reloaded = BotStore(storageDirectory: dir)
        let texts = reloaded.activeConversation?.messages.map(\.text) ?? []
        XCTAssertTrue(texts.contains("hola"))
        XCTAssertFalse(texts.contains("…"))
    }

    func testLoadDropsLegacyPersistedPlaceholders() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        let store = BotStore(storageDirectory: dir)
        guard let conversationId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }

        // Simula el estado antiguo: un "…" que quedó guardado en disco.
        store.appendMessage(ChatMessage(role: "user", text: "hola"), conversationId: conversationId)
        store.appendMessage(ChatMessage(role: "bot", text: "…"), conversationId: conversationId)

        let reloaded = BotStore(storageDirectory: dir)
        let messages = reloaded.activeConversation?.messages ?? []
        XCTAssertTrue(messages.map(\.text).contains("hola"))
        XCTAssertFalse(messages.contains { $0.isTypingPlaceholder })

        // Y el guardado posterior ya no lo contiene (doble recarga limpia).
        let reloadedAgain = BotStore(storageDirectory: dir)
        XCTAssertFalse((reloadedAgain.activeConversation?.messages ?? []).contains { $0.isTypingPlaceholder })
    }

    func testOnlyBotEllipsisCountsAsPlaceholder() {
        XCTAssertTrue(ChatMessage(role: "bot", text: "…").isTypingPlaceholder)
        XCTAssertFalse(ChatMessage(role: "user", text: "…").isTypingPlaceholder)
        XCTAssertFalse(ChatMessage(role: "bot", text: "respuesta").isTypingPlaceholder)
    }
}
