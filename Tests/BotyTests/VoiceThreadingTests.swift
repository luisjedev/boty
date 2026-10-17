import AVFoundation
import Speech
import XCTest

@testable import Boty

/// Regresión del crash al arrancar el micro (SIGTRAP en `dispatch_assert_queue`):
/// los callbacks de CoreAudio/Speech llegan en hilos del sistema, nunca en el
/// principal. El puente debe aceptarlos fuera del main actor y reenviar el
/// estado dentro. Todo sin micrófono ni diálogos de permiso.
final class VoiceThreadingTests: XCTestCase {
    /// Las mismas referencias a métodos que se entregan al sistema deben poder
    /// invocarse desde un executor de fondo, como el hilo realtime del crash.
    @MainActor
    func testBridgeCallbacksFromBackgroundThread() async {
        let manager = VoiceDictationManager()
        let request = SFSpeechAudioBufferRecognitionRequest()
        let bridge = VoiceCallbackBridge(manager: manager, request: request)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = bridge.audioTap(buffer:time:)
        await Task.detached {
            // Tap de audio + resultado huérfano de una sesión ya cancelada:
            // deben sobrevivir sin hacer nada visible…
            tap(buffer, AVAudioTime(hostTime: 0))
            bridge.handle(result: nil, error: NSError(domain: "BotyTests", code: 1))
            // …y el acceso denegado debe reenviar el error al hilo principal.
            bridge.handleMicAccess(granted: false)
        }.value
        await waitForError(on: manager)
        XCTAssertTrue(manager.errorMessage?.contains("micrófono") == true)
    }

    @MainActor
    func testSpeechDeniedFromBackgroundThread() async {
        let manager = VoiceDictationManager()
        let bridge = VoiceCallbackBridge(manager: manager)
        await Task.detached {
            bridge.handleSpeechAuth(.denied)
        }.value
        await waitForError(on: manager)
        XCTAssertTrue(manager.errorMessage?.contains("reconocimiento de voz") == true)
    }

    /// El reenvío al actor principal es asíncrono: esperar a que llegue.
    @MainActor
    private func waitForError(on manager: VoiceDictationManager) async {
        for _ in 0 ..< 100 {
            if manager.errorMessage != nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("el puente no reenvió el estado al hilo principal")
    }
}
