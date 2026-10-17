import Foundation

/// Infraestructura: ejecuta `muse mcp login/logout <server>`.
///
/// - `login` abre el navegador + callback loopback: funciona desde un
///   proceso GUI sin TTY. Solo tiene sentido en entradas streamable-HTTP
///   (el CLI lo exige). Antes de llamar, la UI confirma mostrando la URL.
/// - `logout` es idempotente en el CLI (exit 0 aunque no exista): aquí se
///   refleja igual, sin convertirlo en error.
enum McpAuthRunner {
    /// Autoriza un servidor por OAuth. Devuelve la salida del CLI.
    static func login(
        server name: String,
        musePath: String?,
        timeoutSeconds: Double = 300
    ) async throws -> String {
        guard let musePath, !musePath.isEmpty else { throw MuseError.binaryNotFound }
        return try await run(
            musePath: musePath,
            arguments: ["mcp", "login", name],
            timeoutSeconds: timeoutSeconds
        )
    }

    static func logout(server name: String, musePath: String?) async throws -> String {
        guard let musePath, !musePath.isEmpty else { throw MuseError.binaryNotFound }
        return try await run(
            musePath: musePath,
            arguments: ["mcp", "logout", name],
            timeoutSeconds: 60
        )
    }

    private static func run(
        musePath: String,
        arguments: [String],
        timeoutSeconds: Double
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: musePath)
            proc.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            do {
                try proc.run()
            } catch {
                throw MuseError.launchFailed(error.localizedDescription)
            }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while proc.isRunning {
                if Date() > deadline {
                    proc.terminate()
                    throw MuseError.timeout
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                let detail = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                throw MuseError.nonZeroExit(Int(proc.terminationStatus), detail)
            }
            return (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
