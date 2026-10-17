import Combine
import Darwin
import Foundation

// MARK: - Modelo

/// Uso de suscripción tal como lo muestra `/usage` en el TUI.
/// Son los porcentajes verbatim del proveedor: la app no puede
/// derivarlos de los registros locales (la cuota usa una unidad
/// interna del servidor, no tokens brutos).
struct SubscriptionUsage: Sendable, Equatable {
    var windowPercent: Int
    var windowResets: String
    var weeklyPercent: Int
    var weeklyResets: String
    var tier: String
}

enum UsageFetchError: Error, Sendable {
    case museNotFound
    case launchFailed
    case promptTimeout
    case panelTimeout
    case parseFailed

    var message: String {
        switch self {
        case .museNotFound:
            return "CLI `muse` no encontrado"
        case .launchFailed:
            return "no se pudo abrir el TUI"
        case .promptTimeout:
            return "el TUI tardó demasiado en arrancar"
        case .panelTimeout:
            return "/usage no respondió a tiempo"
        case .parseFailed:
            return "no se entendió la respuesta de /usage"
        }
    }
}

// MARK: - Parseo puro

func stripAnsi(_ text: String) -> String {
    let pattern = "\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][A-B0]|\u{1B}[=>78]|\u{0F}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
}

func parseUsagePanel(_ raw: String) -> SubscriptionUsage? {
    let text = stripAnsi(raw)
    guard let window = firstMatch(
        pattern: #"Current\s+(\d+)% used\s*·\s*Resets?\s+at\s+([^│\n]+)"#, in: text
    ), let windowPercent = Int(window[0]),
        let weekly = firstMatch(
            pattern: #"Weekly\s+(\d+)% used\s*·\s*Resets?\s+([^│\n]+)"#, in: text
        ), let weeklyPercent = Int(weekly[0]),
        let tier = firstMatch(pattern: #"Subscription\s*·\s*([^│\n]+)"#, in: text)
    else { return nil }
    return SubscriptionUsage(
        windowPercent: windowPercent,
        windowResets: window[1].trimmingCharacters(in: .whitespaces),
        weeklyPercent: weeklyPercent,
        weeklyResets: weekly[1].trimmingCharacters(in: .whitespaces),
        tier: tier[0].trimmingCharacters(in: .whitespaces)
    )
}

private func firstMatch(pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    return (1..<match.numberOfRanges).map { index in
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }
}

/// El TUI está listo para recibir comandos cuando pinta su prompt.
/// Sin umbral de bytes: el TUI actual pinta el prompt con ~1,6 KB y
/// en reposo no llega a 3 KB, así que exigir un mínimo de salida
/// hacía que la espera siempre agotara el plazo.
func isTUIPromptReady(_ text: String) -> Bool {
    text.contains("❯")
}

/// Fracción 0...1 para la barra (el % puede pasar de 100).
func usageBarFraction(percent: Int) -> Double {
    min(max(Double(percent) / 100, 0), 1)
}

/// Intervalo de auto-actualización del medidor del pie (30 min, según README).
let usageAutoRefreshInterval: TimeInterval = 30 * 60

// MARK: - Lector del TUI por pty

/// Ejecuta `/usage` en una sesión efímera del TUI bajo un pty y devuelve
/// los porcentajes reales de suscripción. Bloquea al llamador: ejecutar
/// en un hilo de fondo. Típico ~15 s; peor caso ~2 min.
func fetchSubscriptionUsage(musePath: String, workingDirectory: String) -> Result<SubscriptionUsage, UsageFetchError> {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0 else { return .failure(.launchFailed) }
    defer { close(master) }
    guard grantpt(master) == 0, unlockpt(master) == 0,
          let slavePath = ptsname(master).map({ String(cString: $0) })
    else { return .failure(.launchFailed) }
    // Ventana generosa para que el panel quepa en una pasada.
    // OJO: en macOS TIOCSWINSZ solo aplica en el esclavo (en el
    // maestro falla); y el esclavo no debe cerrarse y reabrirse.
    var size = winsize(ws_row: 60, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)

    // El esclavo se abre UNA vez y se hereda abierto: cerrarlo y
    // reabrirlo antes del exec deja al TUI clavado (reproducido).
    // --trust-workspace evita el diálogo de confianza sin guardar nada.
    let args = [musePath, "--trust-workspace", "--workspace", workingDirectory]
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    let env = environment.map { "\($0.key)=\($0.value)" }
    let slaveFd: Int32 = slavePath.withCString { open($0, O_RDWR | O_NOCTTY) }
    guard slaveFd >= 0 else { return .failure(.launchFailed) }
    _ = ioctl(slaveFd, TIOCSWINSZ, &size)
    var child: pid_t = 0
    let spawned: Int32 = musePath.withCString { cPath in
        withCStrings(args) { argv in
            withCStrings(env) { envp in
                var actions: posix_spawn_file_actions_t?
                guard posix_spawn_file_actions_init(&actions) == 0 else { return -1 as Int32 }
                defer { posix_spawn_file_actions_destroy(&actions) }
                guard posix_spawn_file_actions_addclose(&actions, master) == 0,
                      posix_spawn_file_actions_adddup2(&actions, slaveFd, STDIN_FILENO) == 0,
                      posix_spawn_file_actions_adddup2(&actions, slaveFd, STDOUT_FILENO) == 0,
                      posix_spawn_file_actions_adddup2(&actions, slaveFd, STDERR_FILENO) == 0
                else { return -1 as Int32 }
                if slaveFd > STDERR_FILENO {
                    guard posix_spawn_file_actions_addclose(&actions, slaveFd) == 0 else {
                        return -1 as Int32
                    }
                }
                return posix_spawn(&child, cPath, &actions, nil, argv, envp)
            }
        }
    }
    guard spawned == 0 else {
        close(slaveFd)
        return .failure(.launchFailed)
    }
    // El padre no necesita el esclavo; el hijo ya tiene sus dup2.
    // (Cierre aquí, no en defer: si no, el EOF no llegaría nunca.)
    close(slaveFd)
    defer {
        kill(child, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(child, &status, 0)
    }

    let flags = fcntl(master, F_GETFL)
    _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

    var output = Data()
    // Volcado de diagnóstico (solo con MUSEBOTS_USAGE_DEBUG): ayuda a
    // depurar cambios de formato del TUI.
    defer {
        if ProcessInfo.processInfo.environment["MUSEBOTS_USAGE_DEBUG"] != nil {
            try? output.write(to: URL(fileURLWithPath: "/tmp/boty-usage-debug.bin"))
        }
    }
    let started = Date()
    let promptDeadline: TimeInterval = 90
    let panelTimeout: TimeInterval = 45
    var usageSentAt: Date?
    var confirmSent = false

    while Date().timeIntervalSince(started) < promptDeadline + panelTimeout {
        var pending = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        if poll(&pending, 1, 500) > 0, (pending.revents & Int16(POLLIN)) != 0 {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(master, &chunk, chunk.count)
            if count > 0 {
                output.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                break // el hijo cerró el pty
            }
        }
        let text = String(decoding: output, as: UTF8.self)
        guard let sentAt = usageSentAt else {
            if isTUIPromptReady(text) {
                ptyWrite(master, "/usage\r")
                usageSentAt = Date()
            } else if Date().timeIntervalSince(started) > promptDeadline {
                return .failure(.promptTimeout)
            }
            continue
        }
        if text.contains("Subscription"), text.contains("Weekly") {
            break
        }
        // Segundo intro: confirma el comando en la paleta.
        if !confirmSent, Date().timeIntervalSince(sentAt) > 3 {
            ptyWrite(master, "\r")
            confirmSent = true
        }
        if Date().timeIntervalSince(sentAt) > panelTimeout {
            return .failure(.panelTimeout)
        }
    }

    if let usage = parseUsagePanel(String(decoding: output, as: UTF8.self)) {
        return .success(usage)
    }
    return .failure(.parseFailed)
}

private func ptyWrite(_ fd: Int32, _ text: String) {
    text.withCString { pointer in
        var remaining = strlen(pointer)
        var cursor = pointer
        while remaining > 0 {
            let written = write(fd, cursor, remaining)
            if written <= 0 { break }
            remaining -= written
            cursor = cursor.advanced(by: written)
        }
    }
}

private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) throws -> R) rethrows -> R {
    var owned = strings.map { strdup($0) }
    defer { owned.forEach { free($0) } }
    owned.append(nil)
    return try owned.withUnsafeMutableBufferPointer { buffer in
        try body(Array(buffer))
    }
}

// MARK: - Tracker observable

/// Uso de suscripción leído de `/usage`. Cada lectura abre un TUI
/// efímero (~15 s), así que se refresca cada 30 min y a mano.
@MainActor
final class UsageTracker: ObservableObject {
    @Published private(set) var usage: SubscriptionUsage?
    @Published private(set) var isFetching = false
    @Published private(set) var lastFetch: Date?
    @Published private(set) var errorMessage: String?

    private var running = false

    /// Lee en segundo plano; las llamadas concurrentes se fusionan.
    func refresh(musePath: String?) {
        guard !running else { return }
        guard let musePath, !musePath.isEmpty else {
            errorMessage = UsageFetchError.museNotFound.message
            return
        }
        running = true
        isFetching = true
        errorMessage = nil
        Task { [weak self, musePath] in
            let result = await Task.detached(priority: .utility) {
                fetchSubscriptionUsage(musePath: musePath, workingDirectory: NSHomeDirectory())
            }.value
            guard let self else { return }
            switch result {
            case .success(let usage):
                self.usage = usage
                self.lastFetch = Date()
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.message
            }
            self.running = false
            self.isFetching = false
        }
    }
}
