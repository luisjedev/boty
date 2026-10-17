import XCTest

@testable import Boty

/// Enrutador oculto de grupos: con varios miembros y sin @menciones, un
/// mediador invisible elige quién responde a cada mensaje.
@MainActor
final class GroupRouterTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    private func makeMembers() -> [Bot] {
        [
            Bot(name: "Coder", specialty: "programa", colorHex: "#0A84FF", systemPrompt: "Escribe código."),
            Bot(name: "Revisor Jefe", specialty: "revisa", colorHex: "#0A84FF", systemPrompt: "Revisa código."),
        ]
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

    // MARK: - Parseo de la decisión

    func testResolveReturnsFirstValidBotOnly() {
        let members = makeMembers()
        // Aunque el modelo devuelva varios, el orquestador da un bot como
        // máximo: el primer nombre válido (los desconocidos y vacíos se saltan).
        let resolved = resolveRoutedBots(
            from: #"{"responder": ["", "Desconocido", "Revisor Jefe", "coder", "Coder"]}"#,
            members: members
        )
        XCTAssertEqual(resolved.map(\.name), ["Revisor Jefe"])
    }

    func testResolveToleratesFencesAndKeyVariants() {
        let members = makeMembers()
        XCTAssertEqual(
            resolveRoutedBots(from: "```json\n{\"responder\": [\"Coder\"]}\n```", members: members).map(\.id),
            [members[0].id]
        )
        XCTAssertEqual(
            resolveRoutedBots(from: #"{"responders": ["Coder"]}"#, members: members).map(\.id),
            [members[0].id]
        )
        XCTAssertEqual(
            resolveRoutedBots(from: #"Texto previo {"responder": "Coder"} texto posterior"#, members: members).map(\.id),
            [members[0].id]
        )
        // Primera palabra del nombre también vale.
        XCTAssertEqual(
            resolveRoutedBots(from: #"{"responder": ["Revisor"]}"#, members: members).map(\.id),
            [members[1].id]
        )
    }

    func testResolveReturnsEmptyOnGarbage() {
        let members = makeMembers()
        XCTAssertTrue(resolveRoutedBots(from: "no sé quién debe responder", members: members).isEmpty)
        XCTAssertTrue(resolveRoutedBots(from: #"{"responder": []}"#, members: members).isEmpty)
        XCTAssertTrue(resolveRoutedBots(from: #"{"otro": 1}"#, members: members).isEmpty)
        XCTAssertTrue(resolveRoutedBots(from: "", members: members).isEmpty)
    }

    // MARK: - Prompt del enrutador

    func testRouterPromptIncludesGoalMembersAndMessage() {
        let members = makeMembers()
        let group = BotGroup(name: "Equipo", goal: "hacer la web", botIds: members.map(\.id))
        let prompt = routerPrompt(
            group: group, members: members, triggerText: "¿quién revisa esto?", context: "[Usuario]: hola"
        )
        XCTAssertTrue(prompt.contains("Equipo"))
        XCTAssertTrue(prompt.contains("hacer la web"))
        XCTAssertTrue(prompt.contains("Coder"))
        XCTAssertTrue(prompt.contains("Revisor Jefe"))
        XCTAssertTrue(prompt.contains("Escribe código."))
        XCTAssertTrue(prompt.contains("¿quién revisa esto?"))
        XCTAssertTrue(prompt.contains("[Usuario]: hola"))
        XCTAssertTrue(prompt.contains("responder"))
    }

    func testRouterPromptAsksForSingleBot() {
        let members = makeMembers()
        let group = BotGroup(name: "Equipo", goal: "hacer la web", botIds: members.map(\.id))
        let prompt = routerPrompt(
            group: group, members: members, triggerText: "hola", context: ""
        )
        XCTAssertTrue(prompt.contains("UN solo miembro"))
        XCTAssertTrue(prompt.contains(#"{"responder": "Nombre"}"#))
        XCTAssertFalse(prompt.contains("incluye a todos"))
    }

    // MARK: - Ajuste

    func testRouterEffortIsMinimalWithoutDisabling() {
        // El orquestador usa el razonamiento más bajo sin desactivarlo:
        // el primer tier por encima de `none` en Bot.efforts.
        XCTAssertEqual(routerEffort, "minimal")
        XCTAssertNotEqual(routerEffort, "none")
        let tiers = Bot.efforts
        XCTAssertEqual(tiers.firstIndex(of: routerEffort), (tiers.firstIndex(of: "none") ?? -1) + 1)
    }

    func testAutoRouteDefaultsTrueAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(legacy.autoRouteGroups)

        var settings = AppSettings()
        settings.autoRouteGroups = false
        let data = try JSONEncoder().encode(settings)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: data).autoRouteGroups)
    }

    func testRouterSessionIsStablePerThread() {
        let store = makeIsolatedStore()
        guard let threadId = store.activeConversation?.id else {
            return XCTFail("falta la conversación activa")
        }
        let first = store.ensureSession(key: "router:grupo-1", conversationId: threadId)
        let second = store.ensureSession(key: "router:grupo-1", conversationId: threadId)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, store.ensureSession(key: "router:grupo-2", conversationId: threadId))
    }

    // MARK: - Flujo de envío

    /// El enrutador elige un único miembro. Usa texto simulado y el gancho
    /// de cadena para no lanzar ningún `muse` real.
    func testRoutedSendTargetsChosenMembers() async {
        let store = makeIsolatedStore()
        let group = BotGroup(name: "Equipo", botIds: [store.bots[0].id, store.bots[1].id])
        store.addGroup(group)
        let viewModel = ChatViewModel(store: store)
        viewModel.routerTextOverride = #"{"responder": ["\#(store.bots[1].name)"]}"#
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }
        store.selectGroup(id: group.id)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }

        viewModel.inputText = "hola"
        viewModel.send()

        let resolved = await waitForChain { !chained.isEmpty }
        XCTAssertTrue(resolved)
        XCTAssertEqual(chained.first?.conversationId, threadId)
        XCTAssertEqual(chained.first?.targets.map(\.id), [store.bots[1].id])
        XCTAssertEqual(chained.first?.text, "hola")
    }

    /// Aunque el modelo devuelva varios nombres, el orquestador responde con
    /// un bot como máximo: el primero válido.
    func testRoutedSendWithSeveralNamesTargetsFirstOnly() async {
        let store = makeIsolatedStore()
        let group = BotGroup(name: "Equipo", botIds: [store.bots[0].id, store.bots[1].id])
        store.addGroup(group)
        let viewModel = ChatViewModel(store: store)
        viewModel.routerTextOverride = #"{"responder": ["\#(store.bots[1].name)", "\#(store.bots[0].name)"]}"#
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }
        store.selectGroup(id: group.id)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }

        viewModel.inputText = "hola"
        viewModel.send()

        let resolved = await waitForChain { !chained.isEmpty }
        XCTAssertTrue(resolved)
        XCTAssertEqual(chained.first?.conversationId, threadId)
        XCTAssertEqual(chained.first?.targets.map(\.id), [store.bots[1].id])
        XCTAssertEqual(chained.first?.text, "hola")
    }

    /// Con un solo miembro no hay nada que decidir: va directo, sin tarea.
    func testSingleMemberGroupSkipsRouter() {
        let store = makeIsolatedStore()
        let group = BotGroup(name: "Solo", botIds: [store.bots[0].id])
        store.addGroup(group)
        let viewModel = ChatViewModel(store: store)
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }
        store.selectGroup(id: group.id)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }

        viewModel.inputText = "hola"
        viewModel.send()

        XCTAssertEqual(chained.count, 1)
        XCTAssertEqual(chained.first?.conversationId, threadId)
        XCTAssertEqual(chained.first?.targets.map(\.id), [store.bots[0].id])
        XCTAssertNil(viewModel.routeTasks[threadId])
    }

    /// Con el ajuste apagado responden todos, sin tarea de enrutado.
    func testDisabledSettingTargetsAllMembers() {
        let store = makeIsolatedStore()
        store.settings.autoRouteGroups = false
        let group = BotGroup(name: "Equipo", botIds: [store.bots[0].id, store.bots[1].id])
        store.addGroup(group)
        let viewModel = ChatViewModel(store: store)
        var chained: [(conversationId: UUID, targets: [Bot], text: String)] = []
        viewModel.chainHook = { chained.append(($0, $1, $2)) }
        store.selectGroup(id: group.id)
        guard let threadId = store.groupThread(for: group.id)?.id else {
            return XCTFail("falta el hilo del grupo")
        }

        viewModel.inputText = "hola"
        viewModel.send()

        XCTAssertEqual(chained.count, 1)
        XCTAssertEqual(chained.first?.conversationId, threadId)
        XCTAssertEqual(
            chained.first?.targets.map(\.id),
            [store.bots[0].id, store.bots[1].id]
        )
        XCTAssertNil(viewModel.routeTasks[threadId])
    }
}
