import XCTest

@testable import Boty

/// Cadena de menciones sin límite de turnos: cada @mención continúa el hilo
/// aunque el bot ya haya hablado antes. La cadena solo termina cuando una
/// respuesta no menciona a nadie (o con Detener).
@MainActor
final class MentionChainTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    // MARK: - Continuación de la cadena

    func testContinuationInvokesFreshMentionsInOrder() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let coder = store.bots[1]
        let revisor = store.bots[2]

        let next = viewModel.chainContinuation(
            replyText: "Lo revisamos con @\(revisor.name) y luego sigue @\(coder.name).",
            speakerId: store.bots[0].id
        )

        XCTAssertEqual(next.map(\.id), [revisor.id, coder.id])
    }

    func testContinuationSkipsOnlySpeaker() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let asistente = store.bots[0]
        let coder = store.bots[1]
        let revisor = store.bots[2]

        // El autor se nombra a sí mismo: solo se excluye él, los demás
        // continúan aunque ya hayan hablado antes en esta cadena.
        let next = viewModel.chainContinuation(
            replyText: "Soy @\(coder.name): lo pulimos con @\(revisor.name), sigue @\(asistente.name).",
            speakerId: coder.id
        )

        XCTAssertEqual(next.map(\.id), [revisor.id, asistente.id])
    }

    func testContinuationReinvokesVisitedBots() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let asistente = store.bots[0]
        let coder = store.bots[1]

        // Regresión: A→B→A se cortaba porque A ya había hablado y el flujo
        // terminaba sin responder. Ahora el mencionado continúa siempre.
        let next = viewModel.chainContinuation(
            replyText: "Entendido, @\(asistente.name): lo pulimos juntos.",
            speakerId: coder.id
        )

        XCTAssertEqual(next.map(\.id), [asistente.id])
    }

    func testContinuationEndsWithoutMentions() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)

        // Sin @menciones el turno vuelve al usuario: así termina el trabajo.
        let next = viewModel.chainContinuation(
            replyText: "Trabajo terminado, sin más que añadir.",
            speakerId: store.bots[0].id
        )

        XCTAssertTrue(next.isEmpty)
    }

    // MARK: - Regla de menciones en prompts

    func testMentionRuleStatesInvocationOnly() {
        XCTAssertTrue(mentionHandoffRule.contains("@nombre"))
        XCTAssertTrue(mentionHandoffRule.contains("SOLO"))
        XCTAssertTrue(mentionHandoffRule.contains("SIN @"))
        XCTAssertTrue(mentionHandoffRule.contains("SIN mencionar"))
    }

    func testGroupContextListsMembersWithoutAtAndIncludesRule() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let group = BotGroup(name: "Equipo", goal: "hacer la web", botIds: [store.bots[0].id, store.bots[1].id])

        let context = viewModel.groupContext(group: group)

        XCTAssertTrue(context.contains(store.bots[0].name))
        XCTAssertFalse(context.contains("@" + store.bots[0].name))
        XCTAssertFalse(context.contains("@" + store.bots[1].name))
        XCTAssertTrue(context.contains(mentionHandoffRule))
    }

    func testGreetingsExplainInvocationOnly() {
        XCTAssertTrue(threadGreeting(botName: "Coder").contains("@nombre"))
        let group = groupGreeting(groupName: "Equipo", memberNames: ["Coder"])
        XCTAssertTrue(group.contains("@Coder"))
        XCTAssertTrue(group.contains("necesita que otro actúe"))
    }
}
