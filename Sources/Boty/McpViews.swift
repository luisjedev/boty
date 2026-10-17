import SwiftUI

/// Sheet dedicada "MCPs": lista, alta, edición, borrado, toggle on/off,
/// Conectar/Desconectar (OAuth) y banner de conflicto legacy.
///
/// Es una sheet propia (no una fila del sidebar de chats): no toca la
/// selección activeBot/Group. Los servidores son globales y también quedan
/// disponibles en la terminal del usuario; la UI lo documenta.
struct McpSheetView: View {
    @ObservedObject var mcp: McpStore
    let musePath: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomScale) private var zoomScale

    @State private var editingServer: McpServer?
    @State private var showingNew = false
    @State private var runningAction: String?
    @State private var actionMessage: String?
    @State private var pendingLogin: McpServer?
    @State private var serverToDelete: McpServer?

    var body: some View {
        VStack(spacing: 0) {
            Text("MCPs")
                .font(zoomFont(.headline, scale: zoomScale, weight: .semibold))
                .padding(.top)
            if mcp.legacyConflict {
                legacyBanner
            }
            if let syncError = mcp.syncError {
                Text(syncError)
                    .font(zoomFont(.caption1, scale: zoomScale))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }
            if let actionMessage {
                Text(actionMessage)
                    .font(zoomFont(.caption1, scale: zoomScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }
            List {
                if mcp.servers.isEmpty {
                    Text("Sin servidores MCP. Añade uno con el botón de abajo: los stdio (p. ej. vía npx/uvx) funcionan sin login; los HTTP con OAuth necesitan Conectar.")
                        .font(zoomFont(.body, scale: zoomScale))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mcp.servers) { server in
                        McpRowView(
                            server: server,
                            isRunning: runningAction == server.name,
                            onToggle: { mcp.setEnabled(id: server.id, enabled: $0) },
                            onEdit: { editingServer = server },
                            onDelete: { serverToDelete = server },
                            onLogin: { pendingLogin = server },
                            onLogout: { logout(server) }
                        )
                    }
                }
            }
            .listStyle(.inset)
            Text("Globales: también disponibles en tu terminal (`muse`). Efectivos en el próximo mensaje del chat.")
                .font(zoomFont(.caption1, scale: zoomScale))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 4)
            Divider()
            HStack {
                Button {
                    showingNew = true
                } label: {
                    Label("Nuevo servidor", systemImage: "plus")
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 480)
        .sheet(isPresented: $showingNew) {
            McpFormView(mcp: mcp, server: nil)
        }
        .sheet(item: $editingServer) { server in
            McpFormView(mcp: mcp, server: server)
        }
        .confirmationDialog(
            "Conectar con OAuth",
            isPresented: Binding(
                get: { pendingLogin != nil },
                set: { if !$0 { pendingLogin = nil } }
            ),
            presenting: pendingLogin
        ) { server in
            Button("Abrir navegador y conectar") { login(server) }
            Button("Cancelar", role: .cancel) {}
        } message: { server in
            Text("Se abrirá el navegador para autorizar «\(server.name)» en:\n\(server.url)")
        }
        .confirmationDialog(
            "Eliminar servidor",
            isPresented: Binding(
                get: { serverToDelete != nil },
                set: { if !$0 { serverToDelete = nil } }
            ),
            presenting: serverToDelete
        ) { server in
            Button("Eliminar «\(server.name)»", role: .destructive) {
                mcp.delete(id: server.id)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { server in
            Text("«\(server.name)» dejará de declararse en el settings.json de muse.")
        }
        .onAppear {
            mcp.refreshLegacyState()
        }
    }

    private var legacyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Tu settings.json mezcla `mcp_servers` (antiguo) con `mcpServers`: muse ignora TODOS los MCP en ese estado.")
                .font(zoomFont(.caption1, scale: zoomScale))
            Spacer()
            Button("Migrar") {
                let moved = mcp.migrateLegacy()
                actionMessage = moved > 0
                    ? "Migración completa: \(moved) servidor(es) movidos a `mcpServers`."
                    : "Migración completa: clave antigua eliminada."
            }
            .buttonStyle(.link)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private func login(_ server: McpServer) {
        runningAction = server.name
        actionMessage = nil
        Task {
            do {
                let output = try await McpAuthRunner.login(server: server.name, musePath: musePath)
                await MainActor.run {
                    mcp.markLogin(serverName: server.name)
                    runningAction = nil
                    actionMessage = output.isEmpty ? "«\(server.name)» conectado." : output
                }
            } catch {
                await MainActor.run {
                    runningAction = nil
                    actionMessage = "No se pudo conectar «\(server.name)»: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }

    private func logout(_ server: McpServer) {
        runningAction = server.name
        actionMessage = nil
        Task {
            do {
                let output = try await McpAuthRunner.logout(server: server.name, musePath: musePath)
                await MainActor.run {
                    mcp.markLogout(serverName: server.name)
                    runningAction = nil
                    actionMessage = output.isEmpty ? "«\(server.name)» desconectado." : output
                }
            } catch {
                await MainActor.run {
                    runningAction = nil
                    actionMessage = "No se pudo desconectar «\(server.name)»: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }
}

private struct McpRowView: View {
    let server: McpServer
    let isRunning: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onLogin: () -> Void
    let onLogout: () -> Void
    @Environment(\.zoomScale) private var zoomScale

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(zoomFont(.body, scale: zoomScale, weight: .medium))
                    Text(server.transport.displayName)
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    if !server.enabled {
                        Text("apagado")
                            .font(zoomFont(.caption1, scale: zoomScale))
                            .foregroundStyle(.orange)
                    } else if server.supportsLogin {
                        Text(server.isProbablyAuthenticated ? "conectado" : "sin conectar")
                            .font(zoomFont(.caption1, scale: zoomScale))
                            .foregroundStyle(server.isProbablyAuthenticated ? .green : .secondary)
                    }
                }
                Text(server.detailSummary)
                    .font(zoomFont(.caption1, scale: zoomScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else if server.supportsLogin, server.enabled {
                if server.isProbablyAuthenticated {
                    Button("Desconectar") { onLogout() }
                        .buttonStyle(.link)
                } else {
                    Button("Conectar") { onLogin() }
                        .buttonStyle(.link)
                }
            }
            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help("Activar o desactivar «\(server.name)»")
            Button("Editar") { onEdit() }
                .buttonStyle(.link)
            Button("Eliminar", role: .destructive) { onDelete() }
                .buttonStyle(.link)
        }
        .padding(.vertical, 2)
    }
}

/// Alta y edición de un servidor MCP (stdio o streamable-HTTP).
/// Sin JSON manual: el formulario genera la entrada exacta.
struct McpFormView: View {
    @ObservedObject var mcp: McpStore
    let server: McpServer?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zoomScale) private var zoomScale

    @State private var name: String
    @State private var transport: McpTransport
    @State private var command: String
    @State private var argsText: String
    @State private var envText: String
    @State private var url: String
    @State private var headersText: String
    @State private var enabled: Bool

    init(mcp: McpStore, server: McpServer?) {
        self.mcp = mcp
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _transport = State(initialValue: server?.transport ?? .stdio)
        _command = State(initialValue: server?.command ?? "")
        _argsText = State(initialValue: (server?.args ?? []).joined(separator: " "))
        _envText = State(initialValue: keyValueLines(server?.env ?? [:]))
        _url = State(initialValue: server?.url ?? "")
        _headersText = State(initialValue: keyValueLines(server?.headers ?? [:]))
        _enabled = State(initialValue: server?.enabled ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(server == nil ? "Nuevo servidor MCP" : "Editar «\(server?.name ?? "")»")
                .font(zoomFont(.headline, scale: zoomScale, weight: .semibold))
                .padding(.top)
            Form {
                TextField("Nombre", text: $name, prompt: Text("p. ej. fetch"))
                Text("El nombre es global: clave en el settings.json de muse. Solo letras, números, - y _.")
                    .font(zoomFont(.caption1, scale: zoomScale))
                    .foregroundStyle(.secondary)
                Picker("Tipo", selection: $transport) {
                    Text("stdio (comando local: npx, uvx…)").tag(McpTransport.stdio)
                    Text("HTTP (streamable-HTTP con OAuth)").tag(McpTransport.streamableHttp)
                }
                Toggle("Activado", isOn: $enabled)
                if transport == .stdio {
                    TextField("Comando", text: $command, prompt: Text("p. ej. npx"))
                    Text("Al guardar se resuelve a ruta absoluta (las apps no heredan tu PATH de terminal).")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                    TextField("Argumentos", text: $argsText, prompt: Text("p. ej. -y @modelcontextprotocol/server-fetch"))
                    Section("Variables de entorno (una CLAVE=valor por línea)") {
                        TextEditor(text: $envText)
                            .frame(minHeight: 70)
                            .scrollContentBackground(.visible)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor))
                            )
                    }
                } else {
                    TextField("URL", text: $url, prompt: Text("https://…/mcp"))
                    Section("Cabeceras (una Clave=valor por línea)") {
                        TextEditor(text: $headersText)
                            .frame(minHeight: 70)
                            .scrollContentBackground(.visible)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor))
                            )
                    }
                    Text("Los servidores HTTP usan OAuth: tras guardar, pulsa Conectar para autorizar en el navegador.")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                if let error = draftError {
                    Text(error)
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftError != nil)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private var draft: McpServer {
        McpServer(
            id: server?.id ?? UUID(),
            name: name,
            transport: transport,
            command: command.trimmingCharacters(in: .whitespaces),
            args: argsText.split(separator: " ").map(String.init),
            env: parseKeyValueLines(envText),
            url: url.trimmingCharacters(in: .whitespaces),
            headers: parseKeyValueLines(headersText),
            enabled: enabled,
            lastLoginAt: server?.lastLoginAt,
            lastLogoutAt: server?.lastLogoutAt
        )
    }

    private var draftError: String? {
        draft.validationError(takenNames: mcp.takenNames(except: server?.id))
    }

    private func save() {
        guard draftError == nil else { return }
        if server != nil {
            mcp.update(draft)
        } else {
            mcp.add(draft)
        }
        dismiss()
    }
}
