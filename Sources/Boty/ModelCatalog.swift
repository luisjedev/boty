import Foundation

/// Un modelo del catálogo de la suscripción, tal como lo guarda `muse`
/// en `~/.local/share/muse/model-catalog/` (la misma lista que `/models`
/// muestra en el TUI).
struct CatalogModel: Identifiable, Hashable, Sendable {
    var id: String { modelId }
    var modelId: String
    var displayLabel: String
    var isCurrent: Bool
    var isDefault: Bool
    var details: String?

    /// Etiqueta para el desplegable, marcando el modelo por defecto.
    var pickerLabel: String {
        if isDefault { return "\(displayLabel) (por defecto)" }
        if isCurrent { return "\(displayLabel) (actual)" }
        return displayLabel
    }
}

/// Directorio donde `muse` guarda el catálogo de modelos del proveedor.
/// Respeta `XDG_DATA_HOME` igual que el CLI.
func modelCatalogDirectory() -> URL {
    let base: String
    if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
        base = xdg
    } else {
        base = (NSHomeDirectory() as NSString).appendingPathComponent(".local/share")
    }
    return URL(
        fileURLWithPath: (base as NSString).appendingPathComponent("muse/model-catalog"),
        isDirectory: true
    )
}

/// Parsea un fichero del catálogo (`{"rows": [...]}`). Función pura y
/// tolerante: solo devuelve filas visibles con `model_id`, el resto se
/// ignora en vez de invalidar todo el fichero.
func parseModelCatalogFile(_ data: Data) -> [CatalogModel] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["rows"] as? [[String: Any]]
    else { return [] }
    return rows.compactMap { row in
        guard let modelId = row["model_id"] as? String, !modelId.isEmpty else { return nil }
        let visibility = (row["visibility"] as? String) ?? "visible"
        guard visibility == "visible" else { return nil }
        let label = (row["display_label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? modelId
        return CatalogModel(
            modelId: modelId,
            displayLabel: label,
            isCurrent: (row["is_current"] as? Bool) ?? false,
            isDefault: (row["is_default"] as? Bool) ?? false,
            details: row["description"] as? String
        )
    }
}

/// Lee todos los `*.json` del catálogo y devuelve los modelos visibles
/// sin duplicados (por `model_id`), con el modelo por defecto primero.
/// `muse` mantiene estos ficheros al día solo; si no existen o están
/// vacíos, devuelve `[]` y el editor cae al campo de texto libre.
func loadModelCatalogModels(directory: URL? = nil) -> [CatalogModel] {
    let dir = directory ?? modelCatalogDirectory()
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { return [] }
    var seen = Set<String>()
    var models: [CatalogModel] = []
    for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file) else { continue }
        for model in parseModelCatalogFile(data) where seen.insert(model.modelId).inserted {
            models.append(model)
        }
    }
    models.sort { ($0.isDefault ? 0 : 1, $0.modelId) < ($1.isDefault ? 0 : 1, $1.modelId) }
    return models
}
