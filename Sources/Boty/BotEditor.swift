import AppKit
import SwiftUI

struct BotFormView: View {
    let store: BotStore
    let bot: Bot?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomScale) private var zoomScale

    @State private var name: String
    @State private var specialty: String
    @State private var colorHex: String
    @State private var systemPrompt: String
    @State private var model: String
    @State private var customModel: String
    @State private var effort: String
    @State private var workspacePath: String
    @State private var availableModels: [CatalogModel]

    /// Opción del desplegable para escribir un ID de modelo a mano.
    private static let customSentinel = "boty:custom"

    init(store: BotStore, bot: Bot?) {
        self.store = store
        self.bot = bot
        let catalog = loadModelCatalogModels()
        _availableModels = State(initialValue: catalog)
        _name = State(initialValue: bot?.name ?? "")
        _specialty = State(initialValue: bot?.specialty ?? "")
        _colorHex = State(initialValue: bot?.colorHex ?? Bot.defaultColors.randomElement() ?? "#0A84FF")
        _systemPrompt = State(initialValue: bot?.systemPrompt ?? "")
        _effort = State(initialValue: bot?.effort ?? "low")
        _workspacePath = State(initialValue: bot?.workspacePath ?? "")
        // El valor guardado que no está en el catálogo se conserva como
        // personalizado para no perderlo al abrir el editor.
        let saved = bot?.model ?? ""
        if !catalog.isEmpty, !saved.isEmpty, !catalog.contains(where: { $0.modelId == saved }) {
            _model = State(initialValue: Self.customSentinel)
            _customModel = State(initialValue: saved)
        } else {
            _model = State(initialValue: saved)
            _customModel = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(bot == nil ? "Nuevo bot" : "Editar bot")
                .font(zoomFont(.headline, scale: zoomScale, weight: .semibold))
                .padding(.top)
            Form {
                TextField("Nombre", text: $name, prompt: Text("p. ej. Coder"))
                TextField("Especialidad", text: $specialty, prompt: Text("p. ej. Programa en Swift"))
                colorPicker
                modelField
                Picker("Esfuerzo", selection: $effort) {
                    ForEach(Bot.efforts, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    TextField(
                        "Carpeta de trabajo",
                        text: $workspacePath,
                        prompt: Text("vacío = tu carpeta personal")
                    )
                    Button("Examinar") { pickWorkspace() }
                }
                Section("Prompt de sistema / contexto") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.visible)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let bot {
                    Button("Eliminar", role: .destructive) {
                        store.deleteBot(id: bot.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private var colorPicker: some View {
        HStack {
            Text("Color")
            Spacer()
            ForEach(Bot.defaultColors, id: \.self) { hex in
                Button {
                    colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(Color.primary, lineWidth: colorHex == hex ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Carpeta donde «\(name.isEmpty ? "el bot" : name)» podrá leer y trabajar"
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
        }
    }

    /// Desplegable con los modelos de tu suscripción. Si el catálogo no
    /// está disponible (muse aún no lo ha descargado), cae al campo de
    /// texto libre de antes para no bloquear la edición.
    @ViewBuilder
    private var modelField: some View {
        if availableModels.isEmpty {
            TextField(
                "Modelo",
                text: $model,
                prompt: Text("vacío = modelo por defecto de tu suscripción")
            )
        } else {
            Picker("Modelo", selection: $model) {
                Text(defaultModelLabel).tag("")
                ForEach(availableModels) { catalogModel in
                    Text(catalogModel.pickerLabel).tag(catalogModel.modelId)
                }
                Text("Personalizado…").tag(Self.customSentinel)
            }
            if model == Self.customSentinel {
                TextField(
                    "ID del modelo",
                    text: $customModel,
                    prompt: Text("p. ej. muse-spark-1.3")
                )
            }
        }
    }

    private var defaultModelLabel: String {
        if let current = availableModels.first(where: { $0.isDefault }) {
            "Por defecto (\(current.modelId))"
        } else {
            "Por defecto de tu suscripción"
        }
    }

    /// Modelo efectivo a guardar: el del desplegable, o el texto libre
    /// cuando se eligió "Personalizado…". Vacío = defecto (`muse exec`
    /// sin `--model`).
    private var effectiveModel: String {
        if !availableModels.isEmpty, model == Self.customSentinel {
            customModel.trimmingCharacters(in: .whitespaces)
        } else {
            model.trimmingCharacters(in: .whitespaces)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if var existing = bot {
            existing.name = trimmedName
            existing.specialty = specialty
            existing.colorHex = colorHex
            existing.systemPrompt = systemPrompt
            existing.model = effectiveModel
            existing.effort = effort
            existing.workspacePath = workspacePath.trimmingCharacters(in: .whitespaces)
            store.updateBot(existing)
        } else {
            store.addBot(Bot(
                name: trimmedName,
                specialty: specialty,
                colorHex: colorHex,
                systemPrompt: systemPrompt,
                model: effectiveModel,
                effort: effort,
                workspacePath: workspacePath.trimmingCharacters(in: .whitespaces)
            ))
        }
        dismiss()
    }
}

struct SettingsView: View {
    @ObservedObject var store: BotStore
    @ObservedObject var usage: UsageTracker
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomScale) private var zoomScale
    @State private var musePath: String
    @State private var followMentions: Bool
    @State private var autoRouteGroups: Bool
    @State private var codeTheme: CodeThemeName
    @State private var completionSound: Bool
    @State private var detection: String

    init(store: BotStore, usage: UsageTracker) {
        _store = ObservedObject(wrappedValue: store)
        _usage = ObservedObject(wrappedValue: usage)
        _musePath = State(initialValue: store.settings.musePath)
        _followMentions = State(initialValue: store.settings.followBotMentions)
        _autoRouteGroups = State(initialValue: store.settings.autoRouteGroups)
        _codeTheme = State(initialValue: store.settings.codeTheme)
        _completionSound = State(initialValue: store.settings.completionSoundEnabled)
        _detection = State(initialValue: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Ajustes")
                .font(zoomFont(.headline, scale: zoomScale, weight: .semibold))
                .padding(.top)
            Form {
                Section("Muse Code") {
                    HStack {
                        TextField(
                            "Ruta del CLI muse",
                            text: $musePath,
                            prompt: Text("vacío = detectar automáticamente")
                        )
                        Button("Detectar") { detect() }
                    }
                    if !detection.isEmpty {
                        Text(detection)
                            .font(zoomFont(.caption1, scale: zoomScale))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section("Coordinación entre bots") {
                    Toggle("Seguir menciones @ entre bots", isOn: $followMentions)
                    Text("Los bots se pasan la palabra con @nombre sin límite de turnos, hasta que responden sin mencionar a nadie.")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                    Toggle("Enrutado automático en grupos", isOn: $autoRouteGroups)
                    Text("Un mediador oculto decide qué miembro responde (uno solo) a cada mensaje sin @menciones. Apagado, responden todos.")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                Section("Avisos") {
                    Toggle("Sonido al terminar de responder", isOn: $completionSound)
                    Text("Suena un bip cuando los bots terminan y el hilo queda esperando tu mensaje.")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                Section("Código") {
                    Picker("Tema de resaltado", selection: $codeTheme) {
                        ForEach(CodeThemeName.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                }
                Section("Suscripción") {
                    if let current = usage.usage {
                        Text("Actual: \(current.windowPercent) % (se renueva \(current.windowResets)).")
                        Text("Semanal: \(current.weeklyPercent) % (se renueva \(current.weeklyResets)).")
                        Text(current.tier)
                            .foregroundStyle(.secondary)
                    } else if usage.isFetching {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Leyendo /usage…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = usage.errorMessage {
                        Text("Uso no disponible: \(error).")
                            .foregroundStyle(.secondary)
                            .help("Abre `muse` en la terminal y ejecuta /usage para comprobar tu sesión")
                    } else {
                        Text("Aún sin leer.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Actualizar uso ahora") { refreshUsage() }
                        .disabled(usage.isFetching)
                        .help("Lee /usage ahora (tarda ~15 s)")
                    Text("El % es el real de tu suscripción, leído de /usage.")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Las respuestas se generan con tu suscripción de Muse Code a través del comando `muse exec`. Cada bot y cada grupo tiene su propia conversación y sesión.")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cerrar") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            detect()
            if usage.usage == nil {
                refreshUsage()
            }
        }
    }

    private func refreshUsage() {
        usage.refresh(musePath: MuseClient.resolveMusePath(override: store.settings.musePath))
    }

    private func detect() {
        if let found = MuseClient.resolveMusePath(override: musePath) {
            detection = "muse encontrado en: \(found)"
        } else {
            detection = "No se encontró `muse`. Instálalo o escribe su ruta completa."
        }
    }

    private func save() {
        store.settings.musePath = musePath.trimmingCharacters(in: .whitespaces)
        store.settings.followBotMentions = followMentions
        store.settings.autoRouteGroups = autoRouteGroups
        store.settings.codeTheme = codeTheme
        store.settings.completionSoundEnabled = completionSound
        store.save()
        dismiss()
    }
}
