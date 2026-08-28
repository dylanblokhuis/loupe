import Foundation

/// A YAML reader covering the subset that kubeconfig files and Kubernetes
/// manifests use: block mappings and sequences, flow collections, quoted and
/// plain scalars, block scalars, comments and multi-document streams.
///
/// Anchors, aliases, tags and complex keys are intentionally unsupported —
/// they never appear in the files this app reads, and a focused parser is far
/// easier to reason about than a general one.
enum YAMLParser {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        let line: Int
        var description: String { "YAML error on line \(line + 1): \(message)" }
    }

    private struct Line {
        let indent: Int
        let text: Substring
        let number: Int
    }

    /// Parses the first document of a YAML stream.
    static func parse(_ source: String) throws -> JSONValue {
        try parseDocuments(source).first ?? .null
    }

    /// Parses every document in a `---` separated stream.
    static func parseDocuments(_ source: String) throws -> [JSONValue] {
        var documents: [[Line]] = [[]]
        var lineNumber = 0
        var pendingBlockScalarIndent: Int?

        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            defer { lineNumber += 1 }
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let indent = line.prefix(while: { $0 == " " }).count
            let content = line.dropFirst(indent)

            // Lines belonging to a block scalar are kept verbatim.
            if let blockIndent = pendingBlockScalarIndent {
                if content.isEmpty || indent > blockIndent {
                    documents[documents.count - 1].append(Line(indent: indent, text: content, number: lineNumber))
                    continue
                }
                pendingBlockScalarIndent = nil
            }

            if content.isEmpty || content.hasPrefix("#") { continue }
            if content.hasPrefix("---") && content.dropFirst(3).allSatisfy({ $0 == " " }) {
                if !documents[documents.count - 1].isEmpty { documents.append([]) }
                continue
            }
            if content.hasPrefix("...") { continue }

            // `key: |2-` and friends must arm the verbatim capture too, so the
            // comment and blank lines inside the block survive.
            if let value = splitKey(content)?.1 ?? (isSequenceEntry(content) ? content.dropFirst(2) : nil),
               blockScalarHeader(value.drop(while: { $0 == " " })) != nil {
                pendingBlockScalarIndent = indent
            } else if blockScalarHeader(content) != nil {
                pendingBlockScalarIndent = indent
            }
            documents[documents.count - 1].append(Line(indent: indent, text: content, number: lineNumber))
        }

        return try documents.filter { !$0.isEmpty }.map { lines in
            var cursor = 0
            let value = try parseNode(lines, &cursor, minIndent: lines[0].indent)
            // Anything left over means the indentation stopped making sense.
            // Returning the truncated prefix would be far worse than failing:
            // the YAML editor applies what it parses as a full replace.
            guard cursor == lines.count else {
                throw Error(
                    message: "unexpected indentation; \(lines.count - cursor) line(s) could not be parsed",
                    line: lines[cursor].number
                )
            }
            return value
        }
    }

    // MARK: Block parsing

    private static func parseNode(_ lines: [Line], _ cursor: inout Int, minIndent: Int) throws -> JSONValue {
        guard cursor < lines.count else { return .null }
        let indent = lines[cursor].indent
        guard indent >= minIndent else { return .null }
        if isSequenceEntry(lines[cursor].text) {
            return try parseSequence(lines, &cursor, indent: indent)
        }
        return try parseMapping(lines, &cursor, indent: indent)
    }

    private static func isSequenceEntry(_ text: Substring) -> Bool {
        text == "-" || text.hasPrefix("- ")
    }

    private static func parseSequence(_ lines: [Line], _ cursor: inout Int, indent: Int) throws -> JSONValue {
        var items: [JSONValue] = []
        while cursor < lines.count, lines[cursor].indent == indent, isSequenceEntry(lines[cursor].text) {
            let line = lines[cursor]
            let inlineText = line.text == "-" ? Substring("") : line.text.dropFirst(2)
            let inline = inlineText.drop(while: { $0 == " " })
            // `- key: value` starts a mapping whose keys line up after the dash.
            let entryIndent = indent + (line.text.count - inline.count)
            cursor += 1

            if inline.isEmpty {
                items.append(try parseNode(lines, &cursor, minIndent: indent + 1))
            } else if isSequenceEntry(inline) {
                var synthetic = collectInlineBlock(lines, &cursor, head: inline, at: entryIndent, number: line.number)
                var innerCursor = 0
                items.append(try parseSequence(synthetic, &innerCursor, indent: entryIndent))
                synthetic.removeAll()
            } else if splitKey(inline) != nil {
                var synthetic = collectInlineBlock(lines, &cursor, head: inline, at: entryIndent, number: line.number)
                var innerCursor = 0
                items.append(try parseMapping(synthetic, &innerCursor, indent: entryIndent))
                synthetic.removeAll()
            } else if let header = blockScalarHeader(inline) {
                items.append(.string(try readBlockScalar(lines, &cursor, parentIndent: indent, header: header)))
            } else {
                items.append(try scalar(inline, line: line.number))
            }
        }
        return .array(items)
    }

    /// Re-materialises `- key: value` (or `- - item`) as a standalone block so
    /// the nested node can be parsed by the ordinary block parsers.
    private static func collectInlineBlock(
        _ lines: [Line], _ cursor: inout Int, head: Substring, at entryIndent: Int, number: Int
    ) -> [Line] {
        var block = [Line(indent: entryIndent, text: head, number: number)]
        while cursor < lines.count, lines[cursor].text.isEmpty || lines[cursor].indent >= entryIndent {
            block.append(lines[cursor])
            cursor += 1
        }
        return block
    }

    private static func parseMapping(_ lines: [Line], _ cursor: inout Int, indent: Int) throws -> JSONValue {
        var object = JSONObject()
        while cursor < lines.count, lines[cursor].indent == indent, !isSequenceEntry(lines[cursor].text) {
            let line = lines[cursor]
            guard let (key, rawValue) = splitKey(line.text) else {
                throw Error(message: "expected 'key: value'", line: line.number)
            }
            cursor += 1
            let value = rawValue.drop(while: { $0 == " " })

            if value.isEmpty {
                // The nested block may be a sequence indented at the same level
                // as its key, which YAML permits.
                if cursor < lines.count, lines[cursor].indent == indent, isSequenceEntry(lines[cursor].text) {
                    object[key] = try parseSequence(lines, &cursor, indent: indent)
                } else {
                    object[key] = try parseNode(lines, &cursor, minIndent: indent + 1)
                }
            } else if let header = blockScalarHeader(value) {
                object[key] = .string(try readBlockScalar(lines, &cursor, parentIndent: indent, header: header))
            } else {
                object[key] = try scalar(value, line: line.number)
            }
        }
        return .object(object)
    }

    /// Splits `key: value`, ignoring colons inside quotes or flow collections.
    private static func splitKey(_ text: Substring) -> (String, Substring)? {
        var depth = 0
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let q = quote {
                if c == q { quote = nil }
            } else {
                switch c {
                case "'", "\"": quote = c
                case "[", "{": depth += 1
                case "]", "}": depth -= 1
                case ":" where depth == 0:
                    let next = text.index(after: index)
                    if next == text.endIndex || text[next] == " " {
                        let key = unquote(String(text[text.startIndex..<index]).trimmingCharacters(in: .whitespaces))
                        let rest = next == text.endIndex ? Substring("") : text[next...]
                        return (key, rest)
                    }
                case "#" where depth == 0 && index > text.startIndex && text[text.index(before: index)] == " ":
                    return nil
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private enum BlockStyle { case literal, folded }
    private enum Chomping { case clip, strip, keep }

    private struct BlockHeader {
        var style: BlockStyle
        var chomping: Chomping
        /// Explicit indentation indicator (`|2`), relative to the parent node.
        var indentation: Int?
    }

    private static func blockScalarHeader(_ text: Substring) -> BlockHeader? {
        let head = text.prefix(while: { !$0.isWhitespace })
        guard let first = head.first, first == "|" || first == ">" else { return nil }
        var chomping = Chomping.clip
        var indentation: Int?
        for character in head.dropFirst() {
            switch character {
            case "-": chomping = .strip
            case "+": chomping = .keep
            case "1"..."9": indentation = (indentation ?? 0) * 10 + Int(String(character))!
            default: return nil
            }
        }
        // Only a trailing comment may follow the header.
        let rest = text.dropFirst(head.count).drop(while: { $0 == " " })
        guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
        return BlockHeader(
            style: first == "|" ? .literal : .folded, chomping: chomping, indentation: indentation
        )
    }

    private static func readBlockScalar(
        _ lines: [Line], _ cursor: inout Int, parentIndent: Int, header: BlockHeader
    ) throws -> String {
        var collected: [(indent: Int, text: Substring)] = []
        while cursor < lines.count, lines[cursor].text.isEmpty || lines[cursor].indent > parentIndent {
            collected.append((lines[cursor].indent, lines[cursor].text))
            cursor += 1
        }
        var trailingBlanks = 0
        while collected.last?.text.isEmpty == true {
            collected.removeLast()
            trailingBlanks += 1
        }
        guard let firstContentIndent = collected.first(where: { !$0.text.isEmpty })?.indent else { return "" }
        let base = header.indentation.map { parentIndent + $0 } ?? firstContentIndent

        let rows = collected.map { entry -> String in
            entry.text.isEmpty ? "" : String(repeating: " ", count: max(0, entry.indent - base)) + String(entry.text)
        }
        let body: String
        switch header.style {
        case .literal:
            body = rows.joined(separator: "\n")
        case .folded:
            // Line breaks between plain lines fold into spaces; a blank line
            // survives as a single newline, per the YAML folding rules.
            var out = ""
            var previousWasFoldable = false
            var atLineStart = true
            for row in rows {
                if row.isEmpty {
                    out += "\n"
                    previousWasFoldable = false
                    atLineStart = true
                    continue
                }
                let foldable = !row.hasPrefix(" ")
                if atLineStart {
                    out += row
                } else if previousWasFoldable, foldable {
                    out += " " + row
                } else {
                    out += "\n" + row
                }
                previousWasFoldable = foldable
                atLineStart = false
            }
            body = out
        }

        guard !body.isEmpty else { return body }
        switch header.chomping {
        case .strip: return body
        case .clip: return body + "\n"
        case .keep: return body + String(repeating: "\n", count: trailingBlanks + 1)
        }
    }

    // MARK: Scalars and flow collections

    private static func scalar(_ text: Substring, line: Int) throws -> JSONValue {
        let trimmed = stripComment(text).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            var flow = FlowParser(text: Array(trimmed), line: line)
            return try flow.parse()
        }
        return literal(trimmed)
    }

    private static func stripComment(_ text: Substring) -> Substring {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "#", index > text.startIndex, text[text.index(before: index)] == " " {
                return text[text.startIndex..<index]
            }
            index = text.index(after: index)
        }
        return text
    }

    static func literal(_ raw: String) -> JSONValue {
        if raw.hasPrefix("'") || raw.hasPrefix("\"") { return .string(unquote(raw)) }
        switch raw {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON": return .bool(true)
        case "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF": return .bool(false)
        default: break
        }
        // Only treat something as a number when it round-trips cleanly; version
        // strings such as `1.2.3` and quantities such as `100m` stay strings.
        if raw.first.map({ $0.isNumber || $0 == "-" || $0 == "+" }) == true, !hasRedundantLeadingZero(raw) {
            if raw.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "+" }), Int(raw) != nil {
                return .number(JSONNumber(text: raw))
            }
            if Double(raw) != nil, raw.filter({ $0 == "." }).count <= 1 {
                return .number(JSONNumber(text: raw))
            }
        }
        return .string(raw)
    }

    /// `010` is an octal literal in YAML 1.1 and not valid JSON, so values with
    /// a redundant leading zero are kept as strings rather than reinterpreted.
    private static func hasRedundantLeadingZero(_ raw: String) -> Bool {
        var digits = Substring(raw)
        if digits.first == "-" || digits.first == "+" { digits = digits.dropFirst() }
        return digits.count > 1 && digits.first == "0" && digits.dropFirst().first != "."
    }

    static func unquote(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            let body = String(raw.dropFirst().dropLast())
            var out = ""
            var iterator = body.makeIterator()
            while let c = iterator.next() {
                guard c == "\\" else { out.append(c); continue }
                switch iterator.next() {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case let other?: out.append(other)
                case nil: break
                }
            }
            return out
        }
        return raw
    }

    /// Minimal reader for `[a, b]` / `{a: b}` flow collections.
    private struct FlowParser {
        let text: [Character]
        let line: Int
        var index = 0
        var depth = 0

        init(text: [Character], line: Int) {
            self.text = text
            self.line = line
        }

        mutating func parse() throws -> JSONValue {
            guard depth < 128 else { throw Error(message: "flow collection nested too deeply", line: line) }
            depth += 1
            defer { depth -= 1 }
            skipSpaces()
            guard index < text.count else { return .null }
            switch text[index] {
            case "[": return try parseArray()
            case "{": return try parseObject()
            default: return YAMLParser.literal(readToken(stoppingAt: [",", "]", "}"]))
            }
        }

        private mutating func skipSpaces() {
            while index < text.count, text[index] == " " { index += 1 }
        }

        private mutating func parseArray() throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipSpaces()
            if index < text.count, text[index] == "]" { index += 1; return .array(items) }
            while index < text.count {
                items.append(try parse())
                skipSpaces()
                guard index < text.count else { break }
                if text[index] == "," { index += 1; skipSpaces(); continue }
                if text[index] == "]" { index += 1; return .array(items) }
                throw Error(message: "unexpected '\(text[index])' in flow sequence", line: line)
            }
            throw Error(message: "unterminated flow sequence", line: line)
        }

        private mutating func parseObject() throws -> JSONValue {
            index += 1
            var object = JSONObject()
            skipSpaces()
            if index < text.count, text[index] == "}" { index += 1; return .object(object) }
            while index < text.count {
                let key = readToken(stoppingAt: [":"])
                guard index < text.count, text[index] == ":" else {
                    throw Error(message: "expected ':' in flow mapping", line: line)
                }
                index += 1
                skipSpaces()
                object[YAMLParser.unquote(key)] = try parse()
                skipSpaces()
                guard index < text.count else { break }
                if text[index] == "," { index += 1; skipSpaces(); continue }
                if text[index] == "}" { index += 1; return .object(object) }
                throw Error(message: "unexpected '\(text[index])' in flow mapping", line: line)
            }
            throw Error(message: "unterminated flow mapping", line: line)
        }

        private mutating func readToken(stoppingAt terminators: Set<Character>) -> String {
            skipSpaces()
            var out = ""
            var quote: Character?
            while index < text.count {
                let c = text[index]
                if let q = quote {
                    out.append(c)
                    if c == q { quote = nil }
                } else if c == "'" || c == "\"" {
                    quote = c
                    out.append(c)
                } else if terminators.contains(c) {
                    break
                } else {
                    out.append(c)
                }
                index += 1
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Emitting

enum YAMLEmitter {
    /// Renders a value as YAML using the same layout `kubectl get -o yaml` uses.
    static func string(from value: JSONValue) -> String {
        var out = ""
        emit(value, into: &out, indent: 0, inheritedIndent: false)
        if out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    private static func emit(_ value: JSONValue, into out: inout String, indent: Int, inheritedIndent: Bool) {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .object(let object):
            if object.isEmpty {
                out += (inheritedIndent ? "" : pad) + "{}\n"
                return
            }
            var first = true
            for (key, child) in object.pairs {
                let prefix = (inheritedIndent && first) ? "" : pad
                first = false
                switch child {
                case .object(let nested) where !nested.isEmpty:
                    out += prefix + scalarKey(key) + ":\n"
                    emit(child, into: &out, indent: indent + 1, inheritedIndent: false)
                case .array(let items) where !items.isEmpty:
                    out += prefix + scalarKey(key) + ":\n"
                    emit(child, into: &out, indent: indent, inheritedIndent: false)
                default:
                    out += prefix + scalarKey(key) + ": "
                    emitScalar(child, into: &out, indent: indent + 1)
                }
            }
        case .array(let items):
            if items.isEmpty {
                out += (inheritedIndent ? "" : pad) + "[]\n"
                return
            }
            for item in items {
                switch item {
                case .object(let nested) where !nested.isEmpty:
                    out += pad + "- "
                    emit(item, into: &out, indent: indent + 1, inheritedIndent: true)
                case .array(let nested) where !nested.isEmpty:
                    out += pad + "-\n"
                    emit(item, into: &out, indent: indent + 1, inheritedIndent: false)
                default:
                    out += pad + "- "
                    emitScalar(item, into: &out, indent: indent + 1)
                }
            }
        default:
            out += (inheritedIndent ? "" : pad)
            emitScalar(value, into: &out, indent: indent)
        }
    }

    private static func emitScalar(_ value: JSONValue, into out: inout String, indent: Int) {
        switch value {
        case .null: out += "null\n"
        case .bool(let b): out += (b ? "true" : "false") + "\n"
        case .number(let n): out += n.text + "\n"
        case .array: out += "[]\n"
        case .object: out += "{}\n"
        case .string(let text):
            // Block scalars normalise line breaks, so a string containing a
            // carriage return has to be double-quoted to survive intact.
            if text.unicodeScalars.contains(where: { $0 == "\r" }) {
                out += doubleQuoted(text) + "\n"
            } else if text.contains(where: \.isNewline) {
                emitBlockScalar(text, into: &out, indent: indent)
            } else {
                out += quoteIfNeeded(text) + "\n"
            }
        }
    }

    /// Writes a literal block scalar, choosing the chomping indicator so the
    /// value re-parses to exactly the same string.
    private static func emitBlockScalar(_ text: String, into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

        var trailingNewlines = 0
        while lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
            trailingNewlines += 1
        }
        guard lines.contains(where: { !$0.isEmpty }) else {
            out += doubleQuoted(text) + "\n"
            return
        }

        let chomping: String
        switch trailingNewlines {
        case 0: chomping = "-"
        case 1: chomping = ""
        default: chomping = "+"
        }
        // A first line starting with a space would otherwise be read as the
        // block's indentation, so state the indentation explicitly.
        let indicator = lines.first?.hasPrefix(" ") == true ? "2" : ""

        out += "|" + indicator + chomping + "\n"
        for line in lines {
            out += line.isEmpty ? "\n" : pad + line + "\n"
        }
        if trailingNewlines > 1 {
            out += String(repeating: "\n", count: trailingNewlines - 1)
        }
    }

    private static func doubleQuoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func scalarKey(_ key: String) -> String {
        quoteIfNeeded(key)
    }

    private static func quoteIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        // Every spelling the parser resolves to a bool or null must be quoted,
        // or the value changes type on the way back in.
        let reserved: Set<String> = [
            "~", "-",
            "true", "True", "TRUE", "false", "False", "FALSE",
            "null", "Null", "NULL", "yes", "Yes", "YES", "no", "No", "NO",
            "on", "On", "ON", "off", "Off", "OFF",
        ]
        if reserved.contains(s) { return "\"\(s)\"" }
        if Double(s) != nil { return "\"\(s)\"" }
        let needsQuoting = s.first == " " || s.last == " "
            || s.first.map({ "-?:,[]{}#&*!|>'\"%@`".contains($0) }) == true
            || s.contains(": ") || s.contains(" #") || s.contains("\t")
        if needsQuoting {
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return s
    }
}
