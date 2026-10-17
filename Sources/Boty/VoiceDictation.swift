import AVFoundation
import Combine
import Foundation
import Speech

// MARK: - Lógica pura (testeable sin micrófono)

/// Normaliza un identificador de locale (`es_ES` → `es-ES`) para comparar el
/// preferido del sistema con los que soporta el reconocedor.
func voiceCanonicalLocaleID(_ id: String) -> String {
    id.replacingOccurrences(of: "_", with: "-")
}

/// Elige el locale de dictado: el preferido exacto si está disponible, si no
/// una variante del mismo idioma, si no español, si no inglés, si no el
/// primero por orden. `nil` cuando no hay ninguno.
func voicePreferredLocaleID(preferredID: String, availableIDs: Set<String>) -> String? {
    if availableIDs.isEmpty { return nil }
    let preferred = voiceCanonicalLocaleID(preferredID)
    if let exact = availableIDs.first(where: { voiceCanonicalLocaleID($0) == preferred }) {
        return exact
    }
    let language = String(preferred.split(separator: "-").first ?? Substring(preferred))
    let sameLanguage = availableIDs
        .filter {
            let canonical = voiceCanonicalLocaleID($0)
            return canonical == language || canonical.hasPrefix(language + "-")
        }
        .sorted()
    if let match = sameLanguage.first { return match }
    for fallback in ["es-ES", "es-MX", "es-US", "es", "en-US", "en-GB", "en"] {
        if let match = availableIDs.first(where: { voiceCanonicalLocaleID($0) == fallback }) {
            return match
        }
    }
    return availableIDs.sorted().first
}

/// Mezcla el texto que ya había en el cajón (`base`, fijado al pulsar el
/// micrófono) con la transcripción parcial en vivo: el parcial sustituye al
/// parcial anterior, nunca se acumula ni se pierde lo escrito antes.
func voiceMergedText(base: String, live: String) -> String {
    if live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return base }
    if base.isEmpty { return live }
    if let last = base.last, last.isWhitespace { return base + live }
    return base + " " + live
}

// MARK: - Manager

/// Puente Sendable entre los callbacks de Speech/AVFoundation (que llegan en
/// hilos del sistema) y el manager. `append` es seguro desde el hilo de audio
/// por diseño de `SFSpeechAudioBufferRecognitionRequest`; el resto reenvía al
/// actor principal. El `sessionID` descarta respuestas tardías de una sesión
/// ya cancelada cuando se empieza otra seguida.
///
/// El sistema recibe referencias directas a estos métodos, NUNCA closures en
/// línea del manager: al estar el manager en el main actor, un closure en
/// línea heredaría su aislamiento y petaría con SIGTRAP (`dispatch_assert_queue`)
/// en cuanto CoreAudio/Speech lo invocase fuera del hilo principal (tal como
/// pasó). Interna para que los tests la ejerciten (ver VoiceThreadingTests).
final class VoiceCallbackBridge: @unchecked Sendable {
    weak var manager: VoiceDictationManager?
    let request: SFSpeechAudioBufferRecognitionRequest?
    let sessionID = UUID()

    init(manager: VoiceDictationManager, request: SFSpeechAudioBufferRecognitionRequest? = nil) {
        self.manager = manager
        self.request = request
    }

    /// Entrada del tap de CoreAudio: llega en el hilo realtime de audio.
    func audioTap(buffer: AVAudioPCMBuffer, time _: AVAudioTime) {
        request?.append(buffer)
    }

    func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        let text = result?.bestTranscription.formattedString ?? ""
        let isFinal = result?.isFinal ?? false
        let failed = error != nil
        Task { @MainActor [box = self] in
            box.manager?.handleRecognition(
                session: box.sessionID, text: text, isFinal: isFinal, failed: failed
            )
        }
    }

    func handleSpeechAuth(_ status: SFSpeechRecognizerAuthorizationStatus) {
        Task { @MainActor [box = self] in
            box.manager?.handleSpeechAuth(status)
        }
    }

    func handleMicAccess(granted: Bool) {
        Task { @MainActor [box = self] in
            box.manager?.handleMicAccess(granted: granted)
        }
    }
}

/// Dictado por voz con el reconocedor nativo de Apple: transcribe en tiempo
/// real al cajón de texto. Nunca envía solo: el usuario revisa y pulsa Enviar.
@MainActor
final class VoiceDictationManager: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var liveText = ""
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var errorMessage: String?

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var bridge: VoiceCallbackBridge?
    private var sessionID: UUID?

    func toggle() {
        if isRecording {
            stop()
            return
        }
        errorMessage = nil
        liveText = ""
        guard let locale = resolveLocale() else {
            errorMessage = "Este Mac no ofrece reconocimiento de voz."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            errorMessage = "El dictado no está disponible ahora mismo (puede necesitar conexión a internet)."
            return
        }
        self.recognizer = recognizer
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            checkMicAndStart()
        case .denied, .restricted:
            errorMessage = "Sin permiso de reconocimiento de voz: actívalo en Ajustes del Sistema > Privacidad y seguridad > Reconocimiento de voz."
        case .notDetermined:
            requestSpeechAuth()
        @unknown default:
            requestSpeechAuth()
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        bridge?.request?.endAudio()
        // La tarea se libera al llegar el resultado final.
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Privado

    private func resolveLocale() -> Locale? {
        let available = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        guard let id = voicePreferredLocaleID(preferredID: Locale.current.identifier, availableIDs: available) else {
            return nil
        }
        return Locale(identifier: id)
    }

    private func requestSpeechAuth() {
        isRequestingPermission = true
        let box = VoiceCallbackBridge(manager: self)
        // Referencia al método, no closure en línea (ver doc del puente).
        SFSpeechRecognizer.requestAuthorization(box.handleSpeechAuth)
    }

    fileprivate func handleSpeechAuth(_ status: SFSpeechRecognizerAuthorizationStatus) {
        isRequestingPermission = false
        switch status {
        case .authorized:
            checkMicAndStart()
        case .denied, .restricted:
            errorMessage = "Sin permiso de reconocimiento de voz: actívalo en Ajustes del Sistema > Privacidad y seguridad > Reconocimiento de voz."
        case .notDetermined:
            errorMessage = "El dictado necesita permiso de reconocimiento de voz."
        @unknown default:
            errorMessage = "El dictado necesita permiso de reconocimiento de voz."
        }
    }

    private func checkMicAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .denied, .restricted:
            errorMessage = "Sin permiso de micrófono: actívalo en Ajustes del Sistema > Privacidad y seguridad > Micrófono."
        case .notDetermined:
            isRequestingPermission = true
            let box = VoiceCallbackBridge(manager: self)
            // Referencia al método, no closure en línea (ver doc del puente).
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: box.handleMicAccess(granted:))
        @unknown default:
            errorMessage = "El dictado necesita permiso de micrófono."
        }
    }

    fileprivate func handleMicAccess(granted: Bool) {
        isRequestingPermission = false
        if granted {
            startRecording()
        } else {
            errorMessage = "Sin permiso de micrófono: actívalo en Ajustes del Sistema > Privacidad y seguridad > Micrófono."
        }
    }

    private func startRecording() {
        guard let recognizer else { return }
        cancelRecognition()
        errorMessage = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let box = VoiceCallbackBridge(manager: self, request: request)
        bridge = box
        sessionID = box.sessionID
        // Referencias a métodos, no closures en línea (ver doc del puente):
        // ambos se invocan en hilos del sistema, fuera del hilo principal.
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: box.handle(result:error:))
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0),
            block: box.audioTap(buffer:time:)
        )
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cancelRecognition()
            errorMessage = "No se pudo abrir el micrófono."
            return
        }
        isRecording = true
    }

    fileprivate func handleRecognition(session: UUID, text: String, isFinal: Bool, failed: Bool) {
        // Respuestas tardías de una sesión ya cancelada: ignorar.
        guard session == sessionID else { return }
        if !text.isEmpty { liveText = text }
        if failed {
            let hadText = !liveText.isEmpty
            cancelRecognition()
            isRecording = false
            if !hadText {
                errorMessage = "No se pudo transcribir el audio."
            }
        } else if isFinal, !isRecording {
            cancelRecognition()
        }
    }

    /// Cancela la tarea en curso y suelta audio y callbacks.
    private func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        bridge = nil
        sessionID = nil
    }
}
