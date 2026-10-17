import XCTest

@testable import Boty

/// Adjuntos + visión: detección de imágenes, límites, prompt, flags
/// `--image`, persistencia tolerante y viaje por la cola de envíos.
@MainActor
final class AttachmentTests: XCTestCase {
    private func makeIsolatedStore() -> BotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        return BotStore(storageDirectory: dir)
    }

    private func makeSourceFile(named name: String, contents: String = "hola") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotySrc-\(UUID().uuidString)-\(name)")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Detección y formato

    func testIsImageFilename() {
        XCTAssertTrue(isImageFilename("foto.png"))
        XCTAssertTrue(isImageFilename("FOTO.JPG"))
        XCTAssertTrue(isImageFilename("captura.heic"))
        XCTAssertTrue(isImageFilename("anim.webp"))
        XCTAssertFalse(isImageFilename("doc.pdf"))
        XCTAssertFalse(isImageFilename("notas.txt"))
        XCTAssertFalse(isImageFilename("sin-extension"))
        XCTAssertFalse(isImageFilename(""))
    }

    func testFormatAttachmentSize() {
        XCTAssertEqual(formatAttachmentSize(0), "0 B")
        XCTAssertEqual(formatAttachmentSize(512), "512 B")
        XCTAssertEqual(formatAttachmentSize(2048), "2 KB")
        XCTAssertEqual(formatAttachmentSize(1536), "1,5 KB")
        XCTAssertEqual(formatAttachmentSize(25 * 1024 * 1024), "25 MB")
    }

    func testValidateAttachmentCandidate() {
        XCTAssertNil(validateAttachmentCandidate(fileName: "a.png", byteSize: 100, currentCount: 0))
        XCTAssertNil(validateAttachmentCandidate(fileName: "e.png", byteSize: 100, currentCount: 4))
        let full = validateAttachmentCandidate(fileName: "f.png", byteSize: 100, currentCount: 5)
        XCTAssertTrue(full?.contains("5") ?? false)
        let big = validateAttachmentCandidate(
            fileName: "gordo.zip", byteSize: maxAttachmentBytes + 1, currentCount: 0
        )
        XCTAssertTrue(big?.contains("gordo.zip") ?? false)
    }

    // MARK: - Prompt y contexto

    func testAttachmentPromptBlock() {
        XCTAssertNil(attachmentPromptBlock([]))
        let attachments = [
            ChatAttachment(fileName: "foto.png", storedPath: "/datos/foto.png", byteSize: 10, isImage: true),
            ChatAttachment(fileName: "doc.pdf", storedPath: "/datos/doc.pdf", byteSize: 20, isImage: false),
        ]
        let block = attachmentPromptBlock(attachments)
        XCTAssertTrue(block?.contains("/datos/foto.png") ?? false)
        XCTAssertTrue(block?.contains("visión") ?? false)
        XCTAssertTrue(block?.contains("/datos/doc.pdf") ?? false)
        XCTAssertTrue(block?.contains("léelo con tus herramientas") ?? false)
    }

    func testAttachmentContextSuffix() {
        XCTAssertEqual(attachmentContextSuffix([]), "")
        let attachments = [
            ChatAttachment(fileName: "a.png", storedPath: "/a", byteSize: 1, isImage: true),
            ChatAttachment(fileName: "b.pdf", storedPath: "/b", byteSize: 2, isImage: false),
        ]
        XCTAssertEqual(attachmentContextSuffix(attachments), " [adjuntos: a.png, b.pdf]")
    }

    // MARK: - Flags de muse

    func testExecArgsIncludeImages() {
        let request = MuseRequest(
            sessionId: "s", prompt: "p", model: "", effort: "low",
            workspace: "/tmp", allowTools: true,
            imagePaths: ["/datos/a.png", "/datos/b.jpg"]
        )
        let args = museExecArgs(request: request, promptPath: "/tmp/p.txt")
        let images = args.indices.filter { args[$0] == "--image" }.map { args[$0 + 1] }
        XCTAssertEqual(images, ["/datos/a.png", "/datos/b.jpg"])
    }

    func testExecArgsWithoutImages() {
        let request = MuseRequest(
            sessionId: "s", prompt: "p", model: "", effort: "low",
            workspace: "/tmp", allowTools: true
        )
        XCTAssertFalse(museExecArgs(request: request, promptPath: "/tmp/p.txt").contains("--image"))
    }

    // MARK: - Persistencia tolerante

    func testChatMessageDecodesLegacyJSON() throws {
        // Hilos guardados antes de los adjuntos: sin `attachments`,
        // `toolNotes` ni `date`.
        let json = #"{"role":"user","text":"hola"}"#.data(using: .utf8)!
        let message = try JSONDecoder().decode(ChatMessage.self, from: json)
        XCTAssertEqual(message.text, "hola")
        XCTAssertTrue(message.attachments.isEmpty)
        XCTAssertTrue(message.toolNotes.isEmpty)
    }

    func testChatMessageRoundTripsAttachments() throws {
        let attachment = ChatAttachment(
            fileName: "a.png", storedPath: "/datos/a.png", byteSize: 3, isImage: true
        )
        let message = ChatMessage(role: "user", text: "mira", attachments: [attachment])
        let decoded = try JSONDecoder().decode(
            ChatMessage.self, from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded.attachments, [attachment])
    }

    // MARK: - Almacenamiento

    func testUniqueDestinationNumbersCollisions() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! "x".write(to: dir.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            uniqueAttachmentDestination(in: dir, fileName: "b.png").lastPathComponent, "b.png"
        )
        XCTAssertEqual(
            uniqueAttachmentDestination(in: dir, fileName: "a.png").lastPathComponent, "a 2.png"
        )
    }

    func testCopyAttachmentCopiesContent() throws {
        let store = makeIsolatedStore()
        let conversationId = store.activeConversation!.id
        let source = makeSourceFile(named: "nota.txt", contents: "contenido")
        let attachment = try copyAttachment(
            from: source, storageDir: store.dataDir, conversationId: conversationId
        )
        XCTAssertEqual(attachment.fileName, source.lastPathComponent)
        XCTAssertFalse(attachment.isImage)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: attachment.storedPath)), "contenido")
        // Segunda copia del mismo nombre no sobrescribe.
        let again = try copyAttachment(
            from: source, storageDir: store.dataDir, conversationId: conversationId
        )
        XCTAssertNotEqual(again.storedPath, attachment.storedPath)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: again.storedPath)), "contenido")
    }

    func testSweepRemovesOnlyUnreferenced() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let kept = root.appendingPathComponent("keep.png")
        let dropped = root.appendingPathComponent("drop.png")
        try! "k".write(to: kept, atomically: true, encoding: .utf8)
        try! "d".write(to: dropped, atomically: true, encoding: .utf8)
        let removed = sweepUnreferencedAttachments(root: root, referencedPaths: [kept.path])
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path))
    }

    // MARK: - Envío con adjuntos

    func testAddAndRemovePending() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let conversationId = store.activeConversation!.id
        let source = makeSourceFile(named: "foto.png")

        viewModel.addAttachments(from: [source], conversationId: conversationId)
        XCTAssertEqual(viewModel.pending(for: conversationId).count, 1)
        XCTAssertNil(viewModel.attachmentError)

        let stored = viewModel.pending(for: conversationId)[0].storedPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored))
        viewModel.removePendingAttachment(
            viewModel.pending(for: conversationId)[0].id, conversationId: conversationId
        )
        XCTAssertTrue(viewModel.pending(for: conversationId).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored))
    }

    func testAddAttachmentRejectsDirectory() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let conversationId = store.activeConversation!.id
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotyTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        viewModel.addAttachments(from: [dir], conversationId: conversationId)
        XCTAssertTrue(viewModel.pending(for: conversationId).isEmpty)
        XCTAssertTrue(viewModel.attachmentError?.contains("carpeta") ?? false)
    }

    func testSendWithAttachmentsOnlyDispatches() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let conversationId = store.activeConversation!.id
        var chained: [String] = []
        viewModel.chainHook = { _, _, text in chained.append(text) }

        // Texto vacío + adjunto: se envía igual (ver sufijo en el trigger).
        viewModel.addAttachments(from: [makeSourceFile(named: "foto.png")], conversationId: conversationId)
        viewModel.inputText = "  "
        viewModel.send()

        let sent = store.activeConversation?.messages.last { $0.role == "user" }
        XCTAssertEqual(sent?.attachments.count, 1)
        XCTAssertEqual(chained, [" [adjuntos: \(sent!.attachments[0].fileName)]"])
        XCTAssertTrue(viewModel.pending(for: conversationId).isEmpty)
    }

    func testSendEmptyWithoutAttachmentsDoesNothing() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        var chained = 0
        viewModel.chainHook = { _, _, _ in chained += 1 }
        viewModel.inputText = "  "
        viewModel.send()
        XCTAssertEqual(chained, 0)
        XCTAssertFalse(store.activeConversation?.messages.contains { $0.role == "user" } ?? true)
    }

    func testQueuedSendKeepsAttachments() {
        let store = makeIsolatedStore()
        let viewModel = ChatViewModel(store: store)
        let conversationId = store.activeConversation!.id
        var chained: [String] = []
        viewModel.chainHook = { _, _, text in chained.append(text) }

        viewModel.addAttachments(from: [makeSourceFile(named: "a.png")], conversationId: conversationId)
        viewModel.debugMarkRunning(conversationId: conversationId, botName: "Asistente")
        viewModel.inputText = "mira esto"
        viewModel.send()

        // En cola con sus adjuntos; al drenar viajan en el trigger.
        XCTAssertEqual(viewModel.queuedMessages(for: conversationId), ["mira esto"])
        XCTAssertEqual(viewModel.queuedSends[conversationId]?.first?.attachments.count, 1)
        viewModel.debugClearRunning(conversationId: conversationId)
        viewModel.drainQueue(conversationId: conversationId)
        XCTAssertEqual(chained.count, 1)
        XCTAssertTrue(chained[0].hasPrefix("mira esto [adjuntos: "))
    }

    func testClearThreadRemovesAttachments() {
        let store = makeIsolatedStore()
        let bot = store.bots[0]
        let conversationId = store.thread(for: bot.id)!.id
        let attachment = try! copyAttachment(
            from: makeSourceFile(named: "a.png"),
            storageDir: store.dataDir, conversationId: conversationId
        )
        store.appendMessage(
            ChatMessage(role: "user", text: "x", attachments: [attachment]),
            conversationId: conversationId
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.storedPath))
        store.clearThread(botId: bot.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.storedPath))
    }
}
