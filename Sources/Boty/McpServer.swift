import Foundation

/// Transporte de un servidor MCP gestionado por Boty.
///
/// El plan validado limita la v1 a estos dos transportes: los MCP útiles
/// vía `npx`/`uvx` son `stdio`, y el OAuth (`muse mcp login`) solo existe
/// para `streamable-http`. No hay otros casos en la v1.
enum McpTransport: String, Codable, Sendable, CaseIterable {
    case stdio
    case streamableHttp = "streamable-http"

    var displayName: String {
        switch self {
        case .stdio: return "stdio"
        case .streamableHttp: return "HTTP"
        }
    }
}

/// Servidor MCP global configurado desde Boty.
///
/// Entidad de dominio: Boty no implementa el protocolo MCP, solo declara
/// estos servidores en el `settings.json` de `muse`, que es quien los usa
/// en el siguiente `exec`. Los servidores son globales (también visibles
/// en la terminal del usuario): no hay scoping por bot.
struct McpServer: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Nombre único global: es la clave bajo `mcpServers` en `settings.json`
    /// y el `<server>` de `muse mcp login/logout`. Charset restringido a lo
    /// que acepta el CLI como nombre de servidor.
    var name: String
    var transport: McpTransport
    /// Solo `stdio`.
    var command: String = ""
    var args: [String] = []
    /// Solo `stdio`. Secretos literales: `muse` no expande `${VAR}` en
    /// entradas MCP, así que se guardan tal cual (igual que `settings.json`).
    var env: [String: String] = [:]
    /// Solo `streamable-http`.
    var url: String = ""
    /// Solo `streamable-http`. Cabeceras literales (misma razón que `env`).
    var headers: [String: String] = [:]
    /// Servidor apagado = se declara con `"enabled": false`, nunca se borra
    /// del `settings.json` en silencio (ver `McpSettingsSync`).
    var enabled: Bool = true
    /// Estado de autenticación v1: `auth.json` no expone sección MCP estable,
    /// así que Boty guarda sus propios timestamps de login/logout.
    var lastLoginAt: Date?
    var lastLogoutAt: Date?

    /// Nombres válidos: letras, dígitos, `-` y `_` (lo que el CLI acepta
    /// como `<server>` sin ambigüedad en shell ni JSON).
    static let namePattern = "^[A-Za-z0-9_-]{1,64}$"

    var isNameValid: Bool {
        name.range(of: Self.namePattern, options: .regularExpression) != nil
    }

    /// Error de validación listo para la UI, o `nil` si es válido.
    /// `takenNames` son los nombres de los demás servidores (unicidad).
    func validationError(takenNames: Set<String> = []) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "El nombre no puede estar vacío." }
        if trimmed != name { return "El nombre no puede llevar espacios al inicio o al final." }
        if !isNameValid { return "Solo letras, números, - y _ (máx. 64)." }
        if takenNames.contains(name) { return "Ya existe un servidor con ese nombre." }
        switch transport {
        case .stdio:
            if command.trimmingCharacters(in: .whitespaces).isEmpty {
                return "El comando no puede estar vacío (p. ej. npx)."
            }
        case .streamableHttp:
            let value = url.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return "La URL no puede estar vacía." }
            guard let parsed = URL(string: value),
                  parsed.scheme == "http" || parsed.scheme == "https",
                  parsed.host != nil
            else { return "URL http(s) no válida." }
        }
        return nil
    }

    var isValid: Bool { validationError() == nil }

    /// `true` cuando este servidor admite OAuth vía `muse mcp login`
    /// (solo las entradas streamable-HTTP, según la ayuda del CLI).
    var supportsLogin: Bool { transport == .streamableHttp }

    var detailSummary: String {
        switch transport {
        case .stdio:
            let rest = args.isEmpty ? "" : " " + args.joined(separator: " ")
            return command + rest
        case .streamableHttp:
            return url
        }
    }

    var isProbablyAuthenticated: Bool {
        guard let login = lastLoginAt else { return false }
        guard let logout = lastLogoutAt else { return true }
        return login > logout
    }

    // MARK: - Entrada `settings.json` de muse

    /// Entrada exacta que `muse` espera bajo `mcpServers.<name>`.
    /// Invariantes del spike validado: siempre `"mode": "optional"` (un
    /// servidor caído con `required` deja al usuario sin chat) y jamás
    /// `required`+`mode` juntos (fault que anula todo el miembro MCP).
    func settingsEntry() -> [String: Any] {
        var entry: [String: Any] = ["mode": "optional", "enabled": enabled]
        switch transport {
        case .stdio:
            entry["type"] = "stdio"
            entry["command"] = command
            entry["args"] = args
            entry["env"] = env
        case .streamableHttp:
            entry["type"] = "streamable-http"
            entry["url"] = url
            entry["headers"] = headers
        }
        return entry
    }
}

/// Parsea líneas `CLAVE=valor` (una por línea) al diccionario literal.
/// Sin valor = cadena vacía. Las líneas sin `=` o sin clave se ignoran.
func parseKeyValueLines(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }
        result[key] = String(line[line.index(after: equals)...])
    }
    return result
}

/// Serializa un diccionario a líneas `CLAVE=valor` ordenadas, para el editor.
func keyValueLines(_ dict: [String: String]) -> String {
    dict.keys.sorted().map { "\($0)=\(dict[$0] ?? "")" }.joined(separator: "\n")
}
