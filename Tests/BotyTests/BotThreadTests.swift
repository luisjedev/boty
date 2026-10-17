import XCTest

@testable import Boty

final class BotThreadTests: XCTestCase {
    private func makeBot(name: String) -> Bot {
        Bot(name: name, specialty: "test", colorHex: "#0A84FF", systemPrompt: "prompt")
    }

    func testSyncCreatesOneThreadPerBot() {
        let bots = [makeBot(name: "A"), makeBot(name: "B")]
        let threads = syncedThreads(bots: bots, conversations: [])
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(Set(threads.compactMap(\.botId)), Set(bots.map(\.id)))
        XCTAssertEqual(threads.map(\.title), ["A", "B"])
    }

    func testFreshThreadGreetsWithBotName() {
        let thread = makeThread(for: makeBot(name: "Coder"))
        XCTAssertEqual(thread.title, "Coder")
        XCTAssertEqual(thread.messages.count, 1)
        XCTAssertEqual(thread.messages.first?.role, "system")
        XCTAssertTrue(thread.messages.first?.text.contains("Coder") ?? false)
    }

    func testSyncPreservesExistingThreadContent() {
        let bot = makeBot(name: "A")
        var thread = makeThread(for: bot)
        thread.messages.append(ChatMessage(role: "user", text: "hola"))
        thread.sessionIds[bot.id.uuidString] = "sesion-1"
        thread.introducedBots = [bot.id.uuidString]

        let threads = syncedThreads(bots: [bot], conversations: [thread])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].id, thread.id)
        XCTAssertEqual(threads[0].messages.count, 2)
        XCTAssertEqual(threads[0].sessionIds[bot.id.uuidString], "sesion-1")
        XCTAssertEqual(threads[0].introducedBots, [bot.id.uuidString])
    }

    func testSyncDropsLegacyAndOrphanThreads() {
        let bot = makeBot(name: "A")
        let legacy = Conversation() // Sin botId: formato antiguo.
        var orphan = Conversation()
        orphan.botId = UUID() // Bot que ya no existe.

        let threads = syncedThreads(bots: [bot], conversations: [legacy, orphan])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].botId, bot.id)
    }

    func testSyncKeepsAllThreadsForSameBot() {
        // Con hilos múltiples, dos hilos del mismo bot son legítimos y se
        // conservan en orden (el primero sigue siendo el activo por defecto).
        let bot = makeBot(name: "A")
        var first = makeThread(for: bot)
        first.messages.append(ChatMessage(role: "user", text: "primero"))
        var second = makeThread(for: bot)
        second.messages.append(ChatMessage(role: "user", text: "segundo"))

        let threads = syncedThreads(bots: [bot], conversations: [first, second])
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads.map(\.id), [first.id, second.id])
    }

    func testLegacyConversationDecodesWithoutBotId() throws {
        // El JSON guardado por versiones anteriores no tiene clave "botId".
        let json = """
        {"id":"\(UUID().uuidString)","title":"Vieja","messages":[],"sessionIds":{},"introducedBots":[],"date":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Conversation.self, from: json)
        XCTAssertNil(decoded.botId)
    }
}
