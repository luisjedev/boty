import Foundation

struct MuseRequest: Sendable {
    var sessionId: String
    var prompt: String
    var model: String
    var effort: String
    var workspace: String
    var allowTools: Bool
    var timeoutSeconds: Double = 600
    /// Rutas de imágenes para la visión nativa (`--image`, repetible).
    var imagePaths: [String] = []
}

struct MuseResult: Sendable {
    var text: String
    var toolNotes: [String]
    var sawTerminal: Bool
}

enum MuseError: Error, LocalizedError {
    case binaryNotFound
    case launchFailed(String)
    case nonZeroExit(Int, String)
    case emptyResponse(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "No encuentro el CLI `muse`. Instálalo o configura su ruta en Ajustes."
        case .launchFailed(let detail):
            return "No pude lanzar `muse`: \(detail)"
        case .nonZeroExit(let code, let detail):
            return detail.isEmpty
                ? "muse terminó con error (\(code))."
                : "muse terminó con error (\(code)): \(detail)"
        case .emptyResponse(let hint):
            var msg = "muse no devolvió texto."
            if !hint.isEmpty { msg += "\nPista: \(hint)" }
            return msg
        case .timeout:
            return "La petición superó el tiempo límite (10 min) y se canceló."
        }
    }
}

final class MuseRunToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func setProcess(_ proc: Process?) {
        lock.withLock {
            process = proc
            if cancelled { proc?.terminate() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Acumulador de bytes thread-safe para los pipes del proceso hijo.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var value: Data {
        lock.withLock { data }
    }
}

/// Retiene el último titular de actividad avisado, thread-safe para los
/// handlers de los pipes. Devuelve si el valor cambió (y lo guarda).
final class ActivityLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String? = nil

    func update(_ value: String?) -> Bool {
        lock.withLock {
            guard value != last else { return false }
            last = value
            return true
        }
    }
}

enum MuseClient {
    static func resolveMusePath(override: String) -> String? {
        let trimmed = `override`.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
            return nil
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent("muse")
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in ["~/.local/bin/muse", "/opt/homebrew/bin/muse", "/usr/local/bin/muse"] {
            let expanded = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }
        return nil
    }

    /// Ejecuta el prompt avisando con `(texto, notas)` cada vez que llega
    /// texto nuevo por stdout, sin esperar a que termine el proceso.
    /// `onActivity` recibe el titular de actividad más reciente (un solo
    /// texto que se reemplaza, nunca se acumula) cada vez que cambia, o
    /// `nil` cuando la ejecución termina.
    static func runPrompt(
        musePath: String, request: MuseRequest, token: MuseRunToken,
        onUpdate: @escaping @Sendable (String, [String]) -> Void = { _, _ in },
        onActivity: @escaping @Sendable (String?) -> Void = { _ in }
    ) async throws -> MuseResult {
        let box = RunBox(musePath: musePath, request: request, token: token)
        return try await Task.detached(priority: .userInitiated) {
            try box.execute(onUpdate: onUpdate, onActivity: onActivity)
        }.value
    }
}

private final class RunBox: @unchecked Sendable {
    let musePath: String
    let request: MuseRequest
    let token: MuseRunToken

    init(musePath: String, request: MuseRequest, token: MuseRunToken) {
        self.musePath = musePath
        self.request = request
        self.token = token
    }

    func execute(
        onUpdate: @escaping @Sendable (String, [String]) -> Void,
        onActivity: @escaping @Sendable (String?) -> Void = { _ in }
    ) throws -> MuseResult {
        let fm = FileManager.default
        let promptURL = fm.temporaryDirectory.appendingPathComponent("boty-\(UUID().uuidString).txt")
        try request.prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: promptURL) }

        let args = museExecArgs(request: request, promptPath: promptURL.path)

        let workingDirectory = resolveWorkingDirectory(allowTools: request.allowTools, workspace: request.workspace)
        if request.allowTools {
            try? FileManager.default.createDirectory(
                atPath: workingDirectory, withIntermediateDirectories: true
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: musePath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let stream = ExecStreamParser()
        let latch = ActivityLatch()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            outBox.append(chunk)
            // `muse exec --json` emite los deltas en tiempo real: avisar
            // con el texto acumulado sin esperar al final del proceso.
            // El titular de actividad viaja en el mismo aviso (un solo
            // texto, siempre el más reciente).
            if let update = stream.feed(chunk) {
                if !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !update.toolNotes.isEmpty
                {
                    onUpdate(update.text, update.toolNotes)
                }
                if latch.update(update.activity) {
                    onActivity(update.activity)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBox.append(chunk) }
        }

        do {
            try proc.run()
        } catch {
            throw MuseError.launchFailed(error.localizedDescription)
        }
        token.setProcess(proc)

        let deadline = Date().addingTimeInterval(request.timeoutSeconds)
        while proc.isRunning {
            if token.isCancelled { proc.terminate(); break }
            if Date() > deadline {
                proc.terminate()
                token.setProcess(nil)
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw MuseError.timeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drenar lo que quede en los pipes: stdout llega en ráfaga al final
        // (buffer de bloque) y el handler puede no haberlo entregado todo.
        // El proceso ya terminó, así que EOF es inmediato y no hace falta
        // ninguna espera fija antes de drenar.
        let outRest = outPipe.fileHandleForReading.readDataToEndOfFile()
        if !outRest.isEmpty { outBox.append(outRest) }
        let errRest = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !errRest.isEmpty { errBox.append(errRest) }
        token.setProcess(nil)
        if token.isCancelled { throw CancellationError() }

        let outText = String(data: outBox.value, encoding: .utf8) ?? ""
        let errText = (String(data: errBox.value, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if proc.terminationStatus != 0 {
            throw MuseError.nonZeroExit(Int(proc.terminationStatus), errText)
        }
        let parsed = parseExecOutput(outText)
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw MuseError.emptyResponse(
                emptyResponseHint(stderr: errText, workingDirectory: workingDirectory, parsed: parsed)
            )
        }
        return MuseResult(text: text, toolNotes: parsed.toolNotes, sawTerminal: parsed.sawTerminal)
    }
}

/// Argumentos de `muse exec` para una petición. Función pura para poder
/// probar el gating de herramientas sin lanzar procesos.
func museExecArgs(request: MuseRequest, promptPath: String) -> [String] {
    var args = [
        "exec", "--json",
        "--session-id", request.sessionId,
        "--reasoning-effort", request.effort,
        "--prompt-file", promptPath,
        // Sin agentes recordatorios: tras la respuesta lanzan ~3 s de
        // tareas (skill/goal/verify-reminder) que en un chat son puro
        // lastre antes del evento terminal.
        "--disable-reminders",
    ]
    if !request.model.trimmingCharacters(in: .whitespaces).isEmpty {
        args += ["--model", request.model.trimmingCharacters(in: .whitespaces)]
    }
    for image in request.imagePaths where !image.trimmingCharacters(in: .whitespaces).isEmpty {
        args += ["--image", image]
    }
    if request.allowTools {
        // Acceso total: sin aprobación interactiva, shell sin sandbox para
        // controlar el Mac (screencapture, osascript, open…), workspace
        // confiable para cargar sus skills/reglas, y permiso para ampliar
        // el workspace si lo pide.
        args += [
            "--workspace", request.workspace,
            "--approval-mode", "never",
            "--disable-sandbox",
            "--trust-workspace",
            "--allow-workspace-switch",
        ]
    } else {
        args += ["--disable-web-tools"]
    }
    return args
}

/// Directorio de trabajo para lanzar `muse exec`. Sin esto, una app GUI hereda
/// `/` y Muse lo considera no confiable y no responde.
func resolveWorkingDirectory(allowTools: Bool, workspace: String) -> String {
    let trimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
    if allowTools, !trimmed.isEmpty { return trimmed }
    let home = NSHomeDirectory()
    if !home.isEmpty, home != "/" { return home }
    return FileManager.default.temporaryDirectory.path
}

/// Si Muse se queja de confianza, añade cómo resolverlo.
func decorateTrustHint(_ stderr: String, workingDirectory: String) -> String {
    var hint = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if stderr.localizedCaseInsensitiveContains("untrusted") {
        if !hint.isEmpty { hint += "\n" }
        hint += "Muse considera no confiable «\(workingDirectory)». " +
            "Abre la terminal en esa carpeta, ejecuta `muse` una vez y acepta la confianza; después reintenta."
    }
    return hint
}

/// Pista para `emptyResponse`: solo sugiere `muse login` si stderr huele a
/// autenticación; si no, describe lo que sí llegó por stdout para depurar.
func emptyResponseHint(stderr: String, workingDirectory: String, parsed: ExecParseResult) -> String {
    var hint = decorateTrustHint(stderr, workingDirectory: workingDirectory)
    let lower = stderr.lowercased()
    if lower.contains("login") || lower.contains("auth") || lower.contains("401")
        || lower.contains("unauthorized") || lower.contains("unauthenticated")
    {
        if !hint.isEmpty { hint += "\n" }
        hint += "Parece un problema de sesión: ejecuta `muse login` en la terminal y reintenta."
        return hint
    }
    if !hint.isEmpty { hint += "\n" }
    if parsed.jsonLines == 0 {
        hint += "stdout llegó vacío (0 líneas JSON)."
    } else {
        hint += "stdout trajo \(parsed.jsonLines) líneas JSON sin texto extraíble"
        if !parsed.kinds.isEmpty {
            hint += " (eventos: \(parsed.kinds.joined(separator: ", ")))"
        }
        hint += "."
    }
    return hint
}

struct ExecParseResult: Sendable {
    var text: String
    var toolNotes: [String]
    var sawTerminal: Bool
    var jsonLines: Int = 0
    var kinds: [String] = []
    /// Titular de actividad más reciente (un solo texto, se reemplaza;
    /// nunca se acumula). `nil` si no hubo ninguna señal de actividad.
    var activity: String? = nil
}

/// Estado incremental del parseo de `muse exec --json`: se alimenta línea
/// a línea conforme llegan por stdout y expone en cada momento el mejor
/// texto disponible, con la misma prioridad que el parseo por lotes.
struct ExecStreamState: Sendable {
    var lastAssistant: String?
    var lastTerminal: String?
    var outputDeltas: [String] = []
    var lastFinal: String?
    var plainLines: [String] = []
    var toolNotes: [String] = []
    var sawTerminal = false
    var jsonLines = 0
    var seenKinds = Set<String>()
    /// Titular de actividad vigente: cada señal lo REEMPLAZA, nunca se
    /// acumula. Es lo que se muestra mientras el bot "piensa".
    var activity: String? = nil

    /// El modelo vuelve a pensar: solo ocupa el titular si no hay una
    /// acción concreta vigente. Así el detalle de la última herramienta
    /// ("🔧 List workspace files") no parpadea a genérico ("💭 Pensando…")
    /// en cuanto el modelo encadena su siguiente turno de razonamiento.
    mutating func noteThinking() {
        if activity == nil { activity = activityThinking }
    }

    mutating func feedLine(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            plainLines.append(line)
            return
        }
        jsonLines += 1
        let payload = obj["payload"] as? [String: Any]
        let payloadKind = payload?["kind"] as? String ?? ""
        let payloadType = (obj["payload_type"] as? String) ?? ""
        if !payloadKind.isEmpty { seenKinds.insert(payloadKind) }

        // Envelope real de `muse exec --json`: el texto del asistente llega
        // como deltas (run_output_delta) y texto final (run_terminal).
        if payloadKind == "run_output_delta" {
            if let text = nonEmptyText(payload?["text"]) { outputDeltas.append(text) }
            // Llega texto de respuesta: el bot está redactando.
            activity = activityWriting
            return
        }
        if payloadKind == "run_terminal" || payloadType.contains("terminal") {
            sawTerminal = true
            if let text = nonEmptyText(payload?["text"]) { lastTerminal = text }
            // Fin de la ejecución: no hay titular vigente.
            activity = nil
            return
        }

        let event: [String: Any] = (payload?["event"] as? [String: Any])
            ?? (obj["event"] as? [String: Any])
            ?? obj
        let kind = (event["kind"] as? String) ?? (obj["kind"] as? String) ?? ""
        if !kind.isEmpty { seenKinds.insert(kind) }
        switch kind {
        case "assistant_message_committed":
            if let text = nonEmptyText(event["text"]) { lastAssistant = text }
        case "proposed":
            // Arranque de una subtarea: una herramienta nueva reemplaza
            // siempre (es la acción vigente); que el modelo vuelva a
            // pensar no pisa su detalle (ver `noteThinking`). Los
            // recordatorios y tipos desconocidos se ignoran.
            if let kind = event["task_kind"] as? String {
                if kind.hasPrefix("tool."), let headline = headlineForTaskKind(kind) {
                    activity = headline
                } else if kind.hasPrefix("model.") {
                    noteThinking()
                }
            }
        case "side_effect_intent":
            // La herramienta está a punto de ejecutarse.
            if let operation = event["operation"] as? String {
                if operation.hasPrefix("tool:"), let headline = headlineForOperation(operation) {
                    activity = headline
                } else if operation.hasPrefix("model.") {
                    noteThinking()
                }
            }
        case "status":
            // El modelo abre el stream: piensa en silencio (sin deltas).
            if isThinkingStatus(event) { noteThinking() }
        case "output":
            if let result = event["final_result"], !isNull(result) {
                let text = compactString(result)
                if !text.isEmpty { lastFinal = text }
            }
            // Detalle de la herramienta en curso (comando, archivo…):
            // reemplaza al titular genérico de `proposed`.
            if let headline = headlineForToolChunk(event["chunk"]) { activity = headline }
        case "terminal":
            sawTerminal = true
        case "assistant_tool_calls_committed":
            toolNotes.append(contentsOf: toolSummaries(event["tool_calls"]))
        case "tool_result_batch_committed":
            if let results = event["results"] as? [Any], !results.isEmpty {
                toolNotes.append("✓ \(results.count) resultado(s) de herramienta")
            }
        default:
            if kind.contains("terminal") { sawTerminal = true }
            if kind.contains("completed"), let text = firstText(in: event) {
                lastFinal = text
            }
        }
    }

    func result() -> ExecParseResult {
        let text: String
        if let assistant = lastAssistant {
            text = assistant
        } else if let terminal = lastTerminal {
            text = terminal
        } else {
            let deltas = outputDeltas.joined()
            if !deltas.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = deltas
            } else if let final = lastFinal {
                text = final
            } else {
                text = plainLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ExecParseResult(
            text: text, toolNotes: toolNotes, sawTerminal: sawTerminal,
            jsonLines: jsonLines, kinds: seenKinds.sorted(),
            activity: activity
        )
    }
}

func parseExecOutput(_ stdout: String) -> ExecParseResult {
    var state = ExecStreamState()
    for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
        state.feedLine(String(raw))
    }
    return state.result()
}

/// Titular cuando el modelo está razonando sin emitir texto.
let activityThinking = "💭 Pensando…"

/// Titular cuando ya llega texto de la respuesta.
let activityWriting = "✍️ Escribiendo respuesta…"

/// Titular genérico para el arranque de una subtarea (`proposed`). Los
/// recordatorios internos se ignoran: con `--disable-reminders` no existen
/// en Boty y solo añadirían ruido.
func headlineForTaskKind(_ value: Any?) -> String? {
    guard let kind = value as? String, !kind.isEmpty else { return nil }
    if kind.hasPrefix("model.") { return activityThinking }
    if kind.hasPrefix("tool.") {
        return "🔧 \(friendlyToolName(String(kind.dropFirst(5))))…"
    }
    return nil
}

/// Titular cuando una herramienta está a punto de ejecutarse
/// (`side_effect_intent`). Reafirma el de `proposed`; el detalle real llega
/// después con el `output` de la herramienta.
func headlineForOperation(_ value: Any?) -> String? {
    guard let operation = value as? String, !operation.isEmpty else { return nil }
    if operation.hasPrefix("model.") { return activityThinking }
    if operation.hasPrefix("tool:") {
        return "🔧 \(friendlyToolName(String(operation.dropFirst(5))))…"
    }
    return nil
}

/// Nombre legible de una herramienta para el titular.
func friendlyToolName(_ name: String) -> String {
    switch name {
    case "bash": return "comando"
    case "read_file": return "leyendo archivo"
    case "write_file": return "escribiendo archivo"
    default: return name.replacingOccurrences(of: "_", with: " ")
    }
}

/// El modelo abre su stream (`status` con fase de apertura): a partir de
/// aquí puede pensar en silencio varios minutos sin emitir deltas.
func isThinkingStatus(_ event: [String: Any]) -> Bool {
    guard let message = event["message"] as? String else { return false }
    let lower = message.lowercased()
    return lower.contains("opening") && lower.contains("stream")
}

/// Titular detallado a partir del `output` de una herramienta: el comando
/// con su descripción (`bash`), el archivo leído o el escrito. Si el trozo
/// no tiene forma conocida (p. ej. stdout crudo a mitad de un comando
/// largo), se ignora para no pisar el titular vigente con basura.
func headlineForToolChunk(_ value: Any?) -> String? {
    guard let chunk = value as? String else { return nil }
    let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("{"),
       let data = trimmed.data(using: .utf8),
       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
        let description = (obj["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = (obj["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty, !command.isEmpty {
            return String("🔧 \(description) — `\(command)`".prefix(140))
        }
        if !description.isEmpty { return String("🔧 \(description)".prefix(140)) }
        if !command.isEmpty { return String("🔧 `\(command)`".prefix(140)) }
    }
    let firstLine = trimmed.split(separator: "\n", maxSplits: 1).map(String.init).first ?? ""
    if firstLine.hasPrefix("Read text file `"), firstLine.hasSuffix("`.") {
        let name = firstLine.dropFirst("Read text file `".count).dropLast(2)
        return "📖 Leyendo \(name)"
    }
    if firstLine.hasPrefix("Read text file `") {
        let name = firstLine.dropFirst("Read text file `".count).prefix(while: { $0 != "`" })
        return "📖 Leyendo \(name)"
    }
    if firstLine.hasPrefix("wrote "), firstLine.contains(" bytes to ") {
        let path = firstLine.split(separator: " ").last.map(String.init) ?? ""
        let base = path.split(separator: "/").last.map(String.init) ?? path
        if !base.isEmpty { return "✏️ Escribiendo \(base)" }
    }
    return nil
}

/// Parser thread-safe que trocea los bytes de stdout en líneas JSONL
/// conforme llegan y avisa con el texto acumulado hasta el momento.
final class ExecStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var state = ExecStreamState()
    private var lastSentText = ""
    private var lastSentNotes: [String] = []
    private var lastSentActivity: String? = nil

    /// Alimenta bytes recién leídos del proceso. Devuelve el texto, notas y
    /// titular vigentes si se completó alguna línea y algo cambió; `nil` si
    /// todo quedó pendiente, si no hay nada que mostrar o si nada cambió.
    /// El titular viaja aunque el texto siga vacío (p. ej. el modelo piensa
    /// en silencio): así la app muestra avance desde el primer evento.
    func feed(_ chunk: Data) -> (text: String, toolNotes: [String], activity: String?)? {
        lock.withLock {
            pending.append(chunk)
            var completedLine = false
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending.prefix(upTo: newline)
                pending.removeSubrange(pending.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    state.feedLine(line)
                }
                completedLine = true
            }
            guard completedLine else { return nil }
            let snapshot = state.result()
            guard snapshot.text != lastSentText
                || snapshot.toolNotes != lastSentNotes
                || snapshot.activity != lastSentActivity
            else {
                return nil
            }
            guard !snapshot.text.isEmpty || !snapshot.toolNotes.isEmpty
                || snapshot.activity != lastSentActivity
            else {
                return nil
            }
            lastSentText = snapshot.text
            lastSentNotes = snapshot.toolNotes
            lastSentActivity = snapshot.activity
            return (snapshot.text, snapshot.toolNotes, snapshot.activity)
        }
    }

    /// Estado final, volcando la última línea aunque no termine en `\n`.
    func flush() -> ExecParseResult {
        lock.withLock {
            if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
                state.feedLine(line)
            }
            pending.removeAll()
            return state.result()
        }
    }
}

private func nonEmptyText(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : text
}

private func isNull(_ value: Any) -> Bool { value is NSNull }

private func firstText(in event: [String: Any]) -> String? {
    for key in ["text", "content", "message", "final_result", "final_text"] {
        if let text = nonEmptyText(event[key]) { return text }
        if let nested = event[key] as? [String: Any], let text = nonEmptyText(nested["text"]) { return text }
    }
    return nil
}

private func compactString(_ value: Any) -> String {
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value),
       let text = String(data: data, encoding: .utf8)
    {
        return String(text.prefix(500))
    }
    return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func toolSummaries(_ value: Any?) -> [String] {
    guard let calls = value as? [Any], !calls.isEmpty else { return [] }
    return calls.map { call in
        if let dict = call as? [String: Any] {
            let name = (dict["name"] as? String)
                ?? (dict["tool"] as? String)
                ?? (dict["function"] as? String)
                ?? (dict["command"] as? String)
                ?? "herramienta"
            var detail = (dict["command"] as? String)
                ?? (dict["path"] as? String)
                ?? (dict["file"] as? String)
                ?? ""
            if detail.isEmpty, let args = dict["args"] {
                detail = compactString(args)
            }
            if detail.isEmpty, let args = dict["arguments"] {
                detail = compactString(args)
            }
            detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty || detail == name { return "🔧 \(name)" }
            return "🔧 \(name) — \(detail.prefix(120))"
        }
        return "🔧 \(compactString(call).prefix(120))"
    }
}
