import Combine
import Foundation

@MainActor
final class BotStore: ObservableObject {
    @Published var bots: [Bot] = []
    @Published var groups: [BotGroup] = []
    /// Hilos de chat, N por bot y N por grupo (hilos múltiples). Cada bot y
    /// cada grupo tiene siempre al menos un hilo.
    @Published var conversations: [Conversation] = []
    @Published var settings = AppSettings()
    @Published var activeBotId: UUID?
    @Published var activeGroupId: UUID?
    /// Hilo activo por dueño (bot o grupo): clave `ownerId.uuidString` →
    /// valor `conversationId.uuidString`. Ausencia = primer hilo del dueño.
    @Published var activeThreadIds: [String: String] = [:]

    private let storageOverride: URL?

    private var storageDir: URL {
        if let storageOverride { return storageOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Boty", isDirectory: true)
    }

    init(storageDirectory: URL? = nil) {
        self.storageOverride = storageDirectory
        if storageDirectory == nil {
            migrateLegacyStorageIfNeeded()
        }
        load()
    }

    /// Migración única del renombrado MuseBots → Boty: mueve la carpeta
    /// de datos anterior a la nueva si esta aún no existe.
    private func migrateLegacyStorageIfNeeded() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacy = base.appendingPathComponent("MuseBots", isDirectory: true)
        let current = base.appendingPathComponent("Boty", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: current)
        } catch {
            print("Boty: no se pudo migrar la carpeta de datos anterior: \(error)")
        }
    }

    var activeConversation: Conversation? {
        if let group = activeGroup {
            return activeGroupThread(for: group.id)
        }
        guard let bot = activeBot else { return nil }
        return activeThread(for: bot.id)
    }

    /// Hilo activo de un bot (el que ve el chat). Históricamente `thread(for:)`
    /// era EL hilo del bot; con hilos múltiples es el activo de entre los N.
    func thread(for botId: UUID) -> Conversation? {
        activeThread(for: botId)
    }

    /// Hilo activo de un grupo, análogo al de bot.
    func groupThread(for groupId: UUID) -> Conversation? {
        activeGroupThread(for: groupId)
    }

    /// Todos los hilos de un bot, en orden de creación.
    func threads(for botId: UUID) -> [Conversation] {
        conversations.filter { $0.botId == botId }
    }

    /// Todos los hilos de un grupo, en orden de creación.
    func groupThreads(for groupId: UUID) -> [Conversation] {
        conversations.filter { $0.groupId == groupId }
    }

    /// Dueño (bot o grupo) de una conversación, si existe.
    func ownerId(of conversation: Conversation) -> UUID? {
        conversation.groupId ?? conversation.botId
    }

    /// Hilo activo de un bot, resolviendo el mapeo o el primero como
    /// fallback (migración: el hilo único anterior queda como activo).
    func activeThread(for botId: UUID) -> Conversation? {
        let own = threads(for: botId)
        guard !own.isEmpty else { return nil }
        if let activeId = activeThreadIds[botId.uuidString],
           let match = own.first(where: { $0.id.uuidString == activeId })
        {
            return match
        }
        return own.first
    }

    /// Hilo activo de un grupo, análogo al de bot.
    func activeGroupThread(for groupId: UUID) -> Conversation? {
        let own = groupThreads(for: groupId)
        guard !own.isEmpty else { return nil }
        if let activeId = activeThreadIds[groupId.uuidString],
           let match = own.first(where: { $0.id.uuidString == activeId })
        {
            return match
        }
        return own.first
    }

    /// Marca un hilo como activo para su dueño (bot o grupo).
    func selectThread(id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }),
              let owner = ownerId(of: conversation)
        else { return }
        activeThreadIds[owner.uuidString] = id.uuidString
        save()
    }

    var activeBot: Bot? {
        if activeGroup != nil { return nil }
        return bots.first { $0.id == activeBotId } ?? bots.first
    }

    var activeGroup: BotGroup? {
        groups.first { $0.id == activeGroupId }
    }

    /// Selección del sidebar. El orden de asignación importa: fijar primero
    /// el destino hace que la conversación activa sea correcta en cada aviso
    /// intermedio que recibe el ChatViewModel.
    func selectBot(id: UUID) {
        activeBotId = id
        activeGroupId = nil
    }

    func selectGroup(id: UUID) {
        activeGroupId = id
        activeBotId = nil
    }

    /// Miembros existentes de un grupo, en el orden de su lista.
    func members(of group: BotGroup) -> [Bot] {
        group.botIds.compactMap { botId in bots.first { $0.id == botId } }
    }

    func memberNames(for group: BotGroup) -> [String] {
        members(of: group).map(\.name)
    }

    func botColorHex(for botId: UUID?) -> String {
        bots.first { $0.id == botId }?.colorHex ?? "#0A84FF"
    }

    func botName(for botId: UUID?) -> String {
        bots.first { $0.id == botId }?.name ?? "Bot"
    }

    // MARK: - Bots

    func addBot(_ bot: Bot) {
        bots.append(bot)
        conversations.append(makeThread(for: bot))
        if activeBotId == nil { activeBotId = bot.id }
        save()
    }

    func updateBot(_ bot: Bot) {
        if let index = bots.firstIndex(where: { $0.id == bot.id }) {
            let oldName = bots[index].name
            bots[index] = bot
            // Con hilos múltiples los títulos son propios de cada hilo: solo
            // se actualizan los que aún llevan el nombre anterior (el primer
            // hilo migrado y los no renombrados), sin pisar renombres.
            for threadIndex in conversations.indices where conversations[threadIndex].botId == bot.id {
                if conversations[threadIndex].title == oldName {
                    conversations[threadIndex].title = bot.name
                }
            }
            save()
        }
    }

    func deleteBot(id: UUID) {
        let threadIds = conversations.filter { $0.botId == id }.map(\.id)
        bots.removeAll { $0.id == id }
        conversations.removeAll { $0.botId == id }
        activeThreadIds.removeValue(forKey: id.uuidString)
        for index in groups.indices {
            groups[index].botIds.removeAll { $0 == id }
        }
        if activeBotId == id { activeBotId = bots.first?.id }
        for threadId in threadIds { removeAttachments(conversationId: threadId) }
        save()
    }

    // MARK: - Groups

    func addGroup(_ group: BotGroup) {
        groups.append(group)
        conversations.append(makeGroupThread(for: group, memberNames: memberNames(for: group)))
        if activeBotId == nil, activeGroupId == nil { activeGroupId = group.id }
        save()
    }

    func updateGroup(_ group: BotGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            let oldName = groups[index].name
            groups[index] = group
            for threadIndex in conversations.indices where conversations[threadIndex].groupId == group.id {
                if conversations[threadIndex].title == oldName {
                    conversations[threadIndex].title = group.name
                }
            }
            save()
        }
    }

    func deleteGroup(id: UUID) {
        let threadIds = conversations.filter { $0.groupId == id }.map(\.id)
        groups.removeAll { $0.id == id }
        conversations.removeAll { $0.groupId == id }
        activeThreadIds.removeValue(forKey: id.uuidString)
        if activeGroupId == id {
            activeBotId = bots.first?.id
            activeGroupId = nil
        }
        for threadId in threadIds { removeAttachments(conversationId: threadId) }
        save()
    }

    // MARK: - Threads (N por bot y N por grupo)

    /// Crea un hilo nuevo para un bot y lo deja activo. El título por
    /// defecto numera a partir del nombre del bot ("Asistente 2"…).
    @discardableResult
    func createThread(botId: UUID) -> Conversation? {
        guard bots.contains(where: { $0.id == botId }) else { return nil }
        let name = bots.first(where: { $0.id == botId })?.name ?? "Hilo"
        let count = threads(for: botId).count
        let title = count > 0 ? "\(name) \(count + 1)" : name
        let thread = Conversation(
            botId: botId,
            title: title,
            messages: [ChatMessage(role: "system", text: threadGreeting(botName: name))]
        )
        conversations.append(thread)
        activeThreadIds[botId.uuidString] = thread.id.uuidString
        save()
        return thread
    }

    /// Crea un hilo nuevo para un grupo y lo deja activo.
    @discardableResult
    func createGroupThread(groupId: UUID) -> Conversation? {
        guard let group = groups.first(where: { $0.id == groupId }) else { return nil }
        var thread = makeGroupThread(for: group, memberNames: memberNames(for: group))
        let count = groupThreads(for: groupId).count
        if count > 0 { thread.title = "\(group.name) \(count + 1)" }
        conversations.append(thread)
        activeThreadIds[groupId.uuidString] = thread.id.uuidString
        save()
        return thread
    }

    /// Renombra un hilo. El título vacío o en blanco se ignora.
    func renameThread(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].title = trimmed
        conversations[index].date = Date()
        save()
    }

    /// Borra un hilo garantizando siempre al menos uno por dueño: si es el
    /// último, se vacía en su lugar (conserva el id y queda activo).
    func deleteThread(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let owner = ownerId(of: conversations[index])
        else { return }
        let siblings = conversations.filter {
            $0.id != id && (ownerId(of: $0) == owner)
        }
        if siblings.isEmpty {
            clearConversation(id: id)
            return
        }
        removeAttachments(conversationId: id)
        conversations.remove(at: index)
        if activeThreadIds[owner.uuidString] == id.uuidString {
            activeThreadIds[owner.uuidString] = siblings[0].id.uuidString
        }
        save()
    }

    /// Vacía un hilo concreto y reinicia sus sesiones, sin borrarlo.
    func clearConversation(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let botId = conversations[index].botId {
            let name = bots.first(where: { $0.id == botId })?.name ?? conversations[index].title
            conversations[index].messages = [ChatMessage(role: "system", text: threadGreeting(botName: name))]
        } else if let groupId = conversations[index].groupId {
            let group = groups.first { $0.id == groupId }
            let name = group?.name ?? conversations[index].title
            let names = group.map { memberNames(for: $0) } ?? []
            conversations[index].messages = [ChatMessage(role: "system", text: groupGreeting(groupName: name, memberNames: names))]
        } else {
            return
        }
        conversations[index].sessionIds = [:]
        conversations[index].introducedBots = []
        conversations[index].date = Date()
        removeAttachments(conversationId: conversations[index].id)
        save()
    }

    /// Vacía el hilo activo de un bot y reinicia sus sesiones, sin borrar el bot.
    func clearThread(botId: UUID) {
        guard let active = activeThread(for: botId) else { return }
        clearConversation(id: active.id)
    }

    /// Vacía el hilo activo de un grupo y reinicia sus sesiones, sin borrar el grupo.
    func clearGroupThread(groupId: UUID) {
        guard let active = activeGroupThread(for: groupId) else { return }
        clearConversation(id: active.id)
    }

    // MARK: - Adjuntos

    /// Carpeta de datos (inyectable en tests vía `storageDirectory`).
    var dataDir: URL { storageDir }

    /// Borra la carpeta de adjuntos de una conversación (vaciar/eliminar hilo).
    func removeAttachments(conversationId: UUID) {
        try? FileManager.default.removeItem(
            at: conversationAttachmentsDir(storageDir: storageDir, conversationId: conversationId)
        )
    }

    /// Barrido al arrancar: borra copias que ningún mensaje referencia
    /// (pendientes descartados, app cerrada antes de enviar…).
    func sweepUnreferencedAttachments() {
        let referenced = Set(conversations.flatMap(\.messages).flatMap(\.attachments).map(\.storedPath))
        Boty.sweepUnreferencedAttachments(root: attachmentsRoot(storageDir: storageDir), referencedPaths: referenced)
    }

    /// Con `persist: false` solo actualiza la vista, sin guardar en disco
    /// (para el marcador transitorio de "escribiendo…", que nunca debe
    /// sobrevivir a un reinicio como un spinner eterno).
    func appendMessage(_ message: ChatMessage, conversationId: UUID, persist: Bool = true) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[index].messages.append(message)
        conversations[index].date = Date()
        if persist { save() }
    }

    /// Sustituye el texto de un mensaje. Con `persist: false` solo actualiza
    /// la vista (para el streaming, que guarda una vez al terminar).
    func replaceMessage(
        id: UUID, conversationId: UUID, text: String, toolNotes: [String] = [], persist: Bool = true
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].messages[messageIndex].text = text
        conversations[index].messages[messageIndex].toolNotes = toolNotes
        if persist { save() }
    }

    func removeMessage(id: UUID, conversationId: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[index].messages.removeAll { $0.id == id }
        save()
    }

    // MARK: - Zoom de la escala de la app

    func zoomIn() {
        settings.zoomStep = clampedZoomStep(settings.zoomStep + 1)
        save()
    }

    func zoomOut() {
        settings.zoomStep = clampedZoomStep(settings.zoomStep - 1)
        save()
    }

    func zoomReset() {
        settings.zoomStep = 0
        save()
    }

    // MARK: - Muse sessions

    func ensureSession(botId: UUID, conversationId: UUID) -> String {
        ensureSession(key: botId.uuidString, conversationId: conversationId)
    }

    /// Sesión estable para una clave arbitraria dentro de un hilo (p. ej. el
    /// enrutador oculto de un grupo, que no es un bot).
    func ensureSession(key: String, conversationId: UUID) -> String {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else {
            return UUID().uuidString
        }
        if let existing = conversations[index].sessionIds[key] { return existing }
        let fresh = UUID().uuidString
        conversations[index].sessionIds[key] = fresh
        save()
        return fresh
    }

    func isIntroduced(botId: UUID, conversationId: UUID) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return false }
        return conversation.introducedBots.contains(botId.uuidString)
    }

    func markIntroduced(botId: UUID, conversationId: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        let key = botId.uuidString
        if !conversations[index].introducedBots.contains(key) {
            conversations[index].introducedBots.append(key)
            save()
        }
    }

    // MARK: - Persistence

    func save() {
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            try encoder.encode(bots).write(to: storageDir.appendingPathComponent("bots.json"))
            try encoder.encode(groups).write(to: storageDir.appendingPathComponent("groups.json"))
            try encoder.encode(conversations).write(to: storageDir.appendingPathComponent("conversations.json"))
            try encoder.encode(settings).write(to: storageDir.appendingPathComponent("settings.json"))
            try encoder.encode(activeThreadIds).write(to: storageDir.appendingPathComponent("activeThreads.json"))
        } catch {
            print("Boty: no se pudo guardar: \(error)")
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: storageDir.appendingPathComponent("bots.json")),
           let loaded = try? decoder.decode([Bot].self, from: data), !loaded.isEmpty
        {
            bots = loaded
        } else {
            bots = BotStore.seedBots()
        }
        if let data = try? Data(contentsOf: storageDir.appendingPathComponent("groups.json")),
           let loaded = try? decoder.decode([BotGroup].self, from: data)
        {
            groups = loaded
        }
        if let data = try? Data(contentsOf: storageDir.appendingPathComponent("conversations.json")),
           let loaded = try? decoder.decode([Conversation].self, from: data)
        {
            let legacy = loaded.filter { $0.botId == nil && $0.groupId == nil }
            if !legacy.isEmpty { backupLegacy(legacy) }
            conversations = loaded
        }
        if let data = try? Data(contentsOf: storageDir.appendingPathComponent("settings.json")),
           let loaded = try? decoder.decode(AppSettings.self, from: data)
        {
            settings = loaded
        }
        conversations = syncedThreads(bots: bots, groups: groups, conversations: conversations)
        // Limpieza de estados antiguos: un "escribiendo…" que quedó guardado
        // en disco (app cerrada en plena respuesta) sería un spinner eterno.
        conversations = conversations.map { conversation in
            var fixed = conversation
            fixed.messages.removeAll { $0.isTypingPlaceholder }
            return fixed
        }
        // Migración a hilos múltiples: el hilo único anterior se conserva tal
        // cual y queda como activo (fallback); solo se sanea el mapeo.
        if let data = try? Data(contentsOf: storageDir.appendingPathComponent("activeThreads.json")),
           let loaded = try? decoder.decode([String: String].self, from: data)
        {
            activeThreadIds = loaded
        }
        sanitizeActiveThreads()
        if activeBotId == nil { activeBotId = bots.first?.id }
        sweepUnreferencedAttachments()
        save()
    }

    /// Descarta entradas del mapeo de hilo activo que apunten a dueños o
    /// hilos que ya no existen (el fallback al primer hilo cubre el resto).
    private func sanitizeActiveThreads() {
        let validOwners = Set(bots.map(\.id.uuidString) + groups.map(\.id.uuidString))
        let validThreads = Set(conversations.map(\.id.uuidString))
        activeThreadIds = activeThreadIds.filter { validOwners.contains($0.key) && validThreads.contains($0.value) }
    }

    /// Guarda una copia de los hilos del formato antiguo (sin bot dueño)
    /// antes de empezar los hilos 1:1 por bot.
    private func backupLegacy(_ legacy: [Conversation]) {
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let url = storageDir.appendingPathComponent("conversations.legacy.json")
            if !FileManager.default.fileExists(atPath: url.path) {
                try JSONEncoder().encode(legacy).write(to: url)
            }
        } catch {
            print("Boty: no se pudo respaldar hilos antiguos: \(error)")
        }
    }

    static func seedBots() -> [Bot] {
        [
            Bot(
                name: "Asistente",
                specialty: "Ayuda general",
                colorHex: "#0A84FF",
                systemPrompt: "Eres un asistente general amable y directo. Respondes en español salvo que te pidan otro idioma. Si la pregunta es de programación, sugiere mencionar a @Coder.",
                effort: "low"
            ),
            Bot(
                name: "Coder",
                specialty: "Programa en Swift, Python y más",
                colorHex: "#30D158",
                systemPrompt: "Eres un programador senior. Escribes código limpio con ejemplos cortos y explicas solo lo necesario. Respondes en español. Si te piden revisar código ajeno en profundidad, sugiere mencionar a @Revisor.",
                effort: "medium"
            ),
            Bot(
                name: "Revisor",
                specialty: "Revisa código y propone mejoras",
                colorHex: "#FF9F0A",
                systemPrompt: "Eres un revisor de código estricto pero constructivo. Señalas errores, casos borde y mejoras concretas con ejemplos. Respondes en español.",
                effort: "medium"
            ),
        ]
    }
}
