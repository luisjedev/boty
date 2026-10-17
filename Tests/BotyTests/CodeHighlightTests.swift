import SwiftUI
import XCTest

@testable import Boty

final class CodeHighlightTests: XCTestCase {
    private var palette: CodePalette { codePalette(theme: .catppuccin, dark: true) }

    private func highlight(_ code: String, language: String) -> AttributedString {
        highlightedCode(code, language: language, palette: palette)
    }

    /// Color del primer tramo que contiene `needle`.
    private func color(of needle: String, in attr: AttributedString) -> Color? {
        for run in attr.runs where run.foregroundColor != nil {
            if String(attr[run.range].characters).contains(needle) {
                return run.foregroundColor
            }
        }
        return nil
    }

    private func allColors(in attr: AttributedString) -> [Color?] {
        attr.runs.map(\.foregroundColor)
    }

    func testSwiftBasics() {
        let code = "let greeting = \"hola\"\nfoo(1)"
        let attr = highlight(code, language: "swift")
        XCTAssertEqual(String(attr.characters), code)
        XCTAssertEqual(color(of: "let", in: attr), palette.keyword)
        XCTAssertEqual(color(of: "\"hola\"", in: attr), palette.string)
        XCTAssertEqual(color(of: "foo", in: attr), palette.function)
        XCTAssertEqual(color(of: "1", in: attr), palette.number)
        XCTAssertEqual(color(of: "greeting", in: attr), palette.text)
    }

    func testCommentBeatsString() {
        let code = "// \"no es texto\"\nlet x = 1"
        let attr = highlight(code, language: "swift")
        XCTAssertEqual(String(attr.characters), code)
        XCTAssertEqual(color(of: "\"no es texto\"", in: attr), palette.comment)
        XCTAssertEqual(color(of: "let", in: attr), palette.keyword)
    }

    func testBlockComment() {
        let attr = highlight("/* a\nb */ let", language: "swift")
        XCTAssertEqual(color(of: "a\nb", in: attr), palette.comment)
        XCTAssertEqual(color(of: "let", in: attr), palette.keyword)
    }

    func testUnclosedStringDuringStreaming() {
        // Código a medio llegar: la cadena abierta tiñe hasta el final.
        let code = "let s = \"abc"
        let attr = highlight(code, language: "swift")
        XCTAssertEqual(String(attr.characters), code)
        XCTAssertEqual(color(of: "\"abc", in: attr), palette.string)
    }

    func testPythonHashAndSingleQuotes() {
        let code = "x = 'a b'  # nota"
        let attr = highlight(code, language: "python")
        XCTAssertEqual(String(attr.characters), code)
        XCTAssertEqual(color(of: "'a b'", in: attr), palette.string)
        XCTAssertEqual(color(of: "# nota", in: attr), palette.comment)
    }

    func testApostropheWithoutClosingIsText() {
        // "don't" no debe teñir el resto del bloque como cadena.
        let attr = highlight("don't worry", language: "")
        XCTAssertTrue(allColors(in: attr).allSatisfy { $0 == palette.text })
    }

    func testLuaLongBrackets() {
        let code = "local s = [[hola]] -- fin"
        let attr = highlight(code, language: "lua")
        XCTAssertEqual(String(attr.characters), code)
        XCTAssertEqual(color(of: "local", in: attr), palette.keyword)
        XCTAssertEqual(color(of: "[[hola]]", in: attr), palette.string)
        XCTAssertEqual(color(of: "-- fin", in: attr), palette.comment)
    }

    func testLuaLongComment() {
        let attr = highlight("--[[ oculto ]] print(1)", language: "lua")
        XCTAssertEqual(color(of: "oculto", in: attr), palette.comment)
        XCTAssertEqual(color(of: "print", in: attr), palette.function)
    }

    func testDirectives() {
        let attr = highlight("@MainActor\n#available(iOS 17, *)", language: "swift")
        XCTAssertEqual(color(of: "@MainActor", in: attr), palette.directive)
        XCTAssertEqual(color(of: "#available", in: attr), palette.directive)
    }

    func testShellVariables() {
        let attr = highlight("echo $HOME ${x} $0", language: "bash")
        XCTAssertEqual(color(of: "$HOME", in: attr), palette.directive)
        XCTAssertEqual(color(of: "${x}", in: attr), palette.directive)
        XCTAssertEqual(color(of: "$0", in: attr), palette.directive)
    }

    func testUppercaseIsTypeUnlessCall() {
        let attr = highlight("let v: String = Foo()", language: "swift")
        XCTAssertEqual(color(of: "String", in: attr), palette.type)
        // Seguido de paréntesis manda "llamada", como en los editores.
        XCTAssertEqual(color(of: "Foo", in: attr), palette.function)
    }

    func testUnknownLanguageStillHighlightsBasics() {
        let code = "# nota\nx = \"s\" + 2"
        let attr = highlight(code, language: "")
        XCTAssertEqual(String(attr.characters), code)
        XCTAssertEqual(color(of: "# nota", in: attr), palette.comment)
        XCTAssertEqual(color(of: "\"s\"", in: attr), palette.string)
        XCTAssertEqual(color(of: "2", in: attr), palette.number)
    }

    func testLongCodeFallsBackToPlain() {
        let code = String(repeating: "let x = \"y\" // z\n", count: 2000)
        XCTAssertGreaterThan(code.count, codeHighlightLengthLimit)
        let attr = highlight(code, language: "swift")
        XCTAssertEqual(String(attr.characters), code)
        XCTAssertTrue(allColors(in: attr).allSatisfy { $0 == palette.text })
    }

    func testThemesDiffer() {
        let mocha = codePalette(theme: .catppuccin, dark: true)
        let latte = codePalette(theme: .catppuccin, dark: false)
        let oneDark = codePalette(theme: .oneDark, dark: true)
        let oneLight = codePalette(theme: .oneDark, dark: false)
        XCTAssertNotEqual(mocha.keyword, oneDark.keyword)
        XCTAssertNotEqual(mocha.background, latte.background)
        XCTAssertNotEqual(oneDark.background, oneLight.background)
        XCTAssertNotEqual(mocha.string, mocha.comment)
    }

    func testLegacySettingsDecodeKeepsValues() {
        // Ajustes guardados antes de existir `codeTheme` (y con el antiguo
        // `maxChainHops`): no se pierden y la clave retirada se ignora.
        let json = #"{"musePath":"/tmp/muse","followBotMentions":false,"maxChainHops":5}"#
        let loaded = try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(loaded?.musePath, "/tmp/muse")
        XCTAssertEqual(loaded?.followBotMentions, false)
        XCTAssertEqual(loaded?.codeTheme, .catppuccin)
    }
}
