import Combine
import Foundation

/// Capa de aplicación: servidores MCP de Boty.
///
/// - Persiste en `mcpServers.json` (misma carpeta de datos que el resto,
///   con permiso `0600`: guarda secretos literales igual que `settings.json`).
/// - Tras cada mutación re-sincroniza al `settings.json` de `muse` vía
///   `McpSettingsSync` (los cambios quedan efectivos en el próximo `exec`).
/// - Ownership por nombre: Boty manda en los suyos y no toca el resto.
/// - Tolerante con ficheros antiguos: lo que falte toma su valor por defecto.
@MainActor
final class McpStore: ObservableObject {
    @Published private(set) var servers: [McpServer] = []
    /// Último error de sincronización, para mostrarlo en la sheet.
    @Published private(set) var syncError: String?
    /// Estado del conflicto legacy (`mcp_servers` + `mcpServers`).
    @Published private(set) var legacyConflict: Bool = false
    /// Hay clave legacy (con o sin conflicto): la migración la limpia.
    @Published private(set) var hasLegacyKey: Bool = false

    private var lastSyncedNames: Set<String> = []
    private let storageOverride: URL?
    /// Raíz de configuración de muse inyectable (XDG temporal en tests).
    private let museConfigOverride: String?

    private var storageDir: URL {
        if let storageOverride { return storageOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Boty", isDirectory: true)
    }

    private var storeFile: URL { storageDir.appendingPathComponent("mcpServers.json") }

    private var museSettingsURL: URL {
        McpSettingsSync.settingsURL(xdgConfigHome: museConfigOverride == "" ? nil : museConfigOverride)
    }

    init(storageDirectory: URL? = nil, museConfigHome: String? = nil) {
        self.storageOverride = storageDirectory
        self.museConfigOverride = museConfigHome
        load()
        refreshLegacyState()
    }

    // MARK: - Mutaciones (todas persisten + re-sincronizan)

    /// Alta: resuelve el comando stdio a ruta absoluta antes de guardar
    /// (las apps GUI heredan un PATH pobre y `muse` podría no resolverlo).
    func add(_ server: McpServer) {
        var normalized = server
        if normalized.transport == .stdio {
            normalized.command = McpCommandResolver.resolve(normalized.command)
        }
        servers.append(normalized)
        save()
        syncNow()
    }

    func update(_ server: McpServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let oldName = servers[index].name
        var normalized = server
        if normalized.transport == .stdio,
           normalized.command != servers[index].command
        {
            normalized.command = McpCommandResolver.resolve(normalized.command)
        }
        servers[index] = normalized
        if oldName != normalized.name {
            // Renombrado: el nombre viejo es stale y debe salir del settings.
            lastSyncedNames.insert(oldName)
        }
        save()
        syncNow()
    }

    func delete(id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        lastSyncedNames.insert(servers[index].name)
        servers.remove(at: index)
        save()
        syncNow()
    }

    func setEnabled(id: UUID, enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].enabled = enabled
        save()
        syncNow()
    }

    func markLogin(serverName: String) {
        guard let index = servers.firstIndex(where: { $0.name == serverName }) else { return }
        servers[index].lastLoginAt = Date()
        save()
    }

    func markLogout(serverName: String) {
        guard let index = servers.firstIndex(where: { $0.name == serverName }) else { return }
        servers[index].lastLogoutAt = Date()
        save()
    }

    /// Nombres ocupados por otros servidores (unicidad en el editor).
    func takenNames(except id: UUID? = nil) -> Set<String> {
        Set(servers.filter { $0.id != id }.map(\.name))
    }

    // MARK: - Sincronización

    /// Relee el estado legacy y fusiona al `settings.json` de muse.
    func syncNow() {
        refreshLegacyState()
        do {
            let stale = lastSyncedNames.subtracting(servers.map(\.name))
            let synced = try McpSettingsSync.sync(servers: servers, staleNames: stale, at: museSettingsURL)
            lastSyncedNames = synced
            syncError = nil
            save()
        } catch {
            syncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Migración explícita del conflicto legacy (botón del banner).
    /// Mueve `mcp_servers` → `mcpServers` sin pisar, elimina la clave
    /// legacy y re-sincroniza. Devuelve las entradas movidas.
    @discardableResult
    func migrateLegacy() -> Int {
        do {
            let moved = try McpSettingsSync.migrateLegacy(at: museSettingsURL)
            refreshLegacyState()
            syncNow()
            return moved
        } catch {
            syncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return 0
        }
    }

    func refreshLegacyState() {
        if let settings = try? McpSettingsSync.readSettings(at: museSettingsURL) {
            legacyConflict = McpSettingsSync.hasLegacyConflict(settings)
            hasLegacyKey = McpSettingsSync.hasLegacyKey(settings)
        } else {
            legacyConflict = false
            hasLegacyKey = false
        }
    }

    // MARK: - Persistencia

    private struct StoreFile: Codable {
        var servers: [McpServer] = []
        var lastSyncedNames: [String] = []

        private enum CodingKeys: String, CodingKey {
            case servers, lastSyncedNames
        }

        init(servers: [McpServer] = [], lastSyncedNames: [String] = []) {
            self.servers = servers
            self.lastSyncedNames = lastSyncedNames
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            servers = try container.decodeIfPresent([McpServer].self, forKey: .servers) ?? []
            lastSyncedNames = try container.decodeIfPresent([String].self, forKey: .lastSyncedNames) ?? []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let file = StoreFile(servers: servers, lastSyncedNames: Array(lastSyncedNames))
            try JSONEncoder().encode(file).write(to: storeFile, options: .atomic)
            // Secretos literales en disco: solo el dueño puede leerlo.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeFile.path)
        } catch {
            print("Boty: no se pudo guardar MCPs: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeFile),
              let loaded = try? JSONDecoder().decode(StoreFile.self, from: data)
        else { return }
        servers = loaded.servers
        lastSyncedNames = Set(loaded.lastSyncedNames)
    }
}
