import Foundation

// MARK: - Modelo

/// Un archivo adjunto a un mensaje de usuario, ya copiado a la carpeta de
/// datos de Boty para que sobreviva a que se mueva o borre el original.
/// Las imágenes viajan además por el flag nativo `--image` de `muse exec`
/// (visión); el resto se leen por ruta con las herramientas del bot.
struct ChatAttachment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Nombre original del archivo (p. ej. `captura.png`).
    var fileName: String
    /// Ruta absoluta de la copia en `~/Library/Application Support/Boty/…`.
    var storedPath: String
    var byteSize: Int
    var isImage: Bool
}

// MARK: - Límites

/// Máximo de adjuntos por mensaje.
let maxAttachmentsPerMessage = 5

/// Tamaño máximo por adjunto (25 MB).
let maxAttachmentBytes = 25 * 1024 * 1024

/// Extensiones que `muse` acepta como visión vía `--image`.
let attachmentImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
    "bmp", "tiff", "tif", "avif",
]

/// `true` si el nombre parece una imagen por su extensión.
func isImageFilename(_ fileName: String) -> Bool {
    let ext = (fileName as NSString).pathExtension.lowercased()
    return !ext.isEmpty && attachmentImageExtensions.contains(ext)
}

/// Valida un candidato a adjunto. Devuelve el mensaje de error a mostrar,
/// o `nil` si cabe en el mensaje.
func validateAttachmentCandidate(
    fileName: String, byteSize: Int, currentCount: Int
) -> String? {
    if currentCount >= maxAttachmentsPerMessage {
        return "Máximo \(maxAttachmentsPerMessage) adjuntos por mensaje."
    }
    if byteSize > maxAttachmentBytes {
        return "«\(fileName)» supera el máximo de \(formatAttachmentSize(maxAttachmentBytes)) por archivo."
    }
    return nil
}

/// Tamaño legible con un decimal ("1,2 MB"), independiente del locale para
/// que los tests sean deterministas.
func formatAttachmentSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return "\(rounded1(kb)) KB" }
    let mb = kb / 1024
    if mb < 1024 { return "\(rounded1(mb)) MB" }
    return "\(rounded1(mb / 1024)) GB"
}

private func rounded1(_ value: Double) -> String {
    let r = (value * 10).rounded() / 10
    if r == r.rounded() { return String(Int(r)) }
    return String(r).replacingOccurrences(of: ".", with: ",")
}

// MARK: - Prompt y contexto

/// Bloque para el prompt del bot con las rutas locales de los adjuntos.
/// `nil` cuando no hay ninguno. Las imágenes van además por `--image`;
/// el resto los lee el bot con sus herramientas (acceso total).
func attachmentPromptBlock(_ attachments: [ChatAttachment]) -> String? {
    guard !attachments.isEmpty else { return nil }
    var lines = ["Archivos adjuntos del usuario (rutas locales en este Mac):"]
    for attachment in attachments {
        if attachment.isImage {
            lines.append("- \(attachment.storedPath) (imagen «\(attachment.fileName)», también visible en tu entrada de visión)")
        } else {
            lines.append("- \(attachment.storedPath) («\(attachment.fileName)», \(formatAttachmentSize(attachment.byteSize)): léelo con tus herramientas)")
        }
    }
    return lines.joined(separator: "\n")
}

/// Sufijo para que los adjuntos aparezcan en el contexto reciente y en el
/// texto que ve el enrutador (" [adjuntos: a.png, doc.pdf]"). Vacío sin
/// adjuntos.
func attachmentContextSuffix(_ attachments: [ChatAttachment]) -> String {
    guard !attachments.isEmpty else { return "" }
    return " [adjuntos: \(attachments.map(\.fileName).joined(separator: ", "))]"
}

// MARK: - Almacenamiento

/// Raíz de adjuntos dentro de la carpeta de datos de Boty.
func attachmentsRoot(storageDir: URL) -> URL {
    storageDir.appendingPathComponent("attachments", isDirectory: true)
}

/// Carpeta de adjuntos de una conversación (se crea al copiar el primero).
func conversationAttachmentsDir(storageDir: URL, conversationId: UUID) -> URL {
    attachmentsRoot(storageDir: storageDir)
        .appendingPathComponent(conversationId.uuidString, isDirectory: true)
}

/// Destino libre dentro de `dir` para `fileName`, sin sobrescribir:
/// añade " 2", " 3"… cuando ya existe.
func uniqueAttachmentDestination(in dir: URL, fileName: String) -> URL {
    let safe = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = safe.isEmpty ? "adjunto" : safe
    var candidate = dir.appendingPathComponent(base)
    guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
    let ext = (base as NSString).pathExtension
    let stem = (base as NSString).deletingPathExtension
    var n = 2
    repeat {
        let numbered = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
        candidate = dir.appendingPathComponent(numbered)
        n += 1
    } while FileManager.default.fileExists(atPath: candidate.path)
    return candidate
}

enum AttachmentCopyError: Error, LocalizedError {
    case unreadable(String)
    case copyFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "No pude leer «\(name)»."
        case .copyFailed(let name, let detail):
            return "No pude adjuntar «\(name)»: \(detail)"
        }
    }
}

/// Copia `source` a la carpeta de adjuntos de la conversación y devuelve el
/// registro listo para el mensaje pendiente. Crea la carpeta si hace falta.
func copyAttachment(
    from source: URL, storageDir: URL, conversationId: UUID
) throws -> ChatAttachment {
    let fileName = source.lastPathComponent
    guard let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue else {
        throw AttachmentCopyError.unreadable(fileName)
    }
    let dir = conversationAttachmentsDir(storageDir: storageDir, conversationId: conversationId)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let destination = uniqueAttachmentDestination(in: dir, fileName: fileName)
    do {
        try FileManager.default.copyItem(at: source, to: destination)
    } catch {
        throw AttachmentCopyError.copyFailed(fileName, error.localizedDescription)
    }
    return ChatAttachment(
        fileName: fileName,
        storedPath: destination.path,
        byteSize: size,
        isImage: isImageFilename(fileName)
    )
}

/// Borra los archivos de `root` que ningún mensaje referencia (pendientes
/// descartados, app cerrada antes de enviar…). Devuelve cuántos borró.
/// Solo toca archivos regulares dentro de `root`; nunca sale de él.
@discardableResult
func sweepUnreferencedAttachments(root: URL, referencedPaths: Set<String>) -> Int {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
    // El enumerador puede devolver otra forma de la misma ruta que la
    // guardada (`/private/var/…` frente a `/var/…`): comparar canonizadas.
    let canonical = Set(referencedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    var removed = 0
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        if !canonical.contains(url.resolvingSymlinksInPath().path) {
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
    }
    return removed
}
