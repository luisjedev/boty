import Foundation

/// Infraestructura: sincronización de los servidores de Boty con el
/// `settings.json` real de `muse`.
///
/// Hallazgos del spike (Arquitecto, verificados contra el CLI real) que
/// este motor respeta:
/// - `muse -c` NO sirve para MCP (mapa entero / servidor nuevo / campo
///   existente, las tres formas rechazadas). Único camino: el fichero.
/// - Formato exacto por entrada: `type` + `command/args/env` (stdio) o
///   `url/headers` (streamable-http), más `mode: "optional"` invariante.
/// - Trampa legacy: si coexisten `mcp_servers` + `mcpServers`, el loader
///   tira TODOS los MCP. Este motor nunca crea ese estado y lo detecta.
/// - Cambios efectivos en el próximo `exec`: sin tocar `MuseClient`.
enum McpSettingsSync {
    /// Clave moderna que lee `muse`.
    static let serversKey = "mcpServers"
    /// Clave legacy que, coexistiendo con la moderna, anula todos los MCP.
    static let legacyKey = "mcp_servers"

    /// Ruta del `settings.json` de muse. Respeta `XDG_CONFIG_HOME` (también
    /// es lo que permite a los tests apuntar a un directorio temporal).
    static func settingsURL(xdgConfigHome: String? = nil) -> URL {
        let override = xdgConfigHome
            ?? ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("muse/settings.json")
        }
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config/muse/settings.json")
    }

    /// Lee el `settings.json` como diccionario mutable. Fichero ausente =
    /// diccionario vacío (no es error). Fichero corrupto = error.
    static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw McpSyncError.corruptSettings(url.path)
        }
        return object
    }

    /// `true` cuando el fichero mezcla `mcp_servers` + `mcpServers`: el
    /// loader de muse tira todos los MCP en ese estado.
    static func hasLegacyConflict(_ settings: [String: Any]) -> Bool {
        settings[legacyKey] != nil && settings[serversKey] != nil
    }

    static func hasLegacyKey(_ settings: [String: Any]) -> Bool {
        settings[legacyKey] != nil
    }

    /// Fusiona los servidores de Boty en el `settings.json` con ownership
    /// por nombre: Boty manda en los suyos (upsert) y elimina los que dejó
    /// de gestionar (`staleNames`), sin tocar ninguna otra entrada ni
    /// ninguna otra clave del fichero. Escritura atómica + relectura de
    /// verificación. Devuelve los nombres que quedaron sincronizados.
    ///
    /// - Parameter servers: servidores actuales de Boty.
    /// - Parameter staleNames: nombres que Boty sincronizó antes y ya no
    ///   gestiona (borrados o renombrados): se eliminan del fichero.
    @discardableResult
    static func sync(
        servers: [McpServer],
        staleNames: Set<String> = [],
        at url: URL? = nil
    ) throws -> Set<String> {
        let fileURL = url ?? settingsURL()
        var settings = try readSettings(at: fileURL)
        var current = settings[serversKey] as? [String: Any] ?? [:]
        for stale in staleNames where !servers.contains(where: { $0.name == stale }) {
            current.removeValue(forKey: stale)
        }
        for server in servers {
            current[server.name] = server.settingsEntry()
        }
        settings[serversKey] = current
        try writeAtomically(settings: settings, to: fileURL)
        // Relectura de verificación: lo escrito debe leerse de vuelta.
        let reread = try readSettings(at: fileURL)
        let rereadServers = reread[serversKey] as? [String: Any] ?? [:]
        for server in servers {
            guard rereadServers[server.name] != nil else {
                throw McpSyncError.verifyFailed(server.name)
            }
        }
        return Set(servers.map(\.name))
    }

    /// Migración explícita del conflicto legacy: mueve las entradas de
    /// `mcp_servers` a `mcpServers` (sin pisar las modernas existentes) y
    /// elimina la clave legacy. Solo la invoca el usuario desde el banner.
    /// Devuelve cuántas entradas se movieron.
    @discardableResult
    static func migrateLegacy(at url: URL? = nil) throws -> Int {
        let fileURL = url ?? settingsURL()
        var settings = try readSettings(at: fileURL)
        guard let legacy = settings[legacyKey] as? [String: Any] else { return 0 }
        var current = settings[serversKey] as? [String: Any] ?? [:]
        var moved = 0
        for (name, entry) in legacy where current[name] == nil {
            current[name] = entry
            moved += 1
        }
        settings[serversKey] = current
        settings.removeValue(forKey: legacyKey)
        try writeAtomically(settings: settings, to: fileURL)
        return moved
    }

    /// Escritura atómica que conserva el resto del fichero: temporal en el
    /// mismo directorio + reemplazo. Crea el directorio si falta.
    private static func writeAtomically(settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".settings.json.boty-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            // `replaceItemAt` falla si el destino no existe: caída al
            // movimiento directo, que también es atómico en el mismo fs.
            do {
                try data.write(to: tmp, options: .atomic)
                try fm.moveItem(at: tmp, to: url)
            } catch {
                try? fm.removeItem(at: tmp)
                throw McpSyncError.writeFailed(error.localizedDescription)
            }
        }
    }
}

enum McpSyncError: Error, LocalizedError, Equatable {
    case corruptSettings(String)
    case writeFailed(String)
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .corruptSettings(let path):
            return "El settings.json de muse está corrupto (\(path)). Revísalo antes de sincronizar MCPs."
        case .writeFailed(let detail):
            return "No pude escribir el settings.json de muse: \(detail)"
        case .verifyFailed(let name):
            return "La sincronización no se verificó para «\(name)». Reintenta."
        }
    }
}

/// Infraestructura: resuelve un comando (`npx`, `uvx`…) a ruta absoluta.
///
/// Las apps GUI heredan un PATH pobre y `muse exec` puede no resolver el
/// comando después; por eso Boty almacena la ruta absoluta al guardar.
enum McpCommandResolver {
    /// Resuelve `command` a absoluta vía login shell (`command -v`).
    /// Si ya es ruta (contiene `/`) o no se resuelve, devuelve el input.
    static func resolve(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            return (trimmed as NSString).expandingTildeInPath
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(shellQuote(trimmed))"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return trimmed
        }
        guard proc.terminationStatus == 0 else { return trimmed }
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? trimmed : found
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
