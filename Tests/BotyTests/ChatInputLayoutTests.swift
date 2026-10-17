import AppKit
import SwiftUI
import XCTest

@testable import Boty

/// Regresión del input auto-creciente: la fila es única y estable
/// (editor flexible, micro, enviar) y la altura medida solo ajusta rasgos
/// verticales (padding y alineación). Elegir el contenedor horizontal según
/// la altura reincide en el bucle de layout
/// (ver testWrappingLineMustNotSwitchHorizontalContainer).
final class ChatInputLayoutTests: XCTestCase {
    func testSingleLineContentIsNotMultiline() {
        XCTAssertFalse(chatInputIsMultiline(contentHeight: 20, singleLineHeight: 20))
        XCTAssertFalse(chatInputIsMultiline(contentHeight: 26, singleLineHeight: 20))
    }

    func testGrowingContentIsMultiline() {
        XCTAssertTrue(chatInputIsMultiline(contentHeight: 26.1, singleLineHeight: 20))
        XCTAssertTrue(chatInputIsMultiline(contentHeight: 60, singleLineHeight: 20))
    }

    func testVerticalPaddingGrowsWithContent() {
        XCTAssertEqual(chatInputVerticalPadding(contentHeight: 20, singleLineHeight: 20), 6)
        XCTAssertEqual(chatInputVerticalPadding(contentHeight: 26, singleLineHeight: 20), 6)
        XCTAssertEqual(chatInputVerticalPadding(contentHeight: 26.1, singleLineHeight: 20), 8)
        XCTAssertEqual(chatInputVerticalPadding(contentHeight: 60, singleLineHeight: 20), 8)
    }

    /// El texto del cajón (y su placeholder, que usa la misma letra) va un
    /// punto por encima del cuerpo de lectura para que no se vea pequeño.
    func testEditorFontIsBiggerThanReadingBody() {
        XCTAssertGreaterThan(GrowingTextEditor.baseFontSize, 14)
        // La altura de una línea acompasa a esa letra.
        let singleLine = GrowingTextEditor.singleLineHeight()
        XCTAssertGreaterThan(singleLine, GrowingTextEditor.verticalInset * 2)
    }

    /// Regresión del bucle de layout: una línea que envuelve a 2 líneas al
    /// ancho estrecho pero cabe en 1 a ancho completo cruza el umbral en
    /// ambos sentidos. Si la altura medida eligiera el contenedor horizontal
    /// (HStack estrecho vs VStack ancho), el layout bascularía sin fin y el
    /// input y el scroll del chat petardearían en bucle. Por eso la fila del
    /// input es única y estable y la altura solo ajusta el padding vertical.
    func testWrappingLineMustNotSwitchHorizontalContainer() {
        let singleLineHeight: CGFloat = 20
        let wrappedNarrowHeight: CGFloat = 40
        let fitsWideHeight: CGFloat = 20
        XCTAssertTrue(chatInputIsMultiline(
            contentHeight: wrappedNarrowHeight, singleLineHeight: singleLineHeight
        ))
        XCTAssertFalse(chatInputIsMultiline(
            contentHeight: fitsWideHeight, singleLineHeight: singleLineHeight
        ))
        // Mismo umbral, efecto sin realimentación: solo padding vertical.
        XCTAssertEqual(
            chatInputVerticalPadding(contentHeight: wrappedNarrowHeight, singleLineHeight: singleLineHeight),
            8
        )
        XCTAssertEqual(
            chatInputVerticalPadding(contentHeight: fitsWideHeight, singleLineHeight: singleLineHeight),
            6
        )
    }
}

/// Tamaños de la sección de envío: enviar manda en la fila, los laterales
/// (micro) van por debajo pero bien por encima del texto, y todo escala
/// linealmente con el zoom de la app.
final class ChatSendSizeTests: XCTestCase {
    func testSendIconLeadsRow() {
        XCTAssertGreaterThan(chatSendIconSize(scale: 1), chatSideIconSize(scale: 1))
        XCTAssertGreaterThan(
            chatSideIconSize(scale: 1),
            NSFont.preferredFont(forTextStyle: .body).pointSize
        )
    }

    func testTapTargetsCoverIcons() {
        XCTAssertGreaterThanOrEqual(chatSendTapSize(scale: 1), chatSendIconSize(scale: 1))
        XCTAssertGreaterThanOrEqual(chatSideTapSize(scale: 1), chatSideIconSize(scale: 1))
    }

    func testSizesScaleLinearlyWithZoom() {
        for scale in [0.8, 1.0, 1.5, 2.0] {
            XCTAssertEqual(chatSendIconSize(scale: scale), 28 * scale)
            XCTAssertEqual(chatSideIconSize(scale: scale), 22 * scale)
            XCTAssertEqual(chatSendTapSize(scale: scale), 40 * scale)
            XCTAssertEqual(chatSideTapSize(scale: scale), 36 * scale)
        }
    }
}

/// Regresión: ESC dentro del editor detiene la respuesta en curso (igual
/// que el botón Detener). Sin este manejo, el NSTextView se tragaría la
/// tecla y el atajo del botón nunca se dispararía con el foco en el editor.
@MainActor
final class ChatInputEscapeTests: XCTestCase {
    func testEscapeInEditorInvokesOnEscape() {
        var escaped = false
        let editor = GrowingTextEditor(
            text: .constant("hola"),
            contentHeight: .constant(20),
            focusToken: 0,
            onSubmit: {},
            onEscape: { escaped = true }
        )
        let handled = editor.makeCoordinator().textView(
            NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertTrue(escaped)
    }

    func testEscapeWithoutHandlerIsStillConsumed() {
        let editor = GrowingTextEditor(
            text: .constant(""),
            contentHeight: .constant(20),
            focusToken: 0,
            onSubmit: {}
        )
        let handled = editor.makeCoordinator().textView(
            NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertTrue(handled)
    }
}

/// Regresión: la altura medida se publica al @State de forma asíncrona y
/// converge. `recalculateHeight` corre dentro de `updateNSView` y de `layout`,
/// así que escribir el Binding de forma síncrona mutaría estado durante el
/// view update de SwiftUI (comportamiento indefinido y pasadas extra).
@MainActor
final class ChatInputHeightPublishTests: XCTestCase {
    private final class HeightBox: @unchecked Sendable {
        var value: CGFloat
        init(_ value: CGFloat) { self.value = value }
    }

    func testHeightPublishesAsyncAndConverges() async {
        let singleLine = GrowingTextEditor.singleLineHeight()
        let box = HeightBox(singleLine)
        let longText = String(repeating: "hola ", count: 60)
        let editor = GrowingTextEditor(
            text: .constant(longText),
            contentHeight: Binding(get: { box.value }, set: { box.value = $0 }),
            focusToken: 0,
            onSubmit: {}
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        scrollView.hasVerticalScroller = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.font = .systemFont(ofSize: GrowingTextEditor.baseFontSize)
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 0, height: GrowingTextEditor.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = longText
        scrollView.documentView = textView
        scrollView.layout()

        let coordinator = editor.makeCoordinator()
        coordinator.textView = textView
        coordinator.scrollView = scrollView

        coordinator.recalculateHeight()
        // Sin mutación síncrona durante el view update…
        XCTAssertEqual(box.value, singleLine, accuracy: 0.5)
        await flushMainQueue()
        // …la altura multilínea llega justo después…
        let published = box.value
        XCTAssertGreaterThan(published, singleLine + 6)
        // …y las siguientes pasadas de layout no la mueven (converge).
        coordinator.recalculateHeight()
        await flushMainQueue()
        XCTAssertEqual(box.value, published, accuracy: 0.5)
    }

    /// Espera a los bloques ya encolados en la cola principal (la
    /// publicación va delante de este marcador por orden FIFO).
    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
