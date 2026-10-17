import XCTest

@testable import Boty

/// Hilos múltiples por bot y grupo: CRUD, hilo activo y migración del hilo
/// único anterior (se conserva como primer hilo activo, sin perder mensajes).
@MainActor
final class ThreadMultipleTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    // MARK: - Crear y cambiar de hilo

    func testCreateThreadBecomesActive() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let firstId = store.thread(for: bot.id)!.id

        let second = store.createThread(botId: bot.id)!

        XCTAssertEqual(store.threads(for: bot.id).count, 2)
        XCTAssertEqual(store.activeConversation?.id, second.id)
        XCTAssertNotEqual(second.id, firstId)
        XCTAssertTrue(second.title.contains(bot.name))
    }

    func testCreateGroupThreadBecomesActive() {
        let store = makeIsolatedStore()
        let group = BotGroup(name: "Equipo", botIds: [store.bots[0].id])
        store.addGroup(group)

        let second = store.createGroupThread(groupId: group.id)!

        XCTAssertEqual(store.groupThreads(for: group.id).count, 2)
        XCTAssertEqual(store.activeThreadIds[group.id.uuidString], second.id.uuidString)
    }

    func testSelectThreadSwitchesActiveConversation() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        store.selectBot(id: bot.id)
        let first = store.thread(for: bot.id)!
        let second = store.createThread(botId: bot.id)!

        store.selectThread(id: first.id)

        XCTAssertEqual(store.activeConversation?.id, first.id)
        XCTAssertEqual(store.activeThreadIds[bot.id.uuidString], first.id.uuidString)
        _ = second
    }

    // MARK: - Renombrar

    func testRenameThread() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let thread = store.createThread(botId: bot.id)!

        store.renameThread(id: thread.id, title: "  Diseño API  ")

        XCTAssertEqual(store.conversations.first { $0.id == thread.id }?.title, "Diseño API")
    }

    func testRenameThreadIgnoresBlankTitle() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let thread = store.thread(for: bot.id)!

        store.renameThread(id: thread.id, title: "   ")

        XCTAssertEqual(store.conversations.first { $0.id == thread.id }?.title, thread.title)
    }

    func testUpdateBotPreservesRenamedThreads() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let second = store.createThread(botId: bot.id)!
        store.renameThread(id: second.id, title: "Mi hilo")

        var renamed = bot
        renamed.name = "Nuevo nombre"
        store.updateBot(renamed)

        // El hilo no renombrado sigue al bot; el renombrado se respeta.
        XCTAssertEqual(store.conversations.first { $0.botId == bot.id }?.title, "Nuevo nombre")
        XCTAssertEqual(store.conversations.first { $0.id == second.id }?.title, "Mi hilo")
    }

    // MARK: - Borrar (mínimo un hilo por dueño)

    func testDeleteThreadRemovesItAndActivatesSibling() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let first = store.thread(for: bot.id)!
        let second = store.createThread(botId: bot.id)!

        store.deleteThread(id: second.id)

        XCTAssertEqual(store.threads(for: bot.id).map(\.id), [first.id])
        XCTAssertEqual(store.activeConversation?.id, first.id)
    }

    func testDeleteLastThreadClearsInsteadOfRemoving() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let only = store.thread(for: bot.id)!
        store.appendMessage(ChatMessage(role: "user", text: "hola"), conversationId: only.id)

        store.deleteThread(id: only.id)

        // Invariante: sigue habiendo exactamente un hilo, con el mismo id,
        // vaciado al saludo inicial.
        XCTAssertEqual(store.threads(for: bot.id).map(\.id), [only.id])
        let kept = store.thread(for: bot.id)!
        XCTAssertEqual(kept.messages.count, 1)
        XCTAssertEqual(kept.messages.first?.role, "system")
    }

    // MARK: - Migración y persistencia

    func testMigrationKeepsSingleThreadContentAsActive() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        let store = BotStore(storageDirectory: dir)
        let bot = store.bots[0]
        let oldId = store.thread(for: bot.id)!.id
        store.appendMessage(ChatMessage(role: "user", text: "mensaje antiguo"), conversationId: oldId)

        // Simular datos guardados por la versión de hilo único: sin mapeo.
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("activeThreads.json")
        )

        let reloaded = BotStore(storageDirectory: dir)

        XCTAssertEqual(reloaded.thread(for: bot.id)?.id, oldId)
        XCTAssertTrue(reloaded.thread(for: bot.id)?.messages.contains { $0.text == "mensaje antiguo" } ?? false)
    }

    func testActiveThreadPersistsAcrossReloads() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let second = store.createThread(botId: bot.id)!
        store.appendMessage(ChatMessage(role: "user", text: "en el segundo"), conversationId: second.id)

        let reloaded = BotStore(storageDirectory: store.dataDir)

        XCTAssertEqual(reloaded.threads(for: bot.id).count, 2)
        XCTAssertEqual(reloaded.activeThreadIds[bot.id.uuidString], second.id.uuidString)
        XCTAssertEqual(reloaded.activeThread(for: bot.id)?.id, second.id)
    }

    func testSyncKeepsMultipleGroupThreads() {
        let bot = Bot(name: "A", specialty: "a", colorHex: "#0A84FF", systemPrompt: "p")
        let group = BotGroup(name: "Equipo", botIds: [bot.id])
        var first = makeGroupThread(for: group, memberNames: ["A"])
        first.messages.append(ChatMessage(role: "user", text: "uno"))
        var second = makeGroupThread(for: group, memberNames: ["A"])
        second.messages.append(ChatMessage(role: "user", text: "dos"))

        let threads = syncedThreads(bots: [bot], groups: [group], conversations: [first, second])

        XCTAssertEqual(threads.filter { $0.groupId == group.id }.count, 2)
    }
}
