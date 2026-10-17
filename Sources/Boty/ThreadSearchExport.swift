import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Buscar en chats y exportar a Markdown (mejora #3)
//
// Dominio puro, sin SwiftUI: buscar texto entre hilos y convertir un hilo
// a Markdown. La UI (sidebar y cabecera del chat) lo consume sin lógica.

/// Un mensaje que coincide con la búsqueda: con qué hilo, qué mensaje y
/// un extracto para pintar en la lista de resultados. El salto al mensaje
/// lo resuelve el `ChatViewModel` (selecciona dueño + hilo y desplaza).
struct ThreadSearchResult: Identifiable, Hashable, Sendable {
    var id: UUID { messageId }
    var threadId: UUID
    var messageId: UUID
    var threadTitle: String
    var ownerName: String
    var authorLabel: String
    var snippet: String
    var date: Date
}

/// Nombre del dueño (bot o grupo) de un hilo, para resultados y export.
func threadOwnerName(
    _ conversation: Conversation, bots: [Bot], groups: [BotGroup] = []
) -> String {
    if let groupId = conversation.groupId {
        return groups.first { $0.id == groupId }?.name ?? conversation.title
    }
    if let botId = conversation.botId {
        return bots.first { $0.id == botId }?.name ?? conversation.title
    }
    return conversation.title
}

/// Busca `query` en los mensajes de usuario y bot de `conversations`
/// (se ignoran los saludos de sistema y los marcadores "…"). Insensible a
/// mayúsculas y tildes; en blanco devuelve vacío. Orden: recientes primero.
func searchThreads(
    query: String, conversations: [Conversation], bots: [Bot], groups: [BotGroup] = [],
    limit: Int = 50
) -> [ThreadSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return [] }
    let want = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    var results: [ThreadSearchResult] = []
    for conversation in conversations {
        let owner = threadOwnerName(conversation, bots: bots, groups: groups)
        for message in conversation.messages {
            guard message.role == "user" || message.role == "bot" else { continue }
            guard !message.isTypingPlaceholder else { continue }
            let haystack = message.text.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            guard let range = haystack.range(of: want) else { continue }
            // Posición aproximada en el texto original para el extracto.
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let author: String = message.role == "user"
                ? "Tú"
                : (message.botName ?? bots.first { $0.id == message.botId }?.name ?? "Bot")
            results.append(ThreadSearchResult(
                threadId: conversation.id,
                messageId: message.id,
                threadTitle: conversation.title,
                ownerName: owner,
                authorLabel: author,
                snippet: searchSnippet(message.text, centeredAt: offset, matchLength: trimmed.count),
                date: message.date
            ))
            if results.count >= limit { break }
        }
        if results.count >= limit { break }
    }
    return results.sorted { $0.date > $1.date }
}

/// Extracto de ~120 caracteres alrededor de la coincidencia, con elipsis.
func searchSnippet(_ text: String, centeredAt offset: Int, matchLength: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    guard !flat.isEmpty else { return "" }
    let radius = 60
    let startOffset = max(0, offset - radius)
    let endOffset = min(flat.count, offset + matchLength + radius)
    let start = flat.index(flat.startIndex, offsetBy: startOffset)
    let end = flat.index(flat.startIndex, offsetBy: endOffset)
    var snippet = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
    if startOffset > 0 { snippet = "…" + snippet }
    if endOffset < flat.count { snippet += "…" }
    return snippet
}

// MARK: - Exportar a Markdown

/// Convierte un hilo a Markdown: título, cabecera con dueño/fecha y un
/// apartado por mensaje (usuario/bot con hora). Los adjuntos y notas de
/// herramientas se listan para no perder contexto.
func threadMarkdown(_ conversation: Conversation, ownerName: String) -> String {
    var lines: [String] = []
    lines.append("# \(conversation.title)")
    lines.append("")
    let count = conversation.messages.filter { $0.role != "system" }.count
    let dateText = conversation.date.formatted(date: .abbreviated, time: .shortened)
    lines.append("Hilo de \(ownerName) · \(count) mensajes · \(dateText)")
    lines.append("")
    for message in conversation.messages where message.role != "system" {
        guard !message.isTypingPlaceholder else { continue }
        let time = message.date.formatted(date: .omitted, time: .shortened)
        if message.role == "user" {
            lines.append("## Tú · \(time)")
        } else {
            lines.append("## \(message.botName ?? "Bot") · \(time)")
        }
        lines.append("")
        let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(body.isEmpty ? "(solo adjuntos)" : body)
        lines.append("")
        if !message.attachments.isEmpty {
            lines.append("Adjuntos: " + message.attachments.map(\.fileName).joined(separator: ", "))
            lines.append("")
        }
        for note in message.toolNotes {
            lines.append("> \(note)")
        }
        if !message.toolNotes.isEmpty { lines.append("") }
    }
    return lines.joined(separator: "\n")
}

/// Guarda el Markdown de un hilo con el panel del sistema. Sin efecto si el
/// usuario cancela o el contenido no se puede escribir.
@MainActor
func saveThreadMarkdown(title: String, markdown: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = threadExportFilename(title: title)
    panel.message = "Exportar hilo «\(title)» a Markdown"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? markdown.write(to: url, atomically: true, encoding: .utf8)
}

/// Nombre de archivo seguro para exportar ("Mi hilo" → "Mi-hilo.md").
func threadExportFilename(title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "hilo" : trimmed
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
    let mapped = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
    let collapsed = mapped.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "-")
    let safe = collapsed.isEmpty ? "hilo" : String(collapsed.prefix(80))
    return safe + ".md"
}
