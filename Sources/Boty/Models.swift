import Foundation

struct Bot: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var specialty: String
    var colorHex: String
    var systemPrompt: String
    var model: String = ""
    var effort: String = "low"
    var workspacePath: String = ""

    static let defaultColors = [
        "#0A84FF", "#30D158", "#FF9F0A", "#BF5AF2",
        "#FF453A", "#64D2FF", "#FFD60A", "#FF6482",
    ]

    /// Tiers de esfuerzo en el mismo orden que los acepta
    /// `muse exec --reasoning-effort` (none|minimal|low|medium|high|xhigh|max|ultra).
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    var workspaceResolved: String {
        if workspacePath.trimmingCharacters(in: .whitespaces).isEmpty { return NSHomeDirectory() }
        return (workspacePath as NSString).expandingTildeInPath
    }
}

struct BotGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var goal: String = ""
    var colorHex: String = "#0A84FF"
    var workspacePath: String = ""
    var botIds: [UUID] = []

    /// `true` cuando el grupo fija su propia carpeta de trabajo, que en ese
    /// caso prevalece sobre la de cada bot dentro del hilo del grupo.
    var hasCustomWorkspace: Bool {
        !workspacePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var workspaceResolved: String {
        (workspacePath as NSString).expandingTildeInPath
    }
}

/// Carpeta de trabajo efectiva de un bot dentro de una conversación: la del
/// grupo si la fija, o la propia del bot en caso contrario.
func effectiveWorkspace(bot: Bot, group: BotGroup?) -> String {
    if let group, group.hasCustomWorkspace { return group.workspaceResolved }
    return bot.workspaceResolved
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var role: String // "user" | "bot" | "system"
    var botId: UUID?
    var botName: String?
    var text: String
    var toolNotes: [String] = []
    var date: Date = Date()
    /// Adjuntos del mensaje (solo los de usuario los traen).
    var attachments: [ChatAttachment] = []

    private enum CodingKeys: String, CodingKey {
        case id, role, botId, botName, text, toolNotes, date, attachments
    }

    /// Tolerante con hilos guardados antes de los adjuntos: los que faltan
    /// toman su valor por defecto en vez de invalidar todo el archivo.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(String.self, forKey: .role)
        botId = try container.decodeIfPresent(UUID.self, forKey: .botId)
        botName = try container.decodeIfPresent(String.self, forKey: .botName)
        text = try container.decode(String.self, forKey: .text)
        toolNotes = try container.decodeIfPresent([String].self, forKey: .toolNotes) ?? []
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }

    init(
        id: UUID = UUID(),
        role: String,
        botId: UUID? = nil,
        botName: String? = nil,
        text: String,
        toolNotes: [String] = [],
        date: Date = Date(),
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.botId = botId
        self.botName = botName
        self.text = text
        self.toolNotes = toolNotes
        self.date = date
        self.attachments = attachments
    }

    /// Marcador transitorio de "escribiendo…": solo vive en memoria mientras
    /// llega la respuesta y nunca debe persistir en disco.
    var isTypingPlaceholder: Bool { role == "bot" && text == "…" }
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Bot dueño del hilo. `nil` = formato antiguo (anterior a hilos 1:1 por bot).
    var botId: UUID?
    /// Grupo dueño del hilo. Un hilo es de bot (`botId`) o de grupo
    /// (`groupId`), nunca de ambos; `nil` en los dos = formato antiguo.
    var groupId: UUID?
    var title: String = "Nueva conversación"
    var messages: [ChatMessage] = []
    var sessionIds: [String: String] = [:]
    var introducedBots: [String] = []
    var date: Date = Date()
}

/// Cada bot y cada grupo tiene al menos un hilo: conserva TODOS los hilos
/// existentes con dueño válido (hilos múltiples), crea el primero para los
/// bots/grupos sin ninguno y descarta hilos antiguos sin dueño o de
/// bots/grupos que ya no existen. El orden existente se respeta para no
/// mover el hilo activo al recargar.
func syncedThreads(bots: [Bot], groups: [BotGroup] = [], conversations: [Conversation]) -> [Conversation] {
    let botIds = Set(bots.map(\.id))
    let groupIds = Set(groups.map(\.id))
    var kept: [Conversation] = []
    for conversation in conversations {
        if let groupId = conversation.groupId {
            if groupIds.contains(groupId) { kept.append(conversation) }
        } else if let botId = conversation.botId {
            if botIds.contains(botId) { kept.append(conversation) }
        }
    }
    let hasThreadForBot: (UUID) -> Bool = { botId in kept.contains { $0.botId == botId } }
    let hasThreadForGroup: (UUID) -> Bool = { groupId in kept.contains { $0.groupId == groupId } }
    for bot in bots where !hasThreadForBot(bot.id) {
        kept.append(makeThread(for: bot))
    }
    for group in groups where !hasThreadForGroup(group.id) {
        kept.append(
            makeGroupThread(for: group, memberNames: group.botIds.compactMap { botId in bots.first { $0.id == botId }?.name })
        )
    }
    return kept
}

func makeThread(for bot: Bot) -> Conversation {
    Conversation(
        botId: bot.id,
        title: bot.name,
        messages: [ChatMessage(role: "system", text: threadGreeting(botName: bot.name))]
    )
}

func threadGreeting(botName: String) -> String {
    "Hablas con «\(botName)». Escribe @nombre para invitar a otro bot a este hilo; si un bot necesita que otro actúe, lo menciona con @nombre y este continúa."
}

func makeGroupThread(for group: BotGroup, memberNames: [String]) -> Conversation {
    Conversation(
        groupId: group.id,
        title: group.name,
        messages: [ChatMessage(role: "system", text: groupGreeting(groupName: group.name, memberNames: memberNames))]
    )
}

func groupGreeting(groupName: String, memberNames: [String]) -> String {
    if memberNames.isEmpty {
        return "Grupo «\(groupName)» sin bots. Edítalo para añadir miembros."
    }
    let mentions = memberNames.map { "@\($0)" }.joined(separator: " ")
    return "Hablas en el grupo «\(groupName)» con \(mentions). Escribe y responde el miembro más adecuado (uno solo), o usa @nombre para dirigirte a uno; si un bot necesita que otro actúe, lo menciona con @nombre y este continúa."
}

struct AppSettings: Codable, Sendable {
    var musePath: String = ""
    var followBotMentions: Bool = true
    var codeTheme: CodeThemeName = .catppuccin
    /// Zoom de la escala de la app en pasos sobre el tamaño por defecto (0).
    var zoomStep: Int = 0
    /// Enrutado automático en grupos: un mediador oculto decide qué miembro
    /// responde (uno solo) a cada mensaje sin menciones. Apagado = responden todos.
    var autoRouteGroups: Bool = true
    /// Bip de sistema cuando los bots terminan y el hilo queda esperando tu
    /// mensaje. Se desactiva en Ajustes.
    var completionSoundEnabled: Bool = true

    private enum CodingKeys: String, CodingKey {
        case musePath
        case followBotMentions
        case codeTheme
        case zoomStep
        case autoRouteGroups
        case completionSoundEnabled
    }

    init(
        musePath: String = "",
        followBotMentions: Bool = true,
        codeTheme: CodeThemeName = .catppuccin,
        zoomStep: Int = 0,
        autoRouteGroups: Bool = true,
        completionSoundEnabled: Bool = true
    ) {
        self.musePath = musePath
        self.followBotMentions = followBotMentions
        self.codeTheme = codeTheme
        self.zoomStep = zoomStep
        self.autoRouteGroups = autoRouteGroups
        self.completionSoundEnabled = completionSoundEnabled
    }

    /// Tolerante con ajustes guardados antes de cada campo: los que faltan
    /// toman su valor por defecto en vez de invalidar todo el archivo.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        musePath = try container.decodeIfPresent(String.self, forKey: .musePath) ?? ""
        followBotMentions = try container.decodeIfPresent(Bool.self, forKey: .followBotMentions) ?? true
        codeTheme = try container.decodeIfPresent(CodeThemeName.self, forKey: .codeTheme) ?? .catppuccin
        zoomStep = clampedZoomStep(try container.decodeIfPresent(Int.self, forKey: .zoomStep) ?? 0)
        autoRouteGroups = try container.decodeIfPresent(Bool.self, forKey: .autoRouteGroups) ?? true
        completionSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .completionSoundEnabled) ?? true
    }
}
