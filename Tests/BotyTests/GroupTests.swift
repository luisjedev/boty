import XCTest

@testable import Boty

/// Grupos: un hilo de chat por grupo donde responden sus miembros y que
/// pueden mencionarse entre ellos como en un hilo normal.
@MainActor
final class GroupTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    private func makeGroup(name: String = "Equipo", botIds: [UUID], goal: String = "hacer la web") -> BotGroup {
        BotGroup(name: name, goal: goal, colorHex: "#0A84FF", botIds: botIds)
    }

    /// Espera a que el enrutador asíncrono lance la cadena (gancho de tests).
    private func waitForChain(timeoutMs: Int = 2000, _ ready: () -> Bool) async -> Bool {
        var waited = 0
        while !ready(), waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return ready()
    }

    // MARK: - Sincronización de hilos

    func testSyncCreatesOneThreadPerGroup() {
        let bots = [
            Bot(name: "A", specialty: "a", colorHex: "#0A84FF", systemPrompt: "p"),
            Bot(name: "B", specialty: "b", colorHex: "#0A84FF", systemPrompt: "p"),
        ]
        let group = makeGroup(botIds: bots.map(\.id))

        let threads = syncedThreads(bots: bots, groups: [group], conversations: [])

        XCTAssertEqual(threads.count, 3)
        let groupThread = threads.first { $0.groupId == group.id }
        XCTAssertEqual(groupThread?.title, "Equipo")
        XCTAssertTrue(groupThread?.messages.first?.text.contains("@A") ?? false)
        XCTAssertTrue(groupThread?.messages.first?.text.contains("@B") ?? false)
    }

    func testSyncPreservesGroupThreadContent() {
        let bot = Bot(name: "A", specialty: "a", colorHex: "#0A84FF", systemPrompt: "p")
        let group = makeGroup(botIds: [bot.id])
        var thread = makeGroupThread(for: group, memberNames: ["A"])
        thread.messages.append(ChatMessage(role: "user", text: "hola grupo"))
        thread.sessionIds[bot.id.uuidString] = "sesion-1"

        let threads = syncedThreads(bots: [bot], groups: [group], conversations: [thread])

        XCTAssertEqual(threads.count, 2)
        let kept = threads.first { $0.groupId == group.id }
        XCTAssertEqual(kept?.id, thread.id)
        XCTAssertEqual(kept?.messages.count, 2)
        XCTAssertEqual(kept?.sessionIds[bot.id.uuidString], "sesion-1")
    }

    func testSyncDropsOrphanGroupThreads() {
        let bot = Bot(name: "A", specialty: "a", colorHex: "#0A84FF", systemPrompt: "p")
        var orphan = Conversation()
        orphan.groupId = UUID()

        let threads = syncedThreads(bots: [bot], groups: [], conversations: [orphan, Conversation()])

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].botId, bot.id)
    }

    func testLegacyConversationDecodesWithoutGroupId() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Vieja","messages":[],"sessionIds":{},"introducedBots":[],"date":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Conversation.self, from: json)
        XCTAssertNil(decoded.botId)
        XCTAssertNil(decoded.groupId)
    }

    func testGroupGreetingWithoutMembers() {
        let text = groupGreeting(groupName: "Vacío", memberNames: [])
        XCTAssertTrue(text.contains("Vacío"))
        XCTAssertFalse(text.contains("@"))
    }

    // MARK: - CRUD y selección

    func testAddUpdateDeleteGroup() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let group = makeGroup(botIds: [store.bots[0].id, store.bots[1].id])
        store.addGroup(group)

        // Hilo propio con saludo.
        let thread = store.groupThread(for: group.id)
        XCTAssertEqual(thread?.title, "Equipo")
        XCTAssertEqual(thread?.messages.count, 1)

        // Renombrar actualiza el título del hilo.
        var renamed = group
        renamed.name = "Renombrado"
        store.updateGroup(renamed)
        XCTAssertEqual(store.groupThread(for: group.id)?.title, "Renombrado")

        // Seleccionar el grupo activa su hilo y oculta el bot activo.
        store.selectGroup(id: group.id)
        XCTAssertEqual(store.activeConversation?.groupId, group.id)
        XCTAssertEqual(viewModel.conversation?.groupId, group.id)
        XCTAssertEqual(viewModel.activeGroup?.id, group.id)
        XCTAssertNil(viewModel.activeBot)

        // Volver a un bot y eliminar el grupo: el hilo desaparece.
        store.selectBot(id: store.bots[0].id)
        XCTAssertEqual(viewModel.conversation?.botId, store.bots[0].id)
        store.deleteGroup(id: group.id)
        XCTAssertNil(store.groupThread(for: group.id))
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testDeleteGroupFallsBackToFirstBot() {
        let store = makeIsolatedStore()
        let group = makeGroup(botIds: [store.bots[0].id])
        store.addGroup(group)
        store.selectGroup(id: group.id)

        store.deleteGroup(id: group.id)

        XCTAssertEqual(store.activeConversation?.botId, store.bots[0].id)
        XCTAssertNil(store.activeGroupId)
    }

    func testDeleteBotRemovesItFromGroups() {
        let store = makeIsolatedStore()
        let doomed = store.bots[0]
        let group = makeGroup(botIds: [doomed.id, store.bots[1].id])
        store.addGroup(group)

        store.deleteBot(id: doomed.id)

        XCTAssertEqual(store.groups.first?.botIds, [store.bots[0].id])
        XCTAssertEqual(store.memberNames(for: store.groups[0]), [store.bots[0].name])
    }

    func testClearGroupThread() {
        let store = makeIsolatedStore()
        let group = makeGroup(botIds: [store.bots[0].id])
        store.addGroup(group)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }
        store.appendMessage(ChatMessage(role: "user", text: "hola"), conversationId: threadId)
        _ = store.ensureSession(botId: store.bots[0].id, conversationId: threadId)

        store.clearGroupThread(groupId: group.id)

        let cleared = store.groupThread(for: group.id)
        XCTAssertEqual(cleared?.messages.count, 1)
        XCTAssertEqual(cleared?.messages.first?.role, "system")
        XCTAssertTrue(cleared?.sessionIds.isEmpty ?? false)
        XCTAssertTrue(cleared?.introducedBots.isEmpty ?? false)
    }

    func testGroupsPersistAcrossReloads() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        let store = BotStore(storageDirectory: dir)
        var group = makeGroup(botIds: [store.bots[0].id])
        group.workspacePath = "/tmp/grupo-x"
        store.addGroup(group)
        let threadId = store.groupThread(for: group.id)!.id
        store.appendMessage(ChatMessage(role: "user", text: "hola"), conversationId: threadId)

        let reloaded = BotStore(storageDirectory: dir)

        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups.first?.name, "Equipo")
        XCTAssertEqual(reloaded.groups.first?.workspacePath, "/tmp/grupo-x")
        let thread = reloaded.groupThread(for: group.id)
        XCTAssertEqual(thread?.messages.count, 2)
        XCTAssertTrue(thread?.messages.contains { $0.text == "hola" } ?? false)
    }

    // MARK: - Envío en grupos

    /// Sin menciones, si el enrutador devuelve basura responde el primer
    /// miembro (fallback a uno solo, nunca todo el grupo). Usa el texto
    /// simulado del enrutador y el gancho de cadena para no lanzar `muse`.
    func testGroupSendWithoutMentionsFallsBackToFirstMember() async {
        let store = makeIsolatedStore()
        var group = makeGroup(botIds: [store.bots[0].id, store.bots[1].id])
        group.workspacePath = "/tmp/grupo-x"
        store.addGroup(group)
        let viewModel = ChatViewModel(store: store)
        viewModel.routerTextOverride = "esto no es un JSON"
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }
        store.selectGroup(id: group.id)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }

        viewModel.inputText = "hola a todos"
        viewModel.send()

        let thread = store.groupThread(for: group.id)
        XCTAssertTrue(thread?.messages.contains { $0.role == "user" && $0.text == "hola a todos" } ?? false)
        let resolved = await waitForChain { !chained.isEmpty }
        XCTAssertTrue(resolved)
        XCTAssertEqual(chained.first?.conversationId, threadId)
        XCTAssertEqual(chained.first?.targets.map(\.id), [store.bots[0].id])
        XCTAssertEqual(chained.first?.text, "hola a todos")
    }

    func testGroupSendWithMentionTargetsSubset() {
        let store = makeIsolatedStore()
        let group = makeGroup(botIds: [store.bots[0].id, store.bots[1].id])
        store.addGroup(group)
        let viewModel = ChatViewModel(store: store)
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }
        store.selectGroup(id: group.id)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }

        viewModel.inputText = "@\(store.bots[1].name) haz esto"
        viewModel.send()

        XCTAssertEqual(chained.count, 1)
        XCTAssertEqual(chained.first?.conversationId, threadId)
        XCTAssertEqual(chained.first?.targets.map(\.id), [store.bots[1].id])
        XCTAssertEqual(chained.first?.text, "@\(store.bots[1].name) haz esto")
    }

    func testDraftsAreIndependentBetweenBotAndGroup() {
        let store = makeIsolatedStore()
        let group = makeGroup(botIds: [store.bots[0].id])
        store.addGroup(group)
        let viewModel = ChatViewModel(store: store)

        viewModel.inputText = "borrador bot"

        store.selectGroup(id: group.id)
        XCTAssertEqual(viewModel.inputText, "")
        viewModel.inputText = "borrador grupo"

        store.selectBot(id: store.bots[0].id)
        XCTAssertEqual(viewModel.inputText, "borrador bot")

        store.selectGroup(id: group.id)
        XCTAssertEqual(viewModel.inputText, "borrador grupo")
    }

    func testRunningIndicatorWorksInGroups() {
        let store = makeIsolatedStore()
        let group = makeGroup(botIds: [store.bots[0].id])
        store.addGroup(group)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }
        let viewModel = ChatViewModel(store: store)
        store.selectGroup(id: group.id)

        viewModel.debugMarkRunning(conversationId: threadId, botName: store.bots[0].name)
        XCTAssertTrue(viewModel.isRunning)
        XCTAssertTrue(viewModel.isGroupRunning(group.id))
        XCTAssertFalse(viewModel.isBotRunning(store.bots[0].id))

        store.selectBot(id: store.bots[1].id)
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertTrue(viewModel.isGroupRunning(group.id))
    }

    func testDeleteGroupCancelsOnlyItsOwnRun() {
        let store = makeIsolatedStore()
        let group = makeGroup(botIds: [store.bots[0].id])
        store.addGroup(group)
        guard let groupThreadId = store.groupThread(for: group.id)?.id,
              let botThreadId = store.thread(for: store.bots[0].id)?.id
        else { return XCTFail("faltan hilos") }
        let viewModel = ChatViewModel(store: store)

        let groupToken = MuseRunToken()
        let botToken = MuseRunToken()
        viewModel.runTokens[groupThreadId] = groupToken
        viewModel.runTokens[botThreadId] = botToken

        viewModel.deleteGroup(id: group.id)

        XCTAssertTrue(groupToken.isCancelled)
        XCTAssertFalse(botToken.isCancelled)
        XCTAssertEqual(viewModel.conversation?.id, botThreadId)
    }

    // MARK: - Carpeta de trabajo

    func testEffectiveWorkspacePrefersGroup() {
        let bot = Bot(
            name: "A", specialty: "a", colorHex: "#0A84FF", systemPrompt: "p",
            workspacePath: "/tmp/bot"
        )
        var group = makeGroup(botIds: [bot.id])
        group.workspacePath = "/tmp/grupo"

        XCTAssertEqual(effectiveWorkspace(bot: bot, group: group), "/tmp/grupo")
        XCTAssertEqual(effectiveWorkspace(bot: bot, group: nil), "/tmp/bot")

        var noPath = makeGroup(botIds: [bot.id])
        noPath.workspacePath = ""
        XCTAssertEqual(effectiveWorkspace(bot: bot, group: noPath), "/tmp/bot")
    }
}
