import XCTest

@testable import Boty

final class MuseClientTests: XCTestCase {
    func testAssistantMessageEnvelope() {
        let stdout = """
        {"causation_id":"1","payload":{"event":{"kind":"model_response_created","response_id":"r1"}},"record_type":"x"}
        {"causation_id":"2","payload":{"event":{"kind":"assistant_message_committed","message_id":"m1","text":"Hola, soy Coder."}},"record_type":"x"}
        {"causation_id":"3","payload":{"event":{"kind":"terminal","reason":"done","terminal":true}},"record_type":"x"}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Hola, soy Coder.")
        XCTAssertTrue(result.sawTerminal)
        XCTAssertTrue(result.toolNotes.isEmpty)
    }

    func testLastAssistantTextWins() {
        let stdout = """
        {"payload":{"event":{"kind":"assistant_message_committed","text":"Primer borrador."}}}
        {"payload":{"event":{"kind":"assistant_tool_calls_committed","tool_calls":[{"name":"read","path":"/tmp/a.txt"}]}}}
        {"payload":{"event":{"kind":"assistant_message_committed","text":"Respuesta final."}}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Respuesta final.")
        XCTAssertEqual(result.toolNotes.count, 1)
        XCTAssertTrue(result.toolNotes[0].contains("read"))
    }

    func testFinalResultFallback() {
        let stdout = """
        {"payload":{"event":{"kind":"output","task_id":"t","final_result":"Hecho con output."}}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Hecho con output.")
    }

    func testDottedCompletedKind() {
        let stdout = """
        {"kind":"run.terminal.completed","text":"Texto terminal punteado."}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Texto terminal punteado.")
        XCTAssertTrue(result.sawTerminal)
    }

    func testToolCallShapes() {
        let stdout = """
        {"payload":{"event":{"kind":"assistant_tool_calls_committed","tool_calls":[{"tool":"shell","command":"ls -la"},{"function":"read_file"},{"name":"solo-nombre"}]}}}
        {"payload":{"event":{"kind":"assistant_message_committed","text":"Listo."}}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Listo.")
        XCTAssertEqual(result.toolNotes.count, 3)
        XCTAssertTrue(result.toolNotes[0].contains("ls -la"))
        XCTAssertTrue(result.toolNotes[1].contains("read_file"))
    }

    func testReasoningSummariesAreIgnored() {
        let stdout = """
        {"payload":{"event":{"kind":"reasoning_summary_committed","text":"Pensando en voz alta…"}}}
        {"payload":{"event":{"kind":"reasoning_summary_delta","text":"más pensamiento"}}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertTrue(result.text.isEmpty)
    }

    func testPlainTextFallback() {
        let stdout = """
        Esta línea no es JSON.
        Ni esta.
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Esta línea no es JSON.\nNi esta.")
    }

    func testEmptyOutput() {
        let result = parseExecOutput("\n  \n")
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertFalse(result.sawTerminal)
    }

    func testRealExecJsonEnvelope() {
        // Formato real de `muse exec --json` (v1.4.4): el texto viaja en
        // payload.kind run_output_delta / run_terminal, no en payload.event.
        let stdout = """
        {"schema_version":1,"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"echo: Di hola\\n"}}
        {"schema_version":1,"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","text":"echo: Di hola\\n","reason":null}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "echo: Di hola\n")
        XCTAssertTrue(result.sawTerminal)
    }

    func testOutputDeltasAccumulate() {
        let stdout = """
        {"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"Hola, "}}
        {"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"¿qué tal?"}}
        {"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","reason":null}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Hola, ¿qué tal?")
        XCTAssertTrue(result.sawTerminal)
    }

    func testAssistantMessageBeatsDeltas() {
        let stdout = """
        {"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"borrador parcial"}}
        {"record_type":"event","payload":{"event":{"kind":"assistant_message_committed","text":"Respuesta final."}}}
        {"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","text":"Respuesta final."}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.text, "Respuesta final.")
        XCTAssertTrue(result.sawTerminal)
    }

    func testResolveMusePathWithBadOverride() {
        XCTAssertNil(MuseClient.resolveMusePath(override: "/no/existe/muse"))
    }

    func testWorkingDirectoryPrefersWorkspaceForTools() {
        XCTAssertEqual(resolveWorkingDirectory(allowTools: true, workspace: "/tmp/work"), "/tmp/work")
    }

    func testWorkingDirectoryFallsBackToHome() {
        let home = NSHomeDirectory()
        XCTAssertFalse(home.isEmpty)
        XCTAssertEqual(resolveWorkingDirectory(allowTools: false, workspace: "/tmp/work"), home)
        XCTAssertEqual(resolveWorkingDirectory(allowTools: true, workspace: "  "), home)
    }

    func testWorkingDirectoryNeverRoot() {
        XCTAssertNotEqual(resolveWorkingDirectory(allowTools: false, workspace: "/"), "/")
        XCTAssertNotEqual(resolveWorkingDirectory(allowTools: true, workspace: ""), "/")
    }

    func testExecArgsFullAccessWhenToolsEnabled() {
        let request = MuseRequest(
            sessionId: "s1", prompt: "hola", model: "", effort: "low",
            workspace: "/tmp/work", allowTools: true
        )
        let args = museExecArgs(request: request, promptPath: "/tmp/p.txt")
        XCTAssertTrue(args.contains("--workspace"))
        XCTAssertTrue(args.contains("--approval-mode"))
        // Acceso total: shell sin sandbox (control del Mac vía screencapture,
        // osascript, open…), workspace confiable y cambio de workspace.
        XCTAssertTrue(args.contains("--disable-sandbox"))
        XCTAssertTrue(args.contains("--trust-workspace"))
        XCTAssertTrue(args.contains("--allow-workspace-switch"))
        XCTAssertFalse(args.contains("--disable-web-tools"))
        XCTAssertFalse(args.contains("--model"))
    }

    /// Sin recordatorios en ningún modo: tras la respuesta lanzan ~3 s de
    /// tareas (skill/goal/verify-reminder) que en un chat son puro lastre.
    func testExecArgsAlwaysDisableReminders() {
        for allowTools in [true, false] {
            let request = MuseRequest(
                sessionId: "s1", prompt: "hola", model: "", effort: "low",
                workspace: "/tmp/work", allowTools: allowTools
            )
            let args = museExecArgs(request: request, promptPath: "/tmp/p.txt")
            XCTAssertTrue(args.contains("--disable-reminders"), "allowTools=\(allowTools)")
        }
    }

    func testExecArgsRestrictedWhenToolsDisabled() {
        let request = MuseRequest(
            sessionId: "s1", prompt: "hola", model: "m1", effort: "low",
            workspace: "/tmp/work", allowTools: false
        )
        let args = museExecArgs(request: request, promptPath: "/tmp/p.txt")
        XCTAssertTrue(args.contains("--disable-web-tools"))
        XCTAssertFalse(args.contains("--workspace"))
        XCTAssertFalse(args.contains("--disable-sandbox"))
        XCTAssertFalse(args.contains("--trust-workspace"))
        XCTAssertTrue(args.contains("--model"))
    }

    func testTrustHintMentionsDirectory() {
        let hint = decorateTrustHint(
            "muse: Agent delegation: auto unavailable: workspace is untrusted.",
            workingDirectory: "/Users/x"
        )
        XCTAssertTrue(hint.contains("/Users/x"))
        XCTAssertTrue(hint.contains("terminal"))
    }

    func testTrustHintPassthrough() {
        XCTAssertEqual(decorateTrustHint("otro error", workingDirectory: "/Users/x"), "otro error")
    }

    func testEmptyResponseHintSuggestsLoginOnlyOnAuth() {
        let empty = ExecParseResult(text: "", toolNotes: [], sawTerminal: false)
        let authHint = emptyResponseHint(
            stderr: "error: not authenticated (401)", workingDirectory: "/Users/x", parsed: empty
        )
        XCTAssertTrue(authHint.contains("muse login"))
        let parsed = ExecParseResult(
            text: "", toolNotes: [], sawTerminal: false,
            jsonLines: 34, kinds: ["run_output_delta"]
        )
        let plainHint = emptyResponseHint(
            stderr: "muse: workspace trust: trusted", workingDirectory: "/Users/x", parsed: parsed
        )
        XCTAssertFalse(plainHint.contains("muse login"))
        XCTAssertTrue(plainHint.contains("34 líneas JSON"))
        XCTAssertTrue(plainHint.contains("run_output_delta"))
    }

    func testParseDiagnosticsCountJsonLines() {
        let stdout = """
        {"record_type":"event","payload":{"kind":"task_stream_linked"}}
        no-json
        {"record_type":"event","payload":{"event":{"kind":"completed","task_id":"t"}}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.jsonLines, 2)
        XCTAssertTrue(result.kinds.contains("task_stream_linked"))
        XCTAssertTrue(result.kinds.contains("completed"))
    }

    func testStreamParserAccumulatesDeltasIncrementally() {
        let parser = ExecStreamParser()
        let first = parser.feed(Data(
            "{\"record_type\":\"status\",\"payload_type\":\"run.output.delta\",\"payload\":{\"kind\":\"run_output_delta\",\"text\":\"Hola, \"}}\n".utf8
        ))
        XCTAssertEqual(first?.text, "Hola, ")
        let second = parser.feed(Data(
            "{\"record_type\":\"status\",\"payload_type\":\"run.output.delta\",\"payload\":{\"kind\":\"run_output_delta\",\"text\":\"¿qué tal?\"}}\n".utf8
        ))
        XCTAssertEqual(second?.text, "Hola, ¿qué tal?")
    }

    func testStreamParserBuffersPartialLines() {
        let parser = ExecStreamParser()
        let bytes = Array(
            "{\"payload\":{\"event\":{\"kind\":\"assistant_message_committed\",\"text\":\"Listo.\"}}}\n".utf8
        )
        let mid = bytes.count / 2
        XCTAssertNil(parser.feed(Data(bytes[..<mid])))
        let update = parser.feed(Data(bytes[mid...]))
        XCTAssertEqual(update?.text, "Listo.")
    }

    func testStreamParserSkipsNoiseWithoutText() {
        let parser = ExecStreamParser()
        XCTAssertNil(parser.feed(Data(
            "{\"record_type\":\"event\",\"payload\":{\"kind\":\"task_lifecycle\"}}\n".utf8
        )))
    }

    func testStreamParserFinalStateMatchesBatchParse() {
        let stdout = """
        {"schema_version":1,"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"borrador parcial"}}
        {"payload":{"event":{"kind":"assistant_tool_calls_committed","tool_calls":[{"name":"read","path":"/tmp/a.txt"}]}}}
        {"payload":{"event":{"kind":"assistant_message_committed","text":"Respuesta final."}}}
        {"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","text":"Respuesta final."}}
        """
        let batch = parseExecOutput(stdout)
        let parser = ExecStreamParser()
        let bytes = Array((stdout + "\n").utf8)
        var index = 0
        for size in [7, 1, 64, 3, 200] {
            let end = min(index + size, bytes.count)
            _ = parser.feed(Data(bytes[index..<end]))
            index = end
        }
        _ = parser.feed(Data(bytes[index...]))
        let streamed = parser.flush()
        XCTAssertEqual(streamed.text, batch.text)
        XCTAssertEqual(streamed.toolNotes, batch.toolNotes)
        XCTAssertEqual(streamed.sawTerminal, batch.sawTerminal)
        XCTAssertEqual(streamed.jsonLines, batch.jsonLines)
        XCTAssertEqual(streamed.kinds, batch.kinds)
        XCTAssertEqual(streamed.activity, batch.activity)
    }

    func testActivityThinkingFlowsWithoutText() {
        // El modelo piensa en silencio: el titular avisa aunque no haya
        // texto ni notas que pintar.
        let parser = ExecStreamParser()
        let update = parser.feed(Data(
            "{\"record_type\":\"event\",\"payload_type\":\"task.lifecycle.proposed\",\"payload\":{\"kind\":\"task_lifecycle\",\"event\":{\"kind\":\"proposed\",\"task_kind\":\"model.meta.response\"}}}\n".utf8
        ))
        XCTAssertEqual(update?.activity, activityThinking)
        XCTAssertEqual(update?.text ?? "", "")
    }

    func testActivityToolDetailReplacesGeneric() {
        // proposed genérico → side_effect_intent → output con detalle: cada
        // titular reemplaza al anterior, nunca se acumulan.
        let stdout = """
        {"record_type":"event","payload_type":"task.lifecycle.proposed","payload":{"kind":"task_lifecycle","event":{"kind":"proposed","task_kind":"tool.bash"}}}
        {"record_type":"event","payload_type":"task.lifecycle.side_effect_intent","payload":{"kind":"task_lifecycle","event":{"kind":"side_effect_intent","operation":"tool:bash"}}}
        {"record_type":"event","payload_type":"task.lifecycle.output","payload":{"kind":"task_lifecycle","event":{"kind":"output","chunk":"{\\"command\\": \\"ls -1\\", \\"description\\": \\"List workspace files\\"}"}}}
        """
        let result = parseExecOutput(stdout)
        XCTAssertEqual(result.activity, "🔧 List workspace files — `ls -1`")
    }

    func testActivityReadAndWriteChunks() {
        XCTAssertEqual(
            headlineForToolChunk("Read text file `hola.txt`.\n1|hola"),
            "📖 Leyendo hola.txt"
        )
        XCTAssertEqual(
            headlineForToolChunk("wrote 4 bytes to /private/tmp/boty-probe/resumen.txt"),
            "✏️ Escribiendo resumen.txt"
        )
    }

    func testActivityDeltaMeansWriting() {
        let result = parseExecOutput("{\"payload\":{\"kind\":\"run_output_delta\",\"text\":\"hola\"}}\n")
        XCTAssertEqual(result.activity, activityWriting)
    }

    func testActivityIgnoresReminders() {
        let result = parseExecOutput(
            "{\"payload\":{\"kind\":\"task_lifecycle\",\"event\":{\"kind\":\"proposed\",\"task_kind\":\"reminder.agent.skill-reminder\"}}}\n"
        )
        XCTAssertNil(result.activity)
    }

    func testActivityTerminalClears() {
        let stdout = """
        {"payload":{"kind":"run_output_delta","text":"hola"}}
        {"payload":{"kind":"run_terminal","terminal":"completed","text":"hola"}}
        """
        XCTAssertNil(parseExecOutput(stdout).activity)
    }

    func testStreamParserEmitsActivityOnlyUpdates() {
        let parser = ExecStreamParser()
        let thinking = parser.feed(Data(
            "{\"payload\":{\"kind\":\"task_lifecycle\",\"event\":{\"kind\":\"proposed\",\"task_kind\":\"tool.read_file\"}}}\n".utf8
        ))
        XCTAssertEqual(thinking?.activity, "🔧 leyendo archivo…")
        // Repetir el mismo evento no reavisa.
        XCTAssertNil(parser.feed(Data(
            "{\"payload\":{\"kind\":\"task_lifecycle\",\"event\":{\"kind\":\"proposed\",\"task_kind\":\"tool.read_file\"}}}\n".utf8
        )))
    }

    func testActivityToolHeadlineSurvivesLaterThinking() {
        // El detalle de la herramienta no parpadea a genérico cuando el
        // modelo encadena su siguiente turno de razonamiento.
        let stdout = """
        {"payload":{"kind":"task_lifecycle","event":{"kind":"proposed","task_kind":"tool.bash"}}}
        {"payload":{"kind":"task_lifecycle","event":{"kind":"output","chunk":"{\\"command\\": \\"ls -1\\", \\"description\\": \\"List workspace files\\"}"}}}
        {"payload":{"kind":"task_lifecycle","event":{"kind":"proposed","task_kind":"model.meta.response"}}}
        {"payload":{"kind":"task_lifecycle","event":{"kind":"side_effect_intent","operation":"model.meta.response"}}}
        """
        XCTAssertEqual(parseExecOutput(stdout).activity, "🔧 List workspace files — `ls -1`")
    }

    func testActivityWritingReplacesToolHeadline() {
        // Cuando llega texto de respuesta, redactar sí reemplaza.
        let stdout = """
        {"payload":{"kind":"task_lifecycle","event":{"kind":"proposed","task_kind":"tool.bash"}}}
        {"payload":{"kind":"run_output_delta","text":"hola"}}
        """
        XCTAssertEqual(parseExecOutput(stdout).activity, activityWriting)
    }

    func testActivityIgnoresUnknownChunkShape() {
        // stdout crudo sin forma conocida no pisa el titular vigente.
        let stdout = """
        {"payload":{"kind":"task_lifecycle","event":{"kind":"proposed","task_kind":"tool.bash"}}}
        {"payload":{"kind":"task_lifecycle","event":{"kind":"output","chunk":"línea cruda de stdout sin forma conocida"}}}
        """
        XCTAssertEqual(parseExecOutput(stdout).activity, "🔧 comando…")
    }

    func testRunPromptStreamsPartialUpdatesBeforeFinishing() async throws {
        // El binario falso emite los deltas con pausas: la app debe avisar
        // con texto parcial ANTES de que termine el proceso.
        let script = """
        #!/bin/bash
        echo '{"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"¡Hola! "}}'
        sleep 0.5
        echo '{"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"¿En qué te ayudo?"}}'
        sleep 0.5
        echo '{"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","text":"¡Hola! ¿En qué te ayudo?","reason":null}}'
        """
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-muse-stream-\(UUID().uuidString).sh")
        try script.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeURL.path
        )
        defer { try? FileManager.default.removeItem(at: fakeURL) }

        let updates = UpdatesBox()
        let request = MuseRequest(
            sessionId: UUID().uuidString, prompt: "hola",
            model: "", effort: "low", workspace: "/tmp", allowTools: false,
            timeoutSeconds: 30
        )
        let result = try await MuseClient.runPrompt(
            musePath: fakeURL.path, request: request, token: MuseRunToken(),
            onUpdate: { text, _ in updates.append(text) }
        )
        XCTAssertEqual(result.text, "¡Hola! ¿En qué te ayudo?")
        let seen = updates.value
        XCTAssertGreaterThanOrEqual(seen.count, 2)
        XCTAssertNotEqual(seen.first, result.text)
        XCTAssertTrue(result.text.hasPrefix(seen.first ?? ""))
        XCTAssertEqual(seen.last, result.text)
    }

    func testRunPromptReportsActivityHeadlines() async throws {
        // El binario falso emite ciclo de vida de herramienta: la app debe
        // avisar con el titular genérico y luego con el detalle.
        let script = """
        #!/bin/bash
        echo '{"record_type":"event","payload_type":"task.lifecycle.proposed","payload":{"kind":"task_lifecycle","event":{"kind":"proposed","task_kind":"tool.bash"}}}'
        sleep 0.2
        echo '{"record_type":"event","payload_type":"task.lifecycle.output","payload":{"kind":"task_lifecycle","event":{"kind":"output","chunk":"{\\"command\\": \\"ls -1\\", \\"description\\": \\"List workspace files\\"}"}}}'
        sleep 0.2
        echo '{"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","text":"ok","reason":null}}'
        """
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-muse-activity-\(UUID().uuidString).sh")
        try script.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeURL.path
        )
        defer { try? FileManager.default.removeItem(at: fakeURL) }

        let seen = ActivitiesBox()
        let request = MuseRequest(
            sessionId: UUID().uuidString, prompt: "hola",
            model: "", effort: "low", workspace: "/tmp", allowTools: false,
            timeoutSeconds: 30
        )
        let result = try await MuseClient.runPrompt(
            musePath: fakeURL.path, request: request, token: MuseRunToken(),
            onActivity: { seen.append($0) }
        )
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(seen.value.first, "🔧 comando…")
        XCTAssertTrue(seen.value.contains("🔧 List workspace files — `ls -1`"))
    }

    func testDataBoxRoundTrip() {
        let box = DataBox()
        box.append(Data("ab".utf8))
        box.append(Data("cd".utf8))
        XCTAssertEqual(box.value, Data("abcd".utf8))
    }

    func testRunPromptExtractsTextFromFakeBinary() async throws {
        // Binario falso que imita `muse exec --json`: diagnóstico por
        // stderr y eventos JSONL reales por stdout, con exit 0.
        let sample = """
        {"schema_version":1,"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"¡Hola! "}}
        {"schema_version":1,"record_type":"status","payload_type":"run.output.delta","payload":{"kind":"run_output_delta","text":"¿En qué te ayudo?"}}
        {"schema_version":1,"record_type":"event","payload_type":"run.terminal.completed","payload":{"kind":"run_terminal","terminal":"completed","text":"¡Hola! ¿En qué te ayudo?","reason":null}}
        """
        let script = """
        #!/bin/bash
        echo 'muse: workspace trust: trusted source=user-config' >&2
        cat <<'EOF'
        \(sample)
        EOF
        """
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-muse-\(UUID().uuidString).sh")
        try script.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeURL.path
        )
        defer { try? FileManager.default.removeItem(at: fakeURL) }

        let request = MuseRequest(
            sessionId: UUID().uuidString, prompt: "hola",
            model: "", effort: "low", workspace: "/tmp", allowTools: false,
            timeoutSeconds: 30
        )
        let result = try await MuseClient.runPrompt(
            musePath: fakeURL.path, request: request, token: MuseRunToken()
        )
        XCTAssertEqual(result.text, "¡Hola! ¿En qué te ayudo?")
        XCTAssertTrue(result.sawTerminal)
    }
}

/// Colector thread-safe de titulares de actividad para los tests.
private final class ActivitiesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var headlines: [String?] = []

    func append(_ headline: String?) {
        lock.withLock { headlines.append(headline) }
    }

    var value: [String?] {
        lock.withLock { headlines }
    }
}

/// Colector thread-safe de avisos de streaming para los tests.
private final class UpdatesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []

    func append(_ text: String) {
        lock.withLock { texts.append(text) }
    }

    var value: [String] {
        lock.withLock { texts }
    }
}
