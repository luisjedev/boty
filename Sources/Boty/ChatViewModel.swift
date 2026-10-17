import AppKit
import Combine
import Foundation

/// Un envío en cola: el texto más los adjuntos que lo acompañan.
struct QueuedSend: Sendable {
    var text: String
    var attachments: [ChatAttachment] = []
}

@MainActor
final class ChatViewModel: ObservableObject {
    let store: BotStore
    @Published var inputText = ""
    @Published var isRunning = false
    @Published var runningBotName = ""
    @Published var runningHeadline = ""
    /// Inicio de la ejecución en curso (cronómetro de la cabecera).
    @Published var runningSince: Date?
    /// Último cambio del titular (el reloj muestra el tiempo sin novedades:
    /// si crece, el bot está atascado; si se renueva, avanza).
    @Published var runningActivityAt: Date?
    @Published var queuedCount = 0
    /// Salto pendiente a un mensaje tras una búsqueda: la vista lo desplaza
    /// y lo limpia. Se fija junto con la selección del hilo dueño.
    @Published var pendingJumpMessageId: UUID?

    // MARK: - Estado por conversación (los bots son totalmente independientes)

    /// Token de cancelación del proceso `muse` en curso, por conversación.
    var runTokens: [UUID: MuseRunToken] = [:]
    /// Tarea de la cadena de respuestas en curso, por conversación.
    var chainTasks: [UUID: Task<Void, Never>] = [:]
    /// Tarea del enrutador oculto de grupo en curso, por conversación.
    var routeTasks: [UUID: Task<Void, Never>] = [:]
    /// Gancho para tests: texto que devuelve el enrutador sin lanzar `muse`.
    var routerTextOverride: String?
    /// Gancho para tests: registra cada cadena lanzada (hilo, destinos y
    /// texto) sin ejecutar `muse`. Cuando está activo, `runChain` no crea
    /// tareas ni procesos; la cola se avanza a mano con `drainQueue`.
    var chainHook: ((UUID, [Bot], String) -> Void)?
    /// Reproductor del aviso de fin (`NSSound.beep` por defecto). Gancho
    /// para tests: contar avisos sin sonar.
    var soundPlayer: () -> Void = { NSSound.beep() }
    /// Nombre del bot que está respondiendo, por conversación. Presencia = en curso.
    var runningBotNames: [UUID: String] = [:]
    /// Titular de actividad en curso, por conversación: UN solo texto con la
    /// acción más reciente (se reemplaza, nunca se acumula). Lo alimenta
    /// `muse exec --json` en tiempo real (ver `onActivity` en `runBot`).
    var activityLines: [UUID: String] = [:]
    /// Inicio de la ejecución en curso, por conversación.
    var activityStartedAt: [UUID: Date] = [:]
    /// Último cambio del titular, por conversación.
    var activityUpdatedAt: [UUID: Date] = [:]
    /// Mensajes enviados mientras la conversación estaba ocupada, por
    /// conversación (FIFO). Se procesan al siguiente hueco: fin natural de
    /// la cadena de respuestas.
    var queuedSends: [UUID: [QueuedSend]] = [:]
    /// Borradores de texto, por conversación.
    var inputDrafts: [UUID: String] = [:]
    /// Adjuntos pendientes de enviar, por conversación. Ya están copiados a
    /// la carpeta de datos; se ligan al mensaje al pulsar Enviar.
    @Published var pendingAttachments: [UUID: [ChatAttachment]] = [:]
    /// Último error al adjuntar (transitorio, se muestra sobre el cajón).
    @Published var attachmentError: String?

    private var lastConversationId: UUID?
    private var isRestoringContext = false
    private var cancellables = Set<AnyCancellable>()

    init(store: BotStore) {
        self.store = store
        self.lastConversationId = store.activeConversation?.id
        // ChatView solo observa este view model: republicar los cambios del
        // store para que cabecera y mensajes sigan al bot seleccionado.
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Nota: el parámetro trae el valor nuevo; leer el id que cambia aquí
        // devolvería el anterior porque el aviso se emite antes de almacenar.
        // El otro id se lee del store: no cambia en ese aviso y sigue vigente.
        store.$activeBotId
            .sink { [weak self] newBotId in self?.switchActiveConversation(newBotId: newBotId) }
            .store(in: &cancellables)
        store.$activeGroupId
            .sink { [weak self] newGroupId in self?.switchActiveConversation(newGroupId: newGroupId) }
            .store(in: &cancellables)
        // Cambiar de hilo dentro del mismo bot/grupo no toca los ids de
        // selección: seguir el mapeo de hilo activo.
        store.$activeThreadIds
            .sink { [weak self] _ in self?.switchActiveConversation() }
            .store(in: &cancellables)
        // Persistir borradores de la conversación visible.
        $inputText
            .sink { [weak self] text in
                guard let self, !isRestoringContext, let id = lastConversationId else { return }
                inputDrafts[id] = text
            }
            .store(in: &cancellables)
        // Si un bot se elimina por otra vía (p. ej. desde el editor),
        // cancelar y podar su estado huérfano.
        store.$conversations
            .sink { [weak self] conversations in
                self?.pruneOrphanState(knownIds: Set(conversations.map(\.id)))
            }
            .store(in: &cancellables)
        refreshRunningState()
        refreshQueuedState()
    }

    var activeBot: Bot? { store.activeBot }
    var activeGroup: BotGroup? { store.activeGroup }
    var conversation: Conversation? { store.activeConversation }

    /// Grupo dueño de una conversación, si es un hilo de grupo.
    func group(for conversationId: UUID) -> BotGroup? {
        guard let conversation = store.conversations.first(where: { $0.id == conversationId }),
              let groupId = conversation.groupId
        else { return nil }
        return store.groups.first { $0.id == groupId }
    }

    // MARK: - Estado por conversación

    func isRunning(for conversationId: UUID) -> Bool {
        runningBotNames[conversationId] != nil
    }

    func runningName(for conversationId: UUID) -> String? {
        runningBotNames[conversationId]
    }

    /// Indica si algún hilo de un bot tiene una respuesta en curso.
    /// Sirve para el indicador del sidebar.
    func isBotRunning(_ botId: UUID) -> Bool {
        store.threads(for: botId).contains { isRunning(for: $0.id) }
    }

    /// Igual para los hilos de un grupo.
    func isGroupRunning(_ groupId: UUID) -> Bool {
        store.groupThreads(for: groupId).contains { isRunning(for: $0.id) }
    }

    /// Ganchos para tests: simulan una respuesta en curso sin lanzar `muse`.
    func debugMarkRunning(conversationId: UUID, botName: String) {
        runningBotNames[conversationId] = botName
        refreshRunningState()
    }

    func debugClearRunning(conversationId: UUID) {
        runningBotNames.removeValue(forKey: conversationId)
        refreshRunningState()
    }

    /// Guarda el borrador visible y carga el de la nueva conversación activa,
    /// actualizando Detener/alerta solo para ella.
    func switchActiveConversation() {
        switchTo(store.activeConversation?.id)
    }

    func switchActiveConversation(newBotId: UUID?) {
        // Misma resolución que `activeConversation`, pero con el id nuevo que
        // trae el aviso (el almacenado aún es el anterior).
        if let group = store.groups.first(where: { $0.id == store.activeGroupId }),
           let groupThread = store.activeGroupThread(for: group.id)
        {
            switchTo(groupThread.id)
            return
        }
        let bot = store.bots.first { $0.id == newBotId } ?? store.bots.first
        switchTo(bot.flatMap { store.activeThread(for: $0.id) }?.id)
    }

    func switchActiveConversation(newGroupId: UUID?) {
        if let group = store.groups.first(where: { $0.id == newGroupId }),
           let groupThread = store.activeGroupThread(for: group.id)
        {
            switchTo(groupThread.id)
            return
        }
        let bot = store.bots.first { $0.id == store.activeBotId } ?? store.bots.first
        switchTo(bot.flatMap { store.activeThread(for: $0.id) }?.id)
    }

    private func switchTo(_ newId: UUID?) {
        guard newId != lastConversationId else {
            refreshRunningState(conversationId: newId)
            refreshQueuedState(conversationId: newId)
            return
        }
        if let old = lastConversationId {
            inputDrafts[old] = inputText
        }
        lastConversationId = newId
        isRestoringContext = true
        defer { isRestoringContext = false }
        if let newId {
            inputText = inputDrafts[newId] ?? ""
        } else {
            inputText = ""
        }
        refreshRunningState(conversationId: newId)
        refreshQueuedState(conversationId: newId)
    }

    func refreshRunningState() {
        refreshRunningState(conversationId: store.activeConversation?.id)
    }

    func refreshRunningState(conversationId: UUID?) {
        guard let activeId = conversationId,
              let name = runningBotNames[activeId]
        else {
            isRunning = false
            runningBotName = ""
            runningHeadline = ""
            runningSince = nil
            runningActivityAt = nil
            return
        }
        isRunning = true
        runningBotName = name
        runningHeadline = activityLines[activeId] ?? ""
        runningSince = activityStartedAt[activeId]
        runningActivityAt = activityUpdatedAt[activeId]
    }

    /// Titular vigente de una conversación (cadena vacía = sin actividad).
    func headline(for conversationId: UUID) -> String {
        activityLines[conversationId] ?? ""
    }

    /// Reemplaza el titular de una conversación por el más reciente (o lo
    /// retira con `nil`). Refresca la cabecera si es la visible.
    func setActivity(conversationId: UUID, headline: String?) {
        if let headline, !headline.isEmpty {
            activityLines[conversationId] = headline
            activityUpdatedAt[conversationId] = Date()
        } else {
            activityLines.removeValue(forKey: conversationId)
            activityUpdatedAt.removeValue(forKey: conversationId)
        }
        refreshRunningState()
    }

    /// Mensajes en cola de una conversación (FIFO).
    func queuedMessages(for conversationId: UUID) -> [String] {
        queuedSends[conversationId]?.map(\.text) ?? []
    }

    /// Adjuntos pendientes de enviar en una conversación.
    func pending(for conversationId: UUID) -> [ChatAttachment] {
        pendingAttachments[conversationId] ?? []
    }

    /// Copia `urls` a la carpeta de adjuntos y los deja pendientes de envío
    /// en la conversación. Los errores se exponen en `attachmentError` sin
    /// bloquear los archivos válidos del mismo lote.
    func addAttachments(from urls: [URL], conversationId: UUID) {
        var current = pendingAttachments[conversationId] ?? []
        for url in urls {
            let name = url.lastPathComponent
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                attachmentError = "«\(name)» es una carpeta: adjunta archivos sueltos."
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if let error = validateAttachmentCandidate(fileName: name, byteSize: size, currentCount: current.count) {
                attachmentError = error
                continue
            }
            do {
                let attachment = try copyAttachment(
                    from: url, storageDir: store.dataDir, conversationId: conversationId
                )
                current.append(attachment)
            } catch {
                attachmentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        pendingAttachments[conversationId] = current
    }

    /// Retira un pendiente (y borra su copia, que aún no referencia ningún
    /// mensaje) sin tocar el resto.
    func removePendingAttachment(_ id: UUID, conversationId: UUID) {
        var current = pendingAttachments[conversationId] ?? []
        if let index = current.firstIndex(where: { $0.id == id }) {
            try? FileManager.default.removeItem(atPath: current[index].storedPath)
            current.remove(at: index)
        }
        pendingAttachments[conversationId] = current
    }

    func clearAttachmentError() {
        attachmentError = nil
    }

    func refreshQueuedState() {
        refreshQueuedState(conversationId: store.activeConversation?.id)
    }

    func refreshQueuedState(conversationId: UUID?) {
        guard let activeId = conversationId else {
            queuedCount = 0
            return
        }
        queuedCount = queuedSends[activeId]?.count ?? 0
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversation = store.activeConversation else { return }
        let conversationId = conversation.id
        let attachments = pendingAttachments[conversationId] ?? []
        // Vale enviar solo adjuntos (p. ej. una captura sin comentario).
        guard !text.isEmpty || !attachments.isEmpty else { return }

        inputText = ""
        pendingAttachments[conversationId] = []
        store.appendMessage(
            ChatMessage(role: "user", text: text, attachments: attachments),
            conversationId: conversationId
        )

        // Ocupada (respondiendo): el mensaje queda visible en el chat y en
        // cola hasta el siguiente hueco. Los agentes que respondan después lo
        // leerán en el contexto, y al terminar la cadena se procesará como
        // un turno propio.
        if isRunning(for: conversationId) {
            enqueue(conversationId: conversationId, text: text, attachments: attachments)
            return
        }
        // Libre pero con cola pendiente (p. ej. tras Detener): respetar el
        // orden FIFO — lo nuevo se encola y se lanza lo más antiguo.
        if !(queuedSends[conversationId]?.isEmpty ?? true) {
            enqueue(conversationId: conversationId, text: text, attachments: attachments)
            drainQueue(conversationId: conversationId)
            return
        }
        dispatch(conversationId: conversationId, text: text, attachments: attachments)
    }

    /// Procesa un mensaje de usuario ya añadido al hilo (menciones, enrutado
    /// de grupo o cadena directa). No lo añade: sirve al envío inmediato y a
    /// la cola por igual.
    private func dispatch(conversationId: UUID, text: String, attachments: [ChatAttachment] = []) {
        // Cada conversación tiene su propio estado: enviar en un bot no
        // bloquea ni muestra "Detener" en otro.
        var mentioned = botsMentioned(in: text)
        var routedGroup: BotGroup?
        if mentioned.isEmpty {
            let groupId = store.conversations.first { $0.id == conversationId }?.groupId
            if let groupId, let group = store.groups.first(where: { $0.id == groupId }) {
                let members = store.members(of: group)
                if store.settings.autoRouteGroups, members.count > 1 {
                    // Sin menciones y con varios miembros: el enrutador oculto
                    // elige quién responde (ver runRouted).
                    routedGroup = group
                } else {
                    mentioned = members
                }
            } else if let fallback = threadOwnerBot(conversationId: conversationId) {
                mentioned = [fallback]
            }
        }
        // El enrutador y los bots ven los nombres de los adjuntos; las rutas
        // y la visión viajan en el prompt y en `--image` (ver runBot).
        let triggerText = text + attachmentContextSuffix(attachments)
        if let routedGroup {
            runRouted(
                conversationId: conversationId, group: routedGroup,
                triggerText: triggerText, attachments: attachments
            )
            return
        }

        guard !mentioned.isEmpty else { return }
        runChain(
            conversationId: conversationId, targets: mentioned,
            triggerText: triggerText, attachments: attachments
        )
    }

    /// Bot dueño del hilo de una conversación (`nil` en hilos de grupo).
    /// La cola puede procesarse con otra conversación visible, así que el
    /// destinatario por defecto se resuelve por hilo, no por selección.
    private func threadOwnerBot(conversationId: UUID) -> Bot? {
        guard let botId = store.conversations.first(where: { $0.id == conversationId })?.botId else { return nil }
        return store.bots.first { $0.id == botId }
    }

    private func enqueue(conversationId: UUID, text: String, attachments: [ChatAttachment]) {
        queuedSends[conversationId, default: []].append(QueuedSend(text: text, attachments: attachments))
        refreshQueuedState()
    }

    /// Lanza el siguiente mensaje encolado, si lo hay y la conversación está
    /// libre. Devuelve `true` si arrancó más trabajo. Se llama al terminar
    /// una cadena de forma natural, al enviar en reposo con cola pendiente
    /// y con Reanudar.
    @discardableResult
    func drainQueue(conversationId: UUID) -> Bool {
        guard !isRunning(for: conversationId) else { return false }
        guard var queue = queuedSends[conversationId], !queue.isEmpty else { return false }
        guard store.conversations.contains(where: { $0.id == conversationId }) else {
            queuedSends.removeValue(forKey: conversationId)
            refreshQueuedState()
            return false
        }
        let next = queue.removeFirst()
        queuedSends[conversationId] = queue
        refreshQueuedState()
        dispatch(conversationId: conversationId, text: next.text, attachments: next.attachments)
        return true
    }

    /// Reanuda la cola visible. Tras Detener, la cola espera sin arrancar
    /// sola: Detener lo para todo.
    func resumeQueue() {
        guard let activeId = store.activeConversation?.id else { return }
        drainQueue(conversationId: activeId)
    }

    /// Descarta la cola visible. Los mensajes quedan en el chat como
    /// enviados, pero no generarán más respuestas.
    func clearQueue() {
        guard let activeId = store.activeConversation?.id else { return }
        clearQueue(conversationId: activeId)
    }

    func clearQueue(conversationId: UUID) {
        queuedSends.removeValue(forKey: conversationId)
        refreshQueuedState()
    }

    /// Detiene solo la respuesta de la conversación visible.
    func cancel() {
        guard let activeId = store.activeConversation?.id else { return }
        cancelConversation(activeId)
    }

    func cancelConversation(_ conversationId: UUID) {
        runTokens[conversationId]?.cancel()
        chainTasks[conversationId]?.cancel()
        routeTasks[conversationId]?.cancel()
    }

    /// Vacía un hilo concreto cancelando antes su respuesta en curso.
    func clearConversation(id: UUID) {
        cancelConversation(id)
        cleanupConversationState(id)
        store.clearConversation(id: id)
        refreshRunningState()
        refreshQueuedState()
    }

    /// Vacía el hilo de un bot cancelando antes su respuesta en curso.
    func clearThread(botId: UUID) {
        if let conversation = store.thread(for: botId) {
            cancelConversation(conversation.id)
            cleanupConversationState(conversation.id)
        }
        store.clearThread(botId: botId)
        refreshRunningState()
        refreshQueuedState()
    }

    /// Elimina un bot cancelando antes las respuestas en curso de TODOS sus hilos.
    func deleteBot(id: UUID) {
        for thread in store.threads(for: id) {
            cancelConversation(thread.id)
            cleanupConversationState(thread.id)
        }
        store.deleteBot(id: id)
        switchActiveConversation()
    }

    /// Vacía el hilo de un grupo cancelando antes su respuesta en curso.
    func clearGroupThread(groupId: UUID) {
        if let conversation = store.groupThread(for: groupId) {
            cancelConversation(conversation.id)
            cleanupConversationState(conversation.id)
        }
        store.clearGroupThread(groupId: groupId)
        refreshRunningState()
        refreshQueuedState()
    }

    /// Elimina un grupo cancelando antes las respuestas en curso de TODOS sus hilos.
    func deleteGroup(id: UUID) {
        for thread in store.groupThreads(for: id) {
            cancelConversation(thread.id)
            cleanupConversationState(thread.id)
        }
        store.deleteGroup(id: id)
        switchActiveConversation()
    }

    /// Borra un hilo cancelando antes su respuesta en curso y podando su
    /// estado. Garantiza la invariante de al menos un hilo por dueño (el
    /// store vacía el último en su lugar en vez de eliminarlo).
    func deleteThread(id: UUID) {
        cancelConversation(id)
        cleanupConversationState(id)
        store.deleteThread(id: id)
        switchActiveConversation()
    }

    // MARK: - Buscar y exportar (mejora #3)

    /// Salta a un mensaje de cualquier hilo: selecciona su dueño (bot o
    /// grupo) y su hilo, y deja el mensaje como salto pendiente para que la
    /// vista lo desplace. Sin efecto si el hilo o el mensaje no existen.
    func revealMessage(threadId: UUID, messageId: UUID) {
        guard let conversation = store.conversations.first(where: { $0.id == threadId }),
              conversation.messages.contains(where: { $0.id == messageId })
        else { return }
        if let botId = conversation.botId {
            store.selectBot(id: botId)
        } else if let groupId = conversation.groupId {
            store.selectGroup(id: groupId)
        }
        store.selectThread(id: threadId)
        pendingJumpMessageId = messageId
    }

    /// La vista limpia el salto una vez desplazado.
    func consumePendingJump() {
        pendingJumpMessageId = nil
    }

    /// Markdown del hilo indicado (o del activo) para exportar a archivo.
    func markdownForConversation(id: UUID? = nil) -> (title: String, markdown: String)? {
        let conversation = id.flatMap { wanted in store.conversations.first(where: { $0.id == wanted }) }
            ?? store.activeConversation
        guard let conversation else { return nil }
        let owner = threadOwnerName(conversation, bots: store.bots, groups: store.groups)
        return (conversation.title, threadMarkdown(conversation, ownerName: owner))
    }

    private func pruneOrphanState(knownIds: Set<UUID>) {
        let stale = Set(chainTasks.keys)
            .union(runTokens.keys)
            .union(routeTasks.keys)
            .union(runningBotNames.keys)
            .union(activityLines.keys)
            .union(activityStartedAt.keys)
            .union(activityUpdatedAt.keys)
            .union(queuedSends.keys)
            .union(pendingAttachments.keys)
            .subtracting(knownIds)
        guard !stale.isEmpty else { return }
        for id in stale {
            runTokens[id]?.cancel()
            chainTasks[id]?.cancel()
            routeTasks[id]?.cancel()
            cleanupConversationState(id)
        }
        refreshRunningState()
        refreshQueuedState()
    }

    private func cleanupConversationState(_ conversationId: UUID) {
        runTokens.removeValue(forKey: conversationId)
        chainTasks.removeValue(forKey: conversationId)
        routeTasks.removeValue(forKey: conversationId)
        runningBotNames.removeValue(forKey: conversationId)
        activityLines.removeValue(forKey: conversationId)
        activityStartedAt.removeValue(forKey: conversationId)
        activityUpdatedAt.removeValue(forKey: conversationId)
        queuedSends.removeValue(forKey: conversationId)
        inputDrafts.removeValue(forKey: conversationId)
        // Las copias huérfanas las barre el arranque (ver BotStore.load).
        pendingAttachments.removeValue(forKey: conversationId)
        if store.activeConversation?.id == conversationId {
            isRestoringContext = true
            defer { isRestoringContext = false }
            inputText = ""
        }
    }

    func botsMentioned(in text: String) -> [Bot] {
        var found: [(position: Int, bot: Bot)] = []
        let lower = text.lowercased()
        for bot in store.bots {
            let candidates = [bot.name.lowercased(), firstWord(of: bot.name).lowercased()]
            for candidate in candidates where !candidate.isEmpty {
                if let range = lower.range(of: "@" + candidate) {
                    let position = lower.distance(from: lower.startIndex, to: range.lowerBound)
                    if !found.contains(where: { $0.bot.id == bot.id }) {
                        found.append((position, bot))
                    }
                    break
                }
            }
        }
        return found.sorted { $0.position < $1.position }.map(\.bot)
    }

    func mentionQuery() -> String? {
        let pattern = "@([A-Za-z0-9_áéíóúñÁÉÍóúÑüÜ]*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: inputText, range: NSRange(inputText.startIndex..., in: inputText)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: inputText)
        else { return nil }
        return String(inputText[range])
    }

    func completeMention(with bot: Bot) {
        let pattern = "@[A-Za-z0-9_áéíóúñÁÉÍóúÑüÜ]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(inputText.startIndex..., in: inputText)
        inputText = regex.stringByReplacingMatches(in: inputText, range: range, withTemplate: "@\(bot.name) ")
    }

    private func firstWord(of name: String) -> String {
        String(name.split(separator: " ").first ?? "")
    }

    /// Enrutado oculto de un mensaje de grupo sin menciones: un mediador
    /// invisible (modelo por defecto, esfuerzo mínimo, sin herramientas) elige
    /// qué miembro responde (uno solo, nunca varios). Nunca pinta mensajes
    /// ni revela su existencia: mientras decide, el hilo figura ocupado a
    /// nombre del grupo.
    private func runRouted(
        conversationId: UUID, group: BotGroup, triggerText: String,
        attachments: [ChatAttachment] = []
    ) {
        routeTasks[conversationId]?.cancel()
        routeTasks[conversationId] = Task {
            runningBotNames[conversationId] = group.name
            activityStartedAt[conversationId] = Date()
            setActivity(conversationId: conversationId, headline: "🧭 Eligiendo quién responde…")
            defer { routeTasks[conversationId] = nil }

            let members = store.members(of: group)
            guard let targets = await routeTargets(
                conversationId: conversationId, group: group,
                members: members, triggerText: triggerText
            ), !Task.isCancelled else {
                // Cancelado: sin rastro, como si el mediador no existiera.
                runningBotNames.removeValue(forKey: conversationId)
                activityStartedAt.removeValue(forKey: conversationId)
                setActivity(conversationId: conversationId, headline: nil)
                return
            }
            // A partir de aquí el flujo es el normal: cadena de respuestas
            // (runBot actualizará el nombre en curso).
            runningBotNames.removeValue(forKey: conversationId)
            runChain(
                conversationId: conversationId, targets: targets,
                triggerText: triggerText, attachments: attachments
            )
        }
    }

    /// Devuelve el único miembro que debe responder, o `nil` si se canceló.
    /// Ante cualquier fallo (sin `muse`, error o JSON inválido) responde el
    /// primer miembro: uno solo como máximo y como mínimo, nunca todo el grupo.
    private func routeTargets(
        conversationId: UUID, group: BotGroup, members: [Bot], triggerText: String
    ) async -> [Bot]? {
        if Task.isCancelled { return nil }
        guard let fallback = members.first else { return [] }
        let text: String
        if let override = routerTextOverride {
            text = override
        } else {
            guard let musePath = MuseClient.resolveMusePath(override: store.settings.musePath) else {
                return [fallback]
            }
            let sessionId = store.ensureSession(
                key: routerSessionKey(groupId: group.id), conversationId: conversationId
            )
            let prompt = routerPrompt(
                group: group, members: members, triggerText: triggerText,
                context: recentContext(conversationId: conversationId, excludingTyping: true)
            )
            let token = MuseRunToken()
            runTokens[conversationId] = token
            do {
                let request = MuseRequest(
                    sessionId: sessionId, prompt: prompt, model: "", effort: routerEffort,
                    workspace: "", allowTools: false, timeoutSeconds: 120
                )
                let result = try await MuseClient.runPrompt(
                    musePath: musePath, request: request, token: token
                )
                runTokens.removeValue(forKey: conversationId)
                text = result.text
            } catch is CancellationError {
                runTokens.removeValue(forKey: conversationId)
                return nil
            } catch {
                runTokens.removeValue(forKey: conversationId)
                return [fallback]
            }
        }
        if Task.isCancelled { return nil }
        let resolved = resolveRoutedBots(from: text, members: members)
        return resolved.isEmpty ? [fallback] : resolved
    }

    private func routerSessionKey(groupId: UUID) -> String {
        "router:\(groupId.uuidString)"
    }

    private func runChain(
        conversationId: UUID, targets: [Bot], triggerText: String,
        attachments: [ChatAttachment] = []
    ) {
        // Gancho de tests: registrar sin lanzar `muse` (ver `chainHook`).
        if let hook = chainHook {
            hook(conversationId, targets, triggerText)
            return
        }
        // Solo se cancela la cadena de esta conversación; las demás siguen.
        chainTasks[conversationId]?.cancel()
        chainTasks[conversationId] = Task {
            // Sin límite de turnos ni de visitas: cada @mención continúa la
            // cadena aunque el bot ya haya hablado antes. La cadena termina
            // cuando una respuesta no menciona a nadie, o con Detener.
            for bot in targets {
                if Task.isCancelled { break }
                // Los adjuntos viajan solo en el turno del usuario: las
                // continuaciones bot→bot ya los tienen en su sesión.
                await runBot(
                    conversationId: conversationId, bot: bot,
                    triggerText: triggerText, attachments: attachments
                )
                if Task.isCancelled { break }
                guard store.settings.followBotMentions else { continue }
                guard let reply = store.conversations.first(where: { $0.id == conversationId })?
                    .messages.last(where: { $0.role == "bot" })
                else { continue }
                let next = chainContinuation(replyText: reply.text, speakerId: bot.id)
                if !next.isEmpty {
                    let handoff = "«\(bot.name)» te pasa la palabra:\n\n\(reply.text)"
                    await runChainSync(
                        conversationId: conversationId, targets: next,
                        triggerText: handoff
                    )
                }
            }
            finishChain(conversationId: conversationId, cancelled: Task.isCancelled)
        }
    }

    /// Cierre de una cadena de respuestas: libera su tarea y, si terminó de
    /// forma natural (no Detener), avanza la cola. Si no queda trabajo en
    /// marcha, el hilo espera tu mensaje y suena el aviso de fin.
    /// Interna para tests.
    func finishChain(conversationId: UUID, cancelled: Bool) {
        chainTasks[conversationId] = nil
        // Hueco: la cadena terminó de forma natural; procesar el
        // siguiente mensaje encolado, si lo hay. Tras Detener no se
        // arranca nada solo (la cola espera a Reanudar o al próximo envío)
        // ni suena el aviso: el usuario ya está delante.
        guard !cancelled else { return }
        let moreWork = drainQueue(conversationId: conversationId)
        if !moreWork {
            playCompletionSoundIfEnabled()
        }
    }

    /// Bip de sistema al terminar, salvo que esté desactivado en Ajustes.
    /// Interna para tests.
    func playCompletionSoundIfEnabled() {
        guard store.settings.completionSoundEnabled else { return }
        soundPlayer()
    }

    /// Rama recursiva de la cadena: ejecuta `targets` en orden y sigue las
    /// menciones con @ de sus respuestas, sin límite de turnos: un bot puede
    /// volver a actuar tantas veces como lo mencionen.
    private func runChainSync(
        conversationId: UUID, targets: [Bot], triggerText: String
    ) async {
        for bot in targets {
            if Task.isCancelled { return }
            await runBot(
                conversationId: conversationId, bot: bot,
                triggerText: triggerText
            )
            if Task.isCancelled { return }
            guard store.settings.followBotMentions else { continue }
            guard let reply = store.conversations.first(where: { $0.id == conversationId })?
                .messages.last(where: { $0.role == "bot" })
            else { continue }
            let next = chainContinuation(replyText: reply.text, speakerId: bot.id)
            if !next.isEmpty {
                await runChainSync(
                    conversationId: conversationId,
                    targets: next,
                    triggerText: "«\(bot.name)» te pasa la palabra:\n\n\(reply.text)"
                )
            }
        }
    }

    /// Continuación de la cadena tras una respuesta: mencionados con @ en el
    /// texto, excluyendo solo al autor (evita que un bot se invoque a sí
    /// mismo en bucle). Los demás continúan aunque ya hayan hablado en esta
    /// cadena: la conversación solo termina cuando nadie es mencionado.
    /// Interna para tests.
    func chainContinuation(replyText: String, speakerId: UUID) -> [Bot] {
        botsMentioned(in: replyText).filter { $0.id != speakerId }
    }

    private func runBot(
        conversationId: UUID, bot: Bot, triggerText: String,
        attachments: [ChatAttachment] = []
    ) async {
        // La conversación queda fijada al enviar: cambiar de bot a mitad de
        // una respuesta no desvía el texto a otro hilo.
        guard store.conversations.contains(where: { $0.id == conversationId }) else { return }
        let sessionId = store.ensureSession(botId: bot.id, conversationId: conversationId)
        let introduced = store.isIntroduced(botId: bot.id, conversationId: conversationId)
        let group = group(for: conversationId)
        let prompt = buildPrompt(
            bot: bot, conversationId: conversationId, triggerText: triggerText,
            introduced: introduced, group: group, attachments: attachments
        )

        let typing = ChatMessage(role: "bot", botId: bot.id, botName: bot.name, text: "…")
        store.appendMessage(typing, conversationId: conversationId, persist: false)
        let typingId = typing.id

        runningBotNames[conversationId] = bot.name
        activityStartedAt[conversationId] = Date()
        setActivity(conversationId: conversationId, headline: activityThinking)
        defer {
            runningBotNames.removeValue(forKey: conversationId)
            activityStartedAt.removeValue(forKey: conversationId)
            setActivity(conversationId: conversationId, headline: nil)
            runTokens.removeValue(forKey: conversationId)
        }

        guard let musePath = MuseClient.resolveMusePath(override: store.settings.musePath) else {
            store.replaceMessage(
                id: typingId, conversationId: conversationId,
                text: "⚠️ \(MuseError.binaryNotFound.localizedDescription)"
            )
            return
        }

        let token = MuseRunToken()
        runTokens[conversationId] = token
        // Streaming: pinta el texto parcial conforme llega por stdout, como
        // un chatbot normal, sin esperar a que termine el proceso. Si el
        // usuario cancela, el mensaje ya no existe y el aviso se ignora.
        // Limitado a ~10 repintados/s: sin esto cada delta de la ráfaga
        // reparsea el Markdown de todo el hilo en el main thread.
        let throttle = StreamThrottler()
        let onUpdate: @Sendable (String, [String]) -> Void = { [weak self] text, notes in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !notes.isEmpty else { return }
            guard throttle.shouldPaint() else { return }
            Task { @MainActor [weak self] in
                self?.store.replaceMessage(
                    id: typingId, conversationId: conversationId,
                    text: streamingDisplayText(for: text), toolNotes: notes, persist: false
                )
            }
        }
        // Titular de actividad: un solo texto con lo más reciente (el
        // parser ya reemplaza, nunca acumula). Sin throttle: los eventos
        // son escasos y cada uno es una prueba de vida.
        let onActivity: @Sendable (String?) -> Void = { [weak self] headline in
            Task { @MainActor [weak self] in
                guard let self,
                      self.store.conversations.contains(where: { $0.id == conversationId })
                else { return }
                self.setActivity(conversationId: conversationId, headline: headline)
            }
        }
        do {
            let request = MuseRequest(
                sessionId: sessionId,
                prompt: prompt,
                model: bot.model,
                effort: bot.effort,
                workspace: effectiveWorkspace(bot: bot, group: group),
                // Todos los bots y grupos tienen acceso total, sin avisos.
                allowTools: true,
                // Visión nativa: las imágenes adjuntas entran por `--image`.
                imagePaths: attachments.filter(\.isImage).map(\.storedPath)
            )
            let result = try await MuseClient.runPrompt(
                musePath: musePath, request: request, token: token,
                onUpdate: onUpdate, onActivity: onActivity
            )
            store.replaceMessage(
                id: typingId, conversationId: conversationId,
                text: result.text, toolNotes: result.toolNotes
            )
            store.markIntroduced(botId: bot.id, conversationId: conversationId)
        } catch is CancellationError {
            store.removeMessage(id: typingId, conversationId: conversationId)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            store.replaceMessage(id: typingId, conversationId: conversationId, text: "⚠️ \(detail)")
        }
    }

    private func buildPrompt(
        bot: Bot, conversationId: UUID, triggerText: String, introduced: Bool, group: BotGroup?,
        attachments: [ChatAttachment] = []
    ) -> String {
        var parts: [String] = []
        if !introduced {
            parts.append(
                "Eres «\(bot.name)» (\(bot.specialty)). \(bot.systemPrompt)\n\n" +
                "Estás en un chat con varios bots y un usuario. \(mentionHandoffRule)"
            )
        }
        if let group {
            parts.append(groupContext(group: group))
        }
        let excerpt = recentContext(conversationId: conversationId, excludingTyping: true)
        if !excerpt.isEmpty {
            parts.append("Contexto reciente del chat:\n\(excerpt)")
        }
        if let block = attachmentPromptBlock(attachments) {
            parts.append(block)
        }
        parts.append(triggerText)
        parts.append(
            "(Tienes ACCESO TOTAL al Mac: archivos, shell sin sandbox, web y subagentes. " +
                "Puedes controlar el sistema desde la shell: `screencapture` para capturas de pantalla, " +
                "`osascript` (AppleScript) para ventanas/apps/navegador, `open` para apps y URLs, " +
                "además de leer/escribir archivos y ejecutar cualquier comando. " +
                "Si macOS pide permisos (grabación de pantalla, automatización, accesibilidad), " +
                "dile al usuario que los conceda en Ajustes del Sistema > Privacidad y seguridad.)"
        )
        return parts.joined(separator: "\n\n---\n\n")
    }

    /// Contexto compartido del grupo: objetivo, miembros y carpeta de
    /// trabajo. Va en cada petición del hilo para que los bots sepan con
    /// quién colaborar aunque el grupo se edite a mitad de conversación.
    /// Los miembros se listan SIN @ y con la regla de menciones para no
    /// inducir invocaciones descriptivas. Interna para tests.
    func groupContext(group: BotGroup) -> String {
        var block = "Grupo «\(group.name)»"
        let goal = group.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { block += " — objetivo: \(goal)" }
        let memberList = store.members(of: group)
            .map { "\($0.name) (\($0.specialty))" }
            .joined(separator: ", ")
        if !memberList.isEmpty { block += "\nMiembros: \(memberList)." }
        if group.hasCustomWorkspace {
            block += "\nCarpeta de trabajo del grupo: \(group.workspaceResolved)"
        }
        block += "\n\(mentionHandoffRule)"
        return block
    }

    private func recentContext(conversationId: UUID, excludingTyping: Bool) -> String {
        guard let messages = store.conversations.first(where: { $0.id == conversationId })?.messages
        else { return "" }
        // Los mensajes de solo-adjuntos (texto vacío) también cuentan.
        let relevant = messages.filter {
            $0.role != "system"
                && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.attachments.isEmpty)
        }
        let tail = relevant.suffix(6).filter { !(excludingTyping && $0.text == "…") }
        return tail.map { message in
            let author: String
            if message.role == "user" {
                author = "Usuario"
            } else {
                author = message.botName ?? store.botName(for: message.botId)
            }
            let isAttachmentOnly = message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !message.attachments.isEmpty
            let body = isAttachmentOnly ? "(solo adjuntos)" : message.text
            let snippet = body.count > 400 ? String(body.prefix(400)) + "…" : body
            return "[\(author)]: \(snippet)\(attachmentContextSuffix(message.attachments))"
        }.joined(separator: "\n")
    }
}

// MARK: - Streaming

/// Limitador de repintados de streaming: los deltas llegan en ráfagas y cada
/// repintado reparsea el Markdown y re-renderiza el hilo en el main thread.
/// Deja pasar como máximo uno por intervalo; el texto final siempre se pinta
/// al terminar el proceso, así que soltar intermedios es seguro.
final class StreamThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private let minInterval: TimeInterval
    private var lastPass: Date?

    init(minInterval: TimeInterval = 0.1) {
        self.minInterval = minInterval
    }

    /// `true` la primera vez y cuando ya pasó el intervalo desde la anterior.
    func shouldPaint(now: Date = Date()) -> Bool {
        lock.withLock {
            if let last = lastPass, now.timeIntervalSince(last) < minInterval {
                return false
            }
            lastPass = now
            return true
        }
    }
}

/// Texto a pintar para un parcial de streaming: conserva el marcador "…"
/// (spinner) hasta que el parcial sea legible, para no mostrar fragmentos
/// sueltos como "1" (inicio de "1. …") que se quedan fijos si hay una pausa
/// larga hasta el siguiente trozo. El texto final siempre se pinta tal cual.
func streamingDisplayText(for partial: String) -> String {
    let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "…" }
    return isLegiblePartial(trimmed) ? partial : "…"
}

/// Un parcial es legible si trae un límite de palabra (espacio o salto) o un
/// token suelto con suficientes caracteres que no sea un prefijo estructural
/// de Markdown (número de lista, viñeta, `#`, valla de código…).
private func isLegiblePartial(_ trimmed: String) -> Bool {
    if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return true }
    if isMarkdownPrefix(trimmed) { return false }
    return trimmed.count >= 4
}

private func isMarkdownPrefix(_ token: String) -> Bool {
    let digits = token.prefix(while: { $0.isNumber })
    if !digits.isEmpty {
        let rest = token.dropFirst(digits.count)
        if rest.isEmpty || rest == "." || rest == ")" { return true }
    }
    if token.allSatisfy({ $0 == "#" }) { return true }
    switch token {
    case "-", "*", "+", ">", "|": return true
    default: break
    }
    return token.hasPrefix("```") || token.hasPrefix("~~~")
}

// MARK: - Menciones entre bots

/// Regla de menciones que reciben los bots: @nombre INVOCA al bot (continúa
/// el hilo), así que solo se usa para pedir su acción; para hablar DE un bot
/// se usa su nombre sin @. Sin @menciones el turno vuelve al usuario, así que
/// el trabajo termina respondiendo sin mencionar a nadie. Fuente única usada
/// en la presentación y en el contexto de cada grupo.
let mentionHandoffRule = "Menciona a otro bot con @nombre SOLO cuando necesites que actúe a continuación (él continuará el hilo, sin límite de turnos). Si solo hablas DE otro bot —describes el flujo, explicas quién hace qué o saludas—, usa su nombre SIN @ para no invocarlo. Cuando el trabajo esté terminado o no necesites a nadie más, responde SIN mencionar a ningún bot y el turno volverá al usuario."

// MARK: - Enrutador oculto de grupos

/// Esfuerzo de razonamiento del mediador: el más bajo con razonamiento
/// activo (por debajo solo queda `none`, que lo desactiva).
let routerEffort = "minimal"

/// Prompt del mediador invisible: decide qué miembro responde al mensaje
/// (uno solo, nunca varios). Incluye el objetivo del grupo y las capacidades
/// de cada miembro (tal como las define su propio prompt de sistema) para
/// elegir con criterio.
func routerPrompt(group: BotGroup, members: [Bot], triggerText: String, context: String) -> String {
    var lines = [
        "Eres el enrutador oculto del grupo «\(group.name)». Tu única tarea es decidir qué miembro debe responder al mensaje del usuario.",
    ]
    let goal = group.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    if !goal.isEmpty { lines.append("Objetivo del grupo: \(goal)") }
    lines.append("Miembros:")
    for member in members {
        lines.append("- \(member.name) (\(member.specialty)): \(truncatedPrompt(member.systemPrompt, limit: 2000))")
    }
    if !context.isEmpty {
        lines.append("Contexto reciente del chat:\n\(context)")
    }
    lines.append("Mensaje del usuario:\n\(triggerText)")
    lines.append(
        "Responde SOLO con un JSON válido, sin explicaciones ni vallas de código, " +
            "con esta forma exacta: {\"responder\": \"Nombre\"}. " +
            "Usa el nombre exacto de la lista. Elige UN solo miembro, el más adecuado " +
            "para resolver el mensaje; si no está claro, elige el más general. " +
            "Nunca devuelvas varios ni una lista vacía."
    )
    return lines.joined(separator: "\n\n")
}

private func truncatedPrompt(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= limit { return trimmed }
    return String(trimmed.prefix(limit)) + "…"
}

/// Convierte la respuesta del enrutador en el único miembro que responde:
/// como máximo un bot (el primer nombre válido). Tolerante con vallas de
/// código, variantes de la clave y listas (de las que se toma solo el
/// primero); devuelve vacío si no hay ningún nombre válido (el llamador
/// aplica el fallback al primer miembro).
func resolveRoutedBots(from text: String, members: [Bot]) -> [Bot] {
    guard let data = extractRouterJSON(from: text),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return [] }
    let rawNames: [String]
    if let array = obj["responder"] as? [String] {
        rawNames = array
    } else if let array = obj["responders"] as? [String] {
        rawNames = array
    } else if let array = obj["bots"] as? [String] {
        rawNames = array
    } else if let single = obj["responder"] as? String {
        rawNames = [single]
    } else {
        return []
    }
    for raw in rawNames {
        let want = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !want.isEmpty else { continue }
        if let match = members.first(where: {
            $0.name.lowercased() == want || String($0.name.split(separator: " ").first ?? "").lowercased() == want
        }) {
            return [match]
        }
    }
    return []
}

private func extractRouterJSON(from text: String) -> Data? {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("```") {
        body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("json") { body = String(body.dropFirst(4)) }
        if let end = body.range(of: "```", options: .backwards) { body = String(body[..<end.lowerBound]) }
    }
    guard let start = body.firstIndex(of: "{"),
          let end = body.lastIndex(of: "}"), start <= end
    else { return nil }
    return String(body[start...end]).data(using: .utf8)
}
