import XCTest

@testable import Boty

final class MarkdownBlocksTests: XCTestCase {
    /// `MarkdownBody` es `Equatable` para que SwiftUI no reparsee los
    /// mensajes intactos en cada repintado de streaming.
    func testMarkdownBodyEquality() {
        XCTAssertEqual(MarkdownBody(text: "hola"), MarkdownBody(text: "hola"))
        XCTAssertNotEqual(MarkdownBody(text: "hola"), MarkdownBody(text: "adiós"))
        XCTAssertNotEqual(
            MarkdownBody(text: "hola", codeTheme: .catppuccin),
            MarkdownBody(text: "hola", codeTheme: .oneDark)
        )
    }

    func testParagraphsPreserveSingleNewlines() {
        let blocks = splitMarkdownBlocks("línea uno\nlínea dos\n\nsegundo párrafo")
        XCTAssertEqual(blocks, [
            .paragraph("línea uno\nlínea dos"),
            .paragraph("segundo párrafo"),
        ])
    }

    func testCodeFenceWithLanguage() {
        let blocks = splitMarkdownBlocks("Antes\n\n```lua\nprint(\"hola\")\n```\n\nDespués")
        XCTAssertEqual(blocks, [
            .paragraph("Antes"),
            .code(language: "lua", code: "print(\"hola\")"),
            .paragraph("Después"),
        ])
    }

    func testUnclosedFenceIsStillCode() {
        // Durante el streaming el bloque llega sin cerrar: debe verse como
        // código igualmente, no como texto apelotonado.
        let blocks = splitMarkdownBlocks("Mira:\n\n```swift\nlet x = 1\nlet y = 2")
        XCTAssertEqual(blocks, [
            .paragraph("Mira:"),
            .code(language: "swift", code: "let x = 1\nlet y = 2"),
        ])
    }

    func testHeadingsAndDivider() {
        let blocks = splitMarkdownBlocks("# Título\n\nTexto\n\n---\n\n## Sub")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Título"),
            .paragraph("Texto"),
            .divider,
            .heading(level: 2, text: "Sub"),
        ])
    }

    func testBulletsAndNumbered() {
        let blocks = splitMarkdownBlocks("- uno\n- dos\n\n1. primero\n2. segundo")
        XCTAssertEqual(blocks, [
            .bullets(items: [
                MarkdownListItem(indent: 0, text: "uno"),
                MarkdownListItem(indent: 0, text: "dos"),
            ]),
            .numbered(items: [
                MarkdownListItem(indent: 0, text: "primero"),
                MarkdownListItem(indent: 0, text: "segundo"),
            ]),
        ])
    }

    func testQuote() {
        let blocks = splitMarkdownBlocks("> «Coder» te pasa la palabra:\n> sigue tú")
        XCTAssertEqual(blocks, [.quote("«Coder» te pasa la palabra:\nsigue tú")])
    }

    func testTableDropsSeparatorRow() {
        let blocks = splitMarkdownBlocks("| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks, [.table(rows: [["A", "B"], ["1", "2"]])])
    }

    func testInlineKeepsBreaksAndBold() {
        let attr = inlineAttributed("hola **fuerte**\nsegunda línea")
        XCTAssertEqual(String(attr.characters), "hola fuerte\nsegunda línea")
        XCTAssertTrue(attr.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    func testInlineToleratesPartialMarkdown() {
        // Markdown a medio llegar (streaming): no debe perder el texto.
        XCTAssertEqual(String(inlineAttributed("**roto").characters), "**roto")
        XCTAssertEqual(String(inlineAttributed("`abierto").characters), "`abierto")
    }

    func testRealBotSample() {
        let sample = """
        Sí. Solo necesitas Lua básico y una carpeta en `Interface/AddOns`.

        Ejemplo mínimo:

        **MiAddon.toc**
        ```
        ## Interface: 120105
        ## Title: MiAddon
        MiAddon.lua
        ```

        Lo pones en juego con `/miaddon`.
        """
        let blocks = splitMarkdownBlocks(sample)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .paragraph("Sí. Solo necesitas Lua básico y una carpeta en `Interface/AddOns`."))
        XCTAssertEqual(blocks[1], .paragraph("Ejemplo mínimo:"))
        XCTAssertEqual(blocks[2], .paragraph("**MiAddon.toc**"))
        XCTAssertEqual(blocks[3], .code(language: "", code: "## Interface: 120105\n## Title: MiAddon\nMiAddon.lua"))
        XCTAssertEqual(blocks[4], .paragraph("Lo pones en juego con `/miaddon`."))
    }
}
