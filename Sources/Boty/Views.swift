import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        // Al lanzar desde la terminal, traer la ventana al frente.
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct BotyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = BotStore()

    var body: some Scene {
        WindowGroup("Boty") {
            ContentView(store: store)
                .frame(minWidth: 820, minHeight: 560)
        }
        // Sin texto en la barra de título: el título principal es el
        // nombre del bot/grupo en la cabecera del chat.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1050, height: 700)
        .commands {
            CommandMenu("Vista") {
                Button("Acercar") { store.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Alejar") { store.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Tamaño real") { store.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: BotStore
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var usage = UsageTracker()
    @State private var editingBot: Bot?
    @State private var showingNewBot = false
    @State private var editingGroup: BotGroup?
    @State private var showingNewGroup = false
    @State private var showingSettings = false
    @State private var showingMcp = false
    @StateObject private var mcpStore = McpStore()

    init(store: BotStore) {
        _store = ObservedObject(wrappedValue: store)
        _viewModel = StateObject(wrappedValue: ChatViewModel(store: store))
    }

    /// Escala de zoom actual: se publica en el entorno y como letra base
    /// para que todo el texto sin fuente explícita la herede (incluidos
    /// los diálogos, que heredan el entorno de esta vista).
    private var zoom: Double {
        zoomScale(forZoomStep: store.settings.zoomStep)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                viewModel: viewModel,
                usage: usage,
                showingNewBot: $showingNewBot,
                showingNewGroup: $showingNewGroup,
                showingSettings: $showingSettings,
                showingMcp: $showingMcp,
                editingBot: $editingBot,
                editingGroup: $editingGroup
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 330)
        } detail: {
            ChatView(viewModel: viewModel)
        }
        .environment(\.zoomScale, zoom)
        .font(zoomFont(.body, scale: zoom))
        .sheet(isPresented: $showingNewBot) {
            BotFormView(store: store, bot: nil)
        }
        .sheet(item: $editingBot) { bot in
            BotFormView(store: store, bot: bot)
        }
        .sheet(isPresented: $showingNewGroup) {
            GroupFormView(store: store, group: nil)
        }
        .sheet(item: $editingGroup) { group in
            GroupFormView(store: store, group: group)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, usage: usage)
        }
        .sheet(isPresented: $showingMcp) {
            McpSheetView(
                mcp: mcpStore,
                musePath: MuseClient.resolveMusePath(override: store.settings.musePath)
            )
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: BotStore
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var usage: UsageTracker
    @Environment(\.zoomScale) private var zoomScale
    @Binding var showingNewBot: Bool
    @Binding var showingNewGroup: Bool
    @Binding var showingSettings: Bool
    @Binding var showingMcp: Bool
    @Binding var editingBot: Bot?
    @Binding var editingGroup: BotGroup?
    @State private var renamingThreadId: UUID?
    @State private var renameText = ""
    @State private var threadSearchText = ""

    var body: some View {
        List {
            Section("Bots") {
                ForEach(store.bots) { bot in
                    Button {
                        store.selectBot(id: bot.id)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: bot.colorHex))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name).font(zoomFont(.body, scale: zoomScale))
                                Text(bot.specialty)
                                    .font(zoomFont(.caption1, scale: zoomScale))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if viewModel.isBotRunning(bot.id) {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            if isBotSelected(bot) {
                                Image(systemName: "checkmark")
                                    .font(zoomFont(.caption1, scale: zoomScale))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(
                        isBotSelected(bot) ? Color.accentColor.opacity(0.12) : nil
                    )
                    .contextMenu {
                        Button("Editar") { editingBot = bot }
                        Button("Vaciar conversación") { viewModel.clearThread(botId: bot.id) }
                        Button("Eliminar", role: .destructive) { viewModel.deleteBot(id: bot.id) }
                    }
                }
                Button {
                    showingNewBot = true
                } label: {
                    Label("Nuevo bot", systemImage: "plus")
                        .font(zoomFont(.body, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Grupos") {
                ForEach(store.groups) { group in
                    Button {
                        store.selectGroup(id: group.id)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: group.colorHex))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(zoomFont(.body, scale: zoomScale))
                                Text(groupSubtitle(for: group))
                                    .font(zoomFont(.caption1, scale: zoomScale))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if viewModel.isGroupRunning(group.id) {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            if isGroupSelected(group) {
                                Image(systemName: "checkmark")
                                    .font(zoomFont(.caption1, scale: zoomScale))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(
                        isGroupSelected(group) ? Color.accentColor.opacity(0.12) : nil
                    )
                    .contextMenu {
                        Button("Editar") { editingGroup = group }
                        Button("Vaciar conversación") { viewModel.clearGroupThread(groupId: group.id) }
                        Button("Eliminar", role: .destructive) { viewModel.deleteGroup(id: group.id) }
                    }
                }
                Button {
                    showingNewGroup = true
                } label: {
                    Label("Nuevo grupo", systemImage: "plus")
                        .font(zoomFont(.body, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section(threadSectionTitle) {
                TextField("Buscar en hilos…", text: $threadSearchText)
                    .textFieldStyle(.roundedBorder)
                    .font(zoomFont(.body, scale: zoomScale))
                if isSearchingThreads {
                    ForEach(threadSearchResults) { result in
                        Button {
                            viewModel.revealMessage(threadId: result.threadId, messageId: result.messageId)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(result.threadTitle) · \(result.authorLabel)")
                                    .font(zoomFont(.body, scale: zoomScale, weight: .medium))
                                Text(result.snippet)
                                    .font(zoomFont(.caption1, scale: zoomScale))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .help("Saltar al mensaje en «\(result.threadTitle)»")
                    }
                    if threadSearchResults.isEmpty {
                        Text("Sin coincidencias")
                            .font(zoomFont(.caption1, scale: zoomScale))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(activeOwnerThreads) { thread in
                        Button {
                            store.selectThread(id: thread.id)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title).font(zoomFont(.body, scale: zoomScale))
                                    Text(threadSubtitle(for: thread))
                                        .font(zoomFont(.caption1, scale: zoomScale))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if viewModel.isRunning(for: thread.id) {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                                if store.activeConversation?.id == thread.id {
                                    Image(systemName: "checkmark")
                                        .font(zoomFont(.caption1, scale: zoomScale))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowBackground(
                            store.activeConversation?.id == thread.id ? Color.accentColor.opacity(0.12) : nil
                        )
                        .contextMenu {
                            Button("Renombrar") { beginRename(thread) }
                            Button("Vaciar hilo") { viewModel.clearConversation(id: thread.id) }
                            Button("Exportar a Markdown…") { exportThread(id: thread.id) }
                            Button("Eliminar", role: .destructive) { viewModel.deleteThread(id: thread.id) }
                        }
                    }
                }
                Button {
                    createThread()
                } label: {
                    Label("Nuevo hilo", systemImage: "plus")
                        .font(zoomFont(.body, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .padding(.top, 5)
        .alert("Renombrar hilo", isPresented: isRenaming) {
            TextField("Nombre del hilo", text: $renameText)
            Button("Guardar") {
                if let id = renamingThreadId {
                    store.renameThread(id: id, title: renameText)
                }
                renamingThreadId = nil
            }
            Button("Cancelar", role: .cancel) {
                renamingThreadId = nil
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                UsageFooterView(store: store, usage: usage)
                HStack {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Ajustes", systemImage: "gearshape")
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button {
                        showingMcp = true
                    } label: {
                        Label("MCPs", systemImage: "plug")
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func isBotSelected(_ bot: Bot) -> Bool {
        store.activeGroupId == nil && store.activeBotId == bot.id
    }

    private func isGroupSelected(_ group: BotGroup) -> Bool {
        store.activeGroupId == group.id
    }

    // MARK: - Hilos múltiples

    /// Hilos del dueño actualmente seleccionado (bot o grupo).
    private var activeOwnerThreads: [Conversation] {
        if let group = store.activeGroup {
            return store.groupThreads(for: group.id)
        }
        if let bot = store.activeBot {
            return store.threads(for: bot.id)
        }
        return []
    }

    private var threadSectionTitle: String {
        if let group = store.activeGroup {
            return "Hilos de \(group.name)"
        }
        if let bot = store.activeBot {
            return "Hilos de \(bot.name)"
        }
        return "Hilos"
    }

    private func threadSubtitle(for thread: Conversation) -> String {
        let count = thread.messages.filter { $0.role != "system" }.count
        switch count {
        case 0: return "Vacío"
        case 1: return "1 mensaje"
        default: return "\(count) mensajes"
        }
    }

    private func createThread() {
        if let group = store.activeGroup {
            store.createGroupThread(groupId: group.id)
        } else if let bot = store.activeBot {
            store.createThread(botId: bot.id)
        }
    }

    // MARK: - Buscar y exportar (mejora #3)

    /// Búsqueda activa a partir de 2 caracteres, sobre los hilos del dueño
    /// seleccionado. El resultado salta al hilo y desplaza al mensaje.
    private var isSearchingThreads: Bool {
        threadSearchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private var threadSearchResults: [ThreadSearchResult] {
        searchThreads(
            query: threadSearchText, conversations: activeOwnerThreads,
            bots: store.bots, groups: store.groups
        )
    }

    /// Guarda el hilo en un `.md` elegido con el panel del sistema.
    private func exportThread(id: UUID) {
        guard let exported = viewModel.markdownForConversation(id: id) else { return }
        saveThreadMarkdown(title: exported.title, markdown: exported.markdown)
    }

    private func beginRename(_ thread: Conversation) {
        renameText = thread.title
        renamingThreadId = thread.id
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingThreadId != nil },
            set: { if !$0 { renamingThreadId = nil } }
        )
    }

    private func groupSubtitle(for group: BotGroup) -> String {
        let names = store.memberNames(for: group)
        if names.isEmpty { return "Sin bots" }
        return names.joined(separator: ", ")
    }
}

/// Medidor de suscripción al pie del menú: ventana actual y semanal con
/// % y barra, leídos de `/usage`. Se actualiza al abrir y cada 30 min.
struct UsageFooterView: View {
    @ObservedObject var store: BotStore
    @ObservedObject var usage: UsageTracker
    @Environment(\.zoomScale) private var zoomScale

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: usageAutoRefreshInterval, on: .main, in: .common).autoconnect()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let current = usage.usage {
                UsageBarRow(label: "Actual", percent: current.windowPercent, resets: current.windowResets)
                UsageBarRow(label: "Semanal", percent: current.weeklyPercent, resets: current.weeklyResets)
                HStack(spacing: 6) {
                    Text(current.tier)
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if usage.isFetching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Button {
                        refreshUsage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(zoomFont(.caption1, scale: zoomScale))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(usage.isFetching)
                    .help("Actualizar uso ahora (lee /usage, tarda ~15 s)")
                }
            } else if usage.isFetching {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Leyendo /usage…")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
            } else if let error = usage.errorMessage {
                HStack(spacing: 6) {
                    Text("Uso no disponible: \(error).")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        refreshUsage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(zoomFont(.caption1, scale: zoomScale))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reintentar (lee /usage, tarda ~15 s)")
                }
            } else {
                HStack(spacing: 6) {
                    Text("Uso sin leer.")
                        .font(zoomFont(.caption1, scale: zoomScale))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        refreshUsage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(zoomFont(.caption1, scale: zoomScale))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Leer /usage ahora (tarda ~15 s)")
                }
            }
        }
        .onAppear {
            if usage.usage == nil {
                refreshUsage()
            }
        }
        .onReceive(timer) { _ in
            refreshUsage()
        }
    }

    private func refreshUsage() {
        usage.refresh(musePath: MuseClient.resolveMusePath(override: store.settings.musePath))
    }
}

struct UsageBarRow: View {
    let label: String
    let percent: Int
    let resets: String
    @Environment(\.zoomScale) private var zoomScale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(label) \(percent)%")
                    .font(zoomFont(.caption1, scale: zoomScale, weight: .medium))
                Spacer()
                Text("Renueva \(resets)")
                    .font(zoomFont(.caption1, scale: zoomScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: usageBarFraction(percent: percent))
                .controlSize(.mini)
        }
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.zoomScale) private var zoomScale
    @State private var inputContentHeight: CGFloat = GrowingTextEditor.singleLineHeight()
    @State private var inputFocusToken = 0
    @StateObject private var voice = VoiceDictationManager()
    /// Texto del cajón al pulsar el micrófono: la transcripción en vivo se
    /// fusiona sobre él sin acumular parciales ni perder lo escrito antes.
    @State private var voiceBaseText = ""
    /// Arrastre de archivos sobre la zona de envío.
    @State private var dragOverInput = false

    /// Altura máxima del editor antes de desplazar su contenido interno.
    private let chatInputMaxHeight: CGFloat = 140

    private var messages: [ChatMessage] {
        viewModel.conversation?.messages ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputArea
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let group = viewModel.activeGroup {
                Circle()
                    .fill(Color(hex: group.colorHex))
                    .frame(width: 12, height: 12)
                Text(headerTitle(fallback: group.name))
                    .font(zoomFont(.title3, scale: zoomScale, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(headerGroupSubtitle(for: group))
                    .font(zoomFont(.caption1, scale: zoomScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let bot = viewModel.activeBot {
                Circle()
                    .fill(Color(hex: bot.colorHex))
                    .frame(width: 12, height: 12)
                Text(headerTitle(fallback: bot.name))
                    .font(zoomFont(.title3, scale: zoomScale, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(bot.specialty)
                    .font(zoomFont(.caption1, scale: zoomScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Chat").font(zoomFont(.title3, scale: zoomScale, weight: .semibold))
            }
            Spacer()
            Button {
                exportActiveThread()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(zoomFont(.body, scale: zoomScale))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(viewModel.conversation == nil)
            .help("Exportar hilo a Markdown…")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Guarda el hilo visible en un `.md` elegido con el panel del sistema.
    private func exportActiveThread() {
        guard let exported = viewModel.markdownForConversation() else { return }
        saveThreadMarkdown(title: exported.title, markdown: exported.markdown)
    }

    private func headerGroupSubtitle(for group: BotGroup) -> String {
        let names = viewModel.store.memberNames(for: group)
        if names.isEmpty { return "Sin bots" }
        return names.joined(separator: ", ")
    }

    /// Título de la cabecera: con un solo hilo es el nombre del bot/grupo;
    /// con varios, el título del hilo activo para saber cuál se está viendo.
    private func headerTitle(fallback: String) -> String {
        guard let conversation = viewModel.conversation else { return fallback }
        if let group = viewModel.activeGroup {
            guard viewModel.store.groupThreads(for: group.id).count > 1 else { return fallback }
        } else if let bot = viewModel.activeBot {
            guard viewModel.store.threads(for: bot.id).count > 1 else { return fallback }
        }
        return conversation.title
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, viewModel: viewModel)
                            .id(message.id)
                    }
                    // Centinela al final: desplazarse a él llega hasta abajo
                    // del todo (último mensaje + padding inferior incluidos).
                    Color.clear
                        .frame(height: 1)
                        .id(chatBottomId)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            // Sin ancla de scroll: `.defaultScrollAnchor(.bottom)` provocaba
            // un bucle infinito de layout de AppKit ("more Update Constraints
            // passes than there are views in the window") al abrir hilos
            // largos, que mataba la app con SIGTRAP. Quedarse abajo lo
            // garantizan los reintentos de scrollToBottom (ver ChatScrollTests).
            .onChange(of: messages.count) {
                scrollToBottom(proxy, animated: true, trigger: .newMessage)
            }
            // Durante el streaming solo cambia el contenido: sin animación
            // para no encadenar animaciones que se quedan a medio camino.
            .onChange(of: messages.last?.text) {
                scrollToBottom(proxy, animated: false, trigger: .streamingUpdate)
            }
            .onChange(of: messages.last?.toolNotes) {
                scrollToBottom(proxy, animated: false, trigger: .streamingUpdate)
            }
            // Al cambiar de bot, empezar abajo del todo.
            .onChange(of: viewModel.conversation?.id) {
                scrollToBottom(proxy, animated: false, trigger: .conversationChanged)
            }
            // Salto desde la búsqueda: desplaza al mensaje y limpia el
            // pendiente para no repetirlo. Con animación para orientar.
            .onChange(of: viewModel.pendingJumpMessageId) { _, target in
                guard let target else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    viewModel.consumePendingJump()
                }
            }
            .onAppear {
                scrollToBottom(proxy, animated: false, trigger: .initialAppear)
            }
        }
    }

    private var chatBottomId: String { "chat-bottom" }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool, trigger: ChatScrollTrigger) {
        // En el siguiente ciclo: el LazyVStack ya ha medido el contenido nuevo.
        // Al abrir la app o cambiar de bot, el centinela puede no existir aún
        // (contenido perezoso midiendo el Markdown): se reintenta sin animar.
        DispatchQueue.main.async {
            scrollOnce(proxy, animated: animated)
            for delay in chatScrollRetryDelays(for: trigger) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    scrollOnce(proxy, animated: false)
                }
            }
        }
    }

    private func scrollOnce(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(chatBottomId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(chatBottomId, anchor: .bottom)
        }
    }

    private var inputArea: some View {
        VStack(spacing: 8) {
            if let query = viewModel.mentionQuery() {
                MentionList(viewModel: viewModel, query: query)
            }
            if viewModel.queuedCount > 0 {
                queueRow
            }
            if voice.isRecording {
                voiceRecordingRow
            } else if let error = voice.errorMessage {
                voiceErrorRow(error)
            }
            if let conversationId = viewModel.conversation?.id,
               !viewModel.pending(for: conversationId).isEmpty
            {
                PendingAttachmentsRow(viewModel: viewModel, conversationId: conversationId)
            }
            if let error = viewModel.attachmentError {
                attachmentErrorRow(error)
            }
            inputBox
        }
        .padding()
        .onDrop(of: [.fileURL], isTargeted: $dragOverInput, perform: dropAttachments)
        .onChange(of: voice.liveText) { _, live in
            viewModel.inputText = voiceMergedText(base: voiceBaseText, live: live)
        }
        // Cambiar de bot/grupo con el micro abierto: parar para soltarlo.
        .onChange(of: viewModel.conversation?.id) {
            voice.stop()
        }
    }

    /// Suelta de archivos del Finder sobre la zona de envío.
    private func dropAttachments(_ providers: [NSItemProvider]) -> Bool {
        guard let conversationId = viewModel.conversation?.id else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = {
                    if let direct = item as? URL { return direct }
                    if let data = item as? Data,
                       let string = String(data: data, encoding: .utf8),
                       let parsed = URL(string: string)
                    { return parsed }
                    if let string = item as? String { return URL(string: string) }
                    return nil
                }()
                guard let url else { return }
                Task { @MainActor in
                    viewModel.addAttachments(from: [url], conversationId: conversationId)
                }
            }
        }
        return true
    }

    private func attachmentErrorRow(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(error)
            Spacer()
            Button {
                viewModel.clearAttachmentError()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Descartar")
        }
        .font(zoomFont(.caption1, scale: zoomScale))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private var queueRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
            Text(queueLabel)
            Spacer()
            if !viewModel.isRunning {
                Button("Reanudar") { viewModel.resumeQueue() }
                    .help("Procesar el siguiente mensaje en cola")
            }
            Button {
                viewModel.clearQueue()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Descartar la cola (los mensajes quedan en el chat)")
        }
        .font(zoomFont(.caption1, scale: zoomScale))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private var queueLabel: String {
        viewModel.queuedCount == 1
            ? "1 mensaje en cola — se envía en el siguiente hueco"
            : "\(viewModel.queuedCount) mensajes en cola — se envían en el siguiente hueco"
    }

    /// Fila única y estable: editor flexible, micro y enviar/detener.
    /// El ancho del editor NUNCA depende de la altura medida: alternar entre
    /// HStack (editor estrecho) y VStack (editor a ancho completo) según la
    /// altura provocaba un bucle infinito de layout — una línea que envuelve
    /// a 2 líneas en estrecho pero cabe en 1 en ancho hacía bascular el
    /// contenedor sin fin, petardeando el input y el scroll del chat hasta
    /// casi colgar la app. Solo rasgos verticales dependen de la altura
    /// (padding y alineación): no realimentan el ajuste de línea.
    private var inputBox: some View {
        // Una línea: fila centrada para que texto y placeholder queden
        // centrados en el cajón. Varias: botones abajo, junto a la última
        // línea, como en cualquier chat.
        HStack(alignment: inputRowAlignment, spacing: 10) {
            editorBox
                .frame(height: min(inputContentHeight, chatInputMaxHeight))
            attachButton
            voiceButton
            sendStopButton
        }
        .padding(.horizontal, 12)
        .padding(
            .vertical,
            chatInputVerticalPadding(
                contentHeight: inputContentHeight,
                singleLineHeight: GrowingTextEditor.singleLineHeight(fontSize: editorFontSize)
            )
        )
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    dragOverInput ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: dragOverInput ? 2 : 1
                )
        )
    }

    /// Tamaño de letra del editor, acompasado al zoom de la app.
    private var editorFontSize: CGFloat {
        GrowingTextEditor.baseFontSize * zoomScale
    }

    /// Alineación vertical de la fila del input: centrada con una sola
    /// línea, abajo cuando el texto crece. Solo mueve vistas en vertical,
    /// así que no realimenta el ajuste de línea (ver `inputBox`).
    private var inputRowAlignment: VerticalAlignment {
        chatInputIsMultiline(
            contentHeight: inputContentHeight,
            singleLineHeight: GrowingTextEditor.singleLineHeight(fontSize: editorFontSize)
        ) ? .bottom : .center
    }

    private var editorBox: some View {
        ZStack(alignment: .leading) {
            GrowingTextEditor(
                text: $viewModel.inputText,
                contentHeight: $inputContentHeight,
                focusToken: inputFocusToken,
                fontSize: editorFontSize,
                onSubmit: { voice.stop(); viewModel.send() },
                onEscape: { viewModel.cancel() }
            )
            if viewModel.inputText.isEmpty {
                Text(
                    viewModel.isRunning
                        ? "Escribe feedback… se encolará hasta el siguiente hueco"
                        : "Escribe un mensaje… usa @nombre para invocar a un bot"
                )
                    .font(.system(size: editorFontSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var attachButton: some View {
        Button {
            pickAttachments()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: chatSideIconSize(scale: zoomScale)))
                .frame(
                    minWidth: chatSideTapSize(scale: zoomScale),
                    minHeight: chatSideTapSize(scale: zoomScale)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(viewModel.conversation == nil)
        .help("Adjuntar archivos (o arrástralos aquí): las imágenes las ve el bot, el resto las lee")
    }

    private func pickAttachments() {
        guard let conversationId = viewModel.conversation?.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Adjuntar archivos al mensaje"
        if panel.runModal() == .OK {
            viewModel.addAttachments(from: panel.urls, conversationId: conversationId)
        }
    }

    private var voiceButton: some View {
        Button {
            if !voice.isRecording {
                // Fijar la base antes de arrancar: los parciales se fusionan
                // sobre ella y lo ya escrito no se pierde.
                voiceBaseText = viewModel.inputText
            }
            voice.toggle()
        } label: {
            Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                .font(.system(size: chatSideIconSize(scale: zoomScale)))
                .frame(
                    minWidth: chatSideTapSize(scale: zoomScale),
                    minHeight: chatSideTapSize(scale: zoomScale)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(voice.isRecording ? .red : .secondary)
        .disabled(voice.isRequestingPermission)
        .help(voice.isRecording
            ? "Detener dictado"
            : "Dictar con la voz: transcribe en tiempo real al cajón (revisa y envía tú)")
    }

    private var voiceRecordingRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Escuchando… pulsa el micrófono para detener")
            Spacer()
        }
        .font(zoomFont(.caption1, scale: zoomScale))
        .foregroundStyle(.secondary)
    }

    private func voiceErrorRow(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(error)
            Spacer()
            Button {
                voice.clearError()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Descartar")
        }
        .font(zoomFont(.caption1, scale: zoomScale))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private var sendStopButton: some View {
        Group {
            if viewModel.isRunning {
                HStack(spacing: 10) {
                    Button {
                        voice.stop()
                        viewModel.send()
                        // El clic roba el foco: devolverlo al editor.
                        inputFocusToken += 1
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: chatSendIconSize(scale: zoomScale)))
                            .frame(
                                minWidth: chatSendTapSize(scale: zoomScale),
                                minHeight: chatSendTapSize(scale: zoomScale)
                            )
                    }
                    .buttonStyle(.plain)
                    .opacity(sendDisabled ? 0.4 : 1)
                    .disabled(sendDisabled)
                    .help("Encolar mensaje (Return, Mayús+Return para salto de línea)")
                    Button {
                        viewModel.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: chatSendIconSize(scale: zoomScale)))
                            .frame(
                                minWidth: chatSendTapSize(scale: zoomScale),
                                minHeight: chatSendTapSize(scale: zoomScale)
                            )
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Detener (Esc)")
                    // ESC detiene la respuesta en curso aunque el foco no esté
                    // en el editor (dentro del editor lo gestiona el coordinador).
                    .keyboardShortcut(.cancelAction)
                }
            } else {
                Button {
                    voice.stop()
                    viewModel.send()
                    // El clic roba el foco: devolverlo al editor.
                    inputFocusToken += 1
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: chatSendIconSize(scale: zoomScale)))
                        .frame(
                            minWidth: chatSendTapSize(scale: zoomScale),
                            minHeight: chatSendTapSize(scale: zoomScale)
                        )
                }
                .buttonStyle(.plain)
                .opacity(sendDisabled ? 0.4 : 1)
                .disabled(sendDisabled)
                .help("Enviar (Return, Mayús+Return para salto de línea)")
            }
        }
    }

    private var sendDisabled: Bool {
        if !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        // Sin texto solo se puede enviar si hay adjuntos pendientes.
        guard let conversationId = viewModel.conversation?.id else { return true }
        return viewModel.pending(for: conversationId).isEmpty
    }
}

/// Origen de un scroll al final del chat.
enum ChatScrollTrigger: CaseIterable {
    /// Apertura de la app: el LazyVStack aún está midiendo el historial.
    case initialAppear
    /// Cambio de bot: el contenido de la conversación se reconstruye.
    case conversationChanged
    /// Mensaje nuevo en la conversación visible.
    case newMessage
    /// Streaming o notas de herramientas: el contenido ya existe.
    case streamingUpdate
}

/// Retardos (segundos) con los que se reintenta el scroll al final cuando el
/// primer intento puede caer antes de que exista el centinela. Solo la
/// apertura y el cambio de bot reintentan; los mensajes en vivo nunca, para
/// no pelear con el scroll del usuario ni saturar la cola principal.
func chatScrollRetryDelays(for trigger: ChatScrollTrigger) -> [TimeInterval] {
    switch trigger {
    case .initialAppear, .conversationChanged:
        return [0.1, 0.3, 0.6]
    case .newMessage, .streamingUpdate:
        return []
    }
}

// MARK: - Editor auto-creciente estilo ChatGPT

/// El contenido supera la altura de una sola línea (con un pequeño margen).
/// Solo ajusta rasgos verticales (ver `chatInputVerticalPadding`): usarlo
/// para elegir el contenedor horizontal reintroduciría el bucle de layout
/// (el ancho cambia el ajuste de línea, la altura cambia el contenedor…).
func chatInputIsMultiline(contentHeight: CGFloat, singleLineHeight: CGFloat) -> Bool {
    contentHeight > singleLineHeight + 6
}

/// Margen vertical del input: algo más aireado cuando el texto crece.
/// Es lo único del input que depende de la altura medida, y al ser solo
/// vertical no realimenta el ajuste de línea del editor.
func chatInputVerticalPadding(contentHeight: CGFloat, singleLineHeight: CGFloat) -> CGFloat {
    chatInputIsMultiline(contentHeight: contentHeight, singleLineHeight: singleLineHeight) ? 8 : 6
}

/// Reloj compacto m:ss para el titular de actividad (0:07, 1:23, 12:05).
/// Mide el tiempo sin novedades: cada evento del CLI lo pone a cero.
func formatRunElapsed(from: Date, to: Date = Date()) -> String {
    let seconds = max(0, Int(to.timeIntervalSince(from)))
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

/// Diámetro del icono de enviar/detener a la escala dada.
func chatSendIconSize(scale: Double) -> CGFloat {
    28 * scale
}

/// Diámetro de los iconos laterales (micro) a la escala dada: mayores que
/// el texto pero por debajo de enviar, que manda en la fila.
func chatSideIconSize(scale: Double) -> CGFloat {
    22 * scale
}

/// Lado mínimo del área táctil de enviar/detener a la escala dada.
func chatSendTapSize(scale: Double) -> CGFloat {
    40 * scale
}

/// Lado mínimo del área táctil de los botones laterales a la escala dada.
func chatSideTapSize(scale: Double) -> CGFloat {
    36 * scale
}

/// TextEditor de una sola línea que crece con el contenido hasta que SwiftUI
/// limita su altura; a partir de ahí desplaza el texto internamente.
struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    var focusToken: Int
    var fontSize: CGFloat = Self.baseFontSize
    var onSubmit: @MainActor () -> Void
    var onEscape: (@MainActor () -> Void)? = nil

    static let baseFontSize: CGFloat = 15
    static let verticalInset: CGFloat = 2
    static func singleLineHeight(fontSize: CGFloat = baseFontSize) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))) + verticalInset * 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = GrowingTextScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        scrollView.documentView = textView
        scrollView.coordinator = context.coordinator
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
        }
        context.coordinator.recalculateHeight()
        // Foco inicial (una sola vez) y tras pulsar Enviar con el ratón.
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            scrollView.window?.makeFirstResponder(textView)
        } else if !context.coordinator.didFocus, let window = scrollView.window {
            if window.makeFirstResponder(textView) {
                context.coordinator.didFocus = true
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var didFocus = false
        var lastFocusToken = 0
        /// Última altura publicada al Binding (la publicación es asíncrona,
        /// así que `parent.contentHeight` aún no la refleja al comparar).
        var lastPublishedHeight: CGFloat

        init(parent: GrowingTextEditor) {
            self.parent = parent
            self.lastPublishedHeight = parent.contentHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func textView(_: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Return = enviar; Mayús+Return = salto de línea (ambos llegan
            // como insertNewline, se distinguen por el modificador).
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftPressed = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                if !shiftPressed {
                    parent.onSubmit()
                    return true
                }
            }
            // ESC = detener la respuesta en curso (igual que botón Detener).
            // Sin esto, el NSTextView se tragaría la tecla y el atajo del
            // botón nunca se dispararía con el foco en el editor.
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape?()
                return true
            }
            return false
        }

        /// Llamado tras cada layout (incluidos los cambios de ancho de la
        /// ventana, que alteran el ajuste de línea y por tanto la altura).
        func viewDidLayout() {
            DispatchQueue.main.async { [weak self] in self?.recalculateHeight() }
        }

        func recalculateHeight() {
            guard let textView,
                  let scrollView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            let clipWidth = scrollView.contentSize.width
            // Sin ancho todavía (pre-layout): conservar la altura anterior.
            guard clipWidth > 1 else { return }
            if abs(textView.frame.width - clipWidth) > 0.5 {
                textView.frame.size.width = clipWidth
            }
            layoutManager.ensureLayout(for: container)
            let usedHeight = layoutManager.usedRect(for: container).height
            let height = max(
                ceil(usedHeight) + GrowingTextEditor.verticalInset * 2,
                GrowingTextEditor.singleLineHeight(fontSize: parent.fontSize)
            )
            // El documentView mide el contenido para que el scroll interno
            // funcione al superar la altura máxima de SwiftUI.
            textView.frame.size.height = max(height, scrollView.contentSize.height)
            // Publicar fuera del ciclo de update/layout: esta función corre
            // dentro de `updateNSView` y de `layout`, y escribir el @State de
            // forma síncrona ahí muta estado durante el view update de SwiftUI
            // (comportamiento indefinido y pasadas extra de layout).
            if abs(lastPublishedHeight - height) > 0.5 {
                lastPublishedHeight = height
                let newHeight = height
                DispatchQueue.main.async { [weak self] in
                    self?.parent.contentHeight = newHeight
                }
            }
        }
    }
}

/// NSScrollView que avisa al coordinador tras cada layout para re-medir.
private final class GrowingTextScrollView: NSScrollView {
    weak var coordinator: GrowingTextEditor.Coordinator?

    override func layout() {
        super.layout()
        coordinator?.viewDidLayout()
    }
}

struct MentionList: View {
    @ObservedObject var viewModel: ChatViewModel
    let query: String

    private var matches: [Bot] {
        let lower = query.lowercased()
        if lower.isEmpty { return viewModel.store.bots }
        return viewModel.store.bots.filter { $0.name.lowercased().contains(lower) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { bot in
                Button {
                    viewModel.completeMention(with: bot)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: bot.colorHex))
                            .frame(width: 10, height: 10)
                        Text(bot.name)
                        Text(bot.specialty)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if matches.isEmpty {
                Text("Sin coincidencias")
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        )
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    // Observado (no `let`): la fila debe redibujarse cuando cambia el
    // titular aunque el mensaje siga siendo el mismo "…".
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.zoomScale) private var zoomScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch message.role {
        case "user":
            // Sin tope de ancho: la burbuja abraza el texto corto y crece
            // hasta casi todo el ancho solo cuando el texto lo llena.
            HStack {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        SentAttachmentsRow(attachments: message.attachments)
                    }
                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(message.text)
                            .font(chatReadingFont(scale: zoomScale))
                            .lineSpacing(4)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                            .textSelection(.enabled)
                    }
                }
            }
        case "system":
            Text(message.text)
                .font(zoomFont(.callout, scale: zoomScale))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        default:
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color(hex: viewModel.store.botColorHex(for: message.botId)))
                    .frame(width: 12, height: 12)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(message.botName ?? viewModel.store.botName(for: message.botId))
                            .font(chatReadingFont(scale: zoomScale, weight: .semibold))
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(zoomFont(.caption1, scale: zoomScale))
                            .foregroundStyle(.tertiary)
                    }
                    if message.text == "…" {
                        // El reloj late cada segundo: mide el tiempo sin
                        // novedades (si crece, el bot está atascado).
                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                // Titular único: la acción más reciente, sin
                                // historial. A la derecha del spinner.
                                let line = typingHeadline(at: context.date)
                                if !line.isEmpty {
                                    Text(line)
                                        .font(zoomFont(.caption1, scale: zoomScale))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    } else {
                        MarkdownBody(text: message.text, codeTheme: viewModel.store.settings.codeTheme)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 13)
                            .background(assistantBubbleBackground)
                            .textSelection(.enabled)
                    }
                    ForEach(message.toolNotes, id: \.self) { note in
                        Text(note)
                            .font(zoomFont(.caption1, scale: zoomScale))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .padding(.leading, 2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Titular de la burbuja de espera: la acción más reciente más el
    /// tiempo sin novedades. Vacío = aún sin titular (runBot lo fija a
    /// "Pensando…" al arrancar, así que casi nunca se ve vacío).
    private func typingHeadline(at now: Date) -> String {
        let headline = viewModel.runningHeadline
        guard !headline.isEmpty else { return "" }
        guard let since = viewModel.runningActivityAt ?? viewModel.runningSince else {
            return headline
        }
        return "\(headline) · \(formatRunElapsed(from: since, to: now))"
    }

    /// Burbuja del asistente: gris elevado suave en vez del
    /// `.controlBackgroundColor` casi negro, que dejaba el blanco puro del
    /// texto demasiado hiriente. Borde tenue y sombra leve para separarla
    /// del fondo sin endurecer el contraste.
    private var assistantBubbleBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.97))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.09)
                            : Color.black.opacity(0.07),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                radius: 6, y: 1
            )
    }
}

/// Fila de pendientes sobre el cajón: miniatura, nombre, tamaño y ×.
struct PendingAttachmentsRow: View {
    @ObservedObject var viewModel: ChatViewModel
    let conversationId: UUID
    @Environment(\.zoomScale) private var zoomScale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pending(for: conversationId)) { attachment in
                    HStack(spacing: 8) {
                        AttachmentThumb(attachment: attachment, side: 36 * zoomScale)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.fileName)
                                .font(zoomFont(.caption1, scale: zoomScale, weight: .medium))
                                .lineLimit(1)
                            Text(formatAttachmentSize(attachment.byteSize))
                                .font(zoomFont(.caption2, scale: zoomScale))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            viewModel.removePendingAttachment(attachment.id, conversationId: conversationId)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Quitar adjunto")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Adjuntos de un mensaje ya enviado: clic para abrir con la app por defecto.
struct SentAttachmentsRow: View {
    let attachments: [ChatAttachment]
    @Environment(\.zoomScale) private var zoomScale

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: attachment.storedPath))
                } label: {
                    HStack(spacing: 8) {
                        AttachmentThumb(attachment: attachment, side: 40 * zoomScale)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.fileName)
                                .font(zoomFont(.caption1, scale: zoomScale, weight: .medium))
                                .lineLimit(1)
                            Text(formatAttachmentSize(attachment.byteSize))
                                .font(zoomFont(.caption2, scale: zoomScale))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                }
                .buttonStyle(.plain)
                .help("Abrir «\(attachment.fileName)»")
            }
        }
    }
}

/// Miniatura de imagen o icono de documento, recortada en cuadrado.
struct AttachmentThumb: View {
    let attachment: ChatAttachment
    let side: CGFloat

    var body: some View {
        Group {
            if attachment.isImage, let nsImage = NSImage(contentsOfFile: attachment.storedPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc.fill")
                    .font(.system(size: side * 0.45))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .separatorColor).opacity(0.4))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
