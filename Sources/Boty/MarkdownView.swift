import AppKit
import Foundation
import SwiftUI

// MARK: - Modelo de bloques

struct MarkdownListItem: Equatable, Sendable {
    var indent: Int
    var text: String
}

enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets(items: [MarkdownListItem])
    case numbered(items: [MarkdownListItem])
    case quote(String)
    case code(language: String, code: String)
    case table(rows: [[String]])
    case divider
}

// MARK: - Parser (puro, testeable)

/// Trocea texto Markdown en bloques de presentación. Tolera cercas de código
/// sin cerrar (texto a medio llegar por streaming) tratándolas como código.
func splitMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var bullets: [MarkdownListItem] = []
    var numbered: [MarkdownListItem] = []
    var quote: [String] = []
    var tableRows: [[String]] = []
    var fenceMarker: String?
    var fenceLanguage = ""
    var fenceLines: [String] = []

    func flushParagraph() {
        if !paragraph.isEmpty {
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
    }
    func flushLists() {
        if !bullets.isEmpty { blocks.append(.bullets(items: bullets)); bullets = [] }
        if !numbered.isEmpty { blocks.append(.numbered(items: numbered)); numbered = [] }
    }
    func flushQuote() {
        if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
    }
    func flushTable() {
        let rows = tableRows.filter { !$0.isEmpty }
        if !rows.isEmpty { blocks.append(.table(rows: rows)) }
        tableRows = []
    }
    func flushNonCode() {
        flushParagraph()
        flushLists()
        flushQuote()
        flushTable()
    }

    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        // Dentro de una cerca de código todo es literal hasta el cierre.
        if let marker = fenceMarker {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix(marker), stripped.dropFirst(marker.count).allSatisfy({ $0 == "`" || $0 == "~" || $0.isWhitespace }) {
                blocks.append(.code(language: fenceLanguage, code: fenceLines.joined(separator: "\n")))
                fenceMarker = nil
                fenceLanguage = ""
                fenceLines = []
            } else {
                fenceLines.append(line)
            }
            continue
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flushNonCode()
            continue
        }
        if let (marker, language) = openingFence(trimmed) {
            flushNonCode()
            fenceMarker = marker
            fenceLanguage = language
            continue
        }
        if let heading = parseHeading(trimmed) {
            flushNonCode()
            blocks.append(heading)
            continue
        }
        if isDivider(trimmed) {
            flushNonCode()
            blocks.append(.divider)
            continue
        }
        if let quoted = parseQuote(line) {
            flushParagraph()
            flushLists()
            flushTable()
            quote.append(quoted)
            continue
        }
        if let item = parseListItem(line, numbered: false) {
            flushParagraph()
            flushQuote()
            flushTable()
            if !numbered.isEmpty { flushLists() }
            bullets.append(item)
            continue
        }
        if let item = parseListItem(line, numbered: true) {
            flushParagraph()
            flushQuote()
            flushTable()
            if !bullets.isEmpty { flushLists() }
            numbered.append(item)
            continue
        }
        if trimmed.hasPrefix("|") {
            flushParagraph()
            flushLists()
            flushQuote()
            if let row = parseTableRow(trimmed), !isSeparatorRow(row) {
                tableRows.append(row)
            }
            continue
        }
        flushLists()
        flushQuote()
        flushTable()
        paragraph.append(trimmed)
    }

    // Cerca sin cerrar (streaming): el resto es código igualmente.
    if fenceMarker != nil {
        blocks.append(.code(language: fenceLanguage, code: fenceLines.joined(separator: "\n")))
    }
    flushNonCode()
    return blocks
}

private func openingFence(_ trimmed: String) -> (marker: String, language: String)? {
    for marker in ["```", "~~~"] {
        if trimmed.hasPrefix(marker) {
            let language = trimmed.dropFirst(marker.count)
                .trimmingCharacters(in: .whitespaces)
            return (marker, language)
        }
    }
    return nil
}

private func parseHeading(_ trimmed: String) -> MarkdownBlock? {
    var level = 0
    for char in trimmed {
        guard char == "#" else { break }
        level += 1
    }
    guard (1 ... 6).contains(level) else { return nil }
    let rest = trimmed.dropFirst(level)
    guard rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return .heading(level: level, text: text)
}

private func isDivider(_ trimmed: String) -> Bool {
    guard trimmed.count >= 3 else { return false }
    guard let first = trimmed.first, first == "*" || first == "-" || first == "_" else { return false }
    return trimmed.allSatisfy { $0 == first }
}

private func parseQuote(_ line: String) -> String? {
    var index = line.startIndex
    while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
    guard index < line.endIndex, line[index] == ">" else { return nil }
    var rest = line[line.index(after: index)...]
    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
    return String(rest)
}

private func parseListItem(_ line: String, numbered: Bool) -> MarkdownListItem? {
    var index = line.startIndex
    var spaces = 0
    while index < line.endIndex, line[index] == " " || line[index] == "\t" {
        spaces += line[index] == "\t" ? 2 : 1
        index = line.index(after: index)
    }
    guard index < line.endIndex else { return nil }
    if numbered {
        var end = index
        while end < line.endIndex, line[end].isNumber { end = line.index(after: end) }
        guard end > index, end < line.endIndex,
              line[end] == "." || line[end] == ")"
        else { return nil }
        let after = line.index(after: end)
        guard after < line.endIndex, line[after] == " " || line[after] == "\t" else { return nil }
        let text = line[after...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(indent: spaces / 2, text: text)
    } else {
        let char = line[index]
        guard char == "-" || char == "*" || char == "+" else { return nil }
        let after = line.index(after: index)
        guard after < line.endIndex, line[after] == " " || line[after] == "\t" else { return nil }
        let text = line[after...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(indent: spaces / 2, text: text)
    }
}

private func parseTableRow(_ trimmed: String) -> [String]? {
    var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    if cells.first?.isEmpty == true { cells.removeFirst() }
    if cells.last?.isEmpty == true { cells.removeLast() }
    guard !cells.isEmpty else { return nil }
    return cells
}

private func isSeparatorRow(_ row: [String]) -> Bool {
    !row.isEmpty && row.allSatisfy { cell in
        let stripped = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" }
    }
}

// MARK: - Markdown en línea

private let inlineOptions = AttributedString.MarkdownParsingOptions(
    interpretedSyntax: .inlineOnlyPreservingWhitespace
)

/// Interpreta negritas, cursivas, código y enlaces conservando los saltos de
/// línea simples (el parseo completo los colapsaría). Si el Markdown llega a
/// medio formar (streaming), degrada por líneas sin perder texto.
func inlineAttributed(_ text: String) -> AttributedString {
    if let parsed = try? AttributedString(markdown: text, options: inlineOptions) {
        return styleInlineCode(parsed)
    }
    var result = AttributedString()
    let lines = text.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
        if index > 0 { result += AttributedString("\n") }
        if let parsed = try? AttributedString(markdown: line, options: inlineOptions) {
            result += styleInlineCode(parsed)
        } else {
            result += AttributedString(line)
        }
    }
    return result
}

/// El código en línea (`TDL.lua`) venía con el mismo color que el texto y se
/// perdía en el párrafo. Se tiñe con fondo tenue y monoespaciada para que se
/// distinga sin romper la lectura.
private func styleInlineCode(_ input: AttributedString) -> AttributedString {
    var output = input
    for run in output.runs {
        guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
        output[run.range].font = .system(.callout, design: .monospaced)
        output[run.range].backgroundColor = Color.primary.opacity(0.12)
    }
    return output
}

/// Cuerpo de lectura del chat: un punto por encima del `.body` del sistema
/// (13pt en macOS) para que los párrafos largos no se vean apretados.
func chatReadingFont(scale: Double, weight: Font.Weight = .regular) -> Font {
    .system(size: 14 * scale, weight: weight)
}

// MARK: - Vistas

/// `Equatable` para que SwiftUI no reparse el Markdown (ni re-tintee el
/// código) de los mensajes intactos en cada repintado de streaming: solo el
/// mensaje que cambia re-evalúa su cuerpo.
struct MarkdownBody: View, Equatable {
    let text: String
    var codeTheme: CodeThemeName = .catppuccin

    var body: some View {
        let blocks = splitMarkdownBlocks(text)
        if blocks.isEmpty {
            Text(text).lineSpacing(5)
        } else {
            // Sin ancho infinito: abraza el texto corto y solo llega al
            // ancho completo cuando el contenido lo necesita (el Text largo
            // envuelve hasta todo el ancho propuesto por el HStack padre).
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks.indices, id: \.self) { index in
                    MarkdownBlockView(block: blocks[index], codeTheme: codeTheme)
                }
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var codeTheme: CodeThemeName = .catppuccin
    @Environment(\.zoomScale) private var zoomScale

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(chatReadingFont(scale: zoomScale))
                .foregroundStyle(.primary.opacity(0.93))
                .lineSpacing(5)
        case .heading(let level, let text):
            Text(inlineAttributed(text))
                .font(headingFont(level: level, scale: zoomScale))
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .padding(.top, 6)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(chatReadingFont(scale: zoomScale, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(inlineAttributed(items[index].text))
                            .font(chatReadingFont(scale: zoomScale))
                            .foregroundStyle(.primary.opacity(0.93))
                            .lineSpacing(5)
                    }
                    .padding(.leading, CGFloat(items[index].indent) * 16)
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(chatReadingFont(scale: zoomScale, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(inlineAttributed(items[index].text))
                            .font(chatReadingFont(scale: zoomScale))
                            .foregroundStyle(.primary.opacity(0.93))
                            .lineSpacing(5)
                    }
                    .padding(.leading, CGFloat(items[index].indent) * 16)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(inlineAttributed(text))
                    .font(chatReadingFont(scale: zoomScale))
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
            }
            .padding(.vertical, 4)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, codeTheme: codeTheme)
        case .table(let rows):
            TableBlockView(rows: rows)
        case .divider:
            Divider().padding(.vertical, 6)
        }
    }

    private func headingFont(level: Int, scale: Double) -> Font {
        switch level {
        case 1: return zoomFont(.title3, scale: scale).bold()
        case 2: return zoomFont(.headline, scale: scale, weight: .semibold)
        default: return chatReadingFont(scale: scale, weight: .semibold)
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    var codeTheme: CodeThemeName = .catppuccin
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.zoomScale) private var zoomScale
    @State private var copied = false

    private var palette: CodePalette {
        codePalette(theme: codeTheme, dark: colorScheme != .light)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !language.isEmpty {
                    Text(language)
                        .font(zoomFont(.caption2, scale: zoomScale))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "Copiado ✓" : "Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .buttonStyle(.link)
                .font(zoomFont(.caption2, scale: zoomScale))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(highlightedCode(code, language: language, palette: palette))
                    .font(zoomFont(.callout, scale: zoomScale, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(
            palette.background,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        )
    }
}

private struct TableBlockView: View {
    let rows: [[String]]
    @Environment(\.zoomScale) private var zoomScale

    private var columns: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0 ..< columns, id: \.self) { column in
                        Text(inlineAttributed(cell(row: row, column: column)))
                            .font(
                                row == 0
                                    ? zoomFont(.callout, scale: zoomScale).bold()
                                    : zoomFont(.callout, scale: zoomScale)
                            )
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 5)
                if row == 0, rows.count > 1 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        )
    }

    private func cell(row: Int, column: Int) -> String {
        guard column < rows[row].count else { return "" }
        return rows[row][column]
    }
}
