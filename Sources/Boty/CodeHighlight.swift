import Foundation
import SwiftUI

// MARK: - Tema de resaltado

enum CodeThemeName: String, Codable, CaseIterable, Sendable {
    case catppuccin
    case oneDark

    var displayName: String {
        switch self {
        case .catppuccin: return "Catppuccin"
        case .oneDark: return "One Dark"
        }
    }
}

struct CodePalette: Sendable, Equatable {
    var background: Color
    var text: Color
    var keyword: Color
    var string: Color
    var comment: Color
    var number: Color
    var function: Color
    var type: Color
    var directive: Color
}

/// Paleta del tema, con variante clara u oscura según el modo del sistema.
func codePalette(theme: CodeThemeName, dark: Bool) -> CodePalette {
    switch (theme, dark) {
    case (.catppuccin, true): // Catppuccin Mocha
        return CodePalette(
            background: Color(hex: "#1E1E2E"),
            text: Color(hex: "#CDD6F4"),
            keyword: Color(hex: "#CBA6F7"),
            string: Color(hex: "#A6E3A1"),
            comment: Color(hex: "#7F849C"),
            number: Color(hex: "#FAB387"),
            function: Color(hex: "#89B4FA"),
            type: Color(hex: "#F9E2AF"),
            directive: Color(hex: "#F38BA8")
        )
    case (.catppuccin, false): // Catppuccin Latte
        return CodePalette(
            background: Color(hex: "#EFF1F5"),
            text: Color(hex: "#4C4F69"),
            keyword: Color(hex: "#8839EF"),
            string: Color(hex: "#40A02B"),
            comment: Color(hex: "#8C8FA1"),
            number: Color(hex: "#FE640B"),
            function: Color(hex: "#1E66F5"),
            type: Color(hex: "#DF8E1D"),
            directive: Color(hex: "#D20F39")
        )
    case (.oneDark, true): // Atom One Dark
        return CodePalette(
            background: Color(hex: "#282C34"),
            text: Color(hex: "#ABB2BF"),
            keyword: Color(hex: "#C678DD"),
            string: Color(hex: "#98C379"),
            comment: Color(hex: "#5C6370"),
            number: Color(hex: "#D19A66"),
            function: Color(hex: "#61AFEF"),
            type: Color(hex: "#E5C07B"),
            directive: Color(hex: "#E06C75")
        )
    case (.oneDark, false): // Atom One Light
        return CodePalette(
            background: Color(hex: "#FAFAFA"),
            text: Color(hex: "#383A42"),
            keyword: Color(hex: "#A626A4"),
            string: Color(hex: "#50A14F"),
            comment: Color(hex: "#A0A1A7"),
            number: Color(hex: "#986801"),
            function: Color(hex: "#4078F2"),
            type: Color(hex: "#C18401"),
            directive: Color(hex: "#E45649")
        )
    }
}

// MARK: - Lenguajes

enum CodeTokenKind: Sendable, Equatable {
    case text
    case keyword
    case string
    case comment
    case number
    case function
    case type
    case directive
}

struct CodeDelimPair: Sendable {
    var start: String
    var end: String
}

struct CodeLanguageConfig: Sendable {
    var lineComments: [String]
    var blockComments: [CodeDelimPair]
    var keywords: Set<String>
    /// Corchetes largos estilo Lua: `[[ ]]` (texto) y `--[[ ]]` (comentario).
    var longBrackets: Bool
}

private let swiftKeywords: Set<String> = [
    "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
    "catch", "class", "continue", "convenience", "default", "defer", "didSet",
    "do", "dynamic", "else", "enum", "extension", "fallthrough", "false",
    "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in",
    "indirect", "infix", "init", "inout", "internal", "is", "isolated", "lazy",
    "let", "mutating", "nil", "nonisolated", "nonmutating", "open", "operator",
    "optional", "override", "postfix", "precedence", "prefix", "private",
    "protocol", "public", "repeat", "required", "rethrows", "return", "self",
    "Self", "set", "some", "static", "struct", "subscript", "super", "switch",
    "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
    "where", "while", "willSet",
]

private let pythonKeywords: Set<String> = [
    "False", "None", "True", "and", "as", "assert", "async", "await", "break",
    "case", "class", "continue", "def", "del", "elif", "else", "except",
    "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
    "match", "nonlocal", "not", "or", "pass", "raise", "return", "try",
    "while", "with", "yield",
]

private let jsKeywords: Set<String> = [
    "abstract", "as", "async", "await", "break", "case", "catch", "class",
    "const", "constructor", "continue", "declare", "default", "delete", "do",
    "else", "enum", "export", "extends", "false", "finally", "for", "from",
    "function", "get", "if", "implements", "import", "in", "instanceof",
    "interface", "let", "module", "namespace", "new", "null", "of", "override",
    "private", "protected", "public", "readonly", "require", "return",
    "satisfies", "set", "static", "super", "switch", "this", "throw", "true",
    "try", "type", "typeof", "var", "void", "while", "with", "yield",
]

private let luaKeywords: Set<String> = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
]

private let shellKeywords: Set<String> = [
    "case", "coproc", "do", "done", "elif", "else", "esac", "fi", "for",
    "function", "if", "in", "return", "select", "then", "time", "until",
    "while",
]

private let sqlKeywords: Set<String> = [
    "add", "all", "alter", "and", "as", "asc", "between", "by", "case",
    "column", "create", "delete", "desc", "distinct", "drop", "else", "end",
    "exists", "false", "foreign", "from", "full", "group", "having", "in",
    "index", "inner", "insert", "into", "is", "join", "key", "left", "like",
    "limit", "not", "null", "offset", "on", "or", "order", "outer", "primary",
    "references", "right", "select", "set", "table", "then", "true", "union",
    "unique", "update", "values", "view", "when", "where",
]

private let cKeywords: Set<String> = [
    "abstract", "alignas", "alignof", "assert", "auto", "become", "bool",
    "boolean", "box", "break", "byte", "case", "catch", "chan", "char",
    "checked", "class", "const", "constexpr", "consteval", "constinit",
    "continue", "crate", "crossinline", "data", "default", "defer", "delete",
    "do", "double", "dyn", "else", "enum", "explicit", "export", "extends",
    "extern", "fallthrough", "false", "field", "final", "finally", "float",
    "fn", "for", "friend", "fun", "func", "goto", "if", "impl", "implements",
    "import", "in", "init", "inline", "inner", "instanceof", "int", "interface",
    "iota", "lateinit", "let", "long", "loop", "macro", "map", "match", "mod",
    "move", "mut", "mutable", "namespace", "native", "new", "nil", "noexcept",
    "noinline", "null", "nullptr", "object", "operator", "out", "override",
    "package", "param", "permits", "priv", "private", "protected", "pub",
    "public", "range", "receiver", "record", "ref", "register", "reified",
    "return", "sealed", "select", "self", "Self", "short", "signed", "sizeof",
    "static", "strictfp", "struct", "super", "suspend", "switch", "synchronized",
    "tailrec", "template", "this", "throw", "throws", "trait", "transient",
    "true", "try", "type", "typealias", "typedef", "typename", "typeof",
    "unchecked", "union", "unsafe", "unsigned", "unsized", "use", "using",
    "val", "var", "vararg", "virtual", "void", "volatile", "when", "where",
    "while", "with", "yield",
]

private let genericKeywords: Set<String> = [
    "and", "as", "async", "await", "break", "by", "case", "catch", "class",
    "const", "continue", "def", "default", "define", "do", "done", "elif",
    "else", "end", "endfor", "endfunction", "endif", "except", "export",
    "false", "fi", "finally", "for", "from", "func", "function", "guard",
    "if", "ifdef", "ifndef", "import", "in", "include", "is", "lambda", "let",
    "local", "match", "new", "nil", "not", "null", "or", "pass", "raise",
    "repeat", "require", "return", "select", "self", "struct", "super",
    "switch", "then", "this", "throw", "throws", "true", "try", "until",
    "var", "when", "where", "while", "with", "yield",
]

private let cBlockComments = [CodeDelimPair(start: "/*", end: "*/")]

func codeLanguageConfig(for language: String) -> CodeLanguageConfig {
    let lang = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch lang {
    case "swift":
        return CodeLanguageConfig(lineComments: ["//"], blockComments: cBlockComments, keywords: swiftKeywords, longBrackets: false)
    case "python", "py", "python3", "py3":
        return CodeLanguageConfig(lineComments: ["#"], blockComments: [], keywords: pythonKeywords, longBrackets: false)
    case "javascript", "js", "jsx", "typescript", "ts", "tsx", "mjs", "cjs", "json", "json5":
        return CodeLanguageConfig(lineComments: ["//"], blockComments: cBlockComments, keywords: jsKeywords, longBrackets: false)
    case "lua":
        return CodeLanguageConfig(lineComments: ["--"], blockComments: [], keywords: luaKeywords, longBrackets: true)
    case "bash", "sh", "shell", "zsh", "fish", "console", "terminal", "shellscript", "sh-session":
        return CodeLanguageConfig(lineComments: ["#"], blockComments: [], keywords: shellKeywords, longBrackets: false)
    case "sql", "mysql", "postgresql", "pgsql", "sqlite":
        return CodeLanguageConfig(lineComments: ["--", "#"], blockComments: cBlockComments, keywords: sqlKeywords, longBrackets: false)
    case "html", "xml", "xhtml", "vue", "svelte", "astro", "svg":
        return CodeLanguageConfig(lineComments: [], blockComments: [CodeDelimPair(start: "<!--", end: "-->")], keywords: [], longBrackets: false)
    case "css", "less":
        return CodeLanguageConfig(lineComments: [], blockComments: cBlockComments, keywords: [], longBrackets: false)
    case "scss", "sass":
        return CodeLanguageConfig(lineComments: ["//"], blockComments: cBlockComments, keywords: [], longBrackets: false)
    case "c", "h", "cpp", "hpp", "cc", "cxx", "c++", "h++", "cs", "c#", "csharp",
         "java", "kt", "kotlin", "kts", "scala", "go", "rs", "rust", "dart",
         "php", "objc", "objective-c", "obj-c", "m", "mm", "proto", "solidity",
         "groovy", "zig", "nim", "v", "vala":
        return CodeLanguageConfig(lineComments: ["//"], blockComments: cBlockComments, keywords: cKeywords, longBrackets: false)
    case "ruby", "rb", "r", "perl", "pl", "yaml", "yml", "toml", "ini", "cfg",
         "conf", "dockerfile", "docker", "makefile", "make", "cmake", "nginx",
         "gitignore", "env", "properties", "elixir", "ex", "jl", "julia", "tcl":
        return CodeLanguageConfig(lineComments: ["#"], blockComments: [], keywords: genericKeywords, longBrackets: false)
    default:
        // Sin etiqueta: tolera los estilos más comunes.
        return CodeLanguageConfig(lineComments: ["//", "#"], blockComments: cBlockComments, keywords: genericKeywords, longBrackets: false)
    }
}

// MARK: - Tokenizer (una pasada, tolera código a medio llegar)

/// Trocea el código en segmentos consecutivos del mismo tipo. Los comentarios
/// y textos sin cerrar (streaming) se tiñen hasta el final sin perder texto.
func highlightCodeSegments(_ code: String, language: String) -> [(CodeTokenKind, String)] {
    let config = codeLanguageConfig(for: language)
    var segments: [(CodeTokenKind, String)] = []
    var buffer = ""
    var bufferKind: CodeTokenKind = .text

    func push(_ kind: CodeTokenKind, _ text: String) {
        guard !text.isEmpty else { return }
        if kind == bufferKind {
            buffer += text
        } else {
            if !buffer.isEmpty { segments.append((bufferKind, buffer)) }
            bufferKind = kind
            buffer = text
        }
    }

    var index = code.startIndex
    let end = code.endIndex

    func hasPrefix(_ s: String) -> Bool { code[index...].hasPrefix(s) }
    func char(at i: String.Index) -> Character { code[i] }
    func next(_ i: String.Index) -> String.Index { code.index(after: i) }

    while index < end {
        // Comentario largo Lua: --[[ ... ]] (con niveles --[==[ ... ]==]).
        if config.longBrackets, hasPrefix("--"),
           let afterDashes = code.index(index, offsetBy: 2, limitedBy: end),
           let level = longOpenLevel(code, afterDashes)
        {
            let searchFrom = code.index(afterDashes, offsetBy: level + 2, limitedBy: end) ?? end
            let closeEnd = longCloseIndex(code, from: searchFrom, level: level) ?? end
            push(.comment, String(code[index ..< closeEnd]))
            index = closeEnd
            continue
        }
        // Comentario de línea.
        var matchedLineComment: String?
        for prefix in config.lineComments where hasPrefix(prefix) {
            matchedLineComment = prefix
            break
        }
        if matchedLineComment != nil {
            var j = index
            while j < end, char(at: j) != "\n" { j = next(j) }
            push(.comment, String(code[index ..< j]))
            index = j
            continue
        }
        // Comentario de bloque.
        var matchedBlock: CodeDelimPair?
        for pair in config.blockComments where hasPrefix(pair.start) {
            matchedBlock = pair
            break
        }
        if let pair = matchedBlock {
            let searchFrom = code.index(index, offsetBy: pair.start.count, limitedBy: end) ?? end
            let closeEnd = code.range(of: pair.end, range: searchFrom ..< end)?.upperBound ?? end
            push(.comment, String(code[index ..< closeEnd]))
            index = closeEnd
            continue
        }
        // Texto largo Lua: [[ ... ]].
        if config.longBrackets, let level = longOpenLevel(code, index) {
            let searchFrom = code.index(index, offsetBy: level + 2, limitedBy: end) ?? end
            let closeEnd = longCloseIndex(code, from: searchFrom, level: level) ?? end
            push(.string, String(code[index ..< closeEnd]))
            index = closeEnd
            continue
        }
        // Texto multilínea con comillas triples.
        var triple: String?
        for delim in ["\"\"\"", "'''"] where hasPrefix(delim) {
            triple = delim
            break
        }
        if let delim = triple {
            push(.string, String(code[index ..< scanQuoted(code, from: index, delimiter: delim, stopAtNewline: false)]))
            index = scanQuoted(code, from: index, delimiter: delim, stopAtNewline: false)
            continue
        }
        // Cadenas con " o ` (el backtick abarca líneas: plantillas JS).
        let c = char(at: index)
        if c == "\"" || c == "`" {
            let stopAtNewline = c == "\"" && !config.longBrackets
            let closeEnd = scanQuoted(code, from: index, delimiter: String(c), stopAtNewline: stopAtNewline)
            push(.string, String(code[index ..< closeEnd]))
            index = closeEnd
            continue
        }
        // Apóstrofe: solo es cadena si se cierra en la misma línea; así
        // "don't" no tiñe medio bloque (en Lua sí abarca líneas).
        if c == "'" {
            if let closeEnd = scanApostrophe(code, from: index) {
                push(.string, String(code[index ..< closeEnd]))
                index = closeEnd
                continue
            } else if config.longBrackets {
                let closeEnd = scanQuoted(code, from: index, delimiter: "'", stopAtNewline: false)
                push(.string, String(code[index ..< closeEnd]))
                index = closeEnd
                continue
            }
        }
        // Número.
        if c.isNumber {
            var j = index
            while j < end, char(at: j).isLetter || char(at: j).isNumber || char(at: j) == "_" { j = next(j) }
            if j < end, char(at: j) == ".",
               let afterDot = code.index(j, offsetBy: 1, limitedBy: end),
               char(at: afterDot).isNumber
            {
                j = next(afterDot)
                while j < end, char(at: j).isLetter || char(at: j).isNumber || char(at: j) == "_" { j = next(j) }
            }
            push(.number, String(code[index ..< j]))
            index = j
            continue
        }
        // Directivas y decoradores: #if, @State, $HOME, ${x}, $0.
        if c == "#" || c == "@" || c == "$" {
            if let closeEnd = scanDirective(code, from: index) {
                push(.directive, String(code[index ..< closeEnd]))
                index = closeEnd
                continue
            }
        }
        // Identificador: palabra clave, llamada, tipo o texto.
        if c.isLetter || c == "_" {
            var j = index
            while j < end, char(at: j).isLetter || char(at: j).isNumber || char(at: j) == "_" { j = next(j) }
            let word = String(code[index ..< j])
            let kind: CodeTokenKind
            if config.keywords.contains(word) {
                kind = .keyword
            } else {
                var k = j
                while k < end, char(at: k) == " " || char(at: k) == "\t" { k = next(k) }
                if k < end, char(at: k) == "(" {
                    kind = .function
                } else if let first = word.first, first.isUppercase {
                    kind = .type
                } else {
                    kind = .text
                }
            }
            push(kind, word)
            index = j
            continue
        }
        // Cualquier otro carácter (puntuación, espacios, saltos).
        push(.text, String(c))
        index = next(index)
    }

    if !buffer.isEmpty { segments.append((bufferKind, buffer)) }
    return segments
}

/// Escanea una cadena entrecomillada desde la apertura (incluida) hasta el
/// cierre (incluido) o el final. Respeta `\x` y, si se pide, corta en el
/// salto de línea (cadenas de una línea a medio llegar por streaming).
private func scanQuoted(_ code: String, from: String.Index, delimiter: String, stopAtNewline: Bool) -> String.Index {
    var j = code.index(from, offsetBy: delimiter.count, limitedBy: code.endIndex) ?? code.endIndex
    while j < code.endIndex {
        if code[j] == "\\" {
            j = code.index(after: j)
            if j < code.endIndex { j = code.index(after: j) }
            continue
        }
        if stopAtNewline, code[j] == "\n" { return j }
        if code[j...].hasPrefix(delimiter) {
            return code.index(j, offsetBy: delimiter.count, limitedBy: code.endIndex) ?? code.endIndex
        }
        j = code.index(after: j)
    }
    return j
}

/// Cierre de un apóstrofe en la misma línea (o `nil` si no lo hay).
private func scanApostrophe(_ code: String, from: String.Index) -> String.Index? {
    var j = code.index(after: from)
    while j < code.endIndex, code[j] != "\n" {
        if code[j] == "\\" {
            j = code.index(after: j)
            if j < code.endIndex { j = code.index(after: j) }
            continue
        }
        if code[j] == "'" { return code.index(after: j) }
        j = code.index(after: j)
    }
    return nil
}

private func isDirectiveName(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "_"
}

/// Escanea `#nombre`, `@nombre`, `$nombre`, `${...}` o `$0` (o `nil`).
private func scanDirective(_ code: String, from: String.Index) -> String.Index? {
    let marker = code[from]
    guard let second = code.index(from, offsetBy: 1, limitedBy: code.endIndex) else { return nil }
    if marker == "$", second < code.endIndex, code[second] == "{" {
        var j = code.index(after: second)
        while j < code.endIndex, code[j] != "}" { j = code.index(after: j) }
        return j < code.endIndex ? code.index(after: j) : j
    }
    guard second < code.endIndex, isDirectiveName(code[second]) else { return nil }
    // `#` solo llega aquí cuando no es comentario de línea en este lenguaje.
    var j = second
    while j < code.endIndex, isDirectiveName(code[j]) { j = code.index(after: j) }
    return j
}

/// Si en `index` hay una apertura larga `[=*\[`, devuelve el nivel (`=`).
private func longOpenLevel(_ code: String, _ index: String.Index) -> Int? {
    guard index < code.endIndex, code[index] == "[" else { return nil }
    var j = code.index(after: index)
    var level = 0
    while j < code.endIndex, code[j] == "=" {
        level += 1
        j = code.index(after: j)
    }
    guard j < code.endIndex, code[j] == "[" else { return nil }
    return level
}

/// Fin del cierre largo `]=*]` del mismo nivel (excluido) o `nil`.
private func longCloseIndex(_ code: String, from: String.Index, level: Int) -> String.Index? {
    var j = from
    while j < code.endIndex {
        if code[j] == "]" {
            var k = code.index(after: j)
            var count = 0
            while k < code.endIndex, code[k] == "=", count < level {
                count += 1
                k = code.index(after: k)
            }
            if count == level, k < code.endIndex, code[k] == "]" {
                return code.index(after: k)
            }
        }
        j = code.index(after: j)
    }
    return nil
}

// MARK: - AttributedString

/// Por encima de este tamaño el bloque se muestra en un solo color para no
/// atascar el re-render durante el streaming.
let codeHighlightLengthLimit = 20_000

/// Tiñe el código con la paleta. Nunca pierde ni reordena texto.
func highlightedCode(_ code: String, language: String, palette: CodePalette) -> AttributedString {
    func color(for kind: CodeTokenKind) -> Color {
        switch kind {
        case .text: return palette.text
        case .keyword: return palette.keyword
        case .string: return palette.string
        case .comment: return palette.comment
        case .number: return palette.number
        case .function: return palette.function
        case .type: return palette.type
        case .directive: return palette.directive
        }
    }
    if code.count > codeHighlightLengthLimit {
        var plain = AttributedString(code)
        plain.foregroundColor = palette.text
        return plain
    }
    var result = AttributedString()
    for (kind, text) in highlightCodeSegments(code, language: language) {
        var run = AttributedString(text)
        run.foregroundColor = color(for: kind)
        result += run
    }
    return result
}
