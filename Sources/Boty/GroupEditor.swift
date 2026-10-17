import AppKit
import SwiftUI

struct GroupFormView: View {
    let store: BotStore
    let group: BotGroup?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomScale) private var zoomScale

    @State private var name: String
    @State private var goal: String
    @State private var colorHex: String
    @State private var workspacePath: String
    @State private var selectedBotIds: Set<UUID>

    init(store: BotStore, group: BotGroup?) {
        self.store = store
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _goal = State(initialValue: group?.goal ?? "")
        _colorHex = State(initialValue: group?.colorHex ?? Bot.defaultColors.randomElement() ?? "#0A84FF")
        _workspacePath = State(initialValue: group?.workspacePath ?? "")
        _selectedBotIds = State(initialValue: Set(group?.botIds ?? []))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(group == nil ? "Nuevo grupo" : "Editar grupo")
                .font(zoomFont(.headline, scale: zoomScale, weight: .semibold))
                .padding(.top)
            Form {
                TextField("Nombre", text: $name, prompt: Text("p. ej. Equipo web"))
                colorPicker
                HStack {
                    TextField(
                        "Carpeta de trabajo",
                        text: $workspacePath,
                        prompt: Text("vacío = la de cada bot")
                    )
                    Button("Examinar") { pickWorkspace() }
                }
                Section("Descripción de lo que quieres hacer") {
                    TextEditor(text: $goal)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.visible)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                }
                Section("Bots del grupo") {
                    if store.bots.isEmpty {
                        Text("Aún no hay bots. Crea primero un bot.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.bots) { bot in
                            Toggle(isOn: binding(for: bot.id)) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(hex: bot.colorHex))
                                        .frame(width: 10, height: 10)
                                    Text(bot.name)
                                    Text(bot.specialty)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let group {
                    Button("Eliminar", role: .destructive) {
                        store.deleteGroup(id: group.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty || selectedBotIds.isEmpty
                    )
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

    private func binding(for botId: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedBotIds.contains(botId) },
            set: { checked in
                if checked {
                    selectedBotIds.insert(botId)
                } else {
                    selectedBotIds.remove(botId)
                }
            }
        )
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Carpeta donde trabajará el grupo «\(name.isEmpty ? "nuevo" : name)» (prevalece sobre la de cada bot)"
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Orden estable: el de la lista de bots.
        let orderedIds = store.bots.map(\.id).filter { selectedBotIds.contains($0) }
        if var existing = group {
            existing.name = trimmedName
            existing.goal = goal
            existing.colorHex = colorHex
            existing.workspacePath = workspacePath.trimmingCharacters(in: .whitespaces)
            existing.botIds = orderedIds
            store.updateGroup(existing)
        } else {
            store.addGroup(BotGroup(
                name: trimmedName,
                goal: goal,
                colorHex: colorHex,
                workspacePath: workspacePath.trimmingCharacters(in: .whitespaces),
                botIds: orderedIds
            ))
        }
        dismiss()
    }
}
