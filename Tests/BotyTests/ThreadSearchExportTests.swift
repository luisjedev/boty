import XCTest

@testable import Boty

/// Buscar en chats y exportar a Markdown: funciones puras de
/// `ThreadSearchExport.swift` (cierre de la mejora #3).
final class ThreadSearchExportTests: XCTestCase {
    private let bot = Bot(
        name: "Coder", specialty: "Programa", colorHex: "#30D158", systemPrompt: "p"
    )

    private func thread(
        title: String = "Hilo",
        messages: [ChatMessage],
        botId: UUID? = nil
    ) -> Conversation {
        Conversation(
            botId: botId ?? bot.id, title: title, messages: messages
        )
    }

    private func user(_ text: String, date: Date = Date()) -> ChatMessage {
        ChatMessage(role: "user", text: text, date: date)
    }

    private func botMsg(_ text: String, date: Date = Date()) -> ChatMessage {
        ChatMessage(role: "bot", botId: bot.id, botName: bot.name, text: text, date: date)
    }

    // MARK: - searchThreads: consulta mínima

    func testBlankOrSingleCharQueryReturnsEmpty() {
        let conversations = [thread(messages: [user("hola mundo")])]
        XCTAssertTrue(searchThreads(query: "", conversations: conversations, bots: [bot]).isEmpty)
        XCTAssertTrue(searchThreads(query: "   ", conversations: conversations, bots: [bot]).isEmpty)
        XCTAssertTrue(searchThreads(query: "a", conversations: conversations, bots: [bot]).isEmpty)
    }

    // MARK: - Insensible a mayúsculas y tildes

    func testSearchIsCaseInsensitive() {
        let conversations = [thread(messages: [user("Hola MUNDO")])]
        let results = searchThreads(query: "mundo", conversations: conversations, bots: [bot])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].authorLabel, "Tú")
    }

    func testSearchIgnoresDiacritics() {
        let conversations = [thread(messages: [user("el camión llegó")])]
        XCTAssertEqual(
            searchThreads(query: "camion", conversations: conversations, bots: [bot]).count, 1
        )
        let reverse = [thread(messages: [user("el camion llego")])]
        XCTAssertEqual(
            searchThreads(query: "camión", conversations: reverse, bots: [bot]).count, 1
        )
    }

    // MARK: - Ignora sistema y marcadores

    func testSearchSkipsSystemMessages() {
        let conversations = [thread(messages: [
            ChatMessage(role: "system", text: "El elefante saluda al inicio"),
            user("otra cosa"),
        ])]
        XCTAssertTrue(
            searchThreads(query: "elefante", conversations: conversations, bots: [bot]).isEmpty
        )
    }

    func testSearchSkipsTypingPlaceholder() {
        let conversations = [thread(messages: [
            ChatMessage(role: "bot", botId: bot.id, botName: bot.name, text: "…"),
            botMsg("respuesta sobre el elefante"),
        ])]
        let results = searchThreads(query: "elefante", conversations: conversations, bots: [bot])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].snippet, "respuesta sobre el elefante")
    }

    // MARK: - Orden y límite

    func testSearchOrdersRecentFirst() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let conversations = [
            thread(title: "Viejo", messages: [user("palabra rara aquí", date: old)]),
            thread(title: "Nuevo", messages: [user("palabra rara allá", date: new)]),
        ]
        let results = searchThreads(query: "rara", conversations: conversations, bots: [bot])
        XCTAssertEqual(results.map(\.threadTitle), ["Nuevo", "Viejo"])
    }

    func testSearchRespectsLimit() {
        let conversations = (0..<55).map { i in
            thread(title: "Hilo \(i)", messages: [user("mensaje común número \(i)")])
        }
        XCTAssertEqual(
            searchThreads(query: "común", conversations: conversations, bots: [bot]).count, 50
        )
        XCTAssertEqual(
            searchThreads(query: "común", conversations: conversations, bots: [bot], limit: 5).count,
            5
        )
    }

    // MARK: - searchSnippet

    func testShortSnippetHasNoEllipsis() {
        XCTAssertEqual(searchSnippet("hola mundo", centeredAt: 0, matchLength: 4), "hola mundo")
    }

    func testLongSnippetTruncatesBothSides() {
        let text = String(repeating: "a", count: 100) + " objetivo " + String(repeating: "b", count: 100)
        let snippet = searchSnippet(text, centeredAt: 100, matchLength: 8)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("objetivo"))
        XCTAssertLessThan(snippet.count, text.count)
    }

    // MARK: - threadMarkdown

    func testMarkdownHasHeaderMessagesAndAttachments() {
        let attachment = ChatAttachment(
            fileName: "foto.png", storedPath: "/tmp/foto.png", byteSize: 10, isImage: true
        )
        let conversation = thread(title: "Diseño API", messages: [
            ChatMessage(role: "system", text: "saludo"),
            ChatMessage(role: "user", text: "revisa esto", attachments: [attachment]),
            ChatMessage(
                role: "bot", botId: bot.id, botName: bot.name, text: "se ve bien",
                toolNotes: ["nota de herramienta"]
            ),
        ])
        let markdown = threadMarkdown(conversation, ownerName: "Coder")

        XCTAssertTrue(markdown.hasPrefix("# Diseño API\n"))
        XCTAssertTrue(markdown.contains("Hilo de Coder · 2 mensajes"))
        XCTAssertTrue(markdown.contains("## Tú ·"))
        XCTAssertTrue(markdown.contains("revisa esto"))
        XCTAssertTrue(markdown.contains("Adjuntos: foto.png"))
        XCTAssertTrue(markdown.contains("## Coder ·"))
        XCTAssertTrue(markdown.contains("> nota de herramienta"))
        XCTAssertFalse(markdown.contains("saludo"))
    }

    // MARK: - threadExportFilename

    func testExportFilenameIsSafe() {
        XCTAssertEqual(threadExportFilename(title: "Mi hilo"), "Mi-hilo.md")
        XCTAssertEqual(threadExportFilename(title: "a/b:c"), "a-b-c.md")
        XCTAssertEqual(threadExportFilename(title: "   "), "hilo.md")
        XCTAssertTrue(threadExportFilename(title: "Diseño API").hasSuffix(".md"))
    }

    // MARK: - threadOwnerName

    func testOwnerNameResolvesBotGroupAndFallback() {
        let group = BotGroup(name: "Equipo", botIds: [bot.id])
        XCTAssertEqual(
            threadOwnerName(thread(messages: []), bots: [bot]), "Coder"
        )
        XCTAssertEqual(
            threadOwnerName(
                Conversation(groupId: group.id, title: "T"), bots: [bot], groups: [group]
            ),
            "Equipo"
        )
        XCTAssertEqual(
            threadOwnerName(
                Conversation(botId: UUID(), title: "Perdido"), bots: [bot]
            ),
            "Perdido"
        )
    }
}
